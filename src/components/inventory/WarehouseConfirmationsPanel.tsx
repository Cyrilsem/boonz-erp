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
  pod_product_id: string | null;
  qty: number;
  expiry_date: string | null;
  dispatch_date: string;
  proposed_outcome: ProposedOutcome;
  proposed_target_machine_id: string | null;
  proposed_target_machine_name: string | null;
  proposed_waste_by: string | null;
  age_hours: number;
}

interface VariantOption {
  product_id: string;
  boonz_product_name: string;
}

interface SplitEntry {
  boonz_product_id: string;
  boonz_product_name: string;
  qty: number;
  expiry: string;
  outcome: ConfirmOutcome;
  target_machine_id: string;
  disposal_code: string;
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

  // ONE-LOOP-3 Job 1.6: Split toggle -- reuses the variant/expiry-batch split
  // pattern from PendingRemoveApprovalsPanel.tsx, but calls wm_confirm_line_split
  // (one RPC, one entry per row, each entry may carry its own outcome).
  const [splitMode, setSplitMode] = useState<Record<string, boolean>>({});
  const [variantOptions, setVariantOptions] = useState<
    Record<string, VariantOption[]>
  >({});
  const [splitEntries, setSplitEntries] = useState<
    Record<string, SplitEntry[]>
  >({});

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

  const loadVariantsForRow = useCallback(
    async (row: QueueLine) => {
      if (!row.pod_product_id) return;
      if (variantOptions[row.line_id]) return;
      const supabase = createClient();
      const { data, error: lookupErr } = await supabase
        .from("product_mapping")
        .select(
          "boonz_product_id, boonz_products(product_id, boonz_product_name)",
        )
        .eq("pod_product_id", row.pod_product_id)
        .eq("status", "Active");
      if (lookupErr || !data) {
        console.error(
          "[WarehouseConfirmations] variant lookup failed:",
          lookupErr,
        );
        return;
      }
      const opts: VariantOption[] = [];
      const seen = new Set<string>();
      for (const m of data as Array<{
        boonz_product_id: string;
        boonz_products:
          | { product_id: string; boonz_product_name: string }
          | { product_id: string; boonz_product_name: string }[]
          | null;
      }>) {
        const bp = Array.isArray(m.boonz_products)
          ? m.boonz_products[0]
          : m.boonz_products;
        const id = bp?.product_id ?? m.boonz_product_id;
        if (!id || seen.has(id)) continue;
        seen.add(id);
        opts.push({
          product_id: id,
          boonz_product_name: bp?.boonz_product_name ?? "(unnamed)",
        });
      }
      opts.sort((a, b) =>
        a.boonz_product_name.localeCompare(b.boonz_product_name),
      );
      setVariantOptions((prev) => ({ ...prev, [row.line_id]: opts }));
      const seedExpiry = expiryEdit[row.line_id] || row.expiry_date || "";
      setSplitEntries((prev) => ({
        ...prev,
        [row.line_id]: opts.map((v) => ({
          boonz_product_id: v.product_id,
          boonz_product_name: v.boonz_product_name,
          qty: 0,
          expiry: seedExpiry,
          outcome: "waste" as ConfirmOutcome,
          target_machine_id: "",
          disposal_code: "Waste",
        })),
      }));
    },
    [variantOptions, expiryEdit],
  );

  function toggleSplitMode(row: QueueLine) {
    const willOpen = !splitMode[row.line_id];
    if (willOpen) void loadVariantsForRow(row);
    setSplitMode((prev) => ({ ...prev, [row.line_id]: willOpen }));
  }

  function updateSplitEntry(
    lineId: string,
    idx: number,
    patch: Partial<SplitEntry>,
  ) {
    setSplitEntries((prev) => {
      const list = prev[lineId] ?? [];
      return {
        ...prev,
        [lineId]: list.map((e, i) => (i === idx ? { ...e, ...patch } : e)),
      };
    });
  }

  async function confirmSplit(row: QueueLine) {
    const entries = (splitEntries[row.line_id] ?? []).filter((e) => e.qty > 0);
    const target = qtyEdit[row.line_id] ?? row.qty;
    if (entries.length === 0) {
      setError("Add at least one variant with qty > 0, or close split mode.");
      return;
    }
    const sum = entries.reduce((s, e) => s + e.qty, 0);
    if (sum !== target) {
      setError(
        `Split breakdown sums to ${sum}, but qty is ${target}. Adjust so they total ${target}.`,
      );
      return;
    }
    const missingExpiry = entries.find(
      (e) => e.outcome !== "waste" && !e.expiry,
    );
    if (missingExpiry) {
      setError(
        `"${missingExpiry.boonz_product_name}" needs a batch expiry (waste lines are the only exception).`,
      );
      return;
    }
    const missingTarget = entries.find(
      (e) => e.outcome === "redeploy_pending" && !e.target_machine_id,
    );
    if (missingTarget) {
      setError(
        `"${missingTarget.boonz_product_name}" is set to redeploy but has no target machine.`,
      );
      return;
    }

    setActing(row.line_id);
    setError(null);
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();

    const p_splits = entries.map((e) => ({
      boonz_product_id: e.boonz_product_id,
      qty: e.qty,
      expiry: e.expiry || null,
      outcome: e.outcome,
      target_machine_id:
        e.outcome === "redeploy_pending" ? e.target_machine_id : null,
      disposal_code: e.outcome === "waste" ? e.disposal_code : null,
    }));

    const { error: rpcErr } = await supabase.rpc("wm_confirm_line_split", {
      p_line_id: row.line_id,
      p_splits,
      p_reason: `WM confirmed split via Warehouse Confirmations queue (${row.source})`,
      p_caller: user?.id ?? null,
      p_dry_run: false,
    });

    if (rpcErr) {
      setError(rpcErr.message);
      setActing(null);
      return;
    }
    setActing(null);
    setSplitMode((prev) => {
      const next = { ...prev };
      delete next[row.line_id];
      return next;
    });
    setSplitEntries((prev) => {
      const next = { ...prev };
      delete next[row.line_id];
      return next;
    });
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
          const isSplit = !!splitMode[row.line_id];
          const splits = splitEntries[row.line_id] ?? [];
          const splitSum = splits.reduce((s, e) => s + (e.qty || 0), 0);
          const splitTarget = qtyEdit[row.line_id] ?? row.qty;
          const vOpts = variantOptions[row.line_id] ?? [];

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
                {!isSplit && (
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
                )}
              </div>

              {row.pod_product_id && (
                <div className="mb-3">
                  <button
                    type="button"
                    disabled={isBusy}
                    onClick={() => toggleSplitMode(row)}
                    className="text-xs font-medium text-amber-700 underline hover:text-amber-900 dark:text-amber-300"
                  >
                    {isSplit
                      ? "← Cancel split, confirm as single line"
                      : `↳ Split by variant (this return covers multiple flavours)`}
                  </button>
                  {isSplit && (
                    <div className="mt-2 rounded border border-amber-200 bg-amber-50/50 p-2 dark:border-amber-900 dark:bg-amber-950/30">
                      <p className="mb-2 text-[11px] text-amber-800 dark:text-amber-300">
                        Enter qty, batch expiry, and outcome for each flavour.
                        Total must equal <strong>{splitTarget}</strong>.
                      </p>
                      {vOpts.length === 0 ? (
                        <p className="text-xs text-neutral-500">
                          Loading variants…
                        </p>
                      ) : (
                        <ul className="space-y-2">
                          {splits.map((entry, idx) => (
                            <li
                              key={entry.boonz_product_id}
                              className="flex flex-wrap items-center gap-2 text-xs"
                            >
                              <span className="min-w-0 flex-1 truncate text-neutral-700 dark:text-neutral-300">
                                {entry.boonz_product_name}
                              </span>
                              <input
                                type="number"
                                min={0}
                                value={entry.qty}
                                onChange={(e) =>
                                  updateSplitEntry(row.line_id, idx, {
                                    qty: parseFloat(e.target.value) || 0,
                                  })
                                }
                                placeholder="0"
                                className="w-14 rounded border border-neutral-300 px-2 py-1 text-center dark:border-neutral-600 dark:bg-neutral-900"
                              />
                              <input
                                type="date"
                                value={entry.expiry}
                                onChange={(e) =>
                                  updateSplitEntry(row.line_id, idx, {
                                    expiry: e.target.value,
                                  })
                                }
                                className="rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
                              />
                              <select
                                value={entry.outcome}
                                onChange={(e) =>
                                  updateSplitEntry(row.line_id, idx, {
                                    outcome: e.target.value as ConfirmOutcome,
                                  })
                                }
                                className="rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
                              >
                                <option value="restocked">Back to stock</option>
                                <option value="redeploy_pending">
                                  Redeploy
                                </option>
                                <option value="waste">Waste</option>
                              </select>
                              {entry.outcome === "redeploy_pending" && (
                                <select
                                  value={entry.target_machine_id}
                                  onChange={(e) =>
                                    updateSplitEntry(row.line_id, idx, {
                                      target_machine_id: e.target.value,
                                    })
                                  }
                                  className="rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
                                >
                                  <option value="">target…</option>
                                  {machineOptions.map((m) => (
                                    <option
                                      key={m.machine_id}
                                      value={m.machine_id}
                                    >
                                      {m.official_name}
                                    </option>
                                  ))}
                                </select>
                              )}
                              {entry.outcome === "waste" && (
                                <select
                                  value={entry.disposal_code}
                                  onChange={(e) =>
                                    updateSplitEntry(row.line_id, idx, {
                                      disposal_code: e.target.value,
                                    })
                                  }
                                  className="rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
                                >
                                  {DISPOSAL_CODES.map((c) => (
                                    <option key={c} value={c}>
                                      {c}
                                    </option>
                                  ))}
                                </select>
                              )}
                            </li>
                          ))}
                        </ul>
                      )}
                      <div className="mt-2 flex items-center justify-between text-xs">
                        <span
                          className={
                            splitSum === splitTarget
                              ? "font-semibold text-green-700 dark:text-green-400"
                              : "font-semibold text-rose-700 dark:text-rose-400"
                          }
                        >
                          Sum: {splitSum} / {splitTarget}
                        </span>
                      </div>
                    </div>
                  )}
                </div>
              )}

              {!isSplit && (
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
              )}

              {!isSplit && (
                <p className="mb-2 text-[11px] text-neutral-400">
                  System proposed:{" "}
                  {row.proposed_outcome === "redeploy"
                    ? `redeploy → ${row.proposed_target_machine_name ?? "?"}, waste by ${formatDMY(row.proposed_waste_by)}`
                    : "waste"}
                </p>
              )}

              <button
                onClick={() => (isSplit ? confirmSplit(row) : confirm(row))}
                disabled={isBusy || (isSplit && splitSum !== splitTarget)}
                className="w-full rounded-lg bg-green-600 py-2 text-sm font-medium text-white transition-colors hover:bg-green-700 disabled:opacity-50"
              >
                {isBusy
                  ? "Confirming…"
                  : isSplit
                    ? `✓ Confirm ${splitSum} units across ${splits.filter((e) => e.qty > 0).length} variants`
                    : "✓ Confirm"}
              </button>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
