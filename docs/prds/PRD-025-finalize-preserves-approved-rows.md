# PRD-025: engine_finalize_pod Must Preserve Approved Rows ("Stitch failed: no approved rows")

**Date:** 2026-06-12
**Status:** Draft, awaiting CS approval
**Severity:** High. Breaks the FE Commit flow intermittently; operators see "✗ Stitch failed: no approved rows" and retry blind.
**Owner:** assistant (RPC patch) → Cody (canonical-writer review). Optional FE ordering fix: Stax.

---

## 1. Problem

`stitch_pod_to_boonz` raises `no approved rows` when zero `pod_refill_plan` rows have `status='approved'` for the plan date. This fires whenever `engine_finalize_pod` runs AFTER `approve_pod_refill_plan`, because finalize's upsert unconditionally resets status:

```sql
ON CONFLICT (...) DO UPDATE
  SET ..., status = 'draft', updated_at = now()
```

Every approved row touched by finalize silently reverts to draft. A stitch fired next finds nothing approved and aborts.

## 2. Evidence (write_audit_log, night of 2026-06-11/12)

- 01:53:30.2 Dubai: `approve_pod_refill_plan` (rows → approved)
- 01:53:30.7: `engine_finalize_pod` (approved rows reset → draft)
- subsequent stitch → "no approved rows" error seen by CS in the FE
- 02:10:24: finalize, 02:11:03: approve, 02:11:12: stitch → success (correct order)

This is the known subset-commit gotcha (feedback 2026-05-31) now biting the main Commit path, not just subset commits.

## 3. Fix options

**Option A (recommended): make finalize idempotent w.r.t. approval.**
In `engine_finalize_pod`'s upsert, preserve status when the incumbent row is approved and materially unchanged:

```sql
ON CONFLICT (...) DO UPDATE
  SET qty = EXCLUDED.qty, reasoning = EXCLUDED.reasoning, decision = EXCLUDED.decision,
      linked_refill_pk = EXCLUDED.linked_refill_pk, linked_swap_id = EXCLUDED.linked_swap_id,
      status = CASE
                 WHEN pod_refill_plan.status = 'approved'
                  AND pod_refill_plan.qty = EXCLUDED.qty
                  AND pod_refill_plan.action = EXCLUDED.action
                 THEN 'approved'          -- approval survives a no-op re-finalize
                 ELSE 'draft'             -- material change requires re-approval
               END,
      updated_at = now()
```

Approval is only invalidated when the engine actually changed the row. The ordering bug becomes impossible for unchanged rows, and changed rows correctly demand re-approval.

**Option B (complementary, FE): Commit always runs finalize → approve → stitch in that order.** Cheap insurance even with Option A; ship both.

## 4. Constitutional notes

- `engine_finalize_pod` is a canonical writer on `pod_refill_plan`: mandatory Cody review (Hard Rule 6).
- Forward-only migration `phaseF_finalize_preserve_approved`, registry + changelog updates.
- Within-24h second rewrite of the same function requires CS green light (Hard Rule 10); coordinate with any other pending finalize change.

## 5. Verification

1. Approve a plan, re-run finalize with no engine changes: all approved rows still approved.
2. Approve, then change one pod_refills row and re-run finalize: only the changed row reverts to draft.
3. Full FE Commit on a fresh draft: succeeds with zero "no approved rows" errors in 5 consecutive runs.
4. Subset-commit regression: finalize → subset approve → stitch works without un-approving the subset.

## 6. Acceptance criteria

- [x] Option A live with Cody sign-off (Articles 1, 4, 5, 8, 12), registries updated. Migration `phaseF_finalize_preserve_approved` applied 2026-06-12; v13 rollback md5 `ec8ace36cc2b1a6527bc0eb8ea185b6d`; 1-arg wrapper untouched. Rolled-back regression on 06-13: case 1 no-op re-finalize keeps 133/133 approved (0 drafts), case 2 one mutated qty -> exactly 1 draft / 132 approved, case 4 subset re-finalize keeps 24/24. The "no approved rows" ordering race is unreproducible for unchanged rows.
- [x] Option B ticketed to Stax via action_tracker (FE Commit always orders finalize -> approve -> stitch; cheap insurance on top of Option A).
- [ ] One week of FE Commits with zero occurrences of the error. (Accrues post-deploy; check ~2026-06-19.)
