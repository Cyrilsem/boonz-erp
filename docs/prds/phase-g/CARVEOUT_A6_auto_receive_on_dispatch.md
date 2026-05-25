# Carve-out PRD — A.6 Auto-receive on dispatch

**Parent:** PRD-Phase-G v2 Section 11 (Phase 4 scope)
**Status:** Carve-out from Phase G P4. Not shipped in 2026-05-25 batch.
**Reason for carve-out:** Behavioral change to the WH→pod handoff. Requires standalone staging window because every machine refill confirmation today must explicitly hit `receive_dispatch_line`; auto-receive flips that contract and rebases downstream reporting.

## Problem

When a packed dispatch is field-dispatched (`dispatched=true`) but never confirmed at the machine via `receive_dispatch_line` (network drop, app crash, driver skipped step), the `consumer_stock` reservation on `warehouse_inventory` is stuck indefinitely. The Saturday corrections cadence catches some via the C.6 reconciliation backstop; many slip through.

A.6 proposes that **dispatch automatically resolves the WH-pod handoff** for actions in `('Refill','Add New','Add')`:

- If `picked_up=true` AND `received_at IS NULL` AND the dispatch is older than N hours (proposed N=24), auto-call `receive_dispatch_line` with a system actor and an `auto_received_eod` reason.
- The receive RPC already exists and is the canonical writer — A.6 is the orchestration around it, not a new write path.

## Out-of-scope alternatives considered

1. **Move detection to FE polling.** Rejected: the FE only knows about its own dispatches. Server-side cron is the only reliable detector.
2. **Skip received_at and just drain consumer_stock at EOD.** Rejected: that loses the per-line audit trail. Re-using the canonical receive path gives us `inventory_audit_log` + `pod_inventory` updates for free.

## Proposed solution (sketch)

New cron `auto_receive_dispatch_lines` running 2am Dubai:

```sql
FOR v_row IN
  SELECT dispatch_id FROM refill_dispatching
  WHERE picked_up = true
    AND received_at IS NULL
    AND returned = false
    AND action IN ('Refill','Add New','Add')
    AND now() - picked_up_at > interval '24 hours'
LOOP
  PERFORM receive_dispatch_line(v_row.dispatch_id, 'auto_received_eod');
END LOOP;
```

Constitution articles to satisfy: 1 (single writer = receive_dispatch_line), 4 (set app.via_rpc), 8 (universal audit), 11 (cron via RPC).

## Why it needs standalone staging

`receive_dispatch_line` writes to `pod_inventory` and decrements `consumer_stock`. Running the auto-receive sweep across the live 2026-05-25 backlog without a manual dry-run could:

- Resurrect old un-confirmed dispatches that were intentionally abandoned (driver said "skip this row, fridge was broken" but never returned the row).
- Cascade into the daily flow reconciliation view (C.6) as a large one-time adjustment, swamping the daily delta and burying real anomalies.

Mitigation: **first run is dry-mode** (count + sample 10 rows, no actual receive). CS reviews the sample. Then `auto_run=true` on the second night.

## Open questions for CS

1. N hours threshold: 24 too aggressive? 48? PRD section 11 doesn't pin this.
2. Should the auto-receive set `received_qty = filled_quantity` blindly, or copy `driver_confirmed_qty` if non-NULL?
3. Acknowledge channel: should warehouse_admin see a daily Slack/email with the auto-received count, or just rely on the C.6 reconciliation view?

## Acceptance gate

- Dry-run report reviewed and signed off by CS.
- First live run touches no more than 20 rows.
- C.6 reconciliation delta for the run day is bucketed into a new `auto_received_eod` category, distinct from manual receives.

## Estimated ship window

Sprint after Phase G chapter closes. One week of FE-side flag dev for the warehouse audit chip, plus one staging dry run.
