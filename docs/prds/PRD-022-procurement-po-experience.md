# PRD-022 — Procurement PO Experience v2 (supplier-centric drawer, ordered-state, PO editing)

Status: Shipped 2026-06-11 (branch feat/prd-022-po-experience eda0061, 5 migrations applied; per project memory). Doc restored by WS-E salvage.

Date: 2026-06-10. Owner: CS. Builds on Procurement Brain v3 (PRD-1..5, commit 168766e).
Scope: /app/procurement Demand tab UX + PO lifecycle. NO schema changes expected; all
writes through existing canonical RPCs.

## Problem

The Demand page now shows what to buy (sub-tabs, supplier grouping, baskets) but the
buying act itself is clumsy:

P1. After creating a PO, the ordered products stay visually identical in the list.
Operator can select them again and double-order. (The RPC already nets on_order
in `gap`, but only on next data refresh, and the UI gives no ordered cue.)
P2. PO creation is select-everything-then-create. Real flow is per-supplier: you
decide a Union Coop run, you want the Union Coop basket open NEXT TO the demand
list, tweak it, and issue.
P3. No way to edit a PO from this page. `edit_purchase_order_line` and
`cancel_po_line` exist (PRD-001/001b) but are only surfaced in /field/orders.
P4. Can't add a product the engine didn't flag (proactive top-up) to a basket
without leaving the flow.

## Design

### D1 — Ordered state (closes P1)

- Row state derives from DATA, not client memory: a SKU with `on_order > 0` renders
  grey with an "On order — PO-xxxx (n units)" chip. Source: RPC `on_order` col +
  a light reader for open PO refs per product (see D5).
- Immediately after issuing a PO from the drawer (D2): optimistic-update the
  affected rows to ordered state, then refetch.
- Ordered rows are NOT selectable for a new basket; an explicit "order more"
  action on the row bypasses (rare case), pre-warning current on-order qty.

### D2 — Supplier drawer (closes P2)

- Click a supplier group header → right-side drawer (sheet) opens:
  - Header: supplier name, last order date, open-PO count, Champions-style delay
    warning if applicable.
  - Body: draft basket pre-filled with that supplier's suggested lines from the
    demand list (qty = suggested_qty, box-rounded). Editable qty (stepper snaps to
    units_per_box multiples; manual override allowed with a one-tap "off-box" confirm).
    Unit price pre-filled from supplier_products.last_unit_price_aed, editable.
  - "Add product" search: all Active supplier_products rows for this supplier
    (name search), even if not in today's gap. Blocked products never appear.
  - Footer: lines, total units, est. total AED → [Issue PO].
- [Issue PO] calls `create_purchase_order` (single atomic call incl. driver_task),
  closes drawer, greys rows (D1). Errors (e.g. blocked product) surface inline
  per line, not as a toast.
- Basket is per-supplier client state; persists in localStorage until issued or
  cleared, so a half-built basket survives a reload.

### D3 — PO editing in-page (closes P3)

- Drawer gets two tabs: "New order" (D2) and "Open POs".
- "Open POs" lists this supplier's POs with received_date IS NULL: per line show
  product, ordered_qty, price, expiry, age (days since purchase_date).
  - Edit qty/price/expiry → `edit_purchase_order_line` (reason field, min 10 chars,
    per existing RPC contract).
  - Cancel line → `cancel_po_line` (reason required).
  - Receiving stays in /field/orders (warehouse flow) — out of scope here.
- Age > 7 days renders an amber "chase" badge (Champions rule generalized).

### D3b — Add lines to an open PO (owner-only)

- In the "Open POs" drawer tab, an "Add product" action appends lines to a
  not-yet-received PO (same po_id/po_number), qty box-snapped, driver_tasks.notes
  regenerated from open lines (DF2 mechanism).
- Gated to owner: visible/executable only for operator_admin/superadmin role
  (CS account). Other roles see the PO read-only.
- Write path: extend create_purchase_order with p_existing_po_id (append mode,
  same guardrails incl. blocked-product check) OR a sibling
  `add_purchase_order_lines` writer with identical validation — Dara/Cody decide.
  No FE direct inserts.

### D4 — Add-from-anywhere (closes P4)

- Row-level "+" on any SKU in the Boonz SKU tab adds it to its preferred supplier's
  basket (creates the basket if not open). Unassigned SKUs prompt the set-supplier
  action first (existing PRD-2 component).

### D5 — Reader RPC (only new DB object)

- `get_open_po_lines(p_supplier_id uuid DEFAULT NULL)` — read-only DEFINER returning
  open PO lines (po_id, po_line_id, boonz_product_id, product name, ordered_qty,
  price, expiry, purchase_date, supplier_id, age_days). Powers D1 chips + D3 list.
  Read-only class (c) per Constitution; register in RPC_REGISTRY.

### D7 — Line ordering + cancelled-line display (CS 2026-06-10)

- ALL PO line lists (drawer baskets, Open POs tab, /field/orders, driver_tasks.notes)
  sort by product name alphabetically, then quantity — NOT by quantity. Drivers shop
  shelf-by-shelf; alphabetical = same products together.
- driver_tasks.notes are always REGENERATED from open lines sorted by name (never
  string-patched). Same mechanism as DF2.
- Cancelled (not_purchased) lines must not render as "Pending — Not received";
  show a distinct struck-through "Cancelled" state or hide behind a toggle.
- Every PO created by any path MUST get a driver_tasks row (EATCO PO-2026-MQ7MO2T9
  was found orphaned with no task; remediated manually).

## Guardrails (unchanged, enforced)

- ALL writes via create_purchase_order / edit_purchase_order_line / cancel_po_line.
  No new writers. No direct table writes (RLS already drops direct path —
  phasef_proc_po_rls_writes_rpc_only).
- Blocked products (v_procurement_blocked_products) excluded from search and add.
- Box-multiple snapping default-on; off-box override logged in the line (notes).
- Server-side filtering + pagination; no fleet-wide fetch-then-filter under row cap.

## Acceptance criteria

1. Issue a PO from the Union Coop drawer → its rows grey instantly with PO chip;
   re-running demand shows on_order reflected; the same units cannot be added to a
   new basket without the explicit "order more" path.
2. Build a basket, reload the page → basket intact (localStorage).
3. Add a non-gap product to a basket from search; blocked products (Ritz, Sun Blast
   Cherry) unfindable.
4. Edit an open PO line's qty with reason → procurement_events + write_audit_log
   rows exist (existing dual-audit); cancel a line → outcome not_purchased.
5. Off-box qty requires explicit confirm and is visible on the PO line.
6. Zero direct writes to purchase_orders from FE (grep + RLS test).

## Defect fixes (found 2026-06-10, fold into this PRD)

DF1. PO number collision: create_purchase_order issued po_number 9140 while a
received PO already held 9140 (Union Coop, Jun 1). Fix the number allocation
(MAX+1 under lock, or a sequence) AND add a guard so a po_number can never be
reused across different po_ids. Incident remediated manually (PO-2026-ETYODP7Z
renumbered to 9144).
DF2. Cancelling PO lines does not update the driver_tasks.notes product list, so
drivers still see cancelled products. cancel_po_line (or the FE flow) must
regenerate the task notes from the remaining open lines. Incident remediated
manually (task 7f257627, PO 9142).

## Out of scope

- Receiving flow changes (/field/orders untouched).
- Forecast math (PRD-4 revisit ~2026-07-01).
- Multi-supplier PO splitting of one SKU.
