-- PRD-110 P1.2 - `shelf_state` canonical view (WS-A1). Ships as `v_shelf_state` (house `v_*` convention).
-- ONE row per enabled, non-phantom shelf. Enabled := machine status='Active' AND include_in_refill=true,
-- which is EXACTLY the scope guard of seed_missing_slot_lifecycle (P0.2), so coverage is comparable.
-- DATA-SOURCE LAW honoured: WEIMI (via v_shelf_slot_identity -> v_live_shelf_stock) is the only
-- slot-product identity + stock source; slot_lifecycle is joined by shelf_id ONLY; pod_inventory is
-- read for expiry ONLY (via v_machine_expiry_batches); sourcing comes from v_product_sourcing_current
-- / resolve_product_sourcing_v3, never from product_mapping.
CREATE OR REPLACE VIEW public.v_shelf_state
WITH (security_invoker = true) AS
WITH base AS (
  SELECT sc.shelf_id, sc.machine_id, sc.shelf_code,
         m.official_name   AS machine_name,
         m.operating_model AS operating_model
  FROM public.shelf_configurations sc
  JOIN public.machines m ON m.machine_id = sc.machine_id
  WHERE sc.is_phantom = false
    AND m.status = 'Active'
    AND m.include_in_refill = true
),
life AS (   -- slot_lifecycle: join by shelf_id ONLY; one row per shelf (newest evaluation wins)
  SELECT DISTINCT ON (sl.shelf_id)
         sl.shelf_id, sl.velocity_30d, sl.signal, sl.score
  FROM public.slot_lifecycle sl
  WHERE sl.archived = false AND sl.is_current = true
  ORDER BY sl.shelf_id, sl.last_evaluated_at DESC NULLS LAST
),
srcagg AS ( -- shelf-grain summary of the SKU-grain canonical sourcing object
  SELECT c.machine_id, c.pod_product_id,
         CASE WHEN count(DISTINCT c.source) = 1 THEN min(c.source) ELSE 'mixed' END AS pod_source
  FROM public.v_product_sourcing_current c
  GROUP BY c.machine_id, c.pod_product_id
),
verified AS ( -- shelf-grain PHYSICAL evidence: executed dispatch OR manual-refill/adjust audit
  SELECT ev.shelf_id, max(ev.evidence_date) AS last_verified
  FROM (
    SELECT rd.shelf_id, rd.dispatch_date AS evidence_date
      FROM public.refill_dispatching rd
     WHERE rd.cancelled = false AND rd.skipped = false
       AND (rd.picked_up OR rd.returned OR rd.dispatched OR rd.packed)
       AND rd.shelf_id IS NOT NULL
    UNION ALL
    SELECT pal.shelf_id, pal.created_at::date
      FROM public.pod_inventory_audit_log pal
     WHERE (pal.reference_id LIKE 'manual-refill-%' OR pal.reference_id LIKE 'adjust-%')
       AND pal.shelf_id IS NOT NULL
  ) ev
  GROUP BY ev.shelf_id
)
SELECT
  b.machine_id,
  b.machine_name,
  b.operating_model,                                        -- NULL = unclassified (D-07 parked)
  b.shelf_id,
  b.shelf_code,                                             -- canonical zero-padded form (A01)
  i.slot_name,                                              -- WEIMI form (A1); join key to v_slot_capacity
  i.pod_product_id,                                         -- WEIMI identity ONLY (never slot_lifecycle)
  i.pod_product_name AS pod_name,
  CASE WHEN i.pod_product_id IS NULL THEN NULL
       ELSE count(*) OVER (PARTITION BY b.machine_id, i.pod_product_id) END AS pod_shelf_count,
  COALESCE(
    s.pod_source,
    CASE WHEN i.pod_product_id IS NOT NULL
         THEN public.resolve_product_sourcing_v3(b.machine_id, i.pod_product_id, NULL) END
  )                                        AS sourcing,     -- boonz_wh | venue | partner | mixed | NULL
  i.current_stock,                                          -- latest WEIMI count
  COALESCE(vc.effective_max_stock, i.max_stock) AS max_stock,
  i.snapshot_at                            AS stock_as_of,  -- sensor freshness
  l.velocity_30d                           AS velocity_raw, -- units/DAY, 30d window, (machine,pod) grain
  NULL::numeric                            AS velocity_instock,       -- P2.1
  l.signal,
  l.score,
  NULL::numeric                            AS composition_confidence, -- P1.4
  ex.oldest_expiry_est,
  (CURRENT_DATE - v.last_verified)::int    AS days_since_verified,    -- NULL = never verified
  h.days_since_visit                                                   -- PRD-074 SSOT passthrough
FROM base b
LEFT JOIN public.v_shelf_slot_identity i  ON i.shelf_id = b.shelf_id
LEFT JOIN public.v_slot_capacity vc       ON vc.machine_id = b.machine_id AND vc.slot_name = i.slot_name
LEFT JOIN life l                          ON l.shelf_id = b.shelf_id
LEFT JOIN srcagg s                        ON s.machine_id = b.machine_id AND s.pod_product_id = i.pod_product_id
LEFT JOIN verified v                      ON v.shelf_id = b.shelf_id
LEFT JOIN public.v_machine_health_signals h ON h.machine_id = b.machine_id
LEFT JOIN LATERAL (
  SELECT min(e.expiration_date) AS oldest_expiry_est
  FROM public.v_machine_expiry_batches e
  WHERE e.shelf_id = b.shelf_id AND e.current_stock > 0
) ex ON true;

COMMENT ON VIEW public.v_shelf_state IS
'PRD-110 P1.2 (WS-A1) canonical shelf-state object. One row per non-phantom shelf on an Active, include_in_refill machine. Sources: identity+stock=WEIMI via v_shelf_slot_identity; capacity=v_slot_capacity.effective_max_stock (falls back to live WEIMI max); velocity/signal/score=slot_lifecycle joined by shelf_id ONLY; sourcing=v_product_sourcing_current aggregated to pod grain (mixed => resolve per SKU with resolve_product_sourcing_v3); expiry=v_machine_expiry_batches; days_since_visit=v_machine_health_signals (PRD-074 SSOT passthrough, never re-derived). velocity_instock is NULL until P2.1; composition_confidence is NULL until P1.4. velocity_raw is (machine,pod)-grain and REPLICATED across the pod''s shelves - never SUM it; pod_shelf_count is the replication factor.';

REVOKE ALL ON public.v_shelf_state FROM anon;
GRANT SELECT ON public.v_shelf_state TO authenticated, service_role;
