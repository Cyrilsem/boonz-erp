"use client";

// PRD-053 Phase B: per-expiry split on a dispatch line, TOTAL LOCKED to the line
// qty. Calls the canonical set_dispatch_line_breakdown (no direct .from() write).
// The line total is immutable here — only the per-expiry distribution changes.

import { useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";

type Entry = { qty: string; expiry: string };

export default function ExpiryBreakdownDialog({
  dispatchId,
  lineTotal,
  productName,
  initial,
  onClose,
  onSaved,
}: {
  dispatchId: string;
  lineTotal: number;
  productName: string;
  initial?: { qty: number; expiry: string | null }[] | null;
  onClose: () => void;
  onSaved?: () => void;
}) {
  const [rows, setRows] = useState<Entry[]>(
    initial && initial.length > 0
      ? initial.map((e) => ({ qty: String(e.qty), expiry: e.expiry ?? "" }))
      : [{ qty: String(lineTotal), expiry: "" }],
  );
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  const total = useMemo(
    () => rows.reduce((s, r) => s + (parseInt(r.qty) || 0), 0),
    [rows],
  );
  const matches = total === lineTotal;

  function update(i: number, patch: Partial<Entry>) {
    setRows((prev) => prev.map((r, j) => (j === i ? { ...r, ...patch } : r)));
  }
  function addRow() {
    setRows((prev) => [...prev, { qty: "0", expiry: "" }]);
  }
  function removeRow(i: number) {
    setRows((prev) =>
      prev.length > 1 ? prev.filter((_, j) => j !== i) : prev,
    );
  }

  async function save() {
    if (!matches) {
      setMsg(
        `The split must total ${lineTotal} (the line quantity is locked). Currently ${total}.`,
      );
      return;
    }
    setBusy(true);
    setMsg(null);
    const breakdown = rows
      .filter((r) => (parseInt(r.qty) || 0) > 0)
      .map((r) => ({
        qty: parseInt(r.qty) || 0,
        expiry: r.expiry || null,
      }));
    const supabase = createClient();
    const { error } = await supabase.rpc("set_dispatch_line_breakdown", {
      p_dispatch_id: dispatchId,
      p_batch_breakdown: breakdown,
      p_edit_role: "driver",
      p_reason: `driver per-expiry split for ${productName}`,
    });
    setBusy(false);
    if (error) {
      setMsg(error.message);
      return;
    }
    onSaved?.();
    onClose();
  }

  return (
    <div
      className="fixed inset-0 z-[200] flex items-end justify-center bg-black/40 p-0 sm:items-center sm:p-4"
      onClick={() => !busy && onClose()}
    >
      <div
        role="dialog"
        aria-label="Split this line across expiry dates"
        className="w-full max-w-md rounded-t-2xl bg-white p-4 shadow-xl sm:rounded-2xl dark:bg-neutral-900"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="text-base font-semibold">Split across expiry dates</h2>
        <p className="mt-0.5 text-xs text-neutral-600 dark:text-neutral-400">
          {productName} — total locked to <strong>{lineTotal}</strong>.
          Distribute across real expiry dates; leave a date blank for "to
          confirm".
        </p>

        <div className="mt-3 space-y-2">
          {rows.map((r, i) => (
            <div key={i} className="flex items-center gap-2">
              <input
                type="number"
                min={0}
                inputMode="numeric"
                value={r.qty}
                aria-label={`Quantity for row ${i + 1}`}
                onChange={(e) => update(i, { qty: e.target.value })}
                className="min-h-[44px] w-16 rounded-lg border border-neutral-300 px-2 text-right text-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-neutral-900 dark:border-neutral-700 dark:bg-neutral-950"
              />
              <span className="text-xs text-neutral-500">@</span>
              <input
                type="date"
                value={r.expiry}
                aria-label={`Expiry date for row ${i + 1}`}
                onChange={(e) => update(i, { expiry: e.target.value })}
                className="min-h-[44px] flex-1 rounded-lg border border-neutral-300 px-2 text-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-neutral-900 dark:border-neutral-700 dark:bg-neutral-950"
              />
              <button
                type="button"
                onClick={() => removeRow(i)}
                aria-label={`Remove row ${i + 1}`}
                disabled={rows.length <= 1}
                className="min-h-[44px] min-w-[44px] rounded-lg border border-neutral-300 text-sm text-neutral-600 disabled:opacity-40 dark:border-neutral-700 dark:text-neutral-300"
              >
                −
              </button>
            </div>
          ))}
          <button
            type="button"
            onClick={addRow}
            className="min-h-[44px] w-full rounded-lg border border-dashed border-neutral-300 text-sm font-medium text-neutral-600 hover:bg-neutral-50 dark:border-neutral-700 dark:text-neutral-300"
          >
            + Add expiry row
          </button>
        </div>

        <div
          className={`mt-3 flex items-center justify-between rounded-lg px-3 py-2 text-sm ${
            matches
              ? "bg-emerald-50 text-emerald-800 dark:bg-emerald-950/30 dark:text-emerald-200"
              : "bg-amber-50 text-amber-800 dark:bg-amber-950/30 dark:text-amber-200"
          }`}
        >
          <span>Split total</span>
          <span className="font-semibold tabular-nums">
            {total} / {lineTotal}{" "}
            {matches
              ? "✓"
              : `(${total > lineTotal ? "−" : "+"}${Math.abs(lineTotal - total)})`}
          </span>
        </div>

        {msg && (
          <p className="mt-2 rounded-lg bg-rose-50 px-2 py-1.5 text-xs text-rose-700 dark:bg-rose-950/30 dark:text-rose-300">
            {msg}
          </p>
        )}

        <div className="mt-4 flex gap-2">
          <button
            type="button"
            onClick={onClose}
            disabled={busy}
            className="min-h-[44px] flex-1 rounded-lg border border-neutral-300 text-sm font-medium text-neutral-700 disabled:opacity-50 dark:border-neutral-600 dark:text-neutral-300"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={save}
            disabled={busy || !matches}
            className="min-h-[44px] flex-1 rounded-lg bg-indigo-600 text-sm font-medium text-white hover:bg-indigo-700 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-700 disabled:opacity-50"
          >
            {busy ? "Saving…" : "Save split"}
          </button>
        </div>
      </div>
    </div>
  );
}
