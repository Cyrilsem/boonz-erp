-- PRD-020 — log_retroactive_refill_visit dedup key now includes expiry_date.
-- Cody-approved (Articles 1, 4, 8, 12). Applied to prod 2026-06-10 via MCP
-- (Supabase migration name `prd020_retro_log_dedup_include_expiry`); this file
-- keeps the repo in sync. Body verbatim except the one added dedup conjunct:
--   AND (expiry_date IS NOT DISTINCT FROM v_expiry)
-- Rationale: two genuinely distinct same-qty/same-shelf batches that differ only
-- by expiry (e.g. ALJLT-1015 Dubai Popcorn Butter 1@2027-02-01 and 1@2027-02-07)
-- were wrongly collapsed by the prior dedup, which omitted expiry. The change is
-- strictly narrower (cannot over-write or lose data; only stops false-positive skips).

CREATE OR REPLACE FUNCTION public.log_retroactive_refill_visit(p_machine_id uuid, p_visit_date date, p_lines jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_line jsonb; v_boonz uuid; v_qty numeric; v_shelf_code text; v_shelf_id uuid;
  v_pod uuid; v_expiry date; v_origin text; v_action text; v_comment text;
  v_n int:=0; v_skip int:=0; v_out jsonb:='[]'::jsonb; v_id uuid;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','log_retroactive_refill_visit',true);
  IF auth.uid() IS NOT NULL AND NOT EXISTS (SELECT 1 FROM user_profiles
     WHERE id=(SELECT auth.uid()) AND role=ANY(ARRAY['operator_admin','superadmin','manager','warehouse']))
  THEN RAISE EXCEPTION 'log_retroactive_refill_visit: caller role not permitted'; END IF;
  IF p_visit_date IS NULL OR p_visit_date>CURRENT_DATE THEN RAISE EXCEPTION 'visit_date must be non-future (got %)',p_visit_date; END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)=0 THEN RAISE EXCEPTION 'p_lines must be non-empty array'; END IF;
  IF COALESCE(length(trim(p_reason)),0)<10 THEN RAISE EXCEPTION 'p_reason must be >=10 chars'; END IF;
  IF NOT EXISTS (SELECT 1 FROM machines WHERE machine_id=p_machine_id AND status='Active') THEN RAISE EXCEPTION 'machine % not Active',p_machine_id; END IF;

  FOR v_line IN SELECT jsonb_array_elements(p_lines) LOOP
    v_boonz:=(v_line->>'boonz_product_id')::uuid; v_qty:=(v_line->>'qty')::numeric;
    v_shelf_code:=NULLIF(trim(v_line->>'shelf_code'),''); v_expiry:=NULLIF(v_line->>'expiry','')::date;
    v_origin:=COALESCE(NULLIF(v_line->>'source_origin',''),'warehouse');
    v_action:=COALESCE(NULLIF(trim(v_line->>'action'),''),'Refill');
    v_comment:=NULLIF(trim(v_line->>'comment'),'');
    IF v_boonz IS NULL OR v_qty IS NULL OR v_qty<=0 THEN RAISE EXCEPTION 'line needs boonz_product_id and qty>0 (got %)',v_line; END IF;
    IF NOT EXISTS (SELECT 1 FROM boonz_products WHERE product_id=v_boonz) THEN RAISE EXCEPTION 'boonz_product % not found',v_boonz; END IF;
    IF v_origin NOT IN ('warehouse','vox_at_venue') THEN RAISE EXCEPTION 'source_origin must be warehouse or vox_at_venue (got %)',v_origin; END IF;
    IF v_action NOT IN ('Refill','Add New') THEN RAISE EXCEPTION 'action must be Refill or Add New (got %)',v_action; END IF;
    SELECT pod_product_id INTO v_pod FROM product_mapping
      WHERE boonz_product_id=v_boonz AND status='Active' AND (machine_id=p_machine_id OR is_global_default=true)
      ORDER BY (machine_id=p_machine_id) DESC NULLS LAST LIMIT 1;
    IF v_pod IS NULL THEN RAISE EXCEPTION 'no active product_mapping for boonz % on machine %',v_boonz,p_machine_id; END IF;
    v_shelf_id:=NULL;
    IF v_shelf_code IS NOT NULL THEN
      SELECT shelf_id INTO v_shelf_id FROM shelf_configurations WHERE machine_id=p_machine_id AND shelf_code=v_shelf_code;
      IF v_shelf_id IS NULL THEN RAISE EXCEPTION 'shelf % not on machine %',v_shelf_code,p_machine_id; END IF;
    END IF;
    IF EXISTS (SELECT 1 FROM refill_dispatching
        WHERE machine_id=p_machine_id AND dispatch_date=p_visit_date AND boonz_product_id=v_boonz
          AND quantity=v_qty AND action=v_action AND comment LIKE '[RETRO-LOG%'
          AND (shelf_id IS NOT DISTINCT FROM v_shelf_id)
          AND (expiry_date IS NOT DISTINCT FROM v_expiry)) THEN
      v_skip:=v_skip+1;
      v_out:=v_out||jsonb_build_object('boonz',v_boonz,'qty',v_qty,'status','skipped_duplicate');
      CONTINUE;
    END IF;
    INSERT INTO refill_dispatching
      (machine_id,shelf_id,pod_product_id,boonz_product_id,dispatch_date,action,quantity,filled_quantity,
       driver_confirmed_qty,packed,picked_up,dispatched,returned,item_added,include,is_m2m,source_origin,
       expiry_date,comment,created_by_edit,created_at)
    VALUES (p_machine_id,v_shelf_id,v_pod,v_boonz,p_visit_date,v_action,v_qty,v_qty,v_qty,
       true,true,true,false,true,true,false,v_origin::source_origin_enum,
       v_expiry, format('[RETRO-LOG %s] %s%s',p_visit_date,p_reason,COALESCE(' | '||v_comment,'')),true,now())
    RETURNING dispatch_id INTO v_id;
    v_n:=v_n+1;
    v_out:=v_out||jsonb_build_object('dispatch_id',v_id,'boonz',v_boonz,'qty',v_qty,'shelf',v_shelf_code,'action',v_action,'origin',v_origin);
  END LOOP;
  RETURN jsonb_build_object('machine_id',p_machine_id,'visit_date',p_visit_date,
     'rows_logged',v_n,'rows_skipped_dup',v_skip,'lines',v_out,
     'note','no WH/pod stock movement - pod is WEIMI-fed; audited via tg_audit_refill_dispatching');
END $function$;
