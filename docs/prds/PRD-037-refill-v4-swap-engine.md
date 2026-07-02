# PRD-037 — Refill v4: Swap Engine (Logic 2), done properly

**Status:** Shipped (engine_swap_pod v12/v14 line now superseded by v15_slot_profile - verified live in prod 2026-07-02; planned_swaps live; swaps_enabled=false keeps output advisory-only). PRD-071 sweep.
**Owner:** CS (cyrilsem@gmail.com)
**Created:** 2026-06-19
**Depends on:** PRD-035 (engine_add_pod v18, stitch v24, picker v10 — all live). PRD-028 (v_wh_pickable).
**Related guardrail spec (source of truth, already in repo):** `engines/refill/guardrails/coexistence.md`, `portfolio_strategy.md`, `layout.md`, `travel-scope.md`.

## 0. Principle

ADD is simple and it works. Keep it. **`engine_add_pod` v18 is FROZEN by this PRD** — no behaviour change, guarded by a regression test (T12). All the value and all the risk live in the SWAP. Today `engine_swap_pod` v11 does a thin Pearson pass and is gated OFF. This PRD replaces it with a proper score-driven, guardrail-enforced, redeployment-aware swap engine that implements the spec already written in the four guardrail files.

The whole engine in one expression, per slot S on machine M holding incumbent I, with `cap(S) = max_capacity[physical_type][shelf_size] x 0.85`:

```
value of any product P in slot S:
  V(P,S,M) = margin(P) x min( velocity(P,M) x D , cap(S) )       # D = days_cover

choose the action that maximises:
  KEEP I         : V(I,S,M)
  SWAP in P*     : V(P*,S,M)                + Redeploy(I)
  DOUBLE DOWN W  : margin(W) x min(unmet(W,M), cap(S)) + Redeploy(I)

  Redeploy(I) = margin(I) x min( velocity(I,M*) x D , cap_at_M* )  # I's value at its best other home M*
  unmet(W,M)  = max( 0, velocity(W,M) x D - cap(current slot of W) ) # a starving winner's overflow

subject to:
  - candidate pool pre-filtered HARD by eligibility (WS-1)
  - winning alternative must beat KEEP by margin theta (hysteresis)
  - rate limits: <=2 swaps/machine/cycle, 14-day slot stability, fleet <=10/day
```

`min(velocity x D, cap)` is the slot-size rule: a slow product cannot use a big slot, a fast one is bounded by it. DOUBLE DOWN competes head to head with a new product (the "expand a winner vs add an irrelevant new SKU" case). Redeploy adds the value recovered by freeing a star that is dead here but sells elsewhere (Activia: 2/30d at ADDMIND, 18 at AMZ-3001).

## 1. What stays / what changes

| Component                               | Action                                                                                               |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `engine_add_pod` v18                    | **FROZEN.** Regression-tested, byte-identical output (T12).                                          |
| `engine_swap_pod` v11                   | **REWRITTEN** to v12 per this PRD.                                                                   |
| `engine_finalize_pod`, `stitch`, picker | unchanged                                                                                            |
| `refill_settings.swaps_enabled`         | **stays `false`.** Engine emits proposals; auto-apply stays OFF until proven over supervised cycles. |

## 2. Data prerequisites (Dara)

Most of it already exists — confirmed 2026-06-19:

| Need                                                                 | Status                    | Note                                                                                                                                                                                 |
| -------------------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| margin(P)                                                            | EXISTS                    | `price - boonz_products.avg_30days_cost`. Fall back to revenue/units if cost null. Phase-2 upgrade to true gross profit.                                                             |
| cap(S)                                                               | EXISTS                    | `slot_capacity_max(physical_type, shelf_size)` x 0.85 fill_factor (layout.md §4).                                                                                                    |
| physical_type, lifecycle_archetype, product_family_id, product_brand | EXIST on `boonz_products` |                                                                                                                                                                                      |
| in-stock                                                             | EXISTS                    | `v_wh_pickable`                                                                                                                                                                      |
| sister-venue velocity                                                | EXISTS                    | `v_sales_history_resolved` joined `machines.location_type`                                                                                                                           |
| **coexistence_rules**                                                | **MISSING — build it**    | Materialize coexistence.md Rule 1 + Groups 1-7 as a table: `(product_a_family_or_id, product_b_family_or_id, scope, rule_type hard/soft)`.                                           |
| **TCCC portfolio tag**                                               | **MISSING — build it**    | Tag every Coca-Cola Company brand (full portfolio list in coexistence.md Rule 1). Add `boonz_products.brand_owner` or a `tccc_portfolio` boolean. Used by the ADDMIND/VOX exclusion. |
| travel-scope lock                                                    | data exists               | the 8 VOX-locked SKUs (travel-scope.md). Encode as a lock table or reuse existing.                                                                                                   |

## 3. Workstreams

**WS-1 — Eligibility filter (hard gates, applied BEFORE scoring).** A candidate survives only if ALL hold:

1. In `v_wh_pickable` with stock >= a seed minimum.
2. Not already on machine M (no duplicate slot).
3. Coexistence-clean vs every product currently on M: no TCCC at `venue_group IN ('ADDMIND','VOX')`; max 1 per `product_family` (soft -> escalate, not silent); the Group 1-7 pairs (Soft Drinks Mix vs any CSD, 1 Coca-Cola variant, 1 Pepsi variant, 1 Almarai flavour, 1 sparkling-water brand, Krambals/Zigi family, Loacker family).
4. Not travel-scope-locked away from M.
5. Slot S not changed in the last 14 days (cooldown).
6. Not a HARD phase-out-bias product (portfolio_strategy.md §6).

**WS-2 — Projected score for candidates.** A candidate has no local sales, so its score is proxied and put on the same scale as the incumbent's `final_score`:
`projected_score = w1 * global_velocity + w2 * sister_velocity(same location_type) + w3 * pearson_affinity(M's basket)`.
Sister-venue dominates (an office machine predicts another office machine). Weights tuned in replay; start `w2 > w1 > w3`.

**WS-3 — Decision math.** Implement the §0 argmax. Compute V() for KEEP, the best eligible SWAP candidate, and the best on-machine DOUBLE-DOWN winner. Add Redeploy(I) to the two action options. Pick max; require it beat KEEP by `theta`. Then apply rate limits (portfolio_strategy.md §9) at the Decider stage.

**WS-4 — Destination-aware remove (redeploy).** When the chosen action displaces I and I has a better home M* (relocation value > 0), the REMOVE is tagged with `redeploy_target = M*` so the freed units are earmarked, not generic-returned. (Engine 2 / relocation behaviour.)

**WS-5 — Test harness.** All tests in §4 run inside `BEGIN; ... ROLLBACK;` with `swaps_enabled` forced true to observe Pass-3, each printed PASS/FAIL with the actual value. Apply to prod only when all pass AND CS green-lights.

## 4. Conditional tests (acceptance criteria — all must pass in replay)

| #    | Test                                   | Setup                                                                                         | Expected                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ---- | -------------------------------------- | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| T1   | TCCC block at ADDMIND                  | candidate pool for any ADDMIND swap                                                           | no product where `tccc_portfolio = true` (Coke, Sprite, Fanta, Schweppes, Powerade, Monster, Minute Maid, Fuze Tea...)                                                                                                                                                                                                                                                                                                              |
| T2   | TCCC block at VOX                      | candidate pool for a VOX machine                                                              | same as T1                                                                                                                                                                                                                                                                                                                                                                                                                          |
| T3   | Sparkling water 1-brand                | machine has Perrier                                                                           | Evian Sparkling NOT a candidate (and vice versa)                                                                                                                                                                                                                                                                                                                                                                                    |
| T4   | Family dup                             | candidate shares `product_family_id` with an on-machine product                               | excluded; surfaced as escalation, not silent drop                                                                                                                                                                                                                                                                                                                                                                                   |
| T5   | Score gate theta                       | best candidate's projected_score does not beat incumbent by theta                             | action = KEEP, 0 swaps                                                                                                                                                                                                                                                                                                                                                                                                              |
| T6   | No-substitute guard                    | dead/expiring shelf, eligible pool empty after WS-1                                           | action = keep + flag, 0 swaps (never strand the shelf)                                                                                                                                                                                                                                                                                                                                                                              |
| T7   | Kill switch                            | `swaps_enabled = false`                                                                       | engine emits 0 Pass-3 swaps                                                                                                                                                                                                                                                                                                                                                                                                         |
| T8   | Double-down beats new                  | on-machine winner W with `velocity x D > cap(W slot)` and overflow value > best new candidate | action = DOUBLE DOWN W, not swap-in                                                                                                                                                                                                                                                                                                                                                                                                 |
| T9   | Redeploy routing                       | incumbent dead at M, strong at M\* (Activia ADDMIND->AMZ)                                     | REMOVE carries `redeploy_target = M*`                                                                                                                                                                                                                                                                                                                                                                                               |
| T10  | Cooldown                               | slot S changed < 14 days ago                                                                  | no swap proposed at S                                                                                                                                                                                                                                                                                                                                                                                                               |
| T11  | Rate limits                            | a machine that wants 4 swaps                                                                  | <= 2 emitted for that machine; fleet-wide <= 10/day                                                                                                                                                                                                                                                                                                                                                                                 |
| T12  | ADD regression                         | run `engine_add_pod` v18 before/after                                                         | output byte-identical (ADD untouched)                                                                                                                                                                                                                                                                                                                                                                                               |
| T13  | ADDMIND worked example (Phase 1 scope) | run swap Pass-3 on ADDMIND-1007 A08/A14/A15                                                   | each dead/rotate slot yields a SWAP whose chosen swap-in is: (a) coexistence-clean and NOT a TCCC product (A14 Perrier replacement especially), (b) in WH stock and not already on the machine, (c) distinct per slot (no product proposed into two slots in one cycle), (d) value-justified V(P\*) >= V(I) x (1 + theta). Exact product identity (YoPRO/Zigi) and the Activia redeploy tag are Phase 2 (see T13b/T9), not Phase 1. |
| T13b | ADDMIND worked example (Phase 2 scope) | run full swap + redeploy on ADDMIND-1007 A08/A14/A15                                          | A08 Activia displaced and redeploy-tagged to its best other home (AMZ); A14/A15 swap-ins per the value model. Literal product targets are illustrative, not asserted; the binding checks are the redeploy routing (T9) and Phase-1 guardrails (T13).                                                                                                                                                                                |

## 5. Phasing

- **Phase 1 (correctness core):** Dara builds `coexistence_rules` + TCCC tag. Then WS-1 eligibility + WS-2 projected score + WS-3 decision using available data/proxies. Tests T1-T7, T10-T13. `swaps_enabled` OFF.
- **Phase 2 (redeploy + double-down):** WS-4 destination-aware remove + DOUBLE-DOWN multi-facing (layout.md §6). Tests T8, T9, T13b.

> Re-scope note (2026-06-20): T13 was split. The original T13 asserted literal swap-in products (YoPRO/Zigi) and an Activia redeploy tag, but redeploy is WS-4 (Phase 2) so Phase 1 cannot emit it, and the value model selects by real margin x velocity (it picks Be-kind Bar / McVities on ADDMIND-1007, not the illustrative SKUs). Phase-1 T13 now asserts the guardrail invariants the engine must satisfy; the literal products and redeploy moved to Phase-2 T13b alongside T9. A latent Pass-3 bug found during the replay (same product proposed into two slots in one cycle) was fixed in the v12 migration with an intra-cycle swap-in dedup guard.

- **Phase 3 (enable, later):** flip `swaps_enabled` to true only after N supervised cycles of clean proposals reviewed on `/refill`.

## 6. Guardrail-to-code map (this PRD wires the spec, it does not invent it)

| Logic                                                                          | Lives in                                  | Wired by                     |
| ------------------------------------------------------------------------------ | ----------------------------------------- | ---------------------------- |
| TCCC exclusion, coexistence matrix, family dup                                 | coexistence.md Rule 1 + Groups 1-7        | WS-1, `coexistence_rules`    |
| VOX 8-SKU lock                                                                 | travel-scope.md                           | WS-1                         |
| Archetypes, phase-out bias, rate limits, redeploy intent                       | portfolio_strategy.md §3/§6/§9 + Engine 2 | WS-1, WS-3, WS-4             |
| Capacity by physical_type x size, 70/30, migration, multi-facing (double-down) | layout.md §4/§5/§6                        | WS-3 (cap), WS-3 DOUBLE-DOWN |

## 7. Open follow-ups

1. Phase-2 margin upgrade from cost-proxy to true gross profit once cost coverage is complete.
2. 70/30 core/flex enforcement (layout.md §5) — out of scope here, candidate for PRD-038.
3. `swaps_enabled` stays OFF until Phase 3 sign-off.
