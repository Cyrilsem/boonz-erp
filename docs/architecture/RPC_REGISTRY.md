# RPC Registry

Inventory of all `SECURITY DEFINER` functions in the Boonz Supabase project (`eizcexopcuoycuosittm`), classified by role. The classification drives which functions need Phase A.5 patching (canonical writers) and which can be left alone.

**Verified live** on 2026-04-25 via `pg_proc` query (45 DEFINER functions total).
**Updated 2026-04-27:** +2 procurement canonical writers (`create_purchase_order`, `receive_purchase_order`).
**Updated 2026-05-04:** +3 inventory operations (`transfer_warehouse_stock`, `log_manual_refill`, `adjust_pod_inventory`), +1 warehouse reconciliation (`adjust_warehouse_stock`). Total: 30+ canonical writers.

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

### Refill engine — UPDATED 2026-05-04
| Function | Writes to | Status |
|---|---|---|
| `auto_generate_refill_plan` | `refill_plan_output`, `refill_dispatching` (via `write_refill_plan`), `shelf_configurations` (via `seed_shelf_configurations`) | ✅ **UPDATED 2026-05-04 (RPC A)** — added `p_machines text[]` param. When provided: bypasses health triage + LIMIT 10, processes exactly the listed machines. Auto-calls `seed_shelf_configurations` for machines with 0 shelf configs. Preserves packed dispatching rows. Args: `p_filter text`, `p_plan_date date`, `p_dry_run boolean`, `p_machines text[]`. |

### Refill plan + dispatch — UPDATED 2026-05-04
| Function | Writes to | Status |
|---|---|---|
| `approve_refill_plan` | `refill_plan_output` (status→approved), `refill_dispatching` | ✅ **UPDATED 2026-05-04 (RPC E)** — loud errors. Pre-approve diagnostics detect missing shelf_configs, unmatched products, unmatched machines. Returns `alerts` jsonb array. Preserves packed dispatching rows (`AND packed=false` guard). Dispatch gap detection: warns when `rows_approved > dispatching_rows_written`. Args: `p_plan_date date, p_machine_names text[]`. Roles: operator_admin, superadmin, manager. Articles 1, 3, 4, 5, 8, 12. |
| `write_refill_plan` | `refill_plan_output` | ✅ **UPDATED 2026-05-04 (RPC B)** — scoped delete. Extracts distinct machine_names from `p_lines` jsonb; only deletes pending rows for those machines (was: all pending for date). Returns `machines_affected` array. Articles 1, 4, 8, 12. |
| `override_refill_quantity` | `refill_plan_output` | ✅ **NEW 2026-05-04 (RPC C)** — operator quantity override. Updates pending REFILL/ADD NEW rows for a specific machine+shelf. Multi-variant: proportional redistribution. Args: `p_plan_date date, p_machine_name text, p_shelf_code text, p_new_quantity int`. Roles: operator_admin, superadmin, manager. Articles 1, 4, 5, 8, 12. |
| `inject_swap` | `refill_plan_output`, `refill_dispatching` | ✅ **NEW 2026-05-04 (RPC D)** — inject swap into live plan. Inserts REMOVE + ADD NEW rows as `approved`, creates dispatching rows. Preserves packed rows (`AND packed=false` guard). Validates machine, shelf_config, pod_product, boonz_product existence. Args: `p_plan_date date, p_machine_name text, p_shelf_code text, p_remove_pod_product text, p_add_pod_product text, p_add_boonz_product text, p_add_quantity int, p_comment text`. Roles: operator_admin, superadmin, manager. Articles 1, 4, 5, 8, 12. |
| `seed_shelf_configurations` | `shelf_configurations` | ✅ **NEW 2026-05-04 (RPC F)** — auto-seed shelf_configurations from `v_live_shelf_stock`. Converts aisle codes (`0-A00`→`A01`). Idempotent via `ON CONFLICT DO NOTHING`. Args: `p_machine_name text`. Roles: operator_admin, superadmin, manager. Articles 1, 4, 8, 12. |
| `cleanup_orphan_dispatching` | `refill_dispatching` (DELETE orphaned rows) | ✅ **NEW 2026-05-04** — deletes unpacked/not-picked-up dispatching rows that have no matching plan row (pending or approved). Scoped by date + optional machine_names. Used after `write_refill_plan` rewrites plan rows to clean stale dispatching. Args: `p_dispatch_date date, p_machine_names text[]`. Roles: operator_admin, superadmin, manager. Articles 1, 4, 8, 12. |
| `write_dispatch_plan` | `dispatch_plan` | ✅ A.5b — patched 2026-04-26 |
| `push_plan_to_dispatch` | `dispatch_plan`, `dispatch_lines` | ✅ A.5b — patched 2026-04-26 |
| `pack_dispatch_line` | `dispatch_lines`, `warehouse_inventory` | ✅ A.5b — patched 2026-04-26 |
| `receive_dispatch_line` | `dispatch_lines`, `pod_inventory` | ✅ A.5b — patched 2026-04-26 |
| `receive_all_dispatches_for_machine` | `dispatch_lines`, `pod_inventory` | ✅ A.5b — patched 2026-04-26 |
| `return_dispatch_line` | `dispatch_lines`, `warehouse_inventory` | ✅ A.5b — patched 2026-04-26 |
| `return_all_dispatches_for_machine` | `dispatch_lines`, `warehouse_inventory` | ✅ A.5b — patched 2026-04-26 |

> **Count check:** 26 listed above. The verified count is 25 — re-verify when patching A.5 (one of these may be a read-only helper that was misclassified, or two may be aliases). The Cody skill carries the canonical list as a JSON artifact in `cody/canonical_rpcs.json`.

### Warehouse-status propose-then-confirm — NEW 2026-05-04
| Function | Writes to | Status |
|---|---|---|
| `confirm_warehouse_status_proposal(uuid, text)` | `warehouse_inventory` (status flip), `warehouse_inventory_status_proposal` (status→confirmed) | ✅ NEW 2026-05-04 — canonical confirm path. Roles: warehouse, operator_admin, superadmin, manager. Drift detection marks proposal `superseded` if live status diverged. Articles 1, 4, 5, 8. |
| `reject_warehouse_status_proposal(uuid, text)` | `warehouse_inventory_status_proposal` (status→rejected) | ✅ NEW 2026-05-04 — canonical reject path. `warehouse_inventory.status` is NOT modified. Roles: warehouse, operator_admin, superadmin, manager. Articles 1, 4, 5, 8. |

### Inventory operations — NEW 2026-05-04
| Function | Writes to | Status |
|---|---|---|
| `transfer_warehouse_stock(uuid, uuid, jsonb, date, text)` | `warehouse_inventory` (source decrement + dest increment/insert), `inventory_audit_log` (both sides) | ✅ NEW 2026-05-04 — canonical inter-warehouse transfer. FIFO: picks oldest-expiry batches from source. Cold storage validation. Splits across batches if needed. Creates dest rows on first transfer. Args: `p_source_warehouse_id, p_dest_warehouse_id, p_lines [{boonz_product_id, qty, expiration_date}], p_transfer_date, p_reason`. Roles: warehouse, operator_admin, superadmin, manager. Articles 1, 4, 6, 8. |
| `log_manual_refill(text, uuid, date, jsonb, text)` | `warehouse_inventory` (source decrement), `pod_inventory` (insert), `inventory_audit_log`, `pod_inventory_audit_log` | ✅ NEW 2026-05-04 — retroactive manual refill recording. FIFO warehouse decrement. Continues on WH shortfall (backlog cleanup — physical refill already happened). Args: `p_machine_name, p_source_warehouse_id, p_refill_date, p_lines [{shelf_code, boonz_product_id, qty, expiration_date}], p_reason`. Roles: warehouse, operator_admin, superadmin, manager. Articles 1, 4, 8. |
| `adjust_pod_inventory(text, date, jsonb, text)` | `pod_inventory` (update or insert), `pod_inventory_audit_log` | ✅ NEW 2026-05-04 — manual pod inventory correction + FIFO cleanup. Matches existing rows by (machine, shelf, product, expiry). Updates current_stock, marks Depleted when qty=0 (no DELETE). Supports batch-level FIFO: multiple lines per shelf with different expiry dates. Args: `p_machine_name, p_snapshot_date, p_lines [{shelf_code, boonz_product_id, new_qty, expiration_date, batch_id}], p_reason`. Roles: warehouse, operator_admin, superadmin, manager. Articles 1, 4, 5, 8. |
| `adjust_warehouse_stock(uuid, jsonb, date, text)` | `warehouse_inventory` (update or insert), `inventory_audit_log` | ✅ NEW 2026-05-04 — physical count reconciliation for warehouse inventory. Matches existing rows by `wh_inventory_id` or `(warehouse, product, expiry)`. Updates stock + consumer_stock + expiration_date + batch_id + status. Inserts new rows when no match. Unchanged-check includes expiry comparison (catches expiry-only corrections). Args: `p_warehouse_id, p_lines [{wh_inventory_id?, boonz_product_id, new_warehouse_stock, new_consumer_stock, expiration_date?, batch_id?, status?}], p_snapshot_date, p_reason`. Roles: warehouse, operator_admin, superadmin, manager. Articles 1, 4, 5, 8. |

### Pickup — NEW 2026-05-04
| Function | Writes to | Status |
|---|---|---|
| `mark_picked_up(uuid[])` | `refill_dispatching` (picked_up=true on packed=true rows only) | ✅ NEW 2026-05-04 — canonical pickup path. Replaces direct FE `refill_dispatching` UPDATE in `field/pickup/page.tsx`. Roles: field_staff, warehouse, operator_admin, superadmin, manager. Returns counts + skipped IDs (already picked up / not packed / not found). Articles 1, 3, 4, 5, 8. **Dormant** until tonight's FE deploy wires it. |

### Terminal-to-machine history — NEW 2026-05-05
| Function | Writes to | Status |
|---|---|---|
| `register_terminal_move(p_unique_terminal_id text, p_new_machine_id uuid, p_effective_from date, p_attributed_name text, p_attributed_venue_group text, p_notes text)` | `machine_terminal_history` (close open window via UPDATE, then INSERT new window) | ✅ NEW 2026-05-05 — canonical writer for terminal reassignments / machine renames. Validates inputs (NULL guards), FK existence on `machine_id`, role gate (operator_admin or superadmin). Returns `{closed_history_id, new_history_id}` jsonb. Audited via the generic `audit_log_write` trigger. Articles 1, 4, 8. Use whenever a physical Adyen terminal moves between machine_ids or a machine is renamed — downstream attribution views auto-correct. |
| `propose_rotation_plan(p_horizon_days int DEFAULT 21, p_min_fit_score numeric DEFAULT 50.0, p_max_proposals_per_source int DEFAULT 3, p_dry_run boolean DEFAULT false)` | `rotation_proposals` (INSERT pending rows) | ✅ NEW 2026-05-06 — Engine 2 main loop. Iterates `v_warehouse_at_risk` (urgent buckets only), scores every active machine via `score_machine_for_product`, INSERTs top-N pending proposals. `trigger_reason='expiry_risk'`, `proposal_type='wh_to_machine'` in Phase B.2b. System-callable (cron via service_role) and operator-callable. Articles 1, 4, 8. First run: 21 inserts, 3 dedup-skips, 0 hard-blocks-below-threshold, 21s wall-clock. |
| `apply_rotation_proposal(p_proposal_id uuid, p_plan_date date, p_notes text DEFAULT NULL)` | `rotation_proposals` (UPDATE pending → applied) | ✅ NEW 2026-05-06 — CS approval path. Validates pending status, sets `applied_to_plan_date`, `reviewed_at`, `reviewed_by`. Operator-only (no system bypass). **Phase B prototype: status flip only — does NOT create a planned_swaps row. Phase C wires it into the refill engine.** Articles 1, 4, 5, 8. |
| `reject_rotation_proposal(p_proposal_id uuid, p_reason text)` | `rotation_proposals` (UPDATE pending → rejected) | ✅ NEW 2026-05-06 — CS veto path. Captures p_reason in notes for downstream weight-tuning analysis. Operator-only. Articles 1, 4, 5, 8. |
| `mark_proposals_expired(p_age_days int DEFAULT 3)` | `rotation_proposals` (UPDATE pending → expired) | ✅ NEW 2026-05-06 — daily housekeeping. System-callable (pg_cron via service_role) and operator-callable. Articles 1, 4, 5, 8, 11 (cron wiring pending Phase B.3). |

## Read-only helpers — 9 functions (no A.5 patching needed)

These do not mutate; they exist as DEFINER for RLS-bypass on read paths (with the exception of the INVOKER ones noted below — newer additions prefer INVOKER per Cody Article 4 default).

- `get_active_planogram`
- `get_machine_planogram`
- `get_pod_inventory_for_machine`
- `get_warehouse_summary`
- `get_refill_plan_for_date`
- `get_settlement_for_partner`
- `get_user_role` (returns role from `user_profiles` to FE)
- `get_per_machine_performance(p_date_from date, p_date_to date, p_venue_group text, p_machine_names text[])` — **NEW 2026-05-05.** Returns a JSON array of per-attributed-machine WEIMI vs Adyen rollups. SECURITY INVOKER, LANGUAGE sql STABLE — RLS applies via `v_sales_history_attributed` and `v_adyen_transactions_attributed` (both `security_invoker = true`). Single greppable call site for `/app/performance` Sites & Machines and any per-machine dashboard. Splits repurposed machines automatically (e.g. ACTIVATE-2005 vs MPMCC-2005). Refund-netted `adyen_net_cash_aed` per row.
- `score_machine_for_product(p_target_machine_id uuid, p_boonz_product_id uuid, p_horizon_days int DEFAULT 21, p_proposed_qty int DEFAULT 5)` — **NEW 2026-05-05.** Engine 2 fit scorer. Returns `{score, hard_block, breakdown}` jsonb where score is 0-100 and breakdown carries per-component scores (throughput 35%, archetype_fit 20%, location_fit 15%, open_capacity 15%, urgency 10%) plus the inputs that drove them. SECURITY INVOKER, LANGUAGE sql STABLE — reads `v_machine_absorption_capacity`. Hard cutoffs surface as `hard_block` reason: `machine_excluded`, `machine_inactive`, `travel_scope_vox_locked`. Called by `propose_rotation_plan` (Phase B.2b) and ad-hoc by operators reviewing rotation candidates.

## Audit / system helpers — 4 functions (left as-is)

- `audit_machine_duplicates` — read-only diagnostic.
- `log_wh_mutation` — pre-existing audit hook on `warehouse_inventory`. Will be superseded by the generic trigger in A.4 but not removed (deprecation per Article 13 — 90-day monitor).
- `check_edge_function_service_key` — guard used by edge functions.
- `audit_log_write` — **NEW (Phase A.3, 2026-04-26).** Generic AFTER trigger function for `write_audit_log`. `SECURITY DEFINER`. EXECUTE revoked from `anon`/`authenticated`/`PUBLIC`. Reads `app.via_rpc` and `app.rpc_name` GUCs, captures PK from `TG_ARGV[0]`, records full row payload. Installed on protected tables in A.4.

## Trigger-only — 3 functions (not callable from FE; bypass A.5)

- `auto_audit_warehouse_inventory` (UPDATE trigger)
- `auto_audit_warehouse_inventory_insert` (INSERT trigger)
- `handle_new_user` (auth trigger — creates `user_profiles` row on signup)

## Trigger-only proposers — 2 functions (NEW 2026-05-04, NOT YET BOUND)

These functions write to `warehouse_inventory_status_proposal` only — never UPDATE `warehouse_inventory.status`. They are bodies-only as of 2026-05-04 and will be bound to `warehouse_inventory` triggers in `m3b` post-dispatch tonight. Article 6 (revised) compliant: they propose, the manager confirms.

- `propose_inactivate_on_zero_stock()` — fires AFTER UPDATE on `warehouse_inventory` when both stock columns just dropped to zero on an Active row. Idempotency guard skips duplicate pending proposals from the same proposer.
- `propose_reactivate_on_stock_return()` — fires AFTER UPDATE/INSERT on `warehouse_inventory` when total stock just transitioned 0→>0 on an Inactive row (procurement / restock case). Same idempotency guard.

## Deprecated — 1 function (Phase A.2 complete)

- `rename_machine_in_place_legacy` — replaced by `repurpose_machine`. **Deprecated 2026-04-25** via migration `phaseA_a2_deprecate_rename_machine_legacy`. Now `SECURITY INVOKER` with `EXECUTE` revoked from `anon`/`authenticated`. `service_role` retains EXECUTE through the monitor window. **Scheduled DROP date: 2026-07-24** (90 days after deprecation, per Article 13). Caller scan at deprecation time returned zero callers across code, n8n, cron, triggers, and other DEFINERs.

## How to add a new RPC

1. Decide if it's a canonical writer (mutates a protected entity) or a helper.
2. If writer: must set `app.via_rpc`, must validate inputs, must be the only write path. Add a row to the appropriate section above.
3. If helper: keep `SECURITY DEFINER` only if RLS-bypass on read is genuinely needed. Otherwise prefer `SECURITY INVOKER`.
4. Add an entry to CHANGELOG.md citing the Constitution article(s) it satisfies.
5. CI lint (Phase A.6) will check that any new function in `pg_proc` is registered here.
