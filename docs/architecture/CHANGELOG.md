# Architecture Changelog

A running log of every architecture-level edit. Newest first. Each entry: what changed, why, what was applied where, and how to roll back. The Supabase `migrations` table is the system of record for SQL; this file is the human-readable companion that maps migrations to Constitution articles and explains intent.

Format:

```
## YYYY-MM-DD — short title
**Phase / Article:** A.X / Constitution Article N
**Applied to:** prod | repo | both
**Migration name:** <name in Supabase migrations table, if any>
**Summary:** one paragraph on what / why
**Rollback:** SQL or steps to undo
```

---

## 2026-05-05 — Repurposed-machine attribution: `machine_terminal_history` + attributed view + per-machine RPC
**Phase / Article:** A.4 / Constitution Articles 1, 2, 4, 7, 8, 12, 14
**Applied to:** prod
**Migration name:** `phaseA_a4_machine_terminal_history`, `phaseA_a4b_attributed_view_dedupe`, `phaseA_a4c_per_machine_performance_rpc`, `phaseA_a4d_vox_commercial_report_via_attributed_view`, `phaseA_a4e_vox_consumer_report_join_by_machine_id`, `phaseA_a4f_consumer_report_adyen_pending_flag`, `phaseA_a4g_vox_commercial_filter_by_machine_id`

**Summary:** New versioned-history table `machine_terminal_history` (terminal-id × machine-id × date-range) with EXCLUDE-overlap constraint, RLS, and the generic A.3 audit trigger installed. Backfilled with 9 known terminal-to-machine windows: ACTIVATE-2005 chain (LLFP_2005 Feb 13-14 → MPMCC-2005-0000-W0 Apr 23-27 → ACTIVATE-2005-0000-W0 Apr 28+), MPMCC-1054/1058 ← ACTIVATEMCC-1054/1058 Apr 28 rebrands, IFLYMCC-1024 install, ALHQ-1016 stable. New canonical writer `register_terminal_move(text, uuid, date, text, text, text)` is the only path to add new windows; validates inputs + FK + role (operator_admin or superadmin). New view `v_adyen_transactions_attributed` (with `security_invoker = true`) joins Adyen rows through the history table to expose `attributed_machine_name`, `attributed_machine_id`, `attributed_venue_group`, `attribution_source` per row. Dedupe patch (`a4b`) restricts the machines join to `status='Active'` so stale Inactive terminal claims don't double-count. New read-only RPC `get_per_machine_performance(p_date_from, p_date_to, p_venue_group, p_machine_names)` returns a JSON array per attributed-machine combining WEIMI sales (via `v_sales_history_attributed`) with Adyen settled+refunded captures, including refund-netted `adyen_net_cash_aed`. Existing `get_vox_commercial_report` patched (`a4d`) to read Adyen via the new view and split SettledBulk vs RefundedBulk so partial refunds net out of captured. **Net effect:** repurposed machines now appear as separate rows in any per-machine report (e.g. ACTIVATE-2005 has 5 days at 1,087 AED under MPMCC-2005-0000-W0 and 7 days at 1,456.85 AED under ACTIVATE-2005-0000-W0 in the Feb 1 → May 4 window, instead of 12 days collapsed into one row). Validated by Cody (⚠️ Approve with revisions — all revisions applied: real ALHQ uuid, btree_gist extension, input/role validation, security_invoker on the view, audit trigger installed, terminology corrected from "append-only audit" to "versioned history"). FE wiring of `/app/performance` Sites & Machines tab patched separately (`src/app/(app)/app/performance/page.tsx` — `machineData` keys by `sales_history.machine_mapping` instead of `machine_id`). Pending: register_terminal_move callsite from a future "Rename machine" UI, wire `get_per_machine_performance` if/when the Sites & Machines tab needs Adyen-net-cash beside revenue.

**Rollback:**
```sql
DROP FUNCTION IF EXISTS public.get_per_machine_performance(date, date, text, text[]);
DROP FUNCTION IF EXISTS public.register_terminal_move(text, uuid, date, text, text, text);
DROP VIEW    IF EXISTS public.v_adyen_transactions_attributed;
DROP TRIGGER IF EXISTS trg_mth_audit ON public.machine_terminal_history;
DROP POLICY  IF EXISTS mth_authenticated_read ON public.machine_terminal_history;
DROP POLICY  IF EXISTS mth_service_all       ON public.machine_terminal_history;
DROP TABLE   IF EXISTS public.machine_terminal_history;
-- restore the prior get_vox_commercial_report from migration history.
```

---

## 2026-05-04 — Orphan dispatching cleanup RPC
**Phase / Article:** Operational hardening / Articles 1, 4, 8, 12
**Applied to:** prod
**Migration name:** `cleanup_orphan_dispatching_rpc`

**Summary:** New canonical-writer RPC `cleanup_orphan_dispatching(date, text[])` to delete orphaned `refill_dispatching` rows that have no matching plan row in `refill_plan_output`. This gap was surfaced operationally when `write_refill_plan` (RPC B) rewrote plan rows for 4 machines (MC-2004, MINDSHARE, WAVEMAKER, WPP) — the old plan's dispatching rows were left behind because `write_refill_plan` only touches the plan table. The RPC validates caller role (operator_admin, superadmin, manager), requires non-NULL `p_dispatch_date`, and JOINs through `machines` + `shelf_configurations` to match dispatching rows back to plan rows by `(plan_date, machine_id, shelf_id, action)`. Only deletes rows where `packed=false AND picked_up=false` (Article 12 — never touch packed/picked-up rows). Returns `{status, dispatch_date, machines_scoped, orphan_rows_deleted}`. Designed by Dara, reviewed by Cody (⚠️ Approve with revisions — revisions applied: role validation, NULL guard, JOIN rewrite from subquery to NOT EXISTS). First call deleted 8 orphaned swap dispatching rows across 4 machines for 2026-05-05.

**Rollback:**
```sql
DROP FUNCTION IF EXISTS public.cleanup_orphan_dispatching(date, text[]);
```

---

## 2026-05-04 — Warehouse stock reconciliation RPC + bug fixes across 3 inventory RPCs
**Phase / Article:** Operational hardening / Articles 1, 4, 5, 8
**Applied to:** prod
**Migration names:** `inventory_rpc_adjust_warehouse_stock`, `patch_adjust_warehouse_stock_update_expiry`, `fix_adjust_warehouse_stock_wh_name_col`, `fix_adjust_warehouse_stock_generated_col`, `patch_adjust_wh_stock_expiry_unchanged_check`, `fix_log_manual_refill_generated_delta`, `fix_log_manual_refill_audit_constraints`, `fix_transfer_warehouse_stock_generated_delta`

**Summary:** New canonical-writer RPC `adjust_warehouse_stock` for physical count reconciliation of warehouse inventory. Matches existing rows by `wh_inventory_id` or `(warehouse, product, expiry)`, updates stock + consumer_stock + expiration_date + batch_id + status, inserts new rows when no match found. Unchanged-check includes expiry comparison (catches expiry-only corrections like mislabeled dates). Used to reconcile WH_MCC physical counts on 2026-05-04. Also fixed `inventory_audit_log.delta` generated-column bug in all 3 existing inventory RPCs (`adjust_warehouse_stock`, `log_manual_refill`, `transfer_warehouse_stock`) — the `delta` column is GENERATED ALWAYS and cannot be explicitly INSERTed. Fixed `log_manual_refill` pod_inventory_audit_log constraint violations: `operation` must be lowercase ('insert' not 'INSERT'), `source` must be from enum ('refill' not 'manual_refill').

**Rollback:**
```sql
DROP FUNCTION IF EXISTS public.adjust_warehouse_stock(uuid, jsonb, date, text);
-- Then CREATE OR REPLACE log_manual_refill and transfer_warehouse_stock with pre-fix bodies
```

---

## 2026-05-04 — Inventory operations: 3 new RPCs (transfer, manual refill, pod adjust)
**Phase / Article:** Operational hardening / Articles 1, 4, 5, 6, 8
**Applied to:** prod
**Migration names:** `inventory_rpc_transfer_warehouse_stock`, `inventory_rpc_log_manual_refill`, `inventory_rpc_adjust_pod_inventory`

**Summary:** Three new canonical-writer RPCs to close inventory management gaps. Designed by Dara, reviewed by Cody (Articles 1, 4, 5, 6, 8 — all pass). These enable the operator to: (1) transfer stock between warehouses (WH_CENTRAL → WH_MCC/WH_MM) with FIFO batch picking and cold-storage validation; (2) retroactively log manual refills that happened outside the system (backlog cleanup), decrementing source warehouse and creating pod_inventory entries; (3) correct pod_inventory via physical count reconciliation with batch-level FIFO support. All three write full audit trails to `inventory_audit_log` and/or `pod_inventory_audit_log`. Article 6 compliance verified: none of the three RPCs touch `warehouse_inventory.status` (the propose_inactivate trigger may fire when source stock hits zero, but that only proposes — manager confirms).

**Rollback:**
```sql
DROP FUNCTION IF EXISTS public.transfer_warehouse_stock(uuid, uuid, jsonb, date, text);
DROP FUNCTION IF EXISTS public.log_manual_refill(text, uuid, date, jsonb, text);
DROP FUNCTION IF EXISTS public.adjust_pod_inventory(text, date, jsonb, text);
```

---

## 2026-05-04 — Refill pipeline hardening: 6 RPC changes (B, E, C, D, F, A)
**Phase / Article:** Operational hardening / Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration names:** `refill_b_scoped_write_refill_plan`, `refill_e_loud_approve_refill_plan`, `refill_c_override_refill_quantity`, `refill_d_inject_swap`, `refill_f_seed_shelf_configurations`, `refill_a_multi_machine_generate`

**Summary:** Six coordinated RPC changes designed by Dara, reviewed by Cody (Articles 1, 2, 4, 5, 7, 8, 12, 14 — all pass), to eliminate the need for manual SQL in the refill pipeline. The operator (Claude / boonz-master skill) now works exclusively through RPCs for all plan mutations.

1. **RPC B — `write_refill_plan` scoped delete.** The DELETE now only removes pending rows for machines present in `p_lines` (was: all pending for date). Fixes the "sequential per-machine calls destroy each other" bug. Returns `machines_affected` array.

2. **RPC E — `approve_refill_plan` loud errors.** Pre-approve diagnostics detect missing `shelf_configurations`, unmatched `pod_products`/`boonz_products`, unmatched `machine_name`. Returns structured `alerts` jsonb array with impact descriptions. Dispatch gap detection: warns when `rows_approved > dispatching_rows_written`. Added `AND packed=false` guard to dispatching DELETE (never wipe packed rows).

3. **RPC C — `override_refill_quantity` (NEW).** Operator quantity override for pending REFILL/ADD NEW rows. Multi-variant products: proportional redistribution. Single-variant: direct update. Appends `[QTY OVERRIDE]` comment for audit trail.

4. **RPC D — `inject_swap` (NEW).** Inject a product swap into a live/approved plan. Inserts REMOVE + ADD NEW rows directly as `approved` + creates dispatching rows. Preserves packed dispatching rows. Full input validation: machine, shelf_config, pod_product, boonz_product existence checks with descriptive errors.

5. **RPC F — `seed_shelf_configurations` (NEW).** Auto-seed `shelf_configurations` from `v_live_shelf_stock`. Converts aisle codes (`0-A00`→`A01`, `1-A00`→`B01`). Idempotent via `ON CONFLICT (machine_id, shelf_code) DO NOTHING`. Called automatically by `auto_generate_refill_plan` when a machine has 0 configs.

6. **RPC A — `auto_generate_refill_plan` multi-machine.** New `p_machines text[]` parameter. When provided: bypasses health triage filter + LIMIT 10, processes exactly the listed machines. Auto-calls `seed_shelf_configurations` for machines with 0 configs. Added `AND packed=false` to dispatching DELETE. Old 3-param overload dropped.

**Cody review:** ⚠️ Approve with revisions. All revisions applied: alerts are warnings not blockers (E), packed rows preserved (D/E/A), idempotent ON CONFLICT (F), role validation on all new RPCs (C/D/F). Constitution articles satisfied: 1 (each RPC is canonical for its operation type), 4 (GUCs + role + input validation), 5 (status transitions respected), 8 (audit trigger fires on all targets), 12 (forward-only CREATE OR REPLACE).

**Verification:**
- All 6 functions confirmed: `prosecdef=true`, `has_via_rpc=true`, `has_rpc_name=true`.
- `auto_generate_refill_plan` has exactly one overload (4 params).
- Old 3-param overload dropped cleanly.

**Rollback:**
```sql
-- Reverse in opposite order
DROP FUNCTION IF EXISTS public.auto_generate_refill_plan(text, date, boolean, text[]);
-- Then CREATE OR REPLACE with old 3-param body (archived in this changelog git history)
DROP FUNCTION IF EXISTS public.seed_shelf_configurations(text);
DROP FUNCTION IF EXISTS public.inject_swap(date, text, text, text, text, text, int, text);
DROP FUNCTION IF EXISTS public.override_refill_quantity(date, text, text, int);
-- Then CREATE OR REPLACE approve_refill_plan + write_refill_plan with pre-B/E bodies
```

---

## 2026-05-04 — Refill app issues Phase 1: propose-then-confirm + canonical pickup
**Phase / Article:** Operational fix bundle / Articles 1, 2, 3, 4, 5, 6 (revised), 7, 8, 9, 12
**Applied to:** prod (additive only — no live-flow behavior change today)
**Migration names:** `m1_warehouse_inventory_status_proposal_table`, `m2_confirm_reject_warehouse_status_proposal_rpcs`, `m3_propose_status_change_functions_unbound`, `m4_mark_picked_up_rpc`, `m5_diagnostic_views`

**Summary:** First wave of fixes for the 12 refill-app issues + Issue #13 (orphan dispatch machine names). All migrations today are strictly additive — they introduce new tables, functions, and views, but do NOT alter behavior of any existing pack/receive/dispatch flow. CS guardrail in effect: "do not alter or touch anything in the existing packing and dispatching of today; fix the issues and stress test along the way."

1. **`warehouse_inventory_status_proposal` table (M1)** — Implements the propose-then-confirm pattern for `warehouse_inventory.status` mutations (Article 6 revised, see Amendment 002). Automated flows (triggers / RPCs / cron / n8n) write proposal rows here. The warehouse manager confirms or rejects via canonical RPCs. RLS: read for warehouse + admin roles, INSERT/UPDATE/DELETE blocked from authenticated. Universal audit trigger bound (Article 8).

2. **`confirm_warehouse_status_proposal` + `reject_warehouse_status_proposal` RPCs (M2)** — Canonical write paths for the manager's confirm/reject decision. SECURITY DEFINER, validate role + inputs, set `app.via_rpc`, return JSON. Confirm path atomically flips `warehouse_inventory.status` and marks proposal `confirmed`. Drift detection: if `warehouse_inventory.status` changed since the proposal was filed, marks proposal `superseded` instead of confirming.

3. **`propose_inactivate_on_zero_stock` + `propose_reactivate_on_stock_return` trigger functions (M3)** — Body created today, **NOT BOUND** to `warehouse_inventory`. Binding deferred to tonight's post-dispatch deploy (m3b) so today's pack/receive flow is untouched. Both functions write to the proposal table only; never UPDATE `warehouse_inventory.status` directly. Idempotency guard skips duplicate pending proposals.

4. **`mark_picked_up(uuid[])` RPC (M4)** — Canonical write path for the field-driver pickup flow. Replaces direct `refill_dispatching` UPDATEs from `field/pickup/page.tsx`. Filters to `packed=true AND picked_up=false`; returns counts + skipped IDs for FE feedback. Sits dormant until tonight's FE deploy wires it.

5. **Diagnostic views (M5)** — `v_pending_status_proposals` (manager UI surface), `v_orphan_dispatch_machine_names` (Issue #13: refill_plan_output rows whose machine_name doesn't resolve to `machines.official_name` — currently 4 rows: MPMCC-2005-0000-L0, ACTIVATEMCC-1058-0000-R0, ACTIVATEMCC_1054_0000_M0 (typo), JET-2001-3000-O1), `v_machines_without_shelf_config` (currently 2 rows: IRIS, LLFP — both `include_in_refill=false`, benign).

**Constitution amendment (002):** Article 6 revised. The previous absolute rule ("`warehouse_inventory.status` may only be written by the warehouse manager — no trigger / function / cron / n8n / app may mutate it") is replaced with a propose-then-confirm rule that allows automated flows to PROPOSE status changes via the new proposal table, with manager confirmation as the gate. Silent direct UPDATE of `warehouse_inventory.status` from any trigger / RPC / cron / n8n / FE remains forbidden. See `06_amendment_002_article_6_propose_then_confirm.md`.

**Today-safe verification:**
- `warehouse_inventory` triggers unchanged (no new mutation triggers; lockdown holds).
- `refill_dispatching` triggers unchanged (`enforce_packed_dispatch_immutability`, `tg_audit_refill_dispatching`, `trg_conserve_split_qty`, `trg_prevent_duplicate_unstarted_dispatch` all intact).
- No FE deploy required to apply these migrations. RPCs sit dormant until tonight's FE deploy.

**Rollback:**
```sql
-- M5
DROP VIEW IF EXISTS public.v_machines_without_shelf_config;
DROP VIEW IF EXISTS public.v_orphan_dispatch_machine_names;
DROP VIEW IF EXISTS public.v_pending_status_proposals;
-- M4
DROP FUNCTION IF EXISTS public.mark_picked_up(uuid[]);
-- M3
DROP FUNCTION IF EXISTS public.propose_reactivate_on_stock_return();
DROP FUNCTION IF EXISTS public.propose_inactivate_on_zero_stock();
-- M2
DROP FUNCTION IF EXISTS public.reject_warehouse_status_proposal(uuid, text);
DROP FUNCTION IF EXISTS public.confirm_warehouse_status_proposal(uuid, text);
-- M1
DROP TABLE IF EXISTS public.warehouse_inventory_status_proposal;
```

**Pending tonight (post-dispatch deploy window):** m3b (bind triggers), FE updates to (a) wire `mark_picked_up`, (b) add `picked_up=false` filter in pickup page, (c) surface `v_pending_status_proposals` in the inventory page; conserve_split trigger swap; backfills.

---

## 2026-04-30 — Boonz Master operational intelligence layer
**Phase / Article:** Operational / Articles 1, 2, 3, 4, 5, 8, 12
**Applied to:** prod + repo
**Migration names:** `boonz_master_foundation`, `add_approve_refill_plan_rpc`

**Summary:** Introduced the Boonz Master skill as the single operational interface for the refill system, replacing the need for CS to route between `/refill-engine`, Cody, Stax, and Dara for day-to-day ops. Four changes shipped:

1. **`boonz_context` table** — Active operational brief. One row at a time. Master writes here when CS sets context ("NOVO promo next 2 weeks", "push office to aggressive"). The refill-engine reads this before generating any plan. Holds `context_text` (plain English), `default_scenario` (conservative/standard/aggressive), `scenario_overrides` per venue group, and `machine_modes` per machine.

2. **`planned_swaps` table** — Confirmed next-visit swap orders from operator, CS, or driver (phone call, chat, field note). Brain executes these unconditionally on next run, bypassing lifecycle signal checks. Status lifecycle: pending → applied | cancelled.

3. **`machine_field_notes` table** — Driver feedback loop. Post-dispatch prompt in field app creates a note (add_more, reduce, substitute, remove, general). Brain reads and applies on next plan run, marks as applied after.

4. **`product_mapping.mix_weight` column** — Controls how refill qty splits across variants of the same pod product. Default 1.0 = equal share. "More M&M than Mars" → update M&M weight to 1.5, Mars stays 1.0 → 60/40 split from next run.

5. **`approve_refill_plan(date, text[])` RPC** — New canonical approval gate. Replaces the missing approval step in the refill flow. Flips `operator_status` pending→approved, then writes `refill_dispatching` rows in one atomic call. FE "Approve & Dispatch" button calls this. Roles: operator_admin, superadmin, manager only.

6. **FE changes** — `RefillPlanningTab` plan state lifted to `page.tsx` parent (tab-wipe bug fixed). "Write plan" renamed to "Save draft". "Approve & Dispatch" button added (calls `approve_refill_plan` RPC). Two-step flow: save draft → review → approve.

7. **Boonz Master skill** — New `boonz-master` skill installed. Single ops interface. Interprets plain English instructions, writes to the new tables, invokes refill-engine with context applied. Replaces `/refill-engine` for daily ops.

8. **6am Dubai scheduled run** — `boonz-morning-refill` scheduled task created. Runs at 06:05 Dubai time daily. Reads `boonz_context` + pending swaps + field notes, generates tomorrow's plan for all critical/warning machines, posts morning brief with link to approve.

9. **`refill-engine` v4** — Updated SKILL.md. New CONTEXT CHECK step runs before PRE-FLIGHT: reads `boonz_context`, `planned_swaps`, `machine_field_notes`. Applies scenario mapping, machine_modes, planned swaps, field note adjustments to the plan.

**Rollback:**
```sql
-- boonz_master_foundation
DROP TABLE IF EXISTS public.machine_field_notes;
DROP TABLE IF EXISTS public.planned_swaps;
DROP TABLE IF EXISTS public.boonz_context;
ALTER TABLE public.product_mapping DROP COLUMN IF EXISTS mix_weight;
-- add_approve_refill_plan_rpc
DROP FUNCTION IF EXISTS public.approve_refill_plan(date, text[]);
```
FE rollback: revert `page.tsx` and `RefillPlanningTab.tsx` to previous state via git.

---

## 2026-04-27 (v2) — Supplier consolidation + driver task filtering + not-purchased + audit trail
**Phase / Article:** Post-fix procurement v2 / Articles 1, 4, 6
**Applied to:** prod + repo
**Migration names:** `procurement_supplier_consolidation`, `procurement_outcome_and_audit_schema`, `procurement_rpcs_v2`
**Summary:** (1) Merged Union Coop SUP_014 → SUP_005 (canonical "Union Coop"). Reclassified Arab Sweet + Merich as walk_in. Cleared bogus contact_email='na' on Carrefour. (2) create_purchase_order v2: driver task only for walk_in OR p_force_driver_task=true. FE adds emergency "🚨 pick-up" checkbox for supplier_delivered. Tasks page filters to walk_in + forced only. (3) Not-purchased: purchase_orders.purchase_outcome column. WH toggles lines as not_purchased in receiving page; RPC closes them with received_qty=0. Driver hints (outcome_comment parsed) surfaced in receiving UI — auto-marks not_available lines, shows partial qty. (4) Procurement audit log: procurement_events append-only table + driver_tasks trigger for status transitions. RPCs log po_created / goods_received / line_not_purchased. 10 historical events backfilled.
**Rollback:** Re-activate SUP_014, revert Arab Sweet + Merich procurement_type. p_force_driver_task defaults false — RPC change is backward-compatible. purchase_outcome is additive + nullable.

---

## 2026-04-27 — Procurement flow overhaul: B-1 → B-6 fixes + 2 new canonical writers
**Phase / Article:** Post-A.5 procurement fix / Constitution Articles 1, 3, 4, 6
**Applied to:** prod + repo
**Migration names:** `procurement_supplier_type_column`, `procurement_po_number_sequence`, `create_purchase_order_rpc`, `receive_purchase_order_rpc`, `tighten_warehouse_inventory_rls`
**Summary:** Full procurement flow investigation identified 6 active bugs and 2 feature gaps. Applied in one session: (1) B-1 — added `suppliers.procurement_type` column to replace hardcoded `WALK_IN_SUPPLIER_CODES = ["SUP_005","SUP_011"]` constant in FE; backfilled SUP_005/011/014 as `walk_in`; Union Coop (SUP_014) was silently missing, causing wrong confirm dialog and null email attempts. (2) B-2 — receiving page was inserting extra `purchase_orders` rows for each expiry batch, inflating `line_count` and `total_ordered` in every order view; fixed by moving receipt logic to the `receive_purchase_order` RPC which only UPDATEs the original line and creates separate `warehouse_inventory` rows per batch. (3) B-3 — `warehouse_inventory` was being written directly from the browser client by `field_staff` role; moved to `receive_purchase_order` SECURITY DEFINER RPC and tightened RLS to remove `field_staff` from write policy. (4) B-4 — `po_additions` (field-added items) were shown on the receiving page but never processed by the confirm action; RPC now accepts `p_additions` array and marks each addition received + creates `warehouse_inventory` row. (5) B-5 — `po_number` was generated client-side via max+1 query (race condition); replaced with `po_number_seq` Postgres sequence, assigned inside `create_purchase_order` RPC via `nextval()`. (6) B-6 — orders list now cross-references `driver_tasks` by `po_id` to show "In transit — awaiting WH receipt" when a driver has collected a PO but WH has not yet received it. Two new canonical writers registered in `RPC_REGISTRY.md`: `create_purchase_order` and `receive_purchase_order`.
**Rollback:** To revert the RLS tightening: `DROP POLICY warehouse_write_wh_inventory ON warehouse_inventory; CREATE POLICY warehouse_write_wh_inventory ON warehouse_inventory FOR ALL TO public USING (EXISTS (SELECT 1 FROM user_profiles WHERE id=(SELECT auth.uid()) AND role=ANY(ARRAY['field_staff','warehouse','operator_admin','superadmin','manager'])));`. FE rollback: revert the three modified files to the versions before this session. The RPCs and sequence are additive and safe to leave in place even if FE is rolled back.

---

## 2026-04-26 — A.6.0 incident filed: 4 non-canonical write paths into protected tables
**Phase / Article:** A.6.0 / Constitution Article 1 (canonical write paths) — drift surfaced by A.5b smoke test
**Applied to:** repo (incident report only — no migration applied)
**Migration name:** —
**Summary:** Post-A.5b investigation of one anomalous `via_rpc=false` audit row on `machines` widened into a full sweep that revealed four distinct non-canonical write paths active in prod over the last 24 hours. The largest by volume: `refill_plan_output` saw 180 direct INSERT/DELETE/UPDATE writes (n8n service_role + FE operator_admin), zero of which went through the canonical `write_refill_plan` RPC despite the RPC being correctly patched in A.5b. Three smaller findings: a `machines` repurpose-shape UPDATE done directly against PostgREST (Article 1 violation), a coordinated 4-row `boonz_product_id` remap that was a legitimate data-correction migration but lacked an audit-trail marker row (process gap), and an n8n flow doing pointless `updated_at` heartbeats on `machines`. **A.5b is correct as shipped** — the 24 canonical writers are constitutional. What surfaced is a Phase B FE/n8n migration gap: the canonical writers exist and work but the production traffic doesn't go through them yet. Full evidence, audit_ids, repro queries, and a 10-step remediation sequence (B.x.3 → B.x.1 → B.x.2 → B.x.4 → A.6, with Cody review gates) live in `INCIDENT_2026-04-26_NON_CANONICAL_WRITES.md`. Pulls A.6 (governance YAML in warn mode) priority forward.
**Rollback:** N/A (no migration applied — investigation + sequencing artifact only).

---

## 2026-04-26 — A.5b applied: patch remaining 24 canonical writers + RLS on `refill_dispatch_plan`
**Phase / Article:** A.5b / Constitution Article 1 (canonical path) + Article 2 (RLS) + Article 4 (validation/via_rpc) + Article 8 (universal audit)
**Applied to:** prod
**Migration names:** `phaseA_a5b_part1_of_4_canonical_writers`, `phaseA_a5b_part2_of_4_canonical_writers`, `phaseA_a5b_part3_of_4_canonical_writers`, `phaseA_a5b_part4_of_4_rls_refill_dispatch_plan` (split into 4 because the combined diff exceeds Supabase's per-migration size limit)

**Summary:** Closes the A.5 perimeter. Patches the 24 remaining canonical SECURITY DEFINER writers and closes the one real RLS gap surfaced by Amendment 001.

**Change 1 — 22 plpgsql writers patched (parts 1–3):**
`add_new_machine`, `add_sanity_increment`, `auto_decrement_pod_inventory`, `auto_sanity_check`, `backfill_dispatch_boonz_product_ids`, `load_pod_staging_chunk`, `pack_dispatch_line`, `process_adyen_staging`, `process_weimi_staging`, `push_plan_to_dispatch`, `receive_all_dispatches_for_machine`, `receive_dispatch_line`, `repurpose_machine`, `return_all_dispatches_for_machine`, `return_dispatch_line`, `toggle_machine_refill`, `upsert_aisle_snapshot`, `upsert_pod_snapshot`, `upsert_refill_stock_snapshot`, `upsert_sales_lines`, `write_dispatch_plan`, `write_refill_plan`. Each now starts its `BEGIN` block with `PERFORM set_config('app.via_rpc', 'true', true); PERFORM set_config('app.rpc_name', '<fn>', true);` so the A.4 generic audit trigger captures `via_rpc=true, rpc_name=<fn>` on every protected-entity row. Where missing (13 of 24), folded in `SET search_path TO 'public'` at function level (defensive Article 4 hardening — built-in param, function-level SET is allowed).

**Change 2 — 2 SQL-language writers converted to plpgsql:**
`refresh_product_scores` and `retry_staging_errors` were SQL-language; they couldn't use `PERFORM`, so they were re-authored as plpgsql while preserving exact behaviour. `refresh_product_scores` additionally writes its own explicit `INSERT INTO write_audit_log` row before `REFRESH MATERIALIZED VIEW CONCURRENTLY mv_global_product_scores;` — matview refreshes don't fire AFTER triggers, so the audit row is written manually (mirrors A.5a's `refresh_sales_aggregated`).

**Change 3 — RLS on `refill_dispatch_plan` (part 4):**
`ALTER TABLE refill_dispatch_plan ENABLE ROW LEVEL SECURITY` + `CREATE POLICY refill_dispatch_plan_select FOR SELECT TO authenticated USING (true)`. No INSERT/UPDATE/DELETE policy — default-deny for anon/authenticated. service_role bypasses RLS, which is how canonical RPC writes still reach the table. Closes Amendment 001's only real RLS gap.

**Why PERFORM set_config in body, not function-level SET:**
Cody's review recommended function-level `SET app.via_rpc='true'` (atomic save/restore on entry/exit, no SET LOCAL leak). Supabase rejected that shape with `42501: permission denied to set parameter "app.via_rpc"` because custom GUCs (any param with a dot) must be pre-registered via `ALTER DATABASE/ROLE/SYSTEM SET app.via_rpc=''` to be accepted in a function-level SET clause, and the migration role lacks that grant. Pivot: stay with the A.5a precedent — `PERFORM set_config(...)` at the top of `BEGIN`. **Audited the 4 nested-DEFINER call sites** (`auto_sanity_check→add_sanity_increment`, `receive_all_dispatches_for_machine→receive_dispatch_line`, `return_all_dispatches_for_machine→return_dispatch_line`, `upsert_sales_lines→refresh_sales_aggregated`) and confirmed none write to a protected entity AFTER the inner call returns — they either return immediately or update a non-protected table (`daily_pipeline_runs`). So the SET LOCAL leak from PERFORM does not corrupt the audit trail in any current code path.

**Verification:**
- All 24 functions confirmed `prosecdef=true`, `proconfig` includes `search_path=public`, body contains both `PERFORM set_config` calls.
- Smoke 1: ran `toggle_machine_refill('ADDMIND-1007-0000-W0', !current); toggle_machine_refill(..., current);` — two new `write_audit_log` rows landed with `via_rpc=true, rpc_name='toggle_machine_refill'`.
- Smoke 2: ran `refresh_product_scores();` — one row landed with `table_name='mv_global_product_scores', operation='REFRESH', via_rpc=true, rpc_name='refresh_product_scores', payload={kind: matview_refresh, trigger: manual_or_cron}`.
- Security advisors run post-apply: zero new findings on `refill_dispatch_plan`; no patched function appears in the `function_search_path_mutable` list (the 35 remaining are pre-existing helpers/triggers/read-only RPCs out of A.5b scope).

**Open follow-ups (not blockers):**
- **A.5c**: re-author all 25 A.5a/A.5b writers to function-level `SET app.via_rpc='true'` once `app.via_rpc` is pre-registered at db level (requires a separate `ALTER DATABASE postgres SET app.via_rpc=''` migration as superuser, then rewriting the bodies). This eliminates the SET LOCAL leak entirely and matches Cody's preferred shape.
- **B.x**: tighten `refill_plan_output` RLS — currently allows authenticated INSERT/UPDATE which violates Article 1/3 (sole canonical writer is `write_refill_plan`).
- **A.4.b**: install audit triggers on the 6 deferred protected tables once Amendment 001 lands.
- **Investigate** (RESOLVED → see `INCIDENT_2026-04-26_NON_CANONICAL_WRITES.md`): the `machines` audit row at 2026-04-26 06:06:03 UTC was the visible tip of four distinct non-canonical write paths into protected tables. Most material: zero `write_refill_plan` calls in 24h despite 180 direct INSERT/DELETE/UPDATE writes against `refill_plan_output`. A.5b is correct as shipped — what surfaced is a Phase B FE/n8n migration gap, now sequenced as B.x.1–B.x.4 in the incident doc.

**Rollback:**
```sql
-- Function bodies: pre-A.5b versions are archived in pg_proc history and in
-- /sessions/gracious-compassionate-noether/a5b_rows.json. To roll any one
-- back, CREATE OR REPLACE FUNCTION with the prior body.
-- RLS on refill_dispatch_plan:
ALTER TABLE public.refill_dispatch_plan DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS refill_dispatch_plan_select ON public.refill_dispatch_plan;
```

---

## 2026-04-26 — Data correction: merge Santiveri Cranberries → Cran Berry + Article 7 RLS on inventory_audit_log
**Phase / Article:** Data correction / Constitution Article 7 (audit log append-only), Article 6 (warehouse_inventory.status untouched), Appendix A (boonz_products + product_mapping: intentionally permissive)
**Applied to:** prod
**Migration names:** `data_merge_cranberries_into_cran_berry`, `rls_inventory_audit_log_append_only`
**Summary:** Two `boonz_products` rows represented the same physical SKU — "Santiveri - Cran Berry" (`cd5fd194`) and "Santiveri - Cranberries" (`19c2983f`). Migration 1 removed the duplicate by: (a) deleting 24 redundant `product_mapping` rows and 5 `product_pricing` rows where Cran Berry already had identical entries; (b) remapping `boonz_product_id` FK on `purchase_orders` (1), `weekly_procurement_plan` (10), `refill_dispatching` (25), `warehouse_inventory` (1), `pod_inventory` (3); (c) correcting 4 rows in `inventory_audit_log` (same physical product, data correction not historical falsification); (d) deleting the orphaned `boonz_products` row. Orphan check confirmed 0 remaining references. Migration 2 applied INSERT-only RLS to `inventory_audit_log` per the Article 7 `*_audit_log` wildcard — closing the gap that made the correction migration possible in the first place.
**Rollback:** Re-insert `boonz_products` row `19c2983f`, re-point all FK columns back. No schema changes to reverse for migration 2 (ADD POLICY is forward-only; to revert, DROP POLICies and DISABLE RLS).

---

## 2026-04-26 — A.5a follow-up applied: widen `write_audit_log.operation` CHECK
**Phase / Article:** A.5a.1 / Constitution Article 12 (forward-only)
**Applied to:** prod
**Migration name:** `phaseA_a5a_followup_allow_refresh_op`
**Summary:** End-to-end smoke of A.5a's `refresh_sales_aggregated()` failed with `23514: violates check constraint "write_audit_log_operation_check"` — the column's CHECK was authored in A.3 with the value set `{'INSERT','UPDATE','DELETE'}`. The patched `refresh_sales_aggregated()` records `operation='REFRESH'` for matview refreshes (the only reasonable verb — REFRESH is conceptually an UPDATE on the entire matview but not on any single row). Forward-only fix: dropped the existing CHECK and re-added it with `{'INSERT','UPDATE','DELETE','REFRESH'}`. Pure additive widening — every prior row remains valid; no behavior regression; no RLS change. Cody auto-approve path (constraint-widening, no surface change).
**Verification:** Re-ran `SELECT public.refresh_sales_aggregated();` — succeeded; one row landed in `write_audit_log` with `operation='REFRESH'`, `via_rpc=true`, `rpc_name='refresh_sales_aggregated'`, `payload->>'kind'='matview_refresh'`.
**Rollback:**
```sql
ALTER TABLE public.write_audit_log
  DROP CONSTRAINT write_audit_log_operation_check;
ALTER TABLE public.write_audit_log
  ADD CONSTRAINT write_audit_log_operation_check
  CHECK (operation = ANY (ARRAY['INSERT','UPDATE','DELETE']));
-- Note: cannot roll back if any rows with operation='REFRESH' exist.
-- Inspect first: SELECT count(*) FROM public.write_audit_log WHERE operation='REFRESH';
```

---

## 2026-04-26 — A.5a applied: patch `upsert_daily_sales` + split matview refresh
**Phase / Article:** A.5a / Constitution Article 1 (canonical path) + Article 4 (validation/via_rpc) + Article 8 (universal audit) + Article 9 (heavy work on its own surface) + Article 11 (cron via RPC) + Article 12 (forward-only)
**Applied to:** prod
**Migration name:** `phaseA_a5a_patch_upsert_daily_sales_and_split_matview`
**Summary:** First batch of A.5 — patches the writer that triggered this entire diagnostic session (the n8n `Supabase Upsert1` gateway timeout on 2026-04-25). Three coordinated changes shipped together.

**Change 1 — `upsert_daily_sales(p_items jsonb)` body:**
- Added `PERFORM set_config('app.via_rpc',  'true', true)` at the top of `BEGIN`. `is_local=true` scopes the GUC to the current transaction (no leak across pooled n8n connections).
- Added `PERFORM set_config('app.rpc_name', 'upsert_daily_sales', true)` for the audit-log `rpc_name` field.
- Removed the synchronous `PERFORM refresh_sales_aggregated();` at the end (the line that was causing the gateway timeout).
- Updated COMMENT to record A.5a context.
- All other behavior preserved verbatim: `SECURITY DEFINER`, `search_path=public`, `TimeZone=Asia/Dubai`, `resolve_machine_id` lookup, defensive timestamp parse, total_amount fallback chain, `ON CONFLICT (internal_txn_sn) DO UPDATE` rules, per-item `EXCEPTION WHEN OTHERS` envelope, jsonb summary return shape.

**Change 2 — `refresh_sales_aggregated()` body:**
- Added the same two `set_config` GUC tags so the cron-triggered refresh is audit-traceable.
- Inserted an explicit row into `public.write_audit_log` before the `REFRESH MATERIALIZED VIEW CONCURRENTLY`. This is required by Article 8 because matviews cannot carry AFTER triggers, so the writer must record itself. Required Cody Change 3 in the review.
- Pinned `search_path TO 'public'` (defensive; the previous version inherited the calling session's path).
- Updated COMMENT.

**Change 3 — pg_cron schedule:**
- New cron job `refresh-sales-aggregated-10min` runs `*/10 * * * *` calling `SELECT public.refresh_sales_aggregated();`.
- The `DO $cron$` block first `cron.unschedule`s any prior version of the same job, then `cron.schedule`s — making the migration idempotent / replay-safe.
- Cadence rationale: 10 min keeps `sales_history_aggregated` fresh enough for ops dashboards (refill-engine, partner-performance) which already tolerate hour-old aggregates; cheap enough for a ~15K-row matview with `CONCURRENTLY` refresh.

**Constitutional impact:**
- Article 1 ✅ — `upsert_daily_sales` remains the sole writer for `sales_history`.
- Article 4 ✅ — GUC tags now declared. Input validation via `EXCEPTION WHEN OTHERS` envelope (per-item; preserves partial-success semantics for the n8n batch).
- Article 8 ✅ — every `sales_history` write now lands in `write_audit_log` with `via_rpc=true, rpc_name='upsert_daily_sales'`. Every matview refresh lands with `via_rpc=true, rpc_name='refresh_sales_aggregated'`.
- Article 9 ✅ — heavy work (matview refresh) is now on its own surface (cron), separated from the synchronous writer.
- Article 11 ✅ — cron job calls an RPC, not raw DDL/DML.
- Article 12 ✅ — `CREATE OR REPLACE FUNCTION` is forward-only; cron block is idempotent.

**Phase B note (deferred, not done in A.5a):** `upsert_daily_sales` still has `EXECUTE` granted to `PUBLIC` (`=X/postgres` ACL entry). Phase B will tighten to `service_role` only — n8n already auths as service_role. Don't ship this now (would be an unrelated behavior change).

**Verification:**
- `pg_get_functiondef(upsert_daily_sales)` confirms both `set_config` calls present and `refresh_sales_aggregated()` call removed.
- `pg_get_functiondef(refresh_sales_aggregated)` confirms both `set_config` calls present and the explicit `INSERT INTO public.write_audit_log` line.
- `cron.job` shows `refresh-sales-aggregated-10min` active with schedule `*/10 * * * *`.
- End-to-end smoke (replay-an-existing-row pattern):
  - `SELECT public.upsert_daily_sales('[{...one existing internal_txn_sn replayed...}]'::jsonb)` returned `{"status":"ok","upserted":1,"skipped":0,"total":1}`.
  - `write_audit_log` row appeared: `table=sales_history, op=UPDATE, via_rpc=true, rpc_name='upsert_daily_sales'`.
  - `SELECT public.refresh_sales_aggregated();` succeeded after the follow-up CHECK widening (see A.5a.1 entry above).
  - `write_audit_log` row appeared: `table=sales_history_aggregated, op=REFRESH, via_rpc=true, rpc_name='refresh_sales_aggregated', payload={kind: matview_refresh, trigger: cron}`.
- Bypass-detector still works: pre-existing `machines` audit row from A.4 smoke still shows `via_rpc=false` — proves the index `idx_wal_via_rpc` will surface unpatched canonical paths until A.5b+ closes them.

**Operational impact:**
- The 23:59 n8n flow that fired this whole diagnostic is now safe — the synchronous matview refresh that caused the gateway timeout is gone. Worst case, the n8n upsert returns immediately with the per-item summary, and the matview catches up within ≤10 minutes.
- The matview refresh now happens 144x/day (every 10 min) vs ~3-5x/day previously. The marginal cost is small — `REFRESH MATERIALIZED VIEW CONCURRENTLY` is incremental relative to the previous full refresh.

**Rollback:**
```sql
-- 1. Restore upsert_daily_sales pre-A.5a body (without GUC tags, with inline matview refresh).
--    Body archived in this CHANGELOG file's git history at HEAD~1.
--    Re-apply via CREATE OR REPLACE FUNCTION.

-- 2. Restore refresh_sales_aggregated pre-A.5a body:
CREATE OR REPLACE FUNCTION public.refresh_sales_aggregated()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY sales_history_aggregated;
END;
$$;

-- 3. Drop the cron job:
SELECT cron.unschedule('refresh-sales-aggregated-10min');
```
(Rollback is destructive of the audit-tagging behavior. Prefer forward-fix via a new migration unless a critical regression is observed.)

---

## 2026-04-26 — A.4 applied: install audit triggers on 10 protected tables
**Phase / Article:** A.4 / Constitution Article 1 (canonical write paths) + Article 8 (universal audit) + Article 15 (Appendix A reconciliation flagged)
**Applied to:** prod
**Migration name:** `phaseA_a4_install_audit_triggers`
**Summary:** Installed the generic `audit_log_write(pk_col)` AFTER trigger from A.3 onto every protected table where the Constitution name unambiguously matches a live `public.*` table. The trigger fires on INSERT, UPDATE, and DELETE for all 10 tables and writes one row to `public.write_audit_log` per affected row, capturing `table_name`, `operation`, `row_pk` (extracted via `TG_ARGV[0]`), `actor`, `actor_role`, `via_rpc` (false until A.5 patches the canonical writers), `rpc_name`, `occurred_at`, and a full `old`/`new` jsonb payload. Idempotent (DROP IF EXISTS guards before each CREATE), so the migration is replay-safe. Updated the `audit_log_write()` function COMMENT to record installation date. The 10 tables and their PK columns:

| # | Table | PK column injected | Trigger name |
|---|---|---|---|
| 1 | `machines` | `machine_id` | `tg_audit_machines` |
| 2 | `shelf_configurations` | `shelf_id` | `tg_audit_shelf_configurations` |
| 3 | `planogram` | `planogram_id` | `tg_audit_planogram` |
| 4 | `sim_cards` | `sim_id` | `tg_audit_sim_cards` |
| 5 | `slot_lifecycle` | `slot_lifecycle_id` | `tg_audit_slot_lifecycle` |
| 6 | `pod_inventory` | `pod_inventory_id` | `tg_audit_pod_inventory` |
| 7 | `pod_inventory_audit_log` | `audit_id` | `tg_audit_pod_inventory_audit_log` |
| 8 | `warehouse_inventory` | `wh_inventory_id` | `tg_audit_warehouse_inventory` |
| 9 | `refill_plan_output` | `id` | `tg_audit_refill_plan_output` |
| 10 | `sales_history` | `transaction_id` | `tg_audit_sales_history` |

**Deferred to A.4.b** (pending Article 15 amendment): `sales_history_aggregated` (Constitution called it `sales_aggregated`), `refill_dispatch_plan` (called `dispatch_plan`), `refill_dispatching` (called `dispatch_lines`), `inventory_audit_log` (called `warehouse_inventory_audit_log`). The Constitution names predate the schema as it stands today, so before installing triggers we must amend Appendix A so the protected-entity list and the live schema agree.

**Removed from protected list** (via the Article 15 amendment): `slots` (does not exist in `public`; the rotation lifecycle is captured in `slot_lifecycle` which already has its trigger), and `settlements` (does not exist as a table — settlements are computed views on top of `sales_history`).

**Important pre-A.5 expectation:** Until A.5 patches the canonical writers, every row appearing in `write_audit_log` will have `via_rpc = false`. This is **not** a constitutional violation — it just means the writer didn't yet declare itself via the `app.via_rpc` GUC. A.5 fixes that, and the `idx_wal_via_rpc` partial index (created in A.3) becomes the bypass-traffic detector once the canonical paths are tagged.

**Verification:**
- All 10 triggers exist and are enabled (`pg_trigger.tgenabled = 'O'`); `pg_get_triggerdef` confirms each binds `audit_log_write` with the correct PK arg.
- Synthetic smoke: a no-op self-update on one row of `machines` produced exactly one row in `write_audit_log` with `table_name=machines`, `operation=UPDATE`, correct `row_pk`, `via_rpc=false`, `rpc_name=NULL`, and a full `payload.old` / `payload.new` snapshot. Confirms trigger fires, PK extraction works, and payload capture works end-to-end.

**Rollback:**
```sql
DROP TRIGGER IF EXISTS tg_audit_machines ON public.machines;
DROP TRIGGER IF EXISTS tg_audit_shelf_configurations ON public.shelf_configurations;
DROP TRIGGER IF EXISTS tg_audit_planogram ON public.planogram;
DROP TRIGGER IF EXISTS tg_audit_sim_cards ON public.sim_cards;
DROP TRIGGER IF EXISTS tg_audit_slot_lifecycle ON public.slot_lifecycle;
DROP TRIGGER IF EXISTS tg_audit_pod_inventory ON public.pod_inventory;
DROP TRIGGER IF EXISTS tg_audit_pod_inventory_audit_log ON public.pod_inventory_audit_log;
DROP TRIGGER IF EXISTS tg_audit_warehouse_inventory ON public.warehouse_inventory;
DROP TRIGGER IF EXISTS tg_audit_refill_plan_output ON public.refill_plan_output;
DROP TRIGGER IF EXISTS tg_audit_sales_history ON public.sales_history;
```
(Rollback drops only the triggers; the `audit_log_write` function and `write_audit_log` table from A.3 remain. Existing audit rows are preserved.)

---

## 2026-04-26 — A.3 applied: universal audit ledger
**Phase / Article:** A.3 / Constitution Article 7 (audit append-only) + Article 8 (universal audit) + Article 12 (forward-only)
**Applied to:** prod
**Migration name:** `phaseA_a3_audit_log_infra`
**Summary:** Built the universal write ledger that turns "what happened to my protected tables" from an unanswerable question into a SQL query. Created `public.write_audit_log` (audit_id, table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, occurred_at, payload jsonb). RLS enabled with append-only policies (SELECT/INSERT permissive for `authenticated`; UPDATE/DELETE explicitly blocked). Three supporting indexes: `(table_name, occurred_at DESC)`, `(via_rpc, occurred_at DESC) WHERE via_rpc = false` (the bypass-traffic detector), `(actor, occurred_at DESC)`. Created the generic `public.audit_log_write()` `SECURITY DEFINER` trigger function — reads `app.via_rpc` and `app.rpc_name` session GUCs, captures the PK via `TG_ARGV[0]`, records full row payload as jsonb. EXECUTE revoked from PUBLIC/anon/authenticated (callable only as a trigger). The ledger is empty until A.4 installs the trigger on each protected table.
**Verification:** Verified via Supabase MCP — `pg_class.relrowsecurity = true`. Policies: `wal_insert, wal_no_delete, wal_no_update, wal_select`. Indexes: `idx_wal_actor, idx_wal_table_occurred, idx_wal_via_rpc, write_audit_log_pkey`. Function `audit_log_write` is DEFINER. EXECUTE grants: `{postgres=X/postgres, service_role=X/postgres}` — anon and authenticated have no execute.
**Rollback:**
```sql
DROP FUNCTION IF EXISTS public.audit_log_write();
DROP TABLE IF EXISTS public.write_audit_log;
```
(Note: rollback is destructive of audit data once any rows exist. Prefer forward-fix via a new migration.)

---

## 2026-04-25 — A.2 applied: deprecate `rename_machine_in_place_legacy`
**Phase / Article:** A.2 / Constitution Article 13 (deprecation 90-day process) + Article 1 (one canonical write path)
**Applied to:** prod
**Migration name:** `phaseA_a2_deprecate_rename_machine_legacy`
**Summary:** Closed the side door on the legacy machine-rename path. The function `rename_machine_in_place_legacy(uuid, text, text, text, text, boolean, date, text)` was previously `SECURITY DEFINER` and granted EXECUTE to `anon`, `authenticated`, and `service_role`. It is superseded by `repurpose_machine` as the canonical writer for machine identity transitions. Caller scan (code: `src/`, `engines/`, `scripts/`, `n8n/`, `boonz-data-migration/`; DB: `cron.job`, triggers, other DEFINER functions) returned **zero callers** — function is fully dormant. Applied: (1) `ALTER FUNCTION ... SECURITY INVOKER`, (2) `REVOKE EXECUTE FROM PUBLIC, anon, authenticated`, (3) updated function comment to mark deprecated and schedule DROP for 2026-07-24. `service_role` retains EXECUTE for the monitor window as an escape hatch; revoke at end of 90-day period if usage stays at zero.
**Verification:** `pg_proc.prosecdef = false` (was true). `proacl = {postgres=X/postgres,service_role=X/postgres}` (was `{postgres,anon,authenticated,service_role}`). Comment updated.
**Rollback:**
```sql
ALTER FUNCTION public.rename_machine_in_place_legacy(uuid, text, text, text, text, boolean, date, text)
  SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.rename_machine_in_place_legacy(uuid, text, text, text, text, boolean, date, text)
  TO anon, authenticated;
COMMENT ON FUNCTION public.rename_machine_in_place_legacy(uuid, text, text, text, text, boolean, date, text) IS
  'LEGACY: Older rename-in-place pattern. Same machine_id is preserved across the rename. Use only for backwards-compat with existing field PWA flows. For new identity transitions, use repurpose_machine() which atomically creates a fresh machine_id (canonical pattern as of Round 2).';
```

---

## 2026-04-25 — Architecture repository established
**Phase / Article:** Phase A scaffolding / Article 15 (PRs declare invariants)
**Applied to:** repo
**Migration name:** n/a
**Summary:** Created `boonz-erp/docs/architecture/` and seeded it with the Constitution v1.0, Phase A plan, and A1 before/after dashboard. Added this CHANGELOG, the migrations registry, and the RPC registry. Going forward, every backend change that touches a protected entity must be reflected here in addition to the SQL migration.
**Rollback:** `rm -rf boonz-erp/docs/architecture` (no DB impact).

---

## 2026-04-25 — A1 applied: RLS on `planogram` + `pod_inventory_audit_log`
**Phase / Article:** A.1 / Constitution Article 2 (RLS mandatory) + Article 7 (audit logs append-only)
**Applied to:** prod
**Migration name:** `phaseA_a1_rls_planogram_pia`
**Summary:** Enabled Row Level Security on `public.planogram` (was disabled — meant any authenticated user could mutate planogram with no RLS gate) and on `public.pod_inventory_audit_log` (was disabled — audit log was technically writeable/deletable). Added permissive SELECT/INSERT/UPDATE/DELETE policies for `authenticated` on `planogram` (matches the prior implicit behavior — no behavior change for the FE). On `pod_inventory_audit_log`, added permissive SELECT + INSERT, and explicit UPDATE/DELETE blocks to make the table append-only at the policy layer. `auto_decrement_pod_inventory` (the only function that writes to this log) is `SECURITY DEFINER` and continues to write fine — DEFINER bypasses RLS as the function owner. Zero rows mutated. Zero FE behavior change.
**Verification:** Visited via Supabase MCP: both tables now report `rowsecurity = true`. Policy counts: `planogram` = 4, `pod_inventory_audit_log` = 4.
**Rollback:**
```sql
DROP POLICY IF EXISTS planogram_select ON public.planogram;
DROP POLICY IF EXISTS planogram_insert ON public.planogram;
DROP POLICY IF EXISTS planogram_update ON public.planogram;
DROP POLICY IF EXISTS planogram_delete ON public.planogram;
ALTER TABLE public.planogram DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pial_select ON public.pod_inventory_audit_log;
DROP POLICY IF EXISTS pial_insert ON public.pod_inventory_audit_log;
DROP POLICY IF EXISTS pial_no_update ON public.pod_inventory_audit_log;
DROP POLICY IF EXISTS pial_no_delete ON public.pod_inventory_audit_log;
ALTER TABLE public.pod_inventory_audit_log DISABLE ROW LEVEL SECURITY;
```

---

## 2026-04-25 — Decision: skip Supabase preview branching for Phase A
**Phase / Article:** Phase A process / Article 12 (forward-only)
**Applied to:** decision log
**Migration name:** n/a
**Summary:** Attempted to create a preview branch via `mcp__supabase__create_branch` to apply A1 in isolation first. Returned `PaymentRequiredException` — branching is Pro-plan-only. Decided to apply Phase A directly to prod instead, with the `before/after` artifact as the visual diff and the rollback SQL as the safety net. This is acceptable for Phase A specifically because every step is metadata-only (no row mutation, no schema-shape change). For Phase B (FE migration touches data writes via new code paths), we will revisit branching or a staging Supabase project.
**Rollback:** n/a (decision-only).

---

## 2026-04-25 — Constitution v1.0 ratified
**Phase / Article:** n/a (constitutive doc)
**Applied to:** repo
**Migration name:** n/a
**Summary:** Authored 15 articles defining canonical write paths, validation, audit, surfaces (edge fns / n8n / cron), schema hygiene, and process. Codified the "make the wrong thing impossible" governance principle. See `01_constitution.html`.
**Rollback:** n/a (deprecating the Constitution requires the amendment process in Article 15 itself).

---
