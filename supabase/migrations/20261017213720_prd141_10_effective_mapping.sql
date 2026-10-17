-- PRD-141 item 10 (C1, C4): the engine and write_refill_plan read the effective mapping.
-- Effective mapping for (machine, pod, boonz): the machine's Active rows win; global rows only
-- apply when the machine has no Active row for that pod. split_pct = 0 on the effective row, or
-- only inactive rows for the product, means never propose and never accept a Refill / Add New.
-- A pod/boonz pair with no mapping row at all is NOT blocked here (unchanged behaviour, C4).
--   * mapping_refill_block(): NULL when allowed, else the blocking row as jsonb.
--   * resolve_fefo_sku_legs_v3 / resolve_supply_ladder_v3 (v3 draft path, cron 13): variant lists
--     skip blocked rows. Before this, they took the UNION of machine and global Active rows, so a
--     product dropped at machine level came back through its global row, and 0% rows stayed in.
--   * write_refill_plan: new G11_mapping_blocks error naming the row and the fix; the existing
--     G11_not_in_machine_mapping message now names the mapped products and the fix.
-- Night window only. Fleet diff in docs/prds/PRD-141-log.md. Rollback: supabase/rollbacks/prd141_10_rollback.sql.

CREATE OR REPLACE FUNCTION public.mapping_refill_block(p_machine_id uuid, p_pod_product_id uuid, p_boonz_product_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  r record;
  v_scope text;
BEGIN
  -- Machine-scoped Active rows win: if the machine has any for this pod, only they count.
  -- Inactive machine rows are history, not a veto (3,531 such rows in prod on 18 Oct).
  IF EXISTS (SELECT 1 FROM public.product_mapping pm
              WHERE pm.machine_id = p_machine_id AND pm.pod_product_id = p_pod_product_id AND pm.status = 'Active') THEN
    v_scope := 'machine';
    SELECT pm.mapping_id, pm.split_pct, pm.status INTO r FROM public.product_mapping pm
     WHERE pm.machine_id = p_machine_id AND pm.pod_product_id = p_pod_product_id
       AND pm.boonz_product_id = p_boonz_product_id AND pm.status = 'Active'
     ORDER BY COALESCE(pm.split_pct, 0) DESC LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('scope','machine','mapping_id',NULL,'split_pct',NULL,'status',NULL,'reason','shadowed_by_machine_mapping');
    END IF;
  ELSE
    v_scope := 'global';
    SELECT pm.mapping_id, pm.split_pct, pm.status INTO r FROM public.product_mapping pm
     WHERE pm.machine_id IS NULL AND pm.pod_product_id = p_pod_product_id
       AND pm.boonz_product_id = p_boonz_product_id AND pm.status = 'Active'
     ORDER BY COALESCE(pm.split_pct, 0) DESC LIMIT 1;
    IF NOT FOUND THEN
      -- No Active row for this product: blocked only if an inactive row says so explicitly;
      -- no row at all is not blocked here (C4).
      SELECT pm.mapping_id, pm.split_pct, pm.status, (pm.machine_id IS NOT NULL) AS scoped INTO r FROM public.product_mapping pm
       WHERE (pm.machine_id = p_machine_id OR pm.machine_id IS NULL) AND pm.pod_product_id = p_pod_product_id
         AND pm.boonz_product_id = p_boonz_product_id
       ORDER BY (pm.machine_id IS NOT NULL) DESC, pm.updated_at DESC NULLS LAST LIMIT 1;
      IF FOUND THEN
        RETURN jsonb_build_object('scope', CASE WHEN r.scoped THEN 'machine' ELSE 'global' END,'mapping_id',r.mapping_id,'split_pct',r.split_pct,'status',r.status,'reason','mapping_not_active');
      END IF;
      RETURN NULL;
    END IF;
  END IF;
  IF COALESCE(r.split_pct, 0) = 0 THEN
    RETURN jsonb_build_object('scope',v_scope,'mapping_id',r.mapping_id,'split_pct',r.split_pct,'status',r.status,'reason','split_zero');
  END IF;
  RETURN NULL;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.mapping_refill_block(uuid, uuid, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.mapping_refill_block(uuid, uuid, uuid) TO authenticated, service_role;

DO $patch$
DECLARE
  v_def text; v_new text; n int;
  a_old text := 'AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)';
  a_new text := 'AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)'
             || ' AND public.mapping_refill_block(p_machine_id, pm.pod_product_id, pm.boonz_product_id) IS NULL';
  g_old text := '            ''message'',''G11 not in machine mapping'',';
  g_new text := '            ''message'',format(''G11: %s is not in the %s mapping for this pod on %s (mapped: %s). Add an Active machine-scoped product_mapping row for it in Config > Product Mapping, or plan one of the mapped products.'', v_product, v_machine, v_shelf, (SELECT string_agg(bpm.boonz_product_name, '', '' ORDER BY bpm.boonz_product_name) FROM public.boonz_products bpm WHERE bpm.product_id = ANY(v_g11.mapped_ids))),';
  b_old text := '        ELSIF v_g11.is_override THEN';
  b_new text := '        ELSIF public.mapping_refill_block(v_g11_machine_id, v_g11_pod_product_id, v_g11_boonz_product_id) IS NOT NULL THEN' || chr(10)
             || '          v_map_block := public.mapping_refill_block(v_g11_machine_id, v_g11_pod_product_id, v_g11_boonz_product_id);' || chr(10)
             || '          v_errors := v_errors || jsonb_build_object(' || chr(10)
             || '            ''line'',v_line_idx,''check'',''G11_mapping_blocks'',' || chr(10)
             || '            ''message'',format(''%s %s on %s %s is blocked by the %s mapping row %s (split_pct %s, status %s, %s). Set split above 0 and status Active in Config > Product Mapping, or insert an Active machine-scoped row for this machine.'', v_action, v_product, v_machine, v_shelf, v_map_block->>''scope'', COALESCE(v_map_block->>''mapping_id'',''(none)''), COALESCE(v_map_block->>''split_pct'',''-''), COALESCE(v_map_block->>''status'',''-''), v_map_block->>''reason''),' || chr(10)
             || '            ''machine'',v_machine,''product'',v_product,''mapping'',v_map_block);' || chr(10)
             || '        ELSIF v_g11.is_override THEN';
  d_old text := '  v_weimi_stock  int;' || chr(10) || 'BEGIN';
  d_new text := '  v_weimi_stock  int;' || chr(10) || '  v_map_block    jsonb;' || chr(10) || 'BEGIN';
BEGIN
  v_def := pg_get_functiondef('public.resolve_fefo_sku_legs_v3(date,uuid,uuid,uuid,integer,text)'::regprocedure);
  n := (length(v_def) - length(replace(v_def, a_old, ''))) / length(a_old);
  IF n <> 2 THEN RAISE EXCEPTION 'prd141_10: fefo anchor count %', n; END IF;
  EXECUTE replace(v_def, a_old, a_new);

  v_def := pg_get_functiondef('public.resolve_supply_ladder_v3(date,uuid,uuid,uuid,integer,integer)'::regprocedure);
  n := (length(v_def) - length(replace(v_def, a_old, ''))) / length(a_old);
  IF n <> 1 THEN RAISE EXCEPTION 'prd141_10: ladder anchor count %', n; END IF;
  EXECUTE replace(v_def, a_old, a_new);

  v_def := pg_get_functiondef('public.write_refill_plan(date,jsonb)'::regprocedure);
  FOREACH v_new IN ARRAY ARRAY[g_old, b_old, d_old] LOOP
    n := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
    IF n <> 1 THEN RAISE EXCEPTION 'prd141_10: write_refill_plan anchor count % for %', n, left(v_new, 40); END IF;
  END LOOP;
  v_new := replace(replace(replace(v_def, g_old, g_new), b_old, b_new), d_old, d_new);
  EXECUTE v_new;
END
$patch$;

REVOKE EXECUTE ON FUNCTION public.write_refill_plan(date, jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.write_refill_plan(date, jsonb) TO authenticated, service_role;
