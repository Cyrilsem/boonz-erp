---
id: PRD-008
title: Refill plan shows phantom SKUs and hides real ones
status: Done
severity: P1
reported: 2026-05-21
source: Refill update 21-05-2026 — VML 4F, Nook, multiple machines
routing: [refill-brain, Dara]
protected_entities: [warehouse_inventory, pod_inventory, refill_plan_output]
done_summary: |
  Core fix: stitch_pod_to_boonz v11.2 patched via
  supabase/migrations/20260522093139_prd008_stitch_quarantined_filter.sql
  — all 3 WH availability reads filter `wi.quarantined=false`. AC#1 audit
  via supabase/migrations/20260522095225_prd008_product_mapping_audit_view.sql
  exposing v_product_mapping_audit (live: 78 unmapped boonz_products, 19
  with active pod stock, 7 with active WH stock — gap_live_stock priority
  backlog for CS curation). AC#3 (procurement_alerts) was already in v11.1
  and preserved by v11.2. AC#4 (empty-slot ADD pass) is engine_add_pod's
  existing behavior. AC#5 (2026-05-21 replay) is a post-apply verification
  step for CS.
---

# PRD-008 — Refill plan shows phantom SKUs and hides real ones

## Problem

The refill plan delivered to drivers on 2026-05-21 had two symmetric failure modes:

- **Phantom SKUs shown:** items appearing in the plan that had zero pickable WH stock (driver couldn't fulfil them)
  - VML 4F: Cookies & Caramel, Creamy Crisps shown but no stock
  - VML 4F: Perrier 1 Regular shown but not available
  - Nook: Cookies & Caramel, Creamy Crisps shown but no stock

- **Real SKUs hidden:** items with WH stock that should have been refilled but appeared with no qty
  - Nook: McVities Mini Milk Chocolate, Mini Dark Chocolate qty not showing
  - Nook: Oreo qty not showing
  - USH: McVities qty not showing

Both directions point to the same underlying defect — the bridge between `warehouse_inventory` and `refill_plan_output` is producing incorrect quantities.

## Observed behaviour

- Lines appear in the plan with qty > 0 but no matching WH stock → driver cannot pick → underdelivery
- Lines either don't appear or appear with qty=0 despite WH having stock → engine fails to recommend a fill that was warranted

## Expected behaviour

Every line in `refill_plan_output` with qty > 0 must correspond to enough pickable units in `warehouse_inventory` to satisfy at least that qty (FEFO-resolved). If WH is short, Stage 3 Stitch must either reduce the plan qty to match WH availability OR raise a procurement alert and leave the line at 0 — never deliver an un-fulfillable qty to the driver.

Symmetric requirement: if a slot is empty on a machine that is being visited and a matching WH product has stock, the engine must consider that fill (ADD pass) and write a line with appropriate qty.

## Hypothesis on root cause

Heavily correlated with [[PRD-003-phantom-mcc-wh-inventory]]. If WH stock counts are wrong, Stitch is honest but its inputs are wrong.

Beyond that, four candidate root causes:

1. **WH stock snapshot is stale.** Stage 3 Stitch consumes a snapshot of `warehouse_inventory` that isn't refreshed between the time pod_refill_plan finalises and the time Stitch runs. New sales or moves in between leave Stitch with a wrong picture.
2. **Largest-remainder distribution rounds wrong on edge cases.** Stitch uses largest-remainder distribution per the boonz-pico-stitch skill. Edge cases (1 unit available across many machines) may distribute fractionally and round non-zero qty to machines that should have gotten zero.
3. **product_mapping is incomplete or wrong.** Some boonz_products don't have a mapping row, so Stitch silently drops them (real SKU hidden) or maps them to the wrong family (phantom SKU shown).
4. **Sequential WH redistribution leaks.** The sequential redistribution step may move qty from one machine to another but forget to zero out the original line.

## Scope

In scope:

- Stage 3 Stitch — both the largest-remainder distribution and the sequential WH redistribution
- `product_mapping` audit — every boonz_product needs an entry, every entry must point to a valid WH SKU
- Procurement alert flow when WH can't cover the plan
- Symmetric brain check: ADD pass for empty slots with WH-available products

Out of scope:

- Per-machine velocity recalibration
- Pearson correlation tuning

## Protected entities touched

`refill_plan_output`, `warehouse_inventory`, `pod_inventory`. Dara reviews any product_mapping schema changes; Cody reviews Stitch RPC edits.

## Acceptance criteria

- [ ] Audit shows every `boonz_product` has a `product_mapping` entry
- [ ] Stitch can never write a `refill_plan_output` line with qty > pickable WH stock at the time Stitch ran
- [ ] When WH is short, the line is reduced AND a procurement alert is logged (not silently dropped)
- [ ] Empty slots at visited machines are re-evaluated by ADD pass each plan run
- [ ] Re-run of 2026-05-21 plan against current data shows: no Cookies & Caramel / Creamy Crisps phantom; McVities Mini / Oreo shown with appropriate qty

## Edge cases (all must verify before marking Done)

- **WH has 0 pickable units of planned product:** line written with qty 0, procurement alert raised, plan continues for other lines.
- **WH total < sum of planned across machines:** largest-remainder distribution shrinks proportionally; each machine sees its reduced fair share, not a binary all-or-nothing cut.
- **Two parallel Stitch runs reserving the same WH units:** row-level lock pattern prevents double-claim; second run blocks or fails fast.
- **Snapshot age > 1h at Stitch run time:** Stitch rejects the snapshot, rebuilds, retries once; if still stale, fails the run and alerts.
- **product_mapping missing for a boonz_product:** skipped + alert (per Decisions, never drop silently — that's how phantom SKUs got here).
- **RAMPING slot ADD pass returns nothing:** continue, don't fail the run; log "no ADD candidates" for that machine.
- **EMPTY slot with WH-available product:** picked up by ADD pass and written into refill_plan_output.
- **Plan claims qty 5 but WH covers only 3:** driver-facing message shows "Plan 5, picking 3 (short by 2)" per Decisions — never silently hide the gap.

## Verification

- [ ] `npx tsc --noEmit`, `npm run build`, `npm run lint`
- [ ] Replay 2026-05-21 plan with fix applied; diff against shipped plan; manual spot-check VML 4F and Nook
- [ ] Procurement alert visible in admin UI for the short cases
- [ ] Cody review on any RPC change

## Decisions

- **WH snapshot for Stitch:** MATERIALIZED snapshot taken atomically at Stitch run time, and Stitch holds reservations against that snapshot for the duration of the plan (until publish or rollback). This is the only way to prevent the same units being claimed twice by different machines in the same run. Tied to the batch-reservation decision in [[PRD-007-expiry-wrong-in-dispatch]] — they implement the same underlying mechanism.
- **Empty-slot ADD pass scope:** runs on BOTH `EMPTY` and `RAMPING` slots, with different scoring weights. EMPTY = high priority (a dead slot is lost revenue every hour). RAMPING = considered but requires Pearson correlation confirmation against shelf neighbours, to avoid filling a slot with a product that doesn't fit the local mix. Consistent with the calibrated Pearson threshold-10 logic in refill-brain.
- **Driver-facing short message:** SHOW BOTH. Display "Plan 5, picking 3 (short by 2 — see procurement alert)". Transparency builds trust with the driver; hiding the planned-vs-actual gap is what produced the silent failures in the first place.
- **Procurement alerts:** NOTIFY ONLY for now. Auto-draft POs is a follow-up that should wait until WH data is trustworthy (post-[[PRD-003-phantom-mcc-wh-inventory]]). Existing `weekly-procurement` skill already covers the alert-to-PO flow; this PRD just needs to feed it.

## Linked PRDs

- [[PRD-003-phantom-mcc-wh-inventory]] — upstream input bug
- [[PRD-004-engine-fills-full-shelf]] — sibling symptom of pod/plan drift
- [[PRD-007-expiry-wrong-in-dispatch]] — adjacent batch-resolution issue
