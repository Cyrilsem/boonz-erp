# PRD-064 — Assortment / Variety Refill Signal (multi-SKU shelves)

Status: Open (PRD-071 sweep 2026-07-02). Verdict: parked 2026-06-28 by CS pending WS-B re-scope to the robust signal; Re-scope WS-B to the robust signal below before building.
Owner: CS · Author: Cowork conductor · Date: 2026-06-28
Governance: Dara (design) → Cody (Article 16; touches v_machine_priority) → apply.
Depends on: PRD-063 (extends the picker urgency view).

## ⭐ REVISED APPROACH (2026-06-28) — physical variety capacity, not per-SKU stock

The share-weighted floor in WS-B below depends on **current per-SKU stock**, which is NOT
reliable today (pod_inventory per-flavor is stale/incomplete — NOOK Chocolate Bar tracked ~3–4u
vs 17u physical, snapshots months old). A simulation dialing it up lit up ~14 machines (noise).

Smarter signal that needs NO per-SKU data: **for a multi-SKU shelf, low fill IS low variety, by
physics.** A slot holding fewer units than its intended SKU count cannot present its assortment.
`variety_capacity = LEAST(units_in_slot, intended_SKU_count)`; flag when
`units_in_slot <= variety_floor` (e.g. ≤2) while `intended_SKU_count ≥ 3`. Uses the reliable slot
total (`v_live_shelf_stock`) + planogram SKU count (`product_mapping`, split_pct>0) only.

Validated 2026-06-28: this flags exactly 4 main machines (vs 14 for the fragile floor), with
**NOOK-1019 on top** (Vitamin Well 2u/7 SKUs + Krambals 2u/4 SKUs) — the machine CS expected.
Others: JET (Santiveri 1u/3), NISSAN (Keen Health 2u/3), USH (already P1). Build WS-B as this
capacity-variety signal; keep the per-SKU/refill-demand work (WS-A) as the later precision layer.

## Problem

Multi-SKU "category" shelves collapse to almost no variety between visits, and the brain
can't see it. Live evidence (2026-06-28, fleet averages):

| Shelf         | SKUs it carries | Avg SKUs in stock |
| ------------- | --------------- | ----------------- |
| Chocolate Bar | 8               | 1.5               |
| Vitamin Well  | 7               | 1.0               |
| Barebells     | 7               | 1.5               |
| Zigi          | 7               | 0.6               |
| Snack Bar     | 4–5             | ~0.5              |

Root cause: **sales don't record the flavor.** Every sale logs the generic product
(`pod_product_name='Vitamin Well'`, `boonz_product_id` NULL), and all flavors share one slot.
So the velocity the picker uses is the all-flavor aggregate — it cannot tell that the loved,
high-share SKUs are gone while the 5%-share laggards remain. A near-empty-variety shelf reads
"fine," isn't prioritized, and the customer sees one flavor.

Two facts that make this fixable WITHOUT the POS:

- The **refill side carries the SKU**: `refill_dispatching.boonz_product_id` + packed/picked_up;
  `refill_plan_output.boonz_product_name` + quantity. So we know what flavors we load.
- `product_mapping.split_pct` carries the **intended mix per SKU** (Vitamin Well 5–50%, no
  nulls — heroes high, laggards low). Plus a driver-feedback layer (`v_driver_feedback_demand`,
  `driver_feedback_notes`) for qualitative demand.

## Goal

(A) Recover per-SKU demand from refill records + driver notes (not the POS). (B) Add an
assortment-floor to the picker urgency so a multi-SKU shelf gets a more-pressing refill when
its **high-share** SKUs are depleted — measured as a **share-weighted ratio of capacity**, not
an absolute SKU count (per CS).

## WS-A — Per-SKU demand from refills (not POS)

`v_sku_demand_from_refill`: per (machine, SKU), consumption between visits =
Σ(loaded units from `refill_dispatching`, picked_up/packed) − current per-SKU stock
(`pod_inventory`), accumulated to a per-SKU velocity proxy. Fold in `v_driver_feedback_demand`
(field "flavor X always empty / customers want Y"). Output: a per-(machine,SKU) demand
estimate that identifies the heroes the POS can't.

## WS-B — Assortment floor (CS's design: share-weighted, capacity-ratio)

Per shelf = (machine, pod_product family):

- intended share `w_s` = `split_pct/100`, normalized per (machine, family) to sum 1; drop
  `split_pct = 0` SKUs (placeholders, not part of the intended assortment).
- target units `t_s = w_s × shelf_capacity`.
- per-SKU coverage `c_s = min(stock_s / t_s, 1)`.
- **assortment_health = Σ_s ( w_s × c_s )** — demand-weighted, 0–1. If the 50%-share hero is
  out, health drops ~0.5 even when a 5%-share SKU remains.
- floor signal `s_assortment = 100 × (1 − assortment_health)` (capped), gated to shelves above
  a min capacity. Added as a tunable-weighted component to `urgency`, OR a P2 trigger when
  `assortment_health < threshold`. Ratio-of-capacity, share-weighted — never a raw count.

## Design objects

1. `v_shelf_assortment` — per (machine, family): SKUs, normalized intended mix (`split_pct`),
   per-SKU stock, capacity, `assortment_health`, weakest high-share SKU. Reads
   `product_mapping` + `pod_inventory` + shelf capacity.
2. Extend `pick_urgency_params` (PRD-063) with assortment knobs: `w_assortment`,
   `assortment_health_p2`, `assortment_min_capacity`.
3. `v_machine_priority` (PRD-063 rewrite) consumes `v_shelf_assortment` → adds `s_assortment`
   to the urgency. (This PRD lands on top of PRD-063.)
4. `v_sku_demand_from_refill` (WS-A) for per-SKU demand + driver-demand wiring.

## Data prerequisites / caveats (validate before trusting the floor)

- `split_pct` has zeros (placeholder SKUs) — exclude from the intended assortment.
- `mix_weight` has a known normalization bug (cf. stitch VW 7→21 inflation, `bug_stitch_mix_weight_not_normalized`) — use `split_pct`, normalized per machine×family, and validate the sums.
- `pod_inventory` per-SKU Active counts may undercount post-PRD-059 — spot-check against
  physical before the floor goes live.
- WS-A refill-consumption proxy is noisy where the decrement logic assigns flavor-less sales to
  SKUs heuristically — treat it as directional until POS flavor capture exists.

## Acceptance tests

- T1 `v_shelf_assortment` computes assortment_health that drops sharply when a high-share SKU
  is out vs a low-share one (verify on Vitamin Well / Chocolate Bar).
- T2 with `w_assortment=0`, `v_machine_priority` is byte-identical to PRD-063 (golden — the
  floor is purely additive and dialable).
- T3 turning the dial up surfaces the variety-depleted multi-SKU shelves as P2/P1; arithmetic
  matches the param delta.
- T4 split_pct normalization sums to 1 per machine×family; 0-share SKUs excluded.
- T5 engines byte-identical; swaps_enabled false.

## Out of scope

POS flavor capture (WEIMI dispense → `sales_history.boonz_product_id`) — the true long-term
fix so flavor demand is measured at sale; separate ticket. Procurement mix re-balancing.
