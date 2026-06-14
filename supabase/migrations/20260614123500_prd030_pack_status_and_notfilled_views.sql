-- PRD-030 step 3c: canonical readiness + unfilled-demand views (Article 16).
CREATE OR REPLACE VIEW public.v_machine_pack_status AS
WITH lines AS (
  SELECT rd.machine_id, rd.dispatch_date,
    count(*) FILTER (WHERE COALESCE(rd.include,true) AND NOT COALESCE(rd.cancelled,false)) AS total_included,
    count(*) FILTER (WHERE COALESCE(rd.include,true) AND NOT COALESCE(rd.cancelled,false)
                       AND (rd.packed OR rd.skipped OR rd.pack_outcome='not_filled')) AS resolved,
    count(*) FILTER (WHERE rd.packed AND COALESCE(rd.include,true) AND NOT COALESCE(rd.cancelled,false)) AS physical,
    count(*) FILTER (WHERE rd.pack_outcome='not_filled' AND NOT COALESCE(rd.cancelled,false)) AS not_filled,
    count(*) FILTER (WHERE rd.pack_outcome='partial' AND NOT COALESCE(rd.cancelled,false)) AS partial,
    count(*) FILTER (WHERE rd.skipped AND NOT COALESCE(rd.cancelled,false)) AS skipped,
    count(*) FILTER (WHERE rd.packed AND rd.picked_up  AND COALESCE(rd.include,true) AND NOT COALESCE(rd.cancelled,false)) AS picked_up_physical,
    count(*) FILTER (WHERE rd.packed AND rd.dispatched AND COALESCE(rd.include,true) AND NOT COALESCE(rd.cancelled,false)) AS dispatched_physical
  FROM refill_dispatching rd GROUP BY rd.machine_id, rd.dispatch_date
)
SELECT l.machine_id, l.dispatch_date, m.official_name AS machine_name,
  l.total_included, l.resolved, l.physical, l.not_filled, l.partial, l.skipped,
  l.picked_up_physical, l.dispatched_physical,
  (l.total_included > 0 AND l.resolved = l.total_included) AS is_pack_complete,
  (l.picked_up_physical = l.physical) AS is_pickup_complete,
  (l.dispatched_physical = l.physical) AS is_dispatch_complete,
  (c.machine_id IS NOT NULL) AS pack_confirmed, c.confirmed_at, c.confirmed_by
FROM lines l
JOIN machines m ON m.machine_id = l.machine_id
LEFT JOIN dispatch_pack_confirmation c ON c.machine_id = l.machine_id AND c.dispatch_date = l.dispatch_date;
COMMENT ON VIEW public.v_machine_pack_status IS 'PRD-030 / Article 16 canonical machine pack/pickup/dispatch readiness. is_pack_complete = every included non-cancelled line resolved (packed/partial/not_filled/skipped); pickup/dispatch over PHYSICAL lines only so not_filled/skipped never block. FE reads this; no client-side count re-derivation.';

CREATE OR REPLACE VIEW public.v_not_filled_lines AS
SELECT rd.dispatch_date, rd.machine_id, m.official_name AS machine_name, rd.shelf_id, sc.shelf_code,
  rd.pod_product_id, pp.pod_product_name, rd.boonz_product_id, bp.boonz_product_name, rd.action,
  max(COALESCE(rd.original_quantity, rd.quantity)) AS planned_quantity,
  sum(COALESCE(rd.filled_quantity, 0::numeric)) AS filled_quantity,
  (max(COALESCE(rd.original_quantity, rd.quantity)) - sum(COALESCE(rd.filled_quantity, 0::numeric))) AS shortfall,
  CASE WHEN bool_or(rd.pack_outcome='not_filled') THEN 'full_not_filled' ELSE 'partial_remainder' END AS kind
FROM refill_dispatching rd
JOIN machines m ON m.machine_id = rd.machine_id
LEFT JOIN shelf_configurations sc ON sc.shelf_id = rd.shelf_id
LEFT JOIN pod_products pp ON pp.pod_product_id = rd.pod_product_id
LEFT JOIN boonz_products bp ON bp.product_id = rd.boonz_product_id
WHERE NOT COALESCE(rd.cancelled, false) AND rd.pack_outcome = ANY (ARRAY['not_filled'::pack_outcome_enum,'partial'::pack_outcome_enum])
GROUP BY rd.dispatch_date, rd.machine_id, m.official_name, rd.shelf_id, sc.shelf_code,
         rd.pod_product_id, pp.pod_product_name, rd.boonz_product_id, bp.boonz_product_name, rd.action
HAVING (max(COALESCE(rd.original_quantity, rd.quantity)) - sum(COALESCE(rd.filled_quantity, 0::numeric))) > 0::numeric;
COMMENT ON VIEW public.v_not_filled_lines IS 'PRD-030 / Article 16 canonical unfilled-demand feed (procurement, PRD-031). One row per line with shortfall>0: full not_filled OR partial remainder (kind column).';
