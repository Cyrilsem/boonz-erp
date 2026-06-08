---
id: PRD-REFILL-V2
title: Refill v2 — fill-to-capacity add engine, reliable correlation-driven swap, driver-intent translator
status: Draft
date: 2026-06-08
owners: { design: Dara, review: Cody, implement: refill-brain + Stax }
protected_entities:
  [
    pod_refill_plan,
    pod_refills,
    pod_swaps,
    refill_plan_output,
    refill_dispatching,
  ]
supersedes_behaviour_in:
  [
    engine_add_pod v14,
    engine_swap_pod v8,
    pick_machines_for_refill v7,
    stitch_pod_to_boonz,
  ]
---

# PRD-REFILL-V2 — make the 8pm flow fill machines properly, reliably, every day

## Why (evidence, live 2026-06-09 draft, 94 refill rows)

The add engine under-fills selling shelves. Target = `max(velocity × 10 × cover_mult, floor_pct × capacity)`
capped at capacity. For modest-velocity sellers the velocity term is small, so the 70% floor governs:

- 61 of 94 rows (65%) hit `visual_floor` → filled to ~69%.
- KEEP stance (49 shelves, the bulk): avg 72% fill; 45 selling shelves left under 80%.
- Only STAR / DOUBLE DOWN reach 94–100%.
- Re-sized to "fill sellers to capacity": avg seller fill 77% → **97%**; sellers under 80% **62 → 3**
  (the 3 are warehouse-limited, not engine-limited); units 377 → **634** (~257 units of real demand were
  being dropped); **4 dead shelves** isolated for swap.

Two more problems: the swap engine is over-scoped (autonomous Pearson on every shelf + lifecycle
optimization — neither wanted), and driver intent (stored at boonz-SKU level + free text) is never
reliably translated into the pod-level plan or the SKU-level dispatch.

## The model (CS-approved 2026-06-08)

### A. Add / refill — "if it sells, it's full"

- **Quantity is decoupled from the score.** `final_score` / Pearson stay as RANKING only.
- **Every selling shelf fills to capacity.** `refill_qty = max_stock − current_stock` for any shelf that
  is not dead. Velocity no longer caps the fill.
- **Dead shelves get 0 and a swap tag.** Dead = stance ∈ (DEAD, ROTATE OUT, DEAD — SWAP NOW) OR
  `velocity_30d = 0`. Write the shelf to a swap-candidate list for stage B (do not refill).
- **Warehouse scarcity is the only throttle.** When `wh_avail < Σ needed`, allocate units to shelves in
  descending performance (velocity → final_score) so the best shelves fill first; the rest emit a
  `procurement_gap`.
- **Driver requested qty** is honored as a floor: `refill_qty = GREATEST(fill_to_cap, driver_req)`
  (already partially present; keep).

### B. Swap — narrow trigger, reliable swap-in

- **Trigger only:** a shelf whose product is DEAD / ROTATE OUT (the tags from stage A), low stock.
  No swaps for healthy underperformers (deferred). No lifecycle optimization (CS not comfortable — OUT).
- **Swap-in candidate = a product that performs globally and is NOT already in the machine,** ranked by
  Pearson / co-purchase correlation against THIS machine's basket for reliability (not just the 💎
  badge). Fall back to global performance rank when correlation is thin.
- **Removed product → warehouse (M2W)** so it can be reused elsewhere, not written off.
- **Driver-recommended swaps** (`driver_recommendations.kind ∈ needs_product / wrong_product`) are pulled
  in so none are missed.

### C. Driver-intent translator (new)

One resolver that takes any driver signal — pod product name, boonz SKU id, or free-text note — and
returns `{pod_product_id, boonz_product_id, qty, shelf_code (01–16)}`. Feeds: add (qty floor), swap
(product choice), and stitch (SKU overlay). Goal: never miss a driver ask, never mis-count.

### D. Expiry daily rule (new, lightweight — not the strategic batch engine)

For a slot holding expired/at-risk units: if the product still performs → refill it (stage A handles
it); if it does not perform → tag it for swap (stage B). That's the whole rule for now.

### E. Picker — P1 + siblings

`pick_machines_for_refill` selects on the new restock-urgency P1 definition (empty shelf / short runway /
strong-seller-low) and expands to venue siblings (sibling expansion already exists). Stop over-picking.

### F. Stitch — product mapping % + driver SKU overlay

`stitch_pod_to_boonz` keeps the `product_mapping` % split (pod → boonz SKU), then **overlays the driver's
SKU-level recommendation** (via the translator) so the exact boonz SKUs and counts are right, then
dispatches to the driver refill plan for the next day.

### G. Process & automation

8pm cron runs pick → add → swap → expiry → finalize and STOPS at the reviewable draft (server-side,
unattended; the build fix of 2026-06-07 already makes this reliable). Operator approves on the Vercel
page → backend stitches + dispatches with **no Cowork in the loop**. Shelf numbering is **01–16**
everywhere operator/driver-facing (canonical `shelf_code` is already A01–A16; the WEIMI 0-based index
stays internal only — add a guard so it never leaks).

## Dara — schema

- Swap-candidate tag: reuse `pod_swaps` / `planned_swaps` (add `reason='dead_tagged_by_add'`) rather than
  a new table — Dara to confirm the cleanest of the two. No `_v2` tables (Article 14).
- Translator: a read-only resolver `resolve_driver_intent(p_plan_date, p_machine_id)` returning the
  normalized rows; no new table needed (reads `driver_feedback` + `driver_recommendations` +
  `product_mapping` + `pod_products`).
- Correlation: reuse the existing Pearson source used by `find_substitutes_for_shelf` /
  `engine_swap_pod` Pass 2; no new structure.

## Cody — review (engine writers)

`engine_add_pod`, `engine_swap_pod`, `stitch_pod_to_boonz`, `pick_machines_for_refill` are canonical
writers → **diff-gate vs live, Hard Rule 10, CS green light before apply.** Articles 1, 4, 5, 8, 12, 14.
Read-only resolver (translator, candidate ranking) = SECURITY INVOKER (Article 4). No `warehouse_inventory.status`
writes (Article 6). Forward-only migrations (Article 12).

## Acceptance tests

- A1 (fill): on a re-run, ≥95% of selling shelves end ≥ 95% fill; remaining shortfalls are all
  `blocked_no_wh` (warehouse-limited), never engine-limited.
- A2 (dead): every dead shelf has `refill_qty = 0` AND a swap-candidate tag.
- A3 (swap-in): each swap-in is a product not already in the machine, performing globally, with a
  recorded Pearson/correlation score or an explicit global-rank fallback reason.
- A4 (M2W): every swap-out emits a paired warehouse return.
- A5 (no lifecycle / no underperformer swaps): zero swaps with reason ∈ (lifecycle, autonomous_pearson_healthy).
- A6 (translator): every `driver_feedback` / `driver_recommendations` row for the plan_date resolves to a
  pod+boonz+shelf, or is surfaced as `unresolved_driver_intent` (none silently dropped).
- A7 (stitch overlay): driver SKU asks appear in `refill_plan_output` at the right boonz SKU + qty.
- A8 (picker): picked set = P1 ∪ siblings; no warehouses/excluded.
- A9 (process): 8pm → draft with no human step; Vercel approve → stitch + dispatch with no Cowork; shelf
  codes 01–16 throughout.

## Out of scope (deferred, explicit)

Lifecycle-based inventory optimization. Underperformer (healthy) swaps. Strategic batch-expiry dissolution.
Automated source/PO-in-refill (RD-02/06).
