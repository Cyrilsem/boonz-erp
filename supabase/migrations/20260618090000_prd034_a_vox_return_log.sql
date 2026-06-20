-- PRD-034 Phase A: vox_return_log ledger table.
-- NOT APPLIED. Author-only; apply after CS sign-off. Forward-only, no edit-in-place.
--
-- Append-only record of every venue_team (VOX-supplied) REMOVE receipt that was
-- deliberately NOT credited to Boonz warehouse_inventory (Phase B writes the rows
-- from inside receive_dispatch_line). Gives VOX partner reconciliation a queryable
-- surface instead of parsing write_audit_log. Table only: no writer is registered
-- here; the canonical writer (receive_dispatch_line) is patched in Phase B.
CREATE TABLE IF NOT EXISTS public.vox_return_log (
  vox_return_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispatch_id      uuid NOT NULL,
  machine_id       uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  boonz_product_id uuid REFERENCES public.boonz_products(product_id) ON DELETE SET NULL,
  qty              numeric NOT NULL CHECK (qty >= 0),
  expiry_date      date,
  source_of_supply text NOT NULL,
  received_by      uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  received_at      timestamptz NOT NULL DEFAULT now(),
  reason           text
);

ALTER TABLE public.vox_return_log ENABLE ROW LEVEL SECURITY;

-- Append-only: read for any authenticated user; UPDATE/DELETE blocked for everyone.
-- Direct authenticated INSERT is blocked too (Article 3): the only writer is the
-- SECURITY DEFINER receive_dispatch_line, which inserts as table owner and bypasses
-- RLS, so WITH CHECK (false) closes the direct-write path without affecting it.
CREATE POLICY vrl_select    ON public.vox_return_log FOR SELECT TO authenticated USING (true);
CREATE POLICY vrl_insert    ON public.vox_return_log FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY vrl_no_update ON public.vox_return_log FOR UPDATE USING (false);
CREATE POLICY vrl_no_delete ON public.vox_return_log FOR DELETE USING (false);

CREATE INDEX idx_vrl_machine_time ON public.vox_return_log (machine_id, received_at DESC);
CREATE INDEX idx_vrl_dispatch     ON public.vox_return_log (dispatch_id);

COMMENT ON TABLE public.vox_return_log IS
'PRD-034 append-only ledger of venue_team (VOX) REMOVE receipts intentionally NOT credited to Boonz warehouse_inventory. Written only by receive_dispatch_line (DEFINER) in the Remove branch when source_of_supply=venue_team. RLS on, UPDATE/DELETE blocked.';
