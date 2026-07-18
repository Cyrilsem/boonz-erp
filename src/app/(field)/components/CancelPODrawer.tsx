"use client";

// PRD-103b — Cancel an ENTIRE unreceived PO from the field Orders page.
// Mirrors the /app/procurement "✕ Cancel PO" action (PRD-087): delegates to
// the canonical cancel_po RPC, which loops cancel_po_line per open line so
// the role gate, driver-note regeneration, procurement_events and
// write_audit_log all fire for every line. The backend refuses the whole
// call if any line has been received ("reverse receipts first") — the FE
// gates visibility, it does not need to re-enforce.

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface CancelPODrawerProps {
  poNumber: number;
  poId: string;
  supplierName: string;
  lineCount: number;
  totalOrdered: number;
  open: boolean;
  onClose: () => void;
  onConfirmed: () => void;
}

export function CancelPODrawer({
  poNumber,
  poId,
  supplierName,
  lineCount,
  totalOrdered,
  open,
  onClose,
  onConfirmed,
}: CancelPODrawerProps) {
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) {
      setReason("");
      setError(null);
      setSaving(false);
    }
  }, [open]);

  if (!open) return null;

  const trimmed = reason.trim();
  const disabled = trimmed.length < 10 || saving;

  async function handleConfirm() {
    setError(null);
    setSaving(true);
    const supabase = createClient();
    const { error: rpcErr } = await supabase.rpc("cancel_po", {
      p_po_number: String(poNumber),
      p_reason: trimmed,
    });
    setSaving(false);
    if (rpcErr) {
      setError(rpcErr.message);
      return;
    }
    onConfirmed();
    onClose();
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40">
      <div className="relative flex w-full max-w-md flex-col rounded-t-2xl bg-white p-4 dark:bg-neutral-950">
        <div className="mb-3 flex items-start justify-between gap-2">
          <div className="min-w-0">
            <h2 className="text-base font-semibold">Cancel entire PO</h2>
            <p className="mt-0.5 text-xs text-neutral-500 truncate">
              {poId} · {supplierName}
            </p>
            <p className="text-xs text-neutral-500">
              {lineCount} {lineCount === 1 ? "product" : "products"} ·{" "}
              {totalOrdered} units ordered
            </p>
          </div>
          <button
            onClick={onClose}
            disabled={saving}
            aria-label="Close cancel PO drawer"
            className="rounded-full p-2 text-neutral-500 hover:bg-neutral-100 disabled:opacity-50 dark:hover:bg-neutral-900"
          >
            ✕
          </button>
        </div>

        <p className="mb-3 rounded-md bg-red-50 px-3 py-2 text-xs text-red-800 dark:bg-red-950 dark:text-red-300">
          This cancels every open line on this PO (duplicated order, no longer
          needed, supplier fell through). It cannot be undone from the app.
          Every line is logged with your name and this reason.
        </p>

        <label className="block">
          <span className="text-xs font-medium text-neutral-700 dark:text-neutral-300">
            Why cancel the whole PO? (required, min 10 chars)
          </span>
          <textarea
            rows={4}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="Duplicate of PO-2026-XXXX, order no longer needed, supplier cancelled..."
            disabled={saving}
            className="mt-1 w-full resize-none rounded-md border border-neutral-300 px-2 py-2 text-sm focus:border-neutral-500 focus:outline-none dark:border-neutral-700 dark:bg-neutral-900"
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
            disabled={saving}
            className="flex-1 rounded-lg border border-neutral-300 py-2 text-sm font-medium text-neutral-700 hover:bg-neutral-50 disabled:opacity-50 dark:border-neutral-700 dark:text-neutral-300 dark:hover:bg-neutral-900"
          >
            Keep PO
          </button>
          <button
            onClick={handleConfirm}
            disabled={disabled}
            className="flex-1 rounded-lg bg-red-700 py-2 text-sm font-medium text-white hover:bg-red-800 disabled:opacity-50"
          >
            {saving ? "Cancelling…" : "Cancel entire PO"}
          </button>
        </div>
      </div>
    </div>
  );
}
