# /goal - PRD-019 follow-up (atomic commit + D1 refinements, <4000 chars). Paste into Claude Code in boonz-erp.

```
/goal Follow-up to PRD-019 (boonz-erp, Supabase eizcexopcuoycuosittm). Read docs/prds/refill-pipeline/PRD-019-conductor-capacity-commit-visibility.md and docs/architecture/RPC_EXECUTION_KIT.md. This builds on the 6 already-authored migrations (D1/A/C) + the FE; it adds the atomic commit RPC and two D1 refinements, then syncs the spec.

RULES
- Fetch live RPC bodies via pg_get_functiondef before patching; base each migration on the live body. Never guess a signature.
- Forward-only migrations (ts prefix, continue the sequence after 20260616110416). Every SECURITY DEFINER writer sets app.via_rpc + app.rpc_name, validates role + inputs, uses the audit trigger.
- Protected entities (pod_refill_plan, refill_plan_output, refill_dispatching, machines_to_visit): Cody verdict per writer/DDL. Schema -> dara, FE -> stax.
- No raw UPDATE/INSERT/DELETE on a protected table. No qty cut or stock reduction without a per-row diff + CS sign-off. Author FILES only, apply NOTHING to prod; per phase: Cody verdict, SQL + diff, STOP. No em dashes.

PHASE E - atomic commit RPC (supersedes the D2 saga)
E1 New DEFINER commit_refill_plan_atomic(p_plan_date date, p_machine_names text[]) returns jsonb. In ONE BEGIN/EXCEPTION transaction, in order: assert the plan lock is held by this context (else acquire); resolve names -> machine_ids; engine_finalize_pod(p_plan_date, machine_ids) SCOPED to those machines; stitch_pod_to_boonz(p_plan_date, false); approve_refill_plan(p_plan_date, p_machine_names).
E2 Pre-COMMIT invariants: stitch lines_built > 0; every named machine has >= 1 refill_plan_output row AND >= 1 refill_dispatching row; no leftover 'pending' on the named machines. On any failure or empty stitch, RAISE so the whole transaction rolls back. Never leave pod 'stitched' with empty output.
E3 Return verified counts {output_rows, dispatch_rows, machines}. Cody: composing writer over pod_refill_plan + refill_plan_output + refill_dispatching (Articles 4,6,9,12,14).
E4 Repoint FE Commit to one call: acquire_refill_plan_lock -> commit_refill_plan_atomic -> render the returned verified counts -> release_refill_plan_lock in finally. Delete the multi-step saga path. npx next build.

PHASE F - D1 refinements
F1 Per-machine refusal (replaces the whole-date refusal). Patch assert_refill_plan_writable and the engine_add_pod / engine_swap_pod / engine_finalize_pod guards so they refuse or skip ONLY machines that already have a refill_plan_output row past 'pending'. Building a fresh machine on a date that has other dispatched machines is ALLOWED (this is the scoped-add path). Amending an already-committed machine still requires reset_approved_undispatched first. The engines skip committed machines instead of failing the whole run.
F2 Lock TTL 15 min (was 30): acquire_refill_plan_lock treats a lock older than 15 min as stale and may take it. Add DEFINER force_release_refill_plan_lock(p_plan_date date, p_reason text) gated operator_admin/superadmin, reason >= 10 chars, audited.

PHASE G - spec sync
G1 Update PRD-019 AC-D1 (per-machine refusal + 15-min TTL + force-release) and AC-D2 (commit_refill_plan_atomic is the canonical commit; saga retired). Record the new migration filenames + Cody verdicts in the execution log.

OUTPUT per phase: Cody verdict, migration files (continue 110417+), FE diff, apply order, STOP for CS sign-off. Apply nothing to prod.
```
