# PRD-131: One movement kind per dispatch leg, and what each screen may show

Status: draft for Claude Code
Owner: CS
Date: 2026-09-22
Depends on: PRD-130 (01, 02, 05 applied; 03, 04, 06, 07, 08 pending)
Window rule: migrations touching field-app or warehouse-confirmation functions run outside 06:00 to 22:00 Dubai.

## Found while implementing

Three real bugs found and fixed while drafting F1 and F2, none asked for by this PRD:

1. `refill_dispatching_source_kind_chk` (fully validated, enforced on every row) did not allow `intra_machine`, only `wh, venue, m2m, truck_transfer, unknown`. `add_intra_machine_move` (PRD-130 F5, applied 2026-09-22 morning) has therefore never been able to insert a row successfully since it shipped. Confirmed with a rolled-back probe insert before and after. Fixed same day, daytime, in prd130_11 (purely additive, no historical-row risk).
2. `refill_dispatching` carries four pre-existing NOT VALID CHECK constraints (`chk_dispatch_qty_nonnegative`, `chk_packed_requires_outcome`, `m2m_consistency`, `refill_dispatching_source_consistency_chk`). NOT VALID only skips the one-time bulk scan at creation, it does not exempt existing non-compliant rows from being re-validated on every future UPDATE. The F1 backfill UPDATE (a blanket UPDATE across all 42,054 rows) aborted on the first of 2,272 negative-quantity rows it touched. Fixed by dropping all four inside the F1 migration, running the classification UPDATE untouched by their semantics, then restoring all four verbatim (same definition, still NOT VALID) so the exact same protective posture exists after the migration as before it.
3. In the F2 draft itself, found during the required second-pass proof of `push_plan_to_dispatch`: the Remove-leg insert still set `from_warehouse_id` and never set `return_warehouse_id`, so the very rule this PRD exists to enforce (return_warehouse_id set, from_warehouse_id NULL, on every warehouse_return row) failed its own first real test. A related near-miss caught in the same pass: nulling `from_warehouse_id` on the Remove leg without checking `source_warehouse_id` separately broke `refill_dispatching_source_consistency_chk`, which requires `source_kind='wh'` to carry a non-null `source_warehouse_id` regardless of `from_warehouse_id`/`return_warehouse_id`. Fixed in `push_plan_to_dispatch`, `add_dispatch_row`, and `insert_driver_remove_line`; re-verified twice more, once with a minimal faithful reproduction of the Remove/Refill insert paths and once with the full real `push_plan_to_dispatch` body itself (a rolled-back transaction against WAVEMAKER, plan_date 2031-02-02), both green: every Refill/Add New warehouse_fill with from_warehouse_id set, every Remove warehouse_return with return_warehouse_id set and from_warehouse_id NULL.
4. While scoping F3: `pack_dispatch_line` already safely no-ops on any non-Refill/Add New action, and `tg_default_pack_outcome_driver_legs` (an existing trigger) already auto-sets `pack_outcome='no_pack_needed'` on any Remove/Machine To Warehouse row regardless of its `packed` flag. Neither needed a change. The one real gap: `push_plan_to_dispatch` was the only writer left creating a warehouse_return leg with `packed=false` (every other writer already used `packed=true` for its non-fill legs). That is the literal packing-screen bug (a return sitting in the pick list until someone packed or ignored it). Fixed in `prd131_03` by changing that one INSERT's `packed` value to true; no FE change was needed for this half of F3, since the packing screen's existing `packed=false` filter already excludes it once this ships.

**Standing rule from this session, effective immediately:** every migration that creates or
replaces a function must end with one rolled-back smoke call of that function using realistic
arguments, and the migration is not considered done until that call is shown green. All three
bugs above (the overload ambiguity, the missing intra_machine constraint value, the NOT VALID
constraint revalidation) passed `apply_migration` cleanly and only broke on first real use. Add
this line to the top of every future migration template in this repo.

## 1. The rule

Every line in `refill_dispatching` is exactly one kind of physical movement, decided when the line is created, never inferred later from `action`, `from_warehouse_id` or button presses:

| movement_kind    | What it is                                                                                                        | Packing screen     | Field app                  | Warehouse receipt                                                |
| ---------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------ | -------------------------- | ---------------------------------------------------------------- |
| warehouse_fill   | units picked in a warehouse and put in a machine                                                                  | yes, pick and pack | Put in, confirm count      | no (unfilled remainder handled by the existing return flow)      |
| warehouse_return | units taken out of a machine and brought to a warehouse                                                           | no                 | Take out, confirm count    | yes, validated per flavour and expiry, credited only on approval |
| transfer_out     | units taken out of machine A for machine B                                                                        | no                 | Take out, confirm count    | never                                                            |
| transfer_in      | the same units put in machine B                                                                                   | no                 | Put in, confirm count      | never                                                            |
| intra_out        | units taken out of lane X for lane Y of the same machine                                                          | no                 | Move X to Y, confirm count | never                                                            |
| intra_in         | the same units put in lane Y                                                                                      | no                 | (same card as intra_out)   | never                                                            |
| write_off        | units taken out and destroyed on site (expired, damaged)                                                          | no                 | Take out, reason required  | no, logged to write-off report                                   |
| legacy_noop      | pre-2026-05-04 row that never moved stock (historical action values with no real movement); backfill-only, see F1 | no                 | no                         | no                                                               |

Stock effects, one place each:

- warehouse_fill: warehouse debited at pack (already), machine credited at item_added (already).
- warehouse_return: machine debited at driver confirm (pod lot), warehouse credited only at receipt approval, with the count the warehouse verified, never the driver's count.
- transfer_out / transfer_in: machine A debited at driver confirm, machine B credited at item_added, no warehouse touch, same lot id carried.
- intra_out / intra_in: lot moves lane on item_added, no warehouse touch.
- write_off: machine debited, nothing credited, row in write-off report.
- legacy_noop: no stock effect, ever. Excluded from every screen and every guard. The F2 insert trigger rejects it on any new row (check constraint allows the value to exist for backfilled history; nothing may be created with it going forward).

Nothing else. If a screen cannot tell what a line is from `movement_kind` alone, the screen is wrong.

## 2. Why (22 Sep, all in one day)

- Packing screen listed Red Bull returns as "pick 7" because returns carry `from_warehouse_id`.
- Field app labelled Machine To Warehouse lines as REFILL because it only maps `Remove`.
- Driver pressed "Returned" on those lines (the unfilled-goods button), so they left the receipt path entirely. Simran could not confirm 18 units physically sitting in the office.
- 21 Sep: transfer legs were receipted as warehouse returns, 14 phantom units.
- Every one of these is a screen guessing the movement from side columns.

## 3. Changes

### F1. Column and constraint

- `refill_dispatching.movement_kind text NOT NULL` with the eight values above, check constraint.
- `action` stays for compatibility but is derived: warehouse_fill and transfer_in and intra_in map to Refill or Add New; everything else maps to Remove. `Machine To Warehouse` is retired: the check constraint on `action` no longer accepts it.
- Backfill for all existing rows, matched case-insensitively throughout (`lower(action)`), in this order:
  1. `is_m2m` or `source_kind in ('m2m','truck_transfer')`, action Remove → transfer_out; action in (Refill, Add New, Add) → transfer_in.
  2. `source_kind='intra_machine'`, action Remove → intra_out; action in (Refill, Add New, Add) → intra_in.
  3. action in (Remove, Machine To Warehouse) → warehouse_return.
  4. action in (Refill, Add New, Add) → warehouse_fill (`'Add' = 'Add New' = warehouse_fill`, a pre-2026-05-04 naming convention, always `source_kind='wh'` — confirmed on all 18,064 rows).
  5. action in (Move, Transfer): `source_machine_id is not null or from_machine_id is not null` → transfer_out when `from_wh_inventory_id is null`, else transfer_in; when neither machine field is set → warehouse_fill. (Live data: all 78 Move/Transfer rows have neither machine field set, so all resolve to warehouse_fill.)
  6. action = Replace → warehouse_fill.
  7. action in (Keep, Backup, Calibrate) → legacy_noop.
  8. action is NULL: `item_added = true` → warehouse_fill; `returned = true or quantity < 0` → warehouse_return; else → legacy_noop.
  - `return_reason` is never scanned for this backfill (see F1a).
  - Print the counts per kind before and after, and list any row the rules cannot classify (expect 0, stop if not). Dry run 2026-09-22 on all 42,054 rows: warehouse_fill 38,368, warehouse_return 3,289, legacy_noop 216, transfer_out 95, transfer_in 86, intra_out/intra_in 0/0, unclassifiable 0.

### F1a. write_off is forward-only

`write_off` gets zero backfilled rows. It is set only going forward, by two writers: the F4 field app take-out flow (driver marks the units destroyed on site, reason expired or damaged) and the F10 expiry-check tap when the driver marks units destroyed at the machine. Historical `return_reason` text is never scanned to infer write_off — the 43 distinct historical values in that column carry no reliable, enumerable write-off signal (mostly one-off CS operational notes), and guessing a subset would misclassify real returns.

### F2. Writers set it

`push_plan_to_dispatch`, `add_dispatch_row`, `add_m2m_transfer` (PRD-130 02), `add_intra_machine_move` (PRD-130 05), `insert_driver_remove_line`, the driver split (`wm_confirm_line_split` and the app's split), `convert_removes_to_m2m_transfer`, `pair_internal_transfer_m2m`. Each sets `movement_kind` explicitly. A trigger `tg_movement_kind_required` rejects any insert without it and any update that changes it after `packed=true` or `driver_confirmed_at is not null`, except through `reclassify_dispatch_movement(p_dispatch_id, p_new_kind, p_reason)` which requires operator_admin, a 10+ character reason, logs to `refill_dispatching_edit_log`, and refuses if the line already has a warehouse credit.

### F3. Packing

`pack_dispatch_line` and the packing screen query: `movement_kind = 'warehouse_fill'` only. All other kinds are born `packed=true, pack_outcome='no_pack_needed'`. Remove the `from_warehouse_id` test from the screen. `from_warehouse_id` is set only on warehouse_fill; returns use a new `return_warehouse_id`.

**Drafted and tested 2026-09-22** (`prd131_03_packing_by_kind`, NOT yet applied, gated to after 22:00 Dubai): confirmed `pack_dispatch_line` and the pack_outcome default already held before this migration (see "Found while implementing" #4); the only actual change needed was `push_plan_to_dispatch`'s Remove/warehouse_return leg insert, `packed: false -> true`. Tested in a rolled-back transaction with prd131_01 + prd131_02 applied first, real `push_plan_to_dispatch` call against WAVEMAKER-1006-4100-O1, synthetic plan_date 2031-03-03: Remove/Machine To Warehouse line (A01, Hunter Canister Hot Chili) came back `movement_kind=warehouse_return, packed=true, pack_outcome=no_pack_needed, from_warehouse_id=NULL, return_warehouse_id=<WAVEMAKER primary wh>`; the untouched Refill line (A02, Ice Tea Peach) came back `movement_kind=warehouse_fill, packed=false, pack_outcome=NULL, from_warehouse_id=<same wh>, return_warehouse_id=NULL`. Green, no constraint or trigger errors. The packing-screen FE change (dropping non-fill kinds from the pick list, defense in depth alongside the now-corrected `packed=false` filter) is drafted separately on branch `prd131-packing-screen`, not pushed, gated on this migration landing.

### F4. Field app

One card per lane, verb from `movement_kind`: Put in, Take out, Move X to Y. The driver enters the count taken out or put in. The "Returned" button (unfilled goods coming back) exists only on warehouse_fill cards. Take-out cards have no Returned button, they have Confirm count and a Not found option (count 0 with reason). Intra pairs render as one card.

### F5. Warehouse receipt

The receipt screen and `wh_approve_remove_receipt` / `wh_approve_remove_receipt_multivariant`: `movement_kind = 'warehouse_return'` only. Warehouse enters what physically arrived per flavour and expiry; approval credits that count. Driver count is shown for comparison, never credited. A return with driver count > 0 and no approval after 48 hours raises an alert (G-RETURN-STALE). transfer_* and intra_* lines are refused by these RPCs with a message naming the right path (already partly there for is_m2m; make it kind-based).

### F6. Receipts for transfers and intra moves

`receive_dispatch_line` on transfer_in / intra_in: credit the destination lot, mark the paired out-leg settled, no warehouse. On transfer_out / intra_out directly: refuse, the in-leg drives it.

### F7. 22 Sep repair

Reclassify the six stuck rows (WAVEMAKER A04 Red Bull 5 + 4, MINDSHARE A16 Krambals 2 + 3 + 3 + 1) to warehouse_return with `returned=false`, driver count = quantity, via `reclassify_dispatch_movement`. Then they appear on the receipt screen for Simran to confirm. Also check WAVEMAKER A01 Sunbites: approved as 6, driver reported 2; produce the variance for the recount list, do not change the approval.

**Verified 2026-09-23** (`scripts/prd131_f7_repair_20260922.sql`, read-only, run against live data): all six rows already carry `action='Remove'` and a non-null `wh_approved_at` (approved between 10:38 and 11:47 on 2026-09-22, as part of Part 1 of this session's work). Nothing left to reclassify. The Sunbites variance check found no live discrepancy: both WAVEMAKER A01 Sunbites Remove rows show `driver_confirmed_qty` exactly equal to the approved `quantity` (4=4, 2=2) as of today. The "driver reported 2" figure in the paragraph above does not match current data; not fabricated to match it. If a real variance is still expected, it is not visible via `driver_confirmed_qty` today and needs a different signal named explicitly.

### F8. Guards, nightly on jobid 82

- G-KIND-NULL: rows with movement_kind NULL. Expect 0.
- G-KIND-PACK: movement_kind <> warehouse_fill with pack_outcome = 'packed'. Expect 0.
- G-KIND-CREDIT: inventory_audit_log credits whose source dispatch is not warehouse_return or a warehouse_fill remainder. Expect 0.
- G-RETURN-STALE: per F5.
- G-M2W: any row with action = 'Machine To Warehouse'. Expect 0 after backfill.
- G-RETURN-GAP: per 4b, every gap with its reason, listed daily.
- G-EXPIRY-TAP-OFFSITE: `removed_at_machine` events whose actor is not field_staff or has no matching picked-up dispatch. Expect 0.

## 4. Acceptance

1. Engine swap (Remove + Add New on one lane): Remove is warehouse_return, shows Take out in the app, appears on the receipt screen after driver confirm, credits only on approval with the approved count.
2. `add_m2m_transfer` A to B: out and in legs, neither on packing, neither on receipt, B credited on item_added, A debited on driver confirm.
3. `add_intra_machine_move`: one card, lot moves lane, no warehouse touch.
4. Driver presses Not found on a return: count 0, no credit, flagged.
5. A `Machine To Warehouse` insert fails.
6. Receipt card: clear and overwrite Qty, add a second expiry row for the same flavour, confirm with a gap and a reason, and check the warehouse credit equals the lots table exactly. Inventory control not needed.
7. Expiry tap from a warehouse role creates a request, not a removed_at_machine event.
8. All guards return 0 on 21 and 22 Sep after F1 backfill, F7 and the F10 repair.

## 4b. Warehouse receipt screen, field by field (from Simran's video and messages, 22 Sep)

What is broken today on the confirmation card:

- The Qty box cannot be cleared or overwritten. Typing appends to the existing value (1 became 133 in the video). Controlled input resets its value on every keystroke.
- Batch expiry is shown but not editable. Red Bull came back as 3 of 21 Jan 28 and 6 of 22 Feb 28; the card offered one lot. Simran had to confirm the wrong split, then fix stock by hand through inventory control (12 manual edits between 15:09 and 15:48).
- "Split by variant" splits flavours only. No split by expiry for the same flavour.
- No place to say why the count differs from what the driver reported.
- No gap flag. A return confirmed at 1 when the driver reported 4 leaves the 3 unexplained.

Required card (F5 extended):

- Driver count, read only, next to an editable Received count. Received defaults to driver count. Input must accept clear, overwrite and 0.
- Lots table under the card: one row per (flavour, expiry, qty). Add row, remove row, edit expiry with a date picker, edit qty. Sum of rows must equal Received or the Confirm button is disabled with the difference shown.
- Outcome per lot row (back to stock, redeploy to machine X, waste, quarantine), system proposal pre-filled.
- Gap line: Received minus Driver count. When not zero, a reason is mandatory (miscount by driver, damaged, consumed, not found, other with text). Stored on the dispatch row as `receipt_gap_qty`, `receipt_gap_reason`, and raised as an alert (G-RETURN-GAP) so it shows on the recount list and the daily story.
- One Confirm per card. Confirm credits exactly the lots table, nothing else. Inventory control must not be needed to finish a return.
- The card header shows movement_kind and source (planned return, driver take-out beyond plan, expiry check) and the machine and lane it came from.

### F10. Expiry-check tap must come from the machine, not the office

The two Activia lines on 22 Sep (AMZ-1029 A05, Honey & Oats 2, Strawberries 6, expiry 25 Sep) were created at 08:11 by the warehouse manager account through the driver expiry-check tap, from the office, while the driver had not visited AMZ-1029. The tap wrote `removed_at_machine` on two pod lots, put 8 units into the receipt queue, and nobody had touched the machine. The product is still on the shelf and expires in 3 days.

- The expiry-check tap is only enabled for a field_staff session with the machine open in the field app during a visit (a dispatch for that machine and date exists and is picked up), and it records who tapped and from which dispatch.
- From any other role or context the same button creates an `expiry_action_request` (proposed), which becomes a take-out line on the machine's next plan, not a `removed_at_machine` event.
- Repair for 22 Sep: supersede the two Activia events (`superseded_by_event`), restore the two pod lots, and put a Remove for Activia x8 with reason expiring on AMZ-1029's next visit. AMZ-1029 was visited today, so the next visit is the one to catch it; if the product will expire before, flag it on the daily story.

**Partially done, discovered 2026-09-23** (`scripts/prd131_f10_activia_repair_20260922.sql`): the pod_inventory restore was already carried out earlier in this session, before writing this script, via `adjust_pod_inventory` -- but not to 2 and 6 as this section assumed. WEIMI (real physical shelf state) showed only 4 units actually on A05, not 8, so the restore was pro rata to the original 2:6 split: Honey & Oats 0 -> 1, Strawberries 5 -> 3 (`pod_inventory_audit_log`, reference `adjust-AMZ-1029-3003-O1-A05-2026-09-22`). Restoring the full tapped 8 units would have created 4 units of phantom stock; not done. Still outstanding as of 2026-09-23: the two original events (`03027dc0`, `f0e117f6`) still self-reference their own `superseded_by_event` rather than pointing at a real correction event, and no Remove has been scheduled yet for the next visit. The rewritten script does both, at the corrected 1 + 3 quantities, tested green in a rolled-back transaction; not yet applied.

## 4c. wm_confirm_return, the real F5 RPC (spec only, tomorrow's session implements)

The receipt card ships tonight calling the existing `wm_confirm_line_split`. That RPC has no
structured gap fields and no VOX/venue-warehouse routing. `wm_confirm_return` replaces it once
written.

**Signature:**

```
wm_confirm_return(
  p_dispatch_id uuid,
  p_lots jsonb,       -- array of {boonz_product_id, expiry, qty, outcome, target_machine_id, disposal_code}
  p_gap_reason text,  -- required only when sum(p_lots.qty) <> driver_confirmed_qty, else NULL
  p_caller uuid
) RETURNS jsonb
```

**Validations, in order:**

1. `p_dispatch_id` resolves to a `refill_dispatching` row with `movement_kind = 'warehouse_return'`. Any other kind is refused by name (transfer_out/transfer_in/intra_out/intra_in go through F6's receipt path instead, never this one).
2. Row is not already settled: `wh_approved_at IS NULL` and `item_added = false`.
3. `p_lots` is a non-empty array. Every entry's `qty > 0`.
4. Every lot's `boonz_product_id` maps to the parent row's `pod_product_id` via an Active `product_mapping` row. A lot naming a product with no such mapping is refused, naming the product and the parent pod product.
5. Every non-waste lot has a non-null `expiry` (waste lots may omit it, matching the existing `wm_confirm_line_split` rule).
6. `sum(p_lots.qty)` compared against `driver_confirmed_qty` (or `quantity` if the driver never confirmed): if they differ, `p_gap_reason` must be non-null and at least 10 characters. If they match, `p_gap_reason` must be NULL (no fabricated reason for a clean count).
7. VOX rule: `return_warehouse_id` on the parent row decides where credit lands, always. The function never re-derives a warehouse from the caller or from any lot entry. If `return_warehouse_id IS NULL` (should not happen post-F1 backfill, but refuse loudly rather than guess), raise naming the dispatch id.

**What it writes, one call, one transaction:**

- One `inventory_audit_log` row per lot (the credit), `source_event_id = p_dispatch_id`, warehouse = the parent row's `return_warehouse_id`.
- One `disposition_events` row per lot (`source = 'return_receipt'`, `state` = the lot's outcome), same shape `wm_confirm_line_split` already writes today.
- `receipt_gap_qty = sum(p_lots.qty) - driver_confirmed_qty` and `receipt_gap_reason = p_gap_reason` on the parent `refill_dispatching` row (NULL/NULL when the count matched exactly).
- `wh_approved_at = now()`, `wh_approved_by = p_caller` on the parent row, once, at the end, after every lot has been written successfully.
- Nothing to `inventory_control` or `pod_inventory` directly. Acceptance 9's "zero inventory_control writes" holds by construction, this function never touches that table, same as `wm_confirm_line_split` today.

**Office vs venue queue split (the VOX rule from CS, 2026-09-22):** `v_wm_confirmations` gets a
`return_warehouse_id` column (copied straight from the dispatch row) and the office screen
(`WarehouseConfirmationsPanel`) filters `return_warehouse_id = WH_CENTRAL` only. A second,
separate view or filter (`v_wm_confirmations_venue` or a query param) shows
`return_warehouse_id <> WH_CENTRAL` rows, one venue at a time, for the VOX visit day, so a venue
return never sits in the office queue accumulating hundreds of hours the way the two IFLYMCC
returns did on 22 Sep (678h and 176h).

## 4d. Field app: Not-found flow and intra-pair cards (spec only, tomorrow's session implements)

Not done tonight. The button text change ("Put in" / "Take out") ships tonight since it uses only
today's `dispatch_action` field and changes no behavior. Everything below needs a proper spec,
implementation, and a test account against the preview before it goes anywhere near a driver.

**Why not tonight:** removing the existing "Could not remove" / "Returned" fallback button
without a tested replacement removes a working safety net for drivers mid-shift. This screen
(`field/dispatching/[machineId]/page.tsx`) is 1747 lines with deep conditional branching on
`dispatch_action` and `is_internal_move`; a same-day rewrite of its behavior, untestable against
the SSO-gated preview interactively, is not a responsible risk to take alongside everything else
landing tonight.

**Not-found flow, take-out cards (movement_kind IN warehouse_return, transfer_out, intra_out):**

- Remove the "↩ Returned" / "↩ Could not remove" button from any card whose `movement_kind` is
  not `warehouse_fill`. Replace with a "Not found" action: count defaults to 0, a reason is
  required (dropdown: not on shelf, wrong product, already gone, other + text), and the RPC
  behind it must still be `driver_confirm_remove`/its transfer or intra equivalent with
  `p_qty_removed = 0` and the reason logged to `refill_dispatching_edit_log`, not silently
  dropped. Confirm-count stays the primary action, unchanged.
- `movement_kind = warehouse_fill` keeps exactly today's "↩ Returned" button and behavior
  unchanged (unfilled goods coming back is still a real, needed path).

**Intra pairs as one card:**

- Group `intra_out` and `intra_in` legs sharing an `m2m_transfer_id` into a single card, labelled
  "Move {from_shelf} to {to_shelf}", one Confirm-count input (the same physical count applies to
  both legs, they cannot diverge). Today these render as two separate, unrelated-looking lines.
- Test account: needs a real field_staff login against the preview (not SSO-gated for a
  field_staff role, per the login flow) so this can actually be clicked through before shipping,
  unlike the operator_admin-only receipt card screens.

## 5. Out of scope

- Reservation of planned quantities against driver additions (PRD-130 F9).
- align_pod_lots_to_weimi NULL-expiry lots.

---

## Claude Code prompt

You are working in the boonz-erp repo against Supabase project eizcexopcuoycuosittm. Save this file as docs/PRD-131-movement-kind.md and read it fully.

Before anything: report the status of PRD-130. Migrations prd130_01, prd130_02 and prd130_05 are applied on the database; 03, 04, 06, 07, 08 are not. Say for each whether the code exists on a branch, whether it is merged, and what blocks it. PRD-131 builds on 130, so 130 must land first or in the same branch; propose the order and wait for my go before applying anything.

Then, in order:

1. F1 migration `prd131_01_movement_kind` with the backfill as a dry-run first (print counts per kind, list unclassifiable rows, stop if any). Apply only after I confirm the counts.
2. F2 `prd131_02_writers_set_kind`, F10 `prd131_10_expiry_tap_scope` (with the Activia repair as a script, `scripts/prd131_f10_activia_repair_20260922.sql`, run on my go), F3 `prd131_03_packing_by_kind`, F5 `prd131_05_receipt_by_kind`, F6 `prd131_06_transfer_receipts`, F8 `prd131_08_guards`. F4 and the receipt card in section 4b are app changes, separate commits, and the receipt card is the first app change to ship: fix the Qty input, editable expiry, lots table with split by expiry, gap reason, one Confirm. Each migration idempotent, rollback capture in supabase/rollback/, never in supabase/migrations/, existing signatures preserved.
3. F7 as a script `scripts/prd131_f7_repair_20260922.sql` that calls `reclassify_dispatch_movement` on the six rows and prints the Sunbites variance. Run it only when I say go.
4. Timing: anything touching pack_dispatch_line, receive_dispatch_line, wh_approve_remove_receipt*, protect_packed_dispatch_row or the field app runs after 22:00 Dubai. State the time in the report.
5. Acceptance tests 1 to 8, on a branch database if available, otherwise on prod after 22:00 with plan_date 2026-09-30 and cancel afterwards. Show SQL and results.
6. Branch prd131-movement-kind, push, compare URL, no merge. No em dashes anywhere.

Report: PRD-130 status table first, then one table per PRD-131 fix (migration, applied at, test result), guard counts before and after, then anything you changed that the PRD did not ask for.
