-- Wave-2 Block 4: resolve WEIMI slot names through weimi_product_alias in the engine's
-- central name resolver.
--
-- v_live_shelf_stock matches goodsName to pod_products in tiers:
--   1 direct, 2 case_insensitive, 3 conventions (product_name_conventions), else unmatched.
-- The 17 drifted WEIMI names seeded into weimi_product_alias (2026-07-02) fall through all
-- three tiers today, causing (a) phantom pod rows invisible in machine views and (b) engine
-- planogram-fallback misfires. This adds tier 4 'alias' AFTER conventions: zero behavior
-- change for any currently-matched row; only currently-unmatched rows are rescued.
--
-- Multi-target aliases (e.g. 'M&M bag' -> 2 pods): deterministic pick = the target with an
-- Active product_mapping first (engine-usable), then alphabetical pod name.
--
-- Downstream (no further change needed): stitch_pod_to_boonz, engine_add_pod,
-- v_machine_priority, v_shelf_sales_identity all consume pod_product_id from this view
-- (v_shelf_sales_identity applies its own scoped canonicalization on top). PRD-063
-- name-match prereq is satisfied by this base-view fix. v_machine_service_priority's
-- goods_name_raw usage is a SALES-name join, out of scope here.
--
-- CREATE OR REPLACE: output column list byte-identical (match_method gains value 'alias').
CREATE OR REPLACE VIEW public.v_live_shelf_stock AS
 WITH latest_snapshots AS (
         SELECT DISTINCT ON (weimi_device_status.device_name) weimi_device_status.machine_id,
            weimi_device_status.device_name,
            weimi_device_status.weimi_device_id,
            weimi_device_status.door_statuses,
            weimi_device_status.snapshot_at
           FROM weimi_device_status
          ORDER BY weimi_device_status.device_name, weimi_device_status.snapshot_at DESC
        ), flattened AS (
         SELECT ls.machine_id,
            ls.device_name AS machine_name,
            ls.weimi_device_id,
            ls.snapshot_at,
            (cabinet.value ->> 'code')::integer AS cabinet_index,
            layer.value ->> 'layer' AS layer_label,
            aisle.value ->> 'code' AS aisle_code,
            aisle.value ->> 'showName' AS slot_name,
            aisle.value ->> 'goodsName' AS goods_name_raw,
            GREATEST(0, (aisle.value ->> 'currStock')::integer) AS current_stock,
            (aisle.value ->> 'maxStock')::integer AS max_stock,
            (aisle.value ->> 'isBroken')::boolean AS is_broken,
            (aisle.value ->> 'isEnable')::boolean AS is_enabled,
                CASE
                    WHEN (aisle.value ->> 'price') IS NOT NULL THEN ((aisle.value ->> 'price')::numeric) / 100::numeric
                    ELSE NULL::numeric
                END AS price_aed
           FROM latest_snapshots ls,
            LATERAL jsonb_array_elements(ls.door_statuses) cabinet(value),
            LATERAL jsonb_array_elements(cabinet.value -> 'layers') layer(value),
            LATERAL jsonb_array_elements(layer.value -> 'aisles') aisle(value)
        ), tier1 AS (
         SELECT f.*, pp.pod_product_id, 'direct'::text AS match_method
           FROM flattened f
             JOIN pod_products pp ON pp.pod_product_name = f.goods_name_raw
        ), unmatched1 AS (
         SELECT f.*
           FROM flattened f
          WHERE NOT (EXISTS ( SELECT 1 FROM pod_products pp
                  WHERE pp.pod_product_name = f.goods_name_raw))
        ), tier2 AS (
         SELECT u.*, pp.pod_product_id, 'case_insensitive'::text AS match_method
           FROM unmatched1 u
             JOIN pod_products pp ON lower(TRIM(BOTH FROM pp.pod_product_name)) = lower(TRIM(BOTH FROM u.goods_name_raw))
        ), unmatched2 AS (
         SELECT u.*
           FROM unmatched1 u
          WHERE NOT (EXISTS ( SELECT 1 FROM pod_products pp
                  WHERE lower(TRIM(BOTH FROM pp.pod_product_name)) = lower(TRIM(BOTH FROM u.goods_name_raw))))
        ), tier3 AS (
         SELECT u.*, pp.pod_product_id, 'conventions'::text AS match_method
           FROM unmatched2 u
             JOIN product_name_conventions pnc ON pnc.original_name = u.goods_name_raw
             JOIN pod_products pp ON pp.pod_product_name = pnc.official_name
        ), unmatched3 AS (
         SELECT u.*
           FROM unmatched2 u
          WHERE NOT (EXISTS ( SELECT 1
                   FROM product_name_conventions pnc
                     JOIN pod_products pp ON pp.pod_product_name = pnc.official_name
                  WHERE pnc.original_name = u.goods_name_raw))
        ), tier4 AS (
         SELECT u.*, x.pod_product_id, 'alias'::text AS match_method
           FROM unmatched3 u
             JOIN LATERAL (
               SELECT a.pod_product_id
                 FROM weimi_product_alias a
                 JOIN pod_products pp ON pp.pod_product_id = a.pod_product_id
                WHERE a.weimi_name = u.goods_name_raw
                ORDER BY (EXISTS (SELECT 1 FROM product_mapping pm
                                  WHERE pm.pod_product_id = a.pod_product_id
                                    AND pm.status = 'Active')) DESC,
                         pp.pod_product_name
                LIMIT 1
             ) x ON true
        ), unmatched4 AS (
         SELECT u.*, NULL::uuid AS pod_product_id, 'unmatched'::text AS match_method
           FROM unmatched3 u
          WHERE NOT (EXISTS ( SELECT 1 FROM weimi_product_alias a
                  WHERE a.weimi_name = u.goods_name_raw))
        ), all_matched AS (
         SELECT * FROM tier1
        UNION ALL
         SELECT * FROM tier2
        UNION ALL
         SELECT * FROM tier3
        UNION ALL
         SELECT * FROM tier4
        UNION ALL
         SELECT * FROM unmatched4
        ), deduped AS (
         SELECT DISTINCT ON (all_matched.machine_id, all_matched.cabinet_index, all_matched.layer_label, all_matched.slot_name) all_matched.machine_id,
            all_matched.machine_name,
            all_matched.weimi_device_id,
            all_matched.snapshot_at,
            all_matched.cabinet_index,
            all_matched.layer_label,
            all_matched.aisle_code,
            all_matched.slot_name,
            all_matched.goods_name_raw,
            all_matched.pod_product_id,
            all_matched.match_method,
            all_matched.current_stock,
            all_matched.max_stock,
            all_matched.is_broken,
            all_matched.is_enabled,
            all_matched.price_aed
           FROM all_matched
          ORDER BY all_matched.machine_id, all_matched.cabinet_index, all_matched.layer_label, all_matched.slot_name, all_matched.snapshot_at DESC, (
                CASE all_matched.match_method
                    WHEN 'direct' THEN 1
                    WHEN 'case_insensitive' THEN 2
                    WHEN 'conventions' THEN 3
                    WHEN 'alias' THEN 4
                    WHEN 'unmatched' THEN 5
                    ELSE 6
                END)
        )
 SELECT d.machine_id,
    d.machine_name,
    d.weimi_device_id,
    d.cabinet_index,
    d.layer_label,
    d.aisle_code,
    d.slot_name,
    d.goods_name_raw,
    d.pod_product_id,
    d.match_method,
    d.current_stock,
    d.max_stock,
        CASE
            WHEN d.max_stock > 0 THEN d.current_stock * 100 / d.max_stock
            ELSE NULL::integer
        END AS fill_pct,
    d.is_broken,
    d.is_enabled,
    d.price_aed,
    d.snapshot_at,
    m.adyen_status = 'Online today' AND m.adyen_inventory_in_store = 'Live' AND m.repurposed_at IS NULL AS is_eligible_machine
   FROM deduped d
     JOIN machines m ON m.machine_id = d.machine_id;
