# PRD-085: Finalize preserve-approved — verify under referee (v2)

Status: PARKED 2026-07-07 (prior art verified live; blocked on referee candidate-capture / branch-data — see EXECUTION-LOG).
Owner: CS. Mode: AUTO with hard gates. Dara verifies, Cody reviews.

## Why

PRD-025 documented the exact defect: `engine_finalize_pod`'s `ON CONFLICT DO UPDATE SET status='draft'` reverted approved rows, breaking stitch ("no approved rows"). It was fixed via the v2 subset-aware finalize. Wave 0 requires this be provably locked, not just believed-fixed — hence a referee-backed regression test rather than a new patch.

## Design (Dara verifies, Cody reviews)

1. **Verify live:** on a branch, approve a subset, re-run `engine_finalize_pod`, confirm approved rows stay `approved` (reproduce the PRD-025 scenario; expect PASS on current prod logic).
2. **If it still reproduces** (regression crept back): apply the minimal guard — exclude `status='approved'` rows from the finalize upsert mutation, and surface engine-wanted changes as `finalize_pending_changes` in the return payload. Otherwise **no code change** — verification + test only.
3. **Add permanent regression:** a T-test in the referee suite asserting finalize never downgrades approved rows; wire into the PRD-076 harness so every future wave runs it.

## Gates

- Engines md5 byte-identical unless the guard is actually needed (then Cody signs). `diff_vs_golden` identical on a no-approval fixture. No change to `approve_*` semantics. BEGIN..ROLLBACK; forward-only.

## T-tests

- T1 approve a row, re-run finalize with a different computed qty ⇒ row stays `approved` (+ pending change surfaced if guard added).
- T2 partially-approved machine ⇒ only draft rows change.
- T3 `diff_vs_golden` identical on no-approval fixture.
- T4 concurrent approve + finalize ⇒ no lost approval.
- T5 regression test registered in the referee suite.

## CLOSE

CHANGELOG; if unchanged, note "verified, no patch needed, regression added"; PRD-085 SHIPPED + EXECUTION-LOG; commit + push. Wave 0c complete ⇒ Wave 0 COMPLETE.
