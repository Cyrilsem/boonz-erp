---
id: PROGRAM-2026-05-26
parent: PROGRAM-2026-05-25
title: Refill-week data reconciliation — pick up the pending work
status: Partial-Phase3-Done-rest-Blocked
overnight_outcome_2026-05-30: |
  Phase 3 (PRD-013 engine FEFO investigation) DONE — both diagnostic
  queries ran live, two distinct sub-bugs identified (VOX-list filter
  missing + variant-allocation tally missing), proposed fixes documented
  in PRD-013 "Findings 2026-05-26" section. Not shipped — engine is hot
  path, needs CS approval. Phases 1, 2, 4, 5 all Blocked: Phase 1 needs
  CS to paste batch row source data; Phase 2 needs CS per-row
  classification + new RPC builds with Cody review; Phase 4 needs Cody
  (new RPC) + Stax (FE); Phase 5 needs Cody (trigger + view+cron
  bundles). See PROGRAM-2026-05-26-execution-log.md for the full state.
severity: P1
reported: 2026-05-26
source: CS reassessment of refill update doc (22, 24, 25 May) after today's backend infra ship. Backend RPCs are live; the operational pod_inventory and dispatch-row corrections were missed due to system sloppiness and need to be reconciled.
routing: [Dara, Cody, Stax]
parent_program: docs/prds/_programs/PROGRAM-2026-05-25-refill-week-fixes.md
depends_on:
  - PRD-011-refill-pipeline (Backend Done; FE drawer + bulk repair complete)
  - PRD-012-rescue (Done; record_variant_correction live)
  - PRD-014-inventory (Phase 1+2 Done; Phase 3 orphan repair pending)
  - phaseF_prd011_mark_dispatch_vox_sourced (Done; 12 rows tagged)
---

# Program — Refill-week data reconciliation (2026-05-26 continuation)

This is the follow-on to PROGRAM-2026-05-25. The backend infrastructure for repair + variant correction + M2M prevention + VOX tagging has shipped and is live in prod. What remains is the operational data-correction work that was missed in the original refill cycles, plus the engine-side overallocation bug and a couple of FE follow-ups.

The driver: refill updates from 22, 24, 25 May described physical reality the system never captured. Today's backend infra makes those captures possible; this program executes them with proper edge-case handling.

## Outcome we want

By the time this program is Done:

1. Every line in the 22, 24, 25 May refill update doc has a matching row in `pod_inventory` (or `planned_swap`) with the right qty, expiry, and provenance.
2. The 79 over-allocated dispatch rows from the 19-23 May window are either resolved or explicitly logged as "WH did not have the stock we planned for, qty trimmed to actual".
3. The 28 historical orphan M2M rows from PRD-014 Phase 3 have a repair path: either paired up correctly or marked as known-orphans with reason.
4. The Krambals Creamy Cheese phantom (HUAWEI-2003), Snickers wrong expiry (HUAWEI), YoPro wrong expiry (MC) are all fixed at pod_inventory level.
5. The engine FEFO bug (PRD-013) has a root-cause investigation report with reproducer queries, plus a proposed fix.

## What's already shipped today (do not redo)

Verify against `pg_proc` and the migrations registry before touching these. If anything in this list is missing in prod, that's a data-integrity emergency — stop and raise to CS.

- `repair_unbound_dispatch(uuid, uuid, text)` — binds a packed-but-NULL-bound dispatch row to a WH batch
- `bulk_repair_unbound_dispatches(uuid, date, text, boolean)` — per-machine FEFO loop, dry-run default
- `mark_dispatch_vox_sourced(uuid, text)` — flips `source_origin='vox_at_venue'`
- `block_orphan_internal_transfer` trigger on `refill_dispatching` BEFORE INSERT
- `record_variant_correction(uuid, uuid, uuid, numeric, text, text, text)` and `curated_product_families` table
- `cancel_po_line` and `edit_purchase_order_line` (live since 23-25 May procurement work)

## Pending work (priority order)

### Phase 1 — Data fixes (do first, requires CS-in-loop)

**Batch-25May — HUAWEI-2003 + MC-2004 pod additions** (largest by row count, simplest mechanically)

Source: 25-May refill update doc. Lists ~80 line items across the two machines with explicit `{product, expiry, qty}` triples. Per CS: "same pattern as MCC ACTIVATE / VOXMM refills."

For each line:

- Parse `{machine, boonz_product_name, expiry_date, qty}` from the doc
- Resolve `boonz_product_id` from `boonz_products` (halt on unresolved)
- Resolve `pod_product_id` from `product_mapping` for the target machine (halt on unmapped)
- Resolve `shelf_id` for the pod_product_id at that machine (halt on multiple, default to most recent if single)
- INSERT a new `pod_inventory` row with `status='Active'`, snapshot_at=now()
- Audit: `actor=CS`, `reason='Batch-25May HUAWEI/MC pod sync per Refill Update 25-May'`

Edge cases mandatory:

- **Same product + expiry already exists in pod_inventory** → add to existing row, do NOT create duplicate
- **Same product different expiry already exists** → create separate row (this is the multi-batch pattern, expected)
- **Expiry date in doc is ambiguous (e.g. "29/06/26")** → assume DD/MM/YY, halt if year < 26 or > 28
- **Product name has slight variation** (e.g. "Krambal cheese" vs "Krambals Creamy Cheese") → halt and ask CS, do not fuzzy-match
- **HUAWEI Snickers expiry wrong in system** (separate doc note) → query existing pod row, UPDATE expiry, do NOT add new
- **MC YoPro Strawberry expiry update** → same UPDATE pattern

**Batch-22May — Post-refill manual additions** (~30 rows)

Source: 22-May refill update doc.

- **NOVO-1023**: Pepsi Regular +3 @ 01/02/27, Pepsi Black +4 @ 29/10/26
- **OMDBB-1020**: Activia Honey +1 @ 01/02/26, Hot Chili +1 @ 11/11/26, Black Truffle +1 @ 31/01/27, Vitamin Well Care +1, Upgrade +2, Antioxidant +1, Caramel Cashew +1
- **AMZ-1038**: Snickers +4, Mars +4, Twix +5, Bounty +3, Delice +3, KitKat +8. Plus REMOVE Organic Rice Milk Choc 2 pcs (12/12/26) from OMDBB AND from warehouse_inventory.
- **AMZ-1057**: Smart Gourmet Classic +2 @ 25/01/26, Bounty +2, Snickers +4, Mars +4, Twix +5
- **AMZ-1068**: Smart Gourmet +2 @ 25/01/27, Sabahoo +4 @ 15/06, Popcorn Butter +2, Popcorn Salt +2, Twix +5
- **AMZ-1029**: Twix +5, Mini Dark Choc +4, Salt Popcorn +1, Butter Popcorn +1, Hunter Sea Salt +2 @ 16/11/26
- **OMDBB Hot & Sweet → Himalayan Pink swap**: write to `planned_swaps` (do NOT execute the swap; that needs PRD-014-refill cross-brand RPC)
- **NOVO Be Kind → Barebells swap**: same, `planned_swaps`
- **Driver wishlists** (McVities Milk/Dark, Oreo, Mars, Snickers, Delice for OMDBB; Mars/Bounty/M&M for MC): write to `planned_swaps` as future-refill suggestions, do NOT add to current pod_inventory

Edge cases mandatory:

- **2 pcs Organic Rice Milk Choc REMOVED from OMDBB and from WH**: this is a DELETE-like operation. Do NOT actually delete the row; mark pod_inventory.status='Removed' with removal_reason='moved_to_AMZ-1038', and decrement warehouse_inventory.warehouse_stock by 2 via a canonical writer (NOT raw UPDATE)
- **AMZ-1057 Smart Gourmet Classic expiry 25/01/2026 is suspicious** (past expiry by the time it would land): halt and ask CS to confirm the date
- **AMZ-1068 Sabahoo 15/06**: ambiguous year (2026? 2027?). Halt and ask CS.
- **All AMZ machines are non-VOX venue**: these are Boonz-supplied, full WH path. No VOX tagging.

**Batch-24May — VOX day + From-Office** (~50 rows)

Source: 24-May refill update doc. Eight machines plus the "From Office" delivery.

- **VOX-0797**: Iced Tea Lemon +6, Galaxy Choc +8, Bounty +7, Snickers +6, Well Reload +3, Well Upgrade +5
- **VOX-0795**: Iced Tea Peach +12, Well Upgrade +7, Well Reload +2
- **IFLY refill** (which machine? doc says "IFLY refill"): Galaxy Choc +5, Snickers +8, Mars +5 → likely IFLYMCC-1024
- **MP-0719**: Pepsi Diet +5, Iced Tea Peach +6, M&M Peanut +3, M&M Choc +3, Sunblast Apple +4
- **MP-0715**: Aquafina +32
- **ACT-0817**: Aquafina +24, Redbull +5 (WH-sourced), PLUS Gatorade Blue +6, Gatorade Zero +6, Sunblast Apple +6, Evian 1L +2 (all FROM OFFICE)
- **ACT-0736**: Evian 1L +4 (FROM OFFICE)
- **Marecato-0798**: Krambals Tomato +3, Leibniz Cocoa +1, Leibniz Milk Honey +1, Leibniz Original +1, Well Reload +3, Well Upgrade +3, Well Zero Peach +2

Edge cases mandatory:

- **From-Office items need `source_kind='from_office'` (new enum value)**: confirm enum already accepts this or add via Cody-reviewed migration first. CS approved this provenance flag in a prior turn.
- **VOX cinema machines (VOX-0797, VOX-0795, IFLY) for VOX-sourced products (Pepsi, Aquafina, M&M, Iced Tea)**: tag `source_origin='vox_at_venue'`, skip WH debit. For non-VOX products on those machines (Snickers, Mars, Vitamin Well), they ARE Boonz-supplied through the WH.
- **"IFLY refill" is ambiguous**: halt and ask CS which machine (IFLYMCC-1024 vs anything else).
- **Magic Planet machines (MP-0719, MP-0715) are MCC venues**: most products there are VOX-sourced. Confirm before tagging.

### Phase 2 — Repair the 79 over-allocated dispatch rows + 28 M2M orphans

**79 over-allocated dispatch rows** (19-23 May, packed=true, from_wh_inventory_id IS NULL, action Refill/Add New, NOT in vox_at_venue, no Active WH batch with sufficient stock)

These are rows where the engine planned more units than WH ever had. Three valid resolution paths:

1. **Trim dispatch qty to whatever WH actually had**, bind via repair_unbound_dispatch with the trimmed qty. Loses 0 inventory accuracy.
2. **Mark dispatch as fulfilled-from-elsewhere**: new RPC `mark_dispatch_external_source(dispatch_id, source_note)` that sets a flag and binds without WH debit. Use only when there's evidence the qty physically landed at the machine (e.g. driver report).
3. **Mark dispatch as not-fulfilled**: cancellation pattern. New RPC `cancel_dispatch_line(dispatch_id, reason)` analogous to cancel_po_line. The dispatch row stays for audit but `cancelled=true`.

Pick the right one per row based on physical reality. CS sign-off per row mandatory.

**28 historical M2M orphan rows** (PRD-014 Phase 3)

Build `repair_orphan_internal_transfer(orphan_dispatch_id, destination_machine_id_or_null, reason)` canonical writer:

- If physical product landed at destination → write the missing Add New row, pair with the orphan Remove via a fresh m2m_transfer_id
- If product returned to WH (not a real M2M) → reactivate the WH row via reactivate_warehouse_row with explicit reason
- Allow-listed in the prevention trigger that's already live

Then walk through the 28 rows with CS per row.

### Phase 3 — Engine FEFO investigation (PRD-013)

Root cause unknown after overnight V3 falsification. Run these queries to characterize:

```sql
-- Pattern 1: engine planned a product whose WH was 100% Inactive at plan time
SELECT rpo.plan_date, m.official_name, bp.boonz_product_name, rpo.quantity,
       (SELECT bool_and(status = 'Inactive')
        FROM warehouse_inventory wh
        WHERE wh.boonz_product_id = rpo.boonz_product_id) AS all_inactive_at_now
FROM refill_plan_output rpo
JOIN machines m ON m.machine_id = rpo.machine_id
JOIN boonz_products bp ON bp.product_id = rpo.boonz_product_id
WHERE rpo.plan_date BETWEEN '2026-05-19' AND '2026-05-23'
  AND (SELECT bool_and(status = 'Inactive')
       FROM warehouse_inventory wh
       WHERE wh.boonz_product_id = rpo.boonz_product_id);

-- Pattern 2: engine planned more than total Active WH stock
WITH plan_demand AS (
  SELECT boonz_product_id, plan_date, SUM(quantity) AS planned_qty
  FROM refill_plan_output
  WHERE plan_date BETWEEN '2026-05-19' AND '2026-05-23'
  GROUP BY boonz_product_id, plan_date
),
wh_supply AS (
  SELECT boonz_product_id, SUM(warehouse_stock) AS available
  FROM warehouse_inventory
  WHERE status = 'Active'
  GROUP BY boonz_product_id
)
SELECT bp.boonz_product_name, pd.plan_date,
       pd.planned_qty::int AS planned, ws.available::int AS wh_active_now,
       (pd.planned_qty - COALESCE(ws.available, 0))::int AS shortfall
FROM plan_demand pd
JOIN boonz_products bp ON bp.product_id = pd.boonz_product_id
LEFT JOIN wh_supply ws ON ws.boonz_product_id = pd.boonz_product_id
WHERE pd.planned_qty > COALESCE(ws.available, 0)
ORDER BY shortfall DESC;
```

Document findings as PRD-013 update with reproducer + proposed fix. Then either ship the engine patch or escalate to CS for design call.

### Phase 4 — FE follow-ups (Stax)

PRD-011 packing FE drawer:

- Render `vox_at_venue` dispatch rows with a "VOX-sourced" chip instead of expiry/batch picker
- Show a "Re-pin batch" button on rows where `packed=true` AND `from_wh_inventory_id IS NULL` AND `source_origin <> 'vox_at_venue'` (calls `repair_unbound_dispatch`)
- Allow qty + expiry edit inside the pack screen (the unbound case where stitch couldn't pre-pin)

PRD-014-refill cross-brand substitute (drafted, blocked on PRD-012 — now unblocked):

- Backend: `record_cross_brand_substitution(dispatch_id, new_boonz_product_id, qty, reason)` writes to slot_lifecycle + dispatch + driver_feedback
- FE: driver-side "Substitute different product" affordance, distinct from variant-swap

### Phase 5 — Hygiene PRDs

PRD-015-inventory MCC phantom WH: 7-day RAISE WARNING window then flip to RAISE EXCEPTION on null-provenance INSERTs.

PRD-016-inventory phantom pod row detector: read-only view + daily cron + alert table. Already has Cody draft, just needs apply.

## Hard rules (inherited from parent program)

1. **Never raw-SQL a protected table.** Always canonical RPC.
2. **STOP and ask CS** before any DELETE on any table, or any operation that would reduce warehouse_stock / consumer_stock / pod stock. Backfill NULL → value is OK; reduce-from-value needs sign-off.
3. **Pod vs WH expiry scope** (per feedback_pod_vs_wh_expiry_scope): edits to pod expiry do NOT cascade to WH unless explicitly requested.
4. **Cody approval mandatory** for every new migration.
5. **Stax review mandatory** for every FE diff.
6. **Verify against pg_proc** before assuming a memory claim is true. (V4 lesson from yesterday.)
7. **No double-fix**: check pg_proc + recent commit history before re-implementing anything.
8. **If a step fails verification in production**, mark its task `Blocked` with the failing check and continue to the next.

## Edge cases worth flagging up front

These have already burned us once. Re-read the relevant memory before touching the surface:

- **Al Ain Water pattern** ([[feedback_pod_vs_wh_expiry_scope]]): edits to pod expiry do not cascade to WH.
- **Multi-variant even split** ([[feedback_multivariant_even_split]]): when splitting across flavours, distribute EVENLY (±1 unit). Do not dump 12 of one flavour. Applies to anything in the Hunter, Barebells, Vitamin Well, Be Kind families.
- **Title case action** ([[feedback_dispatching_action_casing]]): `refill_dispatching.action` must be Title Case ('Refill', 'Add New', 'Remove'). ALL CAPS breaks the FE.
- **VOX-sourced product list** ([[reference_vox_sourced_products]]): Pepsi, Ice Tea, M&M Bags, Aquafina, Maltesers, Fade Fit, Chocolate Bar, Skittles Bag, Soft Drinks Mix (7up). Exclude these from Boonz POs for VOX venue_group machines.
- **NOVO Pepsi specifically**: the 2 rows that CS reported as "no stock" are in the 79 over-allocated bucket. WH genuinely ran out (Pepsi Black 2 left, Pepsi Regular 2 left). After Batch-22May adds Pepsi Regular +3 @ 01/02/27 and Pepsi Black +4 @ 29/10/26, the WH should have enough to repair those rows. Order matters: do Batch-22May BEFORE retrying the over-allocation repair for NOVO.

## Verification (per phase)

- Each batch ends with: `SELECT COUNT(*) FROM pod_inventory WHERE created_at >= today AND created_by = '<CS uuid>'` matches expected.
- Each repair pass ends with: count of `from_wh_inventory_id IS NULL` rows decreased by the expected amount.
- Each migration ends with: `SELECT proname FROM pg_proc WHERE proname = '<rpc_name>'` returns 1 row.
- After Phase 1+2: re-pull the 19-23 May per-machine breakdown, confirm `still_unbound` count is ≤ 79 (the engine-overallocation bucket) and dropping as Phase 2 proceeds.

## Done criteria

This program is Done when:

1. All 3 batches reconciled, per-row sign-off captured in `procurement_events` or `inventory_audit_log`.
2. The 79 over-allocated rows have an explicit resolution (trim / external-source / cancel).
3. The 28 M2M orphans have either a repair Pair or a cancel-with-reason.
4. PRD-013 has a written investigation report with reproducer + proposed engine fix.
5. PRD-011 FE drawer + PRD-014 cross-brand RPC shipped (Stax can take these in parallel with the data fixes).
6. PRD-015 + PRD-016 applied to prod with the warning-window pattern.
7. MEMORY.md updated with project entries for everything above.
8. CHANGELOG.md updated.

## /goal command for Claude Code

```
/goal docs/prds/_programs/PROGRAM-2026-05-26-refill-data-reconciliation.md

Execute Phase 1 through Phase 5 in order. Before EACH phase, re-read the
parent doc PROGRAM-2026-05-25-refill-week-fixes.md and the relevant child
PRDs to confirm current prod state.

Phase 1 (data fixes, CS-in-the-loop per batch):
  - Batch-25May first (largest, simplest mechanically). Parse the doc lines
    into {machine, product, expiry, qty} tuples. For EACH tuple: resolve IDs,
    show CS the per-row diff in a chat message, wait for explicit "go", then
    INSERT/UPDATE via canonical pod write path. Halt on any unresolved name
    or ambiguous date. Mandatory edge cases listed in the program doc.
  - Batch-22May next. Same per-row sign-off. The Organic Rice Milk Choc
    REMOVE from OMDBB + WH needs special handling (canonical decrement,
    not delete).
  - Batch-24May last. The "From Office" items need source_kind='from_office'
    provenance. If the enum doesn't accept that value yet, add it via a
    Cody-reviewed migration before running the batch.

Phase 2 (over-allocation + M2M orphan repairs):
  - 79 over-allocated dispatch rows: for each, classify as trim/external/
    cancel based on physical reality (CS-provided). Build the
    cancel_dispatch_line RPC if it doesn't exist. Per-row CS sign-off.
  - 28 M2M orphans: build repair_orphan_internal_transfer RPC (allow-listed
    in the existing trigger). Walk through with CS.

Phase 3 (PRD-013 engine FEFO investigation):
  - Run the two diagnostic queries in the program doc.
  - Write findings to docs/prds/refill-pipeline/PRD-013-engine-fefo-investigation.md
    under a new "Findings 2026-05-26" section.
  - Propose a fix in the same doc. Do NOT ship without CS approval (the
    engine touches every refill cycle).

Phase 4 (FE follow-ups via Stax skill):
  - PRD-011 FE drawer: VOX-sourced chip + Re-pin batch button + edit-during-pack.
  - PRD-014-refill cross-brand substitute: backend + FE.
  - Stax review of every FE diff before merge.

Phase 5 (hygiene):
  - PRD-015-inventory: ship the provenance-warning trigger with a 7-day
    warning window flag. Document the cutover plan.
  - PRD-016-inventory: ship the phantom pod row view + daily cron + alert
    table.

Hard rules (restated):
- Never raw-SQL a protected table. Canonical RPC only.
- Stop and ask CS before any DELETE on any table, or any reduction of
  warehouse_stock / consumer_stock / pod stock.
- Pod-vs-WH expiry scope: pod edits do not cascade to WH unless
  explicitly requested.
- Cody approval mandatory on every migration; Stax review mandatory on
  every FE diff.
- No double-fixing: verify pg_proc + recent commits before drafting any
  PRD body.
- If a step fails production verification, mark Blocked in frontmatter
  with the failing check and continue to the next.
- Apply the edge-case checklist from the program doc to every batch row.
- Title case action values, multi-variant even split, VOX-sourced product
  list — all the memory rules apply.

End state: every line in the 22/24/25 May refill update doc has a matching
prod state (pod_inventory or planned_swap with the right qty, expiry,
provenance), the 79 over-allocated rows are resolved, the 28 M2M orphans
have a repair pair or cancel, PRD-013 investigation is written, PRD-011 FE
+ PRD-014-refill + PRD-015 + PRD-016 are either Done or Blocked-with-reason.
```

## Linked PRDs

- [[PROGRAM-2026-05-25-refill-week-fixes]] — parent program; backend infra ship
- [[PRD-011-packing-fe-rebind-wh-and-edit]] — backend done, FE pending
- [[PRD-012-rescue-record-variant-correction]] — done
- [[PRD-013-engine-fefo-investigation]] — needs investigation update
- [[PRD-014-cross-brand-driver-substitute]] — drafted, unblocked by PRD-012
- [[PRD-014-m2m-routing-fix-and-ifly-rca]] (inventory) — Phase 1+2 done, Phase 3 pending
- [[PRD-015-mcc-phantom-wh-rca]] (inventory) — drafted, blocked
- [[PRD-016-phantom-pod-row-detector]] (inventory) — drafted, blocked

## Linked memory

- [[feedback_pod_vs_wh_expiry_scope]] — Al Ain lesson
- [[feedback_multivariant_even_split]] — distribute evenly
- [[feedback_dispatching_action_casing]] — Title Case
- [[feedback_no_destructive_changes]] — no silent reductions
- [[reference_vox_sourced_products]] — the canonical 9-product VOX list
- [[reference_edit_purchase_order_line]] — procurement edit RPC reference
- [[reference_cancel_po_line]] — procurement cancel RPC reference
- [[project_prd011_014_phase2_shipped]] — what shipped today
- [[project_prd012_rescue_curated_families]] — variant correction landed
