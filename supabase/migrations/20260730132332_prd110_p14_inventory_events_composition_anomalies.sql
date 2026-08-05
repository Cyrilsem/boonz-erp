-- ============================================================================
-- PRD-110 P1.4 (WS-J2) — inventory events + composition estimator truth layer
-- Dara design / Cody review verdict: approve with revisions (all incorporated).
-- Articles: 1 (canonical writer), 2 (RLS), 4, 7 (append-only), 8 (audit), 12, 14, 16.
-- SHADOW ONLY: no existing consumer reads these. pod_inventory untouched.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. inventory_events — append-only ledger of PHYSICAL truth about a shelf.
--    Every quantity change on a shelf is an event. This is the only place the
--    system records WHY a count moved. Nothing here is ever updated or deleted.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_events (
  event_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ts                timestamptz NOT NULL DEFAULT now(),   -- when the event happened (may backdate)
  machine_id        uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  shelf_id          uuid NOT NULL REFERENCES public.shelf_configurations(shelf_id) ON DELETE RESTRICT,
  boonz_product_id  uuid NOT NULL REFERENCES public.boonz_products(product_id) ON DELETE RESTRICT,
  qty_delta         numeric NOT NULL,                     -- signed; + onto shelf, - off shelf
  kind              text NOT NULL,
  expiry_date       date,                                 -- which expiry bucket; NULL = unknown (SELLABLE, see note)
  source_ref        text,                                 -- dispatch_id / po_line_id / audit ref
  actor             uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  note              text,
  created_at        timestamptz NOT NULL DEFAULT now(),    -- when the row was written (never backdated)
  CONSTRAINT inventory_events_kind_check CHECK (kind = ANY (ARRAY[
    'load','venue_fill','return','write_off','spot_buy_receive',
    'driver_confirm','correction','derived_decrement','expired_sold_incident'])),
  CONSTRAINT inventory_events_qty_nonzero CHECK (qty_delta <> 0),
  -- Sign discipline by kind. Additive kinds may only add, removal kinds may only
  -- remove; only driver_confirm and correction are reconciling deltas and may go
  -- either way. Kills a whole class of estimator sign bugs at the schema layer.
  CONSTRAINT inventory_events_sign_by_kind CHECK (
    CASE
      WHEN kind = ANY (ARRAY['load','venue_fill','spot_buy_receive']) THEN qty_delta > 0
      WHEN kind = ANY (ARRAY['return','write_off','derived_decrement','expired_sold_incident']) THEN qty_delta < 0
      ELSE true
    END)
);

COMMENT ON TABLE  public.inventory_events IS
  'PRD-110 P1.4 (WS-J2). Append-only ledger of physical shelf truth. RPC-only writers; UPDATE/DELETE blocked by trigger. expiry_date NULL means UNKNOWN bucket, which the estimator treats as SELLABLE - never as expired, because treating unknown as expired would freeze it from derived decrements forever and inflate est_qty. The EXPIRY IRON RULE binds KNOWN-expired buckets only.';
COMMENT ON COLUMN public.inventory_events.qty_delta IS 'Signed delta on the shelf. Sign constrained by kind (inventory_events_sign_by_kind).';
COMMENT ON COLUMN public.inventory_events.kind IS 'derived_decrement = estimator-inferred sale. All others are real-world events. expired_sold_incident = an expired unit left the shelf without a write-off (KPI).';

-- Access patterns (D5 - each index names its query):
-- estimator replays every event for one shelf since the last snapshot
CREATE INDEX IF NOT EXISTS idx_inventory_events_shelf_ts
  ON public.inventory_events (shelf_id, ts DESC);
-- confidence model needs the most recent driver_confirm per shelf, constantly
CREATE INDEX IF NOT EXISTS idx_inventory_events_confirm
  ON public.inventory_events (shelf_id, ts DESC) WHERE kind = 'driver_confirm';
-- sales attribution v2 / COGS aggregates by product over time
CREATE INDEX IF NOT EXISTS idx_inventory_events_product_ts
  ON public.inventory_events (boonz_product_id, ts DESC);
-- FE machine feed and per-machine event review
CREATE INDEX IF NOT EXISTS idx_inventory_events_machine_ts
  ON public.inventory_events (machine_id, ts DESC);

-- ---------------------------------------------------------------------------
-- 2. shelf_composition — the estimator's maintained belief about what is
--    physically on each shelf, per SKU per expiry bucket.
--    expiry_bucket is part of IDENTITY, not an attribute: the EXPIRY IRON RULE
--    requires an expired bucket to coexist with a sellable bucket of the same
--    product on the same shelf, so they must be separate rows.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.shelf_composition (
  composition_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id        uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  shelf_id          uuid NOT NULL REFERENCES public.shelf_configurations(shelf_id) ON DELETE RESTRICT,
  boonz_product_id  uuid NOT NULL REFERENCES public.boonz_products(product_id) ON DELETE RESTRICT,
  expiry_bucket     date,                                 -- NULL = unknown bucket (sellable)
  est_qty           numeric NOT NULL DEFAULT 0 CHECK (est_qty >= 0),
  confidence        numeric NOT NULL DEFAULT 1.0 CHECK (confidence >= 0 AND confidence <= 1),
  last_verified_at  timestamptz,                          -- last driver_confirm / load-to-empty
  last_event_id     uuid REFERENCES public.inventory_events(event_id) ON DELETE SET NULL,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  created_at        timestamptz NOT NULL DEFAULT now(),
  -- NULLS NOT DISTINCT (PG15+) so the unknown-expiry bucket is a single row per
  -- (shelf, product) rather than an unbounded set of NULL-keyed duplicates.
  CONSTRAINT shelf_composition_identity
    UNIQUE NULLS NOT DISTINCT (shelf_id, boonz_product_id, expiry_bucket)
);

COMMENT ON TABLE public.shelf_composition IS
  'PRD-110 P1.4 (WS-J2). Estimated per-SKU per-expiry-bucket shelf composition, maintained incrementally by the estimator from inventory_events + WEIMI count deltas. NOT a materialized view (Article 14): the value depends on event ORDER and on confidence decay history, which no SELECT can derive. est_qty >= 0 is enforced in-schema (stress-suite S2: composition never negative).';
COMMENT ON COLUMN public.shelf_composition.expiry_bucket IS 'Part of row identity. NULL = unknown expiry, treated as SELLABLE by the estimator.';
COMMENT ON COLUMN public.shelf_composition.confidence IS '1.0 at driver_confirm or load-to-empty; decays per unexplained delta and per day. Auto-write-off actions gate on this (>= threshold param), else a verify task is raised.';

-- estimator + FE read the whole composition of one shelf at once
CREATE INDEX IF NOT EXISTS idx_shelf_composition_shelf
  ON public.shelf_composition (shelf_id);
-- driver-collapse picker ranks shelves by lowest confidence (top uncertainty)
CREATE INDEX IF NOT EXISTS idx_shelf_composition_confidence
  ON public.shelf_composition (confidence) WHERE est_qty > 0;
-- expiry sweep: which shelves hold a bucket at/after a given date
CREATE INDEX IF NOT EXISTS idx_shelf_composition_expiry
  ON public.shelf_composition (expiry_bucket) WHERE expiry_bucket IS NOT NULL;
-- product-level rollups (procurement, COGS)
CREATE INDEX IF NOT EXISTS idx_shelf_composition_product
  ON public.shelf_composition (boonz_product_id);

-- ---------------------------------------------------------------------------
-- 3. inventory_anomalies — exception queue. A count movement the estimator
--    could not explain lands here rather than being silently absorbed.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_anomalies (
  anomaly_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  detected_at       timestamptz NOT NULL DEFAULT now(),
  machine_id        uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  shelf_id          uuid NOT NULL REFERENCES public.shelf_configurations(shelf_id) ON DELETE RESTRICT,
  boonz_product_id  uuid REFERENCES public.boonz_products(product_id) ON DELETE SET NULL, -- NULL = pod-level
  kind              text NOT NULL,
  observed_qty      numeric,
  expected_qty      numeric,
  weimi_snapshot_at timestamptz,
  detail            jsonb NOT NULL DEFAULT '{}'::jsonb,
  resolved_at       timestamptz,
  resolution        text,
  resolved_by       uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  CONSTRAINT inventory_anomalies_kind_check CHECK (kind = ANY (ARRAY[
    'count_rise_unexplained','count_above_capacity','negative_delta_unallocatable',
    'composition_underflow','expired_sold_suspected','snapshot_gap'])),
  CONSTRAINT inventory_anomalies_resolution_check CHECK (resolution IS NULL OR resolution = ANY (ARRAY[
    'venue_fill_confirmed','driver_corrected','sensor_error','written_off','ignored'])),
  CONSTRAINT inventory_anomalies_resolution_pair CHECK (
    (resolved_at IS NULL AND resolution IS NULL) OR (resolved_at IS NOT NULL AND resolution IS NOT NULL))
);

COMMENT ON TABLE public.inventory_anomalies IS
  'PRD-110 P1.4 (WS-J2). Exception queue for shelf count movements the estimator cannot explain. LAW 5 analogue for physical truth: nothing is silently absorbed. resolution_pair mirrors blocked_demand.';

-- open-anomaly worklist, the dominant read
CREATE INDEX IF NOT EXISTS idx_inventory_anomalies_open
  ON public.inventory_anomalies (detected_at DESC) WHERE resolved_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_inventory_anomalies_shelf
  ON public.inventory_anomalies (shelf_id, detected_at DESC);

-- ---------------------------------------------------------------------------
-- 4. Article 7 — append-only enforcement on the ledger.
--    RLS is not sufficient: DEFINER RPCs and service_role bypass it. Mirrors
--    the existing tg_product_sourcing_append_only precedent.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_inventory_events_append_only()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION
    'inventory_events is append-only (Article 7): % is forbidden. Correct a bad event with a compensating ''correction'' event.',
    TG_OP;
END;
$$;

DROP TRIGGER IF EXISTS tg_inventory_events_append_only ON public.inventory_events;
CREATE TRIGGER tg_inventory_events_append_only
  BEFORE UPDATE OR DELETE ON public.inventory_events
  FOR EACH ROW EXECUTE FUNCTION public.tg_inventory_events_append_only();

-- ---------------------------------------------------------------------------
-- 5. Shared shelf/machine consistency guard (Cody finding).
--    machine_id is denormalized on all three tables per BUILD SPEC; without
--    this it can silently disagree with the shelf's real machine.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_assert_shelf_machine_match()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_real uuid;
BEGIN
  SELECT sc.machine_id INTO v_real
    FROM public.shelf_configurations sc WHERE sc.shelf_id = NEW.shelf_id;
  IF v_real IS NULL THEN
    RAISE EXCEPTION 'shelf_id % does not exist', NEW.shelf_id;
  END IF;
  IF v_real <> NEW.machine_id THEN
    RAISE EXCEPTION 'machine_id % does not own shelf_id % (real owner %)',
      NEW.machine_id, NEW.shelf_id, v_real;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tg_inventory_events_shelf_match ON public.inventory_events;
CREATE TRIGGER tg_inventory_events_shelf_match
  BEFORE INSERT ON public.inventory_events
  FOR EACH ROW EXECUTE FUNCTION public.tg_assert_shelf_machine_match();

DROP TRIGGER IF EXISTS tg_shelf_composition_shelf_match ON public.shelf_composition;
CREATE TRIGGER tg_shelf_composition_shelf_match
  BEFORE INSERT OR UPDATE ON public.shelf_composition
  FOR EACH ROW EXECUTE FUNCTION public.tg_assert_shelf_machine_match();

DROP TRIGGER IF EXISTS tg_inventory_anomalies_shelf_match ON public.inventory_anomalies;
CREATE TRIGGER tg_inventory_anomalies_shelf_match
  BEFORE INSERT ON public.inventory_anomalies
  FOR EACH ROW EXECUTE FUNCTION public.tg_assert_shelf_machine_match();

-- ---------------------------------------------------------------------------
-- 6. Article 8 — universal audit, same pattern as blocked_demand/product_sourcing.
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS tg_audit_inventory_events ON public.inventory_events;
CREATE TRIGGER tg_audit_inventory_events
  AFTER INSERT ON public.inventory_events
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_write('event_id');

DROP TRIGGER IF EXISTS tg_audit_shelf_composition ON public.shelf_composition;
CREATE TRIGGER tg_audit_shelf_composition
  AFTER INSERT OR UPDATE OR DELETE ON public.shelf_composition
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_write('composition_id');

DROP TRIGGER IF EXISTS tg_audit_inventory_anomalies ON public.inventory_anomalies;
CREATE TRIGGER tg_audit_inventory_anomalies
  AFTER INSERT OR UPDATE ON public.inventory_anomalies
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_write('anomaly_id');

-- ---------------------------------------------------------------------------
-- 7. Article 2/3 — RLS. SELECT-only for authenticated via the user_profiles
--    role join. NO insert/update/delete policies at all, which is precisely
--    what makes these RPC-only-write tables (house pattern: blocked_demand).
-- ---------------------------------------------------------------------------
ALTER TABLE public.inventory_events    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shelf_composition   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_anomalies ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS inventory_events_select ON public.inventory_events;
CREATE POLICY inventory_events_select ON public.inventory_events
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.user_profiles up
            WHERE up.id = (SELECT auth.uid())
              AND up.role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager','field_staff'])));

-- field_staff included: the driver collapse UI reads the expected list.
DROP POLICY IF EXISTS shelf_composition_select ON public.shelf_composition;
CREATE POLICY shelf_composition_select ON public.shelf_composition
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.user_profiles up
            WHERE up.id = (SELECT auth.uid())
              AND up.role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager','field_staff'])));

-- anomaly triage is an ops function; drivers do not resolve anomalies.
DROP POLICY IF EXISTS inventory_anomalies_select ON public.inventory_anomalies;
CREATE POLICY inventory_anomalies_select ON public.inventory_anomalies
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.user_profiles up
            WHERE up.id = (SELECT auth.uid())
              AND up.role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])));

REVOKE ALL ON public.inventory_events    FROM anon;
REVOKE ALL ON public.shelf_composition   FROM anon;
REVOKE ALL ON public.inventory_anomalies FROM anon;
