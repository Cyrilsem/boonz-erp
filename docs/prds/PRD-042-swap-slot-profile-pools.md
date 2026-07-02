# PRD-042 — Refill v5 Swap: slot-profile assortment pools (machine-level)

**Status:** Shipped (engine_swap_pod v15_slot_profile VERIFIED LIVE in prod 2026-07-02; see PROD-SYNC-PRD042-043-LOG.md). swaps_enabled stays `false`. engine_add_pod FROZEN. PRD-071 sweep.
**Owner:** CS (cyrilsem@gmail.com)
**Created:** 2026-06-20
**Replaces:** the abandoned PRD-041 (physical-compat gate) — removed 2026-06-20, never applied; its `physical_type_lane_family` idea is absorbed into P0 here.
**Depends on:** PRD-040 (`product_slot_capacity` + `product_slot_capacity_units` live; engine v14 gated off), PRD-039/037 (guardrails, value model, helpers).

## 0. Why (the model change)

Today's v14 Pass-3 does a **product-level swap over the raw warehouse universe**, then bolts on filters. It has no concept of what physically belongs in a slot, so it offers a bar into a yogurt/bottle/popcorn lane and sizes the order to the bar (25 units). Patching one more filter (PRD-041) treats the symptom.

CS model (2026-06-20): make the swap a **machine-level pick from a curated, size-appropriate pool**. A shelf needing change is a "slot profile" (its lane family + size); the engine picks the most suitable product for _this machine_ from that profile's pool, excluding what's already in the pod, at the pool's quantity. Physical fit and quantity are then correct **by construction** — the pool only ever contains products that belong in that slot, each carrying its own fill quantity.

## 1. Concepts

- **lane_family** — a form-factor family of `physical_type` (from PRD-041): bottle, can, snack_small, bag, boxed, cup, other. CS-approved grouping; coverage 14/14.
- **slot profile** — `(lane_family, shelf_size)`. A band-3 slot resolves to its profile via incumbent `physical_type -> lane_family` and the planogram `shelf_size`.
- **assortment pool** — for a profile, the set of eligible products, each with a fill quantity. **Auto-derived then curated, recomputed nightly:** every product whose `lane_family` matches, with `fill_qty = floor(product_slot_capacity_units(product.physical_type, size) * 0.85)`; CS overrides (include/exclude) layered on top. Persisted to a precomputed table refreshed every night so the engine just reads it (fast), no live derivation at engine time.
- **most suitable** — rank the pool (minus on-machine, minus guardrail-blocked) by the existing value model + affinity; pick the best that beats KEEP by theta.

## 2. Data (Dara designs, CS approves, Cody verdicts)

1. `physical_type_lane_family(physical_type PK, lane_family)` — from PRD-041; CS confirms grouping (bottle+can? bag+boxed? cup isolated?). Coverage 14/14.
2. `slot_pool_curation(lane_family, shelf_size, boonz_product_id, mode CHECK in ('include','exclude'), note)` — CS overrides. RLS read-only; written by a small curation RPC (Cody decides write path).
3. `slot_profile_pool(lane_family, shelf_size, boonz_product_id, fill_qty, computed_at)` — **precomputed table, rebuilt nightly.** A `rebuild_slot_profile_pool()` RPC (SECURITY DEFINER) recomputes the effective pool = derived (lane_family x size x product, fill_qty from `product_slot_capacity_units`) MINUS `slot_pool_curation` excludes PLUS includes, and writes it here with `computed_at = now()`. Scheduled via pg_cron to run nightly **before** the 8pm engine cron (job 13), so the engine reads a fresh, ready table instead of deriving pools live. RLS read-only; written only by the rebuild RPC.

## 3. Engine v14 -> v15 (forward CREATE OR REPLACE; Pass-3 rewrite)

Per band-3 eligible slot on a swaps-enabled, gate-clean machine:

1. Resolve profile `(lane_family, shelf_size)` from the incumbent + planogram. If unresolvable, KEEP (never strand).
2. Effective pool = `slot_profile_pool` (precomputed nightly) for that profile, MINUS products already in the machine's pod, MINUS guardrail-blocked (`_coexistence_blocks`, `_travel_scope_blocks`, 30-day intro cooldown, 3x-suppressed), AND in WH stock > seed min. (The nightly table holds the size/lane membership + fill_qty; the per-machine/per-run filters above are applied live since they depend on machine state.)
3. Score each pool product: `V = margin(landed-cost based) * min(projected_velocity * D, fill_qty)` where `fill_qty` is the **profile quantity** (NOT the candidate's own cap). projected_velocity = `0.5*sister + 0.3*global + 0.2*affinity*global`.
4. KEEP unless best `V >= keep_v * (1 + theta=0.15)`.
5. Assign greedily, value-desc: rate limits (<=2/machine, fleet <=10), no duplicate product/machine, homogenisation <=K=3 machines/product. qty_in = profile `fill_qty` (clamped to WH stock); qty_out = current shelf stock.

Passes 1 (strategic tags), dead-tag, 2b (driver recs) unchanged. Kill switch unchanged (swaps_enabled=false -> 0). engine_add_pod untouched.

## 4. Conditional tests (replay on ADDMIND-1007 + fleet, BEGIN..ROLLBACK, swaps forced true)

| #   | Test                 | Expected                                                                                                                                             |
| --- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| SP1 | profile constraint   | A08 (cup) / A14 (bottle) / A15 (bag) pools contain ONLY cup / bottle / bag products; no bar_standard anywhere in them.                               |
| SP2 | quantity authority   | proposed qty_in = profile fill_qty for the slot's lane x size, never the candidate's own form-factor cap (no 25-bars-in-popcorn).                    |
| SP3 | pod exclusion        | no pool product that is already in the machine's pod.                                                                                                |
| SP4 | curation respected   | an `exclude` row removes that product from the profile; an `include` row admits it.                                                                  |
| SP5 | ranking + guardrails | winner is highest-V in-pool, beats keep x1.15; coexistence/TCCC/travel/dedup/homogenisation/rate-limits all hold.                                    |
| SP6 | nightly freshness    | `slot_profile_pool.computed_at` is current (rebuild RPC ran), and the cron is scheduled before job 13; engine reads the table, does not derive live. |
| R1  | regression           | PRD-037 T1-T4/T7/T10-T13 hold (coexistence, kill switch, ADD byte-identical); value/assignment behaviour re-verified under the pool model.           |

## 5. Phasing / gates

- **P0** Dara builds `physical_type_lane_family` (CS approves grouping) + `slot_pool_curation` + `slot_profile_pool` table + `rebuild_slot_profile_pool()` RPC + nightly pg_cron scheduled before job 13; run the first rebuild; CS spot-checks a few profiles' pools + quantities; Cody verdict; apply on "apply P0".
- **P1** engine v15_slot_profile rewrite; Cody verdict; replay SP1-SP5 + R1; STOP for CS; apply on "apply P1".
- swaps_enabled stays false throughout. PRD-040 Track D pilot resumes only after P1 lands.

## 6. Open follow-ups / cross-ref

- Per-shelf true vendable form factor (vs incumbent proxy) — revisit if lanes get reconfigured.
- DOUBLE-DOWN / redeploy (PRD-037 Phase 2 / T9) still parked.
- 70/30 core-flex = PRD-038. swaps_enabled OFF until supervised Phase-3 (PRD-040 Track D) after this lands.
