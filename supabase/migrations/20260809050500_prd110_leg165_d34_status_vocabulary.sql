-- PRD-110 leg 165 · D-34 (1 of 4 code migrations) · the log's status vocabulary
--
-- S-331 #4: run_pipeline_v3 has failure modes run_nightly_shadow_v3 has never seen.
-- Without a word for each, they all arrive as 'error' and the log stops being read --
-- which is S-112's original complaint, one layer up.
--
--   no_base              the engine produced no base run (its own refusal is nested,
--                        and is preferred over this word when present)
--   composed_empty       a composed plan with ZERO lines. Deliberately NOT a fall-back
--                        to the base: falling back would resurrect every dropped line.
--   compose_error        compose_plan_with_edits_v3 failed
--   stitch_error         stitch_v3 failed, or the pipeline caught its own
--                        planned-vs-consumed mismatch RAISE
--   blocked_demand_error the plan is fine; the D-29 promotion step failed
--
-- ⛔ ADDITIVE ONLY. Every word already in the constraint stays, so no existing row can
--    be orphaned by the swap and no existing assertion changes meaning.

ALTER TABLE public.shadow_runner_log_v3
  DROP CONSTRAINT shadow_runner_log_v3_status_check;

ALTER TABLE public.shadow_runner_log_v3
  ADD CONSTRAINT shadow_runner_log_v3_status_check
  CHECK (status = ANY (ARRAY[
    -- pre-existing, unchanged
    'ok'::text,
    'ok_no_shadow_rows'::text,
    'error'::text,
    'blocked_gate0'::text,
    'skipped'::text,
    'skipped_calendar'::text,
    'no_picks'::text,
    -- D-34: the pipeline's own failure modes
    'no_base'::text,
    'composed_empty'::text,
    'compose_error'::text,
    'stitch_error'::text,
    'blocked_demand_error'::text,
    -- CODY (Article 4): run_pipeline_v3's role gate is STRICTER than this runner's
    -- (operator_admin/superadmin vs +manager/+warehouse). A manager or warehouse caller
    -- is refused by the inner call; that is fail-closed and correct, but it must not
    -- arrive as a generic 'error'. Cron passes a NULL uid and never sees this.
    'role_refused'::text
  ]));

COMMENT ON CONSTRAINT shadow_runner_log_v3_status_check ON public.shadow_runner_log_v3 IS
  'D-34/S-331: the runner reads run_pipeline_v3''s receipt, so the log must be able to name '
  'the pipeline''s failure modes separately from a generic error. v_shadow_runner_health_v3 '
  'whitelists the GOOD words rather than blacklisting the bad ones (S-332) -- if a word is '
  'added here it must be classified there in the SAME unit, or it reads healthy.';
