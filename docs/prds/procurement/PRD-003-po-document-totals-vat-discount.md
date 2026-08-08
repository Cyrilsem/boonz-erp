# PRD-003 — PO Document Totals: VAT, Discounts, Adjustments, Grand Total

**Status:** DRAFT
**Date:** 2026-08-08
**Author:** CS (request from procurement team)
**Area:** Procurement / Receiving
**Depends on:** PRD-001 (WH edit submitted PO with audit), PRD-002 (per-line edit lock)

---

## 1. Summary

Add a document-level totals block to the Purchase Order: **discount, VAT, other adjustments, and grand total**, captured at receiving and correctable afterwards with an audit trail. The PO grand total then reconciles to the supplier invoice to the fils, without distorting per-unit product cost.

---

## 2. Problem

`purchase_orders` is a **line-level table only**. There is no PO header row. `po_id` is repeated across lines, and the "Total" shown on the PO card is a client-side `SUM(total_price_aed)` computed in the browser.

Consequence: there is nowhere to record anything that exists at the _document_ level — VAT, a trade or promotional discount, a delivery charge, a credit note, or the supplier's grand total.

The live example, PO-2026-9260 (Merich Global Wholesalers):

|                 | Boonz PO         | Merich invoice |
| --------------- | ---------------- | -------------- |
| Goods (ex-VAT)  | 254.77           | 254.78         |
| VAT @ 5%        | — (not captured) | 12.74          |
| **Grand total** | **254.77**       | **267.52**     |

The team cannot make these match, and the only tool available to them today is to inflate line prices until the total lands on 267.52.

**That workaround must not happen.** `price_per_unit_aed` feeds `warehouse_inventory` valuation → COGS → the VOX / MAFE Statement of Account. Pushing recoverable VAT into unit cost inflates COGS on every partner settlement and understates net client revenue. Line prices stay ex-VAT, permanently.

### 2.1 A second finding surfaced while scoping this

The 0.01 gap above is **not** a VAT problem. Actual stored data for PO-2026-9260:

| Product            | Qty | Stored unit price | Stored line total | Qty × 6.71 |
| ------------------ | --- | ----------------- | ----------------- | ---------- |
| Activia Honey      | 16  | 6.7094            | 107.35            | 107.36     |
| Activia Strawberry | 17  | 6.7100            | 114.07            | 114.07     |
| YoPRO Choc Milk    | 5   | 6.6700            | 33.35             | 33.35      |

The receiving screen captures **"total paid for N units"** and back-computes the unit price (`107.35 / 16 = 6.7094`). The supplier priced at a flat 6.71/unit, so their line is 107.36. One fils entered short on one line, compounded by 1.05, produces the 267.51 vs 267.52 mismatch.

This is exactly why the VAT field must be **editable** rather than hard-computed, and why a **variance indicator against the supplier's stated grand total** is worth more than the VAT field itself: it turns a silent penny drift into a visible flag at the moment of receipt.

---

## 3. Invariants (non-negotiable)

- **I-1.** `purchase_orders.price_per_unit_aed` and `total_price_aed` remain **ex-VAT**. No RPC in this PRD writes to `purchase_orders`.
- **I-2.** VAT is recoverable input VAT (Boonz is VAT-registered). It is a receivable, never an inventory cost. It never reaches `warehouse_inventory`, COGS, or any Statement of Account.
- **I-3.** Document totals are **presentational and financial-reconciliation only**. No refill, packing, dispatch, stitch or forecasting path reads them.
- **I-4.** A PO with no totals row behaves exactly as it does today (subtotal only). The feature is additive and backward-compatible.

---

## 4. Data model

New table. One row per `po_id`.

```sql
CREATE TABLE public.purchase_order_totals (
  po_id                   text PRIMARY KEY,

  -- snapshot of SUM(total_price_aed) over non-cancelled lines at time of entry.
  -- stored so we can detect that lines changed after totals were agreed.
  subtotal_ex_vat_aed     numeric(12,2) NOT NULL,

  discount_aed            numeric(12,2) NOT NULL DEFAULT 0 CHECK (discount_aed >= 0),
  discount_label          text,

  vat_rate                numeric(6,4)  NOT NULL DEFAULT 0.05
                            CHECK (vat_rate >= 0 AND vat_rate <= 1),
  vat_aed                 numeric(12,2) NOT NULL DEFAULT 0 CHECK (vat_aed >= 0),

  -- signed: positive = delivery/handling charge, negative = credit note / rounding
  other_adjustment_aed    numeric(12,2) NOT NULL DEFAULT 0,
  other_adjustment_label  text,

  -- computed, never free-typed. kept as a stored column for reporting.
  grand_total_aed         numeric(12,2) NOT NULL,

  -- what the supplier's paper says. optional. drives the variance chip.
  supplier_invoice_number text,
  supplier_invoice_date   date,
  supplier_invoice_total_aed numeric(12,2),

  source                  text NOT NULL DEFAULT 'receiving'
                            CHECK (source IN ('receiving','edit','backfill')),
  created_at              timestamptz NOT NULL DEFAULT now(),
  created_by              uuid,
  last_edited_at          timestamptz,
  last_edited_by          uuid,

  CONSTRAINT po_totals_grand_total_coherent CHECK (
    grand_total_aed = subtotal_ex_vat_aed - discount_aed + vat_aed + other_adjustment_aed
  )
);
```

**Notes**

- No FK to `purchase_orders(po_id)` is possible — `po_id` is not unique there. The RPC validates existence with an `EXISTS` check instead.
- `other_adjustment_label` is required by the RPC whenever `other_adjustment_aed <> 0`. Same for `discount_label` when `discount_aed > 0`. An unexplained adjustment is how reconciliation rots.
- `grand_total_aed` is derived, enforced by CHECK. Users never type it. This guarantees the document can never be internally inconsistent.
- `supplier_invoice_total_aed` is what they read off the paper. `grand_total_aed − supplier_invoice_total_aed` is the **variance**, surfaced but never blocking.

### 4.1 Companion view

```sql
CREATE VIEW public.v_po_document_totals AS
SELECT
  l.po_id,
  SUM(l.total_price_aed) FILTER (WHERE l.purchase_outcome IS DISTINCT FROM 'cancelled')
    AS live_subtotal_ex_vat_aed,
  t.subtotal_ex_vat_aed,
  t.discount_aed, t.discount_label,
  t.vat_rate, t.vat_aed,
  t.other_adjustment_aed, t.other_adjustment_label,
  t.grand_total_aed,
  t.supplier_invoice_number, t.supplier_invoice_date, t.supplier_invoice_total_aed,
  ROUND(COALESCE(t.grand_total_aed,0) - COALESCE(t.supplier_invoice_total_aed,0), 2)
    AS invoice_variance_aed,
  -- true when lines were edited after totals were captured
  (t.po_id IS NOT NULL AND t.subtotal_ex_vat_aed IS DISTINCT FROM
     SUM(l.total_price_aed) FILTER (WHERE l.purchase_outcome IS DISTINCT FROM 'cancelled'))
    AS totals_stale
FROM public.purchase_orders l
LEFT JOIN public.purchase_order_totals t ON t.po_id = l.po_id
GROUP BY l.po_id, t.po_id;
```

`totals_stale` is the safety net for the PRD-002 edit path: if someone edits a line price after totals were set, the card shows a "totals out of date" chip instead of quietly presenting a wrong grand total.

---

## 5. RPCs

Both follow the established `edit_purchase_order_line` pattern exactly: role gate, GUC (`app.via_rpc` / `app.rpc_name`), `procurement_events` + `write_audit_log`, jsonb return.

### 5.1 `set_po_document_totals(...)` — upsert

```
set_po_document_totals(
  p_po_id                     text,
  p_discount_aed              numeric DEFAULT 0,
  p_discount_label            text    DEFAULT NULL,
  p_vat_aed                   numeric DEFAULT NULL,   -- NULL = auto @ vat_rate
  p_vat_rate                  numeric DEFAULT 0.05,
  p_other_adjustment_aed      numeric DEFAULT 0,
  p_other_adjustment_label    text    DEFAULT NULL,
  p_supplier_invoice_number   text    DEFAULT NULL,
  p_supplier_invoice_date     date    DEFAULT NULL,
  p_supplier_invoice_total_aed numeric DEFAULT NULL,
  p_reason                    text    DEFAULT NULL,   -- required on UPDATE only
  p_source                    text    DEFAULT 'receiving'
) RETURNS jsonb
```

Behaviour:

1. Role gate: `warehouse`, `operator_admin`, `manager`, `superadmin`. Anything else → raise.
2. `EXISTS` check on `purchase_orders.po_id`; raise if unknown.
3. Recompute `subtotal_ex_vat_aed` live from non-cancelled lines. Never trust a client-supplied subtotal.
4. `v_vat := COALESCE(p_vat_aed, ROUND((subtotal - discount) * p_vat_rate, 2))`.
5. Label guards: `discount_aed > 0` requires `discount_label`; `other_adjustment_aed <> 0` requires `other_adjustment_label`.
6. `grand_total := subtotal - discount + vat + other`.
7. If a row already exists → this is an **edit**: require `p_reason` ≥ 10 chars (same rule as `edit_purchase_order_line`), set `source='edit'`, stamp `last_edited_*`.
8. Sanity warning (returned, **not** raised): if `p_vat_aed` was supplied and deviates from the auto figure by more than 1.00 AED, return `vat_override_warning`. Human overrides for real reasons (mixed-rate or zero-rated goods) must stay possible.
9. Write `procurement_events` (`po_totals_set` / `po_totals_edited`) with before/after, and `write_audit_log`.
10. Return the full totals object plus `invoice_variance_aed` and any warnings.

### 5.2 `get_po_document_totals(p_po_id text)` — read

Thin wrapper over `v_po_document_totals` for one PO. Returns the totals, the live subtotal, `totals_stale`, and `invoice_variance_aed`. Lets the FE render the block in one call rather than re-deriving arithmetic client-side (which is how we got here).

---

## 6. Frontend

### 6.1 Receiving — `src/app/(field)/field/receiving/[poId]/page.tsx`

New **Invoice Totals** card below the line list, above Confirm. Fields, top to bottom:

| Field                       | Behaviour                                                                                                                                     |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Subtotal (ex-VAT)           | read-only, live from received lines                                                                                                           |
| Discount                    | input, default 0, label required if > 0                                                                                                       |
| VAT (5%)                    | input, **pre-filled** with `round((subtotal − discount) × 0.05, 2)`, freely editable, shows "auto" vs "edited" state                          |
| Other adjustment            | input, default 0, signed, label required if ≠ 0                                                                                               |
| **Grand Total**             | read-only, bold, computed                                                                                                                     |
| Supplier invoice no. / date | optional text + date                                                                                                                          |
| Supplier invoice total      | optional input                                                                                                                                |
| Variance                    | chip. Green ✓ when 0.00. Amber when \|variance\| ≤ 0.10 ("rounding"). Red when > 0.10, with the hint "check line prices or add an adjustment" |

The variance chip is advisory. It **never blocks** Confirm — receiving must not be gated on a paperwork mismatch, and a driver standing at the warehouse door will not thank us for it.

Submitted as one `set_po_document_totals` call **after** `receive_purchase_order` succeeds. If the totals call fails, receiving still stands; show a retry affordance.

### 6.2 PO card — `src/app/(field)/field/orders/page.tsx`

Replace the single `Total` footer (currently `SUM` over `total_price_aed`) with the full breakdown when a totals row exists, and the current single line when it does not:

```
Subtotal                254.78 AED
Discount                  0.00 AED
VAT (5%)                 12.74 AED
Grand Total             267.52 AED   ✓ matches invoice
```

Add a `totals_stale` chip when lines changed after totals were captured.

### 6.3 Procurement page — `src/app/(app)/app/procurement/page.tsx`

Same footer treatment on the PO detail view. Manager-role edit entry point for post-receipt correction, routing to `set_po_document_totals` with a reason.

### 6.4 Not in scope for v1

Per-line VAT rates (zero-rated vs standard-rated mixes). Every current supplier is flat 5% or exempt-at-document-level. If a mixed-rate supplier appears, the editable VAT field already absorbs it; per-line rates can come later.

---

## 7. Migration & backfill

- One migration: table + view + two RPCs + RLS + grants.
- **No backfill.** Historical POs keep showing subtotal-only. Retro-entering VAT on hundreds of closed POs from memory would manufacture false precision.
- Optional follow-up if finance wants it: a `source='backfill'` bulk path fed from actual supplier invoices, run deliberately, never inferred.

## 8. RLS

Read: any authenticated role that can already read `purchase_orders`.
Write: denied at table level; all writes go through the SECURITY DEFINER RPCs. Consistent with Article 3 (no direct table writes from FE).

---

## 9. Test plan

| #   | Case                                             | Expected                                                        |
| --- | ------------------------------------------------ | --------------------------------------------------------------- |
| T1  | PO-2026-9260, subtotal 254.77, VAT auto          | VAT 12.74, grand 267.51, variance −0.01 amber vs invoice 267.52 |
| T2  | Same, correct Activia Honey line to 107.36 first | subtotal 254.78, VAT 12.74, grand 267.52, variance 0.00 green   |
| T3  | Discount 20.00 with no label                     | RPC raises                                                      |
| T4  | Discount 20.00, label "Promo"                    | VAT auto on 234.78, grand recomputed                            |
| T5  | VAT typed as 0 (exempt supplier)                 | accepted, `vat_override_warning` returned, grand = subtotal     |
| T6  | Edit totals with no reason                       | RPC raises (≥10 chars)                                          |
| T7  | Edit a line price after totals set               | `totals_stale = true` on the view; card shows chip              |
| T8  | PO with no totals row                            | card renders exactly as today                                   |
| T9  | Driver role calls the RPC                        | forbidden                                                       |
| T10 | Confirm receiving with red variance              | succeeds; variance recorded                                     |
| T11 | `warehouse_inventory` cost after receipt         | unchanged by VAT — assert equal to ex-VAT unit price            |

**T11 is the one that matters.** It is the regression test that protects every partner settlement.

---

## 10. Effort

| Piece                               | Estimate      |
| ----------------------------------- | ------------- |
| Migration: table, view, RLS, grants | 0.5 day       |
| Two RPCs + audit wiring             | 0.5 day       |
| Receiving totals card               | 0.5 day       |
| PO card + procurement footer        | 0.5 day       |
| Test pass incl. T11 regression      | 0.5 day       |
| **Total**                           | **~2.5 days** |

Low risk: additive, no writes to protected entities, no path into refill/packing/dispatch.

---

## 11. Open questions for CS

- **Q1.** Confirm the procurement PRD numbering. This folder runs its own sequence (PRD-001, PRD-002) and those numbers are referenced inside `edit_purchase_order_line`, while the global sequence is at PRD-112. Filed here as procurement **PRD-003**; say the word if it should be PRD-113 global.
- **Q2.** Should the variance ever be _blocking_ for a manager-level receipt (as opposed to advisory for warehouse staff)? Current spec: never blocking.
- **Q3.** Once VAT is captured, a recoverable input-VAT report by period is a ~1 hour add (`SUM(vat_aed)` by month by supplier). Worth including in v1 for finance?
- **Q4.** Separate from this PRD: should the receiving screen capture **unit price** rather than **total paid**? The back-computation (`107.35 / 16 = 6.7094`) is the root cause of the fils drift in §2.1 and will keep generating variances.
