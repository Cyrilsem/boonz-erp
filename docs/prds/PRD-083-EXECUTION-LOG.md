# PRD-083 Execution Log — Retire duplicate engine (deprecate-only)

Run 2026-07-07 overnight, AUTO. **Status: SHIPPED (deprecate; drop parked).** Family A md5
`8587be9a1f54594f047f0ae6726599bc` — UNCHANGED. Cody PASS (⚠️→ revisions applied).

## What shipped (Article 13, flag-gated, reversible)
- `refill_qa.feature_flag` (RLS read-only) + `refill_qa.flag(text)` helper. Seeded
  `engine_single_path='deprecate'`.
- Flag-gated RAISE-redirect guard on the 5 Family-B orphan functions:
  `orchestrate_refill_plan`, `propose_add_plan`, `propose_swap_plan`,
  `engine_publish_to_refill_plan`, `reconcile_intent_progress`. Under `deprecate` they raise
  "use Family A"; set the flag off to restore original behaviour. **DROP nothing** (parked).
  KEPT: `approve_refill_plan`, `write_refill_plan`, `refill_plan_output` (shared).
- Referee fix (`prd076_fix_capture_run…`): `capture_run` input_fingerprint referenced a
  nonexistent `slot_lifecycle.slot_id` (→ `slot_lifecycle_id`). Surfaced on first
  rollback-on-prod capture; corrected. Makes the referee candidate-capable.

## Orphan-island evidence (Cody residual-risk cleared)
`orchestrate_refill_plan`: 0 callers (pg_proc + cron). The 4 leaves: called only by
`orchestrate_refill_plan`. `reconcile_intent_progress`: NOT called by `approve_refill_plan`,
any Family-A engine, or any cron. FE/n8n CS-confirmed clear. refill-engine skill already
Family-A oriented (no Family-B refs).

## Envelope / referee (rollback-on-prod capture)
| Check | Result |
|---|---|
| Family A md5 byte-identical | PASS (8587be9a) |
| deprecated fns redirect under flag | PASS |
| candidate capture succeeds (build_draft independent of Family-B) | PASS (run, 54 rows) |
| **diff_vs_golden identical** | PASS — 21 unchanged, 0 added/removed/changed, net_units 0 |
| conservation delta (new violations) | 0 |
| reversible (flag toggle, no drop) | PASS |
| cody | PASS (RLS on feature_flag + reconcile audit) |

## Parked
- The DROP of the Family-B island (Article 13: after 90-day monitor). {owner: Cody+CS; needs: 90-day clean window under deprecate}.

## Status: SHIPPED (deprecate live behind engine_single_path).
