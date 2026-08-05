-- PRD-110 P2.0b — shadow table at the pod_refills (engine-advisory) grain.
--
-- WHY: every PRD-110 Phase-2 acceptance assertion reads public.pod_refills
-- (qty / current_stock / max_stock / clamp_reason / wh_available_pod) or
-- public.blocked_demand. The existing pod_refill_plan_shadow mirrors
-- pod_refill_plan (the plan/approval grain) and carries none of those columns,
-- so engine_add_pod_v3 could not prove its contract without writing the LIVE
-- table — forbidden by PRD-110 LAW 4 ("shadow, don't switch").
--
-- CONSTITUTIONAL BASIS: docs/architecture/ADR-shadow-plan-tables.md §2 names
-- this table and grants sibling shadow tables "on identical terms"; §5's four
-- staleness guarantees apply verbatim. Cody review at apply time (leg 24):
-- ⚠️ Approve with revisions — all four applied here.
--
-- ARTICLE 8 — DELIBERATE, NOT ACCIDENTAL: the generic audit_log_write trigger
-- is NOT attached. pod_refills / pod_refill_plan / blocked_demand all carry it;
-- this table does not, because it is a non-protected diagnostic object taking
-- ~544 INSERTs per nightly run, and run_id + engine_tag + produced_at already
-- answer "who wrote what, when". Stated so it is a decision, not an oversight.

CREATE TABLE IF NOT EXISTS public.pod_refills_shadow (
  -- ADR §2 shadow triple, identical terms to pod_refill_plan_shadow
  run_id             uuid         NOT NULL,
  engine_tag         text         NOT NULL,
  produced_at        timestamptz  NOT NULL DEFAULT now(),

  -- mirrored grain; types identical to public.pod_refills.
  -- FKs use NO ACTION (no explicit clause), mirroring pod_refills exactly:
  -- a shadow must never constrain production more tightly than its live twin.
  plan_date          date         NOT NULL,
  machine_id         uuid         NOT NULL REFERENCES public.machines(machine_id),
  shelf_id           uuid         NOT NULL REFERENCES public.shelf_configurations(shelf_id),
  pod_product_id     uuid         NOT NULL REFERENCES public.pod_products(pod_product_id),
  qty                integer      NOT NULL,
  current_stock      integer      NOT NULL DEFAULT 0,
  max_stock          integer      NOT NULL DEFAULT 0,
  days_cover         integer      NULL,
  signal             text         NULL,
  wh_available_pod   integer      NULL,   -- NULL is MEANINGFUL: see availability_basis
  clamp_reason       text         NULL,
  reasoning          jsonb        NOT NULL DEFAULT '{}'::jsonb,

  -- v3-only columns.
  -- velocity_30d is DELIBERATELY NOT MIRRORED (PRD-110 S-13): that column is
  -- units-per-day despite its name and v19 reads it three incompatible ways.
  -- velocity_instock is daily by construction and named for what it is.
  -- ⚠️ This column RECORDS WHAT THE ENGINE USED. It is not a metric object and
  -- does not make v_shelf_instock_velocity_v3 canonical — that is gated on D-10.
  velocity_instock   numeric(8,3) NULL,
  -- v19 encodes "unknown" and "unconstrained" both as a NULL wh_available_pod.
  -- Under P1.1 sourcing those are opposite meanings; fixture 5/105 seq 10 is
  -- exactly the assertion that ambiguity would defeat. So state the basis.
  availability_basis text         NOT NULL,

  CONSTRAINT pod_refills_shadow_pkey
    PRIMARY KEY (run_id, plan_date, machine_id, shelf_id, pod_product_id),
  CONSTRAINT pod_refills_shadow_qty_check
    CHECK (qty >= 0),
  CONSTRAINT pod_refills_shadow_engine_tag_chk
    CHECK (btrim(engine_tag) <> ''),
  CONSTRAINT pod_refills_shadow_clamp_reason_chk
    CHECK (clamp_reason IS NULL OR btrim(clamp_reason) <> ''),
  CONSTRAINT pod_refills_shadow_availability_basis_chk
    CHECK (availability_basis IN ('boonz_wh','venue','partner','mixed','unknown')),
  -- PRD-110 LAW 5 AS A CONSTRAINT, not an aspiration: a zero must say why.
  -- Empirically true on the entire history of the mirrored table: 834 qty=0
  -- rows across 3841 live pod_refills rows, ZERO with a NULL clamp_reason.
  CONSTRAINT pod_refills_shadow_no_silent_zero
    CHECK (qty > 0 OR clamp_reason IS NOT NULL),
  -- a Boonz-sourced line must state its number...
  CONSTRAINT pod_refills_shadow_unconstrained_is_declared
    CHECK (availability_basis <> 'boonz_wh' OR wh_available_pod IS NOT NULL),
  -- ...and an indeterminate one must say why it is indeterminate (LAW 5 again).
  CONSTRAINT pod_refills_shadow_unknown_is_explained
    CHECK (availability_basis <> 'unknown' OR clamp_reason IS NOT NULL)
);

COMMENT ON TABLE public.pod_refills_shadow IS
  'PRD-110 P2.0b. Shadow of public.pod_refills at the engine-advisory grain; '
  'engine_add_pod_v3 writes here, never the live table (LAW 4). Append-only, '
  'write-once per run_id. Constitutional basis and staleness argument: '
  'docs/architecture/ADR-shadow-plan-tables.md (see the P2 addendum). '
  'Article 8 audit trigger deliberately NOT attached — see migration comment.';

COMMENT ON COLUMN public.pod_refills_shadow.velocity_instock IS
  'Daily rate the engine actually used. NOT a canonical metric object; '
  'v_shelf_instock_velocity_v3 remains not-yet-canonical pending D-10.';
COMMENT ON COLUMN public.pod_refills_shadow.availability_basis IS
  'boonz_wh = constrained, wh_available_pod holds the number. venue/partner = '
  'unconstrained by sourcing. mixed = pod spans both. unknown = unresolved, '
  'and then clamp_reason must explain it.';

-- Indexes serve queries, not the schema (Dara D5).
-- Every fixture coverage probe: NOT EXISTS (... WHERE plan_date=X AND shelf_id=Y)
CREATE INDEX IF NOT EXISTS idx_prs_plan_shelf
  ON public.pod_refills_shadow (plan_date, shelf_id);
-- "latest shadow run for this plan_date" — the ADR's stated purpose for produced_at
CREATE INDEX IF NOT EXISTS idx_prs_plan_latest
  ON public.pod_refills_shadow (plan_date, produced_at DESC);

-- APPEND-ONLY, ENFORCED AGAINST THE WRITER.
-- The RLS policies below bind `authenticated` only; RLS is bypassed by
-- SECURITY DEFINER functions owned by postgres and by service_role. ADR §5
-- guarantee (1) — "write-once per run, never UPDATEd" — is load-bearing for the
-- Article 14 signoff, so it needs enforcement that binds the writer too.
CREATE OR REPLACE FUNCTION public.tg_pod_refills_shadow_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  RAISE EXCEPTION
    'pod_refills_shadow is append-only (ADR-shadow-plan-tables §5.1): % refused. '
    'Shadow rows are immutable evidence for the Phase-2 cutover gate; write a new run_id instead.',
    TG_OP
    USING ERRCODE = '42501';
END;
$fn$;

DROP TRIGGER IF EXISTS tg_pod_refills_shadow_append_only ON public.pod_refills_shadow;
CREATE TRIGGER tg_pod_refills_shadow_append_only
  BEFORE UPDATE OR DELETE ON public.pod_refills_shadow
  FOR EACH ROW EXECUTE FUNCTION public.tg_pod_refills_shadow_append_only();

-- RLS: mirrors pod_refill_plan_shadow exactly ("identical terms").
ALTER TABLE public.pod_refills_shadow ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pod_refills_shadow_select ON public.pod_refills_shadow;
CREATE POLICY pod_refills_shadow_select ON public.pod_refills_shadow
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles up
                  WHERE up.id = (SELECT auth.uid())
                    AND up.role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])));

DROP POLICY IF EXISTS pod_refills_shadow_no_update ON public.pod_refills_shadow;
CREATE POLICY pod_refills_shadow_no_update ON public.pod_refills_shadow
  FOR UPDATE USING (false);

DROP POLICY IF EXISTS pod_refills_shadow_no_delete ON public.pod_refills_shadow;
CREATE POLICY pod_refills_shadow_no_delete ON public.pod_refills_shadow
  FOR DELETE USING (false);

REVOKE ALL ON public.pod_refills_shadow FROM anon;
REVOKE ALL ON public.pod_refills_shadow FROM authenticated;
GRANT SELECT ON public.pod_refills_shadow TO authenticated;
REVOKE ALL ON FUNCTION public.tg_pod_refills_shadow_append_only() FROM anon;
