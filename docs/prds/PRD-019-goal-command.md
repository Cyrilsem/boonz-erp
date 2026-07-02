# /goal — PRD-019 (paste into Claude Code, repo root)

```
/goal Execute docs/prds/PRD-019-jun05-06-refills.md on Supabase eizcexopcuoycuosittm. Data-logging round (05/06 + 06/06) + 2 side-notes. Cody before any canonical-writer/view/trigger change; verbatim bodies. DO NOT redo 01-04 Jun (PRD-017 §0 + PRD-018).

RECONCILIATION (critical):
- NISSAN-0804: CS confirms 04/06 (14 retro rows, 45u) and the 05/06 doc list are the SAME visit. SUPERSEDE: set_dispatch_include(dispatch_id,false) on the 14 existing 04/06 Nissan [RETRO-LOG] rows + comment '[SUPERSEDED by 05/06 full log]' (add the service-role bypass to set_dispatch_include if missing — same one-line pattern as update_dispatch_comment/adjust_pod_inventory), THEN log the FULL 05/06 Nissan list at date 2026-06-05. No double-count.
- AMZ-1038 & AMZ-1029: prior logs are other dates; the 05/06 full refills are DISTINCT → log at 2026-06-05. NOOK-1019-0200-B1 = new.

PART 1 — log every 05/06 and 06/06 placement EXACTLY as listed in PRD-019 Part 1. Rules: resolve shorthand→boonz_products.product_id + product_mapping per machine via docs/refill-aliases.md; pod is WEIMI-fed → LOG-FIRST (log_retroactive_refill_visit, Refill/Add New; WH not debited); SWAPS = Remove via insert_driver_remove_line + Add via log RPC (AMZ-1029 A1 Zigi→Sunbites; AMZ-1038 A1 Zigi(remove 3)→McVities Nibbles); combine same product+date+machine (sum qty, earliest expiry, batches in comment); mix pods keep their split. 06/06 machines (Activate 0736=ACTIVATEMCC-1037, Activate 0817=ACTIVATE-2005, IFLY=IFLYMCC-1024, Vox 0795=VOXMCC-1011, MP 0719=MPMCC-1054, Vox 0797=VOXMCC-1005) source_origin=vox_at_venue.
GAPS/DATES — do NOT guess: AMZ-1029 A6 Hummus 'Not Available' → park+procurement; any PAST or INVALID expiry (Hunter Sea Salt Vinegar 01/02/26; Dubai Popcorn Salted 17/02/26; AMZ-1029 A16 Reload '30/02/26' invalid; Vox 0795/0797 Well Care 06/06/26; KitKat '28/02/26') → confirm/skip, don't log blindly; aliases: Gatorade Cool Raspberry→Gatorade Cool - Blue Raspberry, Gatorade Zero→Gatorade Zero - Cool Blue, poppit→Popit, Evain→Evian, Environ Wellness→Eviron - Wellness Drink, Hummus→Smart Gourmet - Classic Humus, 'Al Ain Zero'→confirm Al Ain Water Zero variant else park.

PART 2 — side-notes:
- VW Zero Lemon (exists in catalog): add 5 pcs @ 2026-09-06 to warehouse via adjust_warehouse_stock as WH manager (provenance manual_adjust); confirm target WH (Mirdif/WH_MM or WH_CENTRAL) before applying.
- Mirdif Stockroom list (Gatorade/Sunblast/Evian/Leibniz/Pocari) = 'not in system, for Simran' → surface as ONE action_tracker task (type task), DO NOT log refills or WH writes.

CONSTRAINTS: service-role bypass pattern (IF auth.uid() IS NOT NULL AND NOT role-ok); pod_inventory_audit_log operation lowercase(insert/update/delete)+source∈(seed,sale,refill,manual_edit,weimi_sync,correction,cleanup); pod_inventory.status∈(Active,Inactive,Expired,Removed,Removed/Expired); warehouse_inventory.status manager-only; RPC-only writes to refill_dispatching/pod_refill_plan/refill_plan_output + new dispatch writers join enforce_canonical_dispatch_write allow-list; respect block_orphan_internal_transfer + tg_audit_refill_dispatching. Verify in rolled-back tx; update RPC_REGISTRY.md + CHANGELOG.md + PRD-019 status. NOTE: BUG-D Dara reservation design (PRD-018) is NOT part of this round. DONE = Nissan superseded+full 05/06 logged once; AMZ-1029/AMZ-1038/NOOK 05/06 + 6 machines 06/06 logged (swaps Remove+Add); gaps/bad-dates parked; VW Zero Lemon added to WH; Mirdif list surfaced for Simran; registries updated.
```
