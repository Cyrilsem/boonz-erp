-- PRD-141 item 15 rollback. Fast path (no DDL): UPDATE public.pick_urgency_params SET w_empty = 0;
-- Full path: remove the two added terms from v_machine_priority.
UPDATE public.pick_urgency_params SET w_empty = 0.945;
DO $rb$
DECLARE v_def text := pg_get_viewdef('public.v_machine_priority'::regclass);
BEGIN
  v_def := replace(v_def, ' + round((p_2.w_empty * round(mscore.pct_empty_lanes, 2)), 2) AS p_score,', ' AS p_score,');
  v_def := replace(v_def, ' + round((p_2.w_empty * mscore.pct_empty_lanes), 2) AS p_score_aed', ' AS p_score_aed');
  EXECUTE 'CREATE OR REPLACE VIEW public.v_machine_priority AS ' || v_def;
END $rb$;
