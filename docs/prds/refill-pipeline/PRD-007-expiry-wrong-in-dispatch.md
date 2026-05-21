---
id: PRD-007
title: Expiry dates shown in dispatch don't match warehouse batch reality
status: Blocked
severity: P1
reported: 2026-05-21
source: Refill update 21-05-2026 — Addmind & USH Hunter Ridges
routing: [Stax, refill-brain]
protected_entities: [warehouse_inventory, refill_plan_output]
blocked_reason: |
  Decision: "refill_plan_output MUST carry wh_inventory_id (specific batch reservation)"
  — that's a structural change to a protected table + matching change in
  stitch_pod_to_boonz (body in live DB). Schema migration here would be a Dara/Cody
  pass adding `from_wh_inventory_id uuid REFERENCES warehouse_inventory` (already
  exists per migration 20260514_phaseF_bug012_structural_fix — see
  sync_dispatch_expiry_from_pinned_wh trigger). The trigger reference suggests the
  pin already exists on refill_dispatching but maybe not on refill_plan_output;
  needs verification on the live DB before writing the migration. FE expiry display
  change in dispatching/packing pages is doable but only meaningful once Stitch pins
  the batch. PO-receive expiry-anomaly warning IS pure FE and could ship; logged as
  a follow-up here rather than partial Done.
---

# PRD-007 — Expiry dates shown in dispatch don't match warehouse batch reality

## Problem

On 2026-05-21, the dispatch / picking app displayed wrong expiration dates for several Hunter Ridges items:

- **Addmind-1007 — Hunter Sea Salted:** shown as 01/02 (year unclear from doc), actual on the batch differs.
- **Addmind-1007 — Hunter Hot & Sweet:** shown as 05/11, actual differs.
- **Ushuaia (USH-1008) — Hunter Hot & Sweet:** shown as something wrong, correct expiry is **08/03/2027**.

When dispatch expiry display is wrong, drivers either pick the wrong batch (violating FEFO and increasing waste risk) or get confused about whether to refuse a pick. This also undermines [[expiry-opt]] dissolve-batch intents because the engine and the driver are looking at different truths.

## Observed behaviour

- Hunter Ridges variants at multiple machines show expiry strings that differ from the actual `warehouse_inventory` batch the driver picked from
- No error — just silent display drift

## Expected behaviour

The expiry shown to the driver MUST be the expiry of the specific `warehouse_inventory` row that FEFO selected at pick time. Per CLAUDE.md: `expiration_date ASC NULLS LAST, walk all batches`.

If the picking flow has multiple batches available for one SKU, the displayed expiry should be the earliest expiration date among the units the driver will pick (or per-unit if expiry varies within the pick).

## Hypothesis on root cause

Three candidate root causes:

1. **Stitch (Stage 3) writes an expiry that's stale.** Stitch picks a batch at plan time, but by the time the driver picks, FEFO would have walked to a different batch. The plan still shows the old batch's expiry.
2. **Dispatch UI joins on `boonz_product_id` alone, not on `wh_inventory_id`.** It picks "an" expiry from any batch of the product, not the FEFO batch.
3. **Manual mis-keying when receiving the PO.** The expiry on the batch row is wrong at source — the display is honest about a bad input. Cross-check with PO receive flow.

The first two are software bugs; the third is a data hygiene issue that suggests adding validation at PO receive.

## Scope

In scope:

- Stitch's batch-selection output (does it pin a wh_inventory_id?)
- Picking UI's expiry render path
- PO receive validation: warn if expiry looks unreasonable (e.g. <30 days, >24 months for non-shelf-stable categories)

Out of scope:

- Rebuild of the FEFO walk algorithm (it works per CLAUDE.md)
- Reprinting / relabelling physical batches

## Protected entities touched

`warehouse_inventory`, `refill_plan_output`. Cody review on any RPC change.

## Acceptance criteria

- [ ] Reproduce: machine has Hunter with two WH batches of different expiry — picking UI shows FEFO batch expiry
- [ ] If multiple batches are pulled for one line, UI shows per-batch breakdown
- [ ] Three reported Hunter cases (Addmind Sea Salt, Addmind Hot & Sweet, USH Hot & Sweet) re-run against current data and now match reality
- [ ] PO receive flow warns the user when expiry value seems anomalous (configurable thresholds per category)
- [ ] Append-only log row written when the displayed expiry differs from what was eventually picked (drift detector)

## Edge cases (all must verify before marking Done)

- **Pinned wh_inventory_id no longer exists at pick time** (sold or expired between plan and pick): fall back to next FEFO batch, log deviation, continue without blocking.
- **Two batches with identical expiration_date:** deterministic tiebreaker — lowest `wh_inventory_id` wins (avoids non-deterministic FEFO).
- **Pick spans multiple batches:** UI shows earliest expiry as default, per-batch breakdown on tap.
- **All batches for product gone at pick time:** procurement alert raised, line skipped without crash.
- **Expiry drift >14 days between pinned and FEFO-resolved at pick:** soft hold triggers, driver acknowledges to proceed.
- **Driver picks a different batch than pinned:** allowed, deviation logged (drivers sometimes can't reach the pinned batch physically).
- **Wh row with NULL expiration_date:** ordered last per CLAUDE.md FEFO rule (`NULLS LAST`); never the default pick.

## Verification

- [ ] `npx tsc --noEmit`, `npm run build`, `npm run lint`
- [ ] Manual test with two batches; confirm FEFO ordering and display
- [ ] Cody review

## Decisions

- **Batch reservation in refill_plan_output:** `refill_plan_output` MUST carry `wh_inventory_id` (a specific batch reservation), not just `boonz_product_id`. Stitch pins the FEFO-resolved batch at plan time and reserves it. Without batch pinning, two machines on the same plan can both "claim" the same units, and FEFO can be cherry-picked out from under a plan that was already published. This is the structural fix; expiry display drift is a downstream symptom of unbacked planning.
- **USH Hot & Sweet diagnostic:** convert to a side-by-side verification step in acceptance criteria — query the WH row's actual `expiration_date` at plan time, compare to the value rendered in the picking app, capture both in the log. Don't guess; instrument.
- **Soft hold on expiry drift:** YES. If at pick time the FEFO batch's expiry differs from what was pinned at plan time by more than 14 days (matching the [[expiry-opt]] safety buffer), the picking app prompts for confirmation. Captures the divergence without blocking the route, and feeds back into Stitch calibration.

## Linked PRDs

- [[PRD-006-dispatch-enforces-single-variant]] — same picking surface
- [[PRD-008-refill-plan-shows-phantom-skus]] — same theme of plan ↔ WH divergence
