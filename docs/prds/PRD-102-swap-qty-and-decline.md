# PRD-102: Pod swap — operator-decided quantity + Confirm / Don't-swap with reason

Status: SHIPPED 2026-07-18. Dara + Cody pass; T1-T8 pass (T3 adapted: request-100-vs-
WH-60 proves the same wh_limited contract; shrinking WH to 8 requires an Article-6
status write - zeroing auto-inactivates the row). Engines md5-unchanged. Details:
PRD-102-EXECUTION-LOG.md.

## Why (verified live during the 2026-07-18 swap test)

Two gaps in the field packing "Swap the pod" flow (`app/(field)/field/packing/[machineId]/page.tsx` → `swap_shelf_pod`):

1. **No quantity control.** `swap_shelf_pod` auto-fills the incoming pod to shelf capacity: cap = `MAX(max_stock_weimi)` from `v_shelf_max_stock`, spread across in-stock mapped variants via `spread_pod_qty`. The user cannot decide the quantity. That cap is also the WRONG anchor for a swap: `max_stock_weimi` reflects the OLD product's physical facing. The incoming product is a different item with a different physical size — capacity for it is unknown at swap time and the person standing at the machine is the only one who knows what fits. Verified 2026-07-18 on WH1-2002 A01: swap auto-filled 8 (old product's WEIMI cap) with no way to say 6 or 10.

2. **No way to decline a swap.** The modal is Cancel / Confirm only. When the planner emits a swap pair (SWAPS section, paired Remove + Add New) the field user sometimes decides the swap should NOT happen (product is actually selling, wrong call, no space, product unavailable on the truck). Today the only options are silently skipping lines (invisible decision, and the engine re-proposes the same swap next cycle) or executing a swap they disagree with. The learning loop already exists and is starving: `engine_swap_pod` consumes `refill_edit_signals` rows with `signal_type='swap_rejected'` for its R5 cooldowns (14-day no-repeat-removal) — but no FE surface writes that signal.

## Design

### D1 — Quantity input in the swap modal (FE + RPC)

- **RPC (forward-only overload):** `swap_shelf_pod(p_plan_date, p_machine_id, p_shelf_id, p_new_pod_product_id, p_reason, p_new_qty integer DEFAULT NULL)`.
  - `p_new_qty IS NULL` → current behavior (fill to WEIMI cap) — every existing caller unchanged.
  - `p_new_qty > 0` → spread exactly `p_new_qty` across the pod's WH-available mapped variants (same `spread_pod_qty` largest-remainder mechanics, target = `p_new_qty` instead of cap). **Deliberately NOT clamped to `v_shelf_max_stock`** — that cap describes the old product; the operator's number wins. The only hard limit stays WH availability (cannot add stock that does not exist): if WH-available < `p_new_qty`, fill what exists and return `clamp_reason='wh_limited'` + `requested_qty` in the response.
  - Validation: `p_new_qty >= 1` when provided; role gate unchanged (`field_staff, warehouse, operator_admin, superadmin, manager`); reason ≥ 10 chars unchanged; `app.via_rpc`/`app.rpc_name` unchanged. Writes still go leg-by-leg through `add_dispatch_row` (canonical, Article 1).
- **FE (packing page swap sheet):** add a "Quantity to add" numeric input, prefilled with the pod's default fill (call `spread_pod_qty` total, shown as "suggested: N") but freely editable. Show WH-available total for the chosen pod next to the input so the user knows the real ceiling. Submit passes `p_new_qty`.

### D2 — Confirm / Don't-swap + reason (FE + new RPC)

- **New DEFINER RPC `decline_swap_pair(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_dispatch_ids uuid[], p_reason text)`:**
  1. Role gate: `field_staff, warehouse, operator_admin, superadmin, manager` (⛔ current vocabulary — lesson of the 2026-07-18 role-constraint incident; any new role list MUST include `field_staff`+`warehouse`).
  2. Validates the rows exist, belong to machine/shelf/date, are an unstarted swap pair (Remove and/or Add New, `filled_quantity=0`, not packed/picked_up), reason ≥ 10 chars.
  3. Marks both legs `skipped=true` (or `include=false` via the existing remove semantics — Dara to pick one; must remain visible as a DECISION, not vanish) with `last_edited_by_role` + edit-log rows (`edit_kind='decline_swap'`).
  4. **Writes the learning signal:** INSERT into `refill_edit_signals` (`signal_type='swap_rejected'`, source='field', the removed pod/boonz product, machine, reason). This is what makes the decline feed `engine_swap_pod` R5 cooldowns so the same swap is not re-proposed for 14 days — turning a silent skip into a taught preference.
- **FE:** in the SWAPS section (paired Remove + Add New) and in the swap modal, next to **Confirm pod swap** add **Don't swap** (secondary). Tapping it opens a one-field reason sheet (min 10 chars) → calls `decline_swap_pair`. The pair renders as "Declined — [reason]" (struck-through, not deleted) for the rest of the day.

## Gates

- D1 RPC change = `CREATE OR REPLACE` on an existing DEFINER writer touching `refill_dispatching` via `add_dispatch_row` → **Cody review required** (Articles 1, 4, 8, 12, 13). Default-NULL param preserves every existing call site; no signature break, no deprecation needed.
- D2 = new DEFINER writer on `refill_dispatching` (protected) + append INSERT into `refill_edit_signals` → **Dara design pass** (skipped vs include=false semantics; edit_log kind) then **Cody**. `refill_dispatching_edit_log` stays append-only (Article 7).
- Engine untouched: `engine_swap_pod` already reads `swap_rejected`; no engine edit → Family-A md5 unchanged, `diff_vs_golden` identical.
- FE `npm run build` green; forward-only migrations; CHANGELOG + RPC_REGISTRY + MIGRATIONS_REGISTRY updated.

## T-tests

- T1 Swap with `p_new_qty=NULL` ⇒ byte-identical behavior to today (regression: WH1-2002 A01 fills 8).
- T2 Swap with `p_new_qty=6` on a shelf whose WEIMI cap is 8 ⇒ exactly 6 added (proves capacity no longer clamps).
- T3 Swap with `p_new_qty=12`, WH-available=8 ⇒ 8 added, `clamp_reason='wh_limited'`, `requested_qty=12` in response.
- T4 `p_new_qty=0`/negative ⇒ raise.
- T5 `decline_swap_pair` as impersonated **field_staff** ⇒ both legs terminal-skipped, edit-log rows written, `refill_edit_signals` row `signal_type='swap_rejected'` present (role-vocab regression guard).
- T6 Next `engine_swap_pod` run after T5 ⇒ same removal NOT re-proposed for that machine/pod (R5 cooldown consumed the signal).
- T7 Decline on an already-packed pair ⇒ raise (too late).
- T8 FE: modal shows suggested qty + WH-available; Don't-swap renders the declined pair struck-through with reason; build green.

## CLOSE

CHANGELOG; PRD-102 SHIPPED + PRD-102-EXECUTION-LOG.md; commit+push. Rollback: D1 = forward migration restoring the 5-arg body (default-NULL param additive); D2 = `DROP FUNCTION decline_swap_pair` + FE revert; signals rows are append-only history, left in place.
