# Validation Report — Amendable committed plans (PRD-018)

_Generated: 2026-06-01_

## Verdict

**Strong, with a hard scoping caveat.**

The core idea (a committed refill plan must be amendable without a full rebuild) holds up: it is a real, recurring, painkiller-grade problem that just cost a multi-hour workaround and nearly shipped an empty plan to drivers. But most of the 2026-06-01 damage traces to **two** defects (non-transactional commit and the missing reverse status edge), not the full ten. Build those first. Treat RELOCATE, the inject_swap rewrite, and the pre-pickup variant editor as data-gated, not assumed.

## Scorecard

| Area              | Score | Read                                                                                                                                       |
| ----------------- | ----: | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Pain intensity    |   4/5 | One failed commit + 4 punted edits + ~2h workaround in a single routine session; nearly shipped 0 lines to drivers.                        |
| Buyer clarity     |   5/5 | The user is CS (operator) plus the field/packing team. Zero ambiguity about who feels it.                                                  |
| Urgency           |   3/5 | Workarounds exist (FE edits, reset_and_restitch), so it is not blocking daily ops, but it re-bites on every launch or same-day correction. |
| Differentiation   |   4/5 | `reopen_pod_refill_rows` is genuinely absent today; nothing else provides a non-destructive reverse edge.                                  |
| Speed to validate |   5/5 | Instrument post-commit edits + ship Phase 1 in days, not weeks. CS owns the whole stack.                                                   |
| Founder advantage |   5/5 | CS controls schema (Dara), constitution (Cody), FE/orchestration (Stax). Can ship and measure immediately.                                 |

## Core Assumption

Operators amend already-committed plans (launch placements, variant fixes, same-day corrections) often enough, and the failure modes are damaging enough, that a gated reopen plus an atomic commit pays for itself versus living with FE-only edits and occasional destructive resets.

## Fatal Flaws

| Risk                                                                 | Severity | Why It Matters                                                                                                                                                                                               | Fast Test                                                                                                                |
| -------------------------------------------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| Over-build: the full 10-defect layer is solved by 2 fixes            | High     | ~90% of the 2026-06-01 pain was the non-atomic commit (R-B1) plus no reopen edge (R-A1). RELOCATE, inject_swap rewrite, and pre-pickup variant editor may be low-ROI gold-plating.                           | Count, over the last 30 days, how many days had a post-commit edit or a failed commit, and which defect family each hit. |
| The real fix may be "amend only in the FE, never the chat conductor" | Medium   | Most blocks (auth on vox tag, inject_swap quirks, post-pickup product lock) only bit because edits ran headless through RPCs. In the authenticated FE, 3 of the 4 punted items are already doable post-load. | For each of the 4 punted edits, confirm whether the FE (loaded, authenticated) handles it today with no new RPC.         |
| Constitution cascade risk                                            | Medium   | New reverse status transitions + a RELOCATE enum + new canonical writers on pod_refill_plan are exactly the surface that produced the 2026-05-19 v4 to v7 engine cascade. Each new writer is risk.           | Cody pre-read on just `reopen_pod_refill_rows` + `commit_refill_plan` before any other scope is greenlit.                |

## Problem Reality

- **Pain:** Real and felt today. A routine 6-machine route with one launch placement produced a silent failed commit, two reverted manual edits, four corrections punted to the FE, and a long manual recovery. Recurs on every launch and most same-day corrections (weekly-ish cadence).
- **Early adopter:** CS, operating the daily refill flow, plus the field/packing team who see the downstream symptoms (dashes, wrong variants, an empty dispatch that the banner called "committed").
- **Vitamin or painkiller:** Painkiller for the atomic-commit and reopen pieces (they prevent shipped-wrong and unrecoverable states). Vitamin for RELOCATE and the inject_swap rewrite (genuinely nicer, not bleeding).

## Competition

- **Current behavior:** Edit in the FE after load; for stuck states, `reset_and_restitch` (destructive, re-derives from pod_refills) or just live with it; or manual RPC surgery via the conductor.
- **Real enemy:** The FE Commit chain's non-atomicity and the one-directional status machine. Secondary enemy: the habit of doing live edits through the chat conductor, where auth and tooling are weaker than the FE.
- **Differentiation needed:** A gated, non-destructive reopen that lets engine output and hand-made rows coexist through a correction. That is the one capability neither the FE nor reset provides today.

## First Proof (adapted from "first 10 customers": internal tool, single operator)

1. **Instrument the problem.** Log every post-commit edit and every commit failure for two weeks. This sizes the assumption before more is built. Where the data lives: pod_refill_plan_audit + refill_dispatching_edit_log already exist; add a commit-outcome log.
2. **Ship Phase 1** (reopen + transactional commit + truthful banner) and run the next 5 routes through it. Success = zero phantom-stitched states and no edit punted to a workaround.
3. **Watch the field team.** Success = packing stops reporting dashes / out-of-stock variants on the lines Phase 1 touches.

## MVP

- **Build:** `reopen_pod_refill_rows` (R-A1) + transactional `commit_refill_plan` (R-B1) + truthful banner (R-B2). That trio is the painkiller.
- **Cut (for now):** RELOCATE action, inject_swap retire/rewrite, pre-pickup variant editor, unique-index/upsert refactor. Defer until the instrumentation proves they recur.
- **2-week test:** Ship Phase 1, instrument, measure clean-commit rate and count of FE-punted edits before vs after. If post-commit edits turn out rare (say under 1 per week) and commits stop failing, the rest of PRD-018 is deprioritized, not built.

## Edits Applied to product-idea.md

Created `docs/product-idea.md` is not applicable: this is a direct validation run against an existing PRD (PRD-018), not an Idea-pipeline candidate. The sharpened direction is captured here and folded back into PRD-018's phasing (Phase 1 is already the recommended cut).

## Next Step

Lock scope to Phase 1 (reopen + atomic commit + truthful banner), hand `reopen_pod_refill_rows` and `commit_refill_plan` to Cody for a pre-read, and instrument post-commit edits in parallel to data-gate Phases 2 and 3. Then `/plaid` (Plan) only if Phase 1 proves the recurring need.
