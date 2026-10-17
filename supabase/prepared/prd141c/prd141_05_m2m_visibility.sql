-- PRD-141 item 5 (A5): M2M is visible to the warehouse, and the destination pod gets the confirmed qty.
-- 1. v_wm_confirmations: new acknowledge-only source 'm2m_transfer' = the source Remove leg of a paired
--    machine-to-machine transfer once the driver confirmed or picked it up, at the confirmed quantity,
--    labelled in the FE "Machine transfer, no stock movement". Only transfers dated from 2026-10-18
--    (go-live) appear, so the historic backlog does not flood the queue. A line clears when the WM
--    acknowledges it (disposition_events row, reason prefixed [m2m_transfer]); no stock moves.
-- 2. wm_confirm_line: the acknowledge-only branch accepts 'm2m_transfer' and writes only the event.
-- 3. approve_m2m_transfer: source and destination legs are received at the driver-confirmed quantity
--    (the partner Remove's driver_confirmed_qty for the destination) instead of the planned quantity;
--    the caller is auth.uid() (p_caller_id honoured only for postgres / service_role sessions).
--    The planned-quantity pair check only applies while the source is unconfirmed: a trigger syncs
--    the Remove quantity to the driver's count, so a partial transfer (7 planned, 6 moved) could
--    never be approved before this.
-- Apply AFTER prd141_02_04 (both touch wm_confirm_line; anchors are disjoint).
-- Rollback: supabase/rollbacks/prd141_05_rollback.sql.

DO $view$
DECLARE
  v_def text := pg_get_viewdef('public.v_wm_confirmations'::regclass, true);
  a_old text := '        ), candidates AS (';
  a_new text := '        ), m2m_candidates AS (' || chr(10)
    || '         SELECT rd.dispatch_id AS line_id,' || chr(10)
    || '            ''m2m_transfer''::text AS source,' || chr(10)
    || '            rd.machine_id,' || chr(10)
    || '            rd.shelf_id,' || chr(10)
    || '            rd.boonz_product_id,' || chr(10)
    || '            rd.pod_product_id,' || chr(10)
    || '            COALESCE(rd.driver_confirmed_qty, rd.filled_quantity, rd.quantity) AS qty,' || chr(10)
    || '            NULLIF(rd.expiry_date, ''2099-12-31''::date) AS expiry_date,' || chr(10)
    || '            rd.from_wh_inventory_id,' || chr(10)
    || '            rd.dispatch_id,' || chr(10)
    || '            rd.dispatch_date,' || chr(10)
    || '            COALESCE(rd.driver_confirmed_at, rd.driver_outcome_at, rd.last_edited_at, rd.created_at) AS left_machine_at,' || chr(10)
    || '            rd.driver_confirmed_breakdown AS driver_breakdown' || chr(10)
    || '           FROM refill_dispatching rd' || chr(10)
    || '          WHERE rd.action = ''Remove''::text AND COALESCE(rd.is_m2m, false) AND rd.m2m_transfer_id IS NOT NULL' || chr(10)
    || '            AND rd.dispatch_date >= ''2026-10-18''::date' || chr(10)
    || '            AND (rd.driver_confirmed_at IS NOT NULL OR rd.picked_up = true)' || chr(10)
    || '            AND COALESCE(rd.driver_confirmed_qty, rd.filled_quantity, rd.quantity, 0::numeric) > 0::numeric' || chr(10)
    || '            AND COALESCE(rd.cancelled, false) = false AND COALESCE(rd.skipped, false) = false AND rd.boonz_product_id IS NOT NULL' || chr(10)
    || '            AND (EXISTS ( SELECT 1 FROM refill_dispatching paired WHERE paired.m2m_transfer_id = rd.m2m_transfer_id AND paired.dispatch_id <> rd.dispatch_id AND (paired.action = ANY (ARRAY[''Refill''::text, ''Add''::text, ''Add New''::text]))))' || chr(10)
    || '            AND NOT (EXISTS ( SELECT 1 FROM disposition_events de WHERE de.dispatch_id = rd.dispatch_id AND de.reason ~~ ''[m2m_transfer]%''::text))' || chr(10)
    || '        ), candidates AS (';
  b_old text := '           FROM tap_candidates' || chr(10) || '        ), proposal AS (';
  b_new text := '           FROM tap_candidates' || chr(10)
    || '        UNION ALL' || chr(10)
    || '         SELECT m2m_candidates.line_id, m2m_candidates.source, m2m_candidates.machine_id, m2m_candidates.shelf_id,' || chr(10)
    || '            m2m_candidates.boonz_product_id, m2m_candidates.pod_product_id, m2m_candidates.qty, m2m_candidates.expiry_date,' || chr(10)
    || '            m2m_candidates.from_wh_inventory_id, m2m_candidates.dispatch_id, m2m_candidates.dispatch_date,' || chr(10)
    || '            m2m_candidates.left_machine_at, m2m_candidates.driver_breakdown' || chr(10)
    || '           FROM m2m_candidates' || chr(10)
    || '        ), proposal AS (';
BEGIN
  IF (length(v_def) - length(replace(v_def, a_old, ''))) / length(a_old) <> 1 THEN RAISE EXCEPTION 'prd141_05: view anchor a'; END IF;
  IF (length(v_def) - length(replace(v_def, b_old, ''))) / length(b_old) <> 1 THEN RAISE EXCEPTION 'prd141_05: view anchor b'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_wm_confirmations AS ' || replace(replace(v_def, a_old, a_new), b_old, b_new);
END
$view$;

DO $patch$
DECLARE
  v_def text; n int; i int;
  pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.wm_confirm_line(uuid,numeric,date,text,uuid,text,text,uuid,boolean,jsonb)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  IF v_line.source IN (''refill_return_ack'', ''quarantine_batch'') THEN',
          '  IF v_line.source IN (''refill_return_ack'', ''quarantine_batch'', ''m2m_transfer'') THEN'],
    ARRAY['    IF v_line.source = ''refill_return_ack'' THEN' || chr(10) || '      PERFORM public.set_write_context(',
          '    IF v_line.source = ''m2m_transfer'' THEN' || chr(10)
          || '      NULL;  -- PRD-141 item 5: acknowledge only, the transfer moves no warehouse stock' || chr(10)
          || '    ELSIF v_line.source = ''refill_return_ack'' THEN' || chr(10) || '      PERFORM public.set_write_context('],
    ARRAY['      CASE WHEN v_line.source = ''refill_return_ack'' THEN p_line_id ELSE NULL END,',
          '      CASE WHEN v_line.source IN (''refill_return_ack'', ''m2m_transfer'') THEN p_line_id ELSE NULL END,']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd141_05: wm_confirm_line anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.approve_m2m_transfer(uuid,uuid)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  v_user_id uuid := COALESCE(p_caller_id, auth.uid());',
          '  v_user_id uuid := COALESCE(auth.uid(), CASE WHEN current_user IN (''postgres'',''service_role'') THEN p_caller_id END);'],
    ARRAY['  FOR r IN SELECT dispatch_id, quantity FROM public.refill_dispatching' || chr(10) || '           WHERE m2m_transfer_id = p_transfer_id AND is_m2m AND action = ''Remove''',
          '  FOR r IN SELECT dispatch_id, COALESCE(driver_confirmed_qty, quantity) AS quantity FROM public.refill_dispatching' || chr(10) || '           WHERE m2m_transfer_id = p_transfer_id AND is_m2m AND action = ''Remove'''],
    ARRAY['  IF v_src_qty <> v_dst_qty THEN',
          '  IF v_src_qty <> v_dst_qty AND NOT EXISTS (SELECT 1 FROM public.refill_dispatching WHERE m2m_transfer_id = p_transfer_id AND is_m2m AND action = ''Remove'' AND driver_confirmed_at IS NOT NULL) THEN'],
    ARRAY['  FOR r IN SELECT dispatch_id, quantity, m2m_partner_id FROM public.refill_dispatching',
          '  FOR r IN SELECT d0.dispatch_id, COALESCE((SELECT s0.driver_confirmed_qty FROM public.refill_dispatching s0 WHERE s0.dispatch_id = d0.m2m_partner_id), d0.quantity) AS quantity, d0.m2m_partner_id FROM public.refill_dispatching d0']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd141_05: approve_m2m_transfer anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

REVOKE EXECUTE ON FUNCTION public.wm_confirm_line(uuid, numeric, date, text, uuid, text, text, uuid, boolean, jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.wm_confirm_line(uuid, numeric, date, text, uuid, text, text, uuid, boolean, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.approve_m2m_transfer(uuid, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.approve_m2m_transfer(uuid, uuid) TO authenticated, service_role;
