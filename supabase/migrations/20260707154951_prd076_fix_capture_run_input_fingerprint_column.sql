-- PRD-076 referee fix: capture_run input_fingerprint referenced sl.slot_id (nonexistent;
-- slot_lifecycle PK is slot_lifecycle_id). Surfaced when the rollback-on-prod capture path
-- was first exercised (PRD-083 validation). Corrected column; body otherwise unchanged.
CREATE OR REPLACE FUNCTION refill_qa.capture_run(p_plan_date date, p_label text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'refill_qa','public','pg_temp'
AS $$
DECLARE v_run_id uuid; v_engine_fp text; v_input_fp text;
BEGIN
  IF COALESCE(current_setting('refill_qa.on_branch', true), 'false') <> 'true' THEN
    RAISE EXCEPTION 'refill_qa.capture_run: refused - not on a preview branch (set refill_qa.on_branch=true only on a branch/rollback-txn).';
  END IF;
  v_engine_fp := md5(string_agg(md5(pg_get_functiondef(p.oid)), ',' ORDER BY p.proname))
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN ('build_draft_for_confirmed','engine_add_pod','engine_swap_pod','engine_finalize_pod','compute_refill_decision','pick_machines_for_refill');
  v_input_fp := md5(concat_ws('|',
    (SELECT md5(COALESCE(string_agg(sl.slot_lifecycle_id::text, ',' ORDER BY sl.slot_lifecycle_id), '')) FROM slot_lifecycle sl WHERE sl.is_current AND NOT sl.archived),
    (SELECT md5(COALESCE(string_agg(v.machine_id::text||v.slot_name||v.current_stock::text, ',' ORDER BY v.machine_id, v.slot_name), '')) FROM v_live_shelf_stock v),
    (SELECT md5(COALESCE(string_agg(w.wh_inventory_id::text||w.warehouse_stock::text, ',' ORDER BY w.wh_inventory_id), '')) FROM warehouse_inventory w),
    (SELECT md5(COALESCE(string_agg(mtv.machine_id::text||mtv.status, ',' ORDER BY mtv.machine_id), '')) FROM machines_to_visit mtv WHERE mtv.plan_date = p_plan_date)));
  PERFORM public.build_draft_for_confirmed(p_plan_date, true);
  INSERT INTO refill_qa.plan_run (plan_date, label, engine_fingerprint, input_fingerprint, meta)
  VALUES (p_plan_date, p_label, v_engine_fp, v_input_fp, jsonb_build_object('captured_by','capture_run','db',current_database())) RETURNING run_id INTO v_run_id;
  INSERT INTO refill_qa.plan_run_row (run_id, machine_id, shelf_id, pod_product_id, action, qty, status, source, linked_intent_id, reasoning)
  SELECT v_run_id, prp.machine_id, prp.shelf_id, prp.pod_product_id, prp.action, prp.qty, prp.status, prp.source_origin::text, prp.linked_intent_id, prp.reasoning
  FROM public.pod_refill_plan prp WHERE prp.plan_date = p_plan_date;
  RETURN v_run_id;
END; $$;
