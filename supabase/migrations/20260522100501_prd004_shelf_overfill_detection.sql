-- ============================================================================
-- PRD-004 — shelf overfill detection (audit + view)
--
-- Source PRD: docs/prds/refill-pipeline/PRD-004-engine-fills-full-shelf.md
--
-- Forensic (2026-05-22 live read): zero refill plan rows in the latest
-- approved plan that would overfill their shelf (`current_stock + qty >
-- shelf_configurations.max_capacity`). The engine cap from propose_add_plan
-- v2 G3 (RPC_REGISTRY) is doing its job at plan time.
--
-- Remaining risk surface: between plan time and pick time, machine telemetry
-- may have refreshed pod_inventory (sale events, manual count), or the engine
-- may have skipped a stale max_capacity. This migration adds reactive
-- detection at receive time + a planning-time verification view:
--
--   1. shelf_overfill_log append-only — every receive that lands stock
--      beyond shelf max_capacity gets a log row. Warn-level; never blocks.
--
--   2. Trigger on refill_dispatching UPDATE — fires when item_added flips
--      true. Computes the new pod_inventory total for the
--      (machine, shelf, boonz_product) and logs if > max_capacity.
--
--   3. v_planning_overfill_risk view — surfaces approved-plan rows whose
--      qty would overfill if all delivered. CS reads pre-pickup.
--
-- Article 7: append-only RLS on the log. Article 12: forward-only.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.shelf_overfill_log (
  overfill_id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  refill_dispatching_id  uuid        NOT NULL REFERENCES public.refill_dispatching(dispatch_id) ON DELETE CASCADE,
  machine_id             uuid        REFERENCES public.machines(machine_id) ON DELETE SET NULL,
  shelf_id               uuid        REFERENCES public.shelf_configurations(shelf_id) ON DELETE SET NULL,
  boonz_product_id       uuid        REFERENCES public.boonz_products(product_id) ON DELETE SET NULL,
  shelf_max_capacity     numeric,
  current_stock_before   numeric,
  delivered_qty          numeric,
  total_after            numeric,
  overflow_units         numeric                                      GENERATED ALWAYS AS (
                                                                       GREATEST(total_after - shelf_max_capacity, 0)
                                                                     ) STORED,
  detected_at            timestamptz NOT NULL DEFAULT now(),
  detected_by            uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  note                   text
);

COMMENT ON TABLE public.shelf_overfill_log IS
  'PRD-004: reactive detection of receives that exceed shelf max_capacity. '
  'overflow_units GENERATED as max(total_after - max_capacity, 0). Surfaces '
  'engine miscalibration or stale telemetry. Warn-level — does not block.';

CREATE INDEX IF NOT EXISTS idx_sol_machine_shelf_recent
  ON public.shelf_overfill_log (machine_id, shelf_id, detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_sol_overflow_severity
  ON public.shelf_overfill_log (overflow_units DESC)
  WHERE overflow_units > 0;

ALTER TABLE public.shelf_overfill_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sol_select ON public.shelf_overfill_log;
CREATE POLICY sol_select ON public.shelf_overfill_log
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS sol_insert ON public.shelf_overfill_log;
CREATE POLICY sol_insert ON public.shelf_overfill_log
  FOR INSERT TO authenticated WITH CHECK (true);
DROP POLICY IF EXISTS sol_no_update ON public.shelf_overfill_log;
CREATE POLICY sol_no_update ON public.shelf_overfill_log
  FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
DROP POLICY IF EXISTS sol_no_delete ON public.shelf_overfill_log;
CREATE POLICY sol_no_delete ON public.shelf_overfill_log
  FOR DELETE TO authenticated USING (false);

CREATE OR REPLACE FUNCTION public.detect_shelf_overfill_on_receive()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := (SELECT auth.uid());
  v_max_cap numeric;
  v_existing numeric;
  v_total numeric;
BEGIN
  -- Only fire on the item_added=true transition for Refill/Add/Add New
  IF NOT (OLD.item_added IS DISTINCT FROM NEW.item_added AND NEW.item_added = true)
     OR NEW.action NOT IN ('Refill','Add New','Add')
     OR COALESCE(NEW.filled_quantity, 0) <= 0
  THEN
    RETURN NEW;
  END IF;

  SELECT max_capacity INTO v_max_cap
  FROM shelf_configurations
  WHERE shelf_id = NEW.shelf_id;

  IF v_max_cap IS NULL OR v_max_cap <= 0 THEN
    RETURN NEW;  -- no cap to compare against
  END IF;

  -- Sum of existing Active pod_inventory on this shelf+product (the
  -- receive_dispatch_line UPSERT will then add filled_quantity to this).
  SELECT COALESCE(SUM(current_stock), 0) INTO v_existing
  FROM pod_inventory
  WHERE machine_id = NEW.machine_id
    AND shelf_id = NEW.shelf_id
    AND boonz_product_id = NEW.boonz_product_id
    AND status = 'Active'
    -- exclude the row this dispatch is about to create/update — best-effort:
    -- the snapshot_date may already match; if so, subtract the inserted row's
    -- prior current_stock (heuristic; trigger fires AFTER the UPDATE on
    -- refill_dispatching but before receive_dispatch_line's pod_inventory
    -- UPSERT runs — so pod_inventory.current_stock here is pre-receive).
  ;

  v_total := v_existing + NEW.filled_quantity;

  IF v_total > v_max_cap THEN
    INSERT INTO public.shelf_overfill_log
      (refill_dispatching_id, machine_id, shelf_id, boonz_product_id,
       shelf_max_capacity, current_stock_before, delivered_qty, total_after,
       detected_by, note)
    VALUES
      (NEW.dispatch_id, NEW.machine_id, NEW.shelf_id, NEW.boonz_product_id,
       v_max_cap, v_existing, NEW.filled_quantity, v_total, v_uid,
       format('Action=%s, plan_qty=%s, filled=%s, max_cap=%s',
              NEW.action, NEW.quantity, NEW.filled_quantity, v_max_cap));
  END IF;

  RETURN NEW;
END
$$;

REVOKE EXECUTE ON FUNCTION public.detect_shelf_overfill_on_receive() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_detect_shelf_overfill ON public.refill_dispatching;
CREATE TRIGGER trg_detect_shelf_overfill
  AFTER UPDATE ON public.refill_dispatching
  FOR EACH ROW EXECUTE FUNCTION public.detect_shelf_overfill_on_receive();

-- v_planning_overfill_risk: pre-pickup check
CREATE OR REPLACE VIEW public.v_planning_overfill_risk
WITH (security_invoker = true) AS
WITH plan_active AS (
  SELECT prp.plan_date, prp.machine_id, prp.shelf_id, prp.pod_product_id,
         prp.qty AS planned_qty
  FROM pod_refill_plan prp
  WHERE prp.status = 'approved' AND prp.action IN ('REFILL','ADD_NEW')
),
shelf_fill AS (
  SELECT machine_id, shelf_id, SUM(current_stock)::numeric AS current_stock
  FROM pod_inventory WHERE status='Active'
  GROUP BY machine_id, shelf_id
)
SELECT
  p.plan_date,
  m.official_name AS machine_name,
  sc.shelf_code,
  sc.max_capacity,
  COALESCE(sf.current_stock, 0) AS current_stock,
  p.planned_qty,
  COALESCE(sf.current_stock, 0) + p.planned_qty AS would_become,
  GREATEST(COALESCE(sf.current_stock, 0) + p.planned_qty - sc.max_capacity, 0) AS would_overflow
FROM plan_active p
LEFT JOIN machines m ON m.machine_id = p.machine_id
LEFT JOIN shelf_configurations sc ON sc.shelf_id = p.shelf_id
LEFT JOIN shelf_fill sf ON sf.machine_id = p.machine_id AND sf.shelf_id = p.shelf_id
WHERE sc.max_capacity IS NOT NULL AND sc.max_capacity > 0
  AND COALESCE(sf.current_stock, 0) + p.planned_qty > sc.max_capacity;

COMMENT ON VIEW public.v_planning_overfill_risk IS
  'PRD-004 pre-pickup verification: any approved plan row that would overfill '
  'its shelf if delivered as planned. Empty result = engine cap is doing its job.';

COMMIT;

-- ============================================================================
-- POST-APPLY USAGE
--   -- Pre-pickup overfill risk for tomorrow''s plan
--   SELECT * FROM v_planning_overfill_risk
--   WHERE plan_date = CURRENT_DATE + 1
--   ORDER BY would_overflow DESC;
--
--   -- Receives that did overfill in the last 7 days
--   SELECT * FROM shelf_overfill_log
--   WHERE detected_at >= NOW() - INTERVAL '7 days'
--   ORDER BY overflow_units DESC;
-- ============================================================================
