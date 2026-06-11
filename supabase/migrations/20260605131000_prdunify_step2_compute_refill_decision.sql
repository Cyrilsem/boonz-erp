-- PRD-UNIFY Step 2 (Dara design) — compute_refill_decision: ONE function, the only source of both
-- target_units AND final_score. Read-only / SECURITY INVOKER / STABLE. The engine uses it to set qty
-- (Step 3) and the card/RefillPlanningTab use it to render (Step 4/5). No competing verdict.
--
-- ALGEBRA (verbatim from PRD-UNIFY; Open-Q answers locked by CS in the goal):
--   stance          = COALESCE(local slot_lifecycle.signal, global lifecycle.signal, 'KEEP')   [Q4 local→global]
--   cover_mult/floor = the dials table (STAR 2.0/0.80 · DOUBLE DOWN 1.5/0.80 · KEEP GROWING 1.0/0.70 ·
--                      KEEP 1.0/0.60 · RAMPING 1.0/0.50 · WATCH 1.0/0.40 · WIND DOWN 1.0/0.00 ·
--                      ROTATE OUT/DEAD 0/0)
--   velocity        = 0.6·v7 + 0.4·v30   (slot_lifecycle; dosage)                              [Q1]
--   days_cover      = p_days_cover (default 7)                                                 [Q2]
--   velocity_target = velocity × days_cover × cover_mult
--   visual_target   = floor_pct × capacity
--   target_units    = LEAST(GREATEST(velocity_target, visual_target), capacity)
--                     EXCEPT WIND DOWN/ROTATE OUT/DEAD: LEAST(that, current_stock)  (drain; never refill up)
--   refill_qty      = GREATEST(target_units − current_stock, 0)
--   runway_days     = current_stock / NULLIF(velocity,0)
--   FINAL SCORE: demand_base = 4·u7d + 0.5·u15d (slot-level sales, == the card's existing Score);
--     stance_mult  = STAR/DD 1.5 · KEEP GROWING 1.2 · KEEP/RAMPING 1.0 · WATCH 0.8 · WIND DOWN 0.4 · ROTATE OUT/DEAD 0.1
--     placement_mult = global_w(💎1.2/📦1.0/🔻0.8) × local_w(👑1.2/✅1.0/🐕0.7/💀0.3)
--     urgency_mult = 1 + LEAST(0.5, GREATEST(0, (days_cover − runway_days)/days_cover))   (∞ runway → 1)
--     final_score  = ROUND(demand_base × stance_mult × placement_mult × urgency_mult, 1)
--
-- CODY verdict (design): ✅ Approve. Article 1 (single authority for target+score), Article 4
-- (read-only INVOKER — no writes, no GUC/role needed), Article 12 (forward-only new function), Article
-- 14 (no parallel table). Registered read-only in RPC_REGISTRY. Depends on v2 FIX-1 (aisle off-by-one) —
-- APPLIED (0/727 drift 2026-06-05), so numbers are trustworthy.
-- APPLY NOTHING — file for CS review.

CREATE OR REPLACE FUNCTION public.compute_refill_decision(
  p_machine_id uuid,
  p_shelf_id uuid,
  p_boonz_product_id uuid,
  p_days_cover integer DEFAULT 7
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $function$
DECLARE
  v_shelf_code   text;
  v_slot_name    text;
  v_pod_id       uuid;
  v_pod_local    uuid;
  v_pod_name     text;
  v_cap          int;
  v_current      int;
  v_signal_local text;
  v_signal_glob  text;
  v_stance       text;
  v7             numeric := 0;
  v30            numeric := 0;
  v30_glob       numeric := 0;
  v_trend        numeric := 0;
  v_velocity     numeric;
  v_cover_mult   numeric;
  v_floor_pct    numeric;
  v_vel_target   numeric;
  v_vis_target   numeric;
  v_target_pre   numeric;
  v_target_units int;
  v_refill       int;
  v_runway       numeric;
  v_u7d          numeric := 0;
  v_u15d         numeric := 0;
  v_demand_base  numeric;
  v_global_badge text;
  v_local_badge  text;
  v_stance_mult  numeric;
  v_global_w     numeric;
  v_local_w      numeric;
  v_place_mult   numeric;
  v_urgency      numeric;
  v_final        numeric;
BEGIN
  -- shelf -> slot_name (WEIMI 1-indexed slot the live view uses)
  SELECT sc.shelf_code, COALESCE(NULLIF(sc.max_capacity,0),0)
    INTO v_shelf_code, v_cap
  FROM public.shelf_configurations sc WHERE sc.shelf_id = p_shelf_id;
  IF v_shelf_code IS NOT NULL THEN
    v_slot_name := LEFT(v_shelf_code,1) || (SUBSTR(v_shelf_code,2)::int)::text;
  END IF;

  -- live stock for the shelf's slot (capacity, current)
  SELECT COALESCE(NULLIF(MAX(vls.max_stock),0), NULLIF(v_cap,0), 10)::int,
         COALESCE(MAX(vls.current_stock),0)::int
    INTO v_cap, v_current
  FROM public.v_live_shelf_stock vls
  WHERE vls.machine_id = p_machine_id AND vls.slot_name = v_slot_name;
  v_cap := COALESCE(v_cap, 10);
  v_current := COALESCE(v_current, 0);
  -- pod identity on the slot (uuid is not aggregable; take one)
  SELECT vls.pod_product_id INTO v_pod_id
  FROM public.v_live_shelf_stock vls
  WHERE vls.machine_id = p_machine_id AND vls.slot_name = v_slot_name AND vls.pod_product_id IS NOT NULL
  LIMIT 1;

  -- local stance + velocities from slot_lifecycle (preferred)
  SELECT sl.signal, COALESCE(sl.velocity_7d,0), COALESCE(sl.velocity_30d,0), COALESCE(sl.trend_component,0), sl.pod_product_id
    INTO v_signal_local, v7, v30, v_trend, v_pod_local
  FROM public.slot_lifecycle sl
  WHERE sl.machine_id = p_machine_id AND sl.shelf_id = p_shelf_id
    AND sl.is_current = true AND sl.archived = false
  LIMIT 1;

  v_pod_id := COALESCE(v_pod_local, v_pod_id);

  -- global lifecycle fallback (separate vars; used ONLY when there is no local row)
  SELECT g.signal, COALESCE(g.per_slot_avg_v30,0)
    INTO v_signal_glob, v30_glob
  FROM public.v_product_lifecycle_global_enriched g
  WHERE g.pod_product_id = v_pod_id
  LIMIT 1;

  IF v_signal_local IS NULL THEN        -- E7: no local lifecycle row -> global velocity, default stance KEEP
    v7 := 0;
    v30 := COALESCE(v30_glob, 0);
    v_trend := 0;
  END IF;

  v_stance := COALESCE(v_signal_local, v_signal_glob, 'KEEP');

  -- dosage velocity = recency-weighted blend (Q1)
  v_velocity := 0.6 * COALESCE(v7,0) + 0.4 * COALESCE(v30,0);

  -- dials (stance -> cover_mult / floor_pct)
  v_cover_mult := CASE v_stance
    WHEN 'STAR' THEN 2.0 WHEN 'DOUBLE DOWN' THEN 1.5
    WHEN 'KEEP GROWING' THEN 1.0 WHEN 'KEEP' THEN 1.0
    WHEN 'RAMPING' THEN 1.0 WHEN 'WATCH' THEN 1.0
    WHEN 'WIND DOWN' THEN 1.0
    WHEN 'ROTATE OUT' THEN 0 WHEN 'DEAD' THEN 0
    ELSE 1.0 END;
  v_floor_pct := CASE v_stance
    WHEN 'STAR' THEN 0.80 WHEN 'DOUBLE DOWN' THEN 0.80
    WHEN 'KEEP GROWING' THEN 0.70 WHEN 'KEEP' THEN 0.60
    WHEN 'RAMPING' THEN 0.50 WHEN 'WATCH' THEN 0.40
    WHEN 'WIND DOWN' THEN 0.00
    ELSE 0.00 END;

  v_vel_target := v_velocity * p_days_cover * v_cover_mult;
  v_vis_target := v_floor_pct * v_cap;
  v_target_pre := LEAST(GREATEST(v_vel_target, v_vis_target), v_cap::numeric);
  -- drain stances never refill up
  IF v_stance IN ('WIND DOWN','ROTATE OUT','DEAD') THEN
    v_target_pre := LEAST(v_target_pre, v_current::numeric);
  END IF;
  v_target_units := ROUND(v_target_pre)::int;
  v_refill := GREATEST(v_target_units - v_current, 0);
  v_runway := CASE WHEN v_velocity > 0 THEN ROUND(v_current / v_velocity, 1) ELSE NULL END;

  -- demand_base from slot-level recent sales (== the card's existing Score basis)
  SELECT
    COALESCE(SUM(sh.qty) FILTER (WHERE sh.transaction_date >= now() - interval '7 days'), 0),
    COALESCE(SUM(sh.qty) FILTER (WHERE sh.transaction_date >= now() - interval '15 days'), 0)
    INTO v_u7d, v_u15d
  FROM public.sales_history sh
  WHERE sh.machine_id = p_machine_id
    AND sh.delivery_status IN ('Success','Successful')
    AND CASE
          WHEN sh.goods_slot LIKE '0-A%' THEN 'A' || ((SUBSTRING(sh.goods_slot,4)::int)+1)::text
          WHEN sh.goods_slot LIKE '1-A%' THEN 'B' || ((SUBSTRING(sh.goods_slot,4)::int)+1)::text
          ELSE sh.goods_slot
        END = v_slot_name;
  v_demand_base := 4 * v_u7d + 0.5 * v_u15d;

  -- badges
  SELECT pp.pod_product_name INTO v_pod_name FROM public.pod_products pp WHERE pp.pod_product_id = v_pod_id;
  SELECT COALESCE(gps.global_status, '📦 Core Range') INTO v_global_badge
  FROM public.mv_global_product_scores gps
  WHERE LOWER(TRIM(gps.product)) = LOWER(TRIM(v_pod_name)) LIMIT 1;
  v_global_badge := COALESCE(v_global_badge, '📦 Core Range');
  v_local_badge := public.compute_local_role(v_demand_base, v_trend);

  -- final score modulators (Q5 weights)
  v_stance_mult := CASE v_stance
    WHEN 'STAR' THEN 1.5 WHEN 'DOUBLE DOWN' THEN 1.5
    WHEN 'KEEP GROWING' THEN 1.2
    WHEN 'KEEP' THEN 1.0 WHEN 'RAMPING' THEN 1.0
    WHEN 'WATCH' THEN 0.8
    WHEN 'WIND DOWN' THEN 0.4
    WHEN 'ROTATE OUT' THEN 0.1 WHEN 'DEAD' THEN 0.1
    ELSE 1.0 END;
  v_global_w := CASE
    WHEN v_global_badge LIKE '💎%' THEN 1.2
    WHEN v_global_badge LIKE '🔻%' THEN 0.8
    ELSE 1.0 END;
  v_local_w := CASE
    WHEN v_local_badge LIKE '👑%' THEN 1.2
    WHEN v_local_badge LIKE '🐕%' THEN 0.7
    WHEN v_local_badge LIKE '💀%' THEN 0.3
    ELSE 1.0 END;
  v_place_mult := v_global_w * v_local_w;
  v_urgency := 1 + LEAST(0.5, GREATEST(0,
                 (p_days_cover - COALESCE(v_runway, p_days_cover)) / NULLIF(p_days_cover,0)::numeric));
  v_final := ROUND(v_demand_base * v_stance_mult * v_place_mult * v_urgency, 1);

  RETURN jsonb_build_object(
    'stance',          v_stance,
    'cover_mult',      v_cover_mult,
    'floor_pct',       v_floor_pct,
    'velocity',        ROUND(v_velocity,3),
    'days_cover',      p_days_cover,
    'velocity_target', ROUND(v_vel_target,2),
    'visual_target',   ROUND(v_vis_target,2),
    'target_units',    v_target_units,
    'refill_qty',      v_refill,
    'runway_days',     v_runway,
    'global_badge',    v_global_badge,
    'local_badge',     v_local_badge,
    'units_7d',        v_u7d,
    'final_score',     v_final,
    'reasoning', jsonb_build_object(
      'demand_base',   v_demand_base,
      'stance_mult',   v_stance_mult,
      'placement_mult',v_place_mult,
      'global_w',      v_global_w,
      'local_w',       v_local_w,
      'urgency_mult',  ROUND(v_urgency,3),
      'units_15d',     v_u15d,
      'capacity',      v_cap,
      'current_stock', v_current,
      'velocity_7d',   v7,
      'velocity_30d',  v30,
      'pod_product_id',v_pod_id,
      'slot_name',     v_slot_name
    )
  );
END;
$function$;

-- read-only; safe to expose to the same roles that read the plan
GRANT EXECUTE ON FUNCTION public.compute_refill_decision(uuid,uuid,uuid,integer) TO anon, authenticated, service_role;
