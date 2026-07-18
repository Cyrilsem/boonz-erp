"use client";

// PRD-001 — WH manager edits a submitted PO line.
// Each line shows the three editable fields (ordered_qty, price_per_unit_aed, expiry_date).
// One Reason input is shared across all changed lines.
// Save iterates changed lines and calls edit_purchase_order_line once per line.
//
// PRD-103 — per-field lock on received lines. Received lines used to be fully
// read-only for everyone but superadmin. Now the EXPIRY field stays editable for
// the standard edit roles (a common receiving typo to fix), while ordered_qty and
// price remain superadmin-only. This mirrors the backend edit_purchase_order_line
// guard exactly, so the two never diverge. Every change is still logged (reason +
// who + before/after) via procurement_events + write_audit_log.

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface POLineForEdit {
  po_line_id: string;
  boonz_product_name: string;
  ordered_qty: number;
  price_per_unit_aed: number | null;
  expiry_date: string | null;
  received_qty: number | null;
  // PRD-002: drives the per-line lock alongside received_qty.
  purchase_outcome: string | null;
}

interface EditPOLineDrawerProps {
  poId: string;
  open: boolean;
  onClose: () => void;
  onSaved: () => void;
  // PRD-002/103: caller role gates the per-field lock. On received lines,
  // qty & price are superadmin-only; expiry stays editable for all edit roles.
  userRole?: string | null;
}

interface DraftLine {
  po_line_id: string;
  product_name: string;
  received_qty: number | null;
  purchase_outcome: string | null;
  original_ordered_qty: number;
  original_price: number | null;
  original_expiry: string | null;
  ordered_qty: string;
  price: string;
  expiry: string;
}

function toDraft(line: POLineForEdit): DraftLine {
  return {
    po_line_id: line.po_line_id,
    product_name: line.boonz_product_name,
    received_qty: line.received_qty,
    purchase_outcome: line.purchase_outcome,
    original_ordered_qty: line.ordered_qty,
    original_price: line.price_per_unit_aed,
    original_expiry: line.expiry_date,
    ordered_qty: String(line.ordered_qty ?? ""),
    price:
      line.price_per_unit_aed != null ? String(line.price_per_unit_aed) : "",
    expiry: line.expiry_date ?? "",
  };
}

function lineIsReceived(d: DraftLine): boolean {
  return (d.received_qty ?? 0) > 0 || d.purchase_outcome === "received";
}

// PRD-103: qty & price are the superadmin-only fields on a received line.
// Expiry is NOT locked — it stays editable for every edit role.
function qtyPriceLocked(d: DraftLine, role: string | null | undefined): boolean {
  return lineIsReceived(d) && role !== "superadmin";
}

function expiryChanged(d: DraftLine): boolean {
  const expiryParsed = d.expiry.trim() === "" ? null : d.expiry;
  return expiryParsed !== null && expiryParsed !== d.original_expiry;
}

function qtyOrPriceChanged(d: DraftLine): boolean {
  const qtyParsed = d.ordered_qty.trim() === "" ? null : Number(d.ordered_qty);
  const priceParsed = d.price.trim() === "" ? null : Number(d.price);
  const qtyChangedV = qtyParsed !== null && qtyParsed !== d.original_ordered_qty;
  const priceChangedV = priceParsed !== null && priceParsed !== d.original_price;
  return qtyChangedV || priceChangedV;
}

// A line is submittable if it has a change we're actually allowed to send:
// on qty/price-locked lines that means an expiry change only.
function lineHasSubmittableChange(
  d: DraftLine,
  role: string | null | undefined,
): boolean {
  if (qtyPriceLocked(d, role)) return expiryChanged(d);
  return expiryChanged(d) || qtyOrPriceChanged(d);
}

export function EditPOLineDrawer({
  poId,
  open,
  onClose,
  onSaved,
  userRole,
}: EditPOLineDrawerProps) {
  const [lines, setLines] = useState<DraftLine[]>([]);
  const [reason, setReason] = useState("");
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) {
      setLines([]);
      setReason("");
      setError(null);
      return;
    }

    let cancelled = false;
    (async () => {
      setLoading(true);
      setError(null);
      const supabase = createClient();
      const { data, error: fetchErr } = await supabase
        .from("purchase_orders")
        .select(
          "po_line_id, ordered_qty, price_per_unit_aed, expiry_date, received_qty, purchase_outcome, boonz_products!inner(boonz_product_name)",
        )
        .eq("po_id", poId)
        .order("po_line_id", { ascending: true })
        .limit(10000);

      if (cancelled) return;

      if (fetchErr) {
        setError(fetchErr.message);
        setLoading(false);
        return;
      }

      const mapped: DraftLine[] = (data ?? []).map((row) => {
        const p = row.boonz_products as unknown as {
          boonz_product_name: string;
        };
        return toDraft({
          po_line_id: row.po_line_id as string,
          boonz_product_name: p.boonz_product_name,
          ordered_qty: Number(row.ordered_qty ?? 0),
          price_per_unit_aed:
            row.price_per_unit_aed != null
              ? Number(row.price_per_unit_aed)
              : null,
          expiry_date: row.expiry_date as string | null,
          received_qty:
            row.received_qty != null ? Number(row.received_qty) : null,
          purchase_outcome: (row.purchase_outcome as string | null) ?? null,
        });
      });
      setLines(mapped);
      setLoading(false);
    })();

    return () => {
      cancelled = true;
    };
  }, [open, poId]);

  function patchLine(idx: number, patch: Partial<DraftLine>) {
    setLines((prev) =>
      prev.map((l, i) => (i === idx ? { ...l, ...patch } : l)),
    );
  }

  async function handleSave() {
    setError(null);

    const reasonTrimmed = reason.trim();
    if (reasonTrimmed.length < 10) {
      setError("Reason is required (at least 10 characters).");
      return;
    }

    const changed = lines.filter((l) => lineHasSubmittableChange(l, userRole));
    if (changed.length === 0) {
      setError("No changes to save. Edit at least one field, or close.");
      return;
    }

    setSaving(true);
    const supabase = createClient();
    const errors: string[] = [];

    for (const d of changed) {
      const locked = qtyPriceLocked(d, userRole);
      const qtyParsed =
        d.ordered_qty.trim() === "" ? null : Number(d.ordered_qty);
      const priceParsed = d.price.trim() === "" ? null : Number(d.price);
      const expiryParsed = d.expiry.trim() === "" ? null : d.expiry;

      const args: Record<string, unknown> = {
        p_po_line_id: d.po_line_id,
        p_reason: reasonTrimmed,
      };
      // PRD-103: never send qty/price for a received line unless superadmin.
      if (!locked) {
        if (qtyParsed !== null && qtyParsed !== d.original_ordered_qty) {
          args.p_new_ordered_qty = qtyParsed;
        }
        if (priceParsed !== null && priceParsed !== d.original_price) {
          args.p_new_price_per_unit_aed = priceParsed;
        }
      }
      if (expiryParsed !== null && expiryParsed !== d.original_expiry) {
        args.p_new_expiry_date = expiryParsed;
      }

      const { error: rpcErr } = await supabase.rpc(
        "edit_purchase_order_line",
        args,
      );
      if (rpcErr) {
        errors.push(`${d.product_name}: ${rpcErr.message}`);
      }
    }

    setSaving(false);

    if (errors.length > 0) {
      setError(errors.join("\n"));
      return;
    }

    onSaved();
    onClose();
  }

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40">
      <div className="relative flex h-[90vh] w-full max-w-3xl flex-col rounded-t-2xl bg-white p-4 dark:bg-neutral-950">
        <div className="mb-3 flex items-center justify-between">
          <div>
            <h2 className="text-base font-semibold">Edit PO lines</h2>
            <p className="text-xs text-neutral-500">{poId}</p>
          </div>
          <button
            onClick={onClose}
            className="rounded-full p-2 text-neutral-500 hover:bg-neutral-100 dark:hover:bg-neutral-900"
            aria-label="Close edit drawer"
            disabled={saving}
          >
            ✕
          </button>
        </div>

        <div className="-mx-2 flex-1 overflow-y-auto px-2">
          {loading ? (
            <div className="flex items-center justify-center p-6">
              <p className="text-sm text-neutral-500">Loading PO lines…</p>
            </div>
          ) : lines.length === 0 ? (
            <p className="p-6 text-sm text-neutral-500">No lines on this PO.</p>
          ) : (
            <ul className="space-y-3">
              {lines.map((line, idx) => {
                const dirty = lineHasSubmittableChange(line, userRole);
                // PRD-103: qty & price locked on received lines for non-superadmin;
                // expiry stays editable. Mirrors the backend guard exactly.
                const lockQtyPrice = qtyPriceLocked(line, userRole);
                return (
                  <li
                    key={line.po_line_id}
                    className={`rounded-lg border p-3 ${
                      dirty
                        ? "border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950"
                        : "border-neutral-200 dark:border-neutral-800"
                    }`}
                  >
                    <div className="flex items-start justify-between gap-2">
                      <p className="text-sm font-medium">{line.product_name}</p>
                      {lockQtyPrice && (
                        <span
                          title="Received — qty & price are superadmin-only. Expiry can still be corrected."
                          className="shrink-0 text-xs text-neutral-500"
                        >
                          🔒 Qty/price locked
                        </span>
                      )}
                    </div>
                    {line.received_qty != null && line.received_qty > 0 && (
                      <p className="mt-0.5 text-xs text-neutral-500">
                        Received: {line.received_qty} units
                        {lockQtyPrice
                          ? " — expiry editable; qty & price superadmin-only"
                          : " (cannot drop ordered_qty below this)"}
                      </p>
                    )}
                    <div className="mt-2 grid grid-cols-3 gap-2">
                      <label className="block">
                        <span className="text-xs text-neutral-500">
                          Ordered qty
                        </span>
                        <input
                          type="number"
                          step="any"
                          inputMode="decimal"
                          value={line.ordered_qty}
                          onChange={(e) =>
                            patchLine(idx, { ordered_qty: e.target.value })
                          }
                          className="mt-1 w-full rounded-md border border-neutral-300 px-2 py-1.5 text-sm focus:border-neutral-500 focus:outline-none disabled:bg-neutral-100 disabled:text-neutral-400 dark:border-neutral-700 dark:bg-neutral-900 dark:disabled:bg-neutral-800"
                          disabled={saving || lockQtyPrice}
                          readOnly={lockQtyPrice}
                        />
                      </label>
                      <label className="block">
                        <span className="text-xs text-neutral-500">
                          Price (AED)
                        </span>
                        <input
                          type="number"
                          step="0.01"
                          inputMode="decimal"
                          value={line.price}
                          onChange={(e) =>
                            patchLine(idx, { price: e.target.value })
                          }
                          className="mt-1 w-full rounded-md border border-neutral-300 px-2 py-1.5 text-sm focus:border-neutral-500 focus:outline-none disabled:bg-neutral-100 disabled:text-neutral-400 dark:border-neutral-700 dark:bg-neutral-900 dark:disabled:bg-neutral-800"
                          disabled={saving || lockQtyPrice}
                          readOnly={lockQtyPrice}
                        />
                      </label>
                      <label className="block">
                        <span className="text-xs text-neutral-500">
                          Expiry
                          {lockQtyPrice && (
                            <span className="ml-1 text-emerald-600 dark:text-emerald-400">
                              ✎ editable
                            </span>
                          )}
                        </span>
                        <input
                          type="date"
                          value={line.expiry}
                          onChange={(e) =>
                            patchLine(idx, { expiry: e.target.value })
                          }
                          className="mt-1 w-full rounded-md border border-neutral-300 px-2 py-1.5 text-sm focus:border-neutral-500 focus:outline-none disabled:bg-neutral-100 disabled:text-neutral-400 dark:border-neutral-700 dark:bg-neutral-900 dark:disabled:bg-neutral-800"
                          disabled={saving}
                        />
                      </label>
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
        </div>

        <div className="mt-3 border-t border-neutral-200 pt-3 dark:border-neutral-800">
          <label className="block">
            <span className="text-xs font-medium text-neutral-700 dark:text-neutral-300">
              Reason for edit (required, min 10 chars)
            </span>
            <textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={2}
              placeholder="e.g. Supplier delivered 12 instead of 10; corrected expiry per box label"
              className="mt-1 w-full resize-none rounded-md border border-neutral-300 px-2 py-2 text-sm focus:border-neutral-500 focus:outline-none dark:border-neutral-700 dark:bg-neutral-900"
              disabled={saving}
            />
          </label>
          {error && (
            <p className="mt-2 whitespace-pre-wrap text-sm text-red-600 dark:text-red-400">
              {error}
            </p>
          )}
          <div className="mt-3 flex gap-2">
            <button
              onClick={onClose}
              className="flex-1 rounded-lg border border-neutral-300 py-2 text-sm font-medium text-neutral-700 hover:bg-neutral-50 dark:border-neutral-700 dark:text-neutral-300 dark:hover:bg-neutral-900"
              disabled={saving}
            >
              Cancel
            </button>
            <button
              onClick={handleSave}
              className="flex-1 rounded-lg bg-neutral-900 py-2 text-sm font-medium text-white hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
              disabled={saving || loading}
            >
              {saving ? "Saving…" : "Save changes"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
