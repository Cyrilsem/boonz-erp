# /goal - PRD-019 (condensed, <4000 chars). Paste into Claude Code in boonz-erp.

```
/goal Implement PRD-019 for boonz-erp (Next.js + Supabase eizcexopcuoycuosittm). Read first: docs/prds/refill-pipeline/PRD-019-conductor-capacity-commit-visibility.md. Phases in priority order: D1 -> A -> C -> B -> D2-5.

RULES
- RPC bodies live in Supabase, not the repo. Fetch via pg_get_functiondef before editing; base each migration on the live body. Never guess a signature.
- Forward-only migrations (ts prefix); no _v2 / edit-in-place. Every SECURITY DEFINER writer sets app.via_rpc + app.rpc_name, validates role + inputs, uses the audit trigger.
- Protected entities (pod_refill_plan, refill_plan_output, refill_dispatching, machines_to_visit, product_mapping, shelf_configurations, planogram): Cody verdict per writer/DDL. Schema -> dara, FE -> stax.
- NEVER raw UPDATE/INSERT/DELETE on a protected table; go through a canonical RPC. Never cut a qty or reduce stock without a per-row diff + CS sign-off. Archive, never DELETE.
- Author migration FILES only; apply NOTHING to prod. Per phase: Cody verdict, SQL + diff, STOP for sign-off. No em dashes.

PHASE D1 - single-writer lock (ship first; this prevents the chat/FE collision)
D1a New table refill_plan_lock(plan_date pk, locked_by, locked_at, context) + DEFINER acquire_refill_plan_lock(plan_date,context) / release_refill_plan_lock(plan_date). Commit AND chat-engine both acquire; second caller rejected with a clear error.
D1b Guard the engine: engine_add_pod / engine_swap_pod / engine_finalize_pod REFUSE to run for a plan_date that has any refill_plan_output row past 'pending', or while the lock is held by another context. Patch each via pg_get_functiondef first.

PHASE A - capacity-aware fills (AC-A1..A4)
A1 Dara view v_shelf_capacity: per shelf_id -> max_stock, current_stock, headroom (max-current), size_class, current product. max from shelf_configurations/planogram, current from v_live_shelf_stock.
A2 Patch add_pod_refill_row + edit_pod_refill_row: clamp qty so current_stock+qty <= max_stock; return clamp_reason='capacity_capped' with the cap. No silent over-fill.
A3 ADD_NEW multi-variant: default target = headroom; return projected per-flavor + per-batch line count so the caller can confirm. Document the seed convention in B.

PHASE C - compact all-rows planning view (AC-C1..C4)
C1 Dara view v_refill_planning_compact: ALL slots A01-A16 per machine, one row: slot, product, stock x/max, fill_pct, stance, global+local badge, sales_7d, final_score, planned action+qty, wh_availability (sellable reserve-aware WH stock for the shelf product; flag 0), comments/upsert fields. Default sort fill_pct asc.
C2 Stax: add the compact table to /refill RefillPlanningTab (all rows; sort toggles Slot/Stock/Fill/Expiry already exist), the WH Availability column, inline comments/upsert. npx next build.

PHASE B - conductor execution kit (AC-B1..B4)
B1 Author docs/architecture/RPC_EXECUTION_KIT.md: for every daily-flow write RPC (pick, confirm, add, swap, edit, stop, finalize plan-wide + scoped, approve_pod, stitch dry+commit, approve_refill, reset_approved_undispatched, reset_and_restitch, unpick, receive_purchase_order, product_mapping setup) give exact signature (from pg_get_functiondef), gate tripped, service-context auth behaviour, gotcha. Include order-of-ops for full route / Path C / post-commit. Stamp a 'last validated' date.

PHASE D2-5 - atomic, verified, scoped commit
D2 FE Commit chain atomic (single txn or saga w/ rollback); never land pod 'stitched' with empty output.
D3 Commit finalize scoped to committed machines only (no plan-wide un-approve). Always run approve_refill_plan as the final step (fire dispatch bridge).
D4 FE banner reports VERIFIED refill_plan_output + refill_dispatching counts, not intent. Add post-commit check: every approved machine has >=1 dispatch row, no duplicate 'pending' on dispatched machines.

OUTPUT per phase: Cody verdicts, migration files, diffs, apply order, STOP for CS. Log each AC met.
```
