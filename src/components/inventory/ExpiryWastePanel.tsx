"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface WhRow {
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
  quarantined: boolean;
}

interface MachineOption {
  machine_id: string;
  official_name: string | null;
}

const SENTINEL_DATE = "2099-12-31";

function daysToExpiry(expiration_date: string | null): number | null {
  if (!expiration_date || expiration_date === SENTINEL_DATE) return null;
  const ms = new Date(expiration_date + "T00:00:00Z").getTime() - Date.now();
  return Math.floor(ms / 86_400_000);
}

/**
 * PRD-119 P4: warehouse batches triaged by days-to-expiry, with Write off
 * (warehouse_expire_writeoff) and Redeploy (propose_wh_redeploy) actions.
 * Reads v_wh_inventory_provenance (already the canonical read object for
 * QuarantinedInventoryPanel) rather than a new view — same table, different
 * filter (Active, not quarantined, dated).
 */
export default function ExpiryWastePanel() {
  const [rows, setRows] = useState<WhRow[]>([]);
  const [machines, setMachines] = useState<MachineOption[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [windowDays, setWindowDays] = useState(30);

  const [writeOffTarget, setWriteOffTarget] = useState<WhRow | null>(null);
  const [writeOffReason, setWriteOffReason] = useState("");
  const [writeOffCode, setWriteOffCode] = useState("Waste");
  const [writeOffBusy, setWriteOffBusy] = useState(false);

  const [redeployTarget, setRedeployTarget] = useState<WhRow | null>(null);
  const [redeployMachine, setRedeployMachine] = useState("");
  const [redeployQty, setRedeployQty] = useState("");
  const [redeployReason, setRedeployReason] = useState("");
  const [redeployBusy, setRedeployBusy] = useState(false);

  const [toast, setToast] = useState<{ ok: boolean; msg: string } | null>(null);

  const fetchRows = useCallback(async () => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const { data, error: fetchError } = await supabase
      .from("v_wh_inventory_provenance")
      .select("*")
      .eq("status", "Active")
      .eq("quarantined", false)
      .gt("warehouse_stock", 0)
      .limit(10000);
    if (fetchError) {
      setError(fetchError.message);
      setRows([]);
    } else {
      setRows((data ?? []) as WhRow[]);
    }
    const { data: mData } = await supabase
      .from("machines")
      .select("machine_id, official_name")
      .is("repurposed_at", null)
      .eq("include_in_refill", true)
      .order("official_name")
      .limit(10000);
    setMachines((mData ?? []) as MachineOption[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial fetch, same pattern as QuarantinedInventoryPanel
    void fetchRows();
  }, [fetchRows]);

  const sorted = useMemo(() => {
    return [...rows]
      .filter((r) => {
        const d = daysToExpiry(r.expiration_date);
        return d !== null && d <= windowDays;
      })
      .sort((a, b) => {
        const da = daysToExpiry(a.expiration_date) ?? Infinity;
        const db = daysToExpiry(b.expiration_date) ?? Infinity;
        return da - db;
      });
  }, [rows, windowDays]);

  const confirmWriteOff = useCallback(async () => {
    if (!writeOffTarget || writeOffReason.trim().length < 10) return;
    setWriteOffBusy(true);
    setToast(null);
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    const { error: rpcErr } = await supabase.rpc("warehouse_expire_writeoff", {
      p_wh_inventory_id: writeOffTarget.wh_inventory_id,
      p_reason: writeOffReason.trim(),
      p_caller_id: user?.id ?? null,
      p_disposal_code: writeOffCode,
    });
    setWriteOffBusy(false);
    if (rpcErr) {
      setToast({ ok: false, msg: rpcErr.message });
      return;
    }
    setToast({
      ok: true,
      msg: `Written off ${writeOffTarget.product_name ?? "batch"} (${writeOffCode}).`,
    });
    setWriteOffTarget(null);
    setWriteOffReason("");
    void fetchRows();
  }, [writeOffTarget, writeOffReason, writeOffCode, fetchRows]);

  const confirmRedeploy = useCallback(async () => {
    const qty = Number(redeployQty);
    if (
      !redeployTarget ||
      !redeployMachine ||
      !qty ||
      qty <= 0 ||
      redeployReason.trim().length < 10
    )
      return;
    setRedeployBusy(true);
    setToast(null);
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    const { data, error: rpcErr } = await supabase.rpc("propose_wh_redeploy", {
      p_wh_inventory_id: redeployTarget.wh_inventory_id,
      p_target_machine_id: redeployMachine,
      p_qty: qty,
      p_reason: redeployReason.trim(),
      p_caller: user?.id ?? null,
      p_dry_run: false,
    });
    setRedeployBusy(false);
    if (rpcErr) {
      setToast({ ok: false, msg: rpcErr.message });
      return;
    }
    const res = data as { waste_by?: string } | null;
    setToast({
      ok: true,
      msg: `Redeploy proposed for ${redeployTarget.product_name ?? "batch"} — must land by ${res?.waste_by ?? "?"}.`,
    });
    setRedeployTarget(null);
    setRedeployMachine("");
    setRedeployQty("");
    setRedeployReason("");
    void fetchRows();
  }, [redeployTarget, redeployMachine, redeployQty, redeployReason, fetchRows]);

  if (loading) {
    return (
      <div className="rounded-lg border border-neutral-300 bg-neutral-50 p-4 text-sm dark:border-neutral-700 dark:bg-neutral-900">
        Loading warehouse batches…
      </div>
    );
  }
  if (error) {
    return (
      <div className="rounded-lg border border-rose-300 bg-rose-50 p-4 text-sm dark:border-rose-800 dark:bg-rose-950/20">
        <div className="font-semibold text-rose-800 dark:text-rose-200">
          Could not load warehouse batches
        </div>
        <div className="mt-1 text-xs text-rose-700 dark:text-rose-300">
          {error}
        </div>
      </div>
    );
  }

  return (
    <div className="rounded-lg border border-neutral-300 dark:border-neutral-700">
      <div className="flex flex-wrap items-center gap-3 border-b border-neutral-200 p-3 dark:border-neutral-800">
        <span className="rounded-full bg-neutral-700 px-2 py-0.5 text-xs font-semibold text-white">
          {sorted.length}
        </span>
        <span className="text-sm font-semibold">Batches by days-to-expiry</span>
        <select
          value={windowDays}
          onChange={(e) => setWindowDays(Number(e.target.value))}
          className="ml-auto rounded border border-neutral-300 bg-white px-2 py-1 text-xs dark:border-neutral-700 dark:bg-neutral-900"
        >
          <option value={7}>Next 7 days</option>
          <option value={14}>Next 14 days</option>
          <option value={30}>Next 30 days</option>
          <option value={90}>Next 90 days</option>
        </select>
      </div>

      <div className="overflow-x-auto">
        <table className="w-full text-xs">
          <thead className="bg-neutral-100 text-left dark:bg-neutral-900">
            <tr>
              <th className="px-3 py-2 font-semibold">Days left</th>
              <th className="px-3 py-2 font-semibold">Warehouse</th>
              <th className="px-3 py-2 font-semibold">Product</th>
              <th className="px-3 py-2 text-right font-semibold">Stock</th>
              <th className="px-3 py-2 font-semibold">Expiry</th>
              <th className="px-3 py-2 text-right font-semibold">Actions</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-neutral-200 dark:divide-neutral-800">
            {sorted.map((r) => {
              const d = daysToExpiry(r.expiration_date) ?? 0;
              const urgency =
                d <= 3
                  ? "text-rose-700 dark:text-rose-300 font-bold"
                  : d <= 14
                    ? "text-amber-700 dark:text-amber-300 font-semibold"
                    : "text-neutral-600 dark:text-neutral-400";
              return (
                <tr
                  key={r.wh_inventory_id}
                  className="hover:bg-neutral-50 dark:hover:bg-neutral-900/60"
                >
                  <td className={`px-3 py-2 font-mono ${urgency}`}>{d}d</td>
                  <td className="px-3 py-2 font-mono">
                    {r.warehouse_name ?? "—"}
                  </td>
                  <td className="px-3 py-2">{r.product_name ?? "(unknown)"}</td>
                  <td className="px-3 py-2 text-right font-mono">
                    {r.warehouse_stock ?? 0}
                  </td>
                  <td className="px-3 py-2 font-mono">
                    {r.expiration_date ?? "—"}
                  </td>
                  <td className="px-3 py-2 text-right">
                    <div className="flex justify-end gap-1">
                      <button
                        onClick={() => {
                          setRedeployTarget(r);
                          setRedeployMachine("");
                          setRedeployQty(String(r.warehouse_stock ?? ""));
                          setRedeployReason("");
                          setToast(null);
                        }}
                        className="rounded border border-sky-400 bg-white px-2 py-1 text-[11px] font-semibold text-sky-800 hover:bg-sky-50 dark:bg-neutral-900 dark:text-sky-200"
                      >
                        Redeploy
                      </button>
                      <button
                        onClick={() => {
                          setWriteOffTarget(r);
                          setWriteOffReason("");
                          setWriteOffCode("Waste");
                          setToast(null);
                        }}
                        className="rounded border border-rose-400 bg-white px-2 py-1 text-[11px] font-semibold text-rose-800 hover:bg-rose-50 dark:bg-neutral-900 dark:text-rose-200"
                      >
                        Write off
                      </button>
                    </div>
                  </td>
                </tr>
              );
            })}
            {sorted.length === 0 && (
              <tr>
                <td
                  colSpan={6}
                  className="px-3 py-4 text-center text-neutral-500"
                >
                  No batches expiring in this window.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {writeOffTarget && (
        <div className="border-t border-neutral-300 bg-white px-3 py-3 dark:border-neutral-700 dark:bg-neutral-900">
          <div className="text-xs font-semibold">
            Write off — {writeOffTarget.product_name ?? "(unknown)"} @{" "}
            {writeOffTarget.warehouse_name ?? "—"}
          </div>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <select
              value={writeOffCode}
              onChange={(e) => setWriteOffCode(e.target.value)}
              className="rounded border border-neutral-300 px-2 py-1 text-xs dark:border-neutral-700 dark:bg-neutral-950"
            >
              <option value="Waste">Waste</option>
              <option value="Returning to supplier">
                Returning to supplier
              </option>
            </select>
            <input
              type="text"
              value={writeOffReason}
              onChange={(e) => setWriteOffReason(e.target.value)}
              placeholder="reason (min 10 chars)"
              className="min-w-[280px] flex-1 rounded border border-neutral-300 px-2 py-1 text-xs dark:border-neutral-700 dark:bg-neutral-950"
            />
            <button
              onClick={confirmWriteOff}
              disabled={writeOffBusy || writeOffReason.trim().length < 10}
              className="rounded bg-rose-600 px-3 py-1 text-xs font-semibold text-white hover:bg-rose-700 disabled:opacity-50"
            >
              {writeOffBusy ? "Writing off…" : "Confirm write off"}
            </button>
            <button
              onClick={() => setWriteOffTarget(null)}
              className="rounded border border-neutral-300 px-3 py-1 text-xs dark:border-neutral-700"
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      {redeployTarget && (
        <div className="border-t border-neutral-300 bg-white px-3 py-3 dark:border-neutral-700 dark:bg-neutral-900">
          <div className="text-xs font-semibold">
            Redeploy — {redeployTarget.product_name ?? "(unknown)"} @{" "}
            {redeployTarget.warehouse_name ?? "—"}
          </div>
          <div className="mt-1 text-[11px] text-neutral-600 dark:text-neutral-400">
            Reserves this batch for the target machine. Confirm as delivered
            from the Alerts/Ledger tab once it actually lands.
          </div>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <select
              value={redeployMachine}
              onChange={(e) => setRedeployMachine(e.target.value)}
              className="rounded border border-neutral-300 px-2 py-1 text-xs dark:border-neutral-700 dark:bg-neutral-950"
            >
              <option value="">Target machine…</option>
              {machines.map((m) => (
                <option key={m.machine_id} value={m.machine_id}>
                  {m.official_name ?? m.machine_id}
                </option>
              ))}
            </select>
            <input
              type="number"
              min={1}
              value={redeployQty}
              onChange={(e) => setRedeployQty(e.target.value)}
              className="w-20 rounded border border-neutral-300 px-2 py-1 text-xs dark:border-neutral-700 dark:bg-neutral-950"
            />
            <input
              type="text"
              value={redeployReason}
              onChange={(e) => setRedeployReason(e.target.value)}
              placeholder="reason (min 10 chars)"
              className="min-w-[240px] flex-1 rounded border border-neutral-300 px-2 py-1 text-xs dark:border-neutral-700 dark:bg-neutral-950"
            />
            <button
              onClick={confirmRedeploy}
              disabled={
                redeployBusy ||
                !redeployMachine ||
                !redeployQty ||
                redeployReason.trim().length < 10
              }
              className="rounded bg-sky-600 px-3 py-1 text-xs font-semibold text-white hover:bg-sky-700 disabled:opacity-50"
            >
              {redeployBusy ? "Proposing…" : "Confirm redeploy"}
            </button>
            <button
              onClick={() => setRedeployTarget(null)}
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
