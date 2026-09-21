-- PRD-129 step 03: compute_refill_decision computed v_u7d/v_u15d from a raw sales_history
-- query matched by PHYSICAL SLOT POSITION (a goods_slot string transform compared to
-- v_slot_name), not by product identity. A slot that changed products still counted the
-- PREVIOUS product's recent sales as if they belonged to the current one -- the same slot-bleed
-- defect class already fixed for the lane-sales lookup and the expiry resolution. Live example:
-- decision.units_7d reported 18 for a lane where the identity-resolved figure
-- (v_shelf_sales_identity) is 14.
--
-- Fix: v_u7d/v_u15d now resolve through v_sales_history_resolved (PRD-129 step 02's set-based
-- rewrite), filtered on the lane's own pod_product_id (v_pod_id, already resolved earlier in
-- this function from v_live_shelf_stock / slot_lifecycle) -- the same identity path
-- v_shelf_sales_identity uses, not a slot-string match. The goods_slot CASE WHEN transform is
-- deleted entirely.
--
-- Facings correction (found during verification, not in the original spec): a first version of
-- this fix summed v_sales_history_resolved directly by pod_product_id with no facings division.
-- v_shelf_sales_identity.units_7d is itself a MACHINE-TOTAL for that pod_product_id -- when a
-- product occupies multiple physical slots (e.g. Aquafina across 11 slots on
-- ACTIVATE-2005-0000-W0), every one of those slots was getting the same whole-machine total
-- instead of a per-lane share, inflating final_score by roughly the facings count. This is
-- exactly the artifact Goal C's lane_sales CTE (20260920180000_fix_lane_sales_pod_product_id_key)
-- already guards against by dividing vsi.units_7d by vsi.facings for the lane-detail table.
-- Applying the identical fix here: v_u7d/v_u15d are now the machine-total divided by v_facings
-- (count of this machine's currently live, enabled, non-broken, eligible shelves holding the
-- same canonical pod_product_id -- same filter shape as v_shelf_sales_identity's own shelf CTE),
-- with the pod_alias canonicalization (168aeb7e -> 51e4600f, the old/current Hunter pair) applied
-- on both sides so the count and the sum agree on identity the same way v_shelf_sales_identity
-- does internally. AMZ-1038 A6 has facings=1, so this is a no-op there (14/1 = 14, matching P5).
--
-- SCOPE, confirmed by reading the full function body before writing this migration: v_u7d/v_u15d
-- feed ONLY v_demand_base (v_demand_base := 4 * v_u7d + 0.5 * v_u15d), which feeds ONLY v_final
-- and v_local_badge. target_units/refill_qty derive from v_velocity, itself from
-- slot_lifecycle.velocity_7d/velocity_30d (v7/v30) -- an entirely separate path, untouched by
-- this change. final_score (v_final) may move; target_units/refill_qty must not, and the
-- fleetwide diff against the pre-change snapshot (public._prd129_before_snapshot) confirms this
-- (see verification notes for the exact count).

CREATE OR REPLACE FUNCTION public.compute_refill_decision(p_machine_id uuid, p_shelf_id uuid, p_boonz_product_id uuid, p_days_cover integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
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
  v_pod_canon    uuid;
  v_facings      int;
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
  SELECT sc.shelf_code, COALESCE(NULLIF(sc.max_capacity,0),0)
    INTO v_shelf_code, v_cap
  FROM public.shelf_configurations sc WHERE sc.shelf_id = p_shelf_id;
  IF v_shelf_code IS NOT NULL THEN
    v_slot_name := LEFT(v_shelf_code,1) || (SUBSTR(v_shelf_code,2)::int)::text;
  END IF;

  SELECT COALESCE(NULLIF(MAX(vls.max_stock),0), NULLIF(v_cap,0), 10)::int,
         COALESCE(MAX(vls.current_stock),0)::int
    INTO v_cap, v_current
  FROM public.v_live_shelf_stock vls
  WHERE vls.machine_id = p_machine_id AND vls.slot_name = v_slot_name;
  v_cap := COALESCE(v_cap, 10);
  v_current := COALESCE(v_current, 0);
  SELECT vls.pod_product_id INTO v_pod_id
  FROM public.v_live_shelf_stock vls
  WHERE vls.machine_id = p_machine_id AND vls.slot_name = v_slot_name AND vls.pod_product_id IS NOT NULL
  LIMIT 1;

  SELECT sl.signal, COALESCE(sl.velocity_7d,0), COALESCE(sl.velocity_30d,0), COALESCE(sl.trend_component,0), sl.pod_product_id
    INTO v_signal_local, v7, v30, v_trend, v_pod_local
  FROM public.slot_lifecycle sl
  WHERE sl.machine_id = p_machine_id AND sl.shelf_id = p_shelf_id
    AND sl.is_current = true AND sl.archived = false
  LIMIT 1;

  v_pod_id := COALESCE(v_pod_local, v_pod_id);

  SELECT g.signal, COALESCE(g.per_slot_avg_v30,0)
    INTO v_signal_glob, v30_glob
  FROM public.v_product_lifecycle_global_enriched g
  WHERE g.pod_product_id = v_pod_id
  LIMIT 1;

  IF v_signal_local IS NULL THEN
    v7 := 0;
    v30 := COALESCE(v30_glob, 0);
    v_trend := 0;
  END IF;

  v_stance := COALESCE(v_signal_local, v_signal_glob, 'KEEP');

  v_velocity := 0.6 * COALESCE(v7,0) + 0.4 * COALESCE(v30,0);

  v_cover_mult := CASE v_stance
    WHEN 'STAR' THEN 2.0 WHEN 'DOUBLE DOWN' THEN 1.5
    WHEN 'KEEP GROWING' THEN 1.0 WHEN 'KEEP' THEN 1.0
    WHEN 'RAMPING' THEN 1.0 WHEN 'WATCH' THEN 1.0
    WHEN 'WIND DOWN' THEN 1.0
    WHEN 'ROTATE OUT' THEN 0 WHEN 'DEAD' THEN 0
    ELSE 1.0 END;
  v_floor_pct := CASE v_stance
    WHEN 'STAR' THEN 0.80 WHEN 'DOUBLE DOWN' THEN 0.80
    WHEN 'KEEP GROWING' THEN 0.70 WHEN 'KEEP' THEN 0.70
    WHEN 'RAMPING' THEN 0.60 WHEN 'WATCH' THEN 0.40
    WHEN 'WIND DOWN' THEN 0.00
    ELSE 0.00 END;

  v_vel_target := v_velocity * p_days_cover * v_cover_mult;
  v_vis_target := v_floor_pct * v_cap;
  v_target_pre := LEAST(GREATEST(v_vel_target, v_vis_target), v_cap::numeric);
  IF v_stance IN ('WIND DOWN','ROTATE OUT','DEAD') THEN
    v_target_pre := LEAST(v_target_pre, v_current::numeric);
  END IF;
  v_target_units := ROUND(v_target_pre)::int;
  v_refill := GREATEST(v_target_units - v_current, 0);
  v_runway := CASE WHEN v_velocity > 0 THEN ROUND(v_current / v_velocity, 1) ELSE NULL END;

  v_pod_canon := CASE v_pod_id
    WHEN '168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid THEN '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid
    ELSE v_pod_id END;

  SELECT count(*) INTO v_facings
  FROM public.v_live_shelf_stock vls
  WHERE vls.machine_id = p_machine_id
    AND vls.is_enabled AND COALESCE(vls.is_broken, false) = false AND vls.is_eligible_machine
    AND (CASE vls.pod_product_id
           WHEN '168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid THEN '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid
           ELSE vls.pod_product_id END) = v_pod_canon;
  v_facings := GREATEST(COALESCE(v_facings, 0), 1);

  SELECT
    COALESCE(SUM(sh.qty) FILTER (WHERE sh.transaction_date >= now() - interval '7 days'), 0),
    COALESCE(SUM(sh.qty) FILTER (WHERE sh.transaction_date >= now() - interval '15 days'), 0)
    INTO v_u7d, v_u15d
  FROM public.v_sales_history_resolved sh
  WHERE sh.machine_id = p_machine_id
    AND sh.delivery_status IN ('Success','Successful')
    AND (CASE sh.pod_product_id
           WHEN '168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid THEN '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid
           ELSE sh.pod_product_id END) = v_pod_canon;
  v_u7d := v_u7d / v_facings;
  v_u15d := v_u15d / v_facings;
  v_demand_base := 4 * v_u7d + 0.5 * v_u15d;

  SELECT pp.pod_product_name INTO v_pod_name FROM public.pod_products pp WHERE pp.pod_product_id = v_pod_id;
  SELECT COALESCE(gps.global_status, '📦 Core Range') INTO v_global_badge
  FROM public.mv_global_product_scores gps
  WHERE LOWER(TRIM(gps.product)) = LOWER(TRIM(v_pod_name)) LIMIT 1;
  v_global_badge := COALESCE(v_global_badge, '📦 Core Range');
  v_local_badge := public.compute_local_role(v_demand_base, v_trend);

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
