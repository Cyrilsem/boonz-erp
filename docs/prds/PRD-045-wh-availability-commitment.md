# PRD-045 - Warehouse availability & commitment correctness

**Status:** ✅ APPLIED 2026-06-21 (backend P0 + P2 FE availability/oversubscribed SHIPPED to prod, deploy `37ce14d`). Read-model only; no stock mutation. swaps_enabled untouched (false).

## EXECUTION LOG (2026-06-21)

- **P0** `prd045_p0_wh_commitment_correctness` APPLIED. The committed/available model lives in `v_dispatch_availability` (consumed by `v_dispatch_pickable`); `v_wh_pickable` is raw pickable (engine input) and was left unchanged. Fix to `reserved_by_earlier`: (a) qualifying line now also requires NOT cancelled, NOT skipped, pack_outcome <> not_filled (dead lines released); (b) `= earlier-over(product,date) MINUS earlier-over(product,date,machine)` = earlier OTHER-machine commitment only (self-commit removed, FEFO running fairness kept). New `oversubscribed` flag; `available_qty` floors at 0. No table change. Cody Art 1/2/4/12/16 (canonical dispatch-availability object corrected, not parallelized).
- **Verified no function consumes** `v_dispatch_availability`/`v_dispatch_pickable` (engine/stitch/picker untouched).
- **Tests (BEGIN..ROLLBACK, product with 12 WH, M1=VOXMCC, M2=ACTIVATE):** T1 available=full ✓; T3 cancelled / T4 packed / skip / not_filled NOT committed (M1 available=3) ✓; T9 self-commit reserved=0 ✓; T10 oversubscribed (q20 vs 12 → available 12 + flag) ✓; T5/T8 cross-machine counted once, sum ≤ stock, no negative ✓; T6 expired excluded by v_wh_pickable ✓; T7 stocked product pickable ✓.
- **P2 FE SHIPPED 2026-06-21** (deploy commit `37ce14d`, boonz-erp.vercel.app): packing page now reads `v_dispatch_pickable.available_qty` (corrected committed-aware) + `oversubscribed`; shows "N available to pick" (green ✓) instead of the false "no pickable stock", and an **Oversubscribed** badge (⚑ icon + text, status-not-color-only) when demand>stock. Build green; prod deploy success. (Note: the page's legacy client-side per-batch committed math still exists alongside; full removal in favour of the view's `available_qty` is a follow-up.)
  **Owner:** CS (cyrilsem@gmail.com)
  **Created:** 2026-06-21
  **Severity:** HIGH. False "out of stock" blocks legitimate refills.

## 0. Problem (observed 2026-06-21)

Products with real warehouse stock show **Available 0** on the packing page ("All batches fully committed - no stock pickable for this machine"), e.g. a shelf reading `WH: 7u | Committed: 4 | Available: 3` while another reads `WH: 1u | Committed: 1 | Available: 0`. Hunter Hot Chili had 8 units in WH yet could not be refilled. Manual line-adds during the day made commitment worse because each new line reserved stock.

## 1. Root cause (decided diagnosis)

`available = wh_active_stock - committed`, but `committed` is over-counted:

1. It includes lines that should NOT hold a reservation: `skipped`, `not_filled`, `cancelled`, and already-`packed` lines (packed stock already left the WH, should debit not double-reserve).
2. Re-stitched / re-added lines double-count against the same batch.
3. No FEFO batch allocation, so a machine is told "no pickable batch" when an earlier-expiry batch is free.
4. A machine's availability calc can count its own pending line as "committed against itself."

## 2. The change (decided, no options)

Redefine the commitment model in `v_wh_pickable` / `v_dispatch_pickable`:

1. **Pickable WH stock** = `warehouse_inventory` rows with `status='Active'`, `warehouse_stock > 0`, not expired (`expiration_date > CURRENT_DATE` or NULL), in a warehouse that serves the machine (`primary_warehouse_id`, else central).
2. **Committed** (per boonz_product_id, per pickable warehouse) = SUM(quantity) of dispatch lines that are ALL of: not cancelled, not skipped, not not_filled, not packed, and `action IN ('Refill','Add New')`. Packed lines are excluded (their units already moved). Remove/M2W never commit inbound stock.
3. **Available for machine M** = pickable_stock - committed_by_OTHER_machines. A machine never competes with its own line for what it is allowed to pick.
4. **FEFO**: allocate earliest `expiration_date` batch first; expose per-batch `available` so the FE shows the batch the driver should pull.
5. Skipping / cancelling / not-filling a line releases its commitment immediately (the views recompute; no stale reservation).
6. Never return negative available (floor at 0); surface a distinct `oversubscribed` flag when demand > stock so it is visible, not silently zeroed.

## 3. Testing rules (all must pass)

| #   | Test                              | Expected                                                                           |
| --- | --------------------------------- | ---------------------------------------------------------------------------------- |
| T1  | product 8 in WH, no other claims  | available = 8                                                                      |
| T2  | skip a competing line             | that product's available rises by the skipped qty on re-query                      |
| T3  | cancelled line                    | not counted in committed                                                           |
| T4  | packed line                       | not counted in committed (units already moved)                                     |
| T5  | two machines compete, 1 batch     | FEFO allocates earliest expiry; no negative available; sum of allocations <= stock |
| T6  | expired batch                     | excluded from pickable                                                             |
| T7  | Hunter Hot Chili replay (8 in WH) | now pickable for the machine                                                       |
| T8  | re-stitch / re-add same product   | no double-count of committed                                                       |
| T9  | own-line self-commit              | machine's own pending line does not reduce its own availability                    |
| T10 | oversubscribed                    | demand 10 vs stock 6 -> available 6 + oversubscribed flag, not silent 0            |

## 4. Phasing / gates

- **P0** Dara: redesign the two views (forward CREATE OR REPLACE VIEW; no table change). Confirm they are read-only (no writes). Cody review (Articles 1,2,4,12; views must not bypass RLS intent).
- **P1** Apply views; run T1-T10 against live data snapshots (read-only) + a BEGIN..ROLLBACK scenario harness. STOP only on a failing test.
- **P2** Stax: FE consumes the corrected `available` + per-batch FEFO + `oversubscribed` badge.
- Depends on PRD-044 (skip/not_filled/partial must release commitment). No engine change.
