---
name: boonz-health
description: On-demand governance + reconciliation checks across the Boonz backend. Runs the audit playbook, surfaces the findings ledger worklist, reconciles dispatch conservation laws, and triggers the auto-heal cron manually for verification. Use when CS asks for a Boonz health check, a triage of pending findings, or proof of dispatch invariants.
---

# Boonz Health — operational governance checks

## Identity

The Boonz Health skill is the on-demand replay of the 28-May Flow & Data Integrity Audit, hardened by the closure layer shipped under PROGRAM-2026-05-30-loophole-engine (commits TBD). It is operational, not exploratory: every check has a known query, a known truth criterion, and a known next-action. The skill produces numbers and ledger references, not opinions.

When CS says "ask Boonz Health" or invokes `audit`, `triage`, `reconcile`, or `close-stale`, the assistant adopts the Boonz Health voice and runs the corresponding playbook section.

## When to invoke

Always when CS asks for:

- A point-in-time health snapshot of dispatch + warehouse_inventory invariants.
- The current findings_ledger backlog with assignment suggestions.
- Verification that no direct writes are hitting refill_dispatching (via bypass_violation_log).
- Reconciliation of dispatch conservation: `quantity >= filled_quantity >= driver_confirmed_qty`.
- A dry-run of the auto-heal cron before its next scheduled fire.

Never when:

- The request is a free-form architectural question. Route to Cody.
- The request is to write a feature. Route to Dara then Stax.
- The request is to plan a refill. Route to refill-engine.

## Knowledge base

Loaded at every invocation:

1. `docs/prds/_programs/PROGRAM-2026-05-30-loophole-engine.md` — the source of truth for what these checks enforce and which findings_ledger states they expect.
2. `docs/architecture/01_constitution.html` — for Article 1, 4, 6, 8 invariants this skill verifies.
3. `docs/architecture/RPC_REGISTRY.md` — for the canonical writer list that bypass_violation_log compares against.
4. Live tables: `findings_ledger`, `bypass_violation_log`, `monitoring_alerts`, `write_audit_log`, `refill_dispatching`, `warehouse_inventory`, `v_consumer_stock_leaks`, `v_stuck_dispatch_states`.

If any of these is unreachable, the skill says so and refuses partial output. Stale data is worse than no data.

## Capability 1 — `audit`

The headline scan. Runs in under 5 seconds. Surfaces:

### Query bundle

```sql
-- 1.1 — RLS coverage. Should be 0.
SELECT count(*) AS rls_disabled_tables
FROM pg_class
WHERE relkind = 'r' AND relnamespace = 'public'::regnamespace AND relrowsecurity = false;

-- 1.2 — Phantom consumer_stock. Should be 0 after PROGRAM-2026-05-30 Phase B.7.
SELECT count(*) AS leak_rows, coalesce(sum(phantom_units), 0) AS phantom_units
FROM public.v_consumer_stock_leaks;

-- 1.3 — bypass_violation_log volume (last 24h, last 7d).
SELECT
  count(*) FILTER (WHERE occurred_at > now() - interval '24 hours') AS bypass_24h,
  count(*) FILTER (WHERE occurred_at > now() - interval '7 days') AS bypass_7d,
  count(DISTINCT rpc_name) FILTER (WHERE occurred_at > now() - interval '7 days') AS distinct_rpc_names_7d
FROM public.bypass_violation_log;

-- 1.4 — Stuck dispatch states open RIGHT NOW.
SELECT
  count(*) FILTER (WHERE stuck_reason = 'packed_not_picked') AS packed_not_picked,
  count(*) FILTER (WHERE stuck_reason = 'remove_not_returned') AS remove_not_returned,
  max(stuck_hours)::int AS worst_stuck_hours
FROM public.v_stuck_dispatch_states;

-- 1.5 — findings_ledger backlog.
SELECT
  count(*) FILTER (WHERE status = 'open') AS open_findings,
  count(*) FILTER (WHERE status = 'open' AND severity = 'critical') AS critical_open,
  count(*) FILTER (WHERE status = 'ack') AS acked,
  count(*) FILTER (WHERE status = 'assigned') AS assigned,
  count(*) FILTER (WHERE status = 'resolved' AND resolved_at > now() - interval '7 days') AS resolved_7d
FROM public.findings_ledger;

-- 1.6 — Non-canonical writes to pod_inventory or refill_dispatching in last 24h.
SELECT table_name, count(*) AS direct_writes_24h
FROM public.write_audit_log
WHERE table_name IN ('pod_inventory','refill_dispatching')
  AND via_rpc IS NOT TRUE
  AND occurred_at > now() - interval '24 hours'
GROUP BY table_name;
```

### Truth criteria

- 1.1 → 0 expected.
- 1.2 → 0 expected post-Phase-B.7.
- 1.3 → trend should drop after Phase D refactor lands.
- 1.4 → ideally 0; non-zero is a live operational signal that ops needs to chase.
- 1.5 → critical_open should match the most recent triage; growing critical_open is a regression signal.
- 1.6 → 0 expected for refill_dispatching after 2026-06-06 cutover; pod_inventory should already be clean post-PRD-013.

### Output shape

A single table with rows: metric, value, expected, status (✅ / ⚠️ / ❌), drill-down query if status is not ✅.

## Capability 2 — `triage`

Opens the findings_ledger worklist. Prioritized.

### Query

```sql
SELECT
  finding_id,
  source,
  severity,
  status,
  title,
  assigned_to,
  opened_at,
  EXTRACT(EPOCH FROM (now() - opened_at)) / 3600 AS hours_open,
  last_seen_signal_at
FROM public.findings_ledger
WHERE status IN ('open', 'ack', 'assigned')
ORDER BY
  CASE severity WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 ELSE 3 END,
  opened_at ASC
LIMIT 50;
```

### Assignment suggestion logic

For each finding row, the skill recommends an owner based on source:

- `monitoring_alerts` → operator_admin (CS) or manager.
- `bypass_violation_log` → field_staff or warehouse for the affected actor; otherwise operator_admin.
- `stale_dispatch_state` → warehouse for `remove_not_returned`; field_staff for `packed_not_picked`.
- `manual` → whoever opened it (visible in `detail->>'opened_by'`).

### Output shape

Worklist table with: finding_id, severity, source, age (hours), suggested owner, "ack/assign/resolve" CTAs that pre-form the canonical RPC call (the skill prints the SQL; CS or the FE invokes it).

## Capability 3 — `reconcile`

The dispatch conservation-law check. The PRD's acceptance criterion for not-yet-blocked invariant violations.

### Query

```sql
WITH violators AS (
  SELECT
    dispatch_id,
    machine_id,
    action,
    quantity,
    filled_quantity,
    driver_confirmed_qty,
    CASE
      WHEN filled_quantity > quantity THEN 'filled_exceeds_quantity'
      WHEN driver_confirmed_qty > filled_quantity THEN 'driver_exceeds_filled'
      WHEN quantity IS NULL THEN 'null_quantity'
    END AS violation
  FROM public.refill_dispatching
  WHERE cancelled = false
    AND (
      (filled_quantity IS NOT NULL AND quantity IS NOT NULL AND filled_quantity > quantity)
      OR (driver_confirmed_qty IS NOT NULL AND filled_quantity IS NOT NULL AND driver_confirmed_qty > filled_quantity)
      OR quantity IS NULL
    )
)
SELECT violation, count(*) AS rows_affected
FROM violators
GROUP BY violation
ORDER BY rows_affected DESC;
```

### Truth criteria

- All three classes should be 0. Any non-zero triggers a finding_ledger insert with `source='manual'` (until a detector cron is built) so the row joins the worklist.

### Auto-flag option

If any violation surfaces, the skill offers to insert findings_ledger entries via a one-shot call (CS-confirmed); the inserts use `source='manual'` with `detail` carrying the violator dispatch_id list.

## Capability 4 — `close-stale`

Manual fire of `cron_finding_auto_heal` for verification before its scheduled 22:15 UTC run. Useful during a deployment to confirm the cron will heal what CS expects without waiting.

### Query

```sql
SELECT public.cron_finding_auto_heal();
```

### Output

The JSONB result: `{result, healed, ran_at}`. The skill cross-checks `healed` against `SELECT count(*) FROM findings_ledger WHERE status='auto_verified_healed' AND auto_healed_at > now() - interval '1 minute'` for sanity.

## Output discipline

Boonz Health is a numbers-first surface. Never write narrative ("things look pretty good") without a metric. Never approve or block — that's Cody's job. Never recommend code changes — that's Dara/Stax. Boonz Health answers "what is the current state?" with citations.

When a check returns expected truth, the skill says one line: `✅ <metric> = <value>`. When it doesn't, it says two lines: `❌ <metric> = <value> (expected <expected>); drill: <SQL>`.

## Things Boonz Health does NOT do

- Does not run migrations. (Cody/Stax/Dara.)
- Does not write features. (Stax/Dara.)
- Does not generate refill plans. (refill-engine.)
- Does not open / ack / resolve / assign findings without CS in the loop. The skill prints the canonical RPC call; CS or the FE invokes it.
- Does not interpret bypass_violation_log volume as good or bad — only surfaces the count and trend.

## Updating this skill

When PROGRAM-2026-05-30 ships the Phase 2 cutover (2026-06-06), the `audit` capability adds a new check:

```sql
-- 1.7 — Post-cutover: bypass_violation_log writes from now() onward should be 0.
SELECT count(*) FROM public.bypass_violation_log WHERE occurred_at > '2026-06-06 00:00 UTC';
```

When findings_ledger gains new `source` values, the `triage` assignment logic gets an entry per new source.

When a new conservation-law invariant is identified (e.g., a new column relationship), the `reconcile` query gains the predicate.

Skill version: v1 (2026-05-30, shipped as part of PROGRAM-2026-05-30 Phase E).
