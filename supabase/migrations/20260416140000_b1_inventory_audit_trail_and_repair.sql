-- ========================================================================
-- Phase B1 (CORRECTED): Audit trail + data repair
-- Fixes blockers identified in pre-flight check:
--   - Blocker 1: NOT NULL adjusted_by breaks service_role writes
--   - Blocker 2: trigger fires before repair runs as service_role
--   - Blocker 3: delta is GENERATED ALWAYS, cannot be inserted
-- Resolution: drop NOT NULL on adjusted_by, run repairs BEFORE creating trigger,
--             omit delta from INSERTs (auto-computed by table).
-- ========================================================================

-- 0. Allow audit rows without a logged-in user (service_role, migrations, cron)
ALTER TABLE public.inventory_audit_log
  ALTER COLUMN adjusted_by DROP NOT NULL;

COMMENT ON COLUMN public.inventory_audit_log.adjusted_by IS
'Auth UID of the human who made the change. NULL for service_role / migration / cron writes — in those cases the source is captured in the reason column.';

-- 1. Helper for explicit RPC-driven audit writes (kept for Phase B2/B3 RPCs)
--    Note: delta is GENERATED ALWAYS AS (new_qty - old_qty), so it's not in the column list.
CREATE OR REPLACE FUNCTION public.log_wh_mutation(
  p_wh_inventory_id uuid,
  p_boonz_product_id uuid,
  p_adjusted_by uuid,
  p_old_qty numeric,
  p_new_qty numeric,
  p_reason text
) RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = public
AS $$
  INSERT INTO inventory_audit_log
    (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at)
  VALUES
    (p_wh_inventory_id, p_boonz_product_id, p_adjusted_by, p_old_qty, p_new_qty,
     p_reason, now())
$$;

GRANT EXECUTE ON FUNCTION public.log_wh_mutation TO authenticated;

-- 2. Drift review queue (created BEFORE repair so we can populate it)
CREATE TABLE IF NOT EXISTS public.inventory_drift_candidates (
  candidate_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispatch_id uuid REFERENCES refill_dispatching(dispatch_id) ON DELETE CASCADE,
  machine_id uuid REFERENCES machines(machine_id),
  boonz_product_id uuid REFERENCES boonz_products(product_id),
  dispatch_date date,
  action text,
  planned_qty numeric,
  filled_qty numeric,
  qty_gap numeric,
  wh_stock_current numeric,
  pod_stock_current numeric,
  status text DEFAULT 'pending_review' CHECK (status IN ('pending_review','confirmed_drift','ignored','repaired')),
  notes text,
  created_at timestamptz DEFAULT now(),
  reviewed_at timestamptz,
  reviewed_by uuid REFERENCES auth.users(id)
);

ALTER TABLE public.inventory_drift_candidates ENABLE ROW LEVEL SECURITY;

CREATE POLICY drift_read ON public.inventory_drift_candidates
  FOR SELECT TO authenticated USING (true);

-- Only operator_admin exists in this DB; superadmin/manager kept for future expansion (no-op today)
CREATE POLICY drift_admin_write ON public.inventory_drift_candidates
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles
                 WHERE id = (SELECT auth.uid())
                   AND role IN ('operator_admin','superadmin','manager')))
  WITH CHECK (EXISTS (SELECT 1 FROM user_profiles
                      WHERE id = (SELECT auth.uid())
                        AND role IN ('operator_admin','superadmin','manager')));

-- 3. Populate drift candidates BEFORE the trigger fires (this is just an INSERT to a new table, no audit needed)
INSERT INTO public.inventory_drift_candidates
  (dispatch_id, machine_id, boonz_product_id, dispatch_date, action,
   planned_qty, filled_qty, qty_gap, wh_stock_current, pod_stock_current)
SELECT
  rd.dispatch_id,
  rd.machine_id,
  rd.boonz_product_id,
  rd.dispatch_date,
  rd.action,
  rd.quantity,
  rd.filled_quantity,
  rd.quantity - rd.filled_quantity,
  (SELECT SUM(warehouse_stock) FROM warehouse_inventory
    WHERE boonz_product_id = rd.boonz_product_id AND status = 'Active'),
  (SELECT SUM(current_stock) FROM pod_inventory
    WHERE boonz_product_id = rd.boonz_product_id
      AND machine_id = rd.machine_id
      AND status = 'Active')
FROM refill_dispatching rd
WHERE rd.dispatched = true
  AND rd.dispatch_date >= '2026-04-03'
  AND rd.dispatch_date <= CURRENT_DATE
  AND rd.quantity IS NOT NULL
  AND rd.filled_quantity IS NOT NULL
  AND rd.filled_quantity < rd.quantity
  AND rd.dispatch_id != '31708bc6-2423-4070-9952-c37d13c02c1e'  -- exclude Coco Max, repaired below
ORDER BY rd.dispatch_date DESC, rd.created_at DESC;

-- 4. Repair Coco Max BEFORE the trigger exists.
--    We write the audit log entry by hand so the repair has a paper trail
--    even though it ran before the auto-trigger was installed.
DO $$
DECLARE
  v_old_wh numeric;
BEGIN
  SELECT warehouse_stock INTO v_old_wh
  FROM warehouse_inventory
  WHERE wh_inventory_id = 'a05194c5-ebc2-477a-81eb-9e3443d35347';

  -- Manual audit row (trigger doesn't exist yet); delta omitted (generated column)
  INSERT INTO inventory_audit_log
    (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at)
  VALUES
    ('a05194c5-ebc2-477a-81eb-9e3443d35347',
     'c3e53989-80a3-4f58-adfd-27adad2dc93d',
     NULL,
     v_old_wh,
     3,
     'B1 repair: Coco Max Huawei 2026-04-16 — restore WH to post-dispatch physical truth (9 - 6 moved = 3). Driver confirmed 6 units physically placed; system had recorded filled_quantity=3 due to the pre-fix 2-stage flow bug.',
     now());

  -- The actual repair
  UPDATE warehouse_inventory
  SET warehouse_stock = 3
  WHERE wh_inventory_id = 'a05194c5-ebc2-477a-81eb-9e3443d35347';

  UPDATE refill_dispatching
  SET filled_quantity = 6
  WHERE dispatch_id = '31708bc6-2423-4070-9952-c37d13c02c1e';
END $$;

-- 5. NOW create the auto-audit trigger (after the repair has run, so it doesn't block itself)
CREATE OR REPLACE FUNCTION public.auto_audit_warehouse_inventory()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_reason text;
  v_uid uuid;
BEGIN
  -- Only log if warehouse_stock or consumer_stock actually changed
  IF OLD.warehouse_stock IS DISTINCT FROM NEW.warehouse_stock
     OR OLD.consumer_stock IS DISTINCT FROM NEW.consumer_stock THEN

    v_uid := (SELECT auth.uid());
    v_reason := COALESCE(
      current_setting('app.mutation_reason', true),
      CASE
        WHEN v_uid IS NULL THEN 'service_role_write_unattributed'
        ELSE 'authenticated_write_no_reason_set'
      END
    );

    -- delta omitted: GENERATED ALWAYS AS (new_qty - old_qty)
    INSERT INTO inventory_audit_log
      (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at)
    VALUES
      (NEW.wh_inventory_id, NEW.boonz_product_id,
       v_uid,  -- nullable now; service_role gets NULL, reason carries the context
       OLD.warehouse_stock, NEW.warehouse_stock,
       v_reason,
       now());
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_wh_inventory ON public.warehouse_inventory;
CREATE TRIGGER trg_audit_wh_inventory
AFTER UPDATE ON public.warehouse_inventory
FOR EACH ROW EXECUTE FUNCTION public.auto_audit_warehouse_inventory();
