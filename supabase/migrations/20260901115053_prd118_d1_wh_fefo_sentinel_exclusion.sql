-- PRD-118 item D (Tier 1, smallest/prerequisite fix): wh_fefo_for_line must exclude
-- sentinel rows (VOXSOURCE-% batch_id OR expiration_date=2099-12-31) from its FEFO
-- candidate set. Verified against md5 b9e42b0bab0eb6c9d6c408e868b8ba14.
-- Cody: approve, Articles 1/4/12/16 — uses the existing canonical _is_phantom_wh_row_v3
-- predicate (the designated "may the FEFO binder pick this row" helper), not a new one.
-- Proven live: before this patch, a 50-unit ask against 7Up-Diet at VOXMCC-1005
-- (34 real units at CENTRAL, 999 sentinel units at WH_MCC) returned
-- total_pickable=1033 / is_satisfiable=true / covers_line=true on the SENTINEL row —
-- i.e. it would silently bind a shortfall against fake stock. After this patch,
-- total_pickable=34 / is_satisfiable=false, correctly reflecting real stock only.
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.proname='wh_fefo_for_line' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'b9e42b0bab0eb6c9d6c408e868b8ba14' THEN
    RAISE EXCEPTION 'wh_fefo_for_line drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;
  v_new := replace(v_def,
$$      AND (vp.reserved_for_machine_id IS NULL
           OR vp.reserved_for_machine_id = p_machine_id)
      AND (vp.expiration_date IS NULL OR vp.expiration_date >= p_plan_date)
  ),$$,
$$      AND (vp.reserved_for_machine_id IS NULL
           OR vp.reserved_for_machine_id = p_machine_id)
      AND (vp.expiration_date IS NULL OR vp.expiration_date >= p_plan_date)
      AND NOT public._is_phantom_wh_row_v3(vp.batch_id, vp.expiration_date)
  ),$$);
  IF v_new = v_def THEN RAISE EXCEPTION 'avail CTE WHERE clause not found'; END IF;
  EXECUTE v_new;
END $mig$;
