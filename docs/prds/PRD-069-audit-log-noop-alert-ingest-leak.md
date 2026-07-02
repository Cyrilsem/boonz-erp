# PRD-069: write_audit_log no-op leak from ingest_alerts_into_ledger + reclaim

Owner: CS. Date: 2026-07-01. Surface: backend cron RPC + one-time reclaim + standing monitor. Touches ingest_alerts_into_ledger, findings_ledger, write_audit_log (Articles 1, 12, 16 - protected append-only log). Cody review mandatory. Idempotent, no em dashes.

## Why (verified live 2026-07-01)

`write_audit_log` is 3,147 MB / 2,378,084 rows, up from 735 MB / 660k rows on 2026-05-26 (4x in 5 weeks). The growth is not organic. One writer owns it:

- `ingest_alerts_into_ledger` = 477,350 of the last 7 days of audit rows = 91% of all write volume, 564 MB/week.
- In the last 24h that RPC wrote 80,146 UPDATE audit rows against `findings_ledger` and only 201 INSERTs.
- In a clean 3h window: 10,170 UPDATE rows, 100% of them no-op (`payload->'old' IS NOT DISTINCT FROM payload->'new'` on every single row), across 3,415 distinct findings, versus 38 real new-alert INSERTs.

Root cause: the hourly ingest (cron job 20, `findings_ledger_alerts_ingest`) does an unconditional `ON CONFLICT DO UPDATE` with no change-guard and no scope filter. Every run it re-upserts every finding that has ever existed - including long-closed `auto_verified_healed` and `resolved` findings that will never change again (sampled finding `44def908` auto-healed 2026-06-27, still rewritten every hour). Postgres fires the UPDATE and the explicit audit write even though nothing changed. `write_audit_log` has no triggers, so the audit row is written from inside the RPC on each no-op UPDATE.

Blast radius beyond table size:

- `ingest_alerts_into_ledger` is the single largest query-time consumer on the DB: mean 8,156 ms, 569 calls, 4,641 s total exec (pg_stat_statements). It churns ~3,400 pointless upserts hourly.
- `monitor_stuck_remove_dispatches` mean has regressed to 2,919 ms (was 794 ms post-fix on 2026-05-26) - collateral from the now 3 GB table it probes. See [[project_db_starvation_incident_2026-05-26]].
- `findings_ledger` itself is needlessly UPDATE-churned and vacuumed ~82k times/day.

This is a logging leak, not real signal. ~82,000 no-op writes/day at ~1.2 KB each is the entire delta between the 2027-Q1 partitioning estimate in [[project_write_audit_log_retention_plan.md]] and today's 3 GB reality.

## Fixes

1. **Change-guard the upsert (primary).** In `ingest_alerts_into_ledger`, add `WHERE findings_ledger.<meaningful cols> IS DISTINCT FROM excluded.<same cols>` to the `ON CONFLICT DO UPDATE` so an identical row is not rewritten. No UPDATE means no audit write. Expected effect: ~82k/day to under ~100/day (only genuine changes). Choose the guard columns as the real signal fields (status, severity, last_seen_signal_at, auto_healed_at, resolved_at, detail) - not audit/echo fields.
2. **Scope the source.** Only ingest alerts whose finding is still `open` / active. Stop re-touching terminal-state findings (`auto_verified_healed`, `resolved`, `closed`). Belt-and-suspenders with fix 1.
3. **Audit-log routing (optional, defense in depth).** Even legitimate `findings_ledger` churn is monitoring bookkeeping, not an operator mutation of a protected business entity. Consider not routing `ingest_alerts_into_ledger`'s own ledger writes into `write_audit_log` at all (the findings_ledger row is itself the durable record). Decide with Cody; not required if fix 1 lands.
4. **One-time reclaim (~2.8 GB).** Archive-then-delete the historical no-op rows: `write_audit_log WHERE rpc_name='ingest_alerts_into_ledger' AND operation='UPDATE' AND payload->'old' IS NOT DISTINCT FROM payload->'new'`. Batched (e.g. 50k/txn) to avoid a long lock, then `pg_repack` (or `VACUUM FULL` in a maintenance window) to return the space. `write_audit_log` is append-only and protected, so this is a documented one-time exception under explicit CS green light, not a routine delete. Keep a count-and-checksum snapshot before deleting.
5. **Standing monitor (Article 16).** Daily job asserts the ingest is healthy: no-op UPDATE count for the day = 0 and `ingest_alerts_into_ledger` daily audit-row count is under a threshold (e.g. 500). Alert into the findings ledger if breached, so a future regression is caught the day it starts, not 5 weeks later.

## Rules

- Canonical RPC edit only; behaviour of the ingest is unchanged except that no-op and terminal-state rows no longer write. Real new alerts and real state transitions still ingest and still audit exactly as today.
- Idempotent: re-running the fixed ingest on an unchanged ledger writes zero rows. Re-running the reclaim after it completes no-ops (predicate matches nothing).
- Append-only integrity: the reclaim deletes ONLY provably-no-op rows (old identical to new); it never touches INSERT rows, real UPDATEs, or any other rpc_name. Snapshot the pre-delete count + a sample for the record.
- CONSERVATION: the reclaim changes no business data - `findings_ledger`, `monitoring_alerts` and all ledgers are untouched; only redundant audit echoes are removed.
- Cody verdict required (protected append-only log + SECURITY DEFINER cron RPC).

## Acceptance

- After deploy, one hourly run of `ingest_alerts_into_ledger` writes fewer than ~100 audit rows (down from ~3,400), and the no-op UPDATE count for that run is 0.
- `ingest_alerts_into_ledger` mean exec time drops below ~1s (from 8.2s) over the following 24h of pg_stat_statements.
- `write_audit_log` weekly growth falls below ~40 MB/week (from ~560 MB/week).
- After reclaim + repack, `write_audit_log` total relation size is back near its real working set (order ~350 MB) and the removed-row count matches the pre-delete no-op snapshot.
- The daily ingest-health monitor is scheduled and its first run is logged.
- Partitioning per [[project_write_audit_log_retention_plan.md]] returns to "someday / on the 3 GB trigger", no longer forced by this leak.
