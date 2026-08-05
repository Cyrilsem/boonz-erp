-- PRD-110 P3.1c — refill_plan_output_shadow
-- The SKU-grain shadow line table stitch_v3 writes. Sibling of pod_refills_shadow /
-- pod_refill_plan_shadow, created on the IDENTICAL terms pre-authorised by
-- docs/architecture/ADR-shadow-plan-tables.md §2 ("plus whatever sibling shadow tables
-- Phase 2/3 need on identical terms ... if the stitch ladder needs a shadow line table
-- at P3.1"). LAW 4: v3 writes shadow, never the live plan.
--
-- Shadow triplet (run_id / engine_tag / produced_at) per ADR §2.
-- Ledger semantics per ADR §5: INSERT-only, never UPDATEd, never DELETEd.
-- ⛔ Enforced by a TRIGGER, not by RLS. RLS `USING (false)` does NOT bind the table owner,
--    service_role, or a SECURITY DEFINER body - which is exactly how stitch_v3 writes. The
--    trigger fires on every path. This mirrors tg_pod_refills_shadow_append_only on the sibling
--    table. (Cody, P3.1c: a guarantee stated in a comment but unenforced on the real write path
--    is not a guarantee.)

CREATE TABLE IF NOT EXISTS public.refill_plan_output_shadow (
  line_id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- ADR §2 shadow triplet
  run_id                    uuid        NOT NULL,
  engine_tag                text        NOT NULL,
  produced_at               timestamptz NOT NULL DEFAULT now(),

  plan_date                 date        NOT NULL,
  -- the pod_refills_shadow run this line was stitched FROM (provenance, ADR §5.3)
  source_run_id             uuid        NOT NULL,

  machine_id                uuid        NOT NULL REFERENCES public.machines(machine_id),
  shelf_id                  uuid        NOT NULL REFERENCES public.shelf_configurations(shelf_id),

  -- the pod the plan ASKED for (never rewritten by a substitution)
  anchor_pod_product_id     uuid        NOT NULL REFERENCES public.pod_products(pod_product_id),
  -- the pod the ladder RESOLVED to (== anchor except on rung 2 'substitute')
  pod_product_id            uuid        NOT NULL REFERENCES public.pod_products(pod_product_id),
  -- SKU binding. NULL until the FEFO bind leg (P3.1d) lands; the ladder resolves pods, not SKUs.
  boonz_product_id          uuid        NULL     REFERENCES public.boonz_products(product_id),

  action                    text        NOT NULL,
  qty                       integer     NOT NULL,
  qty_needed                integer     NOT NULL,
  qty_shortfall             integer     NOT NULL DEFAULT 0,

  resolved_rung             text        NULL,
  rung_no                   integer     NULL,

  source_origin             public.source_origin_enum NOT NULL,
  from_machine_id           uuid        NULL REFERENCES public.machines(machine_id),
  preferred_wh_inventory_id uuid        NULL REFERENCES public.warehouse_inventory(wh_inventory_id) ON DELETE SET NULL,

  reasoning                 jsonb       NOT NULL DEFAULT '{}'::jsonb,

  CONSTRAINT refill_plan_output_shadow_engine_tag_chk
    CHECK (btrim(engine_tag) <> ''),

  -- Title Case dispatch actions (standing DO-NOT list, BUILD-SPEC line 114). 'Blocked' is
  -- shadow-only: it is the LAW 5 carrier for stranded units, never a dispatchable action.
  CONSTRAINT refill_plan_output_shadow_action_chk
    CHECK (action = ANY (ARRAY['Refill','Add New','Remove','Transfer','Machine To Warehouse','Blocked'])),

  CONSTRAINT refill_plan_output_shadow_qty_chk          CHECK (qty >= 0),
  CONSTRAINT refill_plan_output_shadow_qty_needed_chk   CHECK (qty_needed >= 0),
  CONSTRAINT refill_plan_output_shadow_shortfall_chk    CHECK (qty_shortfall >= 0),

  -- ⛔ The rung NAME and NUMBER can never silently disagree (fixture 40 seq 47 as a schema
  --    invariant, not merely an assertion).
  CONSTRAINT refill_plan_output_shadow_rung_pair_chk
    CHECK (
      (resolved_rung IS NULL AND rung_no IS NULL)
      OR (resolved_rung, rung_no) IN
         (('variant',1),('substitute',2),('alt_wh',3),('m2m',4),('spot_buy',5),('blocked_demand',6))
    ),

  -- LAW 5: a 'Blocked' carrier with qty 0 would BE the silent qty-0 it exists to prevent.
  CONSTRAINT refill_plan_output_shadow_blocked_positive_chk
    CHECK (action <> 'Blocked' OR qty > 0),

  -- mirrors pod_refill_plan_shadow_from_machine_origin_chk exactly
  CONSTRAINT refill_plan_output_shadow_from_machine_origin_chk
    CHECK (from_machine_id IS NULL OR source_origin = 'internal_transfer'::public.source_origin_enum)
);

COMMENT ON TABLE public.refill_plan_output_shadow IS
  'PRD-110 P3.1c. SKU-grain shadow output of stitch_v3. INSERT-only ledger (ADR-shadow-plan-tables §5). '
  'anchor_pod_product_id = what was asked; pod_product_id = what the ladder resolved to. '
  'boonz_product_id is NULL until the P3.1d FEFO bind leg. action=''Blocked'' rows are the LAW 5 '
  'carrier for units the ladder could not place - they are never dispatchable.';

COMMENT ON COLUMN public.refill_plan_output_shadow.qty_shortfall IS
  'S-86: the ladder does NOT cascade after a partial fill, so a terminal rung may serve less than '
  'qty_needed. The stranded remainder is the CONSUMER''s LAW 5 obligation and is carried by a '
  'paired action=''Blocked'' row.';

-- Idempotency (STRESS S4): re-running the same source run cannot mint a duplicate line.
-- Runs remain additive-and-distinguishable by run_id, per ADR §2.
CREATE UNIQUE INDEX IF NOT EXISTS refill_plan_output_shadow_uniq
  ON public.refill_plan_output_shadow
     (run_id, shelf_id, pod_product_id, action,
      COALESCE(boonz_product_id, '00000000-0000-0000-0000-000000000000'::uuid));

CREATE INDEX IF NOT EXISTS refill_plan_output_shadow_plan_date_idx
  ON public.refill_plan_output_shadow (plan_date, run_id);
CREATE INDEX IF NOT EXISTS refill_plan_output_shadow_source_run_idx
  ON public.refill_plan_output_shadow (source_run_id);

-- RLS + grants: mirrors pod_refill_plan_shadow byte-for-byte in posture.
-- Article 1 (single writer): authenticated gets NO insert grant and no insert policy.
ALTER TABLE public.refill_plan_output_shadow ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS refill_plan_output_shadow_select ON public.refill_plan_output_shadow;
CREATE POLICY refill_plan_output_shadow_select
  ON public.refill_plan_output_shadow FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles up
                  WHERE up.id = (SELECT auth.uid())
                    AND up.role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])));

DROP POLICY IF EXISTS refill_plan_output_shadow_no_update ON public.refill_plan_output_shadow;
CREATE POLICY refill_plan_output_shadow_no_update
  ON public.refill_plan_output_shadow FOR UPDATE USING (false);

DROP POLICY IF EXISTS refill_plan_output_shadow_no_delete ON public.refill_plan_output_shadow;
CREATE POLICY refill_plan_output_shadow_no_delete
  ON public.refill_plan_output_shadow FOR DELETE USING (false);

-- Append-only, enforced on EVERY write path (owner, service_role, DEFINER bodies included).
-- Mirrors tg_pod_refills_shadow_append_only exactly.
CREATE OR REPLACE FUNCTION public.tg_refill_plan_output_shadow_append_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $tg$
BEGIN
  RAISE EXCEPTION
    'refill_plan_output_shadow is append-only (ADR-shadow-plan-tables §5.1): % refused. '
    'Shadow rows are immutable evidence for the cutover gate; write a new run_id instead.',
    TG_OP
    USING ERRCODE = '42501';
END;
$tg$;

DROP TRIGGER IF EXISTS tg_refill_plan_output_shadow_append_only ON public.refill_plan_output_shadow;
CREATE TRIGGER tg_refill_plan_output_shadow_append_only
  BEFORE DELETE OR UPDATE ON public.refill_plan_output_shadow
  FOR EACH ROW EXECUTE FUNCTION public.tg_refill_plan_output_shadow_append_only();

REVOKE ALL ON public.refill_plan_output_shadow FROM PUBLIC;
REVOKE ALL ON public.refill_plan_output_shadow FROM anon;
GRANT SELECT, REFERENCES, TRIGGER ON public.refill_plan_output_shadow TO authenticated;
GRANT ALL ON public.refill_plan_output_shadow TO service_role;
