# Follow-up: NOOK-1019-0200-B1 A05 becomes a second Coca Cola Zero shelf

**Date raised:** 2026-06-14 (CS)
**Status:** Queued for Dara (planogram / slot change) + Cody review
**Reason:** High Coca Cola Zero velocity at NOOK-1019 (JLT). A05 was Be-Kind Cluster; CS is converting it to a second Coca Cola Zero facing (double shelf) alongside the existing A01 Coca Cola Zero.

## What was done today (2026-06-14 bag)

The 2026-06-14 dispatch for NOOK-1019 was already packed and picked up, which hard-blocks the clean swap path (skip / remove gated on picked_up, product change gated by protect_packed_dispatch_row on packed rows). So the per-bag change was recorded with the only available canonical tools:

- Added a new A05 Coca Cola Zero line, qty 14, wh-sourced (dispatch_id 99c9fbae-2fa2-4cde-85a9-b1ff6eb298cb).
- Zeroed the 6 Be-Kind A05 lines via edit_dispatch_qty (qty -> 0). They remain as packed/picked-up rows at qty 0.

Open inventory cleanup (per-row, needs CS sign-off; see chat) because edit_dispatch_qty does not move stock: 8 Be-Kind units are still committed in consumer_stock, reserved for NOOK (machine 94de9553), pinned to these WH batches:

- Be-kind Dark Chocolate: wh_inventory 6ba48bbf, 1 unit
- Be-kind Hazelnut: wh_inventory 59b253c9, 2 units
- Be-kind Hazelnut: wh_inventory 5b038d3c, 1 unit
- Be-kind Peanut Butter: wh_inventory 5ebf16d7, 1 unit
- Be-kind Peanut Butter: wh_inventory 5e3bd741, 1 unit
- Be-kind Peanut Butter: wh_inventory 2bca7bd7, 2 units

Cleanup = return those 8 units from consumer_stock back to warehouse_stock (reverse the pack reservation), and pack/load the new 14 Coca Cola Zero line (WH has 56 Coke Zero in 4bebef68).

## Permanent change to make (Dara, Cody)

Update the planogram / slot_lifecycle for NOOK-1019-0200-B1 A05 from Be-Kind Cluster to Coca Cola Zero, so future picks, engine plans, and stitch treat A05 as a Coca Cola Zero facing. Confirm shelf max_capacity for A05 as a drinks facing. After this, the per-bag manual workaround above is no longer needed; A05 plans as Coke Zero automatically.

This is also a clean test case for PRD-030 (a packed/picked-up machine should be editable without the dark-stage workaround) and the dispatch-line state integrity work.
