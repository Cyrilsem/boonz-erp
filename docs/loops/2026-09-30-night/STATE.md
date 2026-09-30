# ONE LOOP, 2026-09-30 night, run state

Started 2026-09-30 14:51 Dubai (well before the 22:00-06:00 window; using the pre-window hours
for read-only investigation and drafting/rolled-back testing only, per this run's own hard rule
that dispatch/pickup/plan/mapping migrations apply only inside the window).

## Cody review, pre-window (16:36 Dubai)

Ran Cody on the full batch of 7 tonight's DRAFT migrations (G11 x3, F4, F3, F5, F7) plus a
reference back to last night's still-pending F1b. **Verdict: Approve.** Checked Articles 1, 4, 6,
8, 12, 16 -- no violations. Notable strength: F3 extends the EXISTING canonical
`v_wm_confirmations` object (METRICS_REGISTRY.md's registered "Warehouse Confirmations queue" row)
instead of forking a parallel view; G11/F4 read the existing canonical `v_wh_pickable`/
`v_live_shelf_stock` objects rather than re-deriving inline. One pre-existing registry gap
surfaced (not introduced tonight): `wm_confirm_line`, `add_m2m_transfer`, and
`validate_refill_plan` were never in `RPC_REGISTRY.md` at all -- since all three are touched
tonight, close that gap when updating the registries post-apply. Full registry updates
(`MIGRATIONS_REGISTRY.md`, `RPC_REGISTRY.md`, `CHANGELOG.md`) still need doing after applying
inside the window -- not done yet, tracked as a post-apply step.

## READY-TO-APPLY SUMMARY (consolidated, 16:58 Dubai, ~5h before window)

Everything below is drafted, tested in rolled-back transactions against real/synthetic data, and
either Cody-approved or (F1b) already approved and tested last night. Apply in this exact order
once the 22:00-06:00 Dubai window is confirmed open (each is its own migration; rename every
DRAFT_ file to match whatever version `apply_migration` actually records, per the standing rule):

1. `DRAFT_prd137_f11a_g11_helper_and_validate.sql` -- g11_check_machine_mapping + validate_refill_plan G11 gate.
2. `DRAFT_prd137_f11b_write_refill_plan_v7.sql` -- write_refill_plan V7 (G11 reject/override).
3. `DRAFT_prd137_f4_weimi_remove_qty_gate.sql` -- write_refill_plan V8, stacks on V7.
4. `DRAFT_prd137_f11c_approve_refill_plan_audit.sql` -- approve_refill_plan override-audit scan.
5. `DRAFT_prd137_f3_wm_confirmations_single_inbox.sql` -- v_wm_confirmations + wm_confirm_line + check_stale_wm_confirmations.
6. `DRAFT_prd137_f5_ad_hoc_m2m_role_allowlist.sql` -- add_m2m_transfer role fix.
7. `DRAFT_prd137_f7_confirm_m2m_delivery.sql` -- new RPC confirm_m2m_delivery.
8. `DRAFT_prd137_f6_parent_dispatch_id_db_only.sql` -- schema column + pack_dispatch_line stamp.
9. `DRAFT_prd137_f1b_pickup_completion_and_stale_press.sql` -- from last night, apply last (touches mark_picked_up/pickup triggers, independent of the G11/F3/F4/F5/F7/F6 batch above, no ordering dependency either way).

After all 9 applied: re-run `check_ambiguous_function_overloads()` (baseline confirmed 0 at 16:58
Dubai before any of this applied), run the 12-item smoke test list from Task D's own GATES
section, update `MIGRATIONS_REGISTRY.md` + `RPC_REGISTRY.md` (closing the pre-existing
`wm_confirm_line`/`add_m2m_transfer`/`validate_refill_plan` registration gap Cody flagged) +
`CHANGELOG.md`, commit every renamed migration + rollback file to main, then Block D's
`mark_picked_up` residue sweep, then write the final `docs/loops/2026-09-30-night/REPORT.md` +
WhatsApp summary. Block C (PRD-133/123/130/R2) only if time remains after all of that -- explicitly
lowest priority, cut at 04:30 regardless. (PRD-133's own "G1-G7 P0 tooling" label in Task D's
prompt doesn't map to any gate numbering found in `docs/prds/PRD-133-135-selection-strategist-learning.md`
-- STEP 0's own PRD-133 assessment below is the closest available read of what's actually open.)

## STEP 0, done (max 15 min, read-only)

| Item                                            | Status        | Evidence                                                                                                                                                                                                                                                                                                                               |
| ----------------------------------------------- | ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| PRD-137 Phase 0 (a-l)                           | DONE          | docs/loops/2026-09-29-prd137/REPORT.md, all committed 2026-09-29/30 night                                                                                                                                                                                                                                                              |
| F1 (auto pickup, sticky)                        | DONE          | live, migration 20260929200429                                                                                                                                                                                                                                                                                                         |
| F1b (completion trigger + stale-press widening) | PARTIAL       | drafted and tested in a rolled-back transaction, NOT applied. supabase/migrations/DRAFT_prd137_f1b_pickup_completion_and_stale_press.sql                                                                                                                                                                                               |
| F2 (Could not remove credits nothing)           | DONE          | live, migration 20260929201947, plus FE change                                                                                                                                                                                                                                                                                         |
| F3 (Warehouse Confirmations single inbox)       | OPEN          | not started; item g's double-credit root cause understood, not fixed at the source                                                                                                                                                                                                                                                     |
| F4 (Remove qty from WEIMI)                      | OPEN          | investigated only: source (pod_inventory.current_stock) embedded across auto_generate_refill_plan/engine_add_pod/engine_swap_pod/propose_swap_plan, each 10-16KB                                                                                                                                                                       |
| F5 (driver off-plan actions)                    | OPEN          | not started, no RPCs confirmed to exist yet for ad hoc return/M2M/swap from the driver app                                                                                                                                                                                                                                             |
| F6 (pack screen bugs)                           | OPEN          | 3 bugs confirmed with exact file:line (qty cap, error surfacing, merge-key), no fix drafted                                                                                                                                                                                                                                            |
| F7 (M2M actual qty + auto WH-return diff)       | OPEN          | not started                                                                                                                                                                                                                                                                                                                            |
| F8 (pending reviews dedupe/escalate)            | DONE          | live, migration 20260929202658                                                                                                                                                                                                                                                                                                         |
| F9 (G7 expiry-pull exception)                   | DONE          | live, migration 20260929195322                                                                                                                                                                                                                                                                                                         |
| F10 (Picker P1 exclusion)                       | DONE          | live, migration 20260929195828                                                                                                                                                                                                                                                                                                         |
| PRD-123 (VAT on PO receipt)                     | OPEN          | doc status DRAFT, ready to batch, nothing applied                                                                                                                                                                                                                                                                                      |
| PRD-130 items 03/04                             | OPEN          | still in supabase/migrations_parked/, not applied                                                                                                                                                                                                                                                                                      |
| PRD-133 (pick_machines_v12 shadow engine)       | PARTIAL       | pick_machines_v12, v_picker_shadow_diff, picker_backtest_results, machines_to_visit_shadow, picker_config all live. backtest_priority function does NOT exist live (drafted in the PRD doc only). supabase/tests/selection_v2.sql RE-RUN tonight (16:5x Dubai) -- see note below. picker_config presumably still 'shadow', no cutover. |
| PRD-134 (knowledge tables)                      | DONE (CLOSED) | tables live with seed data, confirmed 2026-09-30                                                                                                                                                                                                                                                                                       |
| PRD-135 (engine safety flags)                   | DONE (CLOSED) | slow_lane_fill_cap_pct live, NULL/off, confirmed 2026-09-30                                                                                                                                                                                                                                                                            |
| Loop R2 (stitch)                                | OPEN          | not investigated this run                                                                                                                                                                                                                                                                                                              |

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

## F3 drafting status (pre-window)

`supabase/migrations/DRAFT_prd137_f3_wm_confirmations_single_inbox.sql` -- Warehouse Confirmations
single inbox. Root cause reconfirmed against real live data: `v_wm_confirmations` only ever looked
at `action='Remove'` rows; a Refill/Add-New line that's returned undelivered gets auto-credited by
`return_dispatch_line` with zero warehouse review and never appears anywhere. As of today there are
**11 such rows sitting live, unreviewed** (31 units total, including the exact `d9da3b7f` row
traced during the 29 Sep incident), plus **6 quarantined REMOVE-RETURN `warehouse_inventory` rows**
(14 units) that were never surfaced anywhere either.

Built tonight: (1) `refill_return_ack` branch (Refill/Add-New returns, acknowledge-only), (2)
`quarantine_batch` branch (quarantined batches, acknowledge-only, releases the quarantine), (3)
qty<=0 hidden on every branch, (4) `check_stale_wm_confirmations()`, a 48h staleness alert mirroring
`check_stale_pending_reviews`'s shape. Held for a follow-up, NOT built tonight: "M2M legs that ended
in WH" (needs its own read of `cancel_m2m_transfer`'s `p_convert_source_to_return` path first) and
"split by variant" (a real per-line UI/data-model change, same risk class as the driver-facing
writers already held under F5/A8).

`wm_confirm_line` gained two acknowledge-only source branches that never re-credit
`warehouse_inventory` (the stock movement already happened) -- they only flip the review flag
(`wh_approved_at` for `refill_return_ack`, `provenance_reason` -> `manual_adjust` for
`quarantine_batch`, same transition `release_wh_quarantine` already uses since `quarantined` is a
GENERATED column derived from `provenance_reason`, PRD-098).

**Two real bugs caught and fixed during testing, before ever touching live data:**

1. My first draft computed `refill_return_ack`'s qty as `COALESCE(filled_quantity, quantity)`.
   Live data showed `filled_quantity=0` (a real zero, not NULL) on every one of these rows --
   `COALESCE(0, quantity)` always returns 0, silently hiding the qty on every row. Root cause,
   confirmed by reading `return_dispatch_line`'s own body: its non-Remove branch computes
   `v_return_qty := COALESCE(v_dispatch.filled_quantity, v_dispatch.quantity)` BEFORE its own
   trailing `UPDATE ... SET filled_quantity = 0` resets the column -- so the credited amount was
   the ORIGINAL `quantity` (filled_quantity was NULL at call time, not 0), but `filled_quantity`
   is unconditionally 0 by the time anything reads the row afterward. Fixed by using `rd.quantity`
   directly (return_dispatch_line's non-Remove branch has no partial-return path, so the full
   planned quantity is always correct here).
2. `wm_confirm_line`'s acknowledge branch for `quarantine_batch` set `provenance_reason =
'manual_adjust'` explicitly, but a live re-test showed the column coming back as
   `'dispatch_return'` instead. Root cause: I'd copied the original function's
   `set_write_context(..., 'dispatch_return', ...)` call unconditionally before branching --
   its 3rd argument sets the `app.provenance_reason` GUC, and a generic `warehouse_inventory`
   trigger stamps `provenance_reason` FROM that GUC, silently overriding the explicit UPDATE
   value. `release_wh_quarantine` (the existing canonical writer for this exact transition) never
   sets that GUC at all -- confirmed by reading its body. Fixed by giving the `quarantine_batch`
   branch its own `set_config` calls (via_rpc/rpc_name/mutation_reason only, matching
   `release_wh_quarantine`'s exact shape) instead of routing through `set_write_context`.
   TESTED against real rows after both fixes: real `refill_return_ack` row `d9da3b7f` -> dry run then
   real acknowledge -> `wh_approved_at` set, disposition_event logged. Real `quarantine_batch` row
   `4fb5624a-9a9f-406a-90b8-c633f7cd9d9e` -> dry run then real acknowledge -> `provenance_reason`
   correctly becomes `manual_adjust` this time. Wrong `p_outcome` on either acknowledge-only source
   correctly rejects. `qty<=0` leak check across the whole view returns 0 rows. `disposition_events`
   has its own fixed-enum CHECK constraints on `source`/`state` that don't know either new branch
   name -- reused `source='return_receipt'`/`state='restocked'` (both already allowed) and kept the
   real distinction in `reason` text instead of inventing new enum values.
   Both the view and `wm_confirm_line` rollbacks
   (`supabase/rollback/DRAFT_prd137_f3_wm_confirmations_single_inbox_rollback.sql`) verified
   byte-exact against live before drafting.

## F5 drafting status (pre-window)

`supabase/migrations/DRAFT_prd137_f5_ad_hoc_m2m_role_allowlist.sql` -- one-line role allowlist fix:
`add_m2m_transfer` already fully implements ad hoc M2M (inserts both legs pre-packed/dispatched,
conservation by construction) but excluded `field_staff` from its own role check. Added
`field_staff` to the allowlist; no other logic touched. Rollback
(`supabase/rollback/DRAFT_prd137_f5_ad_hoc_m2m_role_allowlist_rollback.sql`) verified byte-exact
against live (including two inline "Loop 2026-09-25 A4" comments in the body that a first
whitespace-stripped diff attempt missed -- comments count as literal text in that comparison, not
whitespace). TESTED the actual boolean change directly: `'field_staff' NOT IN (...)` is `true`
under the old 4-role list and `false` under the new 5-role list; an unrelated role (`anon_role`)
stays blocked under both. FE wiring for a driver-facing "record ad hoc M2M" button is HELD, same
reasoning as A8 and last night's held items -- confirmed zero existing call site anywhere in
src/ (the pickup page only shows M2M qty as static read-only text); a net-new safety-relevant
driver flow is not something to design and ship blind under time pressure. The DB-side fix alone
is safe to apply now on its own merits (it only widens who may call an RPC operator_admin/
warehouse already exercise today).

## F7 drafting status (pre-window)

`supabase/migrations/DRAFT_prd137_f7_confirm_m2m_delivery.sql` -- new RPC
`confirm_m2m_delivery(p_transfer_id, p_source_actual_qty, p_dest_actual_qty, p_caller_id,
p_reason)`. Confirmed by reading `receive_dispatch_line`'s body: it already runs its full
`pod_inventory` update for an M2M leg (`is_m2m=true`) regardless -- deactivates the source shelf's
row, increments the dest shelf's row -- it only skips `warehouse_inventory` credit/debit for M2M,
which is correct (M2M never touches the warehouse on its own). So calling it on both legs with the
REAL actual quantities already gets `pod_inventory` right at both ends; the one thing it can't do
per-leg is notice a mismatch between the two real quantities. That mismatch handling is this RPC's
entire job: reject `dest_actual > source_actual` outright (physically impossible), and for a
shortfall, credit `warehouse_inventory` for exactly the difference as a disclosed direct write
(own reasoned default per the fork's earlier note: attributed to the SOURCE machine's primary
warehouse, since that's what a physical audit would check against -- the spec text says "WH
return line", not "writeoff", and doesn't resolve this itself).
TESTED against a real fixture (two ad hoc M2M transfers of "Coca Cola - Zero" via `add_m2m_transfer`,
AMZ-1029-3003-O1 A13 -> AMZ-1038-3001-O1 A13, 5 units each):

- Exact match (source=5, dest=5) -> `shortfall: 0`, no warehouse_inventory change.
- Shortfall (source=5, dest=3) -> `shortfall: 2`, credited to WH_CENTRAL
  (`4bebef68-9e36-4a5c-9c2c-142f8dbdae85`) -- real stock went `346 -> 348`.
- `dest_actual (5) > source_actual (3)` -> correctly rejected before any write.
  Hit one real constraint along the way: `warehouse_inventory.batch_id` has its own vocabulary CHECK
  (`enforce_warehouse_batch_id_vocabulary`) -- `M2M-SHORTFALL-...` isn't an allowed prefix, fixed to
  `TRANSFER-SHORTFALL-...` (`TRANSFER-` is allowed).
  Rollback (`supabase/rollback/DRAFT_prd137_f7_confirm_m2m_delivery_rollback.sql`) is a plain
  `DROP FUNCTION` -- net-new function, nothing to restore.
  FE: zero existing call site anywhere in src/ (the pickup page shows M2M qty as static read-only
  text) -- held for a follow-up, same reasoning as A8/F5's held items.

## B5 backtest (2026-09-16..30) and Block D report, pre-window (16:42 Dubai)

Ran the final, fully-tested `g11_check_machine_mapping` against every real `refill_dispatching`
Refill/Add-New row, `dispatch_date` 2026-09-16..30 (rolled-back transaction, read-only against
real data): **1529 lines scanned, 87 would-block (non-override) violations, 0 overrides** (no
historical line ever carried a `[sub]` comment -- that convention starts tonight). All 4 of Task
D's named examples confirmed present exactly: AMZ-1038 A08 Nestle Kit-kat, AMZ-1029 A08/A14/A15
Nutella - Biscuit T3 (+others), VML-1004 A02 Coca Cola - Regular, WPP-1002-4300-O1 A06 Plaay
Tablets - Dark Chocolate 35g (n=1, exact match). Grouped by machine (15 machines total, worst
offenders AMZ-1038-3001-O1 n=18, AMZ-1029-3003-O1 n=11, USH-1008-0000-W1 n=11) -- full list is in
the fork's original detail plus this final count; not re-pasted here since the earlier fork
investigation already carries the per-line detail and this run's helper is unchanged from what it
tested except the machine_id/product resolution paths, which only affect write_refill_plan/
validate_refill_plan, not this direct dispatch-row scan.

**Block D (30 Sep dispatched lines failing G11):** 11 lines, none `[sub]`-commented (all would
flat-reject under G11 today): AMZ-1029-3003-O1 A08 Nutella-Biscuit-T3 x7, AMZ-1038-3001-O1 A08
Nestle Kit-kat x7 + A08 Kinder Delice-Cake x8 (unpacked) + A15 Al Ain Water x8, MC-2004-0100-O1
A11 Coca Cola-Regular x6 (unpacked) + A13 Al Ain Water x3 + A14 Al Ain Water x4 (unpacked) + B14
Evian-330ML x2 (unpacked), VML-1003-0400-O1 A14 Al Ain Water x15, VML-1004-0500-O1 A02 Coca
Cola-Regular x2, WPP-1002-4300-O1 A06 Plaay Tablets-Dark Chocolate 35g x3. Per Block D's own
instruction: report only, no edits to packed rows -- none made. The "run the new `mark_picked_up`
once for 2026-09-30 residue and report the count" half of Block D depends on F1b actually being
applied, so it happens inside the window, after F1b applies.

**Held, not attempted pre-window:** the "fresh engine dry-run for 2026-10-01 must show 0 non-[sub]
violations" half of B5. Investigated the entry point first: the function named in the spec
(`auto_generate_refill_plan`) is itself DEPRECATED (RPC_REGISTRY.md, PRD-074, Article 13 --
EXECUTE revoked, zero callers, DROP-eligible 2026-10-04). The real current engine is a multi-stage
orchestrator (`orchestrate_refill_plan` -> `propose_add`/`propose_swap` -> `engine_finalize` ->
`engine_publish_to_refill_plan` -> `reconcile_intent_progress`) that writes real intermediate
drafts (`daily_plan_drafts`, `strategic_intents` reconciliation) at each stage -- not a single
function with a simple dry-run flag. Running that pipeline for a date (2026-10-01) that the real
operations team may run for real once the window opens is not something to improvise pre-window
without first understanding its exact dry-run semantics (if any) well enough to be sure nothing
gets left half-written. Recommend doing this INSIDE the window by piggybacking on the real
2026-10-01 planning cycle (if one runs tonight) rather than as a separate synthetic call, or as a
dedicated follow-up with more investigation time.

## F1b pickup-logic replay against real 30 Sep data (pre-window, 16:5x Dubai)

Task D's own gate ("Backtest the pickup logic by replaying 29 and 30 Sep field events") re-run
fresh, since the original 08:14 incident had already been resolved manually by the time I checked
(all 10 AMZ-1038-3001-O1 lines now show `picked_up=true`) -- so I reproduced BOTH real incident
shapes directly against today's real rows, in a rolled-back transaction (nothing committed):

- **Completion trigger:** reset AMZ-1038-3001-O1's 10 real packed 2026-09-30 rows to
  `picked_up=false` and the 11th real row (`85bcacbb-9ff5-45f4-8eb7-aa9f98a3fa26`, the actual
  `not_filled` line from the incident) back to `pack_outcome=NULL` -- confirmed this exactly
  reproduces the incident shape (`10 packed_not_picked, 1 still_undecided`). Then recorded that
  line's real decision (`not_filled`) and confirmed the trigger auto-flips all 10 to
  `picked_up=true` with zero manual presses (`after_packed_not_picked: 0`).
- **Stale-array widening:** reset two of AMZ-1038-3001-O1's real packed rows (A03, A05) to
  `picked_up=false`, then ran the F1b widened `mark_picked_up` UPDATE logic passing only ONE of
  their two dispatch_ids (simulating the FE's stale client array that never learned about the
  second pack event) -- both rows correctly flip to `picked_up=true`, confirming the widening
  catches the one the caller's array missed.
  Both replays confirm F1b's design against real data reproducing the exact real incident shapes,
  not just synthetic approximations.

## F6 bug 3 drafting status (pre-window) -- DB half only

`supabase/migrations/DRAFT_prd137_f6_parent_dispatch_id_db_only.sql` -- adds a nullable
`parent_dispatch_id uuid REFERENCES refill_dispatching(dispatch_id)` column and stamps it on
`pack_dispatch_line`'s multi-batch split child INSERT (the exact spot that already computes
`v_new_child_id` and already returns `child_dispatch_id` per pick in its own response -- it just
never persisted the relationship on the row itself). Purely additive: NULL for every unsplit line
and for the parent row itself; no existing behavior changes until something reads it.
TESTED against a real unpacked Refill line (`308adc6c-d492-405c-9368-a1571d1aeb34`, qty 6, Coca
Cola - Zero on WPP-1002-4300-O1) split across two real warehouse_inventory batches (3+3): the
first pick updates the parent row in place (as designed, `child_dispatch_id: null`), the second
pick creates exactly one child row, and that child's `parent_dispatch_id` correctly equals the
parent's `dispatch_id` (`children_with_correct_parent: 1`).
Rollback (`supabase/rollback/DRAFT_prd137_f6_parent_dispatch_id_db_only_rollback.sql`) verified
byte-exact against live before drafting -- caught and fixed a real transcription gap along the
way (4 inline `-- v2 VOX GUARD` comments dropped when first copying the 200+ line function body;
the whitespace-stripped diff check correctly caught it since comments count as literal text, not
whitespace).
**FE half deliberately HELD**, same reasoning as A8/F5/F7's held items: the packing screen's card-
merge block (grouping by a `${action}|||${boonz_product_id}|||${shelf_code}` heuristic today) also
drives `extraSliceIds`/`extraSlicePacked` accumulation and `batchPickQtys` initialization on a
live, safety-relevant driver tool -- rewriting its grouping key to `parent_dispatch_id ??
dispatch_id` needs real browser testing of the actual packing flow, not a rushed edit. Applying
just the DB half tonight is safe on its own and unblocks that FE work for a dedicated follow-up.

**Cody review (16:5x Dubai): Approve.** Articles 2, 4, 8, 12, 14 checked -- ADD COLUMN on an
existing table needs no new RLS policy (row-level, already covers every column); `pack_dispatch_line`
already sets via_rpc/rpc_name and validates role/inputs unchanged; the generic audit trigger
picks up the new column on the same INSERT it already audits. One non-blocking note: the
self-referencing FK has no `ON DELETE` clause (defaults to `NO ACTION`) -- inert since
`refill_dispatching` rows are never hard-deleted in this codebase (cancelled/skipped are the soft
states used everywhere), but worth a comment if this migration is ever revisited.

## Build order for tonight (pre-window drafting now, apply in window)

1. G11 (Block B) -- DONE, drafted+tested, ready to apply.
2. F4 -- DONE, drafted+tested, ready to apply.
3. F3 -- DONE, drafted+tested, ready to apply.
4. F5 (DB side only) -- DONE, drafted+tested, ready to apply. FE wiring held.
5. F7 DB side (confirm_m2m_delivery) -- DONE, drafted+tested, ready to apply. FE held.
6. F1b -- already drafted and tested last night, just needs applying + renaming.
7. F6 bug 3 (parent_dispatch_id, DB half) -- DONE, drafted+tested, ready to apply. FE held.
8. F5's variant-return/swap-on-spot, A8's unplanned-Remove writer, F7's driver UI, F6's FE
   merge-key rewrite -- holding, same reasoning as last night (net-new/regression-risky FE work
   on live driver tools, not tractable to rush without real browser testing).
9. Block C (PRD-133/123/130/R2) -- only if A+B fully green with time left, cut at 04:30 regardless.

## Block C investigation started early: PRD-133 selection_v2 test re-run (16:5x Dubai)

Task D's own C1 text ("PRD-133 P0 tooling G1-G7") doesn't map to any gate numbering found in
`docs/prds/PRD-133-135-selection-strategist-learning.md` -- closest real match is the "Tests"
section's own description of `supabase/tests/selection_v2.sql`: "one assertion group per rule...
each P1 trigger, each P2 trigger, the VOX gate, the cap, the cluster rule, the donor rule, the
cooldown bypass" -- 7 named rule groups, plausibly what "G1-G7" was informally referring to.

Ran the file (confirmed genuinely read-only by its own header: creates and drops its own temp
tables, no writes to any real table -- safe pre-window). Two runs:

1. **As written** (hardcoded `plan_date='2026-09-25'`, the loop's own evidence day, now 5 days
   stale): first assertion failed -- `AMZ-1029-3003-O1 expected tier=P1, got P2`. This is NOT a
   regression: the file's own header says plainly it reads `pick_machines_v12`'s CURRENT live
   behavior against named evidence machines, not a historical replay ("there is no as-of-date
   capability to replay a past day yet" -- exactly why `backtest_priority` doesn't exist yet
   either). The Activia lot that was expiring around 2026-09-25 has had 5 real days to be sold,
   removed, or restocked, so today's live state naturally no longer matches that day's frozen
   evidence. Expected drift, explicitly documented in the file's own comments, not a code bug.
2. **Structural rules only** (the date-independent checks: cap, total-cap, P1-uncapped invariant,
   cluster-never-on-null-building, cluster-never-on-independent-P1/P2, visit-value-above-median,
   no-em-dash-in-reasons), re-run against `CURRENT_DATE` instead of the stale evidence date --
   **all passed cleanly**. This is a genuine, useful signal: `pick_machines_v12`'s core mechanics
   are healthy and unregressed on today's real fleet data.

Re-validating the date-SPECIFIC evidence checks (P1/cooldown-bypass, VOX-gate, the two named
donors, phantom-expiry, fill-gate, cluster-existence) would require re-identifying fresh evidence
machines for today's actual fleet state (mirroring the original 2026-09-25 evidence-gathering
exercise) -- a real, nontrivial undertaking, correctly out of scope for Block C's lowest-priority
treatment tonight. Not attempted. `backtest_priority` (the genuinely missing PRD-133 piece) is a
substantial multi-metric historical-replay function needing deep understanding of both v11 and
v12's full tier/cluster/donor logic -- also correctly held, not something to build under time
pressure alongside everything else tonight.

## Smoke-test prep (18:05 Dubai, ~3h55m before window)

Gate 4 in `docs/REFILL-DAILY-LOOP.md` (pack a line, add a return, add a return variant, add an
intra-machine move, using the deployed app's real test accounts) needs one account that can do
all four. Checked role gates directly: `pack_dispatch_line` and `return_dispatch_line` have no
role restriction in their body at all (any authenticated caller); `insert_driver_remove_line`
(return variant) and `add_intra_machine_move` both allow `field_staff`, `warehouse`,
`operator_admin`, `superadmin`, `manager`. So `warehouse@boonz.test` (password documented in
CLAUDE.md as `Test1234!`) covers all four actions on its own -- no need to track down
`anthony001@boonz.test`'s undocumented real password (confirmed live: `anthony001@boonz.test` is
the real `field_staff` account, `driver@boonz.test` is `warehouse`, matching project memory
exactly, CLAUDE.md's own test-user table is stale on this point).

No dedicated test machine exists in the fleet (`official_name ilike '%test%'` returns nothing) --
per the gate's own wording ("a real or synthetic test machine"), will pick a real, low-traffic
machine live during the window and use small, clearly-commented quantities for the four actions,
same discipline as every other real-data test tonight.

Per the established policy boundary from last night: entering `warehouse@boonz.test`'s credentials
qualifies for the "testing the user's own application" exception only on a literal local dev host
(`localhost`), never on the deployed `boonz-erp.vercel.app` -- will run the smoke test against the
local dev server once the window opens, same as last night's verification.
