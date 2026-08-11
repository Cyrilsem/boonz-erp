// PRD-003 — the shape returned by get_po_document_totals, a thin wrapper over
// v_po_document_totals: the Article 16 canonical object for "PO document grand
// total" and "recoverable input VAT".
//
// Every consumer READS these figures. Nothing re-derives them client-side —
// browser-side re-derivation of the PO total is the exact defect PRD-003 was
// written to end (see PRD §2: "the 'Total' shown on the PO card is a
// client-side SUM(total_price_aed) computed in the browser").
//
// The money fields arrive from PostgREST as numerics; depending on the driver
// they can surface as `number` or as a numeric-shaped `string`. Callers should
// pass them through `Number(...)` before arithmetic or `.toFixed()`.
export interface PODocumentTotals {
  po_id: string;
  /** false when this PO has no totals row — render subtotal-only, as before PRD-003 (I-4). */
  has_totals: boolean;

  // Live, recomputed on every read from the non-cancelled lines and the
  // additions that have no mirrored line.
  live_lines_ex_vat_aed: number | null;
  live_additions_ex_vat_aed: number | null;
  live_subtotal_ex_vat_aed: number | null;
  live_line_count: number | null;
  /** received po_additions on this PO with no mirrored purchase_orders line. */
  live_unmirrored_additions: number | null;
  /** an addition priced above 3x the product's trailing median — likely a pack total. */
  additions_price_suspect: boolean | null;

  // Captured at entry.
  lines_subtotal_ex_vat_aed: number | null;
  additions_subtotal_ex_vat_aed: number | null;
  subtotal_ex_vat_aed: number | null;
  discount_aed: number | null;
  discount_label: string | null;
  vat_rate: number | null;
  vat_aed: number | null;
  vat_auto_aed: number | null;
  vat_is_override: boolean | null;
  other_adjustment_aed: number | null;
  other_adjustment_label: string | null;
  grand_total_aed: number | null;
  supplier_invoice_number: string | null;
  supplier_invoice_date: string | null;
  supplier_invoice_total_aed: number | null;
  /** 'ex_vat' | 'vat_inclusive' | 'unknown' — legacy lines stay 'unknown'. */
  line_price_regime: string | null;
  source: string | null;

  /** grand_total − supplier_invoice_total. NULL when no supplier figure was entered. */
  invoice_variance_aed: number | null;
  /** true when lines or additions moved after the totals were captured. */
  totals_stale: boolean | null;
}
