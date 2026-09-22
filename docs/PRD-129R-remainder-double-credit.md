# PRD-129R — Warehouse remainder double credit

**Owner:** CS
**Written:** reconstructed 2026-09-22 by Claude Code (see "A note on this document" at the bottom)
**Status:** CLOSED 2026-09-22 (C5 fixed via prd129r_04, all five acceptance checks pass)

---

## 1. Problem

`receive_dispatch_line` computes `v_return_delta = planned - filled` and credits
`warehouse_stock` with it inline, either through the `v_consumer_row` combined UPDATE or one of
the `v_wh_row` fallback branches. It never set `remainder_credited`. Its own closing UPDATE then
sets `item_added = true`, which fires `trg_credit_dispatch_remainder` (AFTER UPDATE OF
`item_added`), which calls `tg_credit_dispatch_remainder_on_receive()`, which sees
`remainder_credited` still false and calls `credit_dispatch_remainder()`, crediting the
identical remainder a second time.

Every partial-fill event since 2026-07-06 doubled: 208 of 208 partial-fill events, 537 phantom
units across 59 products fleet-wide, 255 units across 91 product/batch rows in `WH_CENTRAL`
alone.

A second, independent bug in the same area: `credit_dispatch_remainder` wrote its own explicit
`inventory_audit_log` row after crediting `warehouse_stock`, while
`auto_audit_warehouse_inventory()` (the `AFTER UPDATE` trigger on `warehouse_inventory`) already
logs the same UPDATE via the `app.mutation_reason` this function sets beforehand. Every
remainder credit was writing two `inventory_audit_log` rows for one stock change.

## 2. Root cause

R1. `receive_dispatch_line`'s closing UPDATE sets `item_added = true` without also setting
`remainder_credited = true` in the same statement, so the trigger that fires off `item_added`
still sees `remainder_credited = false` and re-credits.

R2. `credit_dispatch_remainder` duplicates the audit log entry that the `warehouse_inventory`
UPDATE trigger already writes.

## 3. Fix

### prd129r_01_receive_marks_credited

`receive_dispatch_line`'s closing UPDATE now sets `remainder_credited = true` in the same
statement that sets `item_added = true`. Nothing else in the function changes.
`tg_credit_dispatch_remainder_on_receive()`'s own guard is `AND NOT
COALESCE(NEW.remainder_credited,false)` — once this UPDATE sets both columns in one statement,
`NEW.remainder_credited` is already true by the time the trigger evaluates `NEW`, so
`credit_dispatch_remainder()` is never invoked from the trigger path for a fresh receive.
`credit_dispatch_remainder()` itself is untouched by this step and still returns `already_done`
if called directly afterwards, since it checks the same column at its own top.

Verified in a rolled-back transaction before applying: a line planned 8, filled 3, from a pinned
`wh_inventory_id` produced exactly one `warehouse_stock` increment of 5 (not 10), exactly one
`refill_dispatching` row with `remainder_credited = true`, and a direct call to
`credit_dispatch_remainder()` on that dispatch afterwards returned `already_done`.

### prd129r_02_single_log

Removed the explicit `INSERT INTO inventory_audit_log` from `credit_dispatch_remainder`. The
trigger-driven log (`auto_audit_warehouse_inventory()`) is kept as-is. One row per credit going
forward.

### prd129r_03_guards_and_cron / prd129r_03b_fix_g_remainder_scope

Two new guards added to `check_machine_health_integrity()`:

- **G-REMAINDER**: flags a dispatch where credits logged against it (via
  `inventory_audit_log.source_event_id`, filtered to the two reason prefixes the remainder-credit
  mechanism actually writes: `'B3 receive:'` and `'A3 remainder credit'`) sum to more than
  `quantity - filled_quantity`. Scoped to `action IN ('Refill','Add New','Add')`, not M2M, not
  `returned` — `Remove` and whole-line-`returned` dispatches credit the full `filled_quantity`,
  not a remainder, so comparing them against `quantity - filled_quantity` is not meaningful
  (mirrors `credit_dispatch_remainder`'s own exclusions).
- **G-AUDIT-STALE**: flags a `warehouse_audit_baseline` row with `counted_units` still NULL more
  than 48 hours after `audit_date`.

A first pass at G-REMAINDER (`03`) produced 799 hits instead of the expected ~208, from two real
scope bugs: `source_event_id` is reused broadly as a general dispatch-traceability tag (pack-time
debits and one-off manual corrections also carry it), and `Remove`/M2M/`returned` dispatches
were being compared against a remainder concept that does not apply to them. `03b` is a separate
migration carrying the corrected, identical function body, kept distinct from `03` on purpose so
the repo records the in-session bug-and-fix as two real `apply_migration` calls rather than
silently merging it into one migration as if the bug never shipped.

`check_machine_health_integrity()` is also scheduled nightly via `pg_cron` (job **82**,
`prd129r_machine_health_integrity_0330_dubai`, schedule `30 23 * * *` = 23:30 UTC = 03:30 Dubai),
writing to a new `machine_health_integrity_results` table instead of returning to a caller — the
function takes roughly 3 minutes end to end (see section 5 for why), so nothing in the app
should ever call it synchronously.

No corrective stock adjustment was written for the 208 historical double-credits. The recount
pack (`docs/ops/PRD-129R_recount_pack_2026-09-21.xlsx`) is the source of truth for reconciling
them, including a second sheet on 7 `dispatch_return` credits to `WH_CENTRAL` on 2026-09-21 that
should have gone to AMZ-1038/AMZ-1029 per the matching Add New lines' comments (5 of 7 resolved;
2 NOOK-sourced ones have no matching Add New line and are flagged, not guessed).

Writer RPCs (`write_refill_plan`, `validate_refill_plan`, `approve_refill_plan`,
`push_plan_to_dispatch`, `add_dispatch_row`, `edit_dispatch_qty`) and the planner engine are
untouched.

## 4. Acceptance criteria

| #   | Criterion                                                                                                     |
| --- | ------------------------------------------------------------------------------------------------------------- |
| C1  | `receive_dispatch_line` sets `remainder_credited` on the `item_added` update                                  |
| C2  | `credit_dispatch_remainder` has no explicit INSERT (single log line per event)                                |
| C3  | pg_cron jobid 82 at `30 23 * * *`, active                                                                     |
| C4  | G-REMAINDER returns 208 for the 2026-07-06 to 2026-09-21 window and 0 for anything after 2026-09-21 18:20 UTC |
| C5  | G-AUDIT-STALE returns 0                                                                                       |

## 5. Verified on 2026-09-22

**C1 — receive_dispatch_line sets remainder_credited on the item_added update: PASS**

```sql
SELECT pg_get_functiondef('public.receive_dispatch_line(uuid,numeric,uuid,jsonb,boolean,text)'::regprocedure)
  LIKE '%remainder_credited = true%' AS receive_sets_remainder_credited;
```

Result: `true`. The live closing UPDATE reads:

```sql
UPDATE refill_dispatching
   SET filled_quantity = p_filled_quantity, item_added = true, dispatched = true, packed = true,
       picked_up = true, remainder_credited = true, pack_outcome = ...
 WHERE dispatch_id = p_dispatch_id;
```

Matches the migration file exactly, live in the database.

**C2 — credit_dispatch_remainder has no explicit INSERT: PASS**

```sql
SELECT pg_get_functiondef('public.credit_dispatch_remainder(uuid,uuid)'::regprocedure)
  LIKE '%INSERT INTO public.inventory_audit_log%' AS credit_has_explicit_insert;
```

Result: `false`. The live function body has no `INSERT INTO inventory_audit_log` anywhere;
it only issues `UPDATE public.warehouse_inventory` and `UPDATE public.refill_dispatching`.

**C3 — pg_cron jobid 82: PASS**

```sql
SELECT jobid, jobname, schedule, active FROM cron.job WHERE jobid = 82;
```

Result: `{"jobid":82,"jobname":"prd129r_machine_health_integrity_0330_dubai","schedule":"30 23 * * *","active":true}`

**C4 — G-REMAINDER windowed counts: PASS, with a performance caveat**

Running `check_machine_health_integrity()` itself times out interactively (it joins
`get_machine_health()` twice and `get_machine_slots_with_expiry()` once per Active machine,
documented in its own header as a ~3 minute batch job). So G-REMAINDER's own SQL block was
extracted and run standalone. That also timed out unwindowed (30,006 candidate dispatch rows
cross-joined against a 25,083-row `inventory_audit_log` with **no index on
`inventory_audit_log.source_event_id`** — every candidate row forces a sequential scan; this is
almost certainly the real reason the full check takes 3 minutes, not the get_machine_health
calls, and is a new finding, not something PRD-129R asked to fix). Windowing by `dispatch_date`
made both runs fast:

```sql
-- 2026-07-06 to 2026-09-21
SELECT count(*) FROM refill_dispatching rd
JOIN machines m ON m.machine_id = rd.machine_id
CROSS JOIN LATERAL (
  SELECT COALESCE(SUM(GREATEST(ial.new_qty - ial.old_qty, 0)), 0) AS total_credited
  FROM inventory_audit_log ial
  WHERE ial.source_event_id = rd.dispatch_id
    AND (ial.reason ILIKE 'B3 receive:%' OR ial.reason ILIKE 'A3 remainder credit%')
) cr
WHERE rd.item_added = true AND rd.action IN ('Refill','Add New','Add')
  AND NOT COALESCE(rd.is_m2m, false) AND NOT COALESCE(rd.returned, false)
  AND rd.dispatch_date >= '2026-07-06' AND rd.dispatch_date <= '2026-09-21'
  AND cr.total_credited > GREATEST(COALESCE(rd.quantity,0) - COALESCE(rd.filled_quantity,0), 0);
```

Result: **208**. Matches exactly.

```sql
-- after the fix, restricted to dispatch_date >= 2026-09-21 to keep the lateral join tractable,
-- with the actual cutoff enforced on the credit timestamp itself
SELECT count(*) FROM refill_dispatching rd
JOIN machines m ON m.machine_id = rd.machine_id
CROSS JOIN LATERAL (
  SELECT COALESCE(SUM(GREATEST(ial.new_qty - ial.old_qty, 0)), 0) AS total_credited,
         MAX(ial.audited_at) AS last_credit_at
  FROM inventory_audit_log ial
  WHERE ial.source_event_id = rd.dispatch_id
    AND (ial.reason ILIKE 'B3 receive:%' OR ial.reason ILIKE 'A3 remainder credit%')
) cr
WHERE rd.item_added = true AND rd.action IN ('Refill','Add New','Add')
  AND NOT COALESCE(rd.is_m2m, false) AND NOT COALESCE(rd.returned, false)
  AND rd.dispatch_date >= '2026-09-21'
  AND cr.last_credit_at > '2026-09-21 18:20:00+00'
  AND cr.total_credited > GREATEST(COALESCE(rd.quantity,0) - COALESCE(rd.filled_quantity,0), 0);
```

Result: **0**. Matches exactly.

Neither run is the literal unwindowed guard query the nightly cron job runs (that one could not
be executed interactively within this session's query timeout). The `dispatch_date >= 2026-09-21`
prefilter on the second query is a reasonable proxy (receiving happens same day or shortly after
dispatch), not a guarantee it covers every dispatch ever credited after the cutoff regardless of
its own dispatch_date — flagging this rather than presenting it as the exact same query the cron
job runs.

**C5 — G-AUDIT-STALE returns 0: initially FAIL (145), now PASS after prd129r_04**

```sql
SELECT count(*) FROM warehouse_audit_baseline wab
WHERE wab.counted_units IS NULL AND wab.audit_date::timestamptz < now() - interval '48 hours';
```

Result: **145**, not 0. All 145 are `warehouse_audit_baseline` rows dated 2026-09-14, all still
uncounted (confirmed: `count(*)=145`, `count(*) FILTER (WHERE counted_units IS NULL)=145`,
`min(audit_date)=2026-09-14`, `max(audit_date) FILTER (WHERE counted_units IS NULL)=2026-09-14`
— a single batch, none of it entered). The guard was working correctly; the underlying recount
from 2026-09-14 was never completed.

CS's decision: do not fabricate `counted_units`. No canonical audit close/cancel RPC existed
(checked `pg_proc` for `%audit%close%`/`%audit%cancel%`/`%audit%abandon%`, none found), so
`prd129r_04_close_abandoned_audit.sql` adds `close_abandoned_warehouse_audit(p_audit_date,
p_reason, p_caller_id)` plus three new columns (`abandoned_at`, `abandoned_by`,
`abandoned_reason`) on `warehouse_audit_baseline`. It marks a still-uncounted row abandoned
without touching `counted_units` — the row still honestly shows "never counted," it just stops
being an open, unresolved audit. `G-AUDIT-STALE` was updated to exclude abandoned rows.

Run 2026-09-22:

```sql
SELECT close_abandoned_warehouse_audit('2026-09-14', 'abandoned, never counted, superseded by 2026-09-23 recount', '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d');
-- {"status":"ok","audit_date":"2026-09-14","rows_abandoned":145,"reason":"abandoned, never counted, superseded by 2026-09-23 recount"}

SELECT count(*) FROM warehouse_audit_baseline
WHERE counted_units IS NULL AND abandoned_at IS NULL AND audit_date::timestamptz < now() - interval '48 hours';
-- 0
```

**PASS.**

## A note on this document

This file did not exist anywhere in the repository or its git history before this reconstruction
(verified: filename search across the whole working tree and `git log --all`, both empty). The
problem, root cause, and fix sections above are reconstructed from the SQL comments inside
`supabase/migrations/20260921180113_prd129r_01_receive_marks_credited.sql`,
`20260921180134_prd129r_02_single_log.sql`, `20260921180221_prd129r_03_guards_and_cron.sql`,
`20260921181730_prd129r_03b_fix_g_remainder_scope.sql`, the single commit unique to branch
`prd129r-warehouse-remainder-double-credit` (`28b1488`, "fix(prd-129r): stop the warehouse
remainder double credit"), and `supabase/rollback/prd129r_00_rollback.sql`. All of these sources
agree word for word on the root cause and the fix, so no interpretive judgment calls were needed
here the way PRD-127's reconstruction required. Section 5's verification, including the failing
G-AUDIT-STALE check and the missing index on `inventory_audit_log.source_event_id`, is new
information produced by this reconstruction, not carried over from any prior source.
