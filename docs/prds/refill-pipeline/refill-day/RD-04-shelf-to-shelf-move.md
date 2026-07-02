---
id: RD-04
title: Move a product from one shelf to another to fix machine layout
status: Draft
owners: { design: Dara, review: Cody, implement: Stax }
protected_entities:
  [pod_inventory, pod_inventory_audit_log, planogram, shelf_configurations]
depends_on: [FIX-1 v_live_shelf_stock aisle fix]
---

# RD-04 — Shelf-to-shelf layout move

## Problem

On the day, the operator/warehouse manager wants to re-arrange a machine: move a fast seller to a
bigger shelf, group flavors, or correct a mis-placed product (the McVities-on-the-wrong-shelf class).
Today the shelf↔product identity lives in `pod_inventory` (and structurally in `planogram` /
`shelf_configurations`), and there is **no single "move product from shelf A to shelf B" action** —
fixing layout means hand-editing protected tables, which is exactly what we're trying to eliminate.

## Current state

- `pod_inventory` holds the Active product per shelf (we reconciled this 2026-05-31 via
  `reconcile_pod_inventory_shelf`, which archives+seeds one shelf).
- `planogram` / `shelf_configurations` define the structural layout (capacities, shelf_code).
- No `move_shelf_product`. The reconcile RPC handles one shelf's identity, not a paired A↔B move.

## Dara — schema design

No new table. A canonical writer that performs a paired, atomic move using the existing
archive-then-seed pattern on both shelves (extends `reconcile_pod_inventory_shelf`'s discipline).

```sql
-- (no DDL beyond what RD-01/RD-02 add). Optional: a thin layout-change log for audit/diff.
CREATE TABLE IF NOT EXISTS public.shelf_layout_changes (
  change_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id   uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  from_shelf_id uuid NOT NULL REFERENCES public.shelf_configurations(shelf_id) ON DELETE RESTRICT,
  to_shelf_id   uuid NOT NULL REFERENCES public.shelf_configurations(shelf_id) ON DELETE RESTRICT,
  pod_product_id uuid NOT NULL,
  moved_by     uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  moved_at     timestamptz NOT NULL DEFAULT now(),
  reason       text NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_shelf_layout_machine ON public.shelf_layout_changes (machine_id, moved_at DESC);
```

Tradeoff: a _move_ is "archive product on A, seed it on B." If B already holds a product, this is a
**swap** (two paired moves) — the RPC must handle both the empty-B and occupied-B cases explicitly.
Rejected alternative: a free `UPDATE pod_inventory SET shelf_id=...` — loses the audit trail and can
create two Active rows on one shelf (the fan-out we just cleaned). Cody handoff: Articles 1, 4, 5, 8,
12, 14.

**RPC contract:**

- `move_shelf_product(p_machine_id uuid, p_from_shelf_id uuid, p_to_shelf_id uuid, p_reason text, p_confirm boolean DEFAULT false) RETURNS jsonb`
  — `p_confirm=false`: diff (what's on A, what's on B, resulting layout). `p_confirm=true`:
  archive A's Active row, seed it on B (carrying product identity + stock 0 / live from WEIMI); if B
  was occupied, archive B's product and seed it on A (a swap). Refuses if either shelf has a linked
  `refill_plan_output` past `pending`. Writes `shelf_layout_changes` + `pod_inventory_audit_log`.
  Capacity note: if the target shelf's `max_capacity` differs, the move is allowed but surfaces a
  capacity-mismatch note (a hot product moving to a bigger shelf is the _point_).

## Cody — constitutional review

**Verdict:** ⚠️ Approve with revisions.
**Articles:** 1 (the only pod_inventory layout-move path), 4 (GUCs, role `operator_admin`/`superadmin`/
`warehouse`, valid shelves on same machine, reason ≥10 chars), 5 (status transitions via RPC; never
two Active rows per shelf — must respect the pending `uniq_active_pod_per_shelf` index from v2/PRD-015
D4), 8 (pod_inventory audit), 12, 14.
**Revisions:** (a) must enforce both shelves belong to `p_machine_id`; (b) must be atomic — a
half-move (A archived, B not seeded) is a stop-ship; (c) **does NOT edit `planogram` capacities** —
moving a product does not redefine the shelf's size; capacity changes are a separate planogram action
(out of scope here). (d) honor the locked-row guard exactly like `reconcile_pod_inventory_shelf`.

## Stax — FE / wiring

**Files:** `RefillPlanningTab.tsx` or a machine-detail view — a drag-or-select "Move to shelf…"
control on a shelf card; `_actions.ts` (`moveShelfProduct`). Show the `p_confirm=false` diff in a
confirm dialog before applying.

```tsx
export async function moveShelfProduct(
  machineId: string,
  fromShelf: string,
  toShelf: string,
  reason: string,
) {
  const sb = createServerClient();
  const { data, error } = await sb.rpc("move_shelf_product", {
    p_machine_id: machineId,
    p_from_shelf_id: fromShelf,
    p_to_shelf_id: toShelf,
    p_reason: reason,
    p_confirm: true,
  });
  if (error) throw new Error(error.message);
  revalidatePath("/refill");
  return data;
}
```

Rules: S1, S7. Cody handoff: confirm no `.from('pod_inventory')`/`.from('planogram')` write in FE.

## Edge cases (tested)

| #   | Case                                      | Expected                                                  |
| --- | ----------------------------------------- | --------------------------------------------------------- |
| E1  | Target shelf empty                        | Simple move: product now Active on B, A has no Active row |
| E2  | Target shelf occupied                     | Swap: A↔B products exchanged, exactly one Active row each |
| E3  | A and B on different machines             | Refuse (use `mark_internal_transfer` for cross-machine)   |
| E4  | Either shelf locked (rpo past pending)    | Refuse; layout move only on next plan                     |
| E5  | Target capacity smaller than source stock | Allowed + capacity-mismatch note; never silently truncate |
| E6  | Move would create 2 Active rows           | Prevented by atomic archive-then-seed + unique index      |
| E7  | Same from/to shelf                        | No-op with a clear message                                |
| E8  | field_staff attempts                      | Forbidden (role gate)                                     |

## Acceptance tests

- A1: empty-target move → B Active with the product, A empty, one `shelf_layout_changes` + audit rows.
- A2: occupied-target → clean swap, exactly one Active row per shelf afterwards.
- A3: cross-machine move refused.
- A4: locked shelf refused.
- A5: `uniq_active_pod_per_shelf` never violated after any move.
- A6: no FE direct write to `pod_inventory`/`planogram` (grep clean).

## Out of scope / dependencies

Changing shelf **capacity** (planogram edit — separate). Bulk re-planogramming. **Depends on FIX-1**
(correct product-per-shelf so the move acts on the right shelf) and on PRD-015 D4 unique index.
