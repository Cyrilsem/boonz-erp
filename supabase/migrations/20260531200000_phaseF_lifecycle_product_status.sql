-- Phase F: lifecycle inclusion flag. status='inactive' hides a product from
-- lifecycle analysis (Overview / Deep Dive / Heatmap / Divest). Absence = active.
-- Articles: 1 (single writer RPC), 2 (RLS), 4 (DEFINER validates), 8 (audit), 12 (forward-only), 14 (no shadow table).
-- Applied to prod 2026-05-31 via mcp apply_migration (name: phaseF_lifecycle_product_status); this file is the repo copy.

CREATE TABLE IF NOT EXISTS public.lifecycle_product_status (
  pod_product_id uuid PRIMARY KEY
    REFERENCES public.pod_products(pod_product_id) ON DELETE CASCADE,
  status   text NOT NULL DEFAULT 'inactive'
    CHECK (status IN ('active','inactive')),
  reason   text,
  set_by   uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  set_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.lifecycle_product_status IS
  'Per-product lifecycle inclusion flag. status=inactive hides the product from lifecycle analysis. Absence of a row = active. Canonical writer: set_product_lifecycle_status.';

CREATE INDEX IF NOT EXISTS idx_lps_inactive
  ON public.lifecycle_product_status (pod_product_id) WHERE status = 'inactive';

ALTER TABLE public.lifecycle_product_status ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lps_select ON public.lifecycle_product_status;
CREATE POLICY lps_select ON public.lifecycle_product_status
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS lps_write ON public.lifecycle_product_status;
CREATE POLICY lps_write ON public.lifecycle_product_status
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles
                 WHERE id=(SELECT auth.uid())
                 AND role = ANY (ARRAY['operator_admin','superadmin','manager'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_profiles
                 WHERE id=(SELECT auth.uid())
                 AND role = ANY (ARRAY['operator_admin','superadmin','manager'])));

-- Article 8: universal audit trigger (PK = pod_product_id)
DROP TRIGGER IF EXISTS trg_lps_audit ON public.lifecycle_product_status;
CREATE TRIGGER trg_lps_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.lifecycle_product_status
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_write('pod_product_id');

-- Article 1 + 4: sole canonical writer.
CREATE OR REPLACE FUNCTION public.set_product_lifecycle_status(
  p_pod_product_id uuid,
  p_status         text,
  p_reason         text DEFAULT NULL
) RETURNS public.lifecycle_product_status
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_row  public.lifecycle_product_status;
  v_actor uuid := auth.uid();
  v_role  text;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_actor;
  IF v_role IS NULL OR v_role <> ALL (ARRAY['operator_admin','superadmin','manager']) THEN
    RAISE EXCEPTION 'role % not permitted to set lifecycle status', COALESCE(v_role,'(none)');
  END IF;
  IF p_status IS NULL OR p_status <> ALL (ARRAY['active','inactive']) THEN
    RAISE EXCEPTION 'invalid status %', p_status;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pod_products WHERE pod_product_id = p_pod_product_id) THEN
    RAISE EXCEPTION 'unknown pod_product_id %', p_pod_product_id;
  END IF;

  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','set_product_lifecycle_status',true);

  INSERT INTO public.lifecycle_product_status (pod_product_id, status, reason, set_by, set_at)
  VALUES (p_pod_product_id, p_status, p_reason, v_actor, now())
  ON CONFLICT (pod_product_id) DO UPDATE
    SET status = EXCLUDED.status,
        reason = EXCLUDED.reason,
        set_by = EXCLUDED.set_by,
        set_at = now()
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_product_lifecycle_status(uuid,text,text) TO authenticated;

-- One-time seed of 14 retired products with zero live units on active machines.
SELECT set_config('app.via_rpc','true',true);
SELECT set_config('app.rpc_name','phaseF_lifecycle_product_status_seed',true);

INSERT INTO public.lifecycle_product_status (pod_product_id, status, reason)
VALUES
 ('830f0e48-1910-442e-8f4e-a58111fa9fc7','inactive','seed: retired, 0 live units (7 Days Jumbo Croissant)'),
 ('6ccc3ddb-3aaa-4581-8c36-edc06d02422d','inactive','seed: retired, 0 live units (Almarai Farm Select Juice Mix)'),
 ('6f8988fa-37b7-4b72-9e9f-0c88707a0755','inactive','seed: retired, 0 live units (Almarai Farm Select Juice Orange)'),
 ('666787dd-6c68-4120-b1d1-a60ece7de663','inactive','seed: retired, 0 live units (Coco Water)'),
 ('f6681ea9-45d7-4be9-9e05-34ca4bbcce8c','inactive','seed: retired, 0 live units (Galaxy Kunafa)'),
 ('ac28684e-d09a-4c04-bbfb-bc7aeb61faff','inactive','seed: retired, 0 live units (Garden Veggie)'),
 ('4495a19a-3335-4d4f-a917-822fae540728','inactive','seed: retired, 0 live units (Happy holidays)'),
 ('b405b76a-e2d3-4499-9cda-92eb55cc66a3','inactive','seed: retired, 0 live units (Lays Chips)'),
 ('fd516858-ff6f-4ca4-b509-87b6ed481f1e','inactive','seed: retired, 0 live units (Loacker Quadratini)'),
 ('6d2f53dc-d224-458f-a117-ed873d590e7a','inactive','seed: retired, 0 live units (Mezzmix Chocolate & Peanut Butter)'),
 ('c08d8b84-087f-4703-975d-2e2bf8da2345','inactive','seed: retired, 0 live units (Mezzmix Hummus)'),
 ('7396f99c-47fa-4e9a-9fb8-8ead40c25e20','inactive','seed: retired, 0 live units (Nutella B Ready)'),
 ('3185b0d5-b57d-4331-a9de-b9bdda487fa8','inactive','seed: retired, 0 live units (Sprite)'),
 ('23aa44a6-ac97-4ad8-8a60-ea1ca95ba330','inactive','seed: retired, 0 live units (Tannourine Water)')
ON CONFLICT (pod_product_id) DO NOTHING;
