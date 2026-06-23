"use client";

// PRD-053 Phase C: Head Office review queue for flagged driver additions.
// Reads the canonical v_driver_addition_review_queue; accept/reject via the
// canonical review_driver_addition RPC. No direct .from() writes.

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface QueueRow {
  dispatch_id: string;
  dispatch_date: string;
  machine_name: string | null;
  shelf_code: string | null;
  pod_product_name: string | null;
  boonz_product_name: string | null;
  action: string;
  quantity: number;
  review_reason: string | null;
  last_edited_at: string | null;
}

export default function DriverAdditionsReviewPanel() {
  const [rows, setRows] = useState<QueueRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const { data, error } = await supabase
      .from("v_driver_addition_review_queue")
      .select("*")
      .order("dispatch_date", { ascending: false })
      .limit(10000);
    if (error) setError(error.message);
    setRows((data as QueueRow[]) ?? []);
    setLoading(false);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function decide(row: QueueRow, decision: "accepted" | "rejected") {
    const reason = window.prompt(
      `${decision === "accepted" ? "Accept" : "Reject"} ${row.quantity}u ${row.boonz_product_name ?? ""} on ${row.machine_name ?? ""} ${row.shelf_code ?? ""}?\nOptional note:`,
      "",
    );
    if (reason === null) return; // cancelled
    setBusyId(row.dispatch_id);
    setError(null);
    const supabase = createClient();
    const { error } = await supabase.rpc("review_driver_addition", {
      p_dispatch_id: row.dispatch_id,
      p_decision: decision,
      p_reason: reason.trim() || null,
    });
    setBusyId(null);
    if (error) {
      setError(error.message);
      return;
    }
    // optimistic: drop the row from the pending queue
    setRows((prev) => prev.filter((r) => r.dispatch_id !== row.dispatch_id));
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <span className="text-sm text-neutral-600 dark:text-neutral-400">
          {loading ? "Loading…" : `${rows.length} pending`}
        </span>
        <button
          type="button"
          onClick={() => void load()}
          className="inline-flex min-h-[44px] items-center rounded-lg border border-neutral-300 px-3 text-sm font-medium text-neutral-700 hover:bg-neutral-50 focus-visible:outline focus-visible:outline-2 focus-visible:outline-neutral-900 dark:border-neutral-600 dark:text-neutral-300"
        >
          ↻ Refresh
        </button>
      </div>

      {error && (
        <p className="rounded-lg bg-rose-50 px-3 py-2 text-sm text-rose-700 dark:bg-rose-950/30 dark:text-rose-300">
          {error}
        </p>
      )}

      {!loading && rows.length === 0 ? (
        <p className="rounded-lg border border-neutral-200 px-3 py-6 text-center text-sm text-neutral-600 dark:border-neutral-800 dark:text-neutral-400">
          No driver additions awaiting review.
        </p>
      ) : (
        <ul className="space-y-2">
          {rows.map((r) => (
            <li
              key={r.dispatch_id}
              className="flex flex-col gap-2 rounded-xl border border-neutral-200 bg-white p-3 sm:flex-row sm:items-center sm:justify-between dark:border-neutral-800 dark:bg-neutral-900"
            >
              <div className="min-w-0 text-sm">
                <span className="font-medium">{r.boonz_product_name ?? "—"}</span>
                <span className="ml-2 inline-flex items-center gap-0.5 rounded bg-amber-50 px-1.5 py-0.5 text-[11px] font-medium text-amber-700 dark:bg-amber-950/30 dark:text-amber-300">
                  ⚑ {r.review_reason ?? "review"} · {r.quantity}u
                </span>
                <p className="mt-0.5 text-xs text-neutral-600 dark:text-neutral-400">
                  {r.machine_name ?? "—"} · {r.shelf_code ?? "—"} ·{" "}
                  {r.pod_product_name ?? "—"} · {r.action} · {r.dispatch_date}
                </p>
              </div>
              <div className="flex shrink-0 gap-2">
                <button
                  type="button"
                  disabled={busyId === r.dispatch_id}
                  onClick={() => void decide(r, "accepted")}
                  className="min-h-[44px] rounded-lg bg-emerald-600 px-3 text-sm font-medium text-white hover:bg-emerald-700 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-emerald-700 disabled:opacity-50"
                >
                  {busyId === r.dispatch_id ? "…" : "✓ Accept"}
                </button>
                <button
                  type="button"
                  disabled={busyId === r.dispatch_id}
                  onClick={() => void decide(r, "rejected")}
                  className="min-h-[44px] rounded-lg border border-rose-300 px-3 text-sm font-medium text-rose-700 hover:bg-rose-50 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-600 disabled:opacity-50 dark:border-rose-800 dark:text-rose-300"
                >
                  ✗ Reject
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
