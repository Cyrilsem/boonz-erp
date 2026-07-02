# Refill-Day Capability PRDs (RD-01 … RD-06)

**Author:** CS (with Claude, Dara, Cody, Stax) · **Date:** 2026-06-01 · **Status:** Draft for build

These six PRDs cover the **refill-day** operator/warehouse/driver capabilities that the v2 fix
batch (`PRD_refill_v2_fixes.md`, the 2026-06-01 migrations) does **not** address. The v2 batch
fixes reliability/control plumbing and engine correctness (FIX-1…10, F1–F7). This set is the
_human-in-the-loop control surface on the day of the refill_.

Grounding (live DB `eizcexopcuoycuosittm`, verified 2026-06-01):

- Already live: `edit_pod_refill_row`, `swap_pod_refill_row`, `add_pod_refill_row`,
  `stop_pod_refill_row`, `mark_internal_transfer`, `void_refill_plan`, `reschedule_refill_plan`,
  `reconcile_pod_inventory_shelf`, expiry reads (`get_machine_slots_with_expiry`,
  `get_machine_expiry_detail`, `set_dispatch_expiry_date`), `driver_confirm_remove`, `add_stock`.
- v2 files written, pending apply: `reset_and_restitch`, `commit_refill_plan`, `set_swaps_enabled`,
  dedup/stitch-fallback/qty-cap/subset-finalize.
- **Not built (this PRD set):** ad-hoc plan/machine creation, PO-in-refill, driver self-service
  loop, shelf-to-shelf layout move, expiry-aware product pick at edit time, per-row source picker.

| PRD   | Function                             | One-line                                                           | Backing today                |
| ----- | ------------------------------------ | ------------------------------------------------------------------ | ---------------------------- |
| RD-01 | Create plan / add machine on the day | `create_refill_plan`, `add_machine_to_plan`                        | none                         |
| RD-02 | PO-in-refill                         | `request_po_in_refill` + receive + live refresh                    | none (separate weekly flow)  |
| RD-03 | Driver self-service                  | `driver_report_dispatch_outcome`, `driver_propose_adjustment`      | only `driver_confirm_remove` |
| RD-04 | Shelf-to-shelf layout move           | `move_shelf_product`                                               | none                         |
| RD-05 | Expiry-aware product pick at edit    | `get_shelf_fefo_options` + edit-row expiry param                   | expiry reads only            |
| RD-06 | Per-row source selection             | extend `edit_pod_refill_row` source args + `set_refill_row_source` | machine→machine only         |

Build governance for every PRD: **Dara designs → Cody reviews → apply after sign-off → Stax wires
FE/driver-app → Cody reviews diff.** New writers role-gated with service-role bypass
(`auth.uid() IS NULL`). Forward-only migrations. Verbatim reproduction of any core writer is
diff-gated vs live before apply. Driver = `field_staff` role; warehouse manager = `warehouse`.

Dependency note: RD-02/RD-06 read product-per-shelf, so they **depend on v2 FIX-1**
(`v_live_shelf_stock` aisle off-by-one) being fixed first, or they inherit the wrong-shelf bug.

**Sequence:** this RD set is **Layer 2** in the master sequence (`../BUILD-ORDER.md`). It runs
**after PRD-UNIFY** (Layer 1, the brain) is applied — the edit / source / expiry actions here read the
unified `decision` PRD-UNIFY produces. Goal to run this set: `GOAL_refill_day.md`. Full chain:
FIX-1 ✅ → PRD-UNIFY → **RD-01…06 (here)** → learning loop.
