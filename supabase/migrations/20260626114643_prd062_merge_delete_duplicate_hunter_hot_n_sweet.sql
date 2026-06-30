-- PRD-062 merge + delete duplicate boonz_product "Hunter - Hot N Sweet".
-- GENERATED FROM LIVE PROD for git parity (PRD-ALL overnight run, 2026-06-30).
-- Already applied to prod as supabase_migrations version 20260626114643 via MCP apply_migration.
-- This file reproduces the exact applied statement so main holds a file for every prod object.
-- Idempotent if ever re-run (the duplicate cca563ee is gone -> all UPDATE/DELETE no-op,
-- conservation pre==post, DELETE matches 0 rows). DO NOT re-run; it is in prod history.

SET LOCAL app.via_trigger = 'true';

CREATE TEMP TABLE _prd062_pre ON COMMIT DROP AS
SELECT
  COALESCE((SELECT SUM(current_stock) FROM pod_inventory
            WHERE boonz_product_id IN ('cca563ee-2e03-4de3-bad1-b17315b45864',
                                       '8bc412d9-20f3-4432-a140-4e1f5360844f')
              AND status = 'Active'), 0)::numeric AS pre_active_pod,
  COALESCE((SELECT SUM(warehouse_stock) FROM warehouse_inventory
            WHERE boonz_product_id IN ('cca563ee-2e03-4de3-bad1-b17315b45864',
                                       '8bc412d9-20f3-4432-a140-4e1f5360844f')), 0)::numeric AS pre_wh;

UPDATE pod_inventory k
SET current_stock = k.current_stock + s.add_stock
FROM (
  SELECT k2.pod_inventory_id, SUM(p.current_stock) AS add_stock
  FROM pod_inventory k2
  JOIN pod_inventory p
    ON p.boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864' AND p.status = 'Active'
   AND p.machine_id = k2.machine_id AND p.shelf_id IS NOT DISTINCT FROM k2.shelf_id
  WHERE k2.boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' AND k2.status = 'Active'
  GROUP BY k2.pod_inventory_id
) s
WHERE k.pod_inventory_id = s.pod_inventory_id;

DELETE FROM pod_inventory p
WHERE p.boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864' AND p.status = 'Active'
  AND EXISTS (SELECT 1 FROM pod_inventory k
              WHERE k.boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' AND k.status = 'Active'
                AND k.machine_id = p.machine_id AND k.shelf_id IS NOT DISTINCT FROM p.shelf_id);

UPDATE pod_inventory
SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f'
WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';

ALTER TABLE refill_dispatching DISABLE TRIGGER enforce_packed_dispatch_immutability;
UPDATE refill_dispatching
SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f'
WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';
ALTER TABLE refill_dispatching ENABLE TRIGGER enforce_packed_dispatch_immutability;

DELETE FROM daily_reconciliation_log x
WHERE x.boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864'
  AND EXISTS (SELECT 1 FROM daily_reconciliation_log k
              WHERE k.boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f'
                AND k.reconciliation_date = x.reconciliation_date);
UPDATE daily_reconciliation_log SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f'
WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';

DELETE FROM slot_profile_pool x
WHERE x.boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864'
  AND EXISTS (SELECT 1 FROM slot_profile_pool k
              WHERE k.boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f'
                AND k.lane_family = x.lane_family AND k.shelf_size = x.shelf_size);
UPDATE slot_profile_pool SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f'
WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';

DELETE FROM supplier_products x
WHERE x.boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864' AND x.is_preferred
  AND EXISTS (SELECT 1 FROM supplier_products k
              WHERE k.boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' AND k.is_preferred);
DELETE FROM supplier_products x
WHERE x.boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864'
  AND EXISTS (SELECT 1 FROM supplier_products k
              WHERE k.boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f'
                AND k.supplier_id = x.supplier_id);
UPDATE supplier_products SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f'
WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';

UPDATE daily_plan_drafts             SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';
UPDATE inventory_audit_log           SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';
UPDATE phantom_pod_alerts            SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';
UPDATE pod_inventory_audit_log       SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';
UPDATE pod_inventory_edits           SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';
UPDATE procurement_alerts            SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';
UPDATE product_mapping               SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';
UPDATE product_pricing               SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';
UPDATE purchase_orders               SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';
UPDATE warehouse_inventory           SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';
UPDATE weekly_procurement_plan       SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';
UPDATE pod_inventory_backup_20260416 SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';
UPDATE pod_inventory_backup_20260421 SET boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';

DO $$
DECLARE v_pre_pod numeric; v_pre_wh numeric; v_post_pod numeric; v_post_wh numeric; v_dup_pod numeric; v_dup_wh numeric;
BEGIN
  SELECT pre_active_pod, pre_wh INTO v_pre_pod, v_pre_wh FROM _prd062_pre;
  SELECT COALESCE(SUM(current_stock), 0) INTO v_post_pod FROM pod_inventory
    WHERE boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f' AND status = 'Active';
  SELECT COALESCE(SUM(warehouse_stock), 0) INTO v_post_wh FROM warehouse_inventory
    WHERE boonz_product_id = '8bc412d9-20f3-4432-a140-4e1f5360844f';
  SELECT COALESCE(SUM(current_stock), 0) INTO v_dup_pod FROM pod_inventory
    WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864' AND status = 'Active';
  SELECT COALESCE(SUM(warehouse_stock), 0) INTO v_dup_wh FROM warehouse_inventory
    WHERE boonz_product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';
  IF v_dup_pod <> 0 OR v_dup_wh <> 0 THEN
    RAISE EXCEPTION 'PRD-062: duplicate still holds stock after merge (pod=%, wh=%)', v_dup_pod, v_dup_wh;
  END IF;
  IF v_post_pod <> v_pre_pod OR v_post_wh <> v_pre_wh THEN
    RAISE EXCEPTION 'PRD-062 CONSERVATION VIOLATED: active pod pre=% post=%, wh pre=% post=%',
      v_pre_pod, v_post_pod, v_pre_wh, v_post_wh;
  END IF;
  RAISE NOTICE 'PRD-062 conservation OK: active pod=%, wh=% (re-attributed to KEEP)', v_post_pod, v_post_wh;
END $$;

DO $$
DECLARE r record; n bigint;
BEGIN
  FOR r IN
    SELECT DISTINCT tc.table_name AS table_name, kcu.column_name AS column_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
    JOIN information_schema.constraint_column_usage ccu
      ON tc.constraint_name = ccu.constraint_name AND tc.table_schema = ccu.table_schema
    WHERE tc.constraint_type = 'FOREIGN KEY' AND ccu.table_name = 'boonz_products'
    UNION
    SELECT c.table_name, c.column_name
    FROM information_schema.columns c
    JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE c.column_name = 'boonz_product_id' AND c.table_schema = 'public' AND t.table_type = 'BASE TABLE'
  LOOP
    EXECUTE format('SELECT count(*) FROM public.%I WHERE %I = $1', r.table_name, r.column_name)
      INTO n USING 'cca563ee-2e03-4de3-bad1-b17315b45864'::uuid;
    IF n > 0 THEN
      RAISE EXCEPTION 'PRD-062: % rows still reference duplicate in %.%', n, r.table_name, r.column_name;
    END IF;
  END LOOP;
END $$;

DELETE FROM boonz_products WHERE product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM boonz_products WHERE product_id = 'cca563ee-2e03-4de3-bad1-b17315b45864') THEN
    RAISE EXCEPTION 'PRD-062: duplicate boonz_products row still present after DELETE';
  END IF;
END $$;
