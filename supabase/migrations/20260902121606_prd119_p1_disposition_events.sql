-- PRD-119 §6: disposition_events — append-only ledger replacing the returns Google
-- Sheet. Each row is one state transition (removed_at_machine -> in_transit ->
-- received -> {restocked | redeploy_pending | redeployed | waste}); the "current"
-- state of a case is its latest row, chained via superseded_by_event, never an
-- UPDATE in place.
--
-- Dara: two-column CHECK constraints encode the state machine's structural rules
-- at the DB layer (waste needs disposal_code, redeploy_pending needs target +
-- waste_by) rather than trusting every writer to remember them.
--
-- Cody: approve, Articles 2/3/7/12/14 — RLS enabled, explicit REVOKE
-- INSERT/UPDATE/DELETE/TRUNCATE FROM authenticated per S-308 (new tables are born
-- writable otherwise), post-image grant check confirms only SELECT/REFERENCES/
-- TRIGGER remain. No permissive INSERT policy exists — writes only via future
-- SECURITY DEFINER RPCs (wm_confirm_line, driver taps). UPDATE/DELETE blocked at
-- both grant and RLS-policy layer, satisfying Article 7 append-only.
CREATE TABLE public.disposition_events (
  event_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at          timestamptz NOT NULL DEFAULT now(),
  actor               uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  source              text NOT NULL CHECK (source IN ('driver_expiry_check','return_receipt','wh_writeoff','m2m','migration_sheet')),
  machine_id          uuid REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  shelf_id            uuid REFERENCES public.shelf_configurations(shelf_id) ON DELETE RESTRICT,
  boonz_product_id    uuid NOT NULL REFERENCES public.boonz_products(product_id) ON DELETE RESTRICT,
  expiration_date     date,
  qty                 numeric NOT NULL CHECK (qty > 0),
  state               text NOT NULL CHECK (state IN ('removed_at_machine','in_transit','received','restocked','redeploy_pending','redeployed','waste')),
  disposal_code       text CHECK (disposal_code IS NULL OR disposal_code IN ('Waste','Returning to supplier','Returned to supplier')),
  target_machine_id   uuid REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  waste_by            date,
  value_aed           numeric,
  reason              text,
  dispatch_id         uuid REFERENCES public.refill_dispatching(dispatch_id) ON DELETE SET NULL,
  wh_inventory_id     uuid REFERENCES public.warehouse_inventory(wh_inventory_id) ON DELETE SET NULL,
  pod_inventory_id    uuid REFERENCES public.pod_inventory(pod_inventory_id) ON DELETE SET NULL,
  superseded_by_event uuid REFERENCES public.disposition_events(event_id) ON DELETE SET NULL,
  CONSTRAINT disposition_events_waste_needs_code CHECK (state <> 'waste' OR disposal_code IS NOT NULL),
  CONSTRAINT disposition_events_redeploy_needs_target CHECK (state <> 'redeploy_pending' OR (target_machine_id IS NOT NULL AND waste_by IS NOT NULL))
);

COMMENT ON TABLE public.disposition_events IS 'PRD-119 §6: append-only disposition ledger for returned/pulled/expired stock. Each row is one state transition; the current state of a "case" is its latest row (chained via superseded_by_event), not an UPDATE in place.';

CREATE INDEX idx_disposition_events_machine_state ON public.disposition_events (machine_id, state);
CREATE INDEX idx_disposition_events_redeploy_waste_by ON public.disposition_events (waste_by) WHERE state = 'redeploy_pending';
CREATE INDEX idx_disposition_events_created ON public.disposition_events (created_at DESC);

ALTER TABLE public.disposition_events ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.disposition_events FROM authenticated;
CREATE POLICY disposition_events_select ON public.disposition_events FOR SELECT TO authenticated USING (true);
CREATE POLICY disposition_events_no_update ON public.disposition_events FOR UPDATE USING (false);
CREATE POLICY disposition_events_no_delete ON public.disposition_events FOR DELETE USING (false);
