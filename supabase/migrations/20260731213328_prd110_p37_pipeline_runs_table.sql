-- =====================================================================
-- PRD-110 P3.7 — ONE PIPELINE (WS-E3), part 1: the receipt ledger
-- =====================================================================
-- BUILD-SPEC line 95: "dictated path writes plan_edits + engine lines, single
-- approve; conductor path retired." Charter E3: "dictated instructions compile
-- into the same plan (no parallel conductor path); single approve vocabulary."
--
-- ⛔ THE DEFECT THIS CLOSES (measured, leg 71). stitch_v3 with a NULL source
--    picks the latest run for the date by (produced_at DESC, run_id DESC).
--    pod_refills_shadow.produced_at DEFAULTs to now() = the TRANSACTION
--    timestamp, so a base run and the run composed from it inside ONE
--    transaction TIE on produced_at and the pick collapses onto uuid ordering.
--    Whether the human's overlay reaches the stitched plan is therefore a coin
--    flip. The pipeline never relies on that pick: it passes every run id
--    EXPLICITLY, and this table is the receipt that says which id it passed.
--
-- ⛔ LAW 4: shadow only. Nothing here reads or writes refill_plan_output,
--    pod_refills, dispatch_lines or machines_to_visit. An approval recorded
--    here has NO live effect; the live cutover is a parked CS flag (D-34).
--
-- Dara design notes: D1 uuid PK · D2 NOT NULL except where a NULL is a real
-- state (no compose yet, no stitch yet, not approved) · D3 CHECK on status ·
-- D4 the only FK is approved_by -> user_profiles ON DELETE SET NULL; the run
-- ids are deliberately NOT foreign keys because pod_refills_shadow.run_id is
-- not unique there (a run is many rows) · D5 two indexes, each named for the
-- query it serves · D6 append-only enforced by trigger, not by convention.

CREATE TABLE IF NOT EXISTS public.pipeline_runs_v3 (
  pipeline_run_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_date         date        NOT NULL,
  days_cover        integer     NOT NULL,

  -- WHICH PLAN WAS WHICH. The whole point of the receipt.
  base_source       text        NOT NULL,   -- 'engine' | 'supplied'
  base_run_id       uuid,                   -- NULL only if the engine step failed
  composed_run_id   uuid,                   -- NULL only if compose did not run
  planned_run_id    uuid,                   -- the run handed to stitch, explicitly
  stitch_run_id     uuid,                   -- NULL if stitch did not run

  -- WHAT THE HUMANS ASKED FOR, AND WHAT BECAME OF IT.
  edits_considered  integer     NOT NULL DEFAULT 0,
  edits_applied     integer     NOT NULL DEFAULT 0,
  edits_yielded     integer     NOT NULL DEFAULT 0,

  -- WHAT CAME OUT.
  lines_base        integer     NOT NULL DEFAULT 0,
  units_base        integer     NOT NULL DEFAULT 0,
  lines_planned     integer     NOT NULL DEFAULT 0,
  units_planned     integer     NOT NULL DEFAULT 0,
  rows_stitched     integer     NOT NULL DEFAULT 0,
  units_placed      integer     NOT NULL DEFAULT 0,
  units_blocked     integer     NOT NULL DEFAULT 0,
  blocked_rows      integer     NOT NULL DEFAULT 0,

  status            text        NOT NULL,
  steps             jsonb       NOT NULL DEFAULT '[]'::jsonb,
  note              text,
  started_at        timestamptz NOT NULL,
  finished_at       timestamptz NOT NULL DEFAULT now(),
  duration_ms       integer     NOT NULL DEFAULT 0,
  created_by        uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),

  -- THE SINGLE APPROVE VOCABULARY. The only columns that may ever move.
  approved_at              timestamptz,
  approved_by              uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  approve_reason           text,
  approval_superseded_at   timestamptz,
  approval_superseded_by   uuid,

  CONSTRAINT chk_pipeline_runs_v3_status CHECK (
    status IN ('ok','composed_empty','no_base','error')),
  CONSTRAINT chk_pipeline_runs_v3_base_source CHECK (
    base_source IN ('engine','supplied')),
  CONSTRAINT chk_pipeline_runs_v3_days_cover CHECK (days_cover BETWEEN 1 AND 60),
  -- an approval is a whole event or none of it
  CONSTRAINT chk_pipeline_runs_v3_approval CHECK (
      (approved_at IS NULL AND approved_by IS NULL AND approve_reason IS NULL)
   OR (approved_at IS NOT NULL AND approve_reason IS NOT NULL)),
  CONSTRAINT chk_pipeline_runs_v3_approve_reason CHECK (
    approve_reason IS NULL OR char_length(btrim(approve_reason)) >= 10),
  -- a retired approval must have been an approval first
  CONSTRAINT chk_pipeline_runs_v3_supersede CHECK (
    approval_superseded_at IS NULL OR approved_at IS NOT NULL),
  -- ⛔ LAW 5 in the pipeline dimension: no edit may vanish between the
  --    composer and the receipt.
  CONSTRAINT chk_pipeline_runs_v3_edit_accounting CHECK (
    edits_applied + edits_yielded = edits_considered)
);

-- ⭐ SINGLE APPROVE, STRUCTURALLY. At most one STANDING approval per plan_date.
--    Not writer discipline -- a second concurrent approver cannot create a
--    second approved plan for one night.
CREATE UNIQUE INDEX IF NOT EXISTS ux_pipeline_runs_v3_standing_approval
  ON public.pipeline_runs_v3 (plan_date)
  WHERE approved_at IS NOT NULL AND approval_superseded_at IS NULL;

-- Serves: "show me the pipeline runs for this date, newest first" (the board).
CREATE INDEX IF NOT EXISTS ix_pipeline_runs_v3_date
  ON public.pipeline_runs_v3 (plan_date, started_at DESC);

COMMENT ON TABLE public.pipeline_runs_v3 IS
  'PRD-110 P3.7. Append-only receipt for one engine -> compose -> stitch pipeline run. Records WHICH run id was handed to each stage, so the plan that got stitched is never inferred from an ordering tie. Approval is the only mutable dimension, and at most one approval stands per plan_date.';

-- ---------------------------------------------------------------------
-- APPEND-ONLY. ⛔ S-108: a FOR EACH ROW trigger never sees a TRUNCATE, and
-- GRANT ALL TO service_role carries TRUNCATE. Both guards, from birth.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_pipeline_runs_v3_append_only()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  IF TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'pipeline_runs_v3 is append-only: TRUNCATE refused';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'pipeline_runs_v3 is append-only: DELETE refused (pipeline_run_id %)',
      OLD.pipeline_run_id;
  END IF;

  -- Everything except the approval dimension is frozen at insert.
  IF (NEW.pipeline_run_id, NEW.plan_date, NEW.days_cover, NEW.base_source,
      NEW.base_run_id, NEW.composed_run_id, NEW.planned_run_id, NEW.stitch_run_id,
      NEW.edits_considered, NEW.edits_applied, NEW.edits_yielded,
      NEW.lines_base, NEW.units_base, NEW.lines_planned, NEW.units_planned,
      NEW.rows_stitched, NEW.units_placed, NEW.units_blocked, NEW.blocked_rows,
      NEW.status, NEW.steps, NEW.note, NEW.started_at, NEW.finished_at,
      NEW.duration_ms, NEW.created_by, NEW.created_at)
     IS DISTINCT FROM
     (OLD.pipeline_run_id, OLD.plan_date, OLD.days_cover, OLD.base_source,
      OLD.base_run_id, OLD.composed_run_id, OLD.planned_run_id, OLD.stitch_run_id,
      OLD.edits_considered, OLD.edits_applied, OLD.edits_yielded,
      OLD.lines_base, OLD.units_base, OLD.lines_planned, OLD.units_planned,
      OLD.rows_stitched, OLD.units_placed, OLD.units_blocked, OLD.blocked_rows,
      OLD.status, OLD.steps, OLD.note, OLD.started_at, OLD.finished_at,
      OLD.duration_ms, OLD.created_by, OLD.created_at)
  THEN
    RAISE EXCEPTION 'pipeline_runs_v3 is append-only: only the approval columns may change (pipeline_run_id %)',
      OLD.pipeline_run_id;
  END IF;

  -- ⛔ An approval is an EVENT, not a toggle. It may be granted once and then
  --    retired; it may never be cleared, rewritten, or un-retired. Without
  --    this branch "only the approval columns may change" would still permit
  --    quietly un-approving a plan that had already been approved.
  IF OLD.approved_at IS NOT NULL
     AND (NEW.approved_at IS DISTINCT FROM OLD.approved_at
       OR NEW.approved_by IS DISTINCT FROM OLD.approved_by
       OR NEW.approve_reason IS DISTINCT FROM OLD.approve_reason) THEN
    RAISE EXCEPTION 'pipeline_runs_v3: an approval may not be cleared or rewritten (pipeline_run_id %)',
      OLD.pipeline_run_id;
  END IF;
  IF OLD.approval_superseded_at IS NOT NULL
     AND NEW.approval_superseded_at IS DISTINCT FROM OLD.approval_superseded_at THEN
    RAISE EXCEPTION 'pipeline_runs_v3: a retired approval stays retired (pipeline_run_id %)',
      OLD.pipeline_run_id;
  END IF;

  RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS tg_pipeline_runs_v3_append_only ON public.pipeline_runs_v3;
CREATE TRIGGER tg_pipeline_runs_v3_append_only
  BEFORE UPDATE OR DELETE ON public.pipeline_runs_v3
  FOR EACH ROW EXECUTE FUNCTION public.tg_pipeline_runs_v3_append_only();

DROP TRIGGER IF EXISTS tg_pipeline_runs_v3_no_truncate ON public.pipeline_runs_v3;
CREATE TRIGGER tg_pipeline_runs_v3_no_truncate
  BEFORE TRUNCATE ON public.pipeline_runs_v3
  FOR EACH STATEMENT EXECUTE FUNCTION public.tg_pipeline_runs_v3_append_only();

-- ---------------------------------------------------------------------
-- THE BOARD VIEW. What is planned for a date, and is it approved.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_pipeline_runs_v3 AS
  SELECT p.*,
         (p.approved_at IS NOT NULL AND p.approval_superseded_at IS NULL) AS is_standing_approval,
         CASE WHEN p.approved_at IS NULL                    THEN 'unapproved'
              WHEN p.approval_superseded_at IS NOT NULL     THEN 'approval_retired'
              ELSE 'approved' END AS approval_state
    FROM public.pipeline_runs_v3 p;

COMMENT ON VIEW public.v_pipeline_runs_v3 IS
  'PRD-110 P3.7. pipeline_runs_v3 with the approval state named rather than left to be derived from two nullable timestamps.';

-- ---------------------------------------------------------------------
-- GRANTS. ⛔ S-88/S-104: the GRANT is the write guard, not RLS, and Supabase
-- default privileges hand new public tables to anon at CREATE. Mirrors the
-- ratified sibling plan_edits_v3 exactly.
-- ---------------------------------------------------------------------
ALTER TABLE public.pipeline_runs_v3 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pipeline_runs_v3   FROM PUBLIC, anon;
REVOKE ALL ON public.v_pipeline_runs_v3 FROM PUBLIC, anon;
GRANT SELECT ON public.pipeline_runs_v3   TO authenticated;
GRANT SELECT ON public.v_pipeline_runs_v3 TO authenticated;
GRANT ALL    ON public.pipeline_runs_v3   TO service_role;
GRANT SELECT ON public.v_pipeline_runs_v3 TO service_role;

DROP POLICY IF EXISTS pr_v3_select ON public.pipeline_runs_v3;
CREATE POLICY pr_v3_select ON public.pipeline_runs_v3 FOR SELECT USING (true);
