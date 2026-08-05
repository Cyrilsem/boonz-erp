DO $fx9$
DECLARE
  c_mach     uuid := '98868de9-a977-40f4-b0ea-ce787877f24a';
  c_mname    text := 'WH3_1035_0000_W0';
  c_s1 uuid := '54051154-e5f6-4f9b-9bbe-add09d88875d'; -- A01 repack leg
  c_s2 uuid := '483e5bb4-3b12-463c-a6d0-2232818446fe'; -- A02 repack leg
  c_s3 uuid := 'f2c4c372-a1e0-4d54-b7a2-d2b2d4406526'; -- A03 unskip
  c_s4 uuid := 'ed8bf941-2ef4-418d-9b38-8bf9b0803b61'; -- A04 cancelled refusal
  c_s5 uuid := 'e475943b-3e98-4355-8ce2-8736d5c68697'; -- A05 LOG happy
  c_s6 uuid := '1193ffb5-d6c1-4f62-a472-b6036d835c5a'; -- A06 LOG shortfall
  c_pA uuid := '00103662-15c4-47c8-9a32-26d421fa9827';
  c_pB uuid := '8442c7aa-7c41-425e-9b0f-f2d5a3eb87c3';
  c_u_wh    uuid := '7f4ecaa4-1efe-4a32-b233-35f5516f6131';
  c_u_field uuid := '34b19df6-d6c7-4008-9a51-63e5c09fa134';
  c_central uuid := '4bebef68-9e36-4a5c-9c2c-142f8dbdae85';
  c_date date := DATE '2030-07-20';
  v_d1 uuid; v_d2 uuid; v_d3 uuid; v_d4 uuid;
  v_batch uuid; v_rep1 jsonb; v_rep2 jsonb; v_un1 jsonb; v_un2 jsonb;
  v_log1 jsonb; v_log2 jsonb;
  v_wh_before int; v_bvl_before bigint; v_pod_before int;
  v_r_cancel text := 'NOT REFUSED';
  v_out jsonb; v_msg text; c_u_admin uuid := '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d';
  c_date2 date := DATE '2030-07-21';
  c_pp uuid := '9eb1e4f1-a47d-4bda-9090-bf0e13d1d8b9'; v_e1 uuid; v_rep3 jsonb; v_push jsonb; v_rpo_mid boolean; v_rd_mid int;
BEGIN
  SELECT count(*) INTO v_wh_before FROM public.warehouse_inventory;
  SELECT count(*) INTO v_bvl_before FROM public.bypass_violation_log;
  SELECT count(*) INTO v_pod_before FROM public.pod_inventory;

  BEGIN
    PERFORM set_config('app.via_trigger','true',true);

    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
       from_warehouse_id, comment, source_kind, source_warehouse_id)
    VALUES (c_mach, c_s1, c_pA, c_date, 'Refill', 2, c_central, 'FX09 repack A01','wh',c_central)
    RETURNING dispatch_id INTO v_d1;
    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
       from_warehouse_id, comment, source_kind, source_warehouse_id)
    VALUES (c_mach, c_s2, c_pA, c_date, 'Refill', 3, c_central, 'FX09 repack A02','wh',c_central)
    RETURNING dispatch_id INTO v_d2;
    -- the skipped line: "Packing is not saving" - the incident's real reason string
    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
       from_warehouse_id, comment, source_kind, source_warehouse_id, skipped, skip_reason)
    VALUES (c_mach, c_s3, c_pA, c_date, 'Refill', 1, c_central, 'FX09 unskip A03','wh',c_central,
            true, 'other: Packing is not saving')
    RETURNING dispatch_id INTO v_d3;
    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
       from_warehouse_id, comment, source_kind, source_warehouse_id, cancelled, cancelled_at, skip_reason)
    VALUES (c_mach, c_s4, c_pA, c_date, 'Refill', 1, c_central, 'FX09 cancelled A04','wh',c_central,
            true, now(), 'FX09 cancelled by operator')
    RETURNING dispatch_id INTO v_d4;

    -- packed AFTER insert: trg_conserve_split_qty is BEFORE INSERT on packed=true
    UPDATE public.refill_dispatching SET packed = true, pack_outcome = 'packed'::public.pack_outcome_enum WHERE dispatch_id IN (v_d1, v_d2);

    -- the approved plan row the repack will reset (faithful to the incident)
    INSERT INTO public.refill_plan_output
      (plan_date, machine_name, machine_id, shelf_id, shelf_code, boonz_product_id,
       pod_product_id, pod_product_name, boonz_product_name, action, quantity, operator_status, dispatched)
    VALUES (c_date, c_mname, c_mach, c_s1, 'A01', c_pA, c_pp,
       'NRJ Nut', (SELECT boonz_product_name FROM public.boonz_products WHERE product_id=c_pA),
       'Refill', 2, 'approved', true);

    -- WH batch for the LOG path: 2031 expiry (S-190) + provenance (S-189)
    PERFORM set_config('app.provenance_reason','snapshot',true);
    INSERT INTO public.warehouse_inventory
      (boonz_product_id, warehouse_stock, expiration_date, status, batch_id,
       snapshot_date, warehouse_id, provenance_reason, wh_location)
    VALUES (c_pA, 5, DATE '2031-06-30','Active','FX09-BATCH', CURRENT_DATE, c_central,'snapshot','FX09')
    RETURNING wh_inventory_id INTO v_batch;

    PERFORM set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', c_u_wh), true);

    ---- LEG A0: the SUPPORTED path - operator_admin, separate date ----------
    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
       from_warehouse_id, comment, source_kind, source_warehouse_id)
    VALUES (c_mach, c_s5, c_pA, c_date2, 'Refill', 2, c_central, 'FX09 admin repack','wh',c_central)
    RETURNING dispatch_id INTO v_e1;
    UPDATE public.refill_dispatching SET packed=true, pack_outcome='packed'::public.pack_outcome_enum
     WHERE dispatch_id=v_e1;
    INSERT INTO public.refill_plan_output
      (plan_date, machine_name, machine_id, shelf_id, shelf_code, boonz_product_id,
       pod_product_id, pod_product_name, boonz_product_name, action, quantity, operator_status, dispatched)
    VALUES (c_date2, c_mname, c_mach, c_s5, 'A05', c_pA, c_pp, 'NRJ Nut',
       (SELECT boonz_product_name FROM public.boonz_products WHERE product_id=c_pA),
       'Refill', 2, 'approved', true);
    PERFORM set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', c_u_admin), true);
    v_rep3 := public.repack_machine(c_mname, c_date2, 'FX09 admin repack completes');
    SELECT dispatched INTO v_rpo_mid FROM public.refill_plan_output WHERE plan_date=c_date2;
    SELECT count(*) INTO v_rd_mid FROM public.refill_dispatching WHERE dispatch_date=c_date2;
    v_push := public.push_plan_to_dispatch(c_date2, c_mname);
    PERFORM set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', c_u_wh), true);

    ---------------------------------------------------------- LEG A: repack --
    v_rep1 := public.repack_machine(c_mname, c_date, 'FX09 packing is not saving');
    ------------------------------------------- LEG A2: THE FREEZE (2nd call) --
    v_rep2 := public.repack_machine(c_mname, c_date, 'FX09 second attempt');
    ------------------------------------------------------------ LEG B: undo --
    v_un1 := public.unskip_dispatch_line(v_d3, c_u_wh);
    v_un2 := public.unskip_dispatch_line(v_d3, c_u_wh);
    BEGIN
      PERFORM public.unskip_dispatch_line(v_d4, c_u_wh);
    EXCEPTION WHEN OTHERS THEN v_r_cancel := SQLERRM;
    END;
    -------------------------------------------------------- LEG C: LOG path --
    v_log1 := public.log_manual_refill(c_mname, c_central, c_date,
      jsonb_build_array(jsonb_build_object('boonz_product_id', c_pA, 'qty', 3,
        'shelf_code','A05','expiration_date','2031-06-30')),
      'FX09 manual refill after frozen dispatch');
    -- the non-blocking property: more than WH has
    v_log2 := public.log_manual_refill(c_mname, c_central, c_date,
      jsonb_build_array(jsonb_build_object('boonz_product_id', c_pB, 'qty', 10,
        'shelf_code','A06','expiration_date','2031-06-30')),
      'FX09 shortfall - WH cannot cover');

    SELECT jsonb_build_object(
      'rep3', v_rep3, 'push_direct', v_push, 'rpo_mid', v_rpo_mid, 'rd_mid', v_rd_mid,
      'rd_date2', (SELECT count(*) FROM public.refill_dispatching WHERE dispatch_date=c_date2),
      'rd_date2_fresh', (SELECT count(*) FROM public.refill_dispatching
                         WHERE dispatch_date=c_date2 AND returned=false),
      'rpo_date2', (SELECT jsonb_agg(jsonb_build_object('disp',dispatched))
                    FROM public.refill_plan_output WHERE plan_date=c_date2),
      'rep1', v_rep1, 'rep2', v_rep2, 'un1', v_un1, 'un2', v_un2,
      'cancel_err', v_r_cancel, 'log1', v_log1, 'log2', v_log2,
      'd1', (SELECT jsonb_build_object('ret',returned,'rr',return_reason,'fq',filled_quantity,
                'po',pack_outcome::text,'disp',dispatched,'packed',packed)
             FROM public.refill_dispatching WHERE dispatch_id=v_d1),
      'd3', (SELECT jsonb_build_object('ret',returned,'skipped',skipped,'incl',include,'sr',skip_reason)
             FROM public.refill_dispatching WHERE dispatch_id=v_d3),
      'batch_after', (SELECT warehouse_stock FROM public.warehouse_inventory WHERE wh_inventory_id=v_batch),
      'wh_delta', (SELECT count(*) FROM public.warehouse_inventory) - v_wh_before,
      'pod_delta', (SELECT count(*) FROM public.pod_inventory) - v_pod_before,
      'pial', (SELECT count(*) FROM public.pod_inventory_audit_log
               WHERE reference_id = 'manual-refill-'||c_mname||'-'||c_date::text),
      'rpo_after', (SELECT jsonb_agg(jsonb_build_object('disp',dispatched))
                    FROM public.refill_plan_output WHERE plan_date=c_date),
      'rd_now', (SELECT count(*) FROM public.refill_dispatching WHERE dispatch_date=c_date),
      'bvl_delta', (SELECT count(*) FROM public.bypass_violation_log) - v_bvl_before
    ) INTO v_out;

    RAISE EXCEPTION 'FX09_DRY:%', v_out::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FX09_DRY:%' THEN
      v_msg := SQLERRM;
    ELSE RAISE;
    END IF;
  END;
  PERFORM set_config('app.via_trigger','',true);
  PERFORM set_config('request.jwt.claims','',true);
  RAISE EXCEPTION '%', v_msg;
END
$fx9$;
