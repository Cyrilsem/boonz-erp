-- ============================================================================
-- PRD-012-rescue — re-ship PRD-002-refill-pipeline's record_variant_correction
-- with a renamed table to avoid collision with the existing Jaccard-clustering
-- `product_families` table (102 rows, in use by v_product_lifecycle_global_enriched).
--
-- Supersedes 20260521233552_prd002_006_product_families.sql (never applied due
-- to the collision).
--
-- Repoints variant_action_log.product_family_id FK from the Jaccard table to
-- the new curated table. variant_action_log was empty (0 rows) at apply time.
--
-- Cody articles: 1 (sole canonical writer for variant correction), 4 (role +
-- input validation + app.via_rpc), 7 (variant_action_log + curated_product_families
-- have append-only intent), 12 (forward-only — drops a constraint pointing at
-- the wrong table, not the entity itself), 14 (no _v2 — curated_* is a new
-- entity, not a shadow of product_families).
--
-- Applied to prod 2026-05-26 via MCP.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.curated_product_families (
  product_family_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  family_name         text NOT NULL UNIQUE CHECK (length(btrim(family_name)) > 0),
  display_name        text NOT NULL,
  notes               text,
  is_active           boolean NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.curated_product_families IS
  'PRD-012-rescue (supersedes PRD-002/006 product_families intent): manually-curated grouping for multi-variant SKUs. Distinct from public.product_families which is Jaccard-clustering output.';

ALTER TABLE public.curated_product_families ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cpf_select_authenticated ON public.curated_product_families;
CREATE POLICY cpf_select_authenticated ON public.curated_product_families
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS cpf_write_admins ON public.curated_product_families;
CREATE POLICY cpf_write_admins ON public.curated_product_families
  FOR ALL TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.user_profiles
            WHERE id = (SELECT auth.uid())
              AND role = ANY (ARRAY['operator_admin','superadmin','manager']))
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.user_profiles
            WHERE id = (SELECT auth.uid())
              AND role = ANY (ARRAY['operator_admin','superadmin','manager']))
  );

ALTER TABLE public.boonz_products
  ADD COLUMN IF NOT EXISTS product_family_id uuid
    REFERENCES public.curated_product_families(product_family_id) ON DELETE SET NULL;

COMMENT ON COLUMN public.boonz_products.product_family_id IS
  'PRD-012-rescue: optional curated family grouping (NOT the Jaccard product_families clustering output). NULL = standalone SKU. Backfill is CS-curated.';

CREATE INDEX IF NOT EXISTS idx_boonz_products_curated_family
  ON public.boonz_products (product_family_id)
  WHERE product_family_id IS NOT NULL;

ALTER TABLE public.variant_action_log
  DROP CONSTRAINT IF EXISTS variant_action_log_product_family_id_fkey;

ALTER TABLE public.variant_action_log
  ADD CONSTRAINT variant_action_log_product_family_id_fkey
  FOREIGN KEY (product_family_id)
  REFERENCES public.curated_product_families(product_family_id)
  ON DELETE SET NULL;

CREATE OR REPLACE VIEW public.v_product_family_members
WITH (security_invoker = true) AS
SELECT
  bp.product_id,
  bp.boonz_product_name        AS product_name,
  bp.product_family_id,
  cpf.family_name,
  cpf.display_name             AS family_display_name,
  cpf.is_active                AS family_is_active
FROM public.boonz_products bp
LEFT JOIN public.curated_product_families cpf
  ON cpf.product_family_id = bp.product_family_id;

CREATE OR REPLACE FUNCTION public.touch_curated_product_families_updated_at()
RETURNS trigger LANGUAGE plpgsql
AS $touch$
BEGIN NEW.updated_at := now(); RETURN NEW; END
$touch$;

DROP TRIGGER IF EXISTS trg_cpf_touch_updated_at ON public.curated_product_families;
CREATE TRIGGER trg_cpf_touch_updated_at
  BEFORE UPDATE ON public.curated_product_families
  FOR EACH ROW EXECUTE FUNCTION public.touch_curated_product_families_updated_at();

CREATE OR REPLACE FUNCTION public.record_variant_correction(
  p_refill_dispatching_id uuid,
  p_planned_variant_id    uuid,
  p_new_variant_id        uuid,
  p_qty                   numeric,
  p_action_type           text DEFAULT 'return_variant_change',
  p_reason_code           text DEFAULT NULL,
  p_free_text             text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $rpc$
DECLARE
  v_caller_id      uuid := (SELECT auth.uid());
  v_caller_role    text;
  v_dispatch       refill_dispatching%ROWTYPE;
  v_planned_family uuid;
  v_new_family     uuid;
  v_planned_name   text;
  v_new_name       text;
  v_log_id         uuid;
  v_pod_old_row    pod_inventory%ROWTYPE;
  v_pod_new_row    pod_inventory%ROWTYPE;
  v_today          date := CURRENT_DATE;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'record_variant_correction', true);

  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN
    ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'record_variant_correction: role % not authorized', COALESCE(v_caller_role, 'none');
  END IF;

  IF p_refill_dispatching_id IS NULL THEN RAISE EXCEPTION 'p_refill_dispatching_id required'; END IF;
  IF p_new_variant_id IS NULL THEN RAISE EXCEPTION 'p_new_variant_id required'; END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'p_qty must be > 0 (got %)', p_qty; END IF;
  IF p_action_type NOT IN ('return_variant_change','return_variant_split','dispatch_substitution','dispatch_extra_variant') THEN
    RAISE EXCEPTION 'p_action_type % not allowed', p_action_type;
  END IF;
  IF p_planned_variant_id IS NULL AND p_action_type <> 'dispatch_extra_variant' THEN
    RAISE EXCEPTION 'p_planned_variant_id required unless action_type=dispatch_extra_variant';
  END IF;

  SELECT * INTO v_dispatch FROM refill_dispatching WHERE dispatch_id = p_refill_dispatching_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_refill_dispatching_id; END IF;

  IF p_planned_variant_id IS NOT NULL THEN
    SELECT product_family_id, boonz_product_name INTO v_planned_family, v_planned_name
    FROM boonz_products WHERE product_id = p_planned_variant_id;
    IF v_planned_name IS NULL THEN RAISE EXCEPTION 'planned_variant_id % not found', p_planned_variant_id; END IF;
  END IF;

  SELECT product_family_id, boonz_product_name INTO v_new_family, v_new_name
  FROM boonz_products WHERE product_id = p_new_variant_id;
  IF v_new_name IS NULL THEN RAISE EXCEPTION 'new_variant_id % not found', p_new_variant_id; END IF;

  IF p_action_type <> 'dispatch_extra_variant'
     AND p_planned_variant_id IS NOT NULL
     AND v_planned_family IS DISTINCT FROM v_new_family THEN
    RAISE EXCEPTION 'Variant swap crosses families (% -> %) - use dispatch_extra_variant or assign matching product_family_id first',
      v_planned_name, v_new_name;
  END IF;

  INSERT INTO public.variant_action_log
    (action_type, refill_dispatching_id, machine_id,
     planned_variant_id, new_variant_id, product_family_id,
     qty, reason_code, free_text, created_by)
  VALUES
    (p_action_type, p_refill_dispatching_id, v_dispatch.machine_id,
     p_planned_variant_id, p_new_variant_id,
     COALESCE(v_new_family, v_planned_family),
     p_qty, p_reason_code, p_free_text, v_caller_id)
  RETURNING log_id INTO v_log_id;

  IF p_planned_variant_id IS NOT NULL THEN
    SELECT * INTO v_pod_old_row FROM pod_inventory
    WHERE machine_id = v_dispatch.machine_id
      AND boonz_product_id = p_planned_variant_id
      AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL)
      AND status = 'Active'
    ORDER BY snapshot_at DESC LIMIT 1 FOR UPDATE;

    IF FOUND THEN
      UPDATE pod_inventory
      SET current_stock = GREATEST(COALESCE(current_stock,0) - p_qty, 0),
          status = CASE WHEN COALESCE(current_stock,0) - p_qty <= 0 THEN 'Inactive' ELSE status END,
          removal_reason = CASE WHEN COALESCE(current_stock,0) - p_qty <= 0
                                THEN format('variant_corrected_to_%s', v_new_name)
                                ELSE removal_reason END
      WHERE pod_inventory_id = v_pod_old_row.pod_inventory_id;
    END IF;
  END IF;

  SELECT * INTO v_pod_new_row FROM pod_inventory
  WHERE machine_id = v_dispatch.machine_id
    AND boonz_product_id = p_new_variant_id
    AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL)
    AND status = 'Active'
  ORDER BY snapshot_at DESC LIMIT 1 FOR UPDATE;

  IF FOUND THEN
    UPDATE pod_inventory
    SET current_stock = COALESCE(current_stock,0) + p_qty,
        snapshot_at = now()
    WHERE pod_inventory_id = v_pod_new_row.pod_inventory_id;
  ELSE
    INSERT INTO pod_inventory
      (machine_id, shelf_id, boonz_product_id,
       snapshot_date, current_stock, estimated_remaining,
       expiration_date, batch_id, status, snapshot_at, created_at)
    VALUES
      (v_dispatch.machine_id, v_dispatch.shelf_id, p_new_variant_id,
       v_today, p_qty, p_qty, v_dispatch.expiry_date,
       format('VARIANT-CORR-%s', v_today),
       'Active', now(), now());
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'dispatch_id', p_refill_dispatching_id,
    'action_type', p_action_type,
    'planned_variant', jsonb_build_object('id', p_planned_variant_id, 'name', v_planned_name),
    'new_variant',     jsonb_build_object('id', p_new_variant_id,     'name', v_new_name),
    'qty', p_qty,
    'log_id', v_log_id,
    'machine_id', v_dispatch.machine_id
  );
END
$rpc$;

REVOKE EXECUTE ON FUNCTION public.record_variant_correction(uuid,uuid,uuid,numeric,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_variant_correction(uuid,uuid,uuid,numeric,text,text,text)
  TO authenticated, service_role;
