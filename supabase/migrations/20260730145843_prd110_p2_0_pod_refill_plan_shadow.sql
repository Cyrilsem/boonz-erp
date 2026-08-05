-- PRD-110 P2.0 · Phase 2 foundation: shadow plan ledger for engine_add_pod_v3.
-- DESIGN SIGNOFF: docs/architecture/ADR-shadow-plan-tables.md (Constitution Article 14).
-- Read that ADR before changing anything here: §3 (why a view cannot suffice), §5 (the four
-- anti-staleness guarantees), §8 (the obligations this migration discharges).
-- LAW 4 of the PRD-110 goal command: SHADOW, DON'T SWITCH. engine_add_pod (v19) is never modified.

CREATE TABLE IF NOT EXISTS public.pod_refill_plan_shadow (
  -- shadow-only columns (ADR §2)
  run_id                    uuid        NOT NULL,
  engine_tag                text        NOT NULL,
  produced_at               timestamptz NOT NULL DEFAULT now(),
  -- grain + payload, mirroring public.pod_refill_plan
  plan_date                 date        NOT NULL,
  machine_id                uuid        NOT NULL REFERENCES public.machines(machine_id),
  shelf_id                  uuid        NOT NULL REFERENCES public.shelf_configurations(shelf_id),
  pod_product_id            uuid        NOT NULL REFERENCES public.pod_products(pod_product_id),
  action                    text        NOT NULL,
  qty                       integer     NOT NULL,
  reasoning                 jsonb,
  decision                  jsonb,
  source_origin             public.source_origin_enum NOT NULL,
  from_machine_id           uuid        REFERENCES public.machines(machine_id),
  preferred_wh_inventory_id uuid        REFERENCES public.warehouse_inventory(wh_inventory_id) ON DELETE SET NULL,
  CONSTRAINT pod_refill_plan_shadow_pkey
    PRIMARY KEY (run_id, plan_date, machine_id, shelf_id, pod_product_id, action),
  CONSTRAINT pod_refill_plan_shadow_action_check
    CHECK (action = ANY (ARRAY['REFILL'::text, 'REMOVE'::text, 'ADD_NEW'::text, 'M2W'::text])),
  CONSTRAINT pod_refill_plan_shadow_qty_check CHECK (qty >= 0),
  CONSTRAINT pod_refill_plan_shadow_engine_tag_chk CHECK (btrim(engine_tag) <> ''),
  CONSTRAINT pod_refill_plan_shadow_from_machine_origin_chk
    CHECK (from_machine_id IS NULL OR source_origin = 'internal_transfer'::public.source_origin_enum)
);

COMMENT ON TABLE public.pod_refill_plan_shadow IS
  'PRD-110 Phase 2 shadow plan ledger. engine_add_pod_v3 writes HERE, never to pod_refill_plan '
  '(goal-command LAW 4). Append-only, write-once per run_id; no row is ever UPDATEd, so no row can '
  'go stale (the Article 14 risk). NO operational consumer: not dispatch, not stitch, not preflight, '
  'not the FE, not the 8pm advisory. Readers are v_shadow_vs_live_plan_v3, the scoreboard, and CS. '
  'Design signoff + full reasoning: docs/architecture/ADR-shadow-plan-tables.md';

COMMENT ON COLUMN public.pod_refill_plan_shadow.run_id IS
  'One uuid per engine invocation. Re-runs are additive and distinguishable, never destructive.';
COMMENT ON COLUMN public.pod_refill_plan_shadow.engine_tag IS
  'Which engine produced this row (e.g. engine_add_pod_v3). The diff must never have to guess.';
COMMENT ON COLUMN public.pod_refill_plan_shadow.produced_at IS
  'Engine-run wall clock. Ordering for "latest shadow run for this plan_date". There is no '
  'unqualified read that could quietly return an older run (ADR §5(3)).';

-- DELIBERATE OMISSIONS from the live-table column set, recorded so a later leg does not "restore"
-- them by reflex: status, approved_at, approved_by, stitched_at, edited_at, edited_by,
-- linked_refill_pk, linked_swap_id, linked_intent_id, created_at, updated_at.
-- Every one is live-plan LIFECYCLE. A shadow row is never approved, stitched, edited or dispatched,
-- and carrying those columns would invite a consumer to believe a shadow plan has a lifecycle it
-- cannot have. produced_at replaces created_at. Article 12 is forward-only: adding a column later
-- is legal, so the lean shape costs nothing.

CREATE INDEX IF NOT EXISTS idx_prps_plan_date_produced
  ON public.pod_refill_plan_shadow (plan_date, produced_at DESC);
CREATE INDEX IF NOT EXISTS idx_prps_machine_plan_date
  ON public.pod_refill_plan_shadow (machine_id, plan_date);

-- Article 2 — RLS mandatory, with explicit policies (not an implicit deny-all).
ALTER TABLE public.pod_refill_plan_shadow ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname='public' AND tablename='pod_refill_plan_shadow'
                   AND policyname='pod_refill_plan_shadow_select') THEN
    CREATE POLICY pod_refill_plan_shadow_select ON public.pod_refill_plan_shadow
      FOR SELECT TO authenticated
      USING (EXISTS (SELECT 1 FROM public.user_profiles up
                     WHERE up.id = (SELECT auth.uid())
                       AND up.role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])));
  END IF;

  -- Article 7 — append-only ENFORCED, not by convention. The ADR's entire anti-staleness argument
  -- (§5(1)) is "no row is ever UPDATEd"; these two policies are what make that a fact.
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname='public' AND tablename='pod_refill_plan_shadow'
                   AND policyname='pod_refill_plan_shadow_no_update') THEN
    CREATE POLICY pod_refill_plan_shadow_no_update ON public.pod_refill_plan_shadow
      FOR UPDATE USING (false);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname='public' AND tablename='pod_refill_plan_shadow'
                   AND policyname='pod_refill_plan_shadow_no_delete') THEN
    CREATE POLICY pod_refill_plan_shadow_no_delete ON public.pod_refill_plan_shadow
      FOR DELETE USING (false);
  END IF;
END $$;

-- Article 3 — the authenticated role is SELECT-only here; anon sees nothing at all.
-- NOTE (honest scope): these REVOKEs, not the policies above, are the real boundary for
-- service_role / the table owner, which carry BYPASSRLS. Retention purges (ADR §5(4), 90 days)
-- must go through a dedicated SECURITY DEFINER RPC, exactly as Article 7 prescribes.
REVOKE ALL ON public.pod_refill_plan_shadow FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.pod_refill_plan_shadow FROM authenticated;
GRANT SELECT ON public.pod_refill_plan_shadow TO authenticated;
