# Claude Code /goal — Refill-Day Capabilities (RD-01…06)

Copy everything inside the fences (<4000 chars).

```
/goal Build refill-day capabilities for boonz-erp (Supabase eizcexopcuoycuosittm). Read first: docs/prds/refill-pipeline/refill-day/RD-00-index.md + RD-01..RD-06. Build in the phases below.

GOVERNANCE per item: Dara designs → Cody verdict block → write migration FILE → Stax wires FE/driver-app → Cody diff. APPLY NOTHING to prod; output SQL+diff per item; STOP only at the end (run to completion, no mid-halts).

RULES
- RPC bodies live in Supabase, not repo. Fetch via pg_get_functiondef before editing; verbatim reproduction of a core writer (edit_pod_refill_row, add_pod_refill_row) is DIFF-GATED vs live (only the new param differs).
- Forward-only migrations; no _v2 tables. Every DEFINER writer: set app.via_rpc/app.rpc_name, role+input validation, service-role bypass (auth.uid() IS NULL), audit trigger.
- Protected: machines_to_visit, pod_inventory(+audit), warehouse_inventory(+audit), refill_plan_output, refill_dispatching, planogram, shelf_configurations — Cody verdict each.
- ⛔ warehouse_inventory.status manager-only (Art.6): RD-02 receive routes through warehouse_inventory_status_proposal; only role 'warehouse' applies via add_stock. Never silent-flip.
- NEVER delete pod_inventory (archive: status='Inactive'+removal_reason). No 2 Active rows/shelf.
- Roles operator_admin/superadmin/warehouse for operator actions; field_staff (driver) only RD-03, scoped to own dispatch.
- RD-06 set_refill_row_source is the ONLY source writer (retire raw-UPDATE source_origin, Hard Rule 9).

PREREQ (v2 batch): FIX-1 (v_live_shelf_stock aisle off-by-one) + FIX-7 (reset_and_restitch/restitch_after_edits) must be APPLIED. RD-02/04/06 inherit a wrong-shelf bug without FIX-1. If unapplied, build RD-01/03/05 and hold RD-02/04/06 with a note.

PHASE 1 (no FIX-1 dep)
 RD-01: machines_to_visit +status 'cs_added' +add_source; add_machine_to_plan/create_refill_plan set cs_added/operator/is_included=true/confirmed_at; NEVER run engine inside (keep confirm gate). FE "+ Add machine".
 RD-05: pod_refill_plan +preferred_wh_inventory_id; read get_shelf_fefo_options (INVOKER, warehouse_stock>0, FEFO default); extend edit_/add_pod_refill_row with p_preferred_wh_inventory_id (diff-gated). FE batch-by-expiry dropdown.
 RD-03: refill_dispatching +driver_outcome(+qty/at/by); new driver_recommendations (RLS field_staff insert own dispatch only); driver_report_dispatch_outcome (auto action_tracker on not_done), driver_propose_adjustment (writes driver_recommendations+driver_feedback+action_tracker). FE (field) Done/Partial/Couldn't + Recommend, offline-queue idempotent.

PHASE 2 (needs FIX-1)
 RD-02: purchase_orders +origin/origin_plan_date/origin_boonz_product_id; request_po_in_refill (PO + paired driver_tasks atomic, box-multiple round-up, VOX block); receive_po_in_refill (Art.6 proposal path; warehouse role via add_stock); then restitch_after_edits. FE "Procure" on blocked_no_wh; reuse /field/orders receive.
 RD-04: optional shelf_layout_changes log; move_shelf_product archive-then-seed paired move (empty-B move OR occupied-B swap), atomic, same-machine, locked-row guard, NO planogram capacity edit. FE "Move to shelf…".
 RD-06: pod_refill_plan +source_warehouse_id (FK warehouses); set_refill_row_source for warehouse(+which WH)/internal_transfer(delegates to mark_internal_transfer)/vox_at_venue; refuses approved/locked; CHECK WH-id only for warehouse source. FE per-row Source + routing label.

OUTPUT per item: Cody verdict, migration SQL+diff, FE diff, edge-case→test checklist (from the PRD), apply order. Update CHANGELOG+MIGRATIONS_REGISTRY+RPC_REGISTRY. Final summary; I review and apply.
```
