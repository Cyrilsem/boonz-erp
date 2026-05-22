---
id: PRD-003
title: Phantom inventory appearing in MCC warehouse
status: Blocked
severity: P0
reported: 2026-05-21
source: Refill update 21-05-2026 — System Bugs pipe row 3
routing: [Dara, Cody]
protected_entities:
  [warehouse_inventory, pod_inventory, sales_lines, append-only logs]
blocked_reason: |
  MAJOR PROGRESS — schema scaffolding, admin FE, and 8 of 11 canonical writer
  patches landed (all unapplied; CS applies in order). Migrations:
    20260521230813_*  — provenance + quarantine scaffolding
    20260522091624_*  — FU#1 (auto_audit_*_insert) + FU#2 (receive_purchase_order)
    20260522091958_*  — FU#3: pack/return_dispatch_line, adjust/transfer_warehouse_stock
    20260522092342_*  — FU#4: receive_dispatch_line, log_manual_refill, confirm_warehouse_status_proposal
  /admin/wh-quarantine FE page reads v_wh_inventory_provenance.
  Remaining acceptance work:
    - Forensic root-cause naming for existing phantom rows (needs live data)
    - Patch 3 snapshot-class writers (upsert_refill_stock_snapshot,
      add_sanity_increment, auto_sanity_check) — bodies retrievable, mechanical
    - pg_cron entry for refresh_wh_provenance_mv() — Stax follow-up
    - Stitch (PRD-008) consume `quarantined=false` filter — gated on PRD-008
  Status remains Blocked until the snapshot-class writers are patched AND the
  scaffolding migration is applied + verified on the live DB.
---

# PRD-003 — Phantom inventory appearing in MCC warehouse

## Problem

On 2026-05-21, MCC warehouse stock counts surfaced SKUs that were never received via any purchase order: Hunters (multiple variants), Organic Rice Cake, and Perrier. These items show positive `warehouse_inventory` quantities at WH_MCC with no corresponding PO receive event.

Phantom WH stock has cascading downstream effects:

- Refill brain assumes those units are pickable and writes them into `refill_plan_output` ([[PRD-008-refill-plan-shows-phantom-skus]])
- Procurement engine underestimates real gaps and may delay reorders
- Settlement and cost accounting is wrong because the WH "asset" has no purchase origin

This is the most strategically important of the three pipe bugs because it corrupts the foundation of every downstream decision.

## Observed behaviour

- WH_MCC shows positive qty for: Hunters (variants), Organic Rice Cake, Perrier
- No PO receive event exists for these specific batches (per CS report)
- Items have been visible long enough that they entered refill plans (cross-reference with VML 4F Perrier issue in [[PRD-008-refill-plan-shows-phantom-skus]])

## Expected behaviour

Every unit in `warehouse_inventory` must trace to an originating event: PO receive, M2M return, MACHINE_TO_WAREHOUSE return, or an explicit manual adjustment with reason code. There is no other legitimate path for inventory to appear.

If a unit cannot be traced, it must be flagged in a `warehouse_inventory_audit` view and not be pickable by the refill brain.

## Hypothesis on root cause

The pattern (Hunters, Rice Cake, Perrier — three different supplier families) suggests this is NOT a single bug but a structural one. Plausible sources:

1. **M2M misroutes** (see [[PRD-001-m2m-swap-misroute]]) — every M2M that silently fell through to WH would create exactly this kind of phantom row. The IFLY-1024 Barebells case is the only one we know about; there are probably more.
2. **MACHINE_TO_WAREHOUSE return without source decrement.** If the return path writes a WH credit but the corresponding pod_inventory decrement is missed, then a subsequent corrective decrement of pod_inventory (e.g. a manual count) would leave the WH credit orphaned.
3. **Stale n8n flow writing WH on partial success.** Any orchestration that has a "create WH row" step that runs before a transactional commit can leave dangling rows on retry.
4. **Manual adjustments without provenance.** A SQL adjustment run against `warehouse_inventory` outside the canonical RPCs.

Per CLAUDE.md, `warehouse_inventory` is protected. Any fix MUST be reviewed by Cody, and the schema work goes through Dara first.

## Scope

In scope:

- Forensic audit: list every WH_MCC row, join to a synthesized "provenance" view that classifies each unit as `po_receive`, `m2m_return`, `machine_return`, `manual_adjust`, or `unknown`
- Identify which RPC paths can write to `warehouse_inventory` and confirm each one writes an append-only provenance log row
- Add a check constraint / trigger that rejects any WH write without a provenance reason
- Quarantine current phantom rows: flag them but do not delete (sales/finance may still need them visible)
- Backfill plan for cleanup once root cause is named

Out of scope:

- Rebuilding the WH inventory model from scratch
- Cost re-accounting for already-sold units (separate finance task)

## Protected entities touched

`warehouse_inventory`, `pod_inventory`, `sales_lines` (for downstream reconcile), append-only logs. Dara designs the audit view + provenance column; Cody reviews the constraint and any new RPC.

## Acceptance criteria

- [ ] `wh_inventory_provenance` view exists, joining each WH row to its origin event
- [ ] For WH_MCC: a row-by-row classification of current phantom Hunter/Rice Cake/Perrier units
- [ ] Root cause named with evidence (which RPC, which n8n flow, which manual write, etc.)
- [ ] All write paths to `warehouse_inventory` updated to require a `provenance_reason` + linked `event_id`
- [ ] Trigger / check constraint blocks new writes without provenance
- [ ] Phantom rows are flagged (column or status), not pickable by refill brain, and visible in an admin "needs review" screen
- [ ] Cody review checklist signed off

## Edge cases (all must verify before marking Done)

- **Existing WH rows with NULL provenance after migration:** quarantined (not pickable), not erroring — backfill plan documented.
- **Write with provenance_reason but no source_event_id:** rejected by constraint.
- **Manual adjustment without reason_code:** rejected.
- **Same source_event_id referenced twice:** allowed only for the two legs of an M2M (source decrement + destination increment); rejected for anything else.
- **Phantom row referenced by historic sales_lines:** finance integrity preserved — row flagged but not deleted, sales_lines remain joinable.
- **Audit view performance with >100k rows:** completes under 2s (must be indexed on machine_id and product_id at minimum).
- **Materialized view refresh failure:** admin live view continues to work; alert raised to CS; engine consumer falls back to live read with rate limit.
- **IFLY-1024 virtual reconcile (per PRD-001 decision):** test row inserted, audit view classifies it as `manual_correction` with link to PRD.

## Verification

- [ ] `npx tsc --noEmit`, `npm run build`, `npm run lint`
- [ ] `SELECT count(*) FROM warehouse_inventory WHERE provenance_reason IS NULL` returns 0 after backfill
- [ ] Manual: attempt to insert a row without provenance — fails
- [ ] Refill brain test run shows phantom-flagged rows are skipped
- [ ] Cody review

## Decisions

- **Movement log:** if an existing `wh_inventory_movements` / `wh_inventory_log` table exists, extend it with `provenance_reason` and `source_event_id`. If not, Dara creates one as APPEND-ONLY (no UPDATE, no DELETE — only superseding rows). Append-only is the only honest model for inventory audit; mutable logs are how phantom rows happen in the first place.
- **Phantom row handling:** PHYSICAL RECOUNT FIRST, then reconcile. Never write off unknown inventory without verification — in retail, that's how shrinkage and theft get hidden inside "system glitches." Quarantine the rows (flag them, mark not-pickable by the brain), recount physically over the next refill cycle, then reconcile each row with documented origin or write-off-with-reason.
- **WH receive flow movement log:** if the field PWA's WH receive doesn't write a movement log today, that's a Stax fix bundled into this PRD's acceptance criteria. Every WH state change must produce a log row — no exceptions.
- **Audit view shape:** TWO views. A LIVE view for the admin UI (real-time, slow OK because traffic is low). A MATERIALIZED view refreshed every 4h for the engine consumer (matches the existing 4h stock refresh cadence from CLAUDE.md, reduces engine query load while keeping admin truth current).

## Linked PRDs

- [[PRD-001-m2m-swap-misroute]] — almost certainly contributes to the phantom rows
- [[PRD-008-refill-plan-shows-phantom-skus]] — downstream symptom
- [[PRD-002-returns-split-by-variant-ui]] — wrong-variant returns are another contributor
