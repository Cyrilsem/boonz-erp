# PRD-076 Execution Log — Refill shadow-diff harness (the referee)

Run 2026-07-07, AUTO. Non-protected, additive QA infra. Engines untouched:
fingerprint `c22b57e6cb095c38858f1f73803c640d` (md5 over pg_get_functiondef of the 6
pipeline fns) identical before and after. All DDL trialed BEGIN..ROLLBACK before apply.

## Shipped

- **`refill_qa` schema** (isolated, non-protected): `plan_run`, `plan_run_row` + index
  `(run_id, machine_id, shelf_id, pod_product_id, action)`. RLS: authenticated SELECT
  only; writes via the SECURITY DEFINER capture fn.
- **`refill_qa.capture_run(plan_date, label)`** — branch-guarded: refuses unless the
  session GUC `refill_qa.on_branch='true'` (set only on a preview branch by the runbook).
  On a branch: runs `build_draft_for_confirmed(plan_date, true)`, copies the resulting
  `pod_refill_plan` rows into `plan_run_row`, stamps engine_fingerprint (6 pipeline fns)
  and input_fingerprint (slot_lifecycle + v_live_shelf_stock + warehouse_inventory +
  machines_to_visit).
- **`refill_qa.diff_run_rows` / `diff_runs`** — pure SELECT. Full-outer-join at plan-slot
  grain `(machine_id, shelf_id, pod_product_id)`; classes
  unchanged/added/removed/qty_changed/action_changed/status_changed/reason_changed;
  fleet + per-machine aggregates + net_units + `identical` + `inputs_differ`.

## Deliberate spec refinement (logged)

The PRD's stated diff join key `(machine_id, shelf_id, pod_product_id, action)` makes
`action_changed` **unreachable** (an action change would surface as removed+added). To
honor all 7 classes the PRD enumerates, `diff_run_rows` joins at the plan-slot grain
`(machine_id, shelf_id, pod_product_id)` — one action per slot — and treats action/qty/
status/reasoning as compared attributes. The specified 5-col key is preserved as the
storage index. Change priority when several attrs differ: action > qty > status > reason.

## T-tests

| Test                                              | Result                                                                                                                                |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| T1 synthetic 3-class diff                         | PASS — unchanged 1 / added 1 / removed 1 / qty_changed 2, net_units 11, identical=false                                               |
| T2 qty NULL vs 5                                  | PASS — `qty_changed` (IS DISTINCT FROM, never coalesced)                                                                              |
| T3 no-op self-test (DIFF half)                    | PASS — `diff_runs(X,X)` ⇒ identical=true, zero false positives                                                                        |
| T3 no-op (ENGINE half: capture same engine twice) | **PARKED** — needs a data-bearing branch; see below                                                                                   |
| T4 full-fleet capture ⇒ prod unchanged            | **PARKED (read-only proof holds)** — capture never ran on prod (guard verified refusing); the branch-capture itself needs branch data |
| T5 mutate input ⇒ inputs_differ                   | PASS — fingerprint change flips `inputs_differ` true                                                                                  |
| T6 Saturday ⇒ skipped, empty diff                 | **PARKED** — needs branch capture                                                                                                     |
| Capture prod-guard                                | PASS — refuses on prod (`refill_qa.on_branch` unset)                                                                                  |

## Platform blocker (parked to MASTER-PARKING-LOT, feeds PRD-078)

`create_branch` on this project is **schema-only — production data does not carry over**
(Supabase tool contract). So `capture_run` on a fresh branch runs the engine over empty
fleet tables and yields an empty plan; the engine-level no-op (T3), full-fleet capture
(T4), and Saturday (T6) tests cannot be made meaningful until a known dataset seeds the
branch. That seeding is exactly **PRD-078 golden baseline's** job. The referee's diff half
is green and durable now; the capture half is validated end-to-end when golden_v1 lands.
Net: 079-085's "referee GREEN" precondition is satisfied by 076+077+**078** together, as
the goal itself states — not by 076 alone.

## Runbook (WS-4)

`docs/prds/PRD-076-RUNBOOK.md`: branch → `SET refill_qa.on_branch='true'` → `capture_run`
→ `diff_runs(baseline, candidate)` → interpret (identical / intended-delta-only /
inputs_differ). Used by the WAVE0 loop for every 079-085 candidate.

## Status: SHIPPED (infra + diff referee). Capture-on-branch tests deferred to PRD-078.
