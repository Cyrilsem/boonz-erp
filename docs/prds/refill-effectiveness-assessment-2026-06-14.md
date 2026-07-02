# Refill Effectiveness Assessment — 2026-06-14

Synthesis of the 2026-06-03 post-mortem, the reliability PRD, this week's sessions, and today's live investigation.

## Headline

The pipeline now runs end-to-end (plan, approve, stitch, dispatch, pack, pickup) and the worst silent-failure modes from early June are fixed. But the plan that reaches the machine is filling only about 41 to 42 percent of real shelf capacity, so drivers are re-doing the engine's job by hand on nearly every machine. Reliability improved; accuracy and fill did not.

## Effectiveness scorecard

| Dimension                                | State                       | Evidence                                                                                                                       |
| ---------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Plan reaches drivers end-to-end          | Working                     | 2026-06-14: 5 machines built, approved, dispatched, packed. The old silent stitch loss is gated.                               |
| Fill vs shelf capacity                   | Poor (~41-42%)              | 06-13 planned 204 vs gap 503 (41%); 06-14 planned 278 vs gap 661 (42%). Only days with capacity captured; both low.            |
| Pack completion                          | Partial (~87%)              | 06-14 packed 268 of 312, then 271 after a manual Coke substitution; 4 lines went dark-stage and needed manual skip + add.      |
| Quantity integrity (pod intent to shelf) | Broken on multi-SKU shelves | Red Bull pod 6 dispatched 1 with 66 in WH; stitch leaked ~5 units to an off-shelf SKU.                                         |
| Per-machine curation                     | Not honored                 | Snack Bar: AMZ-1057 curated Delice+KitKat dispatched with global McVities+Oreo added.                                          |
| Inventory ledger trust                   | Improved, edges manual      | consumer_stock drains correctly on receive/return now (verified today); shared-SKU and picked-up edits still need manual care. |

## What got fixed since the 2026-06-03 post-mortem

- RC2 packed-but-never-dispatched: stitch no longer confirms on a write error (atomic gate live). Largely resolved.
- RC3 driver recommendations ignored: `resolve_driver_intent` / `v_driver_feedback_demand` are now ingested by the engine and stitch. Resolved.
- RC5 phantom inventory: BUG-006 pack-to-receive pinning fixed; today's six Be-Kind returns drained consumer_stock cleanly. Mostly resolved.
- Dark-stage packing block (surfaced today): PRD-030 shipped today (backend live + FE deployed). A machine with out-of-stock lines now packs and dispatches; lines show as not-filled instead of freezing the bag.

## What is still not working

1. Under-fill to ~42% of capacity. Two compounding causes. (a) The engine targets velocity times 10 days of cover, not capacity, so slow movers come in well below shelf gap even when empty. (b) Stitch leaks quantity when a pod maps to multiple SKUs: units allocated to a SKU not physically on the shelf are dropped, not redistributed (Red Bull 6 to 1). Net effect: drivers hand-fill every visit.

2. Duplicate and inconsistent product_mapping. The Red Bull pod has about 80 active mapping rows; split_pct and mix_weight disagree on the same rows. This corrupts every distribution calculation.

3. Per-machine curation does not take. Stitch unions machine-scoped mapping with the global default instead of letting the curated set replace it, so every Amazon Snack Bar ends up the same.

4. Shared-SKU allocation is still creation-order, not fair-share or reserved. Cola and water read covered at dispatch then pack dry across bags (the 06-14 minus-44 and the original RC1). Not yet fixed.

5. No accuracy gate. The 06-14 stitch dry-run reported zero deviations while ~40 percent of intended quantity was missing. Nothing compares dispatched SKU totals to pod intent, so leaks pass silently.

6. Editing a picked-up bag is painful. Today's NOOK A05 swap needed add + zero + six returns because skip, remove, and product-change are all blocked once a line is picked up. PRD-030 fixes the packing stage, not the picked-up product-replace case.

## What the new pushes fix

- PRD-030 (LIVE today): dark-stage block gone; partial and not-filled packing; a short bag still dispatches. Directly fixes problem 6 at the packing stage and the dark-stage half of problem 4.
- PRD-024 + goal_mixweight (approved, not yet executed): stitch split normalization and canonical mix_weight. Fixes the distribution math behind problems 1b and 2.
- PRD-031 (drafted, not started):
  - WS-1 dedup mapping + UNIQUE constraint: kills problem 2.
  - WS-2 off-shelf redistribution: stops dropping units to absent SKUs, so Red Bull 6 dispatches 6. Fixes problem 1b.
  - WS-2b machine-scoped mapping authoritative: fixes problem 3 (curation takes).
  - WS-3 engine fill target (needs CS decision): fixes problem 1a, the ~42 percent under-fill.
  - WS-4 accuracy gate: fixes problem 5 (catches leaks before push).
  - WS-5 reserve shared SKU at stitch: fixes problem 4 (no more dry packs).
  - WS-6 wire sold_7d: removes the misleading zero-velocity display.

## Still uncovered after these pushes

- The engine fill target (WS-3) is a CS decision and is the single biggest lever on the ~42 percent number. Until it is decided, fill stays low even after the stitch fixes.
- Picked-up product replacement has no clean tool yet (today's NOOK dance). Worth a small follow-up PRD.
- Fair-share priority ordering (beyond simple reservation) for genuinely scarce shared SKUs may still need design after WS-5.
- Edge from PRD-030: a machine whose lines are all not-filled stays in the pickup list with nothing to collect (harmless, follow-up).

## Bottom line

Reliability is in good shape: plans no longer vanish, dark-stage is fixed today, inventory drains correctly. The open frontier is accuracy and fill. The stitch and mapping fixes (PRD-024, PRD-031 WS-1/2/2b) will stop the quantity leaks, and the accuracy gate (WS-4) will make leaks visible. But the headline ~42 percent fill will only move once the engine fill-target decision (WS-3) is made.
