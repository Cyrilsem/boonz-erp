# Saturday 2026-05-23 Inventory Control — Discrepancy & Edit-Block Investigation

**Generated:** 2026-05-24
**Scope:** 23 products WH manager counted physically, plus the question of why edits weren't saving in the Inventory UI.

---

## TL;DR

**(b) Why edits didn't save** — root cause identified.
The Inventory UI's "edit stock value" path is mis-wired. On Saturday it generated only **status proposals** (Inactive↔Active) — it never called `apply_inventory_correction`, which is the canonical RPC for "I physically counted X." The Saturday session produced **zero rows** in `inventory_audit_log` and zero stock-value updates in `write_audit_log` — only 8 `confirm_warehouse_status_proposal` events (all with `old_wh = new_wh`). When the manager typed a count and pressed save, the FE optimistically updated the cell, then re-read from DB and the cell snapped back. This is a FE wiring fix, not a backend bug.

**(a) Why the discrepancies** — three structural causes, in order of size.

1. **PO-received batches with no physical confirmation** (~200u of the gap). When procurement receives a PO, `warehouse_inventory` gets a new row at the full `ordered_qty`. There's no separate "physically received" gate. If a delivery arrives short, damaged, or partially picked into another bin, the row stays at the optimistic number. This is the Al Ain Water +120u (PO May 22) and Snickers +72u+5u (PO May 21).
2. **Consumer_stock phantoms** (~35u in this list, ~830u system-wide per memory). BUG-006 leftover — units pinned as `consumer_stock` from old pack/receive cycles that never reconciled back to `warehouse_stock=0`. Memory note `bug_consumer_stock_drain_asymmetry` covers this; sign-off on the cleanup batch is still pending.
3. **NULL `from_wh_inventory_id` packs** (the same family we cleaned yesterday for the 68 stuck rows). Pack happens, `warehouse_stock` doesn't decrement, system continues to show stock that physically left.

---

## (a) Per-product discrepancy table

System totals as of 2026-05-24. **Δ = system − physical**, positive means system overstates.

| Product                               | Physical | Sys Active WH | Sys Consumer | Sys Total |               Δ vs Physical | Likely cause                                                                                                                                                                        |
| ------------------------------------- | -------: | ------------: | -----------: | --------: | --------------------------: | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Al Ain Water - Regular**            |        1 |           125 |            0 |       125 |                    **+124** | New PO batch `PO-MPGRN9QB-B1` for 120u snapshot 2026-05-22 not physically received in full; plus older 5u batch `PO-MOV1B4SJ-B1` (exp 2027-03-02 — your "1 unit" was from this row) |
| **Snickers - Regular**                |        2 |            85 |            5 |        90 |                     **+83** | Two new May-21 batches (`PO-2026-9126` B1+B2 = 77u) for Nov 6/7 expiry plus older 8u; physical receipt didn't match the PO numbers                                                  |
| **Vitamin Well - Reload**             |       14 |            27 |            3 |        32 |       **+13** (+5 Inactive) | RECON-\* batch from May 4 (12u STAGING D08) plus new May-20 PO (15u). The 5u Inactive row should likely stay inactive; consumer_stock phantom of 3u                                 |
| **Gatorade Cool - Blue Raspberry**    |        0 |             7 |            0 |         7 |                          +7 | Active row with 7u but physical = 0. Either depleted via NULL-source pack or never received                                                                                         |
| **Vitamin Well - Care**               |        0 |             4 |            2 |         6 |             +4 (+2 phantom) |                                                                                                                                                                                     |
| **Vitamin Well - Antioxidant**        |        0 |             4 |            0 |         4 |                          +4 |                                                                                                                                                                                     |
| **Kit-kat Regular**                   |      127 |           131 |            2 |       133 |             +4 (+2 phantom) | Drift                                                                                                                                                                               |
| **Krambals - Forest Mushroom**        |        6 |            10 |            0 |        10 |                          +4 |                                                                                                                                                                                     |
| **Pepsi - Regular** (all batches)     |        6 |             9 |           12 |        21 | +3 WH + 12 phantom consumer | The phantom 12u is the same row from yesterday's Pepsi deep dive (`7c6d72b9`, exp 2026-12-23, BUG-006 family)                                                                       |
| **Krambals - Tomato & Mozzarella**    |       33 |            35 |            2 |        37 |             +2 (+2 phantom) |                                                                                                                                                                                     |
| **Hunter - Sea Salted**               |        7 |             9 |            1 |        10 |             +2 (+1 phantom) |                                                                                                                                                                                     |
| **Hunter - Black Truffle**            |       10 |            11 |            2 |        13 |             +1 (+2 phantom) |                                                                                                                                                                                     |
| **Hunter - Sea Salt & Cider Vinegar** |       11 |            12 |            1 |        13 |             +1 (+1 phantom) |                                                                                                                                                                                     |
| **Kinder Bueno - Hazelnut**           |        0 |             1 |            2 |         3 |             +1 (+2 phantom) |                                                                                                                                                                                     |
| **Kinder Delice - Cake**              |        8 |             9 |            1 |        10 |             +1 (+1 phantom) |                                                                                                                                                                                     |
| **McVities Mini Milk**                |       36 |            37 |            2 |        39 |             +1 (+2 phantom) |                                                                                                                                                                                     |
| **Activia Honey & Oats**              |        2 |             3 |            2 |         5 |             +1 (+2 phantom) |                                                                                                                                                                                     |
| **Krambals - Creamy Cheese**          |        0 |             1 |            0 |         1 |                          +1 |                                                                                                                                                                                     |
| **Popit - Original Cola**             |       48 |            48 |            0 |        48 |                     **0 ✓** | Clean                                                                                                                                                                               |
| **Oreo Cookie - Regular**             |       36 |            28 |            2 |        30 |                      **−8** | System understates — pack with from_wh_inventory_id assignment may have overdrawn; or physical recount higher than booked                                                           |
| **Mars - Regular**                    |       36 |            32 |            0 |        32 |                          −4 | Same family                                                                                                                                                                         |
| **Extra Gum - Peppermint**            |       18 |             6 |            0 |         6 |                     **−12** | System understates by 12 — single Active row holds 6u, physical 18u suggests 12u not on system. Either an unreceived PO or a missed batch entry                                     |

**Aggregate:** system overstates by ~125u (Al Ain Water alone) + ~83u (Snickers) + smaller drift. Three products understate (Oreo −8, Mars −4, Extra Gum −12) — these are the cases where the books undercount what's physically there, opposite cause class.

### Lifecycle pattern signatures

- **Consumer_stock phantoms** (BUG-006 family): Pepsi 12, Snickers 5, Kit-Kat 2, Activia 2, Hunter Black Truffle 2, McVities Mini Milk 2, Krambals Tomato 2, Vitamin Well Care 2, Vitamin Well Reload 3, Kinder Bueno 2, Hunter Sea Salt 1, Hunter Sea Salt & Vinegar 1, Kinder Delice 1, Oreo Cookie 2 — **35u total** across this list. None of these correspond to physical units; they're stranded reservations from old pack cycles.
- **New-PO inflation** (procurement creates WH row before physical receipt closes the loop): Al Ain Water +120, Snickers +72, Vitamin Well Reload +15.
- **Pack drift** (units left WH but `warehouse_stock` not decremented — NULL `from_wh_inventory_id`): scattered 1-4u overstatements across most products.
- **Under-count** (physical > system, items present but not booked): Oreo Cookie, Mars, Extra Gum. These are likely PO additions or physical transfers that never made it into the system.

---

## (b) Why edits didn't save — root cause

Forensics from `write_audit_log` and `inventory_audit_log` over the Saturday session:

**`inventory_audit_log` on 2026-05-23 Dubai: 0 rows.** Not a single warehouse_stock quantity changed all day.

**`write_audit_log` on 2026-05-23 Dubai: 8 UPDATEs, all of this form:**

```
operation: UPDATE
actor_role: operator_admin
via_rpc: true
rpc_name: confirm_warehouse_status_proposal
old_wh = new_wh   (both unchanged)
old_consumer = new_consumer   (both unchanged)
old_status: Inactive → new_status: Active
```

So Saturday's session only **flipped status flags from Inactive to Active** — it did not change any stock counts.

The canonical RPCs that _should_ be called for "I counted X" are:

| RPC                                                                                              | Purpose                                                                             |
| ------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| `apply_inventory_correction(p_wh_inventory_id, p_new_warehouse_stock, p_reason, p_corrected_by)` | Single-row "I counted X" — overwrites `warehouse_stock`, auto-reactivates if needed |
| `adjust_warehouse_stock(p_warehouse_id, p_lines jsonb, p_reason)`                                | Bulk physical-count reconciliation                                                  |
| `reactivate_warehouse_row(p_wh_inventory_id, p_new_warehouse_stock, p_reason, ...)`              | Specifically for Inactive→Active with stock                                         |

**Neither `apply_inventory_correction` nor `adjust_warehouse_stock` was called once on Saturday.** The FE Inventory UI is not wired to either of them.

What it _is_ wired to: `confirm_warehouse_status_proposal`, which only flips the `status` column. So when WH manager:

1. Types a new count in the cell
2. Presses save
3. FE generates a status proposal (probably triggered by the row state, not the typed count)
4. Backend confirms the proposal — only `status` changes
5. FE re-reads from DB — sees the count unchanged
6. Cell snaps back to the original number

This matches your description exactly ("not saving and going back to original number, kind of blocking the transaction"). It's not a trigger blocking the write — there's literally no write being attempted on the quantity field.

### Trigger / RLS scan (cleared as the cause)

- **`trg_detect_silent_warehouse_write`** (BEFORE UPDATE) — does NOT raise. It only inserts a `monitoring_alerts` row on Inactive→Active reactivations bypassing canonical RPCs. Not a blocker.
- **`tg_propose_inactivate_on_zero_stock`** (AFTER UPDATE) — auto-confirms inactivation when stock hits zero. Doesn't block; only fires _after_ a stock change applies. Not the cause.
- **`tg_propose_reactivate_on_stock_return`** (AFTER UPDATE) — creates a proposal when Inactive→Active drifts in. Not a blocker.
- **RLS** — policy `warehouse_write_wh_inventory` permits role ∈ {warehouse, operator_admin, superadmin, manager}. The Saturday actor was `operator_admin`, so RLS was not denying.

None of the backend safeguards were the cause. The cause is upstream: the FE never sent a stock-value UPDATE.

---

## Recommendations

### Immediate (this week)

1. **FE fix — Inventory UI:** rewire the "edit count" save handler to call `apply_inventory_correction(p_wh_inventory_id, p_new_warehouse_stock, 'physical_count_2026-05-23', auth.uid())`. Stop bundling stock changes through the status-proposal flow.
2. **Re-do the Saturday count** once the FE fix is in. The session produced no quantity writes — your data is unchanged from before it. The CSV with the 23 physical counts is the source of truth; we can apply them now via `apply_inventory_correction` per row if you want a manual catch-up before the FE is fixed.
3. **For the three big overstatements** (Al Ain Water +124, Snickers +83, Vitamin Well Reload +13), the new PO batches (`PO-MPGRN9QB`, `PO-2026-9126`, `PO-MPE1PU7P`) look procurement-only — confirm with WH manager whether the physical pallets arrived. If they didn't, the PO line `received_qty` should be corrected via `edit_purchase_order_line` so the WH row recomputes correctly.

### Structural (this month)

4. **Separate PO "received-on-paper" from "physically confirmed":** add a `physical_receipt_confirmed_at` field to `warehouse_inventory` (or to a sibling table). Receiving a PO should create a `pending_physical_confirmation` row; only WH manager's confirmation should flip it to `warehouse_stock > 0` for routing.
5. **Resolve the consumer_stock phantom backlog** (~830u system-wide per memory). The 35u in this list is the visible piece; the rest is invisible at machine level. Memory `bug_consumer_stock_drain_asymmetry` has the cleanup pattern queued — needs your sign-off.
6. **Wire the NULL `from_wh_inventory_id` guardrail at pack time:** refuse to flip `packed=true` on a `refill_dispatching` row without a pinned WH source. This is the same fix that would have prevented yesterday's 68-row cleanup.

### Things I will NOT do without your sign-off

- Apply any of the 23 physical counts via `apply_inventory_correction`. The CSV is ready, but per the "no destructive changes without per-row CS approval" guardrail I'm holding.
- Modify the PO line `received_qty` for the three large PO batches.
- Touch the consumer_stock phantoms.

Say the word per item and I'll execute through the canonical RPCs with audit-traceable reasons.

---

## Audit data attached

- Saturday `write_audit_log` (8 events, all status-only confirmations)
- Saturday `inventory_audit_log` (0 events — the smoking gun)
- WH batch snapshot for the 23 products with current `warehouse_stock`, `consumer_stock`, `status`, `expiration_date`, `batch_id`
- Per-product Δ (system − physical) and likely cause classification (above)
