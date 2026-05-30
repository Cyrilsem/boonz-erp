---
id: PROGRAM-2026-06-01b
parent: PROGRAM-2026-06-01
title: Stax FE refactor — gap closure (6 deferred direct writers + new RPCs)
status: Ready-for-design
severity: P0
reported: 2026-05-30
blocks: PROGRAM-2026-06-01 O4 (the 2026-06-06 RAISE EXCEPTION flip)
source: PROGRAM-2026-06-01 execution. Reading every write site + every candidate RPC body showed the parent PRD's "3 RPCs, all mappings decided" framing held for only 5 of ~11 writers. The other 6 have NO matching canonical RPC. CS decision (2026-05-30): "ship 5 clean now, defer 6 + flip" — those 5 shipped; this PRD captures the remaining 6 so the flip can proceed once they close.
---

# Stax FE refactor — gap closure

## Status of the parent program

**Done (PROGRAM-2026-06-01):**

- O1 ✅ — 3 canonical writers live + Cody-approved + allow-listed (migration
  `phaseG_stax_canonical_writers_for_dispatch_fe_refactor`, applied 2026-05-30):
  `update_dispatch_comment`, `set_dispatch_include`, `insert_driver_remove_line`.
- O2 (partial) — 5 of ~11 direct writers closed:
  - packing:1295 include flip → `set_dispatch_include`
  - dispatching:497 driver Remove insert → `insert_driver_remove_line`
  - dispatching:624 / 669 comment → `update_dispatch_comment`
  - trips:227 comment → `update_dispatch_comment`
- Trigger remains **RAISE WARNING** (no flip).

**Blocked on this PRD:**

- O2 (full) — 6 writers below.
- O3 pre-flip soak — cannot pass while these 6 fire direct writes.
- O4 the 2026-06-06 flip — **must not ship** until all 6 close.

## The 6 deferred sites + why no existing RPC fits

| Site                    | Current write                                                                   | Why the parent PRD's mapping failed                                                                                                                                                                                                                                                                                     |
| ----------------------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| packing:1141            | `.delete().in('dispatch_id', staleSliceIds)`                                    | Hard-deletes not-yet-dispatched pre-pack slice children so `pack_dispatch_line` can spawn fresh ones. `cancel_dispatch_line` requires `dispatched=true` + bars field_staff + bars WH-bound rows. `remove_dispatch_row` only soft-removes (`include=false`) and bars drivers.                                            |
| packing:1209            | `.update({ packed:true, filled_quantity:0 })`                                   | Zero-pack a Refill line. `pack_dispatch_line` rejects `total_picked < 1` for Refill/Add actions.                                                                                                                                                                                                                        |
| packing:1267            | `.update({ packed:false, filled_quantity:0, expiry_date:null, include:false })` | Per-line unpack + exclude. No unpack RPC; `repack_machine` is machine-wide and refuses after dispatch. Also entangled with `restoreWarehouseStock` (packing/[machineId]:169), which writes `warehouse_inventory.status` DIRECTLY — an Article 6 manager-only violation that must be folded into the canonical reversal. |
| dispatching:535         | `.delete().eq('dispatch_id', id)`                                               | Driver undoes their own just-added Remove line (the insert_driver_remove_line row), pre-pickup. `remove_dispatch_row` bars drivers; `cancel_dispatch_line` needs `dispatched=true`.                                                                                                                                     |
| trips:258               | `.update({ filled_quantity, dispatched:true, comment })`                        | Dispatch-confirm flag flip with NO inventory side effects. CS decision: route through `receive_dispatch_line` (which sets dispatched/packed/picked_up/item_added=true AND materializes pod_inventory + WH credits) — a deliberate behavior fix. Comment via `update_dispatch_comment`.                                  |
| DailyDispatchingTab:298 | bulk `.update({ packed/picked_up/dispatched })` by machine+date                 | Admin bulk advance with no inventory side effects. CS decision: materialize inventory. Map picked_up → `mark_picked_up(uuid[])`, dispatched → `receive_all_dispatches_for_machine` (already called after); packed-bulk needs a contract (see below).                                                                    |

## Proposed gap RPCs (to be designed by Dara, reviewed by Cody)

These are **proposals**, not decisions — the parent PRD's lesson is that contracts
must be validated against live RPC bodies before coding. Two involve DELETE /
unpack semantics on a protected table, so per the no-destructive-changes +
propose-then-confirm rules they need explicit CS sign-off on contract shape.

1. **`delete_unstarted_dispatch_line(p_dispatch_id uuid, p_reason text)`** — hard-deletes a single `refill_dispatching` row that is `picked_up=false AND dispatched=false AND item_added=false`. Allows field_staff (the row's creator) for driver-added lines and warehouse/admin generally. Sets the GUCs; audited. Covers packing:1141 (loop over slice ids) and dispatching:535. Open question: hard DELETE vs. a `superseded=true` tombstone column — Dara to decide whether pack_dispatch_line's fresh-child spawn tolerates tombstoned rows.
2. **`zero_pack_dispatch_line(p_dispatch_id uuid)`** OR relax `pack_dispatch_line` to accept empty picks on Refill — marks `packed=true, filled_quantity=0` with no WH deduction. Covers packing:1209.
3. **`unpack_dispatch_line(p_dispatch_id uuid, p_reason text)`** — atomically reverses a pack: credits the picked WH stock back (replacing the non-canonical `restoreWarehouseStock` FE helper, closing the Article 6 hole) and flips `packed=false, filled_quantity=0, expiry_date=null, include=false`. Covers packing:1267. Highest design risk — touches warehouse_inventory.
4. **Bulk-pack path** for DDTab:298 packed case — either a `mark_packed(uuid[])` or have the admin UI iterate `pack_dispatch_line`. Needs UX input (admin "mark packed" without picks is semantically odd).

trips:258 and DDTab:298 dispatched/picked_up paths reuse EXISTING allow-listed
RPCs (`receive_dispatch_line`, `receive_all_dispatches_for_machine`,
`mark_picked_up`) — no new contract, but the inventory-materialization behavior
change must be regression-tested (watch for double-materialization).

## Sequence

1. Dara designs RPCs 1-4; Cody reviews; apply in one migration `phaseG_stax_gap_closure_writers`.
2. Refactor the 6 sites; per-file commits; tsc/build/lint green each.
3. Manual staging exercise per flow (Decision B6) + verify zero new `bypass_violation_log` rows with `rpc_name IS NULL`.
4. Pre-flip soak (parent C1). Only when it returns 0 → ship D1 flip.

## Linked

- [[PROGRAM-2026-06-01-stax-fe-refactor]] — parent (O1 + 5 sites done here)
- [[feedback_no_destructive_changes]] — governs the hard-delete RPC design
- [[feedback_warehouse_status_manager_only]] — governs the unpack_dispatch_line WH reversal (Article 6)
