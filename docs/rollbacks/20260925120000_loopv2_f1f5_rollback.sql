-- Rollback capture for 20260925120000_loopv2_f1f5_pick_machines_v12_fixes.sql
-- Prior live body of pick_machines_v12 (the B2 version, before the F1-F5 HOLD-feedback fixes).

CREATE OR REPLACE FUNCTION public.pick_machines_v12(p_plan_date date, p_cap integer DEFAULT 8)
 RETURNS TABLE(machine_id uuid, official_name text, tier text, visit_value_aed numeric, reasons text[], building_id text, cluster_role text, donor_for jsonb)
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
    SELECT mp.machine_id, mp.official_name, mp.venue_group,
           mp.fill_pct, mp.empty_shelves_count, mp.days_since_visit,
           mp.daily_revenue_aed, mp.hero_runway_days, mp.runway_days,
           NULLIF(left(substring(mp.official_name from '^[A-Za-z]+-\d+-(\d+)-'), 2), '') AS building_code
      FROM public.v_machine_priority mp
     WHERE mp.include_in_refill = true
       AND mp.machine_status NOT IN ('Warehouse','Inactive')
       AND mp.venue_group IS DISTINCT FROM 'LVLUP'
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
  expiry AS (
    SELECT pi.machine_id,
           bool_or(pi.status='Active' AND pi.current_stock>0 AND pi.expiration_date < v_today) AS has_expired_now,
           bool_or(pi.status='Active' AND pi.current_stock>0 AND pi.expiration_date <= p_plan_date) AS has_expiring_by_plan,
           COALESCE(SUM(pi.current_stock) FILTER (
             WHERE pi.status='Active' AND pi.current_stock>0 AND pi.expiration_date <= p_plan_date
           ), 0) AS expiring_units
      FROM public.pod_inventory pi
     WHERE pi.machine_id IN (SELECT machine_id FROM base)
     GROUP BY pi.machine_id
  ),
  lane_all AS (
    SELECT lg.machine_id, lg.lane_id, lg.pod_product_id, lg.current_stock, lg.max_stock,
           lg.dos, lg.lane_dvel, lg.is_empty, lg.fill_ratio,
           ROW_NUMBER() OVER (PARTITION BY lg.machine_id ORDER BY lg.lane_dvel DESC NULLS LAST) AS velocity_rank
      FROM public.v_lane_grain lg
     WHERE lg.machine_id IN (SELECT machine_id FROM base)
  ),
  top2_trigger AS (
    SELECT machine_id, bool_or(is_empty OR COALESCE(dos,0) < 1) AS triggered
      FROM lane_all WHERE velocity_rank <= 2 GROUP BY machine_id
  ),
  lane_boonz AS (
    SELECT la.machine_id, la.lane_id, la.pod_product_id, la.lane_dvel, la.fill_ratio, la.current_stock,
           pm.boonz_product_id
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
  donor_pool AS (
    SELECT DISTINCT lb.machine_id AS donor_machine_id, lb.pod_product_id, lb.boonz_product_id,
           lb.lane_dvel, lb.current_stock AS donor_units
      FROM lane_boonz lb
     WHERE lb.lane_dvel < 0.4
       AND NOT EXISTS (SELECT 1 FROM public.v_wh_pickable wp WHERE wp.boonz_product_id = lb.boonz_product_id)
  ),
  receiver_pool AS (
    SELECT lb.machine_id AS receiver_machine_id, lb.pod_product_id, lb.boonz_product_id,
           lb.fill_ratio,
           percent_rank() OVER (PARTITION BY lb.pod_product_id ORDER BY lb.lane_dvel) AS velocity_pctrank
      FROM lane_boonz lb
  ),
  receivers_qualified AS (
    SELECT * FROM receiver_pool WHERE velocity_pctrank >= 0.75 AND fill_ratio < 0.5
  ),
  donor_links AS (
    SELECT dp.donor_machine_id, dp.pod_product_id, dp.donor_units,
           rq.receiver_machine_id,
           COALESCE(vls.price_aed, 0) AS receiver_price_aed
      FROM donor_pool dp
      JOIN receivers_qualified rq
        ON rq.pod_product_id = dp.pod_product_id AND rq.receiver_machine_id <> dp.donor_machine_id
      LEFT JOIN public.v_live_shelf_stock vls
        ON vls.machine_id = rq.receiver_machine_id AND vls.pod_product_id = rq.pod_product_id
  ),
  donor_value_dedup AS (
    SELECT DISTINCT ON (donor_machine_id, pod_product_id)
           donor_machine_id, pod_product_id, donor_units, receiver_price_aed
      FROM donor_links
     ORDER BY donor_machine_id, pod_product_id, receiver_price_aed DESC
  ),
  donor_agg AS (
    SELECT dvd.donor_machine_id,
           (SELECT jsonb_agg(DISTINCT jsonb_build_object('receiver_machine_id', dl.receiver_machine_id))
              FROM donor_links dl WHERE dl.donor_machine_id = dvd.donor_machine_id) AS donor_for,
           SUM(dvd.donor_units * dvd.receiver_price_aed) AS donor_value_aed
      FROM donor_value_dedup dvd
     GROUP BY dvd.donor_machine_id
  ),
  triggers AS (
    SELECT b.*, rd.rhythm_days,
           COALESCE(e.has_expired_now,false) AS has_expired_now,
           COALESCE(e.has_expiring_by_plan,false) AS has_expiring_by_plan,
           COALESCE(e.expiring_units,0) AS expiring_units,
           COALESCE(t2.triggered,false) AS top2_lane_trigger,
           (b.venue_group = 'VOX') AS is_vox
      FROM base b
      LEFT JOIN rhythm_days rd ON rd.machine_id = b.machine_id
      LEFT JOIN expiry e ON e.machine_id = b.machine_id
      LEFT JOIN top2_trigger t2 ON t2.machine_id = b.machine_id
  ),
  classified AS (
    SELECT tr.*,
      CASE
        WHEN tr.is_vox THEN (tr.has_expired_now OR tr.has_expiring_by_plan OR COALESCE(tr.hero_runway_days,999) <= 0)
        ELSE (tr.has_expired_now OR tr.has_expiring_by_plan OR tr.top2_lane_trigger
              OR COALESCE(tr.empty_shelves_count,0) >= 2 OR COALESCE(tr.fill_pct,100) < 50)
      END AS is_p1_raw
    FROM triggers tr
  ),
  classified2 AS (
    SELECT c.*, c.is_p1_raw AS is_p1,
      (NOT c.is_p1_raw
       AND (COALESCE(c.days_since_visit,0) >= COALESCE(c.rhythm_days,7)
            OR COALESCE(c.hero_runway_days,999) < COALESCE(c.rhythm_days,7)
            OR COALESCE(c.empty_shelves_count,0) >= 1)
       AND (NOT c.is_vox OR v_is_vox_day)
      ) AS is_p2
    FROM classified c
  ),
  base_tier AS (
    SELECT c2.*,
      CASE WHEN c2.is_p1 THEN 'P1'
           WHEN c2.is_p2 THEN 'P2'
           WHEN COALESCE(c2.days_since_visit,0) > 1 THEN 'P3'
           ELSE NULL
      END AS own_tier
    FROM classified2 c2
  ),
  seeded_buildings AS (
    SELECT DISTINCT building_code
      FROM base_tier
     WHERE own_tier IN ('P1','P2') AND building_code IS NOT NULL
  ),
  tiered AS (
    SELECT bt.*,
      da.donor_for, COALESCE(da.donor_value_aed,0) AS donor_value_aed,
      (da.donor_for IS NOT NULL) AS is_donor,
      (bt.own_tier IS NULL AND bt.building_code IS NOT NULL
        AND bt.building_code IN (SELECT building_code FROM seeded_buildings)) AS is_cluster_pullin
    FROM base_tier bt
    LEFT JOIN donor_agg da ON da.donor_machine_id = bt.machine_id
  ),
  final_tier AS (
    SELECT t.*,
      CASE
        WHEN t.own_tier IN ('P1','P2') THEN t.own_tier
        WHEN t.is_donor THEN 'P3'
        WHEN t.is_cluster_pullin THEN 'P3'
        WHEN t.own_tier = 'P3' THEN 'P3'
        ELSE NULL
      END AS tier,
      CASE
        WHEN t.is_donor THEN 'donor'
        WHEN t.is_cluster_pullin THEN 'cluster'
        WHEN t.own_tier IS NOT NULL AND t.building_code IN (SELECT building_code FROM seeded_buildings) THEN 'cluster'
        ELSE NULL
      END AS cluster_role
    FROM tiered t
  ),
  scored AS (
    SELECT f.*,
      ROUND(COALESCE(f.daily_revenue_aed,0)
            * GREATEST(COALESCE(f.rhythm_days,7) - COALESCE(f.runway_days,0), 0)
            / GREATEST(COALESCE(f.rhythm_days,7),1), 2) AS sales_saved_aed,
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
         WHERE pi.machine_id = f.machine_id AND pi.status='Active' AND pi.current_stock>0
           AND pi.expiration_date <= p_plan_date
      ),0), 2) AS expiry_avoided_aed
    FROM final_tier f
  ),
  reasoned AS (
    SELECT s.*,
      (ARRAY[]::text[]
        || CASE WHEN s.has_expired_now THEN ARRAY['expired stock is physically on the shelf'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.has_expiring_by_plan AND NOT s.has_expired_now THEN ARRAY['a lot expires on or before the plan date and still has stock'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.is_vox AND s.is_p1 AND COALESCE(s.hero_runway_days,999) <= 0 THEN ARRAY['hero lane is empty'] ELSE ARRAY[]::text[] END
        || CASE WHEN NOT s.is_vox AND s.top2_lane_trigger THEN ARRAY['one of the top two lanes by velocity is empty or under a day of cover'] ELSE ARRAY[]::text[] END
        || CASE WHEN NOT s.is_vox AND COALESCE(s.empty_shelves_count,0) >= 2 AND s.is_p1 THEN ARRAY['two or more lanes are empty'] ELSE ARRAY[]::text[] END
        || CASE WHEN NOT s.is_vox AND COALESCE(s.fill_pct,100) < 50 AND s.is_p1 THEN ARRAY['overall fill is under 50 percent'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.is_p2 AND COALESCE(s.days_since_visit,0) >= COALESCE(s.rhythm_days,7) THEN ARRAY[format('days since last visit (%s) has reached this machine''s rhythm (%s days)', s.days_since_visit, s.rhythm_days)] ELSE ARRAY[]::text[] END
        || CASE WHEN s.is_p2 AND COALESCE(s.hero_runway_days,999) < COALESCE(s.rhythm_days,7) THEN ARRAY['the hero lane will run out before the next scheduled visit'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.is_p2 AND COALESCE(s.empty_shelves_count,0) >= 1 THEN ARRAY['at least one lane is empty'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.is_donor THEN ARRAY['this machine can donate slow stock to another machine that needs it'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.cluster_role = 'cluster' AND NOT s.is_donor THEN ARRAY['picked up as part of a building cluster with another machine already visited'] ELSE ARRAY[]::text[] END
        || CASE WHEN s.tier = 'P3' AND s.cluster_role IS NULL THEN ARRAY['ride along candidate'] ELSE ARRAY[]::text[] END
      ) AS reasons
    FROM scored s
  ),
  ranked AS (
    SELECT r.*,
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
    FROM reasoned r
    WHERE r.tier IS NOT NULL
  )
  SELECT rk.machine_id, rk.official_name, rk.tier, rk.visit_value_aed, rk.reasons,
         rk.building_code, rk.cluster_role, rk.donor_for
    FROM ranked rk
   WHERE rk.tier = 'P1' OR rk.non_p1_fill_order <= v_cap
   ORDER BY CASE rk.tier WHEN 'P1' THEN 1 WHEN 'P2' THEN 2 WHEN 'P3' THEN 3 ELSE 4 END, rk.visit_value_aed DESC;
END;
$function$;
