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

---

## How to add a new entry

1. Apply the migration via `mcp__supabase__apply_migration` with a descriptive name (`phaseX_NN_description`).
2. Add a row to the table above (or the appropriate section) with the date, the Constitution article(s) it enforces, and a one-line note in CHANGELOG.md.
3. If the migration deprecates anything, also update the deprecation tracker in `RPC_REGISTRY.md`.

## Migration naming convention

`phase{A|B|C}_{step}_{verb_noun}` — e.g., `phaseA_a3_audit_log_infra`, `phaseB_b2_machines_canonical_rpc_only`.

Forward-only. Never reuse a name. If a migration was bad, write a new one that fixes it (and document the why in CHANGELOG.md).
