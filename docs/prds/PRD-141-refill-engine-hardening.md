# PRD-141: Refill engine and refill day hardening

Status: DRAFT for CS green-light. Written 2026-10-17.
Owner: CS. Builder: Claude Code loop. Cody review on every SECURITY DEFINER change.
Sources: Boonz Operations WhatsApp group and Simran DM, 3 to 17 Oct 2026; PRD-138, PRD-139/139b, PRD-140 (what did not ship); drift report 17 Oct; the daily plans run by Claude 13 to 16 Oct.

## 0. Where the last three PRDs stand (verified in prod 17 Oct)

| PRD | Shipped | Not shipped (carried into this PRD) |
| --- | --- | --- |
| PRD-139 / 139b / 139c field fix-first | Role guard, anon execute closed (0 anon-executable definer functions), route gate, dispatch-photos bucket (140 photos), v_po_header, backlog auto-expire (0 stale feedback, 0 stale pod edits) | Item 9 pack-screen immediate write is not proven in the field (Jojo: "if I edit the quantity it will not save"). Item 5 one status everywhere: undelivered packed bags still invisible (AMZ Wed 14 Oct). Item 7 per-line save errors: Simran still gets "max available quantity" with no usable detail. |
| PRD-140 access control | Logout hotfixes only | Items 1 to 8 all open (no access_areas table in prod). Three new prod-only RLS migrations (sim_cards read/write for warehouse, warehouse_write_suppliers, 13 to 14 Oct) have no file in git. |
| PRD-138 drift close-out | Nothing | WS-A four VOX era migrations still prod-only. WS-B era-aware eligibility not applied: VOXDFC-1001 and VOXDFC-2006 still invisible to P1 (17 and 57 sales/7d). WS-C monitor labels not done. ACTIVATEMOE only became eligible because Claude set the Adyen flags by hand on 16 Oct; the sync writer is unproven. |

## 1. What broke on refill days, 3 to 17 Oct (from the chats)

Every line below is something Simran, Jojo, Anthony or CS hit in the field. Grouped by the part of the engine that owns it.

### A. Swaps and returns (the loudest problem, repeated 5 times)
- A0. The app now offers a Swap option, but the flow is broken: the swap writes the incoming product and never logs the outgoing one as a return, so nothing reaches Warehouse Confirmations and Simran cannot validate the goods when the driver brings them back. The swap option must produce the same two legs as a plan swap (Remove with return receipt pending, Add New), or be hidden until it does.
- A1. A swap done through Refill > Add Product > Add New creates no Remove leg. The old product leaves the machine physically but never reaches Warehouse Confirmations, so Simran cannot confirm it and warehouse stock stays wrong. Cases: OMDBB A16 Vitamin Well to Al Ain, ACTIVATEMOE G&H (3 pcs, Claude had to create the Remove by hand and move the receipt from WH_MOE to Central), Mercato, AMZ-1038 return. Prod: 153 Add New lanes in two weeks, only 48 had a Remove on the same lane and date.
- A2. Returns from VOX-type machines land in the venue warehouse (WH_MOE) instead of Central. Two rows moved by hand on 14 Oct.
- A3. No expiry split on a return. HUAWEI Coke Zero 13 pcs across 5 dates and Sunbites with 2 expiries had to be typed as one lot or not at all. Branch `return-split-by-expiry` holds the fix, 5 commits ahead, unpushed since 5 Oct.
- A4. No Damaged outcome. A dented Red Bull can has no place to go except "returned good" or nothing.
- A5. M2M is invisible to the warehouse. The McVities 7 pcs VML-1004 to AMZ-1038 move never shows in Inventory because M2M bypasses warehouse approval, and pod_inventory showed 4 instead of 7, so the app argued with the driver.

### B. Pack screen stock truth
- B1. "Max available quantity" error while editing a line although stock exists (Kit Kat, Nescafe). The check reads raw warehouse_stock in one place and pickable (non-quarantined, non-expired, Central only) in another.
- B2. Near-expiry stock has to be deactivated by hand so it is not packed. The picker should skip lots that expire before the machine's next expected visit.
- B3. Expiry edits on a PO receipt do not propagate to warehouse_inventory (Al Ain Zero 624 bottles, Huel). Batches keep the wrong date and then trigger B2 or expire silently on shelf.
- B4. Packing and refills happen without plan lines (Simran asks for a plan so she knows flavours and quantities). When CS dictates a machine for today, the plan has to exist in refill_dispatching before the warehouse starts, every time.

### C. Mapping adherence
- C1. Removed or 0% products reappear in plans and get repeatedly marked Not filled (7Up, Mountain Dew, Coke Regular at AMZ). Simran dropped split percentages but the engine still proposes them.
- C2. Products added outside the refill list land in the warehouse instead of the pod (Evian at Activate MCC on 0817 and 0736).
- C3. Mapping hygiene: 27 SKUs only exist as machine-scoped mappings, Snack Bar splits sum to 115 to 150, Pepsi Mix 50, Soft Drinks Mix 123. The engine cannot honour splits that do not sum to 100.
- C4. The plan writer rejects legitimate lines (G11 Oreo on AMZ-1038, Krambals flavours at USH, Smart Gourmet Classic at SAP) and forces machine-scoped inserts by hand before every plan.

### D. P1 picker misses the machines that need a visit
- D1. VOX gate: machines with venue-sourced lanes are scored on Boonz lanes only, so a machine full of empty Aquafina lanes grades fine.
- D2. Repurpose grace hides trading machines for 30 days (PRD-138 WS-B). VOXDFC 1001 and 2006 are still invisible.
- D3. Eligibility depends on Adyen flags that go stale on repurposed machines (ACTIVATEMOE sat at Switched off / Pending Setup with 198 sales).
- D4. Empty lanes are not weighted: a machine at 62% with six empty lanes scores like a machine at 62% with every lane half full. CS: "P1 is not my best engine so far given it's missing out on empty shelves."
- D5. New machines (SAP) have no sales history and no WEIMI parity yet, so the picker and slot guard both treat them wrongly; CS rule for now: no swaps on SAP.

### E. Delivery and status truth
- E1. Packed bags that were picked up but never delivered are invisible. AMZ 30 bags (1029 78 u, 1038 85 u) sat in the van from Wed 14 to Fri 16 Oct with no screen showing it; the Friday plan had to be written as "top-ups on top of the Wednesday bags".
- E2. Driver edits on Dispatch Detail do not save (Jojo). Needs the per-line result banner from PRD-139 item 7 verified on a real phone.
- E3. Days-since-visit advances on dispatch, not on delivery confirmation, so an undelivered machine looks served.

### F. WEIMI and new-machine setup blocking the push
- F1. Slot guard blocks Add New on empty lanes and on any pod name mismatch (Hunter Cans vs Hunter Canister 40G, Nutella T3 vs Nutella Biscuits T3). Every plan since 13 Oct needed dispatch-level adds to get around it.
- F2. Missing shelves (A15/A16 on some machines) and relabels (2005 A07 VW, A08 Zigi, 1058 A06 Zigi, MOE A01 VW, SAP B07) are tracked in chat, not in the system.
- F3. pod_inventory under-counts and disagrees with WEIMI (VML-1004 McVities 4 vs 7).

### G. Operator tooling gaps that cost Claude and CS hours per plan
- G1. UPDATE on refill_plan_output hangs (trigger), so one rejected machine cannot be re-approved; the whole machine has to be rebuilt at dispatch level.
- G2. Pending plan lines cannot be deleted (no RPC).
- G3. Multi-row machine updates time out.
- G4. add_dispatch_row pins the FEFO lot regardless of flavour; the lot had to be corrected by hand for G&H.

## 2. Solutions, in build order

Order is by field pain, then by what unblocks the rest. Items marked (night) touch planner views or field functions and run 22:00 to 06:00 Dubai only.

### Phase 1. Swap and return integrity (A1 to A5)
0. Fix the FE Swap option (A0): it calls one RPC `swap_dispatch_lane(machine_id, shelf_code, out_pod_product_id, out_qty, in_boonz_product_id, in_qty, date)` that writes the Remove leg (return receipt pending, `return_warehouse_id` = Central) and the Add New leg in one transaction, returns both dispatch ids, and shows "Return of N x <product> to confirm at warehouse" on the driver card. Until this RPC is live the Swap button is hidden behind a feature flag.
1. Add New on a lane that currently holds a different pod product auto-creates the Remove leg for the full on-shelf quantity (WEIMI current_stock) in `write_refill_plan`, `add_dispatch_row` and the FE Add Product flow. One function `ensure_swap_remove_leg(machine_id, shelf_code, new_pod_product_id, date)` used by all three. A swap is then always two rows, in and out, no matter where it was typed.
2. `driver_confirm_remove` and `return_dispatch_line` book every return to WH_CENTRAL unless the dispatch row carries `return_warehouse_id`. Backfill: none needed, the two MOE rows are already moved.
3. Push and merge `return-split-by-expiry` (A3). Driver enters quantity per expiry date on a return; one `warehouse_inventory` row per date; `wh_approve_remove_receipt_multivariant` already accepts a list.
4. Add `outcome = 'damaged'` to return legs: writes a `warehouse_inventory` row with `quarantined = true` and `provenance_reason = 'damaged_return'` so it never becomes pickable and shows under Quarantine with a write-off button.
5. M2M visibility: an M2M leg shows in Warehouse Confirmations as "Machine transfer, no stock movement" with the source Remove quantity, and the destination pod_inventory is written at `approve_m2m_transfer` time with the confirmed quantity (fixes the 4 vs 7).

### Phase 2. Pack screen stock truth (B1 to B4)
6. One pickable-stock function `pickable_stock(boonz_product_id, warehouse_id, needed_by date)` = Active, not quarantined, Central (or the plan's source warehouse), expiry after `needed_by` plus `min_shelf_life_days` (new param, default 14). The pack screen max, the G8 gate and the picker all call it. The error message names the number it used and why ("12 pickable, 30 on hand: 18 quarantined/expiring before 31 Oct").
7. Receipt expiry edit propagates: `edit_po_line_expiry` updates the PO line and every `warehouse_inventory` row with that `batch_id` that has not been packed yet, and logs an audit row.
8. Every pack outcome writes on tap (PRD-139 item 9 finish): verify on Simran's phone with a test machine, keep the unsaved-packs guard as backstop.
9. Dictated day rule in the app: Packing list shows "No plan lines" in red for any machine CS named for the day but with 0 pending rows, so the warehouse never starts from memory.

### Phase 3. Mapping adherence (C1 to C4) (night)
10. Engine and `write_refill_plan` read the effective mapping: machine-scoped row wins, `split_pct = 0` or status not Active means never propose and never accept a Refill on that lane (G11 message says which mapping blocks it and offers the machine-scoped insert).
11. Mapping hygiene migration: normalise splits to 100 per pod product per machine, promote the 27 machine-scoped-only SKUs to a global row where they sell on 2 or more machines, and add a check constraint or nightly report that fails when a pod product's splits do not sum to 100.
12. Products added at the machine outside the plan (C2) are written as a pod_inventory row on the shelf chosen in the app, with a `Machine To Warehouse` leg only when the driver says so. Default is the machine.

### Phase 4. P1 picker (D1 to D5) (night, Cody review, fleet-diff proof in a rolled-back transaction)
13. Apply PRD-138 WS-A (commit the four VOX era files) and WS-B (era-aware eligibility, `repurpose_min_days` 3, `repurpose_min_sales` 10, velocity clipped to the era). Acceptance unchanged from PRD-138.
14. Eligibility stops depending on Adyen flags alone: `is_eligible_machine` = (Adyen flags Live) OR (successful sales in the last 48 h >= 3). A selling machine is live by definition. Keep a `drift_reason = 'label_not_live'` row in `v_machine_eligibility_drift` so the Adyen writer still gets fixed.
15. Empty-lane weighting: machine score adds `empty_lane_pct * w_empty` (param, default 0.4) and a VOX-aware fill: venue-sourced lanes count in the fill percentage but their refill lines are tagged `vox_at_venue` for the VOX team note, not for the Boonz truck.
16. New-machine mode: machines with `relaunched_at` or `created_at` under 21 days use category velocity (same pod product fleet median) instead of own history, and the slot guard runs in warn mode for them (no Remove suggested, Add New allowed on empty lanes).

### Phase 5. Delivery and status truth (E1 to E3)
17. New state on `v_machine_pack_status`: `in_transit` = picked up and not delivered. Home card "In the van" with age; red after 24 h. Dispatching list shows the undelivered bags per machine with the pickup date.
18. Top-up rule: `write_refill_plan` for a machine with `in_transit` rows warns and tags the new lines `top_up_on_transit`, so the pack list prints "deliver with the bags of <date>".
19. `days_since_visit` and last-visit use delivery confirmation (`receive_dispatch_line`), not dispatch.
20. Dispatch Detail: verify PRD-139 item 7 on a phone; if quantity edits still do not persist, fix the RPC call (likely `edit_dispatch_qty` role check after PRD-139b 2B) and add a visible save confirmation.

### Phase 6. WEIMI and setup (F1 to F3)
21. Slot guard pod-name matching uses `pod_product_aliases` (new table seeded with the known pairs: Hunter Cans = Hunter Canister 40G, Nutella T3 = Nutella Biscuits T3, Freakin Healthy Balls 3P = Freakin Protein Balls 3P, Chewing Gum = Extra Gum) and allows Add New on an empty lane when the plan comment or a `relabel_pending` flag exists.
22. Relabel queue: table `weimi_relabel_requests(machine_id, shelf_code, from_pod, to_pod, requested_by, done_at)`; the plan writer inserts one per swap; Config > Machines shows the open list; CS marks done. No more relabel tracking in WhatsApp.
23. Nightly `resync_pod_inventory_from_weimi` dry run across the fleet with a report of machines where pod_inventory and WEIMI differ by more than 2 units on any lane; weekly auto-commit for machines with no open dispatch.

### Phase 7. Operator tooling (G1 to G4)
24. `reject_plan_lines(date, machine_id)` RPC that marks pending refill_plan_output rows rejected without the hanging trigger (statement-level, SECURITY DEFINER, operator_admin only).
25. Fix the refill_plan_output UPDATE trigger (find the cascading write, make it AFTER STATEMENT or move it to approve time).
26. `add_dispatch_row` takes an optional `pod_lot_id` and otherwise picks FEFO within the same boonz_product_id and flavour.
27. `approve_refill_plan` returns per-machine results instead of failing the whole call on one unbound row (Gate-2 per machine).

## 3. Acceptance (the day this PRD is done)
- Any swap typed anywhere produces a Remove row and a Warehouse Confirmation; zero Add New lanes on an occupied shelf without a Remove in the next 14 days of data.
- Returns land in Central, split by expiry, with a Damaged option; M2M shows in Confirmations and pod counts match the driver.
- Pack screen max equals pickable stock and the message explains the number; a receipt expiry edit changes the batch.
- No Not filled on a 0% or inactive mapping for 14 days; all splits sum to 100.
- VOXDFC 1001 and 2006 and any machine selling in the last 48 h appear in P1; empty-lane machines rank above half-full ones at equal fill.
- Undelivered bags show on Home within the hour; days_since_visit moves on delivery.
- Plans for the standard swap set push without any dispatch-level workaround; relabels live in Config, not WhatsApp.
- PRD-138 WS-A/B, the three 13 to 14 Oct RLS migrations and `return-split-by-expiry` are on main; drift report shows 0 new prod-only migrations.

## 4. Not in this PRD
PRD-140 access control items 1 to 8 (separate loop, already specified). Sanitisation process for machines (ops SOP, not engine). SIM gaps on 15 machines (hardware). VOX team filling VOXMM-1013 and VOXMCC-1012/1017.

---

## Claude Code prompt (paste everything below this line)

You are working in the boonz-erp repo (Next.js App Router, Supabase project `eizcexopcuoycuosittm`). Implement PRD-141 Refill engine and refill day hardening. First save this spec as `docs/prds/PRD-141-refill-engine-hardening.md` and commit it. Take a single-session lock at `docs/prds/PRD-141.lock` exactly as PRD-139b did; stop if another loop holds one under 8 hours old.

Hard rules:
- Phases 3 and 4 touch planner views and `v_live_shelf_stock` consumers: apply only between 22:00 and 06:00 Dubai, after a full-fleet before/after diff in a rolled-back transaction pasted into the log. Phases 1, 2, 5, 6, 7 can run in the day but every field-function change ships with a rollback file in `supabase/rollbacks/` and an immediate three-role smoke test (operator_admin, warehouse, field_staff).
- Every migration is a file in `supabase/migrations/` with the exact applied version and name, applied to prod, committed and pushed after every item. Start Step 0 by writing the files for the three prod-only migrations `20261013073741_sim_cards_warehouse_read_policy`, `20261013074915_sim_cards_warehouse_write_policy`, `20261014065707_warehouse_write_suppliers` and the four 2026-09-28 VOX era migrations from `supabase_migrations.schema_migrations.statements`, byte for byte, md5 checked. Then push branch `return-split-by-expiry` to origin, rebase it on main and open it for merge in Phase 1 item 3.
- Every SECURITY DEFINER function you create or replace ends with `REVOKE EXECUTE FROM public, anon; GRANT EXECUTE TO authenticated` (or service_role only). Role checks use `auth.uid()` and the stored role, never a client parameter. Cody review before apply. No overloads; run the overload check after each phase.
- Never change live pod or warehouse quantities outside the RPCs. Never override `protect_packed_dispatch_row`. Never regenerate a live plan.
- No em dashes anywhere. Dubai dates for all date logic. Surgical scope, no refactors.
- Running log `docs/prds/PRD-141-log.md` and report `docs/prds/PRD-141-REPORT.md` updated after every item: DONE / ALREADY DONE (evidence) / ROLLED BACK (reason) / BLOCKED (exact reason). Do not ask CS questions; take the defaults in the spec.

Execute the 27 items of section 2 in phase order with these time boxes: Step 0 30 min; Phase 1 180 min; Phase 2 120 min; Phase 3 90 min (night only); Phase 4 150 min (night only); Phase 5 90 min; Phase 6 90 min; Phase 7 60 min; gates 40 min. If the night window is not open when you reach Phase 3, do Phases 5, 6, 7 first and come back.

Per item, before building, check main and prod and record ALREADY DONE with evidence if it exists. Test evidence required: Phase 1 a swap typed via FE Add Product on a test machine produces the Remove row and a Warehouse Confirmation; a return of 5 units with two expiry dates creates two warehouse rows in Central; a damaged return is quarantined. Phase 2 the pack screen max for Kit Kat equals `pickable_stock` and the message lists the excluded units; an expiry edit on a received line changes the batch rows. Phase 3 `write_refill_plan` rejects a Refill on a 0% mapping with the mapping named; splits sum to 100 fleet-wide. Phase 4 only VOXDFC-1001 and VOXDFC-2006 flip to eligible in the diff; ACTIVATEMOE stays eligible with the Adyen flags removed in the rolled-back test; a machine with 6 empty lanes outranks one with 0 empty lanes at the same fill. Phase 5 a picked-up undelivered machine shows "In the van" on Home and days_since_visit does not move until `receive_dispatch_line`. Phase 6 a plan with "Hunter Cans" on a "Hunter Canister 40G" lane approves without dispatch-level adds; a swap inserts a relabel request. Phase 7 `reject_plan_lines` returns in under 5 s on a 40-row machine.

Gates before you stop: overload check clean; repo/prod migration parity both directions (the drift script); anon-executable definer count still 0; three-role smoke test of Packing, pack screen, Pickup, Dispatch Detail (add, return with split, damaged), Warehouse Confirmations, Inventory; the acceptance list in section 3 with PASS or FAIL and evidence. Final CS section in plain English: items table, migrations, commits, what changed on screen per role, what CS must do (Vercel deploy if not automatic, mark the open relabels done, approve the mapping hygiene changes list). Delete the lock, commit "PRD-141: release lock", push. Last line of the report: "## PRD-141 DONE".
