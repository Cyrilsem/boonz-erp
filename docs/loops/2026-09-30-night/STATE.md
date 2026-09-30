# ONE LOOP, 2026-09-30 night, run state

Started 2026-09-30 14:51 Dubai (well before the 22:00-06:00 window; using the pre-window hours
for read-only investigation and drafting/rolled-back testing only, per this run's own hard rule
that dispatch/pickup/plan/mapping migrations apply only inside the window).

## STEP 0, done (max 15 min, read-only)

| Item                                            | Status        | Evidence                                                                                                                                                                                                                                                                                                                                                |
| ----------------------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| PRD-137 Phase 0 (a-l)                           | DONE          | docs/loops/2026-09-29-prd137/REPORT.md, all committed 2026-09-29/30 night                                                                                                                                                                                                                                                                               |
| F1 (auto pickup, sticky)                        | DONE          | live, migration 20260929200429                                                                                                                                                                                                                                                                                                                          |
| F1b (completion trigger + stale-press widening) | PARTIAL       | drafted and tested in a rolled-back transaction, NOT applied. supabase/migrations/DRAFT_prd137_f1b_pickup_completion_and_stale_press.sql                                                                                                                                                                                                                |
| F2 (Could not remove credits nothing)           | DONE          | live, migration 20260929201947, plus FE change                                                                                                                                                                                                                                                                                                          |
| F3 (Warehouse Confirmations single inbox)       | OPEN          | not started; item g's double-credit root cause understood, not fixed at the source                                                                                                                                                                                                                                                                      |
| F4 (Remove qty from WEIMI)                      | OPEN          | investigated only: source (pod_inventory.current_stock) embedded across auto_generate_refill_plan/engine_add_pod/engine_swap_pod/propose_swap_plan, each 10-16KB                                                                                                                                                                                        |
| F5 (driver off-plan actions)                    | OPEN          | not started, no RPCs confirmed to exist yet for ad hoc return/M2M/swap from the driver app                                                                                                                                                                                                                                                              |
| F6 (pack screen bugs)                           | OPEN          | 3 bugs confirmed with exact file:line (qty cap, error surfacing, merge-key), no fix drafted                                                                                                                                                                                                                                                             |
| F7 (M2M actual qty + auto WH-return diff)       | OPEN          | not started                                                                                                                                                                                                                                                                                                                                             |
| F8 (pending reviews dedupe/escalate)            | DONE          | live, migration 20260929202658                                                                                                                                                                                                                                                                                                                          |
| F9 (G7 expiry-pull exception)                   | DONE          | live, migration 20260929195322                                                                                                                                                                                                                                                                                                                          |
| F10 (Picker P1 exclusion)                       | DONE          | live, migration 20260929195828                                                                                                                                                                                                                                                                                                                          |
| PRD-123 (VAT on PO receipt)                     | OPEN          | doc status DRAFT, ready to batch, nothing applied                                                                                                                                                                                                                                                                                                       |
| PRD-130 items 03/04                             | OPEN          | still in supabase/migrations_parked/, not applied                                                                                                                                                                                                                                                                                                       |
| PRD-133 (pick_machines_v12 shadow engine)       | PARTIAL       | pick_machines_v12, v_picker_shadow_diff, picker_backtest_results, machines_to_visit_shadow, picker_config all live. backtest_priority function does NOT exist live (drafted in the PRD doc only). supabase/tests/selection_v2.sql exists (195 lines), pass/fail state not re-verified tonight yet. picker_config presumably still 'shadow', no cutover. |
| PRD-134 (knowledge tables)                      | DONE (CLOSED) | tables live with seed data, confirmed 2026-09-30                                                                                                                                                                                                                                                                                                        |
| PRD-135 (engine safety flags)                   | DONE (CLOSED) | slow_lane_fill_cap_pct live, NULL/off, confirmed 2026-09-30                                                                                                                                                                                                                                                                                             |
| Loop R2 (stitch)                                | OPEN          | not investigated this run                                                                                                                                                                                                                                                                                                                               |

Building tonight: everything PARTIAL/OPEN above, per this run's own instruction, prioritized
Block A then Block B (both "never cut"), Block C only if time remains after A+B are green,
stopping Block C cleanly at 04:30 regardless.

## Pre-window plan (now until 22:00 Dubai)

Read-only investigation and drafting only; no apply_migration calls until the window opens.
Launched parallel investigation on: F3, F4, F5, F6 fix design, F7, and Block B's G11 gate. All 6
landed. Findings below.

## Investigation findings (all 6 forks landed)

**G11 (Block B).** `write_refill_plan` has an existing V1-V6 blocking-validation loop; G11 becomes
V7 there (needs its own machine_id/pod_product_id/boonz_product_id lookups, since the loop only
has names at that point). `approve_refill_plan` enforces purely via `validate_refill_plan`'s
`blocking` count (already extended once for F9's G7) -- G11 there is a second, separate insertion
(a new row in that function), not a shared code path. Real flavor-split bug for B2 lives in
`stitch_pod_to_boonz` (50KB): its `m_raw` CTE's ROW_NUMBER partition merges machine-scoped and
global product_mapping rows for the same pod_product instead of the machine-scoped set fully
replacing the global set when any Active machine-scoped row exists. `engine_add_pod` and
`find_substitutes_for_shelf` do not need changes (single-row picks already prefer machine-scoped
via existing ORDER BY; substitutes operates at pod_product category level, not flavor).
`product_mapping` already has `machine_id` (nullable, NULL=global) and `split_pct` -- no schema
migration needed. Canonical WH_CENTRAL pickable stock view: `v_wh_pickable`. `comment` lives on
BOTH `refill_plan_output` and `refill_dispatching` as separate columns -- check whichever the
calling context actually has. Backtest 2026-09-16..30 confirms 3 of 4 named cases exactly
(AMZ-1038 A08 Kit-kat n=7, AMZ-1029 A08 Nutella T3 n=2, VML-1004 A02 Coca Cola n=1, WPP A06 Plaay
Dark n=1); "Delice" was not found under AMZ-1038 A08 specifically (partial match on that pair).
~50 rows total across 21 machines.

**F3.** Correcting last night's own framing: item g was NOT `wm_confirm_line` double-crediting the
same event -- it was a stray Refill-return line (`d9da3b7f`) auto-credited by `return_dispatch_line`
with ZERO review (Refill/Add-type returns bypass `v_wm_confirmations` entirely, since that view
only looks at `action='Remove'`), which happened to land on the same warehouse_inventory row as a
separate, legitimate Remove dispatch that DID go through `wm_confirm_line` correctly. Both events
were real; the fix applied (reversing exactly the stray 8 units) was still correct. The
generalizable bug matches F3's own spec exactly: Refill/Add-type returns need a review step too.
Design: add a third UNION branch to `v_wm_confirmations` for `action IN ('Refill','Add','Add New')
AND returned=true AND wh_approved_at IS NULL` (acknowledge-only, `wm_confirm_line` must NOT credit
warehouse_inventory again for these, only set wh_approved_at), plus a branch for
`warehouse_inventory` rows with `provenance_reason='dispatch_return_unverified'` (the
REMOVE-RETURN quarantine batches), hide qty 0 via `warehouse_stock > 0`. Split by variant is
net-new (wm_confirm_line takes scalar qty/expiry, needs a jsonb breakdown param like
return_dispatch_line already has). 48h alert: direct copy-adapt of tonight's own
`check_stale_pending_reviews` shape. Open: "M2M legs that ended in WH" likely via
`cancel_m2m_transfer`'s `p_convert_source_to_return` option, body not yet read.

**F4.** Reverses last night's "too large" call. The engines already source Remove qty from WEIMI
(`v_live_shelf_stock`, built from live `weimi_device_status` sensor JSON) -- `auto_generate_refill_plan`
and `engine_swap_pod` both confirmed WEIMI-sourced already (one has an inline comment noting this
exact bug was already fixed there previously). The real gap: `write_refill_plan` is a pure
pass-through writer, inserts whatever quantity is in the JSONB payload with ZERO validation against
WEIMI -- a manually-typed or stale-UI-snapshot Remove line sails through unchecked. Fix: one new
gate (same shape as G7/G8/G11) comparing a Remove/M2W line's quantity against
`v_live_shelf_stock.current_stock` for that machine+shelf. Do NOT touch the 4 engine functions.
`driver_confirm_remove`/`wh_approve_remove_receipt` (the "WH confirms driver count" half) already
exist live with matching signatures; bodies not yet read but very likely already correct.

**F5.** Three sub-asks, three different verdicts. (1) Variant return: `insert_driver_remove_line`
already takes exact variant+expiry and is driver-wired ("+ Add variant" button), but only as a
SPLIT of an existing planned Remove line -- cannot create a return with zero prior line. Narrow
reading already works; broad reading not tonight. (2) Ad hoc M2M: `add_m2m_transfer` is ALREADY
fully capable of recording an already-physically-done cross-machine move (inserts both legs
pre-packed/dispatched, conservation by construction) -- just needs `field_staff` added to its role
allowlist (currently operator_admin/superadmin/manager/warehouse only) and new driver UI. Buildable
tonight. (3) Swap on the spot: no fitting RPC exists (`inject_swap` is pre-visit plan editing, not
an after-the-fact record; `recommend_swaps_for_machine` is read-only). Needs a new writer, not
tonight. Conservation invariant for any new path: mirror `is_internal_move_dispatch`'s precedence
exactly (internal_move_cleared_at overrides everything; is_m2m + different destination machine
means genuinely cross-machine, handled by approve_m2m_transfer not this check).

**F6.** Bug 1 (qty cap) and bug 2 (error surfacing): pure FE, no DB/RPC involved, NOT window-gated
-- shipping these now, ahead of tonight's window. `line.warehouse_stock` and a `committedByProduct`
map already exist and compute `lineAvailable` inline at page.tsx:3915 -- reuse that pattern to add
`maxAvailable` to `editingDispatch` state + `DispatchEditDialog` Props, show "Max available: N",
set `max=` on the input, add a client-side guard before the RPC call. For errors: a per-card
`lineErrors` state keyed by dispatch_id (mirroring the existing `zeroQtyWarnings` Set pattern),
set alongside the existing page-top `warnings.push(...)` in the bulk pack loop, rendered next to
the card. Bug 3 (merge-key): a real, persistable correlation signal exists -- `pack_dispatch_line`
already computes `child_dispatch_id` per multi-batch pick in its return payload but never writes
it to the row. Fix: add a nullable `parent_dispatch_id uuid references refill_dispatching`
column (zero effect on existing rows), set it on `pack_dispatch_line`'s child INSERT, change the
FE merge key (page.tsx:1122) to group by `parent_dispatch_id ?? dispatch_id` instead of
action+product+shelf. Schema change + SECURITY DEFINER edit -- Cody review + window required.

**F7.** DB side is buildable and testable tonight: `receive_dispatch_line` ALREADY has the
actual-vs-planned split mechanism (`p_filled_quantity` separate from planned `quantity`, computing
`v_return_delta`/`v_overfill` for WH credit/debit) -- it's just explicitly gated `IF NOT is_m2m`
today. New RPC `confirm_m2m_delivery(p_transfer_id, p_source_actual_qty, p_dest_actual_qty,
p_caller_id, p_reason)`: calls `receive_dispatch_line` on both legs with their real actual qtys
(pod always credits correctly regardless of is_m2m), then for a shortfall
(source_actual > dest_actual) explicitly credits warehouse_inventory for the difference as a
disclosed direct write (the WH-return line the spec asks for, since is_m2m skips that inside
receive_dispatch_line itself); reject a dest_actual > source_actual as physically impossible
in-transit. Role allowlist should include field_staff (driver-entered), unlike
approve_m2m_transfer's narrower list. Open design call, not resolved by the spec text: attribute
the shortfall's WH-return credit to the source machine (my own reasoned default, since the spec's
own words say "WH return line" not "writeoff" -- disclosing this call clearly rather than blocking
on it). FE: confirmed zero existing UI (pickup page shows M2M qty as static read-only text) --
100% new driver UI, flagged as the risky-to-rush part, same as F5's ad hoc M2M UI.

## Build order for tonight (pre-window drafting now, apply in window)

1. G11 (Block B) -- well-specified, "never cut", high value.
2. F4 -- small, contained, same shape as an existing gate.
3. F3 -- contained view + acknowledge-only branch + 48h check.
4. F7 DB side (confirm_m2m_delivery) -- mechanism already exists, just wiring.
5. F5 ad hoc M2M -- role allowlist fix + FE wiring (assess FE risk before committing to ship it).
6. F1b -- already drafted and tested last night, just needs applying + renaming.
7. F6 -- once that fork lands.
8. F5's variant-return/swap-on-spot, F7's driver UI -- holding, same reasoning as last night
   (net-new safety-critical FE, not tractable to rush).
9. Block C (PRD-133/123/130/R2) -- only if A+B fully green with time left, cut at 04:30 regardless.
