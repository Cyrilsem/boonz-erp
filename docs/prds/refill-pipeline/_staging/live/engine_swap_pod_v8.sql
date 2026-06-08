CREATE OR REPLACE FUNCTION public.engine_swap_pod(p_plan_date date DEFAULT (CURRENT_DATE + 1), p_max_swaps_per_machine integer DEFAULT 2, p_min_pearson numeric DEFAULT 0.30, p_days_cover integer DEFAULT 14)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_user_id        uuid;
  v_t0             timestamptz := clock_timestamp();
  v_tag_swaps      integer := 0;
  v_tag_m2w        integer := 0;
  v_auto_swaps     integer := 0;
  v_auto_m2w       integer := 0;
  v_skip_cooldown  integer := 0;
  v_skip_runway    integer := 0;
  v_skip_planned   integer := 0;
  v_skip_duplicate integer := 0;
  v_skipped_swaps  jsonb   := '[]'::jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','engine_swap_pod',true);
  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up WHERE up.id=v_user_id AND up.role='operator_admin'
  ) THEN RAISE EXCEPTION 'engine_swap_pod: caller % lacks operator_admin role', v_user_id; END IF;
  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'engine_swap_pod: p_plan_date required'; END IF;
  IF p_days_cover IS NULL OR p_days_cover <= 0 THEN
    RAISE EXCEPTION 'engine_swap_pod: p_days_cover must be > 0';
  END IF;
  DELETE FROM public.pod_swaps WHERE plan_date=p_plan_date;
  IF NOT EXISTS (SELECT 1 FROM public.machines_to_visit
                  WHERE plan_date=p_plan_date AND status IN ('picked','cs_added')) THEN
    RAISE EXCEPTION 'engine_swap_pod: no picked/cs_added machines for %', p_plan_date;
  END IF;
  PERFORM public._assert_gate_zero(p_plan_date);
  CREATE TEMP TABLE _r5_removal_cooldown ON COMMIT DROP AS
  SELECT DISTINCT m.machine_id, pp.pod_product_id
    FROM public.refill_plan_output rpo
    JOIN public.machines m ON m.official_name = rpo.machine_name
    JOIN public.pod_products pp ON pp.pod_product_name = rpo.pod_product_name
   WHERE rpo.action ILIKE 'Remove%' AND rpo.plan_date >= p_plan_date - interval '14 days';
  CREATE TEMP TABLE _r5_introduction_cooldown ON COMMIT DROP AS
  SELECT DISTINCT m.machine_id, pp.pod_product_id
    FROM public.refill_plan_output rpo
    JOIN public.machines m ON m.official_name = rpo.machine_name
    JOIN public.pod_products pp ON pp.pod_product_name = rpo.pod_product_name
   WHERE rpo.action ILIKE 'Remove%' AND rpo.plan_date >= p_plan_date - interval '30 days';
  CREATE TEMP TABLE _fleet_velocity ON COMMIT DROP AS
  SELECT sl.pod_product_id, AVG(sl.velocity_30d)::numeric(8,3) AS avg_v30
    FROM public.slot_lifecycle sl
   WHERE sl.archived=false AND sl.is_current=true GROUP BY sl.pod_product_id;
  CREATE TEMP TABLE _shelf_live_stock ON COMMIT DROP AS
  SELECT vls.machine_id, sc.shelf_id, MAX(vls.current_stock)::int AS current_stock
  FROM public.v_live_shelf_stock vls
  JOIN public.shelf_configurations sc
    ON sc.machine_id = vls.machine_id AND sc.is_phantom = false
   AND vls.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
  GROUP BY vls.machine_id, sc.shelf_id;
  CREATE TEMP TABLE _planned_swap_shelves ON COMMIT DROP AS
  SELECT DISTINCT sl.machine_id, sl.shelf_id
    FROM public.planned_swaps ps
    JOIN public.pod_products pp ON pp.pod_product_name = ps.remove_pod_product_name
    JOIN public.slot_lifecycle sl
      ON sl.machine_id = ps.machine_id AND sl.pod_product_id = pp.pod_product_id
     AND sl.archived = false AND sl.is_current = true
   WHERE ps.status = 'pending';
  CREATE TEMP TABLE _machine_present_pods ON COMMIT DROP AS
  SELECT DISTINCT machine_id, pod_product_id FROM (
    SELECT sl.machine_id, sl.pod_product_id
      FROM public.slot_lifecycle sl
     WHERE sl.archived = false AND sl.is_current = true
    UNION
    SELECT vls.machine_id, vls.pod_product_id
      FROM public.v_live_shelf_stock vls
     WHERE vls.pod_product_id IS NOT NULL AND vls.current_stock > 0
  ) present;
  -- [F6] Machines with swaps toggled OFF: per-machine override ?? global ?? true (default ON).
  CREATE TEMP TABLE _swaps_disabled_machines ON COMMIT DROP AS
  SELECT m.machine_id
    FROM public.machines m
   WHERE COALESCE(
           (SELECT rs.setting_value FROM public.refill_settings rs
             WHERE rs.setting_key = 'swaps_enabled:' || m.machine_id::text),
           (SELECT rs.setting_value FROM public.refill_settings rs
             WHERE rs.setting_key = 'swaps_enabled'),
           'true'::jsonb
         ) = 'false'::jsonb;
  -- [#10 feed] Substitutes CS rejected >= 3 times in 30d on a machine: never re-propose them.
  CREATE TEMP TABLE _suppressed_swap_subs ON COMMIT DROP AS
  SELECT machine_id, pod_product_id AS pod_in
    FROM public.refill_edit_signals
   WHERE signal_type = 'swap_rejected'
     AND pod_product_id IS NOT NULL
     AND created_at >= now() - interval '30 days'
   GROUP BY machine_id, pod_product_id
  HAVING COUNT(*) >= 3;
  WITH picked AS (SELECT mtv.machine_id FROM public.machines_to_visit mtv
    WHERE mtv.plan_date=p_plan_date AND mtv.status IN ('picked','cs_added')
      AND NOT EXISTS (SELECT 1 FROM _swaps_disabled_machines d WHERE d.machine_id = mtv.machine_id)),
  tag_targets AS (
    SELECT smt.tag_id, smt.strategic_intent_id AS intent_id, smt.machine_id, smt.pod_product_id AS pod_out,
           smt.action_directive, smt.substitute_pod_product_id AS pod_in, smt.priority,
           sl.shelf_id AS sl_shelf,
           ROW_NUMBER() OVER (PARTITION BY smt.machine_id
             ORDER BY smt.priority ASC, smt.proposed_at ASC, smt.tag_id) AS rnk
    FROM public.strategic_machine_tags smt
    JOIN picked p ON p.machine_id = smt.machine_id
    JOIN public.strategic_intents si ON si.intent_id = smt.strategic_intent_id
                                     AND si.status IN ('queued','in_progress')
    LEFT JOIN public.slot_lifecycle sl ON sl.machine_id = smt.machine_id
     AND sl.pod_product_id = smt.pod_product_id AND sl.archived = false AND sl.is_current = true
    WHERE smt.status = 'approved' AND smt.action_directive IN ('swap_out_with_substitute','swap_out_m2w')
  ),
  tag_capped AS (SELECT * FROM tag_targets WHERE rnk <= p_max_swaps_per_machine),
  tag_resolved AS (
    SELECT tc.*,
           COALESCE(tc.sl_shelf,
             (SELECT pil.shelf_id FROM public.v_pod_inventory_latest pil
                JOIN public.product_mapping pm ON pm.boonz_product_id = pil.boonz_product_id
                                                AND pm.status='Active' AND pm.pod_product_id = tc.pod_out
               WHERE pil.machine_id = tc.machine_id AND pil.status='Active'
               ORDER BY pil.current_stock DESC LIMIT 1)
           ) AS shelf_id_final
    FROM tag_capped tc
  )
  INSERT INTO public.pod_swaps(plan_date, machine_id, shelf_id, pod_product_id_out, pod_product_id_in,
    qty_out, qty_in, reason, substitute_source, substitute_score, linked_intent_id, reasoning)
  SELECT p_plan_date, tr.machine_id, tr.shelf_id_final, tr.pod_out,
    CASE WHEN tr.action_directive='swap_out_with_substitute' THEN tr.pod_in ELSE NULL END,
    COALESCE((SELECT GREATEST(SUM(vls.current_stock),1)::int FROM public.v_live_shelf_stock vls JOIN public.shelf_configurations sc ON sc.machine_id = vls.machine_id AND sc.is_phantom = false AND vls.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text WHERE vls.machine_id = tr.machine_id AND sc.shelf_id = tr.shelf_id_final AND vls.pod_product_id = tr.pod_out),1)::int,
    CASE WHEN tr.action_directive='swap_out_m2w' THEN NULL
         ELSE GREATEST(COALESCE((SELECT MAX(sms.max_stock_weimi)::int FROM public.v_shelf_max_stock sms
                                  WHERE sms.shelf_id = tr.shelf_id_final),8)/2,4)::int END,
    CASE WHEN tr.action_directive='swap_out_m2w' THEN 'm2w' ELSE 'intent_driven' END,
    'strategic_tag', NULL::numeric, tr.intent_id,
    jsonb_build_object('pass','1','source','strategic_machine_tag','tag_id', tr.tag_id,
                       'tag_directive', tr.action_directive, 'tag_priority', tr.priority,
                       'engine_version','v9_5_qty_live_shelf_stock')
  FROM tag_resolved tr WHERE tr.shelf_id_final IS NOT NULL
  ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id_out) DO NOTHING;
  UPDATE public.strategic_machine_tags smt
     SET status = 'consumed', consumed_at = now(), consumed_at_plan_date = p_plan_date,
         consumed_via_swap_id = ps.swap_id
    FROM public.pod_swaps ps
   WHERE ps.plan_date = p_plan_date AND (ps.reasoning->>'source') = 'strategic_machine_tag'
     AND (ps.reasoning->>'tag_id')::uuid = smt.tag_id AND smt.status = 'approved';
  SELECT COUNT(*) FILTER (WHERE ps.reason='intent_driven'),
         COUNT(*) FILTER (WHERE ps.reason='m2w')
  INTO v_tag_swaps, v_tag_m2w
  FROM public.pod_swaps ps
  WHERE ps.plan_date = p_plan_date AND (ps.reasoning->>'source')='strategic_machine_tag';
  WITH picked AS (
    SELECT mtv.machine_id, m.location_type FROM public.machines_to_visit mtv
    JOIN public.machines m ON m.machine_id = mtv.machine_id
    WHERE mtv.plan_date=p_plan_date AND mtv.status IN ('picked','cs_added')
      AND NOT EXISTS (SELECT 1 FROM _swaps_disabled_machines d WHERE d.machine_id = mtv.machine_id)
  ),
  pass1_used AS (SELECT machine_id, COUNT(*)::int AS used FROM public.pod_swaps
                 WHERE plan_date=p_plan_date GROUP BY machine_id),
  already_swapped AS (SELECT machine_id, shelf_id FROM public.pod_swaps WHERE plan_date=p_plan_date),
  candidates_raw AS (
    SELECT p.machine_id, p.location_type, sl.shelf_id, sl.pod_product_id AS pod_out, sl.signal,
           pp.product_category AS cat_out, pp.pod_product_name, sc.shelf_code,
           COALESCE(sl.velocity_30d, 0)::numeric    AS v30,
           COALESCE(sls.current_stock, 0)::integer  AS current_stock,
           CEIL(COALESCE(sl.velocity_30d, 0) * p_days_cover * 1.0)::int AS target_stock,
           CASE WHEN COALESCE(sl.velocity_30d, 0) > 0
                THEN ROUND(COALESCE(sls.current_stock, 0)::numeric / sl.velocity_30d, 1)
                ELSE NULL END AS runway_days,
           COALESCE(pu.used, 0) AS pass1_used_count
    FROM picked p
    JOIN public.slot_lifecycle sl ON sl.machine_id=p.machine_id
                                  AND sl.archived=false AND sl.is_current=true
                                  AND sl.signal IN ('DEAD — SWAP NOW','ROTATE OUT','WIND DOWN')
    JOIN public.pod_products pp ON pp.pod_product_id = sl.pod_product_id
    JOIN public.shelf_configurations sc ON sc.shelf_id = sl.shelf_id
    LEFT JOIN _shelf_live_stock sls ON sls.machine_id = sl.machine_id AND sls.shelf_id = sl.shelf_id
    LEFT JOIN already_swapped a ON a.machine_id=p.machine_id AND a.shelf_id=sl.shelf_id
    LEFT JOIN pass1_used pu ON pu.machine_id = p.machine_id
    LEFT JOIN _planned_swap_shelves pss ON pss.machine_id = p.machine_id AND pss.shelf_id = sl.shelf_id
    WHERE a.shelf_id IS NULL AND pss.shelf_id IS NULL
  ),
  candidates_gated AS (
    SELECT c.*, (c.signal IN ('WIND DOWN','ROTATE OUT') AND c.v30 > 0 AND c.current_stock < c.target_stock) AS is_healthy_skip
    FROM candidates_raw c
  ),
  skipped AS (SELECT machine_id, shelf_id, pod_out, signal, v30, current_stock, target_stock, runway_days,
           pod_product_name, shelf_code FROM candidates_gated WHERE is_healthy_skip = true),
  candidates AS (SELECT machine_id, location_type, shelf_id, pod_out, signal, cat_out, pass1_used_count
    FROM candidates_gated WHERE is_healthy_skip = false),
  ranked AS (SELECT c.*, ROW_NUMBER() OVER (PARTITION BY c.machine_id
      ORDER BY CASE c.signal WHEN 'DEAD — SWAP NOW' THEN 1 WHEN 'ROTATE OUT' THEN 2
                              WHEN 'WIND DOWN' THEN 3 END, c.shelf_id) AS within_machine_rnk
    FROM candidates c),
  capped AS (SELECT * FROM ranked WHERE within_machine_rnk <= GREATEST(p_max_swaps_per_machine - pass1_used_count, 0)),
  capped_with_cooldown AS (SELECT c.* FROM capped c
    LEFT JOIN _r5_removal_cooldown roc ON roc.machine_id=c.machine_id AND roc.pod_product_id=c.pod_out
    WHERE roc.pod_product_id IS NULL),
  pass1_added_products AS (SELECT DISTINCT machine_id, pod_product_id_in AS pod_in
    FROM public.pod_swaps WHERE plan_date = p_plan_date AND pod_product_id_in IS NOT NULL),
  sub_candidates AS (
    SELECT c.machine_id, c.shelf_id, c.pod_out, c.signal, c.cat_out, sub.pod_product_id AS pod_in,
           fv.avg_v30 AS sub_v30, per_m.pearson AS p_machine, per_l.pearson AS p_loc,
           CASE WHEN per_m.pearson IS NOT NULL THEN 'pearson_per_machine'
                WHEN per_l.pearson IS NOT NULL THEN 'pearson_per_loc' ELSE 'category_fallback' END AS sub_source,
           ROW_NUMBER() OVER (PARTITION BY c.machine_id,c.shelf_id,c.pod_out
             ORDER BY CASE WHEN per_m.pearson IS NOT NULL THEN 0
                           WHEN per_l.pearson IS NOT NULL THEN 1 ELSE 2 END,
                      COALESCE(per_m.pearson, per_l.pearson, 0) DESC,
                      fv.avg_v30 DESC NULLS LAST, sub.pod_product_id) AS rnk
    FROM capped_with_cooldown c
    JOIN public.pod_products sub ON sub.pod_product_id <> c.pod_out
    JOIN public.v_warehouse_pod_rollup wpr ON wpr.pod_product_id=sub.pod_product_id AND wpr.total_stock>0
    JOIN _fleet_velocity fv ON fv.pod_product_id=sub.pod_product_id
    LEFT JOIN public.correlation_pod_per_machine per_m
      ON per_m.machine_id=c.machine_id
     AND ((per_m.pod_product_a=c.pod_out AND per_m.pod_product_b=sub.pod_product_id)
       OR (per_m.pod_product_b=c.pod_out AND per_m.pod_product_a=sub.pod_product_id))
     AND per_m.pearson >= p_min_pearson
    LEFT JOIN public.correlation_pod_per_loc_type per_l
      ON per_l.location_type=c.location_type
     AND ((per_l.pod_product_a=c.pod_out AND per_l.pod_product_b=sub.pod_product_id)
       OR (per_l.pod_product_b=c.pod_out AND per_l.pod_product_a=sub.pod_product_id))
     AND per_l.pearson >= p_min_pearson
    LEFT JOIN public.v_pod_inventory_latest pil
      ON pil.machine_id=c.machine_id
     AND pil.boonz_product_id IN (SELECT boonz_product_id FROM public.product_mapping
                                   WHERE pod_product_id=sub.pod_product_id AND status='Active')
     AND pil.status='Active'
    LEFT JOIN public.strategic_intents ad_in
      ON ad_in.scope_pod_product_id=sub.pod_product_id
     AND ad_in.intent_type='decommission' AND ad_in.status IN ('queued','in_progress')
    LEFT JOIN _r5_introduction_cooldown rc ON rc.machine_id=c.machine_id AND rc.pod_product_id=sub.pod_product_id
    LEFT JOIN pass1_added_products p1 ON p1.machine_id = c.machine_id AND p1.pod_in = sub.pod_product_id
    LEFT JOIN _machine_present_pods mpp ON mpp.machine_id = c.machine_id AND mpp.pod_product_id = sub.pod_product_id
    LEFT JOIN _suppressed_swap_subs sss ON sss.machine_id = c.machine_id AND sss.pod_in = sub.pod_product_id
    WHERE pil.machine_id IS NULL AND ad_in.intent_id IS NULL AND rc.pod_product_id IS NULL
      AND p1.pod_in IS NULL
      AND mpp.pod_product_id IS NULL
      AND sss.pod_in IS NULL
      AND (per_m.pearson IS NOT NULL OR per_l.pearson IS NOT NULL OR sub.product_category = c.cat_out)
  ),
  pass2_picks_raw AS (SELECT * FROM sub_candidates WHERE rnk=1),
  pass2_picks AS (
    SELECT ppr.*, ROW_NUMBER() OVER (PARTITION BY ppr.machine_id, ppr.pod_in
        ORDER BY COALESCE(ppr.p_machine, ppr.p_loc, ppr.sub_v30) DESC, ppr.shelf_id) AS dedup_rank
    FROM pass2_picks_raw ppr
  ),
  pass2_combined AS (
    SELECT c.machine_id,c.shelf_id,c.pod_out,c.signal,c.cat_out,
           CASE WHEN pp.dedup_rank = 1 THEN pp.pod_in ELSE NULL END AS pod_in,
           pp.sub_v30, pp.sub_source, pp.p_machine, pp.p_loc, pp.dedup_rank
    FROM capped_with_cooldown c
    LEFT JOIN pass2_picks pp ON pp.machine_id=c.machine_id AND pp.shelf_id=c.shelf_id AND pp.pod_out=c.pod_out
  ),
  pass2_inserted AS (
    INSERT INTO public.pod_swaps(plan_date, machine_id, shelf_id, pod_product_id_out, pod_product_id_in,
      qty_out, qty_in, reason, substitute_source, substitute_score, linked_intent_id, reasoning)
    SELECT p_plan_date, p2.machine_id, p2.shelf_id, p2.pod_out, p2.pod_in,
      COALESCE((SELECT GREATEST(SUM(vls.current_stock),1)::int FROM public.v_live_shelf_stock vls JOIN public.shelf_configurations sc ON sc.machine_id = vls.machine_id AND sc.is_phantom = false AND vls.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text WHERE vls.machine_id = p2.machine_id AND sc.shelf_id = p2.shelf_id AND vls.pod_product_id = p2.pod_out),1)::int,
      CASE WHEN p2.pod_in IS NULL THEN NULL
           ELSE GREATEST(COALESCE((SELECT MAX(sms.max_stock_weimi)::int FROM public.v_shelf_max_stock sms
                                    WHERE sms.shelf_id = p2.shelf_id),8)/2,4)::int END,
      CASE WHEN p2.pod_in IS NULL THEN 'm2w'
           WHEN p2.signal = 'DEAD — SWAP NOW' THEN 'dead'
           WHEN p2.signal = 'ROTATE OUT'      THEN 'rotate_out'
           WHEN p2.signal = 'WIND DOWN'       THEN 'wind_down'
           ELSE 'rotate_out' END,
      COALESCE(p2.sub_source, 'm2w'), COALESCE(p2.p_machine, p2.p_loc, p2.sub_v30), NULL::uuid,
      jsonb_build_object('pass','2','source','autonomous','signal',p2.signal,'cat_out',p2.cat_out,
        'pearson_per_machine',p2.p_machine,'pearson_per_loc',p2.p_loc,
        'dedup_demoted_to_m2w', (p2.dedup_rank IS NOT NULL AND p2.dedup_rank > 1),
        'engine_version','v9_5_qty_live_shelf_stock')
    FROM pass2_combined p2
    ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id_out) DO NOTHING
    RETURNING reason, reasoning),
  agg_skipped AS (
    SELECT COUNT(*) AS skip_count,
      COALESCE(jsonb_agg(jsonb_build_object(
        'machine_id', s.machine_id, 'shelf_id', s.shelf_id, 'shelf_code', s.shelf_code,
        'pod_product', s.pod_product_name, 'signal', s.signal, 'velocity_30d', s.v30,
        'current_stock', s.current_stock, 'target_stock', s.target_stock,
        'runway_days', s.runway_days, 'reason', 'healthy_runway'
      ) ORDER BY s.signal, s.current_stock DESC), '[]'::jsonb) AS payload
    FROM skipped s)
  SELECT COUNT(*) FILTER (WHERE reason IN ('dead','rotate_out','wind_down')),
         COUNT(*) FILTER (WHERE reason='m2w'),
         COUNT(*) FILTER (WHERE (reasoning->>'dedup_demoted_to_m2w')::boolean = true),
         (SELECT skip_count FROM agg_skipped),
         (SELECT payload   FROM agg_skipped)
  INTO v_auto_swaps, v_auto_m2w, v_skip_duplicate, v_skip_runway, v_skipped_swaps
  FROM pass2_inserted;
  SELECT COUNT(*) INTO v_skip_planned
    FROM public.machines_to_visit mtv
    JOIN public.slot_lifecycle sl ON sl.machine_id=mtv.machine_id
                                   AND sl.archived=false AND sl.is_current=true
                                   AND sl.signal IN ('DEAD — SWAP NOW','ROTATE OUT','WIND DOWN')
    JOIN _planned_swap_shelves pss ON pss.machine_id=sl.machine_id AND pss.shelf_id=sl.shelf_id
   WHERE mtv.plan_date=p_plan_date AND mtv.status IN ('picked','cs_added');
  SELECT COUNT(*) INTO v_skip_cooldown
    FROM public.machines_to_visit mtv
    JOIN public.slot_lifecycle sl ON sl.machine_id=mtv.machine_id
                                   AND sl.archived=false AND sl.is_current=true
                                   AND sl.signal IN ('DEAD — SWAP NOW','ROTATE OUT','WIND DOWN')
    JOIN _r5_removal_cooldown roc ON roc.machine_id=sl.machine_id AND roc.pod_product_id=sl.pod_product_id
   WHERE mtv.plan_date=p_plan_date AND mtv.status IN ('picked','cs_added');
  RETURN jsonb_build_object(
    'plan_date',p_plan_date, 'max_swaps_per_machine',p_max_swaps_per_machine,
    'min_pearson',p_min_pearson, 'days_cover',p_days_cover,
    'pass1_tag_swaps', v_tag_swaps, 'pass1_tag_m2w', v_tag_m2w,
    'pass2_autonomous_swaps', v_auto_swaps, 'pass2_autonomous_m2w', v_auto_m2w,
    'pass2_skipped_runway', v_skip_runway, 'pass2_skipped_planned_swap', v_skip_planned,
    'pass2_demoted_duplicates', v_skip_duplicate, 'skipped_swaps', v_skipped_swaps,
    'total_swaps', v_tag_swaps + v_auto_swaps, 'total_m2w', v_tag_m2w + v_auto_m2w,
    'skipped_cooldown', v_skip_cooldown, 'engine_version','v9_5_qty_live_shelf_stock',
    'duration_ms',(EXTRACT(EPOCH FROM (clock_timestamp()-v_t0))*1000)::int);
END;
$function$
