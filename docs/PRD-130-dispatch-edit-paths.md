# PRD-130: Post-push dispatch edits that survive packing, the field app and M2M pairing

Status: draft for Claude Code
Owner: CS
Date: 2026-09-21
Depends on: PRD-125 (add_dispatch_row v3), PRD-070 (pair_internal_transfer_m2m), PRD-053 (driver additions), PRD-129R (remainder credit)
Window rule: migrations touching field-app or warehouse-confirmation functions run outside 06:00 to 22:00 Dubai.

## 1. Problem

Every refill day since the engine went live, CS edits the plan after push: swaps the team asks for in the morning, machine-to-machine moves, popcorn lanes with no stock. Those edits go through `add_dispatch_row`, and rows born there do not behave like rows born from `push_plan_to_dispatch`. On 21 Sep this produced five manual fixes, including two direct UPDATE passes with no RPC (09:00 and 14:12) to force `dispatched=true, packed=true, pack_outcome='no_pack_needed'` on four M2M legs so the field app would save.

Evidence, 21 Sep (Dubai time), all from `refill_dispatching_edit_log` and `write_audit_log`:

| Time | What happened | Root cause |
|---|---|---|
| 08:00 to 08:03 | 18 rows added via `add_dispatch_row` (ADDMIND, USH, NOOK, ALJLT, JET, AMZ-1029, AMZ-1038) | Expected, but every row lands `dispatched=false, packed=false` |
| 08:01 | 4 M2M "Add New" legs with `source_kind='m2m'` | `is_m2m=true` set, `m2m_transfer_id` NULL, no partner link, no `source_origin` |
| 08:58 | 4 legs zeroed via `edit_dispatch_qty` | Field app refused to save (orphan M2M) |
| 09:00 | 4 direct UPDATEs: `source_kind='unknown', is_m2m=false`, qty restored | `convert_removes_to_m2m_transfer` rejected the Remove legs (`source_consistency_chk`, source_warehouse_id set), packed guard blocked the edit path |
| 14:12 | 8 direct UPDATEs: `dispatched=true, packed=true, pack_outcome='no_pack_needed'` | Field app only lists rows with `dispatched=true`; packing screen only lists `packed=false` rows that have a warehouse source |
| 14:19, 14:24 | Driver variant split on AMZ-1038 A11 Krambals created 2 new "Refill" rows `source_kind='wh'`, unpacked | Split path inserts fresh rows instead of splitting the parent quantity |
| 21:32 | Those 2 rows skipped by CS | Would otherwise have been packed a second time |
| 08:14 | IRIS A16 popcorn swap added post-push | Same unpacked-row path as above; worked only because it was warehouse sourced and the packer caught it |
| all day | Remove legs of the 3 hand-carried transfers (ADDMIND, USH, ALJLT) receipted as warehouse returns | ~14 phantom units in WH_CENTRAL |
| 11:45 | 1 direct INSERT into `pod_inventory_edits` by a `field_staff` actor, no RPC | RLS allows table insert from the app |

Plus the case from 22 Sep planning: a product moved between two lanes of the same machine (AMZ-1046 G&H A11 to A15) has no representation at all. It had to be modelled as skip the return legs, under-pack the Add New, and fix `pod_inventory` by hand after delivery.

## 2. Root causes

R1. `add_dispatch_row` inserts rows with `dispatched=false`. The push writer sets `dispatched=true` on every row it creates. The field app filters on `dispatched=true`, so post-push rows are invisible to the driver until someone flips the flag.

R2. `add_dispatch_row(source_kind='m2m')` sets `is_m2m=true` but never creates or links a transfer: `m2m_transfer_id` and `m2m_partner_id` stay NULL, `source_origin` stays NULL. The field app's M2M save path requires `m2m_transfer_id`. `pair_internal_transfer_m2m` cannot repair it because it only pairs rows with `source_origin='internal_transfer'`.

R3. Rows created by `add_dispatch_row` with `p_action='Remove'` are always warehouse-return rows (`source_kind` defaults to the caller's value, usually `'wh'`, and `source_warehouse_id` is set). When the physical intent is a transfer, `convert_removes_to_m2m_transfer` refuses them (`source_consistency_chk`) and `receive_dispatch_line` credits them into the warehouse.

R4. The packing screen and `pack_dispatch_line` have no notion of "nothing to pack". An M2M or intra-machine leg has to be marked `packed=true` by hand or it blocks the machine's dispatch from being confirmed.

R5. Driver variant split (`wm_confirm_line_split` / driver split in the app, PRD-053) inserts sibling rows with `packed=false, source_kind='wh'` instead of carrying the parent's packed and source state. Every split therefore re-enters the packing queue.

R6. No intra-machine move. Moving stock from lane A to lane B of the same machine has no action, so the system either double-packs (Remove to WH + Add New from WH) or drifts `pod_inventory`.

R7. `pod_inventory_edits` accepts direct inserts from `field_staff` (RLS), bypassing `propose_pod_inventory_edit` (or whatever the canonical RPC is; verify in code).

## 3. Fixes

### F1. `add_dispatch_row` v4: born ready
- Insert with `dispatched=true` for every action, matching `push_plan_to_dispatch`.
- Set `source_origin`: `'warehouse'` for `wh`, `'internal_transfer'` for `m2m` and `truck_transfer`, `'unknown'` otherwise.
- `p_source_kind='wh'` and action in (Refill, Add New): bind FEFO immediately via the same helper `push_plan_to_dispatch` uses (`bind_dispatch_fefo` or its per-row variant). If nothing binds, insert with `bind_fail_reason='no_stock'` so the packer sees it, do not raise.
- New optional argument `p_partner_dispatch_id uuid`. When given with `source_kind='m2m'`, link the new row and the partner: shared `m2m_transfer_id` (new uuid), reciprocal `m2m_partner_id`, `is_m2m=true` on both, partner's `source_kind` flipped to `'m2m'`, `source_warehouse_id` and `from_warehouse_id` cleared on the partner. The partner must be an unpacked, unreceived Remove on the source machine with the same `pod_product_id`; otherwise raise with the reason.
- When `source_kind='m2m'` and no partner is given: raise. An unpaired M2M leg is exactly the row that broke 21 Sep. The caller (me) creates the Remove first, then the Add New with the partner id.
- Return the transfer id and both dispatch ids.

### F2. `add_m2m_transfer(p_source_machine_id, p_source_shelf_code, p_dest_machine_id, p_dest_shelf_code, p_boonz_product_id, p_quantity, p_dispatch_date, p_reason)`
One call that does R2 and R3 correctly: creates the Remove on the source (lot from `v_pod_inventory_latest` on that shelf, `source_kind='m2m'`, no warehouse), creates the Add New on the destination, links them per F1, marks both `packed=true, pack_outcome='no_pack_needed'` (see F3), `dispatched=true`. Runs the WEIMI slot guard on the destination shelf the same way `approve_refill_plan` does (block mode), so a transfer cannot land on a lane still holding another product without a Remove. This is the RPC the conductor uses for every "take X from machine A to machine B" instruction.

### F3. Packing semantics for legs with nothing to pack
- New allowed `pack_outcome` value `'no_pack_needed'` set by the system, never by the packer, on: M2M and truck_transfer legs, intra-machine legs (F5), and Remove / Machine To Warehouse rows. `packed=true` is set at creation for those rows. `protect_packed_dispatch_row` must exempt rows with `pack_outcome='no_pack_needed'` from the packed lock for the specific columns quantity, expiry_date, skipped and cancelled, because nothing physical has been staged for them yet.
- `receive_dispatch_line` on an M2M Remove leg must not credit any warehouse (it currently only skips credit when `from_warehouse_id` is NULL, verify and make it explicit on `source_kind IN ('m2m','truck_transfer','intra_machine')`). The Remove leg's `driver_confirmed_qty` becomes the transfer quantity on the paired Add New, same rule as `correct_packed_m2m_transfer`.

### F4. Driver variant split carries parent state
In the split path (`wm_confirm_line_split` and the app's driver split, PRD-053): child rows inherit `packed, pack_outcome, dispatched, source_kind, source_origin, source_warehouse_id, from_warehouse_id, is_m2m, m2m_transfer_id` from the parent, and the parent's quantity is reduced by the sum of the children (this is what `conserve_split_dispatch_quantity` is meant to guarantee; make the trigger enforce it for both paths). A split never creates a row with `packed=false` when its parent is packed. Guard: `G-SPLIT`: any dispatch_date with a child row (`created_by_edit=true`, same machine, shelf, pod_product, dispatch_date as a packed parent) that is `packed=false` and `source_kind='wh'` fails the nightly integrity job (jobid 82 already exists, add the check there).

### F5. Intra-machine move
- New `source_kind` value `'intra_machine'` and new RPC `add_intra_machine_move(p_machine_id, p_from_shelf_code, p_to_shelf_code, p_boonz_product_id, p_quantity, p_dispatch_date, p_reason)`.
- Creates a Remove on the from-shelf and an Add New on the to-shelf, both `source_kind='intra_machine'`, linked with the same `m2m_transfer_id` mechanics (source_machine_id = machine_id), `packed=true, pack_outcome='no_pack_needed', dispatched=true`, no warehouse fields.
- `source_consistency_chk` extended to allow `intra_machine` with `source_machine_id = machine_id` and no warehouse.
- On receipt: the Remove leg moves the pod lot from the from-shelf to the to-shelf (update `pod_inventory.shelf_id` on the lot, or archive and reinsert if the app's lot model needs it), no warehouse credit. The Add New leg's `item_added=true` is what triggers it. WEIMI slot guard runs on the to-shelf.
- Field app shows both legs under the machine with the label "Move A11 to A15" so the driver sees one instruction.

### F6. `pair_internal_transfer_m2m` widens
Pair rows with `source_kind='m2m'` as well as `source_origin='internal_transfer'`, and set `source_origin='internal_transfer'` on both legs when it pairs. Backfill: run once for the 21 Sep rows so the 4 forced legs and their 4 Remove legs get a real transfer id (the receipts are done, the pairing is for history and for the phantom cleanup in F8).

### F7. Lock `pod_inventory_edits` to the RPC
RLS: revoke INSERT/UPDATE for `field_staff` and `authenticated` on `pod_inventory_edits`; the app calls the propose RPC. Verify what the 11:45 row was and whether the app still has a direct insert path.

### F8. Phantom cleanup for 21 Sep
The 3 hand-carried transfers (ADDMIND A06 Krambals 5, ADDMIND A07 Hummus 5, USH A14 Hummus 6, ALJLT A02 Dates 5) were receipted as warehouse returns. Produce a dry-run list of the `warehouse_inventory` lots credited by those 4 Remove legs (via `inventory_audit_log.source_event_id`), then reverse them with `adjust_warehouse_stock` under reason "PRD-130 F8 transfer receipted as return, 2026-09-21". Add these to the recount pack so the warehouse count confirms.

## 4. Guards (nightly, jobid 82)
- G-DISP-INVISIBLE: rows for today or tomorrow with `dispatched=false` and `created_by_edit=true`. Expect 0.
- G-M2M-ORPHAN: `is_m2m=true` or `source_kind IN ('m2m','truck_transfer','intra_machine')` with `m2m_transfer_id IS NULL`. Expect 0.
- G-SPLIT: per F4.
- G-RETURN-CREDIT: `inventory_audit_log` rows whose `source_event_id` points at a dispatch with `source_kind IN ('m2m','truck_transfer','intra_machine')`. Expect 0.

## 5. Acceptance
1. Add a warehouse-sourced Add New after push: appears in the packing queue bound FEFO, appears in the field app without any manual flag.
2. `add_m2m_transfer` ADDMIND A06 to AMZ-1038 A11, Krambals 5: two rows, one transfer id, both visible in the app, neither in the packing queue, the app saves both, the receipt moves the lot and credits no warehouse.
3. Driver splits a packed Krambals 5 into 2+2+1: three rows, all packed, parent reduced, nothing new in the packing queue.
4. `add_intra_machine_move` AMZ-1046 A11 to A15 G&H 4: after receipt, `pod_inventory` shows the 4 on A15, A11 empty, WH_CENTRAL unchanged.
5. All four guards return 0 on the 22 Sep plan after the migration and on the backfilled 21 Sep data.
6. Direct insert into `pod_inventory_edits` as `field_staff` fails.

## 6. Out of scope
- Engine path M2M (pod_refill_plan has no transfer action). Stays DICTATED / conductor for now.
- `align_pod_lots_to_weimi` NULL-expiry duplicate lots (separate ticket, it caused the V6 stitch failures on 21 and 22 Sep).

---

## Claude Code prompt

You are working in the boonz-erp repo against Supabase project eizcexopcuoycuosittm. Read docs/PRD-130-dispatch-edit-paths.md first (copy this file there). Then:

1. Read the current definitions of `add_dispatch_row`, `convert_removes_to_m2m_transfer`, `pair_internal_transfer_m2m`, `push_plan_to_dispatch` (the part that sets dispatched and binds FEFO), `pack_dispatch_line`, `receive_dispatch_line`, `protect_packed_dispatch_row`, `conserve_split_dispatch_quantity`, `wm_confirm_line_split`, the `source_consistency_chk` constraint and the field app query that lists a driver's dispatch rows. Confirm each root cause R1 to R7 against the code and write what you find at the top of the migration as comments. If a root cause does not hold, say so and stop for that item, do not invent a fix.
2. Write migrations, one per fix, named `prd130_01_add_dispatch_row_v4`, `prd130_02_add_m2m_transfer`, `prd130_03_no_pack_needed`, `prd130_04_split_inherits_parent`, `prd130_05_intra_machine_move`, `prd130_06_pair_widen_and_backfill`, `prd130_07_pod_inventory_edits_rls`, `prd130_08_guards_jobid82`. Each one is idempotent, carries a rollback capture in `supabase/rollback/` (never in `supabase/migrations/`), and keeps existing function signatures working (add arguments with defaults, never remove).
3. F8 is a dry-run script only (`scripts/prd130_f8_phantom_dryrun.sql`) that prints the lots and quantities. Do not apply the reversal; CS runs it after the warehouse count.
4. Field app: change the driver list query to rely on `dispatched=true` only (already the case, verify) and render `pack_outcome='no_pack_needed'` rows without the pack step. Add the "Move A to B" label for `intra_machine` pairs. Keep the change surgical.
5. Do not run any migration that touches `receive_dispatch_line`, `pack_dispatch_line`, `protect_packed_dispatch_row` or the field app between 06:00 and 22:00 Dubai. Schedule those for after 22:00 and say so in the report.
6. Test in this order on a branch database if available, else on prod after 22:00 Dubai with a plan_date of 2026-09-30 and cancel the rows afterwards: acceptance 1 to 6 from section 5. Report each with the SQL you ran and the result.
7. Run the four guards against 2026-09-21 and 2026-09-22 and report counts before and after.
8. Commit on branch `prd130-dispatch-edit-paths`, push, and give me the compare URL. Do not merge. No em dashes anywhere in code comments, commit messages or docs.

Report format: one table per fix (root cause confirmed yes/no, migration name, applied at, test result), then the guard counts, then anything you changed that the PRD did not ask for.
