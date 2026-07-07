# MASTER Parking Lot — Refill Brain remediation (all waves)

Single cross-wave blocker log for `MASTER-goal-command.md` and every wave's APPLY-ALL loop.
**Rule:** on any blocker a PRD can't resolve safely (a decision it shouldn't make, a protected change without a Cody verdict, an ambiguous reader, a live caller, non-determinism), append a row here and continue to the next PRD/wave. **Never force.**
This is the canonical parking lot. `docs/prds/PARKING_LOT.md` redirects here.

## Active blockers

| Date       | Wave | PRD     | Blocker                                                                                                                                                                                                                                                                                | Needed to unblock                                                                                                                                                                                                                                                 | Owner / decider | Evidence                                                                                                 |
| ---------- | ---- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- | -------------------------------------------------------------------------------------------------------- |
| 2026-07-07 | 0    | 076     | Supabase preview branches are schema-only (no prod data), so engine-level capture tests (T3 twice, T4 full-fleet, T6 Saturday) can't run meaningfully on a bare branch. Diff-referee half is shipped + green; capture half unproven end-to-end.                                        | PRD-078 golden baseline to seed a known dataset onto the branch (or a decision: capture via BEGIN..ROLLBACK on prod with real data instead of a branch — contradicts the branch-only guard, so needs CS/Dara ruling).                                             | Dara + CS       | create_branch tool contract: "production data will not carry over"; capture on empty branch ⇒ empty plan |
| 2026-07-07 | 0    | 077     | T6 known-debt conservation baseline needs CS agreement before delta mode can block a wave. Gate + proposed baseline delivered; agreement outstanding. Batch check is retrospective-stock sensitive (past plan vs current pickable inflates phantom_batch).                             | CS agrees the accepted violation set (run the freeze INSERT in PRD-077-EXECUTION-LOG). Until then, use `absolute` mode informationally, not as a blocker.                                                                                                         | CS              | conservation_check('2026-07-06')=21, ('2026-07-05')=20, all phantom/oversub, orphan_removal=0            |
| 2026-07-07 | 0    | 078     | Candidate-capture path (T1 re-run determinism, T2 perturb) blocked by data-less branches. golden_v1 frozen from prod is shipped; but diffing a CANDIDATE (engine change) needs the engine run on a branch with data.                                                                   | Program decision (below): restore-fixture-on-branch, rollback-on-prod capture, or frozen-golden-only. Until then the referee is reference-ready but not candidate-capable.                                                                                        | Dara + CS       | golden_v1 run 9eb2d050 frozen (21 rows); create_branch is schema-only                                    |
| 2026-07-07 | 0    | 079-085 | (1) All are protected migrations (*) → require Cody verdict + CS sign-off before ANY prod apply (goal rule E). (2) Their "referee GREEN" precondition needs candidate-capture, blocked by the 076/078 branch-data limit. Loop STOPS here per the goal's protected-gate STOP condition. | (a) Resolve the branch-data program decision so the referee can validate candidates; (b) Cody+CS sign-off per PRD. Reconciliation note: 5 of 6 intents already shipped under prior PRDs (see WAVE0-reconciliation) — CS may VERIFY-only rather than re-implement. | Cody + CS       | goal rule E + STOP condition; WAVE0-reconciliation.md                                                    |

## Anticipated parks — Wave 0 (pre-seeded from the PRDs; resolve early)

| PRD     | Likely blocker                                                                                   | Suggested default                                              | Decider     |
| ------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------- | ----------- |
| PRD-078 | non-determinism on a golden fixture (blocks strict-equality gate)                                | tolerance mode now; flag for a Wave 5 hardening PRD            | Dara        |
| PRD-079 | `engine_add_pod.wh_avail` output shifts when the WH predicate is unified (T6)                    | do NOT ship; investigate historical divergence first           | Dara + CS   |
| PRD-080 | dedicated `wh_reservation` table vs overloading `reserved_for_machine_id`; reservation TTL value | dedicated table; TTL = real pick-window from ops               | Dara / Ops  |
| PRD-081 | un-migrated FE/n8n call sites still writing `packed=true` directly                               | stay in WARN; migrate each before ENFORCE                      | Stax        |
| PRD-082 | ambiguous `quantity` readers (planned vs packed); legacy rows w/o `original_quantity`            | keep `qty_split_v1` OFF until repointed; manual-review list    | Stax + CS   |
| PRD-083 | live caller of a Family-B object in grace; uncertain B-only vs shared                            | never drop under a live caller/uncertainty; migrate/park first | Cody + Dara |
| PRD-084 | intended engine swap vs real drift; incomplete multi-SKU allowlist                               | stay advisory; extend allowlist as found                       | CS          |

## Program-level decisions pending

| Item                             | Decision needed                                                                    | Owner |
| -------------------------------- | ---------------------------------------------------------------------------------- | ----- |
| Known-debt conservation baseline | agree the baseline violation set (PRD-077 T6) before the delta gate blocks         | CS    |
| Waves 1–5 PRD authoring          | author each wave's PRDs before its APPLY-ALL loop runs (loop HARD-STOPs otherwise) | CS    |

## Resolved

| Date | Wave | PRD | Resolution |
| ---- | ---- | --- | ---------- |
|      |      |     |            |
