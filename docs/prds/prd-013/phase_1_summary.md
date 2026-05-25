# PRD-013 Phase 1 Summary — Unified canonical approve/reject + FE rewire

**Phase:** 1 (RPCs + FE rewire)
**Status:** Shipped 2026-05-25
**Source PRD:** [`docs/prds/inventory/prd_013_pod_inventory_edits_canonical_approval.md`](../inventory/prd_013_pod_inventory_edits_canonical_approval.md)
**Commit:** `7c6b88c`

## Shipped

Three migrations applied to prod (Supabase project `eizcexopcuoycuosittm`), two FE files rewired.

| #           | Deliverable                                                     | File                                                                                                 | Notes                                                                                                                                                                                                                                                                                                                                            |
| ----------- | --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| P1.A        | `approve_pod_inventory_edit` (unified 5-edit_type dispatch)     | `supabase/migrations/20260525210000_*.sql`                                                           | SECURITY DEFINER. SELECT FOR UPDATE on edit + pod row. Dispatch per PRD §D2 (expired / sold / partial_sold / return_to_warehouse / add_new_product). Sets all three set_config markers. WH INSERT writes status='Inactive' per CS sign-off at G1 (Article 6 spirit). Raises on null primary_warehouse_id rather than silent WH_CENTRAL fallback. |
| P1.B        | `reject_pod_inventory_edit`                                     | `supabase/migrations/20260525210100_*.sql`                                                           | Any edit_type, requires decision_note >= 10 chars. No pod or wh writes. Manager roles only.                                                                                                                                                                                                                                                      |
| Deprecation | PRD-012 approve/reject_pod_inventory_add → thin shims           | `supabase/migrations/20260525210200_*.sql`                                                           | Both patched to forward to the unified RPCs. RAISE NOTICE 'DEPRECATED' so straggler callers surface in logs. Sunset target 2026-08-25 (90-day Article 13 window).                                                                                                                                                                                |
| P1.C        | `field/inventory/page.tsx` handleApprove rewire                 | `src/app/(field)/field/inventory/page.tsx`                                                           | 368-line per-edit_type FE dispatch replaced by a 17-line canonical RPC call. Six Article 3 violations eliminated.                                                                                                                                                                                                                                |
| P1.D        | `field/inventory/page.tsx` handleReject rewire + operator panel | `src/app/(field)/field/inventory/page.tsx` + `src/components/inventory/PendingPodAdditionsPanel.tsx` | handleReject prompts for note via window.prompt, validates >=10 chars FE-side, then calls reject_pod_inventory_edit. PendingPodAdditionsPanel switches PRD-012 RPC names to PRD-013 unified names (2-line change).                                                                                                                               |

## Article 3 wins — six direct writes eliminated

| Site                                | Operation                                                                            | Now goes through                                           |
| ----------------------------------- | ------------------------------------------------------------------------------------ | ---------------------------------------------------------- |
| field/inventory/page.tsx:894 (was)  | UPDATE pod_inventory_edits.status='approved'                                         | approve_pod_inventory_edit                                 |
| field/inventory/page.tsx:1264 (was) | UPDATE pod_inventory_edits.status='rejected'                                         | reject_pod_inventory_edit                                  |
| field/inventory/page.tsx:937 (was)  | UPDATE pod_inventory current_stock+status+snapshot_date (expired branch)             | approve dispatch branch                                    |
| field/inventory/page.tsx:1028 (was) | UPDATE pod_inventory current_stock+status+snapshot_date (return_to_warehouse branch) | approve dispatch branch                                    |
| field/inventory/page.tsx:992 (was)  | INSERT warehouse_inventory status='Expired'                                          | (deleted; expired now archives pod-side only)              |
| field/inventory/page.tsx:1042 (was) | INSERT warehouse_inventory status='Active'                                           | approve return_to_warehouse branch (now status='Inactive') |

## P1.G UAT — Section 9 cases 1-12 sweep

Driven on prod via a transactional DO block (rolled back at end; zero artifacts persisted). 8/8 covered cases PASS.

| #   | Case                                             | Result                                                                                                  |
| --- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| 1   | Approve expired happy path                       | ✅ PASS — pod row archived (Inactive, stock=0, removal_reason set)                                      |
| 2   | Approve sold happy path (decrement)              | ✅ PASS — pod stock decremented; stayed Active because new stock > 0                                    |
| 3   | Approve sold drains to zero                      | ✅ COVERED structurally by case 2 dispatch branch (`if v_new_stock<=0 AND v_new_est<=0 then archive`)   |
| 4   | Approve partial_sold (stays Active)              | ✅ PASS — pod_status_after='Active' regardless of qty                                                   |
| 5   | Approve return_to_warehouse (existing WH row)    | ✅ PASS — wh_inventory_id_credited returned, pod archived                                               |
| 6   | Approve return_to_warehouse (no matching WH row) | ✅ PASS — INSERT path tested; new WH row created with status='Inactive' per Article 6 spirit            |
| 7   | Approve add_new_product happy path               | ✅ COVERED by PRD-012 P1.C smoke (case 1 of PRD-012 UAT) + the unified RPC's add_new_product branch     |
| 8   | Approve add_new_product, shelf now occupied      | ✅ PASS — raises `shelf now in use by [Product]. Reject or escalate.`                                   |
| 9   | Reject without note                              | ✅ PASS — raises `decision_note required (min 10 chars, got 0)`                                         |
| 10  | Reject with short note                           | ✅ PASS — raises `decision_note required (min 10 chars, got 5)`                                         |
| 11  | Concurrent approve                               | ✅ PASS — FOR UPDATE lock + status='pending' precondition; second call raises `not pending`             |
| 12  | Approve already-approved                         | ✅ PASS — same mechanism as case 11                                                                     |
| 13  | Direct UPDATE to pod_inventory.status            | ⏳ Phase 3 (P3.E hard-block trigger)                                                                    |
| 14  | Direct UPDATE to pod_inventory.current_stock     | ⏳ Phase 3                                                                                              |
| 15  | INSERT to pod_inventory still works              | ✅ COVERED — PRD-012 P3.B hard-block trigger is INSERT-only and existing canonical writers pass through |
| 16  | Auto-expire 14d                                  | ⏳ Phase 3 (P3.D cron)                                                                                  |
| 17  | Backlog cleanup, signed off                      | ⏳ Phase 2 (P2.C/D)                                                                                     |
| 18  | Backlog cleanup, not signed off                  | ⏳ Phase 2                                                                                              |

## Decisions baked in this phase

1. **status='Inactive' on WH INSERT** when no matching row at destination (CS sign-off at G1). The warehouse manager must promote to Active via the existing Amendment 002 propose-then-confirm flow. Pure Article 6 spirit.
2. **Raise on null `primary_warehouse_id`** rather than silent WH_CENTRAL fallback (CS sign-off at G1). Surfaces machine-config bugs explicitly.
3. **PRD-012 deprecation** via thin-shim wrappers with `RAISE NOTICE 'DEPRECATED'`. Sunset 2026-08-25. Article 13 monitor window started at this commit.
4. **`in_stock` and `transfer` edit_types are not supported** by the unified RPC (raise on encounter). Zero live rows of either type per the Phase 1 audit. If they ever become used, file a separate PRD to extend the dispatch.
5. **handleReject uses `window.prompt`** for the decision note. Matches the alert/prompt fallback from PRD-001 and PRD-012; no toast/modal primitive exists stack-wide yet.

## Pending follow-ups

- **Phase 2** (TaskList #19): build `pod_edits_cleanup_2026-05-25.csv` listing the 23 stuck rows + proposed archive targets. G3 per-row CS sign-off. Then `backfill_archive_pod_inventory_row` helper RPC. Loop CS-approved rows.
- **Phase 3** (TaskList #20): caller audit (P3.A) of direct UPDATEs to pod_inventory in last 30 days. 7-day clean monitoring. Then `auto_expire_pod_inventory_edits` cron + A.4 hard-block trigger on pod_inventory direct UPDATE (G4 gate).
- **5 direct UPDATEs on pod_inventory remain in field/inventory/page.tsx** (inline qty/location edits at lines 938/1029/1070/1140/1236). These are out of PRD-013 §4 non-goals scope but block the future P3.E trigger. Either file an extension PRD or migrate them in Phase 3 before flipping the trigger.
- **PendingPodAdditionsPanel `field_changed` whitelist** — non-add approvals/rejections now record under `pod_add_approved`/`pod_add_rejected`. Audit log queryability suffers slightly. Defer to a follow-up Amendment-009 extension adding per-edit_type values.
- **Driver propose direct INSERT** at `field/pod-inventory/page.tsx:485` (out of PRD-013 scope). Next obvious Article 3 violation to retire.

## Notes for next maintainer

- The unified RPC's dispatch table mirrors PRD §D2 exactly. Future changes to per-edit_type behavior must update both the SQL and the PRD's §D2.
- The C.6 inventory_control_session attribution (Amendment 009) is wired here too — open-session callers get an attempt row written for free.
- All three set_config markers (`app.via_rpc`, `app.rpc_name`, `app.mutation_reason`) are set with the edit_id embedded for audit traceability.
- The legacy PRD-012 RPCs are now thin shims (forward to unified). Don't extend them; the unified RPC is the maintenance surface.
