---
id: RD-05
title: Expiry-aware product pick at edit time (FEFO chooser)
status: Draft
owners: { design: Dara, review: Cody, implement: Stax }
protected_entities: [pod_refill_plan, refill_plan_output]
depends_on: []
---

# RD-05 — Expiry-aware product pick at edit time

## Problem

When the operator edits/adds a refill row, the system resolves which WH batch supplies it at stitch
time using FEFO — but the operator can't _see_ or _choose_ by expiry while editing. CS wants: at the
moment of picking a product/variant for a shelf, surface the available batches with their expiry and
WH stock, default to first-expiry-first-out, and let the operator deliberately pick a batch (e.g.
"drain the lot expiring in 10 days first" — the EXPIRY OPT intent, but manual on the day).

## Current state

- Expiry **reads** exist: `get_machine_slots_with_expiry`, `get_machine_expiry_detail`,
  `set_dispatch_expiry_date`, `v_effective_expiry`, WH `expiration_date`. Stitch applies FEFO at WH
  pick. `expiry-opt` skill handles batch dissolution as a strategic intent.
- **Missing:** an edit-time chooser that lists batch options by expiry for a given product+machine,
  and a way to pin the chosen batch onto the plan row so stitch honors it.

## Dara — schema design

No new table. One read RPC (options) + a nullable pin column on the plan row that stitch already
could honor (it pins WH origin via `from_wh_inventory_id` downstream).

```sql
-- pin the operator's batch choice on the pod-level plan row; NULL = let stitch FEFO decide
ALTER TABLE public.pod_refill_plan
  ADD COLUMN IF NOT EXISTS preferred_wh_inventory_id uuid
  REFERENCES public.warehouse_inventory(wh_inventory_id) ON DELETE SET NULL;
COMMENT ON COLUMN public.pod_refill_plan.preferred_wh_inventory_id IS
  'RD-05: operator-pinned WH batch (by expiry) for this row; stitch prefers it over default FEFO; NULL = FEFO.';
```

Read RPC contract:

- `get_shelf_fefo_options(p_machine_id uuid, p_boonz_product_id uuid) RETURNS jsonb`
  — STABLE/INVOKER. Returns the WH batches for the product across the machine's source warehouse(s),
  each with `wh_inventory_id`, `expiration_date`, `warehouse_stock`, `days_to_expiry`, ordered FEFO,
  with the FEFO-default flagged. Uses `warehouse_stock > 0` (per `feedback_wh_stock_column`), the
  multi-warehouse model, and `v_effective_expiry`.
  Write path: extend `edit_pod_refill_row` / `add_pod_refill_row` with an optional
  `p_preferred_wh_inventory_id uuid DEFAULT NULL` that sets the pin (verbatim diff-gate on the edit
  writer per the constitution). Cody handoff: Articles 4, 5, 8, 12.

## Cody — constitutional review

**Verdict:** ✅ Approve.
**Articles:** the read RPC is class-(c) read-only → SECURITY INVOKER is correct (Dara used it), no
GUCs, register in RPC*REGISTRY read-only helpers (Article 15). The pin write goes through the existing
`edit_pod_refill_row`/`add_pod_refill_row` canonical writers (Article 1) — a verbatim reproduction
with one added param, **diff-gated vs live before apply** (same transcription gate as the picker/edit
RPCs). Stitch honoring the pin is engine territory (refill-brain), not a new write path. No Article 6
concern (reads WH, never writes `warehouse_inventory.status`).
**Constraint:** the pin is a \_preference*; if the pinned batch is depleted by stitch time, stitch
falls back to FEFO and records a deviation — never hard-fails the row.

## Stax — FE / wiring

**Files:** `RefillPlanningTab.tsx` (the product/qty editor → a batch dropdown showing
"exp 2026-06-20 · 18 in WH (FEFO)"), `_actions.ts` (`getShelfFefoOptions`, and pass
`preferredWhInventoryId` into the existing edit/add actions).

```tsx
export async function getShelfFefoOptions(machineId: string, boonzId: string) {
  const sb = createServerClient();
  const { data, error } = await sb.rpc("get_shelf_fefo_options", {
    p_machine_id: machineId,
    p_boonz_product_id: boonzId,
  });
  if (error) throw new Error(error.message);
  return data; // render options, default = FEFO-flagged
}
```

Rules: S2, S9 (handle empty WH gracefully → show "no WH stock, raise PO" → RD-02). Optimistic edit
with rollback (S8).

## Edge cases (tested)

| #   | Case                                  | Expected                                                             |
| --- | ------------------------------------- | -------------------------------------------------------------------- |
| E1  | Multiple batches                      | Listed FEFO; nearest-expiry flagged default; operator can override   |
| E2  | Only one batch                        | Shown + auto-selected; no chooser friction                           |
| E3  | No WH stock for product               | Empty options + a "raise PO" affordance (hands off to RD-02)         |
| E4  | Pinned batch depleted before stitch   | Stitch falls back to FEFO, records a deviation; row still dispatches |
| E5  | Pinned batch expires before plan_date | Warn at pick time; block pinning an already-expired batch            |
| E6  | Multi-warehouse (VOX two-leg)         | Options scoped to the machine's source warehouse(s) only             |
| E7  | Pin then operator changes product     | Pin cleared (it referenced the old product's batch)                  |

## Acceptance tests

- A1: `get_shelf_fefo_options` returns batches ordered by expiry with `warehouse_stock>0`, FEFO default flagged.
- A2: pinning a batch sets `preferred_wh_inventory_id`; stitch sources from that batch when available.
- A3: depleted pin → FEFO fallback + deviation logged, no hard failure.
- A4: already-expired batch cannot be pinned.
- A5: edit-writer diff vs live shows only the new `p_preferred_wh_inventory_id` param.

## Out of scope / dependencies

Automated batch-dissolution targeting (that's `expiry-opt` strategic intents). No FIX-1 dependency
(operates on product+warehouse, not the shelf-aisle join).
