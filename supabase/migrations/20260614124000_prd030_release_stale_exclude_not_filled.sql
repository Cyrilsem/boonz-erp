-- PRD-030 step 3d: EOD release excludes resolved not_filled lines (one predicate add).
CREATE OR REPLACE FUNCTION public.release_stale_unpacked_dispatches(p_dry_run boolean DEFAULT true, p_before date DEFAULT NULL::date)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_user_id uuid; v_before date; v_n integer := 0; v_summary jsonb; v_excluded integer := 0;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','release_stale_unpacked_dispatches',true);
  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.user_profiles up WHERE up.id=v_user_id AND up.role='operator_admin')
  THEN RAISE EXCEPTION 'release_stale_unpacked_dispatches: caller % lacks operator_admin role', v_user_id; END IF;
  v_before := COALESCE(p_before, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date);
  SELECT COUNT(*) INTO v_excluded FROM public.refill_dispatching
  WHERE COALESCE(cancelled,false)=false AND COALESCE(skipped,false)=false
    AND COALESCE(packed,false)=false AND COALESCE(picked_up,false)=false
    AND COALESCE(returned,false)=false AND COALESCE(item_added,false)=false
    AND COALESCE(pack_outcome::text,'') <> 'not_filled'
    AND dispatch_date < v_before AND source_kind IN ('m2m','truck_transfer') AND is_m2m IS NOT TRUE;
  SELECT jsonb_build_object('lines',COUNT(*),'units',COALESCE(SUM(quantity::numeric),0),
    'products',COUNT(DISTINCT boonz_product_id),'machines',COUNT(DISTINCT machine_id),
    'oldest',MIN(dispatch_date),'newest',MAX(dispatch_date))
  INTO v_summary FROM public.refill_dispatching
  WHERE COALESCE(cancelled,false)=false AND COALESCE(skipped,false)=false
    AND COALESCE(packed,false)=false AND COALESCE(picked_up,false)=false
    AND COALESCE(returned,false)=false AND COALESCE(item_added,false)=false
    AND COALESCE(pack_outcome::text,'') <> 'not_filled'
    AND dispatch_date < v_before AND NOT (source_kind IN ('m2m','truck_transfer') AND is_m2m IS NOT TRUE);
  IF p_dry_run THEN
    RETURN jsonb_build_object('dry_run',true,'before',v_before,'would_release',v_summary,'excluded_m2m_inconsistent',v_excluded);
  END IF;
  UPDATE public.refill_dispatching SET cancelled=true, cancelled_at=now(), cancelled_by=v_user_id,
    cancellation_reason='stale_unpacked_auto_release (never packed, dispatch_date < ' || v_before::text || ')'
  WHERE COALESCE(cancelled,false)=false AND COALESCE(skipped,false)=false
    AND COALESCE(packed,false)=false AND COALESCE(picked_up,false)=false
    AND COALESCE(returned,false)=false AND COALESCE(item_added,false)=false
    AND COALESCE(pack_outcome::text,'') <> 'not_filled'
    AND dispatch_date < v_before AND NOT (source_kind IN ('m2m','truck_transfer') AND is_m2m IS NOT TRUE);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('dry_run',false,'before',v_before,'released_lines',v_n,'excluded_m2m_inconsistent',v_excluded,'summary',v_summary);
END;
$function$;
