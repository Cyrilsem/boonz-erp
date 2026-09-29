# PRD-137: Field flow integrity

Status: IN PROGRESS 2026-09-29
Owner: CS
Date: 2026-09-29
Window rule: migrations touching field-app, packing, pickup or warehouse-confirmation functions
run only inside the confirmed 22:00 to 06:00 Dubai window.
Hard rules for this run: no em dashes anywhere. Canonical RPCs only for data, any direct write
disclosed in the report. DB migrations only inside the 22:00 to 06:00 Dubai window. No new
overloads: a migration that changes an RPC's argument list replaces the function and DROPs the
old signature in the same migration. Every migration committed to main in the same run. Cody
review required for any SECURITY DEFINER change. Never override the packed-row guard.

## Context, prod evidence, 2026-09-29 refill, 10 machines

1. AMZ-1038 pack "not saving": `edit_dispatch_qty` accepted 25+25 Nutella T3 when WH had 25;
   `pack_dispatch_line` raised; the pack screen swallowed the error (6 failed tries).
2. Packed lines invisible to drivers: `mark_picked_up` pressed once per machine at 08:47; lines
   packed later, M2M legs and `add_dispatch_row` lines never picked up. CS pressed it manually
   09:34 (35 lines).
3. Variant returns failed: loop R1 created an ambiguous 8-arg overload of
   `insert_driver_remove_line` (hotfixed). `propose_decommission_plan` has the same ambiguity
   (5-arg vs 6-arg with default) and is still live.
4. `return_dispatch_line` on a REMOVE line ("could not remove") INSERTs a quarantined
   REMOVE-RETURN warehouse row and inactivates the pod row. Quarantined REMOVE-RETURN rows are
   invisible in Warehouse Confirmations (26 Sep: Hunter BT 3, Hot Chili 2, Sea Salted 1 still
   hidden).
5. Driver mis-taps with no confirm: USH A14 Nutella T3 8 filled but tapped Returned (WH wrongly
   credited +8); AMZ-1038 A08 Kit-kat 10 tapped Returned.
6. No in-app path for off-plan moves; team used WhatsApp.
7. Remove qty comes from `pod_inventory` not WEIMI physical (ALJLT planned 17, driver pulled 4).
8. Stale queues: 20 driver Pending Reviews 5 to 6 days old; VML-1004 A03 Red Bull return 102h;
   about 19 qty-0 zombie Remove rows since 15 Sep.
9. Pack screen may hide a second line of the same product (AMZ-1038 A16 Vitamin Well Zero Peach
   2 + 1; CS saw "only 1").

## Already done tonight, do not redo

USH A13 per-flavour returns (BT 2, HC 2, SSCV 2) and wrong quarantine row 0c4e7a0d rejected; USH
A02 Red Bull Diet 3 and USH A06 Plaay dark 50g 2 Remove rows confirmed pending WH approval; ALJLT
A11 McVities confirmed 4; AMZ-1038 Nutella A06 16 / A08 9.

## Phase 0, data reconciliation

Dispatch_date 2026-09-29, via canonical RPCs only, before/after shown per item. Capacity: do not
change any capacity.

a. USH-1008 A14 Nutella T3 8: actually filled. Reverse the WH credit made by
`return_dispatch_line` at 11:35 Dubai and add 8 to the machine pod (`adjust_warehouse_stock`
with existing consumer_stock, `adjust_pod_inventory`).
b. IRIS-1070 to AMZ-1038 A08: McVities Mini Milk 4 (exp 2026-10-29) plus Mini Dark 6 (exp
2026-12-22) moved by driver. Record as a completed move (IRIS pod down, 1038 pod up).
c. AMZ-1038 A08 Kit-kat 10 tapped Returned: leave the WH credit, flag for Simran's morning count.
A08 Nutella 9 never packed: cancel.
d. AMZ-1038 A06 Nutella filled 25 vs line 16: find which batch the extra 9 left from and
reconcile WH.
e. M2M Red Bull: USH Diet leg 2 to 4 (1038 received 4); USH Regular leg 4 matches 1068 filled 4.
Approve and close both transfers so pods move.
f. Cancel never-packed lines: NOOK A15 Al Ain 5, NOOK A14 Vitamin Well Care 3, USH A10 Bounty 3,
AMZ-1057 A07 Bounty 4.
g. ADDMIND A16 stray Coca Cola Zero Refill 8 (created_by_edit, returned): verify it credited
nothing wrong; neutralise.
h. Surface the 26 Sep quarantined REMOVE-RETURN Hunter rows in Warehouse Confirmations (after
F3).
i. ALJLT duplicate driver Pending Reviews "Removed (expired) 4": keep one, reject the duplicate.
j. Close the 3 stale pending `refill_plan_output` rows for ALJLT-1015-0200-O1, plan_date
2026-09-29.
k. Drop `propose_decommission_plan` 5-arg overload (keep the 6-arg with `p_min_pearson`), confirm
`check_ambiguous_function_overloads()` returns 0. (Already done earlier tonight, see STATE.md,
re-verify only, do not repeat.)
l. Delete or close qty-0 zombie Remove rows older than 7 days (not packed goods).

## Phase 1, fixes

Each with a rolled-back SQL test and an app smoke test.

F1. **Pickup.** A line packed after `mark_picked_up` for that machine and date is auto picked up;
M2M legs and operator-added Remove/M2M lines are pickup-ready when packed. Invariant: no row
`packed=true, picked_up=false` for a machine that already has picked-up rows that day.

F2. **Driver outcomes.** Explicit buttons with a confirm dialog: Refill/Add = "Put in machine" /
"Brought back"; Remove = "Removed (count + expiry per variant)" / "Could not remove". "Could not
remove" must NOT touch `warehouse_inventory` or `pod_inventory`. Fix `return_dispatch_line`
accordingly for Remove lines.

F3. **Warehouse Confirmations** is the single inbox for every unit heading to the WH: confirmed
Removes, Refills brought back, M2M legs that ended in WH, quarantined REMOVE-RETURN rows. Hide
qty 0. Split by variant works. Alert (`monitoring_alerts`, warning) for items older than 48h.

F4. **Remove quantities** in plan and pack come from WEIMI physical lane count; WH confirms the
driver-entered count.

F5. **Driver app off-plan actions.** Add a return with variant and expiry; move N units to
another machine (ad hoc M2M, both legs, conservation); on-the-spot swap. Canonical RPCs only,
test each from the app.

F6. **Pack screen.** Qty input capped at free stock with "Max available: N"; every RPC error
shown on the card, never swallowed; two lines of the same product both visible (fix any merge-key
collapse). `edit_dispatch_qty` rejects qty above free stock for warehouse lines.

F7. **M2M.** Driver enters actual qty on each leg; if source does not equal destination, the
difference becomes a WH return line automatically.

F8. **Driver Pending Reviews.** Collapse duplicates, escalate items older than 48h.

## Phase 2, close-out (from the earlier plan, still not run)

- PRD-123 VAT on every PO receipt (wire `receive_purchase_order` to `set_po_document_totals`;
  test with PO-9595).
- PRD-130 steps 03/04 from `supabase/migrations_parked`: close if covered by loop R1/R7, else
  rebase and apply.
- PRD-133 `backtest_priority` plus root cause "9 picks for cap 8".
- Loop R2 stitch: fix or close with reason.
- Paper closes: PRD-131 KILLED, PRD-134 CLOSED (engine logic moved to PRD-136 stub), PRD-135
  CLOSED.

## Gates, mandatory, before 06:00 Dubai

G1. `check_ambiguous_function_overloads()` = 0.
G2. Parity: every prod migration is on main.
G3. App smoke test on the deployed app, test machine, test warehouse and driver users: pack
(including over-stock qty shows the error), pickup (including a line packed after pickup), fill,
brought back, remove with 2 variants, could-not-remove (no stock moves), ad hoc M2M, WH confirm
plus split by variant. Any failure rolls back that night's migrations.
G4. Typecheck, build, push main, Vercel green.

## Report

`docs/loops/2026-09-29-prd137/REPORT.md`: Phase 0 table (item, before, after, RPC), F1 to F8
status with test evidence, Phase 2 PRD statuses, gate results, anything left for CS. Then stop.
