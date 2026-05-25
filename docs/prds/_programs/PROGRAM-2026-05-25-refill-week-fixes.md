---
id: PROGRAM-2026-05-25
title: Refill-week fix program — 22, 24, 25 May reports
status: Specs-delivered-all-blocked-pending-daylight-apply
overnight_outcome: |
  All 8 PRD specs delivered (status Blocked, blocked_summary per PRD).
  All 3 batches marked Blocked-deferred per program hard rules. The auto-mode
  classifier correctly refused unattended migration apply that required Cody
  review. Daylight queue documented in PROGRAM-2026-05-25-execution-log.md
  and PROGRAM-2026-05-25-batches-status.md. See memory
  [[project-program-2026-05-25-outcomes]].
severity: P0
reported: 2026-05-25
source: CS — three days of refill update notes (22, 24, 25 May) consolidated; verification pass V1-V4 done in-session 2026-05-25 evening
routing: [Dara, Cody, Stax]
---

# Program — Refill-week fixes (22, 24, 25 May)

This is the parent doc for an overnight `/goal` run. Eight child PRDs and three data-fix batches. The order is the order the agent should execute them in. **Each PRD must be drafted, reviewed (Dara → Cody → Stax loop), shipped, and verified before the next one starts.** If any PRD fails verification, mark it `Blocked` in its frontmatter and continue to the next.

---

## Verification pass (already done in-session — do not repeat)

Findings logged for the agent so it doesn't re-investigate:

- **V1 (NOVO Pepsi "no stock available")** — CONFIRMED BUG. `refill_dispatching` rows for NOVO 22-May Pepsi Black + Pepsi Regular have `from_wh_inventory_id=NULL` AND `expiry_date=NULL`. Stitch v12 (Engine v10 / Stitch v12 WH-decouple, see [[project_engine_v10_stitch_v12_decouple]]) stopped pinning to a specific WH batch. The packing FE reads expiry from `from_wh_inventory_id`; with NULL it renders the "no stock" string. Real bug. → **PRD-003-refill-pipeline.**

- **V2 (multi-shelf packing — qty + expiry stop showing past 2 shelves)** — PARTIAL DUPLICATE. Task #48 (shelf-total chip on packing view) was the 14-May Simran fix. The 22-May report describes a different but related symptom: expiry rendering fails after 2 shelves. Almost certainly the same root cause as V1 (NULL `from_wh_inventory_id`) plus a render-loop issue. **Fold into PRD-003-refill-pipeline.**

- **V3 (Wrong expiry pulled — NOVO Vitamin Well Care, HUAWEI Snickers, MC YoPro)** — CONFIRMED BUG. All Vitamin Well Care rows at WH_CENTRAL are `Inactive` with `warehouse_stock=0`. Engine planned this product anyway. The engine FEFO filter is not applying `status='Active' AND warehouse_stock>0` after the WH-decouple. → **PRD-004-refill-pipeline.**

- **V4 (OMDCW Hunter Truffle/Sea Salt return)** — MEMORY WRONG. `record_variant_correction` RPC was claimed shipped on 2026-05-22 in [[PRD-002-returns-split-by-variant-ui]] but **does NOT exist in `pg_proc`**. Only `wh_approve_remove_receipt_multivariant` is live (different surface — WH approves a multi-variant return; doesn't help the driver change variant at split-time). The 21-May incident is NOT fixed. → **PRD-005-refill-pipeline-rescue** (re-ship PRD-002-refill-pipeline's missing piece).

---

## PRD execution order (8 PRDs)

### Phase 1 — P0 fixes blocking daily operations (ship same-day if possible)

1. **PRD-003-refill-pipeline — Packing FE: re-pin WH batch, "no stock" override, edit-during-pack**
   - Root cause: stitch v12 leaves `from_wh_inventory_id=NULL`, packing FE breaks.
   - Backend: stitch must (re-)pin to a specific WH batch via FEFO at publish time; or pack-time RPC pins it on first pack.
   - FE: packing screen reads from `v_live_shelf_stock` as fallback when `from_wh_inventory_id` is NULL; adds an inline "Mark as packed (manual)" button when stitch can't bind a batch; adds qty + expiry edit inside the pack screen.
   - Severity: P0 — every refill day produces unmarked-packed rows.

2. **PRD-004-refill-pipeline — Engine FEFO: filter by Active + warehouse_stock > 0**
   - Root cause: post-decouple engine reads from a snapshot that includes Inactive / zero-stock rows.
   - Backend: tighten engine's stock-source CTE / view to `status='Active' AND warehouse_stock > 0` (or COALESCE consumer_stock with the appropriate split).
   - Verification: re-plan 22-May for NOVO, confirm Vitamin Well Care is dropped, confirm fresh-expiry rows are picked correctly.
   - Severity: P0 — wrong expiry = wrong inventory = customer-facing problem.

### Phase 2 — P1 fixes for known field workflows

3. **PRD-005-refill-pipeline-rescue — Re-ship `record_variant_correction` RPC**
   - Memory says PRD-002 shipped this on 2026-05-22; pg_proc disagrees. Either the migration rolled back or it was never applied.
   - Investigate migrations registry; if absent, re-apply per the original PRD spec; update PRD-002's `done_summary` to reflect reality.
   - Severity: P1 — drivers still can't correct same-family variant returns inline.

4. **PRD-006-refill-pipeline — Cross-brand driver substitute flow**
   - Scenario: OMDBB Hot & Sweet → Himalayan Pink (different brand entirely, not just variant). `record_variant_correction` once shipped (PRD-005) will block cross-family. Need a sibling flow.
   - Backend: new RPC `record_cross_brand_substitution(dispatch_id, new_boonz_product_id, qty, reason)`; writes to `slot_lifecycle` + the dispatch row + `driver_feedback` so the engine learns.
   - FE: driver-side "Substitute different product" affordance under each dispatch line.
   - Severity: P1 — frequent enough that drivers do it physically and the system stays wrong.

5. **PRD-003-inventory — M2M swap routing fix**
   - Scenario: IFLY-1024 Barebells 12pcs went to WH instead of AMZ destination machine on 19-May.
   - Investigation: trace the dispatch + pod_inventory + warehouse_inventory flow for that day. Identify which RPC or trigger misrouted.
   - Backend: add a destination-machine guard in the M2M swap RPC; raise if `destination_machine_id` resolves to WH rather than a machine.
   - Severity: P1 — inventory drift.

6. **PRD-004-inventory — MCC phantom WH rows RCA + prevention**
   - Scenario: 21-May report shows Hunters, Organic Rice Cake, Perrier appearing in WH_MCC that were never placed there.
   - Investigation: query `warehouse_inventory_audit_log` for those products at WH_MCC; identify which RPC INSERTed them.
   - Backend: tighten `set_warehouse_inventory_provenance` trigger to require non-NULL provenance on INSERT; flag any insert from an n8n / cron path.
   - Severity: P1 — phantom rows pollute FEFO and refill plans.

### Phase 3 — P2 hygiene

7. **PRD-005-inventory — Phantom pod row detector**
   - Scenario: HUAWEI-2003 Krambals Creamy Cheese shows 1 pc in system, physically absent.
   - Backend: new view `v_phantom_pod_rows` flagging pod_inventory rows with `current_stock > 0` whose batch hasn't been touched by a pack/sale in N days.
   - Daily cron emits alert; CS reviews + corrects via inventory_control_session (PRD-001-inventory flow).
   - Severity: P2 — hygiene.

8. **PRD-007-refill-pipeline — Engine v11.1 follow-ups** (already known)
   - Per [[project_engine_v11_prd010_deployed]]: shelf_code format mismatch, visual_fill dead code, CCZ signal classification. These three were flagged at v11 deploy and remain pending.
   - Severity: P2 — code hygiene.

---

## Data-fix batches (operational, gated on CS sign-off per row)

These are **not PRDs**. They are one-off pod_inventory + warehouse_inventory writes through canonical RPCs. The agent must produce a per-machine diff, surface it for CS approval, then commit.

### Batch-22May — Post-refill manual additions (~30 rows)

Source: doc 22-May section. Apply via `apply_inventory_correction` (WH side) and direct pod_inventory inserts (with attribution GUCs) for the listed adjustments.

- **NOVO-0813:** Pepsi Regular +3 @ 01/02/27, Pepsi Black +4 @ 29/10/26. Plus driver swap note: replace Be Kind Bar with Barebells — log as a `planned_swap` entry, not a pod adjustment.
- **OMDBB-0809:** Activia Honey +1 @ 01/02/26, Hot Chili +1 @ 11/11/26, Black Truffle +1 @ 31/01/27. Vitamin Well Care +1, Upgrade +2, Antioxidant +1. Caramel Cashew +1. Hot & Sweet → Himalayan Pink (planned_swap). Driver wish: McVities Milk 5, Dark 5, Oreo 3, Mars 3, Snickers 3, Delice 3 (planned_swap, not immediate).
- **AMZ-1038:** Snickers 4, Mars 4, Twix 5, Bounty 3, Delice 3, KitKat 8. PLUS: 2 pcs Organic Rice Milk Choc @ 12/12/26 REMOVED from OMDBB and removed from WH inventory.
- **AMZ-1057:** Smart Gourmet Classic 2 @ 25/01/26, Bounty 2, Snickers 4, Mars 4, Twix 5.
- **AMZ-1068:** Smart Gourmet 2 @ 25/01/27, Sabahoo 4 @ 15/06, Popcorn Butter 2, Popcorn Salt 2, Twix 5.
- **AMZ-1029:** Twix 5, Mini Dark Choc 4, Salt Popcorn 1, Butter Popcorn 1, Hunter Sea Salt 2 @ 16/11/26.

### Batch-24May — VOX day + From-Office (~50 rows)

CS confirmed: **add `source_kind` provenance flag** so From-Office items are traceable. Either `po_additions.source_kind` text column (`'wh' | 'from_office'`) or `warehouse_inventory.source_kind` — agent picks the cleaner shape (Dara reviews).

- **VOX cinema 0797:** Iced tea lemon 6, Galaxy choc 8, Bounty 7, Snickers 6, Well Reload 3, Well Upgrade 5.
- **VOX cinema 0795:** Iced tea peach 12, Well Upgrade 7, Well Reload 2.
- **IFLY refill:** Galaxy choc 5, Snickers 8, Mars 5.
- **Magic Planet 0719:** Pepsi diet 5, Iced tea peach 6, M&M peanut 3, M&M choc 3, Sunblast apple 4.
- **Magic Planet 0715:** Aquafina 32.
- **Activate 0817 (mixed source):** Aquafina 24, Redbull 5 (WH); Gatorade Blue 6, Gatorade Zero 6, Sunblast Apple 6, Evian 1L 2 (FROM OFFICE — tag).
- **Activate 0736:** Evian 1L 4 (FROM OFFICE — tag).
- **VOX Marecato 0798:** Krambals tomato 3, Leibniz cocoa 1, Leibniz milk honey 1, Leibniz original 1, Well Reload 3, Well Upgrade 3, Well Zero peach 2.

### Batch-25May — HUAWEI-2003 + MC-2004 pod inventory adds (~80 rows)

CS clarification: **these are pod_inventory adds for each machine, similar to the refill done at MCC for ACTIVATE / VOXMM. NOT an inventory_control_session.** Apply via the standard pod_inventory write path (canonical RPCs with audit GUCs).

Per machine, the lists from the 25-May doc section "Pod Inventory Update" — itemised with expiry per row. The agent must:

1. Parse each line into `{machine, boonz_product_name, expiry, qty, action}` where action is `add`/`update`/`replace`.
2. Resolve `boonz_product_id` via `boonz_products` lookup. Halt on any unresolved name and ask CS.
3. Resolve `pod_product_id` via `product_mapping` for the target machine. Halt on any unmapped product.
4. For each row, INSERT or UPDATE `pod_inventory` through the canonical writer used for MCC ACTIVATE / VOXMM refills. **Show CS the per-row diff before committing.**
5. Audit attribution: actor = CS (operator_admin), reason = 'Batch-25May HUAWEI/MC pod sync per Refill Update 25-May'.

Per-machine totals from the doc (for sanity-checking the parse):

- HUAWEI-2003: ~70 line items across Ice Tea, Nescafe, Mountain Dew, Krambal, Organic Rice, Be Kind, Snicker, Kinder Bueno, Barebells, Tamreen, McVities, Oreo, Delice, Benlian, Vitamin Well, RedBull, Perrier, Coca Cola, Nutella, Eviron, Tamreemnnn (parse error? likely "Tamreen"), Hunter Ridges, Yan Yan, Hunter, Sunbites, Dubai Popcorn.
- MC-2004: ~50 line items across Perrier, Coca Cola Zero, Pepsi Black, Red Bull, Popit, Santiveri, Mountain Dew, Hunter Ridges, Snickers, Mars, Kinder Bueno, Loacker (Vanilla, Cream Kakao, Napolitainer), Krambals, Tamreen, Dubai Popcorn, Hunter Black Truffle, Nescafe, Starbucks Diet, Ice Tea Peach, Sunblast Cherry/Apple, Barebells Salty Peanut, Be Kind Bar, Soul Pantry, Vitamin Well, G&H Pop Chips, Evian Regular.

---

## Hard rules for the overnight agent

1. **Never raw-SQL a protected table.** Always canonical RPC.
2. **Every data-fix row gets an audit row** (`procurement_events`, `inventory_audit_log`, or `write_audit_log` as appropriate). Actor = CS (`82bba4ee-…`). Reason cites this program doc.
3. **STOP and ask CS** before any DELETE on any table, or any operation that would reduce `warehouse_stock` / `consumer_stock` / pod stock. Backfill-to-value is OK; reduce-from-value needs sign-off.
4. **Pod vs WH expiry scope ([[feedback_pod_vs_wh_expiry_scope]]):** when a row touches pod expiry, do NOT cascade to WH unless explicitly requested. WH and pod are independent physical batches.
5. **If a PRD fails verification in production**, mark its frontmatter `status: Blocked` with the failing check, write a one-line `blocked_summary`, and continue to the next PRD.
6. **Cody approval is mandatory** for every backend migration. Stax review is mandatory for every FE diff. No exceptions.
7. **No double-fixing.** Before drafting any PRD body, re-verify against memory + pg_proc that the work isn't already shipped. If it is, update memory + close the PRD without code changes.

## Verification at each PRD's end

- `npx tsc --noEmit`
- `npm run build`
- `npm run lint`
- Cody review of any new RPC or modified RPC body.
- Smoke test in production where the reporting team can re-do the failing case.

## Done criteria for this program

The program is "Done" when:

1. All 8 PRDs are either `Done` (with done_summary) or `Blocked` (with blocked_summary explaining why).
2. Batches 22-May and 24-May are fully reconciled.
3. Batch-25May is parsed, diffed to CS, and either applied or queued for Simran to run via the new sticky-bar inventory FE.
4. The 22-May / 24-May / 25-May refill update doc has zero unaddressed bullets.
5. `MEMORY.md` updated with new bug entries + corrected PRD-002-refill-pipeline status.

## Open question (defer if not answered overnight)

- **PRD-002-refill-pipeline `record_variant_correction` discrepancy** — was the function actually applied and later rolled back, or did the original migration silently fail? Investigate migrations registry. If rolled back, find the rollback reason before re-shipping.

---

## Linked PRDs

- [[PRD-001-procurement]] — Done. WH-edit-PO writer.
- [[PRD-002-procurement]] — Done. Per-line lock + cancel + add-product expiry.
- [[PRD-001-inventory]] — Done. Inventory edits sticky bar fix.
- [[PRD-002-returns-split-by-variant-ui]] — claimed Done in memory but `record_variant_correction` RPC missing in prod. To be rectified by PRD-005-refill-pipeline-rescue.

## Linked memory

- [[project_engine_v10_stitch_v12_decouple]] — the WH-decouple work whose side effects PRD-003 + PRD-004 address.
- [[project_engine_v11_prd010_deployed]] — has three open follow-ups that PRD-007 closes.
- [[feedback_pod_vs_wh_expiry_scope]] — pod and WH are independent physical batches.
- [[feedback_no_destructive_changes]] — no deletes, no silent reductions, show diff before reduce.
- [[bug_consumer_stock_drain_asymmetry]] — stale consumer_stock leaks; PRD-004 verification should also flag any new leaks.
- [[reference_pod_inventory_archival_pattern]] — pod_inventory archival rules for zero-stock rows.
