-- PRD-118 item D fix #2: engine_add_pod's wh_avail computation (candidates CTE) must
-- exclude sentinel rows. NOTE: wh_avail is a pre-existing, registry-acknowledged inline
-- re-derivation of v_wh_pickable's shape (METRICS_REGISTRY.md: "grandfathered v18 debt",
-- ticketed PRD-110 P2.1). This patch does not close that ticket — it only stops the
-- sentinel leak inside the existing debt. P2.1 (engine_add_pod_v3 reading
-- v_shelf_availability_v3 properly) remains open. Verified against md5
-- 03844dde6a0d713331c0eeddd92a30d4. Proven live (standalone predicate replica, since
-- invoking the full RPC risks touching plan_date 2026-09-01 gating even inside a
-- rollback): wh_avail for 7Up-Diet at VOXMCC-1005 drops from 1033 (sentinel-polluted)
-- to 34 (real CENTRAL stock only). Cody: approve with revision noted (Article 16 debt
-- pre-existing, not newly introduced or closed by this patch).
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.proname='engine_add_pod' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '03844dde6a0d713331c0eeddd92a30d4' THEN
    RAISE EXCEPTION 'engine_add_pod drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;
  v_new := replace(v_def,
$$         AND wi.warehouse_id = ANY (ARRAY[mwh.primary_warehouse_id, mwh.secondary_warehouse_id])
         AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = sl.machine_id)
        WHERE pm.pod_product_id = wid.identity_pod AND pm.status = 'Active'$$,
$$         AND wi.warehouse_id = ANY (ARRAY[mwh.primary_warehouse_id, mwh.secondary_warehouse_id])
         AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = sl.machine_id)
         AND NOT public._is_phantom_wh_row_v3(wi.batch_id, wi.expiration_date)
        WHERE pm.pod_product_id = wid.identity_pod AND pm.status = 'Active'$$);
  IF v_new = v_def THEN RAISE EXCEPTION 'wh_avail subquery WHERE clause not found'; END IF;
  EXECUTE v_new;
END $mig$;
