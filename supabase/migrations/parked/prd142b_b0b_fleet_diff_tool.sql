-- PRD-142b Block B test tool (service_role only; no app or engine calls it). Runs the full-fleet before/after
-- draft-plan diff for a synthetic plan date with every include_in_refill machine picked, inside a sub-block that is
-- rolled back: machines_to_visit rows, pod_refills, pod_swaps, flag changes and (p_patch) the PRD-142b engine
-- bodies are all undone. Only the captured rows are written to strategy_engine_diff_runs. p_patch = true applies the
-- exact PRD-142b patch text (same as the migration files) between the two runs; p_patch = false compares two flag
-- sets on the live bodies.
CREATE OR REPLACE FUNCTION public.prd142b_fleet_diff(p_label text, p_patch boolean, p_flags_before jsonb, p_flags_after jsonb,
                                                      p_plan_date date DEFAULT '2026-11-29', p_setup text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '0'
AS $tool$
DECLARE d date := p_plan_date; v_old text; v_new text; v_find text; v_repl text; t record; v_err text; v_id bigint;
  a_old jsonb; w_old jsonb; r_old jsonb; s_old jsonb; a_new jsonb; w_new jsonb; r_new jsonb; s_new jsonb;
  t0 timestamptz := clock_timestamp();
BEGIN
  BEGIN
    IF EXISTS (SELECT 1 FROM machines_to_visit WHERE plan_date = d) OR EXISTS (SELECT 1 FROM pod_refills WHERE plan_date = d)
       OR EXISTS (SELECT 1 FROM pod_swaps WHERE plan_date = d) THEN
      RAISE EXCEPTION 'synthetic plan date % in use', d;
    END IF;
    INSERT INTO machines_to_visit (plan_date, machine_id, official_name, status, add_source)
    SELECT d, machine_id, official_name, 'cs_added', 'operator' FROM machines WHERE include_in_refill;
    IF p_setup IS NOT NULL THEN EXECUTE p_setup; END IF;
    UPDATE refill_settings SET setting_value = COALESCE(p_flags_before->'prd142_fill_depth_enabled', setting_value) WHERE setting_key = 'prd142_fill_depth_enabled';
    UPDATE refill_settings SET setting_value = COALESCE(p_flags_before->'prd142_swap_mode_enabled', setting_value) WHERE setting_key = 'prd142_swap_mode_enabled';
    UPDATE refill_settings SET setting_value = COALESCE(p_flags_before->'prd142_swap_guard_enabled', setting_value) WHERE setting_key = 'prd142_swap_guard_enabled';
    a_old := engine_add_pod(d, 14);
    w_old := engine_swap_pod(d, 2, 0.30, 14);
    r_old := (SELECT jsonb_agg(jsonb_build_array(m.official_name, pr.reasoning->>'shelf_code', pp.pod_product_name, pr.qty, pr.clamp_reason)
            ORDER BY m.official_name, pr.reasoning->>'shelf_code', pp.pod_product_name)
       FROM pod_refills pr JOIN machines m ON m.machine_id = pr.machine_id LEFT JOIN pod_products pp ON pp.pod_product_id = pr.pod_product_id
      WHERE pr.plan_date = d);
    s_old := (SELECT jsonb_agg(jsonb_build_array(m.official_name, sc.shelf_code, po.pod_product_name, pi.pod_product_name, ps.qty_out, ps.qty_in, ps.reason,
                                COALESCE(ps.reasoning->>'tagged_by', ps.reasoning->>'source'), ps.reasoning->>'resolved_as')
            ORDER BY m.official_name, sc.shelf_code, po.pod_product_name)
       FROM pod_swaps ps JOIN machines m ON m.machine_id = ps.machine_id LEFT JOIN shelf_configurations sc ON sc.shelf_id = ps.shelf_id
       LEFT JOIN pod_products po ON po.pod_product_id = ps.pod_product_id_out LEFT JOIN pod_products pi ON pi.pod_product_id = ps.pod_product_id_in
      WHERE ps.plan_date = d);
    FOR t IN SELECT c.relname FROM pg_class c WHERE c.relnamespace = pg_my_temp_schema() AND c.relkind = 'r' LOOP
      EXECUTE format('DROP TABLE pg_temp.%I', t.relname);
    END LOOP;
    IF p_patch THEN
    -- engine_add_pod fill_depth
  v_old := pg_get_functiondef('public.engine_add_pod(date,integer)'::regprocedure);
  v_new := v_old;
  v_find := $f$      LEAST(GREATEST(cv.cover_units, COALESCE(cv.driver_req_qty,0), CASE WHEN v_add_abs_floor$f$;
  v_repl := $r$      -- PRD-142b 5.5 item 2: fill_depth by confirmed posture (prd142_fill_depth_enabled; PROTECT_GROW and
      -- unconfirmed machines keep today's quantity). conservative = base stock only (cover_units, no driver,
      -- min-facing or niche top-up); minimum = only lanes at zero, to base stock; full and standard = today.
      CASE (SELECT pp.params->>'fill_depth' FROM public.v_machine_posture_params pp
             WHERE pp.machine_id = cv.machine_id AND pp.posture_applies
               AND public.prd142_setting_on('prd142_fill_depth_enabled', false))
        WHEN 'conservative' THEN LEAST(GREATEST(cv.cover_units, 0), GREATEST(cv.target_stock - cv.current_stock, 0))
        WHEN 'minimum' THEN CASE WHEN cv.current_stock = 0
                                 THEN LEAST(GREATEST(cv.cover_units, 0), GREATEST(cv.target_stock - cv.current_stock, 0))
                                 ELSE 0 END
        ELSE
      LEAST(GREATEST(cv.cover_units, COALESCE(cv.driver_req_qty,0), CASE WHEN v_add_abs_floor$r$;
  IF (length(v_new) - length(replace(v_new, v_find, ''))) / length(v_find) <> 1 THEN
    RAISE EXCEPTION 'PRD-142b guard: engine_add_pod fill_depth anchor 1 found % times', (length(v_new) - length(replace(v_new, v_find, ''))) / length(v_find);
  END IF;
  v_new := replace(v_new, v_find, v_repl);
  v_find := $f$            GREATEST(cv.target_stock - cv.current_stock, 0))                  AS need_raw$f$;
  v_repl := $r$            GREATEST(cv.target_stock - cv.current_stock, 0))
      END                                                                     AS need_raw$r$;
  IF (length(v_new) - length(replace(v_new, v_find, ''))) / length(v_find) <> 1 THEN
    RAISE EXCEPTION 'PRD-142b guard: engine_add_pod fill_depth anchor 2 found % times', (length(v_new) - length(replace(v_new, v_find, ''))) / length(v_find);
  END IF;
  v_new := replace(v_new, v_find, v_repl);
  IF v_new = v_old THEN RAISE EXCEPTION 'PRD-142b guard: engine_add_pod fill_depth unchanged'; END IF;
  EXECUTE v_new;
  -- engine_swap_pod posture hook and swap guard
  v_old := pg_get_functiondef('public.engine_swap_pod(date,integer,numeric,integer)'::regprocedure);
  v_new := v_old;
  v_find := $f$  HAVING COUNT(*) >= 3;
  WITH picked AS (SELECT mtv.machine_id FROM public.machines_to_visit mtv$f$;
  v_repl := $r$  HAVING COUNT(*) >= 3;

  -- ==== PRD-142b 5.5 items 3, 4 and 7: posture input block (read where strategic_machine_tags is read) ====
  -- Machine posture params bite only for a CS-confirmed posture other than PROTECT_GROW and only while
  -- prd142_swap_mode_enabled is true; the product-posture pool filter has the same flag. The swap guard
  -- (prd142_swap_guard_enabled, default true) never lets the engine propose removing a lane whose product sells
  -- at or above its fleet median velocity (IRIS-1070 Zigi); CS-approved strategic tags (Pass 1) are not guarded.
  CREATE TEMP TABLE _prd142_params ON COMMIT DROP AS
  SELECT pp.machine_id, pp.posture, pp.params, pp.shelf_overrides, m.venue_group, m.building_id
    FROM public.v_machine_posture_params pp JOIN public.machines m ON m.machine_id = pp.machine_id
   WHERE pp.posture_applies AND public.prd142_setting_on('prd142_swap_mode_enabled', false);
  -- swap_mode none: every pass skips the machine.
  INSERT INTO _swaps_disabled_machines (machine_id)
  SELECT machine_id FROM _prd142_params WHERE params->>'swap_mode' = 'none';
  CREATE TEMP TABLE _prd142_guard ON COMMIT DROP AS
  SELECT sl.machine_id, sl.shelf_id, 'fleet_median_guard'::text AS why
    FROM public.slot_lifecycle sl
    JOIN (SELECT pod_product_id, percentile_cont(0.5) WITHIN GROUP (ORDER BY velocity_30d) AS med
            FROM public.slot_lifecycle WHERE archived = false AND is_current = true AND velocity_30d > 0
           GROUP BY pod_product_id) fm ON fm.pod_product_id = sl.pod_product_id
   WHERE sl.archived = false AND sl.is_current = true AND sl.velocity_30d > 0 AND sl.velocity_30d >= fm.med
     AND public.prd142_setting_on('prd142_swap_guard_enabled', true)
  UNION
  SELECT p.machine_id, sc.shelf_id, 'shelf_override_lock'
    FROM _prd142_params p CROSS JOIN LATERAL jsonb_array_elements(p.shelf_overrides) o
    JOIN public.shelf_configurations sc ON sc.machine_id = p.machine_id AND sc.shelf_code = o->>'shelf_code'
   WHERE o->>'action' = 'lock';
  DELETE FROM public.pod_swaps ps USING _prd142_guard g
   WHERE ps.plan_date = p_plan_date AND ps.pod_product_id_in IS NULL
     AND ps.reasoning->>'tagged_by' LIKE 'engine_add_pod%'
     AND g.machine_id = ps.machine_id AND g.shelf_id = ps.shelf_id;
  -- swap_mode aggressive: lanes under 40% of the peer median (nightly machine_strategy.proposal_detail
  -- under_peer_lanes, same definition as the FIX_MIX diagnosis) join the dead-lane queue resolved by Pass 2a.
  DELETE FROM public.pod_swaps WHERE plan_date = p_plan_date AND pod_product_id_in IS NULL
     AND reasoning->>'tagged_by' = 'engine_add_pod_prd142_aggressive';
  INSERT INTO public.pod_swaps (plan_date, machine_id, shelf_id, pod_product_id_out, qty_out, reason, reasoning)
  SELECT p_plan_date, sl.machine_id, sl.shelf_id, sl.pod_product_id,
         GREATEST(COALESCE(sls.current_stock, 0), 1), 'rotate_out',
         jsonb_build_object('shelf_code', sc.shelf_code, 'official_name', m.official_name,
                            'tagged_by', 'engine_add_pod_prd142_aggressive', 'reason_detail', 'under_40pct_peer_median',
                            'posture', p.posture, 'velocity_30d', sl.velocity_30d)
    FROM _prd142_params p
    JOIN public.machine_strategy ms ON ms.machine_id = p.machine_id
    JOIN public.machines m ON m.machine_id = p.machine_id
    JOIN public.machines_to_visit mtv ON mtv.machine_id = p.machine_id AND mtv.plan_date = p_plan_date
                                     AND mtv.status IN ('picked','cs_added')
    CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(ms.proposal_detail->'under_peer_lanes', '[]'::jsonb)) ul(shelf_code)
    JOIN public.shelf_configurations sc ON sc.machine_id = p.machine_id AND sc.shelf_code = ul.shelf_code AND sc.is_phantom = false
    JOIN public.slot_lifecycle sl ON sl.machine_id = p.machine_id AND sl.shelf_id = sc.shelf_id
                                 AND sl.archived = false AND sl.is_current = true
    LEFT JOIN _shelf_live_stock sls ON sls.machine_id = sl.machine_id AND sls.shelf_id = sl.shelf_id
   WHERE p.params->>'swap_mode' = 'aggressive'
     AND NOT EXISTS (SELECT 1 FROM _prd142_guard g WHERE g.machine_id = sl.machine_id AND g.shelf_id = sl.shelf_id)
     AND NOT EXISTS (SELECT 1 FROM _binding_drift bd WHERE bd.machine_id = sl.machine_id AND bd.shelf_id = sl.shelf_id)
     AND NOT EXISTS (SELECT 1 FROM _committed_machines cm WHERE cm.machine_id = sl.machine_id)
     AND NOT EXISTS (SELECT 1 FROM _swaps_disabled_machines dm WHERE dm.machine_id = sl.machine_id)
     AND NOT EXISTS (SELECT 1 FROM _planned_swap_shelves pss WHERE pss.machine_id = sl.machine_id AND pss.shelf_id = sl.shelf_id)
     AND NOT EXISTS (SELECT 1 FROM _r5_removal_cooldown rc WHERE rc.machine_id = sl.machine_id AND rc.pod_product_id = sl.pod_product_id)
  ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id_out) DO NOTHING;
  -- Product posture in the swap pool (5.5 item 7): EXIT and DRAIN never added; RESOURCE only once the warehouse
  -- is stocked; GROW gets +1 priority on machines of its target archetypes.
  CREATE TEMP TABLE _prd142_pool_block ON COMMIT DROP AS
  SELECT ps.pod_product_id FROM public.product_strategy ps
   WHERE public.prd142_setting_on('prd142_swap_mode_enabled', false)
     AND (ps.posture IN ('EXIT', 'DRAIN')
          OR (ps.posture = 'RESOURCE' AND COALESCE((SELECT s.wh_status FROM public.product_supply_daily s
                                                     WHERE s.pod_product_id = ps.pod_product_id
                                                     ORDER BY s.d DESC LIMIT 1), 'none') <> 'stocked'));
  CREATE TEMP TABLE _prd142_grow ON COMMIT DROP AS
  SELECT ps.pod_product_id, unnest(ps.target_archetypes) AS archetype_code FROM public.product_strategy ps
   WHERE ps.posture = 'GROW' AND public.prd142_setting_on('prd142_swap_mode_enabled', false);
  -- allow_new_products false: the pool is limited to products live on the machine or its venue (venue_group or building).
  CREATE TEMP TABLE _prd142_venue_pods ON COMMIT DROP AS
  SELECT DISTINCT p.machine_id, sl.pod_product_id
    FROM _prd142_params p
    JOIN public.machines m2 ON m2.machine_id = p.machine_id
                           OR (p.venue_group IS NOT NULL AND m2.venue_group = p.venue_group)
                           OR (p.building_id IS NOT NULL AND m2.building_id = p.building_id)
    JOIN public.slot_lifecycle sl ON sl.machine_id = m2.machine_id AND sl.archived = false AND sl.is_current = true
   WHERE (p.params->>'allow_new_products')::boolean IS FALSE;
  -- ==== end PRD-142b input block ====
  WITH picked AS (SELECT mtv.machine_id FROM public.machines_to_visit mtv$r$;
  IF (length(v_new) - length(replace(v_new, v_find, ''))) / length(v_find) <> 1 THEN
    RAISE EXCEPTION 'PRD-142b guard: engine_swap_pod posture hook and swap guard anchor 1 found % times', (length(v_new) - length(replace(v_new, v_find, ''))) / length(v_find);
  END IF;
  v_new := replace(v_new, v_find, v_repl);
  v_find := $f$     WHERE sss.pod_in IS NULL
       AND (rss.is_size_up OR rc.pod_product_id IS NULL)
$f$;
  v_repl := $r$     WHERE sss.pod_in IS NULL
       AND (rss.is_size_up OR rc.pod_product_id IS NULL)
       -- PRD-142b: product-posture pool and allow_new_products.
       AND NOT EXISTS (SELECT 1 FROM _prd142_pool_block pb WHERE pb.pod_product_id = rss.pod_product_id)
       AND (rss.is_size_up
            OR NOT EXISTS (SELECT 1 FROM _prd142_params p WHERE p.machine_id = r.machine_id
                              AND (p.params->>'allow_new_products')::boolean IS FALSE)
            OR EXISTS (SELECT 1 FROM _prd142_venue_pods vp WHERE vp.machine_id = r.machine_id
                          AND vp.pod_product_id = rss.pod_product_id))
$r$;
  IF (length(v_new) - length(replace(v_new, v_find, ''))) / length(v_find) <> 1 THEN
    RAISE EXCEPTION 'PRD-142b guard: engine_swap_pod posture hook and swap guard anchor 2 found % times', (length(v_new) - length(replace(v_new, v_find, ''))) / length(v_find);
  END IF;
  v_new := replace(v_new, v_find, v_repl);
  v_find := $f$     ORDER BY rss.rank
     LIMIT 1;$f$;
  v_repl := $r$     ORDER BY rss.rank - CASE WHEN EXISTS (SELECT 1 FROM _prd142_grow g JOIN public.machine_strategy msg
                                             ON msg.archetype_code = g.archetype_code
                                          WHERE g.pod_product_id = rss.pod_product_id AND msg.machine_id = r.machine_id)
                              THEN 1 ELSE 0 END, rss.rank  -- PRD-142b: GROW +1 on target archetypes
     LIMIT 1;$r$;
  IF (length(v_new) - length(replace(v_new, v_find, ''))) / length(v_find) <> 1 THEN
    RAISE EXCEPTION 'PRD-142b guard: engine_swap_pod posture hook and swap guard anchor 3 found % times', (length(v_new) - length(replace(v_new, v_find, ''))) / length(v_find);
  END IF;
  v_new := replace(v_new, v_find, v_repl);
  v_find := $f$     AND NOT public._travel_scope_blocks(mk.machine_id, b.boonz);$f$;
  v_repl := $r$     AND NOT public._travel_scope_blocks(mk.machine_id, b.boonz)
     AND NOT EXISTS (SELECT 1 FROM _prd142_pool_block pb WHERE pb.pod_product_id = b.cand_pod);  -- PRD-142b$r$;
  IF (length(v_new) - length(replace(v_new, v_find, ''))) / length(v_find) <> 1 THEN
    RAISE EXCEPTION 'PRD-142b guard: engine_swap_pod posture hook and swap guard anchor 4 found % times', (length(v_new) - length(replace(v_new, v_find, ''))) / length(v_find);
  END IF;
  v_new := replace(v_new, v_find, v_repl);
  v_find := $f$     AND NOT EXISTS (SELECT 1 FROM _binding_drift bd
                      WHERE bd.machine_id = ranked.machine_id AND bd.shelf_id = ranked.shelf_id);$f$;
  v_repl := $r$     AND NOT EXISTS (SELECT 1 FROM _binding_drift bd
                      WHERE bd.machine_id = ranked.machine_id AND bd.shelf_id = ranked.shelf_id)
     AND NOT EXISTS (SELECT 1 FROM _prd142_guard g  -- PRD-142b swap guard
                      WHERE g.machine_id = ranked.machine_id AND g.shelf_id = ranked.shelf_id);$r$;
  IF (length(v_new) - length(replace(v_new, v_find, ''))) / length(v_find) <> 1 THEN
    RAISE EXCEPTION 'PRD-142b guard: engine_swap_pod posture hook and swap guard anchor 5 found % times', (length(v_new) - length(replace(v_new, v_find, ''))) / length(v_find);
  END IF;
  v_new := replace(v_new, v_find, v_repl);
  IF v_new = v_old THEN RAISE EXCEPTION 'PRD-142b guard: engine_swap_pod posture hook and swap guard unchanged'; END IF;
  EXECUTE v_new;
    END IF;
    UPDATE refill_settings SET setting_value = COALESCE(p_flags_after->'prd142_fill_depth_enabled', setting_value) WHERE setting_key = 'prd142_fill_depth_enabled';
    UPDATE refill_settings SET setting_value = COALESCE(p_flags_after->'prd142_swap_mode_enabled', setting_value) WHERE setting_key = 'prd142_swap_mode_enabled';
    UPDATE refill_settings SET setting_value = COALESCE(p_flags_after->'prd142_swap_guard_enabled', setting_value) WHERE setting_key = 'prd142_swap_guard_enabled';
    a_new := engine_add_pod(d, 14);
    w_new := engine_swap_pod(d, 2, 0.30, 14);
    r_new := (SELECT jsonb_agg(jsonb_build_array(m.official_name, pr.reasoning->>'shelf_code', pp.pod_product_name, pr.qty, pr.clamp_reason)
            ORDER BY m.official_name, pr.reasoning->>'shelf_code', pp.pod_product_name)
       FROM pod_refills pr JOIN machines m ON m.machine_id = pr.machine_id LEFT JOIN pod_products pp ON pp.pod_product_id = pr.pod_product_id
      WHERE pr.plan_date = d);
    s_new := (SELECT jsonb_agg(jsonb_build_array(m.official_name, sc.shelf_code, po.pod_product_name, pi.pod_product_name, ps.qty_out, ps.qty_in, ps.reason,
                                COALESCE(ps.reasoning->>'tagged_by', ps.reasoning->>'source'), ps.reasoning->>'resolved_as')
            ORDER BY m.official_name, sc.shelf_code, po.pod_product_name)
       FROM pod_swaps ps JOIN machines m ON m.machine_id = ps.machine_id LEFT JOIN shelf_configurations sc ON sc.shelf_id = ps.shelf_id
       LEFT JOIN pod_products po ON po.pod_product_id = ps.pod_product_id_out LEFT JOIN pod_products pi ON pi.pod_product_id = ps.pod_product_id_in
      WHERE ps.plan_date = d);
    RAISE EXCEPTION 'prd142b_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'prd142b_rollback' THEN v_err := SQLERRM; END IF;
  END;
  INSERT INTO strategy_engine_diff_runs (label, plan_date, duration_ms, error, flags, add_old, swap_old, refills_old, swaps_old,
                                         add_new, swap_new, refills_new, swaps_new)
  VALUES (p_label, d, (extract(epoch FROM clock_timestamp() - t0) * 1000)::int, v_err,
          jsonb_build_object('patch', p_patch, 'before', p_flags_before, 'after', p_flags_after, 'setup', p_setup),
          a_old - 'procurement_gaps', w_old, r_old, s_old, a_new - 'procurement_gaps', w_new, r_new, s_new)
  RETURNING run_id INTO v_id;
  RETURN v_id;
END
$tool$;
REVOKE EXECUTE ON FUNCTION public.prd142b_fleet_diff(text, boolean, jsonb, jsonb, date, text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prd142b_fleet_diff(text, boolean, jsonb, jsonb, date, text) TO service_role;
