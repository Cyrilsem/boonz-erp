-- PRD-106 — Machine-level swap recommender (read-only, additive).
-- Returns K DISTINCT, warehouse-backed, in-machine-deduped swap-ins for a machine's
-- K dead/swap-tagged shelves, replacing the per-shelf substitute framing.
--
-- Read-only: LANGUAGE plpgsql STABLE, invoker rights (mirrors rank_slot_suitability).
-- No INSERT/UPDATE/DELETE. Consumed by engine_swap_pod (SECURITY DEFINER) and callable
-- by FE for preview. Reuses proven building blocks: v_wh_pickable aggregated by
-- boonz_product_id FIRST (dedup — never join product_mapping before aggregating),
-- product_size_fit (PRD-042 size compat), correlation via get_candidate_affinity,
-- strategic_intents decommission filter, _coexistence_blocks / _travel_scope_blocks.
--
-- Exclusions (candidate universe): in-machine pods (unless DOUBLE DOWN stance on an
-- existing facing), active decommission intents, Evian 1L (standing rule), venue_team
-- (VOX-sourced) pods on non-VOX machines, catch-alls, coexistence/travel-scope blocks,
-- and size-incompatible pods per shelf. wh_available scoped to the machine's routed WHs.
--
-- Scoring: rank_score = GREATEST(basket_corr, 0.30) * ln(1 + fleet_units_30d)
--                       * availability_factor, where availability_factor = 0 when
--          wh_available < the shelf's merchandising floor (min_refill_qty), else
--          1 + FEFO boost (0.25 if a pickable batch expires within expiry_risk_days).
-- Assignment: shelves ranked by capacity (value) desc; greedy top DISTINCT candidate
--          per shelf, no pod repeated across the K rows. qty_suggested = min(cap, wh).
-- No-candidate: in_pod NULL, qty 0, rationale.reason='no_viable_swap_candidate'
--          (M2W is NEVER emitted here — CS rule 2026-07-28; the caller raises the alert).

DROP FUNCTION IF EXISTS public.recommend_swaps_for_machine(date, uuid, integer);

CREATE OR REPLACE FUNCTION public.recommend_swaps_for_machine(
  p_plan_date date,
  p_machine_id uuid,
  p_k integer DEFAULT NULL
)
RETURNS TABLE(
  shelf_id uuid, shelf_code text, out_pod_product_id uuid, pod_name text,
  in_pod_product_id uuid, in_pod_name text, qty_suggested integer,
  rank_score numeric, wh_available integer, rationale jsonb
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_venue      text;
  v_whs        uuid[];
  v_expiry_days int;
  v_used       uuid[] := '{}';
  v_shelf      record;
  v_cand       record;
  v_k_eff      int;
BEGIN
  SELECT m.venue_group,
         ARRAY(SELECT w FROM (VALUES (m.primary_warehouse_id),(m.secondary_warehouse_id)) t(w) WHERE w IS NOT NULL)
    INTO v_venue, v_whs
    FROM public.machines m WHERE m.machine_id = p_machine_id;
  IF v_whs IS NULL OR array_length(v_whs,1) IS NULL THEN
    v_whs := ARRAY['4bebef68-9e36-4a5c-9c2c-142f8dbdae85'::uuid]; -- WH_CENTRAL fallback
  END IF;
  v_expiry_days := COALESCE((SELECT expiry_risk_days FROM public.refill_policy_params ORDER BY id LIMIT 1), 7);

  -- Dead / swap-tagged shelves for this machine+plan_date (unresolved: pod_product_id_in IS NULL),
  -- ordered by shelf value (capacity desc); K defaults to the count of them.
  FOR v_shelf IN
    SELECT ps.shelf_id,
           (SELECT sc.shelf_code FROM public.shelf_configurations sc WHERE sc.shelf_id = ps.shelf_id LIMIT 1) AS shelf_code,
           (SELECT sc.shelf_size FROM public.shelf_configurations sc WHERE sc.shelf_id = ps.shelf_id LIMIT 1) AS shelf_size,
           ps.pod_product_id_out AS out_pod,
           (SELECT pp.pod_product_name FROM public.pod_products pp WHERE pp.pod_product_id = ps.pod_product_id_out) AS out_name,
           GREATEST(COALESCE((SELECT MAX(sms.max_stock_weimi) FROM public.v_shelf_max_stock sms WHERE sms.shelf_id = ps.shelf_id), 8), 1) AS cap
      FROM public.pod_swaps ps
     WHERE ps.plan_date = p_plan_date
       AND ps.machine_id = p_machine_id
       AND ps.pod_product_id_in IS NULL
       AND ps.reason IN ('dead','rotate_out')
       AND ps.reasoning->>'tagged_by' LIKE 'engine_add_pod%'
     ORDER BY GREATEST(COALESCE((SELECT MAX(sms.max_stock_weimi) FROM public.v_shelf_max_stock sms WHERE sms.shelf_id = ps.shelf_id), 8), 1) DESC,
              (SELECT sc.shelf_code FROM public.shelf_configurations sc WHERE sc.shelf_id = ps.shelf_id LIMIT 1)
     LIMIT COALESCE(p_k, 2147483647)
  LOOP
    -- Best DISTINCT candidate for this shelf, excluding already-assigned pods (v_used).
    SELECT * INTO v_cand FROM (
      WITH present AS (
        SELECT DISTINCT pid AS pod_product_id FROM (
          SELECT sl.pod_product_id AS pid FROM public.slot_lifecycle sl
            WHERE sl.machine_id = p_machine_id AND sl.archived = false AND sl.is_current = true
          UNION
          SELECT vls.pod_product_id FROM public.v_live_shelf_stock vls
            WHERE vls.machine_id = p_machine_id AND vls.pod_product_id IS NOT NULL AND vls.current_stock > 0
        ) u WHERE pid IS NOT NULL
      ),
      dd AS (  -- in-machine pods with an existing DOUBLE DOWN facing (2nd-facing exception)
        SELECT DISTINCT sl.pod_product_id FROM public.slot_lifecycle sl
         WHERE sl.machine_id = p_machine_id AND sl.archived = false AND sl.is_current = true
           AND sl.signal = 'DOUBLE DOWN'
      ),
      wh_by_boonz AS (
        SELECT vp.boonz_product_id, SUM(vp.warehouse_stock)::int AS wh_units,
               MIN(vp.expiration_date) FILTER (WHERE vp.expiration_date IS NOT NULL) AS nearest_exp
          FROM public.v_wh_pickable vp
         WHERE vp.warehouse_id = ANY(v_whs)
           AND (vp.reserved_for_machine_id IS NULL OR vp.reserved_for_machine_id = p_machine_id)
         GROUP BY vp.boonz_product_id
      ),
      pod_boonz AS (
        SELECT DISTINCT ON (pm.pod_product_id) pm.pod_product_id, pm.boonz_product_id
          FROM public.product_mapping pm
         WHERE pm.status = 'Active' AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)
         ORDER BY pm.pod_product_id, (pm.machine_id = p_machine_id) DESC NULLS LAST,
                  pm.is_global_default DESC, pm.updated_at DESC
      ),
      fleet_vel AS (
        SELECT sl.pod_product_id, SUM(COALESCE(sl.velocity_30d,0)) * 30 AS fleet_units_30d
          FROM public.slot_lifecycle sl WHERE sl.archived = false AND sl.is_current = true
         GROUP BY sl.pod_product_id
      )
      SELECT pp.pod_product_id, pp.pod_product_name, pb.boonz_product_id,
             w.wh_units, COALESCE(fv.fleet_units_30d,0) AS fleet_units_30d,
             COALESCE(sf.min_refill_qty, CEIL(0.7*sf.cap_typical), 1)::int AS min_qty_eff,
             GREATEST(public.get_candidate_affinity(p_machine_id, pp.pod_product_id), 0.30) AS basket_corr,
             (CASE WHEN w.nearest_exp IS NOT NULL AND w.nearest_exp <= ((now() AT TIME ZONE 'Asia/Dubai')::date + v_expiry_days)
                   THEN 1.25 ELSE 1.0 END) AS avail_factor
        FROM public.pod_products pp
        JOIN pod_boonz pb ON pb.pod_product_id = pp.pod_product_id
        JOIN wh_by_boonz w ON w.boonz_product_id = pb.boonz_product_id AND w.wh_units > 0
        JOIN public.product_size_fit sf
          ON sf.pod_product_id = pp.pod_product_id AND sf.shelf_size = v_shelf.shelf_size AND sf.fits = true
        LEFT JOIN fleet_vel fv ON fv.pod_product_id = pp.pod_product_id
       WHERE COALESCE(pp.is_catchall,false) = false
         AND pp.pod_product_id <> ALL(v_used)
         AND (pp.pod_product_id NOT IN (SELECT pod_product_id FROM present)
              OR pp.pod_product_id IN (SELECT pod_product_id FROM dd))
         AND pp.pod_product_id <> '990461ff-ff92-4b3f-aedb-cde0e951aaf8'::uuid   -- Evian 1L standing rule
         AND w.wh_units >= COALESCE(sf.min_refill_qty, CEIL(0.7*sf.cap_typical), 1)
         AND NOT EXISTS (SELECT 1 FROM public.strategic_intents si
                          WHERE si.intent_type = 'decommission' AND si.status IN ('queued','in_progress')
                            AND si.scope_pod_product_id = pp.pod_product_id)
         AND NOT (v_venue <> 'VOX' AND EXISTS (SELECT 1 FROM public.product_mapping pm2
                          WHERE pm2.pod_product_id = pp.pod_product_id AND pm2.status = 'Active'
                            AND pm2.source_of_supply = 'venue_team'))
         AND NOT public._coexistence_blocks(p_machine_id, pb.boonz_product_id)
         AND NOT public._travel_scope_blocks(p_machine_id, pb.boonz_product_id)
       ORDER BY (GREATEST(public.get_candidate_affinity(p_machine_id, pp.pod_product_id), 0.30)
                 * ln(1 + COALESCE(fv.fleet_units_30d,0))
                 * (CASE WHEN w.nearest_exp IS NOT NULL AND w.nearest_exp <= ((now() AT TIME ZONE 'Asia/Dubai')::date + v_expiry_days)
                         THEN 1.25 ELSE 1.0 END)) DESC,
                w.wh_units DESC, pp.pod_product_id
       LIMIT 1
    ) c;

    IF v_cand.pod_product_id IS NOT NULL THEN
      v_used := v_used || v_cand.pod_product_id;
      shelf_id           := v_shelf.shelf_id;
      shelf_code         := v_shelf.shelf_code;
      out_pod_product_id := v_shelf.out_pod;
      pod_name           := v_shelf.out_name;
      in_pod_product_id  := v_cand.pod_product_id;
      in_pod_name        := v_cand.pod_product_name;
      qty_suggested      := LEAST(v_shelf.cap, v_cand.wh_units);
      rank_score         := ROUND((v_cand.basket_corr * ln(1 + v_cand.fleet_units_30d) * v_cand.avail_factor)::numeric, 3);
      wh_available       := v_cand.wh_units;
      rationale := jsonb_build_object(
        'source','recommend_swaps_for_machine',
        'basket_corr', ROUND(v_cand.basket_corr,4),
        'fleet_units_30d', ROUND(v_cand.fleet_units_30d,2),
        'availability_factor', v_cand.avail_factor,
        'wh_available', v_cand.wh_units,
        'min_floor', v_cand.min_qty_eff,
        'boonz_product_id', v_cand.boonz_product_id,
        'shelf_size', v_shelf.shelf_size,
        'shelf_cap', v_shelf.cap);
      RETURN NEXT;
    ELSE
      shelf_id           := v_shelf.shelf_id;
      shelf_code         := v_shelf.shelf_code;
      out_pod_product_id := v_shelf.out_pod;
      pod_name           := v_shelf.out_name;
      in_pod_product_id  := NULL;
      in_pod_name        := NULL;
      qty_suggested      := 0;
      rank_score         := NULL;
      wh_available       := 0;
      rationale := jsonb_build_object(
        'source','recommend_swaps_for_machine',
        'reason','no_viable_swap_candidate',
        'shelf_size', v_shelf.shelf_size,
        'note','no in-stock, size-fit, non-in-machine candidate cleared the merchandising floor');
      RETURN NEXT;
    END IF;
  END LOOP;

  RETURN;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.recommend_swaps_for_machine(date, uuid, integer)
  TO anon, authenticated, service_role;
