# PRD-061 EXECUTION LOG — Jojo 23-25 Jun off-system edits reconciliation

Run date: 2026-06-26. Mode: auto-run, canonical RPCs only, idempotent, skip+log gaps. Sheet 3 (Transfers) and Sheet 4 (App flags) excluded by scope.

## Headline governance finding (needs CS decision)

The largest class on the sheet -- **REMOVE / return-to-office and the matching Sheet 2 RETURN-credit-WH rows** -- has **NO single canonical writer** for off-system (no-dispatch) events:

- `return_dispatch_line` credits WH + sets pod Inactive, but REQUIRES a pre-existing `refill_dispatching` row with `action='Remove'`. Jojo's manual removals have no dispatch row.
- `log_retroactive_refill_visit` (CS-mapped fallback) was read in full: it ONLY inserts `refill_dispatching` log rows, moves NO pod/WH stock, and only accepts `action IN ('Refill','Add New')` -- it cannot perform a removal or a WH credit.
- `remove_pod_inventory_batch` removes from pod (status `Removed/Expired`, stock 0) but does NOT credit WH.
- `adjust_warehouse_stock` is an absolute SET reconcile (manual_adjust), not a return-credit-by-delta.

Per the hard rule ("if a whole class has no canonical writer, stop and tell me before raw-writing") these rows are logged as SKIP, not raw-written. CS decision needed (one of):

1. Authorise the 2-RPC decomposition: `remove_pod_inventory_batch` (pod) + `adjust_warehouse_stock` (WH credit) per return row; or
2. Create dispatch rows first, then `return_dispatch_line`; or
3. Build a dedicated canonical manual-return writer (separate PRD).

## Reference data resolved

- All machines resolved (the 07xx "device numbers" are the last 4 digits of `pod_number`): 0817 = ACTIVATE-2005-0000-W0, 0736 = ACTIVATEMCC-1037-0000-L0, 0719 = MPMCC-1054-0000-M0, 0715 = MPMCC-1058-0000-R0, 0795 = VOXMCC-1011-0101-B0, 0797 = VOXMCC-1005-0201-B0, 0705/0716/0735/0745 = the four AMZ machines. **No machine-resolution gaps.**
- Writers confirmed via `pg_get_functiondef`. Service-role calls: `remove_pod_inventory_batch` takes `p_caller_id` (passed operator_admin 38c282e3); `log_manual_refill` has no bypass, so impersonated operator_admin via `request.jwt.claims`.

## Sheet 1 -- Machine updates

| Row | Machine          | Action              | Item                                           | Qty     | Result                                                                                                                                                                        |
| --- | ---------------- | ------------------- | ---------------------------------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| R2  | VML-1004         | REMOVE              | Ice Tea Peach                                  | 13      | SKIP -- returns class, no canonical writer. No recent Active pod row (likely already gone).                                                                                   |
| R3  | VML-1004         | REMOVE              | Red Bull Regular                               | 14      | SKIP -- returns class, no canonical writer. No recent Active pod row.                                                                                                         |
| R4  | VML-1003         | REMOVE              | Coca Cola Regular                              | 12      | PARTIAL/already_done (pod) -- pod already `Removed/Expired` (inactive_cleanup, stk 4 snap 2026-06-10). WH-credit side SKIP (no writer).                                       |
| R5  | VML-1003         | NOT ADDED           | Coke Zero                                      | 1       | NO-OP by design -- stays in WH, no machine change.                                                                                                                            |
| R6  | NOVO             | TRANSFER OUT        | Vitamin Well mix                               | 5       | EXCLUDED -- Sheet 3 transfer.                                                                                                                                                 |
| R7  | Mindshare        | ADD (not in list)   | VW Care/Peach/Upgrade/Reload                   | 2/1/1/1 | SKIP -- transfer-sourced (received from NOVO, Sheet 3); not a WH-debit add. "Peach" variant ambiguous.                                                                        |
| R8  | Mindshare        | REMOVE              | Caprice                                        | 3       | SKIP -- returns class no writer + ambiguous variant (Caprice Diet vs Hazelnut).                                                                                               |
| R9  | Mindshare        | REMOVE              | Pepsi Black                                    | 10      | SKIP -- returns class no writer. Pod still Active stk 10 (shelf 324304b3) -- removal NOT reflected.                                                                           |
| R10 | Mindshare        | REMOVE              | NRJ Roasted Salt                               | 1       | SKIP -- returns class no writer. No recent Active pod row.                                                                                                                    |
| R11 | Mindshare        | REMOVE              | NRJ Trailmix                                   | 1       | SKIP -- returns class no writer. No recent Active pod row.                                                                                                                    |
| R12 | Mindshare        | NOT ADDED           | Loacker Vanilla/CreamKakao/Napolitaner         | 3/2/1   | NO-OP by design -- stays in WH.                                                                                                                                               |
| R13 | GRIT             | WRITE-OFF (expired) | VW Antioxidant                                 | 9       | **APPLIED** -- `remove_pod_inventory_batch`. Before: Active stk 0 (shelf 11d57e52, exp 2026-06-28). After: `Removed/Expired` row (snap 2026-06-26). No WH credit (write-off). |
| R14 | GRIT             | WRITE-OFF (expired) | VW Reload                                      | 6       | ALREADY_DONE -- pod already Inactive (ghost_sweep 2026-05-18), no Active row. No WH credit.                                                                                   |
| R15 | GRIT             | SWAP                | VW -> Evian (temp)                             | --      | SKIP -- Evian add has no qty/expiry (ambiguous). VW remove side covered by R13/R14.                                                                                           |
| R16 | Wavemaker        | EDIT                | A5 = Pepsi only (2 black + 1 reg), return rest | 3       | SKIP -- compound edit + returns class no writer; current A5 contents not specified.                                                                                           |
| R17 | WPP              | REFILL (dispatched) | (no explicit deltas)                           | --      | SKIP -- "confirm against plan", no explicit deltas to apply.                                                                                                                  |
| R18 | MC-2004          | ADD (not in list)   | Benlian Sea Salted                             | 2       | SKIP -- no existing slot (not in planogram), no expiry -> shelf unresolvable.                                                                                                 |
| R19 | AMZ-1068         | REFILL (dispatched) | (no explicit deltas)                           | --      | SKIP -- no explicit deltas.                                                                                                                                                   |
| R20 | AMZ-1057         | REFILL (dispatched) | (no explicit deltas)                           | --      | SKIP -- no explicit deltas.                                                                                                                                                   |
| R21 | AMZ-1038         | ADD (not in list)   | ? items (truncated)                            | --      | SKIP -- unknown items; get the list from Jojo.                                                                                                                                |
| R22 | AMZ-1029         | ADD (not in list)   | VW Care                                        | 2       | **APPLIED** -- `log_manual_refill`. WH-2 (batch exp 2026-07-19), pod +2 Active on A16 (pod_inventory_id 04bbd06f). No shortfall.                                              |
| R23 | ACTIVATEMCC-1037 | SWAP                | Evian Regular (out 2) -> Evian 330ml (in 21)   | --      | SKIP -- remove side = returns class no writer; add side (21) needs shelf + WH-source confirm.                                                                                 |
| R24 | ACTIVATE-2005    | ADD                 | Aquafina Water                                 | 72      | SKIP -- no existing slot, no expiry; source-check pending (Sheet 2 R15).                                                                                                      |
| R25 | ACTIVATE-2005    | ADD                 | Fade Fit Coconut                               | 8       | SKIP -- no existing slot, no expiry.                                                                                                                                          |
| R26 | ACTIVATE-2005    | ADD                 | Gatorade Blue                                  | 4       | EXCLUDED -- from Ifly, Sheet 3 transfer.                                                                                                                                      |
| R27 | ACTIVATE-2005    | ADD                 | Loacker Vanilla                                | 5       | SKIP -- no existing slot, no expiry.                                                                                                                                          |
| R28 | ACTIVATE-2005    | REMOVE              | Starbucks                                      | 11      | EXCLUDED -- moved to Amazon, Sheet 3 transfer/redeploy.                                                                                                                       |
| R29 | Ifly             | REMOVE              | Gatorade Blue                                  | 4       | EXCLUDED -- to Activate, Sheet 3 transfer.                                                                                                                                    |
| R30 | Ifly             | REMOVE              | Krambals Forest Mushroom                       | 1       | SKIP -- returns class no writer. No recent Active pod row.                                                                                                                    |
| R31 | VOXMCC-1011      | TRANSFER OUT        | Sunblast Apple/Apple Cherry                    | 5/1     | EXCLUDED -- Sheet 3 transfer.                                                                                                                                                 |
| R32 | VOXMCC-1005      | ADD                 | Sunblast Apple/Apple Cherry                    | 5/1     | EXCLUDED -- transfer receive (Sheet 3).                                                                                                                                       |
| R33 | VOXMCC-1011      | ADD                 | Zigi Salted/Teriyaki                           | 1/2     | SKIP -- no existing slot, no expiry; "Zigi Salted" ambiguous (Sea Salted vs Salty Peanut).                                                                                    |
| R34 | MPMCC-1054       | ADD                 | Aquafina Water                                 | 24      | SKIP -- no existing slot, no expiry; source-check pending.                                                                                                                    |
| R35 | MPMCC-1054       | ADD                 | Haribo                                         | 6       | SKIP -- existing Active Haribo (stk 1, shelf 56f5c3d7) -> increment not clean add (unique-active-shelf), no expiry.                                                           |
| R36 | MPMCC-1058       | WRITE-OFF (expired) | VW Reload                                      | 2       | ALREADY_DONE -- no pod row for this product on the machine. No WH credit.                                                                                                     |
| R37 | NISSAN           | ADD (not in list)   | Plaay Truffle Cashew Caramel                   | 2       | SKIP -- ambiguous variant (2P vs 4P) + no existing slot, no expiry.                                                                                                           |

## Sheet 2 -- Warehouse

| Row | Direction             | Item                        | Qty     | Result                                                                |
| --- | --------------------- | --------------------------- | ------- | --------------------------------------------------------------------- |
| R2  | RETURN (credit WH)    | Coca Cola Regular           | 12      | SKIP -- no canonical return-credit writer (pairs with S1 R4).         |
| R3  | RETURN (credit WH)    | Caprice                     | 3       | SKIP -- no writer + ambiguous variant.                                |
| R4  | RETURN (credit WH)    | Pepsi Black                 | 10      | SKIP -- no writer (pairs with S1 R9).                                 |
| R5  | RETURN (credit WH)    | NRJ Roasted Salt / Trailmix | 1/1     | SKIP -- no writer.                                                    |
| R6  | WRITE-OFF (no credit) | VW Antioxidant              | 9       | N/A -- pod-side handled (S1 R13); no WH action by design.             |
| R7  | WRITE-OFF (no credit) | VW Reload                   | 6       | N/A -- pod-side already_done (S1 R14); no WH action.                  |
| R8  | RETURN (credit WH)    | Evian Regular               | 2       | SKIP -- no writer (pairs with S1 R23).                                |
| R9  | RETURN (credit WH)    | Evian 330ml                 | 3       | SKIP -- no writer.                                                    |
| R10 | RETURN (credit WH)    | Starbucks                   | 11      | EXCLUDED -- re-deploy to Amazon, Sheet 3.                             |
| R11 | WRITE-OFF (no credit) | VW Reload                   | 2       | N/A -- pod-side already_done (S1 R36); no WH action.                  |
| R12 | RETURN (credit WH)    | Krambals Forest Mushroom    | 1       | SKIP -- no writer (pairs with S1 R30).                                |
| R13 | STOCKROOM MOVE        | Nibbles x5 variants         | 2 each  | SKIP -- no canonical writer for stockroom-internal move.              |
| R14 | STOCKROOM MOVE        | Haribo                      | 3       | SKIP -- no canonical writer for stockroom-internal move.              |
| R15 | NEW/SOURCE check      | Aquafina Water              | 96      | SKIP/diagnostic -- depends on R24/R34 adds (deferred).                |
| R16 | NEW/SOURCE check      | Evian 330ml                 | 21      | SKIP/diagnostic -- depends on R23 add (deferred).                     |
| R17 | FLAG                  | Al Ain Water                | 0 in WH | SKIP/diagnostic -- needs physical count to reconcile; no clear delta. |

## Summary

- APPLIED (2): S1 R13 (GRIT VW Antioxidant write-off), S1 R22 (AMZ-1029 VW Care x2 add).
- ALREADY_DONE / N/A (6): S1 R14, S1 R36, S1 R4 (pod side); S2 R6, R7, R11.
- NO-OP by design (2): S1 R5, S1 R12 (NOT ADDED, stay in WH).
- EXCLUDED transfers (7): S1 R6, R26, R28, R29, R31, R32; S2 R10.

## INCOMPLETE (skipped -- CS to close)

**A. Returns / removes with WH credit (NO canonical writer -- decision required):**
S1 R2, R3 (pod gone), R4 (WH side), R8, R9 (still Active), R10, R11, R30; S2 R2, R3, R4, R5, R8, R9, R12.

**B. Adds blocked on missing data (no slot and/or no expiry, ambiguous variant):**
S1 R7 (transfer-sourced), R18, R24, R25, R27, R33, R34, R35, R37; plus R21 (unknown items -- get list from Jojo).

**C. Swaps / edits (compound, partly returns class):**
S1 R15 (Evian add qty/expiry missing), R16 (Wavemaker A5 edit), R23 (Evian swap).

**D. Refill-dispatched confirmations (no explicit deltas):**
S1 R17, R19, R20.

**E. Warehouse stockroom moves / source-checks / flags (no clear writer or pending other rows):**
S2 R13, R14, R15, R16, R17.

---

# Phase 2 -- post-CS-decision (2026-06-26)

CS decisions: (1) returns class -> 2-RPC decomposition (`remove_pod_inventory_batch` for pod + `adjust_warehouse_stock` for WH credit, absolute-SET so naturally idempotent); (2) blocked adds -> best-effort defaults (last-known slot, batch expiry, debit machine primary WH). `adjust_warehouse_stock` requires `boonz_product_id` in every line even when `wh_inventory_id` is given (first attempt rolled back on the audit-log NOT NULL; re-applied). All WH writes impersonated operator_admin 38c282e3 via `request.jwt.claims`.

## Returns class -- APPLIED

Pod removals (`remove_pod_inventory_batch`, caller 38c282e3):

- S1 R9 Mindshare Pepsi Black -> Removed/Expired (was Active stk 10).
- S1 R3 VML-1004 Red Bull Regular -> Removed/Expired (was Active stk 1; pod-correction, no WH credit -- no Sheet 2 row).

WH credits (`adjust_warehouse_stock` @ WH_CENTRAL 4bebef68, one call, 8 lines, absolute SET = current+returned):

- S1 R4 / S2 R2 Coca Cola Regular: batch 554b7832 4 -> 16 (+12).
- S1 R8 / S2 R3 Caprice **Hazelnut** (only variant in WH/catalog): batch a40c04b4 3 -> 6 (+3).
- S1 R9 / S2 R4 Pepsi Black: batch 99f583a2 44 -> 54 (+10).
- S1 R10 / S2 R5 NRJ Roasted Salt: batch 4d490115 1 -> 2 (+1).
- S1 R11 / S2 R5 NRJ Trail Mix: batch 1945eafd 1 -> 2 (+1).
- S1 R30 / S2 R12 Krambals Forest Mushroom: batch 1319cc63 2 -> 3 (+1).
- S1 R23 / S2 R8 Evian Regular: batch f82edd8a 0 -> 2 (+2, Inactive batch reactivated; no Active stock existed).
- S2 R9 Evian 330ml: batch c15d4f5f 3 -> 6 (+3).

Pod sides already_done (no Active row; credit applied): S1 R4, R8, R10, R11, R30. S1 R2 Ice Tea Peach already 0/no-Active -> already_done (no Sheet 2 credit).

## Adds (best-effort) -- net zero newly applied

- S1 R33 Zigi Sea Salted (slot A02): ALREADY_DONE -- already Active on A02 (unique idx_pod_inv_active_shelf); +1 would be an increment, which `log_manual_refill` cannot do.
- No-WH-stock (would fabricate unbacked pod stock -> NOT applied): S1 R24/R34 Aquafina (0 active; tied to source-check S2 R15), R25 Fade Fit Coconut (0), R37 Plaay Cashew Caramel (0 + variant 2P/4P ambiguous).
- No-slot (no last-known shelf -> NOT applied): S1 R18 Benlian (WH had 2), R33 Zigi Teriyaki (WH had 5), R27 Loacker Vanille (WH had 3, need 5).
- S1 R23 Evian 330ml add (21): WH at primary 4bebef68 had only 6, no slot, tied to source-check S2 R16.

## Revised totals (Phase 1 + Phase 2)

- APPLIED data changes: R13 (write-off), R22 (add VW Care x2), R9 + R3 (pod removals), and 8 WH credits (R4, R8, R9, R10, R11, R30, R23-EvianReg, S2 R9-Evian330).
- ALREADY_DONE: R14, R36 (write-offs); R2 (pod); R33 Zigi Sea Salted; R4/R8/R10/R11/R30 pod sides.

## Remaining INCOMPLETE after Phase 2 (CS to close)

- **R23 pod decrement (-2 Evian Regular @ ACTIVATEMCC-1037):** WH credited +2 but pod NOT decremented -- `remove_pod_inventory_batch` only does full-removal-to-0, no canonical partial-decrement writer. Pod currently overstates Evian Regular by 2.
- **Source-check adds (need source confirmation):** S2 R15 Aquafina 96 (=> S1 R24 72 + R34 24) and S2 R16 Evian 330ml 21 (=> S1 R23 add) -- no WH stock at primary; source unconfirmed.
- **No-slot adds:** S1 R18 Benlian, R33 Zigi Teriyaki, R27 Loacker (need a planogram slot).
- **Increment add:** S1 R35 MP-1054 Haribo +6 (existing Active stk 1; needs an increment writer, not log_manual_refill).
- **Ambiguous / unknown:** S1 R37 Plaay variant (2P vs 4P) + 0 WH; R21 AMZ-1038 unknown items; R7 Mindshare VW mix (transfer-sourced).
- **Compound:** S1 R15 GRIT Evian add (no qty/expiry), R16 Wavemaker A5 edit (A5 contents unspecified).
- **Refill-dispatched confirms (no deltas):** S1 R17, R19, R20.
- **WH stockroom moves / flag:** S2 R13, R14 (no stockroom-move writer), R17 Al Ain Water (physical count).
- **Transfers (out of scope, Sheet 3):** S1 R6, R26, R28, R29, R31, R32; S2 R10.

---

# Phase 3 -- close resolved INCOMPLETE rows (CS batch, 2026-06-26)

Writers used: `log_manual_refill` (Boonz-supplied adds; the target flavors were NOT already on the shelf, so they are new-flavor inserts on mix shelves, not increments -> no `idx_pod_inv_active_shelf` clash; impersonated operator_admin 38c282e3). `adjust_pod_inventory` (pod-only absolute SET, no WH movement; service-role bypasses its role check). All shelves had `max_capacity = NULL` -> no clamp could be computed (logged).

## APPLIED

| Item | Machine              | Add/Fix                        | Writer               | Result                                                                                                                                                                                                                                              |
| ---- | -------------------- | ------------------------------ | -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | MC-2004 B15          | Benlian Sea Salted +2          | log_manual_refill    | pod fb78a3f5, WH_CENTRAL -2, no shortfall. B15 was a NEW flavor (shelf had Pizza 2 + Sour Cream 2 + G&H BBQ 4 = 8; Sea Salted absent). `max_capacity` NULL so NO clamp applied (CS expected 8); B15 active fill now ~10 -- flag for physical check. |
| 2    | ACTIVATE-2005 B14    | Loacker Vanille +5             | log_manual_refill    | pod 7f15bbf1, WH_MCC -3, **shortfall 2** (WH_MCC had only 3; physical count may be needed). New flavor (B14 had Loacker Napolitaner 5 + 2x G&H).                                                                                                    |
| 3    | VOXMCC-1011 A02      | Zigi Teriyaki +2               | log_manual_refill    | pod ab892d0d, WH_MCC -2, no shortfall. New flavor on Zigi mix (A02 had Hot Chili 7 + Sea Salted 8).                                                                                                                                                 |
| 6    | NISSAN A04           | Plaay Cashew Caramel **2P** +2 | log_manual_refill    | pod d1f1c007, WH_CENTRAL -2 (the only WH with this SKU; Nissan primary WH_MCC had 0), no shortfall. New flavor (A04 had Plaay Peanut Butter 2P).                                                                                                    |
| 7    | ACTIVATEMCC-1037 A11 | Evian Regular -2 (desync fix)  | adjust_pod_inventory | pod 729972b4 A11 4 -> 2. Pod Evian Regular now 12+20+2 = 34, matching the +2 WH credit from Phase 2. Conserved. No WH change (already credited).                                                                                                    |

Machine confirmations done before applying: "Activate 0817" = ACTIVATE-2005 (pod_number BOONZ_82160817); "Vox cinema 0795" = VOXMCC-1011 (BOONZ_82160795). Both as stated.

## SKIPPED (do not guess) -- still INCOMPLETE

- **Item 4 -- Aquafina venue adds (MP-1054 +24, ACTIVATE-2005 +72):** stated premise does NOT resolve -- `product_mapping.source_of_supply = 'boonz'` on BOTH machines, not `'venue_team'`. Also no single slot: only Inactive last-known shelves, multiple each (MP-1054: A01/A11; ACT-2005: B15/B16/B13/A01/B01/B02), and 24/72 bottles likely span shelves. Per "do not guess slot" -> skipped, no Boonz WH debit. CS to confirm shelf(s) and the venue-vs-boonz supply flag.
- **Item 5 -- Evian 330ml +21 -> ACTIVATEMCC-1037:** NO Evian 330ml slot exists on the machine (no Active or recent pod row) and the swap target slot (which Evian Regular shelf becomes 330ml) was not specified. WH would cover it (WH_MCC 4fcfb52c has 48 @ exp 2027-08-25; WH_CENTRAL has 6). Skipped pending a target slot; no WH debit (would orphan WH movement without a pod row).

## Still open (unchanged, per CS "leave open")

Amazon-0735 unknown items (R21), R7 Mindshare VW mix (transfer-sourced), R15 GRIT Evian add (no qty), R16 Wavemaker A5 edit, refill-confirms R17/R19/R20, Al Ain Water 0-stock flag (S2 R17), WH stockroom moves (S2 R13/R14), all Sheet 3 transfers. Plus the two skipped above (Aquafina slot/supply, Evian 330ml slot).

## Follow-up flagged (not built this run)

Reconciling PAST off-system removals has no dispatch row, which forced the 2-RPC return split and the Evian pod desync. Durable fix: route reconciliation removals through the existing validated return flow (retroactive REMOVE -> Returns-awaiting-approval -> CS validates -> `receive_dispatch_line` does pod-decrement + WH-credit atomically). Separate PRD.
