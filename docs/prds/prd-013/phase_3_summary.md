# PRD-013 Phase 3 Summary — Hardening (caller audit + auto-expire cron)

**Phase:** 3 (hardening)
**Status:** Shipped 2026-05-25 (partial: A.4 trigger formally deferred per G4 CS decision)
**Source PRD:** [`docs/prds/inventory/prd_013_pod_inventory_edits_canonical_approval.md`](../inventory/prd_013_pod_inventory_edits_canonical_approval.md)

## Shipped

| #    | Deliverable                                                         | Status                                                                                                                  |
| ---- | ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| P3.A | Caller audit: every direct UPDATE to pod_inventory in last 30 days  | Done. See "Caller audit findings" below. Surfaced to CS via G4 AskUserQuestion.                                         |
| P3.B | Migrate non-RPC callers found by P3.A                               | Deferred to follow-up PRD. CS decision at G4. See "Why P3.B and P3.E were deferred" below.                              |
| P3.C | Confirm 7 days clean before P3.E flip                               | Not applicable. Trigger flip deferred; 7-day clean precondition moves with it to the follow-up PRD.                     |
| P3.D | `auto_expire_pod_inventory_edits` function + pg_cron at 02:30 Dubai | Applied via `supabase/migrations/20260525230000_prd_013_auto_expire_pod_inventory_edits.sql`. Cody ✅.                  |
| P3.E | Hard-block trigger on pod_inventory direct UPDATE                   | Formally deferred per G4 CS decision. Spec retained for the follow-up PRD.                                              |
| P3.F | Section 9 tests 13-16                                               | Case 16 (auto-expire) ✅ PASS. Cases 13/14 (direct UPDATE block) deferred with P3.E. Case 15 was already ✅ in Phase 1. |

## Caller audit findings (P3.A)

Query: `write_audit_log WHERE table_name='pod_inventory' AND occurred_at > now() - interval '30 days'`, grouped by `operation, rpc_name, via_rpc, actor`.

| Pattern                                              | Count   | Last seen            | Notes                                                                                                                                                                                                                  |
| ---------------------------------------------------- | ------- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| UPDATE via_rpc=false, actor=null                     | 1,517   | 2026-05-19           | One-shot pre-A.5b backfill RPCs (e.g., `manual_ghost_pod_archive_2026-05-18`) that ran before the set_config marker was uniformly applied. Stopped 6+ days ago. Not an active surface.                                 |
| **UPDATE via_rpc=false, actor=bf32624e (warehouse)** | **131** | **2026-05-25 12:38** | **Active surface.** Inline qty/location/status FE handlers at `src/app/(field)/field/inventory/page.tsx` lines 938/1029/1070/1140/1236. Out of PRD-013 §4 explicit non-goal ("inline qty edits stay on current path"). |
| UPDATE via_rpc=false, actor=82bba4ee (operator)      | 3       | 2026-05-25 07:21     | Same FE inline-edit handlers under operator_admin role.                                                                                                                                                                |
| INSERT via_rpc=false, actor=null                     | 93      | 2026-05-19           | Same as row 1: one-shot backfill INSERTs (e.g., `manual_inventory_sync_*`) pre-marker. Not active.                                                                                                                     |
| All other 30-day writes                              | n/a     | n/a                  | Properly attributed to a canonical RPC (auto_decrement_pod_inventory, receive_dispatch_line, propose_inactivate_on_zero_stock, etc.).                                                                                  |

## Why P3.B and P3.E were deferred

The 134 ongoing direct UPDATEs (131 warehouse + 3 operator) all originate from the **5 inline qty/location/status handlers** at `src/app/(field)/field/inventory/page.tsx` (saveInlineQty, saveInlineLocation, inline status flip). These were flagged in the Phase 1 summary as out of PRD-013 §4 non-goals scope ("inline qty edits stay on current path").

The PRD §A.4 hard-block trigger as drafted fires on UPDATE touching `current_stock`, `estimated_remaining`, `status`, or `removal_reason`. All five inline handlers touch at least `current_stock` or `status`. **Flipping the trigger today would break the field PWA.**

CS decision at G4 (recorded in transcript): **"Ship A.3 cron now; defer A.4 trigger to follow-up PRD."** The follow-up PRD owns:

1. Design + apply a canonical `inline_adjust_pod_inventory` RPC covering qty / location / status flips with cabinet-safe optimistic concurrency.
2. Rewire the 5 FE handlers to call it.
3. Wait the 7-day clean window per PRD-013 §D3.
4. Then apply the hard-block trigger from PRD-013 §A.4.

The PRD-013 §A.4 trigger SQL spec is retained in the source PRD for that follow-up.

## P3.D cron — applied + verified

```sql
-- After apply
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname IN ('pod_inventory_edits_auto_expire', 'pod_add_proposals_auto_expire');
-- pod_add_proposals_auto_expire   | 0 22 * * *  | SELECT public.auto_expire_pod_add_proposals();      | true
-- pod_inventory_edits_auto_expire | 30 22 * * * | SELECT public.auto_expire_pod_inventory_edits();    | true

-- Manual test-fire (no rows currently older than 14d + still pending)
SELECT public.auto_expire_pod_inventory_edits();
-- → {"ran_at":"2026-05-25T12:56:19.548+00", "result":"success", "expired_count":0}
```

The two crons are scheduled 30 minutes apart (22:00 then 22:30 UTC) and have overlapping WHERE clauses (PRD-012's targets `edit_type='add_new_product'` only; this one targets all five edit_types). The 30-minute gap makes the race benign today: PRD-012's cron flips its scoped rows first; this one's `WHERE status='pending'` excludes them on the 22:30 pass. **Article 1 follow-up (Cody recommended):** deprecate `auto_expire_pod_add_proposals` under Article 13 once this all-types cron has 30 days of clean runs, leaving a single canonical writer for the auto-expire action.

## Decisions baked in this phase

1. **All-types scope for the auto-expire cron** (not narrowed to `edit_type != 'add_new_product'`). PRD-013 §A.3 wording does not carve out add_new_product, and the unified `approve_pod_inventory_edit` RPC covers all five edit_types, so the cron should too. The 22:00→22:30 ordering keeps the two crons race-free; future consolidation noted above.
2. **P3.E trigger deferred** per G4 CS decision; trigger spec retained in source PRD for the follow-up PRD.
3. **No retro-attribution of pre-marker writes**. The 1,517 anonymous UPDATEs and 93 anonymous INSERTs from the pre-A.5b window are documented here but not cleaned up; they are historical state, not an active surface.

## Pending follow-ups (post-PRD-013)

1. **Follow-up PRD: canonical inline-adjust RPC + trigger flip**. Owns inline qty/location/status handlers + the PRD-013 §A.4 trigger. Blocking-precondition for closing the pod_inventory Article 3 surface entirely.
2. **Article 13 deprecation of `auto_expire_pod_add_proposals`** in favor of `auto_expire_pod_inventory_edits`. Sunset target: 90 days post first clean run (target window opens 2026-08-23 if the all-types cron stays clean).
3. **PRD-012 thin-shim sunset**: `approve_pod_inventory_add` / `reject_pod_inventory_add` thin-shim wrappers from `20260525210200_*.sql` sunset 2026-08-25 per Article 13.

## Notes for next maintainer

- Cron logs land in `cron.job_run_details` — query by `jobid=17` for this one. Failed runs surface a non-null `return_message`.
- The `notes` column accumulates one `[cron] auto_expired after 14 days at <ts>` line per row at the moment of expiration. Useful for forensics if a driver later asks why their pending edit went away.
- Re-applying the migration is safe: the `cron.unschedule + cron.schedule` idempotency guard re-creates the job by name with no duplicate-job risk.
- The function is `REVOKE ALL FROM public`; only the cron daemon (which runs as superuser by default in Supabase) and service_role can invoke it. `authenticated` cannot test-fire it without escalation.
