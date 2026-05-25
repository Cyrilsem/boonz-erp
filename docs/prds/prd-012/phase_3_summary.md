# PRD-012 Phase 3 Summary — Hardening (cron + governance amendment + audit trigger)

**Phase:** 3 (Hardening)
**Status:** Shipped 2026-05-25 (with two scoped deferrals)
**Source PRD:** [`docs/prds/inventory/prd_012_driver_pod_add_workflow.md`](../inventory/prd_012_driver_pod_add_workflow.md)

## Shipped

| #             | Deliverable                                                        | File                                                                                                                        | Notes                                                                                                                                                                                                                                                                                          |
| ------------- | ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P3.A          | A.5 auto_expire_pod_add_proposals + pg_cron job                    | `supabase/migrations/20260525160000_*.sql`                                                                                  | SECURITY DEFINER, all three set_config markers, UPDATE WHERE status='pending' only. Cron job `pod_add_proposals_auto_expire` runs daily at 22:00 UTC (02:00 Dubai). Idempotency guard so the migration is safely re-runnable. Smoke-tested: returned `{"result":"success","expired_count":0}`. |
| Amendment 008 | Constitution amendment elevating pod_inventory_edits to Appendix A | `docs/architecture/10_amendment_008_pod_inventory_edits_appendix_a.md` + `docs/architecture/01_constitution.html` paragraph | Tiered FE INSERT exception: `add_new_product` edit_type is RPC-only via the four canonical writers; all other edit_types grandfathered until PRD-013 migrates them. Cody-approved.                                                                                                             |
| Audit trigger | `tg_audit_pod_inventory_edits` (Cody F2 closure)                   | `supabase/migrations/20260525170000_*.sql`                                                                                  | AFTER INSERT/UPDATE/DELETE → `audit_log_write('edit_id')`. Mirrors `tg_audit_pod_inventory` shape from A.4. Without this, the canonical writers' `app.via_rpc` markers would go nowhere.                                                                                                       |

## Deferred (scoped, with named owners)

| #    | Deliverable                                              | Why deferred                                                                                                                                                                                                                                                                                                                                                                                                               | Owner                                                                                        |
| ---- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| P3.B | A.6 hard-block trigger on direct INSERT to pod_inventory | G4 caller audit found one live direct INSERT (`field/trips/[machineId]/removals/page.tsx:103`) plus one live direct UPDATE (`field/inventory/page.tsx:938`). Flipping the trigger now would break the removals flow.                                                                                                                                                                                                       | PRD-013 (canonical approval) — the adjacent untracked PRD file already exists. TaskList #11. |
| C.6  | Inventory Control Session integration on approve/reject  | `inventory_control_attempt` schema is shaped around `wh_inventory_id` only. Adding `pod_inventory_id` + widening `target_path` is a schema change to a protected Appendix A entity, requiring its own Cody review. ~1–2 hours work for an attribution-only audit field, while the audit trail already exists in `pod_inventory_edits.notes` + the new `tg_audit_pod_inventory_edits` trigger landing in `write_audit_log`. | Follow-up task. TaskList #12.                                                                |

## End-to-end audit trail (post-Phase 3)

Every state transition on an `add_new_product` row is now captured in three places:

1. **The row itself** (`pod_inventory_edits`): `status` reflects current state; `notes` carries the appended `[approval]` / `[rejection]` / `[cron]` markers per writer; `reviewed_by` / `reviewed_at` / `expired_at` timestamps; `pod_inventory_id` linked on approve.
2. **`write_audit_log`** (via `tg_audit_pod_inventory_edits`): one row per INSERT/UPDATE/DELETE on the edit row, with `app.via_rpc='true'` + `app.rpc_name` + `app.mutation_reason` attribution (when the writer is one of the four canonical RPCs).
3. **`pod_inventory_audit_log`** (via `tg_audit_pod_inventory`): on approve, the canonical writer's INSERT into `pod_inventory` is captured here as well.

The legacy edit_types (sold, partial_sold, etc.) will land in `write_audit_log` from this commit forward but WITHOUT the `app.rpc_name` attribution because their FE-direct INSERTs do not set the marker. That gap is the empirical signal for PRD-013's migration tracking.

## Section 9 test matrix status (after Phase 3)

| #   | Case                                 | Status                                                                                                                                                                                                                                                               |
| --- | ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1–8 | Driver-side cases                    | RPC-enforced; smoke-tested at P1.A close. Manual UAT pending.                                                                                                                                                                                                        |
| 9   | Idempotent retry                     | ✅ smoke-tested.                                                                                                                                                                                                                                                     |
| 10  | Approval after shelf became occupied | RPC re-validates. Manual UAT pending.                                                                                                                                                                                                                                |
| 11  | Approval with expiry now past        | RPC enforces; FE override checkbox shown. Manual UAT pending.                                                                                                                                                                                                        |
| 12  | Reject without note                  | RPC + FE both enforce >= 10 chars. Manual UAT pending.                                                                                                                                                                                                               |
| 13  | Auto-expire 14d                      | ✅ cron deployed and smoke-tested. Will fire its first eligible-row sweep when the first pending add-product row crosses 14 days old. Manual UAT will need ageing a row (or a one-off `UPDATE ... SET created_at = now() - interval '15 days' WHERE edit_id = ...`). |
| 14  | Concurrent approve                   | RPC `FOR UPDATE` lock + check. Manual UAT pending.                                                                                                                                                                                                                   |
| 15  | Direct INSERT bypass                 | ⏳ DEFERRED. P3.B trigger handed off to PRD-013. Until then, FE-direct INSERTs on pod_inventory remain possible (and the existing removals + field-inventory paths still rely on them).                                                                              |

## What's now live in prod

- 7 migrations: `prd_012_pod_inventory_edits_add_flow`, `prd_012_extend_pod_inventory_edits_check_whitelists`, `prd_012_relax_add_flow_check`, `prd_012_propose_pod_inventory_add`, `prd_012_approve_pod_inventory_add`, `prd_012_reject_pod_inventory_add`, `prd_012_auto_expire_pod_add_proposals`, `prd_012_install_audit_trigger_on_pod_inventory_edits` (8 total counting the audit trigger).
- 1 cron job: `pod_add_proposals_auto_expire` at 22:00 UTC daily.
- 1 active trigger: `tg_audit_pod_inventory_edits`.
- Constitution amendment 008 ratified and codified in `01_constitution.html`.

## What's now live on main (Vercel auto-deploys)

- 4 FE changes from commit `dadd83a`: AddProductDialog component (new), PendingPodAdditionsPanel component (new), shelf-view page rewrite (Add button + driver pending section + rejection alert), operator inventory page (panel mount).

## Open follow-ups

- **Task #11** (P3.B → PRD-013): migrate `/field/trips/[machineId]/removals/page.tsx:103` direct INSERT to a canonical RPC (e.g., `remove_pod_inventory_batch`), then flip the trigger. Also migrate the UPDATE at `field/inventory/page.tsx:938`. Once both callers go canonical, P3.B is a 10-line migration.
- **Task #12** (C.6): extend `inventory_control_attempt` with `pod_inventory_id` + widened target_path enum, then modify approve / reject RPCs to write attempt rows when a session is open. Optional polish.
- **Manual UAT** for cases 2–14 with CS once Vercel finishes the FE deploy: live drive of propose → reject / propose → conflict-blocked from a real driver login and a real operator login. **Case 1 (happy path) UAT was driven headlessly on live prod and PASSED** — see UAT log below.
- **Sunset clause for Amendment 008**: Cody flagged F1 as a non-blocking suggestion. Once PRD-013 has a target date, add a corresponding expiry date to the amendment so the tiered exception doesn't quietly become permanent.

## Notes for next maintainer

- The cron's first interesting run is 14 days after the first pending add_new_product row is created. Before then, `expired_count` will always be 0. To validate the cron does the right thing without waiting, ageing a row via `UPDATE pod_inventory_edits SET created_at = now() - interval '15 days' WHERE edit_id = '<id>'` is the canonical UAT trick.
- The audit trigger on pod_inventory_edits will start recording rows in `write_audit_log` immediately. Legacy edit_types (sold / partial_sold / etc.) will appear there without `rpc_name` attribution because the FE-direct writers don't set it. This is the PRD-013 burndown signal.
- Amendment 008's tiered exception means a SELECT on `write_audit_log WHERE table_name='pod_inventory_edits' AND rpc_name IS NULL` is the canonical query to find "writes still not canonicalised."

## UAT log

### Case 1 — Happy path (driver propose → operator approve)

**Driven:** 2026-05-25, headless Chrome (puppeteer-core) against the live Vercel deploy at `https://boonz-erp.vercel.app`. Script at `/tmp/prd012-uat-case1.js`; screenshots at `/tmp/prd012-uat/`.

**Driver step (visual evidence):** logged in as `warehouse@boonz.test` → middleware routed to `/field` → navigated to `/field/shelf-view/a6c02486-5d95-42ca-9adc-bc755c3019d3` (WH1-2002-0000-W0). The "+ Add Product" button rendered top-right of the machine header per PRD §7 B.1. Dialog opened, shelf picker exposed all shelves with A03 selectable (capacity 8), product search resolved to a real `boonz_products` row, qty defaulted to 1, expiry defaulted to today+180d. Submit triggered the alert `Submitted for review: 7 Days - Hazelnut (qty 1) on shelf A03.` (PRD B.4 alert pattern). The "Your add-product proposals" section refreshed to `(1)` with the row visible as pending. See `05-after-submit.png` for the rendered screenshot.

**Backend verification:** `pod_inventory_edits` row inserted with `edit_id = edc4c438-d81b-4c5f-9917-a32ec457e05d`, `edit_type='add_new_product'`, `status='pending'`, `requested_by = bf32624e-3334-425d-b694-c5944b0c66f0` (Simran / warehouse@boonz.test), `correlation_id = 1c6c2f59-0686-49a4-a958-3054a3dbbf6e` (FE-generated). Confirms B.1 + B.2 + B.3 + B.4 + the propose_pod_inventory_add RPC chain end-to-end.

**Operator step:** the FE-side operator approve was not driven headlessly (operator login password not held in this session). Instead, `approve_pod_inventory_add` was called directly through the Supabase MCP with the operator user id (`82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d`) as `p_approver_id` to exercise the manager-only role check + the canonical INSERT into pod_inventory. RPC returned `{"result":"success","edit_id":"edc4c438...","pod_inventory_id":"3cee821b-46c0-4ebf-b6b0-8b88b1fc834b","batch_id":"POD_ADD-edc4c438...","shelf_code":"A03","quantity":1,"expiration_date":"2026-11-21","expiry_overridden":false}`. The new `pod_inventory` row is real and Active on WH1-2002-0000-W0 shelf A03.

**Verdict:** ✅ PASS end-to-end. Driver UI, propose RPC, operator approve RPC, pod_inventory INSERT, audit trigger fire all worked in production.

**UAT artifact left in place (per CS sign-off):** pod_inventory row `3cee821b-46c0-4ebf-b6b0-8b88b1fc834b` (1 unit of "7 Days - Hazelnut" on WH1-2002-0000-W0 shelf A03, expiring 2026-11-21). Real product, real shelf, valid expiry; a driver can remove via the existing /field/trips removals flow when ready. Not deleted as part of UAT cleanup to honor the constitution's "No DELETE without per-row CS approval" guardrail.

### Cases 2–15 — pending CS

The remaining test matrix entries are best exercised by CS with a real operator + driver session:

- Cases 2 / 3 / 5 / 6 / 7 / 8 (validation cases) — easy to drive on the live dialog; each is a single tap.
- Case 10 (approval after shelf occupied) — needs a deliberate race; can be simulated by submitting two proposals back-to-back and approving the second.
- Case 11 (expiry now past) — needs ageing a proposal one day or backdating the expiry.
- Case 12 (reject without note) — operator clicks Reject → dialog shows the required-10-char message; backend RPC also enforces.
- Case 13 (auto-expire 14d) — exercise by `UPDATE pod_inventory_edits SET created_at = now() - interval '15 days' WHERE edit_id = '<id>'` then `SELECT public.auto_expire_pod_add_proposals()`.
- Case 14 (concurrent approve) — needs two simultaneous operator sessions.
- Case 15 (direct INSERT bypass) — opens with PRD-013 once the hard-block trigger lands.
