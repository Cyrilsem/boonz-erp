---
id: PRD-001
title: M2M swap misroutes destination machine to warehouse
status: Blocked
severity: P0
reported: 2026-05-19
source: Refill update 21-05-2026 — System Bugs pipe row 1
routing: [refill-brain, Cody]
protected_entities:
  [pod_inventory, warehouse_inventory, refill_plan_output, slot_lifecycle]
blocked_reason: |
  Root-cause and fix both require source for `swap_between_machines` and
  `receive_dispatch_line` (per RPC_REGISTRY both are M2M-aware), which live in the
  live DB, not in the source tree as anything but stub migration files. The IFLY-1024
  → AMZ virtual reconcile requires live data + the PRD-003 quarantine flag to be
  applied first. FE-side M2M handler investigation is possible (files under
  src/app/(field)/field/dispatching/, packing/, pickup/) but the load-bearing
  change is the DB-level guard rejecting M2M completion with destination=warehouse.
---

# PRD-001 — M2M swap misroutes destination machine to warehouse

## Problem

On 2026-05-19, a MACHINE_TO_MACHINE (M2M) swap of 12 Barebells was created with IFLY-1024 as the source and AMZ as the destination. When the driver executed the route, the 12 Barebells were physically and digitally moved into the warehouse instead of into AMZ. The destination leg of the M2M flow was silently dropped.

This is a correctness defect in the M2M pipeline. Any M2M swap currently risks landing inventory in the wrong location, which will then show as WH excess (compounding [[PRD-003-phantom-mcc-wh-inventory]]) and as a missed fill at the destination.

## Observed behaviour

- Source: IFLY-1024 (Barebells, qty 12)
- Intended destination: AMZ machine
- Actual destination: warehouse (MCC WH most likely, since that's the driver's home WH)
- No error surfaced to the driver — the move "succeeded" with the wrong destination
- Reported by CS in the 2026-05-21 refill update

## Expected behaviour

An M2M intent must execute as a two-leg atomic operation:

1. Decrement source pod_inventory by N
2. Increment destination pod_inventory by N

The warehouse must never appear as a destination for an M2M intent. If the destination leg cannot be completed (destination machine unreachable, slot mismatch, capacity exceeded), the move must fail loudly and roll back the source leg, not silently fall through to WH.

## Hypothesis on root cause

Three plausible failure modes — investigation should rule them in/out in this order:

1. **Driver app falls back to WH return when destination slot is rejected.** The PWA might be catching a downstream error (e.g. destination slot already full, planogram mismatch) and rerouting to MACHINE_TO_WAREHOUSE. Check the M2M handler in the field PWA and any try/catch around the destination leg.
2. **n8n flow has a wrong default branch.** If the orchestration uses an n8n flow with a conditional that defaults to WH on any non-success, the destination dispatch can leak into a return flow.
3. **Source and destination are written as separate driver_tasks with no transactional link.** If the destination task is created with a wrong machine_id (or omitted), only the source-leg "return" survives.

Per CLAUDE.md: anything touching `pod_inventory` and `warehouse_inventory` is protected — Cody must review the fix.

## Scope

In scope:

- M2M handler in field PWA (dispatch/return flow)
- Any RPC/edge function that mutates pod_inventory for M2M
- n8n flows that participate in M2M routing
- Add an integrity check / DB constraint that an M2M intent cannot complete with destination = WH

Out of scope:

- Refactor of MACHINE_TO_WAREHOUSE return flow itself
- Backfill of historical misrouted moves (separate cleanup task once root cause is known)
- New UI for M2M planning

## Protected entities touched

`pod_inventory`, `warehouse_inventory`, `refill_plan_output`, `slot_lifecycle` — Cody review required before any migration or RPC change.

## Acceptance criteria

- [ ] Reproduce: create an M2M intent in staging where destination slot is intentionally invalid, confirm current behaviour drops to WH
- [ ] Root cause identified and named (one of the three hypotheses above, or new finding documented)
- [ ] Fix lands: M2M with invalid destination FAILS LOUDLY — source leg rolls back, driver sees actionable error
- [ ] DB-level guard added: any write that would close an M2M intent with `destination_kind = 'warehouse'` is rejected
- [ ] Append-only log entry written for every M2M attempt (success and failure)
- [ ] Backfill plan documented (not executed in this PRD) for the IFLY-1024 → AMZ Barebells case
- [ ] Replayed reconciliation: AMZ shows the missing 12 Barebells; MCC WH credit reversed

## Edge cases (all must verify before marking Done)

- **Source == destination machine:** intent rejected at creation time with clear error.
- **Destination machine offline at execution:** move fails loudly; source leg rolls back; no partial state.
- **Destination slot full (no capacity):** move fails loudly; source leg rolls back.
- **Destination slot has wrong product (planogram mismatch):** move fails loudly; source leg rolls back.
- **Idempotency:** same M2M intent attempted twice (network retry) → second attempt is a no-op, never double-decrements source.
- **Connectivity loss mid-move:** resumable on reconnect; no partial commit (transaction holds or rolls back).
- **Concurrent M2M on same source product:** second move sees the decremented source state; if insufficient, fails loudly.
- **DB guard test:** any attempt to close an M2M intent with `destination_kind = 'warehouse'` is rejected at DB level (not just app level).

## Verification

- [ ] `npx tsc --noEmit`
- [ ] `npm run build`
- [ ] `npm run lint`
- [ ] Manual test in staging with a dummy M2M intent — happy path and forced-failure path
- [ ] Cody review checklist: append-only log, RPC SECURITY DEFINER, RLS, no bare `auth.uid()`
- [ ] Query proves no existing rows violate the new guard (or are quarantined in a separate cleanup task)

## Decisions

- **Transaction model:** single transactional RPC, both legs commit together or neither does. No 2PC, no partial state. Inventory atomicity is non-negotiable for an M2M move.
- **Schema:** one row representing the move, with `source_machine_id`, `destination_machine_id`, and a `status` enum (`pending` → `in_transit` → `completed` | `failed`). One row = one source of truth. Avoids the orphan-leg failure mode entirely.
- **Retry behaviour:** NO auto-retry on destination failure. Fail loudly, surface to the driver, require a human decision. Auto-retry hides systemic issues and silently corrupts data trust — exactly how we ended up with phantom rows.
- **Historical IFLY-1024 reconciliation:** virtual reconcile with documented audit trail. The 12 Barebells are physically at MCC WH already; driving them back wastes labor and adds movement risk. Adjust inventory virtually: increment AMZ pod_inventory, decrement MCC WH, write an append-only `manual_correction` log entry citing this PRD. Use the case as the first test row for the new audit view in [[PRD-003-phantom-mcc-wh-inventory]].

## Linked PRDs

- [[PRD-003-phantom-mcc-wh-inventory]] — phantom WH stock may include misrouted M2M items
- [[PRD-009-driver-feedback-ingest]] — driver should be able to flag this kind of failure inline
