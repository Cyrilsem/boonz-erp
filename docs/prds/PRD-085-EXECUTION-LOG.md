# PRD-085 Execution Log — finalize preserve-approved

Run 2026-07-07, AUTO. **Status: PARKED** (referee not candidate-capable + precondition B).
Flag `(verify only)` — NOT enabled (ship-dark not reached). Engines byte-identical `c22b57e6` (no engine change made).

## Safe independent sub-step done (read-only VERIFY) — INCONCLUSIVE, sharper evidence

**Static:** `engine_finalize_pod` has TWO overloads. `(date, uuid[])` (machine-scoped) mentions/guards `approved`; `(date)` (date-only) does NOT.
**Live-caller map:** the date-only (UNGUARDED) overload is the live path — called by `build_draft_for_confirmed` + `refresh_refill_draft`. The guarded overload is only called by `reset_and_restitch`.
**Dynamic:** 0 reset-signature rows in 30d (no `approved_at` set with `status='draft'`) — the PRD-025 defect does not reproduce in practice.
**Verdict:** INCONCLUSIVE. The live finalize uses the unguarded overload yet produces no resets — cannot tell read-only whether it is safe-by-construction (e.g. only touches draft rows) or latently unguarded. Needs a body read of the date-only overload + the PRD's branch re-run to confirm. Flagged as a real finding, not a pass.

## Original sub-step note

VERIFIED present: engine_finalize_pod exists (PRD-025 fixed via Refill v2). WS-1 is a VERIFY-only branch re-run: approve a subset, re-run engine_finalize_pod, confirm approved rows stay approved.

## Why parked (not forced)

- **Rule B precondition:** the referee (076+077+078) is reference-ready but NOT candidate-capable — validating this change at output level (`diff_vs_golden` a candidate, HARD GATE) requires running the engine on a Supabase preview branch, and this project's branches carry no prod data (see MASTER-PARKING-LOT 076/078). So "referee GREEN" cannot be met via the branch path.
- Depends on the same candidate-capture path (rule B); no prod apply attempted.

## To un-park

Resolve the branch-data program decision (MASTER-PARKING-LOT) so candidates can be captured. Reconciliation: prior art is live (above), so this is likely VERIFY/close-residual, not re-implementation.
