# PRD-040 — Refill v3/v4 Closeout: unapplied debt, hygiene, FE wiring, activation

**Status:** Draft. Catalogs and closes everything started-but-not-done in the PRD-034..039 refill thread.
**Owner:** CS (cyrilsem@gmail.com)
**Created:** 2026-06-20
**Depends on:** PRD-034/035/036/037/039 (all live in prod, on main @120f987). `refill_settings.swaps_enabled` is `false`.
**Grounding (live 2026-06-20):** `get_vox_returns` absent; `product_family_id` 0/307; 90/307 products have NULL/0 `avg_30days_cost`; `get_candidate_affinity` + `product_slot_capacity` live; swaps off.

## 0. Purpose

Close the open ends so nothing stays dormant. Four tracks, each independently gated. ADD/engine behaviour does not change except where a track says so; `swaps_enabled` stays false until Track D.

## Track A — Apply the two built-but-unapplied migrations

Both authored, currently excluded from prod (would be dormant). Cody-review each, replay, apply.

- A1 `20260618130000_prd036_b_log_manual_refill_new_purchase.sql` (PRD-036 Phase B). Confirm it does not conflict with the live `log_manual_refill` (single overload today).
- A2 `20260616130000_prd019c_compact_product_fallback_is_configured.sql` (orphan; `v_refill_planning_compact` is_configured fallback). Confirm `v_refill_planning_compact` consumers unaffected.
  Acceptance: each applied, prod-confirmed, registered (CHANGELOG/MIGRATIONS/RPC). If either is stale/wrong, supersede with a fresh forward migration rather than apply as-is.

## Track B — Backend hygiene / Article-16 debt

- B1 **Affinity metric (Article 16):** register "candidate basket affinity" in METRICS_REGISTRY with `get_candidate_affinity` as canonical; converge `find_substitutes_for_shelf` onto it at its next legitimate change (behaviour-diffed, one pass; do NOT half-migrate).
- B2 **`product_family_id` backfill (0/307):** populate families, then flip Rule 2 (max-1-per-family) from the brand proxy in `coexistence_rules` to true `family_id` matching. Dara designs the family taxonomy + backfill; Cody verdicts.
- B3 **True gross-profit margin:** replace the `price - avg_30days_cost` proxy (90/307 missing cost) with a real GP source; have `engine_swap_pod` V() and `engine_add_pod` (if applicable) consume it. Define the cost source first; this is value-model-affecting, so replay U/C/A/H + R1 from PRD-039.
- B4 **Stitch WH-read unification:** `stitch_pod_to_boonz` reads WH inline in 4 places (`pull_overlaid.wh_avail_variant`, `pull_with_wh`, alert `supply` CTE, `diag`) without the in-date filter. Unify ALL onto `v_wh_pickable` in ONE behaviour-diffed migration (half-migrating re-introduces line/alert disagreement).

## Track C — FE wiring (Stax)

- C1 PRD-034 Phase C: build `get_vox_returns` read surface + FE view of the VOX-return ledger.
- C2 PRD-033 operator-flexibility FE: wire `reopen_stitched_rows`, `release_wh_quarantine`, `check_remove_without_replace`, `convert_shelf` (RPCs live, FE not wired).
- C3 Land the `feat/prd-033-operator-flexibility` branch work properly on main (PRD-033, prd023i/j, Performance-tab FE) — currently committed on the branch, unpushed/unmerged. Reconcile registry entries (PRD-033 + 023i/j were deliberately not carried in the prod-sync).

## Track D — Activate swaps (Phase 3, gated runbook)

- D1 Supervised enable: flip `swaps_enabled` true, per-machine first (`swaps_enabled:<machine_id>`), review proposals on `/refill` for N clean cycles before fleet-wide.
- D2 Revisit PRD-039 tunables in supervised cycles: `v_cand_min_stock=3`, `v_top_n=10`, `v_K=3` (homogenisation).
- D3 Rollback: set the flag back to false (instant no-op); no schema change.
  Acceptance: written runbook + per-machine staged enable + daily review log. This is operational, not a code change.

## Out of scope (parked, cross-referenced)

- 70/30 core-flex enforcement = **PRD-038** (separate).
- Any non-refill open bugs (tracked in their own files).

## Phasing / gates

A and B are backend (Dara designs schema, Cody verdicts each migration, BEGIN..ROLLBACK replay, STOP before apply). C is Stax (FE + review). D is an ops runbook with explicit CS green-light. Each track applies independently; nothing in A/B/C flips `swaps_enabled` (only D does).
