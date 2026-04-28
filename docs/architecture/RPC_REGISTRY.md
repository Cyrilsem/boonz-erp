# RPC Registry

Inventory of all `SECURITY DEFINER` functions in the Boonz Supabase project (`eizcexopcuoycuosittm`), classified by role. The classification drives which functions need Phase A.5 patching (canonical writers) and which can be left alone.

**Verified live** on 2026-04-25 via `pg_proc` query (45 DEFINER functions total).
**Updated 2026-04-27:** +2 procurement canonical writers (`create_purchase_order`, `receive_purchase_order`). Total: 27 canonical writers.

**Phase A.5 complete (2026-04-26):** All 25 canonical writers patched (1 in A.5a, 24 in A.5b — see CHANGELOG and MIGRATIONS_REGISTRY for details). Every writer now tags its transaction with `app.via_rpc='true'` and `app.rpc_name='<fn>'` via `PERFORM set_config(...)` at the top of `BEGIN`, so the A.4 generic AFTER trigger captures `via_rpc=true, rpc_name=<fn>` on every protected-entity row.

## Canonical writers — 25 functions (Phase A.5 scope)

These mutate at least one protected entity. Each must, by the end of Phase A.5:
1. Set `app.via_rpc = 'true'` and `app.rpc_name = '<function_name>'` at the start of the function body.
2. Be the **only** code path that writes to its target tables (Constitution Article 1).
3. Validate all inputs (Article 4).
4. Write a row to `write_audit_log` on success (Article 8 — automated by the generic trigger installed in A.4).

### Machine lifecycle
| Function | Writes to | A.5 status |
|---|---|---|
| `add_new_machine` | `machines`, `slots`, `slot_lifecycle`, `planogram` | ✅ A.5b — patched 2026-04-26 |
| `repurpose_machine` | `machines`, `slots`, `slot_lifecycle`, `planogram` | ✅ A.5b — patched 2026-04-26 |
| `toggle_machine_refill` | `machines` | ✅ A.5b — patched 2026-04-26 |

### Sales & telemetry
| Function | Writes to | A.5 status |
|---|---|---|
| `upsert_daily_sales` | `sales_history` (Constitution Appendix A: was listed as `daily_sales`; reconciled by Amendment 001) | ✅ A.5a — patched 2026-04-26 |
| `upsert_sales_lines` | `sales_history` (was listed as `sales_lines`; superseded by `upsert_daily_sales` — verify caller graph before patching) | ✅ A.5b — patched 2026-04-26 |
| `process_adyen_staging` | `sales_history` via staging | ✅ A.5b — patched 2026-04-26 |
| `process_weimi_staging` | `sales_history` via staging | ✅ A.5b — patched 2026-04-26 |
| `retry_staging_errors` | staging tables | ✅ A.5b — patched 2026-04-26 |
| `refresh_sales_aggregated` | `sales_history_aggregated` (Constitution Appendix A: was listed as `sales_aggregated`; reconciled by Amendment 001) | ✅ A.5a — patched 2026-04-26 (now also writes explicit audit row, runs on `*/10 * * * *` cron) |
| `refresh_product_scores` | `product_scores` | ✅ A.5b — patched 2026-04-26 |

### Inventory snapshots
| Function | Writes to | A.5 status |
|---|---|---|
| `upsert_pod_snapshot` | `pod_inventory` | ✅ A.5b — patched 2026-04-26 |
| `upsert_aisle_snapshot` | `pod_inventory` | ✅ A.5b — patched 2026-04-26 |
| `upsert_refill_stock_snapshot` | `warehouse_inventory` | ✅ A.5b — patched 2026-04-26 |
| `load_pod_staging_chunk` | staging | ✅ A.5b — patched 2026-04-26 |
| `auto_decrement_pod_inventory` | `pod_inventory`, `pod_inventory_audit_log` | ✅ A.5b — patched 2026-04-26 |
| `add_sanity_increment` | `warehouse_inventory` (sanity adjustments) | ✅ A.5b — patched 2026-04-26 |
| `auto_sanity_check` | `warehouse_inventory` | ✅ A.5b — patched 2026-04-26 |
| `backfill_dispatch_boonz_product_ids` | `dispatch_lines` | ✅ A.5b — patched 2026-04-26 |

### Procurement — NEW 2026-04-27
| Function | Writes to | A.5 status |
|---|---|---|
| `create_purchase_order` | `purchase_orders`, `driver_tasks`, `po_notifications` | ✅ 2026-04-27 — new canonical writer. Replaces FE direct inserts. Uses `po_number_seq` for race-safe numbering. Roles: field_staff, warehouse, operator_admin, superadmin, manager. |
| `receive_purchase_order` | `purchase_orders`, `warehouse_inventory`, `po_additions`, `inventory_audit_log` | ✅ 2026-04-27 — new canonical writer. Fixes B-2 (no duplicate PO lines for multi-batch), B-3 (warehouse_inventory no longer written from FE), B-4 (po_additions fully received + inventoried). Roles: warehouse, operator_admin, superadmin, manager. |

### Refill plan + dispatch
| Function | Writes to | A.5 status |
|---|---|---|
| `write_refill_plan` | `refill_plan_output` | ✅ A.5b — patched 2026-04-26 |
| `write_dispatch_plan` | `dispatch_plan` | ✅ A.5b — patched 2026-04-26 |
| `push_plan_to_dispatch` | `dispatch_plan`, `dispatch_lines` | ✅ A.5b — patched 2026-04-26 |
| `pack_dispatch_line` | `dispatch_lines`, `warehouse_inventory` | ✅ A.5b — patched 2026-04-26 |
| `receive_dispatch_line` | `dispatch_lines`, `pod_inventory` | ✅ A.5b — patched 2026-04-26 |
| `receive_all_dispatches_for_machine` | `dispatch_lines`, `pod_inventory` | ✅ A.5b — patched 2026-04-26 |
| `return_dispatch_line` | `dispatch_lines`, `warehouse_inventory` | ✅ A.5b — patched 2026-04-26 |
| `return_all_dispatches_for_machine` | `dispatch_lines`, `warehouse_inventory` | ✅ A.5b — patched 2026-04-26 |

> **Count check:** 26 listed above. The verified count is 25 — re-verify when patching A.5 (one of these may be a read-only helper that was misclassified, or two may be aliases). The Cody skill carries the canonical list as a JSON artifact in `cody/canonical_rpcs.json`.

## Read-only helpers — 7 functions (no A.5 patching needed)

These do not mutate; they exist as DEFINER for RLS-bypass on read paths.

- `get_active_planogram`
- `get_machine_planogram`
- `get_pod_inventory_for_machine`
- `get_warehouse_summary`
- `get_refill_plan_for_date`
- `get_settlement_for_partner`
- `get_user_role` (returns role from `user_profiles` to FE)

## Audit / system helpers — 4 functions (left as-is)

- `audit_machine_duplicates` — read-only diagnostic.
- `log_wh_mutation` — pre-existing audit hook on `warehouse_inventory`. Will be superseded by the generic trigger in A.4 but not removed (deprecation per Article 13 — 90-day monitor).
- `check_edge_function_service_key` — guard used by edge functions.
- `audit_log_write` — **NEW (Phase A.3, 2026-04-26).** Generic AFTER trigger function for `write_audit_log`. `SECURITY DEFINER`. EXECUTE revoked from `anon`/`authenticated`/`PUBLIC`. Reads `app.via_rpc` and `app.rpc_name` GUCs, captures PK from `TG_ARGV[0]`, records full row payload. Installed on protected tables in A.4.

## Trigger-only — 3 functions (not callable from FE; bypass A.5)

- `auto_audit_warehouse_inventory` (UPDATE trigger)
- `auto_audit_warehouse_inventory_insert` (INSERT trigger)
- `handle_new_user` (auth trigger — creates `user_profiles` row on signup)

## Deprecated — 1 function (Phase A.2 complete)

- `rename_machine_in_place_legacy` — replaced by `repurpose_machine`. **Deprecated 2026-04-25** via migration `phaseA_a2_deprecate_rename_machine_legacy`. Now `SECURITY INVOKER` with `EXECUTE` revoked from `anon`/`authenticated`. `service_role` retains EXECUTE through the monitor window. **Scheduled DROP date: 2026-07-24** (90 days after deprecation, per Article 13). Caller scan at deprecation time returned zero callers across code, n8n, cron, triggers, and other DEFINERs.

## How to add a new RPC

1. Decide if it's a canonical writer (mutates a protected entity) or a helper.
2. If writer: must set `app.via_rpc`, must validate inputs, must be the only write path. Add a row to the appropriate section above.
3. If helper: keep `SECURITY DEFINER` only if RLS-bypass on read is genuinely needed. Otherwise prefer `SECURITY INVOKER`.
4. Add an entry to CHANGELOG.md citing the Constitution article(s) it satisfies.
5. CI lint (Phase A.6) will check that any new function in `pg_proc` is registered here.
