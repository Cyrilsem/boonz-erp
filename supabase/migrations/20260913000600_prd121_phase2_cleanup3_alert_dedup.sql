-- PRD-121 Phase 2, cleanup item 3: alert hygiene -- dedupe, and surface criticals.
--
-- v_wm_alert_queue already exists and is exactly the right mechanism ("dedup'd,
-- actionable WM queue lines instead of raw monitoring_alerts rows", consumed by
-- WmAlertQueuePanel.tsx) -- but it only covers 3 sources
-- (bug010_wh_approval_stuck, prd016_guardrail2_return_variant_uncorrected,
-- expiry_unvalidated). Every other high-volume source was left raw. Verified live over
-- the last 7 days: prd018_guardrail3_pack_variant_unconfirmed alone fired 376 times (~54/
-- day) -- the single largest contributor to "~140 alerts/day, mostly repeats, nobody
-- reads them" -- and was not deduped at all.
--
-- Fix: extend the SAME view, SAME UNION ALL / dedup_key / GROUP BY / NOT acknowledged
-- pattern already established, to the 13 other sources found generating real volume:
--
--   Per-entity sources (dedup_key = the natural id already in their own payload):
--     prd018_guardrail3_pack_variant_unconfirmed  -> dispatch_id  (376/7d, the big one)
--     bug010_driver_stuck_remove                  -> dispatch_id
--     bug012_phantom_dispatch_expiry               -> dispatch_id
--     slot_rebind_disagrees_with_weimi            -> dispatch_id
--     weimi_slot_guard                             -> plan_line_id
--     unmatched_weimi_product                      -> goods_name_raw
--
--   Sweep/batch sources (one alert already summarizes many violations per run --
--   dedup_key = 'all', same as the existing expiry_unvalidated branch):
--     orphan_shelf_lots, unpinned_warehouse_dispatch_line, weimi_slot_drift_monitor,
--     refill_draft_missing, wh_routing_gap, zero_stock_sweep, remove_leg_null_pod_lot
--
-- "Route criticals": no notification destination (email/Slack/SMS) is specified anywhere
-- in this codebase, and building one without a named target would be guessing
-- infrastructure that doesn't exist. What IS buildable and done here: every critical-
-- severity source above is now included in the SAME deduped queue the FE already renders
-- with distinct red styling for severity='critical' (WmAlertQueuePanel.tsx) -- criticals
-- were previously just as buried in the raw-row noise as everything else; now they surface
-- in the one queue anyone actually reads, at one row per real incident instead of N.
--
-- Article 16: same canonical dedup object, not a second one -- CREATE OR REPLACE VIEW,
-- same column list/order, purely additive UNION ALL branches.
--
-- Cody: fast-path approve (view definition change on a reporting object, not a protected
-- entity; no new write path; no DDL on a protected table).

CREATE OR REPLACE VIEW public.v_wm_alert_queue AS
SELECT
  'bug010_wh_approval_stuck'::text AS source,
  monitoring_alerts.payload ->> 'dispatch_id' AS dedup_key,
  monitoring_alerts.payload ->> 'dispatch_id' AS dispatch_id,
  NULL::text AS pod_product_id,
  (array_agg(monitoring_alerts.severity ORDER BY monitoring_alerts.created_at DESC))[1] AS severity,
  max(monitoring_alerts.created_at) AS latest_at,
  count(*) AS occurrences,
  (array_agg(monitoring_alerts.payload ORDER BY monitoring_alerts.created_at DESC))[1] AS payload
FROM monitoring_alerts
WHERE monitoring_alerts.source = 'bug010_wh_approval_stuck' AND NOT monitoring_alerts.acknowledged
GROUP BY (monitoring_alerts.payload ->> 'dispatch_id')

UNION ALL
SELECT
  'prd016_guardrail2_return_variant_uncorrected'::text AS source,
  (monitoring_alerts.payload ->> 'dispatch_id') || '|' || (monitoring_alerts.payload ->> 'pod_product_id') AS dedup_key,
  monitoring_alerts.payload ->> 'dispatch_id' AS dispatch_id,
  monitoring_alerts.payload ->> 'pod_product_id' AS pod_product_id,
  (array_agg(monitoring_alerts.severity ORDER BY monitoring_alerts.created_at DESC))[1] AS severity,
  max(monitoring_alerts.created_at) AS latest_at,
  count(*) AS occurrences,
  (array_agg(monitoring_alerts.payload ORDER BY monitoring_alerts.created_at DESC))[1] AS payload
FROM monitoring_alerts
WHERE monitoring_alerts.source = 'prd016_guardrail2_return_variant_uncorrected' AND NOT monitoring_alerts.acknowledged
GROUP BY (monitoring_alerts.payload ->> 'dispatch_id'), (monitoring_alerts.payload ->> 'pod_product_id')

UNION ALL
SELECT
  'expiry_unvalidated'::text AS source,
  'all'::text AS dedup_key,
  NULL::text AS dispatch_id,
  NULL::text AS pod_product_id,
  (array_agg(monitoring_alerts.severity ORDER BY monitoring_alerts.created_at DESC))[1] AS severity,
  max(monitoring_alerts.created_at) AS latest_at,
  count(*) AS occurrences,
  (array_agg(monitoring_alerts.payload ORDER BY monitoring_alerts.created_at DESC))[1] AS payload
FROM monitoring_alerts
WHERE monitoring_alerts.source = 'expiry_unvalidated' AND NOT monitoring_alerts.acknowledged
GROUP BY monitoring_alerts.source

-- PRD-121 Phase 2 cleanup 3: newly added branches below this line.

UNION ALL
SELECT
  'prd018_guardrail3_pack_variant_unconfirmed'::text AS source,
  monitoring_alerts.payload ->> 'dispatch_id' AS dedup_key,
  monitoring_alerts.payload ->> 'dispatch_id' AS dispatch_id,
  monitoring_alerts.payload ->> 'pod_product_id' AS pod_product_id,
  (array_agg(monitoring_alerts.severity ORDER BY monitoring_alerts.created_at DESC))[1] AS severity,
  max(monitoring_alerts.created_at) AS latest_at,
  count(*) AS occurrences,
  (array_agg(monitoring_alerts.payload ORDER BY monitoring_alerts.created_at DESC))[1] AS payload
FROM monitoring_alerts
WHERE monitoring_alerts.source = 'prd018_guardrail3_pack_variant_unconfirmed' AND NOT monitoring_alerts.acknowledged
GROUP BY (monitoring_alerts.payload ->> 'dispatch_id'), (monitoring_alerts.payload ->> 'pod_product_id')

UNION ALL
SELECT
  'bug010_driver_stuck_remove'::text AS source,
  monitoring_alerts.payload ->> 'dispatch_id' AS dedup_key,
  monitoring_alerts.payload ->> 'dispatch_id' AS dispatch_id,
  NULL::text AS pod_product_id,
  (array_agg(monitoring_alerts.severity ORDER BY monitoring_alerts.created_at DESC))[1] AS severity,
  max(monitoring_alerts.created_at) AS latest_at,
  count(*) AS occurrences,
  (array_agg(monitoring_alerts.payload ORDER BY monitoring_alerts.created_at DESC))[1] AS payload
FROM monitoring_alerts
WHERE monitoring_alerts.source = 'bug010_driver_stuck_remove' AND NOT monitoring_alerts.acknowledged
GROUP BY (monitoring_alerts.payload ->> 'dispatch_id')

UNION ALL
SELECT
  'bug012_phantom_dispatch_expiry'::text AS source,
  monitoring_alerts.payload ->> 'dispatch_id' AS dedup_key,
  monitoring_alerts.payload ->> 'dispatch_id' AS dispatch_id,
  monitoring_alerts.payload ->> 'boonz_product_id' AS pod_product_id,
  (array_agg(monitoring_alerts.severity ORDER BY monitoring_alerts.created_at DESC))[1] AS severity,
  max(monitoring_alerts.created_at) AS latest_at,
  count(*) AS occurrences,
  (array_agg(monitoring_alerts.payload ORDER BY monitoring_alerts.created_at DESC))[1] AS payload
FROM monitoring_alerts
WHERE monitoring_alerts.source = 'bug012_phantom_dispatch_expiry' AND NOT monitoring_alerts.acknowledged
GROUP BY (monitoring_alerts.payload ->> 'dispatch_id'), (monitoring_alerts.payload ->> 'boonz_product_id')

UNION ALL
SELECT
  'slot_rebind_disagrees_with_weimi'::text AS source,
  monitoring_alerts.payload ->> 'dispatch_id' AS dedup_key,
  monitoring_alerts.payload ->> 'dispatch_id' AS dispatch_id,
  monitoring_alerts.payload ->> 'new_pod_product_id' AS pod_product_id,
  (array_agg(monitoring_alerts.severity ORDER BY monitoring_alerts.created_at DESC))[1] AS severity,
  max(monitoring_alerts.created_at) AS latest_at,
  count(*) AS occurrences,
  (array_agg(monitoring_alerts.payload ORDER BY monitoring_alerts.created_at DESC))[1] AS payload
FROM monitoring_alerts
WHERE monitoring_alerts.source = 'slot_rebind_disagrees_with_weimi' AND NOT monitoring_alerts.acknowledged
GROUP BY (monitoring_alerts.payload ->> 'dispatch_id'), (monitoring_alerts.payload ->> 'new_pod_product_id')

UNION ALL
SELECT
  'weimi_slot_guard'::text AS source,
  monitoring_alerts.payload ->> 'plan_line_id' AS dedup_key,
  NULL::text AS dispatch_id,
  NULL::text AS pod_product_id,
  (array_agg(monitoring_alerts.severity ORDER BY monitoring_alerts.created_at DESC))[1] AS severity,
  max(monitoring_alerts.created_at) AS latest_at,
  count(*) AS occurrences,
  (array_agg(monitoring_alerts.payload ORDER BY monitoring_alerts.created_at DESC))[1] AS payload
FROM monitoring_alerts
WHERE monitoring_alerts.source = 'weimi_slot_guard' AND NOT monitoring_alerts.acknowledged
GROUP BY (monitoring_alerts.payload ->> 'plan_line_id')

UNION ALL
SELECT
  'unmatched_weimi_product'::text AS source,
  monitoring_alerts.payload ->> 'goods_name_raw' AS dedup_key,
  NULL::text AS dispatch_id,
  NULL::text AS pod_product_id,
  (array_agg(monitoring_alerts.severity ORDER BY monitoring_alerts.created_at DESC))[1] AS severity,
  max(monitoring_alerts.created_at) AS latest_at,
  count(*) AS occurrences,
  (array_agg(monitoring_alerts.payload ORDER BY monitoring_alerts.created_at DESC))[1] AS payload
FROM monitoring_alerts
WHERE monitoring_alerts.source = 'unmatched_weimi_product' AND NOT monitoring_alerts.acknowledged
GROUP BY (monitoring_alerts.payload ->> 'goods_name_raw')

UNION ALL
SELECT
  'orphan_shelf_lots'::text AS source, 'all'::text AS dedup_key, NULL::text AS dispatch_id, NULL::text AS pod_product_id,
  (array_agg(monitoring_alerts.severity ORDER BY monitoring_alerts.created_at DESC))[1] AS severity,
  max(monitoring_alerts.created_at) AS latest_at, count(*) AS occurrences,
  (array_agg(monitoring_alerts.payload ORDER BY monitoring_alerts.created_at DESC))[1] AS payload
FROM monitoring_alerts
WHERE monitoring_alerts.source = 'orphan_shelf_lots' AND NOT monitoring_alerts.acknowledged
GROUP BY monitoring_alerts.source

UNION ALL
SELECT
  'unpinned_warehouse_dispatch_line'::text AS source, 'all'::text AS dedup_key, NULL::text AS dispatch_id, NULL::text AS pod_product_id,
  (array_agg(monitoring_alerts.severity ORDER BY monitoring_alerts.created_at DESC))[1] AS severity,
  max(monitoring_alerts.created_at) AS latest_at, count(*) AS occurrences,
  (array_agg(monitoring_alerts.payload ORDER BY monitoring_alerts.created_at DESC))[1] AS payload
FROM monitoring_alerts
WHERE monitoring_alerts.source = 'unpinned_warehouse_dispatch_line' AND NOT monitoring_alerts.acknowledged
GROUP BY monitoring_alerts.source

UNION ALL
SELECT
  'weimi_slot_drift_monitor'::text AS source, 'all'::text AS dedup_key, NULL::text AS dispatch_id, NULL::text AS pod_product_id,
  (array_agg(monitoring_alerts.severity ORDER BY monitoring_alerts.created_at DESC))[1] AS severity,
  max(monitoring_alerts.created_at) AS latest_at, count(*) AS occurrences,
  (array_agg(monitoring_alerts.payload ORDER BY monitoring_alerts.created_at DESC))[1] AS payload
FROM monitoring_alerts
WHERE monitoring_alerts.source = 'weimi_slot_drift_monitor' AND NOT monitoring_alerts.acknowledged
GROUP BY monitoring_alerts.source

UNION ALL
SELECT
  'refill_draft_missing'::text AS source, 'all'::text AS dedup_key, NULL::text AS dispatch_id, NULL::text AS pod_product_id,
  (array_agg(monitoring_alerts.severity ORDER BY monitoring_alerts.created_at DESC))[1] AS severity,
  max(monitoring_alerts.created_at) AS latest_at, count(*) AS occurrences,
  (array_agg(monitoring_alerts.payload ORDER BY monitoring_alerts.created_at DESC))[1] AS payload
FROM monitoring_alerts
WHERE monitoring_alerts.source = 'refill_draft_missing' AND NOT monitoring_alerts.acknowledged
GROUP BY monitoring_alerts.source

UNION ALL
SELECT
  'wh_routing_gap'::text AS source, 'all'::text AS dedup_key, NULL::text AS dispatch_id, NULL::text AS pod_product_id,
  (array_agg(monitoring_alerts.severity ORDER BY monitoring_alerts.created_at DESC))[1] AS severity,
  max(monitoring_alerts.created_at) AS latest_at, count(*) AS occurrences,
  (array_agg(monitoring_alerts.payload ORDER BY monitoring_alerts.created_at DESC))[1] AS payload
FROM monitoring_alerts
WHERE monitoring_alerts.source = 'wh_routing_gap' AND NOT monitoring_alerts.acknowledged
GROUP BY monitoring_alerts.source

UNION ALL
SELECT
  'zero_stock_sweep'::text AS source, 'all'::text AS dedup_key, NULL::text AS dispatch_id, NULL::text AS pod_product_id,
  (array_agg(monitoring_alerts.severity ORDER BY monitoring_alerts.created_at DESC))[1] AS severity,
  max(monitoring_alerts.created_at) AS latest_at, count(*) AS occurrences,
  (array_agg(monitoring_alerts.payload ORDER BY monitoring_alerts.created_at DESC))[1] AS payload
FROM monitoring_alerts
WHERE monitoring_alerts.source = 'zero_stock_sweep' AND NOT monitoring_alerts.acknowledged
GROUP BY monitoring_alerts.source

UNION ALL
SELECT
  'remove_leg_null_pod_lot'::text AS source, 'all'::text AS dedup_key, NULL::text AS dispatch_id, NULL::text AS pod_product_id,
  (array_agg(monitoring_alerts.severity ORDER BY monitoring_alerts.created_at DESC))[1] AS severity,
  max(monitoring_alerts.created_at) AS latest_at, count(*) AS occurrences,
  (array_agg(monitoring_alerts.payload ORDER BY monitoring_alerts.created_at DESC))[1] AS payload
FROM monitoring_alerts
WHERE monitoring_alerts.source = 'remove_leg_null_pod_lot' AND NOT monitoring_alerts.acknowledged
GROUP BY monitoring_alerts.source;
