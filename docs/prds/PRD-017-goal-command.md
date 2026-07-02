# /goal command — PRD-017 (paste into Claude Code, repo root)

Character count of the block below: ~3,500 (under 4000).

---

```
/goal Execute docs/prds/PRD-017-refill-availability-bugs.md on Supabase eizcexopcuoycuosittm. Fix two refill availability bugs + small deterministic cleanups. Cody review BEFORE every canonical-writer/view/trigger change; reproduce full bodies verbatim and change only target lines. Do NOT redo Section 0 (already applied).

SHARED: "Available WH stock" for (machine,boonz_product) = SUM(warehouse_stock) over warehouse_inventory where status='Active' AND quarantined=false AND (expiration_date>=CURRENT_DATE OR NULL) AND warehouse_id IN (machine.primary_warehouse_id, secondary_warehouse_id) AND (reserved_for_machine_id IS NULL OR =machine). Never count consumer_stock.

BUG-A (packing rows at 0 WH): make WH-sourced rows non-packable/suppressed when Available=0, in engine_add_pod sizing + get_pod_refill_draft.wh_avail + v_dispatch_availability. EDGE CASES (all): (1) use the Available def exactly; (2) multi-variant pod — suppress only the 0 variants, never the whole pod if any variant has stock; (3) source_origin IN ('vox_at_venue','internal_transfer')/office are NOT subject to suppression — only 'warehouse'; (4) quarantined-only stock = Available 0 → suppress BUT emit procurement_gaps/needs-review (never silent-drop); (5) exclude expired/near-expiry (FEFO); (6) never touch packed/dispatched/picked_up rows.

BUG-B (pickup 0 despite physical stock): per (product,machine) classify then fix — Case1 NO-DATA (warehouse_stock=0 everywhere): adjust_warehouse_stock to physical count, provenance manual_adjust. Case2 WRONG-WH (stock only in non-serving WH): include secondary WH if valid for venue_group else transfer_warehouse_stock to serving WH. Case3 QUARANTINED (Active but quarantined=true): WH-manager propose-then-confirm un-quarantine via adjust_warehouse_stock w/ explicit provenance — NEVER auto-unquarantine. Case4 INACTIVE (stock>0,status=Inactive): reactivate_warehouse_row. Pre-classified instances: YoPRO Chocolate@OMDCW serving-WH = Case1 set 3 (Simran-confirmed); VW Upgrade@MINDSHARE = resolve serving WH then Case2/Case3 (19 in WH_MCC +5 quarantined +1 WH_CENTRAL); Hunter Ridge Sour Cream@HUAWEI = Case2 (1 in WH_CENTRAL).

CLEANUPS: (a) GH Popped Chips add @MINDSHARE 01/06 — log_retroactive_refill_visit Add New for the GH variant mapped+present on Mindshare; if both Sweet BBQ & Sweet&Salty qualify pick the one with WH stock, tie→Sweet BBQ; date 2026-06-01. (b) YoPRO WH count = Case1 above.

CONSTRAINTS: service-role bypass pattern (IF auth.uid() IS NOT NULL AND NOT role-ok); pod_inventory_audit_log operation∈(insert,update,delete) lowercase + source∈(seed,sale,refill,manual_edit,weimi_sync,correction,cleanup); pod_inventory.status∈(Active,Inactive,Expired,Removed,Removed/Expired); warehouse_inventory.status manager-only; no raw writes to refill_dispatching/pod_refill_plan/refill_plan_output (RPC only) and add any new dispatch writer to enforce_canonical_dispatch_write allow-list; respect block_orphan_internal_transfer + tg_audit_refill_dispatching. VERIFY each change in a rolled-back transaction; smoke field/packing + field/pickup; update RPC_REGISTRY.md + CHANGELOG.md + PRD-017 status. DONE = BUG-A 6 edge cases verified, BUG-B all 3 instances resolved to a Case with Available>0, GH chips + YoPRO done, registries updated.
```
