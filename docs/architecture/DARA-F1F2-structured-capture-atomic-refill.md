# DARA proposal — F1 structured capture + F2 atomic `record_actual_refill`

**Author:** Dara · **Date:** 2026-07-16 · **Status:** proposal → Cody review
**Entities:** new `refill_events`, `refill_event_lines` (both to be added to Appendix A). Writes existing
protected entities `pod_inventory`, `warehouse_inventory`, `refill_plan_output` via the F2 RPC.

---

## Design problem

Today the physical truth of a refill enters the system as free text in a Google Doc and is reconstructed,
days later, across three tables by hand. There is no structured record of "what the driver actually did on
machine X today, and did it land in every table." I am modelling that record. F1 is a two-level capture
ledger: a header per refill visit (`refill_events`) and one typed row per placed/removed/transferred line
(`refill_event_lines`). It must support three queries: (Q1) everything changed on a machine on a date,
(Q2) every event a given line participated in for audit, (Q3) events that failed to apply. The business
invariant it protects: **a captured refill either lands in pod + warehouse + log atomically, or it is
recorded as failed — never partially applied.** The header is the single ledger CS asked for. F2 is the
RPC that consumes a captured event and applies it in one transaction; Dara specifies its contract here, the
body is the implementer's + Cody's.

## Proposed schema

```sql
-- F1a: capture header — one row per refill visit / action-batch on a machine
CREATE TABLE IF NOT EXISTS public.refill_events (
  event_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id    uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,   -- the machine serviced
  plan_date     date NOT NULL,                                        -- the operational date this refill belongs to
  source        text NOT NULL CHECK (source IN ('driver_app','cs','venue_team','reconcile')), -- who/what captured it
  captured_by   uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,               -- actor (nullable for system)
  captured_at   timestamptz NOT NULL DEFAULT now(),                   -- capture time
  status        text NOT NULL DEFAULT 'pending'                       -- lifecycle of the apply
                CHECK (status IN ('pending','applied','failed','dry_run')),
  reason        text,                                                 -- free-text note / provenance
  applied_at    timestamptz,                                          -- when F2 committed the writes
  error_text    text                                                  -- populated on status='failed'
);

-- F1b: capture detail — one typed row per line the driver actually placed/removed/moved
CREATE TABLE IF NOT EXISTS public.refill_event_lines (
  line_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id           uuid NOT NULL REFERENCES public.refill_events(event_id) ON DELETE CASCADE, -- parent visit
  action             text NOT NULL CHECK (action IN                    -- the physical action
                        ('refill','remove','write_off','transfer_out','transfer_in','wh_return','wh_receive')),
  boonz_product_id   uuid NOT NULL REFERENCES public.boonz_products(product_id) ON DELETE RESTRICT, -- resolved SKU (never free text)
  shelf_id           uuid REFERENCES public.shelf_configurations(shelf_id) ON DELETE RESTRICT,  -- pod shelf (NULL for WH-only lines)
  qty                numeric NOT NULL CHECK (qty >= 0),                 -- units in this line
  set_mode           text NOT NULL DEFAULT 'delta'                     -- 'delta' (added N) vs 'set' (shelf now holds N)
                     CHECK (set_mode IN ('delta','set')),
  expiration_date    date,                                             -- batch expiry (NULL allowed for unattributed)
  warehouse_id       uuid REFERENCES public.warehouses(warehouse_id) ON DELETE RESTRICT,    -- source/dest WH (NULL if pod-only / net-zero)
  partner_machine_id uuid REFERENCES public.machines(machine_id) ON DELETE RESTRICT,        -- other leg of a transfer
  result_pod_inventory_id uuid,                                        -- what F2 wrote (audit back-pointer)
  applied            boolean NOT NULL DEFAULT false,                   -- did this specific line land
  notes              text
);
```

Both tables carry no `warehouse_inventory.status` write and no sensitive-column mutation — the applier RPC
does that through the existing gated RPCs, never here.

## Indexes

```sql
CREATE INDEX IF NOT EXISTS idx_refill_events_machine_date
  ON public.refill_events (machine_id, plan_date DESC);           -- Q1: everything on machine X on date D
CREATE INDEX IF NOT EXISTS idx_refill_events_status_pending
  ON public.refill_events (status) WHERE status IN ('pending','failed'); -- Q3: worklist of unapplied/failed (tiny partial)
CREATE INDEX IF NOT EXISTS idx_refill_event_lines_event
  ON public.refill_event_lines (event_id);                        -- header→detail expansion
CREATE INDEX IF NOT EXISTS idx_refill_event_lines_product
  ON public.refill_event_lines (boonz_product_id, applied);       -- Q2: audit a SKU across events
```

## RLS policies

```sql
ALTER TABLE public.refill_events      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.refill_event_lines ENABLE ROW LEVEL SECURITY;

-- read: any authenticated (Phase A permissive, matches sibling protected entities)
CREATE POLICY refill_events_select ON public.refill_events      FOR SELECT TO authenticated USING (true);
CREATE POLICY refill_lines_select  ON public.refill_event_lines FOR SELECT TO authenticated USING (true);

-- write: inventory-manager roles only (via user_profiles join, never auth.jwt())
CREATE POLICY refill_events_write ON public.refill_events FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_profiles
    WHERE id = (SELECT auth.uid())
      AND role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])));
CREATE POLICY refill_lines_write ON public.refill_event_lines FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_profiles
    WHERE id = (SELECT auth.uid())
      AND role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])));

-- append-only: no update / delete on the header (lines cascade with header only)
CREATE POLICY refill_events_no_update ON public.refill_events FOR UPDATE USING (false);
CREATE POLICY refill_events_no_delete ON public.refill_events FOR DELETE USING (false);
```

Note: F2 (SECURITY DEFINER) updates `refill_events.status`/`applied_at` as owner, bypassing the no-update
policy for the controlled lifecycle transition only — Cody to confirm this is acceptable (it mirrors how
`approve_return` mutates a protected row via a definer function).

## F2 contract (RPC body is implementer + Cody, not Dara)

```
record_actual_refill(
  p_machine_name text,
  p_plan_date    date,
  p_lines        jsonb,   -- [{action, product, shelf_code, qty, set_mode, expiration_date, warehouse, partner_machine, notes}]
  p_source       text  DEFAULT 'cs',
  p_actor        uuid  DEFAULT NULL,
  p_reason       text  DEFAULT NULL,
  p_dry_run      boolean DEFAULT true      -- Gate-1 by default: resolve + validate, write nothing
) RETURNS jsonb
```

Behaviour (one transaction, all-or-nothing):
1. Insert a `refill_events` header (`status='dry_run'` when p_dry_run, else `pending`).
2. For each line: resolve product + shelf, validate; insert a `refill_event_lines` row.
3. If not dry-run: apply each line by **orchestrating the existing proven RPCs** inside the same transaction
   — `adjust_pod_inventory` (pod), `adjust_warehouse_stock` / `transfer_warehouse_stock` (WH), and the
   `refill_plan_output` insert (log). Set `result_pod_inventory_id`, `applied=true`.
4. On success: header `status='applied'`, `applied_at=now()`. Any exception rolls back the whole transaction
   (header + lines + all three target tables) and the caller records `status='failed'` with `error_text`.

This makes a partial write structurally impossible (kills challenge B) and gives one queryable ledger
(kills challenge D's tracking gap). It reuses proven stock logic rather than reimplementing it, so it does
not re-open the FEFO question — it inherits whatever the underlying RPCs do (which the flow-validity ticket
will fix in one place).

## Tradeoffs and alternatives

- **Single table with `lines jsonb` (rejected).** Simpler DDL, but violates D2/D3 (untyped "figure it out
  later" column) and cannot serve Q2 (audit a SKU across events) without JSON scans. The two-level typed
  design is queryable and honest. When the jsonb version would be right: if lines were truly free-shape and
  never queried by product — they are not.
- **Reuse `refill_plan_output` with a `capture` flag (rejected).** rpo is the plan/log, keyed to plan
  semantics (operator_status, dispatched). Overloading it with physical-capture rows muddies both. Keep the
  capture ledger separate; F2 writes an rpo row as one of its three targets.
- **F2 reimplements stock math (rejected).** Higher fidelity control, but duplicates and diverges from
  `adjust_pod_inventory` / `adjust_warehouse_stock`. Orchestrating the existing RPCs is lower-risk and keeps
  one implementation of the merge/FEFO logic.

## Cody handoff checklist

- **Article 14 (protected entities):** add `refill_events` + `refill_event_lines` to Appendix A in the same
  migration that creates them.
- **Article 2/3 (RLS):** read = authenticated; write = manager-roles via `user_profiles` join; append-only
  header. Confirm shape.
- **Article 4/12 (audit):** the ledger IS the audit surface; F2 also leaves the existing per-table audit
  logs intact (it calls the gated RPCs which already audit). Confirm no double-standard.
- **Article 6 (sensitive `status`):** F2 must NOT write `warehouse_inventory.status`; it only moves qty via
  the gated RPCs. Confirm.
- **Article 5 (state machine):** `refill_events.status` transitions pending→applied / pending→failed /
  dry_run(terminal). Confirm the graph.
- **Article 15:** if "structured physical-capture ledger" is a new concept the Constitution doesn't cover,
  surface as an amendment.
```
