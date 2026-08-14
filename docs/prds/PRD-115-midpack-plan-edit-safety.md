# PRD-115 — Mid-pack plan edits are safe: no resurrection, one refresh banner, honest validation

**Status:** APPROVED by CS 2026-08-14 (live incident same day) · **Owner:** Stax-class unit,
executable by Claude Code
**Repo:** boonz-erp. Backend (2 writers + push guard) + /field packing FE. Cody review required
(touches refill_dispatching writers + push_plan_to_dispatch — protected).

## 1. Problem (live incident, NISSAN-0804, 2026-08-14 ~14:27)

CS re-scoped a shelf three times (Al Ain → Coke Zero → Dubai Popcorn → Hunter) while the packer
was actively packing the machine. Result, all reproduced live:

1. **Resurrection:** `remove_dispatch_row` sets `include=false`, but the linked
   `refill_plan_output` row stays `approved`; the NEXT `approve_refill_plan`/`push_plan_to_dispatch`
   for the machine re-created the removed dispatch rows. Removed popcorn came back twice.
2. **Warning wall:** every subsequent edit surfaced per-line "already packed — refresh to edit"
   noise (19 warnings on one screen) instead of one actionable state.
3. **Opaque validation:** "Activia Mix & Go: Pick total (6) exceeds planned quantity (3)" — the
   packer had (reasonably) counted the same-pod Remove leg's 3 units into her pick. The message
   neither says which line nor that Remove legs don't count toward pick.
4. **Stuck confirm state:** after ops unpacked 2 rows post-confirm, the machine showed BOTH
   "already packed for 2026-08-14" AND "Finish - 1 to resolve", with destructive
   "Override & re-pack" as the only prominent exit. Ops had to hand-close the line and re-run
   `confirm_machine_packed` from SQL.

## 2. Fixes

### 2.1 Backend — tombstones (the resurrection killer)

- `remove_dispatch_row` additionally stamps the linked `refill_plan_output` row:
  `operator_status='rejected'`, comment appended `removed_at_dispatch_by <actor> <ts>`.
  (Single transaction; if no rpo link, no-op.)
- `push_plan_to_dispatch` never creates a dispatch row for an rpo row whose id appears in a
  prior operator-removed dispatch row for the same plan_date (tombstone check), regardless of
  operator_status. Belt and braces.

### 2.2 Backend — confirm-state transition

- New lightweight state on `v_machine_pack_status` derivation: if `pack_confirmed` AND any
  included line is unpacked/unresolved → state `needs_reconfirm` (not "already packed", not
  fresh). `confirm_machine_packed` re-run closes it (already idempotent).

### 2.3 FE — /field packing

- Replace the per-line warning wall with ONE banner: "Plan changed while you were packing —
  N lines updated. [Refresh]". Individual "already packed — refresh to edit" strings removed.
- `needs_reconfirm`: banner "Plan changed after confirm — M lines to finish", primary CTA is
  **Finish remaining**, and "Override & re-pack" moves behind a confirm dialog labelled
  destructive ("returns ALL packed stock to warehouse").
- Pick-qty validation names the line and the rule: "This line plans 3 (Remove legs are counted
  separately — do not add them to your pick)." Same-pod Remove legs render adjacent with a
  "counts separately" chip.

## 3. Hard constraints

- Cody reviews both writer changes + the push guard. No engine changes. Guards
  (duplicate-unstarted, packed-row protection, conservation) byte-identical.
- PRD-112 substitution RPC and PRD-114 sanity checks untouched.
- Tombstone is additive metadata; no schema change beyond what a comment/status carries today.
  If a real column is warranted, Dara designs it first.

## 4. Acceptance

1. Fixture: remove a dispatch row mid-plan → re-approve the machine → row does NOT come back;
   rpo row reads rejected with the removal stamp.
2. Fixture: confirm machine → unpack one line → state reads needs_reconfirm →
   confirm_machine_packed closes it. "already packed"+unresolved combination is unrepresentable.
3. FE: plan edit during pack renders exactly one refresh banner; zero per-line warning strings.
4. Pick-total validation message includes line name + Remove-leg rule (string asserted in test).
5. golden run_all green (one-fixture-per-tick runner); build green; merge to main; production
   verified.

## 5. Execution notes for Claude Code

Single-session task, branch `prd-115-midpack-safety`. Backend first (Cody paragraph in report),
then FE. Own migration files only; no git add -A; other PRDs' files untouched. Append progress to
docs/prds/PRD-115-REPORT.md; final line exactly `## PRD-115 DONE` (or `## PRD-115 BLOCKED`).
