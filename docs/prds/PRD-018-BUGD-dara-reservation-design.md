# BUG-D — Dara design: quantified warehouse reservations

Status: Closed 2026-07-02 (PRD-071 sweep). Reason: historical design record (PRD-018 shipped v6_resilient_bridge era). Reopen by deleting this line.

**For:** Cody review → implementer. Companion to PRD-018 §BUG-D. Created 2026-06-04.

## Design problem

When a single warehouse batch is shared across machines in one refill session, the system must let
each machine reserve only the quantity it packs, leaving the remainder visible to the others. Today,
reservations are modeled as **one FK column on the batch row** — `warehouse_inventory.reserved_for_machine_id`
(+ `reservation_priority`, `reserved_at`). `pack_dispatch_line` stamps that column to the first machine,
which earmarks the **entire** remaining `warehouse_stock` to that machine. The §1 availability read
(`v_dispatch_availability`, `pick_wh_batch_for_machine`) excludes rows reserved for other machines, so
every later machine sees Available = 0 even though physical stock remains (BUG-D: Al Ain Water 37u, AMZ-1068
packed 14, OMDCW then saw 0). A batch-level single-FK reservation cannot express "14 reserved for A, 19 for B,
4 free." We need a quantified, per-machine reservation ledger. Reservations are a _claim_ ledger only — they
never mutate `warehouse_stock` or `status`; the real decrement still happens at receive.

## Proposed schema

```sql
CREATE TABLE IF NOT EXISTS public.warehouse_reservation (
  reservation_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wh_inventory_id  uuid NOT NULL REFERENCES public.warehouse_inventory(wh_inventory_id) ON DELETE RESTRICT, -- the batch being claimed
  machine_id       uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,                 -- who claims it
  reserved_qty     numeric NOT NULL CHECK (reserved_qty > 0),                                               -- how many units claimed (NOT the whole batch)
  dispatch_id      uuid REFERENCES public.refill_dispatching(dispatch_id) ON DELETE SET NULL,               -- the pack that created the claim
  status           text NOT NULL DEFAULT 'active'
                     CHECK (status IN ('active','consumed','released','expired')),                          -- active=held; consumed=received; released/expired=freed
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  released_at      timestamptz
);
COMMENT ON TABLE public.warehouse_reservation IS
  'Quantified per-machine claims on a warehouse_inventory batch. Available(machine,batch) = warehouse_stock - SUM(reserved_qty WHERE status=active AND machine_id<>machine). Never mutates warehouse_stock/status.';
```

**New §1 availability** (replaces the `reserved_for_machine_id` clause): for (machine M, batch B)
`available_to_M = B.warehouse_stock - COALESCE(SUM(r.reserved_qty) FILTER (WHERE r.status='active' AND r.machine_id <> M), 0)`.
A machine's own active reservations do NOT subtract from its own availability (it already holds them).

## Indexes

```sql
CREATE INDEX idx_wh_resv_batch_active ON public.warehouse_reservation (wh_inventory_id) WHERE status='active';
-- serves the per-batch SUM in the availability read (the hot path).
CREATE INDEX idx_wh_resv_machine_active ON public.warehouse_reservation (machine_id) WHERE status='active';
-- serves "what does this machine currently hold".
CREATE INDEX idx_wh_resv_dispatch ON public.warehouse_reservation (dispatch_id);
-- serves consume/release keyed off the originating dispatch (receive/return path).
```

## RLS policies

```sql
ALTER TABLE public.warehouse_reservation ENABLE ROW LEVEL SECURITY;
CREATE POLICY whr_select ON public.warehouse_reservation FOR SELECT TO authenticated USING (true);
CREATE POLICY whr_write  ON public.warehouse_reservation FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles WHERE id=(SELECT auth.uid())
                 AND role=ANY(ARRAY['warehouse','operator_admin','superadmin','manager'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_profiles WHERE id=(SELECT auth.uid())
                 AND role=ANY(ARRAY['warehouse','operator_admin','superadmin','manager'])));
```

RPC work (Cody + implementer, NOT Dara): `pack_dispatch_line` INSERTs a reservation row for the packed qty
(status='active') instead of stamping `reserved_for_machine_id`; `receive_dispatch_line` flips the matching
reservation to 'consumed'; `return_dispatch_line`/EOD-release flips to 'released'. `v_dispatch_availability`
and `pick_wh_batch_for_machine` switch to the SUM expression above. Add an expiry sweep (cron) to flip stale
'active' → 'expired'.

## Tradeoffs and alternatives

- **Alt A — split the batch row per machine on reservation** (insert child warehouse_inventory rows). Rejected:
  inflates the protected `warehouse_inventory` table, fractures FEFO/expiry batches, and corrupts the physical
  count semantics. A claim is not a physical batch.
- **Alt B — keep the single FK but add `reserved_qty` to warehouse_inventory.** Rejected: still one claimant per
  batch row; can't express two machines on one batch without Alt A's row-splitting.
- Chosen: a separate quantified ledger — one batch, many partial claims, `warehouse_stock` untouched.

## Cody handoff checklist

- **Article 1/6** — reservations never write `warehouse_stock` or `warehouse_inventory.status`; the batch stays
  the system of record, claims are an overlay. Confirm.
- **Article 2** — RLS enabled with the `user_profiles` role join. ✓ shape above.
- **Article 4** — the writer (`pack_dispatch_line`) validates qty ≤ available before INSERT; sets `app.via_rpc`.
- **Article 7/8** — audit the reservation table (trigger or generic) so claims are traceable.
- **Article 12** — forward-only; deprecate `reserved_for_machine_id`/`reservation_priority`/`reserved_at` via
  Article 13 (90-day) once readers move to the ledger; do not drop in this migration.
- **Article 14** — `warehouse_reservation` is a NEW concept, not a parallel `_v2` of warehouse_inventory. ✓

## Next step

Take this proposal to `cody`. On ✅/⚠️, implementer applies the DDL + reworks `pack_dispatch_line` /
`receive_dispatch_line` / `v_dispatch_availability` / `pick_wh_batch_for_machine` (each its own Cody-reviewed
change), verifies the BUG-D scenario (Al Ain Water shared across AMZ-1068 + OMDCW shows each its fair remainder),
then deprecates the old FK columns.
