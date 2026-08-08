-- PRD-110 DR-1 (leg 160) — fixture 74's planted series hit a second constraint.
--
-- ⛔ engine_forecast_error_v3_basis_chk restricts velocity_basis to {velocity_30d, velocity_instock}.
--    The fixture used 'fixture74' as a convenient MARKER for its own planted rows — which the CHECK
--    correctly refused. ⭐ The marker and the residue proof must move TOGETHER: seq 62 identified
--    the planted rows by that same velocity_basis, so changing only the INSERT would have left the
--    residue assertion looking for rows that can never exist, i.e. passing vacuously forever.
--
-- ⭐ The new marker is the plan_date itself. 2026-07-01 holds ZERO rows live (probed), it sits
--    inside the gate's real window (< 2027-01-01) so the planted evidence actually counts, and it
--    cannot collide with the 2030 synthetic dates or with any real measured date.
--
-- Article 12: forward-only. Two exact-once replacements, each guarded.

DO $mig$
DECLARE
  v_sql text;
  v_n   int;
  v_from1 text; v_to1 text;
  v_from2 text; v_to2 text;
BEGIN
  SELECT scenario_sql INTO v_sql FROM golden.fixtures WHERE fixture_id = 74;
  IF v_sql IS NULL THEN RAISE EXCEPTION 'fixture 74 not found'; END IF;

  -- (1) the two planted rows: legal velocity_basis
  v_from1 :=
'      (DATE ''2026-07-01'',''v3'',  v_novo, v_pod, 7, DATE ''2026-07-08'', 1, 1, 110, 100, true, ''fixture74'', now()),' || E'\n' ||
'      (DATE ''2026-07-01'',''v19'', v_novo, v_pod, 7, DATE ''2026-07-08'', 1, 1, 140, 100, true, ''fixture74'', now());';
  v_to1 :=
'      (DATE ''2026-07-01'',''v3'',  v_novo, v_pod, 7, DATE ''2026-07-08'', 1, 1, 110, 100, true, ''velocity_instock'', now()),' || E'\n' ||
'      (DATE ''2026-07-01'',''v19'', v_novo, v_pod, 7, DATE ''2026-07-08'', 1, 1, 140, 100, true, ''velocity_instock'', now());';

  v_n := (length(v_sql) - length(replace(v_sql, v_from1, ''))) / length(v_from1);
  IF v_n <> 1 THEN RAISE EXCEPTION 'fixture 74 basis patch: INSERT anchor found % times, expected 1', v_n; END IF;
  v_sql := replace(v_sql, v_from1, v_to1);

  -- (2) the residue proof: identify planted rows by plan_date, not by the retired marker
  v_from2 := '(SELECT count(*) FROM public.engine_forecast_error_v3 WHERE velocity_basis=''fixture74'')';
  v_to2   := '(SELECT count(*) FROM public.engine_forecast_error_v3 WHERE plan_date = DATE ''2026-07-01'')';

  v_n := (length(v_sql) - length(replace(v_sql, v_from2, ''))) / length(v_from2);
  IF v_n <> 1 THEN RAISE EXCEPTION 'fixture 74 basis patch: residue anchor found % times, expected 1', v_n; END IF;
  v_sql := replace(v_sql, v_from2, v_to2);

  -- post-image: the retired marker must be gone from BOTH sites, not just the INSERT
  IF position('fixture74' in v_sql) > 0 THEN
    RAISE EXCEPTION 'fixture 74 basis patch: the retired marker still appears in the scenario';
  END IF;

  UPDATE golden.fixtures SET scenario_sql = v_sql WHERE fixture_id = 74;
END
$mig$;

-- ⛔ NON-VACUITY GUARD FOR THE NEW MARKER: if 2026-07-01 ever acquires real rows, seq 62's residue
--    proof silently stops meaning anything. Prove it is empty at apply time.
DO $post$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM public.engine_forecast_error_v3 WHERE plan_date = DATE '2026-07-01';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'fixture 74: plan_date 2026-07-01 already holds % row(s); pick another marker date', v_n;
  END IF;
  RAISE NOTICE 'fixture 74 marker date 2026-07-01 is empty as required';
END
$post$;
