# PRD-088 — A manual refill IS an executed plan: unify the plan clock with the visit clock

**Date:** 2026-07-08
**Status:** DRAFT → ready (backend: `get_machine_health()` only; Cody review — canonical reader)
**Supersedes:** the `dispatched = true` narrowing shipped in PRD-087 (that split manual refills back out).
**Scope:** `get_machine_health()` — how `last_plan_date` / `last_plan_days` are produced. No data change,
no write-path change, `days_since_visit` untouched.

---

## Problem / principle (from CS)

"A manual refill is a visit **and** a dispatch plan — they're done the same. One happened in the
planning session, the other as an ad-hoc / last-minute decision. They are the same." So the health card
must not show `last plan` diverging from `last visit`. PRD-087 made `last plan` = last _dispatched_ plan,
which correctly killed the approved-but-never-serviced inflation, but it also made a **manual** refill
(which is a real service) NOT count as a plan — so machines serviced on-spot read e.g. `last visit 1d`
but `last plan 2d`. That divergence is the bug this PRD closes.

## The single source of truth already exists

`get_machine_health.days_since_visit` (from `v_machine_health_signals`) is
`today − GREATEST(last_executed_dispatch, last_manual_refill)` — it already treats a dispatched plan and
an on-spot manual refill as the same servicing event. That is the canonical "machine was serviced" clock.

## Fix — make the plan clock mirror the visit clock

In `get_machine_health()`, stop computing `last_plan_date/last_plan_days` from `refill_plan_output` and
instead derive them from the same canonical service evidence as `days_since_visit` (the `hs` join already
in the function). Concretely, the two output columns become:

```sql
-- last_plan_date  (was: MAX(plan_date) FILTER approved [+dispatched]) → mirror the service clock:
CASE WHEN hs.days_since_visit IS NULL OR hs.days_since_visit < 0
     THEN NULL
     ELSE (CURRENT_DATE - hs.days_since_visit) END,          -- last_plan_date
-- last_plan_days:
COALESCE(hs.days_since_visit, -1)::int,                      -- last_plan_days
```

The `plan_data` CTE (and its `pld` join) can be dropped, since the value now comes from `hs`.

Result: `last_plan_days == days_since_visit` for **every** machine — a dispatched plan and a manual refill
both count, identically. Planned = visited, full stop.

## FE follow-up (cosmetic, not required for correctness)

With the numbers now identical, the `last plan {n}d` chip in `SnapshotTab.tsx` (~L1670) is redundant — it
can simply be removed, leaving the single `last visit {n}d`. (Owned by the `feat/prd-087-ui-uplift`
branch; let it ride that train.) Correctness no longer depends on the FE: even if the chip stays, it now
shows the same number as `last visit`.

## Acceptance

- For every Active machine, `last_plan_days == days_since_visit` (verify md5/row-diff = 0 mismatches).
- ADDMIND-1007 / HUAWEI-2003 / MINDSHARE-1009 (manual-refill visits): `last plan` now equals `last visit`
  (1d, not 2d).
- `days_since_visit` values unchanged vs before; no write path, RPC, or data touched.

## Rollback

`CREATE OR REPLACE FUNCTION get_machine_health()` restoring the prior `plan_data` CTE + `pld` columns.
No data to undo.
