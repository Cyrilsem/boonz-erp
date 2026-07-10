# PRD-088 unify plan clock with visit clock - EXECUTION LOG

Run: 2026-07-09 (Dubai) / 2026-07-08 UTC, Claude Fable 5. AUTO mode. Supersedes PRD-087's dispatched=true narrowing.

## Change

get_machine_health() v3: plan_data CTE and its pld join DROPPED; last_plan_date/last_plan_days now mirror the canonical service clock (hs.days_since_visit from the existing v_machine_health_signals join): last_plan_date = CURRENT_DATE - days_since_visit (NULL when unknown/negative), last_plan_days = COALESCE(days_since_visit, -1). A dispatched plan and an on-spot manual refill now count identically - planned = visited, full stop. Everything else byte-identical to the live PRD-087 v2 body.

Base c25188bfb91f12244463cc16dd2a8d33 (verified live + reconstructed locally from the archived v1 base64) -> v3 1cf209efedea59e6eec6d228db1c7740. Applied as `prd088_unify_plan_clock_with_visit` version 20260708171949 via the guarded transform (aborts on base drift, on anchor-count <> 1, and unless the post-apply md5 equals the committed parity file) - concurrency-safe against the parallel feat/prd-087-ui-uplift session.

## Cody review (self-run, canonical reader)

Read-only STABLE SECURITY DEFINER reader. Drops a CTE + join (strictly less work, no refill_plan_output scan); output-only semantics change; hs.days_since_visit typed integer (checked) so CURRENT_DATE - int is date, matching RETURNS TABLE. No write path, no data, no view change; days_since_visit itself untouched by construction. Articles 12/14/16. VERDICT: APPROVE.

## Proof (dry-run DO+RAISE, then live re-verify - identical)

- Fleet-wide: 0 rows where days_since_visit >= 0 AND last_plan_days <> days_since_visit.
- ADDMIND-1007-0000-W0 / HUAWEI-2003-0000-B1 / MINDSHARE-1009-4500-O1 (manual-refill visits): last_plan_days 1 == days_since_visit 1 (was 2 vs 1 divergence under PRD-087).
- Fleet-wide days_since_visit md5 identical before vs after (canonical clock untouched).
- Post-apply fn md5 == parity file md5.

## FE follow-up

The now-redundant `last plan {n}d` chip in SnapshotTab.tsx: left to the feat/prd-087-ui-uplift branch per PRD (correctness no longer depends on it - it shows the same number as last visit either way). Backend-only: no Vercel deploy.

## Rollback

CREATE OR REPLACE restoring the plan_data CTE + pld columns - the PRD-087 body is verbatim in supabase/migrations/20260708163722_prd087_plan_clock_requires_dispatched.sql.

## CLOSED 2026-07-10

Re-verified live: count(*) filter (where days_since_visit >= 0 and last_plan_days <> days_since_visit) = 0 (37 rows / 30 with visit). Live fn md5 1cf209efedea59e6eec6d228db1c7740 equals this PRD's applied migration body; no plan_data CTE, no dispatched filter. No further migration required. FE chip removal handed to feat/prd-087-ui-uplift.
