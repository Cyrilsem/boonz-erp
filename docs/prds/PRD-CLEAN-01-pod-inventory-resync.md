# PRD-CLEAN-01 — pod_inventory Weimi-Authoritative Resync

Status: BLOCKED (2026-07-11) — M1 DDL applied to prod (RPC + audit CHECK); M2 fleet data run
denied by auto-mode permission classifier (destructive prod write needs attended approval).
Dry run validated: 37 machines, ~1,468 units off / ~2,756 added. See docs/prds/BLOCKED.md.
Priority: P0 (root cause — everything else reads this data)
Approved by CS: yes, no review gate. Weimi physical count wins fleet-wide.

## Problem

pod_inventory (the batch/expiry ledger) has diverged massively from physical
reality (Weimi). Worst machine: ledger 4,194 units vs 160 physical. 1,095
"expired" units currently on the books inside machines; 819 expired >30 days
ago on machines visited weekly. These are ghost batches: sales/removals do not
reliably decrement the batch ledger.

Consequence: `v_machine_health_signals.expired_skus_now` (source: pod_inventory)
feeds `v_machine_priority` → the picker burns P1 visit slots on phantom expiry,
FEFO binding is meaningless, EXPIRY OPT and waste metrics are garbage.

## Goal

After this PRD: for every machine+shelf, SUM(pod_inventory.current_stock)
== v_live_shelf_stock.current_stock (tolerance 0). Ghost stock written off with
full audit trail. Idempotent, re-runnable.

## Design — RPC `resync_pod_inventory_from_weimi(p_machine_id uuid DEFAULT NULL)`

SECURITY DEFINER, returns a summary table (machine_id, shelves_touched,
units_written_off, units_added_unattributed).

Per machine (all machines when p_machine_id IS NULL), per shelf:

1. physical_qty = current_stock from public.v_live_shelf_stock for that shelf.
   ⚠ JOIN BY slot_name, NEVER aisle_code (aisle_code is zero-indexed Weimi
   format `0-A09`; shelf_configurations.shelf_code is one-indexed `A10` —
   known off-by-one landmine).
2. ledger rows = pod_inventory WHERE machine_id/shelf_id match AND current_stock > 0.
3. Product mismatch: if the Weimi product on the shelf (resolved via
   product_mapping / weimi_product_alias) differs from a ledger row's product,
   zero that ledger row (write-off, reason 'drift_resync_product_mismatch').
4. ledger_qty > physical_qty: trim OLDEST batches first
   (ORDER BY expiration_date ASC NULLS LAST) — FIFO consumption means surviving
   physical stock is the newest. Decrement/zero oldest until ledger == physical.
   Log every decrement to pod_inventory_audit_log with reason 'drift_resync'.
5. ledger_qty < physical_qty: INSERT one unattributed batch row
   (expiration_date NULL, batch_id NULL, status 'Active',
   removal_reason NULL) for the remainder. Log reason 'drift_resync_unattributed'.
   These NULL-expiry rows are the follow-up list for driver expiry checks.
6. Weimi shelf has no snapshot (stale device): SKIP the machine entirely and
   report it — do not zero a machine on missing data (Weimi snapshot staleness
   is a known silent failure mode).

## Migrations (STRICT: DDL and data in SEPARATE apply_migration calls —

mixing them silently rolls back everything on any error)

- M1 (DDL): create the RPC. If pod_inventory_audit_log lacks a `reason` or
  `source` column able to carry 'drift_resync', add it here.
- M2 (data): `SELECT * FROM resync_pod_inventory_from_weimi();` — run OUTSIDE
  the 8pm Dubai cron window (cron 13 runs 16:00 UTC) and not while a stitch is
  mid-commit.

## Verification battery (must all pass before marking DONE)

1. `SELECT COUNT(*) FROM v_inventory_drift_check`-style recheck: per-machine
   |ledger − weimi| = 0 for every machine with a fresh Weimi snapshot.
2. Units expired >30d ago in machines: expect collapse from ~819 to near-real
   (record before/after in DECISIONS.md).
3. pod_inventory_audit_log write-off total == before/after ledger delta.
4. Re-run the RPC: second run touches 0 shelves (idempotency).
5. Spot-check 3 machines incl. the 4,194-unit outlier.

## Gotchas

- Do NOT touch refill_dispatching (packed rows are trigger-protected;
  irrelevant here — this PRD writes pod_inventory only).
- warehouse_inventory is out of scope (WH side is clean).
- Do not "fix" sales decrement logic in this PRD — root-cause fix is separate;
  this PRD establishes truth + the daily reconciliation must keep it (see
  follow-up note: verify cron_daily_inventory_reconciliation converges after
  resync; if it still drifts >2% in 7 days, open PRD-CLEAN-08).
