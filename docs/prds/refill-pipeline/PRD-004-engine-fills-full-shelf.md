---
id: PRD-004
title: Refill engine recommends adding units to already-full shelves
status: Done
severity: P1
reported: 2026-05-21
source: Refill update 21-05-2026 — OMDCW-1021 Dubai Popcorn
routing: [refill-brain, Dara]
protected_entities: [pod_inventory, refill_plan_output]
done_summary: |
  Live diagnostic (2026-05-22 via read MCP): zero refill rows in the latest
  approved plan would overfill their shelf — the engine cap from
  propose_add_plan v2 G3 is doing its job at plan time. Migration
  20260522100501_* adds the reactive audit layer:
    - shelf_overfill_log append-only table (overflow_units GENERATED)
    - trigger on refill_dispatching UPDATE when item_added flips true:
      logs if (existing pod_inventory + filled_quantity) > max_capacity
    - v_planning_overfill_risk view for pre-pickup verification
  No false-positive scenarios observed in current data; the audit
  surfaces future drift between engine cap and live shelf state.
---

# PRD-004 — Refill engine recommends adding units to already-full shelves

## Problem

On 2026-05-21 at OMDCW-1021, the engine generated a REFILL line for Dubai Popcorn, but the shelf was physically full when the driver arrived. The engine's view of pod state diverged from reality — it believed there was room to add units when there was none.

This is a calibration bug between `pod_inventory` (what the engine sees) and the actual physical state of the slot, OR a bug in how shelf capacity is enforced when ENGINE ADD writes a REFILL draft.

## Observed behaviour

- Machine: OMDCW-1021
- Product: Dubai Popcorn
- Engine action: ADD recommendation for additional units
- Reality: shelf full
- Driver action: did not refill that line; reported back

## Expected behaviour

ENGINE ADD must not write a REFILL line whose final on-shelf qty would exceed the slot's `capacity_units`. R7 (the 60% shelf cap on swaps) provides a related guardrail, but R7 is about swap composition, not absolute capacity. There needs to be a hard absolute-capacity guardrail on ADD too.

Specifically: `pod_inventory.current_qty + refill_qty <= slot.capacity_units` must hold for every line written to `refill_plan_output`.

## Hypothesis on root cause

Three plausible failure modes:

1. **Stale pod_inventory.** Sales since the last refresh weren't applied, so `current_qty` underestimates real on-shelf qty (which would normally lead to OVER-recommending — not the observed case). OR returns/M2M moves weren't applied, so `current_qty` underestimates additions. Inspect when pod_inventory was last refreshed before the plan ran.
2. **Capacity field missing or wrong.** `slot.capacity_units` may be NULL, 0, or set to a fleet-average default that doesn't match the physical slot. In that case the engine has no ceiling to honour.
3. **ADD pass doesn't check capacity.** The engine logic in `engine_add_pod` (Stage 2a) may compute "desired qty based on velocity" without subtracting current qty or capping at capacity.

Once root cause is named, the fix could be a one-line guard, a pod_inventory refresh trigger, or a Dara-led schema fix to populate capacity reliably.

## Scope

In scope:

- ENGINE ADD logic in `engine_add_pod` (Stage 2a per CLAUDE.md / refill-brain skill)
- pod_inventory refresh cadence and any caching layer between pod_inventory and the engine
- Slot capacity column health audit across the fleet

Out of scope:

- R7 60% shelf cap (already in effect for swaps)
- Swap placement (covered in [[PRD-005-swap-engine-ignores-better-shelf]])

## Protected entities touched

`pod_inventory`, `refill_plan_output`. Cody review on any guardrail SQL.

## Acceptance criteria

- [ ] Reproduce: synthetic case where pod_inventory says current_qty=10 and capacity=12 — engine must cap REFILL at 2, not >2
- [ ] Audit: report of slots fleet-wide where `capacity_units IS NULL OR capacity_units = 0` (Dara investigates)
- [ ] Guardrail: SQL constraint or RPC-level check that no `refill_plan_output` line produces final_qty > capacity
- [ ] If pod_inventory is stale at engine run time, the engine logs a warning and skips that pod for ADD (do not write a risky REFILL)
- [ ] Test re-run on OMDCW-1021 Dubai Popcorn shows no over-fill recommendation

## Edge cases (all must verify before marking Done)

- **capacity_units NULL:** ADD pass blocks for that slot; admin alert raised listing all NULL-capacity slots.
- **capacity_units = 0:** ADD pass blocks.
- **current_qty > capacity_units (data integrity violation):** ADD blocked, alert raised, slot flagged for physical recount.
- **current_qty + planned_refill == capacity_units exactly:** allowed (no off-by-one).
- **Slot in MAINTENANCE state:** skipped entirely per refill-brain rules (don't fail the run).
- **Slot in RAMPING state:** allowed but pearson-confirmed per [[PRD-008-refill-plan-shows-phantom-skus]] edge case.
- **pod_inventory snapshot >4h old at engine run time:** ADD pass skips that pod and logs a freshness warning (no risky REFILL written).
- **planned_refill = 0:** no-op, no row written.

## Verification

- [ ] `npx tsc --noEmit`, `npm run build`, `npm run lint`
- [ ] Unit test on `engine_add_pod` capacity branch
- [ ] Re-run brain for OMDCW-1021 against current pod state and verify Dubai Popcorn is excluded
- [ ] Cody review

## Decisions

- **Pod_inventory freshness diagnostic:** add a column or log row capturing `pod_inventory_snapshot_at` for every brain run, so freshness drift is observable going forward. For the 2026-05-21 OMDCW investigation specifically: cross-reference the n8n 4h refresh schedule (per CLAUDE.md) against the brain run timestamp — diagnostic step, not a decision.
- **Capacity field location:** `slot.capacity_units` is canonical (per-machine slot instance). `planogram` carries the INTENDED capacity (template); `shelf_configurations` holds physical layout metadata. If a slot's actual capacity diverges from the planogram, `slot.capacity_units` overrides. This is standard in retail: the physical bay knows its own capacity better than the template does.
- **NULL capacity default:** BLOCK ADD entirely. Treat NULL as zero room. Conservative bias — never recommend a fill we can't verify will fit. A fleet-average default papers over the real bug (the missing data) and risks repeating the Dubai Popcorn failure mode elsewhere. Surface NULL-capacity slots in an admin alert until they're filled in.

## Linked PRDs

- [[PRD-005-swap-engine-ignores-better-shelf]] — sibling engine placement issue at the same machine
- [[PRD-008-refill-plan-shows-phantom-skus]] — same underlying theme of engine seeing wrong state
