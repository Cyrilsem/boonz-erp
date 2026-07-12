# PRD-099 — `approve_return` fails `wh_provenance_event_required` on legacy/manual returns

**Date:** 2026-07-09 · **Status:** SHIPPED 2026-07-10 (Cody PASS; empty-GUC + COALESCE deviation to preserve pipeline event ids). See EXECUTION-LOG. Reconcile = CS decision.
**Scope:** `approve_return()` (one function). Touches `warehouse_inventory` write path (UPDATE only).
No schema change, no data migration.

---

## Problem

In an inventory-control session, approving a warehouse return fails with:

```
new row for relation "warehouse_inventory" violates check constraint "wh_provenance_event_required"
```

Live blocker: Simran's **Barebells Hazelnut Nougat** return from Addmind (5 removed, machine showed 3).
Booked to WH manually via `adjust_warehouse_stock` as a stopgap 2026-07-09 — see "Reconcile the stopgap".

**Relationship to PRD-098:** PRD-098 (shipped 2026-07-10) built `approve_return` to clear the return
quarantine backlog, including the ~68 recoverable **legacy `unknown_pre_migration`** units. Those legacy
rows are precisely the ones that fail here (NULL `source_event_id`), so PRD-098's legacy-clearing path is
currently blocked. PRD-099 is the one-line completion that unblocks it.

## Root cause (verified against the live catalogue + data)

The constraint is:

```sql
CHECK ( provenance_reason IS NULL
     OR provenance_reason IN ('manual_adjust','snapshot','status_flip','unknown_pre_migration')
     OR source_event_id IS NOT NULL )
```

The FE "Approve return" button calls **`approve_return(p_wh_inventory_id, …)`**. That function takes a
pending quarantine row and unconditionally rewrites it:

```sql
UPDATE public.warehouse_inventory
   SET provenance_reason = 'dispatch_return',            -- ← NOT in the whitelist
       expiration_date   = COALESCE(p_corrected_expiry, expiration_date),
       warehouse_stock   = COALESCE(p_corrected_qty, warehouse_stock)
 WHERE wh_inventory_id = p_wh_inventory_id;
```

It sets `app.provenance_reason='dispatch_return'` but **never sets `app.source_event_id`**, and the row's
own `source_event_id` is left untouched. So after the flip the row has a non-whitelisted reason
(`dispatch_return`) — and the constraint then _requires_ `source_event_id IS NOT NULL`.

- Returns that came **through the dispatch pipeline** (`return_dispatch_line`, batch
  `REMOVE-RECEIVE-2026-07-xx`) already carry a `source_event_id` → the flip passes. That's why most
  approvals work.
- Returns that are **manual / legacy** carry `provenance_reason='unknown_pre_migration'` (whitelisted)
  with `source_event_id = NULL`. Flipping them from a _whitelisted_ reason to the _non-whitelisted_
  `dispatch_return` while the event id is still NULL trips the constraint. Confirmed on the two failing
  Barebells Hazelnut rows: `6cb1b7b2…` (exp 2026-12-12) and `8f24dda3…` (exp 2026-12-22), both
  `unknown_pre_migration` + `source_event_id = NULL`.

`approve_return` is the **only** warehouse writer that stamps a non-whitelisted, event-requiring provenance
without ever supplying an event id. (`drain_consumer_stock_phantom` and `repair_unbound_dispatch` also skip
`source_event_id`, but they use the whitelisted `manual_adjust`, so they're safe.)

## Fix — the approval IS the event; give it one

An approval is a bona-fide event, so `dispatch_return` is the right provenance — it just needs an event id.
In `approve_return`, mint an approval event id and ensure the row carries it:

```sql
DECLARE v_event uuid := gen_random_uuid();
...
PERFORM set_config('app.provenance_reason','dispatch_return', true);
PERFORM set_config('app.source_event_id', v_event::text, true);      -- ← NEW
...
UPDATE public.warehouse_inventory
   SET provenance_reason = 'dispatch_return',
       source_event_id   = COALESCE(source_event_id, v_event),        -- ← NEW (keep pipeline id if present)
       expiration_date   = COALESCE(p_corrected_expiry, expiration_date),
       warehouse_stock   = COALESCE(p_corrected_qty, warehouse_stock)
 WHERE wh_inventory_id = p_wh_inventory_id;
```

`COALESCE` preserves the real dispatch event id for pipeline rows (no behaviour change there) and supplies
a fresh approval-event id for manual/legacy rows. Optionally also write `v_event` into
`return_approval_log` for traceability. One function-body change; no schema, constraint, or data change.

### Optional belt-and-suspenders (recommended, separate)

Make `set_warehouse_inventory_provenance` fail loud: if the incoming `provenance_reason` is event-requiring
and `source_event_id` is empty, `RAISE EXCEPTION` naming `current_setting('app.rpc_name', true)` — so the
next mis-wired writer gets "RPC X set an event-reason without an event id" instead of the opaque check
violation.

## Reconcile the stopgap (do before/with ship — avoid double count)

On 2026-07-09 the Barebells Hazelnut Nougat units were already credited to WH_CENTRAL manually via
`adjust_warehouse_stock`. Once `approve_return` is fixed, **do not also approve** the pending Hazelnut
quarantine rows for the same physical units (`6cb1b7b2…`, `8f24dda3…`) — that would double-count. Either
discard those quarantine rows, or reverse the manual credit and let the fixed approval carry the units.
Confirm with CS which side to keep.

## Acceptance

- Approving a return through the inventory-control session succeeds for **manual/legacy** rows
  (`unknown_pre_migration`, NULL event) as well as pipeline rows.
- After approval the row has `provenance_reason='dispatch_return'` and a non-null `source_event_id`.
- Pipeline rows keep their original `source_event_id` (COALESCE), unchanged behaviour.
- No change to the constraint, the trigger contract, the whitelist, or any data.

## Cody handoff checklist

- **Article 6 (`status` sensitive):** `approve_return` doesn't flip `status` — confirm the fix doesn't add one.
- **Article 4/12 (audit):** approval already writes `return_approval_log`; optionally record `v_event` there.
- **Article 14:** function-body change on a protected-entity writer → Cody review + guarded apply.

## Rollback

`CREATE OR REPLACE FUNCTION approve_return(...)` restoring the prior body (drop the two new lines). No data
undo.
