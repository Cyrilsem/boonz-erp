"use client";

// PRD-119 §4.1 — the single Warehouse Confirmations queue. Replaces
// PendingRemoveApprovalsPanel (BUG-010 driver-return approvals) and the
// returns-awaiting-approval path (approve_return, which never had an FE call
// site). Every field action that moved goods lands here as one line, pre-filled
// from v_wm_confirmations with a system-proposed outcome; the WM counts, edits
// if needed, and taps Confirm. Her confirm — wm_confirm_line — is the only
// write to warehouse_inventory and disposition_events for that line.
//
// Both source panels stay in the tree (not deleted) per the PRD-119 build
// order — only their render call is removed from the page — until P4 sign-off.

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

type ProposedOutcome = "redeploy" | "waste";
type ConfirmOutcome = "restocked" | "redeploy_pending" | "waste";

interface QueueLine {
  line_id: string;
  source: "dispatch_return" | "driver_expiry_check";
  dispatch_id: string | null;
  machine_id: string;
  machine_name: string;
  shelf_id: string | null;
  shelf_code: string | null;
  boonz_product_id: string;
  boonz_product_name: string;
  qty: number;
  expiry_date: string | null;
  dispatch_date: string;
  proposed_outcome: ProposedOutcome;
  proposed_target_machine_id: string | null;
  proposed_target_machine_name: string | null;
  proposed_waste_by: string | null;
  age_hours: number;
}

const DISPOSAL_CODES = [
  "Waste",
  "Returning to supplier",
  "Returned to supplier",
] as const;

function formatDMY(iso: string | null): string {
  if (!iso) return "no date";
  const [y, m, d] = iso.split("-");
  return `${d}/${m}/${y}`;
}

export default function WarehouseConfirmationsPanel() {
  const [rows, setRows] = useState<QueueLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [acting, setActing] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const [qtyEdit, setQtyEdit] = useState<Record<string, number>>({});
  const [expiryEdit, setExpiryEdit] = useState<Record<string, string>>({});
  const [outcomeEdit, setOutcomeEdit] = useState<
    Record<string, ConfirmOutcome>
  >({});
  const [targetEdit, setTargetEdit] = useState<Record<string, string>>({});
  const [disposalEdit, setDisposalEdit] = useState<Record<string, string>>({});
  const [machineOptions, setMachineOptions] = useState<
    { machine_id: string; official_name: string }[]
  >([]);

  const fetchRows = useCallback(async () => {
    const supabase = createClient();
    const { data, error: fetchErr } = await supabase
      .from("v_wm_confirmations")
      .select("*")
      .order("age_hours", { ascending: false });
    if (fetchErr) {
      console.error("[WarehouseConfirmations] fetch failed:", fetchErr);
      setError(fetchErr.message);
      setRows([]);
      setLoading(false);
      return;
    }
    const r = (data ?? []) as QueueLine[];
    setRows(r);
    setQtyEdit((prev) => {
      const next = { ...prev };
      r.forEach((row) => {
        if (!(row.line_id in next)) next[row.line_id] = row.qty;
      });
      return next;
    });
    setExpiryEdit((prev) => {
      const next = { ...prev };
      r.forEach((row) => {
        if (!(row.line_id in next)) next[row.line_id] = row.expiry_date ?? "";
      });
      return next;
    });
    setOutcomeEdit((prev) => {
      const next = { ...prev };
      r.forEach((row) => {
        if (!(row.line_id in next))
          next[row.line_id] =
            row.proposed_outcome === "redeploy" ? "redeploy_pending" : "waste";
      });
      return next;
    });
    setTargetEdit((prev) => {
      const next = { ...prev };
      r.forEach((row) => {
        if (!(row.line_id in next) && row.proposed_target_machine_id)
          next[row.line_id] = row.proposed_target_machine_id;
      });
      return next;
    });
    setDisposalEdit((prev) => {
      const next = { ...prev };
      r.forEach((row) => {
        if (!(row.line_id in next)) next[row.line_id] = "Waste";
      });
      return next;
    });
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchRows();
  }, [fetchRows]);

  useEffect(() => {
    const supabase = createClient();
    supabase
      .from("machines")
      .select("machine_id, official_name")
      .eq("status", "Active")
      .order("official_name")
      .limit(10000)
      .then(({ data }) => {
        setMachineOptions(
          (data ?? []) as { machine_id: string; official_name: string }[],
        );
      });
  }, []);

  async function confirm(row: QueueLine) {
    setActing(row.line_id);
    setError(null);
    const supabase = createClient();
    const outcome = outcomeEdit[row.line_id] ?? "waste";
    const qty = qtyEdit[row.line_id] ?? row.qty;
    const expiry = expiryEdit[row.line_id] || null;

    if (
      outcome === "redeploy_pending" &&
      (!targetEdit[row.line_id] || !expiry)
    ) {
      setActing(null);
      setError("Redeploy needs a target machine and a batch expiry.");
      return;
    }
    if (outcome === "waste" && !disposalEdit[row.line_id]) {
      setActing(null);
      setError("Pick a disposal code for waste.");
      return;
    }

    const {
      data: { user },
    } = await supabase.auth.getUser();

    const { error: rpcErr } = await supabase.rpc("wm_confirm_line", {
      p_line_id: row.line_id,
      p_qty: qty,
      p_expiry: expiry,
      p_outcome: outcome,
      p_target_machine_id:
        outcome === "redeploy_pending" ? targetEdit[row.line_id] : null,
      p_disposal_code: outcome === "waste" ? disposalEdit[row.line_id] : null,
      p_reason: `WM confirmed via Warehouse Confirmations queue (${row.source})`,
      p_caller: user?.id ?? null,
      p_dry_run: false,
    });

    if (rpcErr) {
      setError(rpcErr.message);
      setActing(null);
      return;
    }
    setActing(null);
    await fetchRows();
  }

  if (loading) return null;
  if (rows.length === 0) return null;

  return (
    <div className="mb-4 rounded-xl border-l-4 border-l-amber-400 border border-neutral-200 bg-amber-50 p-4 dark:border-neutral-800 dark:bg-amber-950/20">
      <div className="mb-3 flex items-center gap-2">
        <span className="text-base">📦</span>
        <h3 className="text-sm font-bold uppercase tracking-wide text-amber-700 dark:text-amber-400">
          Warehouse Confirmations ({rows.length})
        </h3>
      </div>
      <p className="mb-3 text-xs text-amber-700/80 dark:text-amber-400/80">
        Goods physically left a machine and are waiting on your receipt. Count
        what arrived, confirm or edit the proposed outcome — this is the only
        write to stock and the disposition ledger for these lines.
      </p>

      {error && (
        <p className="mb-3 rounded-lg bg-rose-50 px-3 py-2 text-xs text-rose-700 dark:bg-rose-950/30 dark:text-rose-400">
          {error}
        </p>
      )}

      <ul className="space-y-2">
        {rows.map((row) => {
          const isOld = row.age_hours > 48;
          const outcome = outcomeEdit[row.line_id] ?? "waste";
          const isBusy = acting === row.line_id;

          return (
            <li
              key={row.line_id}
              className={`rounded-lg border p-3 dark:bg-neutral-950 ${
                isOld
                  ? "border-red-300 bg-red-50 dark:border-red-900"
                  : "border-amber-200 bg-white dark:border-amber-900"
              }`}
            >
              <div className="mb-2 flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <p className="text-sm font-semibold">
                    {row.boonz_product_name}
                  </p>
                  <p className="text-xs text-neutral-500">
                    {row.machine_name}
                    {row.shelf_code ? ` / ${row.shelf_code}` : ""} ·{" "}
                    {row.source === "driver_expiry_check"
                      ? "expiry check"
                      : "return"}
                  </p>
                </div>
                <span
                  className={`shrink-0 text-xs ${isOld ? "font-semibold text-red-600 dark:text-red-400" : "text-neutral-400"}`}
                >
                  {Math.round(row.age_hours)}h ago
                </span>
              </div>

              <div className="mb-3 flex flex-wrap items-center gap-3 text-xs">
                <label className="flex items-center gap-2 text-neutral-500">
                  Qty:
                  <input
                    type="number"
                    min={1}
                    disabled={isBusy}
                    value={qtyEdit[row.line_id] ?? row.qty}
                    onChange={(e) =>
                      setQtyEdit((prev) => ({
                        ...prev,
                        [row.line_id]: Math.max(1, Number(e.target.value) || 1),
                      }))
                    }
                    className="w-16 rounded border border-neutral-300 px-2 py-1 text-center dark:border-neutral-600 dark:bg-neutral-900"
                  />
                </label>
                <label className="flex items-center gap-2 text-neutral-500">
                  Batch expiry:
                  <input
                    type="date"
                    disabled={isBusy}
                    value={expiryEdit[row.line_id] ?? ""}
                    onChange={(e) =>
                      setExpiryEdit((prev) => ({
                        ...prev,
                        [row.line_id]: e.target.value,
                      }))
                    }
                    className="rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
                  />
                </label>
              </div>

              <div className="mb-3 flex flex-wrap items-center gap-3 text-xs">
                <label className="flex items-center gap-2 text-neutral-500">
                  Outcome:
                  <select
                    disabled={isBusy}
                    value={outcome}
                    onChange={(e) =>
                      setOutcomeEdit((prev) => ({
                        ...prev,
                        [row.line_id]: e.target.value as ConfirmOutcome,
                      }))
                    }
                    className="rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
                  >
                    <option value="restocked">Back to stock</option>
                    <option value="redeploy_pending">Redeploy</option>
                    <option value="waste">Waste</option>
                  </select>
                </label>

                {outcome === "redeploy_pending" && (
                  <label className="flex items-center gap-2 text-neutral-500">
                    Target machine:
                    <select
                      disabled={isBusy}
                      value={targetEdit[row.line_id] ?? ""}
                      onChange={(e) =>
                        setTargetEdit((prev) => ({
                          ...prev,
                          [row.line_id]: e.target.value,
                        }))
                      }
                      className="rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
                    >
                      <option value="">select…</option>
                      {machineOptions.map((m) => (
                        <option key={m.machine_id} value={m.machine_id}>
                          {m.official_name}
                        </option>
                      ))}
                    </select>
                  </label>
                )}

                {outcome === "waste" && (
                  <label className="flex items-center gap-2 text-neutral-500">
                    Disposal code:
                    <select
                      disabled={isBusy}
                      value={disposalEdit[row.line_id] ?? "Waste"}
                      onChange={(e) =>
                        setDisposalEdit((prev) => ({
                          ...prev,
                          [row.line_id]: e.target.value,
                        }))
                      }
                      className="rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
                    >
                      {DISPOSAL_CODES.map((c) => (
                        <option key={c} value={c}>
                          {c}
                        </option>
                      ))}
                    </select>
                  </label>
                )}
              </div>

              <p className="mb-2 text-[11px] text-neutral-400">
                System proposed:{" "}
                {row.proposed_outcome === "redeploy"
                  ? `redeploy → ${row.proposed_target_machine_name ?? "?"}, waste by ${formatDMY(row.proposed_waste_by)}`
                  : "waste"}
              </p>

              <button
                onClick={() => confirm(row)}
                disabled={isBusy}
                className="w-full rounded-lg bg-green-600 py-2 text-sm font-medium text-white transition-colors hover:bg-green-700 disabled:opacity-50"
              >
                {isBusy ? "Confirming…" : "✓ Confirm"}
              </button>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
