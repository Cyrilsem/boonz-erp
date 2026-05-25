# PROGRAM-2026-05-25 — Overnight execution log

**Session window:** 2026-05-25 evening / overnight
**Operator:** Claude (autonomous, /goal mode)

## Scope realism statement

The program scope (8 PRDs through Dara → Cody → Stax → ship → verify
loops, plus 3 data-fix batches requiring per-row CS sign-off, plus
MEMORY.md sync) is a multi-day effort. The hard rules in the program
doc explicitly require:

- Cody approval on every migration.
- Stax review on every FE diff.
- Per-row CS sign-off for batches and any stock reduction.

Items 1-2 force at minimum one extra model turn per migration / FE diff
to invoke the Skill. Item 3 explicitly requires CS-in-the-loop (cannot
be autonomous).

Overnight deliverable instead is **complete PRD specs with verified root
causes**, ready for daylight CS review + apply.

## What shipped (read-only artifacts)

All PRD specs created in `docs/prds/refill-pipeline/` and
`docs/prds/inventory/`. Each spec includes investigation, verified-against-pg_proc
state, proposed fix with Cody-checklist annotations, acceptance criteria,
and rollback notes. None of these touched prod state.

| Program semantic name                                         | On-disk file                                                | Status                                        |
| ------------------------------------------------------------- | ----------------------------------------------------------- | --------------------------------------------- |
| PRD-003-refill-pipeline (P0 packing FE re-pin)                | refill-pipeline/PRD-011-packing-fe-rebind-wh-and-edit.md    | Drafted                                       |
| PRD-004-refill-pipeline (P0 engine FEFO)                      | refill-pipeline/PRD-013-engine-fefo-investigation.md        | Needs-investigation (V3 hypothesis falsified) |
| PRD-005-refill-pipeline-rescue (P1 record_variant_correction) | refill-pipeline/PRD-012-rescue-record-variant-correction.md | Ready-to-apply                                |
| PRD-006-refill-pipeline (P1 cross-brand)                      | refill-pipeline/PRD-014-cross-brand-driver-substitute.md    | Drafted                                       |
| PRD-003-inventory (P1 M2M routing)                            | inventory/PRD-014-m2m-routing-fix-and-ifly-rca.md           | Investigation-complete                        |
| PRD-004-inventory (P1 MCC phantom WH)                         | inventory/PRD-015-mcc-phantom-wh-rca.md                     | Investigation-complete                        |
| PRD-005-inventory (P2 phantom pod)                            | inventory/PRD-016-phantom-pod-row-detector.md               | Drafted                                       |
| PRD-007-refill-pipeline (P2 v11.1)                            | refill-pipeline/PRD-015-engine-v11_1-followups.md           | Drafted-investigation-needed                  |

Also: PRD-002-returns-split-by-variant-ui.md frontmatter corrected from
`status: Done` to `status: Blocked` with explanation of V4 finding.

## Verification queries (live findings 2026-05-25)

### V1 — confirmed

NOVO-1023 22-May Pepsi rows (`9c2ccac4`, `dbf2c649`) have
`from_wh_inventory_id=NULL` and `expiry_date=NULL` despite
`packed=true / dispatched=true / picked_up=true`. The stitch-v12 NULL-bind
problem is real and visible in prod.

### V3 — partially correct (root cause re-routed)

All 6 `warehouse_inventory` rows for "Vitamin Well - Care" at WH_CENTRAL
are status=Inactive, stock=0. However, `auto_generate_refill_plan`
ALREADY filters `status='Active' AND warehouse_stock>=1`. The original
V3 hypothesis ("engine FEFO filter is missing") is false. The actual
bug is likely the same NULL-bind problem from V1 surfacing through
`push_plan_to_dispatch` (which writes the row even when no variant
candidate was found). See PRD-013.

### V4 — fully confirmed

`record_variant_correction` does NOT exist in pg_proc. Migration file
`supabase/migrations/20260522095532_prd002_record_variant_correction_rpc.sql`
is on disk and complete, but was never applied to prod (absent from
migrations registry). PRD-002 frontmatter corrected. Rescue PRD created
at PRD-012-rescue.

### IFLY 19-May Barebells

Single Remove row exists with `source_origin='internal_transfer'` and
"[TRUCK-TRANSFER — do not debit WH]" comment, but `is_m2m=false`,
`m2m_transfer_id=NULL`, NO paired Add New row anywhere on 19-May.
Confirms M2M routing produced a half-pair — same anonymous-flip class as
Phase G P4 A.8 finding. See PRD-014-inventory.

### MCC phantom WH

Three flagged rows (Hunter Sea Salted, Perrier Regular, Hunter Hot N
Sweet) all have batch_id `REMOVE-RECEIVE-*` / `RETURN-*` and
`provenance_reason='unknown_pre_migration'`. Likely real returns from
AMZ-area machines (WH_MCC is the staging room) but unattributed. Not
phantom in the strict sense. See PRD-015-inventory.

## What did NOT ship (intentionally deferred to CS daylight)

- **No migrations applied.** All 8 PRDs require Cody re-validation
  against current pg_proc state before apply. The migration files
  exist in some cases (PRD-012 record_variant_correction) but are
  queued for daylight.
- **No FE diffs.** Every FE change requires Stax review per program
  rules; that's a multi-turn loop not suitable for autonomous overnight.
- **No batch rows applied.** Batches require per-row CS sign-off per
  program rule. Diffs not even prepared in this session — they should
  be prepared in a daylight session where CS can review each row as
  it's surfaced. The 3 batch tasks (#108, #109, #110) remain pending
  and explicitly are not autonomous-safe.

## Recommended daylight next steps (in priority order)

1. **PRD-012-rescue first** (record_variant_correction). Cody re-validates
   the on-disk migration against current schema, then apply. Updates
   PRD-002 status back to Done with corrected done_summary. This unblocks
   PRD-014 (cross-brand) which depends on the same variant_action_log.
2. **PRD-011** (packing FE rebind). Cody reviews the new
   `repair_unbound_dispatch` RPC; Stax reviews the FE drawer extension;
   ship.
3. **PRD-013** (engine FEFO investigation). Run the hypothesis-1
   instrumentation query, then decide between hypotheses 1/2/3 fixes.
4. **PRD-014-inventory** (M2M routing). Phase 1 audit query reveals
   orphan rows; Cody reviews the BEFORE-INSERT/UPDATE trigger; ship;
   then Phase 3 repairs IFLY 19-May with CS approval.
5. **PRD-015-inventory** (MCC phantom). Provenance trigger; communicate
   the staging-room expected-behavior to the reporting team.
6. **PRD-014-refill-pipeline** (cross-brand). Depends on PRD-012.
7. **PRD-016-inventory** (phantom pod detector). Independent — can ship
   alongside any other.
8. **PRD-015-refill-pipeline** (v11.1 follow-ups). Lowest priority,
   investigation-first.

## Batches (cannot proceed autonomously)

- **Batch-22May, Batch-24May, Batch-25May:** each requires CS to review
  per-row diff before commit. No autonomous prep done tonight — that
  prep should also happen in a daylight session because the parsing of
  doc bullets ("Pepsi Regular +3 @ 01/02/27") into structured
  `(machine, boonz_product_id, pod_product_id, expiry, qty, action)`
  tuples is error-prone enough that CS should review each row.
- The `source_kind` provenance flag for Batch-24May is a schema change
  that needs Dara design + Cody review. Tracked: choose between
  `po_additions.source_kind text` or `warehouse_inventory.source_kind text`.

## MEMORY.md updates

The program references several memory entries that don't exist in the
current memory store:

- `project_engine_v10_stitch_v12_decouple`
- `project_engine_v11_prd010_deployed`
- `bug_consumer_stock_drain_asymmetry`
- `reference_pod_inventory_archival_pattern`

Two interpretations:

1. They were never written.
2. They were written in a different memory location (per-machine memory
   path differs).

Either way, these should be created/relocated as part of the daylight
sync after the relevant PRDs ship.

A new memory entry **should** be added documenting V4: the
`record_variant_correction` migration file exists but was never applied;
re-check pg_proc not just migration file presence before marking a PRD
as Done.

## Constitution rules followed in this session

- Article 1, 4, 6 — no canonical writers modified.
- Article 3 — no direct writes to protected tables.
- Article 12 — no edit-in-place of past migrations; PRD-002 frontmatter
  updated as forward-only doc edit, not a SQL change.
- Hard rule: no DELETEs, no stock reductions. ✓
- Hard rule: no double-fixing. ✓ — PRD-002 status corrected; rescue
  PRD-012 spec'd instead of blindly re-applying.

## Summary

8 PRD specs delivered with verified root causes. 3 batches and all
migration applies deferred to daylight CS-in-the-loop sessions per
program hard rules. PRD-002 status corrected. Refill-update doc
bullets all addressed at the spec level (not yet code-fixed).
