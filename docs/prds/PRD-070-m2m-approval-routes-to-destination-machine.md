# PRD-070: M2M transfer approval must move stock to the destination machine, not the warehouse

Status: Shipped 2026-07-01 (merge 11a1153 on main; pair_internal_transfer_m2m + approve_m2m_transfer + block_orphan_internal_transfer verified live in prod 2026-07-02; approve is v2 and push auto-pairs as of PRD-071 WS-B/C3).

Owner: CS. Date: 2026-07-01. Surface: backend RPC + FE approve action + dispatch-list visibility. Touches refill_dispatching, pod_inventory, warehouse_inventory, refill_plan_output (Articles 1,3,12). Dara design -> Cody review mandatory; migration FILE first; STOP for CS before apply. Idempotent, no em dashes.

## The report (CS, 2026-07-01)

A machine-to-machine (M2M) transfer receives NO physical stock into the warehouse - it is only a transfer approval. On approval the stock should move directly to the DESTINATION machine's pod with the SAME quantity and SAME expiry, and the destination leg should appear in the dispatch list.

Currently, approving the transfer credits the WAREHOUSE inventory instead of the destination machine. That is the bug.

(Separately: the Starbucks transfer Mastercard -> AMZ-1029 is already completed - not part of this fix.)

## Diagnosis (verified live 2026-07-01)

The movement logic is already M2M-aware; the bug is in the APPROVAL ROUTING / flagging, not the ledger math:

- `receive_dispatch_line` is M2M-neutral:
  - is_m2m Remove leg -> path `remove_m2m_no_wh_credit`: archives the source pod, NO warehouse credit.
  - is_m2m Refill/Add leg -> path `add_m2m_no_wh_draw`: no WH draw, and writes the DESTINATION pod_inventory (machine_id, qty, expiry). Correct.
- `acknowledge_m2m_transfer(transfer_id)` stamps wh_approved on all is_m2m lines of a transfer, no WH credit. This is the intended approve path BUT requires `m2m_transfer_id`.
- `wh_approve_remove_receipt` is for genuine machine->warehouse returns (action='Remove' only) and calls receive_dispatch_line.

Root causes to confirm + fix (evidence from live rows):

1. Several live M2M rows have `m2m_transfer_id = NULL` (e.g. WAVEMAKER-1006 -> AMZ-1029 Barebells x5, MC-2004 -> AMZ-1029 Nutella). With a NULL transfer id they cannot be acknowledged via `acknowledge_m2m_transfer`, so approval falls back to a path that can still WH-credit. The pair may also be missing the is_m2m flag on one leg (created via convert_removes_to_m2m_transfer / mark_internal_transfer, or a fresh field receipt), so `receive_dispatch_line` takes the warehouse-credit branch.
2. The destination 'Refill' leg has no operator approve path (`wh_approve_remove_receipt` refuses action<>'Remove'), so the destination-pod write / dispatch-list appearance never happens through the approve button.

## Desired behavior

Approving an M2M transfer: NO warehouse receipt. Both legs process atomically:

- Source machine pod OUT (archive the moved units).
- Destination machine pod IN with the SAME qty and SAME expiry.
- Warehouse_stock unchanged (net zero across the transfer).
- The destination leg appears in the DESTINATION machine's dispatch / pick list so the driver physically moves + refills it.

## Fix

1. **Pairing integrity.** Every M2M pair (source Remove + dest Refill) must carry `is_m2m=true` AND a shared `m2m_transfer_id` at creation (`mark_internal_transfer`, `convert_removes_to_m2m_transfer`). Backfill existing is_m2m rows that have NULL m2m_transfer_id into transfer groups (source+dest, qty-matched, same product+expiry).
2. **One canonical approve = `approve_m2m_transfer(p_transfer_id)`**: validates the pair (qty match, expiry carry-over), then runs the receive on BOTH legs - source Remove archives source pod (no WH), dest Refill writes dest pod with same qty+expiry (no WH) - and stamps wh_approved. Atomic + idempotent (re-run is a no-op).
3. **Hard guard.** No is_m2m row may ever credit warehouse via ANY path. Add an explicit guard in receive_dispatch_line (belt-and-suspenders on both Remove and Refill branches) and make `wh_approve_remove_receipt` REJECT is_m2m rows with a message pointing to `approve_m2m_transfer`.
4. **Dispatch-list visibility.** The destination Refill M2M leg must surface in the destination machine's dispatch / pick list (refill_plan_output / v_dispatch_pick_list). Confirm the stitch/dispatch bridge carries M2M dest legs and does not drop them (see the known "stitch drops M2M" issue).
5. **Dry-run the live stuck transfer.** Trace the AMZ-1029 M2M transfer end to end BEGIN..ROLLBACK before applying, to confirm WH delta = 0 and dest pod +qty at correct expiry.

## Acceptance

- Approving an M2M transfer moves the exact qty + expiry from the source machine pod to the destination machine pod; `warehouse_stock` is unchanged (assert WH delta = 0 across the transfer).
- The destination leg appears in the destination machine's dispatch list.
- No is_m2m row can credit the warehouse via any path; `wh_approve_remove_receipt` cleanly rejects is_m2m rows.
- Idempotent. The already-completed Starbucks MC-2004 -> AMZ-1029 transfer is not disturbed.
