# Overnight Report -- ONE LOOP, 2026-09-15

Branch: `overnight-2026-09-15-prd123-126` (off `prd122-lane-grain-priority`, itself 7 commits
ahead of unpushed `main`). Fourteen migrations applied and committed, one per logical change.
Full one-line-per-migration index: `CHANGELOG.md`. Full requirement-by-requirement status:
`IMPLEMENTATION-CHECKLIST-2026-09-15.md`. Every judgment call and its reasoning:
`DECISIONS-2026-09-15.md` (D-001 through D-009).

This run covered Phases 1-7 of the ONE-LOOP prompt, with the exceptions named throughout this
report and the checklist. Phases 8-11 were not attempted and are explicitly left open. This
report does not round up: every "done" below has a proof line; every gap is named.

## Why this ran unattended at all

The ONE-LOOP prompt voided the "STOP HERE. Wait for CS." lines embedded in the PRD-125/126
goal-command files for this session specifically, and named its own risk controls in their
place: a canary fingerprint on the live packed 2026-09-15 plan, mandatory rollback-and-reprove
on any canary break, a running decisions log, dry-run defaults on every writer, and an explicit
replacement for the one PRD-125 gate (D5, automatic build) whose removal the STOP line existed
to prevent. Phase 6 of this same prompt keeps that exact gate. Given the PRDs were authored by
CS the night before, an identical earlier draft plus the final goal-command file were already
in the repo, and the precedence and risk-mitigation design were internally consistent, this was
treated as genuine advance authorization rather than blindly followed or refused. That
reasoning is recorded in full at the top of `DECISIONS-2026-09-15.md`.

## Canary: the 2026-09-15 plan

Fingerprint: `md5(string_agg(dispatch_id::text || quantity::text || shelf_id::text ||
coalesce(include,true)::text, ',' order by dispatch_id))` over
`refill_dispatching where dispatch_date='2026-09-15'`.

Captured before Phase 1. Re-verified after every phase through Phase 7. **Result: identical
every time. Zero drift. Not one row of the live packed plan changed.** (D-001 fixed the initial
query, which referenced a non-existent `id` column -- the real PK is `dispatch_id`.)

## Per-phase summary

### Phase 1 -- WEIMI is the shelf truth

Fixed the Remove-path bug in both `push_plan_to_dispatch` and `add_dispatch_row` where the
lot's shelf could silently win over the plan's shelf. Added `weimi_shelf_now` as the new
canonical live-shelf read and `align_pod_lots_to_weimi` (dry-run by default, nightly cron) to
keep `pod_inventory` lots aligned to WEIMI. Found and fixed a self-introduced bug before commit:
in dry-run mode, the first draft of `align_pod_lots_to_weimi` could propose the same lot as the
move target for multiple shelves sharing a product, because it re-queried "an Active lot
elsewhere" fresh on every shelf iteration without excluding lots already claimed earlier in the
same pass. Fixed with an in-pass claimed-lot array. Named proof machines could not be replayed
against live 2026-09-15 data (their rows are already rejected/mismatched); proved instead via a
synthetic same-shape scenario on 2026-09-16, same real machines/shelves/products.

### Phase 2 -- stock at the supplying warehouse

Added `wh_available_for`, switched `engine_add_pod` and `find_substitutes_for_shelf` to it, and
threaded `source_kind` (wh/venue/m2m) through every `push_plan_to_dispatch` write path. Two
CHECK constraints didn't allow `'venue'` as a value and had to be extended; discovered by two
failed UPDATE attempts, not by reading the constraint defs first.

### Phase 3 -- the gate checks the engine's rules

Rewrote `validate_refill_plan` to exactly the five named gates (G3/G5/G7/G8/G10), removed
G1/G2/G4/G6/G9 as instructed, and made `approve_refill_plan`'s waiver argument functionally
inert. Caught a genuine self-introduced bug: the naive G8 rewrite reused `wh_available_for`'s
pin-subtraction logic, which counts the very dispatch rows being validated as pins against
themselves, so validating a plan made its own gate fail more often, not less (violation count
went 7 -> 25 on the first attempt, an increase that should never happen from a correctness fix).
Root-caused and fixed by having G8 read raw warehouse stock, no pins, for validation purposes
specifically. `engine_add_pod`, `find_substitutes_for_shelf`, and `confirm_and_build` correctly
keep pin-aware `wh_available_for`. Two items (G2/G4/G9 as `get_pod_refill_draft` booleans, and
D1's literal ceiling inside `engine_add_pod`'s scoring model) were deferred as too risky to
rewrite under time pressure; a `hero_velocity_floor` param was added to `refill_policy_params`
so the ceiling work doesn't need a further migration when it's picked back up.

### Phase 4 -- substitution rules as data

New `substitution_rules` table (RLS + explicit S-308 revoke from `authenticated`), seeded for
Evian, Hunter, the snack chain, scarce-stock, and expired-on-shelf. `find_substitutes_for_shelf`
now reads it instead of the old ad-hoc correlation logic. Enforcement of the scarce-stock/
expired-on-shelf rules inside `engine_add_pod`, the `exceptions` array on
`get_pod_refill_draft`, and an FE settings table were all deferred (documented in PRD-125's own
Phase 4 note as later work). "Freakin Roasted" has no `pod_products` row and was left out of
the seed rather than guessed at.

### Phase 5 -- picker brain (PRD-126)

Added the full AED-denominated scoring model to `v_machine_priority`:
`s_runout_aed`, `s_gap_aed`, `expiry_penalty_aed`, `stale_penalty_aed`, `p_score_aed`,
`p_tier_aed`, `daily_revenue_aed`. Set `horizon_days=3` (it had drifted to 2 from an earlier
PRD and had to be explicitly overwritten) and the two AED thresholds. Verified A1, A2, A4 of
PRD-126's acceptance criteria pass live. **A3, A5, A6, A7 could not be honestly verified**: a
genuine fleet-wide data gap exists in `v_current_price` -- 19,686 of 119,136 rows (16.5%) have
`effective_price_aed IS NULL`, including ACTIVATEMCC-1037's own highest-velocity lane
(Aquafina). This is a pricing-data completeness problem, not a scoring-logic bug, and it
materially understates AED revenue-at-risk for every affected lane. It should be treated as a
standalone data-quality item, not something to guess a value for.

### Phase 6 -- build on confirm, reliably (replaces PRD-125 D5)

Built `confirm_and_build(plan_date, machine_names, cars)`: sets the pick list to exactly the
given machines (drops the rest, confirms/creates as needed), assigns cars by
cluster-then-p_score_aed, and runs the existing build core. `approve_pod_refill_plan` now also
runs `stitch_pod_to_boonz` and `push_plan_to_dispatch` per machine inside the same call.
`cron13_build_or_alert_v3` replaces the old missing-draft alert with one that fires only when
nothing is confirmed. **CS keeps the manual gate: there is still no automatic 20:00 build.**
Verified live in a rolled-back transaction on 2026-09-16 for AMZ-1029 + NISSAN-0804: 29 refills
inserted, scoped to exactly those two machines, 0 unintended drops, `stage_2a` measured
15968ms against the function's 120s timeout. R5's full cluster-affinity car-fill algorithm was
simplified to cluster-then-score; the richer version was not attempted given time.

### Phase 7 -- remaining PRD-124 items (partial)

Shipped: `mark_dispatched` (item 35, was entirely missing from
`enforce_canonical_dispatch_write`'s allowlist -- every call would have logged a bypass
violation even though nothing was actually blocked), `source_kind` mapping (item 38, delivered
as part of Phase 2), and `CHANGELOG.md` (item 9). Found already-fixed and needing no migration:
`bind_dispatch_fefo`'s temp-table lifetime (item 39) and the four pod_inventory-decides-
placement functions (a separate class of bug PRD-124 named). Genuinely blocked: the 76 junk
2029+ dispatch rows cannot be cleared with `cancel_dispatch_line` as instructed -- the RPC
requires `dispatched=true` (all 76 are false) and explicitly refuses rows with a warehouse pin
attached, by the function's own design ("Use a reverse-cancellation RPC (not yet
implemented)"). Building an ad-hoc pin-release writer overnight, without Dara/Cody review, was
judged too risky. The remaining seven Phase 7 items are all frontend-only (SnapshotTab.tsx,
Save-notice UX, /refill filter, procurement query, migration-alert cron, banner text) and were
not attempted -- no FE code was touched this session.

### Phases 8-11

Not started. Phase 8 (PRD-123 return splits) got as far as capturing a live baseline
(`v_wm_confirmations` = 1, not the 11 PRD-123's text assumed -- time had passed since the PRD
was written) before this run's time budget ran out. Phases 9 (docs), 10 (full rolled-back
end-to-end day), and 11 (frontend build/typecheck/lint/deploy) were not touched at all.

## PRD-124 item table (this session's slice)

| #            | Item                                                | Status                                                              |
| ------------ | --------------------------------------------------- | ------------------------------------------------------------------- |
| 35           | `mark_dispatched` RPC                               | DONE -- migration `20260915001400`                                  |
| 38           | `source_kind` mapping at push                       | DONE -- migration `20260915000700`                                  |
| 39           | `_bind_tally` temp-table lifetime                   | SUPERSEDED -- already `ON COMMIT DROP` live, no bug found           |
| (unnumbered) | pod_inventory-decides-placement class (4 functions) | SUPERSEDED -- all 4 already compliant                               |
| (junk rows)  | 76 stale 2029+ dispatch rows                        | OPEN -- `cancel_dispatch_line` precondition mismatch, needs new RPC |
| 2            | `SnapshotTab.tsx` -> `get_machine_health_cached`    | OPEN -- FE, not attempted                                           |
| 3            | Save-notice scroll+disable                          | OPEN -- FE, not attempted                                           |
| 6            | `/refill` `cs_added` filter check                   | OPEN -- FE, not attempted                                           |
| 7            | procurement count/list single-query                 | OPEN -- not attempted                                               |
| 8            | migration-window alert cron + reconciliation        | OPEN -- not attempted                                               |
| 9            | `CHANGELOG.md`                                      | DONE -- this session, repo root                                     |
| 10           | `StartInventorySessionBar.tsx` banner text          | OPEN -- FE, not attempted                                           |

(This table covers only the items named in this session's Phase 7 scope, not the full
nineteen-item PRD-124 backlog, most of which was closed in earlier sessions before this run.)

## Decisions log contents (`DECISIONS-2026-09-15.md`)

- D-001: canary PK fix (`dispatch_id`, not `id`).
- D-002: used `'dispatch'` as `validate_refill_plan`'s real regression surface, since
  `'plan_output'` is vacuous for 09-12/09-15 (both 100% approved/rejected already).
- D-003: `v_wm_confirmations` live baseline is 1, not PRD-123's stated 11.
- D-004: `v_live_shelf_stock` left untouched, already WEIMI-only.
- D-004b: `bind_dispatch_fefo`'s described bug does not exist live.
- D-005: four pod_inventory-decides-placement functions already compliant.
- D-006: Phase 1 named-proof machines replayed synthetically instead of on live rows.
- D-006b: G2/G4/G9 booleans and D1's literal ceiling deferred, `hero_velocity_floor` param
  added for later.
- D-007: Phase 4 enforcement wiring, exceptions array, FE settings table, and "Freakin
  Roasted" all deferred/excluded with reasons.
- D-008: `horizon_days` overwrite from 2 to 3; redundant `cooldown_days_v126` column added
  then dropped before commit.
- D-009: the 76 junk rows cannot be cleared with the existing RPC; needs a new one.

## Timing (where measured)

| Operation                      | Machines                  | Time                                  |
| ------------------------------ | ------------------------- | ------------------------------------- |
| `confirm_and_build` `stage_2a` | 2 (AMZ-1029, NISSAN-0804) | 15968ms                               |
| `confirm_and_build` full call  | 2                         | well under the 120s statement timeout |

No fleet-wide timing run was performed (that belongs to Phase 10, not attempted).

## Git

Branch `overnight-2026-09-15-prd123-126`, 14 migration commits (`prd12x p1` through `p7`,
prefixed by phase), each with its own `git add` + `git commit` (kept separate and terse after
the commit-message classifier rejected longer/HEREDOC messages three times this session). Plus
this report, the checklist, `CHANGELOG.md`, and `DECISIONS-2026-09-15.md`. Not pushed to a
remote; not merged; not deployed. No frontend commit exists this session.

## Note for CS (5 lines)

Backend is solid through Phase 7 with the exceptions listed above; canary never moved.
Two real gaps need your call, not more engineering: the 16.5% AED price-data hole (blocks
PRD-126 A3/A5-A7) and the 76 junk 2029+ dispatch rows (needs a new reverse-cancellation RPC,
Dara/Cody review first). Phases 8-11 (return splits, docs, full e2e day, FE deploy) are
untouched -- next session should start there, in that order. Nothing was pushed or deployed;
this branch is safe to review before merging.

## Final action

One `monitoring_alerts` row will be written now (source `overnight_2026_09_15`, severity
`info`), summarizing this run, as the closing action of Phase 12.
