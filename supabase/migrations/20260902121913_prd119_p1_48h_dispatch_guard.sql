-- PRD-119 P1: 48h dispatch guard. "bind/recommendation never offers a batch with
-- <=2 days to expiry; Gate-2 refuses it; NO override parameter." Stricter than PRD-118
-- item K's 7-day Gate-2 check, which allows a written EXPIRY OVERRIDE comment to bypass
-- it — this floor is absolute and sits underneath K's check with no bypass at all.
--
-- approve_refill_plan gains a THIRD Gate-2 block (after the existing unbound-row and
-- 7-day checks), refusing any Refill/Add New line resolved to a batch <=48h from
-- expiry, unconditionally.
--
-- pick_wh_batch_for_machine, repin_dispatch_batch, get_shelf_fefo_options — the
-- FEFO-pick and rebind recommendation functions — are tightened so none of them ever
-- surfaces a batch <=48h from expiry as a candidate in the first place.
--
-- bind_dispatch_fefo and pack_dispatch_line are deliberately NOT touched here — same
-- reason as PRD-118 G2b: they are the live packing writers for the 2026-09-02 run,
-- gate query still returning open rows at write time. engine_add_pod's wh_avail sizing
-- and find_substitutes_for_shelf_v3 (product-level substitution, not batch FEFO) are
-- also out of scope for this specific guard.
--
-- Cody: approve, Articles 1/4/12 — tightens existing writers' completion conditions
-- and recommendation predicates, no new write path, no role-check touched. Verified
-- via rolled-back test transaction before this real apply.
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='approve_refill_plan' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '963731c55e4ef2e9e86aa0a51bf73a1d' THEN RAISE EXCEPTION 'approve_refill_plan drifted (md5 %)', md5(v_def); END IF;

  v_new := replace(v_def,
    E'v_shortdated_n    int := 0;\n  v_shortdated_summary text;',
    E'v_shortdated_n    int := 0;\n  v_shortdated_summary text;\n  v_expired48_n     int := 0;\n  v_expired48_summary text;');
  IF v_new = v_def THEN RAISE EXCEPTION 'declare not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
$patch$  IF v_shortdated_n > 0 THEN
    RAISE EXCEPTION 'Gate-2 (item K): % Refill/Add New line(s) resolved to a NULL or short-dated batch (expiry <= plan_date+7d) with no EXPIRY OVERRIDE comment — %', v_shortdated_n, v_shortdated_summary;
  END IF;

  RETURN jsonb_build_object($patch$,
$patch$  IF v_shortdated_n > 0 THEN
    RAISE EXCEPTION 'Gate-2 (item K): % Refill/Add New line(s) resolved to a NULL or short-dated batch (expiry <= plan_date+7d) with no EXPIRY OVERRIDE comment — %', v_shortdated_n, v_shortdated_summary;
  END IF;

  -- PRD-119 P1 48h dispatch guard (CS doctrine 02 Sep, absolute — NO override marker
  -- honoured here, unlike the K1 check above). A batch <=48h from expiry at the
  -- warehouse door must never leave it, full stop.
  SELECT count(*),
         string_agg(format('%s/%s %s exp=%s (dispatch %s)',
           m4.official_name, COALESCE(sc4.shelf_code,'?'), COALESCE(bp4.boonz_product_name,'?'),
           COALESCE(rd4.expiry_date::text,'NULL'), rd4.dispatch_id), '; ')
    INTO v_expired48_n, v_expired48_summary
  FROM refill_dispatching rd4
  JOIN machines m4 ON m4.machine_id = rd4.machine_id
  LEFT JOIN shelf_configurations sc4 ON sc4.shelf_id = rd4.shelf_id
  LEFT JOIN boonz_products bp4 ON bp4.product_id = rd4.boonz_product_id
  WHERE rd4.dispatch_date = p_plan_date
    AND m4.official_name = ANY(p_machine_names)
    AND rd4.action IN ('Refill','Add New')
    AND rd4.expiry_date IS NOT NULL
    AND rd4.expiry_date <= (p_plan_date + 2)
    AND COALESCE(rd4.cancelled,false) = false
    AND COALESCE(rd4.skipped,false) = false;

  IF v_expired48_n > 0 THEN
    RAISE EXCEPTION 'Gate-2 (PRD-119 48h floor): % Refill/Add New line(s) resolved to a batch <=48h from expiry — no override possible — %', v_expired48_n, v_expired48_summary;
  END IF;

  RETURN jsonb_build_object($patch$);
  IF v_new = v_def THEN RAISE EXCEPTION 'insertion point not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='pick_wh_batch_for_machine' AND p.pronamespace='public'::regnamespace;
  v_new := replace(v_def,
    E'AND NOT COALESCE(quarantined, false)\n    AND NOT COALESCE(manually_quarantined, false)\n    AND (expiration_date IS NULL\n         OR expiration_date >= (now() AT TIME ZONE \'Asia/Dubai\')::date)',
    E'AND NOT COALESCE(quarantined, false)\n    AND NOT COALESCE(manually_quarantined, false)\n    AND (expiration_date IS NULL\n         OR expiration_date > (now() AT TIME ZONE \'Asia/Dubai\')::date + 2)');
  IF v_new = v_def THEN RAISE EXCEPTION 'pick_wh_batch_for_machine: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='repin_dispatch_batch' AND p.pronamespace='public'::regnamespace;
  v_new := replace(v_def,
    E'IF v_target.status <> \'Active\' OR COALESCE(v_target.quarantined,false) OR COALESCE(v_target.manually_quarantined,false) THEN\n    RAISE EXCEPTION \'repin_dispatch_batch: batch % is not Active/unquarantined stock\', p_wh_inventory_id;\n  END IF;',
    E'IF v_target.status <> \'Active\' OR COALESCE(v_target.quarantined,false) OR COALESCE(v_target.manually_quarantined,false) THEN\n    RAISE EXCEPTION \'repin_dispatch_batch: batch % is not Active/unquarantined stock\', p_wh_inventory_id;\n  END IF;\n  IF v_target.expiration_date IS NOT NULL AND v_target.expiration_date <= (now() AT TIME ZONE \'Asia/Dubai\')::date + 2 THEN\n    RAISE EXCEPTION \'repin_dispatch_batch: batch % is <=48h from expiry (PRD-119 floor, no override)\', p_wh_inventory_id;\n  END IF;');
  IF v_new = v_def THEN RAISE EXCEPTION 'repin_dispatch_batch: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='get_shelf_fefo_options' AND p.pronamespace='public'::regnamespace;
  v_new := replace(v_def,
    E'AND wi.status = \'Active\'\n      AND wi.quarantined = false\n      AND NOT COALESCE(wi.manually_quarantined, false)\n      AND COALESCE(wi.warehouse_stock,0) > 0\n      AND (wi.expiration_date IS NULL OR wi.expiration_date >= CURRENT_DATE)',
    E'AND wi.status = \'Active\'\n      AND wi.quarantined = false\n      AND NOT COALESCE(wi.manually_quarantined, false)\n      AND COALESCE(wi.warehouse_stock,0) > 0\n      AND (wi.expiration_date IS NULL OR wi.expiration_date > CURRENT_DATE + 2)');
  IF v_new = v_def THEN RAISE EXCEPTION 'get_shelf_fefo_options: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;
