# MASTER Parking Lot — Refill Brain remediation (all waves)

Single cross-wave blocker log for `MASTER-goal-command.md` and every wave's APPLY-ALL loop.
**Rule:** on any blocker a PRD can't resolve safely (a decision it shouldn't make, a protected change without a Cody verdict, an ambiguous reader, a live caller, non-determinism), append a row here and continue to the next PRD/wave. **Never force.**
This is the canonical parking lot. `docs/prds/PARKING_LOT.md` redirects here.

## Active blockers

| Date                              | Wave | PRD | Blocker                                                                                                                                                                                                                                         | Needed to unblock                                                                                                                                                                                                     | Owner / decider | Evidence                                                                                                 |
| --------------------------------- | ---- | --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- | -------------------------------------------------------------------------------------------------------- |
| 2026-07-07                        | 0    | 076 | Supabase preview branches are schema-only (no prod data), so engine-level capture tests (T3 twice, T4 full-fleet, T6 Saturday) can't run meaningfully on a bare branch. Diff-referee half is shipped + green; capture half unproven end-to-end. | PRD-078 golden baseline to seed a known dataset onto the branch (or a decision: capture via BEGIN..ROLLBACK on prod with real data instead of a branch — contradicts the branch-only guard, so needs CS/Dara ruling). | Dara + CS       | create_branch tool contract: "production data will not carry over"; capture on empty branch ⇒ empty plan |
| _(none yet — Wave 0 not started)_ |      |     |                                                                                                                                                                                                                                                 |                                                                                                                                                                                                                       |                 |                                                                                                          |

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
