# PRD-076: Refill shadow-diff harness (the referee)

Status: SHIPPED 2026-07-07 (infra + diff referee; capture-on-branch tests deferred to PRD-078 — see EXECUTION-LOG). NET-NEW (no prior art — verified absent from docs/prds and repo). Wave 0 / 0a.1.
Owner: CS. Mode: AUTO with hard gates. Dara designs the `refill_qa` store, Cody reviews (additive QA infra), Stax wires the branch-capture loop.

## Why

There is no way today to prove a change altered the plan only where intended. The engine is a multi-stage, temp-table pipeline with non-deterministic tie-breaks; every prior PRD verified itself with ad-hoc `md5 byte-identical` checks on the engine functions. That is necessary but not sufficient — it proves the _function text_ is unchanged, not that the _plan output_ is unchanged after a dependency/view/data change. Wave 0b/0c (and every later wave) needs a reusable **output-level** referee: run the engine in isolation, capture `pod_refill_plan`, and diff row-by-row against a baseline. This PRD builds it. It changes no engine logic and writes to no production planning/inventory table.

## Design (Dara designs, Cody reviews, Stax wires)

1. **`refill_qa` schema** (non-protected QA store, outside all planning/inventory tables):
   - `refill_qa.plan_run(run_id uuid pk, plan_date, label, engine_fingerprint text, input_fingerprint text, created_at, meta jsonb)`
   - `refill_qa.plan_run_row(run_id, machine_id, shelf_id, pod_product_id, action, qty, status, source text, linked_intent_id, reasoning jsonb)`; index `(run_id, machine_id, shelf_id, pod_product_id, action)`.
2. **`refill_qa.capture_run(plan_date, label)`** — on a Supabase **preview branch** (never prod): run `build_draft_for_confirmed(plan_date, true)`, copy the resulting `pod_refill_plan` rows into `plan_run_row` tagged with a new `run_id`. `engine_fingerprint` = md5 of `pg_get_functiondef` of the 6 pipeline fns (`build_draft_for_confirmed`, `engine_add_pod`, `engine_swap_pod`, `engine_finalize_pod`, `compute_refill_decision`, `pick_machines_for_refill`). `input_fingerprint` = md5 of scoped input rows (`slot_lifecycle`, `v_live_shelf_stock`, `warehouse_inventory`, `machines_to_visit`, `strategic_*`).
3. **`refill_qa.diff_runs(baseline uuid, candidate uuid, machine_scope uuid[] default null)`** — full outer join on natural key `(machine_id, shelf_id, pod_product_id, action)`; classify each row `unchanged|added|removed|qty_changed|action_changed|status_changed|reason_changed`; aggregate fleet + per-machine + net-units + `identical bool`; set `inputs_differ` when fingerprints differ. Pure SELECT.
4. **Runbook** `_programs/`-style doc: branch → capture → diff → interpret, usable by the WAVE0 loop.

## Gates

- Engines untouched: `engine_add_pod`, `engine_swap_pod`, `engine_finalize_pod`, `pick_machines_for_refill` md5 byte-identical (this PRD only reads them).
- Zero writes to prod planning/inventory: capture asserts it is running on a branch (project ref check) before invoking the engine; post-run assert prod `pod_refill_plan` row-count + max(updated_at) for the date unchanged.
- BEGIN..ROLLBACK for the `refill_qa` DDL trial; forward-only migration on apply. Cody signs the additive schema.
- Registries updated (RPC_REGISTRY: capture_run, diff_runs).

## T-tests

- T1 diff on synthetic runs differing by one added / one removed / one qty-changed ⇒ exactly those three classes, counts correct.
- T2 qty NULL vs 5 ⇒ `qty_changed` (never coalesced).
- T3 **no-op self-test**: capture the same engine twice on frozen inputs ⇒ `diff = identical` (zero false positives — the load-bearing test).
- T4 full-fleet capture ⇒ prod `pod_refill_plan` byte-unchanged (read-only proof).
- T5 mutate one input on branch ⇒ `inputs_differ=true` surfaced.
- T6 Saturday plan_date ⇒ `skipped_saturday`, empty diff, no error.

## CLOSE

Update RPC_REGISTRY + CHANGELOG; PRD-076 status → SHIPPED with EXECUTION-LOG; commit + push (main == origin/main). Referee is then a precondition for PRD-079..085.
