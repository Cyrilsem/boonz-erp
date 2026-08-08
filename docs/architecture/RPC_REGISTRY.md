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

| Function                | Writes to                                          | A.5 status                                                                                                                                                                                                                                                                                                                                                                     |
| ----------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `add_new_machine`       | `machines`, `slots`, `slot_lifecycle`, `planogram` | ✅ A.5b — patched 2026-04-26                                                                                                                                                                                                                                                                                                                                                   |
| `repurpose_machine`     | `machines`, `slots`, `slot_lifecycle`, `planogram` | ✅ A.5b — patched 2026-04-26                                                                                                                                                                                                                                                                                                                                                   |
| `toggle_machine_refill` | `machines`                                         | ✅ A.5b — patched 2026-04-26                                                                                                                                                                                                                                                                                                                                                   |
| `set_machine_warehouse` | `machines` (primary/secondary_warehouse_id)        | ✅ new 2026-07-16 (`phasef_machine_warehouse_canonical_writer`) — canonical writer for warehouse mapping. Roles: operator_admin, superadmin, manager. Validates warehouse existence + primary≠secondary + VOX invariant (non-VOX ⇒ primary WH_CENTRAL, also a table CHECK). Articles 1, 4, 8. Closes the gap that let the 2026-07-04 anonymous bulk write mis-map NISSAN/NOVO. |

### Sales & telemetry

| Function                   | Writes to                                                                                                               | A.5 status                                                                                     |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `upsert_daily_sales`       | `sales_history` (Constitution Appendix A: was listed as `daily_sales`; reconciled by Amendment 001)                     | ✅ A.5a — patched 2026-04-26                                                                   |
| `upsert_sales_lines`       | `sales_history` (was listed as `sales_lines`; superseded by `upsert_daily_sales` — verify caller graph before patching) | ✅ A.5b — patched 2026-04-26                                                                   |
| `process_adyen_staging`    | `sales_history` via staging                                                                                             | ✅ A.5b — patched 2026-04-26                                                                   |
| `process_weimi_staging`    | `sales_history` via staging                                                                                             | ✅ A.5b — patched 2026-04-26                                                                   |
| `retry_staging_errors`     | staging tables                                                                                                          | ✅ A.5b — patched 2026-04-26                                                                   |
| `refresh_sales_aggregated` | `sales_history_aggregated` (Constitution Appendix A: was listed as `sales_aggregated`; reconciled by Amendment 001)     | ✅ A.5a — patched 2026-04-26 (now also writes explicit audit row, runs on `*/10 * * * *` cron) |
| `refresh_product_scores`   | `product_scores`                                                                                                        | ✅ A.5b — patched 2026-04-26                                                                   |

### Inventory snapshots

| Function                              | Writes to                                  | A.5 status                   |
| ------------------------------------- | ------------------------------------------ | ---------------------------- |
| `upsert_pod_snapshot`                 | `pod_inventory`                            | ✅ A.5b — patched 2026-04-26 |
| `upsert_aisle_snapshot`               | `pod_inventory`                            | ✅ A.5b — patched 2026-04-26 |
| `upsert_refill_stock_snapshot`        | `warehouse_inventory`                      | ✅ A.5b — patched 2026-04-26 |
| `load_pod_staging_chunk`              | staging                                    | ✅ A.5b — patched 2026-04-26 |
| `auto_decrement_pod_inventory`        | `pod_inventory`, `pod_inventory_audit_log` | ✅ A.5b — patched 2026-04-26 |
| `add_sanity_increment`                | `warehouse_inventory` (sanity adjustments) | ✅ A.5b — patched 2026-04-26 |
| `auto_sanity_check`                   | `warehouse_inventory`                      | ✅ A.5b — patched 2026-04-26 |
| `backfill_dispatch_boonz_product_ids` | `dispatch_lines`                           | ✅ A.5b — patched 2026-04-26 |

### Procurement — NEW 2026-04-27 (extended 2026-05-23 for PRD-001)

| Function                   | Writes to                                                                                                                                                                             | A.5 status                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `create_purchase_order`    | `purchase_orders`, `driver_tasks`, `po_notifications`                                                                                                                                 | ✅ 2026-04-27 — new canonical writer. Replaces FE direct inserts. Uses `po_number_seq` for race-safe numbering. Roles: field_staff, warehouse, operator_admin, superadmin, manager. **2026-06-10 (PRD-1, migration `phasef_proc_block_decommissioned_po_writes`)**: per-line guard before insert — rejects any product where `boonz_product_block_reason()` is non-NULL (all `supplier_products` rows Inactive never-order). No service-role bypass; applies to every role. Error names the rule + product. Otherwise rebuilt verbatim from the live body. Cody-reviewed (Articles 1, 4, 12). **2026-06-11 (PRD-022 DF1, migration `prd022_df1_po_number_allocation`)**: po_number allocation hardened - after `nextval('po_number_seq')` a skip-used loop advances past any already-present number (self-heals sequence drift). Paired with `setval` resync + `BEFORE INSERT` trigger `trg_po_number_one_po_id` (a brand-new po_id cannot claim a po_number owned by a different po_id; skips same-po_id multi-line + D3b appends). Cody-reviewed (Articles 1, 4, 12).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `receive_purchase_order`   | `purchase_orders`, `warehouse_inventory`, `po_additions`, `inventory_audit_log`                                                                                                       | ✅ 2026-04-27 — new canonical writer. Fixes B-2 (no duplicate PO lines for multi-batch), B-3 (warehouse_inventory no longer written from FE), B-4 (po_additions fully received + inventoried). Roles: warehouse, operator_admin, superadmin, manager.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `edit_purchase_order_line` | `purchase_orders` (UPDATE: ordered_qty, price_per_unit_aed, total_price_aed, expiry_date, last_edited_at, last_edited_by), `procurement_events` (`po_line_edited`), `write_audit_log` | ✅ 2026-05-23 (PRD-001) — sole canonical UPDATE writer for the three editable PO-line fields. SECURITY DEFINER, role gate on `warehouse / operator_admin / superadmin / manager`. Required reason ≥10 chars. No-op edit guard (rejects when all three fields already match). Coherence guard: `ordered_qty < received_qty` is rejected with a "reverse receipt first" message. **Dual-write audit**: every edit lands in both `procurement_events` (event_type='po_line_edited', primary read path) AND `write_audit_log` (Article 8). Args: `p_po_line_id uuid, p_new_ordered_qty numeric DEFAULT NULL, p_new_price_per_unit_aed numeric DEFAULT NULL, p_new_expiry_date date DEFAULT NULL, p_reason text`. NULL params = "no change to that field" (current value preserved via COALESCE). Cody-reviewed (Articles 1, 4, 5, 7, 8). **2026-05-25 (PRD-002, migration `phaseF_proc_edit_po_line_received_lock`)**: added received-state guard — lines with `received_qty > 0` OR `purchase_outcome = 'received'` are now superadmin-only (other roles get `line is already received; only superadmin can edit` raise). New `lock_level` field (`'received'` \| `'unreceived'`) recorded in `procurement_events.payload`, `write_audit_log.payload`, and the function's return jsonb so the audit history can differentiate normal edits from superadmin overrides. No signature change. Cody re-reviewed (Articles 1, 4, 5, 8, 12). **2026-06-10 (PRD-1, migration `phasef_proc_block_decommissioned_po_writes`)**: added blocked-product guard right after the line is locked — if `boonz_product_block_reason(boonz_product_id)` is non-NULL the edit is rejected for every role **except** `superadmin` (CS carve-out; removal otherwise via `cancel_po_line`). PRD-002 received-lock + `lock_level` preserved (rebuilt from live body). Cody-reviewed (Articles 1, 4, 12). **2026-07-18 (PRD-103, migration `prd103_edit_po_line_expiry_unlock_post_receipt`)**: received-line lock relaxed — `warehouse`/`operator_admin`/`manager` may now correct the **EXPIRY DATE only** on a received line (qty/price stay superadmin-only). New `post_receipt_expiry_edit` boolean in `procurement_events.payload`, `write_audit_log.payload` and return jsonb. Coherence guard `ordered_qty < received_qty` now only fires when qty is actually being changed. Rebuilt from live body (PRD-1 block guard preserved). Cody-reviewed (Articles 1, 4, 5, 6, 8, 12). |
| `cancel_po_line`           | `purchase_orders` (UPDATE: `purchase_outcome='not_purchased'`, last*edited*\*), `driver_tasks` (UPDATE `notes`), `procurement_events` (`line_not_purchased`), `write_audit_log`       | ✅ PRD-001b — sole canonical cancel writer. SECURITY DEFINER, role gate `warehouse/operator_admin/superadmin/manager`, reason ≥10 chars, refuses received lines. Dual audit. **2026-06-11 (PRD-022 DF2, migration `prd022_df2_cancel_regenerates_driver_notes`)**: after the cancel UPDATE, rebuilds `driver_tasks.notes` for the PO's still-actionable task (status pending/acknowledged) from remaining non-cancelled lines so drivers stop seeing cancelled products; `(all lines cancelled)` fallback. Touches `notes` only, never `status`. Cody-reviewed (Articles 1, 4, 8, 12).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `add_purchase_order_lines` | `purchase_orders` (INSERT lines), `driver_tasks` (UPDATE `notes`), `procurement_events` (`lines_appended`), `write_audit_log`                                                         | ✅ 2026-06-11 (PRD-022 D3b, migration `prd022_d3b_add_purchase_order_lines`). **Owner-only** (operator_admin/superadmin) writer appending lines to an existing OPEN PO. Reuses the PO po_number/supplier_id/purchase_date; identical line validation to create (boonz_product_id, ordered_qty>0, `boonz_product_block_reason` check, no bypass); refuses fully-received/cancelled POs; regenerates `driver_tasks.notes` (DF2); dual audit. The **2nd and final INSERT path** on purchase_orders alongside `create_purchase_order`, disjoint by precondition (create rejects an existing po_id, append requires one). DF1 trigger skips it (existing po_id). Dara chose Option B (sibling writer); Cody-reviewed (Articles 1, 4, 8, 12; "two INSERT writers is the ceiling").                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |

### Inventory control session and attempts — NEW 2026-05-24 (PRD-Phase-G P1)

| Function                                                                                                                                                                                                 | Writes to                                                                                                                                         | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `inactivate_warehouse_row(p_wh_inventory_id uuid, p_reason text, p_inactivated_by uuid DEFAULT NULL)`                                                                                                    | `warehouse_inventory` (UPDATE status Active->Inactive)                                                                                            | ✅ 2026-05-24 (Phase G P1 / PRD B.2). NEW canonical writer for the Active->Inactive transition. SECURITY DEFINER, role gate on `warehouse / operator_admin / superadmin / manager`. Refuses when current status != 'Active', when `warehouse_stock > 0 OR consumer_stock > 0`, or when `reserved_for_machine_id IS NOT NULL`. Sets `app.via_rpc` + `app.rpc_name` so the warehouse_inventory audit trigger captures the transition. Companion to `reactivate_warehouse_row` (which still owns Inactive->Active). Amendment 005 narrow-concern writer. Cody-reviewed (Articles 1, 4, 5, 6, 7, 8). |
| `start_inventory_session(p_scope_warehouse_id uuid, p_scope_product_ids uuid[] DEFAULT NULL, p_session_slug text DEFAULT NULL, p_started_by uuid DEFAULT NULL)`                                          | `inventory_control_session` (INSERT new; UPDATE auto-close prior open session for same user)                                                      | ✅ 2026-05-24 (Phase G P1 C.3). Opens an inventory-control sitting. Auto-aborts any prior `status='open'` session for the same user so the partial-unique-on-(started_by) WHERE open index is never violated. SECURITY DEFINER, role gate same as #1. Returns `{session_id, session_slug, scope_warehouse_id, status}`.                                                                                                                                                                                                                                                                          |
| `close_inventory_session(p_session_id uuid, p_closed_by uuid DEFAULT NULL, p_summary jsonb DEFAULT NULL)`                                                                                                | `inventory_control_session` (UPDATE status open->closed, closed_at, summary)                                                                      | ✅ 2026-05-24 (Phase G P1 C.3). Closes the session, auto-computes summary from `inventory_control_attempt` rows (attempt_total / success_count / failure_count / by_result / distinct_products / distinct_rows), merges caller-supplied jsonb on top. Refuses if session is not open.                                                                                                                                                                                                                                                                                                            |
| `attempt_inventory_correction(p_session_id, p_wh_inventory_id, p_new_warehouse_stock, p_reason, p_client_correlation_id, p_attempted_by DEFAULT NULL)`                                                   | `inventory_control_attempt` (INSERT one terminal-state row); delegates to `apply_inventory_correction` for the actual `warehouse_inventory` write | ✅ 2026-05-24 (Phase G P1 C.3). Logging wrapper around `apply_inventory_correction`. Uses PL/pgSQL BEGIN/EXCEPTION as implicit SAVEPOINT; classifies failures by SQLSTATE into `blocked_rls / blocked_trigger / validation_error / rpc_error`. **Option Y append-only**: writes exactly one attempt row in the terminal state. Returns `{attempt_id, result, rpc_response, error}` to FE; never raises.                                                                                                                                                                                          |
| `attempt_reactivate_row(p_session_id, p_wh_inventory_id, p_new_warehouse_stock, p_reason, p_client_correlation_id, p_attempted_by DEFAULT NULL, p_source_doc, p_new_expiration_date, p_new_wh_location)` | `inventory_control_attempt`; delegates to `reactivate_warehouse_row`                                                                              | ✅ 2026-05-24 (Phase G P1 C.3). Same shape as `attempt_inventory_correction`. `field_changed='status'`, `rpc_called='reactivate_warehouse_row'`.                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `attempt_status_change(p_session_id, p_wh_inventory_id, p_new_status, p_reason, p_client_correlation_id, p_attempted_by DEFAULT NULL, p_new_warehouse_stock DEFAULT NULL)`                               | `inventory_control_attempt`; delegates to `reactivate_warehouse_row` (Inactive->Active) or `inactivate_warehouse_row` (Active->Inactive)          | ✅ 2026-05-24 (Phase G P1 C.3). Toggle wrapper that picks the right canonical writer based on current and target status. No-op or unsupported transitions are captured as `validation_error`. Records the routed RPC name in `rpc_called`.                                                                                                                                                                                                                                                                                                                                                       |

### Refill engine — UPDATED 2026-05-04

| Function                    | Writes to                                                                                                                      | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `auto_generate_refill_plan` | `refill_plan_output`, `refill_dispatching` (via `write_refill_plan`), `shelf_configurations` (via `seed_shelf_configurations`) | ✅ **UPDATED 2026-05-04 (RPC A)** — added `p_machines text[]` param. When provided: bypasses health triage + LIMIT 10, processes exactly the listed machines. Auto-calls `seed_shelf_configurations` for machines with 0 shelf configs. Preserves packed dispatching rows. Args: `p_filter text`, `p_plan_date date`, `p_dry_run boolean`, `p_machines text[]`. **DEPRECATED 2026-07-04 (PRD-074, Article 13): INVOKER + execute revoked; zero callers; use the refill brain (write_refill_plan pipeline / refill-engine). DROP eligible 2026-10-04.** |

### Refill plan + dispatch — UPDATED 2026-05-04

| Function                                                                                                                                                | Writes to                                                                        | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `approve_refill_plan`                                                                                                                                   | `refill_plan_output` (status→approved), `refill_dispatching`                     | ✅ **UPDATED 2026-05-04 (RPC E)** — loud errors. Pre-approve diagnostics detect missing shelf_configs, unmatched products, unmatched machines. Returns `alerts` jsonb array. Preserves packed dispatching rows (`AND packed=false` guard). Dispatch gap detection: warns when `rows_approved > dispatching_rows_written`. Args: `p_plan_date date, p_machine_names text[]`. Roles: operator_admin, superadmin, manager. Articles 1, 3, 4, 5, 8, 12.                                                                                                                                                                                                                                                                                                                                                          |
| `write_refill_plan`                                                                                                                                     | `refill_plan_output`                                                             | ✅ **UPDATED 2026-05-04 (RPC B)** — scoped delete. Extracts distinct machine_names from `p_lines` jsonb; only deletes pending rows for those machines (was: all pending for date). Returns `machines_affected` array. Articles 1, 4, 8, 12.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `override_refill_quantity`                                                                                                                              | `refill_plan_output`                                                             | ✅ **NEW 2026-05-04 (RPC C)** — operator quantity override. Updates pending REFILL/ADD NEW rows for a specific machine+shelf. Multi-variant: proportional redistribution. Args: `p_plan_date date, p_machine_name text, p_shelf_code text, p_new_quantity int`. Roles: operator_admin, superadmin, manager. Articles 1, 4, 5, 8, 12.                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `inject_swap`                                                                                                                                           | `refill_plan_output`, `refill_dispatching`                                       | ✅ **NEW 2026-05-04 (RPC D)** — inject swap into live plan. Inserts REMOVE + ADD NEW rows as `approved`, creates dispatching rows. Preserves packed rows (`AND packed=false` guard). Validates machine, shelf_config, pod_product, boonz_product existence. Args: `p_plan_date date, p_machine_name text, p_shelf_code text, p_remove_pod_product text, p_add_pod_product text, p_add_boonz_product text, p_add_quantity int, p_comment text`. Roles: operator_admin, superadmin, manager. Articles 1, 4, 5, 8, 12.                                                                                                                                                                                                                                                                                          |
| `seed_shelf_configurations`                                                                                                                             | `shelf_configurations`                                                           | ✅ **NEW 2026-05-04 (RPC F)** — auto-seed shelf_configurations from `v_live_shelf_stock`. Converts aisle codes (`0-A00`→`A01`). Idempotent via `ON CONFLICT DO NOTHING`. Args: `p_machine_name text`. Roles: operator_admin, superadmin, manager. Articles 1, 4, 8, 12.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `cleanup_orphan_dispatching`                                                                                                                            | `refill_dispatching` (DELETE orphaned rows)                                      | ✅ **NEW 2026-05-04** — deletes unpacked/not-picked-up dispatching rows that have no matching plan row (pending or approved). Scoped by date + optional machine_names. Used after `write_refill_plan` rewrites plan rows to clean stale dispatching. Args: `p_dispatch_date date, p_machine_names text[]`. Roles: operator_admin, superadmin, manager. Articles 1, 4, 8, 12.                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `write_dispatch_plan`                                                                                                                                   | `dispatch_plan`                                                                  | ✅ A.5b — patched 2026-04-26                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `push_plan_to_dispatch`                                                                                                                                 | `dispatch_plan`, `dispatch_lines`                                                | ✅ A.5b — patched 2026-04-26                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `pack_dispatch_line`                                                                                                                                    | `refill_dispatching`, `warehouse_inventory`                                      | ✅ **UPDATED 2026-07-04 (PRD-072 live binding, `prd072_p1_pack_dispatch_line_live_rebind`)** — pre-flight validates every pick (Active, non-quarantined, in-date, pin NULL-or-mine, stock>=qty) and RE-BINDS stale picks live via `v_wh_pickable` FEFO (bind_dispatch_fefo predicate); all-or-nothing; fail-soft `status='bind_failed'` + `refill_dispatching.bind_fail_reason` (no_stock/quarantined/inactive_batch/pinned_elsewhere) + `bind_fail_at`; no longer writes the whole-remainder `reserved_for_machine_id` pin (stock move is the qty-scoped commitment; `release_stale_wh_pins` cron 34 sweeps legacy pins). Successful pack / not_filled clears bind_fail state. Known gap (pre-existing, ticketed): no Article-4 role gate. Prior: A.5b patch 2026-04-26, PRD-028 guards, PRD-030 not_filled |
| `reweight_pod_splits(text,text,jsonb,text,bool,bool)`                                                                                                   | `product_mapping` (per-machine split_pct + synced mix_weight), `write_audit_log` | ✅ NEW 2026-07-04 (PRD-073, `prd073_reweight_pod_splits`). Recommendation-driven weekly reweight: rec flavors proportional x0.90, other mapped flavors share 0.10, sum=100 asserted post-write. `p_dry_run` DEFAULT true (Gate-1 table); `p_rebuild` required for broken-sum pods and creates recommended-but-unmapped flavors. Roles: operator_admin/superadmin/manager (NULL uid = trusted server-side). Machines: Active or Warehouse. Articles 1,4,7,8,12. Dara+Cody ✅.                                                                                                                                                                                                                                                                                                                                 |
| `check_provenance_reason_registry()`                                                                                                                    | read-only (pg_proc vs wh_provenance_reason_enum)                                 | ✅ NEW 2026-07-04 (PRD-072 P3). INVOKER drift detector: every set_config('app.provenance_reason', literal) in public functions must be registered in the CHECK constraint; rows with registered=false are runtime-failing drift. Run in health checks; migration apply asserts once.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `get_machine_health()`                                                                                                                                  | read-only (WEIMI agg + canonical pass-through)                                   | ✅ **v3 2026-07-04 (PRD-074, `prd074_p1_health_v3_stale_v2_canonical_clocks`)**: days_since_visit = canonical v_machine_health_signals clock (executed dispatch); old approved-plan MAX renamed to APPENDED keys last_plan_date/last_plan_days; +urgency_breakdown jsonb (pts sum == v_machine_priority.urgency; core term lumped until the view exposes s_runout/s_capacity/s_expiry/s_stale) +reasons_arr. All 32 prior keys kept; sole consumer refill/page.tsx (grep-proofed). WEIMI-direct remainder (no canonical or deliberately kept): total_stock, max_capacity, total_slots, slots_at_zero, slots_below_25pct, fill_pct, has_sensor_errors, dead_stock_count, local_hero_count, revenue label/strategy.                                                                                            |
| `get_stale_visit_signals()`                                                                                                                             | read-only (v_machine_health_signals)                                             | ✅ **v2 2026-07-04 (PRD-074)**: thin SELECT over the signals view; threshold = pick_urgency_params.stale_override_days; output names kept for SignalsTab. Approved-plan definition + private >10 literal retired.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `check_priority_surface_consistency()`                                                                                                                  | read-only (get_machine_health vs canonical views)                                | ✅ NEW 2026-07-04 (PRD-074 P2). Per-machine diffs on visit clock / score / tier / track / breakdown-sum for Active machines; zero rows = consistent. Run after any priority-surface change.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `refill_qa.capture_run(date,text)`                                                                                                                      | writes refill_qa.plan_run/_row (branch-only; refuses on prod)                    | ✅ NEW 2026-07-07 (PRD-076). Runs build_draft_for_confirmed on a preview branch, snapshots pod_refill_plan into the QA store with engine+input fingerprints. SECURITY DEFINER, guarded by GUC refill_qa.on_branch.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `refill_qa.diff_runs(uuid,uuid,uuid[])` / `refill_qa.diff_run_rows(...)`                                                                                | read-only (refill_qa)                                                            | ✅ NEW 2026-07-07 (PRD-076). Pure-SELECT shadow-diff referee: row-level classification + fleet/per-machine aggregates + identical/inputs_differ. The output-level regression gate for PRD-079..085.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `refill_qa.conservation_check(date,uuid,text)`                                                                                                          | read-only (wraps check_pod_conservation + v_wh_pickable)                         | ✅ NEW 2026-07-07 (PRD-077). Plan-level conservation pass/fail gate: orphan_removal (a) + phantom/oversubscribed batch (b/c, dispatch layer). absolute/delta modes vs refill_qa.conservation_baseline. Mandatory gate for PRD-079..085.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `refill_qa.diff_vs_golden(uuid,text)`                                                                                                                   | read-only (refill_qa)                                                            | ✅ NEW 2026-07-07 (PRD-078). Scopes diff_runs to the golden fixture machines. golden_v1 = frozen committed plan (run 9eb2d050). Candidate capture pending branch-data decision.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `refill_qa.check_prepack_drift(date,uuid[])`                                                                                                            | read-only (dispatch vs v_live_shelf_stock)                                       | ✅ NEW 2026-07-07 (PRD-084 advisory). Per dispatch line: planned pod vs live WEIMI; ok/sku_mismatch/weimi_unresolved/allowed_multi_sku; multi_sku_shelf allowlist. Block tier parked (protected).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `v_shelf_expiry_risk`                                                                                                                                   | read-only (v_pod_inventory_latest+slot_lifecycle)                                | ✅ NEW 2026-07-09 (PRD-091 signal). Per-shelf on-machine expiry risk. Consumed by PRD-095.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `approve_return` / `reject_return` / `cron_pending_return_alert` / `return_approval_log` / `v_pending_return_approvals` / `v_pending_legacy_quarantine` | warehouse_inventory (provenance flip / drain+inactivate) + append-only log       | ✅ NEW 2026-07-10 (PRD-098). Manager return-approval. Sanctioned warehouse_stock/provenance writers (Art 1); Art-6 clean (reject via inactivate_warehouse_row).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `compute_nowh_proposals(date)` / `refill_action_proposals`                                                                                              | writes side-table only (DEFINER)                                                 | ✅ NEW 2026-07-09 (PRD-092). blocked_no_wh -> substitute/m2m/procurement proposals. Standalone, not engine-called.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `refill_qa.check_approved_preserved(date)`                                                                                                              | read-only (pod_refill_plan)                                                      | ✅ NEW 2026-07-07 (PRD-085). Regression monitor: 0 defect_rows = finalize preserves approved (PRD-025).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `refill_qa.flag(text)` / `refill_qa.feature_flag`                                                                                                       | read-only flag store                                                             | ✅ NEW 2026-07-07 (PRD-083). Wave-0 feature flags (engine_single_path/wh_gate_v2/qty_split_v1/pack_guard/fefo_reserve_v1).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `wh_is_pickable(uuid,uuid,date)` / `v_wh_stock_state`                                                                                                   | read-only (warehouse_inventory)                                                  | ✅ NEW 2026-07-07 (PRD-079). Canonical WH pickability predicate (Art 16) + held-state view. engine_add_pod unification parked.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `pack_dispatch_line` (modified)                                                                                                                         | refill_dispatching (canonical pack writer)                                       | 🔶 2026-07-07 (PRD-082 DARK). Flag qty_split_v1 gates quantity overwrite vs preserve. Off=current. Enable parked (FE repoint + settlement re-check).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `tg_enforce_pack_via_rpc` / `refill_pack_bypass_log`                                                                                                    | trigger on refill_dispatching + audit log                                        | ✅ NEW 2026-07-07 (PRD-081 WARN). Pack-state flips only via sanctioned pack RPC; bypasses logged. ENFORCE parked.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `wh_reservation` / `bind_fefo_reserved` / `release_fefo_reservation`                                                                                    | wh_reservation (new, dark)                                                       | ✅ NEW 2026-07-07 (PRD-080 DARK). FEFO soft holds; no-op when fefo_reserve_v1 off. Enable parked (Ops TTL + Article-14 dual-mechanism).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Family-B: `orchestrate_refill_plan`,`propose_add_plan`,`propose_swap_plan`,`engine_publish_to_refill_plan`,`reconcile_intent_progress`                  | refill_plan_output/pod_refill_plan                                               | ⛔ DEPRECATED 2026-07-07 (PRD-083, Article 13). RAISE-redirect under engine_single_path='deprecate'. Orphan island (0 callers). DROP parked 90d. Use Family A (build_draft_for_confirmed pipeline).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `receive_dispatch_line`                                                                                                                                 | `refill_dispatching`, `warehouse_inventory`, `pod_inventory`                     | ✅ **UPDATED 2026-05-31** (PRD-016B Migration 2, `phaseF_prd016_unverified_return_provenance`) — create-new-batch ELSE branches (`RETURN-%`, `REMOVE-RECEIVE-%`) now stamp `provenance_reason='dispatch_return_unverified'` (→ `quarantined=true`) immediately before the INSERT and restore `dispatch_receive` after; merge paths stay trusted. Prior 2026-05-18: M2M-aware early branch (is_m2m skips WH ops); 2026-05-11 REMOVE handling (BUG 3 fix).                                                                                                                                                                                                                                                                                                                                                     |
| `receive_all_dispatches_for_machine`                                                                                                                    | `dispatch_lines`, `pod_inventory`                                                | ✅ A.5b — patched 2026-04-26                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `return_dispatch_line`                                                                                                                                  | `refill_dispatching`, `warehouse_inventory`, `pod_inventory`                     | ✅ **UPDATED 2026-05-31** (PRD-016B Migration 2, `phaseF_prd016_unverified_return_provenance`) — create-new-batch ELSE branches (`REMOVE-RETURN-%`) now stamp `provenance_reason='dispatch_return_unverified'` (→ `quarantined=true`) immediately before the INSERT and restore `dispatch_return` after; merge-into-existing paths stay trusted. Prior 2026-05-11: BUG 1 fix (REMOVE uses ABS(quantity)); BUG 2 fix (removed phantom-WH-credit fallback ELSE); archives pod for REMOVE.                                                                                                                                                                                                                                                                                                                      |
| `return_all_dispatches_for_machine`                                                                                                                     | `dispatch_lines`, `warehouse_inventory`                                          | ✅ A.5b — patched 2026-04-26                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |

> **Count check:** 26 listed above. The verified count is 25 — re-verify when patching A.5 (one of these may be a read-only helper that was misclassified, or two may be aliases). The Cody skill carries the canonical list as a JSON artifact in `cody/canonical_rpcs.json`.

### Warehouse-status propose-then-confirm — NEW 2026-05-04

| Function                                        | Writes to                                                                                     | Status                                                                                                                                                                                       |
| ----------------------------------------------- | --------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `confirm_warehouse_status_proposal(uuid, text)` | `warehouse_inventory` (status flip), `warehouse_inventory_status_proposal` (status→confirmed) | ✅ NEW 2026-05-04 — canonical confirm path. Roles: warehouse, operator_admin, superadmin, manager. Drift detection marks proposal `superseded` if live status diverged. Articles 1, 4, 5, 8. |
| `reject_warehouse_status_proposal(uuid, text)`  | `warehouse_inventory_status_proposal` (status→rejected)                                       | ✅ NEW 2026-05-04 — canonical reject path. `warehouse_inventory.status` is NOT modified. Roles: warehouse, operator_admin, superadmin, manager. Articles 1, 4, 5, 8.                         |

### Inventory operations — NEW 2026-05-04

| Function                                                  | Writes to                                                                                                            | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `transfer_warehouse_stock(uuid, uuid, jsonb, date, text)` | `warehouse_inventory` (source decrement + dest increment/insert), `inventory_audit_log` (both sides)                 | ✅ NEW 2026-05-04 — canonical inter-warehouse transfer. FIFO: picks oldest-expiry batches from source. Cold storage validation. Splits across batches if needed. Creates dest rows on first transfer. Args: `p_source_warehouse_id, p_dest_warehouse_id, p_lines [{boonz_product_id, qty, expiration_date}], p_transfer_date, p_reason`. Roles: warehouse, operator_admin, superadmin, manager. Articles 1, 4, 6, 8.                                                                                                                                                                                       |
| `log_manual_refill(text, uuid, date, jsonb, text)`        | `warehouse_inventory` (source decrement), `pod_inventory` (insert), `inventory_audit_log`, `pod_inventory_audit_log` | ✅ NEW 2026-05-04 — retroactive manual refill recording. FIFO warehouse decrement. Continues on WH shortfall (backlog cleanup — physical refill already happened). Args: `p_machine_name, p_source_warehouse_id, p_refill_date, p_lines [{shelf_code, boonz_product_id, qty, expiration_date}], p_reason`. Roles: warehouse, operator_admin, superadmin, manager. Articles 1, 4, 8.                                                                                                                                                                                                                        |
| `adjust_pod_inventory(text, date, jsonb, text)`           | `pod_inventory` (update or insert), `pod_inventory_audit_log`                                                        | ✅ NEW 2026-05-04 — manual pod inventory correction + FIFO cleanup. Matches existing rows by (machine, shelf, product, expiry). Updates current_stock, marks Depleted when qty=0 (no DELETE). Supports batch-level FIFO: multiple lines per shelf with different expiry dates. Args: `p_machine_name, p_snapshot_date, p_lines [{shelf_code, boonz_product_id, new_qty, expiration_date, batch_id}], p_reason`. Roles: warehouse, operator_admin, superadmin, manager. Articles 1, 4, 5, 8.                                                                                                                |
| `adjust_warehouse_stock(uuid, jsonb, date, text)`         | `warehouse_inventory` (update or insert), `inventory_audit_log`                                                      | ✅ NEW 2026-05-04 — physical count reconciliation for warehouse inventory. Matches existing rows by `wh_inventory_id` or `(warehouse, product, expiry)`. Updates stock + consumer_stock + expiration_date + batch_id + status. Inserts new rows when no match. Unchanged-check includes expiry comparison (catches expiry-only corrections). Args: `p_warehouse_id, p_lines [{wh_inventory_id?, boonz_product_id, new_warehouse_stock, new_consumer_stock, expiration_date?, batch_id?, status?}], p_snapshot_date, p_reason`. Roles: warehouse, operator_admin, superadmin, manager. Articles 1, 4, 5, 8. |

### Pickup — NEW 2026-05-04

| Function                 | Writes to                                                      | Status                                                                                                                                                                                                                                                                                                                                       |
| ------------------------ | -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `mark_picked_up(uuid[])` | `refill_dispatching` (picked_up=true on packed=true rows only) | ✅ NEW 2026-05-04 — canonical pickup path. Replaces direct FE `refill_dispatching` UPDATE in `field/pickup/page.tsx`. Roles: field_staff, warehouse, operator_admin, superadmin, manager. Returns counts + skipped IDs (already picked up / not packed / not found). Articles 1, 3, 4, 5, 8. **Dormant** until tonight's FE deploy wires it. |

### Pod inventory edits canonical approval — NEW 2026-05-25 (PRD-013)

Unified writer for all five `pod_inventory_edits` edit_types. Supersedes the per-edit_type FE dispatch that silently left 23 pod rows Active despite operator-approved 'expired' edits. PRD-012's `approve_pod_inventory_add` and `reject_pod_inventory_add` are now thin shims forwarding here; Article 13 sunset 2026-08-25.

| Function                                                                                            | Writes to                                                                                                      | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `approve_pod_inventory_edit(uuid, uuid, text, boolean)`                                             | `pod_inventory_edits` (status→approved), `pod_inventory` (per dispatch), `warehouse_inventory` (return branch) | ✅ NEW 2026-05-25 — canonical 5-edit_type dispatch (`expired`, `sold`, `partial_sold`, `return_to_warehouse`, `add_new_product`) per PRD-013 §D2. SELECT FOR UPDATE on edit + pod row. For `return_to_warehouse` with no matching wh row, INSERTs with `status='Inactive'` (Article 6 spirit — warehouse manager promotes via m2 propose-then-confirm). Raises on `machines.primary_warehouse_id IS NULL`. C.6 inventory_control_session attribution (Amendment 009). Roles: operator_admin, superadmin, manager. Articles 1, 4, 5, 6, 8. Cody ✅. |
| `reject_pod_inventory_edit(uuid, text, uuid)`                                                       | `pod_inventory_edits` (status→rejected)                                                                        | ✅ NEW 2026-05-25 — any edit_type. Requires decision_note ≥ 10 chars. No pod or warehouse_inventory writes. Roles: operator_admin, superadmin, manager. Articles 1, 4, 5, 8. Cody ✅.                                                                                                                                                                                                                                                                                                                                                              |
| `backfill_archive_pod_inventory_row(uuid, text, uuid, uuid)`                                        | `pod_inventory` (status→Inactive, stock=0, est=0, removal_reason)                                              | ✅ NEW 2026-05-25 (PRD-013 P2.C) — backlog-cleanup helper. Gated to superadmin + operator_admin. `p_reason` min 10 chars. FOR UPDATE lock. Idempotent (RAISE NOTICE on already-Inactive). Used once on 2026-05-25 to archive 9 stuck pod rows. Stays available for future ad-hoc backfills under per-row CS sign-off. Articles 1, 4, 8, 12. Cody ✅ (F1 — p_reason 5→10 chars).                                                                                                                                                                    |
| `auto_expire_pod_inventory_edits()`                                                                 | `pod_inventory_edits` (status pending→expired, reviewed_at, notes append)                                      | ✅ NEW 2026-05-25 (PRD-013 P3.D) — pg_cron `pod_inventory_edits_auto_expire` at 22:30 UTC daily (02:30 Dubai). All five edit_types. `REVOKE ALL FROM public` (cron daemon + service_role only). 30-minute gap after PRD-012 `pod_add_proposals_auto_expire` (22:00 UTC) keeps the two race-free. Article 1 follow-up filed to deprecate PRD-012's cron in 90 days. Articles 1, 4, 5, 8, 11, 12. Cody ✅.                                                                                                                                           |
| `approve_pod_inventory_add(uuid, uuid, text, boolean)` / `reject_pod_inventory_add(uuid,text,uuid)` | (forwards to the PRD-013 unified RPCs)                                                                         | ⚠️ DEPRECATED 2026-05-25 — thin shims that emit `RAISE NOTICE 'DEPRECATED'` and forward. Sunset 2026-08-25 (90-day Article 13 monitor window). Do not extend; do not call from new code.                                                                                                                                                                                                                                                                                                                                                           |

### Machine-to-machine transfers — NEW 2026-05-18

| Function                                                    | Writes to                                                                                                                                              | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `swap_between_machines(uuid, uuid, jsonb, date, text)`      | `refill_dispatching` (INSERT paired Remove+Add New with is_m2m=true), `pod_inventory` (UPDATE source decrement + UPSERT dest increment)                | ✅ NEW 2026-05-18 — canonical M2M transfer writer. Creates matched dispatch pair born packed=true+dispatched=true (zero WH stock movement). Adjusts pod_inventory on both machines atomically. Net-zero guaranteed. Validates: different machines, source stock sufficiency, qty > 0, caller role (operator_admin/superadmin/manager). Sets app.via_rpc. Returns transfer_id + item details. Articles 1, 4, 8, 12. Dara-designed, Cody-reviewed.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `convert_removes_to_m2m_transfer(uuid[], uuid, uuid, text)` | `refill_dispatching` ONLY (UPDATE source Removes -> is_m2m=true + INSERT paired dest Add New)                                                          | ✅ NEW 2026-06-23 (PRD-052, migration `prd052_convert_removes_to_m2m_transfer`). Retroactive remediation: converts EXISTING dispatched plain Removes into a paired M2M transfer (shared `m2m_transfer_id`, bidirectional `m2m_partner_id`, `from_warehouse_id` NULL, qty=COALESCE(driver_confirmed_qty,quantity); sets `source_machine_id`+`source_kind='m2m'` to satisfy `m2m_consistency`; dest born packed+dispatched+picked_up=false). Does NOT touch pod_inventory/warehouse_inventory (both machines reconcile from WEIMI; physical move already done — divergence from `swap_between_machines` which adjusts pods). Validates: non-empty, all exist + action=Remove + one source machine + item_added/cancelled/returned=false + is_m2m=false (idempotency raise) + dest machine/shelf. Role: `auth.uid() IS NULL` (trusted server-side remediation) OR operator_admin/superadmin/manager. Sets app.via_rpc+app.rpc_name; added to `enforce_canonical_dispatch_write` allowlist. GRANT authenticated, service_role. Articles 1, 4, 6, 8, 12, 14. Dara+Cody ✅. First run: transfer_id `1538f35f…`, 7 NOVO-1023 VW -> MINDSHARE-1009 A16, 11u, zero WH credit. |
| `acknowledge_m2m_transfer(uuid)`                            | `refill_dispatching` (UPDATE wh_approved_at/wh_approved_by on M2M rows)                                                                                | ✅ NEW 2026-05-18 — WH manager acknowledgment for M2M transfers. No stock movement. Roles: warehouse, operator_admin, superadmin, manager. Sets app.via_rpc. Articles 1, 4, 8.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `approve_m2m_transfer(uuid, uuid)`                          | `refill_dispatching` (UPDATE wh_approved + m2m_approved stamps) via `receive_dispatch_line` on both legs (source pod OUT, dest pod IN same qty+expiry) | ✅ NEW 2026-07-01 (PRD-070) — canonical atomic+idempotent M2M approve. Locks all is_m2m legs sharing m2m_transfer_id, validates source Remove qty == dest Add/Refill qty, runs receive_dispatch_line on both (ZERO warehouse credit), stamps wh_approved+m2m_approved, asserts warehouse_stock before==after. Roles: warehouse/operator_admin/superadmin/manager. Sets app.via_rpc/via_trigger. Articles 1,3,4,6,8,12. Dara-designed, Cody-approved. **v2 2026-07-02 (PRD-071 WS-C3, `prd071_wsc3_approve_m2m_normalize_returned_on_approve`):** explicit counted normalize pass (returned=false on not-yet-received dest legs) before receiving - convert-path anomaly fixed at the approve choke point; dispatch_date kept historical (packed-row immutability).                                                                                                                                                                                                                                                                                                                                                                                                   |
| `pair_internal_transfer_m2m(date, uuid)`                    | `refill_dispatching` (UPDATE pairing metadata ONLY: is_m2m, m2m_transfer_id, m2m_partner_id, source_machine_id, source_kind)                           | ✅ NEW 2026-07-01 (PRD-070 D-2) — idempotent flag+pair pass for internal_transfer dispatch legs that push_plan_to_dispatch left unflagged. Acts only on UNAMBIGUOUS 1:1 conserving pairs (sum source out == dest in, same product+date); ambiguous/mismatch skip+logged. Never touches inventory/qty/status -> WH delta 0 by construction. Also the backfill. Roles: operator_admin/superadmin/manager/warehouse. Sets app.via_rpc/via_trigger. Articles 1,3,4,6,8,12. Dara-designed, Cody-approved. **2026-07-02 (PRD-071 WS-B):** now auto-invoked same-txn by push_plan_to_dispatch v7 as a post-loop safety net (failure logs to monitoring_alerts, never fails the push).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |

### Terminal-to-machine history — NEW 2026-05-05

| Function                                                                                                                                                               | Writes to                                                                         | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `register_terminal_move(p_unique_terminal_id text, p_new_machine_id uuid, p_effective_from date, p_attributed_name text, p_attributed_venue_group text, p_notes text)` | `machine_terminal_history` (close open window via UPDATE, then INSERT new window) | ✅ NEW 2026-05-05 — canonical writer for terminal reassignments / machine renames. Validates inputs (NULL guards), FK existence on `machine_id`, role gate (operator_admin or superadmin). Returns `{closed_history_id, new_history_id}` jsonb. Audited via the generic `audit_log_write` trigger. Articles 1, 4, 8. Use whenever a physical Adyen terminal moves between machine_ids or a machine is renamed — downstream attribution views auto-correct. |

### Stage 1 — machine picker (Phase F, 2026-05-11)

| Function | Writes to | Status |
| ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pick_machines_for_refill(p_plan_date date DEFAULT CURRENT_DATE+1)` | `machines_to_visit` (UPSERT one row per machine; supersedes prior pick for the same date) | ✅ NEW 2026-05-11 — Phase F Stage 1 canonical writer. DEFINER, role-gated `operator_admin`, sets `app.via_rpc`. Pure-read of `machines` + `slot_lifecycle` + `refill_dispatching` + `strategic_intents` + `v_live_shelf_stock`. Picks machines on five reasons (health ≥30% bad slots; stale ≥7d since last picked_up; empty ≥20% shelves at 0; active strategic_intent touching machine or fleet-wide; ramping ≤30d since relaunch/first_sale). Priority score 0..100 weighted sum. Sibling expansion via `venue_group` (fallback `building_id`) — once a machine is picked, siblings get pulled in at half thresholds (e.g. dead_slot_pct ≥15, days_since_visit ≥4). Idempotent: re-running supersedes prior pick. Returns set of `(out_machine_id, out_official_name, out_picked_reasons, out_priority_score, out_route_cluster, out_visit_order)` ordered by cluster then priority. **Smoke test 2026-05-12:** 24 machines across 8 clusters. Foundation for Stage 2 (pick products per machine, pod_product level). Articles 1, 4, 5, 8, 12. **Known nit (#17):** sibling-only picks get pri_score=0 because sibling pass doesn't re-score — fix in v5. **UPDATED 2026-06-02 (`phaseF_picker_v7_velocity_shelf_reweight`):** scoring rewritten to a velocity + shelf-weighted two-tier model. severity CASE → `priority_tier` (P1_RESTOCK / P2_MAINTAIN). P1 = any empty shelf (50pts + 12/extra), selling-machine low runway (units_7d≥20 & runway<14d, or runway<7d), or <25% shelf on a seller (units_7d≥15). P2 = dead_slot_pct≥15 / days_since_visit≥14 / expired_now / active_intent (small weights). New CTE `shelf_u25` reads `v_live_shelf_stock` for <25% non-empty count. Two new `machines_to_visit` columns written: `service_track` ('main' | 'vox') + `priority_tier`. VOX scored in same pass but tagged `vox` and ordered below all `main` rows (CS: VOX refilled daily on the spot; parallel track below a dashed separator); VOX excluded from sibling expansion. visit_order now = (track, tier, score). `severity`/`priority_score` still populated (tier→band map) for back-compat. Articles 1, 2, 4, 5, 8, 12. Cody-reviewed (cleared). Identity signature unchanged. Verified 2026-06-03: 30 picks (22 main + 8 vox), ~2.3s. |

### Stage 2a / 2c + Gates (Phase F, 2026-05-11)

| Function | Writes to | Status |
| -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `engine_add_pod(p_plan_date date DEFAULT CURRENT_DATE+1, p_days_cover int DEFAULT 14)` | `pod_refills` (DELETE prior plan_date rows + INSERT new refill drafts) | ✅ NEW 2026-05-11 — Phase F Stage 2a "More of the Best". DEFINER, role-gated operator_admin. Reads machines_to_visit + slot_lifecycle + pod_inventory aggregated at (machine_id, shelf_id) + v_shelf_max_stock + v_warehouse_pod_rollup. Signal-aware sizing: STAR/DOUBLE DOWN fill-to-max; KEEP GROWING/KEEP velocity_30d × days_cover; RAMPING/WATCH velocity × 7 capped at half-max; WIND DOWN/ROTATE OUT/DEAD skipped. All qty capped by (max-current) and WH pod rollup. Idempotent (DELETE+INSERT per plan_date). Default fallback v_default_max=10 when neither shelf_configurations.max_capacity nor v_live_shelf_stock has a value. Smoke 2026-05-12: 124 refills, 417ms. Articles 1, 4, 5, 8, 9, 12. **UPDATED 2026-06-22 (PRD-048, `prd048_c_engine_add_pod_v19_base_stock`):** v18→v19. Flag-gated on `refill_policy_params.refill_sizing_mode` (`legacy` | `base_stock`, default `legacy`). `legacy` = byte-identical to v18 (gate-clean md5 `26bfe216…`, 78 rows). `base_stock` sizes via service-level order-up-to S (calls pure `compute_base_stock_decision`); `covered`/`flagged` CTEs only; allocated/final/dead/stitch handoff unchanged. Inputs: `machine_service_policy.trip_interval_days` (T), margin-tier z (`v_current_price`+`v_product_landed_cost`), FEFO shelf-life via canonical `v_product_shelf_life` (`prd048_e`; Art-16 closed). Units fix `prd048_f`: velocity_7d/30d are DAILY rates, engine passes v7*7/v30*30 to the window-total helper. **ENABLED 2026-06-22 (base_stock, global; nightly draft human-gated FE 1+2)**. Cold-start (RAMPING/new slot) seeded, not dead-zeroed. NOT enabled (flag OFF). Article 16 (canonical refill-qty object). |
| `engine_finalize_pod(p_plan_date date DEFAULT CURRENT_DATE+1)` | `pod_refill_plan` (UPSERT draft rows; supersedes prior drafts for plan_date) | ✅ NEW 2026-05-11 — Phase F Stage 2c. Reads pod_refills + pod_swaps, writes pod_refill_plan (status='draft'). R4 conflict rule: swap-touched shelves invalidate refills on the same shelf (anti-join). Emits 4 action types: REFILL, REMOVE, ADD_NEW, M2W. R7 60% shelf cap surfaced as diagnostic only at this stage. Diagnostics: rows_finalized, refills_in, swaps_in, r4_overruled_refills, r7_machines_over_60pct, duration_ms. Articles 1, 4, 5, 8, 12. |
| `approve_pod_refill_plan(p_plan_date date, p_machine_names text[] DEFAULT NULL)` | `pod_refill_plan` (UPDATE: status draft → approved + approved_at + approved_by) | ✅ NEW 2026-05-11 — Phase F Gate 1. Optional p_machine_names filter for partial approval (NULL = all draft rows). After this gate, Stage 3 Stitch becomes eligible to run. DEFINER, role-gated operator_admin. Articles 1, 4, 5, 8. |
| `reject_pod_refill_rows(p_plan_date date, p_machine_names text[], p_reason text)` | `pod_refill_plan` (UPDATE: status draft → superseded + rejection_reason in reasoning jsonb) | ✅ NEW 2026-05-11 — Phase F Gate 1 reject path. Mandatory reason captured in reasoning jsonb. Operator-admin only. Articles 1, 4, 5, 8. |
| `confirm_stitched_plan(p_plan_date date)` | `pod_refill_plan` (UPDATE: status approved → stitched + stitched_at) | ✅ NEW 2026-05-11 — Phase F Gate 2. Called by Stage 3 (stitch_pod_to_boonz, not yet built) after refill_plan_output rows are successfully written. Operator-admin or service_role. Articles 1, 4, 5, 8. |

### Refill sizing helper — read-only (PRD-048, 2026-06-22)

| Function                                                                                                                                                                                                      | Writes to   | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `compute_base_stock_decision(p_v7, p_v30, p_oh, p_cap, p_trip_days, p_z, p_shelf_life_days, p_wh_pickable, p_min_fill_pct, p_seller_wk_threshold, p_ewma_w7, p_ewma_w30, p_spoilage_factor, p_is_cold_start)` | (read-only) | ✅ NEW 2026-06-22 (PRD-048, `prd048_b_compute_base_stock_decision` + `prd048_b2_spoilage_dominates_floor`). **Pure scalar**, LANGUAGE sql **IMMUTABLE**, zero table access (all inputs passed) → fully unit-testable. Implements PRD §3 order-up-to S = `mu·T + z·sigma·sqrt(T)`, spoilage-capped (cap dominates the seller floor, §4.5), seller-gated min_fill floor (§4.1), cold-start seed (§4.2), DEAD unchanged. Returns jsonb {mu_day,sigma,S,spoilage_cap,is_seller,is_cold_start,is_dead,floor,target,want,add,reason,…}. Called only by `engine_add_pod` v19 when `refill_sizing_mode=base_stock`. Deliberately a NEW name (not a `compute_refill_decision` overload — CLAUDE.md foot-gun rule). Article 12. |

### Draft orchestrator + reader (Phase F v2, 2026-05-22)

| Function | Writes to | Status |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `auto_generate_draft(p_plan_date date DEFAULT CURRENT_DATE+1)` | `machines_to_visit` (via `pick_machines_for_refill`), `pod_refills` (via `engine_add_pod`), `pod_swaps` (via `engine_swap_pod`) | ✅ NEW 2026-05-22 — Phase F v2 orchestrator. SECURITY DEFINER. Chains Stage 1 → 2a → 2b in one call. Role gate: `service_role` passthrough (cron) OR `operator_admin`/`superadmin`/`manager` via `user_profiles`. Per-stage exception blocks return diagnostic jsonb on failure (`status='error'`, `stage=<name>`, `message=SQLERRM`). Sets `app.via_rpc='true'` + `app.rpc_name='auto_generate_draft'`. Called by cron job 13 at 8pm Dubai (0 16 \* \* \*) for `CURRENT_DATE + 1`. Returns `{status, plan_date, machines_picked, stage_1, stage_2a, stage_2b}`. Articles 1, 4, 8, 11. Cody-reviewed 2026-05-22. |
| `get_pod_refill_draft(p_plan_date date DEFAULT CURRENT_DATE+1)` | (read-only) | ✅ NEW 2026-05-22 — Phase F v2 draft reader. **SECURITY INVOKER**, LANGUAGE sql, STABLE. Returns enriched `pod_refill_plan` rows with JOINs to `machines` (official_name), `shelf_configurations` (shelf_code), `pod_products` (pod_product_name), `v_live_shelf_stock` (current_stock, max_stock, fill_pct). Extracts velocity_30d, signal, clamp_reason from `reasoning` JSONB. **UPDATED 2026-05-23 (PRD-001):** appended `wh_avail integer` column (SUM of `warehouse_inventory.warehouse_stock` across active product_mapping variants, NULL when no rows). **UPDATED 2026-05-24 (fix_get_pod_refill_draft_weimi_join):** replaced broken `SPLIT_PART(lss.aisle_code, '-', 2) = sc.shelf_code` JOIN with the slot_name JOIN used by `engine_add_pod` v10 (`lss.slot_name = LEFT(sc.shelf_code,1) |     | (SUBSTR(sc.shelf_code,2)::int)::text`). Fixes multi-cabinet fan-out + B-side NULL stock + A-side cross-cabinet contamination on 8 affected machines (ACTIVATE-2005, HUAWEI-2003, MC-2004, LLFP-2005, LLFP-2007, WH-2001, WH1-2002, WH2-2006). Called by FE `RefillPlanningTab.tsx` "Load draft" button. Article 12 (forward-only). |

### Edit + re-stitch (Phase F day 3, 2026-05-18)

| Function                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | Writes to                                                                                                                                                         | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `edit_pod_refill_row(p_plan_date, p_machine_id, p_shelf_id, p_pod_product_id, p_action, p_new_qty, p_reason, p_conductor_session)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | `pod_refill_plan` (UPDATE qty on the specific 5-tuple PK row + edited_at/by + appended `reasoning.manual_edit` jsonb) + `pod_refill_plan_audit` (INSERT diff row) | ✅ NEW 2026-05-18 — Phase F qty-only edit. 5-tuple PK addressing: `(plan_date, machine_id, shelf_id, pod_product_id, action)`. Refuses if any linked `refill_plan_output` row for the same machine+shelf is past pending (packed / dispatched / picked_up). Action enum validated (`REFILL/ADD_NEW/REMOVE/M2W/NOTHING`). qty ≥ 0. Role-gated operator_admin/superadmin with service-role bypass when `auth.uid() IS NULL`. Sets `app.via_rpc`/`app.rpc_name` so generic audit trigger fires. **Scope deferred to v2:** changing `pod_product_id` or `action` requires DELETE+INSERT because they're part of the PK — `swap_pod_refill_row` is the planned v2 RPC. Articles 1, 4, 8. |
| `stop_pod_refill_row(p_plan_date, p_machine_id, p_shelf_id, p_pod_product_id, p_action, p_reason)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | thin wrapper → `edit_pod_refill_row(..., p_new_qty := 0)`                                                                                                         | ✅ NEW 2026-05-18 — soft-stop. Action stays as-is; stitch then treats qty=0 as no-op. Audit row classifies as `edit_type='stop'`. Articles 1, 4.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `add_pod_refill_row(p_plan_date, p_machine_id, p_shelf_id, p_pod_product_id, p_action, p_qty, p_reason, p_conductor_session)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | `pod_refill_plan` (INSERT new draft row) + `pod_refill_plan_audit` (INSERT `edit_type='add'`, before_state `'{}'`)                                                | ✅ NEW 2026-05-31 — the missing manual-add canonical writer (counterpart to `edit_pod_refill_row`). Validates `pod_product_id` resolves in `pod_products` (kills the "missing pod identifiers" FE failure), shelf-belongs-to-machine, action enum, qty ≥ 0, no 5-tuple clobber, and refuses if a linked `refill_plan_output` row is past pending. Inserts at `status='draft'`, `source_origin='warehouse'`. Role-gated operator_admin/superadmin/warehouse with service-role bypass. Sets `app.via_rpc`/`app.rpc_name`. Migrations: `phaseF_add_pod_refill_row_canonical_writer` + fix-forward `phaseF_add_pod_refill_row_fix_audit_before_state`. Cody-approved. Articles 1, 4, 8. |
| `restitch_after_edits(p_plan_date, p_dry_run)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | `refill_plan_output` indirectly via `stitch_pod_to_boonz(p_plan_date, false)` — scoped delete inside `write_refill_plan` protects operator_status ≠ pending rows  | ✅ NEW 2026-05-18 — scoped re-stitch. Computes diff (which boonz lines will change, which are locked) since the last stitch (compared against `refill_plan_output.generated_at`). Default `p_dry_run=true` returns diff jsonb; explicit `false` commits. Role-gated. Articles 1, 4, 8.                                                                                                                                                                                                                                                                                                                                                                                              |
| `_assert_gate_zero(p_plan_date)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | (read-only helper)                                                                                                                                                | ✅ NEW 2026-05-18 — Gate 0 precondition. Raises `Gate 0 not passed: N machine(s) picked but unconfirmed` if any `machines_to_visit` row for the date is `status='picked' AND confirmed_at IS NULL`. `PERFORM`-ed near the top of `engine_add_pod` and `engine_swap_pod` — the engine cannot run until CS confirms. Articles 1, 4.                                                                                                                                                                                                                                                                                                                                                   |
| `confirm_machines_to_visit(p_plan_date)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | `machines_to_visit` (UPDATE: sets `confirmed_at=now()`, `confirmed_by` on rows where `status='picked' AND confirmed_at IS NULL`)                                  | ✅ NEW 2026-05-18 — Gate 0 commit. After this, Stage 2 engines can run. Role-gated operator_admin/superadmin with service-role bypass. Articles 1, 4, 5, 8.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `unpick_machine_to_visit(p_plan_date, p_machine_id, p_reason)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | `machines_to_visit` (UPDATE: status → 'cs_dropped' + dropped_at/by/reason)                                                                                        | ✅ NEW 2026-05-18 — Gate 0 drop. Targets `picked` or `cs_added` rows. Refuses if no matching row exists. Articles 1, 4, 5, 8.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `pick_machine_manually(p_plan_date, p_machine_id, p_reason)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | `machines_to_visit` (INSERT with status='cs*added' + confirmed_at=now() auto-confirm; ON CONFLICT cleans dropped*\* + reinstates as cs_added)                     | ✅ NEW 2026-05-18 — Gate 0 add. CS-added machines bypass picker and are auto-confirmed. Articles 1, 4, 5, 8.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `find_substitutes_for_shelf(p_plan_date, p_machine_id, p_shelf_id, p_anchor_pod_product_id, p_top_n, p_aggressiveness_pct)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | read-only — returns TABLE                                                                                                                                         | ✅ NEW 2026-05-18 — **SECURITY INVOKER** (read-only by design per Cody Article 4/13 — no DEFINER privilege needed). Pearson top-N substitute search with 0–100 aggressiveness knob: 0–33 per-machine Pearson only; 34–66 + loc_type Pearson; 67–100 + category fallback. Returns rank, pod_product_id, name, pearson_score, source ('machine'/'loc_type'/'category_fallback'), wh_stock_units, human-readable reason. Filters out catchall pods (`is_catchall=false`). Articles 4 (read-only INVOKER).                                                                                                                                                                              |
| **PATCHED 2026-05-18:** `engine_add_pod` (Gate 0 precondition + cs_added status), `engine_swap_pod` (Gate 0 precondition + cs_added status), `pick_machines_for_refill` (v2/v3 — pod-deployed intent counting, days_since_visit clamp, velocity floor, ramping window 14d, last_visit counts picked_up OR returned). Engine versions: `engine_add_pod` → `v4_intent_guardrail_gate0`; `engine_swap_pod` → `v7c_gate0`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | (no behavior shift in writes beyond predicate)                                                                                                                    | ✅ Existing canonical writers. Articles 1, 4, 8, 12.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| **FILE (pending apply) 2026-06-01 — Refill-Day RD batch:** `add_machine_to_plan(date,uuid,boolean)` + `create_refill_plan(date,uuid[])` [RD-01, writers of machines_to_visit, never run engine]; `get_shelf_fefo_options(uuid,uuid)` [RD-05, read-only INVOKER helper] + `edit_pod_refill_row`/`add_pod_refill_row` extended to 9-arg via no-DROP wrapper [RD-05 pin]; `driver_report_dispatch_outcome(uuid,text,int)` + `driver_propose_adjustment(uuid,text,text,uuid,uuid)` [RD-03, writers of refill_dispatching outcome + driver_recommendations]. All DEFINER, app.via_rpc set, role-gated + service bypass. Migrations `20260601200000/210000/220000_rd0*`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | machines_to_visit; pod_refill_plan; refill_dispatching; driver_recommendations                                                                                    | 📝 Files written, NOT applied. Cody design ✅; RD-03 ownership caveat open.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| **NEW 2026-06-01:** `snapshot_engine_recommendations(p_plan_date date, p_machine_ids uuid[] DEFAULT NULL)` (Refill v2 #10 stage-1). Write-once (ON CONFLICT DO NOTHING) freeze of the engine's draft into `engine_recommendation_snapshot`. DEFINER, operator_admin/superadmin + bypass. Plus trigger `tg_capture_refill_edit_signal` on `pod_refill_plan` (manual-edit RPCs only) writing typed signals to `refill_edit_signals`. Migration `refillv2_p2_learning_loop_capture`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | `engine_recommendation_snapshot`; trigger → `refill_edit_signals`                                                                                                 | ✅ Canonical writers. Articles 2, 4, 7, 8, 12. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **PATCHED 2026-06-01:** `engine_swap_pod` → `v9_4_signal_feedback` (Refill v2 #10 stage-2a, "feeding the engine"). New temp `_suppressed_swap_subs` (refill_edit_signals swap_rejected ≥3 in 30d per machine,pod) + `NOT EXISTS` gate in sub_candidates → repeatedly-rejected substitute never re-proposed. Read-only on refill_edit_signals; pod_swaps write unchanged. Migration `refillv2_p2_learning_loop_feed_swaps`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | `pod_swaps` (unchanged)                                                                                                                                           | ✅ Patched. Articles 1, 4, 12. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **PATCHED 2026-06-02 (PRD-017 BUG-A §1 availability):** three surfaces now use the §1 _Available_ def (serving WH primary+secondary, Active, non-quarantined, in-date, non-reserved-elsewhere; never consumer*stock): `v_dispatch_availability` (view, per-(machine,product) WH CTE; verified 47/47 §1 match), `get_pod_refill_draft.wh_avail` (+expiry/serving-WH/reservation), `engine_add_pod` → `v12_wh_avail_s1_suppress` (wh_avail=0 ⇒ suppress + procurement_gap). Migrations `prd017_buga*\*`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | reads warehouse_inventory; engine_add_pod writes pod_refills (unchanged shape)                                                                                    | ✅ Patched. Articles 1, 4, 6, 12. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| **NEW 2026-06-01:** `set_swaps_enabled(p_enabled boolean, p_machine_id uuid DEFAULT NULL)` (Refill v2 #8/F6). Sole writer of the new `refill_settings` KV config table; upserts global `swaps_enabled` or per-machine `swaps_enabled:<id>`. DEFINER, operator_admin/superadmin + `auth.uid() IS NULL` bypass. Read by `engine_swap_pod` v9_3 (skips disabled machines in both passes). Migration `refillv2_f6_swaps_flag`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | `refill_settings` (upsert)                                                                                                                                        | ✅ Canonical writer. Articles 1, 2, 4, 12. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **NEW 2026-06-01:** `reset_and_restitch(p_plan_date date, p_machine_ids uuid[], p_reason text)` (Refill v2 #7). One-call re-derive + re-stitch of a plan subset, replacing ~8 raw dispatch edits. Composes archive-only supersede of `pod_refill_plan` + `engine_finalize_pod(date,ids)` + `approve_pod_refill_plan(date,names)` + `stitch_pod_to_boonz(date,false)`. Dispatch guard refuses if subset `refill_plan_output` past pending; `write_refill_plan` per-machine pending-only delete keeps dispatched machines safe. DEFINER, operator_admin/superadmin + `auth.uid() IS NULL` bypass, reason≥10. Migration `refillv2_p2_reset_and_restitch`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | `pod_refill_plan` (supersede) + delegates to finalize/approve/stitch                                                                                              | ✅ Canonical writer. Articles 1, 4, 5, 8, 12. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| **NEW 2026-06-01:** `commit_refill_plan(p_plan_date date, p_comment text, p_machine_ids uuid[] DEFAULT NULL)` (Refill v2 #8/F5). Captures a refill-plan push comment + summary into the new append-only `refill_commit_log`. DEFINER (sole writer of refill_commit_log), operator_admin/superadmin/manager + `auth.uid() IS NULL` bypass, non-empty comment. Read-only summary from `refill_plan_output`. Migration `refillv2_f5_commit_refill_plan`. **AMENDED 2026-07-31 (PRD-110 leg 50, P2.6, `prd110_p26_preflight_gate_at_commit`):** now consults canonical `preflight_refill_plan` before its INSERT and enforces the verdict per `refill_policy_params.preflight_enforcement`. `warn` (today) = the response gains a `preflight` block, behaviour otherwise unchanged; `block` = a `FAIL` verdict returns `status='preflight_failed'` and writes **nothing**, unless an unspent `preflight_override_v3` grant exists, which it consumes by reference. The commit row records `preflight_verdict`, `preflight_violation_count` and `preflight_override_id`. ⛔ **`p_machine_ids` carries `DEFAULT NULL::uuid[]` and MUST keep it** — the first apply dropped it and Postgres refused with `42P13`; check `pronargdefaults` before any `CREATE OR REPLACE`. oid 144821 preserved, one overload. Golden fixture 33 (35 assertions).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | `refill_commit_log` (append-only insert)                                                                                                                          | ✅ Canonical writer. Articles 2, 4, 7, 12. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **PATCHED 2026-06-01:** `engine_finalize_pod` subset-aware (Refill v2 #6/B6). NO-DROP wrapper (Cody/Art.12): 1-arg `engine_finalize_pod(date)` replaced in place delegates to NEW 2-arg `engine_finalize_pod(date, uuid[])` → `v13_subset_aware` with 14 machine gates `(p_machine_ids IS NULL OR <tbl>.machine_id = ANY(p_machine_ids))`. 2-arg has no defaults (avoids 1-arg call ambiguity). Whole-plan (NULL) behaviour identical to v12_1. Foundation for #7 reset_and_restitch. Migration `refillv2_b6_finalize_subset_aware`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | `pod_refill_plan` (ON CONFLICT upsert; unchanged shape)                                                                                                           | ✅ Patched. Articles 1, 4, 8, 12. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| **VIEWS 2026-06-12:** `v_wh_pickable` NEW (PRD-028 WS3, Article 16 draft) - canonical WH pickable predicate (Active, NOT quarantined, in-date Dubai or NULL, stock>0; batch grain; `security_invoker=true`). `v_dispatch_availability` PATCHED - wh_avail CTE consumes `v_wh_pickable` (inline predicate deleted), commitments gain `picked_up=false`; output columns unchanged; zero consumers pre-patch, packing FE is the first consumer (badges + batch pool). Migration `prd028_ws3_wh_pickable_dispatch_availability`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | (read-only views; no DEFINER)                                                                                                                                     | ✅ Applied. Articles 2, 3, 12, 14. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| **NEW 2026-06-12:** `unskip_dispatch_line(p_dispatch_id uuid, p_actor uuid DEFAULT NULL)` (PRD-029 dispatch-state-integrity step 3). Canonical writer for the skip -> active transition: clears `skipped` + `include=false` in one logged write (actor = COALESCE(p_actor, auth.uid()) recorded in mutation_reason; skip_reason preserved for history); REFUSES cancelled lines (cancellation is not reversible from packing); idempotent noop on unflagged lines. Exists because `set_dispatch_include` cannot clear `skipped`, which would leave the packing Un-skip affordance silently dead under the phaseF_dispatch_state_guards refusals. Caller: packing FE `handleUnskip`. Migration `phaseF_unskip_dispatch_line`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | `refill_dispatching` (skipped/include flags only)                                                                                                                 | ✅ Canonical writer. Articles 1, 4, 5, 12. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **PATCHED 2026-06-14:** `pack_dispatch_line` → PRD-030 partial/not_filled (no dark stage). Empty/zero picks `[]` => confirmed `not_filled` (sets `pack_outcome='not_filled'`, `filled_quantity=0`, `packed` stays FALSE, snapshots planned into `original_quantity`, **NO warehouse debit, no `from_wh_inventory_id` required**) instead of raising. Partial (`0<sum<planned`) sets `pack_outcome='partial'` + keeps planned in `original_quantity`; full sets `pack_outcome='packed'`. `quantity = total_picked` UNCHANGED so `conserve_split_dispatch_quantity` is untouched (Cody required-check #1 resolved via `original_quantity`, not a trigger edit). BUG-006 `from_wh` guard kept for real picks. Signature unchanged (no overload). Rolled-back battery: not_filled 25->25 WH (no debit), partial filled=3/qty=3/orig=5, full=packed. Rollback md5 `63454d3d3f51d6a56e8a4852dc5c703c`. Migration `prd030_pack_dispatch_line_partial_notfilled`. New enum `pack_outcome_enum` + column `refill_dispatching.pack_outcome` via `prd030_pack_outcome_enum_and_column`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | `refill_dispatching`, `warehouse_inventory` (same surface; not_filled touches neither WH nor packed)                                                              | ✅ Patched. Articles 1, 4, 5, 8, 12, 14. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **NEW 2026-06-14:** `confirm_machine_packed(p_machine_name, p_dispatch_date, p_packed_by, p_reason)` (PRD-030). Canonical machine-level pack gate: flips a machine to packed when every included non-cancelled fillable line is resolved (packed/partial/not_filled/skipped); returns `status='blocked'` + the unresolved lines otherwise (never invents picks). Role warehouse/operator_admin/superadmin/manager, reason>=10, GUCs set. Writes ONLY the new `dispatch_pack_confirmation` table (PK id + UNIQUE(machine_id,dispatch_date), RLS read-all + DEFINER-only write + audit_log_write trigger). Rolled-back battery: blocked w/ unresolved line, ok when all resolved (machine with 2 not_filled lines reaches is_pack_complete). Migrations `prd030_dispatch_pack_confirmation_table` + `..._add_id_pk` + `prd030_confirm_machine_packed`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | `dispatch_pack_confirmation` (sole writer)                                                                                                                        | ✅ NEW. Articles 1, 4, 8, 12. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| **PATCHED 2026-06-14:** `release_stale_unpacked_dispatches` → PRD-030: EOD release excludes resolved `not_filled` lines (`AND pack_outcome <> 'not_filled'` on count+update WHERE) so a packed machine with not-filled lines is complete, not stale. One-predicate add, rest verbatim. Migration `prd030_release_stale_exclude_not_filled`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | `refill_dispatching` (cancel; same surface)                                                                                                                       | ✅ Patched. Articles 1, 4, 12. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **PATCHED 2026-06-12:** `pack_dispatch_line` + `return_dispatch_line` → dispatch-state guards (PRD-029 dispatch-state-integrity step 1, Incidents A+B). pack: unconditional three-flag refusal (skipped / cancelled / include=false) before ANY mutation incl. the packed_no_pick early path; error names flag + skip_reason; no override param (un-skip is a separate logged FE action). return: same three-flag refusal CONDITIONAL on packed=false AND picked_up=false (flagged-but-packed stays returnable: Incident-A recovery path + eod_auto_release_unpicked pass-1 contract) + system-actor guard (p_returned_by NULL AND nothing physical -> refuse; kills the Dispatch Complete auto-return burst). Battery 1-4 green in rolled-back tx. Rollback functiondefs + md5s in docs/prds/prd-029-dispatch/. Migration `phaseF_dispatch_state_guards`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | `refill_dispatching`, `warehouse_inventory`, `pod_inventory` (same write surface; refusals only)                                                                  | ✅ Patched. Articles 1, 4, 12. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **PATCHED 2026-06-12:** `get_machine_health` → canonical velocity source (PRD-028 WS2, Article 16 draft). `with_velocity.daily_velocity` now reads NEW `v_machine_velocity` (CANONICAL machine velocity: units_7d/30d, daily_velocity_7d/30d, Success-only, rolling now() windows) instead of inline `SUM(qty)/NULLIF(7,0)` - formula identical, values unchanged for all machines. Fn gains `SET search_path = public, pg_temp` (was DEFINER without it). Sibling change: `v_machine_health_signals.sales_recent` consumes the view (units_last_7d gains Success filter + rolling anchor; before/after in WS2 design note). daily_revenue (60d revenue) untouched - separate metric. AC: 0 mismatches vs canonical; pg_proc scan clean. Migration `prd028_ws2_velocity_canonical`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | (read-only; no writes)                                                                                                                                            | ✅ Patched. Articles 4, 12. Cody ⚠️→cleared.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| **PATCHED 2026-06-14:** `stitch_pod_to_boonz` → `v23_wh_reserved` (PRD-031 WS-5, shared-SKU reservation). New `wh_reservation` CTE computes `wh_remaining = wh_avail − SUM(variant_final)` already claimed by higher-ordered (machine*name, shelf_code) warehouse-sourced lines for the same boonz SKU (window PARTITION BY boonz_product_id). The `[WH_WARNING]` comment now fires on **reserved-remaining**, not total WH stock — so a shared SKU can no longer read "covered" for five machines and pack dry. Warn-only (no qty cap): BUG-006 in `pack_dispatch_line` is the physical pack-time guard (PRD-030 not_filled handles the shortfall) and WS-4 `v_refill_accuracy` surfaces the honest warning as `wh_short`. Edits confined to: new `wh_reservation` CTE (aliased r*\* keys to avoid emit-column collision), 2 WH_WARNING conditions + 2 messages switched to `COALESCE(wr.wh_remaining, wh_avail)`, one LEFT JOIN in the emit, version bump. **2nd stitch rewrite within 24h** (WS-2 was first today) — proceeded under CS "continue WS-5" directive (Hard Rule 10). v22 rollback md5 `5cec95904ca5da5ed99b9a9a499ecbe5`, live v23 md5 `450303cdaf8f401e9a5cb875e512d3fa`. Rolled-back battery (Popit Cola WH=3, 3 machines, reservation order): ACTIVATE-2005 emits 1 (clean), VML-1003 emits 2 (clean, cumulative=WH), VML-1004 flagged `[WH_WARNING reserved WH 0 < planned 1]`. Migration `prd031_ws5_stitch_wh_reserved`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | `refill_plan_output` via `write_refill_plan` (unchanged; warn-only, no qty change)                                                                                | ✅ Patched. Articles 1, 4, 5, 8, 12, 14. Cody ⚠️→cleared.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| **PATCHED 2026-06-14:** `engine_add_pod` → `v17_cover_capped` (PRD-031 WS-3, CS decision Option B: cover is the target, capacity caps). v16 emitted `need_raw = GREATEST(fill_to_cap, driver_req)` (always fill-to-capacity); v17 emits `need_raw = LEAST(GREATEST(cover_units, driver_req), fill_to_cap)` where `cover_units` = stance-aware velocity cover top-up (`compute_refill_decision.velocity_target` = velocity×days_cover×cover_mult), wind-down/rotate-out/dead → 0, every other live selling shelf floored at 1. Drift fix: `compute_refill_decision` now called with `p_days_cover` (was hardcoded 10). The engine consumes `velocity_target`, NOT `refill_qty` (which carries an extra visual floor `floor_pct×cap` that CS's lean-slow-mover decision rejects — `refill_qty`/`target_units` are now advisory, not the engine source). `final_qty` (WH allocation + shared-SKU `prior_need` pool) verbatim; smaller `need_raw` reduces WH contention. New `clamp_reason='cover_capped'`; reasoning gains `cover_units`+`velocity_target`; version-tag housekeeping (delete-list, dead_tags.tagged_by, driver_feedback.resolved_by_engine → v17). Read-only battery on 2026-06-15 picked plan: 135 selling shelves, **v16 515u → v17 324u (−37%)**; 44 lean cover-capped (incl. barely-alive rotate/wind-down now 0: Ice Tea 9→0, Nescafe 6→0), 53 capacity-binds unchanged. live v17 md5 `53efb83f235af2518e43cbe1ea976e68`. Migration `prd031_ws3_engine_cover_capped`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | `pod_refills` (sole writer, same surface); `pod_swaps` dead-tags (unchanged)                                                                                      | ✅ Patched. Articles 1, 4, 8, 12, 16. Cody ⚠️→cleared (Article-16 advisory-refill_qty note folded in).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| **PATCHED 2026-06-14:** `stitch_pod_to_boonz` → `v22_onshelf_scoped` (PRD-031 WS-2 + WS-2b, CRITICAL refill-execution accuracy). **WS-2b (scoped-authoritative mapping):** `pull_raw` and procurement `pm_per_row` joins change from the union `(pm.machine_id IS NULL OR pm.machine_id=a.machine_id)` to set-level precedence — a global default row is admitted ONLY via `pm.machine_id IS NULL AND NOT EXISTS (active scoped row for same pod+machine)`. A curated machine now emits ONLY its scoped SKU set; the global set leaks in only where no scoped mapping exists. Kills the Snack-Bar global leak (AMZ-1057 curated Delice+KitKat was dispatched Delice+KitKat+McVities×2+Oreo). **WS-2 (off-shelf redistribution):** new `on_shelf` bool on `pull_raw` (EXISTS in `v_pod_inventory_latest` for machine+shelf+boonz) + windowed `shelf_has_known_variant`; `pull_resid.is_residual_variant` gains `AND (on_shelf OR action<>'REFILL' OR NOT shelf_has_known_variant)`. PRD-024's `total_split` window already sums split over residual-eligible only, so excluding an off-shelf REFILL variant AUTO-renormalizes the on-shelf variants to 1.0 and the largest-remainder distributor hands them the full residual_pool — no unit dropped, redistributed. **Cody required #1:** `action<>'REFILL'` exempts ADD_NEW swap-ins (variant not yet on shelf). Empty/unknown shelf → `shelf_has_known_variant=false` → all mapped variants eligible (v21-identical, no starvation). Deviation `m_raw`/`ex_final` left verbatim (vacuous: `variant_target≡variant_final`; superseded by WS-4). v21 rollback md5 `52a6d3b139fc5cb5542ab733f848a01e`, live v22 md5 `5cec95904ca5da5ed99b9a9a499ecbe5`. Rolled-back battery (synthetic date 2099-06-14, real mapping+inventory): R2 AMZ-1057 Snack Bar REFILL → Delice only (no global McVities/Oreo despite on-shelf, KitKat off-shelf zeroed); R4 same Snack Bar ADD_NEW → Delice+KitKat (exemption); R3 Red Bull on no-RB shelf → full set (no starve). Migration `prd031_ws2_ws2b_stitch_onshelf_scoped`. | `refill_plan_output` via `write_refill_plan` (unchanged); `refill_plan_deviations`, `procurement_alerts` directly (unchanged)                                     | ✅ Patched. Articles 1, 4, 5, 8, 12, 14. Cody ⚠️→cleared (revision #1 ADD_NEW exemption folded in).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **NEW 2026-06-14:** `get_refill_plan_accuracy(p_plan_date date)` + view `v_refill_accuracy` (PRD-031 WS-4, Article 16 metric "refill execution accuracy"). Read-only INVOKER reader over the new `security_invoker` view; returns per-shelf-pod `{pod_intent, dispatched_qty, shelf_gap, wh_short, shortfall, status}` + a plan `summary` with `intent_fill_ratio`, `gap_fill_ratio`, and `verdict` (block on any `leak`, flag on under-fill, else pass). The view is INTENT-driven (`pod_refill_plan` LEFT JOIN aggregated `refill_plan_output` by name + action map) so a fully-leaked shelf-pod with zero output rows is still visible with `dispatched_qty=0`; `status` = `ok` (filled or shelf already at gap) \| `wh_short` (WH_WARNING/WH_STOCK_UNKNOWN — excused) \| `leak` (intent missing with shelf room and no WH cause) \| `over`. Replaces the structurally-vacuous stitch deviation block (root-cause D). Consumed by `RefillPlanningTab` (WS-4 panel) + the conductor dry-run gate. Rolled-back battery green: leak/wh_short/ok/zero-dispatch all classified, verdict=block on leaks. Migration `prd031_ws4_refill_accuracy_gate`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | (read-only; no writes — INVOKER, honors operator RLS on `refill_plan_output`)                                                                                     | ✅ NEW. Articles 4, 12, 16. Cody ⚠️→cleared (security_invoker + grants + metric registry folded in).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| **PATCHED 2026-06-12:** `get_machine_expiry_detail` + `get_machine_slots_with_expiry` → canonical expiry source (PRD-028 WS1, Article 16 draft). Both now read NEW `v_machine_expiry_batches` (the single batch-resolution rule: latest Active batch per shelf, NULL-shelf legacy per machine+product, no 30d window) instead of their own per-machine-latest-snapshot + 30d-window scans. `get_machine_expiry_detail` stays SECURITY DEFINER, gains `SET search_path = public, pg_temp`, moves CURRENT_DATE → Dubai operational date; `get_machine_slots_with_expiry` stays INVOKER, `product_expiry` CTE repointed, `latest_snap` CTE removed, rest verbatim. Sibling change: `v_machine_expiry_summary` is now the CANONICAL machine-grain expiry metric (+SKU cols) and `v_machine_health_signals.expiry_state` consumes it. AC: 30 machines, 0 disagreements signals vs get_machine_health. Migration `prd028_ws1_expiry_canonical`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | (read-only; no writes)                                                                                                                                            | ✅ Patched. Articles 4, 12, 13. Cody ⚠️→cleared.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| **PATCHED 2026-06-12:** `engine_swap_pod` → `v10_2_ws1_guards` (PRD-027 WS1). 1a: `p_min_pearson` finally APPLIED in the dead-tag resolution — threshold-qualifying candidates preferred; when none qualify the best remaining candidate is taken explicitly with `substitute_source='global_performer_fallback'` + `reasoning.below_pearson_threshold=true` (corr 0.214/0.242 swaps had shipped unmarked). 1b: `p_max_swaps_per_machine` caps ACROSS passes — strategic tags consume budget first, dead-tags resolve worst-shelf-first (lowest live stock), overflow deferred with `reasoning.deferred_by_cap=true` (pod_in stays NULL so finalize's orphan-M2W suppression keeps them off the plan; tag carries to next cycle). Driver-rec pass uncapped. 1c: hardcoded default-8 swap-in qty now audit-marked `clamp_reason='default_capacity_8'` (interim until WS4 backfill). New return counters `dead_tags_deferred_by_cap`/`dead_tags_below_pearson_fallback`. v10.1 rollback md5 `c30f1165329034488967b1dfca5e4894`. Rolled-back smoke on 06-13 green. Migration `phaseF_swap_pod_v10_2_ws1_guards`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | `pod_swaps` (same write surface; selection + markers only)                                                                                                        | ✅ Patched. Articles 1, 4, 8, 12. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| **PATCHED 2026-06-12:** `engine_finalize_pod` (2-arg) → `v14_preserve_approved` (PRD-025 Option A). The upsert's `ON CONFLICT` no longer unconditionally resets `status='draft'`: approval is preserved when the incumbent row is `approved` and materially unchanged (same qty + action); any material change still reverts to draft and demands re-approval. Kills the "Stitch failed: no approved rows" FE Commit race (approve 01:53:30.2 → finalize 01:53:30.7 silently un-approved everything, night 06-11/12). 1-arg wrapper untouched (md5 unchanged). Rolled-back regression on 06-13 (119 refills + 7 swaps): no-op re-finalize keeps 133/133 approved; 1 mutated row → exactly 1 draft; subset re-finalize keeps 24/24. v13 rollback md5 ec8ace36cc2b1a6527bc0eb8ea185b6d. Migration `phaseF_finalize_preserve_approved`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | `pod_refill_plan` (ON CONFLICT upsert; status now approval-preserving on no-op)                                                                                   | ✅ Patched. Articles 1, 4, 5, 8, 12. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| **PATCHED 2026-06-12:** `stitch_pod_to_boonz` → `v20_split_pct_normalize` (PRD-024 section 1, CRITICAL). The SKU split is now self-normalizing: all four mapping reads switch `pm.mix_weight` → `pm.split_pct`, and the four split sites (`pull_norm`, `remove_phys_split`, deviation `n`, new procurement `pm_norm`) divide by the windowed `total_split` so shares sum to 1.0 regardless of raw scale (100, 170, or all-1.0). Kills the multi-flavor inflation (1,713 machine-scoped mix_weight=1.0 rows gave each variant the FULL shelf qty: VOXMCC A10 10→30). Procurement demand drops the arbitrary 0.20 default for the shared even-split-when-zero rule. Battery (read-only sim, 06-13 plan, 106 shelf-pods/82 multi-SKU): v19 math inflates 4 shelf-pods (worst +60), v20 conserves on ALL, 0 single-SKU drift, Activia sum-170 splits 4/3/3 = 10. Pre-apply audit: 0 variants lose allocation (all 753 split_pct=0 rows already had mix_weight=0). v19 rollback fingerprint md5 16fb196b820c97a31b8cfccfdff84614. Migration `phaseF_stitch_split_pct_normalize`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | `refill_plan_output` via `write_refill_plan` (unchanged); `refill_plan_deviations`, `procurement_alerts` directly (unchanged)                                     | ✅ Patched. Articles 1, 4, 5, 8, 12, 14. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **PATCHED 2026-06-01:** `stitch_pod_to_boonz` → `v14_remove_qty_capped` (Refill v2 #4/B4). `remove_lines.variant_final` capped: non-internal_transfer removes use `LEAST(fanned, pil.current_stock)`; internal_transfer uncapped so the fan-out invariant holds. Stops over-capacity REMOVE emissions (Nescafe 96 etc.). Verbatim repro, diff-gated 2 lines. Migration `refillv2_b4_cap_remove_qty_live_stock`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | `refill_plan_output` via `write_refill_plan` (unchanged)                                                                                                          | ✅ Patched. Articles 1, 4, 6, 8, 12, 14. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **PATCHED 2026-06-01:** `stitch_pod_to_boonz` → `v13_physical_remove_fallback` (Refill v2 #3 REMOVE/M2W dispatch). New CTE `remove_lines_physical_fallback` emits a driver line (boonz NULL, qty = `v_live_shelf_stock.current_stock`) for REMOVE/M2W rows the mapped+inventory path dropped (VOX/untracked, non-internal_transfer), so every planned REMOVE reaches the driver. Existing mapped path + internal_transfer fan-out invariant + deviations/alerts unchanged. Verbatim repro, diff-gated. Migration `refillv2_p2_stitch_physical_remove_fallback`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | `refill_plan_output` via existing `write_refill_plan`; `refill_plan_deviations`, `procurement_alerts` directly (unchanged)                                        | ✅ Patched. Articles 1, 4, 6, 8, 12, 14. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **PATCHED 2026-06-01:** `engine_swap_pod` → `v9_2_machine_present_dedup` (Refill v2 #2 dedup-guard). New `ON COMMIT DROP` temp `_machine_present_pods` = `slot_lifecycle` is_current ∪ `v_live_shelf_stock` physical(`current_stock>0`); pass-2 `sub_candidates` excludes any substitute already on the machine (`mpp.pod_product_id IS NULL`) so it falls to M2W, never duplicated. Verbatim repro, diff-gated; no schema/gate change. Migration `refillv2_p2_swap_dedup_machine_present`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | `pod_swaps` (engine staging; unchanged write shape)                                                                                                               | ✅ Patched. Articles 1, 4, 8, 12, 14. Cody ✅.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| **PATCHED 2026-05-18 PM:** `stitch_pod_to_boonz` v8 — `remove_lines` CTE switched pm JOIN to EXISTS-with-machine-scoping (no fan-out, ONE row per machine/shelf/pod/boonz combo); `demand` CTE adds DISTINCT ON to dedupe pm rows preferring per-machine over global. Engine version flipped `v7_sequential_redist` → `v8_machine_aware_pm`. Smoke test on 2026-05-12 plan: 265 lines, 38 deviations, 47 alerts, 1.1s.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | `refill_plan_output` via existing `write_refill_plan`; `refill_plan_deviations`, `procurement_alerts` directly                                                    | ✅ Patched. Articles 1, 4, 12. Migration `phaseF_stitch_v8_machine_aware_pm_joins`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **VIEW PATCHED 2026-05-18 PM:** `v_warehouse_pod_rollup` — added `pm_distinct AS (SELECT DISTINCT pod_product_id, boonz_product_id FROM product_mapping WHERE status='Active')` subquery before the join to warehouse_inventory. `total_stock` reduced by ~24× on every multi-machine-mapped product (e.g. Vitamin Well 1,200 → 48, Soft Drinks Mix 3,216 → 134). Affects every reader: `engine_add_pod`, `engine_swap_pod`, ops queries.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | (read-only view; no DEFINER)                                                                                                                                      | ✅ Patched. Article 12. Migration `phaseF_fix_v_warehouse_pod_rollup_machine_aware_dedupe`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |

### PRD-REFILL-V2 — engine rebuild (STAGED 2026-06-08, per-item CS apply gate; NOTHING APPLIED)

Core principle: quantity DECOUPLED from score (final_score/Pearson = ranking only). Files in `supabase/migrations/`; prior live bodies preserved in `docs/prds/refill-pipeline/_staging/live/`.

- **`engine_add_pod` -> v15_fill_to_cap** (file `20260608120000_refillv2_engine_add_pod_v15_fill_to_cap`). Fill-to-capacity: `need_raw=GREATEST(max_stock-current_stock, driver_req)` capped ONLY by a shared-WH window allocation (best sellers first by velocity->final_score). Dead (stance DEAD/ROTATE OUT/'DEAD — SWAP NOW' or velocity_30d=0) -> qty 0 + `pod_swaps` tag (reason dead/rotate_out, pod_product_id_in NULL, reasoning.tagged_by='engine_add_pod_v15'). `compute_refill_decision` retained for stance/final_score/velocity (ranking only; target_units/refill_qty NO LONGER cap). DRY-RUN 2026-06-09: 284/284 WH-fillable sellers >=95% (100% engine fill); 137 dead tagged. 🟡 Staged, ready for CS sign-off. Articles 1,4,5,8,12,14.
- **`resolve_driver_intent(p_plan_date date, p_machine_id uuid DEFAULT NULL)`** (file `20260608121000_refillv2_resolve_driver_intent_translator`). NEW read-only **SECURITY INVOKER**, sql STABLE. Returns TABLE(signal_source, source_id, machine_id, shelf_code, pod_product_id, boonz_product_id, qty, intent_kind, resolved, resolution). Reads driver_feedback + driver_recommendations + product_mapping (boonz->pod reverse) + shelf_configurations. Unresolved -> 'unresolved_driver_intent' (none dropped). Feeds items 1/2/6. DRY-RUN 2026-06-05: 6/7 resolved. 🟡 Staged. Article 4.
- **`pick_machines_for_refill` -> v8_p1_restock** (file `20260608123000_refillv2_pick_machines_v8_p1_restock`). P1_RESTOCK mirrors get_machine_health bands (velocity proxied units_last_7d>0); explicit warehouse/excluded filter; sibling expansion (r_cluster) + visit_order preserved. DRY-RUN: same 28 picked, P1 18->12, 0 warehouses. 🟡 Staged, ready for CS sign-off. Articles 1,4,5,8,12.
- **`engine_swap_pod` v9_5 -> v10** — ⏳ DESIGN+SPEC, 2 CS forks (M2W paired warehouse return in-engine vs downstream; consume add tags UPDATE-in-place vs DELETE+rebuild). Removes Pass-2 autonomous-Pearson + lifecycle; swap-in via `find_substitutes_for_shelf` + global fallback; consume driver_recommendations. File pending CS decision.
- **`stitch_pod_to_boonz` v18 overlay** — ⏳ DESIGN+SPEC, overlay-semantic fork (pin driver SKU+qty requires re-solving mix largest-remainder; sum=pod_qty invariant) + defensive shelf-code A01..E16 guard (all 2615 live already canonical). File pending CS decision.

### Dispatch editing — driver / WH manager / admin edits (Phase F, 2026-05-19)

| Function                                                                                                                                                                                                         | Writes to                                                                                          | Status                                                                                                                                                                                                                                                                                                                                                           |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `edit_dispatch_qty(p_dispatch_id, p_new_qty, p_edit_role, p_reason, p_conductor_session)`                                                                                                                        | `refill_dispatching` (UPDATE qty + audit cols) + `refill_dispatching_edit_log` (INSERT kind='qty') | ✅ NEW 2026-05-19. State guard: item_added=false. Role: warehouse / operator_admin / superadmin / manager. Snapshots prior quantity into original_quantity on first edit. Articles 1 (revised by Amendment 005), 4, 5, 8.                                                                                                                                        |
| `edit_dispatch_shelf(p_dispatch_id, p_new_shelf_code, p_edit_role, p_reason, p_conductor_session)`                                                                                                               | `refill_dispatching` (UPDATE shelf_id) + edit_log INSERT kind='shelf'                              | ✅ NEW 2026-05-19. State guard: picked_up=true AND item_added=false (driver moves a row to a different shelf at the machine). Role: field_staff (driver) / operator_admin / superadmin / manager. WH manager rejected by p_edit_role check. Resolves shelf_id via shelf_configurations lookup on the same machine; refuses phantom shelves. Articles 1, 4, 5, 8. |
| `edit_dispatch_product(p_dispatch_id, p_new_boonz_product_id, p_edit_role, p_reason, p_conductor_session)`                                                                                                       | `refill_dispatching` (UPDATE boonz_product_id + pod_product_id) + edit_log INSERT kind='product'   | ✅ NEW 2026-05-19. State guard: picked_up=true AND item_added=false. Driver-only. Resolves new pod_product_id via machine-aware product_mapping lookup (per-machine wins over global). Articles 1, 4, 5, 8.                                                                                                                                                      |
| `add_dispatch_row(p_machine_id, p_shelf_code, p_boonz_product_id, p_quantity, p_action, p_dispatch_date, p_source_kind, p_source_warehouse_id, p_source_machine_id, p_edit_role, p_reason, p_conductor_session)` | `refill_dispatching` (INSERT new row with created_by_edit=true) + edit_log INSERT kind='add'       | ✅ NEW 2026-05-19. Driver or WH manager adds a row not in the original engine plan. Validates: action in ('Refill','Add New','Remove'), shelf exists on planogram, product_mapping exists, qty > 0. m2m source kind HARD-REFUSES if source machine has no active pod_inventory > 0 for the product. Articles 1, 4, 8.                                            |
| `remove_dispatch_row(p_dispatch_id, p_edit_role, p_reason, p_conductor_session)`                                                                                                                                 | `refill_dispatching` (UPDATE include=false) + edit_log INSERT kind='remove'                        | ✅ NEW 2026-05-19. State guard: picked_up=false (too late to remove once driver has it). WH-manager-only (driver rejected by p_edit_role check). Soft-remove — no DELETE. Articles 1, 4, 5, 8.                                                                                                                                                                   |
| `set_dispatch_source(p_dispatch_id, p_source_kind, p_source_warehouse_id, p_source_machine_id, p_edit_role, p_reason, p_conductor_session)`                                                                      | `refill_dispatching` (UPDATE source*kind / source*\*\_id) + edit_log INSERT kind='source'          | ✅ NEW 2026-05-19. WH-manager-only. State guard: item_added=false. Same m2m hard-refuse validation. Annotates the source-of-stock for traceability so receive logic knows WH-Central vs WH-MCC vs M2M-from-machine-X. Articles 1, 4, 8.                                                                                                                          |

`restore_dispatch_row` was proposed but **rejected by Cody R2** during review — rewriting `item_added=true` history would misrepresent physical events. Use `adjust_pod_inventory` directly for post-receive corrections.

**PATCHED 2026-05-19:** `receive_dispatch_line` Refill/Add New / Add path now archives any existing Active pod_inventory row(s) on the same (machine, shelf, boonz_product) before inserting, then sums current_stock and takes MIN expiry. Resolves `idx_pod_inv_active_shelf` UNIQUE conflict. Migration `phaseF_receive_dispatch_line_upsert_active_pod_row`.

### Stax FE refactor writers (Phase G, 2026-05-30, PROGRAM-2026-06-01)

Three small canonical writers added so the field PWA can stop writing `refill_dispatching` directly for comment edits, include flips, and driver-added Remove lines. Migration `phaseG_stax_canonical_writers_for_dispatch_fe_refactor`. All three appended to the `enforce_canonical_dispatch_write` allow-list (trigger still RAISE WARNING; the RAISE EXCEPTION flip is parked until the 6 deferred FE writers close, see `PROGRAM-2026-06-01b`).

| Function                                                                                                                         | Writes to                                                                                               | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| -------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `update_dispatch_comment(p_dispatch_id, p_comment)`                                                                              | `refill_dispatching` (UPDATE comment)                                                                   | ✅ NEW 2026-05-30. Comment-only edit; `NULLIF(TRIM(...))` so blank stores NULL. Role: field_staff / warehouse / operator_admin / superadmin / manager. NOT FOUND guard. Articles 1, 4, 8. FE: dispatching:624/669, trips:227.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `set_dispatch_include(p_dispatch_id, p_include)`                                                                                 | `refill_dispatching` (UPDATE include)                                                                   | ✅ NEW 2026-05-30. Include-flag flip (un-skip / skip). Not a state-machine column (Article 5 N/A). Same role tier. NOT FOUND guard. Articles 1, 4, 8. FE: packing:1295. **UPDATED 2026-06-07 (PRD-019, `prd019_set_dispatch_include_service_role_bypass`):** added the standard service-role bypass (`IF auth.uid() IS NOT NULL AND role-not-ok`) so cron/service-role can void rows (used for the Nissan 04/06 supersede). Cody ✅; only the role-gate guard changed.                                                                                                                                                                                                                                                                                                                                                                         |
| `insert_driver_remove_line(p_machine_id, p_boonz_product_id, p_pod_product_id, p_shelf_id, p_quantity, p_expiry_date, p_reason)` | `refill_dispatching` (INSERT action='Remove')                                                           | ✅ NEW 2026-05-30. Driver inserts an off-plan Remove line (multi-variant split). Title Case 'Remove'. qty > 0, reason ≥ 10 chars. Stamps `dispatch_date=CURRENT_DATE`, packed/picked_up=true, dispatched/returned=false, `filled_quantity=0`, `item_added=false`, `[DRIVER-INSERT] <reason>` comment. Articles 1, 4, 8. FE: dispatching:497. **NB:** no service-role bypass — caller must have a real role-bearing uid (NULL uid raises 'role none'); impersonate operator/manager via `request.jwt.claims` for retro/service-role logging. No `p_date` param — `dispatch_date` is always CURRENT_DATE.                                                                                                                                                                                                                                        |
| `log_retroactive_refill_visit(p_machine_id, p_visit_date, p_lines jsonb, p_reason)`                                              | `refill_dispatching` (INSERT action='Refill'/'Add New', one row per line, `[RETRO-LOG <date>]` comment) | ✅ Canonical retro-log writer. Refill/Add New only (Removes via `insert_driver_remove_line`). `p_lines[]` = `{boonz_product_id, qty, shelf_code?, expiry?, source_origin? (warehouse\|vox_at_venue), action? (Refill\|Add New), comment?}`. Validates non-future date, machine Active, boonz exists, active `product_mapping` (per-machine wins over global default), shelf-on-machine. Born packed+picked_up+dispatched=true, item_added=false (WEIMI-fed pod, no WH/pod stock movement). Service-role bypass (`auth.uid() IS NULL` skips role gate). Per-line idempotent dedup. Articles 1, 4, 8. **UPDATED 2026-06-10 (PRD-020, `prd020_retro_log_dedup_include_expiry`):** dedup key gained `AND (expiry_date IS NOT DISTINCT FROM v_expiry)` so distinct-expiry batches (same qty/shelf) no longer false-collapse. Cody ✅ (1, 4, 8, 12). |

### Machine relaunch (Phase E-1, 2026-05-10)

| Function | Writes to | Status |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `set_machine_relaunched_at(p_machine_id uuid, p_relaunched_at timestamptz, p_reason text)` | `machines` (UPDATE: relaunched_at, updated_at) | ✅ NEW 2026-05-10 — canonical writer for `machines.relaunched_at`. When set, the lifecycle engine treats the machine as a new deployment from this timestamp, overriding `first_sale_at` as the RAMPING grace anchor. Used for physical relocations to new venues where historical sales should not influence current scoring. Validates non-future timestamp, refuses non-Active machines, role-gated to operator_admin/superadmin/manager. Audited via the standard machines audit trigger. Articles 1, 4, 5, 8. Edge function `evaluate-lifecycle` v13+ reads this field. |
| `engine_finalize(p_plan_date date, p_dry_run boolean DEFAULT false)` | `daily_plan_drafts` (UPDATE: status flip draft → finalized | overruled) | ✅ NEW 2026-05-06 — ENGINE FINALIZE. Canonical UPDATE writer for daily_plan_drafts status. Reads all drafts for plan_date, runs conflict-resolution rules: R1+R2+R4 (SWAP touches a shelf → ADD on that shelf overruled), R6 (EXPIRY_OPT_PUSH directive surfaced as warning), R3 + R5 (warnings only). Updates draft rows with proper terminal-state metadata (finalized_at OR overrule_reason). Returns jsonb summary {total_drafts, finalized, overruled, resolutions, warnings}. Phase C-4 prototype — does NOT yet write refill_plan_output. Step 5 orchestrator will wire write_refill_plan after engine_finalize runs. Articles 1, 4, 5, 8, 12. System-callable (cron via service_role) and operator-callable. |
| `propose_add_plan(p_plan_date date, p_min_qty_threshold int DEFAULT 1, p_days_cover int DEFAULT 21)` | `daily_plan_drafts` (INSERT: REFILL drafts) | ✅ UPDATED 2026-05-14 (G1+G2+G3 v2) — ENGINE ADD v2. Three-track target: (A) velocity × days_cover, (B) fill% floor — shelves ≤50% fill → target 70% regardless of velocity, (C) capacity boost — fill to 80% of gap since driver already on-site. Final target = MAX(A,B,C) capped at max_stock. Zero-vel skip refined: only skips if fill% > 50% (depleted shelves caught by track B). **G3 multi-variant split:** pod_products with multiple Active boonz_product mappings get per-variant WH stock check; qty split evenly via FLOOR(qty/N) + remainder to oldest-expiry variant, one draft row per variant. Prevents "Barebells → Caramel Cashew default with zero WH stock" incident. New return fields: `version` (v2_g1g2g3), `skipped_no_wh_stock`, `multivariant_splits`, `fill_floor_applied`, `capacity_boost_applied`. Dry-run against OMDCW May 14: 56u vs 61u CS-manual (92% match, delta = strategic overrides). INSERT-only writer. Articles 1, 4, 5, 8, 12. |
| `propose_swap_plan(p_plan_date date, p_max_swaps_per_machine int DEFAULT 2, p_min_substitute_score numeric DEFAULT 10.0)` | `daily_plan_drafts` (INSERT: REMOVE + ADD_NEW pairs) | ✅ UPDATED 2026-05-10 (D-3 + D-3a) — ENGINE SWAP, two-pass. **Pass 1 (strategic):** walks active `decommission` intents, joins to `pod_inventory` rows for products in scope, emits SWAP REMOVE+ADD_NEW pairs with `linked_intent_id` set so reconcile can credit progress. Shelf resolved via `pod_inventory.shelf_id → shelf_configurations` (no unsafe fallback). **Pass 2 (autonomous):** original slot_signal-driven swaps for ROTATE_OUT / DEAD / WIND_DOWN slots not addressed in Pass 1. Per-machine cap shared across passes; strategic intents take priority. **Substitute selection** (both passes): Pearson via `get_similar_products` with category fallback (slot_lifecycle.velocity_30d aggregated, deterministic UUID tiebreaker) when Pearson returns nothing. Default `p_min_substitute_score` recalibrated 30.0 → 10.0 against observed Pearson distribution (median in-category top score = 28.18, floor at 10). **Guardrails** (both paths): substitute must not have an Active pod_inventory row on target machine (prevents "swap Pepsi for Pepsi"); substitute must not itself be in an active decommission intent (prevents replacing one phase-out with another). New return fields: `intent_driven_swaps`, `pearson_substitutes`, `fallback_substitutes`, `skipped_no_shelf`, `min_substitute_score`. INSERT-only writer. Articles 1, 4, 5, 8, 12. Phase D backlog: R3 brand guardrail, R5 14-day cooldown, R7 60% shelf rule, MACHINE_TO_WAREHOUSE return when no substitute. |
| `reconcile_intent_progress(p_plan_date date)` | `strategic_intents` (UPDATE: progress.applied_units, progress.events, status, closed_at, closure_reason) | ✅ UPDATED 2026-05-10 (D-3b) — Closes the strategic-intent loop. Walks finalized `daily_plan_drafts` for the given plan_date that carry `linked_intent_id` AND `action='REMOVE'`, credits `intent.progress.applied_units`, appends to `progress.events` (dedup by draft_id via `@>` containment), and auto-completes when `applied_units >= (target_qty - max_residual_units)`. Action filter added in D-3b to fix double-counting bug (SWAP pairs link both REMOVE and ADD_NEW; only REMOVE counts toward decommission progress). Future additive intent types (`introduce`, `rotate_in`) will need a CASE-per-intent_type filter. System-callable (cron via service_role) and operator-callable. Articles 1, 4, 5, 8. Called by `orchestrate_refill_plan` as the 4th and final stage. |
| `abandon_intent(p_intent_id uuid, p_reason text)` | `strategic_intents` (UPDATE status→abandoned, closed_at/closed_by/closure_reason) | ✅ Canonical intent-closer. Status guard: abandonable only from `queued`/`in_progress`/`blocked`. DEFINER, sets `app.via_rpc`, `FOR UPDATE` row lock. Roles: operator_admin/superadmin/manager. Articles 1, 4, 5, 8, 12. **UPDATED 2026-06-10 (PRD-021, `prd021_abandon_intent_service_role_bypass`):** added the standard service-role bypass (`v_user_id IS NOT NULL AND NOT role-ok`) so cron/service-role can close intents (used to lift the Ritz Cracker decommission `ba1ef467`); `closed_by` is NULL under service-role. Cody ✅. |
| `orchestrate_refill_plan(p_plan_date date)` | (no direct writes — calls propose_add → propose_swap → engine_finalize → engine_publish_to_refill_plan → reconcile_intent_progress) | ✅ UPDATED 2026-05-10 (D-5b) — Phase D-5b orchestrator. Calls the five canonical stages in sequence: ADD → SWAP → FINALIZE → PUBLISH → RECONCILE. ADD and SWAP are parallel-independent (no cross-read), FINALIZE handles conflict resolution, PUBLISH writes finalized drafts to refill_plan_output via write_refill_plan, RECONCILE credits applied_units back to strategic_intents. Returns combined jsonb summary with each stage's output + total_duration_ms. **First D-5b run:** 156 ADD + 39 SWAP × 2 = 234 drafts → 224 finalized + 10 overruled → 667 rows published (with prior-test-run accumulated drafts) → 4 reconcile events, 1 auto-completed intent. 4.66s wall-clock. |
| `engine_publish_to_refill_plan(p_plan_date date)` | (no direct writes — adapter that calls write_refill_plan) | ✅ NEW 2026-05-10 (D-5b) — PUBLISH stage. Reads finalized daily_plan_drafts for plan_date, maps action vocabulary to title case (REFILL→Refill, REMOVE→Remove, ADD_NEW→Add New) — field-packing FE keys on title case (CS memory). Resolves machine_id → official_name, boonz_product_id → name; for ADD_NEW drafts (no pod_product_id), looks up global default pod via product_mapping. Skips MACHINE_TO_WAREHOUSE drafts (refill_plan_output doesn't yet support that action; D-3d adds it). Hands assembled jsonb to write_refill_plan (canonical refill_plan_output writer) — PUBLISH is a thin adapter, not a parallel write path (Article 1). Returns `published`, `skipped_m2w`, `skipped_no_machine`, `skipped_no_product`, `write_result`. **Idempotency:** write_refill_plan does scoped DELETE-of-pending then INSERT, so re-running orchestrate_refill_plan during a review window replaces unreviewed rows for affected machines. Approved rows untouched. Articles 1, 4, 5, 8, 12. |
| `propose_rotation_plan(p_horizon_days int DEFAULT 21, p_min_fit_score numeric DEFAULT 50.0, p_max_proposals_per_source int DEFAULT 3, p_dry_run boolean DEFAULT false)` | `rotation_proposals` (INSERT pending rows) | ✅ NEW 2026-05-06 — Engine 2 main loop. Iterates `v_warehouse_at_risk` (urgent buckets only), scores every active machine via `score_machine_for_product`, INSERTs top-N pending proposals. `trigger_reason='expiry_risk'`, `proposal_type='wh_to_machine'` in Phase B.2b. System-callable (cron via service_role) and operator-callable. Articles 1, 4, 8. First run: 21 inserts, 3 dedup-skips, 0 hard-blocks-below-threshold, 21s wall-clock. |
| `apply_rotation_proposal(p_proposal_id uuid, p_plan_date date, p_notes text DEFAULT NULL)` | `rotation_proposals` (UPDATE pending → applied) | ✅ NEW 2026-05-06 — CS approval path. Validates pending status, sets `applied_to_plan_date`, `reviewed_at`, `reviewed_by`. Operator-only (no system bypass). **Phase B prototype: status flip only — does NOT create a planned_swaps row. Phase C wires it into the refill engine.** Articles 1, 4, 5, 8. |
| `reject_rotation_proposal(p_proposal_id uuid, p_reason text)` | `rotation_proposals` (UPDATE pending → rejected) | ✅ NEW 2026-05-06 — CS veto path. Captures p_reason in notes for downstream weight-tuning analysis. Operator-only. Articles 1, 4, 5, 8. |
| `mark_proposals_expired(p_age_days int DEFAULT 3)` | `rotation_proposals` (UPDATE pending → expired) | ✅ NEW 2026-05-06 — daily housekeeping. System-callable (pg_cron via service_role) and operator-callable. Articles 1, 4, 5, 8, 11 (cron wiring pending Phase B.3). |

> **PRD-054 (2026-06-23) note (no signature change):** `receive_dispatch_line`'s Remove branch already carries the durable venue_team (VOX) guard — when `product_mapping.source_of_supply='venue_team'` for the dispatch (machine+boonz), it skips ALL `warehouse_inventory` credit, logs `vox_return_log`, path `remove_venue_team_no_wh_credit`, sets `item_added=true` (Art 4/6/8). `wh_approve_remove_receipt` + `wh_approve_remove_receipt_multivariant` delegate credit to it, so the guard covers all three receive paths. Verified T1-T6 rolled-back; no function change. Companion view `v_pending_wh_remove_confirmations` recreated to exclude `is_m2m=true` legs (migration `prd054_a_returns_queue_exclude_m2m`).

> **PRD-055 (2026-06-23):** notes consolidated into Signals (`refill_edit_signals`). New read-only view `v_action_tracker_issues` (security_invoker) = `action_tracker` minus `driver_feedback` — the kept CS Issues/bug board (Tracker tab renamed to Issues, reads this). `refill_edit_signals.signal_type` CHECK extended with `'note'` (migrated field/operational notes are inert: `engine_swap_pod` reads only `signal_type='swap_rejected'`; md5 `90f26896…` unchanged). `machine_field_notes` write path retired via REVOKE (Art 13; SELECT kept, not dropped). P5 (`prd055_p5_redirect_driver_writers_to_signals`): `driver_propose_adjustment`/`driver_report_dispatch_outcome` redirected — their `action_tracker` driver-feedback/re-dispatch inserts now write `refill_edit_signals` (source='action', signal_type='note', engine-inert) so new driver feedback lands in Signals; other writes + validation + app.via_rpc preserved; engine md5 `90f26896…` unchanged.

## Read-only helpers — 10 functions (no A.5 patching needed)

These do not mutate; they exist as DEFINER for RLS-bypass on read paths (with the exception of the INVOKER ones noted below — newer additions prefer INVOKER per Cody Article 4 default).

- `recommend_swaps_for_machine(p_plan_date date, p_machine_id uuid, p_k int DEFAULT NULL)` → **read-only helper (plpgsql STABLE, INVOKER; EXECUTE to anon/authenticated/service_role).** ✅ 2026-07-29 (`prd106_recommend_swaps_for_machine`, PRD-106). Machine-level swap recommender: returns K DISTINCT, WH-backed, in-machine-deduped swap-ins for the machine's K dead/swap-tagged shelves (`pod_swaps` unresolved `dead`/`rotate_out` rows, `tagged_by LIKE 'engine_add_pod%'`). WH availability aggregated by `boonz_product_id` FIRST via canonical `v_wh_pickable` then mapped to pod grain (kills the ~10-40x `product_mapping` fan-out; Red Bull 714→17). Basket affinity via canonical `get_candidate_affinity` (no inline Pearson — Art 16). Exclusions: in-machine (unless `slot_lifecycle.signal='DOUBLE DOWN'`), decommission `strategic_intents`, Evian 1L, `venue_team` source on non-VOX, catch-alls, `_coexistence_blocks`/`_travel_scope_blocks`, `product_size_fit` at shelf size ≥ `min_refill_qty`. Score = `GREATEST(get_candidate_affinity,0.30)*ln(1+fleet_units_30d)*avail_factor`; greedy distinct-K by capacity; `qty=LEAST(cap,wh)`. No candidate → qty-0 `no_viable_swap_candidate` (never M2W, CS 2026-07-28). No writes. Cody Articles 1,2,3,12,14,16. **Consumer wiring into `engine_swap_pod`/`engine_finalize_pod` PARKED for the Wave-2 engine-freeze** (see `PRD-106-EXECUTION-LOG.md`).

- `preflight_refill_plan(p_plan_date date)` → **read-only gate helper (no writes).** ⚠️ **BACKFILLED 2026-07-30 (PRD-110 leg 7, PARKING-LOT S-12) - shipped by PRD-109 on 2026-07-29 and never registered.** The stitch **commit gate**: `stitch_refill_plan` calls it before committing and enforces the verdict according to `refill_policy_params.preflight_enforcement` (`'warn'` today - CS burn-in pending; do NOT flip to `'block'` without CS). Currently `set_version v2`. Returns a verdict plus per-invariant findings for **12 invariants INV-01..INV-12** covering: plan/line conservation, shelf-and-pod existence and enablement, WH availability vs planned qty, mapping resolvability, duplicate lines, action-vocabulary legality, and the **absence** detectors. Two things a future editor must not "simplify":
  - **INV-06 is plan-conservation for `REMOVE` / `M2W` only.** It was corrected in PRD-110 P0.6(d): a REMOVE parent is _satisfied_ when a matching `Remove` line exists in `refill_plan_output` (join by plan/machine/shelf/pod + action). It is **deliberately disjoint** from the registered metric "Refill execution accuracy" (`v_refill_accuracy`), which covers `REFILL` / `ADD_NEW`. Merging them silently loses one domain. See METRICS_REGISTRY, PRD-110 P0.6 section.
  - **INV-10 is an ABSENCE detector** (PRD-109's Extra Gum ghost stockout: stitch _dropped_ the line, so no row existed to fail INV-01). Rewriting it as a predicate over existing rows re-opens the incident it was built for.
  - ⚠️ `proacl` grants `EXECUTE` to **`anon`**. Left untouched here (PRD-110 LAW 10, no scope drift); it belongs to the open backend-tightening carry-forward (revoke-anon batch) from the Batch-3 FE deploy.
  - ⚠️ `pod_refill_plan` holds BOTH the REMOVE and the M2W parent for one shelf/pod, so action-matched conservation joins give false positives (PRD-109 landmine).
  - ✅ **SECOND CONSUMER 2026-07-31 (PRD-110 leg 50, P2.6):** `commit_refill_plan` now calls it too. The single `refill_policy_params.preflight_enforcement` flag arms **both** gates — stitch and commit — so the CS burn-in flip is still exactly one decision, not two. Still `'warn'`.

- `preflight_override_v3(p_plan_date date, p_reason text)` → **NEW 2026-07-31 (PRD-110 leg 50, migration `prd110_p26_preflight_gate_at_commit`, BUILD SPEC P2.6 / WS-B2).** DEFINER writer of `preflight_override_log` (`source='commit'`); the **single audited escape hatch** for a commit blocked by preflight. Role gate operator_admin/superadmin/manager with the `auth.uid() IS NULL` system bypass; sets `app.via_rpc`+`app.rpc_name`; requires `p_reason` ≥ 10 characters. Refuses with `status='not_needed'` when the verdict is not `FAIL` (nobody banks a blanket grant against a plan that later goes bad) and with `status='already_granted'` when an unspent grant exists (grants do not stack). `REVOKE`d from `PUBLIC` and `anon`; EXECUTE to authenticated + service_role. Cody ✅ Articles 1, 2, 4, 7, 8, 12, 14, 16.
  - ⭐ **The grant is SINGLE USE, and consumption is an INSERT, never an UPDATE.** `preflight_override_log` carries `pol_no_update`/`pol_no_delete`; a postgres-owned DEFINER would have bypassed RLS and stamped a `consumed_at` anyway, defeating Article 7 invisibly. So the consumption record lives on the **consumer**: `refill_commit_log.preflight_override_id` names the grant it spent, and a partial UNIQUE index makes a second spend physically impossible. **When an append-only log needs "consumed" state, put the state on the consumer.**
  - 📌 `preflight_override_log` now has **two** writers, distinguished by `source`: the inline `p_force` path in `stitch_pod_to_boonz` (`'stitch'`, the backfilled default and correct for every pre-P2.6 row) and this RPC (`'commit'`). Article 1 is satisfied per-gate, not globally — do not add a third.

- `snapshot_shelf_stock()` — **NEW 2026-06-10 (PRD-4b, migration `phasef_proc_shelf_stock_daily_snapshot`).** DEFINER **writer** of the non-protected analytics table `shelf_stock_daily` (sole write path; idempotent `ON CONFLICT` upsert of per-(machine,pod_product) aggregates from `v_live_shelf_stock`). Caller gate: system/cron (`auth.uid() IS NULL`) or operator_admin/superadmin; sets `app.via_rpc`+`app.rpc_name`. Scheduled by pg_cron `shelf_stock_daily_snapshot` (20:30 UTC). Accrues days-in-stock history for a future availability-adjusted forecast. Cody ✅ (Articles 2, 4, 11, 12).
- `boonz_product_block_reason(p_boonz_product_id uuid)` — **NEW 2026-06-10 (PRD-1, migration `phasef_proc_block_decommissioned_po_writes`).** STABLE SECURITY DEFINER (RLS-independent so create/edit/view share one verdict). Returns `'decommissioned_product' | 'never_order_flavor' | NULL`; non-NULL ⇒ product is BLOCKED for ordering (≥1 `supplier_products` row, all Inactive never-order). Sole source of the orderable verdict for `create_purchase_order`, `edit_purchase_order_line`, and view `v_procurement_blocked_products`. GRANT EXECUTE authenticated, service_role. Cody-reviewed (Articles 1, 4, 12). Companion read-only view `v_procurement_blocked_products(boonz_product_id, boonz_product_name, product_category, block_reason, supplier_notes)` backs the FE "Blocked" group.
- `get_open_po_lines(p_supplier_id uuid DEFAULT NULL)` — **NEW 2026-06-11 (PRD-022 D5, migration `prd022_d5_get_open_po_lines`).** STABLE SECURITY DEFINER, LANGUAGE sql, no writes. Returns open PO lines (`received_date IS NULL AND purchase_outcome <> 'not_purchased'` — same predicate as `get_procurement_demand.on_order` so D1 chips reconcile) with optional server-side supplier filter; columns po_line_id/po_id/po_number/supplier_id/supplier_name/boonz_product_id/boonz_product_name/ordered_qty/price_per_unit_aed/expiry_date/purchase_date/age_days. Powers `/app/procurement` D1 ordered-state chips + D3 Open POs drawer. DEFINER for reader parity (INVOKER would also suffice). GRANT authenticated, service_role. Dara + Cody ✅ (Articles 4, 12).
- `get_procurement_demand_pod(p_lookback_days integer DEFAULT 14, p_source text DEFAULT 'boonz')` — **NEW 2026-06-10 (PRD-3, migration `phasef_proc_demand_pod_level_rpc`).** STABLE SECURITY DEFINER, LANGUAGE sql, no writes. Returns pod_product-level demand (sales_14d, velocity_per_day, category-context `ctx_multiplier`, forecast_demand, mapped_variant_count, `pod_breakdown` jsonb) BEFORE the mix_weight trickle-down that `get_procurement_demand` collapses. Each breakdown entry carries mix_weight/split_pct/attributed_14d/source_of_supply + PRD-1 `block_reason`. Same pod-sales window + `demand_context_factors` machinery as the boonz RPC so the two FE tabs reconcile. Powers `/app/procurement` Demand "Pod demand" sub-tab. DEFINER for parity with sibling `get_procurement_demand`. GRANT authenticated, service_role. Cody-reviewed (read-only, Articles 1 n/a, 4, 12).
- `get_refill_session_readiness(p_plan_date date DEFAULT CURRENT_DATE+1)` — **NEW 2026-06-18 (PRD-035 WS-D, migration `prd035_c_refill_session_readiness`, file `20260618094000_*`).** STABLE SECURITY INVOKER, LANGUAGE sql, no writes. Session-readiness snapshot built when a refill plan opens: one row per in-scope shelf (`pod_refill_plan` REFILL/ADD_NEW, status draft|approved) resolving pod → mapped boonz flavor(s) → on-shelf flavor → REAL pickable WH (quarantine + per-machine reservation netted on top of canonical `v_wh_pickable`) → `readiness` verdict (`can_fill` | `can_fill_via_sibling` | `cant_fill_wh_zero` | `cant_fill_unmapped`) + human `reason`, plus mapping/onboarding health and WH expiry risk. Verdict logic mirrors the WS-C stitch line-builder so readiness predicts exactly what stitch will do. Reads `pod_refill_plan`, `v_wh_pickable` (Article 16 row 34 — consumed, not re-derived), `v_pod_inventory_latest` (on-shelf flavor identity only), `product_mapping`, `machines`/`shelf_configurations`/`pod_products`/`boonz_products`. Dara + Cody ✅ (read-only fast-path; Articles 12, 16).
- `get_active_planogram`
- `get_machine_planogram`
- `get_pod_inventory_for_machine`
- `get_warehouse_summary`
- `get_refill_plan_for_date`
- `get_settlement_for_partner`
- `get_user_role` (returns role from `user_profiles` to FE)
- `get_per_machine_performance(p_date_from date, p_date_to date, p_venue_group text, p_machine_names text[])` — **NEW 2026-05-05.** Returns a JSON array of per-attributed-machine WEIMI vs Adyen rollups. SECURITY INVOKER, LANGUAGE sql STABLE — RLS applies via `v_sales_history_attributed` and `v_adyen_transactions_attributed` (both `security_invoker = true`). Single greppable call site for `/app/performance` Sites & Machines and any per-machine dashboard. Splits repurposed machines automatically (e.g. ACTIVATE-2005 vs MPMCC-2005). Refund-netted `adyen_net_cash_aed` per row.
- `score_machine_for_product(p_target_machine_id uuid, p_boonz_product_id uuid, p_horizon_days int DEFAULT 21, p_proposed_qty int DEFAULT 5)` — **NEW 2026-05-05.** Engine 2 fit scorer. Returns `{score, hard_block, breakdown}` jsonb where score is 0-100 and breakdown carries per-component scores (throughput 35%, archetype_fit 20%, location_fit 15%, open_capacity 15%, urgency 10%) plus the inputs that drove them. SECURITY INVOKER, LANGUAGE sql STABLE — reads `v_machine_absorption_capacity`. Hard cutoffs surface as `hard_block` reason: `machine_excluded`, `machine_inactive`, `travel_scope_vox_locked`. Called by `propose_rotation_plan` (Phase B.2b) and ad-hoc by operators reviewing rotation candidates.
- `get_similar_products(p_boonz_product_id uuid, p_top_n int DEFAULT 5, p_min_score numeric DEFAULT 10.0)` — **NEW 2026-05-06.** ENGINE PRODUCT CORRELATION v1 lookup. Returns ranked similar products (score 0-100) for a given boonz_product_id with shared_machines, Pearson correlation, and source label. SECURITY INVOKER, LANGUAGE sql STABLE — reads `v_product_basket_affinity`. v1 substrate is machine basket affinity; future versions will combine sales co-purchase + LLM enrichment substrates and expose source per row. First-run distribution: 6,960 pairs total — 436 strong (≥50), 920 moderate, 2,574 weak, 3,030 noise.
- `get_po_edit_history(p_po_id text)` — **NEW 2026-05-23 (PRD-001).** Powers the "Edit history" pill on `/field/orders` and the post-receipt warning banner on `/field/receiving/[poId]`. SECURITY INVOKER, LANGUAGE sql STABLE — reads `procurement_events` (filter `event_type='po_line_edited'`) joined to `user_profiles` for the actor name. Returns `event_id, po_line_id, actor_id, actor_name, actor_role, changed_at, before, after, reason` ordered newest-first. Covered by `idx_procurement_events_po_id`.
- `get_vox_consumer_report(p_pods text[], p_consolidated boolean, p_date_from date, p_date_to date)` — **DOCUMENTED 2026-06-01.** Backs `/refill/consumers` (MAFE). SECURITY INVOKER, LANGUAGE plpgsql STABLE, TimeZone Asia/Dubai. Returns one big jsonb: `summary` (totals, captured = Adyen SettledBulk for the stores + `cash_recovery_log`, default*rate/disc_count over matched baskets), `transactions` (basket-level `recent_txns`), `discrepancies`, plus daily/weekly/dow/hourly/product/machine/funding/card/wallet rollups. Scope = `machines WHERE venue_group='VOX' AND status='Active'` filtered to Mercato/Mirdif by `pod_location`. Baskets grouped by `regexp_replace(internal_txn_sn,'*\d+$','')`; Adyen joined by `merchant_reference`. **UPDATED 2026-06-01 (`phaseF_vox_consumer_report_raise_recent_txns_limit`):** `recent_txns`cap raised`LIMIT 2000`→`LIMIT 100000`so the Default list reconciles with`summary.disc_count` (was showing 15 of 32). Article 12. **UPDATED 2026-06-08 (`phaseF_vox_consumer_report_basket_level_items_filter`):** the `vox_sales` amount filter changed from per-line (`total>0 OR paid>0`) to basket-level (window `SUM`over`base_txn_sn` `> 0`). Some WEIMI baskets lump all amounts onto line 1 and record sibling lines at 0/0; the old per-line filter dropped those siblings, so `items`showed only 1 product (and undercounted`units`). Now the whole basket is kept as long as the basket total is positive. Revenue/captured/default_gap/disc_count unchanged (hidden lines sum to 0.00); 12 baskets / +22 units affected over Feb–Jun. Article 12.

## Audit / system helpers — 4 functions (left as-is)

- `audit_machine_duplicates` — read-only diagnostic.
- `log_wh_mutation` — pre-existing audit hook on `warehouse_inventory`. Will be superseded by the generic trigger in A.4 but not removed (deprecation per Article 13 — 90-day monitor).
- `check_edge_function_service_key` — guard used by edge functions.
- `audit_log_write` — **NEW (Phase A.3, 2026-04-26).** Generic AFTER trigger function for `write_audit_log`. `SECURITY DEFINER`. EXECUTE revoked from `anon`/`authenticated`/`PUBLIC`. Reads `app.via_rpc` and `app.rpc_name` GUCs, captures PK from `TG_ARGV[0]`, records full row payload. Installed on protected tables in A.4.

## Trigger-only — 3 functions (not callable from FE; bypass A.5)

- `auto_audit_warehouse_inventory` (UPDATE trigger)
- `auto_audit_warehouse_inventory_insert` (INSERT trigger)
- `handle_new_user` (auth trigger — creates `user_profiles` row on signup)

## System-of-record propagation triggers — 1 function (NEW 2026-05-14)

These trigger functions cascade authoritative state from a parent table to dependent snapshot columns. They are NOT new canonical writers under Article 1 — they touch ONLY snapshot fields, never state-machine columns, and they're gated by an explicit FK on the dependent row. SECURITY DEFINER with pinned `search_path`. Set `app.via_rpc='true'` + `app.rpc_name` so the universal audit trigger attributes the cascaded UPDATE.

- `sync_dispatch_expiry_from_pinned_wh()` — **NEW (2026-05-14, BUG-012 structural fix).** Bound `AFTER UPDATE OF expiration_date ON warehouse_inventory FOR EACH ROW`. When the wh row's `expiration_date` changes (typical trigger: WEIMI snapshot re-ingest or warehouse-manager correction), propagates the new value to every un-finalized `refill_dispatching` row pinned to this wh row via `from_wh_inventory_id` (`item_added=false AND returned=false`). Touches only `expiry_date` — never identity or state columns. Emits `info` `monitoring_alerts` row with `source='bug012_expiry_sync'` summarising rows synced. Owner=postgres. Satisfies Constitution Articles 1 (system-of-record propagation, not a new canonical writer), 4 (validates DISTINCT change and sets audit GUCs), 8 (universal audit picks up the cascade). See `CHANGELOG.md` entry dated 2026-05-14.

## Trigger-only proposers — 2 functions (NEW 2026-05-04, NOT YET BOUND)

These functions write to `warehouse_inventory_status_proposal` only — never UPDATE `warehouse_inventory.status`. They are bodies-only as of 2026-05-04 and will be bound to `warehouse_inventory` triggers in `m3b` post-dispatch tonight. Article 6 (revised) compliant: they propose, the manager confirms.

- `propose_inactivate_on_zero_stock()` — fires AFTER UPDATE on `warehouse_inventory` when both stock columns just dropped to zero on an Active row. Idempotency guard skips duplicate pending proposals from the same proposer.
- `propose_reactivate_on_stock_return()` — fires AFTER UPDATE/INSERT on `warehouse_inventory` when total stock just transitioned 0→>0 on an Inactive row (procurement / restock case). Same idempotency guard.

## Deprecated — 1 function (Phase A.2 complete)

- `rename_machine_in_place_legacy` — replaced by `repurpose_machine`. **Deprecated 2026-04-25** via migration `phaseA_a2_deprecate_rename_machine_legacy`. Now `SECURITY INVOKER` with `EXECUTE` revoked from `anon`/`authenticated`. `service_role` retains EXECUTE through the monitor window. **Scheduled DROP date: 2026-07-24** (90 days after deprecation, per Article 13). Caller scan at deprecation time returned zero callers across code, n8n, cron, triggers, and other DEFINERs.

## Lifecycle — NEW 2026-05-31 (Phase F)

- `set_product_lifecycle_status(p_pod_product_id uuid, p_status text, p_reason text DEFAULT NULL)` → writes `lifecycle_product_status` (non-protected). ✅ 2026-05-31. Sole canonical writer for the lifecycle inclusion flag (status active/inactive). SECURITY DEFINER: requires `auth.uid()`, role gate `operator_admin/superadmin/manager`, validates status enum + `pod_products` FK, sets `app.via_rpc`/`app.rpc_name`. Audited via universal `audit_log_write('pod_product_id')` trigger on the table. Cody-reviewed (Articles 1, 2, 4, 8). Migration `phaseF_lifecycle_product_status`.

## Refill System v2 — NEW 2026-06-01 (Phase 0)

- `cron_refill_draft_missing_alert()` → writes `monitoring_alerts` (non-protected alert ledger). ✅ 2026-06-01. B1 reliability monitor. Cron-only (jobid 23, `15 16 * * *` = 20:15 Dubai); reads `refill_plan_output` + `machines_to_visit`, writes one deduped finding (`source='refill_draft_missing'`, severity `critical`) when tomorrow's draft is missing, with the recomputed reason + `action_needed`. SECURITY DEFINER: cron-context bypass (`auth.uid() IS NULL` proceeds), authenticated caller must be `operator_admin/superadmin/manager`; sets `app.via_rpc`/`app.rpc_name`. No protected entity touched (alert-only; does not auto-confirm machines). Cody-reviewed (Articles 4, 8, 11, 12, 14). Migration `refillv2_b1_draft_missing_alert`.
- `cron_shelf_index_drift_alert()` → writes `monitoring_alerts` (non-protected alert ledger). ✅ 2026-06-01. B2 regression guard. Cron-only (jobid 24, `30 3 * * *` = 07:30 Dubai); reads the new read-only view `v_shelf_aisle_index_drift`, writes one deduped finding (`source='shelf_aisle_index_drift'`, severity `critical`) if any live slot violates the WEIMI `aisle_code(0-indexed)+1 == slot_name(1-indexed)` invariant or has a malformed aisle_code. SECURITY DEFINER: cron-context bypass, authenticated caller must be `operator_admin/superadmin/manager`; sets `app.via_rpc`/`app.rpc_name`. Additive; does NOT modify the (already-correct) refill read path. Cody-reviewed (Articles 4, 8, 11, 12, 14). Migration `refillv2_b2_shelf_index_drift_guard`.
- `v_shelf_aisle_index_drift` (read-only view, SECURITY INVOKER) → diagnostic backing the B2 guard above. verdict in (`ok`|`index_drift`|`unparseable_aisle_code`); `expected_slot_name` mirrors `seed_shelf_configurations`. Same migration.

## Refill System v2 — Phase 1 lifecycle writers (2026-06-01+)

- `void_refill_plan(p_plan_date date, p_reason text)` → writes `pod_refill_plan` (protected; status state machine). ✅ 2026-06-01. Canonical whole-plan void: archives every `draft/approved/stitched` row to the new `voided` terminal state (never DELETE), appends `{voided_reason,voided_by,voided_at}` to `reasoning`. DEFINER, role `operator_admin/superadmin`, sets `app.via_rpc`/`app.rpc_name`, reason ≥10 chars. Refuses when `refill_plan_output` for the date is past `pending` (plan dispatched). Audited by `tg_audit_pod_refill_plan`. Cody-reviewed (Articles 1, 3, 4, 5, 8, 12). Migration `refillv2_p1_void_refill_plan` (also extended `pod_refill_plan_status_check` with `voided`).
- `reschedule_refill_plan(p_from_date date, p_to_date date, p_reason text)` → writes `pod_refill_plan` + `machines_to_visit` (both protected). ✅ 2026-06-01. Moves a whole plan between dates (key-move `UPDATE plan_date` on the visit list + live draft rows; never DELETE). DEFINER, `operator_admin/superadmin`, GUCs set, reason ≥10, `from≠to`. Refuses if source dispatched (`refill_plan_output` past pending) or target occupied. `pod_refill_plan` audited by `tg_audit_pod_refill_plan`; `machines_to_visit` move traceable via `reasoning.rescheduled_from` (no audit trigger on that table — matches its existing writers). Cody-reviewed (Articles 1, 3, 4, 5, 8, 12). Migration `refillv2_p1_reschedule_refill_plan`.

## Refill reliability batch (2026-06-04, PRD WS2/WS4/WS5/WS6/WS7)

- `skip_dispatch_line(p_dispatch_id uuid, p_reason text)` → writes `refill_dispatching` (protected). ✅ 2026-06-04. WS2a canonical "skip line" writer: sets `skipped=true, include=false`, bumps `edit_count`, records `skip_reason/skipped_by/skipped_at` on the row so an unfulfillable line never hard-blocks machine submission. DEFINER, role `field_staff/warehouse/operator_admin/superadmin/manager`, reason ≥10 chars, GUCs set. Refuses already-picked-up / already-skipped / cancelled lines. Added to `enforce_canonical_dispatch_write` allow-list. Migration `refillv2_ws2a_skip_dispatch_line` (also `ALTER refill_dispatching ADD skipped/skip_reason/skipped_at/skipped_by`). Cody-reviewed (Articles 2, 4, 8, 12).
- `push_plan_to_dispatch(p_plan_date date, p_machine_name text)` v5 → writes `refill_dispatching` (protected). ✅ 2026-06-04 (edit-aware overload). WS2b: before regenerating a plan row for `(machine, date, shelf, pod_product)`, skips it if the operator already reworked that key at dispatch level (`created_by_edit OR edit_count>0 OR cancelled OR skipped`), consuming the plan line (`dispatched=true`) and linking it instead of clobbering. Makes re-push idempotent + edit-aware (fixes the VML A01 manual-swap resurrection). Legacy `(p_machine_name, p_plan_date)` overload untouched — flagged for deprecation (Article 13). Migration `refillv2_ws2b_push_edit_aware`. Cody-reviewed (Articles 1, 4, 8, 12). **UPDATED 2026-06-04 → v6_resilient_bridge (PRD-018 BUG-C, migrations `prd018_bugc_resilient_dispatch_bridge` + `prd018_bugc_bridge_severity_fix`):** the per-machine loop body now runs in a per-row `BEGIN/EXCEPTION` sub-block so one raising row (block_orphan_internal_transfer / prevent_duplicate / NULL shelf) no longer aborts the whole machine's bridge — the bad row is counted (`lines_failed`) + logged to `monitoring_alerts` (`dispatch_bridge_failure`, critical) and left `dispatched=false` (visible), siblings still bridge. `internal_transfer` plan rows are skipped (they bridge via `swap_between_machines`; `lines_skipped_internal_transfer`). Idempotent cover-link guard links an existing live (non-cancelled, non-returned) dispatch row instead of inserting a duplicate. Returns `status='ok'|'partial'`. WS2b edit-aware preservation retained. Companion: the bridge trigger `trg_fire_dispatch_on_approval` now logs non-ok/exception to `monitoring_alerts` instead of a silent NOTICE. Verified in rolled-back tx. Cody ✅ (Articles 1, 4, 5, 8, 12). The legacy `(p_machine_name, p_plan_date)` overload remains untouched + flagged for deprecation (its existence forces explicit `::date`/`::text` casts when calling with literals). **UPDATED 2026-07-02 -> v7_prd071_autopair_m2m (PRD-071 WS-B, `prd071_wsb_push_v7_prepaired_m2m_drop_legacy_overload`):** legacy overload DROPPED (it made every PostgREST named-notation call fail 42725 'function is not unique', silently breaking FE approve->push). internal_transfer plan lines now insert as PRE-PAIRED M2M legs (dest-driven atomic pair, shared m2m_transfer_id, FEFO source batch split, source lines defer, skip-log to monitoring_alerts, never fails the push) satisfying block_orphan_internal_transfer; post-loop pair_internal_transfer_m2m safety net + provenance GUC restore. Full body now reconstructible from git (PRD-057 drift closed). Dry-run: pair_ok, WH delta 0, idempotent x2, engines md5 unchanged. Cody OK (Articles 1,3,4,6,8,12; Am.003/005).
- `engine_add_pod` v13 → writes `pod_refills` staging. ✅ 2026-06-04. WS4b: ingests `v_driver_feedback_demand` as a GREATEST demand floor on raw_qty/final_qty (`clamp_reason='driver_request'`), preserves §1 `wh_avail=0` pod-level suppression + `_assert_gate_zero`, marks contributing `driver_feedback` rows resolved (`resolved_by_engine='engine_add_pod_v13'`). Migration `refillv2_ws4b_engine_driver_demand`. Cody-reviewed (Articles 1, 4, 8, 12, 14). **⏳ DRAFT v14 (PRD-UNIFY Step 3, `prdunify_step3_engine_add_pod_calibrate`, NOT applied — Hard Rule 10 needs CS green light):** delegates per-shelf sizing to `compute_refill_decision` (single source) + rides the full decision in `pod_refills.reasoning`; only dials + decision emission change vs v13 (orchestration byte-identical); fixes the WIND-DOWN-refills-up bug.
- `compute_refill_decision(p_machine_id uuid, p_shelf_id uuid, p_boonz_product_id uuid, p_days_cover int DEFAULT 7)` → **read-only helper (SECURITY INVOKER, STABLE, no writes).** ⏳ DRAFT (PRD-UNIFY Step 2, `prdunify_step2_compute_refill_decision`, NOT applied). The ONE source of both `target_units` and `final_score`: stance from `slot_lifecycle.signal` (local) → `v_product_lifecycle_global_enriched.signal` (global) → `'KEEP'`; dosage velocity `0.6·velocity_7d + 0.4·velocity_30d`; dials table (cover_mult/floor_pct); `target = LEAST(GREATEST(velocity·dc·cover, floor·cap), cap)` with WIND DOWN/ROTATE OUT/DEAD drained ≤ current; `final_score = ROUND(demand_base × stance_mult × placement_mult × urgency_mult, 1)`. Both `engine_add_pod` v14 (qty) and `get_machine_slots_with_expiry` (display) consume it → one brain. Returns the `decision` jsonb persisted on `pod_refill_plan.decision`. GRANT EXECUTE to anon/authenticated/service_role. Cody ✅ (Articles 1, 4, 12, 14). Verified in rolled-back tx vs PRD A2/A4/A5.
- `get_machine_slots_with_expiry(p_machine_name text)` → read-only display reader (SECURITY INVOKER, STABLE). **⏳ DRAFT repoint (PRD-UNIFY Step 4, `prdunify_step4_get_machine_slots_repoint`, NOT applied):** DROP+CREATE adds `decision`/`final_score`/`stance` columns; `target_stock`/`refill_qty`/badges now come from `compute_refill_decision` (was `COALESCE(ri.target_stock, max_stock)` fill-to-max + standalone `base_score`); rows sort by Final Score; stops calling `compute_strategy`/`compute_local_strategy` for a target or score (those stay in DB, deprecated, badge/label only). FE `refill/page.tsx` moves in lockstep.
- **PRD-105 (APPLIED 2026-07-28, `expiry_truth_slots_shelf_keyed`):** `get_machine_slots_with_expiry` re-keyed from product-name to `shelf_id`. Name-keyed `product_boonz`/`product_expiry`/`prod_nearest_date`/`prod_nearest` CTEs (machine-blind, lowest-UUID variant) removed; replaced by `shelf_expiry` (MIN(expiration_date) per shelf over `v_machine_expiry_batches`) + `shelf_min_batch` (SUM(current_stock) at that MIN) + `shelf_top_boonz` (DISTINCT ON shelf, highest current_stock). `expiry_days=(min_exp-today)::int`, `expiry_qty=min_exp_qty` **unconditional** (7d window dropped), `nearest_expiry_*` mirror. `compute_refill_decision` now passed `shelf_top_boonz.boonz_product_id` — that arg is unused inside the fn, so scoring is byte-unchanged (decision coverage 544/544). Stays SECURITY INVOKER STABLE. Old body md5 `f57322b3c770e14c155008a9e10502b4`. Reads canonical `v_machine_expiry_batches` (Art 16 ✅).
- `get_machine_orphan_expiry(p_machine_name text)` → read-only reader (SECURITY INVOKER, STABLE). **PRD-059 origin (NULL-shelf batches off any live slot); PRD-105 (APPLIED 2026-07-28, `expiry_truth_orphan_live_aisle`): predicate `shelf_id IS NULL` → `(shelf_id IS NULL OR shelf_id NOT IN live_shelf)` where `live_shelf` = shelf_ids in the machine's live WEIMI aisle (RC-4). `boonz_product_id NOT IN live_boonz` exclusion kept per design → off-aisle ghosts whose product is live elsewhere stay suppressed (open item for CS). Old body md5 `e5e19b3cef7a2a6fcc504940410c4077`.**

### Refill-Day Phase 1 — RD-01 / RD-05 / RD-03 (⏳ DRAFT 2026-06-06, NOT applied)

- `add_machine_to_plan(p_plan_date date, p_machine_id uuid, p_confirm boolean DEFAULT true)` → writes `machines_to_visit` (protected). ⏳ DRAFT (RD-01, `rd01_create_plan_add_machine`). DEFINER; operator_admin/superadmin/warehouse + service-role bypass; inserts `status='cs_added'`, `add_source='operator'`, `is_included=true`, `confirmed_at` (when confirm), pulling the `v_machine_health_signals` snapshot; idempotent on (plan_date,machine_id) (re-include); refuses non-Active machines; **does NOT run the engine** (confirm gate preserved). Sets GUCs. Articles 4,5,8.
- `create_refill_plan(p_plan_date date, p_machine_ids uuid[])` → writes `machines_to_visit` via `add_machine_to_plan`. ⏳ DRAFT (RD-01). Atomic loop (one bad id rolls the whole call back). Same role gate. Does NOT run the engine.
- `pick_machines_for_refill(date)` → v7 reproduced verbatim + RD-01 ON CONFLICT reclaim (`add_source='picker', is_included=true`) so a picker re-pick reclaims an operator/sibling row. Diff-gated.
- `get_shelf_fefo_options(p_machine_id uuid, p_boonz_product_id uuid)` → **read-only helper (SECURITY INVOKER, STABLE).** ⏳ DRAFT (RD-05, `rd05_expiry_aware_fefo_pick`). Returns the WH batches for the product across the machine's source warehouse(s) (`primary_warehouse_id`+`secondary_warehouse_id`), Active + non-quarantined + `warehouse_stock>0` + non-expired, ordered FEFO with nearest-expiry `is_default`, each `{wh_inventory_id, warehouse_id, expiration_date, warehouse_stock, days_to_expiry, is_default}`. Empty array → FE "raise PO" (RD-02). GRANT anon/authenticated/service*role. \*\*Writer pin extension on `edit*/add_pod_refill_row` is HELD\*\* pending PRD-UNIFY apply.
- `driver_report_dispatch_outcome(p_dispatch_id uuid, p_outcome text, p_actual_qty int DEFAULT NULL)` → writes `refill_dispatching` (driver_outcome\* only) + `refill_edit_signals` (source='action', signal_type='note', engine-inert). ✅ live; PRD-055 P5 (`prd055_p5_redirect_driver_writers_to_signals`) redirected the re-dispatch punch-item from `action_tracker` to Signals so driver feedback lands in one channel (idempotency guard now on the `[driver_outcome re-dispatch <id>]` note tag). DEFINER; field_staff (ownership via `trip_events` driver↔machine↔date proxy — `dispatch_plan` doesn't exist) + operator/superadmin/warehouse bypass; enum-validated; never mutates quantity/action (Cody b); refuses to reverse a `picked_up` line; idempotent on dispatch_id+outcome. Articles 1,3,4,5,8,12.
- `driver_propose_adjustment(p_machine_id uuid, p_kind text, p_note text, p_boonz_product_id uuid DEFAULT NULL, p_shelf_id uuid DEFAULT NULL)` → writes `driver_recommendations` + `driver_feedback` (when product named) + `refill_edit_signals` (source='action', signal_type='note', engine-inert). ✅ live; PRD-055 P5 redirected the driver-feedback row from `action_tracker` to Signals. DEFINER; field_staff scoped to a recently-tripped machine + operator+; kind/note validated; sets GUCs. `driver_recommendations` is a new RLS'd table (NOT Appendix-A protected — proposal feed). Articles 1,4,5,8,12,14.
- `stitch_pod_to_boonz(p_plan_date date, p_dry_run boolean)` v17 → writes `refill_plan_output` via `write_refill_plan` (protected). ✅ 2026-06-04. WS6: WS1b multi-variant REMOVE/M2W resolution to concrete boonz variant (pod_inventory FEFO + even split + physical-fallback path) so swaps/reorgs stitch in one pass + WS6.2 suppression of resolved warehouse-sourced variants with 0 stock anywhere (vox/internal exempt). Confirm-on-write-ok gate (2026-06-03) merged inline so re-baseline cannot revert it. Migration `refillv2_ws6_suppress_zero_anywhere`. Cody-reviewed (Articles 1, 4, 8, 12, 14).
- `propose_recommendation_intent` / `confirm_recommendation_intent` / `reject_recommendation_intent` / `apply_mix_weight_recommendation` / `apply_recommendation_intent` → write `recommendation_intents` (new protected table); `apply_*` writes `product_mapping.mix_weight` (protected). ✅ 2026-06-04. WS5: free-text → typed intent (status `proposed→confirmed→applied|rejected`) → on human-confirm, renormalize per-machine `mix_weight` to sum 1.0; `apply_*` requires `status='confirmed'`. NOTE: engine still reads `split_pct`, not `mix_weight` (flagged follow-up — applying an intent does not yet change engine behavior). Migrations `refillv2_ws5a_recommendation_intents` (table + RLS), `refillv2_ws5b_recommendation_rpcs`. Cody-reviewed (Articles 1, 2, 4, 5, 8, 12).
- `get_refill_plan_output_enriched(p_plan_date date)` (read-only STABLE helper) → joins `refill_plan_output` pending rows to `v_live_shelf_stock` + LATERAL 7d `v_sales_history_attributed`. ✅ 2026-06-04. WS7: backs the pending Refill Planning view's Stock + 7d columns (stitch writes 0/0 placeholders). No writes. Migration `refillv2_ws7_pending_enriched_reader`.
- `v_driver_feedback_demand` (read-only view) → per `(machine_id, pod_product_id)` unresolved driver-feedback demand within a 14-day decay window, mapped boonz→pod via `product_mapping`. ✅ 2026-06-04. WS4a. Consumed by `engine_add_pod` v13. Migration `refillv2_ws4a_driver_feedback_demand_view`.

### PRD-023 — VOX commercial reporting (read-only, ✅ 2026-06-11)

- `get_vox_commercial_txn_lines(p_pods text[], p_date_from date, p_date_to date)` → **NEW read-only helper (SECURITY INVOKER, STABLE, SET TimeZone Asia/Dubai).** One row per `sales_history` line for Active `venue_group='VOX'` machines (same filters as `get_vox_commercial_report`), reusing its per-txn waterfall so `txn_captured/default/refunded/status` match the cards; `supply_source` three-valued (Boonz/VOX/LLFP, unmapped surfaced), `unit_cogs` from `vox_product_mapping.cost_incl_vat` (0 for VOX-sourced). No writes. Grants: `authenticated, service_role` (anon dropped). Migration `prd023_c_vox_commercial_txn_lines`. Cody-reviewed (read-only; Article 15). Validated SUM(line_total)=36,940.00 / SUM(line_cogs)=1,878.02 / 1592 txns / 2448 units (06Feb–30Apr).
- `get_vox_commercial_report(text[],date,date)` (read-only, same signature) → patched: machine display by `official_name`/`machine_id` (was `machine_mapping`); money unchanged. Migrations `prd023_a_..` + `prd023_a_fix_machineid_groupby`.
- `get_vox_consumer_report(text[],boolean,date,date,uuid)` (read-only) → **signature changed**: trailing `p_machine uuid DEFAULT NULL` (server-side machine scope) via DROP+CREATE (avoids PGRST203 overload; sole caller uses named params). Refund-netted captured (SettledBulk+RefundedBulk on `v_adyen_transactions_attributed`), `machine_id` grouping + distinct `num_machines`, `total_captured` from the matched set. Migrations `prd023_b_..` + `prd023_b_fix_machineid_groupby`. Grants narrowed to `authenticated, service_role`.

### PRD-037 — Refill v4 swap engine (✅ 2026-06-20)

- `engine_swap_pod(p_plan_date date, p_max_swaps_per_machine int, p_min_pearson numeric, p_days_cover int)` v11 -> **v12_value_model** → canonical writer to `pod_swaps`. ✅ 2026-06-20 (`prd037_p1_engine_swap_pod_v12`). Pass-3 rewritten to value model V=margin x min(velocity x D, cap), SWAP only if best eligible candidate beats KEEP by theta=0.15; WS-1 eligibility via `_coexistence_blocks` + `_travel_scope_blocks`; rate limits (<= per-machine cap, fleet <=10, 14-day cooldown); intra-cycle swap-in dedup (no product into 2 slots/machine/cycle). Sets app.via_rpc; operator_admin gate; `_assert_refill_plan_writable` + `_assert_gate_zero`. `swaps_enabled=false` keeps Pass-3 a no-op. Cody Articles 1,4,6,8. engine_add_pod UNTOUCHED.
- `_coexistence_blocks(p_machine_id uuid, p_cand_boonz uuid)` → read-only STABLE SECURITY DEFINER helper. ✅ 2026-06-20. Returns true if a candidate violates `coexistence_rules` (Rule 1 TCCC venue exclusion, or Groups 1-7 vs an on-machine product, bidirectional). No writes.
- `_travel_scope_blocks(p_machine_id uuid, p_cand_boonz uuid)` → read-only STABLE SECURITY DEFINER helper. ✅ 2026-06-20. Returns true if a VOX-locked SKU (8-name list + "VOX " prefix + Aquafina brand) is being placed outside venue_group='VOX'. No writes.
- New reference table `coexistence_rules` (RLS read-only, written by migration only; `prd037_p0_coexistence_rules_brand_owner`) + `boonz_products.brand_owner` tag. Cody Articles 2,3,12,14.

### PRD-039 — Refill v4 swap value-model (Phase 1 ✅ 2026-06-20)

- `engine_swap_pod(p_plan_date date, p_max_swaps_per_machine int, p_min_pearson numeric, p_days_cover int)` v12 -> **v13_value_model_broad** → canonical writer to `pod_swaps`. ✅ 2026-06-20 (`prd039_p1_engine_swap_pod_v13`). Pass-1/dead-tag/Pass-2b byte-identical to v12; **Pass-3 rewritten**: WS-A broad universe from `v_wh_pickable` (find_substitutes no longer the gate; untouched), WS-B candidate-specific cap via `product_slot_capacity_units`×0.85 + `slot_capacity_max` override + `shelf_configurations.max_capacity` fallback, WS-C greedy-by-marginal-value unique assignment (product once/machine/cycle), WS-D homogenisation K=3/product/cycle; fleet ≤10, ≤2/machine, 14-day cooldown. Pearson w3 term = set-based mirror of `get_candidate_affinity`. **Value-model swaps land under `reason='rotate_out'` (was the illegal `score_swap` in v12) + `reasoning->>'source'='value_model_swap_broad'` — downstream `pod_swaps` consumers MUST distinguish them by `reasoning->>'source'`, not by `reason`.** Sets app.via_rpc; operator_admin gate; `_assert_refill_plan_writable` + `_assert_gate_zero`. `swaps_enabled=false` keeps Pass-3 a no-op (P2 enables). Cody Articles 1/4/5/12/16. engine_add_pod UNTOUCHED (T12).

### PRD-039 — Refill v4 swap value-model (Phase 0 ✅ 2026-06-20)

- `product_slot_capacity_units(p_physical_type text, p_shelf_size text)` → **read-only helper (LANGUAGE sql STABLE, SECURITY INVOKER, search_path pinned).** ✅ 2026-06-20 (`prd039_p0_product_slot_capacity`). Matrix-miss resolver over the new `product_slot_capacity` table: returns max UNITS for a (physical_type, shelf_size), ladder exact → nearest size same type → bar_standard of size → 8. Never NULL across the 14 live physical_types × {Small,Medium,Large} (coverage 42/42). No writes. Phase-1 WS-B applies ×0.85 then override/shelf fallback.
- `get_candidate_affinity(p_machine_id uuid, p_cand_pod_product_id uuid)` → **read-only helper (SECURITY DEFINER, STABLE, search_path pinned; EXECUTE to authenticated/service_role).** ✅ 2026-06-20 (`prd039_p0_get_candidate_affinity`). Scoring-only Pearson/co-purchase score for an arbitrary candidate pod vs a machine basket (velocity>0 on-machine pods); per-machine correlation then loc-type fallback, COALESCE 0. Mirrors `find_substitutes_for_shelf` basket_corr exactly so the Phase-1 broad universe carries the w3 term without `find_substitutes` as a gate. No writes. Cody Articles 2/12/14/16. **Art-16 follow-up:** register "candidate basket affinity" in METRICS_REGISTRY with this as canonical; converge `find_substitutes` on it later.
- New reference table `product_slot_capacity(physical_type, shelf_size, max_units)` (RLS read-only `psc_select`, written by migration only; `prd039_p0_product_slot_capacity`). Seed = observed physical max from `v_shelf_max_stock` (CS choice, 33 cells). Cody Articles 2/12/14/16.

### PRD-040 — Track A closeout (✅ 2026-06-20)

- `log_manual_refill(p_machine_name text, p_source_warehouse_id uuid, p_refill_date date, p_lines jsonb, p_reason text)` → canonical writer (warehouse_inventory + pod_inventory). ✅ 2026-06-20 (`prd036_b_log_manual_refill_new_purchase`). Per-line `new_purchase` boolean added: `false` (default) = unchanged FEFO-decrement of existing WH stock → pod; `true` = INSERT a `warehouse_inventory` receipt batch (Active, `NEW-PURCHASE-<date>`, captured expiry, audited) → draw it fully → same pod insert. Field new-purchase with no PO is receipted via this RPC (CS-confirmed). Sets app.via_rpc/app.rpc_name/app.provenance_reason='manual_adjust'; role-gated; never UPDATEs warehouse_inventory.status (the new batch's Active→Inactive on draw-to-0 is the pre-existing depletion trigger). Cody Articles 1/4/6/8/12.
- `v_refill_planning_compact` (read-only VIEW) → patched ✅ 2026-06-20 (`prd019c_compact_product_fallback_is_configured`): product COALESCE chain gains a planogram fallback (0 row change in current data) + new trailing `is_configured` column (a product exists in any source: live/lifecycle/planogram/planned). Sole consumer FE `RefillPlanningTab.tsx`. Cody Articles 12/14/16. (Pre-existing `wh_availability` inline WH-sum is grandfathered Art-16 debt, unchanged.)

### PRD-040 — Track C / C1 VOX returns surface (✅ 2026-06-20)

- `get_vox_returns(p_date_from date, p_date_to date, p_machine_id uuid DEFAULT NULL)` → **NEW read-only helper (LANGUAGE sql, SECURITY DEFINER, STABLE, `search_path=public, pg_temp`).** ✅ 2026-06-20 (`prd040_c1_get_vox_returns` + `prd040_c1_get_vox_returns_revoke_anon`). One row per `vox_return_log` entry scoped to `machines.venue_group='VOX'`, joined to `machines.official_name`, `boonz_products.boonz_product_name`, and `user_profiles.full_name` (received-by). DEFINER is required solely to resolve staff names across the own-row-only `user_profiles` RLS (mirrors `get_product_performance`); INVOKER would NULL every name but the caller's. No writes. Grants: `authenticated, service_role` (anon EXECUTE revoked in the follow-up — RLS-bypassing reader must not be callable pre-auth). **Article 16:** raw ledger passthrough, no registered-metric re-derivation. Cody-reviewed (read-only class-c; Articles 1/3/12/13/16). Consumer: FE `VoxReturnsPanel.tsx` via `/api/vox/returns` (internal-role gated tab on the MAFE dashboard).

### PRD-033 — operator flexibility (objects live in prod 2026-06-17; landed on main via PRD-040 Track C C3)

Five objects, all verified live in `pg_proc`; FE wired in Track C C2 (Article 3 — every mutation routes through these RPCs, no direct table writes).

- `v_shelf_capacity` (read-only VIEW) PATCHED (PRD-033 R1, `prd033_a_shelf_capacity_nets_removals`): `headroom = max - GREATEST(current - LEAST(planned_removed, current), 0)`; new `planned_removed` = SUM(qty) of REMOVE/M2W on the shelf's latest active plan (status IN draft/approved), capped at current_stock. One row per shelf. `add_pod_refill_row`/`edit_pod_refill_row`/`convert_shelf` read post-removal headroom live. Articles 3/12/16. Cody ✅.
- `reopen_stitched_rows(p_plan_date date, p_machine_ids uuid[], p_shelf_ids uuid[] DEFAULT NULL, p_reason text)` → canonical writer to `pod_refill_plan` (PRD-033 R2, `prd033_b_reopen_stitched_rows`). DEFINER, operator_admin/superadmin, reason>=10, via_rpc + audit. Flips selected rows stitched→approved in place (shelf_ids NULL = all stitched shelves for the machines); refuses if any linked `refill_plan_output` is past pending. Re-resolve via `stitch_pod_to_boonz(date,false)`. Articles 1/4/5/8/12. Cody ✅. FE: RefillPlanningTab pending-view "Re-stitch machines".
- `release_wh_quarantine(p_wh_inventory_id uuid, p_reason text, p_verified_by uuid DEFAULT NULL)` → writer to `warehouse_inventory.provenance_reason` ONLY (PRD-033 R3, `prd033_c_release_wh_quarantine`). DEFINER, warehouse/operator_admin/superadmin, reason>=10, via_rpc + mutation_reason + audit. Sets provenance_reason='manual_adjust' so the GENERATED `quarantined` flips false (row enters `v_wh_pickable`). Does NOT write `status` (Article 6 clear). No-op on a non-quarantined row. Articles 1/4/6/8/12. Cody ✅. FE: QuarantinedInventoryPanel "Release".
- `check_remove_without_replace(p_plan_date date)` → read-only DEFINER STABLE, NO writes (PRD-033 R4, `prd033_d_check_remove_without_replace`). Returns `{plan_date, status: ok|block, flagged_count, flagged[]}`; flags shelves with an active REMOVE/M2W paired with an ADD_NEW resolving to 0 pickable WH units (mirrors stitch wh_avail). DEFAULT BLOCK. Articles 3/16. Cody ✅. FE: RefillPlanningTab pre-commit gate (blocks commit on status='block', Override to proceed).
- `convert_shelf(p_plan_date, p_machine_id, p_shelf_id, p_old_pod_product_id, p_new_pod_product_id, p_new_qty, p_return_mode='wh', p_reason)` → writer to `pod_refill_plan` (PRD-033 R6, `prd033_e_convert_shelf`). DEFINER, operator_admin/superadmin/warehouse, via_rpc + per-row `pod_refill_plan_audit` (edit_type='convert'). Atomic swap: REMOVE/M2W(old, tracked physical qty from `v_pod_inventory_latest`) + ADD_NEW(new) clamped to post-removal `v_shelf_capacity` headroom. return_mode in wh/m2m/truck_transfer/unknown (wh→M2W else REMOVE). Articles 1/4/8/12. Cody ✅. FE: RefillPlanningTab draft-row "Convert" modal.

### Product performance — Products → Performance tab (objects live 2026-06-16; landed via PRD-040 Track C C3)

- `get_product_performance(p_bucket text, p_as_of date)` → read-only helper (SECURITY DEFINER, STABLE, `search_path=public, pg_temp`; EXECUTE authenticated/service_role). Migrations `get_product_performance_rpc` + `get_product_performance_add_wh_available`. Per-product performance buckets (Remaining Expected, Missing WH Inv) for the Products → Performance tab; resolves staff names past `user_profiles` own-row RLS (the DEFINER precedent `get_vox_returns` reuses). No writes. Article 16: reporting reader.

### PRD-042 — Swap engine v5 slot-profile pools (✅ 2026-06-20, gated OFF)

- `rebuild_slot_profile_pool()` → writer DEFINER (sets app.via_rpc). ✅ 2026-06-20 (`prd042_p0_slot_profile_pools`). Full nightly refresh of the precomputed `slot_profile_pool` cache = derived (lane_family × shelf_size × product, `fill_qty = floor(product_slot_capacity_units(physical_type, size)×0.85)`) MINUS `slot_pool_curation` excludes PLUS includes; `computed_at=now()`. Grant: service_role. Scheduled via pg_cron `rebuild_slot_profile_pool_nightly` 15:30 UTC (before job 13). Cody Articles 1/4/12/16.
- `engine_swap_pod(date,integer,numeric,integer)` v14 → **v15_slot_profile** → canonical writer to `pod_swaps`/`pod_refill_plan`. ✅ 2026-06-20 (`prd042_p1_engine_swap_pod_v15_slot_profile`). Pass-3 candidate universe now the precomputed `slot_profile_pool` for the slot's (lane_family, shelf_size) intersected with the live `_p3_cand` guardrail universe; `cand_cap = pool fill_qty` (profile quantity). Value model unchanged. `swaps_enabled=false` keeps Pass-3 a no-op. engine_add_pod UNTOUCHED (T12). Cody Articles 1/4/12/16. New ref tables `physical_type_lane_family`, `slot_pool_curation`, `slot_profile_pool` (all RLS read-only).

### PRD-043 — Picker v11 VOX calendar gate (✅ 2026-06-20)

- `days_until_next_vox_day(date)` → read-only helper, LANGUAGE sql IMMUTABLE, no table access. ✅ 2026-06-20 (`prd043_p0_days_until_next_vox_day`). Days from p_plan_date to the next Wed/Fri (DOW 3/5); 0 on a VOX day. Grant authenticated/service_role.
- `pick_machines_for_refill(date,integer,integer)` v10 → **v11** → canonical writer to `machines_to_visit`. ✅ 2026-06-20 (`prd043_p1_pick_machines_for_refill_v11`). VOX venue gate on the normal-day `ranked_primary` (Option B: VOX excluded off-calendar except `runway_days < days_until_next_vox_day`, tagged `vox_emergency_offday`, counted vs cap). `sibling_ranked` / VOX-day sweep / Saturday guard unchanged. NOT flag-gated (live pick). Cody Articles 1/12/16.

### PRD-044/045/046/047 — refill-day fixes (✅ 2026-06-21, applied via MCP, pending prod-sync git-commit)

- `confirm_machine_packed(text,date,uuid,text,boolean)` → **NEW 5-arg two-mode** canonical writer to `dispatch_pack_confirmation` (PRD-044, `prd044_p1_confirm_two_mode`). p_final=false = Save & come back (records final=false → pack_state in_progress, never blocks, returns resolved_n/remaining_n); p_final=true = Finish (blocks on any unresolved fillable line, final=true → completed). The 4-arg form now delegates to Finish. app.via_rpc + role gate + reason. Cody Articles 1/4/5/8/12.
- `pack_dispatch_line(uuid,jsonb,uuid)` → patched (PRD-044): the not_filled (pick<1) branch records `not_filled_reason` from the picks payload. Otherwise unchanged (already did pick 0→not_filled, partial, packed).
- `v_dispatch_availability` / `v_dispatch_pickable` (read-only VIEWS) → patched (PRD-045, `prd045_p0_wh_commitment_correctness`): `reserved_by_earlier` excludes cancelled/skipped/not_filled/packed and counts only earlier OTHER-machine commitment (no self-commit); new `oversubscribed` flag; available floors at 0. No function consumes them (engine/stitch untouched). Article 16 (corrected the canonical dispatch-availability object, not parallelized).
- `stitch_pod_to_boonz(date,boolean)` v25_wh_pickable_unified → **v26_multivariant_spread** → canonical writer to `refill_plan_output` (PRD-046, `prd046_stitch_v26_multivariant_spread`). Distribution CTEs only: residual set = all WH-available active variants (drop the on-shelf collapse) + on_shelf leftover tie-break; largest-remainder + conservation kept. ADD/SWAP/FINALIZE + driver overlay byte-identical. Cody Articles 1/4/8/12.
- `swap_dispatch_shelf(date,uuid,uuid,uuid,numeric,uuid,numeric,text)` → **NEW** writer (PRD-047, `prd047_p0_swap_dispatch_shelf`). Atomic one-tap shelf swap: composes the canonical `add_dispatch_row` twice (Remove old + Add New new) in one transaction (both or neither). Title-case actions, WH-sourced (primary warehouse), FEFO at pack, edit-log audit inherited. Grants authenticated/service_role. Cody Articles 1/4/8/12.
- `swap_shelf_pod(date,uuid,uuid,uuid,text)` → **NEW** writer (PRD-047 v2, `prd047v2_swap_shelf_pod`). Atomic pod-level whole-shelf swap: Removes every current Refill/Add line on the shelf at current qty, then Adds New the chosen pod spread across its WH-available mapped variants at shelf capacity (`v_shelf_max_stock.max_stock_weimi`) via `spread_pod_qty`. Composes the canonical `add_dispatch_row` per line (title-case, source_kind='wh', FEFO at pack); pre-validates a non-empty spread before any write. Grants authenticated/service_role. Cody Articles 1/4/8/12.
- `spread_pod_qty(uuid,uuid,uuid,integer)` → **NEW** read-only helper (PRD-047 v2, `SECURITY INVOKER`, STABLE). Replicates the stitch v26 multi-variant distribution (normalized split_pct over WH-available mapped variants, FLOOR base + largest-remainder, on-shelf tie-break, conserves SUM==target). Single source of truth for the swap path; `stitch_pod_to_boonz` keeps its own inline copy (engine byte-equivalence, Art 12) — keep the two in sync. Grants authenticated/service_role.

## How to add a new RPC

1. Decide if it's a canonical writer (mutates a protected entity) or a helper.
2. If writer: must set `app.via_rpc`, must validate inputs, must be the only write path. Add a row to the appropriate section above.
3. If helper: keep `SECURITY DEFINER` only if RLS-bypass on read is genuinely needed. Otherwise prefer `SECURITY INVOKER`.
4. Add an entry to CHANGELOG.md citing the Constitution article(s) it satisfies.
5. CI lint (Phase A.6) will check that any new function in `pg_proc` is registered here.

## PRD-102 (2026-07-18)

- `swap_shelf_pod(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_new_pod_product_id uuid, p_reason text, p_new_qty integer DEFAULT NULL)` — v2 canonical field pod-swap writer (5-arg signature dropped; default-NULL keeps all named-param callers). NULL qty = fill-to-WEIMI-cap (legacy, byte-identical); qty>=1 = operator quantity, WH-availability-limited only (`clamp_reason='wh_limited'` + `requested_qty` + `wh_available` in response). Legs via add_dispatch_row (Article 1). Roles: field_staff, warehouse, operator_admin, superadmin, manager; reason >= 10 chars.
- `decline_swap_pair(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_dispatch_ids uuid[], p_reason text)` — NEW canonical writer: declines an unstarted planner swap pair. skipped=true/include=false/skip_reason 'decline_swap: …' (visible decision; unskip_dispatch_line reactivates), edit-log rows kind='decline_swap' (append-only), one refill_edit_signals `swap_rejected` row (source='field', incoming pod) for engine suppression. Same role list (role-vocab rule: always includes field_staff + warehouse). Refuses started/packed/picked-up/cancelled/already-skipped legs.

## 2026-07-16 addition — canonical atomic writer

- `record_actual_refill(p_machine_name, p_plan_date, p_lines jsonb, p_source, p_actor, p_reason, p_dry_run)` — DEFINER. Canonical ATOMIC write path for a captured physical refill: writes refill_events + refill_event_lines and applies pod+warehouse+refill_plan_output in one subtransaction (all-or-nothing). Orchestrates adjust_pod_inventory + adjust_warehouse_stock; does NOT reimplement stock math; does NOT write warehouse_inventory.status. p_dry_run=true default. Articles 1,4,6,7,8. See PRD-100.

- `get_payment_default_summary` / `get_vox_consumer_report` / `get_vox_commercial_report` — **UPDATED 2026-07-28 (recon_fix4/5a/5b):** refund figures now read `adyen_transactions.refunded_amount_value` (backfilled for May-Jun VOX by recon_fix3) instead of gross captured / adjusted_amount_value; refunded baskets count as matched; commercial `captured_amount` is gross-of-refund so `net_revenue = captured - refund - fees` subtracts the refund once; consumer summary gains `total_refunded`/`refunded_txns`, recent_txns gains `status='refunded'` + `refunded`. All read-only, signatures unchanged, grants preserved. Consumers/performance/SOA now reconcile to the cent on Default and Refunds.

## PRD-110 P1.1 (2026-07-30) — sourcing truth layer

Canonical writers:

- `set_product_sourcing_v3(p_machine_id uuid, p_pod_product_id uuid, p_source text, p_reason text, p_boonz_product_id uuid DEFAULT NULL)` — DEFINER. THE write path for one sourcing edge (Article 1). Supersede-then-insert; `source` is never updated in place. Roles operator_admin/superadmin/manager, reason >= 10 chars. Returns `{changed, sourcing_id, superseded_id, from, to}`; returns `changed:false` and writes nothing when already at that source. Backs the FE product × machine sourcing grid.
- `set_machine_operating_model_v3(p_machine_id uuid, p_model text, p_reason text)` — DEFINER. THE write path for `machines.operating_model` (Appendix A protected entity). Roles operator_admin/superadmin. **Refuses any classification that contradicts the machine's live Active edges** (partner_managed with boonz_wh edges; fully_managed with venue edges) — `tg_product_sourcing_model_guard` fires only on product_sourcing writes and cannot retro-validate, so this RPC is where that invariant is held.
- `backfill_product_sourcing_v3(p_dry_run boolean DEFAULT true)` — DEFINER. Genesis seed of product_sourcing from `product_mapping.source_of_supply`. Idempotent and insert-only: never supersedes or overwrites an Active edge, so a human decision made after genesis survives every re-run.
- `apply_proposed_operating_models_v3(p_dry_run boolean DEFAULT true)` — DEFINER. **PARKED** (PRD-110 PARKING-LOT D-07). Applies `v_machine_operating_model_proposed` through the canonical writer, one machine at a time, collecting per-machine failures rather than aborting the batch.

Read-only helpers:

- `resolve_product_sourcing_v3(p_machine_id uuid, p_pod_product_id uuid, p_boonz_product_id uuid DEFAULT NULL)` — **SECURITY INVOKER**, STABLE. Precedence: SKU-grain edge > pod-grain edge > operating-model default > `boonz_wh`. The terminal fallback is deliberately the CONSTRAINED answer: an unknown edge must never silently grant unconstrained (phantom) availability.

Canonical read objects: `v_product_sourcing_current`, `v_machine_operating_model_proposed`, `v_product_sourcing_model_conflicts`.

### PRD-110 P1.2 (2026-07-30) - shelf-state coverage guarantee

Canonical writers:

- `provision_shelf_lifecycle_v3(p_shelf_id uuid)` - **SECURITY DEFINER**, canonical **single-shelf**
  `slot_lifecycle` provisioner. Idempotent. Scope guard identical to `seed_missing_slot_lifecycle`
  (the canonical BATCH writer): `machines.status='Active' AND include_in_refill` and
  `shelf_configurations.is_phantom=false`. Identity comes from WEIMI (`v_live_shelf_stock`) only.
  Revives an archived `(shelf, pod)` row rather than duplicating. Sets `app.via_rpc` +
  `app.rpc_name`; role check (`operator_admin|superadmin|manager|warehouse`) is skipped ONLY when
  `app.via_trigger='true'`. Returns `{action: inserted|revived|deferred|skipped, reason}` - it never
  raises on a business condition, so it can never block a shelf INSERT.
  EXECUTE granted to `authenticated`, `service_role`; REVOKEd from PUBLIC and `anon`.

Trigger-only:

- `tg_provision_shelf_lifecycle()` → `tg_provision_shelf_lifecycle_ins` AFTER INSERT ON
  `shelf_configurations` FOR EACH ROW WHEN (`NEW.is_phantom = false`). Thin wrapper: sets
  `app.via_trigger`, calls the writer, clears the GUC (no provenance leak to later statements).

Canonical read objects: `v_shelf_state` (see `SHELF_STATE_DEFINITION.md` and METRICS_REGISTRY).

## PRD-110 P1.4 (WS-J2) — inventory truth layer writers · 2026-07-30

Canonical writers. All SECURITY DEFINER, `search_path = public, pg_temp`, set `app.via_rpc` +
`app.rpc_name`, EXECUTE granted to `authenticated`, REVOKEd from PUBLIC and `anon`. Role gate follows
the `record_blocked_demand_v3` house pattern: **a NULL actor is permitted** so cron and the estimator
can call them; a real caller must hold the role.

- `record_inventory_event_v3(shelf_id, boonz_product_id, qty_delta, kind, expiry_date, source_ref,
note, ts)` → jsonb. **The** write path for `inventory_events`, and the only thing that moves a
  `shelf_composition` bucket. Derives `machine_id` from the shelf rather than accepting it.
  Roles: warehouse | operator_admin | superadmin | manager | field_staff.
  ⚠️ **Enforces the EXPIRY IRON RULE**: a `derived_decrement` naming a known-expired bucket is
  REFUSED. Human events (`write_off`, `return`, `expired_sold_incident`, `correction`,
  `driver_confirm`) on the same bucket are allowed — that asymmetry IS the rule and must not be
  "simplified" into a blanket expired-bucket lock.
  ⚠️ Underflow is never silently absorbed: a delta driving `est_qty` below 0 clamps to 0 **and**
  raises a `composition_underflow` anomaly.
  Confidence side-effects: 1.0 on `driver_confirm` and on a `load` into an empty bucket
  ("load-to-empty"); unchanged for every other kind.
- `driver_confirm_shelf_v3(shelf_id, confirmed jsonb[], note)` → jsonb. The collapse. Snaps
  composition to reported truth, resets confidence to 1.0, zeroes believed-in buckets the driver did
  not report. History is preserved — every correction is an appended event, never an overwrite.
  ⚠️ A known-expired bucket that confirms LOWER (or is absent) emits `expired_sold_incident`, **not**
  `driver_confirm`, and raises an `expired_sold_suspected` anomaly. That is fixture 23's behaviour and
  it lives in the writer, not in the FE.
- `decay_composition_confidence_v3(shelf_id, amount, reason)` → int. Deliberately separate from the
  event writer so "how sure are we" never rides on "what happened". Clamped to [0,1].
  Roles: warehouse | operator_admin | superadmin | manager.
- `raise_inventory_anomaly_v3(shelf_id, kind, observed, expected, product, snapshot_at, detail)` →
  uuid. Only writer of `inventory_anomalies`.
  ⚠️ **IDEMPOTENT PER OBSERVATION since 2026-07-31 (PRD-110 S-41).** When `snapshot_at IS NOT NULL`,
  a row with the same `(shelf_id, kind, weimi_snapshot_at, boonz_product_id)` is treated as the SAME
  physical observation: the existing `anomaly_id` is returned and **nothing is inserted**.
  ⚠️ **RETURN CONTRACT:** the uuid returned may therefore be **pre-existing, not freshly minted**.
  Do not assume a new row exists just because you got an id back. With `snapshot_at IS NULL` there is
  no observation identity, so every call inserts - the dedupe can never silence such a caller.
  Why a function guard and not a unique index: 15 duplicate rows predating the fix are deliberately
  retained as the evidence for S-41, and an index would have required deleting them.
- `resolve_inventory_anomaly_v3(anomaly_id, resolution, note)` → jsonb. 10-char minimum note (house
  rule); refuses an already-resolved anomaly.

Read-only / job:

- `estimate_shelf_composition_v3(shelf_id DEFAULT NULL, dry_run DEFAULT true, force_rederive DEFAULT false)`
  → jsonb. The composition estimator. Reconciles WEIMI pod-level counts against per-SKU belief; writes
  only through the writers above. **Defaults to DRY RUN.** Roles: operator_admin | superadmin.
  ⚠️ Idempotent per WEIMI snapshot via `source_ref = 'estimator:<snapshot_at>'` — this is what makes
  re-runs safe (stress-suite S4) and why no watermark table exists. Do not change the `source_ref`
  format without understanding that it IS the idempotency key.
  ⛔ **BUT THAT GUARANTEE IS PARTIAL, AND THE OLD WORDING HERE WAS WRONG (PRD-110 S-41, 2026-07-31).**
  The marker is an `inventory_events` row. A shelf whose belief already equals its clamped count goes
  **flat**, writes **no event**, and therefore **never sets the marker** — so it re-runs its whole
  body on every cron-44 firing (24x/day). Measured live: `already_processed_skipped = 0` on a
  snapshot already processed four times. RISK 76 predicted this; S-41 measured its cost.
  Both accruing side effects are now guarded rather than the skip semantics changed:
  **anomalies** dedupe per observation (see `raise_inventory_anomaly_v3` above), and **age decay**
  anchors on `shelf_composition.last_age_decay_at`, which the function stamps as it decays, so the
  decay is at-most-once-per-elapsed-day and independent of firing frequency (S-42).
  Proven by **golden fixture 27**, whose seq 3 asserts the second call still does NOT skip — so no
  future change can satisfy the fixture by short-circuiting instead of fixing the accrual.
  Returns `shelves_age_decayed` for observability.
  ⚠️ **The idempotency marker is the EVENTS THEMSELVES**, not a watermark: the skip test is
  `EXISTS(inventory_events WHERE shelf_id = s AND source_ref = v_ref)`. A shelf whose delta is 0 writes
  no event, so it is legitimately re-examined on every run and skips nothing. Measured leg 26 — do not
  read a `already_processed_skipped = 0` as proof that force is broken.
  ⚠️ `p_force_rederive` (PRD-110 S-28, migration `20260730211918`) skips ONLY the already-processed
  `CONTINUE`, so a caller that has deliberately perturbed belief can re-run against a consumed snapshot.
  It is **REFUSED fleet-wide** — it requires a single `p_shelf_id`. It exists for golden fixtures 20 and
  22, which otherwise become no-ops once cron 44 goes fleet-wide (fixture 20 would then prove LAW 7
  **vacuously**). Low-risk by construction: if belief already equals the sensor the recomputed delta is
  0 and nothing is written. It DOES re-raise `count_above_capacity` on a sensor-lie shelf, because
  anomalies are raised once per snapshot per shelf and are not idempotent the way events are (R25-D3).
  ⚠️ **The 2-arg overload was DROPPED**, not left beside the 3-arg one: both original parameters carry
  defaults, so co-existing 2-arg and 3-arg candidates make EVERY call site ambiguous (42725), including
  cron 44's. The 2-arg call text still resolves, and the migration proves it rather than assuming it.
  Driven by `cron.job` **44** `prd110_p14_composition_estimator_hourly` (`40 * * * *`), **ACTIVE since
  leg 20** and scoped by D-08's staged activation to the shelf set of `MPMCC-1058-0000-R0`; it calls the
  2-arg form, so it never forces. Fleet-wide expansion is pre-approved after 3 clean burn-in days.
- `_estimator_rise_disposition_v3(machine_id, pod_product_id, boonz_product_id)` → text. STABLE.
  Returns `venue_fill` only for a `co_managed` machine on a venue-sourced product, else `anomaly`.
  Extracted so fixture 19 can assert both branches without mutating a live machine.
  ⚠️ Returns `anomaly` fleet-wide today: `operating_model` is NULL on all 102 machines until D-07 is
  applied. Fail-safe direction is correct — flag, never silently invent stock.

Canonical write objects: `inventory_events`, `shelf_composition`, `inventory_anomalies` (all three
have a SELECT policy and NO insert/update/delete policy — that absence is the enforcement).

### PRD-110 P1.4 read-only views (2026-07-30, leg 9)

Both `WITH (security_invoker = true)` — the house pattern (`v_shelf_state`, `v_blocked_demand_open`),
so the caller's RLS on `shelf_composition` still applies. Neither contains a write statement. Cody
class (c): INVOKER is sufficient, DEFINER would have been an unnecessary privilege surface.

- `v_shelf_audit_prompts` → the canonical driver-audit prompt selector. One row per shelf whose
  composition confidence is below `refill_policy_params.composition_confidence_prompt_threshold`
  (0.5), ranked per machine by `(1 - confidence) * est_units * pod recommended_selling_price` and
  capped at `composition_max_prompts_per_visit` (3). Columns include `prompt_rank`,
  `uncertainty_value_score`, `prompt_threshold`, `max_prompts_per_visit`.
  ⚠️ The cap is enforced IN THE VIEW, not by the consumer. Fixture 22 seq 12-14 proves it BINDS
  (14 flagged shelves on one machine → exactly 3 rows) and that the param, not a literal, decides.
  ⚠️ Deliberately disjoint from `v_machine_priority` (machines/refill) — see `METRICS_REGISTRY.md`.
  Consumer: the Stax driver-collapse UI (S-14). Returns 0 rows today because `shelf_composition` is
  empty until D-08 is flipped.
- `v_expiry_action_queue` → BUILD SPEC P1.4's auto-action gate. One row per
  `(shelf, product, expiry_bucket)` in `shelf_composition` where the bucket is **past-dated** and
  `est_qty > 0`, emitting `action = 'auto_write_off'` when `confidence >= composition_confidence_min_autoaction`
  (0.7) else `'verify_task'`.
  ⚠️ `expiry_bucket IS NULL` rows are EXCLUDED by design: NULL means UNKNOWN, and unknown is
  **sellable**. Treating unknown as expired would inflate the queue without bound. Fixtures 21 seq 9
  and 22 seq 9 pin this in both the confirm path and the queue.
  ⚠️ This view PROPOSES; it never acts. The EXPIRY IRON RULE still requires a human `write_off`
  event — `record_inventory_event_v3` refuses a `derived_decrement` on a known-expired bucket
  regardless of what this view says (fixture 20 seq 11/12 proves both directions).
  ⚠️ Deliberately disjoint from `v_machine_expiry_summary` (batch records from `pod_inventory`)
  — this is BELIEF from `shelf_composition`. See `METRICS_REGISTRY.md`.

### PRD-110 P1.3 — availability contract (read-only helpers, 2026-07-30)

- `_is_sentinel_wh_row_v3(p_batch_id text, p_expiration_date date)` → boolean, IMMUTABLE.
  The **NARROW, name-AND-expiry** definition of a VOX fake-stock sentinel row. It is the
  **authorisation scope** of `drain_consumer_stock_phantom_v3` (SECURITY DEFINER, zeroes stock on
  `warehouse_inventory`), and Cody narrowed it there deliberately in that RPC's revision 1.
  ⚠️ **The conjunction is load-bearing FOR THAT JOB.** 9 REAL PO-batch rows (202 units, WH_CENTRAL)
  carry `wh_location = 'VOX_SOURCED'`; keying a retirement on `wh_location` destroys real stock.
  Verified live: selects exactly 40, rejects all 9.
  ⛔⛔ **CORRECTED 2026-08-08 (leg 154, S-293).** This entry previously read _"THE single definition
  of a VOX fake-stock sentinel row … any sentinel query must call this and nothing else."_ **Both
  halves were false when written, and the false claim is what let the defect live.** (i) The
  conjunction is NULL-blind: a row with `batch_id IS NULL` on the 2099-12-31 marker evaluates
  `NULL AND true = NULL → COALESCE false`, i.e. **classified as REAL stock**. Five such rows holding
  **5,029 units** were being bound into live dispatch legs by `resolve_fefo_sku_legs_v3`; golden
  fixture 6 went red 48/51 and that is how it surfaced. (ii) "and nothing else" was never true:
  `resolve_supply_ladder_v3` carried its own **inline, name-only** copy. ⭐ **That half is CLOSED at
  leg 155** (`20260808171000`, D-37's unit, which restated the same function): the ladder now calls
  `_is_phantom_wh_row_v3` for all three of its supply buckets and re-derives nothing. See the two
  entries below.
- `_is_phantom_wh_row_v3(p_batch_id text, p_expiration_date date)` → boolean, IMMUTABLE,
  SECURITY INVOKER. **PRD-110 leg 154**, migration `20260808161000`. The **BINDER'S** question:
  _may this warehouse row be bound into a dispatch leg at all._ NULL-safe on **both** limbs and a
  strict **superset** of `_is_sentinel_wh_row_v3` - either the 2099-12-31 marker **or** the
  `VOXSOURCE-` name is sufficient evidence on its own. Catches **45** rows where the narrow
  predicate catches 40. Consumers: `resolve_fefo_sku_legs_v3` (leg 154) and
  **`resolve_supply_ladder_v3` (leg 155, S-293)**.
  ⛔ **DO NOT MERGE THE TWO, and do not "converge" them under Article 16.** They answer different
  questions: _may the binder pick this_ vs _may a SECURITY DEFINER RPC destroy this_. Widening the
  second is destructive-reach creep. Golden fixture 6 seqs 53–57 are the executed truth table
  (including the over-classification guard: **11 NULL-batch rows with a REAL expiry hold 91 units of
  genuine stock** and must stay bindable).
  ⚠️ Grants tightened in `20260808162000`: `{postgres, authenticated, service_role}` - no `PUBLIC`,
  no `anon` (S-268: `anon` holds its grant BY NAME, so a bare `REVOKE … FROM PUBLIC` misses it).
  `authenticated` is retained deliberately - the binder is SECURITY INVOKER and is granted to
  `authenticated`, so its callers must hold EXECUTE on this helper.
  ⛔ **The sibling still carries `anon` + `PUBLIC`** and was deliberately NOT touched by leg 154.
- `resolve_shelf_availability_v3(p_shelf_id uuid)` → jsonb, STABLE, SECURITY **INVOKER**.
  Per-shelf point lookup of `v_shelf_availability_v3`. Deliberately a wrapper and not a second
  implementation: the engine asks per machine (set-based, reads the view) and stitch/pack ask per
  line (this function), and both must return the same number.
  ⚠️ `available_units IS NULL` means **unconstrained**, not "unknown" and not zero. A consumer that
  coalesces it to 0 re-creates the blocked-on-venue-stock defect that WS-A2 exists to delete.

### PRD-110 golden harness — fixture precondition primitives (`golden` schema, legs 27–28)

These are **test-harness objects, not business writers.** They are registered here anyway because
they are `SECURITY DEFINER` and they mutate `public` tables, so a future audit will find them and
must be able to tell instantly why they exist and why they are safe.

All three share one guard: they **REFUSE unless a golden run is in flight**, detected as
`EXISTS (SELECT 1 FROM golden.runs WHERE finished_at IS NULL)`. `golden.run_fixture` INSERTs its run
row with `finished_at NULL` _before_ executing `scenario_sql` and UPDATEs it at the end of the **same
transaction**, so an unfinished row is visible if and only if a fixture is running right now. No
production path — cron, engine, FE, n8n — ever has one. EXECUTE is granted to `service_role` only;
`anon` and `authenticated` are explicitly REVOKEd and the ACL is **asserted after apply** (RISK 77).

- `golden.arrange_shelf(p_shelf_id uuid, p_release_snapshot boolean)` → jsonb, DEFINER. **Leg 27.**
  Deletes DERIVED `shelf_composition` for one shelf and re-dates that machine's newest
  `weimi_device_status` row so the estimator's `source_ref` is unconsumed.
  ⚠️ It **re-dates**, never INSERTs: `unique_device_status UNIQUE (weimi_device_id, snapshot_date)`
  is one row per device per DAY, and the INSERT form raised `duplicate key` on every call.
  ⚠️ `status_id` is `uuid`, not `bigint`.
  ⚠️ Callers must place it INSIDE the fixture's own `BEGIN … RAISE 'GPnn:' … EXCEPTION` block —
  `golden.run_fixture` is **not** a rollback envelope (RISK 80). Closed S-28: 17 reds → 1.

- `golden.pin_machine_stock(p_machine_id uuid, p_curr_stock integer)` → jsonb, DEFINER. **Leg 28.**
  Rewrites `currStock` on **every aisle** of the machine's newest `weimi_device_status` row, after
  stashing the pre-image in `golden.weimi_pin_backup`.
  ⚠️ **`snapshot_at` is deliberately untouched** — it is the estimator's idempotency key and
  `v_shelf_instock_velocity_v3`'s anchor. Only the count changes.
  ⚠️ Self-proving: it re-reads `v_shelf_slot_identity` (the same view the engine reads) and RAISEs
  unless **every** non-phantom shelf now reports `p_curr_stock`. A pin that did not land can never be
  mistaken for one that did (RISK 75).

- `golden.restore_machine_stock(p_machine_id uuid)` → jsonb, DEFINER. **Leg 28.**
  Restores the pre-image and drains the backup row. RAISEs if there is no backup (LAW 5: a restore
  with nothing to restore means the pin never happened and the caller is about to assert on state it
  does not own), and RAISEs unless the post-restore total equals the pre-pin total **as the pin
  recorded it through the same view** — re-summing the raw JSONB instead would count aisles that map
  to no non-phantom shelf, so a correct restore would fail comparison.

⚠️ **THE SAFETY ARGUMENT, in one line, because everything rests on it:** `golden.run_all` is a single
transaction, so pin and restore commit atomically and **no other session can ever observe the pinned
value**. That is what makes the cron-44 estimator race impossible by construction rather than merely
improbable. Fixtures 3 and 5 carry **seq 94** (`golden.weimi_pin_backup` is empty) and **seq 95** (the
machine's live WEIMI fingerprint is byte-identical to the pre-pin capture) so an un-restored pin is
not merely unlikely — it is detected and named.

📌 **Do not repurpose these as a general "set the fleet up how I like" tool.** They exist so a fixture
can neutralise the ONE confounder that makes its subject unobservable — daily stock drift — and each
one refuses loudly rather than doing nothing.

---

## `public.engine_add_pod_v3(p_plan_date date, p_days_cover integer) RETURNS jsonb`

**PRD-110 P2 · relay leg 31 · migration `20260730234831` · SECURITY DEFINER ·
`SET search_path = public, pg_temp` · `anon` REVOKEd, `authenticated` + `service_role` GRANTed.**

The first v3 ADD engine. **Additive — `public.engine_add_pod` (v19) is byte-untouched and remains
the production engine.** v3 writes **only** `public.pod_refills_shadow` under a fresh `run_id`
(LAW 4 — shadow, don't switch) and is invoked by nothing except the golden harness
(`golden.run_engine_v3_if_built`) until a later leg wires it.

**Preamble, in this order** — ADR-shadow-plan-tables §7 Art 4:
`app.via_rpc` / `app.rpc_name` → role check (`operator_admin`, NULL `auth.uid()` allowed through,
same posture as v19) → arg validation → `_assert_refill_plan_writable(p_plan_date)` **ONE ARG, as
v19 calls it** (the function is two-arg with a default; passing `p_machine_ids` changes its
behaviour — the `pronargdefaults` trap) → picked-machines check → `_assert_gate_zero(p_plan_date)`
(LAW 11: the shadow engine honours manual Gate 0 too, or a shadow run could plan machines CS never
confirmed).

**Candidate set = the truth layer, NOT `slot_lifecycle`.** `v_shelf_state` (pod-bound) LEFT JOIN
`v_shelf_availability_v3` on `shelf_id`, scoped to `machines_to_visit` `picked`/`cs_added`.
⛔ **AMENDED 2026-08-08 (PRD-110 leg 159, S-304b, migration `20260808201000`). The clause that used
to end that sentence — "minus machines with an approved `refill_plan_output` row (LAW 12, the same
exclusion v19 applies)" — is GONE, and the attribution in it was wrong.** LAW 12 forbids _touching
live plan tables_; `engine_add_pod_v3` satisfies it by its write target (its body holds exactly ONE
write statement, `INSERT INTO public.pod_refills_shadow`, and no UPDATE or DELETE against any live
plan table), not by that predicate. What the exclusion actually did was let **v19's own output
delete v3's input**: cron 45 fires 21:22 UTC, and on 2026-08-07 the live plan was approved at
20:54:13 UTC, so all 7 picked machines were excluded, v3 planned NOTHING, and the runner logged
`ok`. The single non-vacuous v3 date in DR-1's whole evidence base (2026-08-04) survives only
because that night's approval landed at 21:59, 37 minutes after the cron. The predicate was carried
in FOUR places — the scope count, the empty-machine count, the picked CTE that drives the write, and
the RISK-75 self-proving coverage guard — and all four moved together, or the guard would `RAISE` on
every night with an approved plan. Golden fixture 37 seq 33/34/35 pin it (seq 35 shipped RED first).
**R29-D1: this is a free win.** v19 joins `slot_lifecycle … archived=false AND is_current=true`,
which is exactly why S-35's nightly rotation gap blinds it ~17h/day. Both truth-layer views contain
the S-35 victim shelf. v3 inherits none of it.

⭐ **The one predicate it exists to delete.** v19's insert is
`WHERE (NOT f.is_dead AND f.need_raw > 0)` — a shelf whose need rounds to 0, an over-capacity shelf
and a dead-tagged shelf get **no row at all**. v3 emits a line for **every** in-scope pod-bound
shelf, always, and says why in `clamp_reason`. There is no `ELSE NULL` branch in the clamp ladder:
that is LAW 5 as code, and `pod_refills_shadow_no_silent_zero` enforces it at the table.

**Sizing is the P2 SKELETON and nothing more** (LAW 10, no scope drift):
`need_raw = LEAST(GREATEST(ceil(velocity_raw × days_cover), floor_units), max_stock − clamped_stock)`
with **P2.5's unconditional floor** (`stock = 0` + non-partner ⇒ ≥ 1, up to `min_facing_floor`).
Availability is a **per (machine, pod) pool** consumed by a `prior_need` window ordered by velocity —
without it two shelves of the same product each claim the whole pool and the plan promises stock
twice. `is_constrained = false` ⇒ unlimited; `NULL` availability and `0` availability are never
conflated (that conflation is S-06).
⚠️ **P2.1–P2.4 are NOT wired.** `velocity_instock` is written through verbatim (NULL) and never used
to size — reading it as canonical would route around **D-10** and walk into S-13's ppad trap.

**Column contract:** `current_stock` is the **CLAMPED** value (`LEAST(raw, max)`), never the raw
sensor lie — fixture 14 seq 31. `availability_basis` is the sourcing edge itself
(`boonz_wh|venue|partner|mixed|unknown`, CHECK-constrained), not free text.
`reasoning->>'need_raw'` is present on **every** line or `v_blocked_demand_shadow_v3` derives nothing
and fixture 105 seq 10 can never go green. The returned jsonb **carries `run_id`** — the shadow table
is append-only, so run_id is the only honest scope for an acceptance assertion.

**It proves itself before returning** (RISK 75): a coverage guard re-reads its own scope and RAISEs if
any in-scope shelf got no line, and RAISEs if `lines <> scope`. A run that covered less than its scope
fails loudly instead of reporting a cheerful number.

**First-run evidence (leg 31, all four engine fixtures, `lines/scope` exact):** 3 → 16/16 · 5 → 64/64
· 14 → 16/16 (5 `sensor_over_capacity`) · 105 → 48/48 (3 `blocked_no_wh`, all genuinely `boonz_wh`).
Slowest 867 ms. `public.pod_refills` unmoved, proven per fixture by seq 87.

### `golden.v3_run_id(integer)` · `golden.run_engine_v3_if_built(integer, date, integer)`

Harness-only (migration `20260730234725`). `run_engine_v3_if_built` captures the live `pod_refills`
(at plan_date) and `pod_refill_plan` (absolute) counts **before** calling v3, then calls v3 **only if
it exists**, and **captures any error rather than propagating it** — letting it escape would abort
the rendered scenario and roll back the fixture's v19 call too, turning every unrelated assertion red
with no usable cause. Captured, seq 88 names the `SQLERRM` on line one.
⚠️ **Placement is not uniform and must stay that way:** on fixtures 3 and 5 the call sits **inside**
the S-34 pin envelope (beside the v19 call); on 14 and 105 it is appended. Guard 7b2 in the migration
enforces it.

---

## `golden.written_by_this_txn(p_xmin xid) → boolean` · read-only helper · PRD-110 S-48, leg 41

Harness-internal (schema `golden`), **SECURITY INVOKER**, **VOLATILE**, no writes.

```sql
SELECT pg_xact_status(p_xmin::text::xid8) = 'in progress'
```

**What it answers:** was this row written by the CURRENT transaction tree, subtransactions included?
A row that is VISIBLE to our snapshot but whose `xmin` is still `'in progress'` can only have been
written by us - READ COMMITTED never exposes another transaction's uncommitted rows.

**Why it exists.** It replaces the `created_at >= t0` idiom in the golden LAW-12 tripwires, which is
**structurally blind**: `created_at` DEFAULTs to `now()` (TRANSACTION START) while `t0` is a
`clock_timestamp()` taken INSIDE the transaction, so a fixture's own writes always have
`created_at < t0`. Proven live at leg 41 (S-48).

⚠️ **`xmin = pg_current_xact_id()::xid` is NOT a substitute** and was rejected on evidence:
`golden.run_fixture` runs `scenario_sql` inside a `BEGIN..EXCEPTION` block, which is a
**subtransaction**, so scenario writes carry a subxid. Probed: that form matched **1 of 2** writes;
`pg_xact_status` matched **2 of 2**.

⚠️ **`golden.run_all` runs EVERY fixture in ONE transaction** (proven: all fixtures in a run share
`created_at` = the same transaction start). Transaction-grain attribution therefore cannot separate
one fixture's writes from another's, so the tripwires are stated at the honest grain: the SUITE may
write ONLY on registered synthetic (`>= 2030`) fixture `plan_date`s.

📌 **Callers:** `golden.assertions` fixture 14 seq 91, 92, 93 and the seq-100 self-test. Nothing else.
📌 **Epoch assumption:** `xid::text::xid8` assumes epoch 0 (live xid age range 18..442009, no frozen
xids on `refill_plan_output` / `pod_refills` / `pod_refill_plan`). **seq 100 is the guard** - if the
predicate ever stops seeing this run's own writes, seq 100 goes red rather than the tripwires going
silently vacuous.

## `public.drain_consumer_stock_phantom_v3(p_wh_inventory_id uuid, p_reason text, p_drained_by uuid) RETURNS jsonb` · canonical writer · PRD-110 S-50, leg 43

Zeroes **phantom `consumer_stock` on VOX sentinel `warehouse_inventory` rows** so that P1.3 sentinel
retirement can complete. `tg_propose_inactivate_on_zero_stock` fires only when **both**
`warehouse_stock=0` **and** `consumer_stock=0`; without this writer the 5 sentinels carrying phantom
consumer stock are left **Active with zero warehouse stock** forever.

- **Migration:** `20260731054325_prd110_s50_drain_consumer_stock_phantom_v3` (md5 `58448ddd…3ff7`).
- **Article 4** — role gate `warehouse|operator_admin|superadmin|manager`, `p_reason` ≥ 10 chars,
  NULL checks, `FOR UPDATE`; sets `app.via_rpc`, `app.rpc_name`, `app.provenance_reason='manual_adjust'`
  and `app.mutation_reason`.
- **Article 6** — writes `consumer_stock` **only**; `status` is never assigned. The Active → Inactive
  flip stays with the pre-existing trigger (the S-17 exposure disclosed in PARKING-LOT D-09). A
  migration post-guard fails the apply if the body ever contains a `status` assignment.
- **Article 7** — writes one explicit `inventory_audit_log` row prefixed `consumer_phantom_drain: `.
  ⛔ **Never insert the `delta` column** — it is `GENERATED ALWAYS AS (new_qty - old_qty)`.
- **Article 8** — covered by `tg_audit_warehouse_inventory` → `audit_log_write('wh_inventory_id')`.
- **Scope** — refuses any row that is not `_is_sentinel_wh_row_v3(batch_id, expiration_date)`.
- **Audit footprint (measured):** exactly **two** `inventory_audit_log` rows per drain — the generic
  trigger row (which reads _warehouse_ stock, so it records delta 0) plus the explicit semantic row.
  `app.mutation_reason` is deliberately **unprefixed** so the two stay distinguishable.
- **Grants:** `authenticated` only; `PUBLIC` and `anon` revoked.
- 📌 **Callers:** PARKING-LOT D-09 activation script (parked), `golden.assertions` fixture 24.

### ⛔ Do NOT use these two — superseded, and one has never worked (PRD-110 S-51)

| function                                            | status                                                                                                                                                                                                                |
| --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `drain_consumer_stock_phantom(uuid, text, uuid)`    | ⛔ **BROKEN — unconditionally raises `428C9`.** It INSERTs into the generated column `inventory_audit_log.delta`, so it has never been able to run. Referenced by no function and no cron. Retirement parked as D-17. |
| `drain_phantom_consumer_stock(uuid, numeric, text)` | ⚠️ Works, but weaker: `operator_admin`/`superadmin` only, requires non-null `auth.uid()`, and writes **no audit row**. Retirement parked as D-17.                                                                     |

The three names are near-anagrams of each other — this is the CLAUDE.md `repurpose_machine` /
`rename_machine_in_place_legacy` foot-gun in a new place. **Always call the `_v3` one.**

### Amendment 2026-07-31 (PRD-110 P2.2c, relay leg 44) — `engine_add_pod_v3` sizes on base stock

`20260731061440` replaces `cover_units = ceil(vel_eff * p_days_cover)` with the BUILD SPEC P2.2
target `cover_units = ceil(mu*H + z*sigma_daily_shelf*sqrt(H))`. Everything else about the function
is unchanged: same signature, same SECURITY DEFINER posture, same preamble order, `anon` still
REVOKEd, still writes **only** `pod_refills_shadow`, still invoked by nothing but the golden harness.

- `H` and `z` come from `v_machine_base_stock_policy_v3` — ⛔ **never from `machine_service_policy`
  directly**, whose base columns belong to live v19 and are deliberately stale (D-14 / D-16).
- `phi` comes from `v_pod_demand_dispersion_v3`; the engine derives `sigma_daily_shelf` itself,
  which is what METRICS_REGISTRY instructs (there is deliberately no shelf-grain sigma object).
- Both new views are read as **MATERIALIZED** CTEs — one fleet-wide evaluation per run (S-26/RISK 88).
- **Two new LAW-5 RAISE guards:** the function refuses to return if any line carries an unrecognised
  `horizon_source` or `sigma_source`. A quantity may not move on an unnamed horizon or sigma.
- **New telemetry in the return value:** `horizon_policy_lines`, `horizon_fallback_lines`,
  `sigma_measured_lines`, `sigma_no_dispersion_lines`, `sigma_no_split_lines`, `fill_to_cap_lines`,
  `fill_to_cap_share`, `days_cover_role`; `engine_version` -> `v3_p22c_base_stock`.
- `reasoning->>'engine_calibration'` -> **`v3_p22c_base_stock`**. ⚠️ Rows written before this
  migration carry `v3_p21_velocity_instock` and are NOT comparable — scope by `run_id`.

### Amendment 2026-07-31 (PRD-110 P2.3, relay leg 46) — `engine_add_pod_v3` gains the EXPIRY CEILING

`20260731070920` adds BUILD SPEC P2.3's third cap. Signature, SECURITY DEFINER posture, preamble
order and ACL are unchanged (`anon` still absent); still writes **only** `pod_refills_shadow`;
still invoked by nothing but the golden harness. **oid 235798 preserved** — the migration asserts
that before and after, because a substitution that perturbs the signature would ADD an overload
instead of replacing, and only the oid proves identity.

- **The cap.** `expiry_ceiling_units = floor(expiry_days * vel_eff * base_stock_expiry_safety_factor)`,
  computed **only** where `basis IN ('boonz_wh','mixed') AND earliest_expiry IS NOT NULL`, else NULL.
  `expiry_days = GREATEST(COALESCE(earliest_expiry - p_plan_date, 0), 0)` — re-anchored on the PLAN
  date, floored at zero.
- ⛔ **It caps the COVER term ONLY. The min-facing floor survives it** (Cody rev 2 / LAW 5):
  `need_raw = LEAST(GREATEST(LEAST(cover, COALESCE(ceiling, cover)), floor), fill_to_cap)`.
  A build that also capped the floor reds fixture 8 seq 26 fleet-wide.
- **`need_raw_no_expiry`** is computed alongside, so `expiry_binds` is EXACT rather than inferred.
- **Expiry source** is pod-grain FEFO: `MIN(v_product_shelf_life.earliest_expiry)` over the pod's
  Active `product_mapping` members and the machine's `[primary, secondary]` warehouses. ⛔ The
  predicate is **copied VERBATIM from `v_shelf_availability_v3`'s `wh` CTE** — v3 keeps exactly ONE
  pod->WH resolution (METRICS_REGISTRY Article 16). ⛔ **Never `remaining_shelf_life_days`** — it is
  `CURRENT_DATE`-anchored and answers a different question for any future `plan_date`.
- **New `clamp_reason` value `'expiry_ceiling'`, emitted BEFORE `'skipped_full'`.** Order is the
  subtle part: a line the ceiling drives to 0 would otherwise be labelled `'skipped_full'` — a lie
  that hides the whole clamp class from procurement (fixture 8 seq 27). The `blocked_no_wh` branch
  gained an explicit `AND f.need_raw > 0` guard; its outcomes are unchanged.
- **New LAW-5 RAISE guard:** the function refuses to return if any line carries an unrecognised
  `expiry_source` (`wh_fefo_batch | no_wh_batch | not_wh_sourced | unknown_sourcing`).
- **New `reasoning` keys:** `earliest_expiry`, `expiry_days`, `expiry_ceiling_units`,
  `expiry_source`, `expiry_safety_factor`, `need_raw_no_expiry`. `engine_calibration` ->
  **`v3_p23_expiry_ceiling`**; `candidate_source` gains `v_product_shelf_life`; `sizing_mode` gains
  the ceiling clause. ⚠️ Rows written before this migration carry `v3_p22c_base_stock` and are NOT
  comparable — scope by `run_id`.
- **New telemetry:** `expiry_ceiling_lines`, `expiry_units_removed`, `expiry_fefo_lines`,
  `expiry_no_batch_lines`, `expiry_not_wh_lines`, `expiry_unknown_src_lines`;
  `engine_version` -> `v3_p23_expiry_ceiling`.
- 📌 `expiry_days` is **0, not NULL**, where no FEFO candidate resolves, so every line carries the
  COMPLETE expiry block (fixture 8 seq 22). `expiry_source` names WHY it is 0 and
  `expiry_ceiling_units` stays NULL there, so nothing ever binds off a non-measurement.

---

## PRD-110 P2.4 — demand multiplier RPCs (relay leg 48, 2026-07-31)

- **`resolve_demand_multiplier_v3(p_machine_id uuid, p_plan_date date)`** — read-only helper,
  `STABLE`, **`SECURITY INVOKER`** (Cody's preferred default for read-only), `SET search_path`.
  Returns `(factor, factor_raw, n_factors, clamped, provenance)`. `provenance` is a jsonb ARRAY
  naming every contributing row (LAW 5). Empty calendar ⇒ `factor = 1.0`, `provenance = []`.
  Output is `round(..., 4)` so the scale is deterministic regardless of typmod propagation.
- **`set_demand_factor_v3(text,integer,integer,smallint,date,date,uuid,text,numeric,text)`** —
  **THE canonical writer** for `demand_calendar` (Article 1). `SECURITY DEFINER`, role-gated to
  `operator_admin`/`superadmin`/`manager` via the `user_profiles` join (never `auth.jwt()`), sets
  `app.via_rpc` + `app.rpc_name` (Article 4), validates source/factor/note/scope before the CHECKs
  see them. Append-only supersede: never `UPDATE`s a factor, never `DELETE`s. A restatement of an
  identical factor returns `changed:false` and supersedes nothing, so history stays honest.
- **`load_dow_profile_v3(p_lookback_days integer DEFAULT 90)`** — `SECURITY DEFINER` loader.
  Derives the fleet day-of-week profile from **`v_sales_history_resolved`** (the canonical resolved
  sales object, Article 16 — never `sales_lines` directly), normalises so the mean across the seven
  days is 1.0, and writes **through `set_demand_factor_v3`** rather than INSERTing (Article 1).
  Refuses rather than half-loading when any DOW has fewer than 4 observed dates (LAW 5).
  ⚠️ Not invoked by the migration; P2.4 ships with an empty calendar.

📌 **S-02 still binds:** `context-intelligence` is absent, so the `event` leg has **no** auto-loader
and is RPC-written only. The `macro_kpi` leg has no live CS-side source table either — its writer is
ready and the loader is parked.

### Amendment 2026-07-31 (PRD-110 P2.4, relay leg 49) — `engine_add_pod_v3` reads the demand multiplier

`engine_add_pod_v3(date, integer)` now applies the canonical demand multiplier. Signature, oid
(**235798**), `SECURITY DEFINER`, role gate, `app.via_rpc`/`app.rpc_name` and every write target are
**unchanged**; this is a sizing-input change only.

- New CTE `dmf`: **one** `resolve_demand_multiplier_v3(machine_id, p_plan_date)` evaluation per
  **picked machine**, never per shelf (the answer is machine-grain; shelf-grain evaluation would
  re-run it ~16× per machine for an identical result).
- `LEFT JOIN LATERAL … ON true` + `COALESCE` is deliberate: a resolver returning zero rows would
  otherwise **drop that machine's shelves from the plan entirely** — the silent-qty-0 class LAW 5
  forbids. Fixture 31 seq 2/4 pin that the resolver is total and never NULL.
- `cand` gains `vel_base` (the unscaled velocity, kept so shadow-vs-v19 diffing can separate
  "demand moved" from "we multiplied it") and `vel_eff = vel_base × COALESCE(demand_factor, 1)`.
  **`vel_eff` is the single insertion point** — it feeds `mu_term`, `cover_units` _and_
  `expiry_ceiling_units`, so one multiplication carries the factor into every sizing term.
- `reasoning` gains `velocity_base_daily`, `demand_factor`, `demand_factor_raw`,
  `demand_factor_clamped`, `demand_factor_sources` — in a **second** `jsonb_build_object` merged
  with `||`, because the base object is at the 50-pair / 100-argument ceiling.
- `engine_calibration` → `v3_p24_demand_multiplier`; `candidate_source` now names `demand_calendar`.

**Article 16 discharged, not incurred:** the engine READS the canonical resolver. It must never
re-implement the most-specific-within-source / multiply-across-sources / clamp rule — that rule
lives in `resolve_demand_multiplier_v3` and is pinned by fixture 31 seq 3.

Contract pinned by **golden fixture 7** (24 assertions, green): the factor scales
`velocity_effective_daily` and `mu_term` on every line; the 2.5 clamp reaches quantities; an uplift
never reduces a quantity; an unfactored line records `1.0` and an empty source list explicitly.

---

### `golden.probe_scalar(text)` — harness only (PRD-110 leg 51)

Runs a scalar probe whose target relation **may not exist yet** and returns a `MISSING: …` /
`ERROR: …` sentinel instead of raising.

**Why it exists.** LAW 1 requires the fixture to land before the object it proves. A plain
`check_sql` that names a not-yet-created relation fails at **parse** time, so the whole fixture
aborts as an ERROR and the RED is unreadable — which is why legs 47-50 had to pick fixtures whose
objects all already existed. `probe_scalar` turns "object missing" into a clean assertion **FAILURE**,
so any future object can be fixture-first without contortion.

⛔ **Use only with `eq` / `ne` / `contains`.** `golden.compare` RAISES on `gt`/`gte`/`lt`/`lte` when
an operand is non-numeric, so a sentinel under `gt` reintroduces the error this helper removes.

📌 It catches `undefined_table` / `undefined_column` / `undefined_function` / `undefined_object`
distinctly from everything else, so a genuine bug in the probe reads as `ERROR:` and is never
mistaken for "not built yet".

First consumer: golden fixture 34 (D-12), 28 of whose 45 assertions were RED through this path with
**zero** run errors.

---

## `public.refresh_engine_forecast_error_v3(p_plan_date date)` — WMAPE measurement writer (P2, D-12)

SECURITY DEFINER. Measures forecast error for **one** `plan_date` and writes it to
`engine_forecast_error_v3` (DELETE+INSERT scoped to that date, so re-measuring is safe and
idempotent — pinned by golden fixture 36 seq 30). Every row it writes carries `measured_at` and
`actuals_settled`, so a measurement taken before the horizon elapsed is visibly provisional rather
than quietly wrong.

⛔ **Not a reader.** Read through `v_engine_wmape_v3` / `v_engine_wmape_v3_gate` and branch on
`is_vacuous` (see METRICS_REGISTRY). Do not compute WMAPE anywhere else.
⛔ **Do not call it in a loop over all plan_dates.** ADR §10.1 measured the cost: date-bounded it is
~2.75 s, unbounded across dates it is 13-63 s because the actuals join key is a per-row name lookup
(RISK 88). One date per call is the supported shape.

---

## `public.run_nightly_shadow_v3(p_plan_date date, p_days_cover int, p_settle_limit int, p_note text)` — nightly shadow runner (P2.7)

SECURITY DEFINER, Article 4 role gate (NULL uid = trusted cron, per the
`refresh_engine_forecast_error_v3` precedent), sets `app.via_rpc` / `app.rpc_name`, validates
`p_days_cover` 1..60 and `p_settle_limit` 0..10. Defaults: plan_date =
`resolve_refill_plan_date()`, cover 7, settle 3. Called by cron **45** at `22 21 * * *`.

Four steps, each in its own exception block so one failure cannot abort the night, and **each step
logs its own outcome** to `shadow_runner_log_v3`: **engine** (`engine_add_pod_v3` → shadow) ·
**measure** (`refresh_engine_forecast_error_v3` on the plan_date) · **settle** (up to
`p_settle_limit` earlier dates whose horizon has elapsed — this is the ONLY thing that turns a
provisional row into a score) · **summary**.

⭐ **`blocked_gate0` is a first-class outcome, not an error.** Under LAW 11 Gate 0 is manual, so on a
normal night cron 13 has picked and CS has not yet confirmed — `_assert_gate_zero` then raises
`check_violation`. Classifying that as `error` would make every ordinary night look broken and bury
real failures. ⛔ **The runner never auto-confirms**; that would be precisely the auto-fallback CS
decision #1 forbids. Fixture 37 seq 11-16.

⛔ Writes **no** live plan table. ⛔ Do not raise `p_settle_limit` to sweep history — RISK 88.

---

## `public.find_substitutes_for_shelf_v3(date, uuid, uuid, uuid, integer, integer)` — category-first substitute selection (P3.1a)

**SECURITY INVOKER**, `STABLE`, read-only. ⭐ INVOKER is the correct choice, not a shortcut:
`v_wh_pickable` is itself `security_invoker=true`, so the caller's RLS on `warehouse_inventory`
applies rather than being bypassed.

Args mirror v1 exactly so the two stay call-compatible for the eventual `stitch_v3` wiring;
`p_shelf_id` and `p_aggressiveness_pct` are accepted and unused **in both**.

Returns `rank, pod_product_id, pod_product_name, product_category, category_match,
requires_cs_review, perf_score, pearson_score, unit_margin, wh_stock_units, source, reason`.

**Selection order (BUILD-SPEC line 89, CS 2026-07-31):**

```
ORDER BY category_match DESC,                     -- (1) same category first
         global_v30 * ln(1 + wh_stock) DESC,      -- (3) performance x stock
         basket_corr DESC NULLS LAST,             --     Pearson = tiebreak ONLY
         pod_product_id                           --     deterministic final tiebreak (STRESS S7)
```

v1 ranked on `COALESCE(basket_corr, 0.05) * ln(1 + wh_stock)`, so a high-correlation **complement**
outranked every in-category peer. That is the whole bug.

`requires_cs_review` = **cross-category AND no in-category candidate exists anywhere in the
candidate set**. A cross-category row ranked _below_ a perfectly good in-category winner is filler,
not a decision, and is not flagged. `source` ∈ `in_category_performer` / `cross_category_flagged` /
`cross_category_filler`.

⛔ **v1 `find_substitutes_for_shelf` is NOT deprecated and NOT revoked.** It keeps both live callers
(`engine_swap_pod`, `compute_nowh_proposals`); Phase 3 has not yet earned the right to change swap
behaviour. Fixture 39 seq 30 pins v1's `md5(prosrc)` so an in-place edit fails the suite. ⛔ v3 has
**no consumer yet** — wiring it into the P3.1 substitution ladder is a later unit.

⭐ **Article 16:** reads `v_wh_pickable` and `get_candidate_affinity()` rather than re-deriving them.
⚠️ `pearson_score` reads **0**, not NULL, for a candidate with no correlation history (the canonical
affinity function COALESCEs; v1's inline block did not).

⚠️ `unit_margin` is **informational, not a ranking term** (D-20): `purchasing_cost` covers only
102/163 pods, so weighting it would systematically demote the rest. ⚠️ Category matching is **exact**
— see S-59 on taxonomy fragmentation; under-reach surfaces as `requires_cs_review`, never silently.

Grants: `authenticated`, `service_role`. ⛔ Explicitly **revoked from `PUBLIC` and `anon`** (v1 is
still anon-executable; v3 ships tight). Proven by golden fixture 39 (37 assertions).

### `resolve_supply_ladder_v3` (read-only helper, PRD-110 P3.1b, 2026-07-31)

`resolve_supply_ladder_v3(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_qty_needed integer, p_top_n integer DEFAULT 3) RETURNS jsonb`

- **Class:** Cody (c) read-only DEFINER review → shipped **SECURITY INVOKER**, `STABLE`,
  `SET search_path TO 'public'`. STABLE forbids DML, so "writes nothing" is enforced by
  Postgres rather than by convention. INVOKER also removes the need for a role gate: RLS
  applies as the caller, and a DEFINER here would have silently widened read access to WH stock.
- **What:** BUILD-SPEC line 88 substitution ladder —
  `variant → substitute → alt_wh → m2m → spot_buy → blocked_demand`. All six rungs are always
  logged with an explicit reason; the terminal rung is the first satisfiable one in spec order.
- **LAW 5:** asserts silent qty-0 is impossible — raises if no terminal rung resolves, if a
  non-`blocked_demand` rung resolves to qty 0, or if fewer than six rungs are logged.
- **Article 16:** reads canonical objects only — `v_wh_pickable` (WH pickable stock),
  `v_shelf_state` (live shelf stock/velocity), and delegates substitute selection to
  `find_substitutes_for_shelf_v3`. No registered metric is re-derived inline.
  ⚠️ **Named caveat on rung 4 (leg 63, Cody Article-16 finding — pre-existing, not a regression):**
  the donor-overstock arithmetic reads `COALESCE(v_shelf_state.velocity_instock, velocity_raw, 0)`.
  Per **S-73** `v_shelf_state.velocity_instock` is NULL on all 656 shelves, so rung 4 is in fact
  running on `velocity_raw` while appearing to prefer in-stock velocity. The canonical owner is
  `v_shelf_instock_velocity_split_v3`. Recorded rather than silently inherited; not fixed in the
  S-85 unit because that unit was scoped to the crash.
- ⛔ **S-85 (leg 63) — it threw on its HAPPIEST path for its entire P3.1b life, and a 38/38 GREEN
  fixture could not see it.** Every call whose demand was satisfiable from the primary warehouse
  raised `55000 record "v_sub" is not assigned yet`: the rung-2 **log** entry dereferences `v_sub`
  unconditionally, while the `SELECT INTO` that assigns it runs only when rung 1 has already
  FAILED. A `CASE` guard cannot prevent this — PL/pgSQL must resolve a record's tuple structure to
  build the expression, whichever branch executes. Fixture 40 missed it because anchors A and B are
  **both deliberately starved** (sentinel trap / contention), so the suite proved rungs 2-6 and
  never once executed terminal rung 1. Fixed by `20260731170130`: one `record` → eight
  NULL-initialised scalars, so the failure mode is removed by construction rather than guarded.
  Signature, volatility, security mode, `search_path` and `pronargdefaults` (1) all byte-identical
  — a true Article-12 `CREATE OR REPLACE`. `prosrc` md5 `ec8dffa2…` → **`920b32d0…`**.
- ✅ **D-37 + S-293 (leg 155, `20260808160000` + `20260808171000`) - the rung ORDER became a CS dial,
  and the supply base stopped re-deriving the sentinel test.** Two changes, one reviewed unit,
  because they are two edits to one body.
  (a) **D-37.** CS ruled `refill_policy_params.ladder_prefer_own_stock_transfer` **DEFAULT TRUE**:
  when the dial is on and rung 3 covers the **whole** need, `alt_wh` outranks `substitute` - moving
  your own stock beats rewriting the customer's shelf. A **partial** transfer does not qualify and
  still falls through to rung 2. ⛔ **Only the TERMINAL choice moves**: all six rungs are still
  logged 1..6 in BUILD-SPEC order, so the ladder still shows what it passed over, and rung 2's
  expensive selector is short-circuited (with an explicit reason) exactly when the preference
  preempts it. The terminal payload carries `preferred_over_substitute` and names the ruling in `rule`.
  ⭐ **LAW 4 holds and was verified, not assumed:** the only callers are `list_m2m_donors_v3`
  (read-only) and `stitch_v3`, and `stitch_v3` writes `refill_plan_output_shadow` /
  `pod_refills_shadow` only - never the live plan table. The ruled default reaches the shadow
  pipeline alone.
  ⭐ Measured live at execution: **32 of 41** stranded shelves move from `substitute` to `alt_wh`,
  unlocking a **3,459-unit** stranded pool across 5 machines and 14 pods; the remaining **9** are
  partial-cover and correctly still substitute.
  (b) **S-293.** The supply base's three buckets used an inline name-only pair. `NULL NOT LIKE …`
  and `NULL LIKE …` are both NULL, so a NULL-batch row landed in **no bucket at all** - genuine
  stock vanished from the supply base and phantom stock was excluded by accident rather than by
  rule. The buckets are now a true partition over `_is_phantom_wh_row_v3`. ⛔ It binds the
  **binder's** predicate, deliberately not the destructive RPC's `_is_sentinel_wh_row_v3`;
  converging those two remains a refusal.
  `prosrc` md5 **`056cca45…` → `011f83d8…`**, pinned by golden fixture **6 seq 50** and fixture
  **44 seq 28**. Fixture 6 **RED 55/66 → GREEN 66/66**, and its seq 27 caught the harm on the way
  through: one live shelf whose real stock the old filter could not see.
- 📌 **S-86 (leg 63) — the ladder does NOT cascade after a partial fill.** The terminal rung is the
  first **satisfiable** rung at ANY quantity, so a rung-1 fill of 1 unit against a need of 2 stops
  there and rung 2 reads `attempted: false`. The stranded unit is a **LAW 5 obligation on the
  consumer**, never on the ladder. Any caller that assumes the returned `qty_resolved` equals
  `qty_needed`, or that a shortfall implies `resolved_rung = 'blocked_demand'`, is wrong.
  Pinned by fixture 40 seq 51 and stated as a contract at seq 55.
- **Two live-data invariants it encodes:** VOXSOURCE sentinel stock (40 rows / 39,463 phantom
  units) is never counted as supply, only reported; and WH availability is netted off prior
  claims on the same `plan_date`, because the engine allocates a shared pool fleet-wide
  (`prior_need_pool`), so `wh_available_pod` is gross stock, not what remains.
- **Grants:** `REVOKE ALL FROM PUBLIC, anon` · `GRANT EXECUTE TO authenticated, service_role`
  (S-57 applied forward; pinned in both directions by fixture 40 seq 35/36).
- **Consumers:** NONE yet, deliberately (D-22). Wiring into `stitch_v3` is a later unit;
  `engine_swap_pod` still consumes v1. ⭐ S-85 was found precisely by exercising it **as that
  consumer would** — 6 real shadow-plan lines instead of 2 hand-picked starved anchors.
- **Proof:** golden fixture 40 — **56/56** (was 38/38). Anchors **C** (rung-1 full, MPMCC-1058
  A02 Red Bull) and **D** (rung-1 partial, AMZ-1046 A11 Hunter Ridge) added at leg 63, seq 39-56.
  D's demand is asked as `net_primary + 1`, computed independently from base tables, so the
  partial is guaranteed **by construction** and cannot decay into a vacuous pass as stock moves.

### `resolve_m2m_sku_legs_v3` (read-only helper, PRD-110 P3.2, 2026-07-31)

`resolve_m2m_sku_legs_v3(p_source_shelf_id uuid, p_dest_shelf_id uuid, p_lines jsonb DEFAULT NULL) RETURNS jsonb`

- **Class:** Cody (c) read-only → **SECURITY INVOKER**, `STABLE`,
  `SET search_path = public, pg_catalog`. Same reasoning as the ladder: STABLE makes "writes
  nothing" a Postgres guarantee rather than a claim, and INVOKER keeps RLS applying as the caller.
- **What:** BUILD-SPEC line 90 — M2M at SKU level. Splits a machine-to-machine transfer into
  per-SKU legs. A SKU transfers only if it is in the **destination pod's** Active assortment;
  everything else takes a `return_to_wh` leg with a named reason. Destination headroom clamps
  rather than overflows, and clamped units are reported separately from non-assortable ones.
- **The defect it exists to prevent:** `convert_removes_to_m2m_transfer` copies the source row's
  `pod_product_id` and `boonz_product_id` verbatim onto the destination shelf with no assortment
  check, so a `Krambals & Zigi` source contaminates a `Zigi` destination with Krambals SKUs
  (incident 2026-07-30). All 36 live `is_m2m` rows already carry a `boonz_product_id` — the
  storage grain was never the defect, the **pairing predicate** was.
- **LAW 5:** raises if `input_units <> transfer_units + return_units`. No unit is ever dropped;
  a unit that cannot cross is returned with a reason, never silently zeroed.
- **Article 16:** shelf stock and capacity come from `v_shelf_state`, the registered canonical
  object for shelf state. Nothing registered is re-derived inline.
- **DATA-SOURCE LAW:** `product_mapping` is read **only** as the pod→SKU assortment map, never
  to size stock — this function sums no stock at all. Every mapping read is `DISTINCT`-ed first
  (anchor pod: 253 raw rows → 21 Active → 7 distinct SKUs) and the raw row count is reported.
  ⛔ Must never be extended to aggregate warehouse stock across those joins.
- **Honest-unknown path:** with no caller lines and no `shelf_composition` coverage it returns
  `source_composition_unknown` with a remedy, rather than inventing a split across the pod.
- **Grants:** `REVOKE ALL FROM PUBLIC` · `GRANT EXECUTE TO authenticated, service_role`.
- **Consumers:** NONE yet, deliberately — same posture as the ladder. It is advisory; the caller
  emits the dispatch rows. Wiring belongs with `stitch_v3` (S-62).
- **Proof:** golden fixture 41 — 46/46, four consecutive identical runs (S7 pre-cleared).
  Fixture pins both live writers' md5 (seq 44/45), so LAW 3 is proven, not asserted.

## `rank_machines_by_value_at_risk_v3(p_plan_date date, p_limit integer DEFAULT NULL)` — read-only helper (PRD-110 P3.5, 2026-07-31, leg 58 · **REDEFINED leg 62 by CS decisions D-24 + D-25**)

`LANGUAGE sql` · **STABLE** · **SECURITY INVOKER** · `SET search_path = public, pg_temp` ·
md5 `3a6c591442f67af5526715acf455fab8` (was `8c4dc618…` at leg 58) · returns TABLE (19 cols)
ordered by `rank` · `pronargdefaults` = 1.

**What it answers:** how much money is lost if this machine is NOT visited on `p_plan_date`, and
which machines fit a driver day once any BREACHED visit-cadence floor has taken its share.

```
lost_units(shelf) = GREATEST(0, mu * demand_factor * gap_days - current_stock)
VAR(machine)      = SUM(lost_units * realized_unit_price)  over shelves, sourcing <> 'partner'
breached          = days_since_visit >= LEAST(gap_days * var_cadence_floor_multiple,
                                              var_cadence_hard_max_days)      -- D-24
staleness         = blind_shelves / shelves_total * days_since_visit          -- D-25, TIEBREAK ONLY
order             = cadence_floor_due(BREACHED) DESC, VAR DESC, staleness DESC, machine_name ASC
                    (total, hence deterministic)
selected          = contiguous PREFIX of that order that fits BOTH caps
                    (cum_minutes <= var_driver_day_minutes AND rank <= driver_capacity)
```

- ⛔ **SEMANTIC REDEFINITION, leg 62 — `cadence_floor_due` CHANGED MEANING WITHOUT CHANGING NAME
  OR TYPE.** It used to mean `days_since_visit >= gap_days` (the SOFT service target). It now means
  **BREACHED** (the hard floor above). The soft state did not disappear — it moved to
  **`reasoning.cadence.target_due`**, alongside `breach_threshold_days`, `floor_multiple` and
  `hard_max_days`, so every row still explains both. ⭐ **Why the column was redefined rather than
  added to:** a new OUT column forces `DROP` + `CREATE` (Postgres cannot `CREATE OR REPLACE`
  through a return-type change) and **Article 12 forbids DROP-and-recreate**. The name now reads
  true for the first time: a _floor_ being _due_ should mean the hard floor.
  **Blast radius, probed live before the change and recorded here so it stays auditable: 0 FE call
  sites · 0 DB function callers · 0 views · 0 cron jobs.** The sole reader was golden fixture 42.
  ⛔ Any future consumer must read `reasoning.cadence.target_due` if it wants the soft state.
- **CS DECISION D-24 (MONEY FIRST, closed 2026-07-31 ~18:05 Dubai).** Before this, cadence was the
  primary sort and put nine machines ahead of everything else — **seven carrying 0.00 AED** — while
  VOXMCC-1005-0201-B0 at **543.50 AED** sat unselected at rank 10. Cadence is now a CONSTRAINT that
  forces inclusion only when actually breached. Live effect on the same data: 4 breached machines
  forced in, then money — VOXMCC-1005 to **rank 5, selected**, plus VOXMCC-1011 (196.63) and
  ACTIVATEMCC-1037 (155.74). ~896 AED that the old order left on the shelf. Fixture 42 seq 60 is
  CS's acceptance test verbatim.
- **CS DECISION D-25 (COVERAGE TIEBREAK, same session).** `coverage_staleness` sorts blind machines
  up so they surface. ⛔ **It is a TIEBREAK ONLY and there is NO synthetic imputation** —
  `value_at_risk_aed` stays purely realized revenue, which fixture 42 seq 27 proves independently
  by recomputing every machine's AED from base tables (0 mismatches). Not registered in
  METRICS_REGISTRY: it has exactly one producer and no consumer. ⛔ **The moment a second object
  reads it, register it** (Cody, Article 16, leg 62).
- **Params (both new, both POLICY, both flippable with one UPDATE and no migration):**
  `var_cadence_floor_multiple` **2.0** · `var_cadence_hard_max_days` **14**. On live data it is the
  **14-day cap that binds**, not the multiple — the breached set is identical at 1.5×. Setting the
  multiple to 1.0 collapses breach back into the soft target and silently undoes D-24; fixture 42
  seq 61 is the sensor that reds if it ever happens.

- **Article 16 — every input read from its owner, none re-derived.** mu ←
  `v_shelf_instock_velocity_split_v3` (P2.1) · demand factor ← `resolve_demand_multiplier_v3` (P2.4)
  · cadence ← `v_machine_base_stock_policy_v3` (P2.2) · **visit clock ←
  `v_machine_health_signals.days_since_visit`** (registry line 49 — Cody made this a revision
  condition at leg 58; it had been reading `v_machine_priority`'s pass-through copy) · stock and
  capacity ← `v_shelf_state` · machine scope and `r_cluster` ← `v_machine_priority` (which owns
  `r_cluster`; `v_machine_health_signals` does not carry it).
- **DATA-SOURCE LAW:** price is realized `paid_amount / qty` from `sales_history` joined through
  `v_sales_history_resolved`. ⛔ It is NEVER read through `product_mapping` — that join fans out
  (253 raw rows for 7 distinct SKUs on one pod, S-67) and would multiply revenue. This function
  touches `product_mapping` nowhere at all.
- **LAW 11 / Gate 0:** ADVISORY ONLY. It writes nothing (Postgres enforces it: STABLE + INVOKER)
  and never touches `machines_to_visit`. ⛔ **Cody standing condition: the first consumer that
  turns this ranking into a `machines_to_visit` row is a NEW class (b) review** — that RPC, not
  this one, is where Gate 0's manual-only rule gets tested.
- **LAW 5 — what it cannot measure is COUNTED, never scored zero.** `no_price_basis_shelves`,
  `no_velocity_shelves`, `at_risk_but_unpriceable` and `partner_shelves_excluded` ride on every
  row and are repeated in `reasoning.coverage_gaps` (seq 53 pins the two copies equal). Leg 62
  adds **`blind_shelves`** (a shelf with no velocity basis OR no price basis — one the picker
  cannot turn into money for either reason) and **`coverage_staleness`** to the same blob.
  ⚠️ **S-71: a 0.00 AED machine may be a blind machine, not a safe one** — five AMZ machines carry
  24 of 40 shelves with no velocity and no price. **CS decision D-25 answers this: the ranking
  still does not compensate — it SURFACES.** Staleness breaks ties so a blind machine climbs above
  an equally-scoring measured one; it never adds a fabricated dirham to the AED figure. 13 machines
  carry strictly positive staleness live (fixture 42 seq 66 keeps that population non-vacuous).
- **Price ladder:** realized machine×pod → realized fleet pod → `pod_products.recommended_selling_price`
  → none. Live coverage 494 / 28 / 0 / 134 of 656 shelves.
- **⚠️ Cost basis is MODELLED, not measured (S-69):** `trip_events` holds **zero rows**, so nothing
  in the schema observes real driver minutes. The `var_*` defaults are a transparent standing
  assumption CS can correct with one UPDATE. They are not evidence.
- **Perf:** ~20-26 s per call — dominated by the single read of `v_shelf_instock_velocity_split_v3`
  (RISK 88 / S-26: that object costs ~20 s and machine-scoping does NOT reduce it). Read once per
  run and join; never call this in a loop.
- **Grants (⛔ CORRECTED leg 62, read from `proacl` and not from this file — S-81):** the leg-58
  object shipped EXECUTable by **`anon` AND PUBLIC**, exposing fleet-wide value at risk in AED,
  velocity coverage and visit cadence. This is the same loose-grant class migration
  `20260731121100` swept under S-57; it regrew because fixture 42 seq 51 pins **volatility**, not
  **grants**. Migration `20260731163549` revokes both. **Current: `{postgres, authenticated,
service_role}`.** ⭐ Fixture 42 **seq 67** now pins the grants (mirroring fixture 43 seq 15), so
  it cannot regrow a third time silently. INVOKER, so the caller's own RLS applies throughout.
- **Consumers:** NONE yet, deliberately — the third P3 selector shipped standalone (after
  `find_substitutes_for_shelf_v3` and `resolve_supply_ladder_v3`). Re-probed live at leg 62 across
  FE, `pg_proc`, `pg_views` and `cron.job`: **still zero.** That is what made the leg-62 semantic
  redefinition of `cadence_floor_due` safe to ship in place.
- **Proof:** golden fixture 42 — **67/67** at leg 62 (was 55/55; +12 assertions for D-24, D-25,
  S-81 and the S-79 sweep), whole P3 suite re-run green per fixture. Seq 27 recomputes every
  machine's AED figure from base tables and compares: 0 mismatches — unchanged by D-25, which is
  the proof that the tiebreak never touched the money. Seq 62 pins `cadence_floor_due` to the
  BREACH predicate machine by machine. Seq 49/50 pin both live Gate-0 objects byte-untouched.
  ⚠️ **Runtime ~108 s** — see S-77: this single fixture now sits ON the ~100 s gateway ceiling.

### `propose_rotations_v3(p_plan_date date, p_limit int DEFAULT NULL, p_dry_run bool DEFAULT false)` — PRD-110 P3.3, leg 59

- **Class:** writer. `VOLATILE` · `SECURITY DEFINER` · `SET search_path = public, pg_temp`.
  Article 4 satisfied: validates `p_plan_date` and `p_limit`, sets `app.via_rpc` and
  `app.rpc_name`, raises if `refill_policy_params` holds no row.
- **Writes:** `public.rotation_proposals_v3` ONLY, always at `status = 'pending'`.
  ⛔ **Writes no protected entity.** Fixture 43 seq 47/48/49 pin `pod_refill_plan`,
  `refill_plan_output` and `machines_to_visit` row-identical across the call — this object writes,
  so those tripwires are load-bearing, not decorative.
- **Reads:** `v_shelf_state` (stock, capacity, sourcing, expiry) and
  `v_shelf_instock_velocity_split_v3` (velocity — the OWNER, never the `v_shelf_state` copy, S-73).
- **Grants (CORRECTED leg 61, read from `proacl` not from this file):**
  `{postgres, authenticated, service_role}`. ⛔ **`authenticated` HOLDS EXECUTE** — this line
  previously claimed "`service_role` only", which was FALSE. `PUBLIC` and `anon` are genuinely
  absent. Impact is bounded (it writes an advisory `pending` queue and no protected entity),
  but any logged-in user can run the heartbeat. Tightening is parked as **S-81**.
- **Qty formula (D-26, CS 2026-07-31, leg 61):**
  `LEAST(GREATEST(source_stock - rot_keep_floor, 0), target_headroom)`, floor default **2**.
  ⛔ `GREATEST(..., 0)` is load-bearing: without it a below-floor shelf yields a negative qty
  and hence a negative `projected_days_to_sell`, which passes the LAW-7 expiry guard
  VACUOUSLY. Every `scoring_breakdown.params` records the `keep_floor` it was scored under.
- **Idempotent** per `rp_v3_unique_heartbeat (plan_date, source_shelf_id, target_shelf_id)` via
  `ON CONFLICT ON CONSTRAINT … DO NOTHING`.
  ⛔ **The constraint is named, not inferred:** a column inference list is ambiguous against the
  identically-named `RETURNS TABLE` OUT parameters and fails with 42702. **S-76.**
- ⛔ **`p_dry_run => true` SKIPS THE INSERT.** A dry-run smoke test therefore proves nothing about
  the write path — it returned 25 correct rows while the write path was broken on every call.
- **Consumers:** NONE yet, deliberately. The approved-proposal → M2M dispatch leg hop is BLOCKED
  on `stitch_v3`, which does not exist (S-62). No cron is wired; the weekly heartbeat schedule is
  parked with the CS gate.
- **Proof:** golden fixture 43 — **53 assertions**, authored RED (23 pass / 27 fail, every failure
  reading `NO_ROTATION_OUTPUT` or `-1`, zero vacuous passes). Seq 20-24 recompute the entire pair
  set, quantity, fit and projected days independently from base tables: 0 mismatches. Seq 25
  proves cross-row conservation (no destination shelf committed twice — the per-row headroom CHECK
  cannot catch that).

---

### `stitch_v3(p_plan_date date, p_source_run_id uuid DEFAULT NULL) RETURNS jsonb` — PRD-110 P3.1c

`SECURITY DEFINER`, `VOLATILE`, `search_path = public, pg_temp`, `pronargdefaults` **1**,
md5 `10ae3658198d692be16fb4699ff774e1`. Migration `20260731173122`.

**⛔ THIS IS A SKELETON, NOT THE PORT.** v1 `stitch_pod_to_boonz` is 50,903 chars (md5
`806340b2…`) and is **byte-untouched**. Not yet ported: FEFO SKU binding (**P3.1d** — every row
lands with `boonz_product_id` NULL except m2m legs), the PRD-109 preflight gate, variant
redistribution, Remove/M2W legs, and the live `blocked_demand` `source='stitch'` writer.

**Pipeline:** `pod_refills_shadow` (positive lines of one run) → `resolve_supply_ladder_v3` per
line → `refill_plan_output_shadow`. Writes **exactly one table**, which has no operational
consumer (LAW 4). Zero protected-entity writes.

**Rung → emission:** 1 `variant` → `Refill`/`warehouse` · 2 `substitute` → `Add New` on the
substitute pod, `anchor_pod_product_id` preserving what was asked · 3 `alt_wh` → `Transfer` ·
4 `m2m` → one `Refill`/`internal_transfer` row **per SKU leg**, `from_machine_id` = donor ·
5 `spot_buy` and 6 `blocked_demand` → nothing placeable, all units Blocked.

**⭐ Conservation is BY CONSTRUCTION, not by guard** (the S-85 lesson). Placeable rows are emitted
first into `v_placed`; the blocked quantity is then `qty_needed - v_placed` — **never** the
ladder's `qty_shortfall` field. Any rung, present or future, that places less than asked lands the
remainder in a `Blocked` row automatically, and the total is asserted before return. LAW 5 cannot
be violated by an omission.

**⛔ S-86 honoured.** The ladder does not cascade after a partial fill, so a terminal rung may serve
less than `qty_needed` while lower rungs read `attempted: false`. Fixture 44 seq 17 pins the
consequence: the `Blocked` row's terminal rung is **`variant#1`, not `blocked_demand#6`**. Any
consumer inferring rung 6 from the presence of a shortfall is wrong.

**⛔ S-87 honoured.** `resolve_m2m_sku_legs_v3` is **never** called with `p_lines = NULL` — on this
fleet that returns `source_composition_unknown` (`shelf_composition` covers 16 of 656 shelves) and
the units would vanish. `p_lines` is built from the donor shelf's `Remove` rows in
`refill_plan_output`, which carry `boonz_product_id`. When no SKU mix is knowable the units are
**Blocked with reason `m2m_sku_unknown`** rather than passed to a function that cannot answer.

**⛔ The rung-4 branch has never executed end-to-end.** No live line terminates at rung 4. Both of
its queries were validated standalone against real data, and the schema + fixture 44 seq 22 pin the
contract, but per the S-85 rule — _an object whose happy path has never run is not proven_ —
**executing rung 4 is the next leg's first task.**

📌 The donor shelf is resolved through **`v_shelf_state`**, the P1.2 canonical shelf↔pod object.
⛔ `shelf_configurations` carries **no `pod_product_id`** (cols: `shelf_id, machine_id, shelf_code,
shelf_size, max_capacity, created_at, is_phantom`) — a body written against it compiles fine and
throws 42703 at runtime, because plpgsql does not validate SQL in function bodies at CREATE time.

**Proof:** golden fixture 44 — **30/30**, plan_date 2030-02-14. Anchor P (Red Bull @ MPMCC-1058)
is asked at `net_primary + 1`, so the rung-1 partial is structural and cannot decay into a vacuous
pass; anchor F (Fade Fit) is an **ordinary fully-satisfied line included on purpose** per S-85.

---

## PRD-110 P3.1c — rung-4 m2m made reachable (2026-07-31, relay leg 65)

Two NEW read-only helpers. Both **SECURITY INVOKER + STABLE**, neither writes anything. Cody class
(c); this section is that class's mandatory step 4.

| Function                    | Signature                                                                                                                                                                                               | What it is                                                                                                                                                                        |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `list_m2m_donors_v3`        | `(p_pod_product_id uuid, p_exclude_machine_id uuid DEFAULT NULL)` → `TABLE(donor_machine_id, donor_shelf_id, donor_shelf_code, donor_machine_name, current_stock, velocity, cover_floor, excess_units)` | **Names** the rung-4 overstock donors the ladder only **counted**. Shelf grain, ordered `excess DESC, machine_id, shelf_id` — a **total** order, so donor choice is reproducible. |
| `resolve_m2m_donor_legs_v3` | `(p_plan_date date, p_dest_machine_id uuid, p_dest_shelf_id uuid, p_pod_product_id uuid, p_qty_needed integer)` → `jsonb`                                                                               | The rung-4 **seam**: walks donors until one has a knowable SKU mix, clamps to THAT donor's excess, returns transfer-only legs.                                                    |

### ⛔ Why a seam exists at all (S-89)

`stitch_v3`'s rung-4 branch had **executed zero times** and could not be reached to prove it:
across all **544** live shelves carrying a pod, the ladder terminates at rung 1 (**383**) or rung 2
(**161**). Rungs 3–6 are unreachable — rung 2 (`find_substitutes_for_shelf_v3`) satisfies almost
everything, **including for `partner_managed` machines**, the one operating model that disables both
warehouse rungs (and all 3 such machines have zero shelves in `v_shelf_state` anyway). Lifting the
branch behind a callable seam makes it permanently fixture-provable on real donors without forcing
the ladder or moving a single unit of stock.

### ⛔ The four defects that hid behind the unreachable branch (S-91)

- **D1 (fatal).** The ladder's payload carries `donor_machines` as `count(DISTINCT machine_id)` — an
  **INT**. `stitch_v3` tested `jsonb_typeof(payload->'donor_machines') = 'array'` and read UUIDs out
  of it. A number is never an array, so the donor was **always NULL** and every m2m unit blocked as
  `m2m_sku_unknown`. **The branch could not place one unit.**
- **D2.** `stitch_v3` blocked when the donor had no `Remove` rows — bypassing the
  `shelf_composition` fallback `resolve_m2m_sku_legs_v3` **already implements** for `p_lines IS NULL`.
- **D3.** `qty_resolved` is `LEAST(needed, SUM(excess) over ALL donors)`, but only **one** donor is
  drawn from, so stitch could place more than the chosen donor holds.
- **D4.** `resolve_m2m_sku_legs_v3` returns `transfer` **and** `return_to_wh` legs; `stitch_v3`
  looped over every leg with `qty > 0` and wrote them all as `Refill`. ⛔ Verified live on donor
  `46c0c29e` → dest `558ad2f1`: 13 transfer + **5 `dest_capacity_clamp`** units, and all 18 would
  have been pushed into the destination — the exact incident the helper exists to prevent.

### ⛔ S-92 — donor choice must consider whether the mix is KNOWABLE

Found by executing the branch, not by reading it. v1 took the biggest donor, then asked for its SKU
mix; `shelf_composition` covers **16 of 656 shelves (2.4%)**, so the largest-excess donor is
overwhelmingly one whose mix is unknowable and the units blocked against a donor we could never have
drawn from. LAW 5 was satisfied and the answer was still useless. v2 walks donors in excess order
(bounded at 10) and takes the first whose mix resolves, recording **every** attempt with a named
outcome. Live: 5 donors skipped as `source_composition_unknown`, winner A08.

**Proof:** golden fixture 45 — **18/18**, plan_date 2030-02-15. Assertions are structural and
self-consistent (the same donor set computed two ways), never pinned to today's unit counts, so
fleet movement does not flake them but a real regression in donor choice, the clamp or the
transfer-only filter does. Assertions 4–5 are the **Article 16 pin** (below).

---

## PRD-110 P3.1d — FEFO SKU binding (2026-07-31, relay leg 66)

One NEW read-only helper. **SECURITY INVOKER + STABLE**, writes nothing. Cody class (c); this
section is that class's mandatory step 4.

| Function                   | Signature                                                                                                                               | What it is                                                                                                                                                                                      |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `resolve_fefo_sku_legs_v3` | `(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_qty integer, p_rung text DEFAULT 'variant')` → `jsonb` | The pod→SKU **binding seam**: merges the per-SKU walks of `wh_fefo_for_line` across every Active variant of a pod into ONE cross-SKU FEFO order and allocates `p_qty` over it, one leg per SKU. |

⛔ **Grants (Cody binding revision):** `REVOKE ALL … FROM PUBLIC, anon` then `GRANT EXECUTE … TO
authenticated, service_role`. A new function inherits `EXECUTE` for `PUBLIC`, which reaches `anon`,
and this one returns warehouse batch ids, batch codes and expiry dates. The sibling seams are
inconsistent here (`list_m2m_donors_v3` / `resolve_m2m_donor_legs_v3` are anon-executable;
`resolve_supply_ladder_v3` / `stitch_v3` are not) — this one matches the **tighter** pair.

### ⭐ Article 16 — this seam CONVERGES, it does not mirror

The batch walk is **not** reimplemented. `public.wh_fefo_for_line` is the canonical FEFO object and
already encodes, in one place: LAW 6 ordering (`expiration_date ASC NULLS LAST`, ALL batches walked),
LAW 7 (`expiration_date >= p_plan_date`, so nothing expired by the plan date can ever bind),
pickability via the registered canonical `v_wh_pickable`, reservation honouring, and the netting of
units committed elsewhere on the same date. Sentinels are excluded through the canonical predicate
`_is_sentinel_wh_row_v3` rather than a re-typed `LIKE 'VOXSOURCE-%'` (S-63).

**The seam adds exactly one thing that object cannot do:** a single FEFO order **across** the pod's
variants, so the oldest stock in the pod leaves first regardless of which SKU it happens to be.
Fixture 46 assertion 15 **pins** the convergence (`canonical_walker = 'public.wh_fefo_for_line'`),
so a future leg that quietly re-implements the walk turns the fixture red instead of drifting.

⭐ **D-28 (PRD-110 leg 149, 2026-08-08): `wh_fefo_for_line` no longer names `refill_dispatching`.**
"Units committed elsewhere on the same date" used to be a seven-clause predicate written inline in
its `committed` CTE and repeated twice more inside `v_dispatch_availability`. It now reads the
canonical `public.v_dispatch_open_wh_commitment`, and so does the view. ⛔ **Grant consequence worth
knowing before touching it:** `wh_fefo_for_line` is `SECURITY INVOKER`, so its invoker-rights callers
(`resolve_fefo_sku_legs_v3`, `find_substitutes_for_shelf_v3`, both granted to `authenticated`) need
`SELECT` on that view - it is granted to `authenticated, service_role` and **revoked from `anon` and
`PUBLIC` by name** (S-268). ⚠️ `wh_fefo_for_line` itself still carries `anon` **and** `PUBLIC`
EXECUTE, so a direct anon call now raises `permission denied for view` where it previously returned
`committed_elsewhere = 0` - not because there was nothing committed, but because `refill_dispatching`'s
only SELECT policy is `authenticated_read` and RLS blinded anon to every competitor row. A loud
refusal replacing a silently wrong number is an improvement; **revoking that anon/PUBLIC EXECUTE is
the D-30-shaped close and is parked, deliberately not bundled.** Golden fixture 70 seq 15/16 assert
both halves of the grant. What the convergence did NOT change: `committed_elsewhere` is still the
symmetric whole-rest-of-the-field discount, byte-identical on live data (fixture 70 seq 18-22).

### ⛔ The authority split, stated so it stays inspectable

`resolve_supply_ladder_v3` decides **how many** units are placeable. This seam decides **which SKU**
they are. It never places more than it was handed, and it never overrides the ladder's count. The
two objects deliberately use **different expiry horizons** — the ladder counts stock pickable
_today_, the seam binds only stock still in date _on the plan date_ — so on a far-future plan_date
the ladder can rule units placeable that no batch can name. That is reported as `qty_unbound` with a
named `unbound_reason`, never silently reconciled (LAW 5 in the identity dimension).

Named outcomes: `no_active_variants` · `no_primary_warehouse` · `no_warehouse_in_scope` ·
`all_batches_sentinel` · `no_pickable_batch_in_scope` · `fefo_ceiling_exhausted` · `fefo_short`.

**Modified:** `stitch_v3` (SECURITY DEFINER, unchanged in its gates) now emits **one row per SKU
leg** with `boonz_product_id` **and** `preferred_wh_inventory_id` set, replacing the single row that
carried `boonz_product_id NULL` + `reasoning.sku_binding='deferred_to_p31d'`. Its return contract
gains `sku_binding='fefo_v3'`, `units_sku_bound`, `units_sku_unbound`, `sku_legs`.

**Proof:** golden fixture 46 — **27/27**, plan_date 2030-02-16. Assertions are invariants
(conservation, monotone cross-SKU FEFO order, no expired batch, no sentinel, no duplicate SKU, named
reasons), never pinned to today's unit counts, so ordinary trading cannot flake them.

---

## PRD-110 P3.1e — the blocked_demand promotion (2026-07-31, relay leg 67)

### Read-only helpers (Cody class (c); this section is that class's mandatory step 4)

All three **SECURITY INVOKER**, write nothing, `REVOKE ALL … FROM PUBLIC, anon` +
`GRANT EXECUTE … TO authenticated, service_role`.

| Function                             | Signature                                                                                                      | What it is                                                                                                                                       |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `_blocked_demand_reason_map_v3`      | `(p_named text) → text`, **IMMUTABLE**                                                                         | Maps a `stitch_v3` named reason onto the four-value `blocked_demand.reason` enum, organised by the action a human must take. md5 `cc62d0dd`.     |
| `_blocked_demand_gaps_stitch_v3`     | `(p_plan_date date) → TABLE(machine_id, shelf_id, pod_product_id, qty_blocked, reason, reasoning)`, **STABLE** | Gap source for `source='stitch'`: the latest `stitch_v3` run's `Blocked` rows + its FEFO-unbound rows, merged one row per shelf. md5 `877e1fb6`. |
| `_blocked_demand_gaps_for_source_v3` | `(p_plan_date date, p_source text) → TABLE(… same shape …)`, **STABLE**, plpgsql                               | Routes the canonical writer to the gap source for a `blocked_demand.source`. md5 `2b3ab311`.                                                     |

⛔ **The dispatcher is plpgsql with an explicit `IF`, not a SQL `UNION ALL` with `WHERE p_source =
'…'`.** The UNION form reads better but relies on the planner proving a constant qual false to avoid
executing the other branch's set-returning function. An explicit branch is guaranteed.

⛔ **`pack` RAISES**, in both the writer and the dispatcher. It is a valid `blocked_demand.source`
with no gap source until P4.4b, and a writer that returned zero rows for an unimplemented source
would be indistinguishable from a clean night.

⛔ **Same shape, deliberately.** `_blocked_demand_gaps_stitch_v3` returns the identical `TABLE(…)`
signature as the P0.5 `_blocked_demand_gaps_v3` so the writer consumes either without knowing which
it holds. `_blocked_demand_gaps_v3` is **byte-untouched** at md5 `e436b8b8`.

⚠️ These read `refill_plan_output_shadow`, which has **RLS enabled**. Called through the DEFINER
writer the effective role is the owner, so RLS does not apply; called _directly_ by an authenticated
user it could silently return fewer rows. They are underscore-prefixed and anon-REVOKEd precisely
because `record_blocked_demand_v3` is the only supported consumer.

### `record_blocked_demand_v3(p_plan_date date, p_source text DEFAULT 'engine_add') → jsonb` — UPDATED

`SECURITY DEFINER`, `search_path = public`, `pronargs` **2** / `pronargdefaults` **1** (unchanged —
cron 43's single-argument call still binds). md5 `f950b17f` (was `d03345ba`).

Still **the** and only write path for `blocked_demand` (Article 1). Article 8 satisfied by the
pre-existing `tg_audit_blocked_demand` → `audit_log_write` trigger. Now accepts `source='stitch'`;
the `engine_add` path is behaviourally unchanged and was proven so by a three-date before/after diff,
not by inspection.

⛔ **CODY BINDING REVISION, applied at this review:** the live ACL carried `anon=X/postgres`. Because
the role gate permits a NULL actor (the documented house pattern, so cron can call it), that let an
**unauthenticated** caller insert, update and delete ledger rows through a SECURITY DEFINER — S-88,
the GRANT is the write guard, not RLS. This function is cited **in this very registry** as the
exemplar of "EXECUTE granted to `authenticated`, REVOKEd from PUBLIC and `anon`", and did not follow
it. Fixed here because P3.1e widens what the function may write. Pinned by fixture 47 assertion 46.

⏸️ **NOT fixed here, its own line item:** `_blocked_demand_gaps_v3` (P0.5) carries the same `anon`
grant. It is an object this unit does not modify.

⚠️ **The stale-close DELETE is a RETRACTION, not a resolution.** Pre-existing behaviour, source-scoped
(`bd.source = p_source`), touching only `resolved_at IS NULL` rows — so stitch rows can never disturb
engine_add rows. But a row that _vanishes_ must never be read as "solved": it means the detection is
no longer reproducible from the current gap set. Inherited unchanged; changing it would alter live
cron-43 behaviour.

### `stitch_v3` — marker corrected (md5 `a8753091`, was `5d9c8a38`; `pronargdefaults` still 1)

The `Blocked`-row payload key `blocked_demand_promotion` promised a writer that now exists. It now
reads `record_blocked_demand_v3(plan_date, 'stitch') promotes this row; not called automatically
(LAW 4, D-29)`. ⛔ **stitch_v3 still does not invoke the promotion** — see the P3.1e migrations
registry entry for why. The "not yet ported" list at the P3.1c section above therefore loses one
item: the live `blocked_demand` `source='stitch'` writer now exists.

### `propose_facing_changes_v3(date, integer DEFAULT NULL, boolean DEFAULT false)` — NEW (P3.4, leg 69)

md5 `ad626601` · SECURITY DEFINER · `SET search_path = public, pg_temp` · owner `postgres`.
ACL `postgres=X | authenticated=X | service_role=X` — the house pattern this registry already names:
EXECUTE to `authenticated`, REVOKEd from PUBLIC and `anon`. Pinned by fixture 48 seq 43/44.

**Writes exactly one table — `facing_proposals_v3` — and nothing else.** No plan row, no dispatch leg,
no `machines_to_visit`, no shadow ledger, no planogram or `shelf_configurations` touch (all protected).
Seven LAW-4 tripwires in fixture 48 (seq 36–42) compare before/after counts across the live plan, the
shadow ledgers, the sibling rotation queue and `blocked_demand`. **Not wired to any cron.**

Reads `v_facing_performance_v3` and proposes that a product family holds one lane too many or too few.

- **SHRINK** needs only a below-median lane (ratio `< fac_shrink_ratio`) plus an absolute AED floor.
- **EXPAND** additionally REQUIRES `starvation_ratio >= fac_starvation_ratio`. ⛔ This asymmetry is
  the whole design: high revenue per lane on its own is an argument for **RESTOCKING** that lane, not
  for building a second one. The only evidence a second lane would sell more is that the first keeps
  running dry. Without the gate the engine would propose extra lanes for every strong seller in the
  fleet and be right about almost none of them.
- ⛔ `p_plan_date` is a **BATCH KEY, not a clock** (S-75). Every measurement comes from the live view's
  `CURRENT_DATE` windows; nothing in the body compares against it. Fixtures use synthetic 2030 dates.
- Idempotent per `(plan_date, machine_id, pod_product_id)` via `ON CONFLICT DO NOTHING`; a re-run
  writes 0. `p_dry_run` computes the full answer and writes nothing.
- LAW 5: five named skip counters are RETURNED, so every family the proposer declines to judge is
  reported rather than silently dropped.

⚠️ **PERF IS A HARD CONSTRAINT ON EVERY CALLER.** Each call is ~25–40 s: it inherits
`v_shelf_instock_velocity_split_v3`'s cost through `v_facing_performance_v3`, and machine-scoping does
NOT reduce it (the inner `vel` CTE is MATERIALIZED — S-26 / RISK 88). The function reads the view ONCE
into a temp table for exactly this reason. ⛔ Do not call it in a loop over dates or machines.

⛔ **`ON COMMIT DROP` IS NOT `ON RETURN DROP`.** The scratch tables are explicitly dropped at the top of
each call, because a second invocation inside one transaction otherwise dies on
`relation "_fac_perf" already exists`. Any future function that memoises an expensive view this way
inherits the same trap.

⏸️ **D-31 remains open against this unit's sibling:** `v_facing_performance_v3` carries a second inline
copy of `rank_machines_by_value_at_risk_v3`'s three-tier price cascade, copied verbatim so the two
cannot disagree (S-94). That is mitigation, not convergence.

---

## `record_plan_edit_v3` / `compose_plan_with_edits_v3` (PRD-110 P3.6, leg 70)

```
record_plan_edit_v3(p_plan_date date, p_shelf_id uuid, p_pod_product_id uuid,
                    p_kind text, p_qty integer, p_lock text, p_reason text) RETURNS jsonb
compose_plan_with_edits_v3(p_plan_date date, p_source_run_id uuid DEFAULT NULL) RETURNS jsonb
```

Both `SECURITY DEFINER`, `SET search_path = public, pg_temp`, role-gated on
`user_profiles.role IN ('operator_admin','superadmin')`, both set `app.via_rpc` + `app.rpc_name`
(Article 4). ACL matches the ratified v3 convention (S-104): `postgres=X | authenticated=X |
service_role=X`, anon explicitly revoked. Cody-reviewed at leg 70 (Articles 1, 2, 4, 7, 8, 12, 14, 16).

**`record_plan_edit_v3`** is the **sole write path** to `plan_edits_v3` (Article 1). It resolves
shelf→machine through `v_shelf_state` (never by shelf_code — DATA-SOURCE LAW), captures
`base_qty_at_edit` from the latest **non-composed** shadow run, and supersedes any prior active edit
on the key. ⛔ It refuses: a reason under 10 characters, a kind outside `set_qty/add/drop`, a lock
outside `hard/soft`, a `drop` carrying a quantity, and a negative quantity.

**`compose_plan_with_edits_v3`** composes a base run with the active overlay into a **new**
`compose_v3` run in `pod_refills_shadow`. It never rewrites its input and never writes an edit.
⛔ It resolves its default base run with `engine_tag <> 'compose_v3'`: composing over a previous
composed run would apply the overlay to its own output and make every soft edit read as fresh forever.

⭐ **D-45 EXECUTED (CS ruling 2026-08-04, applied leg 133, `prosrc` md5 `32d2a805` → `0f8dcfb6`):
`add` is ADDITIVE.** An applied `add` composes to **`base_qty + qty`**, `set_qty` stays ABSOLUTE, and
`drop` stays 0. Before the fix the composer applied `add` as absolute while `record_plan_edit_v3`
evaluated it as additive for its pin-contradiction guard — so "add 3" on a base of 12 composed to 3,
a silent 9-unit REDUCTION of a line the human meant to raise. ⛔ **The writer was deliberately NOT
touched**; `record_plan_edit_v3` still reads `add` additively and always did.
⛔ **Loop (b) — edits with no base line — is unchanged and must stay unchanged**: base is 0 there, so
`0 + qty = qty` was already the additive answer. This is why fixtures 1/50/54 never moved: their adds
all land on shelves the base never planned.
⭐ Proof pair, both banked and both to be retained: `golden.stress_runs`
**`2ecddab8`** (S3, `passed=false`, 33/2 — the fixed composer against the OLD sensors, seq 18 and 20
red exactly as the ruling predicted) and **`ec76abd0`** (S3, `passed=true`, **36/0** — sensors
re-based). S3 seq 36 `D45_additive_assertion_is_load_bearing` reads **5**, so the assertion is not
vacuous. Fixtures 1/11/50/51/54/57 re-run green (59/39/49/53/41/39, 0 skipped).

⛔ **`edits_considered` is counted INDEPENDENTLY of the loops that consume it**, so a base run carrying
two rows for one `(shelf, pod)` makes the accounting assertion RAISE instead of being silently
absorbed by an in-loop counter.

⚠️ Not wired to any cron. `stitch_v3` picks the latest shadow run for a date by
`(produced_at DESC, run_id DESC)`, so a composed run is picked up naturally on the next stitch —
that coupling is **implicit and untested end-to-end**; P3.7 (one pipeline) is where it gets pinned.

---

## PRD-110 P3.7 — `run_pipeline_v3` / `approve_pipeline_run_v3` (leg 71)

**`run_pipeline_v3(p_plan_date date, p_days_cover integer = 14, p_base_run_id uuid = NULL,
p_promote_blocked boolean = false, p_note text = NULL)`** · SECURITY DEFINER · md5 `prosrc`
**`d16df04a`** · runs `engine_add_pod_v3 → compose_plan_with_edits_v3 → stitch_v3` as one receipted
unit and writes one `pipeline_runs_v3` row.

⛔ **THE PIN: it never calls `stitch_v3` with a NULL source.** A NULL source resolves by
`(produced_at DESC, run_id DESC)`, and `produced_at` DEFAULTs to `now()` = the **transaction**
timestamp, so a base run and its composed run written by one pipeline TIE and the pick collapses onto
uuid ordering. Every run id is passed explicitly, and the function re-asserts afterwards that
`stitch.source_run_id` is the run it planned — if that ever diverges it RAISEs rather than reporting
a plan it did not produce. This supersedes the ⚠️ note at the end of the P3.6 section above.

⭐ **It ALWAYS composes**, even on a date with no edits: one pipeline means one shape, so "which run
did stitch consume?" never has two possible answers. Cost is one extra shadow run per night.

⛔ **A composed plan with zero lines does NOT fall back to the base** — that would resurrect every
dropped line, the exact silent revert P3.6 exists to prevent. It stops at status `composed_empty`.

⛔ `p_base_run_id` refuses a run tagged `compose_v3`: composing over a composed run applies the
overlay to its own output. ⛔ `p_promote_blocked` defaults **false** — auto-promotion into
`blocked_demand` is parked as CS decision **D-29**, so the step is built but idle.

**`approve_pipeline_run_v3(p_pipeline_run_id uuid, p_reason text)`** · SECURITY DEFINER · md5
`prosrc` **`6c88faa9`** · the **single approve verb**. At most one approval STANDS per `plan_date`,
enforced structurally by `ux_pipeline_runs_v3_standing_approval`. Approving a different run for a
date that already has one **retires the incumbent by name** (returned as `superseded_approval_of`) —
a late edit must stay approvable, but two approved plans for one night must not exist.
⛔ **S-105 order applies: the incumbent is retired FIRST**, because the partial unique index permits
exactly one standing row and claiming before retiring raises a duplicate key every time.
⛔ Requires a reason of ≥10 characters; refuses an unknown run, a run whose status is not `ok`, and
any run that has already carried an approval.

⚠️ **Article 5 note (Cody, leg 71):** the append-only trigger does not require that an approval
arrive via this RPC, because the `app.rpc_name` GUC leaks across statements in this database
(PRD-016B). What holds instead is the S-88 guarantee: `authenticated` has `SELECT` only on
`pipeline_runs_v3` and `anon` has nothing, so no application user can approve outside the RPC. The
trigger does refuse to clear, rewrite, or un-retire an approval once granted.

⚠️ Neither function is wired to any cron. LAW 4: an approval has **no live effect** — the cutover is
parked as **D-34**.

## PRD-110 S-112 / S-113 — the nightly shadow runner tells the truth (leg 72)

### Read-only helpers (Cody class (c); this section is that class's mandatory step 4)

#### `is_refill_planning_day_v3(p_plan_date date) RETURNS boolean` — NEW

`LANGUAGE sql`, `IMMUTABLE`, **SECURITY INVOKER** (Cody class (c) step 1: DEFINER was not
justified, so the safer default stands). `SET search_path TO 'public','pg_catalog'`.
`REVOKE ALL FROM PUBLIC, anon` · `GRANT EXECUTE TO authenticated, service_role`.

Returns false for a NULL date and for Saturday (DOW 6) per PRD-035 WS-E; true otherwise. Contains
no write statement. Registered in `METRICS_REGISTRY.md`.

✅ **The Article 16 debt this entry used to record is PAID (leg 95, 2026-08-03).** The inline copy
inside `_build_draft_core_v3` was the "known illegal copy to retire"; CS answered **D-35 → COLLAPSE**
and `20260803183540_prd110_p03_stage1_d35_collapse_saturday_to_helper` substituted it for
`NOT public.is_refill_planning_day_v3(p_plan_date)`. Stage 1 (behind cron 13) now asks this helper by
name, so it and `run_nightly_shadow_v3` share one calendar. Pinned by golden fixture **61**.

⛔ **NOTE FOR ANY FUTURE CALLER: this helper's guard set is strictly larger than a bare
`EXTRACT(DOW …) = 6`** — it also returns false for NULL. Swapping it in at a site that does NOT
already refuse a NULL date upstream converts a raise into a silent skip. `_build_draft_core_v3`
raises on NULL three lines above its branch, which is why the collapse was safe THERE; the migration
asserts that ordering positionally and refuses rather than assuming it.

### `run_nightly_shadow_v3(date, integer, integer, text)` — UPDATED (md5 `prosrc` `c0ddc8b5`, was `969b1042`)

Signature, role gate, input validation, `app.via_rpc`/`app.rpc_name`, and all four step bodies are
**unchanged**. Two classification sites changed:

1. The engine `EXCEPTION` handler no longer collapses every refusal into `error`. It now yields
   `blocked_gate0` (unchanged), `skipped_calendar` (the engine found no picks **and**
   `is_refill_planning_day_v3` says the date is never planned), `no_picks` (no picks on a plannable
   date — legitimate and recurring while Gate 0 is manual-only under LAW 11), or `error`.
2. The summary `CASE` propagates those two new names instead of flattening them into `error`.

⛔ **The engine's own words are still written verbatim** into `message`. This changes how a refusal
is CLASSIFIED, never what was caught — golden fixture 53 seq 13 pins that the string
`no picked/cs_added machines` survives reclassification.

`shadow_runner_log_v3.status` CHECK widened to a strict superset
(`+skipped_calendar, +no_picks`); all 72 pre-existing rows stay legal and the append-only trigger
`tg_srl_v3_no_update` is untouched (Article 7).

### `v_shadow_runner_health_v3` — REDEFINED (S-113)

Nine incumbent columns keep their names, types and ORDER (`CREATE OR REPLACE VIEW` may only
append); six appended: `log_is_alive`, `last_scheduled_at`, `last_scheduled_status`,
`last_scheduled_plan_date`, `hours_since_last_scheduled`, `last_scheduled_ok_at`.

⛔ **Two incumbent columns changed MEANING, which is the whole point:**

| column         | was                 | is                                                                                                                              |
| -------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `is_healthy`   | any run within 30h  | the **scheduled** run within 30h **and** its night did not error                                                                |
| `is_measuring` | any `ok` within 30h | a **scheduled** `ok` within **8 days** (the calendar guarantees gaps — every Saturday is skipped, and no-pick nights are legal) |

The scheduled run is identified by `shadow_runner_log_v3.note = 'cron'`, which cron job 45 now sets
and a human calling the runner by hand does not. ⛔ **NULL cannot serve as the mark** — that is
exactly what the masking manual run carried on 2026-07-31.

`log_is_alive` carries the OLD `is_healthy` semantics under a name that says what it measures, and
is the dead-schedule absence detector. Fixture 37 seq 17/18 were re-pointed onto it: they were
never about the schedule succeeding, only about the log going dark when nothing runs.

⚠️ **Cron 45's SCHEDULE was NOT changed** (`22 21 * * *` stands) — see the EXECUTION-LOG for the
measurement that refuted leg 71's proposed reschedule. Only its `command` changed, to pass the tag.
The migration RAISEs if the schedule moved.

## `swap_v3` (PRD-110 P3.6, leg 73)

```
swap_v3(p_plan_date date, p_machine_id uuid, p_shelf_id uuid,
        p_new_pod_product_id uuid, p_reason text,
        p_qty integer DEFAULT NULL, p_cross_machine_source uuid DEFAULT NULL) -> jsonb
```

The **one-verb swap** (BUILD-SPEC line 94, charter E3). A swap is TWO legs on one shelf recorded as
ONE act: `drop(outgoing)` + `add(incoming, qty)`, both **hard** locked, sharing one
`[swap_group:<uuid>]` marker in `reason`.

⭐ **It is NOT a write path.** Article 1 is satisfied because `swap_v3` **calls
`record_plan_edit_v3`** - the sole writer to `plan_edits_v3` - rather than INSERTing. The supersede
chain, `base_qty_at_edit` capture and the append-only trigger keep their single owner.

Guards: shelf resolved via `v_shelf_state` **by `shelf_id`** (DATA-SOURCE LAW, never `shelf_code`) ·
shelf must belong to the named machine · self-swap refused · **in-machine duplicate refused, counting
assortment ∪ pending `add`/`set_qty` edits** and excusing pods an active `drop` is removing (CS rule
2026-07-31) · cross-machine donor must actually hold the pod in stock. `p_qty` defaults to shelf
capacity.

⛔ **It deliberately does NOT check `guardrail_products`** - `preflight_refill_plan` owns that rule,
and a second copy is the D-35 defect.

⚠️ **Audit attribution caveat (D-36):** `record_plan_edit_v3` overwrites `app.rpc_name` with its own
name, so `write_audit_log` attributes both legs to the inner writer. A swap is therefore **not**
distinguishable from two hand-made edits in the audit table; the `swap_group` marker is the only
link. Proven by golden fixture **54 (32/32)**.

## `public.assortment_guardrails` (PRD-110 P3.1a, leg 76) - the standing-guardrail registry

```
assortment_guardrails(pod_product_id uuid PK -> pod_products,
                      reason text NOT NULL CHECK (length(btrim(reason)) >= 20),
                      active boolean NOT NULL DEFAULT true,
                      created_at timestamptz, created_by text)
```

Products that must **never be proposed** as a swap-in / size-up / substitution candidate for a
machine that does not already carry them. Seeded with one row: **Evian - 1L** (PRD-106b2).

⭐ **Why a table and not a second hardcode.** The rule already existed as a literal uuid inside
`rank_slot_suitability`. "One brain" cannot mean two engines each carrying a private copy of a
business rule, and CS should not need a migration to retire a guardrail. Golden fixture 12 seq 23
actively FAILS a fix that copies the constant instead of reading the registry.

⛔ **It is INTRODUCTION-only.** It does NOT block refilling a shelf that already holds the product -
the substitute candidate set removes already-present pods several predicates earlier. Fixture 12
seq 8 pins that, so a later leg cannot "tighten" this into a refill ban.

⛔ **RLS: the SELECT policy is `USING (true)` with NO `TO` clause, deliberately.**
`find_substitutes_for_shelf_v3` is **SECURITY INVOKER**, so a policy scoped to `authenticated`
would make the guardrail invisible to a cron or service-role caller - and an invisible guardrail
**fails OPEN**, silently restoring the exact bug it was built to fix. Do not narrow this without
re-running fixture 12 under each role. Writes mirror `refill_policy_params.rpp_write`
(operator_admin / superadmin, `(SELECT auth.uid())` form). Cody Articles 2/12/14/16.

⛔ **Deactivate with `active=false`, never DELETE** - the history of the rule is the point.

### `find_substitutes_for_shelf_v3` - amended at leg 76

One `NOT EXISTS` added to the `cand` CTE against `assortment_guardrails WHERE active`. Applied as a
**named substitution on `pg_get_functiondef`**, not a retype, so the other 146 lines are provably
byte-identical. md5(prosrc) `ca7c52f9...` -> `6aa6885e...` (pinned by fixture 40 seq 34, restated
at `20260731232443`). Still SECURITY INVOKER + STABLE; ACL preserved by CREATE OR REPLACE
(fixture 39 seq 33/34 green: anon still cannot execute, authenticated still can).

⛔ **v1 `find_substitutes_for_shelf` was NOT amended and is byte-identical (`8486ff04`).** It has
the same hole - it will still propose a guardrail product - and that is RECORDED, not fixed:
`engine_swap_pod` and `compose_nowh_proposals` consume it, v1 is explicitly not deprecated
(see above), and LAW 10 forbids the drift. Fixture 12 seq 31 pins v1's md5 to prove this leg did
not touch it, and seq 32 records the witness. **S-120** carries the convergence follow-up.

⚠️ **Not to be confused with `guardrail_products`** (6,889 rows, keyed by NAME, a pairwise
source/target compatibility matrix read by `preflight_refill_plan` ONLY, and the rule `swap_v3`
deliberately does not re-check per D-35). Different table, different rule, different owner.

---

## `propose_reallocations_v3(p_plan_date date, p_base_run_id uuid, p_composed_run_id uuid, p_dry_run boolean DEFAULT false) -> jsonb`

**PRD-110 P3.8 · added `20260731234438` · SECURITY DEFINER · `search_path = public, pg_temp` ·
sole write path for `reallocation_proposals_v3` (Article 1).**

Diffs a base draft against its composed plan. For every `boonz_wh` line whose quantity FELL between
the two - i.e. a mid-plan drop - the difference is FREED warehouse units, and each freed line is
re-offered to a shelf in the SAME plan that was clamped `blocked_no_wh` / `partial_wh_limited` on the
same `pod_product_id`. Where nothing can use them, it writes an **`unclaimed`** row rather than
nothing, so a freed unit is never silently absorbed.

⛔ **PROPOSES ONLY (LAW 4).** It writes nothing but its own CS-gated queue. It never moves a plan
line, never touches a protected table, never writes `pod_refills_shadow`.

⭐ **Article 4 satisfied:** sets `app.via_rpc` + `app.rpc_name`, validates the caller against
`user_profiles.role IN ('operator_admin','superadmin')`, NULL-checks all three keys, **refuses
base == composed**, and refuses a base run with no rows on the plan date.

⛔ **Only `availability_basis = 'boonz_wh'` lines can free anything.** Venue and partner stock was
never a warehouse claim, so "freeing" it would offer units the warehouse does not have.

⛔ **A shelf that itself freed units is never a claimant**, and neither is any other shelf on a
machine that freed units - that machine was dropped, so it will not be visited. Fixture 11 seq 25
pins this.

⭐ **Deterministic:** claimants are consumed largest-unmet-first then by `shelf_id`, and a partially
filled claimant carries its reduced remainder into the next source line, so two runs over the same
inputs produce the same queue. `ux_realloc_v3_pair` makes a re-run idempotent per composed run.

⭐ `p_dry_run = true` computes the full answer and writes nothing (fixture 11 seq 35/36).

**ACL:** `REVOKE ALL` from PUBLIC and `anon`; `EXECUTE` to `authenticated` and `service_role` - the
v3 fleet convention (S-104). **Proven by fixture 11: 39/39.**

⏸️ **NOT WIRED INTO `run_pipeline_v3` - see S-123.** Today it is an explicit call. Wiring it into the
nightly pipeline edits an engine, moves that engine's md5, and needs its own fixture first (LAW 1).

---

## `submit_feedback_v3(p_channel, p_machine_id, p_intent, p_note, p_shelf_id, p_boonz_product_id)` — PRD-110 P4.1, 2026-08-01 leg 80

`SECURITY DEFINER` · migration `20260801012431_prd110_p41_feedback_verbs` · md5 `00318176`.

**The only writer of `feedback_ledger_v3`** (verified live, not asserted: a `prosrc` sweep over every
function in `public` returns no other writer of any of the three P4 tables). Channels: `driver`,
`client`, `cs`, `miner`.

⭐ **The driver channel WRAPS `driver_propose_adjustment`; it does not restate it.** That function
already writes `driver_recommendations`, `driver_feedback` and `refill_edit_signals`. Duplicating
those writes would give one event two independent records that immediately drift.
`feedback_ledger_v3.driver_rec_id` exists so the wrap is traceable, and `chk_fbl_v3_driver_channel`
is an **equivalence**, so the DDL itself forbids a driver row without a rec and a non-driver row with
one. The eight planning intents fold onto that table's own five-value vocabulary
(`always_stock`/`dont_reduce`/`more_facings` → `needs_product`, `never_stock`/`less_facings` →
`overstocked`, the rest pass through).

⛔ **AND IT RESTORES `app.rpc_name` AFTERWARDS.** The inner verb stamps the GUC with its own name and
both settings are transaction-local, so without the restore **every driver submission — and anything
else writing later in the same transaction — is audited as `driver_propose_adjustment`.** Fixture 56
seq 24 pins it; the falsification run (restore removed) produced **exactly one red, at seq 24,
`got=driver_propose_adjustment`**.

⭐ **Article 4:** per-channel role sets validated by joining `user_profiles` on `auth.uid()`, never
`auth.jwt()`. Refuses a note under 10 characters, an unknown channel or intent, a missing machine,
and — the quiet one — **a shelf belonging to a different machine**, which no FK can catch because
both rows are perfectly valid and which would eventually aim a pin at a plan nobody complained about.

**ACL:** `REVOKE ALL` from PUBLIC and `anon`; `EXECUTE` to `authenticated` and `service_role` (S-104).

---

## `propose_pin_from_feedback_v3(p_feedback_ids, p_plan_date, p_pin_kind, p_trigger_reason, p_pin_value, p_pin_mode, p_pin_expires_at)` — PRD-110 P4.1

`SECURITY DEFINER` · same migration · md5 `f6ca591e`. **The only writer of `feedback_proposals_v3`.**

⭐ **THE TARGET IS DERIVED FROM THE EVIDENCE, NOT PASSED IN.** The caller supplies the feedback ids
and the _shape_ of the pin; `machine_id`, `shelf_id` and `boonz_product_id` are read off the cited
rows. That is what makes the provenance chain load-bearing rather than decorative — a proposal
**cannot** aim somewhere nobody complained about, so fixture 16's "provenance intact" claim becomes a
property of the verb instead of a convention. Fixture 56 seq 9 asserts it as an inequality over all
proposals, not a spot check.

⛔ **Evidence is SPENT on citation** (`open` → `proposed` + `triaged_at`, which
`chk_fbl_v3_triage` forces as a pair). Without this one complaint could justify any number of pins and
P4.3's acceptance-rate telemetry would be counting the same row repeatedly. Re-citing a spent row is
refused by name.

⛔ **`count(DISTINCT)` IGNORES NULLS**, so one product plus two product-less rows would read as
agreement. The verb tallies the NULLs separately — that tally is what makes the check real.

⭐ Evidence may disagree on **shelf** (several shelf complaints about one product on one machine
legitimately generalise to a machine-wide pin); the generalisation is **recorded** in
`scoring_breakdown.shelf_scope`, never guessed silently. Evidence may **not** disagree on machine or
product. Duplicate ids are de-duplicated: citing one complaint three times is not three pieces of
evidence.

⭐ A contradiction (`always_stock` vs a live `never_stock`) is **flagged here, refused at approve** —
CS may well intend to flip a standing rule, and the refusal belongs where the pin is actually minted.
One pending proposal per `(target, kind)`: the predecessor is moved to `superseded`.

**ACL:** as above. Role gate: `operator_admin` / `superadmin`.

---

## `approve_feedback_proposal_v3(p_proposal_id, p_decision, p_review_note)` — PRD-110 P4.1

`SECURITY DEFINER` · same migration · md5 `e4bf1bb3`. **The only minter of `planning_pins_v3`.**

`p_decision IN ('approve','reject')`; only a `pending` proposal can be decided, and a settled one
cannot be re-decided. A rejection is reviewed and stamped but mints nothing —
`applied_pin_id` stays NULL.

⛔ **THE CONTRADICTION GUARD READS THE BASE TABLE, NOT `v_planning_pins_active_v3`, AND THAT IS
DELIBERATE.** See the Article 16 carve-out in `METRICS_REGISTRY.md`: the guard must match
`ux_pin_v3_stock_policy_exclusive`, whose predicate is `revoked_at IS NULL` **alone**. The canonical
view additionally hides _expired_ pins, which still occupy the uniqueness slot — so reading the view
here would let an expired-but-unrevoked `never_stock` slip past and resurface to CS as a bare
`23505`. ⛔ **Do not "fix" this to read the view.**

⭐ A newer approved pin of the **same** kind **supersedes** its predecessor: the old row is revoked
(attributed, reason `superseded_by_proposal <id>`) and kept, which is what answers "what constrained
the plan on `<date>`?" later. ⛔ **Order is load-bearing** — `ux_pin_v3_active_one_per_kind` admits
one live pin per `(target, kind)`, so the predecessor is retired **before** the successor is
inserted; insert-first raises `23505` every time.

⭐ **Article 8:** `chk_pin_v3_revoke` demands a named revoker for any reason other than
`expired_system`, so with no identified caller the verb **refuses to supersede** rather than
laundering a human act as a system expiry.

**ACL:** as above. Role gate: `operator_admin` / `superadmin`.
**Evidence for all three: fixture 56, 40/40 live, twice, each in its own transaction (59 ms, 58 ms);
RED at 4/41 before this migration.**

### Amendment 2026-08-01 (S-128 option (b), relay leg 83) — `never_stock` IS REFUSED, NOT MINTED

`prosrc` md5 `e4bf1bb3` → **`0be4d718`**. Migration `20260801024503`. **INTERIM — this block is
designed to be removed.**

P4.2's engine consumer reads `protect_depth` / `min_facing` / `always_stock`, all of which are
**FLOORS**. `never_stock` is a **CEILING**: a different branch that must force qty to 0, name itself
as the clamp, and survive the P2.5 unconditional floor that would otherwise re-raise the line. LAW 1
says it is not built before the fixture that proves it.

⛔ **The failure mode this closes was SILENT.** CS could approve a `never_stock` pin, the verb would
mint it, `v_planning_pins_active_v3` would report it **active**, and the engine would plan the shelf
anyway. A rule that is accepted and then ignored is strictly worse than one that is refused.

⛔ **Two placement decisions, both load-bearing, both falsified rather than argued:**

- **The guard PRECEDES the contradiction guard.** Hoisting it below produced exactly three reds
  (fixture 56 seq 35/41/44). "Revoke the live `always_stock` first" is _true_ but _misleading_ — it
  invites CS to retire a standing rule to unblock an approval that would still fail afterwards.
  Asserted against `prosrc` by **fixture 56 seq 44**.
- **The guard sits INSIDE the approve branch, so REJECTION stays legal.** Hoisting it above the
  reject branch produced exactly one red (seq 43). A proposal that could be neither approved nor
  rejected would sit in CS's queue forever — a permanent stuck state traded for a silent wrong one.

⚠️ **CONSEQUENCE: the contradiction guard above is now a DEAD BRANCH, in both directions.**
`never_stock` is refused earlier; `always_stock` needs a live `never_stock` pin to collide with, and
none can be minted. ⛔ **Do NOT delete it as dead code** — it becomes load-bearing again the moment
the ceiling branch ships, and delete-then-restore is how the ordering bug returns. Its _structural_
counterpart (`ux_pin_v3_stock_policy_exclusive`) is untouched and still proven independently by
**fixture 55 seq 7** at the index level; what leg 83 gave up is a message test, not a protection.

⭐ **REMOVAL CONTRACT — the ceiling-branch unit must, in ONE migration:** drop this guard · retire
fixture 56 **seq 42** (`never_stock` pin count = 0 fleet-wide) · re-state **seq 35/41/44**. Split
across two units, the tripwires fire on the fix itself.

**Evidence: fixture 56 RED 42/3 (seqs 35, 41, 44) recorded in `golden.runs` BEFORE the guard, GREEN
45/45 after; regression 55 26/26, 16 31/31, 17 25/25 all re-run live; `engine_add_pod_v3` `e9f3caff`
and `stitch_v3` `a8753091` byte-unchanged.**

### Amendment 2026-08-01 (PRD-110 P4.2, relay leg 82) — `engine_add_pod_v3` READS PLANNING PINS

`engine_add_pod_v3(date, integer)` now performs the P4.2 **L0 constraint read**. Signature, oid and
ACL unchanged; `prosrc` md5 `a79bbe1f` → **`e9f3caff`**. Migration `20260801022432`.

**What a pin means, precisely.** A pin is a **FLOOR on the units this visit plans**, never a licence
to fill the shelf:

| kind            | value | floor contributed                                 |
| --------------- | ----- | ------------------------------------------------- |
| `protect_depth` | V     | `GREATEST(V - current_stock, 0)` — a DEPTH target |
| `min_facing`    | V     | `V` — facings placed THIS visit                   |
| `always_stock`  | NULL  | `1` — a presence guarantee                        |
| `never_stock`   | NULL  | **not consumed** (a ceiling, not a floor — S-128) |

The per-shelf floor is `max()` over active pins, capped by `fill_to_cap`, then folded into
`need_raw`'s `GREATEST`.

⛔ **`always_stock` is a floor on UNITS, not on DEPTH.** As a depth rule it would be a no-op on every
shelf already holding stock, and therefore exactly redundant with the P2.5 unconditional floor which
already fires at `stock = 0`. As a units rule it does real work: on fixture 16's A07 (stock 5, cover
0, warehouse dry) it converts a line the engine would have passed over **in silence** into a NAMED
`blocked_no_wh` row — LAW 5, and the thing that routes the unit into `blocked_demand`.

**Reads `v_planning_pins_active_v3`, never the base table** (Article 16; the base table keeps revoked
AND expired pins forever). Scoped by machine + **shelf_id**, plus an `EXISTS` on `product_mapping`
(`status='Active'`) so a pin retires itself when its shelf is repurposed. ⛔ **Never by pod
identity** — A01 and A03 are both Coca Cola Zero on `VML-1003-0400-O1`, so a pod-resolved pin would
move a shelf nobody named.

**Clamp ladder — two orderings, both load-bearing and both asserted:**

- **Availability OUTRANKS the pin**: `blocked_no_wh` / `partial_wh_limited` are tested BEFORE
  `pin_floor`. A pin raises DEMAND; it never conjures STOCK (fixture 16 seq 16).
- **The pin OUTRANKS the expiry ceiling**: the `expiry_ceiling` branch gains `AND NOT pin_binds`,
  because a binding pin already overrode the ceiling inside the `GREATEST` and naming the ceiling
  would name a constraint that decided nothing (fixture 16 seq 8).

`pin_binds` is computed **once**, in `final`, so the ladder and the reasoning blob cannot disagree.

**New `reasoning` keys, on EVERY line pinned or not** (LAW 5 — an unpinned line records `0 / 0 /
false` explicitly): `pin_floor_units`, `pin_count`, `pin_binds`, `need_raw_no_pin`. ⛔ They live in a
**THIRD** `jsonb_build_object` merged with `||`: the base object is at **49 pairs = 98 arguments**,
one pair short of the 100-argument ceiling, and adding a key there kills every run with `54023`.

⭐ **Regression safety is structural, not tested-in:** `pin_floor_units` is 0 on every unpinned line,
so `pin_binds` is FALSE (never NULL — `FALSE AND NULL` is `FALSE`), so the new branch never fires and
the expiry branch keeps its original condition. An unpinned fleet plans byte-identically.

**Evidence: fixtures 16 (31/31, 67.2 s) and 17 (25/25, 66.2 s) live, both RED before this migration
(20/11 and 19/6). Falsification — hoisting `pin_floor` above `blocked_no_wh` — produced EXACTLY ONE
red, seq 16 `got=pin_floor exp=blocked_no_wh`.**

---

## `mine_edit_history_v3` — PRD-110 P4.3a, WS-H2 edit-history miner (leg 85, `20260801031252`)

`mine_edit_history_v3(p_plan_date date, p_lookback_days int = 90, p_min_occurrences int = 2,
p_machine_id uuid = NULL, p_limit int = 25, p_dry_run bool = false) -> jsonb`.
SECURITY DEFINER, `search_path = public, pg_temp`, `postgres/authenticated/service_role` (S-104).

⛔ **It is NOT a writer.** It writes no table directly: evidence goes through `submit_feedback_v3`
(channel `miner`, whose operator_admin/superadmin gate P4.1 built for exactly this) and the proposal
through `propose_pin_from_feedback_v3`. Both queue tables keep exactly one canonical writer
(Article 1); fixture 57 seq 37 asserts it against `prosrc`. Attribution is re-stamped after each
inner call — without it every later write in the transaction is audited as the inner verb
(the fixture-56 seq-24 landmine); seq 35 pins it.

**Sources:** `plan_edits_v3` (v3-native, carries `base_qty_at_edit` so direction is exact) and
`pod_refill_plan_audit` (the legacy before/after ledger — the charter's "months of labeled training
data", 1710 rows back to 2026-05-19). `reopen` / `convert` are status transitions, not preferences,
and are outside the vocabulary.

⛔ **THE FOUR REFUSALS — each is a defect it would have been easy to ship, and each is named in the
receipt rather than dropped:**

1. **A TRIM never becomes a pin.** `protect_depth` and `min_facing` are FLOORS; there is no ceiling
   pin kind. CS cutting a line 10 → 7 three times means "stop sending 10", and the only available pin
   would pin it AT the quantity being cut to. ⭐ **Proven by falsification, not assertion:** a mutant
   miner mapping `trim -> protect_depth` turned fixture 57 to 29/10, and seq 8 read `GOT 7` — the
   inversion caught in the act with the exact number. Live data has **zero** trim clusters, so this
   branch is unreachable outside a fixture; seq 10 with its non-vacuity companion seq 11 is the
   only thing standing between this and a silent inversion.
2. **`never_stock` is never minted.** S-128(b) refuses it at approve, so the proposal would be dead
   on arrival and would depress G12 while measuring nothing.
3. **A product is never invented.** Edit history is at POD grain, pins at BOONZ PRODUCT grain. A pod
   that does not resolve to exactly one active boonz product under the house rule
   (`status='Active' AND (machine_id = <m> OR machine_id IS NULL)`) is reported, not guessed at.
   ⚠️ **On live data this is the DOMINANT outcome — 88 of 100 clusters — and it is the substance of
   D-39, not a rounding error.**
4. **Nothing is silently capped**: `already_pinned`, `already_pending_identical`, `over_limit` and
   `writer_refused` each appear by name in `skipped`.

**Recurrence is counted in DISTINCT plan_dates**, not rows — three edits on one date are one
occasion on which CS reached a conclusion, not three (fixture 57 seq 16/17). **H3** excludes
unexplained edits (reason < 10 chars) and superseded `plan_edits_v3` rows — the latter being the only
machine-readable "the author took it back" signal available, since reasons are free text.

⭐ **Article 16:** the `already_pinned` guard asks _"is a pin in force?"_ and therefore reads
`v_planning_pins_active_v3`, never the base table. Seq 36 asserts both halves against `prosrc`.

**Idempotency:** a second run on unchanged inputs makes 0 proposals and spends no fresh evidence
(seq 27/28/29). **Dry run** computes the identical answer and writes nothing (seq 30/31/32).
**Evidence: fixture 57 = 39/39, ~110 ms, green across four consecutive committed runs.**

---

## `mine_pick_history_v3(p_as_of date, p_window_days integer, p_dry_run boolean)` — PRD-110 P4.3b (leg 87)

**Class:** writer DEFINER. **Writes:** `picker_weight_proposals_v3` (not a protected entity).
**Reads:** `v_pick_decision_cohorts_v3` (canonical, Article 16), `machines_to_visit` (feature values,
under the leg-86 carve-out), `picker_feature_param_map_v3`, `refill_policy_params`, and
`pick_urgency_params` **SELECT-ONLY**.

⛔ **THE APPLICATION IS PARKED AND THE PARKING IS ENFORCED, NOT ASSERTED IN A COMMENT.** This function
proposes weight changes; it never applies them. `SECURITY DEFINER` owned by `postgres` bypasses RLS,
so nothing in the schema PREVENTS a write to `pick_urgency_params` — which is precisely why fixture
58 carries three standing assertions that re-prove it on every run (S-138): `updated_at` byte-unchanged
across a real run, still at the `2026-07-13 17:36:38.481583+00` baseline, and the `prosrc` matching no
`INSERT|UPDATE|DELETE` against that table.

**Method.** On each learnable `plan_date`, every same-day (kept, dropped) machine pair is one
observation; a feature is CONCORDANT when the kept machine's value is higher. Candidates aggregate
**by dial**, led by the feature with the largest `|concordance − 50|`; `pairs` is the LEAD's, never
the sum across features, which would double-count the same machines under two names.

**`pairs` vs `comparable_pairs`.** `pairs` counts pairs EVALUABLE on that feature (both sides
non-null); `comparable_pairs` counts those that are not ties. Concordance is computed over the
comparable subset and `pl_min_pairs` gates on it, because ties add no statistical power. The
evaluable count is what gets STORED, so a reviewer can see the tie fraction — live, `empty_shelves_count`
sits at 1318 evaluable / 474 discriminating, meaning **64% of the evidence is ties**.

**Polarity** is read from `picker_feature_param_map_v3.param_rewards`, never a `CASE` here:
`direction = 'raise'` iff `(concordance > 50) = (param_rewards = 'high')`. A one-row `UPDATE` can
falsify the sign, and fixture 58 proves it does.

**Nothing is silently capped.** `below_concordance_band`, `below_min_pairs`, `below_min_days`,
`no_such_dial`, `round_to_equal`, `pending_exists`, `max_proposals_reached`,
`feature_is_not_a_numeric_column_on_machines_to_visit`, `inactive_in_map`, `no_comparable_pairs` and
`not_lead_for_<dial>` each appear by name. Every failed GATE is reported, not merely the first tested.

⛔ **S-137 is designed in, not discovered.** `CHECK (proposed_weight <> current_weight)` aborts the
whole run for any candidate whose move rounds back onto its current weight — `w_expiry` at 0.120
needs ~0.42% before `numeric(6,3)` moves at all. The band is gated strictly `>` and a round-to-equal
candidate is refused BY NAME, taking no other proposal down with it.

**Article 4:** `app.via_rpc` + `app.rpc_name`, `user_profiles` role gate on `(SELECT auth.uid())`
(`operator_admin`/`superadmin`), `p_window_days <= 0` rejected.
⚠️ **Article 8 gap (S-127):** `picker_weight_proposals_v3` has no write-audit trigger yet — this
writer stamps correctly, so the trigger works the day it is installed. Eighth of eight tables.

**Evidence: fixture 58 = 42/42, ~350 ms, green across four consecutive committed runs.**
**Not scheduled.** Neither miner has a cron job yet.

### `g12_verdict_v3(p_accepted int, p_decided int, p_min_decided int, p_bar_pct numeric) -> text`

**Read-only helper** (PRD-110 P4.3c, leg 88, `20260801042730`). `IMMUTABLE`, **SECURITY INVOKER**
(Cody class (c): DEFINER was not justified, so the safer default stands). Reads no table, writes
nothing. ACL `{postgres,authenticated,service_role}` - **no `anon`**. One overload.

Domain: `insufficient_evidence` | `incoherent` | `pass` | `fail`. Sole consumer today is
`v_proposal_acceptance_v3`, which calls the same helper the fixture tests directly - so the tested
logic and the shipped logic cannot drift.

⛔ **CODY, leg 88 - the NULL-bar arm is not optional.** `(100.0 * accepted / decided) >= NULL`
evaluates to NULL, which is not TRUE, so a bare `ELSE 'fail'` would render a **missing threshold** as
"the miner is noise" - the worst possible default, and S-126 (a NULL that passes through a boolean
gate as a decision) in a new organ. NULL bar, NULL min_decided, NULL accepted and NULL decided all
return `insufficient_evidence`. Pinned by fixture 59 seq 41/42.

⛔ **Gate the boundary, do not discover it (S-137).** `>= bar` is a PASS and `decided >= min_decided`
is enough evidence - both inclusive, both exercised exactly on the boundary by fixture 59 seq 33/37.

**Evidence: fixture 59 = 50/50, ~40 ms, green twice committed. Seq 35-44 test all ten helper
branches with no data at all.**

## `run_weekly_miners_v3(p_invoked_by text, p_pick_dry_run boolean, p_edit_dry_run boolean) -> jsonb`

**Schedule entry point** (PRD-110 P4.3d, leg 89, `20260801045333`). `SECURITY DEFINER`,
`search_path = public, pg_temp`. Writes **only** `miner_runs_v3`. One overload.
ACL `{postgres=X/postgres,service_role=X/postgres}` - ⛔ **deliberately NOT granted to
`authenticated`**: it can mint live proposals the moment the dials flip, so it is a schedule entry
point and not an FE affordance. Called by cron **46** `prd110_p43d_weekly_miners_0530_dubai`
(`30 1 * * 1`, Monday 05:30 Dubai) as the bare `SELECT public.run_weekly_miners_v3(p_invoked_by =>
'cron');` - Article 11.

**What it does:** reads `refill_policy_params.miner_weekly_{pick,edit}_dry_run` (both **TRUE**), runs
`mine_edit_history_v3` then `mine_pick_history_v3` **each in its own subtransaction**, normalises two
incompatible return vocabularies into one row shape, and appends one `miner_runs_v3` row per miner
sharing a `batch_id`.

⛔ **WHY A WRAPPER AND NOT LOGGING INSIDE THE MINERS.** Both miners are proven objects with pinned
`prosrc` md5s (fixtures 57, 58). Teaching each to log would rewrite two proven bodies for a concern
that is not theirs. **Neither miner changed by one byte** - fixture 60 seq 19/20 assert exactly that,
so the justification is falsifiable rather than asserted. ⚠️ **The honest cost: a miner invoked
DIRECTLY leaves no log row.** This table answers "what did the SCHEDULE find".

⛔ **THE DIALS ARE THE PARKED CS DECISION AND CANNOT BE WALKED AROUND.** Passing either
`p_*_dry_run` requires `operator_admin`/`superadmin`, or a NULL `auth.uid()` (cron / postgres /
harness). Without that check the dials would be advisory - anyone could pass `false`. Fixture 60 seq
45 pins it. `p_invoked_by` is validated **before** the override check and before either miner runs:
a call that cannot be logged must not mine (seq 46 pins the ordering).

⛔ **PROVENANCE IS STAMPED IMMEDIATELY BEFORE THE LOG INSERT, NOT AT THE TOP.** Both miners set
`app.rpc_name` to their own name while they run, so an early stamp is overwritten and the log row
would name the miner. Restored to `false`/`''` after, because the GUC leaks across statements in this
codebase (seq 53/54).

⭐ **`query_canceled` and `admin_shutdown` are re-raised, never swallowed.** A statement timeout is
not a miner finding, and if it were caught the very next INSERT would be cancelled too - the run
would die **without** the log row the handler exists to write.

**Returns** `{ok, batch_id, invoked_by, pick_dry_run, edit_dry_run, warnings, runs[]}`.
`warnings` may carry `synthetic_pending_blocks_live_minting` - see S-142.

### `miner_refusal_tally_v3(p_codes text[]) -> jsonb`

**Read-only helper** (same migration). `IMMUTABLE`, **SECURITY INVOKER**, reads no table.
ACL `{postgres,authenticated,service_role}` - no `anon`. One overload.
Tallies refusal codes to `[{code,n}]` ordered `n DESC, code ASC`. ⛔ **NULL and empty both return
`[]`, never NULL** - a run with nothing to refuse and a run whose refusals were lost must not look
the same. Every branch is testable with no data at all (fixture 60 seq 21-25), the `g12_verdict_v3`
shape.

**Evidence: fixture 60 = 54/54, ~150 ms, green twice committed. Neighbours 57/58/59 re-run green.**
**Scheduled weekly, dry, from 2026-08-03.**

---

## `public.create_spot_purchase_v3` (PRD-110 P4.4, leg 91, `20260803171126`)

```
create_spot_purchase_v3(p_machine_id uuid, p_warehouse_id uuid, p_supplier_id uuid,
                        p_lines jsonb, p_dispatch_date date DEFAULT NULL,
                        p_receipt_photo text DEFAULT NULL, p_po_id text DEFAULT NULL,
                        p_note text DEFAULT NULL, p_dry_run boolean DEFAULT false) RETURNS jsonb
```

SECURITY DEFINER · `search_path=public, pg_temp` · ACL `{postgres,authenticated,service_role}`, no
`anon` · one overload · md5 `79305485`.

One transaction: PO mint-or-attach -> auto-close the walk-in driver task -> receive into the
**requested** warehouse -> machine-scoped FEFO bind -> `blocked_demand` resolution ->
`procurement_events`. It **composes** `create_purchase_order`, `add_purchase_order_lines` and
`bind_dispatch_fefo` and **edits none of them** - which is the condition Cody's verdict rests on.

⛔ **Gate is `warehouse+`, NOT `field_staff+` as the leg-90 design specified (S-144).**
`bind_dispatch_fefo` refuses `field_staff` outright, so a driver-called happy path would have raised
inside the binder. A new RPC must never hand a role a power its own component writers deny. The
driver-facing path is **P4.4b**.

⛔ **Writes NO `inventory_events` (S-146).** That table is machine+shelf grained (both NOT NULL, plus
`tg_assert_shelf_machine_match`); a warehouse receive is not a shelf-composition fact and inventing a
`shelf_id` would poison the P1.4 estimator. `spot_buy_receive` belongs to the moment spot goods enter
a SHELF - i.e. P4.4b.

⛔ **`p_warehouse_id` is REQUIRED and has no default (S-141).** ⛔ **`bind_dispatch_fefo` is always
called with the single machine's `official_name`, never NULL (S-143).**
⛔ **Partial cover does NOT close a larger block (LAW 5)** - the row stays open and the shortfall is
written to `resolution_note`. Restores `app.via_rpc`/`app.rpc_name`/`app.provenance_reason` on BOTH
exit paths (Article 4 / PRD-016B leak).

⏸️ **NOT YET FIXTURED - golden fixture 18 is owed and is the next task.** Evidence today is a live
dry-run smoke probe plus a zero-residue re-probe, not a golden run.

---

## `record_plan_edit_v3` / `submit_feedback_v3` — D-38 amendment (2026-08-03, relay leg 96)

**No signature change on either verb; both keep one overload, SECURITY DEFINER and their whole ACL.**
Registered here because their CONTRACTS changed, not their shapes.

**`record_plan_edit_v3`** (`b77f9e9a` → `7c510cd1`) additionally: reads the engine-recorded pin floor
from the base `pod_refills_shadow` line it already resolves; decides `pin_contradiction` as
`floor > 0 AND effective < floor AND effective < base`; when true, emits evidence through
`submit_feedback_v3` on channel `cs` with intent `pin_contradiction`, **restores `app.via_rpc` /
`app.rpc_name` afterwards** (the inner verb overwrites them — fixture 56 seq 24), and stamps
`pin_floor_at_edit` / `pin_contradiction` / `pin_feedback_id` onto the inserted row. Three new keys
are echoed in the return jsonb so the FE can say it out loud. ⛔ **Still the sole writer to
`plan_edits_v3` (Article 1), and the edit still WINS — nothing clamps the human at the machine.**
⭐ **Never invents a SKU (D-39's standing rule):** the boonz product is attached only when the pod
resolves to EXACTLY ONE Active mapping; 0 or 2+ resolve to NULL and the evidence still lands,
machine- and shelf-addressed.

**`submit_feedback_v3`** (`00318176` → `26ffe548`) accepts a **ninth** intent, `pin_contradiction`.
⛔ It is its own value rather than a reuse of `less_facings` or `other` deliberately — D-40 is the
standing lesson that attaching a new signal to the nearest-looking existing one moves the system in a
direction nobody sanctioned while every count-based assertion stays green. ⚠️ **`pronargdefaults` is
2 on this verb and 0 on `record_plan_edit_v3`** — assert the real number per verb after any
`CREATE OR REPLACE`, never a convenient uniform 0 (S-163; 13-day driver-confirm outage precedent).
⏸️ **Open, parked:** the verb does not restrict who may submit `pin_contradiction`. It is
system-generated by `record_plan_edit_v3` today, but a driver could submit one and dilute the G12
stream. Gating it is beyond D-38's wording (LAW 10).

## Leg 98 — the two D-19 gate probes

- `golden.probe_stitch_under_mode(p_plan_date date, p_mode text, p_dry_run boolean, p_force boolean, p_force_reason text)`
  → jsonb, INVOKER. **Leg 98.** Temporarily forces `refill_policy_params.preflight_enforcement`,
  calls `public.stitch_pod_to_boonz`, and **restores the flag on every path** — happy, caught-exception,
  and mode-validation-refusal alike. Returns `result` / `error` / `override_log_delta`.
  ⚠️ Modelled directly on `golden.probe_commit_under_mode`, which covers the OTHER enforcement site.

- `golden.probe_atomic_commit_under_mode(p_plan_date date, p_mode text, p_machine_names text[])`
  → jsonb, INVOKER. **Leg 98.** Same envelope around `public.commit_refill_plan_atomic`.
  ⛔ **Call this ONLY where the preflight verdict is `FAIL` and the mode is `block`** — i.e. only where
  the call is guaranteed to abort at the gate and roll back. In any other combination
  `commit_refill_plan_atomic` runs a REAL stitch, and on a fixture's synthetic rows that is a live
  write, not a probe. Fixture 63 satisfies the precondition by construction.

⛔ **THE FINDING THESE TWO PROBES EXIST TO RECORD (S-172).** `preflight_enforcement` is a single global
flag, and it arms **three** call paths, not the one fixture 33 covers:

| path                        | gated?           | escape hatch                                  | who calls it                                          |
| --------------------------- | ---------------- | --------------------------------------------- | ----------------------------------------------------- |
| `commit_refill_plan`        | yes              | `preflight_override_v3` — audited, single-use | **nothing in `src/`**                                 |
| `stitch_pod_to_boonz`       | yes              | `p_force` + ≥10-char reason, inline           | FE `RefillPlanningTab.tsx:680`                        |
| `commit_refill_plan_atomic` | **transitively** | **none**                                      | FE `RefillPlanningTab.tsx:960` — the only commit path |

`commit_refill_plan_atomic` calls `stitch_pod_to_boonz(p_plan_date, false)` and then RAISEs unless
`v_stitch->'write_result'->>'status' = 'ok'`. A block-mode refusal returns `{'status':'preflight_failed'}`
with **no `write_result` key at all**, so the atomic commit aborts with
`stitch write_result=null — rolling back (PRD-019 E2).` The gate therefore does have real teeth on the
production path — the commit rolls back, proven by fixture 63 seq 50/51 — but the invariant id, the
`fix_path` and the `p_force` instructions are all discarded before the operator sees them, and the
function hard-codes `false` with no `p_force` passthrough, so **the audited hatch is unreachable from
the only commit button the FE has.**

---

## leg 99 (2026-08-03) — D-41: the legacy Stage-1 tier is no longer anon-reachable

Five `SECURITY DEFINER` functions in `public` were executable by `anon`. All five are now swept to the
v3 convention. **Bodies unchanged** — this was a grant-layer change only (CS scope, LAW 12), and
fixture 64 seq 18–22 pin each body by `md5(prosrc)` to keep it that way.

| function                                     | writes?                | anon before → after | `md5(prosrc)` (pinned, unchanged) |
| -------------------------------------------- | ---------------------- | ------------------- | --------------------------------- |
| `_build_draft_core_v3(date,boolean,boolean)` | Stage 1 core           | **true** → false    | `fef941d5`                        |
| `build_draft_for_confirmed_v3(date,boolean)` | via core — **cron 13** | **true** → false    | `947a3140`                        |
| `build_confirmed_now_v3(date)`               | via core               | **true** → false    | `9c03b20e`                        |
| `pick_machines_for_refill(date,int,int)`     | ⛔ `machines_to_visit` | **true** → false    | `d9f508d1`                        |
| `confirm_machines_to_visit(date)`            | ⛔ yes                 | **true** → false    | `a3344191`                        |

**ACL for all five, after (read BACK and asserted whole, S-140):**
`{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}`

⛔ **`anon` IS A MEMBER OF `PUBLIC`, AND FOUR OF THE FIVE CARRIED A PUBLIC GRANT.** Revoking `anon`
alone leaves `has_function_privilege('anon', oid, 'EXECUTE')` **TRUE**. Any future grant sweep in this
codebase must revoke **both** `anon` and `PUBLIC` and then read `proacl` back — the two Supabase traps
compose: `anon` is granted **explicitly** (so a PUBLIC-only revoke removes nothing, S-140 leg 87) _and_
a PUBLIC grant may also be present (so an anon-only revoke removes nothing either, **found here**).

⚠️ **ARTICLE 4 REMAINS OPEN AGAINST THIS TIER.** The guard is
`IF auth.uid() IS NOT NULL AND NOT EXISTS (... operator_admin ...) THEN error` — it validates an
authenticated non-admin and **skips validation entirely for a caller with no role**. The revoke removes
reachability, not the inversion. CS assigned the hardening to v3, which already implements the correct
NULL-refusing check. **Do not read "D-41 closed" as "the guard is fixed."**

### Golden probe added

| object                           | purpose                                                                                                                                                                                                                                                                                  |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `golden._acl_canary_public_64()` | SECURITY INVOKER, returns `1`, touches no data. Deliberately holds an **explicit PUBLIC EXECUTE grant** so fixture 64 seq 24 can prove the seq-9 PUBLIC-grant detector is capable of detecting one. ⛔ Never move to `public`; never revoke its PUBLIC grant — that grant _is_ the test. |

---

## leg 100 (2026-08-03) — `commit_refill_plan_atomic` now speaks the pre-flight refusal

`public.commit_refill_plan_atomic(p_plan_date date, p_machine_names text[])` → jsonb, **SECURITY
DEFINER**. `md5(prosrc)` **`56f14180` → `4237fbcc`**. Signature unchanged, `pronargdefaults` still `0`,
single overload.

The S-172 table above recorded that this path's refusal discarded the invariant id, the `fix_path` and
the hatch instructions. It no longer does — a `preflight_failed` branch sits **before** the generic
`write_result` guard and RAISEs the payload. Updating the S-172 table's third row:

| path                        | gated?           | operator sees                                                    | escape hatch                                           |
| --------------------------- | ---------------- | ---------------------------------------------------------------- | ------------------------------------------------------ |
| `commit_refill_plan`        | yes              | full payload                                                     | `preflight_override_v3` — audited, single-use          |
| `stitch_pod_to_boonz`       | yes              | full payload                                                     | `p_force` + ≥10-char reason, inline                    |
| `commit_refill_plan_atomic` | **transitively** | ⭐ **invariant id + machine/shelf + `fix_path` + where to look** | ⛔ **still none — S-172 step 2, and D-19 waits on it** |

⛔ **Legibility is not reachability.** The message now _names_ the audited hatch and says plainly that
it is not reachable from this path. That is step 1. Step 2 adds the `p_force`/`p_force_reason`
passthrough and the FE affordance; **`preflight_enforcement` must not flip to `'block'` before it.**

### ⛔ PREMISE CORRECTION — "v3 already implements the correct NULL-refusing check" is FALSE

The D-41 section above (and the leg-99 migration note) states that the Article 4 guard inversion is
cured in v3. **Re-derived live this leg per S-158: it is not.** Every v3 function carries the _same_
inversion as the legacy tier:

```
v_user_id := auth.uid();
IF v_user_id IS NOT NULL AND NOT EXISTS (... role check ...) THEN RAISE EXCEPTION ...; END IF;
```

Verified verbatim in `stitch_v3`, `engine_add_pod_v3`, `run_pipeline_v3` and `preflight_override_v3`.

⭐ **And the bypass is DELIBERATE, not an oversight.** `run_pipeline_v3` carries the comment
_"…caller (cron), matching the fleet convention"_ immediately above it. `pg_cron` runs as `postgres`
with no JWT, so `auth.uid()` is **NULL** for every scheduled call — crons **13, 14, 42, 43, 44, 45, 46**
all depend on NULL being waved through.

⛔ **THE LANDMINE THIS DEFUSES:** D-41's proposed fix **(b)** — _"invert the short-circuit so a NULL
`auth.uid()` is REFUSED"_ — would **strand every cron in the fleet**, including the nightly advisory
(LAW 12). CS scoped D-41 to the grant layer, and that was the right call for a reason the parking lot
never stated. **The grant layer is the only safe lever here.** A guard that refuses NULL requires a
separate, explicit "is this an automated caller" test first, and that is its own unit.

---

## `compute_scoreboard_day_v3(p_metric_date date)` — PRD-110 P4.5 (leg 101)

**Class:** writer, `SECURITY DEFINER`, `SET search_path = public`, single overload,
`pronargdefaults = 0`. **Target:** `public.scoreboard_daily_v3` only — a NON-protected table.
**Returns:** `jsonb` `{ok, metric_date, scope, metrics_written, metrics[]}`.
**Final ACL:** `{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}` —
no `anon`, no `PUBLIC` (D-42 shape pre-empted at birth rather than swept later).
**Callers:** cron **47** `prd110_p45_scoreboard_daily_0245_dubai` (`45 22 * * *` UTC = 02:45 Dubai,
computes the Dubai day that just CLOSED), plus manual backfill.

⛔ **ARTICLE 4, DELIBERATE PARTIAL EXEMPTION — recorded so the next leg does not read it as an
oversight and "fix" it.** The function validates its input and its caller role, but does **NOT** set
`app.via_rpc` / `app.rpc_name`. Article 4's GUC clause exists to feed the Article 8 generic audit
trigger on protected entities. `scoreboard_daily_v3` is not protected and carries no such trigger, so
setting the GUCs would buy **zero** audit and would add a ninth site to the open GUC-leak defect
(**D-36 / S-160**), where the value survives past the statement that set it. Cody reviewed and
approved the exemption explicitly. **If this table ever becomes protected, the exemption dies with
that change.**

⭐ **The NULL-`auth.uid()` bypass is present here too, and it is correct.** The role gate reads
`IF auth.uid() IS NOT NULL AND NOT EXISTS (...)`. `pg_cron` has no JWT, so refusing NULL would strand
cron 47 on its first night — the same landmine documented above for D-41/D-42. Exposure is contained
at the grant layer, which is the only safe lever.

**Read surfaces (both `anon`- and `PUBLIC`-revoked, `SELECT` to `authenticated`):**

- `v_scoreboard_daily_v3` — one wide row per date. ⛔ A NULL metric here is **always** explained by
  the companion `vacuous_reasons` jsonb. Read the two together or a refusal reads as a zero.
- `v_scoreboard_health_v3` — `days_in_latest_streak`, the P4 GATE measurement.

**Pinned by golden fixture 65 (28 assertions):** seq 20 asserts the whole `relacl` string, seq 14-19
the grant surface, seq 6-10 the two CHECK constraints in both directions, seq 8 and seq 12 are the
**positive controls** (S-173), seq 23 is the reachability tripwire, seq 4 idempotency.

## `public.receive_dispatch_line_sourced_v3` (PRD-110 P4.4b, leg 103, `20260803213141`)

```
receive_dispatch_line_sourced_v3(p_dispatch_id uuid, p_qty_from_wh numeric, p_qty_spot numeric,
                                 p_spot_supplier_id uuid DEFAULT NULL, p_spot_breakdown jsonb DEFAULT NULL,
                                 p_unit_price_aed numeric DEFAULT NULL, p_receipt_photo text DEFAULT NULL,
                                 p_note text DEFAULT NULL, p_received_by uuid DEFAULT NULL,
                                 p_dry_run boolean DEFAULT false) RETURNS jsonb
```

SECURITY DEFINER · `search_path=public, pg_temp` · ACL `{postgres=X,service_role=X,authenticated=X}`,
no `anon` · one overload. Gate is **`field_staff` and up** — this is the driver-facing path
`create_spot_purchase_v3`'s own refusal message points at.

Phase 1 of the post-facto fill. The driver reports the split he actually made: **n from the
warehouse + m bought at a counter.** The split is **explicit and required, never inferred** — a
single `filled_quantity` that exceeds plan is exactly the ambiguity that stranded the 07-30 driver.

⭐ **THE FIX IN ONE SENTENCE: the incumbent `receive_dispatch_line` is called with n ONLY.** Its
`v_overfill := GREATEST(n - planned, 0)` therefore never covers the spot units and the line-112
guard is never asked. ⛔ **That guard was RIGHT and is byte-for-byte untouched** (md5 `28195f57`,
re-verified after this migration). ⛔ Anyone "fixing" this path by weakening that RAISE has rebuilt
the phantom-mint this codebase spent whole PRDs removing.

⛔ **The spot leg never touches `warehouse_inventory` (design D-E).** Proven live, not asserted:
`wh_rows_created = 0` in the leg's rolled-back replay. The rejected "WH in-and-out netted" design
UPDATEs `warehouse_inventory.status` (Article 6 manager-only) and mints an auto-confirmed proposal on
**every single fill** (measured: proposals 1148→1149, status→`Inactive`).

⭐ **Composition and the event are ONE call to `record_inventory_event_v3`** — the only writer of
`inventory_events` in the database. Doing them separately is how they drift. Bucket is the **NULL**
expiry bucket until phase 2 supplies the receipt expiry. ⛔ Never default that expiry — `2099-12-31`
is the sentinel shape (P0.4) and would make spot goods immortal in FEFO.

⛔ **It re-asserts its OWN `app.rpc_name` before writing `filled_quantity`, and that is why the
allowlist entry exists.** `receive_dispatch_line` leaks `app.rpc_name='receive_dispatch_line'` and
never restores it (S-160), so this write would otherwise have passed
`enforce_canonical_dispatch_write` **for free, under another writer's identity** — a guard satisfied
for the wrong reason. GUC restore on every exit path is verified live (`guc_after_call` returned the
sentinel set before the call).

Refusals, each fired live: negative qty · `n + m = 0` · dispatch not found · already received ·
`m > 0` on a non-fill or m2m leg · `m > 0` with a NULL `shelf_id` (the units would have nowhere to
land — LAW 5) · `m > 0` with no supplier · breakdown that does not sum to m.

## `public._resolve_open_walkin_po_v3` (PRD-110 P4.4b, leg 103, `20260803213141`)

```
_resolve_open_walkin_po_v3(p_supplier_id uuid, p_lines jsonb, p_po_id text DEFAULT NULL) RETURNS jsonb
```

SECURITY DEFINER · `search_path=public, pg_temp` · ACL `{postgres=X,service_role=X}` — **no `anon`,
no `authenticated`**: internal helper, reached only as definer. Returns
`{po_id, po_number, po_path, caller_role, warnings}`.

⛔ **Design §3 declared this `(p_supplier_id, p_po_id) RETURNS text`. Corrected on live evidence:**
`purchase_orders` is LINE-grained (PK `po_line_id`, no header table) and `create_purchase_order`
takes `p_lines` NOT NULL, so a `po_id` for a minted PO **cannot exist without its lines**. Returns
jsonb because the path and its warnings are load-bearing (below), and dropping them is the
silent-information failure LAW 5 exists to prevent.

⛔ **S-145 BITES HARDEST HERE, AND THE RULE'S NAME LIES ABOUT IT.** `add_purchase_order_lines` is
`operator_admin`/`superadmin` only. P4.4b's PRIMARY caller is a **driver**. So for the driver path
the rule "attach to today's open walk-in PO, else mint" is **ALWAYS "mint", never "attach"** —
confirmed live, `po_path = 'minted'` under `field_staff`. That is correct (`create_purchase_order`
does admit `field_staff`) and the caller is TOLD via `warnings`, but a reader of the rule's name
would expect otherwise.

⚠️ **`create_spot_purchase_v3` was deliberately NOT refactored onto this helper** (md5 `79305485`
unchanged). It is fixture-18-green at 80/80 and it is a protected-entity writer; rewriting it to
delegate is not a versioned addition. The helper is byte-faithful to the incumbent's rule **today** —
see S-181 for the drift risk and the cheap check that closes it.

---

## leg 104 (2026-08-04) — D-42: the commit/stitch tier is no longer anon-reachable

D-41 swept the tier that **builds** a draft and never looked at the tier that **commits** one. Leg 100
found it; CS closed D-42 on 2026-08-04 with the same call and the same scope. Five more
`SECURITY DEFINER` functions in `public` were executable by `anon`. **Bodies unchanged** — grant-layer
only (CS scope, LAW 12), and fixture 66 seq 18–22 pin each body by `md5(prosrc)` to keep it that way.

| function                                   | writes?                                 | anon before → after | `md5(prosrc)` (pinned, unchanged) |
| ------------------------------------------ | --------------------------------------- | ------------------- | --------------------------------- |
| `commit_refill_plan_atomic(date,text[])`   | ⛔ commits the plan                     | **true** → false    | `4237fbcc` (GATE)                 |
| `commit_refill_plan(date,text,uuid[])`     | ⛔ commits the plan                     | **true** → false    | `ed4a3df6` (GATE)                 |
| `stitch_pod_to_boonz(date,bool,bool,text)` | ⛔ stitches; `p_force` override-capable | **true** → false    | `806340b2` (GATE)                 |
| `approve_pod_refill_plan(date,text[])`     | ⛔ approves                             | **true** → false    | `76c5342b`                        |
| `approve_refill_plan(date,text[])`         | ⛔ approves                             | **true** → false    | `029f0ef6`                        |

**ACL for all five, after (read BACK and asserted whole, S-140):**
`{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}`

⭐ **THREE OF THE FIVE PINS ARE THE GATE md5s** the RESUME POINTER already carries leg to leg. Fixture
66 and the relay pointer now agree **by construction** — a leg that moves a gate md5 breaks a standing
fixture, not just a pointer line an operator has to remember to compare.

⛔ **THE PUBLIC TRAP RECURRED EXACTLY AS D-41 PREDICTED IT WOULD.** Four of the five
(`approve_pod_refill_plan`, `commit_refill_plan`, `commit_refill_plan_atomic`, `stitch_pod_to_boonz`)
carried an explicit PUBLIC grant `=X/postgres`; `approve_refill_plan` carried `anon` but no PUBLIC.
Revoking `anon` alone would have left `has_function_privilege('anon', …)` **TRUE** on four of five and
CS's own acceptance test would have failed. The pre-sweep fixture run measured it: seq 9 read **4**.

⭐ **AND THE EXPOSURE WAS REACHABLE, NOT THEORETICAL:** `anon` holds `USAGE` on schema `public`
(`has_schema_privilege('anon','public','USAGE')` = true), so `anon=X` on a plan-committing DEFINER was
a live unauthenticated write path, not a dormant grant.

⚠️ **S-158 CORRECTED THE RULING'S OWN PREMISE.** D-42 stated "RefillPlanningTab.tsx calls two of
these." It calls **three** — `commit_refill_plan_atomic` (:960), `stitch_pod_to_boonz` (:680),
`approve_refill_plan` (:1099) — and a **fourth** call site lives in
`src/components/RefillPlanReview.tsx` (:222). `approve_pod_refill_plan` has **no** FE call site.
All those files build their client with the **anon key**, but `src/middleware.ts` calls
`supabase.auth.getUser()` and redirects any session-less request to `/login`, so the JWT **role** at
every live call site is `authenticated`. ⛔ **The anon KEY is not the anon ROLE** — that distinction is
the whole reason this revoke is safe, and it is worth stating because reading the call site alone
suggests the opposite.

⚠️ **ARTICLE 4 REMAINS OPEN AGAINST THIS TIER TOO**, on the same terms as D-41: the revoke removes
reachability, not any guard defect. CS scoped D-42 to the grant layer. **Do not read "D-42 closed" as
"the guards are fixed."**

## `receive_spot_fill_po_v3` — PRD-110 P4.4b phase 2 (leg 105, 2026-08-04)

```
public.receive_spot_fill_po_v3(
  p_po_id       text,
  p_lines       jsonb,     -- [{spot_fill_id, expiry_date, price_per_unit_aed}]
  p_received_by uuid    DEFAULT NULL,
  p_dry_run     boolean DEFAULT false
) RETURNS jsonb
```

SECURITY DEFINER · `search_path=public, pg_temp` · one overload · md5(prosrc) **dd7f63ea** ·
ACL exactly `{postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}` ·
role gate **warehouse / operator_admin / superadmin / manager** (deliberately **not** `field_staff`,
unlike phase 1 — this is a receipt, not a machine action). Migration `20260803221105`.

**Closes the financial chain** opened by `receive_dispatch_line_sourced_v3` (phase 1, `20260803213141`,
md5 **91902266**). Phase 1 puts the units on the shelf and leaves them financially unreceived; that gap
is a real business state (goods on hand, invoice pending) and it closes here.

⛔ **D-E: no `warehouse_inventory` write, ever.** Complete DML inventory is three statements —
`UPDATE purchase_orders`, `UPDATE spot_fill_v3`, `INSERT procurement_events`. The incumbent
`receive_purchase_order` inserts a WH batch at the equivalent point; this function deliberately does
not, because the goods went counter → driver → shelf. ⛔ Do **not** "repair" the missing batch: doing so
resurrects the netting design, which drives `tg_propose_inactivate_on_zero_stock` into an
**Article 6 manager-only** `warehouse_inventory.status` UPDATE on every fill.

⭐ **Composition is MOVED, never increased.** Two `record_inventory_event_v3` `'correction'` events,
−qty out of the NULL expiry bucket and +qty into the receipt bucket, netting to zero. `'correction'` is
the only `inventory_events` kind whose sign CHECK admits both directions.

⭐ **Idempotent by design.** A `spot_fill_v3` row already at `status='received'` is **skipped, not
raised** (retry after partial failure is ordinary operator behaviour) and reported in `skipped[]`; the
PO-line lookup additionally requires `received_date IS NULL`, so a re-run stamps nothing and writes no
second `procurement_events` row.

⛔ **The `not_purchased` clause in the PO-line lookup is load-bearing.** `cancel_po_line` sets
`purchase_outcome='not_purchased'` without stamping `received_date` — **13 live rows** are in that
state. Without `AND COALESCE(purchase_outcome,'') <> 'not_purchased'` a receipt could flip a cancelled
line back to `'received'`.

⚠️ **Article 8:** `purchase_orders` has no `audit_log_write` trigger, so this writer (the **8th**
DEFINER on that table) is not covered by the universal audit. Pre-existing across all 8; the domain
audit is `procurement_events`, event type **`post_facto_fill_received`** (added by this migration,
kept distinct from `goods_received` precisely because D-E creates no warehouse batch).

⏸️ **Still owed:** golden **fixture 26** (Migration D) is the proof harness for this chain and is
**not yet built**. Until it is green, phase 2 has guard-level and shape-level evidence only — the
end-to-end conservation claim (WH debited exactly n, composition n+m, phase-2 idempotency) is
**unproven**.

---

## 2026-08-06 — PRD-110 leg 134: `push_plan_to_dispatch` v11, `repack_machine` pre-flight, and a new role-set object

### NEW read-only helper — `public.push_dispatch_authorized_roles() RETURNS text[]`

`LANGUAGE sql IMMUTABLE`, `SET search_path TO ''`, **SECURITY INVOKER** (not DEFINER — it reads
nothing). Body is a constant: `ARRAY['operator_admin','superadmin','manager','warehouse']`.
Grants: `REVOKE ALL FROM PUBLIC, anon` · `GRANT EXECUTE TO service_role` **only** (Cody revision,
Article 3 — both callers are DEFINER owned by `postgres`, so the EXECUTE check resolves as the
definer and an `authenticated` grant would publish the privileged-role list for no caller that needs
it). ⛔ **This is the ONLY place the push-authorisation role set is written down.** Both
`push_plan_to_dispatch` (gate) and `repack_machine` (pre-flight) read it, so the two can never
silently diverge again — which is the defect class that produced the 2026-07-20 NOOK incident.

### `push_plan_to_dispatch(p_plan_date date, p_machine_name text)` → **v11_rc01_single_writer_d43_s193**

Was `v10_rc01_single_writer`, md5 **21371529 → 6372fe60**. Single overload; signature unchanged.
Four named substitutions on `pg_get_functiondef` output, diff-verified to 4 hunks / 6 changed lines:

1. **D-43 half 1** — the role gate now reads `role = ANY (public.push_dispatch_authorized_roles())`
   instead of the literal `ARRAY['operator_admin','superadmin','manager']`. `warehouse` is admitted.
   ⚠️ The `v_user_id IS NOT NULL` guard is UNCHANGED: a **NULL caller (service role) still bypasses
   the gate entirely**. Any claim about "who may push" must say so.
2. **S-193**, preserve-block RC-01 §5(5a) — `AND COALESCE(rd.returned,false) = false`.
3. **S-193**, preserve-block RC-01 §5(5b) (the multi-wave idempotency probe — the actual freeze
   path) — `AND COALESCE(rd.returned,false) = false`.
4. version tell.

⭐ **Effect:** a dispatch row that has been RETURNED no longer counts as already serving its plan
line, so a re-push after a repack creates the replacement row instead of "preserving" the plan
against a corpse. The partial unique index and `prevent_duplicate_unstarted_dispatch` already
excluded `returned=true`; this predicate was the last place that did not.

⚠️ **Blast radius, measured:** only `push_plan_to_dispatch`, `repack_machine` and
`reset_approved_undispatched` ever set `refill_plan_output.dispatched=false`, and the third also
moves `operator_status` to `pending` (which push does not select). The change reaches the repack
path and nothing else.

### `repack_machine(p_machine_name text, p_dispatch_date date, p_reason text)` — **D-43 half 2**

md5 **d719d3c1 → 2e8330fe**. Single overload; signature unchanged. One inserted block, placed after
the machine lookup and the `cannot_repack_after_dispatch` check and **immediately above the
`return_dispatch_line` loop** — that loop is the function's first destructive act and there is no
savepoint. Returns `{"status":"error","error":"push_not_authorized", …, "returned_count":0,
"plan_rows_reset":0, "fresh_dispatch_rows_created":0}`.

⛔ **The pre-flight mirrors push's NULL-caller bypass exactly** (`IF auth.uid() IS NOT NULL AND …`).
An asymmetric pre-flight would refuse the unattended path push itself permits.

⛔ **UNCHANGED ON PURPOSE:** repack's own gate literal
`('warehouse','operator_admin','superadmin','manager')` (fixture 9 seq 1 pins it; CS chose option
(a), so only push widened) and its `search_path` — still `'public'` **alone, no `pg_temp`**, the
unhardened shape fixture 9 seq 4 records as fleet-scale item **S-198**.

⚠️ **S-192 IS NOT FIXED.** A repack's own returns stamp `dispatched=true`, so the second repack on a
(machine, date) is still refused permanently. Fixture 9 seq 31-34 continue to pin it, and it is now
the only one of the three original defects still open.

⭐ **S-248 note for whoever reads this next:** once `warehouse` joined push's set, repack's gate and
push's set became **identical**, so the pre-flight is a branch **no role can reach**. It is not
pointless — it is the guard that fires the day the two diverge — but it **cannot be proven by a role
replay**. Fixture 9 seq 78 asserts `repack_roles ⊆ push_roles` as data; seq 79 asserts the
pre-flight precedes the first destructive act.

---

## `approve_facing_proposal_v3(p_proposal_id uuid, p_decision text, p_review_note text)` — **DR-8** (leg 148)

`SECURITY DEFINER`, owner `postgres`, `search_path = public, pg_temp`, migration `20260807180500`,
`prosrc` md5 **`9435ab69`**. ACL `{postgres=X, authenticated=X, service_role=X}` — **no `anon`**.
**The only writer of `facing_proposals_v3.status`** (`authenticated` holds neither INSERT nor UPDATE,
measured `false`/`false`). Proven by **golden fixture 69: RED 16/42 before, 42/42 after**, every
baseline failure a bare `42883` — an honest LAW-1 red, not a `scenario_error`.

⛔ **IT IS NOT A COPY OF `approve_feedback_proposal_v3`, AND THE DIFFERENCE IS THE WHOLE UNIT.**
`facing_proposals_v3` carries `CHECK fp_v3_review_named` — `status NOT IN ('approved','rejected',
'applied') OR reviewed_by IS NOT NULL`. Its sibling tolerates `auth.uid() IS NULL` because
`feedback_proposals_v3` has no such CHECK, so a transliteration would reach that CHECK and surface to
CS as a **bare 23514 naming a constraint** instead of the missing identity. The `v_uid IS NULL`
refusal is therefore the **FIRST** statement after the GUCs — ahead of the role check and every
argument guard. ⛔ **Order is load-bearing; fixture 69 seq 20 asserts `P0001` and NOT `23514`, and
seq 22 asserts the message names `fp_v3_review_named` so the next engineer cannot delete the guard as
redundant.**

⭐ **S-128 APPLIED AS DISCLOSURE, NOT REFUSAL — the opposite call to its sibling, on purpose.**
`approve_feedback_proposal_v3` REFUSES `never_stock` because approving it would MINT a pin the engine
ignores (a live rule that lies). Approving a facing proposal **mints nothing**; it records a decision.
Refusing would leave CS unable to clear the queue at all. So the return payload carries
`plan_effect: 'none_yet'` plus a `plan_effect_detail` naming the gap in words. Measured from the
SOURCE side (S-267): **zero** functions consume the approved status; the one reader is
`v_proposal_acceptance_v3`, the **G12 acceptance scoreboard — a scoreboard, not a planner**.

⛔ **`'applied'` IS DELIBERATELY NOT AN ACCEPTED DECISION AND `applied_to_plan_date` IS NEVER
WRITTEN.** Both are real (`facing_proposals_v3_status_check` admits `applied`; `fp_v3_applied_dated`
ties the date to it) and both belong to a **future applier**. Writing either here would claim a facing
change had reached a machine when nothing did. Fixture 69 seq 33/34.

⛔ **THE OVERLOAD GUARD RUNS BEFORE THE `CREATE`.** `CREATE OR REPLACE` does not replace across a
differing signature — it silently overloads, which is the `repurpose_machine` foot-gun (CLAUDE.md)
pointed at CS review. A `DO $guard$` block raises if any other signature of the name exists. Fixture
69 seq 1 catches it after the fact; the guard refuses it before the fact.

⛔⛔ **THE HONEST HEADLINE, AND IT MUST NOT BE SOFTENED (S-276): THE QUEUE THIS RPC SERVES IS EMPTY.**
All 20 pending rows are fixture-48 residue at `plan_date = 2030-02-18`; under S-244 a CS-facing read
filters `plan_date < '2027-01-01'`, so the **reviewable** queue is **0**, and **no cron mints facings**
(`propose_facing_changes_v3` is unwired). Contrast DR-7, which shipped a real weekly Sunday cron at
leg 141. Fixture 69 seq 44/45 measure both halves and will go red the day a filler legitimately ships
— re-baseline them THEN, naming the filler, and restate seq 31/32/42 in the same unit.

⚠️ **ARTICLE 8 GAP, FAMILY-WIDE, PARKED NOT PATCHED:** `facing_proposals_v3` carries **zero** user
triggers, so no `write_audit_log` row is minted. Measured across all four `*_proposals_v3` tables
(`facing`, `feedback`, `rotation`, `picker_weight`): **all zero**, including `feedback_proposals_v3`
whose approve-RPC shipped at P4.1 and set the precedent. Fixing it here alone would diverge DR-8 from
its three siblings — it is a family unit. Parked as **DR-10**.

---

## PRD-110 D-31 (2026-08-08, leg 152) - new read-only helper: `pod_unit_value_v3`

- `pod_unit_value_v3(p_lookback_days integer)` → **read-only helper (sql STABLE, SECURITY INVOKER, `ROWS 20000`, `SET search_path = public, pg_catalog`; EXECUTE to `authenticated` + `service_role` ONLY).** ✅ 2026-08-08 (`prd110_d31_converge_pod_unit_value`, `20260808150500`, PRD-110 D-31, CS ruling 2026-08-01). **The canonical unit-value object (Article 16, registered in `METRICS_REGISTRY.md`).** Returns `(machine_id, pod_product_id, unit_price, price_basis)` over a grid of `machines × pods-known-to-either-source` UNION the realized `(machine, pod)` pairs - 16.7k rows live. `price_basis` ∈ `realized_machine_pod` | `realized_fleet_pod` | `recommended_price` | `none`, and it names which of the three rungs the cascade landed on. **Replaces two inline copies**, both wired on the same migration: `rank_machines_by_value_at_risk_v3` (`prosrc` md5 `754532ac` → `df7831e3`) and `v_facing_performance_v3`.
  - ⛔ **The lookback is an ARGUMENT, not a dial read inside the object.** The two consumers own DIFFERENT dials - `var_price_lookback_days` and `fac_price_lookback_days` - which read 90 today by coincidence, **not** by construction, contrary to what the parking lot and `METRICS_REGISTRY.md` recorded ("copied verbatim so the two cannot disagree", S-94 - measured false at leg 152). Reading one dial here would have retired a policy dial CS owns under cover of a refactor. Fixture 72 seqs 13/14 pin which consumer passes which and go red if anyone collapses them.
  - ⭐ Scans the sales window **once**, not twice: the fleet tier is a rollup of the machine-pod sums (`SUM(sum_paid)/SUM(sum_qty)`), exact by associativity, with the `HAVING` applied independently at each grain so a non-positive machine-pod group still counts toward the fleet total.
  - ⛔ Excludes `pod_product_id IS NULL` - 15 unattributed sales groups (110 units, AED 1,904/90d) that the inline copies carried and **no consumer could ever join to**. Equivalence-preserving; the resolver gap itself is NAMED, NOT FIXED (LAW 10).
  - **No writes.** `proacl` read back whole after apply (S-140): `{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}` - **no `anon`, no `PUBLIC`**, with `anon` revoked by name because a bare `REVOKE … FROM PUBLIC` does not remove Supabase's schema defaults (S-268, the D-30 exposure).
  - Proof: golden fixture **72, 11/16 → 27/0**, `scenario_error` null; plus 522/522 consumer rows compared in-snapshot against the pre-image cascade - **0 price mismatches, 0 basis mismatches**.
  - Cody ⚠️→ approved with revisions (Articles 1, 2, 3, 4, 6, 7, 12, 14, 16); the revisions were the registry rows in this file and in `METRICS_REGISTRY.md`, both landed on this unit.
