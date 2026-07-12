# PRD-087 planned=visited - EXECUTION LOG

Run: 2026-07-09 (Dubai) / 2026-07-08 UTC, Claude Fable 5. AUTO mode.

## Change

get_machine_health() plan_data CTE: added `AND rpo.dispatched = true` (one line). Everything else byte-identical to the live base (md5 96ef4dd57267b1c47de5818faa72f9ce, fetched base64 to avoid escape mangling). v2 md5 c25188bfb91f12244463cc16dd2a8d33. Applied as migration `prd087_plan_clock_requires_dispatched` (version 20260708163722) via a GUARDED transform: aborts unless the live base md5 matches AND the post-apply md5 equals the parity file's - so the git file is provably what runs in prod.

## Cody review (self-run, canonical reader)

Read-only STABLE SECURITY DEFINER reader; no write path, no data, no view, no engine touched. days_since_visit comes from the v_machine_health_signals JOIN, not this CTE - untouched by construction. Semantics of last_plan_date/last_plan_days change from "last approved plan" to "last EXECUTED (dispatched) plan" - the documented intent (planned = visited when executed). Articles 12 (read-only/idempotent), 14 (engines untouched), 16 (canonical reader semantics; registry note in this log). VERDICT: APPROVE.

## Proof

BEGIN..ROLLBACK dry-run (DO+RAISE), then live re-verify after apply - identical results:
- VOXMCC-1011-0101-B0: days_since_visit 0, last_plan_days 0 (planned == visited)
- ACTIVATE-2005-0000-W0: days_since_visit 0, last_plan_days 0
- OMDCW-1021-0100-W0: the goal named it "dispatched today" but live data shows its 2026-07-08 plan has 13 approved rows and ZERO dispatch legs - approved, never pushed; its visit 0d is a manual refill. Post-fix it correctly reads last_plan 2026-07-02 (its last EXECUTED plan, 6d) while last visit stays 0d. This is exactly acceptance criterion #2 (approved-only plans no longer inflate the plan clock) and doubles as the required approved-but-undispatched test machine (also verified: MC-2004 max approved 07-07 vs dispatched 07-06; HUAWEI-2003 same shape; JET-1016 07-02 vs 06-29).
- Fleet-wide days_since_visit md5 identical before vs after (untouched).
- 0 machines where last_plan_date deviates from MAX(plan_date) FILTER (WHERE dispatched).
- Concurrency note: a parallel session (feat/prd-087-ui-uplift) applied prd087_dashboard_summary_v3_themed and prd089 migrations seconds after this apply; get_machine_health md5 re-verified c25188bf... afterwards - no clobber.

## FE chip (optional step) - SKIPPED, highlighted

SnapshotTab.tsx relabel deliberately not done this run: the active parallel session owns that surface on feat/prd-087-ui-uplift (dirty worktree on the same file family). Applying a competing edit would collide. The chip now reads execution-truth anyway (same RPC); relabel to "last executed" can ride the ui-uplift train. No Vercel deploy needed (backend-only).

## Rollback

CREATE OR REPLACE get_machine_health() without the `AND rpo.dispatched = true` line (base body md5 96ef4dd57267b1c47de5818faa72f9ce in git history / this migration's header).

## CLOSED 2026-07-10 - SUPERSEDED by PRD-088

The live get_machine_health no longer contains the plan_data CTE or the rpo.dispatched filter; last_plan_* mirrors days_since_visit (PRD-088 body, md5 1cf209efedea59e6eec6d228db1c7740, verified live 2026-07-10).
