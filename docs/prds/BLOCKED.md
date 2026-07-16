# BLOCKED — HUAWEI-2003-0000-B1 rebind (2026-07-16 ~10:10 UTC)

## Why (per the task's hard-stop rule: guard still blocks after Task 1)
`rebind_slot_lifecycle_from_weimi` still skips HUAWEI (`skipped_live_plan_machines`)
because its live-plan guard locks any machine with an OPEN dispatch line
(cancelled=false AND include=true AND picked_up=false AND dispatch_date >= today).
Three legitimate rows from today's visit are still open — A03 Healthy Cola x1,
A10 Barebells x1, A16 Vitamin Well x1 (all packed=false, include=true). The Caprice
row is NOT the blocker. Suppressing those three would cancel possibly-legitimate
pending work; out of this task's scope ("cancel only the single Caprice row").
The guard keys on open-line state, exactly as designed — not on plan status.

## Task 1 state: already satisfied before this task ran
The orphan Caprice A08 row (fdb39ced) was ALREADY neutralized at 2026-07-16 04:42 UTC
via the canonical skip path: skipped=true, include=false,
skip_reason 'CS: cancel +1 Caprice refill, A08 Caprice expiring 07-17, swapping to
Dates'. Skipped lines are inert (PRD-028: pack refuses unconditionally). Judgement
call: NOT double-cancelled via cancel_dispatch_line — skip is reversible
(unskip_dispatch_line) and already carries the drift-referencing reason.

## The 20:00-Dubai-halt premise is STALE — no emergency
Verified from live pg_proc: p0_fix2 + p0_fix12 (2026-07-12/13) replaced PRD-CLEAN-09's
global halt. Tonight engine_add_pod will AUTO-PLAN the two drifted HUAWEI shelves from
the TRUE WEIMI identity (A06 Plaay 35g, A08 Freakin Awesome Filled Dates) as cold
start + raise a critical monitoring alert; engine_swap_pod per-shelf-skips them.
HUAWEI is picked for 2026-07-17 → expect ONE 'engine_add_pod_binding_drift' critical
alert tonight, with a CORRECT plan. No halt, no wrong-product lines.

## To resume (one line, after the EOD sweep clears the 3 open rows)
eod_auto_release_unpicked runs 19:59 UTC daily. Any time after that (or tomorrow):
```sql
SELECT rebind_slot_lifecycle_from_weimi(
  (SELECT ARRAY[machine_id] FROM machines WHERE official_name='HUAWEI-2003-0000-B1'),
  false,
  'Post-swap rebind: A06 -> Plaay Tablets - Mix 35g, A08 -> Freakin Awesome Filled Dates. Swaps dispatched 2026-07-16; slot_lifecycle was stale.');
```
Dry-run first if desired (p_dry_run=true; expect exactly 2 inserts, HUAWEI only).
Then confirm SELECT COUNT(*) FROM v_slot_binding_drift = 0.
