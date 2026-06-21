-- PRD-043 P1: pick_machines_for_refill v10 -> v11. Enforce the VOX Wed/Fri calendar gate in the
-- normal-day primary pick (the gap: v10 turned the VOX sweep ON for Wed/Fri but never turned VOX OFF
-- in the normal-day ranked_primary). Option B (CS): VOX excluded on non-VOX days EXCEPT a VOX machine
-- that will not survive to its next scheduled VOX day (runway_days < days_until_next_vox_day), tagged
-- 'vox_emergency_offday' and still counted against cap-8.
--
-- NOT flag-gated: this changes the live pick (the intended fix). Forward CREATE OR REPLACE of the
-- canonical pick_machines_for_refill (no _v11 parallel). Two anchored changes only:
--   1) venue gate on ranked_primary's WHERE.
--   2) 'vox_emergency_offday' reason tag in the ordered CTE for VOX primary picks.
-- sibling_ranked already excludes VOX (unchanged). VOX-day sweep branch unchanged. Saturday guard
-- (PRD-035 WS-E) unchanged. No engine / stitch / cron change.
--
-- Surgical DO-block: fetch live def, two anchored replaces, drift guards, EXECUTE.

DO $do$
DECLARE v text;
BEGIN
  SELECT pg_get_functiondef('public.pick_machines_for_refill(date,integer,integer)'::regprocedure) INTO v;

  -- 1) venue gate on ranked_primary
  v := replace(v,
    E'      FROM scored sc WHERE sc.p_tier = ''P1_RESTOCK''\n'
    || E'    ),\n'
    || E'    primary_picks AS (',
    E'      FROM scored sc WHERE sc.p_tier = ''P1_RESTOCK''\n'
    || E'        AND ( v_is_vox_day\n'
    || E'              OR sc.venue_group IS DISTINCT FROM ''VOX''\n'
    || E'              OR ( sc.venue_group = ''VOX'' AND COALESCE(sc.runway_days, 999) < public.days_until_next_vox_day(p_plan_date) ) )\n'
    || E'    ),\n'
    || E'    primary_picks AS (');

  -- 2) emergency reason tag (VOX rows in the normal-day branch can only be override picks; siblings
  --    already exclude VOX, so a non-sibling VOX row is an off-day emergency).
  v := replace(v,
    E'        CASE WHEN fp.sibling THEN ARRAY_APPEND(fp.reasons_arr, ''sibling'') ELSE fp.reasons_arr END AS final_reasons,',
    E'        CASE WHEN fp.sibling THEN ARRAY_APPEND(fp.reasons_arr, ''sibling'') WHEN fp.venue_group = ''VOX'' THEN ARRAY_APPEND(fp.reasons_arr, ''vox_emergency_offday'') ELSE fp.reasons_arr END AS final_reasons,');

  IF position('days_until_next_vox_day(p_plan_date)' in v) = 0 THEN
    RAISE EXCEPTION 'PRD-043 P1: venue gate not injected (ranked_primary anchor drifted).';
  END IF;
  IF position('vox_emergency_offday' in v) = 0 THEN
    RAISE EXCEPTION 'PRD-043 P1: emergency tag not injected (ordered CTE anchor drifted).';
  END IF;

  EXECUTE v;
END $do$;
