-- PRD-119 P3: apply_expiry_check's day_close_events payload was missing
-- product_name/severity/qty (for not_there and date_read) — the DayCloseTab
-- read-only log display needs these to be self-describing rather than joining
-- live against pod_inventory (which may already be archived/renamed by the
-- time the log is viewed). Additive only, no write-path change.
--
-- Verified live: not_there fixture payload correctly carries qty:6,
-- severity:'expiring', product_name:'Pepsi - Regular'.
--
-- Cody: approve, Articles 8/12 — md5-guarded, purely additive to the log
-- payload, no write-path change.
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='apply_expiry_check' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'b247b84cef2cf353d91f2490cf6d0f02' THEN RAISE EXCEPTION 'apply_expiry_check drifted (md5 %)', md5(v_def); END IF;

  v_new := replace(v_def,
    E'  v_role text; v_pod pod_inventory%ROWTYPE; v_is_dated boolean; v_event_id uuid;\n',
    E'  v_role text; v_pod pod_inventory%ROWTYPE; v_is_dated boolean; v_event_id uuid;\n  v_product_name text; v_severity text;\n');
  IF v_new = v_def THEN RAISE EXCEPTION 'apply_expiry_check: declare pattern not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
    E'  v_is_dated := v_pod.expiration_date IS NOT NULL;\n  IF p_outcome = \'removed\' AND NOT v_is_dated THEN',
    E'  v_is_dated := v_pod.expiration_date IS NOT NULL;\n  SELECT boonz_product_name INTO v_product_name FROM public.boonz_products WHERE product_id = v_pod.boonz_product_id;\n  v_severity := CASE WHEN NOT v_is_dated THEN \'date_unverified\' WHEN v_pod.expiration_date < (now() AT TIME ZONE \'Asia/Dubai\')::date THEN \'expired\' ELSE \'expiring\' END;\n  IF p_outcome = \'removed\' AND NOT v_is_dated THEN');
  IF v_new = v_def THEN RAISE EXCEPTION 'apply_expiry_check: severity-compute pattern not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
    E'jsonb_build_object(\'pod_inventory_id\', p_pod_inventory_id, \'outcome\', \'removed\', \'qty\', p_qty,\n        \'expiration_date\', v_pod.expiration_date, \'disposition_event_id\', v_event_id), v_user_id, now(), v_user_id);',
    E'jsonb_build_object(\'pod_inventory_id\', p_pod_inventory_id, \'outcome\', \'removed\', \'qty\', p_qty,\n        \'expiration_date\', v_pod.expiration_date, \'disposition_event_id\', v_event_id,\n        \'product_name\', v_product_name, \'severity\', v_severity), v_user_id, now(), v_user_id);');
  IF v_new = v_def THEN RAISE EXCEPTION 'apply_expiry_check: removed-payload pattern not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
    E'jsonb_build_object(\'pod_inventory_id\', p_pod_inventory_id, \'outcome\', \'not_there\',\n        \'expiration_date\', v_pod.expiration_date), v_user_id, now(), v_user_id);',
    E'jsonb_build_object(\'pod_inventory_id\', p_pod_inventory_id, \'outcome\', \'not_there\',\n        \'expiration_date\', v_pod.expiration_date, \'qty\', v_pod.current_stock,\n        \'product_name\', v_product_name, \'severity\', v_severity), v_user_id, now(), v_user_id);');
  IF v_new = v_def THEN RAISE EXCEPTION 'apply_expiry_check: not_there-payload pattern not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
    E'jsonb_build_object(\'pod_inventory_id\', p_pod_inventory_id, \'outcome\', \'date_read\', \'new_expiry\', p_new_expiry), v_user_id, now(), v_user_id);',
    E'jsonb_build_object(\'pod_inventory_id\', p_pod_inventory_id, \'outcome\', \'date_read\', \'new_expiry\', p_new_expiry,\n        \'qty\', v_pod.current_stock, \'product_name\', v_product_name, \'severity\', v_severity), v_user_id, now(), v_user_id);');
  IF v_new = v_def THEN RAISE EXCEPTION 'apply_expiry_check: date_read-payload pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;
