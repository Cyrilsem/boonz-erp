---
id: RD-06
title: Per-row source selection — say where each refill line comes from (warehouse / which machine)
status: Draft
owners: { design: Dara, review: Cody, implement: Stax }
protected_entities: [pod_refill_plan, refill_plan_output, refill_dispatching]
depends_on: [FIX-1 v_live_shelf_stock aisle fix]
---

# RD-06 — Per-row source selection

## Problem

A refill line can be sourced three ways: from a warehouse (which one — `WH_CENTRAL`/`WH_MM`/`WH_MCC`),
from another machine (internal transfer / M2M), or VOX-at-venue (driver picks up at the site). Today
the engine defaults `source_origin='warehouse'`; machine→machine is possible only via
`mark_internal_transfer`, and `vox_at_venue` has no writer (the routing label is set, but there's no
clean per-row picker on the day). CS wants, per line: choose the source and, for WH, which warehouse.

## Current state

- `source_origin` column exists on `pod_refill_plan`/`refill_plan_output`/`refill_dispatching`
  (values `warehouse` | `internal_transfer` | `vox_at_venue`); `from_machine_id` for transfers.
- `mark_internal_transfer` is the canonical writer for machine→machine (creates the paired REMOVE at
  source). `push_plan_to_dispatch` v3 propagates `source_origin` + `from_machine_id` forward.
- **Missing:** per-row _warehouse_ selection (which WH), a `vox_at_venue` writer, and an FE per-row
  source picker. Multi-warehouse is live (3 warehouses) but the row doesn't say which WH it draws.

## Dara — schema design

Add an explicit source-warehouse pin to the plan row; reuse `source_origin`/`from_machine_id`.

```sql
ALTER TABLE public.pod_refill_plan
  ADD COLUMN IF NOT EXISTS source_warehouse_id uuid
    REFERENCES public.warehouses(warehouse_id) ON DELETE SET NULL;  -- which WH when source_origin='warehouse'
COMMENT ON COLUMN public.pod_refill_plan.source_warehouse_id IS
  'RD-06: operator-pinned source warehouse for a warehouse-sourced row; NULL = default WH resolution.';
```

(`warehouses` is the live multi-WH table: WH_CENTRAL/WH_MM/WH_MCC.) No new table.
RPC contracts:

- `set_refill_row_source(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_action text, p_source text, p_from_machine_id uuid DEFAULT NULL, p_source_warehouse_id uuid DEFAULT NULL, p_qty int DEFAULT NULL) RETURNS jsonb`
  — single canonical writer that sets the row's source: `warehouse` (+ which WH), `internal_transfer`
  (delegates to `mark_internal_transfer` so the paired REMOVE at the source machine is created), or
  `vox_at_venue` (the missing `mark_vox_sourced` path — set `source_origin='vox_at_venue'`, comment
  `[VOX-SOURCED]`). Refuses on `status='approved'`/locked rows (matches `mark_internal_transfer`).
- This replaces the "raw-UPDATE source_origin" anti-pattern (Hard Rule 9 in the conductor) with one
  writer. Cody handoff: Articles 1, 4, 5, 8, 12, 14.

## Cody — constitutional review

**Verdict:** ✅ Approve (this is the writer that _closes_ a known stop-ship).
**Articles:** 1 (one canonical writer for all source tagging — explicitly retires the JSONB-only /
raw-UPDATE source_origin pattern the conductor forbids), 4 (GUCs, role gate, valid source enum, WH
exists, from_machine ≠ dest), 5 (refuses on approved/locked rows), 8 (audit), 12, 14.
**Ruling:** `internal_transfer` MUST go through `mark_internal_transfer` internally (don't duplicate
the paired-REMOVE logic). `vox_at_venue` rows carry no WH draw — `source_warehouse_id` must be NULL
for non-warehouse sources (CHECK). For VOX venue machines, default the WH picker to that venue's
staging room per the two-leg model.

## Stax — FE / wiring

**Files:** `RefillPlanningTab.tsx` (a per-row "Source" control: Warehouse ▸ [WH picker] · From machine
▸ [machine picker] · VOX at venue), `_actions.ts` (`setRefillRowSource`). Show the resulting routing
label (`[TRUCK-TRANSFER from X]` / `[VOX-SOURCED]`) inline so the driver instruction is unambiguous.

```tsx
export async function setRefillRowSource(
  key: RowKey,
  source: "warehouse" | "internal_transfer" | "vox_at_venue",
  opts: { fromMachineId?: string; sourceWarehouseId?: string },
) {
  const sb = createServerClient();
  const { error } = await sb.rpc("set_refill_row_source", {
    p_plan_date: key.planDate,
    p_machine_id: key.machineId,
    p_shelf_id: key.shelfId,
    p_pod_product_id: key.podProductId,
    p_action: key.action,
    p_source: source,
    p_from_machine_id: opts.fromMachineId ?? null,
    p_source_warehouse_id: opts.sourceWarehouseId ?? null,
  });
  if (error) throw new Error(error.message);
  revalidatePath("/refill");
}
```

Rules: S1, S2, S7. Cody handoff: confirm no raw `UPDATE ... source_origin` anywhere (conductor Hard
Rule 9); confirm `push_plan_to_dispatch` still forward-propagates the chosen source to dispatch.

## Edge cases (tested)

| #   | Case                                      | Expected                                                                           |
| --- | ----------------------------------------- | ---------------------------------------------------------------------------------- |
| E1  | Source = warehouse, pick WH_MM            | `source_origin='warehouse'`, `source_warehouse_id=WH_MM`; stitch draws from WH_MM  |
| E2  | Source = internal_transfer                | Delegates to `mark_internal_transfer`; paired REMOVE created at the source machine |
| E3  | Source = vox_at_venue                     | `source_origin='vox_at_venue'`, `source_warehouse_id` NULL, `[VOX-SOURCED]` label  |
| E4  | Row already approved/locked               | Refused (source change only on pending)                                            |
| E5  | from_machine_id == dest machine           | Refused (can't transfer from self)                                                 |
| E6  | WH picked has no stock of the product     | Allowed but flags `blocked_no_wh` → hands to RD-02 PO-in-refill                    |
| E7  | Non-warehouse source with a WH id passed  | CHECK rejects (WH id only valid for warehouse source)                              |
| E8  | Source flips warehouse→transfer then back | Paired REMOVE from the transfer attempt is cleaned up (no orphan REMOVE)           |

## Acceptance tests

- A1: setting WH source pins `source_warehouse_id`; the dispatch draws from that warehouse.
- A2: internal_transfer creates exactly one paired REMOVE at the source machine (via `mark_internal_transfer`).
- A3: vox_at_venue sets the label and carries no WH draw.
- A4: locked-row source change refused.
- A5: zero raw `UPDATE ... source_origin` in code (conductor Hard Rule 9 honored); `push_plan_to_dispatch` propagates the source.
- A6: flipping source back to warehouse removes any orphan paired-REMOVE from a prior transfer choice.

## Out of scope / dependencies

Automated source optimization (cheapest/nearest WH). **Depends on FIX-1** (correct product-per-shelf so
the source applies to the right line) and reuses `mark_internal_transfer` + `push_plan_to_dispatch` v3.
