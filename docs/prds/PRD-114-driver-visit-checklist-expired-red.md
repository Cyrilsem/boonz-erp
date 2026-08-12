# PRD-114 — Dispatch list: "Sanity checks — expiry" category with driver dispositions

**Status:** APPROVED by CS 2026-08-12 (design amended by CS same day) · **Owner:** Stax-class unit,
executable by Claude Code
**Repo:** boonz-erp. Field PWA + one read RPC + one narrow writer. Cody review required
(reads pod_inventory — protected; stock writes ONLY at day-close acknowledge via canonical paths).

## 1. Problem (CS, 2026-08-12)

The refill plan tells the driver what to PUT IN; nothing tells him what to CHECK. Expired and
near-expiry units sit on shelves with no notification in dispatching. CS design (verbatim intent):
keep the SAME STYLE as the dispatch line list — one extra category at the end, "Sanity checks for
expired products", listing every batch expiring within 7 days plus everything already expired, and
the driver marks each row with what he found.

## 2. What exists (reuse)

- `pod_inventory` = the expiry ledger (LAW: expiry truth here and nowhere else; NOT stock/flavor
  identity). Candidate rows: `status='Active' AND coalesce(current_stock,0)>0 AND expiration_date
<= today(Dubai)+7`.
- PRD-113: expired batches are never auto-consumed → the list is stable and truthful.
- PRD-112: `day_close_events` + acknowledge; nothing auto-writes stock. This PRD adds ONE event
  kind and wires acknowledge to existing canonical stock paths.
- Manual write-off flow (archive batch / removal_reason) — stays the ONLY exit for expired stock.

## 3. Design

### 3.1 Read RPC `get_expiry_sanity_checks(p_machine_id)` (SECURITY DEFINER, read-only)

Roles field_staff/warehouse/operator_admin. Returns rows: pod_inventory_id, shelf_code, product
name, qty, expiration_date, and `severity`: `expired` (date < today Dubai) or `expiring`
(today..today+7).

### 3.2 Field PWA — the category

- In the driver's machine view (`/field/packing/[machineId]` + trip line view), AFTER the dispatch
  lines, a final category styled EXACTLY like the other line groups, titled
  **"Sanity checks — expired products"**. Auto-expanded whenever any `expired` row exists.
- **Expired rows: RED** (background tint + `EXPIRED` badge). Driver options per row: **Sold** ·
  **Remove**. (It cannot "exist and stay" — it must leave the shelf, either it already sold or the
  driver pulls it.)
- **Expiring ≤7 days rows: AMBER**. Driver options per row: **Exists** · **Sold** · **Remove** ·
  **Skip**.
- Options render as chips in the row, same interaction style as pack/not-filled outcomes. One tap
  sets the disposition; tap again to change until day-close acknowledge locks it.
- Each disposition writes ONE `day_close_events` row kind=`expiry_check`
  (payload: pod_inventory_id, shelf, product, qty, expiry, severity, outcome, actor). No stock
  writes at tap time. `Skip`/`Exists` are also logged (audit that the check happened).

### 3.3 Day Close (PRD-112 tab) — acknowledge semantics

`expiry_check` rows appear under Changes (red chip for expired). CS acknowledge applies, per row,
via EXISTING canonical paths only:

- **Remove** → batch archived / zeroed with `removal_reason='expired_writeoff'` (existing manual
  write-off path).
- **Sold** → batch closed as sold-through (existing archival pattern, removal_reason
  'sold_through_<date>') — records that revenue already captured it; no WH movement.
- **Exists** → no stock write; stamps a verified-at fact in the event payload.
- **Skip** → no write; row simply closes.
- Re-acknowledge idempotent. Nothing fires without CS's click.

## 4. Hard constraints

1. pod_inventory READ-ONLY except the canonical archival/write-off paths fired at acknowledge.
   Cody reviews the RPC, the event writer registration, and the acknowledge extension.
2. LAW 7 / PRD-113 untouched: no auto-consumption, no auto-write-off.
3. No engine changes, no new cron. v3-compatible (day_close_events shape unchanged, new kind only).
4. Additive UI: packing/pickup/dispatch flows byte-identical when the category is collapsed/empty.
5. Reads pod_inventory directly — NOT the /refill slot-drawer join (known disconnect, not fixed here).

## 5. Acceptance

1. Machine with 1 expired + 2 expiring batches: category renders at list end, red/amber correct,
   expired rows offer only Sold/Remove, amber rows offer Exists/Sold/Remove/Skip.
2. Each tap = exactly one day_close_events row; changing a disposition before acknowledge updates
   the same event, never duplicates.
3. Acknowledge: Remove → batch Inactive expired_writeoff; Sold → batch Inactive sold_through;
   Exists/Skip → no stock change. WH untouched in all four. Re-acknowledge idempotent.
4. Golden fixture on synthetic 2030 data covering all four outcomes end-to-end.
5. run_all green (one-fixture-per-tick runner per PRD-003); build green; merge to main; production
   verified.

## 6. Execution notes for Claude Code

Single-session task, branch `prd-114-visit-checklist`. RUN AFTER the PRD-003 relay exits (shared
golden runner). Backend first, Cody paragraph in the report, then FE. Own migration files only; do
not touch other PRDs' files; no git add -A. Append progress to docs/prds/PRD-114-REPORT.md; final
line exactly `## PRD-114 DONE` (or `## PRD-114 BLOCKED` with the verdict).
