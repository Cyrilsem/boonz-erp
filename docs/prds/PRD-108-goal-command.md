# /goal — PRD-108 Volume-Driven Size-Up

GOAL: Replace the relative-percentile size-up test in rank_slot_suitability with three ABSOLUTE volume tests, calibrated against 90d of real data BEFORE any code ships. Read PRD-108-volume-driven-sizeup.md first. Supabase eizcexopcuoycuosittm. Two-phase session: Phase 1 calibration (read-only, present to CS, STOP for threshold sign-off), Phase 2 implement (Dara design, Cody review MANDATORY before apply).

WHY (CS rule 2026-07-29): pctile>=0.80 is relative to the machine — a zombie machine's "top seller" at 2-3/wk can qualify for a second facing, while the coverage test is passable by artifact when the existing facing is small. Size-up must be volume-driven: star-machine small shelf at 40-50/wk → concentrate; zombie local hero → never (zombies get exploration with NEW products instead).

PHASE 1 — CALIBRATION (read-only, no writes):

1. Fleet-wide trailing-90d query at (machine, pod) grain: on-machine vel_day, full_shelf_units (sum of facings' max_stock), trip_interval_days (machine_service_policy, default 21), exp_vel of the rank-1 NON-present size-fit candidate per shelf (GREATEST(proven, lookalike, global)), sell-out-day count where derivable from stock history.
2. Score the three tests at proposed thresholds: T1 vel_day>=1.0; T2 vel_day*trip > full_shelf_units*1.25 (or measured lost-sales form where telemetry supports it); T3 projected incremental units >= 1.3 * best-newcomer exp_vel.
3. Output: pass-list (machine, product, which tests pass, all inputs) + sensitivity table at ±25% per threshold + explicit check that no machine <=30u/wk total appears, and that known star-machine capacity-constrained shelves (OMDCW Al Ain Zero class) DO appear.
4. Present to CS. STOP. Thresholds only proceed with explicit sign-off; store agreed values in refill_policy_params (new columns sizeup_min_vel_per_day, sizeup_overflow_factor, sizeup_vs_alternative_factor).

PHASE 2 — IMPLEMENT (after sign-off only): 5. One forward-only migration: CREATE OR REPLACE rank_slot_suitability — in `flagged`, replace `proven_machine_pctile >= 0.80` with T1 AND T2 AND T3 reading refill_policy_params; KEEP is_present, NOT is_blended, AND is_dd (PRD-106b), coverage retained inside T2's fallback form. Expose T1/T2/T3 inputs + thresholds in a rationale-friendly way (extend the returned columns or reasoning payload without breaking engine_swap_pod's consumption — check call sites first; NO new overload of any existing function name, 42725 trap per RPC_REGISTRY.md:372). 6. engine_swap_pod NOT touched (PRD-094/095 freeze stands). recommend_swaps_for_machine: apply the same three tests to its DOUBLE DOWN exception branch for parity. 7. Phase 2b (optional, separate approval): boonz-pico-upstream weekly session auto-proposes DD flags for T1-T3 passers, CS batch-approves — nightly autonomy unchanged.

GUARDRAILS: Phase 1 strictly read-only; STOP between phases is a hard gate; Cody review before the Phase 2 migration; no raw DML anywhere; protect PRD-106b behavior (DD still required — these tests tighten, never widen); thresholds in refill_policy_params, never hardcoded; forward-only migration; no em-dashes in client copy.

ACCEPTANCE:

- Zombie replay (machine <=30u/wk): zero size-up proposals at any threshold in the sensitivity band.
- Star replay: capacity-constrained 40u/wk shelf passes and outranks best newcomer in rationale.
- pgTAP: T1/T2/T3 boundaries, missing-lookalike fallback in T3, DD-still-required invariant, params-driven thresholds.
- MIGRATIONS_REGISTRY.md + CHANGELOG.md updated; EXECUTION-LOG at PRD-108-EXECUTION-LOG.md with Cody verdict AND the CS threshold sign-off recorded.
