# PRD-145: refill pack and edit integrity (P3-2 to P3-7)

Source: the 20 Oct 2026 refill forensic. Verified on prod 20 Oct 2026. Constitution articles in every PR: 1, 4, 5, 8, 12.

## Context

- No packed quantity was lost. `pack_dispatch_line` (PRD-144 P0-1) splits one plan line into one `refill_dispatching` row per warehouse lot. The edit dialog shows one lot row, so the team reads "6 became 5" and "2 became 1". AMZ-1038 A12 Mountain Dew = rows 65681a9c (2) + 25bf2e46 (1) for a plan of 3.
- Edit dialog "Maximum available" = the lot's remaining `warehouse_stock` only; it ignores the units already packed on the line being edited (Coke Regular: 6 packed from an 11 lot, dialog said max 5).
- Ghost lots: `push_plan_to_dispatch` pins FEFO to `warehouse_inventory` rows of 1 to 3 units that are not physically there; 37 lines over 19 and 20 Oct. The operator repinned them by hand on 20 Oct and deducted 81 units from the real lots. A warehouse edit after push does not move the pin.
- `refill_dispatching` ea944182 (AMZ-1029 A14 Popcorn Salted) ended at pack_outcome partial, filled_quantity 0, item_added true, picked_up true. `driver_report_dispatch_outcome` refuses picked_up rows; `amend_dispatch_after_pickup` refuses item_added rows. The team had no exit; the operator closed it by hand.
  - Correction from `write_audit_log`: the row was packed with 1 unit at 04:24 (from a ghost lot). The partial / filled 0 / item_added state came from `receive_dispatch_line` called with 0 at 08:51. c8393638 (ADDMIND A12, 12 Oct) took the same path (packed 3, received 0). `pack_dispatch_line` with 0 picks already wrote not_filled and never item_added.
- `add_dispatch_row` flagged two wh Remove rows (NOOK A12 Popit, 0bd0ae62 and a6e3a29f) is_internal_move=true because the only pairing match on the machine was an intra_machine leg.
- `pod_inventory` carried 423 rows of products never mapped to the lane's WEIMI pod; cleared by hand on 20 Oct on 36 machines. The 7 machines refilled on 20 Oct (ALJLT-1015-0200-O1, AMZ-1029-3003-O1, AMZ-1038-3001-O1, BEBEACH-1069-0000-W0, IRIS-1070-0000-O1, NOOK-1019-0200-B1, USH-1008-0000-W1) still need the pass once a WEIMI snapshot dated after the refill exists.

## Rules for every item

One PR per item, in the order below, each with tests, each declaring Constitution articles (1, 4, 5, 8, 12) in the PR body. Forward-only migrations. No direct table writes from the FE; RPC changes only. Deploy gate for every PR: every machine with lines on the current dispatch_date has a final row in `dispatch_pack_confirmation`; otherwise push the branch and wait. Do not merge without a go from CS.

## P3-5 Zero-unit pack is not a delivery (migration + FE)

a. `pack_dispatch_line`: when total picks = 0, set pack_outcome='not_filled', filled_quantity=0, item_added=false, picked_up unchanged. Never set item_added when filled_quantity=0.
   - Held: the brief also asks for packed=true. A not_filled line is packed=false everywhere (PRD-030), and `mark_picked_up` marks every packed=true row of the machine-day picked_up, so packed=true would put the 0-unit line on the driver page. Needs a CS call.
   - Added (root cause): `receive_dispatch_line` on a fill line with 0 units sets pack_outcome='not_filled', item_added=false, not_filled_reason 'driver delivered 0', and refuses a second receive of that row (its packed units were credited back on the first).
b. Driver page and warehouse returns queue exclude pack_outcome='not_filled' rows.
c. `driver_report_dispatch_outcome`: allow 'not_done' and 'no_stock_on_truck' when filled_quantity=0 even if picked_up=true.
d. `amend_dispatch_after_pickup`: allow p_void when filled_quantity=0 regardless of item_added; a void of a 0-filled row credits nothing to the warehouse.
e. One-time sweep: rows since 2026-10-01 with pack_outcome='partial', filled_quantity=0, driver_outcome null, delivered_at null -> pack_outcome='not_filled', include=false, not_filled_reason='sweep PRD-145'. List the rows in the PR body.

Tests: scripts/prd145-pack-zero.test.mjs (pack 0 => not_filled and item_added=false; driver not_done accepted on picked_up 0-filled row; amend void accepted; driver query excludes the row).

## P3-3 Max available on edit (FE only)

max = lot.warehouse_stock remaining + units already packed on this line from this lot (and across the line's lot rows in the grouped view from P3-2). Test: scripts/prd145-max-available.test.mjs, Coke Regular 6 packed from an 11 lot => max 11.

## P3-2 Edit view by line, not by lot (FE + one RPC)

a. Dispatch edit dialog (operator and warehouse) groups refill_dispatching rows by (machine_id, shelf_id, boonz_product_id, action, source_kind, coalesce(parent_dispatch_id, dispatch_id)) and shows the line total with lot rows (expiry, qty) as detail underneath.
b. Amend quantity acts on the total. New RPC amend_dispatch_line_total(p_group jsonb, p_new_total numeric, p_reason text): lowers from the newest-expiry lot first, raises on the FEFO live lot; writes refill_dispatching_edit_log with a coherent before/after (the state_coherence check constraint applies); credits or debits warehouse_inventory per lot through the same path pack_dispatch_line uses. Operator_admin and warehouse roles. Sets app.via_rpc and app.rpc_name.
c. Extend scripts/prd144-lane-cards.test.mjs with the 20 Oct snapshot: AMZ-1038 A12 Mountain Dew shows total 3 with lots 2 (2027-07-04) and 1 (2027-06-10); lowering to 2 removes the 2027-06-10 unit.

## P3-6 add_dispatch_row guard (migration)

A Remove with source_kind='wh' is never flagged is_internal_move when the matching Add leg on the machine is source_kind='intra_machine'. Test on the NOOK A12 20 Oct shape.

## P3-7 Orphan pod rows and pod resync (migration + Pending tab)

a. New RPC get_pod_orphan_rows(p_machine_id uuid default null): pod_inventory Active rows with current_stock>0 whose boonz_product has no product_mapping row (any status, any scope) to the pod product on that lane in the latest weimi_aisle_snapshots (resolve WEIMI product_name through product_name_conventions.original_name -> official_name; zero-pad slot codes A1 -> A01), plus rows on shelves absent from the snapshot.
b. New RPC clear_pod_orphan_rows(p_machine_id uuid, p_reason text): calls adjust_pod_inventory with new_qty 0 for those rows; refuses when the machine's latest snapshot is not newer than its last packed dispatch_date (so a refill is never reverted).
c. Pending tab section "Pod rows off WEIMI" listing counts per machine with a Clear button (operator_admin), and a nightly cron that runs get_pod_orphan_rows and writes the count to the Pending tab, never clears automatically.
d. Run clear_pod_orphan_rows for the 7 machines of 20 Oct once their snapshot is newer than 2026-10-20 pack time, and report the counts.

## P3-4 Lot truth at pack (migration + FE), largest, last

a. pack_dispatch_line records the lot(s) actually picked; the row's expiry_date and from_wh_inventory_id follow the pick. Pack screen preselects the pinned lot; one tap switches to any live lot of the same product in the same warehouse.
b. adjust_warehouse_stock and the warehouse confirm path: when a lot with unpacked pinned rows goes to 0 or changes expiry, re-pin those rows to the FEFO live lot and log it (refill_dispatching_edit_log edit_kind that passes the check constraint; if none fits, add one in the same migration).
c. New RPC get_ghost_lot_candidates(): warehouse_inventory Active lots with warehouse_stock between 1 and 3 where another Active lot of the same product in the same warehouse has at least 5x the stock. Pending tab section "Lots to count" with a Zero button (warehouse manager role only, Article 6: do not touch warehouse_inventory.status).
d. Gate 1 data: get_plan_pin_preview(p_plan_date date) returning, per planned warehouse line, the lot(s) the push would pin with expiry and remaining units, and a flag tail_lot when the lot has under 4 units and a bigger live lot exists. Read-only.

Tests: scripts/prd145-lot-truth.test.mjs (pack from a non-pinned lot moves the row's expiry and lot; warehouse edit re-pins unpacked rows; ghost candidates list contains a seeded 2-unit lot next to a 40-unit lot; pin preview flags it).

## Reporting after each PR

PR URL, test pass counts, migration names, the deploy gate query result, and for P3-2 and P3-5 a before and after screenshot of AMZ-1038 A12 and AMZ-1029 A14 on 2026-10-20.

## Shipped (2026-10-20, Dubai)

CS go on 2026-10-20. Merged to main in the ordered sequence, each rebased on the previous production deploy, tests re-run after the rebase, the deploy gate checked before every apply and push (all 7 machines of 2026-10-20 had a final dispatch_pack_confirmation row each time; no 2026-10-21 lines existed).

| Step | Item | Commits on main | Migration applied (registry version) | Tests after rebase |
|---|---|---|---|---|
| 1 | PRD-144 P3-1 lane cards | 584b62d, e9827cb, 8a51feb | none | node 10/10 lane cards, 5/5 multilot, 3/3 wh metadata |
| 2 | P3-5 zero-unit line | fb4dda9 (this spec), 764a956 | prd145_p3_5_zero_pack_not_delivery (20261020163107) | SQL 8/8, node 7/7 |
| 3 | P3-6 internal-move guard | e189c9d | prd145_p3_6_wh_remove_not_internal_move (20261020163402) | SQL 4/4 |
| 4 | P3-3 edit max, P3-2 edit by line | 565310b, ecc3c4e, f2912ac | prd145_p3_2_amend_dispatch_line_total (20261020163711) | SQL 6/6, node 5/5 + 10/10 |
| 5 | P3-7 orphan pod rows | b27b6ca, 7b18807 | prd145_p3_7_pod_orphan_rows (20261020164002), cron prd145_pod_orphan_rows_0400_dubai | SQL 5/5 |
| 6 | P3-4 lot truth | 8bcd720, a61a665 | prd145_p3_4_lot_truth (20261020164455) | SQL 5/5, node 5/5 |

SQL tests ran against live data in a transaction that ended in ROLLBACK. Production builds (next build --webpack) passed for every FE combination before its push; tsc clean. P3-4 merged last; the dispatching page import conflict was resolved with PodOrphanRowsPanel first, LotsToCountPanel second. Repo migration files keep their 2026102016xxxx..20xxxx names; the registry versions above are the apply times.

P3-5 sweep: closed one row, c8393638 (ADDMIND-1007-0000-W0, 12 Oct), partial with filled 0 -> not_filled.

P3-7 clear (clear_pod_orphan_rows, operator_admin, through adjust_pod_inventory), then resync_pod_inventory_from_weimi commit mode (run drift-resync-20261020T204346):

| Machine | Orphan rows cleared | Units cleared | Resync shelves | Written off | Added unattributed |
|---|---|---|---|---|---|
| ALJLT-1015-0200-O1 | 6 | 23 | 4 | 0 | 20 |
| AMZ-1029-3003-O1 | 90 | 545 | 3 | 3 | 25 |
| AMZ-1038-3001-O1 | 50 | 329 | 0 | 0 | 0 |
| BEBEACH-1069-0000-W0 | 15 | 66 | 7 | 7 | 41 |
| IRIS-1070-0000-O1 | 7 | 12 | 2 | 0 | 2 |
| NOOK-1019-0200-B1 | 5 | 23 | 2 | 0 | 14 |
| USH-1008-0000-W1 | 20 | 63 | 0 | 0 | 0 |
| Total | 193 | 1061 | 18 | 10 | 102 |

NOOK A06 rows were the old Plaay Tablets - Dark Chocolate (CS). BEBEACH and USH each have one shelf with no WEIMI slot identity, skipped by the resync. After the clear, get_pod_orphan_rows returns 0 rows on the 7 machines and the Pending tab reads "Every pod row matches WEIMI".

Post-deploy checks on production (2026-10-20):
- AMZ-1029 A14: the driver page shows Dubai Popcorn - Butter x3 only; Popcorn Salted (ea944182) is not_filled, filled 0, include false.
- AMZ-1038 A12 Mountain Dew: one line, total 3, rows 25bf2e46 (1) + child 65681a9c (2), both 2027-07-04. Both rows are delivered (item_added), so the packing page is read-only and the edit dialog does not open; a post-delivery change goes through amend_dispatch_after_pickup.
- Lots to count: 24 lots, 16 products, 32 units, 2 with a pinned unpacked line.
- get_plan_pin_preview('2026-10-21'): 0 rows (no plan yet).
