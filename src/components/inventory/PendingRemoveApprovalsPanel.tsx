"use client";

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface PendingRemoveRow {
  dispatch_id: string;
  machine: string;
  boonz_product_name: string;
  planned_qty: number;
  driver_confirmed_qty: number;
  driver_confirmed_at: string;
  dispatch_expiry: string | null;
  comment: string | null;
  hours_awaiting_approval: number;
}

/**
 * BUG-010 — WH-manager-side phase of the two-step REMOVE confirmation.
 *
 * Lists every REMOVE dispatch where the driver confirmed via
 * `driver_confirm_remove` but warehouse_stock + pod_inventory haven't
 * been credited yet. Approve button calls `wh_approve_remove_receipt`
 * (which wraps `receive_dispatch_line` under the hood — canonical credit).
 *
 * Until this panel exists, REMOVE returns silently strand at
 * driver_confirmed without crediting inventory.
 */
export default function PendingRemoveApprovalsPanel() {
  const [rows, setRows] = useState<PendingRemoveRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [acting, setActing] = useState<string | null>(null);
  const [overrides, setOverrides] = useState<Record<string, number>>({});

  const fetchRows = useCallback(async () => {
    const supabase = createClient();
    const { data, error } = await supabase
      .from("v_pending_wh_remove_confirmations")
      .select("*");
    if (error) {
      console.error("[PendingRemoveApprovals] fetch failed:", error);
      setRows([]);
    } else {
      setRows((data ?? []) as unknown as PendingRemoveRow[]);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchRows();
  }, [fetchRows]);

  // Realtime: refetch on any dispatch row change
  useEffect(() => {
    const supabase = createClient();
    const ch = supabase
      .channel("pending_remove_approvals")
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "refill_dispatching" },
        () => fetchRows(),
      )
      .subscribe();
    return () => {
      supabase.removeChannel(ch);
    };
  }, [fetchRows]);

  async function handleApprove(row: PendingRemoveRow) {
    setActing(row.dispatch_id);
    const supabase = createClient();
    const verifiedQty =
      overrides[row.dispatch_id] ?? row.driver_confirmed_qty;
    const reason =
      verifiedQty === row.driver_confirmed_qty
        ? "WH manager verified — qty matches driver count"
        : `WH manager verified — adjusted from driver count ${row.driver_confirmed_qty} to ${verifiedQty}`;
    const {
      data: { user },
    } = await supabase.auth.getUser();
    const { error } = await supabase.rpc("wh_approve_remove_receipt", {
      p_dispatch_id: row.dispatch_id,
      p_actual_qty: verifiedQty,
      p_batch_breakdown: null,
      p_approved_by: user?.id ?? null,
      p_reason: reason,
    });
    if (error) {
      alert(`Approve failed: ${error.message}`);
      console.error("[PendingRemoveApprovals] approve failed:", error);
    } else {
      await fetchRows();
    }
    setActing(null);
  }

  if (loading) return null;
  if (rows.length === 0) return null;

  return (
    <div className="mb-4 rounded-xl border-l-4 border-l-amber-400 border border-neutral-200 bg-amber-50 p-4 dark:border-neutral-800 dark:bg-amber-950/20">
      <div className="mb-3 flex items-center gap-2">
        <span className="text-base">🟡</span>
        <h3 className="text-sm font-bold uppercase tracking-wide text-amber-700 dark:text-amber-400">
          Returns awaiting your approval ({rows.length})
        </h3>
      </div>
      <p className="mb-3 text-xs text-amber-700/80 dark:text-amber-400/80">
        Driver confirmed these REMOVEs in the field. Warehouse stock + pod
        inventory will only update once you verify physical receipt.
      </p>
      <ul className="space-y-2">
        {rows.map((row) => {
          const editedQty = overrides[row.dispatch_id] ?? row.driver_confirmed_qty;
          const drifted = editedQty !== row.driver_confirmed_qty;
          return (
            <li
              key={row.dispatch_id}
              className="rounded-lg border border-amber-200 bg-white p-3 dark:border-amber-900 dark:bg-neutral-950"
            >
              <div className="mb-2 flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <p className="text-sm font-semibold">
                    {row.boonz_product_name}
                  </p>
                  <p className="text-xs text-neutral-500">
                    {row.machine}
                    {row.dispatch_expiry && (
                      <span className="ml-2">
                        exp {new Date(row.dispatch_expiry).toLocaleDateString("en-GB", { day: "2-digit", month: "short", year: "2-digit" })}
                      </span>
                    )}
                  </p>
                </div>
                <span className="shrink-0 text-xs text-neutral-400">
                  {Math.round(row.hours_awaiting_approval)}h ago
                </span>
              </div>
              <div className="mb-3 flex flex-wrap items-center gap-3 text-xs">
                <span className="text-neutral-500">
                  Planned: <strong>{row.planned_qty}</strong>
                </span>
                <span className="text-neutral-400">·</span>
                <span className="text-neutral-500">
                  Driver said: <strong>{row.driver_confirmed_qty}</strong>
                </span>
                <span className="text-neutral-400">·</span>
                <label className="flex items-center gap-2 text-neutral-500">
                  Verified:
                  <input
                    type="number"
                    min={0}
                    value={editedQty}
                    onChange={(e) =>
                      setOverrides((prev) => ({
                        ...prev,
                        [row.dispatch_id]:
                          parseFloat(e.target.value) || 0,
                      }))
                    }
                    className="w-16 rounded border border-neutral-300 px-2 py-1 text-center text-sm dark:border-neutral-600 dark:bg-neutral-900"
                  />
                </label>
                {drifted && (
                  <span className="rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-amber-800 dark:bg-amber-900/40 dark:text-amber-300">
                    Δ {editedQty - row.driver_confirmed_qty}
                  </span>
                )}
              </div>
              {row.comment && (
                <p className="mb-2 truncate text-xs text-neutral-500">
                  Note: {row.comment}
                </p>
              )}
              <button
                onClick={() => handleApprove(row)}
                disabled={acting === row.dispatch_id}
                className="w-full rounded-lg bg-green-600 py-2 text-sm font-medium text-white transition-colors hover:bg-green-700 disabled:opacity-50"
              >
                {acting === row.dispatch_id
                  ? "Approving…"
                  : `✓ Approve receipt — credit ${editedQty} units to warehouse`}
              </button>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
