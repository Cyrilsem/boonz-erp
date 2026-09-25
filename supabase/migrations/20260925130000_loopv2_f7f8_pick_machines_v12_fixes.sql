-- Loop 2026-09-25 (CS HOLD feedback F7-F8): pick_machines_v12 sales_saved and cluster fixes.
--
-- picker_config.picker_version stays 'shadow' throughout this migration; nothing here changes
-- which picker is authoritative.
--
-- F7 VISIT VALUE: confirmed live before writing anything. AMZ-1038-3001-O1 (daily revenue 228.98
-- AED, hero_runway_days 0.77, an empty top lane) had visit_value_aed=0 for 2026-09-27 under the
-- prior formula: sales_saved_aed = daily_revenue_aed * GREATEST(rhythm_days - runway_days, 0) /
-- rhythm_days. AMZ-1038's own machine-level runway_days (4.2, an average across every lane) sits
-- above its rhythm (3, top revenue tercile), so GREATEST(3 - 4.2, 0) = 0 regardless of how
-- urgent the single empty top lane actually is. The machine-level average masks the real per-lane
-- shortage. Same root cause for ADDMIND-1007-0000-W0 (runway_days 36.4 against rhythm 7 or 10).
--
-- Checked CS's netting hypothesis directly against the schema before ruling on it: no view or
-- table in this project computes a "stock after netting planned/unconfirmed dispatch" figure.
-- v_lane_grain and v_live_shelf_stock both read current_stock straight from the latest WEIMI
-- snapshot with no adjustment for refill_dispatching/refill_plan_output rows at all, confirmed by
-- reading both view definitions live. So same-day netting of in-progress plan 2026-09-25 is not
-- happening in this code path; the root cause is the machine-level runway_days formula above, not
-- netting. Recorded here rather than silently assumed.
--
-- Fix: sales_saved_aed is now computed per lane and summed, using each lane's own velocity and
-- current stock (no netting exists to apply, so stock_after_netting = the lane's own live
-- current_stock) against a per-machine horizon of GREATEST(rhythm_days, 3) days:
--   sales_saved_aed = SUM over lanes of GREATEST(0, lane_dvel * horizon_days - current_stock)
--                      * lane price_aed
-- Lane price comes from v_live_shelf_stock, joined on the same physical slot (machine_id +
-- slot_name), the same source pick_machines_v12 already uses for donor/receiver pricing.
--
-- F8 COSMETIC: root cause confirmed live: with_cluster tagged cluster_role='cluster' (and the
-- reasoned CTE then added the cluster reason) on ANY machine sharing a building with another
-- tiered machine, including machines that already independently qualify P1 or P2 on their own
-- merits (AMZ-1029, AMZ-1038, AMZ-1046 all did this for 2026-09-27/2026-09-25). That is
-- misleading: the machine's own reasons already fully explain the visit, and tagging it "cluster"
-- on top implies the building is why it was picked, when it was not. Fixed: cluster_role='cluster'
-- now only applies when the machine's own_tier is NOT P1 or P2 (i.e., its own merit alone is at
-- most a P3 ride-along need, or none, and it is being added specifically because the building is
-- already being visited). A machine that is independently P1/P2 never gets the cluster tag or
-- reason, matching "cluster applies only to machines added because of the building".

CREATE OR REPLACE FUNCTION public.pick_machines_v12(p_plan_date date, p_cap int DEFAULT 8)
 RETURNS TABLE(
   machine_id uuid, official_name text, tier text, visit_value_aed numeric,
   reasons text[], building_id text, cluster_role text, donor_for jsonb
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_cap int := COALESCE(p_cap, 8);
  v_today date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_is_vox_day boolean := EXTRACT(DOW FROM p_plan_date) IN (3, 5);
BEGIN
  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'pick_machines_v12: p_plan_date required'; END IF;
  IF v_cap < 1 THEN v_cap := 8; END IF;

  RETURN QUERY
  WITH base AS (
    SELECT mp.machine_id, mp.official_name, mp.venue_group, mp.building_id,
           mp.fill_pct, mp.empty_shelves_count, mp.days_since_visit,
           mp.daily_revenue_aed, mp.hero_runway_days, mp.runway_days
      FROM public.v_machine_priority mp
     WHERE mp.include_in_refill = true
       AND mp.machine_status NOT IN ('Warehouse','Inactive')
       AND mp.venue_group IS DISTINCT FROM 'LVLUP'
  ),
  revenue_p25 AS (
    SELECT percentile_cont(0.25) WITHIN GROUP (ORDER BY COALESCE(b.daily_revenue_aed,0)) AS p25
      FROM base b
  ),
  rhythm AS (
    SELECT b.machine_id, NTILE(3) OVER (ORDER BY COALESCE(b.daily_revenue_aed,0) DESC) AS tercile
      FROM base b
  ),
  rhythm_days AS (
    SELECT r.machine_id,
           CASE r.tercile
             WHEN 1 THEN (SELECT rhythm_days FROM public.pick_rhythm_params WHERE tier_label='top')
             WHEN 2 THEN (SELECT rhythm_days FROM public.pick_rhythm_params WHERE tier_label='mid')
             ELSE        (SELECT rhythm_days FROM public.pick_rhythm_params WHERE tier_label='slow')
           END AS rhythm_days
      FROM rhythm r
  ),
  -- F4: resolve each Active pod_inventory row to a pod_product_id (machine-scoped Active mapping
  -- overrides the global Active default, same pattern used throughout this loop), then require
  -- WEIMI to currently confirm that same pod product on that machine with stock > 0.
  pod_inv_resolved AS (
    SELECT pi.machine_id, pi.boonz_product_id, pi.current_stock, pi.expiration_date,
           (SELECT pm.pod_product_id FROM public.product_mapping pm
             WHERE pm.boonz_product_id = pi.boonz_product_id AND pm.status = 'Active'
               AND (pm.machine_id = pi.machine_id OR pm.machine_id IS NULL)
             ORDER BY (pm.machine_id = pi.machine_id) DESC NULLS LAST, pm.is_global_default DESC
             LIMIT 1) AS resolved_pod_product_id
      FROM public.pod_inventory pi
     WHERE pi.machine_id IN (SELECT machine_id FROM base)
       AND pi.status = 'Active' AND pi.current_stock > 0
  ),
  pod_inv_matched AS (
    SELECT pir.*,
           EXISTS (
             SELECT 1 FROM public.v_shelf_slot_identity ssi
              WHERE ssi.machine_id = pir.machine_id
                AND ssi.pod_product_id = pir.resolved_pod_product_id
                AND ssi.current_stock > 0
           ) AS weimi_confirms
      FROM pod_inv_resolved pir
  ),
  expiry AS (
    SELECT machine_id,
           bool_or(weimi_confirms AND expiration_date < v_today) AS has_expired_now,
           bool_or(weimi_confirms AND expiration_date <= p_plan_date) AS has_expiring_by_plan
      FROM pod_inv_matched
     GROUP BY machine_id
  ),
  -- F7: lane_all now also carries the physical slot's own price (from v_live_shelf_stock, same
  -- machine_id + slot_name grain used for the sales_saved sum below and already the pricing
  -- source for donor/receiver value elsewhere in this function).
  lane_all AS (
    SELECT lg.machine_id, lg.lane_id, lg.pod_product_id, lg.current_stock, lg.max_stock,
           lg.dos, lg.lane_dvel, lg.is_empty, lg.fill_ratio,
           COALESCE(vls.price_aed, 0) AS price_aed,
           ROW_NUMBER() OVER (PARTITION BY lg.machine_id ORDER BY lg.lane_dvel DESC NULLS LAST) AS velocity_rank
      FROM public.v_lane_grain lg
      LEFT JOIN public.v_live_shelf_stock vls
        ON vls.machine_id = lg.machine_id AND vls.slot_name = lg.lane_id
     WHERE lg.machine_id IN (SELECT machine_id FROM base)
  ),
  -- F7: per-lane shortage against a per-machine horizon (rhythm days, floored at 3), summed and
  -- priced per lane. No netting is applied because none exists anywhere upstream: current_stock is
  -- the live WEIMI figure, confirmed by reading v_lane_grain/v_live_shelf_stock's own definitions,
  -- so stock_after_netting is simply each lane's own current_stock.
  sales_saved_by_lane AS (
    SELECT la.machine_id,
           SUM(GREATEST(0, la.lane_dvel * GREATEST(COALESCE(rd.rhythm_days,7), 3) - la.current_stock)
               * la.price_aed) AS sales_saved_aed
      FROM lane_all la
      LEFT JOIN rhythm_days rd ON rd.machine_id = la.machine_id
     GROUP BY la.machine_id
  ),
  top2_trigger AS (
    SELECT machine_id, bool_or(is_empty OR COALESCE(dos,0) < 1) AS triggered
      FROM lane_all WHERE velocity_rank <= 2 GROUP BY machine_id
  ),
  -- F5: at least one real-velocity lane, required to let fill<50% count toward P1.
  has_active_lane AS (
    SELECT machine_id, bool_or(lane_dvel >= 0.3) AS has_lane_ge_03
      FROM lane_all GROUP BY machine_id
  ),
  lane_boonz AS (
    SELECT la.machine_id, la.lane_id, la.pod_product_id, la.lane_dvel, la.fill_ratio,
           la.current_stock, la.max_stock, pm.boonz_product_id
      FROM lane_all la
      JOIN public.product_mapping pm
        ON pm.pod_product_id = la.pod_product_id
       AND pm.status = 'Active'
       AND CASE WHEN EXISTS (
                  SELECT 1 FROM public.product_mapping pm2
                   WHERE pm2.pod_product_id = la.pod_product_id
                     AND pm2.status = 'Active'
                     AND pm2.machine_id = la.machine_id)
                THEN pm.machine_id = la.machine_id
                ELSE pm.is_global_default
           END
  ),
  triggers AS (
    SELECT b.*, rd.rhythm_days,
           COALESCE(e.has_expired_now,false) AS has_expired_now,
           COALESCE(e.has_expiring_by_plan,false) AS has_expiring_by_plan,
           COALESCE(t2.triggered,false) AS top2_lane_trigger,
           COALESCE(hal.has_lane_ge_03,false) AS has_lane_ge_03,
           (b.venue_group = 'VOX') AS is_vox
      FROM base b
      LEFT JOIN rhythm_days rd ON rd.machine_id = b.machine_id
      LEFT JOIN expiry e ON e.machine_id = b.machine_id
      LEFT JOIN top2_trigger t2 ON t2.machine_id = b.machine_id
      LEFT JOIN has_active_lane hal ON hal.machine_id = b.machine_id
  ),
  classified AS (
    SELECT tr.*,
      -- F5: fill<50% only counts toward P1 when the machine has real velocity and meaningful
      -- revenue; otherwise it is tracked separately (fill_low_downgraded) to feed P2 instead.
      (COALESCE(tr.fill_pct,100) < 50 AND tr.has_lane_ge_03
        AND COALESCE(tr.daily_revenue_aed,0) >= (SELECT p25 FROM revenue_p25)) AS fill_low_qualifies_p1,
      (COALESCE(tr.fill_pct,100) < 50 AND NOT (tr.has_lane_ge_03
        AND COALESCE(tr.daily_revenue_aed,0) >= (SELECT p25 FROM revenue_p25))) AS fill_low_downgraded
    FROM triggers tr
  ),
  classified2 AS (
    SELECT c.*,
      CASE
        WHEN c.is_vox THEN (c.has_expired_now OR c.has_expiring_by_plan OR COALESCE(c.hero_runway_days,999) <= 0)
        ELSE (c.has_expired_now OR c.has_expiring_by_plan OR c.top2_lane_trigger
              OR COALESCE(c.empty_shelves_count,0) >= 2 OR c.fill_low_qualifies_p1)
      END AS is_p1
    FROM classified c
  ),
  classified3 AS (
    SELECT c2.*,
      (NOT c2.is_p1
       AND (COALESCE(c2.days_since_visit,0) >= COALESCE(c2.rhythm_days,7)
            OR COALESCE(c2.hero_runway_days,999) < COALESCE(c2.rhythm_days,7)
            OR COALESCE(c2.empty_shelves_count,0) >= 1
            OR c2.fill_low_downgraded)
       AND (NOT c2.is_vox OR v_is_vox_day)
      ) AS is_p2
    FROM classified2 c2
  ),
  base_tier AS (
    SELECT c3.*,
      CASE WHEN c3.is_p1 THEN 'P1'
           WHEN c3.is_p2 THEN 'P2'
           WHEN COALESCE(c3.days_since_visit,0) > 1 THEN 'P3'
           ELSE NULL
      END AS own_tier
    FROM classified3 c3
  ),
  -- F3 donor tightening: (a) zero pickable at the donor's OWN primary warehouse, (b) velocity
  -- under 0.4/day AND WEIMI stock at least 4, (c) a receiver lane of the same pod product in the
  -- top quartile of FLEET velocity (all eligible lanes, not just same-product peers) with fill
  -- under 50%, (d) the receiver's own tier is P1 or P2.
  donor_pool AS (
    SELECT DISTINCT lb.machine_id AS donor_machine_id, lb.pod_product_id, lb.boonz_product_id,
           lb.lane_dvel, lb.current_stock AS donor_units
      FROM lane_boonz lb
      JOIN public.machines m ON m.machine_id = lb.machine_id
     WHERE lb.lane_dvel < 0.4
       AND lb.current_stock >= 4
       AND NOT EXISTS (
         SELECT 1 FROM public.v_wh_pickable wp
          WHERE wp.boonz_product_id = lb.boonz_product_id
            AND wp.warehouse_id = m.primary_warehouse_id
            AND (wp.reserved_for_machine_id IS NULL OR wp.reserved_for_machine_id = lb.machine_id)
       )
  ),
  receiver_pool AS (
    SELECT lb.machine_id AS receiver_machine_id, lb.pod_product_id,
           lb.fill_ratio, lb.current_stock, lb.max_stock,
           percent_rank() OVER (ORDER BY lb.lane_dvel) AS fleet_velocity_pctrank
      FROM lane_boonz lb
  ),
  receivers_qualified AS (
    SELECT rp.*
      FROM receiver_pool rp
      JOIN base_tier bt ON bt.machine_id = rp.receiver_machine_id
     WHERE rp.fleet_velocity_pctrank >= 0.75
       AND rp.fill_ratio < 0.5
       AND bt.own_tier IN ('P1','P2')
  ),
  donor_links AS (
    SELECT dp.donor_machine_id, dp.pod_product_id, dp.donor_units,
           rq.receiver_machine_id,
           GREATEST(rq.max_stock - rq.current_stock, 0) AS receiver_capacity,
           COALESCE(vls.price_aed, 0) AS receiver_price_aed
      FROM donor_pool dp
      JOIN receivers_qualified rq
        ON rq.pod_product_id = dp.pod_product_id AND rq.receiver_machine_id <> dp.donor_machine_id
      LEFT JOIN public.v_live_shelf_stock vls
        ON vls.machine_id = rq.receiver_machine_id AND vls.pod_product_id = rq.pod_product_id
  ),
  donor_value_dedup AS (
    SELECT DISTINCT ON (donor_machine_id, pod_product_id)
           donor_machine_id, pod_product_id, donor_units, receiver_capacity, receiver_price_aed
      FROM donor_links
     ORDER BY donor_machine_id, pod_product_id, receiver_price_aed DESC
  ),
  donor_agg AS (
    SELECT dvd.donor_machine_id,
           (SELECT jsonb_agg(DISTINCT jsonb_build_object('receiver_machine_id', dl.receiver_machine_id))
              FROM donor_links dl WHERE dl.donor_machine_id = dvd.donor_machine_id) AS donor_for,
           -- donor_value counts only units the receiver can actually take, never more than the
           -- donor actually holds.
           SUM(LEAST(dvd.donor_units, dvd.receiver_capacity) * dvd.receiver_price_aed) AS donor_value_aed
      FROM donor_value_dedup dvd
     GROUP BY dvd.donor_machine_id
  ),
  tiered AS (
    SELECT bt.*,
      da.donor_for, COALESCE(da.donor_value_aed,0) AS donor_value_aed,
      (da.donor_for IS NOT NULL) AS is_donor
    FROM base_tier bt
    LEFT JOIN donor_agg da ON da.donor_machine_id = bt.machine_id
  ),
  -- F2: tier comes ONLY from a machine's own merits (P1/P2/its own P3 ride-along need) or donor
  -- value. Cluster membership never manufactures or changes a tier; it only adds a label below.
  final_tier AS (
    SELECT t.*,
      CASE
        WHEN t.own_tier IN ('P1','P2') THEN t.own_tier
        WHEN t.is_donor THEN 'P3'
        WHEN t.own_tier = 'P3' THEN 'P3'
        ELSE NULL
      END AS tier
    FROM tiered t
  ),
  -- F8: cluster_role='cluster' only when the machine's OWN tier is not already P1 or P2 (its own
  -- merit is at most a P3 ride-along need, or none) AND it shares a real, non-null building_id
  -- with another machine that already has a tier. A machine that independently qualifies P1/P2
  -- never gets the cluster tag or reason: its own reasons already explain the visit, and the
  -- building is not why it was picked.
  with_cluster AS (
    SELECT f.*,
      CASE
        WHEN f.is_donor THEN 'donor'
        WHEN f.own_tier IS DISTINCT FROM 'P1' AND f.own_tier IS DISTINCT FROM 'P2'
             AND f.tier IS NOT NULL AND f.building_id IS NOT NULL
             AND EXISTS (
               SELECT 1 FROM final_tier f2
                WHERE f2.machine_id <> f.machine_id
                  AND f2.building_id = f.building_id
                  AND f2.tier IS NOT NULL
             )
        THEN 'cluster'
        ELSE NULL
      END AS cluster_role
    FROM final_tier f
  ),
  -- F7: sales_saved_aed now comes from the per-lane sum computed above, not a machine-level
  -- revenue/runway approximation.
  scored AS (
    SELECT w.*,
      ROUND(COALESCE(ssl.sales_saved_aed, 0), 2) AS sales_saved_aed,
      ROUND(COALESCE((
        SELECT SUM(pi.current_stock * COALESCE(vls.price_aed,0))
          FROM public.pod_inventory pi
          LEFT JOIN public.v_live_shelf_stock vls
            ON vls.machine_id = pi.machine_id
           AND vls.pod_product_id IN (
             SELECT pm.pod_product_id FROM public.product_mapping pm
              WHERE pm.boonz_product_id = pi.boonz_product_id AND pm.status='Active'
                AND (pm.machine_id = pi.machine_id OR pm.machine_id IS NULL)
              ORDER BY (pm.machine_id = pi.machine_id) DESC NULLS LAST, pm.is_global_default DESC
              LIMIT 1)
         WHERE pi.machine_id = w.machine_id AND pi.status='Active' AND pi.current_stock>0
           AND pi.expiration_date <= p_plan_date
      ),0), 2) AS expiry_avoided_aed
    FROM with_cluster w
    LEFT JOIN sales_saved_by_lane ssl ON ssl.machine_id = w.machine_id
  ),
  reasoned AS (
    SELECT s.*,
      (ARRAY[]::text[]
        || CASE WHEN s.has_expired_now THEN ARRAY['expired stock is physically on the shelf'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.has_expiring_by_plan AND NOT s.has_expired_now THEN ARRAY['a lot expires on or before the plan date and still has stock'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.is_vox AND s.is_p1 AND COALESCE(s.hero_runway_days,999) <= 0 THEN ARRAY['hero lane is empty'] ELSE ARRAY[]::text[] END
        || CASE WHEN NOT s.is_vox AND s.top2_lane_trigger THEN ARRAY['one of the top two lanes by velocity is empty or under a day of cover'] ELSE ARRAY[]::text[] END
        || CASE WHEN NOT s.is_vox AND COALESCE(s.empty_shelves_count,0) >= 2 AND s.is_p1 THEN ARRAY['two or more lanes are empty'] ELSE ARRAY[]::text[] END
        || CASE WHEN NOT s.is_vox AND s.fill_low_qualifies_p1 THEN ARRAY['overall fill is under 50 percent, with real velocity and revenue above the fleet 25th percentile'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.is_p2 AND COALESCE(s.days_since_visit,0) >= COALESCE(s.rhythm_days,7) THEN ARRAY[format('days since last visit (%s) has reached this machine''s rhythm (%s days)', s.days_since_visit, s.rhythm_days)] ELSE ARRAY[]::text[] END
        || CASE WHEN s.is_p2 AND COALESCE(s.hero_runway_days,999) < COALESCE(s.rhythm_days,7) THEN ARRAY['the hero lane will run out before the next scheduled visit'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.is_p2 AND COALESCE(s.empty_shelves_count,0) >= 1 THEN ARRAY['at least one lane is empty'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.is_p2 AND s.fill_low_downgraded THEN ARRAY['overall fill is under 50 percent (downgraded from P1: not enough velocity or revenue to justify a P1 visit on fill alone)'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.is_donor THEN ARRAY['this machine can donate slow stock to another machine that needs it'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.cluster_role = 'cluster' AND NOT s.is_donor THEN ARRAY['picked up as part of a building cluster with another machine already visited'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.tier = 'P3' AND s.cluster_role IS NULL THEN ARRAY['ride along candidate'] ELSE ARRAY[]::text[] END
      ) AS reasons
    FROM scored s
  ),
  counts AS (
    SELECT COUNT(*) FILTER (WHERE tier = 'P1') AS p1_count FROM reasoned WHERE tier IS NOT NULL
  ),
  ranked AS (
    SELECT r.*, c.p1_count,
      (COALESCE(r.sales_saved_aed,0) + COALESCE(r.expiry_avoided_aed,0) + COALESCE(r.donor_value_aed,0)) AS visit_value_aed,
      CASE WHEN r.tier <> 'P1' THEN
        ROW_NUMBER() OVER (
          PARTITION BY (r.tier <> 'P1')
          ORDER BY CASE WHEN r.tier = 'P2' THEN 1
                        WHEN r.tier = 'P3' AND r.cluster_role IN ('donor','cluster') THEN 2
                        ELSE 3 END,
                   (COALESCE(r.sales_saved_aed,0) + COALESCE(r.expiry_avoided_aed,0) + COALESCE(r.donor_value_aed,0)) DESC,
                   r.official_name
        )
      END AS non_p1_fill_order
    FROM reasoned r CROSS JOIN counts c
    WHERE r.tier IS NOT NULL
  )
  -- F1: the cap governs the WHOLE output. P1 is never trimmed; if P1 alone reaches or exceeds the
  -- cap, only P1 rows are returned and each gets a p1_overflow reason appended.
  SELECT rk.machine_id, rk.official_name, rk.tier, rk.visit_value_aed,
         CASE WHEN rk.tier = 'P1' AND rk.p1_count >= v_cap
              THEN rk.reasons || ARRAY['p1_overflow: cap exceeded, all P1 rows returned, no P2 or P3 filled']
              ELSE rk.reasons END AS reasons,
         rk.building_id, rk.cluster_role, rk.donor_for
    FROM ranked rk
   WHERE rk.tier = 'P1'
      OR (rk.p1_count < v_cap AND rk.non_p1_fill_order <= (v_cap - rk.p1_count))
   ORDER BY CASE rk.tier WHEN 'P1' THEN 1 WHEN 'P2' THEN 2 WHEN 'P3' THEN 3 ELSE 4 END, rk.visit_value_aed DESC;
END;
$function$;
