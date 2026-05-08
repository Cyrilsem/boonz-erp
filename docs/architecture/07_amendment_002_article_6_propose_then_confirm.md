# Amendment 002 — Article 6: Propose-then-Confirm for `warehouse_inventory.status`

**Status:** Draft, pending ratification by CS
**Filed:** 2026-05-04
**Article amended:** 6 (warehouse_inventory.status manager-only) — invoked under Article 15
**Trigger event:** Resolution of refill-app issues #2, #8, #11. CS instruction (verbatim, 2026-05-04): *"in this case let's remove this constraint and auto inactive warehouse_inventory.status is manager-only condition. Actually, allow any change in the condition to be highlighted in the inventory for the warehouse manager to confirm. this would help in checks and balances and ensure if there's any error to be detected"*

---

## Context

Article 6 of the Backend Constitution states (verbatim):

> "warehouse_inventory.status manager-only — `warehouse_inventory.status` may only be written by the warehouse manager. No trigger / function / cron / n8n / app may mutate it."

This rule was authored after the 2026-04-25 incident, when `auto_reactivate_wh_on_stock_return()` silently flipped status on every stock-return UPDATE without a human in the loop. The lockout was a hard fix: shut every automated path off entirely.

The hard lockout has two operational costs the team has now hit:
1. **Issue #2 / #8 / #11 in the refill-app issues report:** when a batch's `warehouse_stock` and `consumer_stock` both reach zero, the status stays `Active` until the manager manually inactivates each row. With ~hundreds of batches and turnover increasing, this is unsustainable.
2. **Procurement reactivation:** when a PO addition refills a previously zero (Inactive) batch, the status stays `Inactive` until the manager flips it back. The refill engine then ignores the row — silent loss of stock visibility.

The lockout was correct as a stopgap, but it removed the safety value of automation entirely instead of routing it through the manager. Amendment 002 restores the automation, but inverts the trust model: automation may **propose** a change; only the manager (or an admin acting in that role) may **apply** it.

## Proposed revised Article 6

> **Article 6 (revised, 2026-05-04) — `warehouse_inventory.status` propose-then-confirm.**
>
> `warehouse_inventory.status` may be written only by:
> 1. The original-INSERT path on row creation (initial value when a new batch is dispatched / received). No proposal is required for INSERTs.
> 2. The canonical RPC `confirm_warehouse_status_proposal(uuid, text)`, called by the warehouse manager (or `operator_admin` / `superadmin` / `manager` acting in that role).
>
> Silent direct UPDATE of `warehouse_inventory.status` from any trigger, RPC, cron job, n8n flow, edge function, or FE direct write **remains forbidden**.
>
> Automated flows MAY propose status changes by INSERTing into `warehouse_inventory_status_proposal` with a clear `reason`, `proposer_kind`, and `proposer_name`. The proposal sits in `pending` state until the manager calls `confirm_warehouse_status_proposal` (which atomically flips the live status and marks the proposal `confirmed`) or `reject_warehouse_status_proposal` (which marks the proposal `rejected`; live status is untouched). Drift detection: if `warehouse_inventory.status` has changed since the proposal was filed, `confirm_*` marks the proposal `superseded` rather than applying it.

## What this amendment introduces

**One new protected entity:**
- `warehouse_inventory_status_proposal` (Appendix A addition)

**Two new canonical writers:**
- `confirm_warehouse_status_proposal(p_proposal_id uuid, p_note text)` → `jsonb`
- `reject_warehouse_status_proposal(p_proposal_id uuid, p_note text)` → `jsonb`

**Two new trigger-only functions** (initially unbound, bound in m3b post-dispatch):
- `propose_inactivate_on_zero_stock()` — proposes Active→Inactive when both stocks reach zero
- `propose_reactivate_on_stock_return()` — proposes Inactive→Active when stock returns

## Why this is safer than the old rule

The old rule had a single mode: lockout. The risk was:
- Real depleted batches stayed `Active`, polluting the refill engine's product mix calculations.
- Manager had to manually inactivate dozens of rows after every dispatch cycle.

The new rule preserves the manager as the sole gatekeeper of the *applied* state, but lets automation surface the candidates for action. Specifically:
1. **Automation cannot apply a flip.** The proposal table has RLS that blocks INSERT/UPDATE/DELETE from `authenticated`; only DEFINER triggers/RPCs (which run as owner) can write.
2. **Manager sees every proposal.** The Inventory page surfaces `v_pending_status_proposals` with the original reason, so the manager has full context.
3. **Audit trail is dual-actor.** Both the proposer (system actor name + reason) and the confirmer (manager UUID + decision note) are captured in `write_audit_log` via the universal audit trigger.
4. **Drift detection.** If the live status changed between proposal time and confirmation, the proposal is auto-marked `superseded` — no surprise overwrites.
5. **Idempotency.** The trigger functions skip inserting a duplicate pending proposal from the same proposer for the same row.

## Constitutional conformance

| Article | Status under Amendment 002 |
|---|---|
| 1 (single canonical write path) | ✅ `confirm_warehouse_status_proposal` is the sole non-INSERT writer of `warehouse_inventory.status`. |
| 2 (RLS) | ✅ `warehouse_inventory_status_proposal` has RLS enabled. |
| 3 (no authenticated direct writes on protected entities) | ✅ All write policies on the proposal table are `WITH CHECK (false)` for `authenticated`. |
| 4 (DEFINER validates) | ✅ Both confirm/reject RPCs validate caller role, validate inputs, set `app.via_rpc` and `app.rpc_name`. |
| 5 (status as state machine) | ✅ Proposal: pending → confirmed | rejected | superseded. `warehouse_inventory.status`: only flipped by confirm path. |
| 6 (this amendment) | ✅ Revised text above. |
| 7 (audit logs append-only) | ✅ `write_audit_log` policies unchanged; proposal table writes flow through it. |
| 8 (universal audit) | ✅ `tg_audit_wisp` trigger bound on the proposal table. |
| 9 (edge fn statelessness) | ✅ No edge fn change introduced. |
| 10/11 (n8n / cron via RPC) | ✅ The new flow is RPC-only. |
| 12 (forward-only migrations) | ✅ M1–M5 are additive. |
| 13 (deprecation) | n/a — no DEFINER deprecated. |
| 14 (no snapshot tables) | ✅ One new canonical table, no `_v2`. |
| 15 (PRs declare invariants) | ✅ This amendment is itself the declaration. |

## Migration mapping

| Migration | Article(s) | What it does |
|---|---|---|
| `m1_warehouse_inventory_status_proposal_table` | 1, 2, 3, 6, 7, 8, 12 | Creates the proposal table + RLS + audit trigger |
| `m2_confirm_reject_warehouse_status_proposal_rpcs` | 1, 4, 5, 8 | Creates confirm/reject DEFINER RPCs |
| `m3_propose_status_change_functions_unbound` | 1, 4, 6, 8, 9 | Creates the two trigger function bodies (NOT bound today) |
| `m3b_bind_warehouse_inventory_propose_triggers` *(pending tonight)* | 6, 8 | Binds the triggers AFTER UPDATE/INSERT on `warehouse_inventory` |

## Open questions for ratification

1. **Should `pod_inventory.status` get the same treatment?** The same propose-then-confirm pattern would naturally extend to `pod_inventory.status`. CS has not yet confirmed. Filed for follow-up review under a future amendment.
2. **TTL on pending proposals?** Currently a pending proposal can sit indefinitely. We may want a 30-day auto-supersede sweep so dashboards stay clean. Defer until proposal volume is observable.
3. **Notification channel:** how does the warehouse manager find out a new pending proposal exists? For now: Inventory page surface (read of `v_pending_status_proposals`). Telegram/Slack ping is a v2 ask.

## Ratification

Pending CS sign-off. Once ratified, update `01_constitution.html` Article 6 text and Appendix A list (add `warehouse_inventory_status_proposal`) in a follow-up commit. Until ratified, the migrations are applied (today, additive only) but the formal Constitution document still carries the old Article 6 wording — Amendment 002 stands as the bridge.
