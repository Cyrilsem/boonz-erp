-- PRD-110 P4.4b Migration A — spot_fill_v3
-- The "pending spot_fill event" of BUILD SPEC line 104. Additive, versioned, non-protected.
-- Design + Cody review: docs/prds/PRD-110-P4.4b-DARA-post-facto-fill-design.md §5, §8.
--
-- Records units the driver physically put on a shelf that never passed through a warehouse.
-- Phase 1 (at the machine) writes status='pending'; phase 2 (PO receive) flips to 'received'
-- and supplies the receipt expiry. Direct-to-machine per D-E: this table is the ONLY place the
-- spot units are tracked as inventory-in-transit — there is deliberately no warehouse_inventory row.

CREATE TABLE IF NOT EXISTS public.spot_fill_v3 (
  spot_fill_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispatch_id      uuid NOT NULL REFERENCES public.refill_dispatching(dispatch_id),
  machine_id       uuid NOT NULL,
  shelf_id         uuid,
  boonz_product_id uuid NOT NULL,
  qty              numeric NOT NULL,
  sku_resolved     boolean NOT NULL DEFAULT false,
  supplier_id      uuid NOT NULL REFERENCES public.suppliers(supplier_id),
  po_id            text,
  status           text NOT NULL DEFAULT 'pending',
  unit_price_aed   numeric,
  expiry_date      date,
  receipt_photo    text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  received_at      timestamptz,
  created_by       uuid,
  received_by      uuid,
  note             text,

  CONSTRAINT spot_fill_qty_positive CHECK (qty > 0),
  CONSTRAINT spot_fill_status_enum  CHECK (status IN ('pending', 'received', 'void')),

  -- The constraint that matters. Forbids a 'received' row with a NULL expiry: the exact hole
  -- through which undated stock would otherwise reach a shelf and become immortal in FEFO.
  -- NOT vacuous by construction (S-177): status is NOT NULL, so `status <> 'received'` can never
  -- evaluate to NULL, and a CHECK that evaluates to NULL ACCEPTS the row it meant to forbid.
  CONSTRAINT spot_fill_received_pair CHECK (
    (status <> 'received') OR (received_at IS NOT NULL AND expiry_date IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_spot_fill_v3_dispatch ON public.spot_fill_v3 (dispatch_id);
CREATE INDEX IF NOT EXISTS idx_spot_fill_v3_open     ON public.spot_fill_v3 (status, created_at)
  WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_spot_fill_v3_po       ON public.spot_fill_v3 (po_id)
  WHERE po_id IS NOT NULL;

COMMENT ON TABLE public.spot_fill_v3 IS
  'PRD-110 P4.4b. Units bought at a shop and put straight on a shelf, never through a warehouse. '
  'pending = physically on the shelf, financially unreceived (a real, transient accounting state). '
  'Direct-to-machine per design D-E: netting these through warehouse_inventory would drive '
  'tg_propose_inactivate_on_zero_stock, which UPDATEs warehouse_inventory.status (Article 6, '
  'manager-only) and mints an auto-confirmed status proposal on every fill. Measured, not assumed.';

-- S-178: Supabase default privileges ARM every new public table at birth, to anon AND authenticated.
-- A GRANT does not reduce an existing arwdDxtm. Revoke everything first, then grant the one verb.
REVOKE ALL ON public.spot_fill_v3 FROM PUBLIC;
REVOKE ALL ON public.spot_fill_v3 FROM anon;
REVOKE ALL ON public.spot_fill_v3 FROM authenticated;
GRANT  ALL    ON public.spot_fill_v3 TO service_role;
GRANT  SELECT ON public.spot_fill_v3 TO authenticated;

ALTER TABLE public.spot_fill_v3 ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS spot_fill_v3_select ON public.spot_fill_v3;
CREATE POLICY spot_fill_v3_select ON public.spot_fill_v3
  FOR SELECT TO authenticated USING (true);
