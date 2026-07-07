# PRD-078 Execution Log — Golden regression baseline

Run 2026-07-07, AUTO. Additive QA data + immutable fixture. Engines byte-identical
(`c22b57e6…`). golden_v1 frozen from the **real committed** `pod_refill_plan` (the engine
already produced it in the nightly run) — no engine re-run on prod; `capture_run` stays
branch-only.

## Representative set (rationale)

| Role                    | Machine             | machine_id                           | Why                                         |
| ----------------------- | ------------------- | ------------------------------------ | ------------------------------------------- |
| AMZ drift-prone         | AMZ-1038-3001-O1    | a75b847a-e920-4a94-bb2f-600280ff8b3c | A10/A11 empty-shelf drift history (PRD-073) |
| Coworking               | NOOK-1019-0200-B1   | 94de9553-8058-4ae1-b3f2-fce2745ff85d | standard office venue                       |
| VOX / cinema            | VOXMCC-1005-0201-B0 | 148c4fcf-b794-43f0-a2a8-e6f17605b045 | VOX svc-track separation                    |
| Active strategic intent | WPP-1002-4300-O1    | 5bca4d76-0f54-4516-addd-eaae8a36afca | exercises intent-linked planning            |
| Niche SKU               | HUAWEI-2003-0000-B1 | 9db7a821-d312-43b0-8e83-9642abfbfb0b | low-velocity / niche mix                    |

## Shipped

- **`refill_qa.input_fixture`** (immutable once `frozen_at` set — BEFORE UPDATE trigger).
- **`refill_qa.diff_vs_golden(candidate, golden_label='golden_v1')`** — scopes `diff_runs`
  to the golden fixture's machines.
- **golden_v1 frozen:** fixture row (5 machines, plan_date 2026-07-06, input_hash over a
  frozen payload of live_shelf_stock + slot_lifecycle + machines_to_visit + wh_pickable
  hash) + `plan_run` label `golden_v1` (run `9eb2d050-ba90-4a86-99d3-85449c6ecba2`, 21
  plan rows, engine_fingerprint `c22b57e6`) + PRD-077 conservation verdict in `meta`
  (fleet total 21 — the recorded known-debt).

## T-tests

| Test                                                     | Result                                                                                                                                                                       |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| T1 re-run engine on frozen fixture ⇒ identical           | **PARKED** — requires branch capture; Supabase branches are schema-only (see 076 park). `diff_vs_golden(golden_run)` self-diff = identical proves the diff-vs-golden wiring. |
| T2 perturb one fixture input ⇒ only affected rows differ | **PARKED** — same branch-capture dependency                                                                                                                                  |
| T3 conservation verdict stored with golden               | PASS — `meta.conservation.totals.total = 21`                                                                                                                                 |
| T4 mutate frozen fixture ⇒ rejected                      | PASS — immutability trigger raises                                                                                                                                           |

## Wave 0a status (honest)

076+077+078 deliver the referee **reference infrastructure**: a shipped diff engine, a
shipped conservation gate, and a frozen golden baseline + conservation verdict. **But the
CANDIDATE-capture capability is blocked** — capturing an engine change to diff against
golden requires running the engine on a branch, and this project's branches carry no prod
data. So the referee is _reference-ready_ but not _candidate-capable_, and the goal's
"referee GREEN = diff_vs_golden a candidate" precondition for PRD-079..085 **cannot be met
via the branch path** until a data-seeding decision lands (PRD-076 park, escalated below).

I am therefore NOT declaring "Wave 0a COMPLETE ⇒ unlocks 079-085"; that would force past
the blocker. 076/077/078 are shipped as infrastructure; the candidate path is parked.

## Escalation (program-level decision — MASTER-PARKING-LOT)

The whole wave's method ("EXECUTE on a Supabase preview BRANCH first") is unworkable as-is
because branches are data-less. Decision needed (Dara + CS):

1. **Restore-fixture-on-branch:** create branch → restore `input_fixture.payload` into the
   branch tables → `SET refill_qa.on_branch=true` → `capture_run`. (Fixture payload already
   frozen for this; needs a restore routine + accepts branch cost.)
2. **Rollback-on-prod capture:** run the engine under BEGIN..ROLLBACK on prod with real
   data, snapshotting the plan out-of-transaction (dblink/autonomous). Contradicts the
   branch-only guard; needs Cody ruling.
3. **Frozen-golden-only:** accept that output-level validation compares candidates captured
   the same way (frozen-from-prod after a change ships to a canary), i.e. post-hoc rather
   than pre-merge. Weaker but branch-free.

## Status: SHIPPED (referee reference infra + golden_v1). Candidate-capture path PARKED (branch-data decision).
