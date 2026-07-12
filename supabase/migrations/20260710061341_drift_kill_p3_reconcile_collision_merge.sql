-- drift-kill P3 fix: reconcile move must yield to the partial unique index
-- idx_pod_inv_active_shelf (machine_id, shelf_id, boonz_product_id WHERE
-- status='Active'). When the WEIMI-home shelf ALREADY holds an Active row of
-- the same product, the drifted row is a duplicate, not a relocation ->
-- ARCHIVE it (status Inactive, reversible) instead of moving. Also skip a
-- no-op self-move (row already on its target shelf). Everything else
-- byte-identical to reconcile v1 (base md5 95b8ee928557e832b7843b6330cb2095).
-- Dara-designed, Cody-reviewed (Articles 1,3,5,8,12; Am.005). No deletes.
CREATE OR REPLACE FUNCTION public.reconcile_shelf_identity_weimi(p_machine_id uuid, p_dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_role text;
  r RECORD;
  v_target uuid;
  v_target_n int;
  v_collision boolean;
  v_self_boonz uuid;
  v_moved int := 0; v_archived int := 0; v_plano_off int := 0;
  v_actions jsonb := '[]'::jsonb;
BEGIN
  IF v_user IS NOT NULL THEN
    SELECT role INTO v_role FROM user_profiles WHERE id = v_user;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager','warehouse') THEN
      RAISE EXCEPTION 'reconcile_shelf_identity_weimi: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;
  IF p_machine_id IS NULL THEN RAISE EXCEPTION 'p_machine_id required'; END IF;

  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','reconcile_shelf_identity_weimi', true);
  PERFORM set_config('app.mutation_reason',
    format('drift-kill P3 reconcile machine=%s dry_run=%s by=%s', p_machine_id, p_dry_run, v_user), true);

  FOR r IN
    SELECT * FROM v_weimi_slot_drift_report
    WHERE machine_id = p_machine_id AND source = 'pod_inventory' AND verdict = 'mismatch'
  LOOP
    SELECT ssi.shelf_id, count(*) OVER () INTO v_target, v_target_n
    FROM v_shelf_slot_identity ssi
    JOIN product_mapping pm ON pm.pod_product_id = ssi.pod_product_id AND pm.status='Active'
    JOIN pod_inventory pi ON pi.pod_inventory_id = r.row_id AND pm.boonz_product_id = pi.boonz_product_id
    WHERE ssi.machine_id = p_machine_id AND ssi.match_method <> 'unmatched'
    LIMIT 1;

    SELECT pi.boonz_product_id INTO v_self_boonz FROM pod_inventory pi WHERE pi.pod_inventory_id = r.row_id;

    -- would moving collide with the partial-unique active-shelf index?
    v_collision := v_target IS NOT NULL AND EXISTS (
      SELECT 1 FROM pod_inventory pi
      WHERE pi.machine_id = p_machine_id AND pi.shelf_id = v_target
        AND pi.boonz_product_id = v_self_boonz AND pi.status = 'Active'
        AND pi.pod_inventory_id <> r.row_id);

    IF v_target IS NOT NULL AND v_target_n = 1 AND NOT v_collision THEN
      IF NOT p_dry_run THEN
        UPDATE pod_inventory SET shelf_id = v_target WHERE pod_inventory_id = r.row_id AND status='Active';
      END IF;
      v_moved := v_moved + 1;
      v_actions := v_actions || jsonb_build_object('action','move','row_id',r.row_id,
        'product',r.row_product,'from_shelf',r.shelf_code,'to_shelf_id',v_target,'stock',r.current_stock);
    ELSE
      IF NOT p_dry_run THEN
        UPDATE pod_inventory SET status = 'Inactive' WHERE pod_inventory_id = r.row_id AND status='Active';
      END IF;
      v_archived := v_archived + 1;
      v_actions := v_actions || jsonb_build_object('action','archive','row_id',r.row_id,
        'product',r.row_product,'shelf',r.shelf_code,'stock',r.current_stock,
        'reason', CASE WHEN v_collision THEN 'duplicate_target_shelf_has_active_row'
                       WHEN v_target IS NULL THEN 'no_weimi_home_on_machine'
                       ELSE 'ambiguous_multiple_homes' END);
    END IF;
    v_target := NULL; v_target_n := NULL; v_collision := NULL; v_self_boonz := NULL;
  END LOOP;

  FOR r IN
    SELECT * FROM v_weimi_slot_drift_report
    WHERE machine_id = p_machine_id AND source = 'planogram' AND verdict = 'mismatch'
  LOOP
    IF NOT p_dry_run THEN
      UPDATE planogram SET is_active = false WHERE planogram_id = r.row_id AND is_active = true;
    END IF;
    v_plano_off := v_plano_off + 1;
    v_actions := v_actions || jsonb_build_object('action','planogram_deactivate','row_id',r.row_id,
      'row_product',r.row_product,'shelf',r.shelf_code,'weimi_product',r.weimi_pod_name);
  END LOOP;

  IF NOT p_dry_run AND (v_moved + v_archived + v_plano_off) > 0 THEN
    INSERT INTO monitoring_alerts (source, severity, payload)
    VALUES ('drift_kill_reconcile','warning', jsonb_build_object(
      'title', format('reconciled slot identity: machine %s (%s moved, %s archived, %s planogram off)', p_machine_id, v_moved, v_archived, v_plano_off),
      'machine_id', p_machine_id, 'actions', v_actions, 'by', v_user, 'at', now()));
  END IF;

  RETURN jsonb_build_object('status','ok','dry_run',p_dry_run,'machine_id',p_machine_id,
    'moved',v_moved,'archived',v_archived,'planogram_deactivated',v_plano_off,'actions',v_actions);
END;
$function$;