-- PRD-110 P2.1 — v_weimi_shelf_history_v3
-- Historical shelf state from WEIMI, resolved to pod identity.
--
-- WHY THIS EXISTS (leg 17 finding):
--   `v_shelf_sales_identity` resolves its SHELF side through `v_live_shelf_stock`,
--   which reads `weimi_device_status` (raw JSONB door_statuses) and applies a FOUR-tier
--   name resolver (direct -> case_insensitive -> conventions -> weimi_product_alias).
--   Legs 15/16 assumed the source was `weimi_aisle_snapshots` with a THREE-rung resolver.
--   Measured divergence between the two tables over the same 30d window:
--     - 22,313 rows each, but 355 keys/side differ by TRAILING WHITESPACE
--       (`weimi_aisle_snapshots` trims product_name on ingest; the JSONB does not), and
--     - 294 (machine,date,name) keys disagree on STOCK by large margins
--       (e.g. Aquafina 148 vs 55) at identical slot counts.
--   `v_live_shelf_stock` -> `v_shelf_state` -> the engine all read weimi_device_status,
--   so THAT is the operative truth and P2.1 is built on it. Building the history view as
--   a strict generalisation of the live view means the P2.1 window is consistent BY
--   CONSTRUCTION with the stock the engine sees today.
--
-- RELATIONSHIP TO v_live_shelf_stock (the equivalence invariant this view must satisfy):
--   Restricting this view to the latest snapshot per device reproduces v_live_shelf_stock
--   row-for-row on (machine_id, cabinet_index, layer_label, slot_name) with identical
--   pod_product_id, current_stock and match_method. That invariant is asserted after apply.
--
-- TWO DELIBERATE DIFFERENCES FROM v_live_shelf_stock, both strict improvements:
--   1. Keyed on (machine_id, snapshot_at), NOT `DISTINCT ON (device_name)`.
--      Measured: 4 device_names span >1 machine_id and 11 machine_ids span >1 device_name,
--      so the live view's device_name key can silently DROP a machine. History must not.
--   2. Tier 3 (conventions) gets a deterministic tiebreak. `product_name_conventions`
--      has 2 duplicated original_names and `Al Ain Water` resolves to TWO distinct
--      pod_product_ids; 93 WEIMI rows in 30d hit a duplicated convention name. The live
--      view's plain JOIN leaves that tie to an unordered DISTINCT ON. Here it is ordered.
--
-- ADDITIVE ONLY. No table touched, no RLS, no SECURITY DEFINER, no protected-entity write.

-- security_invoker=true: PRD-110 house convention, matching the two v3 views already live
-- (v_shelf_state, v_shelf_availability_v3). Without it the view executes as its postgres
-- owner and bypasses underlying-table RLS for anon/authenticated (Articles 2, 3).
CREATE OR REPLACE VIEW public.v_weimi_shelf_history_v3
WITH (security_invoker = true) AS
WITH snaps AS (
  -- one row per (machine, snapshot); guards the 1 duplicated (device_name, snapshot_at)
  SELECT DISTINCT ON (ds.machine_id, ds.snapshot_at)
         ds.machine_id,
         ds.device_name,
         ds.weimi_device_id,
         ds.door_statuses,
         ds.snapshot_at
  FROM public.weimi_device_status ds
  ORDER BY ds.machine_id, ds.snapshot_at, ds.status_id DESC
), flattened AS (
  SELECT s.machine_id,
         s.device_name AS machine_name,
         s.weimi_device_id,
         s.snapshot_at,
         (cabinet.value ->> 'code')::integer          AS cabinet_index,
         layer.value ->> 'layer'                      AS layer_label,
         aisle.value ->> 'code'                       AS aisle_code,
         aisle.value ->> 'showName'                   AS slot_name,
         aisle.value ->> 'goodsName'                  AS goods_name_raw,
         GREATEST(0, (aisle.value ->> 'currStock')::integer) AS current_stock,
         (aisle.value ->> 'maxStock')::integer        AS max_stock,
         (aisle.value ->> 'isBroken')::boolean        AS is_broken,
         (aisle.value ->> 'isEnable')::boolean        AS is_enabled,
         CASE WHEN (aisle.value ->> 'price') IS NOT NULL
              THEN ((aisle.value ->> 'price')::numeric) / 100::numeric
         END                                          AS price_aed
  FROM snaps s,
       LATERAL jsonb_array_elements(s.door_statuses)        cabinet(value),
       LATERAL jsonb_array_elements(cabinet.value -> 'layers') layer(value),
       LATERAL jsonb_array_elements(layer.value -> 'aisles')   aisle(value)
), resolved AS (
  SELECT f.*,
         COALESCE(t1.pod_product_id, t2.pod_product_id,
                  t3.pod_product_id, t4.pod_product_id) AS pod_product_id,
         CASE WHEN t1.pod_product_id IS NOT NULL THEN 'direct'
              WHEN t2.pod_product_id IS NOT NULL THEN 'case_insensitive'
              WHEN t3.pod_product_id IS NOT NULL THEN 'conventions'
              WHEN t4.pod_product_id IS NOT NULL THEN 'alias'
              ELSE 'unmatched'
         END AS match_method
  FROM flattened f
  -- tier 1: exact. pod_products.pod_product_name is unique (verified 0 dupes).
  LEFT JOIN LATERAL (
    SELECT pp.pod_product_id FROM public.pod_products pp
    WHERE pp.pod_product_name = f.goods_name_raw LIMIT 1
  ) t1 ON true
  -- tier 2: case/space-insensitive. Also absorbs the trailing-whitespace goodsName class.
  LEFT JOIN LATERAL (
    SELECT pp.pod_product_id FROM public.pod_products pp
    WHERE lower(btrim(pp.pod_product_name)) = lower(btrim(f.goods_name_raw)) LIMIT 1
  ) t2 ON true
  -- tier 3: naming conventions. Deterministic tiebreak (see header note 2).
  LEFT JOIN LATERAL (
    SELECT pp.pod_product_id
    FROM public.product_name_conventions pnc
    JOIN public.pod_products pp ON pp.pod_product_name = pnc.official_name
    WHERE pnc.original_name = f.goods_name_raw
    ORDER BY pp.pod_product_name
    LIMIT 1
  ) t3 ON true
  -- tier 4: WEIMI alias, preferring a pod that carries an Active mapping. Lifted verbatim.
  LEFT JOIN LATERAL (
    SELECT a.pod_product_id
    FROM public.weimi_product_alias a
    JOIN public.pod_products pp ON pp.pod_product_id = a.pod_product_id
    WHERE a.weimi_name = f.goods_name_raw
    ORDER BY (EXISTS (SELECT 1 FROM public.product_mapping pm
                      WHERE pm.pod_product_id = a.pod_product_id
                        AND pm.status = 'Active')) DESC,
             pp.pod_product_name
    LIMIT 1
  ) t4 ON true
), deduped AS (
  SELECT DISTINCT ON (r.machine_id, r.snapshot_at, r.cabinet_index, r.layer_label, r.slot_name) r.*
  FROM resolved r
  ORDER BY r.machine_id, r.snapshot_at, r.cabinet_index, r.layer_label, r.slot_name,
           CASE r.match_method
             WHEN 'direct'           THEN 1
             WHEN 'case_insensitive' THEN 2
             WHEN 'conventions'      THEN 3
             WHEN 'alias'            THEN 4
             ELSE 5
           END
)
SELECT d.machine_id,
       d.machine_name,
       d.weimi_device_id,
       d.snapshot_at,
       d.cabinet_index,
       d.layer_label,
       d.aisle_code,
       d.slot_name,
       d.goods_name_raw,
       d.pod_product_id,
       d.match_method,
       d.current_stock,
       d.max_stock,
       CASE WHEN d.max_stock > 0 THEN d.current_stock * 100 / d.max_stock END AS fill_pct,
       d.is_broken,
       d.is_enabled,
       d.price_aed,
       (m.adyen_status = 'Online today'
        AND m.adyen_inventory_in_store = 'Live'
        AND (m.repurposed_at IS NULL
             OR m.repurposed_at < (now() - make_interval(days => (
                  SELECT p.repurpose_grace_days::integer FROM public.pick_urgency_params p
                ))))) AS is_eligible_machine
FROM deduped d
JOIN public.machines m ON m.machine_id = d.machine_id;

COMMENT ON VIEW public.v_weimi_shelf_history_v3 IS
'PRD-110 P2.1. Historical WEIMI shelf state resolved to pod identity. Strict generalisation of v_live_shelf_stock over ALL snapshots (that view = this view restricted to the latest snapshot per device). Source is weimi_device_status, NOT weimi_aisle_snapshots: the two disagree on 294 stock keys in 30d and the engine reads device_status. Keyed by machine_id (device_name is not 1:1 with machine_id). Identity by product NAME only - never by slot (LAW 6).';
