-- CC-00: Create v_live_shelf_stock — new source of truth for live shelf stock
-- Replaces the stale v_machine_shelf_plan (which reads from refill_instructions,
-- last written Jan 19 and Mar 31, 2026). v_machine_shelf_plan is NOT dropped here.
CREATE OR REPLACE VIEW public.v_live_shelf_stock AS
WITH latest_snapshots AS (
  -- Only the most recent snapshot per machine
  SELECT DISTINCT ON (machine_id)
    machine_id,
    device_name,
    weimi_device_id,
    door_statuses,
    snapshot_at
  FROM public.weimi_device_status
  ORDER BY machine_id, snapshot_at DESC
),
flattened AS (
  -- Flatten cabinets → layers → aisles
  SELECT
    ls.machine_id,
    ls.device_name       AS machine_name,
    ls.weimi_device_id,
    ls.snapshot_at,
    (cabinet.value ->> 'code')::int                            AS cabinet_index,
    layer.value ->> 'layer'                                     AS layer_label,
    aisle.value ->> 'code'                                      AS aisle_code,
    aisle.value ->> 'showName'                                  AS slot_name,
    aisle.value ->> 'goodsName'                                 AS goods_name_raw,
    GREATEST(0, (aisle.value ->> 'currStock')::int)             AS current_stock,
    (aisle.value ->> 'maxStock')::int                           AS max_stock,
    (aisle.value ->> 'isBroken')::boolean                       AS is_broken,
    (aisle.value ->> 'isEnable')::boolean                       AS is_enabled,
    CASE
      WHEN (aisle.value ->> 'price') IS NOT NULL
        THEN ((aisle.value ->> 'price')::numeric / 100)
    END                                                         AS price_aed
  FROM latest_snapshots ls,
    jsonb_array_elements(ls.door_statuses -> 'cabinets') AS cabinet(value),
    jsonb_array_elements(cabinet.value -> 'layers')      AS layer(value),
    jsonb_array_elements(layer.value -> 'aisles')        AS aisle(value)
),
-- Match tier 1: direct exact match
tier1 AS (
  SELECT f.*, pp.pod_product_id, 'direct'::text AS match_method
  FROM flattened f
  JOIN public.pod_products pp ON pp.pod_product_name = f.goods_name_raw
),
-- Unmatched after tier 1
unmatched1 AS (
  SELECT f.*
  FROM flattened f
  WHERE NOT EXISTS (
    SELECT 1 FROM public.pod_products pp WHERE pp.pod_product_name = f.goods_name_raw
  )
),
-- Match tier 2: case-insensitive
tier2 AS (
  SELECT u.*, pp.pod_product_id, 'case_insensitive'::text AS match_method
  FROM unmatched1 u
  JOIN public.pod_products pp
    ON LOWER(TRIM(pp.pod_product_name)) = LOWER(TRIM(u.goods_name_raw))
),
-- Unmatched after tier 2
unmatched2 AS (
  SELECT u.*
  FROM unmatched1 u
  WHERE NOT EXISTS (
    SELECT 1 FROM public.pod_products pp
    WHERE LOWER(TRIM(pp.pod_product_name)) = LOWER(TRIM(u.goods_name_raw))
  )
),
-- Match tier 3: via product_name_conventions
tier3 AS (
  SELECT u.*, pp.pod_product_id, 'conventions'::text AS match_method
  FROM unmatched2 u
  JOIN public.product_name_conventions pnc ON pnc.original_name = u.goods_name_raw
  JOIN public.pod_products pp ON pp.pod_product_name = pnc.official_name
),
-- Unmatched after tier 3
unmatched3 AS (
  SELECT u.*, NULL::uuid AS pod_product_id, 'unmatched'::text AS match_method
  FROM unmatched2 u
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.product_name_conventions pnc
    JOIN public.pod_products pp ON pp.pod_product_name = pnc.official_name
    WHERE pnc.original_name = u.goods_name_raw
  )
),
-- Union all tiers
all_matched AS (
  SELECT machine_id, machine_name, weimi_device_id, snapshot_at,
         cabinet_index, layer_label, aisle_code, slot_name,
         goods_name_raw, pod_product_id, match_method,
         current_stock, max_stock, is_broken, is_enabled, price_aed
  FROM tier1
  UNION ALL
  SELECT machine_id, machine_name, weimi_device_id, snapshot_at,
         cabinet_index, layer_label, aisle_code, slot_name,
         goods_name_raw, pod_product_id, match_method,
         current_stock, max_stock, is_broken, is_enabled, price_aed
  FROM tier2
  UNION ALL
  SELECT machine_id, machine_name, weimi_device_id, snapshot_at,
         cabinet_index, layer_label, aisle_code, slot_name,
         goods_name_raw, pod_product_id, match_method,
         current_stock, max_stock, is_broken, is_enabled, price_aed
  FROM tier3
  UNION ALL
  SELECT machine_id, machine_name, weimi_device_id, snapshot_at,
         cabinet_index, layer_label, aisle_code, slot_name,
         goods_name_raw, pod_product_id, match_method,
         current_stock, max_stock, is_broken, is_enabled, price_aed
  FROM unmatched3
)
SELECT
  am.machine_id,
  am.machine_name,
  am.weimi_device_id,
  am.cabinet_index,
  am.layer_label,
  am.aisle_code,
  am.slot_name,
  am.goods_name_raw,
  am.pod_product_id,
  am.match_method,
  am.current_stock,
  am.max_stock,
  CASE
    WHEN am.max_stock > 0 THEN (am.current_stock * 100 / am.max_stock)
    ELSE NULL
  END                                                          AS fill_pct,
  am.is_broken,
  am.is_enabled,
  am.price_aed,
  am.snapshot_at,
  (
    m.adyen_status = 'Online today'
    AND m.adyen_inventory_in_store = 'Live'
    AND m.repurposed_at IS NULL
  )                                                            AS is_eligible_machine
FROM all_matched am
JOIN public.machines m ON m.machine_id = am.machine_id;

GRANT SELECT ON public.v_live_shelf_stock TO authenticated, service_role;

COMMENT ON VIEW public.v_live_shelf_stock IS
'Live shelf-level stock view built from weimi_device_status.door_statuses JSONB.
Source: latest snapshot per machine (DISTINCT ON machine_id ORDER BY snapshot_at DESC).
Product matching uses 4 tiers: direct → case_insensitive → conventions → unmatched.
Unmatched rows have pod_product_id = NULL and match_method = ''unmatched'' (never dropped).
is_eligible_machine = adyen_status=''Online today'' AND adyen_inventory_in_store=''Live'' AND repurposed_at IS NULL.
DEPRECATED: v_machine_shelf_plan (reads stale refill_instructions table, last written Jan 19 and Mar 31 2026).
Do not drop v_machine_shelf_plan until all consumers are migrated to this view.';
