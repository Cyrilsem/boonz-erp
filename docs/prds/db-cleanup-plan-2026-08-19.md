# DB Cleanup Plan — latency, size, capacity

**Date:** 2026-08-19 · **Project:** `eizcexopcuoycuosittm` (ap-south-1) · **Status:** DRAFT, nothing applied
**Supersedes the alarm level of:** monthly health check run 2026-08-19 (see Corrections)

---

## 0. Corrections to this morning's health-check report

Four claims in the automated report were wrong or overstated. Correcting them changes the priority order, so they come first.

| Claim in report                                             | Reality                                                                                                                       | Evidence                        |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| Audit-log growth is "accelerating", ~700 MB/mo              | **Decelerating.** 677k rows (May) → 519k (Jun) → 361k (Jul) → ~150k/mo run-rate (Aug). ~200 MB/mo now.                        | monthly rollup of `occurred_at` |
| "~3 GB heap by mid-October"                                 | Heap is 2106 MB, +200 MB/mo → **3 GB around Feb 2027**, matching the original plan's "2027-Q1" estimate                       | same                            |
| `prd114_golden_gate_tick` (6039 ms mean) is a live offender | Cron 53 `prd115_golden_gate` is **already inactive**. The 181 calls were a burst before it was disabled. Not an ongoing burn. | `cron.job`                      |
| Implied capacity crisis                                     | **Total active cron burn = 1.06% of one core** (6413 s over 7 days). The DB is not compute-starved.                           | `cron.job_run_details`, 7d      |

Also note: `pg_stat_statements` was reset **2026-08-14**, so all "mean_ms / calls" figures cover a 5-day window only, and `idx_scan` counters are 5-day counts, not lifetime.

**Revised framing:** this is not a capacity fire. It is (a) a real user-facing latency problem on two report RPCs, (b) a storage-concentration problem, and (c) accumulated scheduling and index debt. Treat it as planned maintenance, not incident response.

---

## 1. Where the DB actually stands

**Database: 3140 MB total.**

| Object                      | Size        | Share of DB |
| --------------------------- | ----------- | ----------- |
| `write_audit_log` heap      | 2106 MB     | 67%         |
| `write_audit_log` indexes   | 315 MB      | 10%         |
| **`write_audit_log` total** | **2422 MB** | **77%**     |
| Everything else             | 718 MB      | 23%         |

One append-only log is three-quarters of the database. That is the size story in a single line.

Health checks that came back clean: `relfrozenxid` age 229,588 vs `autovacuum_freeze_max_age` 200,000,000 — no wraparound risk. Planner `reltuples` = 1,474,893 against a true 1,735,590 — close enough that plans are not being mis-costed. Dead tuples 5.7%. Zero cron failures in 30 days.

---

## 2. The three problems, ranked by who feels them

### P1 — Report RPC latency (a person is waiting)

| RPC                         | Mean    | Max           | Calls (5d) |
| --------------------------- | ------- | ------------- | ---------- |
| `get_vox_commercial_report` | 5661 ms | **28,601 ms** | 57         |
| `get_vox_consumer_report`   | 3376 ms | **18,903 ms** | 28         |
| `engine_swap_pod`           | 3567 ms | 6020 ms       | 4          |

Low call volume, but every call is a human staring at a spinner for up to 29 seconds. This is the only finding on the list that degrades someone's actual day. It should be fixed first even though it saves the least CPU.

⚠️ **Both RPCs carry `SET statement_timeout TO '30s'` in their own definition, and the commercial report peaked at 28.6 s.** It is running within 1.4 s of its own ceiling. Some calls are almost certainly already erroring out for users rather than merely being slow. This is more urgent than the mean suggests.

**The cause is not data volume.** Both read `sales_history`, which is **25 MB / 42,837 rows**, and it is already indexed on exactly the right predicate (`idx_sh_machine_date` on `(machine_id, transaction_date)`), plus seven more indexes. The commercial report's other join is `vox_product_mapping` — **53 rows, 32 kB**. Nothing here should take five seconds.

The cost is in the function bodies: 10.3 KB and 13.9 KB of plpgsql respectively, doing per-row `regexp_replace(internal_txn_sn, '_\d+$', '')` for refund grouping, multi-level CTE chains, and full `jsonb` assembly — with `p_include_transactions` defaulting to `true` and `p_txn_limit` defaulting to `NULL`, i.e. every transaction line is serialised into the response by default.

### P2 — Storage concentration in `write_audit_log`

Two independent contributors:

**Fat rows.** Average row is 1.0–1.9 KB. Worst offenders in the last 30 days:

| rpc_name                       | rows/30d | avg row | 30d bytes |
| ------------------------------ | -------- | ------- | --------- |
| `cron_stale_state_escalator`   | 22,666   | 1929 B  | 42 MB     |
| `engine_add_pod`               | 26,712   | 1634 B  | 42 MB     |
| _(NULL — unattributed)_        | 34,404   | 1061 B  | 35 MB     |
| `auto_decrement_pod_inventory` | 15,666   | 1001 B  | 15 MB     |

A single nightly cron (`cron_stale_state_escalator`, job 21) writes 42 MB/month of audit rows at ~1.9 KB each. 18.6% of all rows carry no `rpc_name` at all, so they cost storage without being attributable during debugging — that is the worst possible ratio.

**Index debt.** 315 MB of indexes, of which:

| Index                      | Size   | Scans (5d) | Verdict                                                                                                                                 |
| -------------------------- | ------ | ---------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `idx_wal_rpc_row_occurred` | 194 MB | 2666       | **Keep** — this is the 2026-05-26 incident fix, earning its keep                                                                        |
| `write_audit_log_pkey`     | 80 MB  | 0          | Structural, but never used for lookup                                                                                                   |
| `idx_wal_table_occurred`   | 20 MB  | 12         | Marginal                                                                                                                                |
| `idx_wal_actor`            | 18 MB  | 3          | **Poor** — 3 scans read 424,660 tuples. Bad selectivity                                                                                 |
| `idx_wal_via_rpc`          | 2.9 MB | 0          | **Keep** — partial index `WHERE via_rpc = false`; the lookup path for direct-write audits. Zero scans is expected for a compliance tool |

### P3 — Scheduling debt

Total burn is low, but the shape is wrong.

**`refresh_app_cache` (job 36, `*/5`)** is the single largest consumer: 4922 s over 7 days = **0.81% of one core, 76% of all cron time**. Mean 2.44 s — but **max 57.9 s**. A 58-second run on a 5-minute schedule means overlapping executions are possible. It rebuilds two cache keys (`machine_health`, `dashboard_ops`) unconditionally, every 5 minutes, forever, whether or not anything changed.

**`release-stale-wh-pins` (job 34)** shows the same signature: 0.54 s mean, **58.2 s max**.

**Collisions still unfixed since the May incident** — that post-mortem flagged "3 jobs at 02:00 UTC". It is now four:

| Time (UTC)     | Jobs                                                                                                                                              |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **02:00**      | 3 `daily-machine-duplicate-audit`, 14 `pick_machines_morning_6am_dubai`, 16 `daily_inventory_reconciliation`, 21 `stale_dispatch_state_escalator` |
| **19:59**      | 2 `nightly-fleet-refresh`, 9 `eod_auto_release_unpicked`                                                                                          |
| **22:15**      | 7 `evaluate-lifecycle-4h`, 19 `findings_ledger_auto_heal`                                                                                         |
| **15:30**      | 32 `rebuild_slot_profile_pool_nightly`, 42 `prd110_p02_slot_lifecycle_coverage`                                                                   |
| **16:15**      | 23 `refill_draft_missing_alert`, 43 `prd110_p05_blocked_demand`                                                                                   |
| **03:30**      | 24 `shelf_aisle_index_drift_alert`, 33 `conservation_monitor_daily`                                                                               |
| **hourly :00** | 12 `monitor_stuck_remove_dispatches`, 20 `findings_ledger_alerts_ingest`                                                                          |

The 19:59 pair is the one that failed together in May. It has never been separated.

---

## 3. The plan

Four phases, ordered so that everything reversible happens before anything that touches data. Every phase carries an explicit gate.

### Phase 0 — Reversible wins (this week, ~1 hour)

No data is deleted or moved. Every step is revertible in one statement.

**0.1 Stagger the 02:00 UTC pile-up.** Spread four jobs across 20 minutes. Purely `cron.alter_job` schedule edits.

| Job                                  | From        | To                              |
| ------------------------------------ | ----------- | ------------------------------- |
| 3 `daily-machine-duplicate-audit`    | `0 2 * * *` | `0 2 * * *` (anchor, unchanged) |
| 14 `pick_machines_morning_6am_dubai` | `0 2 * * *` | `5 2 * * *`                     |
| 16 `daily_inventory_reconciliation`  | `0 2 * * *` | `12 2 * * *`                    |
| 21 `stale_dispatch_state_escalator`  | `0 2 * * *` | `20 2 * * *`                    |

⚠️ Check ordering dependencies before applying. `pick_machines_for_refill` may be assumed by downstream jobs to have completed; `daily_inventory_reconciliation` may be assumed to run before the picker. **Confirm the intended order with Stax before moving 14 or 16** — a wrong order here is worse than a collision.

**0.2 Separate the 19:59 pair.** Move job 9 `eod_auto_release_unpicked` to `10 20 * * *`. These two failed together in May at 91 s each; they have no reason to be simultaneous.

**0.3 Split the hourly `:00` pair.** Move job 20 `findings_ledger_alerts_ingest` to `:25`.

**0.4 ~~Drop `idx_wal_via_rpc`~~ — withdrawn on inspection. Keep it.**
It is a _partial_ index: `... (via_rpc, occurred_at DESC) WHERE (via_rpc = false)`. It exists to find writes that bypassed an RPC — i.e. it is the lookup path for constitutional direct-write audits. Zero scans in a 5-day window is expected for a compliance tool, not evidence it is dead. At 2.9 MB it is the cheapest insurance in the database. **No index drops in Phase 0.**

**0.5 Add overlap protection to job 36.** Wrap `refresh_app_cache()` in a `pg_try_advisory_lock` so a slow run cannot be lapped by the next tick. Guards the 57.9 s tail without changing behaviour.

**Gate:** Stax confirms cron ordering dependencies → apply → re-run health check after 7 days and confirm max_sec on jobs 34 and 36 has stabilised.

---

### Phase 1 — Report latency (next 1–2 weeks)

Target: `get_vox_commercial_report` and `get_vox_consumer_report` under 2 s mean, under 5 s p99.

**Do not start by adding indexes.** The tables are tiny and already well indexed; an index will not move this. The cost is in the function bodies.

1. `EXPLAIN (ANALYZE, BUFFERS)` both RPCs over a month-wide `p_date_from`/`p_date_to`, which is how statements actually call them. Confirm where the time goes before changing anything.
2. **Check the default arguments first — likely the cheapest win by far.** `p_include_transactions` defaults to `true` and `p_txn_limit` defaults to `NULL`, so every call serialises the full transaction list into the JSON response even when the caller only renders totals. If the FE statement view does not display line-level transactions, passing `p_include_transactions => false` fixes this with a one-line front-end change and no migration. Confirm with Stax what the FE actually consumes.
3. Attack the per-row `regexp_replace(internal_txn_sn, '_\d+$', '')` used for refund grouping. Note that `idx_sh_txn_sn_pattern` (`text_pattern_ops`) already exists but **cannot** serve a `regexp_replace` in the SELECT list — the expression is computed per row regardless. Options: persist a generated `base_txn_sn` column with its own index, or restructure the grouping.
4. Only if 2–3 fall short, consider pre-aggregation. Do **not** reach for a materialised view by default: the 2026-06-01 correction in the May post-mortem records that `sales_history_aggregated` was refreshed synchronously on every ingest by `upsert_sales_lines`, moving cost onto the hot write path. Same trap, one table over.
5. **Raise `statement_timeout` only as a last resort.** The 30 s ceiling is a symptom guard, not the bug. Lifting it hides user-visible failures rather than fixing them.

**Gate:** step 2 is FE-side and needs no Cody review. Steps 3–4 touch `sales_history` → Dara designs → Cody reviews → apply → measure against a reset `pg_stat_statements`.

---

### Phase 2 — Audit-log payload diet (next 3–4 weeks)

This is where the size curve actually bends. Shrinking the row is worth more than deleting rows, because it compounds.

**2.1 Fix the NULL `rpc_name` rows (18.6% of volume).** Find the write path that omits it. These rows cost 35 MB/month and cannot be used in the one query pattern the table exists to serve. Either attribute them or stop writing them.

**2.2 Trim `cron_stale_state_escalator` payloads.** 1929 B/row is the fattest in the fleet, from a nightly monitoring cron. Monitoring output does not need a full before/after row image. Cutting this to ~400 B saves ~33 MB/month.

**2.3 Same review for `engine_add_pod`** (1634 B × 26.7k rows/mo).

**2.4 Reassess `idx_wal_actor`** (18 MB, 3 scans, 424k tuples read). Either make it selective or drop it.

Combined, 2.1–2.3 should cut monthly growth from ~200 MB to ~120 MB, pushing the partitioning trigger from Feb 2027 to roughly mid-2027.

**Gate:** `write_audit_log` is append-only and Cody-protected. Any change to what gets written is a constitutional review, not a quick edit.

---

### Phase 3 — Partitioning (trigger-based, do not pre-empt)

Unchanged from `project_write_audit_log_retention_plan.md`: Tier 2, monthly RANGE partition on `occurred_at`, 12 months hot, detach + drop older.

**Do not start this yet.** The documented triggers are heap ≥ 3 GB or audit queries feeling slow. Heap is 2106 MB and the incident-fix index is doing its job (2666 scans, 556 tuples read — excellent selectivity). Phase 2 pushes the trigger further out. Revisit at the November or December health check.

When it fires: Dara designs → Cody reviews → apply. Single design-and-apply pass, not a multi-week PRD.

---

## 4. What this buys

| Phase | Effort   | Latency                        | Space                   | Risk                                           |
| ----- | -------- | ------------------------------ | ----------------------- | ---------------------------------------------- |
| 0     | ~1 hr    | Removes collision tail-latency | —                       | Very low, all reversible                       |
| 1     | 1–2 wks  | **29 s → <5 s on reports**     | —                       | Low if the fix is 1.2 (FE flag); Medium if 1.3 |
| 2     | 3–4 wks  | —                              | ~80 MB/mo avoided       | Medium (Cody review)                           |
| 3     | Deferred | —                              | Caps table at 12 months | Higher — defer                                 |

Phase 0 and 1 deliver essentially all the user-visible benefit. Phase 2 is the one that changes the trajectory. Phase 3 stays parked.

## 5. Explicitly not recommended

- **Do not upgrade compute.** Cron uses 1.06% of one core. There is no capacity problem to spend money on.
- **Do not bulk-delete audit history.** It is the forensic record behind several open investigations (IRIS-1010, mapping-split reachability). Retention belongs in Phase 3 with detach-and-drop, not an ad-hoc `DELETE`.
- **Do not add a materialised view for the VOX reports** without first reading the 2026-06-01 correction in `project_db_starvation_incident_2026-05-26.md`.
- **Do not add indexes to `sales_history`.** It has nine already on 42,837 rows. The report latency is function-body cost, not scan cost. More indexes would only slow ingest.
- **Do not drop `idx_wal_via_rpc`** despite zero recorded scans — see §2.
- **Do not VACUUM FULL `write_audit_log`.** It takes an ACCESS EXCLUSIVE lock on 2.1 GB and dead tuples are only 5.7%. Not worth the outage.

## 6. Open questions for CS

1. Cron ordering at 02:00 — does `daily_inventory_reconciliation` need to finish before `pick_machines_for_refill`, or vice versa? Phase 0.1 is blocked on this.
2. How fresh does `dashboard_ops` actually need to be? If 15 minutes is acceptable, job 36 moving from `*/5` to `*/15` cuts the largest single consumer by two-thirds for free.
3. Is `prd115_golden_gate` (job 53) staying disabled? At 6.0 s mean on a `* * * * *` schedule it would consume ~10% of a core if re-enabled — it needs optimising before it goes back on.
