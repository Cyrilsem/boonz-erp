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
