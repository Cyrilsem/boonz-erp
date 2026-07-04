-- PRD-075 WS-A: repurpose grace window in eligibility (Dara design, Cody-reviewed).
-- CS ruling 2026-07-04: repurposed_at + previous_location are permanent relocation
-- history (chk_repurpose_consistency correctly refuses NULLing) - so eligibility must
-- stop permanently branding relocated machines. is_eligible_machine now allows
-- repurposed machines once repurposed_at is older than
-- pick_urgency_params.repurpose_grace_days (default 30; set 0 to restore strict-off...
-- i.e. rollback = param dial, no migration). Un-blinds ACTIVATE-2005 / IFLYMCC-1024 /
-- MPMCC-1054 (repurposed April). Rest of the view body = the PRD-073 tier-4 alias body
-- VERBATIM. Full-fleet before/after eligibility diff proven in rolled-back txn:
-- ONLY the 3 named machines flip (see PRD-075-EXECUTION-LOG.md).
ALTER TABLE public.pick_urgency_params
  ADD COLUMN IF NOT EXISTS repurpose_grace_days numeric NOT NULL DEFAULT 30;

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
    m.adyen_status = 'Online today' AND m.adyen_inventory_in_store = 'Live'
      AND (m.repurposed_at IS NULL
           OR m.repurposed_at < (now() - make_interval(days => (SELECT p.repurpose_grace_days::int FROM pick_urgency_params p))))
      AS is_eligible_machine
   FROM deduped d
     JOIN machines m ON m.machine_id = d.machine_id;

-- Monitor refinement: drift = machines that SHOULD grade (Active + Online + inventory
-- 'Live'/'Live - *') but produce zero grading rows. Legitimately-not-live states
-- (Pending Setup etc.) are expected-ineligible, not drift - PRD-075 T expects zero rows
-- with MPMCC-1058 still Pending Setup.
CREATE OR REPLACE VIEW public.v_machine_eligibility_drift AS
SELECT m.machine_id, m.official_name, m.status, m.adyen_status,
       m.adyen_inventory_in_store, m.repurposed_at
FROM machines m
WHERE m.status = 'Active' AND m.adyen_status = 'Online today'
  AND m.adyen_inventory_in_store LIKE 'Live%'
  AND NOT EXISTS (SELECT 1 FROM v_shelf_sales_identity s WHERE s.machine_id = m.machine_id);
