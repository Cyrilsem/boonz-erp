-- PRD-141 item 15: empty-lane weighting in the P1 machine score.
-- p_score and p_score_aed (what pick_machines_for_refill ranks on) add
-- w_empty * pct_empty_lanes. w_empty already existed (0.945) but no view or function read it;
-- set to the spec default 0.4. Venue-sourced lanes already count in fill_pct and pct_empty_lanes
-- (v_lane_grain / v_machine_health_signals have no sourcing filter) and their refill lines already
-- carry source_origin = 'vox_at_venue', so the VOX-aware half of item 15 needs no change.
-- Night window only. Fleet diff in docs/prds/PRD-141-log.md. Rollback: supabase/rollbacks/prd141_15_rollback.sql
-- (fast path: UPDATE pick_urgency_params SET w_empty = 0;).

UPDATE public.pick_urgency_params SET w_empty = 0.4;

DO $patch$
DECLARE
  v_def text := pg_get_viewdef('public.v_machine_priority'::regclass);
  a_old text := 'round((p_2.w_stale * round(mscore.s_stale, 2)), 2)) AS p_score,';
  a_new text := 'round((p_2.w_stale * round(mscore.s_stale, 2)), 2)) + round((p_2.w_empty * round(mscore.pct_empty_lanes, 2)), 2) AS p_score,';
  b_old text := 'mscore.daily_revenue_aed), 2)) AS p_score_aed';
  b_new text := 'mscore.daily_revenue_aed), 2)) + round((p_2.w_empty * mscore.pct_empty_lanes), 2) AS p_score_aed';
BEGIN
  IF (length(v_def) - length(replace(v_def, a_old, ''))) / length(a_old) <> 1 THEN RAISE EXCEPTION 'prd141_15: anchor a missing or not unique'; END IF;
  IF (length(v_def) - length(replace(v_def, b_old, ''))) / length(b_old) <> 1 THEN RAISE EXCEPTION 'prd141_15: anchor b missing or not unique'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_machine_priority AS ' || replace(replace(v_def, a_old, a_new), b_old, b_new);
END
$patch$;
