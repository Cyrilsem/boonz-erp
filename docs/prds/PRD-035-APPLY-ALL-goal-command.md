# Claude Code /goal Command — PRD-035 APPLY-ALL (one run, replay-gated, no manual stops)

**Prerequisite:** in Claude Code settings add a permission rule allowing `mcp__supabase__apply_migration` (else the auto-mode classifier blocks each apply and it falls back to manual). Phase A is already applied to prod, so this run does **C → B → D → E**. Each phase applies only if its own rolled-back replay passes; the whole run aborts on any failing check. No per-phase human STOP.

```
/goal Apply the remaining PRD-035 phases in ONE autonomous run, order C -> B -> D -> E (Phase A already applied to prod). Read docs/prds/PRD-035-APPLY-RUNBOOK.md and PRD-035-EXECUTION-LOG.md first. Supabase eizcexopcuoycuosittm. No em dashes. Do NOT stop between phases for human input; the gate per phase is its own passing replay, not a manual approval.

PER-PHASE (C, then B, then D, then E):
1. Open the migration file; reconcile the runbook validate-query key names against the actual body and fix any mismatch.
2. REPLAY inside BEGIN..ROLLBACK; evaluate every CONFIRM check for that phase.
3. If ALL checks PASS -> apply the migration to prod (apply_migration), run the read-only prod confirm, flip that phase row to APPLIED (date + AC results) in PRD-035-EXECUTION-LOG.md, then CONTINUE to the next phase automatically.
4. If ANY check FAILS -> STOP immediately; do not apply that phase or any later phase; report the failing check with its query output.

RULES
- Forward-only; no edit-in-place; no _v2. No deletes (supersede only); no qty cut without a per-row diff.
- Cody verdicts already on file (A,B approve-with-revisions re Art-16; C,D,E approve). Do not re-review; just replay-then-apply.
- C = get_refill_session_readiness (read-only, SECURITY INVOKER + STABLE). B = engine_add_pod v18. D = pick_machines_for_refill v10 + build_draft_for_confirmed Saturday-off + VOX calendar. E = engine_swap_pod v11.
- E apply MUST also run: UPDATE refill_settings SET setting_value='false' WHERE setting_key='swaps_enabled'; (it is TRUE on prod) and verify it reads false after apply.
- Per-phase AC (all must pass to apply): C verdict column populates and func is INVOKER+STABLE (no writes); B engine_version=v18, fill scales with within-machine final_score rank (top full, low+empty floor), 0 local sales=0, no stance term in qty; D picker v10, a Saturday plan_date yields 0 machines_to_visit, a Wednesday yields all VOX venue machines + 2-3 non-VOX, picks cluster by venue_group; E engine_swap_pod v11, Pass-3 swaps only when candidate-incumbent>=25 AND candidate>=50, swaps_enabled=false yields 0 Pass-3 swaps.
- Do NOT touch the Article 16 v_wh_pickable unification (separate later migration; do not half-migrate).

FINAL REPORT: per phase - replay PASS/FAIL, applied y/n + timestamp, prod confirm result; explicitly confirm refill_settings.swaps_enabled reads false after E; restate the two open follow-ups (Art-16 unification; swaps_enabled stays OFF).
```
