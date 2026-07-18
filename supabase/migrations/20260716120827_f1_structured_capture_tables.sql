-- backported from prod schema_migrations on 2026-07-18, RC-15 parity
-- version: 20260716120827  name: f1_structured_capture_tables
-- F1: structured refill-capture ledger (Dara design, Cody ⚠️-approved 2026-07-16)
-- Appendix A additions: refill_events, refill_event_lines

CREATE TABLE IF NOT EXISTS public.refill_events (
  event_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id    uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  plan_date     date NOT NULL,
  source        text NOT NULL CHECK (source IN ('driver_app','cs','venue_team','reconcile')),
  captured_by   uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  captured_at   timestamptz NOT NULL DEFAULT now(),
  status        text NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','applied','failed','dry_run')),
  reason        text,
  applied_at    timestamptz,
  error_text    text
);
COMMENT ON TABLE public.refill_events IS 'F1 capture ledger header: one row per physical refill visit/action-batch. Appendix A protected. Applied atomically by record_actual_refill (F2).';

CREATE TABLE IF NOT EXISTS public.refill_event_lines (
  line_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id           uuid NOT NULL REFERENCES public.refill_events(event_id) ON DELETE CASCADE,
  action             text NOT NULL CHECK (action IN
                       ('refill','remove','write_off','transfer_out','transfer_in','wh_return','wh_receive')),
  boonz_product_id   uuid NOT NULL REFERENCES public.boonz_products(product_id) ON DELETE RESTRICT,
  shelf_id           uuid REFERENCES public.shelf_configurations(shelf_id) ON DELETE RESTRICT,
  qty                numeric NOT NULL CHECK (qty >= 0),
  set_mode           text NOT NULL DEFAULT 'delta' CHECK (set_mode IN ('delta','set')),
  expiration_date    date,
  warehouse_id       uuid REFERENCES public.warehouses(warehouse_id) ON DELETE RESTRICT,
  partner_machine_id uuid REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  result_pod_inventory_id uuid,
  applied            boolean NOT NULL DEFAULT false,
  notes              text
);
COMMENT ON TABLE public.refill_event_lines IS 'F1 capture ledger detail: one typed row per placed/removed/transferred line. Appendix A protected.';

-- Indexes (D5: index the access pattern)
CREATE INDEX IF NOT EXISTS idx_refill_events_machine_date
  ON public.refill_events (machine_id, plan_date DESC);
CREATE INDEX IF NOT EXISTS idx_refill_events_status_pending
  ON public.refill_events (status) WHERE status IN ('pending','failed');
CREATE INDEX IF NOT EXISTS idx_refill_event_lines_event
  ON public.refill_event_lines (event_id);
CREATE INDEX IF NOT EXISTS idx_refill_event_lines_product
  ON public.refill_event_lines (boonz_product_id, applied);

-- RLS (Article 2). Read = authenticated; write = manager roles via user_profiles; append-only.
ALTER TABLE public.refill_events      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.refill_event_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY refill_events_select ON public.refill_events FOR SELECT TO authenticated USING (true);
CREATE POLICY refill_lines_select  ON public.refill_event_lines FOR SELECT TO authenticated USING (true);

CREATE POLICY refill_events_write ON public.refill_events FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_profiles
    WHERE id = (SELECT auth.uid())
      AND role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])));
CREATE POLICY refill_lines_write ON public.refill_event_lines FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_profiles
    WHERE id = (SELECT auth.uid())
      AND role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])));

-- Article 7: append-only (both header and lines block UPDATE/DELETE from authenticated; DEFINER owner bypasses)
CREATE POLICY refill_events_no_update ON public.refill_events FOR UPDATE USING (false);
CREATE POLICY refill_events_no_delete ON public.refill_events FOR DELETE USING (false);
CREATE POLICY refill_lines_no_update ON public.refill_event_lines FOR UPDATE USING (false);
CREATE POLICY refill_lines_no_delete ON public.refill_event_lines FOR DELETE USING (false);
