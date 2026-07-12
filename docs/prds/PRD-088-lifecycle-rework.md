# PRD-088 — Lifecycle Rework: one product-health view, phantom-aware, pod + boonz level

**Date:** 2026-07-08 · **Status:** DRAFT (CS review) · **Origin:** CS feedback on PRD-087 preview: "Lifecycle and Performance are confusing and overlapping; one view is needed. Lifecycle needs a refresh — not accounting for phantom data, and the analysis should be at pod product level as well as boonz product level."

## Problem

1. **Overlap.** Lifecycle (stages/signals per product) and Performance → Product Performance (velocity ledger) both rank products by movement. Two pages answer "how is this product doing?" with different numbers and different vocabularies.
2. **Phantom data.** Lifecycle stage math consumes sales/stock series that include phantom pod_inventory rows (WEIMI drift, un-archived expiry rows — see incident 2026-07-02: 148 phantom rows / 632 units archived fleet-wide) and name-drifted SKUs (weimi_product_alias, 17 drifted names). A product can read "DEAD" because its sales record under a drifted name, or "WIND DOWN" because phantom stock inflates supply.
3. **Wrong grain.** Sales record at pod-product grain (generic names, flavor-blind — PRD-064); procurement and margin live at boonz-product grain. Lifecycle currently mixes the two. Multi-SKU shelves (Chocolate Bar, Vitamin Well) need BOTH lenses: the shelf-facing pod lens (what velocity does the slot earn?) and the SKU-facing boonz lens (what do we buy/kill?).

## Proposed shape

**One module: Performance.** Lifecycle stops being a separate nav entry; its stage/signal logic becomes a "Lifecycle" lens inside the Product Performance ledger:

- **Level toggle: Pod product | Boonz product.** Pod level uses the name-normalized sales ledger (product_name_conventions + weimi_product_alias tier). Boonz level distributes pod sales to SKUs via product_mapping split_pct (normalized — the mix_weight lesson from the stitch bug), flagged as _modeled_ where a shelf is multi-SKU.
- **Lifecycle columns on the ledger:** stage (LAUNCH / RAMPING / CORE / WANING / WIND-DOWN / DEAD), weeks-in-stage, trend slope, distribution (machines carrying), and a "data quality" chip when the row is affected by drifted names or recent phantom archives.
- **Phantom hygiene as a precondition:** stage math reads v_live_shelf_stock (alias-aware, PRD-075d) — never raw planogram/pod_inventory; rows flagged by v_pod_phantom_stock are excluded from supply-side signals.
- **Stage rules recomputed on active-week velocity** (same basis as the ledger, refund-excluded) instead of the current lifecycle score — one number family across the app.

## Deliverables

1. Read-only view/RPC `get_product_lifecycle_ledger(p_level, p_weeks)` (Dara design → Cody review) built on the get_product_velocity_ledger CTE spine + stage classifier.
2. FE: lens toggle on the Product Performance tab; Lifecycle nav entry removed (redirect); old lifecycle page retired after one cycle of side-by-side validation.
3. Validation pack: current lifecycle stage vs new stage per product, with diffs explained (phantom/alias/grain) before cutover.

## Out of scope

POS flavor capture (true fix for multi-SKU blindness — separate PRD), engine consumption of the new stages (the refill brain keeps its own signals until validated).

## Open questions for CS

- Stage thresholds: keep current stage taxonomy or redefine around units/active-week bands?
- Should WIND-DOWN/DEAD stages auto-propose strategic_intents (product-opt) or stay display-only? (Recommend display-only first cycle.)
