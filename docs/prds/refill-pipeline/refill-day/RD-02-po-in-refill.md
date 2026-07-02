---
id: RD-02
title: PO-in-refill — create PO, receive, and refresh inventory inline when a product is unavailable
status: Draft
owners: { design: Dara, review: Cody, implement: Stax }
protected_entities:
  [
    warehouse_inventory,
    warehouse_inventory_audit_log,
    refill_plan_output,
    refill_dispatching,
  ]
depends_on: [FIX-1 v_live_shelf_stock aisle fix]
---

# RD-02 — PO-in-refill (procure + receive + refresh, inline)

## Problem

During the refill, a planned row frequently shows the product **not available in the warehouse**
(stitch deviation / procurement alert). Today the operator must leave the refill, run the separate
weekly procurement flow to raise a PO, physically receive stock, and only then re-run the plan — a
multi-tool detour that is the single biggest time sink on refill day. CS wants: from inside the
refill, raise a PO for the short product, mark it received, and have warehouse inventory + the plan
row refresh in one motion.

## Current state

- `weekly-procurement` skill writes `purchase_orders` + `driver_tasks` atomically (the only PO path).
- `receive_dispatch_line` receives dispatched stock; `add_stock` is the canonical pod/WH stock writer
  (shipped 2026-05-30). `reactivate_warehouse_row` un-archives a WH row. `edit_purchase_order_line` /
  `cancel_po_line` exist.
- **No inline "refill saw a shortage → PO → receive → refresh" path.** `warehouse_inventory.status`
  is manager-only (Article 6) — receiving must propose, not silently flip.

## Dara — schema design

Reuse `purchase_orders`, `driver_tasks`, `warehouse_inventory`. Add a thin link so a PO raised from
the refill is traceable back to the plan row, and a staging proposal for the receive (Article 6).

```sql
ALTER TABLE public.purchase_orders
  ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'weekly'
    CHECK (origin IN ('weekly','refill_inline')),
  ADD COLUMN IF NOT EXISTS origin_plan_date date,            -- the refill date that raised it
  ADD COLUMN IF NOT EXISTS origin_boonz_product_id uuid;     -- the short product
CREATE INDEX IF NOT EXISTS idx_po_origin_refill
  ON public.purchase_orders (origin_plan_date) WHERE origin = 'refill_inline';
-- WH receive stays manager-confirmed: reuse warehouse_inventory_status_proposal (Article 6).
```

Tradeoff: we do NOT auto-add `warehouse_inventory` rows on PO create; stock only appears on
_received_, via the existing `warehouse_inventory_status_proposal` → manager confirm path. Rejected
alternative: auto-inserting WH stock on PO submit (would let unreceived stock be planned — phantom
inventory, the BUG-001 class). Cody handoff: Articles 1, 4, 6, 8, 12.

**RPC contracts:**

- `request_po_in_refill(p_plan_date date, p_boonz_product_id uuid, p_qty int, p_supplier text, p_reason text) RETURNS jsonb`
  — rounds `p_qty` up to box multiple (`procurement_min_order_qty`), writes a `purchase_orders`
  line (`origin='refill_inline'`) AND the paired `driver_tasks` row atomically (mirrors
  weekly-procurement), links `origin_plan_date`/`origin_boonz_product_id`.
- `receive_po_in_refill(p_po_line_id uuid, p_received_qty int, p_expiration_date date, p_confirm boolean) RETURNS jsonb`
  — `p_confirm=false`: returns the WH-row diff. `p_confirm=true`: writes a
  `warehouse_inventory_status_proposal` (manager confirms in Inventory UI) OR, if caller role is
  `warehouse`, applies via `add_stock` + records receipt. Never silent-flips `warehouse_inventory.status`.
- After receive, the refill row is re-resolvable: caller re-runs `restitch_after_edits` (RD depends on
  v2 FIX-7) so the previously-blocked row now dispatches.

## Cody — constitutional review

**Verdict:** ⚠️ Approve with revisions.
**Articles:** 1 (PO + driver*tasks via one canonical writer, never raw insert — same rule
weekly-procurement follows), **6 (CRITICAL — `warehouse_inventory.status` is manager-only; receive
must route through `warehouse_inventory_status_proposal` for non-warehouse callers, confirmed in the
Inventory UI; only the `warehouse` role may apply directly via `add_stock`)**, 4 (GUCs, role gate,
qty>0, box-multiple), 8 (PO + WH audit), 12 (forward-only).
**Revisions required:** (a) `receive_po_in_refill` must not bypass the Article-6 proposal path for
operator/superadmin callers; (b) no `warehouse_inventory` row may be created on PO \_create*, only on
confirmed _receive_ — otherwise phantom stock re-enters planning.

## Stax — FE / wiring

**Files:** `RefillPlanningTab.tsx` (a "Procure" action on any row flagged `blocked_no_wh` →
PO modal: supplier, qty prefilled to the gap, reason), `_actions.ts`
(`requestPoInRefill`, `receivePoInRefill`), reuse the `/field/orders` receive surface for the
manager confirm. n8n: none new — the existing PO→driver-task notifier picks up the new row (Rule S5,
Function mode).

```tsx
// _actions.ts ('use server')
export async function requestPoInRefill(
  planDate: string,
  boonzId: string,
  qty: number,
  supplier: string,
  reason: string,
) {
  const sb = createServerClient();
  const { data, error } = await sb.rpc("request_po_in_refill", {
    p_plan_date: planDate,
    p_boonz_product_id: boonzId,
    p_qty: qty,
    p_supplier: supplier,
    p_reason: reason,
  });
  if (error) throw new Error(error.message);
  revalidatePath("/refill");
  return data;
}
```

Rules: S1, S3 (service-role only server-side), S7. Cody handoff: confirm no FE `.from('purchase_orders')`/`.from('warehouse_inventory')` write.

## Edge cases (tested)

| #   | Case                                                    | Expected                                                                                    |
| --- | ------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| E1  | qty below box multiple                                  | Rounded up to full box (`procurement_min_order_qty`); PO reflects rounded qty               |
| E2  | Operator (non-warehouse) receives                       | Writes a `warehouse_inventory_status_proposal`; stock NOT live until manager confirms       |
| E3  | Warehouse manager receives                              | `add_stock` applies; WH row live with the entered expiry                                    |
| E4  | Duplicate PO for same product+date                      | Warn + offer to edit the existing inline PO instead of a second one                         |
| E5  | Receive a qty > ordered                                 | Refuse (or flag over-receipt for manager); never silently inflate                           |
| E6  | VOX-sourced product (not Boonz-procured)                | Block PO; surface "VOX-sourced, raise with VOX team" (per `reference_vox_sourced_products`) |
| E7  | Product still blocked after PO created but not received | Row stays `blocked_no_wh`; no dispatch line until receive + restitch                        |
| E8  | Receive then no restitch                                | Row remains blocked until `restitch_after_edits` runs (documented, not silent)              |

## Acceptance tests

- A1: `request_po_in_refill` writes one `purchase_orders` line (`origin='refill_inline'`, linked
  plan_date/product) AND its paired `driver_tasks` row, atomically (no orphan task).
- A2: qty rounds up to the box multiple.
- A3: operator receive creates a proposal, not a live WH row; manager confirm makes it live.
- A4: warehouse-role receive applies via `add_stock` with the entered expiry; WH audit row written.
- A5: `warehouse_inventory.status` is never written by these RPCs outside the Article-6 path (grep + trigger check).
- A6: after receive + `restitch_after_edits`, the previously `blocked_no_wh` row dispatches.

## Out of scope / dependencies

Supplier catalog management; price negotiation. **Depends on FIX-1** (correct product-per-shelf so the
shortage is attributed to the right product) and on v2 FIX-7 `reset_and_restitch`/`restitch_after_edits`.
