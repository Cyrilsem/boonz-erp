# PRD-083: Retire the duplicate engine generation (one canonical path)

Status: DRAFT 2026-07-07. PARTIAL PRIOR ART — PRD-074 (priority SSOT, 2026-07-04) deprecated `auto_generate_refill_plan`. This PRD extends that to the **orphan Family-B refill generation** (`orchestrate_refill_plan` → `propose_add_plan`/`propose_swap_plan`/`engine_finalize` → `daily_plan_drafts` → `engine_publish_to_refill_plan` → `refill_plan_output`), which is present but unscheduled while cron runs Family A (`build_draft_for_confirmed` → `engine_*_pod`). Wave 0 / 0c.1.
Owner: CS. Mode: AUTO with hard gates. Cody call-site audit, Dara classification, Stax docs/skills/n8n.

## Why

Two engine generations coexist. Family A is the live cron path; Family B is orphaned but callable, and the `refill-brain` skill still points at it. Divergent substitute/cap/reconcile logic = the #1 "messy/unreliable" driver, and every later fix would otherwise need doing twice.

## Design (Dara designs, Cody reviews, Stax wires)

1. **Call-site map:** for each Family-B object, list every caller (cron, edge fn, n8n, FE, other RPCs, skills/docs). Search `pg_proc` bodies, `cron.job`, edge fns, n8n exports, FE, `docs/`.
2. **Classify B-only vs shared.** CAUTION: `write_refill_plan` and `refill_plan_output` are SHARED (Family A's stitch/publish tail) — KEEP. Only truly-unreferenced-by-A objects are B-only.
3. **Deprecate B entry points** (`orchestrate_refill_plan`, `propose_*`): Article 13 pattern (rename `_deprecated` / revoke execute / RAISE redirect to `build_draft_for_confirmed`), behind flag `engine_single_path` (log→deprecate). Do NOT drop yet.
4. **Fix `refill-brain` skill + docs** to describe/run Family A; add a skill regression ("run the brain" → Family A).
5. **Grace window** (log invocations); **drop** B-only objects + `daily_plan_drafts` only after zero invocations (separate Cody-reviewed migration).

## Gates

- Family A engines md5 byte-identical; `diff_vs_golden` identical (removing B changes no live plan). Never drop a shared object; never drop with a live caller in the grace log. Two Cody verdicts (deprecate, drop). BEGIN..ROLLBACK; forward-only.

## T-tests

- T1 call-site map complete + every B object classified with evidence.
- T2 `orchestrate_refill_plan` returns deprecation redirect (grace: logs).
- T3 `refill-brain` skill runs Family A e2e on a branch.
- T4 `diff_vs_golden` identical after deprecate + after drop.
- T5 grace window shows zero B invocations before any drop.

## CLOSE

CHANGELOG + RPC_REGISTRY (Article 13 notes); PRD-083 SHIPPED + EXECUTION-LOG; commit + push. Rollback pre-drop = flag off.
