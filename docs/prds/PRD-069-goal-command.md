/goal Execute PRD-069 (write_audit_log no-op leak). SUPERVISED, gated. Verified live 2026-07-01: ingest_alerts_into_ledger rewrites ~3,400 findings hourly as 100% no-op UPDATEs (payload old = new), ~82k audit writes/day = 91% of write_audit_log growth (now 3.15 GB). Read PRD-069-audit-log-noop-alert-ingest-leak.md first.

PRECHECK (read-only, print): SELECT operation, count(_), count(_) FILTER (WHERE payload->'old' IS NOT DISTINCT FROM payload->'new') AS noop FROM write_audit_log WHERE rpc_name='ingest_alerts_into_ledger' AND occurred_at > now()-interval '3 hours' GROUP BY operation; If no-op UPDATEs no longer dominate, STOP and tell me.

STEP 1 DESIGN (Dara): pg_get_functiondef(ingest_alerts_into_ledger) + findings_ledger columns. Real signal cols = status, severity, last_seen_signal_at, auto_healed_at, resolved_at, resolution_note, detail. Design (a) change-guard: ON CONFLICT DO UPDATE ... WHERE findings_ledger.<signal cols> IS DISTINCT FROM excluded.<signal cols>; (b) scope: ingest only open/active findings, skip auto_verified_healed/resolved/closed; (c) recommend keep-or-drop the internal audit write for this RPC. Print the new body as a diff. Do NOT apply.

STEP 2 REVIEW (Cody): route the STEP 1 migration through Cody (SECURITY DEFINER cron RPC writing a protected append-only log). Get explicit verdict; fix and re-review if flagged. Print it.

STEP 3 APPLY (my green light): apply_migration prd069_ingest_alerts_noop_guard. Fire ONE manual run of the RPC, re-run PRECHECK for the last few minutes. ACCEPTANCE: that run writes < ~100 audit rows and its no-op count = 0. Print before/after. If it still floods, STOP (guard cols wrong).

STEP 4 RECLAIM (SEPARATE explicit "reclaim" green light; destructive on append-only, ~2.8 GB):

- Snapshot to LOG: SELECT count(*) AS noop_rows, min(occurred_at), max(occurred_at) FROM write_audit_log WHERE rpc_name='ingest_alerts_into_ledger' AND operation='UPDATE' AND payload->'old' IS NOT DISTINCT FROM payload->'new'; + 5-row sample.
- Delete in 50k batches, separate txns (never one 2M-row DELETE). Every batch predicate MUST keep rpc_name='ingest_alerts_into_ledger' AND operation='UPDATE' AND payload->'old' IS NOT DISTINCT FROM payload->'new'. Never widen it.
- Reclaim space: pg_repack if available, else VACUUM FULL in a window you agree with me (not blind, not during business hours).
- ACCEPTANCE: rows deleted == snapshot; pg_total_relation_size('write_audit_log') near ~350 MB; INSERT-row count + other rpc_names UNCHANGED (prove only no-op echoes removed).

STEP 5 MONITOR (Article 16): daily job asserts no-op UPDATE count = 0 and ingest_alerts_into_ledger daily audit rows < 500; on breach open a findings_ledger row (no email spam). Log first run.

STEP 6 RECORD: update MIGRATIONS_REGISTRY + RPC_REGISTRY + CHANGELOG + PRD-069-EXECUTION-LOG.md (before/after size, before/after mean exec time, reclaim count, Cody verdict, migration name). Set PRD-069 status. Note write_audit_log 3 GB was this leak, now resolved; partitioning back to the organic 3 GB trigger.

HARD SAFETY: no DB writes in STEPS 1-2. STEP 3 needs my green light. STEP 4 needs a SEPARATE "reclaim" green light and is the only destructive step. Never run an unbounded DELETE, never drop the no-op predicate, never VACUUM FULL in business hours without an agreed window. Do not touch findings_ledger/monitoring_alerts/business ledgers (audit-echo cleanup only). No force-push/history rewrite; if main is protected, open a PR and STOP. swaps_enabled stays false; do not run the refill engine.

AFTER: give me the new weekly-growth projection for write_audit_log and whether partitioning stays parked.
