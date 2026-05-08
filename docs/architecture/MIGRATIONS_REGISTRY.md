# Migrations Registry

The Supabase `migrations` table is the system of record. This file is a curated index that maps **architecture-reform migrations** to Constitution articles and Phase A steps, so we can answer "what's been done, what's left" at a glance without reading raw SQL.

Migrations not listed here are pre-reform (operational migrations from before 2026-04-25). They're not in scope for the constitution-compliance rollup but remain in the Supabase history.

## Phase A — Perimeter

| Step | Migration name | Article(s) | Status | Applied | Rollback ready |
|---|---|---|---|---|---|
| A.1 | `phaseA_a1_rls_planogram_pia` | 2, 7 | ✅ Applied | 2026-04-25 | Yes — see CHANGELOG |
| A.2 | `phaseA_a2_deprecate_rename_machine_legacy` | 13 | ✅ Applied | 2026-04-25 | Yes — see CHANGELOG |
| A.3 | `phaseA_a3_audit_log_infra` | 7, 8 | ✅ Applied | 2026-04-26 | Yes — see CHANGELOG |
| A.4 | `phaseA_a4_install_audit_triggers` | 1, 8 | ⚠️ Applied (10/16) | 2026-04-26 | Yes — see CHANGELOG |
| A.5a | `phaseA_a5a_patch_upsert_daily_sales_and_split_matview` | 1, 4, 8, 9, 11, 12 | ✅ Applied | 2026-04-26 | Yes — see CHANGELOG |
| A.5a.1 | `phaseA_a5a_followup_allow_refresh_op` | 12 (forward-only widening) | ✅ Applied | 2026-04-26 | Yes — see CHANGELOG |
| A.5b | `phaseA_a5b_part{1..4}_of_4_*` (4 migrations) | 1, 2, 4, 8 | ✅ Applied | 2026-04-26 | Yes — see CHANGELOG |
| A.6 | `phaseA_a6_governance_yml_warn_mode` | 15 | ⏳ Pending | — | — |
| A.7 | `phaseA_a7_commit_constitution_to_repo` | 15 | ✅ This commit | 2026-04-25 | n/a (file-only) |

Legend: ⏳ pending, ⏸️ blocked, ✅ applied, ⚠️ applied with caveats, ❌ rolled back.

**A.4 caveat:** Applied to 10 of 16 originally-listed protected entities. The other 6 are deferred to **A.4.b** pending the Article 15 amendment that reconciles Constitution Appendix A with live schema names (`daily_sales/sales_lines → sales_history`, `sales_aggregated → sales_history_aggregated`, `dispatch_plan → refill_dispatch_plan`, `dispatch_lines → refill_dispatching`, `warehouse_inventory_audit_log → inventory_audit_log`; `slots` does not exist and will be removed from the protected list). See CHANGELOG entry for full breakdown.

**A.5b note:** Patches the 24 remaining canonical SECURITY DEFINER writers (22 plpgsql + 2 SQL→plpgsql conversions) to set `app.via_rpc='true'` and `app.rpc_name='<fn>'` via `PERFORM set_config(...)` as the first statements after `BEGIN` (A.5a precedent). Function-level `SET app.via_rpc='true'` was the Cody-recommended shape but was rejected by Supabase (`permission denied to set parameter "app.via_rpc"`) because custom GUCs aren't pre-registered at the role/db level. Audited the 4 nested-DEFINER call sites (`auto_sanity_check→add_sanity_increment`, `receive_all_dispatches_for_machine→receive_dispatch_line`, `return_all_dispatches_for_machine→return_dispatch_line`, `upsert_sales_lines→refresh_sales_aggregated`) and confirmed none write to a protected entity AFTER the inner call returns, so the SET LOCAL leak does not corrupt the audit trail. Also enabled RLS on `refill_dispatch_plan` (Article 2 — closes Amendment 001's RLS gap) with a SELECT-only policy for `authenticated`; service_role bypasses RLS, which is how canonical RPC writes still reach the table. **A.5c follow-up filed**: re-patch all 25 A.5a/A.5b writers to function-level SET once `app.via_rpc` is pre-registered at db level (requires `ALTER DATABASE postgres SET app.via_rpc=''` as superuser).

## Boonz Master — Operational Intelligence Layer (2026-04-30)

| Migration name | Article(s) | Status | Applied | Notes |
|---|---|---|---|---|
| `boonz_master_foundation` | 2, 3, 12 | ✅ Applied | 2026-04-30 | New tables: `boonz_context`, `planned_swaps`, `machine_field_notes`. Alter: `product_mapping.mix_weight`. Non-protected entities — no Appendix A addition required. |
| `add_approve_refill_plan_rpc` | 1, 3, 4, 5, 8, 12 | ✅ Applied | 2026-04-30 | New canonical writer `approve_refill_plan(date, text[])`. Flips `refill_plan_output.operator_status` pending→approved + writes `refill_dispatching`. Roles: operator_admin, superadmin, manager. |

## Refill App Issues — Phase 1 (2026-05-04)

All migrations strictly additive — no live-flow behavior change today. Behavior changes (trigger binding, FE deploys, conserve_split swap, backfills) deferred to tonight's post-dispatch deploy window.

| Migration name | Article(s) | Status | Applied | Notes |
|---|---|---|---|---|
| `m1_warehouse_inventory_status_proposal_table` | 1, 2, 3, 6 (revised), 7, 8, 12 | ✅ Applied | 2026-05-04 | New table + RLS + audit trigger for the propose-then-confirm pattern. Adds `warehouse_inventory_status_proposal` to Appendix A protected entities (via Amendment 002). |
| `m2_confirm_reject_warehouse_status_proposal_rpcs` | 1, 4, 5, 8 | ✅ Applied | 2026-05-04 | Two new canonical writers: `confirm_warehouse_status_proposal(uuid, text)`, `reject_warehouse_status_proposal(uuid, text)`. Manager-confirmation gate for `warehouse_inventory.status` flips; drift detection marks proposal `superseded` when live row diverges. |
| `m3_propose_status_change_functions_unbound` | 1, 4, 6 (revised), 8, 9 | ✅ Applied (function bodies) | 2026-05-04 | Two trigger functions created but **NOT BOUND** to `warehouse_inventory`. Binding migration `m3b` runs post-dispatch tonight. Functions write only to the proposal table; never UPDATE `warehouse_inventory.status`. |
| `m4_mark_picked_up_rpc` | 1, 3, 4, 5, 8 | ✅ Applied | 2026-05-04 | New canonical writer `mark_picked_up(uuid[])` — replaces direct `refill_dispatching` UPDATE from `field/pickup/page.tsx`. RPC dormant until tonight's FE deploy wires it. |
| `m5_diagnostic_views` | 9, 12 | ✅ Applied | 2026-05-04 | Three read-only views: `v_pending_status_proposals`, `v_orphan_dispatch_machine_names` (Issue #13: 4 orphan names), `v_machines_without_shelf_config` (2 rows, both benign — `include_in_refill=false`). `security_invoker=true` so RLS on underlying tables applies. |
| `m3b_bind_warehouse_inventory_propose_triggers` | 6 (revised), 8 | ⏳ Pending | — | **Tonight, post-dispatch.** Binds `propose_inactivate_on_zero_stock` AFTER UPDATE on `warehouse_inventory` and `propose_reactivate_on_stock_return` AFTER UPDATE/INSERT on `warehouse_inventory`. |

## B.1 — Optimizer Brain Phase B: Engine 2 write surface (2026-05-05)

`rotation_proposals` table created with FORCE RLS, four block/allow policies, the universal audit trigger, five indexes (one partial-unique for dedup), and five CHECK constraints enforcing the proposal-type/status state machine. Append-only via DEFINERs (RPCs ship in a separate Phase B.2 migration). Article 15 amendment 003 adds `rotation_proposals` to Appendix A protected entities.

| Migration name | Article(s) | Status | Applied | Notes |
|---|---|---|---|---|
| `phaseB_rotation_proposals_table` | 1, 2, 5, 7, 8, 12, 14, 15 | ✅ Applied | 2026-05-05 | New protected table. ENABLE + FORCE RLS. Audit trigger `tg_audit_rotation_proposals` fires on INSERT/UPDATE/DELETE. Five canonical writers planned (propose_rotation_plan, apply_rotation_proposal, reject_rotation_proposal, mark_proposals_expired, supersede helper) — bodies pending Phase B.2 with separate Cody review. |
| `phaseB2a_score_machine_for_product` | 12 | ✅ Applied | 2026-05-05 | Read-only INVOKER function. 0-100 fit score with breakdown for routing a boonz_product to a target machine. Reads `v_machine_absorption_capacity`. Weights: throughput 35, archetype 20, location 15, capacity 15, urgency 10. Hard cutoffs: `machine_excluded`, `machine_inactive`, `travel_scope_vox_locked` (8 VOX-locked SKUs hardcoded; TODO Phase C: move to `travel_scope_locks` config table). Smoke tests passed: Vitamin Well Upgrade → VOXMCC-1009 = 69.94 (real fit), Aquafina → VML = 0 (hard_block). Cody-reviewed; revisions applied (COALESCE on throughput formula for single-machine edge case, TODO comment on hardcoded list). |
| `phaseB2a_fix_score_function_multi_row` | 12 | ✅ Applied | 2026-05-06 | Forward-only patch. `v_machine_absorption_capacity` returns multiple rows for one (machine, boonz_product) pair when a boonz SKU is the global default for ≥2 pod_products (multi-variant). LANGUAGE sql function errored with "more than one row returned by a subquery." Patched the `ctx` CTE with `DISTINCT ON (machine_id, boonz_product_id)` ordered by `pod_product_id NULLS LAST` for determinism. |

## B.1 — Lifecycle Reality Anchor (2026-05-07)

| Migration name | Article(s) | Status | Applied | Notes |
|---|---|---|---|---|
| `phaseB_b1_2_machine_first_sale_view` | 2, 9, 12 | ✅ Applied | 2026-05-08 | New view `v_machine_first_sale` (SECURITY INVOKER, GROUP BY machine_id MIN/MAX/COUNT). Used by evaluate-lifecycle to compute MACHINE_RAMPING based on actual deployment age, fixing the B.1.1 false-positive at WAVEMAKER/WPP (mature machines with quiet patch in 62-day window were wrongly flagged ramping). Edge fn v11 reads from this view as the authoritative first-sale source. |
| `phaseB_b3_lifecycle_scoring_redesign` | 9, 12, 13, 14, 15 | ✅ Applied | 2026-05-08 | Splits the lifecycle scoring engine: `product_lifecycle_global.score` becomes rank-percentile of per_machine_avg_v30 across the product universe (top product = 10, bottom = 0). `slot_lifecycle.score` becomes a ratio-spectrum centered on the product's own per-machine global avg (5.0 = at avg, 10.0 = 2× avg). Both EMA-blended with prior value (α=0.67 → recent ≈ 2× historical). New `getSignalV2` hard-gates DOUBLE DOWN/KEEP GROWING on both score AND trend. Adds 7 observability columns across `product_lifecycle_global` and `slot_lifecycle`, partial unique index on `(global_rank)` and `(pod_product_id, score DESC) WHERE is_current=true`, `score_kind` enum on `lifecycle_score_history`, new view `v_product_lifecycle_global_enriched`. Edge fn v12 deployed; Aquafina ranks #1 (per_machine_avg=13.18), Evian Sparkling ranks #36 (per_machine_avg=0.135) — the per-machine apples-to-apples ranking CS asked for. |
| `phaseB_b1_lifecycle_reality_anchor` | 1, 2, 3, 7, 9, 12, 14 | ✅ Applied | 2026-05-07 | Repoints lifecycle off `planogram` (frozen seed) onto `weimi_aisle_snapshots` (refreshed every ~6h). Converts `slot_lifecycle` from a (machine, shelf) snapshot to a (machine, shelf, product) ledger via 3 new columns (`is_current`, `rotated_in_at`, `rotated_out_at`), constraint rotation to `UNIQUE (machine_id, shelf_id, pod_product_id)`, and partial unique index `uq_slot_lifecycle_current_per_slot` enforcing "exactly one current product per live slot." Two `lifecycle_score_history` indexes added for per-slot-per-product history queries. Pre-flight DO-block aborts cleanly if existing data violates the new invariant. Companion edge fn diff (`evaluate-lifecycle/index.ts` v9) reads snapshot + shelf_configurations, normalizes WEIMI's "A1"/"A15" slot codes to padded "A01"/"A15" via TS-side `padShelf` helper, detects rotations by comparing dominant product-per-slot to existing `is_current=true` row and flips the prior to `is_current=false, rotated_out_at=now()`. New DQ flag types `UNRESOLVED_SHELF_ID` and `UNRESOLVED_POD_PRODUCT_NAME` surface unresolvable snapshot rows. FE matrix at `src/app/(app)/app/lifecycle/page.tsx` adds "Show rotated-out products" toggle that overlays prior products as faded points with rotation timestamps. **Known debt:** evaluate-lifecycle remains in violation of Article 9 (business logic + direct writes inline) — pre-existing, deepened by the rotation-detection logic; tracked for follow-up to wrap in `compute_and_apply_lifecycle()` SECURITY DEFINER RPC. **Follow-up filed:** `phaseB_b2_refill_engine_planogram_retirement` (Dara design pending — refill engine still reads `planogram`). |
| `phaseB2b_engine2_rpcs` | 1, 4, 5, 8, 12 | ✅ Applied | 2026-05-06 | Four DEFINER canonical writers for `rotation_proposals`: `propose_rotation_plan` (INSERT loop, system+operator callable), `apply_rotation_proposal` (pending→applied, operator-only), `reject_rotation_proposal` (pending→rejected, operator-only), `mark_proposals_expired` (pending→expired, system+operator callable). All set `app.via_rpc/app.rpc_name`, validate inputs, role-gate via user_profiles. First real run produced 21 pending proposals (top: Vitamin Well Antioxidant→VOXMCC-1009 fit 82.7), 3 dedup-skips, 0 hard-blocks below threshold, 21s wall-clock. Audit trigger fired correctly (21 rows in `write_audit_log` with via_rpc=true, rpc_name='propose_rotation_plan'). Cody approved without revisions. **Phase B.3 follow-up:** wire pg_cron for `propose_rotation_plan` at 04:00 Dubai and `mark_proposals_expired(3)` at 03:00 — Article 11 review required. |

## A.5 — Optimizer Brain Phase A foundations (2026-05-05)

Read-only intelligence layer for Engine 2 (Rotation Planner). Adds the lifecycle archetype column on `boonz_products` (HYPE | ALWAYS_ON | SEASONAL | TRIAL | UNCLASSIFIED), bootstraps it via product lifetime + velocity, and exposes two views: `v_warehouse_at_risk` (warehouse stock × expiry × Engine 1 signal context) and `v_machine_absorption_capacity` (per (machine, boonz_product) absorption profile, sourced from `slot_lifecycle` to avoid parallel velocity computation). No write paths in Phase A. Cody-reviewed; revisions applied (anon grant removed, audit attribution added, article header). Engine 2 RPCs ship in Phase B.

| Migration name | Article(s) | Status | Applied | Notes |
|---|---|---|---|---|
| `phaseA_optimizer_foundations` | 2, 6, 12, 14 | ✅ Applied | 2026-05-05 | ALTER `boonz_products` ADD `lifecycle_archetype` text NOT NULL DEFAULT 'UNCLASSIFIED' with CHECK enum + partial index. Bootstrap UPDATE: 144 ALWAYS_ON, 4 TRIAL, 131 UNCLASSIFIED. New views `v_warehouse_at_risk` (171 rows) and `v_machine_absorption_capacity` (8,845 rows). GRANT SELECT to `authenticated` only. |
| `phaseA_optimizer_foundations_fix_urgency_bucket` | 12 | ✅ Applied | 2026-05-05 | Forward-only patch. `INTERVAL '7'` (no unit) was being parsed as 7 *seconds*, dumping every row into `safe_90d_plus`. Replaced with integer arithmetic (`CURRENT_DATE + 7`). Post-fix: 1 urgent_0_7d, 8 soon_7_30d, 13 medium_30_60d, 19 long_60_90d, 130 safe_90d_plus. |

## A.4 — Repurposed-machine attribution (2026-05-05)

Versioned-history table + Adyen attribution view + per-machine read-only RPC. Makes /app/performance and partner reports correctly split repurposed machines (e.g. ACTIVATE-2005 vs MPMCC-2005-0000-W0). Cody-reviewed; revisions applied.

| Migration name | Article(s) | Status | Applied | Notes |
|---|---|---|---|---|
| `phaseA_a4_machine_terminal_history` | 1, 2, 4, 7, 8, 12, 14 | ✅ Applied | 2026-05-05 | New versioned-history table `machine_terminal_history` (terminal × machine × daterange, EXCLUDE-overlap constraint, RLS, generic audit trigger), 9 backfilled windows, new SECURITY DEFINER RPC `register_terminal_move`, new view `v_adyen_transactions_attributed` (security_invoker). Adds `machine_terminal_history` to protected entities. |
| `phaseA_a4b_attributed_view_dedupe` | 12 | ✅ Applied | 2026-05-05 | Forward-only patch: restrict the view's machines join to `status='Active'` so stale Inactive terminal claims (WH3_* leftovers) don't double-match Adyen rows. |
| `phaseA_a4c_per_machine_performance_rpc` | 12 | ✅ Applied | 2026-05-05 | New read-only RPC `get_per_machine_performance(date, date, text, text[])` returns JSON array per attributed-machine. LANGUAGE sql STABLE; SECURITY INVOKER (RLS via underlying views). Single greppable call site for any per-machine dashboard. |
| `phaseA_a4d_vox_commercial_report_via_attributed_view` | 1, 12 | ✅ Applied | 2026-05-05 | Patches `get_vox_commercial_report` to read Adyen via `v_adyen_transactions_attributed`, split SettledBulk vs RefundedBulk, and net refund_returned out of captured. Site attribution unchanged (still via `sh.machine_mapping`). |
| `phaseA_a4e_vox_consumer_report_join_by_machine_id` | 1, 12 | ✅ Applied | 2026-05-05 | Patches `get_vox_consumer_report` join from `selected_machines.machine_name = sales_history.machine_mapping` (current name) to `selected_machines.machine_id = sales_history.machine_id` (stable). Without this, sales rows whose `machine_mapping` was the historical name (e.g. `MPMCC-2005-0000-W0` Apr 23-27) were dropped because no current machine row had that `official_name`. The breakdown still uses `machine_mapping` so MPMCC-2005 appears as a separate row. Powers `/refill/consumers`. |
| `phaseA_a4f_consumer_report_adyen_pending_flag` | 12 | ✅ Applied | 2026-05-05 | Adds `pending`/`status` fields per recent_txn and `pending_txns`/`wallet_txns` summary counts. Lets the FE distinguish "Adyen settlement pending" (last 48h, no PSP yet) from "wallet/cash" (older, no PSP — genuinely off-Adyen). Adyen settlement lags 1-3 days; without this flag, today's late-afternoon transactions look like unmatched wallet sales until the next settlement file lands. |
| `phaseA_a4g_vox_commercial_filter_by_machine_id` | 1, 12 | ✅ Applied | 2026-05-05 | Patches `get_vox_commercial_report` to drop the `machine_mapping LIKE 'VOXMM%'/'VOXMCC%'` filter (which silently excluded ACTIVATE-2005, MPMCC-2005, IFLYMCC-1024, ACTIVATEMCC-1037, MPMCC-1054, MPMCC-1058 from the commercial waterfall) and switch to `machine_id` matching against the venue_group=VOX Active machines bucketed by pod_location. Now `/refill/consumers` Commercial tab and Header bar agree (was 1,087 AED / 39 txns gap = MPMCC-2005-0000-W0 era + 6 other non-VOX-prefix Mirdif machines). |

---

## How to add a new entry

1. Apply the migration via `mcp__supabase__apply_migration` with a descriptive name (`phaseX_NN_description`).
2. Add a row to the table above (or the appropriate section) with the date, the Constitution article(s) it enforces, and a one-line note in CHANGELOG.md.
3. If the migration deprecates anything, also update the deprecation tracker in `RPC_REGISTRY.md`.

## Migration naming convention

`phase{A|B|C}_{step}_{verb_noun}` — e.g., `phaseA_a3_audit_log_infra`, `phaseB_b2_machines_canonical_rpc_only`.

Forward-only. Never reuse a name. If a migration was bad, write a new one that fixes it (and document the why in CHANGELOG.md).
