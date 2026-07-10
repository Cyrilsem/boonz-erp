# PRD-087 — "Last plan" clock must mean _executed_, so planned = visited

Status: CLOSED 2026-07-10 - SUPERSEDED by PRD-088. The dispatched=true narrowing shipped 2026-07-08 (migration 20260708163722) but is no longer in the live function: the PRD-088 clock-unification replaced the plan_data CTE entirely. Historical record only.

**Date:** 2026-07-08
**Status:** DRAFT → ready (backend: one function; routes through Cody per Article on canonical readers)
**Scope:** `get_machine_health()` — the `plan_data` CTE only. Optional 1-line FE relabel in SnapshotTab.
No migration to data, no write-path change.

---

## Problem

The machine health card shows two clocks side by side (SnapshotTab ~L1657–1674):

- **`last visit Xd`** — canonical, correct.
- **`last plan Yd`** — misleading.

`last plan` = `today − MAX(refill_plan_output.plan_date WHERE operator_status='approved')`. It counts a
plan the moment it's **approved**, whether or not it was ever dispatched/serviced. So a machine can read
a fresh "last plan" without having been visited — and, conversely, a genuinely serviced machine shows a
"planned" number that reads like a separate, competing status. CS: _"a planned should be executed… fix
it so planned = visited if the plan is dispatched and complete."_

## Why the visit clock is already right (no change needed there)

`v_machine_health_signals.days_since_visit` (feeds `get_machine_health.days_since_visit`) is already
`today − GREATEST(last_executed_dispatch, last_manual_refill)`:

- `last_executed_dispatch` = MAX(`refill_dispatching.dispatch_date`) where the line is packed / picked_up
  / dispatched / returned and not cancelled/skipped.
- `last_manual_refill` = MAX(`pod_inventory_audit_log.created_at`) for `manual-refill-%` / `adjust-%`.

So both engine dispatches **and** on-spot manual refills (e.g. the boonz-manual-refill skill's
`adjust_pod_inventory` writes) already register as a visit. That clock is the source of truth for
"when was this machine last serviced." Leave it as-is.

## Fix — make the "planned" clock execution-based

In `get_machine_health()`, `plan_data` CTE, require the plan to be **executed** (dispatched):

```sql
plan_data AS (
  SELECT rpo.machine_name, MAX(rpo.plan_date) AS last_plan_date
  FROM refill_plan_output rpo
  WHERE rpo.operator_status = 'approved'
    AND rpo.plan_date <= CURRENT_DATE
    AND rpo.dispatched = true          -- ← NEW: only plans that were actually pushed/executed
  GROUP BY rpo.machine_name
)
```

Effect: `last_plan_date` now = the last plan that was **dispatched & executed**. For a dispatched+complete
refill this equals the visit date → **planned = visited**. An approved-but-never-dispatched plan no longer
inflates the clock. (Manual on-spot refills stay visible through `last visit`, which already counts them.)

Verified against live data (2026-07-08): VOXMCC-1011 has 16 dispatched lines for 08/07 → `last_plan_days`
becomes 0, matching `last visit 0d`. Its 3 approved-but-undispatched manual-log lines no longer make the
plan clock diverge.

## FE (optional, tiny)

Keep `last visit` as the primary chip. Relabel `last plan Yd` → `last executed Yd` (or hide it when it
equals `last visit`) so the two never read as competing statuses. `SnapshotTab.tsx` ~L1670.

## Acceptance

- For any machine dispatched+complete today, `last plan days == last visit days`.
- A machine with an approved-but-undispatched plan does **not** show a "planned" number more recent than
  its real visit.
- Manual-only refills still show `last visit 0d`.
- No change to `days_since_visit`, to any write path, or to data.

## Rollback

`CREATE OR REPLACE FUNCTION get_machine_health()` reverting the one WHERE clause. No data to undo.
