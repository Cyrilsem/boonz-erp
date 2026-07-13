-- p0_fix17: deactivate machine-specific product_mapping rows that are byte-identical
-- to their pair's active global row on split_pct, mix_weight, source_of_supply.
-- Never DELETE. Lock table clean with partial unique indexes afterwards.

DO $$
DECLARE
  v_count int;
BEGIN
  WITH g AS (
    SELECT pod_product_id, boonz_product_id, split_pct, mix_weight, source_of_supply
    FROM public.product_mapping
    WHERE machine_id IS NULL AND status = 'Active'
  ),
  noise AS (
    SELECT m.mapping_id
    FROM public.product_mapping m
    JOIN g ON g.pod_product_id = m.pod_product_id
          AND g.boonz_product_id = m.boonz_product_id
    WHERE m.machine_id IS NOT NULL
      AND m.status = 'Active'
      AND m.split_pct IS NOT DISTINCT FROM g.split_pct
      AND m.mix_weight IS NOT DISTINCT FROM g.mix_weight
      AND m.source_of_supply IS NOT DISTINCT FROM g.source_of_supply
  ),
  upd AS (
    UPDATE public.product_mapping pm
       SET status = 'Inactive', updated_at = now()
     WHERE pm.mapping_id IN (SELECT mapping_id FROM noise)
    RETURNING pm.mapping_id
  )
  SELECT count(*) INTO v_count FROM upd;

  -- sanity guard: audit said 4,280; abort if wildly off (data drifted since audit)
  IF v_count < 4000 OR v_count > 4600 THEN
    RAISE EXCEPTION 'p0_fix17 aborted: noise count % outside expected band 4000-4600', v_count;
  END IF;

  INSERT INTO public.monitoring_alerts (source, severity, payload)
  VALUES (
    'p0_fix17_product_mapping_dedup_noise',
    'info',
    jsonb_build_object(
      'action', 'deactivated machine-specific product_mapping rows identical to global row',
      'columns_compared', jsonb_build_array('split_pct','mix_weight','source_of_supply'),
      'rows_deactivated', v_count,
      'note', 'rows set Inactive, not deleted; avg_cost divergence on subset verified inert (v_product_landed_cost fallback unaffected)'
    )
  );
END $$;

-- Lock the table clean: one active global row per (pod,boonz) pair,
-- one active machine row per (pod,boonz,machine).
CREATE UNIQUE INDEX IF NOT EXISTS uq_pm_global_pair
  ON public.product_mapping (pod_product_id, boonz_product_id)
  WHERE machine_id IS NULL AND status = 'Active';

CREATE UNIQUE INDEX IF NOT EXISTS uq_pm_machine_pair
  ON public.product_mapping (pod_product_id, boonz_product_id, machine_id)
  WHERE status = 'Active' AND machine_id IS NOT NULL;
