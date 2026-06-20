"use client";

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface QuarantinedRow {
  wh_inventory_id: string;
  warehouse_id: string | null;
  warehouse_name: string | null;
  boonz_product_id: string | null;
  product_name: string | null;
  warehouse_stock: number | null;
  consumer_stock: number | null;
  expiration_date: string | null;
  batch_id: string | null;
  status: string | null;
  provenance_reason: string | null;
  source_event_id: string | null;
  quarantined: boolean;
  last_audit_at: string | null;
  last_audit_reason: string | null;
}

/**
 * PRD-003 acceptance criterion: phantom rows must be flagged and visible in an
 * admin "needs review" screen. Reads `v_wh_inventory_provenance` (the live view
 * added in migration 20260521230813_*). The view's `security_invoker=true`
 * means underlying warehouse_inventory RLS applies — admin/superadmin only.
 *
 * CS uses this panel after physical recount to decide which rows to reconcile
 * via `adjust_warehouse_stock(..., p_reason := 'PRD-003 recount …')`. The brain
 * must skip rows where `quarantined=true` regardless of what this panel shows.
 */
export default function QuarantinedInventoryPanel() {
  const [rows, setRows] = useState<QuarantinedRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [warehouseFilter, setWarehouseFilter] = useState<string>("all");

  // PRD-033 / Track C C2: release a quarantined row via the canonical
  // release_wh_quarantine RPC (sets provenance_reason='manual_adjust'; never
  // touches warehouse_inventory.status — Article 6 safe). Reason >= 10 chars.
  const [releaseTarget, setReleaseTarget] = useState<QuarantinedRow | null>(
    null,
  );
  const [releaseReason, setReleaseReason] = useState("");
  const [releaseBusy, setReleaseBusy] = useState(false);
  const [toast, setToast] = useState<{ ok: boolean; msg: string } | null>(null);

  const fetchRows = useCallback(async () => {
    setLoading(true);
    setError(null);
    const supabase = createClient();

    const { data, error: fetchError } = await supabase
      .from("v_wh_inventory_provenance")
      .select("*")
      .eq("quarantined", true)
      .limit(10000)
      .order("warehouse_name", { ascending: true, nullsFirst: false })
      .order("product_name", { ascending: true, nullsFirst: false });

    if (fetchError) {
      setError(fetchError.message);
      setRows([]);
    } else {
      setRows((data ?? []) as QuarantinedRow[]);
    }
    setLoading(false);
  }, []);

  const confirmRelease = useCallback(async () => {
    if (!releaseTarget || releaseReason.trim().length < 10) return;
    setReleaseBusy(true);
    setToast(null);
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    const { data, error: rpcErr } = await supabase.rpc(
      "release_wh_quarantine",
      {
        p_wh_inventory_id: releaseTarget.wh_inventory_id,
        p_reason: releaseReason.trim(),
        p_verified_by: user?.id ?? null,
      },
    );
    setReleaseBusy(false);
    if (rpcErr) {
      // Surface the guard reason verbatim.
      setToast({ ok: false, msg: rpcErr.message });
      return;
    }
    const res = data as { status?: string; message?: string } | null;
    if (res?.status === "noop") {
      setToast({ ok: false, msg: res.message ?? "Row was not quarantined." });
    } else {
      setToast({
        ok: true,
        msg: `Released ${releaseTarget.product_name ?? "row"} — provenance set to manual_adjust. Pickable only if Active, in-date, stock>0 (v_wh_pickable).`,
      });
    }
    setReleaseTarget(null);
    setReleaseReason("");
    void fetchRows();
  }, [releaseTarget, releaseReason, fetchRows]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial fetch; same pattern as sibling PendingProposalsPanel / PendingRemoveApprovalsPanel
    void fetchRows();
  }, [fetchRows]);

  const warehouses = Array.from(
    new Set(rows.map((r) => r.warehouse_name).filter((n): n is string => !!n)),
  ).sort();

  const visible =
    warehouseFilter === "all"
      ? rows
      : rows.filter((r) => r.warehouse_name === warehouseFilter);

  if (loading) {
    return (
      <div className="rounded-lg border border-neutral-300 bg-neutral-50 p-4 text-sm dark:border-neutral-700 dark:bg-neutral-900">
        Loading quarantined inventory…
      </div>
    );
  }

  if (error) {
    return (
      <div className="rounded-lg border border-rose-300 bg-rose-50 p-4 text-sm dark:border-rose-800 dark:bg-rose-950/20">
        <div className="font-semibold text-rose-800 dark:text-rose-200">
          Could not load quarantined inventory
        </div>
        <div className="mt-1 text-xs text-rose-700 dark:text-rose-300">
          {error}
        </div>
        <div className="mt-2 text-xs text-neutral-500">
          The view <code>v_wh_inventory_provenance</code> ships with PRD-003
          migration <code>20260521230813_*</code>. If this is a fresh
          environment, that migration may not be applied yet.
        </div>
      </div>
    );
  }

  if (rows.length === 0) {
    return (
      <div className="rounded-lg border border-emerald-300 bg-emerald-50 p-4 text-sm dark:border-emerald-800 dark:bg-emerald-950/20">
        <span className="font-semibold text-emerald-800 dark:text-emerald-200">
          No quarantined inventory
        </span>{" "}
        — every <code>warehouse_inventory</code> row carries a known provenance.
      </div>
    );
  }

  return (
    <div className="rounded-lg border border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/20">
      <div className="flex flex-wrap items-center gap-3 p-3">
        <span className="rounded-full bg-amber-500 px-2 py-0.5 text-xs font-semibold text-white">
          {visible.length}
        </span>
        <span className="text-sm font-semibold">Quarantined WH rows</span>
        <span className="text-xs text-neutral-600 dark:text-neutral-400">
          (PRD-003 — provenance missing or pre-migration; refill brain skips
          these)
        </span>

        {warehouses.length > 1 && (
          <select
            value={warehouseFilter}
            onChange={(e) => setWarehouseFilter(e.target.value)}
            className="ml-auto rounded border border-amber-300 bg-white px-2 py-1 text-xs dark:border-amber-700 dark:bg-neutral-900"
          >
            <option value="all">All warehouses ({rows.length})</option>
            {warehouses.map((w) => (
              <option key={w} value={w}>
                {w} ({rows.filter((r) => r.warehouse_name === w).length})
              </option>
            ))}
          </select>
        )}
      </div>

      <div className="overflow-x-auto">
        <table className="w-full text-xs">
          <thead className="bg-amber-100 text-left text-amber-900 dark:bg-amber-900/40 dark:text-amber-100">
            <tr>
              <th className="px-3 py-2 font-semibold">Warehouse</th>
              <th className="px-3 py-2 font-semibold">Product</th>
              <th className="px-3 py-2 text-right font-semibold">WH stock</th>
              <th className="px-3 py-2 text-right font-semibold">Consumer</th>
              <th className="px-3 py-2 font-semibold">Expiry</th>
              <th className="px-3 py-2 font-semibold">Batch</th>
              <th className="px-3 py-2 font-semibold">Provenance</th>
              <th className="px-3 py-2 font-semibold">Last audit</th>
              <th className="px-3 py-2 text-right font-semibold">Action</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-amber-200 dark:divide-amber-800">
            {visible.map((r) => (
              <tr
                key={r.wh_inventory_id}
                className="hover:bg-amber-100/60 dark:hover:bg-amber-900/30"
              >
                <td className="px-3 py-2 font-mono">
                  {r.warehouse_name ?? "—"}
                </td>
                <td className="px-3 py-2">{r.product_name ?? "(unknown)"}</td>
                <td className="px-3 py-2 text-right font-mono">
                  {r.warehouse_stock ?? 0}
                </td>
                <td className="px-3 py-2 text-right font-mono">
                  {r.consumer_stock ?? 0}
                </td>
                <td className="px-3 py-2 font-mono">
                  {r.expiration_date ?? "—"}
                </td>
                <td className="px-3 py-2 font-mono text-neutral-500">
                  {r.batch_id ?? "—"}
                </td>
                <td className="px-3 py-2">
                  <span className="rounded bg-amber-200 px-1.5 py-0.5 font-mono text-[10px] font-semibold text-amber-900 dark:bg-amber-800 dark:text-amber-100">
                    {r.provenance_reason ?? "NULL"}
                  </span>
                </td>
                <td className="px-3 py-2 text-neutral-500">
                  {r.last_audit_reason ?? "—"}
                </td>
                <td className="px-3 py-2 text-right">
                  <button
                    onClick={() => {
                      setReleaseTarget(r);
                      setReleaseReason("");
                      setToast(null);
                    }}
                    className="rounded border border-amber-400 bg-white px-2 py-1 text-[11px] font-semibold text-amber-800 hover:bg-amber-100 dark:bg-neutral-900 dark:text-amber-200"
                  >
                    Release
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* PRD-033 / Track C C2: inline release form (reason >= 10 chars). */}
      {releaseTarget && (
        <div className="border-t border-amber-300 bg-white px-3 py-3 dark:bg-neutral-900">
          <div className="text-xs font-semibold">
            Release quarantine — {releaseTarget.product_name ?? "(unknown)"} @{" "}
            {releaseTarget.warehouse_name ?? "—"} (batch{" "}
            {releaseTarget.batch_id ?? "—"})
          </div>
          <div className="mt-1 text-[11px] text-neutral-600 dark:text-neutral-400">
            Sets provenance to <code>manual_adjust</code> so the refill brain
            stops skipping it. Does not change WH status. State what you
            verified (min 10 chars).
          </div>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <input
              type="text"
              value={releaseReason}
              onChange={(e) => setReleaseReason(e.target.value)}
              placeholder="e.g. physical recount confirms batch + expiry"
              className="min-w-[280px] flex-1 rounded border border-neutral-300 px-2 py-1 text-xs dark:border-neutral-700 dark:bg-neutral-950"
            />
            <button
              onClick={confirmRelease}
              disabled={releaseBusy || releaseReason.trim().length < 10}
              className="rounded bg-amber-600 px-3 py-1 text-xs font-semibold text-white hover:bg-amber-700 disabled:opacity-50"
            >
              {releaseBusy ? "Releasing…" : "Confirm release"}
            </button>
            <button
              onClick={() => {
                setReleaseTarget(null);
                setReleaseReason("");
              }}
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

      <div className="border-t border-amber-200 bg-amber-100/60 px-3 py-2 text-[11px] text-neutral-700 dark:border-amber-800 dark:bg-amber-900/30 dark:text-neutral-300">
        Use <strong>Release</strong> (canonical{" "}
        <code>release_wh_quarantine</code>) once a row is physically verified.
        For a quantity correction instead, call{" "}
        <code>adjust_warehouse_stock</code> with the correct provenance.
      </div>
    </div>
  );
}
