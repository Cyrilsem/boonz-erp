---
id: PRD-002
title: Returns flow blocks splitting and changing product variant
status: Done
severity: P1
reported: 2026-05-21
source: Refill update 21-05-2026 — System Bugs pipe row 2
routing: [Stax]
protected_entities: [pod_inventory, warehouse_inventory]
done_summary: |
  Schema + RPC delivered across:
    20260521233552_prd002_006_product_families.sql   (product_families + FK)
    20260521234206_prd002_006_variant_action_log.sql (shared audit log)
    20260522095532_prd002_record_variant_correction_rpc.sql (canonical writer)
  Existing PendingRemoveApprovalsPanel.tsx already implements the WH-side
  multi-variant split (BUG-#2). New record_variant_correction RPC handles
  driver-side variant corrections atomically (pod_inventory + audit log).
  Cross-family swaps are blocked unless action_type='dispatch_extra_variant'.
  AC#1 (reproduce OMDCW-1021) + AC#2 (capture screenshot error) require live
  staging access, not in scope here — flagged in the migration footer.
  Family-membership backfill of boonz_products is CS curation per
  product_families migration footer.
---

# PRD-002 — Returns flow blocks splitting and changing product variant

## Problem

On 2026-05-21 at OMDCW-1021, the driver attempted to return 1 unit of Hunter Truffle from the day's dispatch. The returns UI showed the unit as Hunter Sea Salt instead of Hunter Truffle. The driver tried two paths to correct the variant — both failed:

1. **"Split by variant"** action did not allow changing the variant type.
2. **Manual add + change to Hunter Truffle** produced an error on save (screenshot in source doc).

Net effect: the driver cannot honestly record what is being returned. Either the wrong variant gets booked back into WH (corrupting `warehouse_inventory`), or the return is skipped entirely (leaving `pod_inventory` overstated). Both compound the data drift surfaced in [[PRD-003-phantom-mcc-wh-inventory]] and [[PRD-008-refill-plan-shows-phantom-skus]].

## Observed behaviour

- Item dispatched: Hunter Truffle (variant of Hunter ridges family)
- Item displayed in returns UI: Hunter Sea Salt
- Driver action 1 — "Split by variant": no editable variant selector, or the selector did not apply on save
- Driver action 2 — add 1 in the main box, change type to Hunter Truffle: backend returned an error (exact error message in source doc image — needs to be captured)
- Outcome: driver could not record the return cleanly

## Expected behaviour

- Returns UI should pre-fill the correct variant for each dispatched line, sourced from the same `driver_tasks` row that the dispatch was built from
- If the wrong variant is pre-filled, the driver must be able to edit it inline without leaving the screen
- "Split by variant" must let the driver split a single returned line across two or more variants of the same boonz_product family (e.g. 1 Truffle + 1 Sea Salt back from a 2-pack pick)
- Save must succeed and decrement the correct `pod_inventory` variant row + increment the correct `warehouse_inventory` batch row, FEFO-anchored

## Hypothesis on root cause

Two plausible failure modes:

1. **Display vs identity mismatch.** The dispatched item is stored as a generic `boonz_product_id` representing the Hunter family, with the variant resolved only at WH pick time. The returns UI then guesses the variant (defaults to first / alphabetical / last picked) instead of reading the actual picked variant from `slot_lifecycle` or the dispatch log. The "change" attempt fails because the underlying record has no variant column to update.
2. **Validation rejects same-family variant changes.** The save handler may be checking that the returned `boonz_product_id` equals the dispatched `boonz_product_id`, and rejecting cross-variant changes even within the same family. Need to confirm whether variants share a single product_id or have distinct ones.

Stax owns this fix (FE + the edge function / RPC the FE calls on save).

## Scope

In scope:

- Returns UI: variant pre-fill, inline edit, split-by-variant control
- Returns save RPC / edge function: validate same-family variant changes, write to correct pod/WH rows
- Add a server-side log row for every variant-change-on-return so we can audit driver edits

Out of scope:

- Dispatch-side variant assignment fix (covered in [[PRD-006-dispatch-enforces-single-variant]])
- WH receive flow for new POs

## Protected entities touched

`pod_inventory`, `warehouse_inventory` — both written on return commit. Cody review required for the RPC.

## Acceptance criteria

- [ ] Reproduce the exact OMDCW-1021 Hunter Truffle → Sea Salt mismatch in staging
- [ ] Capture the precise error string from the screenshot in the source doc and link it here
- [ ] Returns UI shows the actual dispatched variant by default
- [ ] Driver can change the variant inline; save succeeds without error
- [ ] "Split by variant" lets the driver split N units across same-family variants; sum-of-splits must equal the original line qty (validated client and server side)
- [ ] On save, the correct variant decrements `pod_inventory` and the correct FEFO batch increments `warehouse_inventory`
- [ ] Audit log row written: `{driver_task_id, original_variant_id, new_variant_id, qty, timestamp, driver_id}`

## Edge cases (all must verify before marking Done)

- **Split sum ≠ original line qty:** server rejects with clear error; UI shows validation inline.
- **Adding a new variant without reason_code:** rejected by server (per Decisions, new variant requires reason).
- **Variant outside the product_family:** rejected (cross-family belongs in substitution flow, [[PRD-006-dispatch-enforces-single-variant]]).
- **Save called twice rapidly (double-tap / network retry):** idempotent — latest payload wins, both attempts logged in audit table.
- **Network drops mid-save:** client queues optimistically and retries on reconnect; no orphaned half-saves.
- **Variant exists in family but has no SKU mapping:** rejected with explicit "no SKU mapping for this variant" message (don't silently default).
- **Empty save (driver clears everything and saves):** rejected — must have at least one variant line.

## Verification

- [ ] `npx tsc --noEmit`
- [ ] `npm run build`
- [ ] `npm run lint`
- [ ] Manual: simulate the OMDCW-1021 scenario end-to-end with `driver@boonz.test`
- [ ] Inspect `pod_inventory` and `warehouse_inventory` deltas match what the driver typed
- [ ] Cody review of any new RPC

## Decisions

- **Variant model:** variants are DISTINCT `boonz_product_id` rows, grouped by a `product_family_id` (or equivalent). Industry standard in retail/vending: every pickable SKU is its own product for inventory and FEFO; family is the analytics + swap-logic grouping. If the current schema collapses Hunter variants into a single product with a `variant` column, that's a Dara schema migration — paired with this PRD, not optional.
- **Audit log:** new table required — `return_audit_log` (driver_task_id, original_variant_id, new_variant_id, qty, reason_code, driver_id, created_at). Any human-driven inventory mutation needs append-only provenance. Reuse this same table for [[PRD-006-dispatch-enforces-single-variant]] substitution captures.
- **Adding a new variant not in original dispatch:** ALLOWED, with a mandatory `reason_code` (driver picked extra variant on the truck, swapped on the fly, etc.). Reality: drivers find off-plan units on the truck regularly. Block this and they'll either skip the return or mis-key — both worse than capturing the truth with a reason.
- **Cross-family splits:** NOT supported in this UI. Cross-family is a different operational event (substitution / replacement of a wholly different product) and belongs in the substitution flow from [[PRD-006-dispatch-enforces-single-variant]]. Keep the concerns separated to avoid a UI that does too much.

## Linked PRDs

- [[PRD-006-dispatch-enforces-single-variant]] — same family, dispatch side
- [[PRD-003-phantom-mcc-wh-inventory]] — wrong-variant returns may be one source of phantom WH stock
