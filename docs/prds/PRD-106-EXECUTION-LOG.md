# PRD-106 — Execution Log (Machine-Level Swap Recommendation)

**Codename:** swap-machine-level · **Date:** 2026-07-29 · **Mode:** AUTO (self-run Dara→Cody) · **Project:** eizcexopcuoycuosittm
**Outcome:** Recommender RPC SHIPPED (additive, read-only, Cody ✅, validated). Engine rewire DESIGNED + Cody-scoped + **PARKED for the engine-freeze window** (governance blocker). Git: no push.

---

## Phase 0 — Reconciliation of PRD model vs live engine (verified on prod)

The PRD (DRAFT, 2026-07-28) describes a root-cause model that is **materially stale**. Verified:

1. **"Engine calls per-shelf `find_substitutes_for_shelf`."** FALSE. `engine_swap_pod` Pass-2a was rewritten to `rank_slot_suitability(...)` (migration `20260713180426_wave2_engine_swap_pod_rewire`). `find_substitutes_for_shelf` is only the manual/FE path — the source of CS's 07-28 Coke-Mix diagnostic.
2. **"RC-06: dead-tag match hardcodes v15/v16, severed since 06-22."** ALREADY FIXED. Migration `20260718034118_rc06_engine_swap_pod_version_agnostic_tags` made the consumer match `tagged_by LIKE 'engine_add_pod%'`, which catches the live tag `engine_add_pod_v19_base_stock`. Substitution is NOT severed. The only residual brittleness is `engine_add_pod`'s dead-tag refresh DELETE (a hardcoded IN-list `v15…v19_base_stock`, currently correct) — a minor hardening, parked with the engine bundle.

### What IS broken (reproduced live, MC-2004-0100-O1, plan 2026-07-29)

Engine `v13` output on the 5 dead shelves:

| Shelf | out           | engine in      | defect                                                  |
| ----- | ------------- | -------------- | ------------------------------------------------------- |
| A06   | Santiveri     | Coca Cola Zero | **in-machine DUP** (live A2+A4) via `is_size_up` bypass |
| A15   | Dubai Popcorn | Barebells      | **in-machine DUP** (live B9) via `is_size_up` bypass    |
| A11   | Loacker       | NULL → **M2W** | banned auto-outcome                                     |
| B02   | Tamreem       | NULL → **M2W** | banned auto-outcome                                     |
| B03   | Ice Tea       | NULL → **M2W** | banned auto-outcome                                     |

Real defect 1: the `rss.is_size_up` branch bypasses the not-already-present guard → in-machine dups (= `bug_swap_brain_within_machine_duplicate`, Hunter A04/A10, still live). Real defect 2: 3/5 dead shelves dumped to M2W.

---

## Phase 1 — SHIPPED: `recommend_swaps_for_machine` (additive, read-only)

Migration `prd106_recommend_swaps_for_machine` (`20260729100001_*`), applied to prod. `LANGUAGE plpgsql STABLE`, INVOKER rights (mirrors `rank_slot_suitability`), **zero writes**, GRANT EXECUTE anon/authenticated/service_role. Cody ✅ (Articles 1, 2, 3, 12, 14, 16).

`recommend_swaps_for_machine(p_plan_date, p_machine_id, p_k int DEFAULT NULL)` → K DISTINCT, WH-backed, in-machine-deduped swap-ins for the machine's K dead shelves. Candidate universe reuses proven predicates; **WH availability aggregated by `boonz_product_id` FIRST via `v_wh_pickable`, then mapped to pod grain** (kills the ~10-40x `product_mapping` fan-out). Exclusions: in-machine (unless `slot_lifecycle.signal='DOUBLE DOWN'`), decommission `strategic_intents`, Evian 1L (id), `venue_team` on non-VOX, catch-alls, `_coexistence_blocks`, `_travel_scope_blocks`, size-fit via `product_size_fit` at the shelf size with `wh >= min_refill_qty`. Score = `GREATEST(get_candidate_affinity,0.30) * ln(1+fleet_units_30d) * avail_factor` (avail_factor 1.0, or 1.25 near-FEFO within `expiry_risk_days`). Greedy: shelves by capacity desc, top DISTINCT candidate each, `qty=LEAST(cap,wh)`. No candidate → `in_pod NULL, qty 0, rationale.reason='no_viable_swap_candidate'` — **M2W is never emitted** (CS rule 2026-07-28).

### Acceptance results (recommender)

| #   | Test                                    | Result                                                                                                                                                                                                                                                                                                      |
| --- | --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | MC-2004 replay (dead A11/B02/B03)       | ✅ **3 DISTINCT** swap-ins: A11→Sunbites (12/wh12), B03→Freakin Protein Balls 3P (14/wh17), B02→G&H Popped Chips (12/wh19). None in-machine, **no Coca Cola**, all `wh_available ≥ qty_suggested`.                                                                                                          |
| 2   | Zero blocked_no_wh (dry run)            | ✅ Structural: `qty=LEAST(cap,wh)` ⇒ `wh ≥ qty` always. Fleet harness: 0 `viol_wh_short` (only MC-2004 has unresolved dead shelves this plan).                                                                                                                                                              |
| 3   | Hunter — no within-machine dup          | ✅ Fleet invariant `viol_within_dup=0`; distinct-K enforced by the greedy used-pods array.                                                                                                                                                                                                                  |
| 4   | RC-06 gone (v18/v19 dead tags resolved) | ✅ Already shipped 2026-07-18; verified the live engine picks up `engine_add_pod_v19_base_stock` tags.                                                                                                                                                                                                      |
| 5   | Scripted asserts                        | ✅ **fan-out dedup**: Red Bull naive join = 714u vs deduped `v_wh_pickable` = 17u (RPC uses 17). **DOUBLE DOWN**: exception live-relevant (14 facings / 10 machines), captured by the `dd` CTE. **decommission**: `viol_decommission=0`. **Evian 1L**: `viol_evian=0`. **distinct-K**: `viol_within_dup=0`. |
| 6   | Re-run `engine_swap_pod` on MC-2004     | ⏸ **PARKED** — requires the engine rewire (Phase 2) + live-plan mutation, both gated by the engine-freeze.                                                                                                                                                                                                  |

---

## Phase 2 — Engine rewire: DESIGNED, Cody-scoped, **PARKED for engine-freeze**

The PRD's item 6 (rewire `engine_swap_pod` to consume the recommender) + item 8 (ban M2W) require a **3-engine interlocked edit**, discovered during design:

1. **`engine_swap_pod` Pass-2a** — replace the `rank_slot_suitability` selection + loose `is_size_up` dup bypass with a per-machine `recommend_swaps_for_machine` lookup (memoized temp). On no-candidate: tag `resolved_as='no_viable_swap_candidate'` + raise a `monitoring_alerts` procurement warning; **do not set `m2w`**. Keep the per-machine cap.
2. **`engine_finalize_pod(date,uuid[])`** — its `swap_m2w_lines` CTE emits an `'M2W'` line for **every** `pod_swaps` row with `pod_product_id_in IS NULL`, unconditionally (line ~104). Banning auto-M2W therefore REQUIRES excluding `reasoning->>'resolved_as'='no_viable_swap_candidate'` here, while preserving intentional strategic `swap_out_m2w`. Without this, the shelf still stitches to M2W regardless of the swap-engine tag.
3. **`engine_add_pod`** — harden the dead-tag refresh DELETE from a hardcoded `tagged_by IN ('…v15'…'…v19_base_stock')` to `LIKE 'engine_add_pod%'` (goal item 7 residual).
4. **`recommend_swaps_for_machine` v2** — add R5 introduction-cooldown (`refill_plan_output` Remove ≤30d) + swap-rejection suppression (`refill_edit_signals` `swap_rejected` ≥3/30d) as universe exclusions, so the engine keeps those guards when it delegates candidate selection.

### Why PARKED (governance blocker, not a capability gap)

`MASTER-PARKING-LOT.md` + `WAVE1-2-DESIGN-DECISIONS.md` declare an **active engine change-freeze**: _"Concurrent sessions edit Family-A engines… Wave-2 engine work needs a scheduled freeze window with NO other engine migrations."_ The freeze watches the md5 of exactly these engines (`engine_add_pod`/`engine_swap_pod`/`engine_finalize_pod`/`pick_machines_for_refill`). **PRD-094** (swap-cap fix) and **PRD-095** (expiry-swap) are already HELD there, and 094 edits the _same_ `engine_swap_pod` passes this rewire touches — a direct collision. Applying now would break the referee byte-identity gate and force a Family-A edit the program has explicitly forbidden outside a scheduled window. Per the parking-lot rule ("Never force"), the engine rewire is parked, not applied.

**Needed to unblock:** a scheduled engine-freeze window (coordinate with the 094/095 unpark), then apply the 4-part bundle above as one migration set with a fresh Cody pass (class (b) DEFINER writers) and rollback md5 capture, and validate by re-running `engine_swap_pod` on MC-2004 (mutates the live 2026-07-29 plan) → expect A06/A15 dups gone, A11/B02/B03 = Sunbites/G&H/Freakin, zero M2W (no_viable + alert instead).

---

## Deliverables

- [x] `recommend_swaps_for_machine` shipped to prod (additive, Cody ✅, validated).
- [x] RPC acceptance battery green (MC-2004 distinct-K, fan-out dedup, in-machine/decommission/Evian/dup invariants).
- [x] `RPC_REGISTRY.md`, `CHANGELOG.md`, `MIGRATIONS_REGISTRY.md` updated.
- [x] Engine rewire fully designed (exact 3-engine diffs above) + parked in `MASTER-PARKING-LOT.md`.
- [ ] Engine rewire apply — **held for the engine-freeze window** (with 094/095).
- [ ] PROD-SYNC to `main` — pending (no push, per goal).

---

## Addendum 2026-07-29 — goal item 6b (`find_substitutes_for_shelf p_exclude_in_machine`) JOINS THE PARK

Re-checked live during the combined PRD-107 + PRD-106 push. `find_substitutes_for_shelf` still has
its 6-arg signature (`p_exclude_in_machine` absent, verified). It looked like the one B6 item
shippable outside the engine freeze, since it is a `SECURITY INVOKER` read-only helper and has
**zero FE callers** (grep across `src/`).

It is not shippable, for a specific reason:

- `engine_swap_pod` **calls `find_substitutes_for_shelf`** (verified via `pg_get_functiondef` scan —
  it is the only caller in the database).
- Adding `p_exclude_in_machine boolean DEFAULT true` creates a **7-arg overload** beside the 6-arg
  function. A 6-arg call then matches **both**, and PostgreSQL raises
  `42725 function is not unique` — breaking the frozen engine at runtime.
- Avoiding the overload means `DROP`ping the 6-arg version, which edits the call contract of a
  Family-A engine under change-freeze — exactly what the freeze forbids.

This is the same trap `RPC_REGISTRY.md:372` records for `push_plan_to_dispatch`, where a second
overload made every PostgREST named-notation call fail `42725` and silently broke FE approve→push.

**Therefore:** item 6b is added to the parked engine bundle (now 5 parts, not 4) and must be applied
in the same freeze window, as `DROP FUNCTION find_substitutes_for_shelf(6-arg)` +
`CREATE ... (7-arg with default)` in one migration, after confirming `engine_swap_pod`'s rewritten
body passes the new argument explicitly.

### Part B status against the combined goal

| Goal item                                      | State                                                                          |
| ---------------------------------------------- | ------------------------------------------------------------------------------ |
| B1 `recommend_swaps_for_machine`               | ✅ live in prod, acceptance green                                              |
| B2 universe / exclusions                       | ✅ (in-machine, DOUBLE DOWN, decommission, Evian 1L, venue_team, slot-profile) |
| B3 WH dedup before pod mapping                 | ✅ Red Bull naive 714u vs deduped 17u; RPC uses 17                             |
| B4 rank_score + rationale                      | ✅                                                                             |
| B5 greedy distinct-K                           | ✅ `viol_within_dup=0`                                                         |
| B6 engine rewire                               | ⏸ **PARKED** — collides with PRD-094 on the same `engine_swap_pod` passes      |
| B6b `find_substitutes_for_shelf` exclude param | ⏸ **PARKED** — overload would break the frozen engine (above)                  |
| B7 M2W ban                                     | ⏸ **PARKED** — requires `engine_finalize_pod`, a Family-A engine               |
