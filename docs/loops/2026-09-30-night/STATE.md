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

## G11 drafting status (pre-window, as of 15:36 Dubai)

Three migrations, one per function, per spec:

1. `supabase/migrations/DRAFT_prd137_f11a_g11_helper_and_validate.sql` -- shared helper
   `g11_check_machine_mapping(machine, pod_product, boonz_product, comment)` returning
   `(is_violation, is_override, mapped_ids)`, plus `validate_refill_plan`'s new G11 blocking row
   (uses the helper via `CROSS JOIN LATERAL`, only on `action IN ('Refill','Add New')`). FULLY
   TESTED: real Kit-kat violation (AMZ-1038-3001-O1 A08, dispatch 27dee694) confirms
   `is_violation=true` and surfaces as a G11 blocking violation via `validate_refill_plan`; 5 real
   McVities Dark rows all clean; synthetic override ([sub] + zero WH_CENTRAL stock on mapped set)
   and synthetic on-mapping-product-passes cases both confirmed. Rollback verified byte-exact
   against live before drafting.
2. `supabase/migrations/DRAFT_prd137_f11b_write_refill_plan_v7.sql` -- write-time V7 gate inside
   the existing per-line loop (only for Refill/Add New, only once machine/product/pod all resolve
   by name so it never stacks a second confusing error on an unresolved-name V4/V5 hit). Rejects
   into `v_errors` on violation; logs to `monitoring_alerts` (source `g11_mapping_override`) on
   override. FULLY TESTED, all three paths, using a synthetic fixture (pod `f0000005-...001`,
   mapped boonz product `f0000005-...002`, off-mapping `f0000005-...003`, `product_mapping` row
   scoped to AMZ-1038-3001-O1's real machine_id `a75b847a-e920-4a94-bb2f-600280ff8b3c`):
   - Off-mapping + `[sub]` comment + zero real WH_CENTRAL stock on the mapped set -> `status:'ok'`,
     line written, 1 `monitoring_alerts` row logged. Override respected correctly.
   - Off-mapping + no `[sub]` comment -> `status:'validation_error'`, `G11_not_in_machine_mapping`,
     0 lines written, 0 alerts. Reject path correct.
   - On-mapping product itself -> `status:'ok'`, line written, 0 alerts (no override needed).
     Correct.
     Rollback (`supabase/rollback/DRAFT_prd137_f11_write_refill_plan_g11_rollback.sql`) verified
     byte-exact against live before drafting.

   **Debugging note (resolved):** the override path first appeared to log 0 alerts on two
   consecutive attempts. First attempt was a genuine test-setup bug (product_mapping fixture
   scoped to the wrong machine_id, a leftover from reusing last night's ALJLT-1015 machine_id).
   After fixing the machine_id, a second attempt STILL showed `alerts_after: 0` even though the
   helper independently confirmed `is_override=true` for the identical inputs. Root cause: the
   test combined `write_refill_plan(...)` and `(SELECT count(*) FROM monitoring_alerts ...)` in
   the SAME SELECT's target list -- PostgreSQL does not guarantee a data dependency between two
   expressions in one target list forces sequential evaluation, so the count subquery is not
   reliably guaranteed to see the write's own side effect. Fix: write the function's result into a
   temp table as its own statement, THEN read `monitoring_alerts` in a later statement. Sequenced
   this way, the alert appears every time. **Lesson for the rest of tonight's testing: never
   combine a side-effecting function call and a read of its own side effect in one SELECT target
   list inside these rolled-back-transaction tests -- always split via a temp table or separate
   statement.**

3. `supabase/migrations/DRAFT_prd137_f11c_approve_refill_plan_audit.sql` -- override-audit safety
   net in `approve_refill_plan`. G11 itself is already enforced here via `validate_refill_plan`'s
   existing blocking-count check (no separate reject path needed in this function). What this adds:
   a scan of `refill_dispatching` rows for the batch being approved, catching Refill/Add-New rows
   with `is_override=true` that never passed through `write_refill_plan`'s V7 (written before V7
   existed, or via a path like `inject_swap`), logging them to `monitoring_alerts` with the same
   shape, deduped by `dispatch_id` in the payload so re-approving or a row already caught at write
   time is never double-logged. Positioned after the existing blocking-violation check, before the
   `operator_status = 'approved'` update. WRITTEN AND TESTED:
   - Full-function test (synthetic override fixture, same as migration 2's) hit unrelated,
     pre-existing gates first (G5 -- the off-mapping product has no product_mapping row of its own
     under any pod_product; G8 -- zero free warehouse stock; G10 -- the real WEIMI shelf shows a
     different product with no Remove line) -- correctly proved G11 itself did NOT add to the
     blocking count for an override, but the batch still correctly failed on those orthogonal,
     unrelated gates (expected: a real [sub] override in production still needs its own G5 mapping
     and available stock/WEIMI-state to clear approval; G11 overriding never bypasses those).
   - Isolated the audit-scan's own query (exact WHERE/LATERAL shape from the migration) to verify
     it directly, sidestepping the unrelated gates: before any alert exists, the scan finds the
     override dispatch row and `g11_check_machine_mapping` returns `is_override=true,
is_violation=false` for it (1 row). After pre-seeding a `monitoring_alerts` row keyed to that
     same `dispatch_id` (simulating "already caught at write time"), the identical scan query
     returns 0 rows -- the dedupe clause works.
     Rollback (`supabase/rollback/DRAFT_prd137_f11_approve_refill_plan_audit_rollback.sql`) verified
     byte-exact against live before drafting.

   **All three G11 migrations are now fully drafted and tested. Ready to apply once the window
   opens, in order f11a -> f11b -> f11c (helper/validate must exist before write_refill_plan or
   approve_refill_plan reference it).**

## F4 drafting status (pre-window)

`supabase/migrations/DRAFT_prd137_f4_weimi_remove_qty_gate.sql` -- write_refill_plan gets V8,
stacked on top of V7 (G11): a Remove/Machine To Warehouse line can't request more than
`v_live_shelf_stock.current_stock` currently shows on that machine/shelf. Skipped (not blocked)
when WEIMI has no live row at all for that machine/shelf. Confirms the fork's finding: the 4 refill
engines already source Remove qty from WEIMI correctly; the real gap was write_refill_plan itself
being a pure pass-through writer. WRITTEN AND TESTED against real live WEIMI data (AMZ-1038-3001-O1
A08, `current_stock=16` today):

- Remove qty 20 (> 16) -> blocked, `V8_weimi_remove_qty`, correct message naming both quantities.
- Remove qty 10 (<= 16) -> `status: ok`.
- Remove qty 999999 on a shelf code with no WEIMI row (`Z99`) -> `status: ok` (fails open on
  absent data, as designed).
  Rollback (`supabase/rollback/DRAFT_prd137_f4_weimi_remove_qty_gate_rollback.sql`) restores the
  exact pre-V8 (V7/G11-only) body -- must apply AFTER `DRAFT_prd137_f11b_write_refill_plan_v7.sql`
  in the window, since it stacks on that version.

## Block A+ (added mid-run by CS, "never cut", do right after Block A)

A7. Driver Remove card must always collect qty + expiry per variant (prefill from the bound lot)
and show every RPC error -- `driver_confirm_remove` must never 400 silently. Evidence: 6x 400
on 2026-09-30 06:29-10:17.

**DONE, SHIPPED (FE-only, no window gating needed, same as F6 bugs 1&2), commit `4f0792c`.**
Fork confirmed root cause exactly: the only call site
(`src/app/(field)/field/dispatching/[machineId]/page.tsx` `handleSave()`) hardcoded
`p_batch_breakdown: null`, so `driver_confirm_remove`'s R5a guard (`IF
COALESCE(jsonb_array_length(p_batch_breakdown),0)=0 AND (expiry_date IS NULL OR expiry_date <=
today+7) THEN RAISE EXCEPTION`) fired on every line whose bound expiry was missing or within 7
days -- and there was no UI on this card to collect an expiry at all (it was read-only), so the
driver had no way to recover. Fix: added a per-line, editable "Expiry on pack" date input
(prefilled from `line.expiry_date`, state `removeExpiry` keyed by `dispatch_id`), and the RPC call
now always sends a single-entry breakdown `[{qty: line.filled_qty, expiry: <that value or null>}]`
-- built from the canonical `{qty, expiry, wh_inventory_id?}` shape already used by
`receive_dispatch_line`/`set_dispatch_line_breakdown` (PRD-053B). Also fixed the error banner,
which was copy-pasted from the `receive_dispatch_line` branch and mislabeled every Remove RPC
failure as "Receive failed" -- now reads "Remove failed" for Remove lines, and the "already
received" idempotency check now also matches driver_confirm_remove's own "already
driver-confirmed" message.
TESTED against real data in rolled-back transactions: (1) reproduced the exact bug -- calling with
the OLD `p_batch_breakdown: null` payload against a real eligible Remove dispatch
(`e4fb039e-4238-4cc9-8aee-795869c67370`, `expiry_date NULL`) raises the exact quoted exception; (2)
the NEW payload shape with a null expiry (driver left the date blank) succeeds --
`status:'driver_confirmed_pending_wh_approval'`; (3) the NEW payload shape with a real driver-typed
expiry (`2027-06-01`) on a different real dispatch (`41f648f1-071f-44a3-8467-7ba114802e0a`) also
succeeds and `driver_confirmed_breakdown` stores exactly `[{"qty":4,"expiry":"2027-06-01"}]`.
`npx tsc --noEmit` and `npm run build` both clean before commit.

A8. Driver "Add return" on a shelf with no planned Remove line: today `insert_driver_remove_line`
refuses ("only 0 units remaining across the planned Remove lines"). Needs a path to create the
Remove line itself via `add_dispatch_row` (auto packed + picked up), capture variant + qty +
expiry, and land it in Warehouse Confirmations. INVESTIGATED, DESIGNED, NOT YET CODED.
Confirmed root cause: `insert_driver_remove_line` is a **reclassify-an-existing-planned-total**
writer, not a create-new-Remove writer -- it sums sibling Remove lines on the same
machine+shelf+pod+date, requires `sibling_total >= p_quantity`, then draws down siblings by
exactly the amount it inserts as the new variant (conservation: total planned Remove volume for
that shelf never changes, only which variant it's attributed to). When NO Remove was planned at
all (`sibling_total = 0`), there is nothing to reclassify, so it correctly refuses -- by design,
not a bug. `add_dispatch_row`'s existing `action='Remove'` branch is close but not quite it: it
inserts with `packed=false, picked_up=false` (a NEW planned line for a FUTURE pack/pickup cycle),
and resolves expiry automatically from `v_pod_inventory_latest`'s FEFO batch rather than from a
driver-entered reading -- wrong shape for "I already physically removed this, unplanned, right
now." Confirmed `v_wm_confirmations`'s Remove branch only requires `action='Remove' AND
picked_up=true AND wh_approved_at IS NULL AND COALESCE(driver_confirmed_qty, filled_quantity,
quantity, 0) > 0 AND NOT returned/item_added/cancelled/skipped` -- it does NOT check `packed`, so
a new row landing with `picked_up=true` + `driver_confirmed_qty` set + `driver_confirmed_at` set
lands in Warehouse Confirmations correctly without any further step.
**Design for a new RPC** (name TBD, e.g. `driver_report_unplanned_remove`): same
role/validation shape as `insert_driver_remove_line` (field_staff+ roles,
`p_reason` >= 10 chars, `p_quantity > 0`), but skips the sibling-sum/draw-down logic entirely --
always a pure additive INSERT into `refill_dispatching`: `action='Remove', packed=true,
picked_up=true, dispatched=true, driver_confirmed_qty=p_quantity, driver_confirmed_at=now(),
driver_confirmed_by=p_driver_id, expiry_date=p_expiry_date` (driver-entered, not FEFO-resolved),
`comment='[DRIVER-UNPLANNED] '||p_reason`. Same class of risk as last night's held "swap on the
spot" and "variant return with zero prior line" items -- genuinely new writer, no existing RPC to
extend safely -- but the design is now fully concrete and low-risk (single INSERT, additive only,
lands in an existing, already-reviewed WH queue). Tractable tonight if Block A time allows; hold
for a dedicated follow-up if not, per the same judgment call as last night's similar items.
A9. Legacy-variant sweep: any lane whose Active pod rows hold a boonz variant not mapped to the
lane's WEIMI pod product should get an automatic Remove line in the next plan, before any
Refill. CS expects USH A6, NOOK A6, VML-1003 A8 (all under 35g-labelled lanes, Plaay Tablets -
Dark Chocolate 50g) to show up.
A10. Report Active pod rows whose product is not mapped to the lane at all (e.g. WPP A06 Coca Cola
Zero x6, x9 on a Plaay lane). Read-only report; archive only after CS review -- no automatic
writes for this item.

**A9/A10 REPORT DONE, DECISION NEEDED BEFORE ANY WRITE.** Full fleet audit in
`docs/loops/2026-09-30-night/A9-A10-legacy-variant-fleet-audit.md`. CS's own example confirmed
exactly (Plaay Tablets - Dark Chocolate on USH A06/NOOK A06/VML-1003 A08, WPP A06 Coca Cola Zero
x6+x9) -- but the real fleet-wide scope is far bigger than the example: **380 mismatched rows, 132
lanes, 29 machines, 1692 units**. Recommending AGAINST auto-generating ~380 Remove lines tonight
sight-unseen (observation in the report: much of this looks like WEIMI-recognition drift, not
purely bad physical stock -- e.g. whole different snack categories cycling through the same bin
fleet-wide, plus a likely `Vitamin Well`/`Vitamin well` duplicate-boonz-product data-hygiene issue
mixed in). A9's Remove-generation logic is HELD pending a CS scope decision (pilot on the 3 named
lanes only / full fleet run / hold for a data-quality pass first) -- see the report's
"Recommendation" section. A10's own instruction (report only, archive after CS review) is already
satisfied by the report itself; no further action needed from A10 tonight.

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
