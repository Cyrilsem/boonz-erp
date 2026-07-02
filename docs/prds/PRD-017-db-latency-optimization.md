# PRD-017 — DB Latency Optimization (RPC Hot Path)

**Status:** Draft / Proposed
**Created:** 2026-06-01
**Author:** Monthly DB health check (cyrilsem@gmail.com)
**Owners:** Dara (design) → Cody (constitutional review) → Stax / assistant (apply)
**Related:** [[project_db_starvation_incident_2026-05-26]], [[project_write_audit_log_retention_plan]], [[reference_vox_consumer_report_rpc]], [[bug_phaseF_middleware_invocation_timeout]]
**Supabase project:** eizcexopcuoycuosittm (ap-south-1)

---

## 1. Overview

The 2026-06-01 monthly health check surfaced "crazy" cron timelines (cron 12 peaking at 533s). On investigation that peak is **already resolved**: the `idx_wal_rpc_row_occurred` index shipped on 2026-05-26 cut `monitor_stuck_remove_dispatches` from a 30.7s average (533.8s peak, 10 failures) to **1.6s average, 2.9s peak, zero failures** across 139 post-fix runs. No further work is needed there. That fix is the model this PRD follows.

What remains are three **live, user-facing RPCs** that sit in the 1.2s to 2.3s mean-latency band and dominate cumulative DB time. These are the real "crazy timelines" worth attacking, because they run on every sales ingest, every consumer-report load, and every Adyen dashboard view, so their cost is paid continuously and is felt by operators and n8n alike.

**Objective:** bring all three hot-path RPCs under a 500ms mean, eliminate the unbounded-fetch and per-row-overhead patterns that cause their high variance, and de-stagger the residual cron pile-ups left open by the May incident, without changing any business output.

**Non-goal:** `write_audit_log` partitioning. At 932 MB / 763k rows it is still well under the 2.5 GB trigger; the retention plan stays parked (see §6).

---

## 2. Verified problem state (2026-06-01)

Top cumulative offenders from `pg_stat_statements` (non-admin only; Supabase introspection queries excluded):

| RPC / query                    | calls | mean        | stddev  | total | signal                                 |
| ------------------------------ | ----- | ----------- | ------- | ----- | -------------------------------------- |
| `upsert_sales_lines(items)`    | 164   | **2259 ms** | 854 ms  | 371 s | #1 cumulative cost; ingest path        |
| `get_vox_consumer_report(...)` | 18    | **1722 ms** | 1775 ms | 31 s  | huge variance; backs /refill/consumers |
| `adyen_transactions` SELECT    | 101   | **1200 ms** | 1630 ms | 121 s | tiny table, latency disproportionate   |

Supporting facts gathered this session:

- `adyen_transactions` is **19 MB / 20,405 rows** with 7 indexes already (`pkey`, `psp_reference_key`, `idx_at_machine`, `idx_at_terminal`, `idx_at_date`, `idx_at_status`, `idx_at_customer_profile`). A 1.2s mean on a 20k-row table is **not** a volume problem. It points to a filter on a non-indexed column (e.g. `merchant_reference` / `store`), an unbounded fetch + client-side sort, or contention during cron pile-ups.
- `get_vox_consumer_report` raised its `recent_txns` cap from 2000 to 100000 (per [[reference_vox_consumer_report_rpc]]). That cap change is the prime suspect for both the 1.7s mean and the 1.8s stddev.
- `write_audit_log` grew ~103k rows in 6 days (660k → 763k), roughly double the 8k/day the retention plan modeled. If `upsert_sales_lines` writes one audit row per line in a loop, that ties the #1 RPC cost to the audit-log growth.

**Premise correction for the record:** the 533s figure in the monthly report is a 30-day-window artifact from before the May 26 fix. Do not spend effort on cron 12.

---

## 3. Confirmed root causes (verified 2026-06-01)

The original hypotheses were confirmed by reading the function bodies, the query text, and the index definitions. Each fix still gets an `EXPLAIN (ANALYZE, BUFFERS)` before/after per Article 14, but the dominant cost for each is now known, not guessed.

**C1 — `upsert_sales_lines`: synchronous MV refresh + per-row re-probe (CONFIRMED).** The function loops per line (`INSERT ... ON CONFLICT (internal_txn_sn)`), and after each upsert runs a second probe (`SELECT xmax=0 FROM sales_history WHERE internal_txn_sn=...`) purely to tally inserted vs updated. Then, once per call, it runs `refresh_sales_aggregated()`, which does a **full materialized-view refresh of `sales_history_aggregated`** plus its own audit write. So every sales ingest synchronously rebuilds the whole MV. Audit is per-row (via the `app.via_rpc` trigger on `sales_history`), but the MV refresh is the prime cost.

> **Cross-finding:** `sales_history_aggregated` is the same MV the May incident flagged as having "zero callers" when cron 4 (`refresh-sales-aggregated-10min`) was disabled. It DOES have a caller: `upsert_sales_lines`, on the hot write path. Disabling the cron did not remove the refresh load, it left it inline on every ingest. The [[project_db_starvation_incident_2026-05-26]] note should be amended.

**C2 — `adyen_transactions` read: unindexed `creation_date` range (CONFIRMED).** The PostgREST call is `WHERE creation_date >= $1 AND creation_date <= $2 LIMIT $3 OFFSET $4`. The only date index, `idx_at_date`, is on **`pos_transaction_date`**, not `creation_date`. So the range predicate has no usable index and seq-scans + sorts all 20,405 rows each call; OFFSET paging compounds it. `creation_date` is already `timestamptz`, so the column type is fine.

**C3 — `get_vox_consumer_report`: oversized result cap (CONFIRMED probable).** The `recent_txns` cap was raised 2000 → 100000 ([[reference_vox_consumer_report_rpc]]), so the RPC materializes and sorts up to 100k rows per call. CS confirmed the consumer of this data is **UI list + reporting only**, so the full 100k materialization is not load-bearing for any downstream contract beyond the rendered slice and the `disc_count` banner.

---

## 4. Proposed work

### FR-017-1 — Diagnose all three (P0, blocks everything else)

Capture `EXPLAIN (ANALYZE, BUFFERS)` for each RPC with representative arguments. For `upsert_sales_lines`, also inspect the function body for a per-row loop and per-row audit writes. Output: a one-page diagnosis confirming or rejecting H1/H2/H3, with the actual plan node that dominates.
**AC:** each RPC has a named dominant cost (seq scan node, nested loop, sort spill, or per-row write count) before any fix is written.

### FR-017-2 — `upsert_sales_lines` set-based rewrite (P0)

Per C1, in priority order: (a) **remove `refresh_sales_aggregated()` from the per-call path** — debounce it (one refresh per ingest window via a lightweight cron or a dirty-flag), use `REFRESH MATERIALIZED VIEW CONCURRENTLY`, or retire the MV and drive dashboards off a plain view if it is genuinely unused elsewhere; (b) convert the per-row loop to a single set-based `INSERT ... ON CONFLICT DO UPDATE` over the unnested `items` payload, using `RETURNING (xmax=0)` to tally inserted vs updated instead of the per-row re-`SELECT`. Preserve exact output and audit semantics. First confirm whether anything other than this RPC reads `sales_history_aggregated` before changing its refresh cadence.
**AC:** mean < 500 ms at the p50 batch size; audit coverage unchanged (Cody sign-off); `inserted`/`updated`/`skipped` counts and n8n ingest output byte-identical on a replay.

### FR-017-3 — `adyen_transactions` read fix (P1)

Per C2: either add a single btree index on `adyen_transactions(creation_date)` (Dara designs, Cody reviews), or, if `pos_transaction_date` is the correct business date, repoint the FE filter to the already-indexed column and add no index at all. Prefer the no-new-index path if the dates are interchangeable for this view. Also replace OFFSET paging with keyset paging if offsets are large.
**AC:** mean < 300 ms; the `creation_date` range uses an index scan (Heap Fetches low); at most one new index, and only if `pos_transaction_date` cannot serve the predicate.

### FR-017-4 — `get_vox_consumer_report` cap fix (P1)

Per C3, and confirmed by CS that the data is UI + reporting only: bound `recent_txns` to what the UI list renders (server-side LIMIT + keyset pagination), and route any reporting/export through a dedicated aggregate query path rather than the 100k-row materialization. Keep the banner `disc_count` accurate via a separate cheap `COUNT(*)`. See [[reference_vox_consumer_report_rpc]] for the disc_count contract that must stay correct.
**AC:** mean < 500 ms; Default list count still matches banner `disc_count` on the VOX Mercato/Mirdif scope; reporting totals unchanged.

### FR-017-5 — De-stagger residual cron pile-ups (P2)

Carry-over from the May incident: 3 jobs fire at 02:00 UTC (daily-machine-duplicate-audit, pick_machines_morning_6am_dubai, daily_inventory_reconciliation) and 2 at 19:59 UTC (nightly-fleet-refresh, eod_auto_release_unpicked). Spread each cluster across a 5 to 10 minute window so no two heavy jobs contend for pg_cron workers.
**AC:** no two jobs in either cluster share a start minute; one week of clean run_details with zero worker-starvation failures.

---

## 5. Non-functional requirements & success metrics

- **Latency:** all three RPCs under target mean (above) for 7 consecutive days in `pg_stat_statements` after a stats reset.
- **Correctness:** zero change to business output. Each fix verified by replaying real inputs and diffing results (Article 14 least-change; no destructive changes per [[feedback_no_destructive_changes]]).
- **Audit integrity:** any change to `upsert_sales_lines` audit behavior gets explicit Cody review (write_audit_log is a protected append-only entity).
- **Variance:** stddev on each RPC at least halved (the high stddev is the operator-visible "sometimes it hangs" symptom).
- **No regressions:** Supabase advisors (`get_advisors`) clean for security + performance after each migration.

---

## 6. Out of scope

- `write_audit_log` partitioning (parked; trigger is 2.5 GB heap or a slow audit query, neither met). **However**, if FR-017-2 confirms per-row audit writes are inflating both `upsert_sales_lines` latency and audit-log growth, revisit the retention-plan timeline, since the ~17k/day actual rate is double the modeled 8k/day and pulls the ~3 GB trigger date earlier than 2027-Q1.
- Cron 12 / `monitor_stuck_remove_dispatches` (already fixed 2026-05-26).
- Any schema change to `machines`, `refill_plan_output`, or other protected entities beyond a single read-path index.

---

## 7. Sequencing & ownership

1. **FR-017-1 (diagnose)** — assistant runs EXPLAIN, hands findings to Dara. Blocks all fixes.
2. **FR-017-2** — Dara designs set-based rewrite → Cody reviews (audit + SECURITY DEFINER) → apply via `apply_migration`.
3. **FR-017-3 / FR-017-4** — Dara designs → Cody reviews → apply. Parallelizable after diagnosis.
4. **FR-017-5** — Stax adjusts cron schedules; no DB design needed.

Each fix is its own migration with its own EXPLAIN before/after attached to the PR. No batched "fix everything" migration.

---

## 8. Resolved questions (2026-06-01)

1. **Audit cadence in `upsert_sales_lines`?** RESOLVED: per-row via trigger, but the dominant cost is the per-call synchronous `refresh_sales_aggregated()` MV refresh plus a per-row `xmax` re-`SELECT`. See C1. The per-row audit writes are real and explain part of the doubled audit-log growth, but batching them is secondary to removing the MV refresh.
2. **Which column does the Adyen read filter on?** RESOLVED: `creation_date` range with `LIMIT/OFFSET`, and the only date index (`idx_at_date`) is on `pos_transaction_date`, so the predicate is unindexed. See C2. Fix is one index on `creation_date` or repoint to `pos_transaction_date`.
3. **Is the 100k `recent_txns` cap load-bearing?** RESOLVED by CS: UI list + reporting only, not load-bearing beyond the rendered slice and `disc_count`. FR-017-4 can bound aggressively and push reporting to a dedicated aggregate.
4. **Do spikes correlate with cron pile-ups?** RESOLVED: yes historically, but the entire >30s cluster sits in the single 2026-05-26 incident window (17:00–20:20 UTC); there are zero recent >30s cron runs. Acute contention is already resolved, so today's RPC variance is intrinsic (MV refresh + unindexed scan), not contention. FR-017-5 is therefore preventive, not a primary lever, and stays P2.

## 9. Newly opened follow-up

- Amend [[project_db_starvation_incident_2026-05-26]]: `sales_history_aggregated` is NOT caller-free. `upsert_sales_lines` refreshes it synchronously on every ingest. Decide whether to keep the MV (debounced refresh) or retire it in favor of a plain view, and confirm no other reader exists before either.
