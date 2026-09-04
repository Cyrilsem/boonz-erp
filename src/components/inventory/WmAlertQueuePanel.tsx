"use client";

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface AlertRow {
  source: string;
  dedup_key: string;
  dispatch_id: string | null;
  pod_product_id: string | null;
  severity: string | null;
  latest_at: string;
  occurrences: number;
  payload: Record<string, unknown>;
}

const SOURCE_LABEL: Record<string, string> = {
  bug010_wh_approval_stuck: "Dispatch stuck at WH approval",
  prd016_guardrail2_return_variant_uncorrected: "Return variant uncorrected",
  expiry_unvalidated: "Pods with unvalidated expiry (>3 days)",
};

/**
 * PRD-119 P4: surfaces the 3 named alerts (bug010_wh_approval_stuck,
 * prd016_guardrail2_return_variant_uncorrected, expiry_unvalidated) as
 * dedup'd, actionable WM queue lines instead of raw monitoring_alerts rows
 * nobody ever resolved. Reads v_wm_alert_queue; Ack does not fix the
 * underlying condition — it only clears the line once a WM has handled it
 * via the normal approval/correction screen.
 */
export default function WmAlertQueuePanel() {
  const [rows, setRows] = useState<AlertRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [ackTarget, setAckTarget] = useState<AlertRow | null>(null);
  const [ackNote, setAckNote] = useState("");
  const [ackBusy, setAckBusy] = useState(false);
  const [toast, setToast] = useState<{ ok: boolean; msg: string } | null>(null);

  const fetchRows = useCallback(async () => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const { data, error: fetchError } = await supabase
      .from("v_wm_alert_queue")
      .select("*")
      .order("latest_at", { ascending: false })
      .limit(10000);
    if (fetchError) {
      setError(fetchError.message);
      setRows([]);
    } else {
      setRows((data ?? []) as AlertRow[]);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial fetch, same pattern as sibling panels
    void fetchRows();
  }, [fetchRows]);

  const confirmAck = useCallback(async () => {
    if (!ackTarget || ackNote.trim().length < 10) return;
    setAckBusy(true);
    setToast(null);
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    const { data, error: rpcErr } = await supabase.rpc("acknowledge_wm_alert", {
      p_source: ackTarget.source,
      p_dedup_key: ackTarget.dedup_key,
      p_note: ackNote.trim(),
      p_caller: user?.id ?? null,
      p_dry_run: false,
    });
    setAckBusy(false);
    if (rpcErr) {
      setToast({ ok: false, msg: rpcErr.message });
      return;
    }
    const res = data as { rows_acked?: number } | null;
    setToast({
      ok: true,
      msg: `Acknowledged (${res?.rows_acked ?? 0} row(s) cleared).`,
    });
    setAckTarget(null);
    setAckNote("");
    void fetchRows();
  }, [ackTarget, ackNote, fetchRows]);

  if (loading) {
    return (
      <div className="rounded-lg border border-neutral-300 bg-neutral-50 p-4 text-sm dark:border-neutral-700 dark:bg-neutral-900">
        Loading alert queue…
      </div>
    );
  }
  if (error) {
    return (
      <div className="rounded-lg border border-rose-300 bg-rose-50 p-4 text-sm dark:border-rose-800 dark:bg-rose-950/20">
        <div className="font-semibold text-rose-800 dark:text-rose-200">
          Could not load alert queue
        </div>
        <div className="mt-1 text-xs text-rose-700 dark:text-rose-300">
          {error}
        </div>
      </div>
    );
  }
  if (rows.length === 0) {
    return (
      <div className="rounded-lg border border-emerald-300 bg-emerald-50 p-4 text-sm dark:border-emerald-800 dark:bg-emerald-950/20">
        <span className="font-semibold text-emerald-800 dark:text-emerald-200">
          No open alerts
        </span>{" "}
        — bug010, prd016 guardrail, and expiry-unvalidated queues are clear.
      </div>
    );
  }

  return (
    <div className="rounded-lg border border-amber-300 dark:border-amber-700">
      <div className="flex flex-wrap items-center gap-3 border-b border-amber-200 p-3 dark:border-amber-800">
        <span className="rounded-full bg-amber-500 px-2 py-0.5 text-xs font-semibold text-white">
          {rows.length}
        </span>
        <span className="text-sm font-semibold">Attention queue</span>
      </div>

      <div className="overflow-x-auto">
        <table className="w-full text-xs">
          <thead className="bg-amber-100 text-left dark:bg-amber-900/40">
            <tr>
              <th className="px-3 py-2 font-semibold">Type</th>
              <th className="px-3 py-2 font-semibold">Detail</th>
              <th className="px-3 py-2 font-semibold">Severity</th>
              <th className="px-3 py-2 text-right font-semibold">Open days</th>
              <th className="px-3 py-2 font-semibold">Last seen</th>
              <th className="px-3 py-2 text-right font-semibold">Action</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-amber-200 dark:divide-amber-800">
            {rows.map((r) => (
              <tr
                key={`${r.source}:${r.dedup_key}`}
                className="hover:bg-amber-100/60 dark:hover:bg-amber-900/30"
              >
                <td className="px-3 py-2">
                  {SOURCE_LABEL[r.source] ?? r.source}
                </td>
                <td className="px-3 py-2 font-mono text-neutral-600 dark:text-neutral-400">
                  {r.dispatch_id
                    ? `dispatch ${r.dispatch_id.slice(0, 8)}…`
                    : r.source === "expiry_unvalidated"
                      ? `${(r.payload as { count?: number })?.count ?? "?"} pod row(s)`
                      : "—"}
                </td>
                <td className="px-3 py-2">
                  <span
                    className={`rounded px-1.5 py-0.5 text-[10px] font-semibold ${
                      r.severity === "critical"
                        ? "bg-rose-200 text-rose-900 dark:bg-rose-800 dark:text-rose-100"
                        : "bg-amber-200 text-amber-900 dark:bg-amber-800 dark:text-amber-100"
                    }`}
                  >
                    {r.severity ?? "warning"}
                  </span>
                </td>
                <td className="px-3 py-2 text-right font-mono">
                  {r.occurrences}
                </td>
                <td className="px-3 py-2 font-mono text-neutral-500">
                  {new Date(r.latest_at).toLocaleDateString()}
                </td>
                <td className="px-3 py-2 text-right">
                  <button
                    onClick={() => {
                      setAckTarget(r);
                      setAckNote("");
                      setToast(null);
                    }}
                    className="rounded border border-amber-400 bg-white px-2 py-1 text-[11px] font-semibold text-amber-800 hover:bg-amber-100 dark:bg-neutral-900 dark:text-amber-200"
                  >
                    Acknowledge
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {ackTarget && (
        <div className="border-t border-amber-300 bg-white px-3 py-3 dark:bg-neutral-900">
          <div className="text-xs font-semibold">
            Acknowledge — {SOURCE_LABEL[ackTarget.source] ?? ackTarget.source}
          </div>
          <div className="mt-1 text-[11px] text-neutral-600 dark:text-neutral-400">
            Acknowledging clears this from the queue — it does not fix the
            underlying dispatch or variant. State what you did (min 10 chars).
          </div>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <input
              type="text"
              value={ackNote}
              onChange={(e) => setAckNote(e.target.value)}
              placeholder="e.g. approved dispatch manually, driver confirmed delivery"
              className="min-w-[280px] flex-1 rounded border border-neutral-300 px-2 py-1 text-xs dark:border-neutral-700 dark:bg-neutral-950"
            />
            <button
              onClick={confirmAck}
              disabled={ackBusy || ackNote.trim().length < 10}
              className="rounded bg-amber-600 px-3 py-1 text-xs font-semibold text-white hover:bg-amber-700 disabled:opacity-50"
            >
              {ackBusy ? "Acknowledging…" : "Confirm"}
            </button>
            <button
              onClick={() => setAckTarget(null)}
              className="rounded border border-neutral-300 px-3 py-1 text-xs dark:border-neutral-700"
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      {toast && (
        <div
          className={`border-t px-3 py-2 text-[11px] ${
            toast.ok
              ? "border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-800 dark:bg-emerald-950/30 dark:text-emerald-200"
              : "border-rose-200 bg-rose-50 text-rose-800 dark:border-rose-800 dark:bg-rose-950/30 dark:text-rose-200"
          }`}
        >
          {toast.ok ? "✓ " : "✗ "}
          {toast.msg}
        </div>
      )}
    </div>
  );
}
