"use client";

// PRD-002 - Cancel a single PO line with a mandatory reason comment.
// Calls cancel_po_line(p_po_line_id, p_reason). The RPC already blocks
// received lines (received_qty > 0 OR purchase_outcome = 'received') so
// the FE only needs to gate visibility, not refuse the click.

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface CancelPOLineDrawerProps {
  poLineId: string;
  productName: string;
  orderedQty: number;
  open: boolean;
  onClose: () => void;
  onConfirmed: () => void;
}

export function CancelPOLineDrawer({
  poLineId,
  productName,
  orderedQty,
  open,
  onClose,
  onConfirmed,
}: CancelPOLineDrawerProps) {
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
    const { error: rpcErr } = await supabase.rpc("cancel_po_line", {
      p_po_line_id: poLineId,
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
            <h2 className="text-base font-semibold">Mark as Not Received</h2>
            <p className="mt-0.5 text-xs text-neutral-500 truncate">
              {productName} - {orderedQty} ordered
            </p>
          </div>
          <button
            onClick={onClose}
            disabled={saving}
            aria-label="Close cancel drawer"
            className="rounded-full p-2 text-neutral-500 hover:bg-neutral-100 disabled:opacity-50 dark:hover:bg-neutral-900"
          >
            ✕
          </button>
        </div>

        <label className="block">
          <span className="text-xs font-medium text-neutral-700 dark:text-neutral-300">
            Why is this not received? (required, min 10 chars)
          </span>
          <textarea
            rows={4}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="Supplier short-shipped, item discontinued, walk-in skipped..."
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
            Close
          </button>
          <button
            onClick={handleConfirm}
            disabled={disabled}
            className="flex-1 rounded-lg bg-red-700 py-2 text-sm font-medium text-white hover:bg-red-800 disabled:opacity-50"
          >
            {saving ? "Cancelling..." : "Confirm cancel"}
          </button>
        </div>
      </div>
    </div>
  );
}
