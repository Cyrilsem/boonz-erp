# /goal - PRD-019 fix: drop finalize from atomic commit + relax invariant (<4000 chars). Paste into Claude Code in boonz-erp.

```
/goal Correct the PRD-019 atomic commit before anything is applied. Re-author migration 20260616110417_prd019_e_commit_refill_plan_atomic.sql in place (it is NOT applied yet). Two changes.

WHY (verified against the live RPC body, do not re-debate): scoped engine_finalize_pod first does `UPDATE pod_refill_plan SET status='superseded' WHERE status='draft' AND machine_id=ANY(ids)` then rebuilds the draft from pod_refills. Any row that lives only in pod_refill_plan (every add_pod_refill_row, swap_pod_refill_row, and any edit_pod_refill_row qty change) is NOT in pod_refills, so finalize erases manual adds/swaps and reverts manual qty edits. Running it inside Commit re-introduces the PRD-018 edit-clobber bug. The reviewed draft in pod_refill_plan IS the source of truth at commit time; Commit must never re-finalize.

FIX 1 - remove engine_finalize_pod from commit_refill_plan_atomic. The chain becomes exactly:
  assert refill_plan_lock held by this context (else RAISE)
  -> approve_pod_refill_plan(p_plan_date, p_machine_names)
  -> stitch_pod_to_boonz(p_plan_date, false)
  -> approve_refill_plan(p_plan_date, p_machine_names)
  -> verify invariants -> on pass return verified counts, on fail RAISE (full rollback).
No engine_finalize_pod, no engine_add/swap. Keep the single BEGIN/EXCEPTION transaction, the lock assert, and the verified-counts return. (Finalize stays only in the BUILD path: the cron and Path C. Commit never calls it.)

FIX 2 - relax the rollback invariant from per-machine to set-level, plus a per-machine soft flag:
  HARD (rollback if violated): across the whole committed set, refill_plan_output rows > 0 AND refill_dispatching rows > 0 AND stitch lines_built > 0. This catches the empty-stitch bug.
  SOFT (report, never rollback): for each named machine that produced 0 actionable dispatch rows, add it to the returned summary as {machine, note:'committed_no_actionable_lines'}. A single dud machine (everything blocked or dropped) must NOT roll back the rest of the route. Same Complete-but-Partial principle as PRD-020.
Drop the prior "every named machine must have >=1 output AND >=1 dispatch" hard check.

SPEC SYNC: update PRD-019 AC-D4 to read "Commit never re-finalizes; the reviewed pod_refill_plan draft is the source of truth. Commit = approve_pod_refill_plan -> stitch_pod_to_boonz(false) -> approve_refill_plan, lock-wrapped." Update AC-D5 to the set-level hard invariant + per-machine soft flag. Note the change in the execution log.

KEEP AS-IS: Phase F1 (per-machine refusal, engines v2), Phase F2 (15-min TTL + force_release_refill_plan_lock), and the FE repoint to the single commit_refill_plan_atomic call wrapped by acquire/release lock. approve_pod_refill_plan before stitch stays (correct).

RULES: forward-only; re-author the unapplied 110417 in place (no new number); DEFINER writer keeps app.via_rpc/app.rpc_name + role + input validation + audit trigger; protected entities -> Cody verdict on the revised RPC; no em dashes. Apply NOTHING; show the revised SQL + diff + Cody verdict, then STOP for sign-off. After my go, apply 110411..110419 in order, then deploy the FE.
```
