# Claude Code /goal — Refill-Day Phase 1 (RD-01 + RD-05 + RD-03)

The three refill-day capabilities with **no FIX-1 dependency**. Run AFTER PRD-UNIFY is applied
(RD-05 extends the same edit/add writers PRD-UNIFY touches, so sequence it after to avoid a
double rewrite collision). Copy everything inside the fences (<4000).

```
/goal Build Refill-Day Phase 1 for boonz-erp (Supabase eizcexopcuoycuosittm): RD-01, RD-05, RD-03. Read first: docs/prds/refill-pipeline/refill-day/RD-01-create-plan-add-machine.md, RD-05-expiry-aware-product-pick.md, RD-03-driver-self-service.md, and RD-00-index.md. Build all three; nothing applied to prod.

GOVERNANCE per item: Dara → Cody verdict → migration FILE → Stax FE → Cody diff. APPLY NOTHING to prod; per item output SQL+diff; run to completion, STOP at end. Update CHANGELOG/MIGRATIONS_REGISTRY/RPC_REGISTRY. Full specs are in the RD files — this is the spine.

RULES
- RPC bodies live in Supabase. Fetch via pg_get_functiondef before editing. Verbatim reproduction of a core writer (edit_/add_pod_refill_row, pick_machines_for_refill) is DIFF-GATED vs live — only the new bits differ.
- Forward-only; no _v2 tables. DEFINER writers set app.via_rpc/app.rpc_name + role/input validation + service-role bypass (auth.uid() IS NULL) + audit. Read fns SECURITY INVOKER.
- Protected: machines_to_visit, pod_refill_plan, refill_dispatching — Cody verdict each.
- Roles: operator_admin/superadmin/warehouse for RD-01 & RD-05; field_staff for RD-03 SCOPED to own dispatch (ownership check mandatory; no direct refill_dispatching writes from FE).
- PREREQ: PRD-UNIFY applied (RD-05 extends edit_/add_pod_refill_row which PRD-UNIFY also extended). If not applied, build RD-01 + RD-03 and HOLD RD-05's edit-writer change.

RD-01 create plan / add machine
- machines_to_visit: status CHECK +'cs_added'; +add_source text DEFAULT 'picker' CHECK(picker,operator,sibling,driver_callout). Patch pick_machines_for_refill ON CONFLICT to keep is_included=true + add_source='picker' (diff-gate).
- add_machine_to_plan(plan_date,machine_id,confirm bool DEFAULT true): insert cs_added/operator/is_included=true/confirmed_at; idempotent; pulls health snapshot; MUST NOT run the engine. create_refill_plan(plan_date,machine_ids[]): loops it, atomic.
- FE: "+ Add machine" on /refill (picker modal) → addMachineToPlan.

RD-05 expiry-aware pick
- pod_refill_plan +preferred_wh_inventory_id uuid REF warehouse_inventory ON DELETE SET NULL.
- get_shelf_fefo_options(machine_id,boonz_product_id) jsonb (INVOKER): WH batches {wh_inventory_id,expiration_date,warehouse_stock,days_to_expiry} for the machine's source WH(s), FEFO order + default flagged, warehouse_stock>0, v_effective_expiry.
- Extend edit_/add_pod_refill_row with p_preferred_wh_inventory_id DEFAULT NULL (the pin). DIFF-GATE — only the new param. Pin is a preference: FEFO fallback+deviation if depleted; refuse expired batch.
- FE: batch dropdown in the qty/product editor; empty WH → "raise PO" affordance.

RD-03 driver self-service
- refill_dispatching +driver_outcome text CHECK(done,partial,not_done,machine_offline,no_stock_on_truck) +driver_outcome_qty int +driver_outcome_at +driver_outcome_by. New driver_recommendations(rec_id pk, created_by, created_at, machine_id, shelf_id, kind CHECK(needs_product,overstocked,wrong_product,machine_issue,other), boonz_product_id, note, status DEFAULT 'open', source DEFAULT 'driver_app'); RLS field_staff INSERT/SELECT own dispatch only, operator+ SELECT all, no field_staff UPDATE/DELETE.
- driver_report_dispatch_outcome(dispatch_id,outcome,actual_qty DEFAULT NULL): ownership-scoped; not_done/no_stock → auto action_tracker punch-item; never mutates qty/action; cannot reverse finalized/picked_up. driver_propose_adjustment(machine_id,kind,note,boonz_product_id DEFAULT NULL,shelf_id DEFAULT NULL): writes driver_recommendations + driver_feedback + action_tracker (BOTH).
- FE (field PWA): per-line Done/Partial/Couldn't + Recommend sheet; optimistic + offline-queue idempotent on dispatch_id+outcome.

OUTPUT per item: Cody verdict, SQL+diff, FE diff, edge-case→test checklist (from the PRD), apply order. Final summary; I review + apply.
```
