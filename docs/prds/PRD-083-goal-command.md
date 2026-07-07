# PRD-083 goal command

GOAL: Execute PRD-083 (docs/prds/PRD-083-retire-duplicate-engine.md) AUTO mode. Self-run Cody/Dara/Stax. Keep PRD-083-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Depends PRD-076+077+078. PRIOR ART PRD-074 (auto_generate_refill_plan deprecated). Flag engine_single_path (log|deprecate|drop). PARK-heavy: never drop with a live caller.

HARD GATES: Family A engines md5 byte-identical; diff_vs_golden identical after deprecate AND after drop. NEVER drop shared objects (write_refill_plan, refill_plan_output are SHARED — KEEP). Two Cody verdicts (deprecate, drop). BEGIN..ROLLBACK; forward-only.

WS-1 AUDIT call sites of Family-B objects [orchestrate_refill_plan, propose_add_plan, propose_swap_plan, engine_finalize(date,bool), engine_publish_to_refill_plan, reconcile_intent_progress, daily_plan_drafts, approve_refill_plan]: pg_proc bodies, cron.job, edge fns, n8n, FE, docs.
WS-2 CLASSIFY B-only vs shared.
WS-3 DEPRECATE B entry points (Article 13: rename/revoke/RAISE redirect to build_draft_for_confirmed) under flag; do NOT drop.
WS-4 Fix refill-brain skill + docs to Family A; skill regression 'run the brain' => Family A.
WS-5 Grace window (log) N days => zero B invocations, then DROP B-only + daily_plan_drafts (separate Cody-reviewed migration).

T-TESTS: T1 call-site map complete + classified. T2 orchestrate redirect. T3 skill runs Family A on branch. T4 diff_vs_golden identical after deprecate+drop. T5 grace window clean.

CLOSE: CHANGELOG + RPC_REGISTRY; PRD-083 SHIPPED + EXECUTION-LOG; commit + push. ON BLOCKER (live caller / uncertain classification): append PARKING_LOT.md, keep flag at log/deprecate, do NOT drop.
