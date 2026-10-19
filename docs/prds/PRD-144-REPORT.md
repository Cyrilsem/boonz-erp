# PRD-144 report (P0 and P1, plus the P2-3 audit)

Date: 2026-10-19 (Dubai). Supabase eizcexopcuoycuosittm. One branch per item, each cut from main at 5f9a42c.
No live data was edited: every test ran inside a transaction that ends in RAISE, and the browser tests block or mock every write.

## Summary

| Item | Branch (PR) | Migration applied to prod | Tests added | Result |
| --- | --- | --- | --- | --- |
| P0-1 pack screen multi-lot save | `prd144/p0-1-pack-multilot` | none (FE only) | `scripts/prd144-pack-multilot.test.mjs` (5 unit tests), `scripts/prd144-pack-multilot.e2e.mjs` (Playwright) | DONE. RED on main (no request sent), GREEN on branch (picks [3, 6]). Root cause: PRD-141 item 8 turned the per-lot `continue` into `return false`. |
| P0-2 add_dispatch_row M2M stamping | `prd144/p0-2-m2m-stamp` | `20261019062503_prd144_p0_2_add_dispatch_row_m2m_stamp` | `supabase/tests/prd144_p0_2_add_dispatch_row_m2m.sql` | DONE. FAIL before, PASS after. No backfill. |
| P0-3 auto-remove legs from WEIMI | `prd144/p0-3-weimi-remove` | `20261019063621_prd144_p0_3_auto_remove_from_weimi` | `supabase/tests/prd144_p0_3_auto_remove_from_weimi.sql` | DONE. SAP B07: before, Remove LevelUp Yubi x4; after, Remove Smart Gourmet Truffle Hummus x4. Empty lane: no leg, "lane empty per WEIMI". |
| P0-4 warehouse stock confirm error | `prd144/p0-4-wh-confirm` | none (FE only) | `scripts/prd144-wh-metadata-payload.test.mjs`, `supabase/tests/prd144_p0_4_adjust_warehouse_stock_payload.sql` | DONE. Error reproduced: "null value in column snapshot_date violates not-null constraint". |
| P1-1 pending / incomplete machines | `prd144/p1-1-pending-machines` | `20261019064628_prd144_p1_1_incomplete_machines_and_prepicks` | `supabase/tests/prd144_p1_1_incomplete_machines.sql` | DONE. 20 machine-days, 104 open lines listed today. |
| P1-2 amend_dispatch_after_pickup | `prd144/p1-2-amend-after-pickup` | `20261019065534_prd144_p1_2_amend_dispatch_after_pickup` | `supabase/tests/prd144_p1_2_amend_dispatch_after_pickup.sql` | DONE (backend; no FE asked). |
| P1-3 expiry editing in dispatch | `prd144/p1-3-expiry-editing` | `20261019070003_prd144_p1_3_split_pod_lot_and_sold_since_planning` | `supabase/tests/prd144_p1_3_split_pod_lot_and_sold.sql` | DONE. Remove per-expiry rows and "+ Add expiry" were ALREADY DONE (PRD-141 item 3). |
| P1-4 Removed by operator label | `prd144/p1-4-removed-label` | none (FE only) | local browser smoke | DONE. |
| P2-1 reintroduction intents | none | none | none | NOT STARTED (brief said P0 then P1). |
| P2-2 M2M builder from WEIMI | none | none | none | NOT STARTED (brief said P0 then P1). |
| P2-3 source tag audit | this report | none | read-only queries | LIST BELOW, nothing changed. |

Every new or replaced SECURITY DEFINER function ends with REVOKE from public, anon and GRANT to authenticated (service_role kept where it was). Role checks use auth.uid() and user_profiles.role. After the last migration: 0 anon-executable definer functions; the only overload in public is the pre-existing `engine_finalize_pod(date)` / `engine_finalize_pod(date, uuid[])` pair (the first is a wrapper, not added here). Each migration has a rollback in `supabase/rollbacks/prd144_*`.

## What each item changed

- P0-1: `packOneLine` skips a lot with 0 picked or a frozen slice instead of abandoning the line; the picks array is built by `packing/_lib/build-picks.ts`; any pack failure raises a red toast as well as the banner.
- P0-2: an M2M leg written by `add_dispatch_row`, and the Remove it pairs with, are `packed=true`, `pack_outcome='no_pack_needed'`, `dispatched=true`. `tg_enforce_pack_via_rpc` lists `add_dispatch_row` as a sanctioned writer for that partner flip.
- P0-3: new `weimi_lane_now(machine, shelf)` reads the latest `weimi_aisle_snapshots` row (A1 = A01). `ensure_swap_remove_leg` (used by `add_dispatch_row` Add New, push via `ensure_swap_remove_legs_for_machine`, and the FE Add Product flow) takes the lane's product and quantity only from it; pod_inventory only picks the lot for expiry. `engine_swap_pod` corrects `pod_swaps` out pod and qty from WEIMI (it used to floor an empty lane at 1); `engine_finalize_pod` writes no REMOVE/M2W for a WEIMI-empty swap and puts the warning on the ADD_NEW. `write_refill_plan` writes no auto-Remove itself (G7 is a `validate_refill_plan` check); its swaps get their Remove at push.
- P0-4: `adjustWarehouseLineMetadata` sent `p_snapshot_date = null` (fails the NOT NULL column) and no `new_consumer_stock` (the RPC sets it to 0). It now sends today's Dubai date and the row's current consumer stock; three screens show the server error text.
- P1-1: `get_incomplete_dispatch_machines(p_days)` and operator_admin-only `resolve_incomplete_dispatch(machine, date, complete|cancel, reason)`. Complete receives open Refill/Add New lines at the packed qty (planned if never packed) with override; Cancel returns them and receives Remove legs at 0. New Today | Pending tabs on /field/dispatching and a "Pending machines" Home card. `write_refill_plan` and `pick_machine_manually` first unpick the date's unconfirmed pre-picks that have no plan and no dispatch lines; `write_refill_plan` re-picks any machine it writes lines for.
- P1-2: `amend_dispatch_after_pickup(dispatch_id, new_shelf_code, new_qty, void, reason, actor)`, operator_admin only, for picked-up undelivered lines. Shelf: mapping checked against the shelf's WEIMI pod, then slot_lifecycle. Lower qty: the difference moves consumer_stock to warehouse_stock on the reservation `return_dispatch_line` would use. Void: `return_dispatch_line`, then include=false, qty 0. Logged in `refill_dispatching_edit_log` (there is no `refill_dispatching_audit` table). `protect_packed_dispatch_row` has one named exemption: this RPC may change shelf_id and pod_product_id on a packed line.
- P1-3: "Sold since planning" on Remove cards (`record_sold_since_planning`, logged as a sales_correction edit), "Expiry split" on Refill / Add New cards (existing total-locked dialog), "Split lot" on lot-bound Remove cards and in the pod inventory sheet (`split_pod_lot`, quantities must add up, a date that already has a lot merges into it).
- P1-4: "Skipped items" lists only skipped=true lines; operator-excluded and cancelled lines go to a collapsed "Removed by operator" group.

## Things that need CS

1. Merge order: P0-1 first. It fixes a regression that is live in production since 18 Oct (multi-lot lines can not be packed by tapping Packed; nothing is shown). The five migrations are already live; their files only reach main when the branches merge, so the repo/prod parity check shows them as prod-only until then. P0-1 and P1-4 both touch the pack screen in different places; P1-1 and P1-3 both touch dispatching in different files. All merge cleanly onto 5f9a42c.
2. P1-1 behaviour change: the first manual pick or written plan for a date drops that date's picker pre-picks that have no plan yet (they become cs_dropped; `pick_machine_manually` brings any one back). In the rolled-back test, a plan for one machine on 20 Oct dropped the other 11 pre-picks.
3. P1-2: the new exemption in `protect_packed_dispatch_row` is a guard change. Review it; the rollback removes it.
4. P1-1 backlog: 20 machine-days with open lines in the last 14 days (HUAWEI 18 Oct has 5 Remove legs, JET-1016 10 Oct 17 Refill lines picked up but never received). Resolve them from the new Pending tab; nothing was resolved here.

## P2-3 audit (read-only, nothing changed)

Active `venue_team` mappings whose boonz product has real Active stock in WH_CENTRAL (2099-12-31 placeholders excluded):

| Product | WH_CENTRAL stock | Active venue_team mappings | Machines |
| --- | --- | --- | --- |
| 7Up - Regular | 51 | 30 | 12 |
| Pepsi - Black | 45 | 9 | 8 |
| 7Up - Diet | 37 | 31 | 12 |
| Red Bull - Diet | 24 | 12 | 12 |
| Snickers - Regular | 12 | 11 | 11 |
| Red Bull - Regular | 5 | 12 | 12 |

Ice Tea - Peach is not on the list: its 7 Active venue_team mappings sit next to 0 units in WH_CENTRAL; its only stock is the 2099 placeholders in WH_MM (972) and WH_MCC (904).

Verification asked for: "receive_dispatch_line and pack_dispatch_line only touch WH stock when source_kind='wh'". FAIL. Neither function reads source_kind. `pack_dispatch_line` routes on `source_origin = 'vox_at_venue'` and then debits the 2099 venue placeholder row; `receive_dispatch_line` moves warehouse stock with no source check. Flipping these mappings to Boonz is therefore not safe yet: the dispatch line's source would not decide which stock moves. Recommended order: make both RPCs branch on source_kind first, then run the flip.

Also found: WH_DFC holds 35 Active "placeholder" rows of 999 units dated 2029-09-27, not the 2099-12-31 sentinel. Anything that excludes placeholders by the sentinel date counts them as real stock (they appear in the raw audit above as 999 units of 7Up, Red Bull, Snickers and others).

SQL for CS to approve, only after the source_kind change above (not run):

```sql
-- PRD-144 P2-3: move the six products' venue_team mappings to Boonz supply.
UPDATE public.product_mapping
   SET source_of_supply = 'boonz'
 WHERE source_of_supply = 'venue_team'
   AND status = 'Active'
   AND boonz_product_id IN (
     SELECT product_id FROM public.boonz_products
      WHERE boonz_product_name IN ('7Up - Regular', 'Pepsi - Black', '7Up - Diet',
                                   'Red Bull - Diet', 'Snickers - Regular', 'Red Bull - Regular'));
-- expected: 105 rows (30 + 9 + 31 + 12 + 11 + 12)
```

No other item needs a prod data backfill. P0-2 asked for none: the 12 M2M legs written through add_dispatch_row before today keep packed=false.
