-- PRD-141 items 2 (A2) and 4 (A4): returns land in WH_CENTRAL; a Damaged outcome on return legs.
-- Item 2: every return credit goes to WH_CENTRAL unless the dispatch row carries return_warehouse_id
--   (new column). Writers patched: wm_confirm_line and wm_confirm_line_split (the Warehouse
--   Confirmations screen, which credited machines.primary_warehouse_id, i.e. WH_MOE / WH_MCC / WH_DFC /
--   WH_MM for 13 venue machines) and receive_dispatch_line's Remove branch (wh_approve_remove_receipt
--   path, credited COALESCE(from_warehouse_id, primary_warehouse_id)); wh_approve_remove_receipt_multivariant
--   children inherit the parent's return_warehouse_id. return_dispatch_line is NOT changed: it restores
--   the packed batch row in place (consumer_stock back to warehouse_stock on the same row), which is a
--   conservation invariant, not a return booking.
-- Item 4: outcome 'damaged' on wm_confirm_line / wm_confirm_line_split writes a NEW warehouse_inventory
--   row (never tops up a pickable one) with provenance_reason 'damaged_return' and damage_source
--   'transit'. quarantined (generated) now includes 'damaged_return', so the row is not pickable and
--   shows on Admin > WH Quarantine, where the write-off button calls warehouse_damage_writeoff.
--   disposition_events gets state 'received' (its CHECK has no 'damaged'; the WH row carries the flag).
-- Hard rule on replaced definers: p_caller is honoured only for postgres / service_role sessions;
--   a signed-in user is always auth.uid() (the FE already sends its own id, so no behaviour change).
-- Rollback: supabase/rollbacks/prd141_02_04_rollback.sql.

ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS return_warehouse_id uuid REFERENCES public.warehouses(warehouse_id);
COMMENT ON COLUMN public.refill_dispatching.return_warehouse_id IS
  'PRD-141 item 2: where a return / Remove leg is credited. NULL = WH_CENTRAL.';

ALTER TABLE public.warehouse_inventory DROP CONSTRAINT wh_provenance_reason_enum;
ALTER TABLE public.warehouse_inventory ADD CONSTRAINT wh_provenance_reason_enum CHECK (((provenance_reason IS NULL) OR (provenance_reason = ANY (ARRAY['po_receive'::text, 'dispatch_return'::text, 'dispatch_pack'::text, 'dispatch_receive'::text, 'm2m_return'::text, 'wh_transfer'::text, 'manual_adjust'::text, 'snapshot'::text, 'status_flip'::text, 'unknown_pre_migration'::text, 'dispatch_return_unverified'::text, 'dispatch_partial_remainder'::text, 'expiry_writeoff'::text, 'unattributed_write'::text, 'refill_event'::text, 'damaged_return'::text]))));
ALTER TABLE public.warehouse_inventory ALTER COLUMN quarantined SET EXPRESSION AS
  (((provenance_reason IS NULL) OR (provenance_reason = ANY (ARRAY['unknown_pre_migration'::text, 'dispatch_return_unverified'::text, 'damaged_return'::text]))));

DO $patch$
DECLARE
  v_def text; v_new text; n int;
  c_central text := '''4bebef68-9e36-4a5c-9c2c-142f8dbdae85''::uuid';
  pairs text[][];
  i int;
BEGIN
  -- wm_confirm_line
  v_def := pg_get_functiondef('public.wm_confirm_line(uuid,numeric,date,text,uuid,text,text,uuid,boolean,jsonb)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  v_user_id uuid := COALESCE(auth.uid(), p_caller);',
          '  v_user_id uuid := COALESCE(auth.uid(), CASE WHEN current_user IN (''postgres'',''service_role'') THEN p_caller END);'],
    ARRAY['  IF p_outcome NOT IN (''restocked'',''redeploy_pending'',''waste'',''acknowledged'') THEN' || chr(10) || '    RAISE EXCEPTION ''wm_confirm_line: p_outcome must be restocked | redeploy_pending | waste | acknowledged (got %)'', p_outcome; END IF;',
          '  IF p_outcome NOT IN (''restocked'',''redeploy_pending'',''waste'',''acknowledged'',''damaged'') THEN' || chr(10) || '    RAISE EXCEPTION ''wm_confirm_line: p_outcome must be restocked | redeploy_pending | waste | acknowledged | damaged (got %)'', p_outcome; END IF;'],
    ARRAY['  v_target_wh := (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_line.machine_id);',
          '  -- PRD-141 item 2: returns land in WH_CENTRAL unless the dispatch row names a return warehouse.' || chr(10) ||
          '  v_target_wh := COALESCE((SELECT rd.return_warehouse_id FROM public.refill_dispatching rd WHERE rd.dispatch_id = v_line.dispatch_id), ' || c_central || ');'],
    ARRAY['  v_state := p_outcome;',
          '  v_state := CASE WHEN p_outcome = ''damaged'' THEN ''received'' ELSE p_outcome END;'],
    ARRAY['CASE WHEN p_outcome = ''waste'' THEN ''expiry_writeoff'' ELSE ''dispatch_return'' END, p_line_id::text);',
          'CASE WHEN p_outcome = ''waste'' THEN ''expiry_writeoff'' WHEN p_outcome = ''damaged'' THEN ''damaged_return'' ELSE ''dispatch_return'' END, p_line_id::text);']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd141_02_04: wm_confirm_line anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  -- damaged never tops up an existing row, and nothing tops up a damaged row (2 lookups)
  v_new := 'WHERE boonz_product_id = v_line.boonz_product_id AND warehouse_id = v_target_wh AND status = ''Active''';
  n := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
  IF n <> 2 THEN RAISE EXCEPTION 'prd141_02_04: wm_confirm_line lookup count %', n; END IF;
  v_def := replace(v_def, v_new, v_new || ' AND p_outcome <> ''damaged'' AND provenance_reason IS DISTINCT FROM ''damaged_return''');
  v_new := 'IF p_outcome = ''waste'' THEN PERFORM public.warehouse_expire_writeoff(v_wh_inventory_id, p_reason, v_user_id, p_disposal_code); END IF;';
  n := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
  IF n <> 2 THEN RAISE EXCEPTION 'prd141_02_04: wm_confirm_line writeoff count %', n; END IF;
  v_def := replace(v_def, v_new, 'IF p_outcome = ''damaged'' THEN UPDATE public.warehouse_inventory SET damage_source = ''transit'' WHERE wh_inventory_id = v_wh_inventory_id; END IF;' || chr(10) || '  ' || v_new);
  EXECUTE v_def;

  -- wm_confirm_line_split
  v_def := pg_get_functiondef('public.wm_confirm_line_split(uuid,jsonb,text,uuid,boolean)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  v_user_id uuid := COALESCE(p_caller, auth.uid());',
          '  v_user_id uuid := COALESCE(auth.uid(), CASE WHEN current_user IN (''postgres'',''service_role'') THEN p_caller END);'],
    ARRAY['    IF v_outcome NOT IN (''restocked'',''redeploy_pending'',''waste'') THEN' || chr(10) || '      RAISE EXCEPTION ''wm_confirm_line_split: entry % outcome must be restocked | redeploy_pending | waste (got %)'', v_i, v_outcome;',
          '    IF v_outcome NOT IN (''restocked'',''redeploy_pending'',''waste'',''damaged'') THEN' || chr(10) || '      RAISE EXCEPTION ''wm_confirm_line_split: entry % outcome must be restocked | redeploy_pending | waste | damaged (got %)'', v_i, v_outcome;'],
    ARRAY['  v_target_wh := (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_line.machine_id);',
          '  -- PRD-141 item 2: returns land in WH_CENTRAL unless the dispatch row names a return warehouse.' || chr(10) ||
          '  v_target_wh := COALESCE((SELECT rd.return_warehouse_id FROM public.refill_dispatching rd WHERE rd.dispatch_id = v_line.dispatch_id), ' || c_central || ');'],
    ARRAY['     WHERE boonz_product_id = v_boonz_product_id AND warehouse_id = v_target_wh AND status = ''Active''',
          '     WHERE boonz_product_id = v_boonz_product_id AND warehouse_id = v_target_wh AND status = ''Active'' AND v_outcome <> ''damaged'' AND provenance_reason IS DISTINCT FROM ''damaged_return'''],
    ARRAY['    IF v_outcome = ''waste'' THEN' || chr(10) || '      PERFORM public.warehouse_expire_writeoff(',
          '    IF v_outcome = ''damaged'' THEN' || chr(10) ||
          '      UPDATE public.warehouse_inventory SET provenance_reason = ''damaged_return'', source_event_id = p_line_id, damage_source = ''transit''' || chr(10) ||
          '       WHERE wh_inventory_id = v_wh_inventory_id;' || chr(10) ||
          '    END IF;' || chr(10) ||
          '    IF v_outcome = ''waste'' THEN' || chr(10) || '      PERFORM public.warehouse_expire_writeoff('],
    ARRAY['v_boonz_product_id, v_expiry, v_qty, v_outcome,',
          'v_boonz_product_id, v_expiry, v_qty, CASE WHEN v_outcome = ''damaged'' THEN ''received'' ELSE v_outcome END,']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd141_02_04: wm_confirm_line_split anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  -- receive_dispatch_line: Remove credits go to WH_CENTRAL unless return_warehouse_id is set.
  v_def := pg_get_functiondef('public.receive_dispatch_line(uuid,numeric,uuid,jsonb,boolean,text)'::regprocedure);
  v_new := 'ELSIF v_dispatch.action = ''Remove'' THEN' || chr(10) || '    v_path := ''remove_single_expiry'';';
  n := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
  IF n <> 1 THEN RAISE EXCEPTION 'prd141_02_04: receive_dispatch_line anchor count %', n; END IF;
  v_def := replace(v_def, v_new, v_new || chr(10) || '    v_target_wh := COALESCE(v_dispatch.return_warehouse_id, ' || c_central || ');  -- PRD-141 item 2');
  EXECUTE v_def;

  -- wh_approve_remove_receipt_multivariant: children inherit the parent's return warehouse.
  v_def := pg_get_functiondef('public.wh_approve_remove_receipt_multivariant(uuid,jsonb,uuid,text)'::regprocedure);
  pairs := ARRAY[
    ARRAY['       expiry_date, from_warehouse_id,' || chr(10) || '       wh_approved_at, wh_approved_by, comment)',
          '       expiry_date, from_warehouse_id, return_warehouse_id,' || chr(10) || '       wh_approved_at, wh_approved_by, comment)'],
    ARRAY['       v_entry_expiry, v_parent.from_warehouse_id,' || chr(10) || '       now(), p_approved_by,',
          '       v_entry_expiry, v_parent.from_warehouse_id, v_parent.return_warehouse_id,' || chr(10) || '       now(), p_approved_by,']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd141_02_04: multivariant anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

REVOKE EXECUTE ON FUNCTION public.wm_confirm_line(uuid, numeric, date, text, uuid, text, text, uuid, boolean, jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.wm_confirm_line(uuid, numeric, date, text, uuid, text, text, uuid, boolean, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.wm_confirm_line_split(uuid, jsonb, text, uuid, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.wm_confirm_line_split(uuid, jsonb, text, uuid, boolean) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.receive_dispatch_line(uuid, numeric, uuid, jsonb, boolean, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.receive_dispatch_line(uuid, numeric, uuid, jsonb, boolean, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.wh_approve_remove_receipt_multivariant(uuid, jsonb, uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.wh_approve_remove_receipt_multivariant(uuid, jsonb, uuid, text) TO authenticated, service_role;
