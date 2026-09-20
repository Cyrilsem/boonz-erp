# PRD-123 — VAT captured on every PO receipt

**Status:** DRAFT, ready to batch
**Supersedes / extends:** `procurement/PRD-003-po-document-totals-vat-discount.md`
**Raised:** 2026-09-14 (CS, after PO-9595 Jaleel showed 2,037.20 against a 2,139.06 tax invoice)
**Owner:** Stax (FE + edge), Cody review (touches a SECURITY DEFINER RPC)

> **Numbering note.** `docs/prds/procurement/` runs its own local series (001, 002, 003)
> while the main series runs 102–122. This PRD uses the **global** series to stop the
> two colliding. A follow-up chore should renumber the three procurement-local PRDs
> into the global series and leave stubs behind.

---

## 1. Problem

PRD-003 shipped. All of this is live and working:

- `purchase_order_totals` table
- `set_po_document_totals(...)` RPC, with discount, VAT override warning, invoice variance
- `get_input_vat_report(...)` for finance
- Procurement page renders **"Grand Total"** from `v_po_document_totals` when a totals
  row exists, and falls back to the ex-VAT line sum when it does not

**But nothing ever calls it.** `receive_purchase_order` writes lines and stock, then
stops. No totals row is created, so every PO silently takes the ex-VAT fallback and
looks like VAT was never captured.

This is a **wiring gap, not a display bug**. The UI was right all along.

### Evidence

| PO   | Supplier     | Displayed (ex-VAT) | Actual invoice |
| ---- | ------------ | -----------------: | -------------: |
| 9595 | Jaleel       |           2,037.20 |   **2,139.06** |
| 9581 | Champions    |           1,644.00 |   **1,726.20** |
| 9588 | Hunter Foods |             795.00 |     **834.75** |

**180 received POs** between April and August 2026, totalling **AED 85,760 ex-VAT**,
carry no totals row. At 5% that is roughly **AED 4,288 of recoverable input VAT**
invisible to `get_input_vat_report`.

---

## 2. Goal

Every received PO ends with a `purchase_order_totals` row. No blanks, ever, without a
human having to remember a second step.

---

## 3. Scope

### T1 — Auto-populate at receipt (backend)

In `receive_purchase_order`, after lines settle and before returning, when
**no** totals row exists for the PO:

```
PERFORM set_po_document_totals(
  p_po_id, 0, NULL, NULL, 0.05, 0, NULL, NULL, NULL, NULL,
  'Auto-captured at receipt (PRD-123). VAT computed at 5% on the ex-VAT line
   subtotal. Correct from the supplier tax invoice if it differs.',
  'receiving', 'ex_vat');
```

Passing `p_vat_aed := NULL` makes the RPC compute VAT itself, so `vat_is_override`
stays false and finance can see which rows were auto-derived.

**Rules**

- Never overwrite an existing totals row. Only fill a gap.
- Never fail the receipt. Wrap in `EXCEPTION WHEN OTHERS THEN RAISE WARNING` —
  goods arriving matters more than a totals row.
- Partial receipts: recompute on every call, since `set_po_document_totals`
  already re-reads the line subtotal each time.

### T2 — Capture the real numbers at receipt (FE)

On `field/receiving/[poId]` and the warehouse receive drawer, add three optional
fields above the confirm button:

- **Supplier invoice number** (text)
- **Supplier invoice total incl. VAT** (number)
- **VAT** (number, blank = auto at 5%)

On confirm, call `receive_purchase_order` then `set_po_document_totals` with whatever
was entered. Blank fields fall through to T1's auto behaviour.

**Show the variance inline.** `set_po_document_totals` already returns
`invoice_variance_aed`. If it is non-zero, surface it immediately rather than leaving
it for month-end:

> `Grand total 2,139.06 vs invoice 2,140.00 — variance +0.94 AED`

### T3 — Backfill the 180 historical POs

⛔ **Do not blanket-apply 5%.** Two reasons:

1. No invoice numbers are on file for April–August.
2. `line_price_regime` is unknown for that period. If any lines were entered
   VAT-inclusive, adding 5% double-counts and overstates recoverable VAT.

**Approach:** backfill with `p_line_price_regime := 'unknown'` and
`p_source := 'backfill'`, leaving `supplier_invoice_number` NULL. That makes the
rows visibly distinct from receipt-captured ones, so finance can filter them out of
a VAT return until each is verified against a physical invoice.

Ship T1 and T2 first. T3 is a separate, reviewed decision.

### T4 — Guard

Add to the nightly advisory:

```sql
SELECT COUNT(DISTINCT po.po_id)
FROM purchase_orders po
LEFT JOIN purchase_order_totals t ON t.po_id = po.po_id
WHERE po.purchase_outcome = 'received'
  AND po.received_date >= CURRENT_DATE - 7
  AND t.po_id IS NULL;
```

Non-zero means T1 regressed.

---

## 4. Out of scope

- Renumbering the procurement-local PRD series (separate chore)
- Mixed-rate or zero-rated invoices. Single `vat_rate` per PO stands.
- Changing line prices. **Line prices stay ex-VAT forever.** VAT is recoverable and
  must never reach COGS, warehouse valuation or partner statements.

---

## 5. Acceptance

1. Receive a PO with no VAT entered. A totals row exists, `vat_rate` 0.05,
   `vat_is_override` false, `source` `receiving`, and the card reads **Grand Total**.
2. Receive a PO entering VAT and an invoice total. The row carries both, and a
   variance over 1.00 AED is shown on screen.
3. Receive a PO twice (partial then final). One row, recomputed, not duplicated.
4. Force `set_po_document_totals` to throw. The receipt still succeeds and stock lands.
5. T4 query returns 0 for the trailing 7 days.

---

## 6. Notes for the implementer

- `set_po_document_totals` requires `warehouse | operator_admin | superadmin | manager`.
  `receive_purchase_order` already gates on the same set, so no new role work.
- `p_source` accepts only `receiving | edit | backfill`.
- `p_reason` is mandatory and must be ≥ 10 chars on any **edit** of an existing row.
- The RPC writes both `procurement_events` and `write_audit_log`, so no extra
  audit work is needed.
- Every MCP-applied migration gets a git file committed immediately (standing rule).
