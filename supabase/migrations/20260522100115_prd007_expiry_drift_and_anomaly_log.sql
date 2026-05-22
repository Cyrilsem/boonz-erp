-- ============================================================================
-- PRD-007 — expiry drift detection + PO receive anomaly warning
--
-- Source PRD: docs/prds/refill-pipeline/PRD-007-expiry-wrong-in-dispatch.md
--
-- Existing infrastructure already addresses most of PRD-007:
--   - refill_dispatching.from_wh_inventory_id pins the FEFO-resolved batch
--     at pack time (BUG-006).
--   - sync_dispatch_expiry_from_pinned_wh trigger (2026-05-14) propagates
--     wh_inventory.expiration_date changes to refill_dispatching.expiry_date
--     on un-finalized rows.
--   - receive_dispatch_line computes v_effective_expiry from the pinned wh
--     row (live), falling back to v_dispatch.expiry_date.
--
-- What this migration adds:
--   1. `expiry_drift_log` — append-only audit row each time the pinned wh
--      row's expiration_date OR the refill_dispatching cached expiry differs
--      between plan time and pick/receive time. Surfaces the silent display
--      drift PRD-007 names.
--
--   2. Trigger `log_dispatch_expiry_drift` on refill_dispatching that
--      writes a drift_log row whenever from_wh_inventory_id changes
--      mid-flight (the driver took a different batch than was pinned),
--      OR when item_added flips true and the actual pinned-batch expiry
--      differs from the cached expiry_date by more than 14 days
--      (the soft-hold threshold from PRD-007 Decisions).
--
--   3. `wh_expiry_anomaly_log` + trigger on warehouse_inventory INSERT
--      that flags expiration_date < 30 days OR > 24 months from today.
--      WARN-level: does not block the insert (receive_purchase_order
--      already rejects NULL expiry per BUG-009); just surfaces the
--      anomaly for CS review.
--
--   4. `v_dispatch_expiry_verification` — read-only view for the
--      USH Hot N Sweet diagnostic + per-machine-shelf "is the displayed
--      expiry actually the FEFO batch?" check.
--
-- Cody Articles: 7 (both log tables append-only), 12 (forward-only),
-- 14 (no _v2 tables).
-- ============================================================================

BEGIN;

-- ── 1. expiry_drift_log table ───────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.expiry_drift_log (
  drift_id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  refill_dispatching_id uuid        NOT NULL REFERENCES public.refill_dispatching(dispatch_id) ON DELETE CASCADE,
  machine_id            uuid        REFERENCES public.machines(machine_id) ON DELETE SET NULL,
  boonz_product_id      uuid        REFERENCES public.boonz_products(product_id) ON DELETE SET NULL,
  drift_kind            text        NOT NULL CHECK (drift_kind IN (
                                      'pinned_batch_changed',  -- from_wh_inventory_id swapped at pack/receive
                                      'cached_expiry_stale',   -- refill_dispatching.expiry_date != pinned wh row's expiry
                                      'soft_hold_14d',         -- |drift| > 14d at receive time
                                      'no_pin_no_fefo'         -- received without a pin and FEFO fallback was used
                                    )),
  old_wh_inventory_id   uuid,
  new_wh_inventory_id   uuid,
  old_expiry            date,
  new_expiry            date,
  delta_days            int,
  detected_at           timestamptz NOT NULL DEFAULT now(),
  detected_by           uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  payload               jsonb
);

COMMENT ON TABLE public.expiry_drift_log IS
  'PRD-007 AC#5: append-only audit each time displayed expiry on a dispatch line '
  'differs from the actual FEFO batch expiry. Two main triggers: pinned batch '
  'changed mid-flight (driver took a different batch) and soft-hold drift > 14d.';

CREATE INDEX IF NOT EXISTS idx_edl_dispatch
  ON public.expiry_drift_log (refill_dispatching_id, detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_edl_machine_recent
  ON public.expiry_drift_log (machine_id, detected_at DESC)
  WHERE machine_id IS NOT NULL;

ALTER TABLE public.expiry_drift_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS edl_select ON public.expiry_drift_log;
CREATE POLICY edl_select ON public.expiry_drift_log
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS edl_insert ON public.expiry_drift_log;
CREATE POLICY edl_insert ON public.expiry_drift_log
  FOR INSERT TO authenticated WITH CHECK (true);
DROP POLICY IF EXISTS edl_no_update ON public.expiry_drift_log;
CREATE POLICY edl_no_update ON public.expiry_drift_log
  FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
DROP POLICY IF EXISTS edl_no_delete ON public.expiry_drift_log;
CREATE POLICY edl_no_delete ON public.expiry_drift_log
  FOR DELETE TO authenticated USING (false);

-- ── 2. Trigger: log pin/drift events on refill_dispatching UPDATE ───────────

CREATE OR REPLACE FUNCTION public.log_dispatch_expiry_drift()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := (SELECT auth.uid());
  v_pinned_expiry date;
  v_delta int;
BEGIN
  -- Case A: pinned batch swapped mid-flight (driver picked a different batch
  -- than was pinned at plan time).
  IF OLD.from_wh_inventory_id IS DISTINCT FROM NEW.from_wh_inventory_id
     AND OLD.from_wh_inventory_id IS NOT NULL
     AND NEW.from_wh_inventory_id IS NOT NULL
  THEN
    INSERT INTO public.expiry_drift_log
      (refill_dispatching_id, machine_id, boonz_product_id,
       drift_kind, old_wh_inventory_id, new_wh_inventory_id,
       old_expiry, new_expiry, detected_by,
       payload)
    VALUES
      (NEW.dispatch_id, NEW.machine_id, NEW.boonz_product_id,
       'pinned_batch_changed', OLD.from_wh_inventory_id, NEW.from_wh_inventory_id,
       OLD.expiry_date, NEW.expiry_date, v_uid,
       jsonb_build_object('action', NEW.action));
  END IF;

  -- Case B: item_added just flipped true. Compare cached expiry to the
  -- pinned wh row's current expiry. >14d drift = soft_hold_14d.
  IF OLD.item_added IS DISTINCT FROM NEW.item_added AND NEW.item_added = true
     AND NEW.from_wh_inventory_id IS NOT NULL
  THEN
    SELECT expiration_date INTO v_pinned_expiry
    FROM warehouse_inventory
    WHERE wh_inventory_id = NEW.from_wh_inventory_id;

    IF v_pinned_expiry IS NOT NULL AND NEW.expiry_date IS NOT NULL THEN
      v_delta := (v_pinned_expiry - NEW.expiry_date);
      IF abs(v_delta) > 14 THEN
        INSERT INTO public.expiry_drift_log
          (refill_dispatching_id, machine_id, boonz_product_id,
           drift_kind, new_wh_inventory_id,
           old_expiry, new_expiry, delta_days, detected_by,
           payload)
        VALUES
          (NEW.dispatch_id, NEW.machine_id, NEW.boonz_product_id,
           'soft_hold_14d', NEW.from_wh_inventory_id,
           NEW.expiry_date, v_pinned_expiry, v_delta, v_uid,
           jsonb_build_object('action', NEW.action,
                              'filled_quantity', NEW.filled_quantity));
      END IF;
    END IF;

    -- Case C: received without a pin (no_pin_no_fefo)
    IF NEW.from_wh_inventory_id IS NULL AND NEW.expiry_date IS NULL THEN
      INSERT INTO public.expiry_drift_log
        (refill_dispatching_id, machine_id, boonz_product_id,
         drift_kind, detected_by, payload)
      VALUES
        (NEW.dispatch_id, NEW.machine_id, NEW.boonz_product_id,
         'no_pin_no_fefo', v_uid,
         jsonb_build_object('action', NEW.action,
                            'filled_quantity', NEW.filled_quantity));
    END IF;
  END IF;

  RETURN NEW;
END
$$;

REVOKE EXECUTE ON FUNCTION public.log_dispatch_expiry_drift() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_log_dispatch_expiry_drift ON public.refill_dispatching;
CREATE TRIGGER trg_log_dispatch_expiry_drift
  AFTER UPDATE ON public.refill_dispatching
  FOR EACH ROW EXECUTE FUNCTION public.log_dispatch_expiry_drift();

-- ── 3. wh_expiry_anomaly_log + INSERT trigger on warehouse_inventory ───────

CREATE TABLE IF NOT EXISTS public.wh_expiry_anomaly_log (
  anomaly_id        uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  wh_inventory_id   uuid        NOT NULL REFERENCES public.warehouse_inventory(wh_inventory_id) ON DELETE CASCADE,
  boonz_product_id  uuid        REFERENCES public.boonz_products(product_id) ON DELETE SET NULL,
  warehouse_id      uuid        REFERENCES public.warehouses(warehouse_id) ON DELETE SET NULL,
  expiration_date   date,
  anomaly_kind      text        NOT NULL CHECK (anomaly_kind IN (
                                  'too_soon',    -- < 30 days from today
                                  'too_far',     -- > 24 months from today
                                  'in_past',     -- < today
                                  'null_expiry'  -- expiration_date IS NULL
                                )),
  days_from_today   int,
  detected_at       timestamptz NOT NULL DEFAULT now(),
  detected_by       uuid,
  note              text
);

COMMENT ON TABLE public.wh_expiry_anomaly_log IS
  'PRD-007 AC#4: append-only audit of warehouse_inventory rows whose '
  'expiration_date is suspicious at insert time. Configurable thresholds: '
  '< 30 days (too_soon), > 24 months (too_far), in the past (in_past), '
  'NULL (null_expiry). Does NOT block insert — warn-level surface for CS review.';

CREATE INDEX IF NOT EXISTS idx_weal_recent
  ON public.wh_expiry_anomaly_log (detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_weal_kind
  ON public.wh_expiry_anomaly_log (anomaly_kind, detected_at DESC);

ALTER TABLE public.wh_expiry_anomaly_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS weal_select ON public.wh_expiry_anomaly_log;
CREATE POLICY weal_select ON public.wh_expiry_anomaly_log
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS weal_insert ON public.wh_expiry_anomaly_log;
CREATE POLICY weal_insert ON public.wh_expiry_anomaly_log
  FOR INSERT TO authenticated WITH CHECK (true);
DROP POLICY IF EXISTS weal_no_update ON public.wh_expiry_anomaly_log;
CREATE POLICY weal_no_update ON public.wh_expiry_anomaly_log
  FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
DROP POLICY IF EXISTS weal_no_delete ON public.wh_expiry_anomaly_log;
CREATE POLICY weal_no_delete ON public.wh_expiry_anomaly_log
  FOR DELETE TO authenticated USING (false);

CREATE OR REPLACE FUNCTION public.check_wh_expiry_anomaly()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := (SELECT auth.uid());
  v_days int;
  v_kind text;
BEGIN
  IF NEW.expiration_date IS NULL THEN
    v_kind := 'null_expiry';
  ELSE
    v_days := (NEW.expiration_date - CURRENT_DATE);
    IF v_days < 0 THEN
      v_kind := 'in_past';
    ELSIF v_days < 30 THEN
      v_kind := 'too_soon';
    ELSIF v_days > 730 THEN          -- 24 months
      v_kind := 'too_far';
    ELSE
      RETURN NEW;                     -- normal range, no log row
    END IF;
  END IF;

  INSERT INTO public.wh_expiry_anomaly_log
    (wh_inventory_id, boonz_product_id, warehouse_id, expiration_date,
     anomaly_kind, days_from_today, detected_by, note)
  VALUES
    (NEW.wh_inventory_id, NEW.boonz_product_id, NEW.warehouse_id,
     NEW.expiration_date, v_kind, v_days, v_uid,
     format('Auto-detected at insert via batch_id=%s', NEW.batch_id));

  RETURN NEW;
END
$$;

REVOKE EXECUTE ON FUNCTION public.check_wh_expiry_anomaly() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_check_wh_expiry_anomaly ON public.warehouse_inventory;
CREATE TRIGGER trg_check_wh_expiry_anomaly
  AFTER INSERT ON public.warehouse_inventory
  FOR EACH ROW EXECUTE FUNCTION public.check_wh_expiry_anomaly();

-- ── 4. v_dispatch_expiry_verification view ─────────────────────────────────

CREATE OR REPLACE VIEW public.v_dispatch_expiry_verification
WITH (security_invoker = true) AS
SELECT
  rd.dispatch_id,
  rd.dispatch_date,
  m.official_name AS machine_name,
  sc.shelf_code,
  bp.boonz_product_name,
  rd.expiry_date         AS cached_expiry,
  rd.from_wh_inventory_id,
  wi.expiration_date     AS pinned_wh_expiry,
  CASE
    WHEN rd.from_wh_inventory_id IS NULL THEN 'no_pin'
    WHEN wi.wh_inventory_id IS NULL      THEN 'pin_orphaned'
    WHEN rd.expiry_date IS NOT DISTINCT FROM wi.expiration_date THEN 'in_sync'
    ELSE 'drifted'
  END AS sync_state,
  CASE
    WHEN rd.expiry_date IS NOT NULL AND wi.expiration_date IS NOT NULL
    THEN (wi.expiration_date - rd.expiry_date)
    ELSE NULL
  END AS drift_days,
  rd.action, rd.packed, rd.picked_up, rd.item_added, rd.returned
FROM refill_dispatching rd
LEFT JOIN machines m ON m.machine_id = rd.machine_id
LEFT JOIN shelf_configurations sc ON sc.shelf_id = rd.shelf_id
LEFT JOIN boonz_products bp ON bp.product_id = rd.boonz_product_id
LEFT JOIN warehouse_inventory wi ON wi.wh_inventory_id = rd.from_wh_inventory_id;

COMMENT ON VIEW public.v_dispatch_expiry_verification IS
  'PRD-007 USH Hot N Sweet / Addmind diagnostic: every dispatch row with its '
  'cached vs pinned-wh expiry, sync_state classification, and drift_days. CS '
  'reads to verify the Hunter cases against current data.';

COMMIT;

-- ============================================================================
-- POST-APPLY USAGE
--
--   -- USH/Addmind Hunter diagnostic (PRD-007 AC#3)
--   SELECT * FROM v_dispatch_expiry_verification
--   WHERE boonz_product_name ILIKE 'Hunter%'
--     AND dispatch_date >= '2026-05-15'
--     AND sync_state <> 'in_sync'
--   ORDER BY drift_days DESC NULLS LAST;
--
--   -- Recent anomalous WH inserts
--   SELECT * FROM wh_expiry_anomaly_log
--   WHERE detected_at >= NOW() - INTERVAL '7 days'
--   ORDER BY detected_at DESC LIMIT 50;
--
--   -- Mid-flight pin swaps over the last week
--   SELECT * FROM expiry_drift_log
--   WHERE drift_kind = 'pinned_batch_changed'
--     AND detected_at >= NOW() - INTERVAL '7 days';
--
-- DEFERRED:
--   - FE: surface expiry_drift_log + wh_expiry_anomaly_log in an admin
--     /admin/expiry-anomalies page (Stax follow-up).
--   - FE: per-batch breakdown rendering in the picking UI (AC#2) once
--     the picking UI accepts variant-level rows (PRD-006 trip page is
--     the starting point).
-- ============================================================================
