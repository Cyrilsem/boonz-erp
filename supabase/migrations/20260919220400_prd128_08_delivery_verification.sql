-- PRD-128 step 08: delivery verification. The shelf-position spine is
-- shelf_configurations.shelf_code -- weimi_aisle_snapshots.slot_code IS the shelf code and
-- joins to it directly. v_live_shelf_stock.aisle_code is offset/cabinet-prefixed and must
-- never be used for this join (0-A12 is shelf A13, 1-A14 is shelf B15 -- it already happened
-- once).
--
-- units_sent is the sum of picked-up, non-cancelled add-type dispatch quantity for the shelf
-- on the day (action IN Add/Refill/Add New, case-insensitive -- live data has both
-- 'Refill'/'REFILL' and 'Add New'/'ADD NEW'); units_removed is the same for Remove/REMOVE.
-- weimi_prev is the shelf's last known WEIMI stock strictly before the dispatch date;
-- weimi_next is its latest WEIMI stock ON the dispatch date (the 23:59 Dubai snapshot, once
-- step 09's job runs after it). weimi_move is next minus prev.
--
-- Verdict, in order: units_sent=0 -> n/a; weimi_move<=0 -> not_landed (checked before the
-- landed threshold, so a genuine drop or no movement never reads as a small "landed" delivery);
-- weimi_move >= units_sent * pick_urgency_params.delivery_verify_tolerance -> landed; else
-- partial.
--
-- FOURTH SCHEMA GOTCHA (not one of the PRD's three): shelf_configurations.shelf_code is
-- zero-padded ("A01".."A16", confirmed 2-digit across the whole fleet); weimi_aisle_snapshots
-- .slot_code is unpadded ("A1".."A9", then "A10".."A16" -- confirmed via length/value spot
-- check, no zero-padded 3-char slot_code exists anywhere). A direct string-equality join only
-- matches the double-digit shelves and silently drops every single-digit one -- an early cut
-- of this view showed ~60 percent not_landed past the WEIMI coverage start date because of
-- exactly this. Both sides are normalized with regexp_replace(code, '^([A-Za-z]+)0*(\d+)$',
-- '\1\2') before joining -- verified against A01/A1/A10/A010/B01/B1/B15/C09.
--
-- PERFORMANCE: the weimi_prev/weimi_next lookups are LATERAL "ORDER BY snapshot_at DESC LIMIT
-- 1" per shelf_spine row, not DISTINCT ON over a pre-joined range set -- the latter forced a
-- Bitmap Heap Scan + external sort per row (714ms for the prev-half alone at 5353 rows) because
-- snapshot_date is a range predicate sitting in the middle of the natural index order. Bounding
-- by snapshot_at directly (< dispatch_date for prev, [dispatch_date, dispatch_date+1) for next)
-- lets Postgres walk idx_weimi_aisle_snapshots_norm_slot_at backward and stop at the first
-- match: confirmed via EXPLAIN ANALYZE, 714ms -> 125ms for the same lookup.

CREATE INDEX IF NOT EXISTS idx_weimi_aisle_snapshots_norm_slot_at
  ON public.weimi_aisle_snapshots (
    machine_id,
    (regexp_replace(slot_code, '^([A-Za-z]+)0*(\d+)$', '\1\2')),
    snapshot_at DESC
  );

CREATE OR REPLACE VIEW public.v_delivery_verification AS
WITH dispatch_agg AS (
  SELECT rd.dispatch_date, rd.machine_id, rd.shelf_id,
    sum(rd.quantity) FILTER (WHERE upper(rd.action) = ANY (ARRAY['ADD','REFILL','ADD NEW'])) AS units_sent,
    sum(rd.quantity) FILTER (WHERE upper(rd.action) = 'REMOVE') AS units_removed
  FROM public.refill_dispatching rd
  WHERE rd.picked_up = true AND NOT COALESCE(rd.cancelled, false)
  GROUP BY rd.dispatch_date, rd.machine_id, rd.shelf_id
),
shelf_spine AS (
  SELECT da.dispatch_date, da.machine_id, da.shelf_id, sc.shelf_code,
    regexp_replace(sc.shelf_code, '^([A-Za-z]+)0*(\d+)$', '\1\2') AS shelf_code_norm,
    COALESCE(da.units_sent, 0) AS units_sent,
    COALESCE(da.units_removed, 0) AS units_removed
  FROM dispatch_agg da
  JOIN public.shelf_configurations sc ON sc.shelf_id = da.shelf_id
)
SELECT
  ss.dispatch_date, ss.machine_id, ss.shelf_id, ss.shelf_code,
  ss.units_sent, ss.units_removed,
  wp.current_stock AS weimi_prev,
  wn.current_stock AS weimi_next,
  (COALESCE(wn.current_stock, 0) - COALESCE(wp.current_stock, 0)) AS weimi_move,
  CASE
    WHEN ss.units_sent = 0 THEN 'n/a'
    WHEN (COALESCE(wn.current_stock, 0) - COALESCE(wp.current_stock, 0)) <= 0 THEN 'not_landed'
    WHEN (COALESCE(wn.current_stock, 0) - COALESCE(wp.current_stock, 0)) >= ss.units_sent * pp.delivery_verify_tolerance THEN 'landed'
    ELSE 'partial'
  END AS verdict
FROM shelf_spine ss
LEFT JOIN LATERAL (
  SELECT w.current_stock
  FROM public.weimi_aisle_snapshots w
  WHERE w.machine_id = ss.machine_id
    AND regexp_replace(w.slot_code, '^([A-Za-z]+)0*(\d+)$', '\1\2') = ss.shelf_code_norm
    AND w.snapshot_at < ss.dispatch_date::timestamptz
  ORDER BY w.snapshot_at DESC
  LIMIT 1
) wp ON true
LEFT JOIN LATERAL (
  SELECT w.current_stock
  FROM public.weimi_aisle_snapshots w
  WHERE w.machine_id = ss.machine_id
    AND regexp_replace(w.slot_code, '^([A-Za-z]+)0*(\d+)$', '\1\2') = ss.shelf_code_norm
    AND w.snapshot_at >= ss.dispatch_date::timestamptz
    AND w.snapshot_at < (ss.dispatch_date + 1)::timestamptz
  ORDER BY w.snapshot_at DESC
  LIMIT 1
) wn ON true
CROSS JOIN public.pick_urgency_params pp;

REVOKE ALL ON public.v_delivery_verification FROM PUBLIC, anon;
GRANT SELECT ON public.v_delivery_verification TO authenticated;

-- v_machine_health_signals: last_visit now means "last day a delivery actually landed on the
-- shelf" (a landed verdict from v_delivery_verification), not "last day a dispatch was picked
-- up or returned" -- a picked-up delivery that never reached the shelf no longer counts as a
-- visit. manual_refill_visit is untouched.
--
-- PERFORMANCE: last_visit is a per-machine correlated scalar subquery, not a
-- LEFT JOIN v_delivery_verification + GROUP BY. The join+group-by shape forces Postgres to
-- compute the view for every machine in refill_dispatching history before filtering down to
-- the ~32 active machines in `base` (3.6s for this view alone); the correlated form lets the
-- machine_id predicate push all the way down into v_delivery_verification's own
-- refill_dispatching scan (confirmed via EXPLAIN ANALYZE: 452ms for the same 32 rows). It is
-- also wrapped MATERIALIZED so a single v_machine_health_signals invocation computes it exactly
-- once even though the view's other CTEs each reference `base` -- without this, the query
-- planner can still re-inline the scalar subquery per outer row when this view itself gets
-- embedded in a larger nested-loop context (see v_machine_priority's own perf-fix migration).

CREATE OR REPLACE VIEW public.v_machine_health_signals AS
 WITH base AS (
         SELECT m.machine_id,
            m.official_name,
            m.venue_group,
            m.location_type,
            m.building_id,
            m.relaunched_at
           FROM machines m
          WHERE m.include_in_refill = true AND m.status = 'Active'::text
        ), slot_health AS (
         SELECT b_1.machine_id,
            count(sl.machine_id)::numeric AS total_slots,
            count(*) FILTER (WHERE sl.signal = ANY (ARRAY['DEAD — SWAP NOW'::text, 'WIND DOWN'::text, 'ROTATE OUT'::text]))::numeric AS bad_slots,
            count(*) FILTER (WHERE sl.signal = 'HERO'::text)::integer AS hero_slots
           FROM base b_1
             LEFT JOIN slot_lifecycle sl ON sl.machine_id = b_1.machine_id AND sl.archived = false AND sl.is_current = true
          GROUP BY b_1.machine_id
        ), shelf_state AS (
         SELECT b_1.machine_id,
            count(vls.machine_id)::numeric AS shelf_count,
            count(*) FILTER (WHERE vls.current_stock = 0)::integer AS empty_count,
            sum(vls.current_stock)::integer AS cur_stock,
            sum(vls.max_stock)::integer AS max_cap
           FROM base b_1
             LEFT JOIN v_live_shelf_stock vls ON vls.machine_id = b_1.machine_id
          GROUP BY b_1.machine_id
        ), expiry_state AS (
         SELECT b_1.machine_id,
            COALESCE(ex_1.expired_skus_now, 0) AS expired_skus_now,
            COALESCE(ex_1.expiring_skus_3d, 0) AS expired_skus_3d,
            COALESCE(ex_1.expiring_skus_7d, 0) AS expired_skus_7d,
            COALESCE(ex_1.expiring_skus_30d, 0) AS expired_skus_30d
           FROM base b_1
             LEFT JOIN v_machine_expiry_summary ex_1 ON ex_1.machine_id = b_1.machine_id
        ), last_visit AS MATERIALIZED (
         SELECT b_1.machine_id,
            (SELECT max(dv.dispatch_date)
               FROM v_delivery_verification dv
              WHERE dv.machine_id = b_1.machine_id AND dv.verdict = 'landed') AS last_visit_date
           FROM base b_1
        ), manual_refill_visit AS (
         SELECT b_1.machine_id,
            max(pal.created_at::date) AS last_manual_refill_date
           FROM base b_1
             LEFT JOIN pod_inventory_audit_log pal ON pal.machine_id = b_1.machine_id AND (pal.reference_id ~~ 'manual-refill-%'::text OR pal.reference_id ~~ 'adjust-%'::text)
          GROUP BY b_1.machine_id
        ), sales_recent AS (
         SELECT b_1.machine_id,
            COALESCE(vv.units_7d, 0) AS units_last_7d
           FROM base b_1
             LEFT JOIN v_machine_velocity vv ON vv.machine_id = b_1.machine_id
        ), ramping AS (
         SELECT b_1.machine_id,
                CASE
                    WHEN b_1.relaunched_at IS NOT NULL AND b_1.relaunched_at > (now() - '14 days'::interval) THEN true
                    WHEN (( SELECT vmfs.first_sale_at
                       FROM v_machine_first_sale vmfs
                      WHERE vmfs.machine_id = b_1.machine_id)) > (now() - '14 days'::interval) THEN true
                    ELSE false
                END AS is_ramping
           FROM base b_1
        ), intent_state AS (
         SELECT b_1.machine_id,
            count(DISTINCT si.intent_id)::integer AS active_intent_count
           FROM base b_1
             JOIN slot_lifecycle sl ON sl.machine_id = b_1.machine_id AND sl.archived = false AND sl.is_current = true
             JOIN strategic_intents si ON (si.status = ANY (ARRAY['queued'::text, 'in_progress'::text])) AND si.scope_pod_product_id = sl.pod_product_id AND (si.scope_machine_ids IS NULL OR (b_1.machine_id = ANY (si.scope_machine_ids)))
          GROUP BY b_1.machine_id
        )
 SELECT b.machine_id,
    b.official_name,
    b.venue_group,
    b.location_type,
    b.building_id,
    round(
        CASE
            WHEN sh.total_slots > 0::numeric THEN sh.bad_slots * 100.0 / sh.total_slots
            ELSE 0::numeric
        END, 2) AS dead_slot_pct,
    round(
        CASE
            WHEN ss.shelf_count > 0::numeric THEN ss.empty_count::numeric * 100.0 / ss.shelf_count
            ELSE 0::numeric
        END, 2) AS empty_shelf_pct,
    round(
        CASE
            WHEN ss.max_cap > 0 THEN ss.cur_stock::numeric * 100.0 / ss.max_cap::numeric
            ELSE 0::numeric
        END, 2) AS fill_pct,
    COALESCE(sh.hero_slots, 0) AS hero_slot_count,
    COALESCE(ex.expired_skus_now, 0) AS expired_skus_now,
    COALESCE(ex.expired_skus_30d, 0) AS expired_skus_30d,
        CASE
            WHEN GREATEST(lv.last_visit_date, mrv.last_manual_refill_date) IS NULL THEN 365
            ELSE LEAST(GREATEST(CURRENT_DATE - GREATEST(lv.last_visit_date, mrv.last_manual_refill_date), 0), 365)
        END AS days_since_visit,
    COALESCE(sr.units_last_7d, 0) AS units_last_7d,
    rmp.is_ramping,
    COALESCE(int_.active_intent_count, 0) AS active_intent_count,
        CASE
            WHEN rmp.is_ramping THEN 'ramping'::text
            WHEN COALESCE(ex.expired_skus_now, 0) > 0 THEN 'at_risk'::text
            WHEN sh.total_slots > 0::numeric AND (sh.bad_slots * 1.0 / sh.total_slots) >= 0.50 AND COALESCE(sr.units_last_7d, 0) < 5 THEN 'zombie'::text
            WHEN COALESCE(sr.units_last_7d, 0) >= 70 THEN 'star'::text
            WHEN sh.total_slots > 0::numeric AND (sh.bad_slots * 1.0 / sh.total_slots) >= 0.30 OR ss.max_cap > 0 AND (ss.cur_stock::numeric * 100.0 / ss.max_cap::numeric) < 50::numeric THEN 'at_risk'::text
            ELSE 'healthy'::text
        END AS tier,
    COALESCE(ss.empty_count, 0) AS empty_shelves_count,
    COALESCE(ss.cur_stock, 0) AS cur_stock,
    COALESCE(ex.expired_skus_3d, 0) AS expired_skus_3d,
    COALESCE(ex.expired_skus_7d, 0) AS expired_skus_7d,
        CASE
            WHEN sr.units_last_7d > 0 AND ss.cur_stock > 0 THEN round(ss.cur_stock::numeric / (sr.units_last_7d::numeric / 7.0), 1)
            ELSE NULL::numeric
        END AS runway_days
   FROM base b
     LEFT JOIN slot_health sh USING (machine_id)
     LEFT JOIN shelf_state ss USING (machine_id)
     LEFT JOIN expiry_state ex USING (machine_id)
     LEFT JOIN last_visit lv USING (machine_id)
     LEFT JOIN manual_refill_visit mrv USING (machine_id)
     LEFT JOIN sales_recent sr USING (machine_id)
     LEFT JOIN ramping rmp USING (machine_id)
     LEFT JOIN intent_state int_ USING (machine_id);

-- get_machine_health(): one more DROP+CREATE pass on top of step 06, adding
-- last_delivery_verdict and lanes_not_landed. Both come from that machine's most recent
-- dispatch_date in v_delivery_verification: lanes_not_landed counts that date's not_landed
-- shelves, last_delivery_verdict is the worst verdict across that date's shelves
-- (not_landed > partial > landed > n/a). Every other column is byte-for-byte identical to
-- step 06's body.
--
-- PERFORMANCE: v_machine_priority and v_machine_health_signals are each wrapped in their own
-- MATERIALIZED CTE (mp_data, hs_data) at the top, and joined by machine_id instead of being
-- referenced as raw views in the LEFT JOINs (mp/hs) further down. Same for v_delivery_verification
-- (dv_data), which last_delivery/last_delivery_detail now read from instead of the raw view.
-- Without this, each of the three gets recomputed once per LEFT JOIN reference in this
-- function's own body, compounding on top of v_machine_priority's own internal reference
-- multiplication (see the dedicated perf-fix migration) -- get_machine_health() measured at
-- 47.7s before any of these fixes. This migration alone does not fully close the gap; see
-- DECISIONS-2026-09-19.md D-010 for the full before/after numbers and the residual known issue.

DROP FUNCTION public.get_machine_health();

CREATE FUNCTION public.get_machine_health()
 RETURNS TABLE(
   machine_name text, machine_id uuid, is_online boolean, total_stock integer, max_capacity integer,
   fill_pct numeric, total_slots integer, slots_at_zero integer, slots_below_25pct integer,
   daily_velocity numeric, days_until_empty numeric, has_sensor_errors boolean, machine_status text,
   include_in_refill boolean, recently_offline boolean, expired_units integer, expiring_7d_units integer,
   expiring_30d_units integer, days_to_earliest_expiry integer, machine_health_label text,
   machine_strategy text, machine_days_active integer, dead_stock_count integer, local_hero_count integer,
   health_tier text, health_sort integer, days_since_visit integer, pending_swap_count integer,
   is_picked_tomorrow boolean, picker_reasons text[], service_track text,
   priority_tier text, priority_score numeric,
   last_plan_date date, last_plan_days integer, urgency_breakdown jsonb, reasons_arr text[],
   pct_empty_lanes numeric, pct_quasi_lanes numeric, pct_ab_empty_or_quasi numeric, hero_runway_days numeric,
   s_gap numeric, p_score_aed numeric, car_no integer, top_contributors_aed jsonb,
   priority_tier_structural text, priority_score_structural numeric,
   unresolved_lane_count integer, machine_cohort text, cohort_sort integer,
   operating_model text, service_model text, is_boonz_serviced boolean, last_seen_at timestamptz,
   last_delivery_verdict text, lanes_not_landed integer
 )
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH mp_data AS MATERIALIZED (
    SELECT * FROM public.v_machine_priority
  ),
  hs_data AS MATERIALIZED (
    SELECT * FROM public.v_machine_health_signals
  ),
  dv_data AS MATERIALIZED (
    SELECT * FROM public.v_delivery_verification
  ),
  latest_device AS (
    SELECT DISTINCT ON (w.machine_id)
      w.machine_id, w.device_name, w.door_statuses, w.total_curr_stock, w.snapshot_at
    FROM weimi_device_status w
    WHERE w.machine_id IS NOT NULL
    ORDER BY w.machine_id, w.snapshot_at DESC
  ),
  device_metrics AS (
    SELECT
      m.machine_id,
      COALESCE(ld.device_name, m.official_name) as device_name,
      m.status as machine_status,
      m.venue_group as venue_grp,
      COALESCE(m.include_in_refill, true) as include_in_refill,
      m.operating_model,
      m.service_model,
      ld.snapshot_at,
      GREATEST(COALESCE(ld.total_curr_stock, 0), 0) as total_stock,
      (SELECT COALESCE(SUM(GREATEST((a->>'maxStock')::int,0)),0) FROM jsonb_array_elements(COALESCE(ld.door_statuses,'[]'::jsonb)) cab, jsonb_array_elements(cab->'layers') lyr, jsonb_array_elements(lyr->'aisles') a) as max_capacity,
      (SELECT COUNT(*)::int FROM jsonb_array_elements(COALESCE(ld.door_statuses,'[]'::jsonb)) cab, jsonb_array_elements(cab->'layers') lyr, jsonb_array_elements(lyr->'aisles') a) as total_slots,
      (SELECT COUNT(*)::int FROM jsonb_array_elements(COALESCE(ld.door_statuses,'[]'::jsonb)) cab, jsonb_array_elements(cab->'layers') lyr, jsonb_array_elements(lyr->'aisles') a WHERE (a->>'currStock')::int <= 0) as slots_at_zero,
      (SELECT COUNT(*)::int FROM jsonb_array_elements(COALESCE(ld.door_statuses,'[]'::jsonb)) cab, jsonb_array_elements(cab->'layers') lyr, jsonb_array_elements(lyr->'aisles') a WHERE (a->>'currStock')::int > 0 AND (a->>'currStock')::numeric / NULLIF((a->>'maxStock')::numeric,0) <= 0.25) as slots_below_25pct,
      (SELECT COUNT(*)::int > 0 FROM jsonb_array_elements(COALESCE(ld.door_statuses,'[]'::jsonb)) cab, jsonb_array_elements(cab->'layers') lyr, jsonb_array_elements(lyr->'aisles') a WHERE (a->>'currStock')::int < 0) as has_sensor_errors
    FROM machines m
    LEFT JOIN latest_device ld ON ld.machine_id = m.machine_id
  ),
  current_pod_ids AS (
    SELECT vls.machine_id,
      array_agg(DISTINCT vls.pod_product_id) FILTER (WHERE vls.pod_product_id IS NOT NULL) as ids
    FROM v_live_shelf_stock vls
    GROUP BY vls.machine_id
  ),
  unresolved_lanes AS (
    SELECT vls.machine_id, count(*)::int as unresolved_lane_count
    FROM v_live_shelf_stock vls
    WHERE vls.pod_product_id IS NULL
    GROUP BY vls.machine_id
  ),
  with_velocity AS (
    SELECT dm.*,
      COALESCE((SELECT vv.daily_velocity_7d FROM public.v_machine_velocity vv WHERE vv.machine_id = dm.machine_id), 0) as daily_velocity,
      COALESCE((SELECT SUM(sh.paid_amount) / NULLIF(GREATEST(EXTRACT(EPOCH FROM (NOW() - MIN(sh.transaction_date))) / 86400, 1), 0)
        FROM sales_history sh WHERE sh.machine_id = dm.machine_id AND sh.delivery_status IN ('Success','Successful') AND sh.transaction_date >= NOW() - interval '60 days'), 0) as daily_revenue,
      (SELECT EXTRACT(DAY FROM NOW() - vfs.first_sale_at)::int
       FROM v_machine_first_sale vfs
       WHERE vfs.machine_id = dm.machine_id) as days_active,
      (SELECT COUNT(*)::int FROM (
        SELECT sh_ds.pod_product_id as norm_product,
          COALESCE(SUM(sh_ds.qty) FILTER (WHERE sh_ds.transaction_date >= NOW() - interval '7 days'), 0) * 4
          + COALESCE(SUM(sh_ds.qty) FILTER (WHERE sh_ds.transaction_date >= NOW() - interval '15 days'), 0) * 0.5 as bs
        FROM public.v_sales_history_resolved sh_ds
        WHERE sh_ds.machine_id = dm.machine_id
          AND sh_ds.delivery_status IN ('Success','Successful')
          AND sh_ds.pod_product_id = ANY (COALESCE((SELECT cpi.ids FROM current_pod_ids cpi WHERE cpi.machine_id = dm.machine_id), ARRAY[]::uuid[]))
        GROUP BY sh_ds.pod_product_id
        HAVING COALESCE(SUM(sh_ds.qty) FILTER (WHERE sh_ds.transaction_date >= NOW() - interval '7 days'), 0) * 4
             + COALESCE(SUM(sh_ds.qty) FILTER (WHERE sh_ds.transaction_date >= NOW() - interval '15 days'), 0) * 0.5 = 0
      ) x) as dead_stock_count,
      (SELECT COUNT(*)::int FROM (
        SELECT sh_lh.pod_product_id as norm_product,
          COALESCE(SUM(sh_lh.qty) FILTER (WHERE sh_lh.transaction_date >= NOW() - interval '7 days'), 0) * 4
          + COALESCE(SUM(sh_lh.qty) FILTER (WHERE sh_lh.transaction_date >= NOW() - interval '15 days'), 0) * 0.5 as bs
        FROM public.v_sales_history_resolved sh_lh
        WHERE sh_lh.machine_id = dm.machine_id
          AND sh_lh.delivery_status IN ('Success','Successful')
          AND sh_lh.pod_product_id = ANY (COALESCE((SELECT cpi.ids FROM current_pod_ids cpi WHERE cpi.machine_id = dm.machine_id), ARRAY[]::uuid[]))
        GROUP BY sh_lh.pod_product_id
        HAVING COALESCE(SUM(sh_lh.qty) FILTER (WHERE sh_lh.transaction_date >= NOW() - interval '7 days'), 0) * 4
             + COALESCE(SUM(sh_lh.qty) FILTER (WHERE sh_lh.transaction_date >= NOW() - interval '15 days'), 0) * 0.5 > 5
      ) x) as local_hero_count
    FROM device_metrics dm
  ),
  with_expiry AS (
    SELECT wv.*,
      COALESCE(ex.expired_units, 0) as expired_units,
      COALESCE(ex.expiring_7d_units, 0) as expiring_7d_units,
      COALESCE(ex.expiring_30d_units, 0) as expiring_30d_units,
      ex.days_to_earliest as days_to_earliest_expiry
    FROM with_velocity wv
    LEFT JOIN v_machine_expiry_summary ex ON ex.machine_id = wv.machine_id
  ),
  swap_data AS (
    SELECT ps.machine_name, COUNT(*)::int as swap_count
    FROM planned_swaps ps
    WHERE ps.status = 'pending'
    GROUP BY ps.machine_name
  ),
  picker_data AS (
    SELECT mtv.machine_id, mtv.picked_reasons, mtv.car_no
    FROM machines_to_visit mtv
    WHERE mtv.plan_date = public.resolve_refill_plan_date()
      AND mtv.status IN ('picked','cs_added')
  ),
  last_plan AS (
    SELECT rpo.machine_id, max(rpo.plan_date) as last_plan_date
    FROM refill_plan_output rpo
    WHERE rpo.operator_status = 'approved'
    GROUP BY rpo.machine_id
  ),
  last_delivery AS (
    SELECT dv.machine_id, max(dv.dispatch_date) as last_dispatch_date
    FROM dv_data dv
    GROUP BY dv.machine_id
  ),
  last_delivery_detail AS (
    SELECT ld2.machine_id,
      count(*) FILTER (WHERE dv.verdict = 'not_landed')::int as lanes_not_landed,
      (array_agg(dv.verdict ORDER BY
        CASE dv.verdict WHEN 'not_landed' THEN 0 WHEN 'partial' THEN 1 WHEN 'landed' THEN 2 ELSE 3 END
      ))[1] as last_delivery_verdict
    FROM last_delivery ld2
    JOIN dv_data dv ON dv.machine_id = ld2.machine_id AND dv.dispatch_date = ld2.last_dispatch_date
    GROUP BY ld2.machine_id
  )
  SELECT
    we.device_name, we.machine_id,
    (we.snapshot_at IS NOT NULL AND we.snapshot_at >= now() - interval '24 hours') as is_online,
    we.total_stock, we.max_capacity,
    CASE WHEN we.max_capacity > 0 THEN ROUND((GREATEST(we.total_stock,0)::numeric / we.max_capacity)*100, 1) ELSE 0 END,
    we.total_slots, we.slots_at_zero, we.slots_below_25pct,
    ROUND(we.daily_velocity, 1),
    CASE WHEN we.daily_velocity > 0 THEN ROUND(GREATEST(we.total_stock,0)::numeric / we.daily_velocity, 1) ELSE 999 END,
    we.has_sensor_errors,
    COALESCE(we.machine_status, 'Active'),
    we.include_in_refill,
    (we.snapshot_at IS NOT NULL AND we.snapshot_at < now() - interval '24 hours' AND we.snapshot_at >= now() - interval '7 days') as recently_offline,
    we.expired_units, we.expiring_7d_units, we.expiring_30d_units, we.days_to_earliest_expiry,
    CASE WHEN we.days_active IS NOT NULL AND we.days_active < 30 THEN '🟦 Ramp-Up Performer'
      ELSE compute_machine_health_label(ROUND(we.daily_revenue::numeric, 1)) END,
    CASE WHEN we.days_active IS NOT NULL AND we.days_active < 30 THEN 'Maintain Visual Standards'
      ELSE compute_machine_strategy(ROUND(we.daily_revenue::numeric, 1)) END,
    we.days_active,
    COALESCE(we.dead_stock_count, 0),
    COALESCE(we.local_hero_count, 0),
    CASE
      WHEN NOT we.include_in_refill THEN 'excluded'
      WHEN COALESCE(we.machine_status,'Active') IN ('Warehouse','Inactive') THEN 'excluded'
      WHEN we.expired_units > 0 THEN 'critical'
      WHEN we.slots_at_zero > 0 THEN 'critical'
      WHEN we.max_capacity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.max_capacity) < 0.30 THEN 'critical'
      WHEN we.daily_velocity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.daily_velocity) < 2 THEN 'critical'
      WHEN we.expiring_7d_units > 0 THEN 'warning'
      WHEN we.max_capacity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.max_capacity) < 0.60 THEN 'warning'
      WHEN we.slots_below_25pct >= 2 THEN 'warning'
      WHEN we.daily_velocity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.daily_velocity) < 5 THEN 'warning'
      ELSE 'healthy'
    END,
    CASE
      WHEN NOT we.include_in_refill THEN 5
      WHEN COALESCE(we.machine_status,'Active') IN ('Warehouse','Inactive') THEN 5
      WHEN we.expired_units > 0 THEN 1
      WHEN we.slots_at_zero > 0 THEN 1
      WHEN we.max_capacity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.max_capacity) < 0.30 THEN 1
      WHEN we.daily_velocity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.daily_velocity) < 2 THEN 1
      WHEN we.expiring_7d_units > 0 THEN 2
      WHEN we.max_capacity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.max_capacity) < 0.60 THEN 2
      WHEN we.slots_below_25pct >= 2 THEN 2
      WHEN we.daily_velocity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.daily_velocity) < 5 THEN 2
      ELSE 3
    END,
    COALESCE(hs.days_since_visit, -1)::int,
    COALESCE(sd.swap_count, 0),
    pd.machine_id IS NOT NULL,
    pd.picked_reasons,
    COALESCE(mp.svc_track, 'main'),
    CASE
      WHEN NOT we.include_in_refill OR COALESCE(we.machine_status,'Active') IN ('Warehouse','Inactive')
        THEN 'excluded'
      WHEN mp.p_tier_aed = 'P1' THEN 'P1_RESTOCK'
      WHEN mp.p_tier_aed = 'P2' THEN 'P2_MAINTAIN'
      ELSE 'skip'
    END,
    COALESCE(mp.p_score_aed, 0),
    lpn.last_plan_date,
    COALESCE(hs.days_since_visit, -1)::int,
    CASE WHEN mp.machine_id IS NULL THEN '[]'::jsonb ELSE
      (SELECT COALESCE(jsonb_agg(jsonb_build_object('label', t.l, 'aed', t.aed) ORDER BY t.aed DESC), '[]'::jsonb)
       FROM (VALUES
         ('runout', round(COALESCE(mp.s_runout_aed,0), 2)),
         ('gap',    round(0.5 * COALESCE(mp.s_gap_aed,0), 2)),
         ('expiry', round(COALESCE(mp.expiry_penalty_aed,0), 2)),
         ('stale',  round(COALESCE(mp.stale_penalty_aed,0), 2))
       ) t(l, aed)
       WHERE t.aed <> 0)
    END,
    mp.reasons_arr,
    mp.pct_empty_lanes,
    mp.pct_quasi_lanes,
    mp.pct_ab_empty_or_quasi,
    mp.hero_runway_days,
    mp.s_gap,
    COALESCE(mp.p_score_aed, 0),
    pd.car_no,
    CASE WHEN mp.machine_id IS NULL THEN '[]'::jsonb ELSE
      (SELECT COALESCE(jsonb_agg(jsonb_build_object('label', t.l, 'aed', t.aed) ORDER BY t.aed DESC), '[]'::jsonb)
       FROM (
         SELECT * FROM (VALUES
           ('runout', round(COALESCE(mp.s_runout_aed,0), 2)),
           ('gap',    round(0.5 * COALESCE(mp.s_gap_aed,0), 2)),
           ('expiry', round(COALESCE(mp.expiry_penalty_aed,0), 2)),
           ('stale',  round(COALESCE(mp.stale_penalty_aed,0), 2))
         ) v(l, aed)
         WHERE v.aed <> 0
         ORDER BY v.aed DESC
         LIMIT 3
       ) t)
    END,
    CASE
      WHEN NOT we.include_in_refill OR COALESCE(we.machine_status,'Active') IN ('Warehouse','Inactive')
        THEN 'excluded'
      WHEN mp.p_tier = 'P3_OK' OR mp.p_tier IS NULL THEN 'skip'
      ELSE mp.p_tier
    END,
    COALESCE(mp.p_score, 0),
    COALESCE(unl.unresolved_lane_count, 0),
    machine_cohort(we.operating_model, we.service_model),
    CASE machine_cohort(we.operating_model, we.service_model)
      WHEN 'boonz' THEN 1 WHEN 'vox' THEN 2 WHEN 'partner' THEN 3 ELSE 4 END,
    we.operating_model, we.service_model,
    machine_cohort(we.operating_model, we.service_model) IN ('boonz','vox'),
    we.snapshot_at,
    ldd.last_delivery_verdict,
    COALESCE(ldd.lanes_not_landed, 0)
  FROM with_expiry we
  LEFT JOIN swap_data sd ON sd.machine_name = we.device_name
  LEFT JOIN picker_data pd ON pd.machine_id = we.machine_id
  LEFT JOIN mp_data mp ON mp.machine_id = we.machine_id
  LEFT JOIN hs_data hs ON hs.machine_id = we.machine_id
  LEFT JOIN unresolved_lanes unl ON unl.machine_id = we.machine_id
  LEFT JOIN last_plan lpn ON lpn.machine_id = we.machine_id
  LEFT JOIN last_delivery_detail ldd ON ldd.machine_id = we.machine_id
  ORDER BY 26,
    CASE WHEN we.max_capacity > 0 THEN ROUND((GREATEST(we.total_stock,0)::numeric / we.max_capacity)*100, 1) ELSE 0 END ASC;
$function$;

REVOKE ALL ON FUNCTION public.get_machine_health() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_machine_health() TO authenticated;
