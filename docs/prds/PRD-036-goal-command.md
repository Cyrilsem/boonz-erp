# Claude Code /goal Command - PRD-036 (condensed)

Paste into Claude Code in `boonz-erp`. Supabase eizcexopcuoycuosittm. Phased; STOP per phase for CS sign-off. Forward-only. No em dashes. Apply nothing to prod. NOTE: PRD-035 WS-C handles the engine/stitch silent-0-fill; this PRD is the packing/dispatch-binding + field-capture side. Do PRD-035 WS-C first if both are in flight.

```
/goal Implement PRD-036 (docs/prds/PRD-036-pickable-stock-and-field-batch-capture.md); read it first. Two systemic fixes from the 08-18 Jun field log: (A) packing shows pickup qty 0 even when the warehouse holds the stock (a correctly-planned line whose WH batch was never bound), forcing manual packing; (B) no field-time batch+expiry capture, so every visit leaves a hand-logged "fix WH/pods" backlog. This is the dispatch/packing + field-capture side; the engine/stitch 0-fill is PRD-035 WS-C, do not duplicate it.

RULES
- Fetch live bodies via pg_get_functiondef/pg_get_viewdef before editing; base migrations on them, never guess.
- Forward-only migrations (ts prefix); no _v2/edit-in-place. DEFINER writers set app.via_rpc+app.rpc_name, validate role+inputs, keep the audit trigger.
- Protected (refill_dispatching, warehouse_inventory, pod_inventory): Cody verdict per writer. Never write warehouse_inventory.status (Article 6). Dara designs any view/column; Stax wires FE (S1: no direct table writes).
- No deletes; no qty cut without a per-row diff. Migration FILES only; apply nothing to prod. Per phase: live body + SQL + diff + Cody verdict, then STOP for CS. Log ACs in PRD-036-EXECUTION-LOG.md.

STATE (verify live, do not assume):
- pickup=0-despite-WH-stock cases: Huawei (Vitamin Well, Pepsi Black), VML5 (Coca Cola Zero, Chocolate Bar), OMDBB (VW Antioxidant).
- Suspected root: from_wh_inventory_id not bound at approve (FEFO bind is done manually by the conductor, FE skips it) so packing finds no pickable batch -> shows 0; plus stale committed/unpacked lines holding availability to 0 (release_stale_unpacked_dispatches exists - confirm coverage); v_wh_pickable may exclude Active-in-date stock.
- log_manual_refill(machine, source_warehouse_id, refill_date, lines jsonb, reason) EXISTS, wired to NO surface. receive_dispatch_line is the canonical receive writer. ManualRefillTab.tsx exists (manual-refill flow).

PHASE A (pickable-stock truth at packing):
1. Diagnose the 3 cases live: per case show the dispatch row (from_wh_inventory_id, packed/picked flags), the matching WH batch availability, and exactly why pickup shows 0.
2. Canonical FEFO bind at approve: fold from_wh_inventory_id stamping into approve_refill_plan OR add bind_dispatch_fefo(plan_date, machine_names[]) (DEFINER, operator_admin/superadmin, audited, idempotent, skip rows past pending) so every Refill/Add New row has its WH batch bound before packing.
3. Confirm release_stale_unpacked_dispatches frees availability for these; extend if not.
4. Stax FE: pickable-stock badge on the packing screen = true WH-available units per line (so a 0 is real, not a binding gap).
VERIFY (rolled back): re-create the 3 cases; after bind, packing pickup qty = real WH availability not 0; no double-commit, no duplicate dispatch lines.

PHASE B (field batch+expiry capture):
1. Wire batch+expiry + new-purchase flag capture into ManualRefillTab.tsx and/or the field flow: on add/replace/new-purchase capture qty + expiry + flag.
2. On submit write WH receipt + pod placement via the canonical path (log_manual_refill or receive_dispatch_line), never on paper, never raw table writes. Cody verdict on any writer change.
3. Surface an "unlogged field corrections" list until each is captured.
VERIFY (rolled back): a simulated new-purchase-with-expiry and a replacement flow fully in-system - WH batch created with captured expiry, pod updated, nothing left for manual logging.

CONFIRM in report, pass/fail each AC. Start with Phase A. Show the live diagnosis + migration file + Cody verdict before applying anything.
```

PRD: `boonz-erp/docs/prds/PRD-036-pickable-stock-and-field-batch-capture.md`.
