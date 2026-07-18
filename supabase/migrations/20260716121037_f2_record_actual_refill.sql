-- backported from prod schema_migrations on 2026-07-18, RC-15 parity
-- version: 20260716121037  name: f2_record_actual_refill
CREATE OR REPLACE FUNCTION public.record_actual_refill(
  p_machine_name text,
  p_plan_date    date,
  p_lines        jsonb,
  p_source       text    DEFAULT 'cs',
  p_actor        uuid    DEFAULT NULL,
  p_reason       text    DEFAULT NULL,
  p_dry_run      boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_machine_id uuid;
  v_event_id   uuid;
  v_line       jsonb;
  v_action     text;
  v_bpid       uuid;
  v_shelf_code text;
  v_shelf_id   uuid;
  v_qty        numeric;
  v_setmode    text;
  v_exp        date;
  v_wh         uuid;
  v_partner    text;
  v_partner_id uuid;
  v_notes      text;
  v_cur        numeric;
  v_newqty     numeric;
  v_whcur      numeric;
  v_whcs       numeric;
  v_whnew      numeric;
  v_pod_res    jsonb;
  v_pod_id     uuid;
  v_rpo_action text;
  v_applied    int := 0;
  v_lineno     int := 0;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','record_actual_refill',true);

  -- resolve + validate machine
  SELECT machine_id INTO v_machine_id FROM machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN RAISE EXCEPTION 'record_actual_refill: machine % not found', p_machine_name; END IF;
  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN RAISE EXCEPTION 'p_lines empty'; END IF;

  -- role: if a caller identity is present, it must be a manager role (skips when auth.uid() is NULL, e.g. MCP)
  IF p_actor IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM user_profiles WHERE id = p_actor
                   AND role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])) THEN
      RAISE EXCEPTION 'record_actual_refill: actor % is not an inventory manager', p_actor;
    END IF;
    -- impersonate so nested gated RPCs (adjust_warehouse_stock) authorize
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', p_actor::text, 'role','authenticated')::text, true);
  END IF;

  -- header (persists even if apply fails, so a failure is recorded)
  INSERT INTO refill_events (machine_id, plan_date, source, captured_by, status, reason)
  VALUES (v_machine_id, p_plan_date, p_source, p_actor,
          CASE WHEN p_dry_run THEN 'dry_run' ELSE 'pending' END, p_reason)
  RETURNING event_id INTO v_event_id;

  BEGIN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
      v_lineno   := v_lineno + 1;
      v_action   := v_line->>'action';
      v_bpid     := (v_line->>'boonz_product_id')::uuid;
      v_shelf_code := v_line->>'shelf_code';
      v_qty      := (v_line->>'qty')::numeric;
      v_setmode  := COALESCE(v_line->>'set_mode','delta');
      v_exp      := NULLIF(v_line->>'expiration_date','')::date;
      v_wh       := NULLIF(v_line->>'warehouse_id','')::uuid;
      v_partner  := v_line->>'partner_machine';
      v_notes    := v_line->>'notes';
      v_shelf_id := NULL; v_pod_id := NULL; v_partner_id := NULL;

      IF v_action IS NULL OR v_action NOT IN
         ('refill','remove','write_off','transfer_out','transfer_in','wh_return','wh_receive') THEN
        RAISE EXCEPTION 'line %: bad action %', v_lineno, v_action; END IF;
      IF v_bpid IS NULL THEN RAISE EXCEPTION 'line %: boonz_product_id required', v_lineno; END IF;
      IF NOT EXISTS (SELECT 1 FROM boonz_products WHERE product_id = v_bpid) THEN
        RAISE EXCEPTION 'line %: product % not found', v_lineno, v_bpid; END IF;
      IF v_partner IS NOT NULL THEN
        SELECT machine_id INTO v_partner_id FROM machines WHERE official_name = v_partner; END IF;

      -- resolve shelf for pod-affecting actions
      IF v_action IN ('refill','remove','write_off','transfer_out','transfer_in') THEN
        IF v_shelf_code IS NULL THEN RAISE EXCEPTION 'line %: shelf_code required for %', v_lineno, v_action; END IF;
        SELECT shelf_id INTO v_shelf_id FROM shelf_configurations
          WHERE machine_id = v_machine_id AND shelf_code = v_shelf_code;
        IF v_shelf_id IS NULL THEN RAISE EXCEPTION 'line %: shelf % not on machine', v_lineno, v_shelf_code; END IF;
      END IF;

      IF NOT p_dry_run THEN
        -- POD effect
        IF v_action IN ('refill','remove','write_off','transfer_out','transfer_in') THEN
          IF v_setmode = 'set' THEN
            v_newqty := v_qty;
          ELSE
            SELECT current_stock INTO v_cur FROM pod_inventory
              WHERE machine_id = v_machine_id AND shelf_id = v_shelf_id AND boonz_product_id = v_bpid
                AND status='Active' AND (expiration_date = v_exp OR (expiration_date IS NULL AND v_exp IS NULL))
              LIMIT 1;
            IF v_action IN ('remove','write_off','transfer_out') THEN
              v_newqty := GREATEST(COALESCE(v_cur,0) - v_qty, 0);
            ELSE
              v_newqty := COALESCE(v_cur,0) + v_qty;
            END IF;
          END IF;
          SELECT public.adjust_pod_inventory(
            p_machine_name, p_plan_date,
            jsonb_build_array(jsonb_build_object(
              'boonz_product_id', v_bpid, 'new_qty', v_newqty,
              'expiration_date', v_exp, 'shelf_code', v_shelf_code,
              'batch_id', 'RECORD-'||to_char(p_plan_date,'YYYY-MM-DD'))),
            COALESCE(p_reason,'record_actual_refill')) INTO v_pod_res;
          v_pod_id := (v_pod_res->'details'->0->>'pod_inventory_id')::uuid;
        END IF;

        -- WAREHOUSE effect
        IF v_wh IS NOT NULL THEN
          SELECT warehouse_stock, consumer_stock INTO v_whcur, v_whcs FROM warehouse_inventory
            WHERE boonz_product_id = v_bpid AND warehouse_id = v_wh AND status='Active'
              AND (expiration_date = v_exp OR (expiration_date IS NULL AND v_exp IS NULL))
            ORDER BY created_at DESC LIMIT 1;
          IF v_action IN ('wh_receive','wh_return') THEN
            v_whnew := COALESCE(v_whcur,0) + v_qty;
          ELSIF v_action = 'refill' THEN
            v_whnew := GREATEST(COALESCE(v_whcur,0) - v_qty, 0);
          ELSE
            v_whnew := NULL;
          END IF;
          IF v_whnew IS NOT NULL THEN
            PERFORM public.adjust_warehouse_stock(
              v_wh,
              jsonb_build_array(jsonb_build_object(
                'boonz_product_id', v_bpid, 'new_warehouse_stock', v_whnew,
                'new_consumer_stock', COALESCE(v_whcs,0), 'expiration_date', v_exp)),
              p_plan_date, COALESCE(p_reason,'record_actual_refill'));
          END IF;
        END IF;

        -- LOG effect (refill_plan_output) for machine-facing actions only
        v_rpo_action := CASE
          WHEN v_action IN ('refill','transfer_in') THEN 'Refill'
          WHEN v_action IN ('remove','write_off','transfer_out') THEN 'Remove'
          ELSE NULL END;
        IF v_rpo_action IS NOT NULL THEN
          INSERT INTO refill_plan_output
            (plan_date, machine_name, shelf_code, pod_product_name, boonz_product_name,
             action, quantity, operator_status, operator_comment, reviewed_at, dispatched, comment)
          SELECT p_plan_date, p_machine_name, v_shelf_code,
                 bp.boonz_product_name, bp.boonz_product_name, v_rpo_action, v_qty,
                 'approved',
                 COALESCE(p_reason,'record_actual_refill')
                   || CASE WHEN v_partner IS NOT NULL THEN ' ('||v_action||' '||v_partner||')' ELSE '' END,
                 now(), false, 'record_actual_refill'
          FROM boonz_products bp WHERE bp.product_id = v_bpid;
        END IF;
      END IF;

      INSERT INTO refill_event_lines
        (event_id, action, boonz_product_id, shelf_id, qty, set_mode, expiration_date,
         warehouse_id, partner_machine_id, result_pod_inventory_id, applied, notes)
      VALUES
        (v_event_id, v_action, v_bpid, v_shelf_id, v_qty, v_setmode, v_exp,
         v_wh, v_partner_id, v_pod_id, (NOT p_dry_run), v_notes);
      v_applied := v_applied + 1;
    END LOOP;

    IF p_dry_run THEN
      UPDATE refill_events SET status = 'dry_run' WHERE event_id = v_event_id;
    ELSE
      UPDATE refill_events SET status = 'applied', applied_at = now() WHERE event_id = v_event_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- subtransaction rolled back ALL target writes + line inserts; record the failure on the header
    UPDATE refill_events SET status = 'failed', error_text = SQLERRM WHERE event_id = v_event_id;
    RETURN jsonb_build_object('status','failed','event_id',v_event_id,'failed_at_line',v_lineno,'error',SQLERRM);
  END;

  RETURN jsonb_build_object(
    'status', CASE WHEN p_dry_run THEN 'dry_run_ok' ELSE 'applied' END,
    'event_id', v_event_id, 'machine', p_machine_name, 'plan_date', p_plan_date,
    'lines', v_applied);
END;
$function$;
