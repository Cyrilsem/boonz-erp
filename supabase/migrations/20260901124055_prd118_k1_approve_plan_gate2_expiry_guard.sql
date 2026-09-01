-- PRD-118 item K (Addendum 2 §K), Gate-2 hard guard — CS doctrine 2026-08-31,
-- non-negotiable: approve_refill_plan refuses any Refill/Add New line whose resolved
-- batch expiry is NULL or <= plan_date + 7 days, unless the row's comment carries an
-- explicit "EXPIRY OVERRIDE" marker. Expired or short-dated stock must be physically
-- impossible to plan onto a shelf.
--
-- Second Gate-2 check on this function tonight (the first, prd118_c2, refuses unbound
-- fill rows). Same mechanism: raising here rolls back this function's subtransaction
-- (the UPDATE and whatever push_plan_to_dispatch's trigger cascade just wrote), so a
-- failed gate means nothing was approved. The existing EXCEPTION WHEN OTHERS handler
-- returns a clean structured error naming the offending rows.
--
-- Verified against md5 947a75570c31273b7a1fe8989e4ad6cd (already carries the item-C
-- Gate-2 check applied earlier this session). Compiles clean; behavioral testing
-- deferred to the item-K fixture (plan a line onto a batch expiring in 3 days, assert
-- Gate-2 refuses it) which needs a constructed scenario rather than a lucky historical
-- row — noted in the report rather than claimed here.
-- Cody: approve, Articles 1/4/12 — same pattern as prd118_c2, tightens the same
-- writer's completion condition, no new write path.
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.proname='approve_refill_plan' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '947a75570c31273b7a1fe8989e4ad6cd' THEN
    RAISE EXCEPTION 'approve_refill_plan drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;

  v_new := replace(v_def,
    'v_unbound_n      int := 0;
  v_unbound_summary text;',
    'v_unbound_n      int := 0;
  v_unbound_summary text;
  v_shortdated_n    int := 0;
  v_shortdated_summary text;');
  IF v_new = v_def THEN RAISE EXCEPTION 'declare not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
$patch$  IF v_unbound_n > 0 THEN
    RAISE EXCEPTION 'Gate-2: % fill row(s) reached dispatch unbound (from_wh_inventory_id NULL, qty>0) — %', v_unbound_n, v_unbound_summary;
  END IF;

  RETURN jsonb_build_object($patch$,
$patch$  IF v_unbound_n > 0 THEN
    RAISE EXCEPTION 'Gate-2: % fill row(s) reached dispatch unbound (from_wh_inventory_id NULL, qty>0) — %', v_unbound_n, v_unbound_summary;
  END IF;

  -- PRD-118 item K, Gate-2 (CS doctrine 2026-08-31, non-negotiable): refuse any
  -- Refill/Add New line whose resolved batch expiry is NULL or <= plan_date + 7 days,
  -- unless the row's comment carries an explicit override marker. Expired or
  -- short-dated stock must be physically impossible to plan onto a shelf.
  SELECT count(*),
         string_agg(format('%s/%s %s exp=%s (dispatch %s)',
           m3.official_name, COALESCE(sc3.shelf_code,'?'), COALESCE(bp3.boonz_product_name,'?'),
           COALESCE(rd3.expiry_date::text,'NULL'), rd3.dispatch_id), '; ')
    INTO v_shortdated_n, v_shortdated_summary
  FROM refill_dispatching rd3
  JOIN machines m3 ON m3.machine_id = rd3.machine_id
  LEFT JOIN shelf_configurations sc3 ON sc3.shelf_id = rd3.shelf_id
  LEFT JOIN boonz_products bp3 ON bp3.product_id = rd3.boonz_product_id
  WHERE rd3.dispatch_date = p_plan_date
    AND m3.official_name = ANY(p_machine_names)
    AND rd3.action IN ('Refill','Add New')
    AND (rd3.expiry_date IS NULL OR rd3.expiry_date <= (p_plan_date + 7))
    AND COALESCE(rd3.cancelled,false) = false
    AND COALESCE(rd3.skipped,false) = false
    AND COALESCE(rd3.comment,'') NOT ILIKE '%EXPIRY OVERRIDE%';

  IF v_shortdated_n > 0 THEN
    RAISE EXCEPTION 'Gate-2 (item K): % Refill/Add New line(s) resolved to a NULL or short-dated batch (expiry <= plan_date+7d) with no EXPIRY OVERRIDE comment — %', v_shortdated_n, v_shortdated_summary;
  END IF;

  RETURN jsonb_build_object($patch$);
  IF v_new = v_def THEN RAISE EXCEPTION 'insertion point not found'; END IF;
  EXECUTE v_new;
END $mig$;
