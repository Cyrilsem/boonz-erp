# PRD-040 Execution Log — Refill Closeout

**Project:** eizcexopcuoycuosittm. Applied 2026-06-20 (Claude Code + Cowork). `swaps_enabled` stays `false` throughout; `engine_add_pod` v18 byte-identical (T12 holds; B3 did not touch its margin source).

## Track A — apply built-but-unapplied migrations: APPLIED

| Item | schema_migrations name | Cody | Prod confirm |
| --- | --- | --- | --- |
| A1 | `prd036_b_log_manual_refill_new_purchase` | Approve | `log_manual_refill` 1 overload; new-purchase path creates its own `warehouse_inventory` receipt batch (audited, `manual_adjust` provenance), no status mutation. CS-confirmed path. |
| A2 | `prd019c_compact_product_fallback_is_configured` | Approve | `v_refill_planning_compact.is_configured` live; 624 rows; 0 regression. |

## Track B — backend hygiene: APPLIED (B1 doc + convergence plan only)

| Item | schema_migrations / artifact | Cody | Replay | Prod confirm |
| --- | --- | --- | --- | --- |
| B1 affinity metric | METRICS_REGISTRY row (doc) | n/a | n/a | `get_candidate_affinity` registered canonical "candidate basket affinity". find_substitutes convergence = PLAN only (future single behaviour-diffed pass). |
| B2 family taxonomy + Rule-2 flip | `prd040_b2_family_taxonomy_rule2_narrow` | Approve | PASS (0 unintended; 21 intended Loacker) | 136 families, `product_family_id` 305/307, 13 family-keyed coexistence rules, `_coexistence_blocks` now family-keyed + is_active. CS decision: brand-fallback family for the rest; brand proxy retired. |
| B3-p1 landed cost | `prd040_b3_product_landed_cost` (`v_product_landed_cost`) | Approve | PASS (307/307) | 307/307 covered: 249 sourced, 58 imputed category-median (CS decision D-B3b). |
| B3-p2 engine margin | `prd040_b3p2_engine_landed_cost_margin` | Approve | PASS (10/10, 7-swap delta, all guardrails) | `engine_swap_pod` v14_landed_cost_margin consumes `v_product_landed_cost`; no `avg_30days_cost`. |
| B4 stitch WH unify | `prd040_b4_stitch_wh_pickable_unify` | Approve | PASS (165/165, diag/alerts identical) | `stitch_pod_to_boonz` v25; 3 pickable reads onto `v_wh_pickable`, 0 inline `warehouse_inventory`. |

## Track C — FE specs: DONE (spec only)

`PRD-040-TRACK-C-FE-SPECS.md`: C1 `get_vox_returns` (PRD-034 Phase C), C2 operator-flex FE wiring (PRD-033 RPCs), C3 land `feat/prd-033` on main + registry reconciliation. No code built (Stax to build).

## Track D — Phase-3 enable runbook: DONE (runbook only, flag NOT flipped)

`PRD-040-PHASE3-ENABLE-RUNBOOK.md`: per-machine `swaps_enabled:<machine_id>` staged enable, N supervised `/refill` cycles, daily review log, instant rollback (flag=false). Tunables to revisit: `v_cand_min_stock=3`, `v_top_n=10`, `v_K=3`.

## Hard-rule compliance (end state)

- `refill_settings.swaps_enabled` = false (only Track D runbook authorizes a flip; not flipped).
- `engine_add_pod` = v18 byte-identical (T12 holds).
- Cody verdicted every migration (A1, A2, B2, B3-p1, B3-p2, B4).
- Forward-only; supersede-not-delete; no `_v2`.
- Final live versions: `engine_swap_pod` v14_landed_cost_margin, `stitch_pod_to_boonz` v25, `engine_add_pod` v18 (frozen), `_coexistence_blocks` family-keyed + is_active, `v_refill_planning_compact.is_configured`, `log_manual_refill` new_purchase, `v_product_landed_cost`.

## Remaining to fully close

- **Git: NOT committed.** All PRD-040 migrations + docs + registry updates are uncommitted on `main` working tree. Run the PRD-040 prod-sync (commit 6 applied migrations + 036b/019c + docs + registries onto main). This is the only step left to make repo == prod.
- B1 find_substitutes convergence (plan-only, future).
- Track C FE build (Stax). Track D supervised enable (CS-run when ready).
- Watch the 58 imputed-cost products in the supervised swap review.

## Parked

PRD-038 (70/30 core-flex). Phase-3 fleet enable pending supervised cycles.
