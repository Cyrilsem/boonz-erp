-- Read-only monitor: surfaces pairs of DISTINCT live pods on a machine that
-- violate an ACTIVE machine-scope coexistence_rules rule, using the SAME
-- matching logic as public._coexistence_blocks(). Excludes rule1 tccc
-- venue-exclusion (venue-scope, different concern). Retroactive-cleanup aid:
-- the _coexistence_blocks() guard only prevents NEW conflicts; this view finds
-- pre-existing same-family duplicate pairs already deployed. READ-ONLY.
CREATE OR REPLACE VIEW public.v_coexistence_violations AS
WITH rules AS (
  SELECT rule_group, a_match_type, a_match_value, b_match_type, b_match_value
  FROM public.coexistence_rules
  WHERE scope = 'machine' AND rule_type = 'hard' AND is_active = true
    AND rule_group <> 'rule1_tccc_venue_exclusion'
),
-- Live pods on each machine: slot_lifecycle current UNION v_live_shelf_stock>0
live_ids AS (
  SELECT sl.machine_id, sl.pod_product_id
  FROM public.slot_lifecycle sl
  WHERE sl.archived = false AND sl.is_current = true AND sl.pod_product_id IS NOT NULL
  UNION
  SELECT vls.machine_id, vls.pod_product_id
  FROM public.v_live_shelf_stock vls
  WHERE vls.pod_product_id IS NOT NULL AND vls.current_stock > 0
),
sl_attr AS (
  SELECT machine_id, pod_product_id,
         max(velocity_30d) AS velocity,
         string_agg(DISTINCT shelf_code, ', ') AS shelf_codes
  FROM public.slot_lifecycle
  WHERE archived = false AND is_current = true AND pod_product_id IS NOT NULL
  GROUP BY machine_id, pod_product_id
),
shelf_attr AS (
  SELECT machine_id, pod_product_id,
         string_agg(DISTINCT (COALESCE('C' || cabinet_index::text, '')
             || COALESCE('-' || layer_label, '')
             || COALESCE('/' || slot_name, '')), ', ') AS shelf_slots
  FROM public.v_live_shelf_stock
  WHERE pod_product_id IS NOT NULL AND current_stock > 0
  GROUP BY machine_id, pod_product_id
),
live_pods AS (
  SELECT li.machine_id, li.pod_product_id,
         pp.pod_product_name AS pod_name,
         COALESCE(sa.velocity, 0)::numeric AS velocity,
         COALESCE(sa.shelf_codes, sh.shelf_slots) AS shelf
  FROM live_ids li
  JOIN public.pod_products pp ON pp.pod_product_id = li.pod_product_id
  LEFT JOIN sl_attr sa ON sa.machine_id = li.machine_id AND sa.pod_product_id = li.pod_product_id
  LEFT JOIN shelf_attr sh ON sh.machine_id = li.machine_id AND sh.pod_product_id = li.pod_product_id
),
-- Resolve each live pod to its DISTINCT active boonz SKUs (no machine filter,
-- matching _coexistence_blocks which joins product_mapping on pod_product_id + Active only)
pod_boonz AS (
  SELECT DISTINCT lp.machine_id, lp.pod_product_id,
         bp.product_id AS boonz_id,
         bp.product_brand AS brand,
         bp.brand_owner AS owner,
         bp.boonz_product_name AS nm,
         bp.product_family_id AS fam
  FROM live_pods lp
  JOIN public.product_mapping pm ON pm.pod_product_id = lp.pod_product_id AND pm.status = 'Active'
  JOIN public.boonz_products bp ON bp.product_id = pm.boonz_product_id
),
-- Same matching predicate as _coexistence_blocks (family_id / product_brand /
-- brand_owner / name / product_id), applied symmetrically over the unordered pair.
raw_viol AS (
  SELECT a.machine_id,
         a.pod_product_id AS pod_a,
         b.pod_product_id AS pod_b,
         r.rule_group,
         CASE WHEN a.brand = b.brand THEN a.brand ELSE a.brand || ' / ' || b.brand END AS family_or_match
  FROM pod_boonz a
  JOIN pod_boonz b
    ON b.machine_id = a.machine_id
   AND a.pod_product_id < b.pod_product_id      -- distinct pods, dedupe A<B, no self-pair
  JOIN rules r ON (
    (
      ( (r.a_match_type = 'product_brand' AND a.brand = r.a_match_value) OR
        (r.a_match_type = 'brand_owner'   AND a.owner = r.a_match_value) OR
        (r.a_match_type = 'name'          AND a.nm    = r.a_match_value) OR
        (r.a_match_type = 'product_id'    AND a.boonz_id::text = r.a_match_value) OR
        (r.a_match_type = 'family_id'     AND a.fam IS NOT NULL AND a.fam::text = r.a_match_value) )
      AND
      ( (r.b_match_type = 'product_brand' AND b.brand = r.b_match_value) OR
        (r.b_match_type = 'brand_owner'   AND b.owner = r.b_match_value) OR
        (r.b_match_type = 'name'          AND b.nm    = r.b_match_value) OR
        (r.b_match_type = 'product_id'    AND b.boonz_id::text = r.b_match_value) OR
        (r.b_match_type = 'family_id'     AND b.fam IS NOT NULL AND b.fam::text = r.b_match_value) )
    )
    OR
    (
      ( (r.b_match_type = 'product_brand' AND a.brand = r.b_match_value) OR
        (r.b_match_type = 'brand_owner'   AND a.owner = r.b_match_value) OR
        (r.b_match_type = 'name'          AND a.nm    = r.b_match_value) OR
        (r.b_match_type = 'product_id'    AND a.boonz_id::text = r.b_match_value) OR
        (r.b_match_type = 'family_id'     AND a.fam IS NOT NULL AND a.fam::text = r.b_match_value) )
      AND
      ( (r.a_match_type = 'product_brand' AND b.brand = r.a_match_value) OR
        (r.a_match_type = 'brand_owner'   AND b.owner = r.a_match_value) OR
        (r.a_match_type = 'name'          AND b.nm    = r.a_match_value) OR
        (r.a_match_type = 'product_id'    AND b.boonz_id::text = r.a_match_value) OR
        (r.a_match_type = 'family_id'     AND b.fam IS NOT NULL AND b.fam::text = r.a_match_value) )
    )
  )
),
dedup AS (
  SELECT DISTINCT ON (machine_id, pod_a, pod_b)
         machine_id, pod_a, pod_b, rule_group, family_or_match
  FROM raw_viol
  ORDER BY machine_id, pod_a, pod_b, rule_group
)
SELECT
  m.official_name                              AS machine_official_name,
  d.machine_id                                 AS machine_id,
  d.rule_group                                 AS rule_group,
  d.family_or_match                            AS family_or_match,
  d.pod_a                                       AS "podA_id",
  la.pod_name                                   AS "podA_name",
  la.shelf                                      AS "podA_shelf",
  la.velocity                                   AS "podA_velocity",
  d.pod_b                                       AS "podB_id",
  lb.pod_name                                   AS "podB_name",
  lb.shelf                                      AS "podB_shelf",
  lb.velocity                                   AS "podB_velocity"
FROM dedup d
JOIN public.machines m  ON m.machine_id = d.machine_id
JOIN live_pods la ON la.machine_id = d.machine_id AND la.pod_product_id = d.pod_a
JOIN live_pods lb ON lb.machine_id = d.machine_id AND lb.pod_product_id = d.pod_b;

COMMENT ON VIEW public.v_coexistence_violations IS
'Read-only monitor of pre-existing coexistence violations: pairs of distinct live pods (slot_lifecycle is_current UNION v_live_shelf_stock>0) on a machine that break an active machine-scope coexistence_rules rule, using the same match logic as _coexistence_blocks(). Excludes rule1 tccc venue-exclusion. Cleanup aid, not enforcement; the swap engine rotates redundant variants out naturally. Migration: coexistence_violation_monitor.';
