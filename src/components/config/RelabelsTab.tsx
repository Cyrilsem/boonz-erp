"use client";

// PRD-141 item 22: WEIMI relabels to do, from weimi_relabel_requests. A swap
// opens one automatically (ensure_swap_remove_leg); operator_admin marks it done
// once the lane is renamed in WEIMI.

import { useState, useEffect } from "react";
import { createClient } from "@/lib/supabase/client";

interface RelabelRow {
  request_id: string;
  shelf_code: string;
  dispatch_date: string | null;
  source: string;
  requested_at: string;
  machine: { official_name: string } | null;
  from_pp: { pod_product_name: string } | null;
  to_pp: { pod_product_name: string } | null;
}

export function RelabelsTab({ canMarkDone }: { canMarkDone: boolean }) {
  const [rows, setRows] = useState<RelabelRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState("");

  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    const supabase = createClient();
    supabase
      .from("weimi_relabel_requests")
      .select(
        "request_id, shelf_code, dispatch_date, source, requested_at, machine:machines!weimi_relabel_requests_machine_id_fkey(official_name), from_pp:pod_products!weimi_relabel_requests_from_pod_fkey(pod_product_name), to_pp:pod_products!weimi_relabel_requests_to_pod_fkey(pod_product_name)",
      )
      .is("done_at", null)
      .order("requested_at", { ascending: true })
      .limit(10000)
      .then(({ data, error: err }) => {
        if (err) setError(err.message);
        setRows((data as unknown as RelabelRow[] | null) ?? []);
        setLoading(false);
      });
  }, [reloadKey]);

  async function markDone(requestId: string) {
    setBusyId(requestId);
    setError("");
    const supabase = createClient();
    const { data, error: err } = await supabase.rpc("mark_relabel_done", {
      p_request_id: requestId,
    });
    setBusyId(null);
    if (err) {
      setError(`Mark done failed: ${err.message}`);
      return;
    }
    if ((data as { status?: string } | null)?.status !== "done") {
      setError("This relabel was already closed.");
    }
    setReloadKey((k) => k + 1);
  }

  if (loading) {
    return <p className="px-4 py-6 text-sm text-neutral-500">Loading…</p>;
  }

  return (
    <div className="px-4 py-4">
      <p className="mb-3 text-xs text-neutral-500">
        Lanes to rename in WEIMI after a swap. Mark a lane done once WEIMI shows
        the new product.
      </p>
      {error && (
        <p className="mb-3 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">
          {error}
        </p>
      )}
      {rows.length === 0 ? (
        <p className="py-6 text-center text-sm text-neutral-500">
          No relabels open
        </p>
      ) : (
        <ul className="space-y-2">
          {rows.map((r) => (
            <li
              key={r.request_id}
              className="flex items-center gap-3 rounded-lg border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950"
            >
              <div className="min-w-0 flex-1">
                <p className="truncate text-sm font-semibold">
                  {r.machine?.official_name ?? "Unknown machine"} ·{" "}
                  {r.shelf_code}
                </p>
                <p className="truncate text-xs text-neutral-600">
                  {r.from_pp?.pod_product_name ?? "Unknown"} →{" "}
                  {r.to_pp?.pod_product_name ?? "Unknown"}
                </p>
                <p className="text-[11px] text-neutral-400">
                  {r.source === "swap" ? "From a swap" : "Opened by hand"}
                  {r.dispatch_date ? `, dispatch ${r.dispatch_date}` : ""}
                </p>
              </div>
              {canMarkDone && (
                <button
                  onClick={() => void markDone(r.request_id)}
                  disabled={busyId === r.request_id}
                  className="shrink-0 rounded-lg bg-[#24544a] px-3 py-1.5 text-xs font-medium text-white disabled:opacity-50"
                >
                  {busyId === r.request_id ? "Saving…" : "Mark done"}
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
