# PRD-042 Execution Log — Swap engine v5: slot-profile assortment pools

**Date:** 2026-06-20 (AUTO MODE) · **Supabase:** eizcexopcuoycuosittm · **Outcome:** P0 + P1 APPLIED to prod, all tests green.
**Invariants held:** `swaps_enabled=false` (never flipped); `engine_add_pod` byte-identical (md5 `244de950d278df3490ea20955d4448a9` before and after); no git push.

## Applied objects

| Object                                                                     | Migration                                    | Applied       |
| -------------------------------------------------------------------------- | -------------------------------------------- | ------------- |
| `physical_type_lane_family` (14 rows, 7 families)                          | `prd042_p0_slot_profile_pools`               | ✅ 2026-06-20 |
| `slot_pool_curation` (RLS read-only, empty)                                | `prd042_p0_slot_profile_pools`               | ✅ 2026-06-20 |
| `slot_profile_pool` (precomputed cache, 921 rows)                          | `prd042_p0_slot_profile_pools`               | ✅ 2026-06-20 |
| `rebuild_slot_profile_pool()` RPC + first rebuild                          | `prd042_p0_slot_profile_pools`               | ✅ 2026-06-20 |
| cron `rebuild_slot_profile_pool_nightly` 15:30 UTC (before job 13 @ 16:00) | `prd042_p0_slot_profile_pools`               | ✅ 2026-06-20 |
| `engine_swap_pod` v14 → **v15_slot_profile**                               | `prd042_p1_engine_swap_pod_v15_slot_profile` | ✅ 2026-06-20 |

## Test results (replay BEGIN..ROLLBACK, swaps forced true, ADDMIND-1007 + fleet on gate-clean 2026-06-21)

| #   | Test                 | Expected                                         | Actual                                                                                                                | Result  |
| --- | -------------------- | ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- | ------- |
| SP1 | profile constraint   | no bar in cup/bottle/bag pools                   | A08(cup) n_cand=0; A14(bottle) cands bottle_330/500/large; A15(bag) bag_snack; n_bar=0; fleet cross-family leak **0** | ✅ PASS |
| SP2 | quantity authority   | qty_in = profile fill_qty                        | cand_cap == pool fill_qty for every pair (fleet mismatch **0**)                                                       | ✅ PASS |
| SP3 | pod exclusion        | no on-machine product                            | on_pod_leak=0 all slots                                                                                               | ✅ PASS |
| SP4 | curation respected   | exclude removes, include admits                  | excluded_still_in_pool=0; included_now_in_pool=1                                                                      | ✅ PASS |
| SP5 | ranking + guardrails | highest-V beats keep×1.15; rate/dedup/homog hold | score_swaps=8 ≤ fleet_cap 10; homog K=3; 0 cross-family                                                               | ✅ PASS |
| SP6 | nightly freshness    | pool fresh + cron before job 13                  | computed_at age 17s; cron 15:30 UTC < job13 16:00 UTC                                                                 | ✅ PASS |
| R1  | regression           | T7 kill switch; engine_add_pod byte-identical    | swaps_enabled=false → 0 score swaps; engine_add_pod md5 unchanged                                                     | ✅ PASS |

## Model / engine change

Pass-3 is now a machine-level pick from the precomputed `slot_profile_pool` for the slot's (lane_family, shelf_size), intersected with the live per-machine guardrail universe `_p3_cand` (WH stock + coexistence + travel + intro-cooldown + on-machine exclusion), with `cand_cap = pool fill_qty` (the profile quantity, not the candidate's own form-factor cap). Value model unchanged and already matched the PRD: `V = margin × min(proj_vel×D, fill_qty)`, `proj_vel = 0.5·sister + 0.3·global + 0.2·affinity·global`, KEEP unless best ≥ keep_v×1.15, greedy ≤2/machine, fleet ≤10, no dup, homogenisation ≤3. Passes 1/dead-tag/2b logic byte-identical (only their engine_version write-tag bumped). If incumbent physical_type is NULL/unmapped the pool join matches nothing → KEEP (never strand).

## Assumptions used (confirm/tweak later)

- **Starter lane grouping** (CS-decided): bottle / can / snack_small / bag / boxed / cup / other, kept distinct (no bottle+can, no bag+boxed merge; cup isolated). Coverage 14/14, 0 unmapped.
- `slot_pool_curation` is empty / derived-only; its dedicated write (curation) RPC is **deferred** — table is RLS read-only and only the rebuild RPC + migration write it. Add a curation RPC when CS wants overrides.
- `rebuild_slot_profile_pool()` does a full DELETE+INSERT refresh of its own derived cache each night (not a protected entity; atomic in one txn).

## Note

`swaps_enabled` stays `false`: v15_slot_profile is a no-op in production until the PRD-040 Track D supervised pilot. **Track D unblocks now that v15_slot_profile has landed.**
