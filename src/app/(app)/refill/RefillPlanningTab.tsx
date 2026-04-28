"use client";

import { useState, useCallback, useRef } from "react";
import { createBrowserClient } from "@supabase/ssr";

// ── Types ──────────────────────────────────────────────────────────────────────

type PlanRow = {
  machine_name: string;
  machine_priority: number;
  shelf_code: string;
  pod_product_name: string;
  boonz_product_name: string;
  action: "REFILL" | "REMOVE" | "ADD NEW";
  quantity: number;
  current_stock: number;
  max_stock: number;
  smart_target: number;
  tier: string;
  global_score: number;
  sold_7d: number;
  fill_pct: number;
  comment: string;
};

type PlanAlert = {
  type: string;
  machine?: string;
  shelf?: string;
  product?: string;
  msg?: string;
  reason?: string;
};

type AddRowForm = {
  machine_name: string;
  shelf_code: string;
  action: "REFILL" | "ADD NEW" | "REMOVE";
  pod_product_name: string;
  boonz_product_name: string;
  quantity: number;
  current_stock: number;
  max_stock: number;
  comment: string;
};

// ── Helpers ────────────────────────────────────────────────────────────────────

const FILTER_OPTIONS = [
  { value: "all", label: "All machines" },
  { value: "office", label: "Office" },
  { value: "coworking", label: "Co-working" },
  { value: "vml", label: "VML" },
  { value: "wpp", label: "WPP" },
  { value: "vox", label: "VOX" },
  { value: "ohmydesk", label: "OhmyDesk" },
  { value: "grit", label: "GRIT" },
  { value: "addmind", label: "ADDMIND" },
];

function actionBadge(action: string) {
  const styles: Record<string, string> = {
    REFILL:
      "bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-300",
    REMOVE:
      "bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-300",
    "ADD NEW":
      "bg-green-100 text-green-700 dark:bg-green-900/40 dark:text-green-300",
  };
  return (
    <span
      className={`inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-semibold ${
        styles[action] ?? "bg-neutral-100 text-neutral-600"
      }`}
    >
      {action}
    </span>
  );
}

function tierDot(tier: string) {
  const colors: Record<string, string> = {
    double_down: "bg-green-500",
    keep: "bg-blue-500",
    monitor: "bg-amber-500",
    discontinue: "bg-red-500",
  };
  return (
    <span
      className={`inline-block w-2 h-2 rounded-full mr-1.5 flex-shrink-0 ${
        colors[tier] ?? "bg-neutral-400"
      }`}
    />
  );
}

function priorityBadge(p: number) {
  if (p === 1)
    return (
      <span className="text-[9px] font-bold text-red-600 dark:text-red-400">
        P1
      </span>
    );
  if (p === 2)
    return (
      <span className="text-[9px] font-bold text-amber-600 dark:text-amber-400">
        P2
      </span>
    );
  return null;
}

const BLANK_FORM: AddRowForm = {
  machine_name: "",
  shelf_code: "",
  action: "REFILL",
  pod_product_name: "",
  boonz_product_name: "",
  quantity: 1,
  current_stock: 0,
  max_stock: 10,
  comment: "",
};

// ── Component ──────────────────────────────────────────────────────────────────

export function RefillPlanningTab({
  selectedDate,
  machineNames,
}: {
  selectedDate: string;
  machineNames: string[];
}) {
  const [filter, setFilter] = useState("all");
  const [generating, setGenerating] = useState(false);
  const [writing, setWriting] = useState(false);
  const [planRows, setPlanRows] = useState<PlanRow[]>([]);
  const [alerts, setAlerts] = useState<PlanAlert[]>([]);
  const [machineCount, setMachineCount] = useState(0);
  const [generated, setGenerated] = useState(false);
  const [writeResult, setWriteResult] = useState<{
    ok: boolean;
    msg: string;
  } | null>(null);

  // Row-level edit state (index → value)
  const [removed, setRemoved] = useState<Set<number>>(new Set());
  const [editedQty, setEditedQty] = useState<Record<number, number>>({});

  // Add row modal
  const [showAdd, setShowAdd] = useState(false);
  const [addForm, setAddForm] = useState<AddRowForm>(BLANK_FORM);

  const supabase = createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  );

  // ── Generate (dry run) ───────────────────────────────────────────────────────
  const generate = useCallback(async () => {
    setGenerating(true);
    setWriteResult(null);
    setRemoved(new Set());
    setEditedQty({});
    setGenerated(false);

    const { data, error } = await supabase.rpc("auto_generate_refill_plan", {
      p_filter: filter,
      p_plan_date: selectedDate,
      p_dry_run: true,
    });

    setGenerating(false);
    if (error) {
      setWriteResult({ ok: false, msg: `Generation failed: ${error.message}` });
      return;
    }
    if (data?.status === "error") {
      setWriteResult({ ok: false, msg: `Error: ${data.error}` });
      return;
    }

    setPlanRows(data?.rows ?? []);
    setAlerts(data?.alerts ?? []);
    setMachineCount(data?.machines ?? 0);
    setGenerated(true);
  }, [filter, selectedDate, supabase]);

  // ── Write plan ───────────────────────────────────────────────────────────────
  const writePlan = useCallback(async () => {
    setWriting(true);
    setWriteResult(null);

    const finalRows = planRows
      .filter((_, idx) => !removed.has(idx))
      .map((row, idx) => ({
        ...row,
        quantity: idx in editedQty ? editedQty[idx] : row.quantity,
      }));

    // write_refill_plan(p_plan_date, p_lines) → writes to refill_plan_output
    // Dispatch mirror happens when operator approves the plan in Stock Snapshot tab
    const { data, error } = await supabase.rpc("write_refill_plan", {
      p_plan_date: selectedDate,
      p_lines: finalRows,
    });

    setWriting(false);
    if (error) {
      setWriteResult({ ok: false, msg: `Write failed: ${error.message}` });
    } else {
      const result = data as { status?: string; lines_written?: number } | null;
      const written = result?.lines_written ?? finalRows.length;
      setWriteResult({
        ok: true,
        msg: `Plan written — ${written} lines for ${selectedDate}`,
      });
    }
  }, [planRows, removed, editedQty, selectedDate, supabase]);

  // ── Add row ──────────────────────────────────────────────────────────────────
  const addRow = useCallback(() => {
    if (!addForm.machine_name || !addForm.shelf_code || !addForm.boonz_product_name) return;
    const newRow: PlanRow = {
      machine_name: addForm.machine_name,
      machine_priority: 5,
      shelf_code: addForm.shelf_code.toUpperCase(),
      pod_product_name: addForm.pod_product_name || addForm.boonz_product_name,
      boonz_product_name: addForm.boonz_product_name,
      action: addForm.action,
      quantity: addForm.quantity,
      current_stock: addForm.current_stock,
      max_stock: addForm.max_stock,
      smart_target: addForm.quantity + addForm.current_stock,
      tier: "keep",
      global_score: 0,
      sold_7d: 0,
      fill_pct: addForm.max_stock > 0 ? Math.round((addForm.current_stock / addForm.max_stock) * 100) : 0,
      comment: addForm.comment || `Manual addition — ${addForm.action}`,
    };
    setPlanRows((prev) => [...prev, newRow]);
    setShowAdd(false);
    setAddForm(BLANK_FORM);
    if (!generated) setGenerated(true);
  }, [addForm, generated]);

  // ── Derived ──────────────────────────────────────────────────────────────────
  const activeRows = planRows.filter((_, i) => !removed.has(i));
  const totalUnits = activeRows
    .filter((r) => r.action === "REFILL")
    .reduce((s, r, idx) => {
      const realIdx = planRows.indexOf(r);
      return s + (realIdx in editedQty ? editedQty[realIdx] : r.quantity);
    }, 0);
  const swapCount = activeRows.filter((r) => r.action === "REMOVE").length;

  // Group by machine
  const byMachine = planRows.reduce(
    (acc, row, idx) => {
      if (!acc[row.machine_name]) acc[row.machine_name] = [];
      acc[row.machine_name].push({ row, idx });
      return acc;
    },
    {} as Record<string, { row: PlanRow; idx: number }[]>,
  );

  const noStockAlerts = alerts.filter((a) => a.type === "no_stock");
  const warnAlerts = alerts.filter((a) => a.type === "warning");

  // ── Render ────────────────────────────────────────────────────────────────────
  return (
    <div>
      {/* ── Controls ──────────────────────────────────────────────────────── */}
      <div className="bg-white dark:bg-neutral-950 border border-neutral-200 dark:border-neutral-800 rounded-xl p-5 mb-6">
        <div className="flex items-center gap-3 flex-wrap">
          {/* Filter */}
          <select
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
            className="rounded-lg border border-neutral-300 dark:border-neutral-700 px-3 py-2 text-sm bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100"
          >
            {FILTER_OPTIONS.map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </select>

          {/* Generate */}
          <button
            onClick={generate}
            disabled={generating}
            className="flex items-center gap-2 px-4 py-2 rounded-lg bg-neutral-900 text-white text-sm font-medium hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
          >
            {generating && (
              <svg className="animate-spin h-3.5 w-3.5" viewBox="0 0 24 24" fill="none">
                <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 5.373 0 12h4z" />
              </svg>
            )}
            {generating ? "Generating…" : "Generate plan"}
          </button>

          {/* Add row */}
          {generated && (
            <button
              onClick={() => setShowAdd(true)}
              className="px-4 py-2 rounded-lg border border-neutral-300 dark:border-neutral-700 text-sm font-medium text-neutral-700 dark:text-neutral-300 hover:bg-neutral-50 dark:hover:bg-neutral-900"
            >
              + Add row
            </button>
          )}

          {/* Write plan */}
          {generated && activeRows.length > 0 && (
            <button
              onClick={writePlan}
              disabled={writing}
              className="ml-auto flex items-center gap-2 px-5 py-2 rounded-lg bg-green-700 text-white text-sm font-medium hover:bg-green-800 disabled:opacity-50"
            >
              {writing ? "Writing…" : `Write plan (${activeRows.length} lines)`}
            </button>
          )}
        </div>

        {/* Write result */}
        {writeResult && (
          <div
            className={`mt-3 rounded-lg px-3 py-2 text-sm font-medium ${
              writeResult.ok
                ? "bg-green-50 text-green-700 dark:bg-green-950/30 dark:text-green-400"
                : "bg-red-50 text-red-700 dark:bg-red-950/30 dark:text-red-400"
            }`}
          >
            {writeResult.ok ? "✓ " : "✗ "}
            {writeResult.msg}
          </div>
        )}
      </div>

      {/* ── Alerts ────────────────────────────────────────────────────────── */}
      {(noStockAlerts.length > 0 || warnAlerts.length > 0) && (
        <div className="mb-5 space-y-2">
          {warnAlerts.map((a, i) => (
            <div
              key={i}
              className="rounded-lg bg-amber-50 dark:bg-amber-950/20 border border-amber-200 dark:border-amber-800 px-3 py-2 text-xs text-amber-700 dark:text-amber-300"
            >
              ⚠️ {a.msg}
            </div>
          ))}
          {noStockAlerts.length > 0 && (
            <div className="rounded-lg bg-red-50 dark:bg-red-950/20 border border-red-200 dark:border-red-800 px-3 py-2 text-xs text-red-700 dark:text-red-300">
              🚨 No WH stock for{" "}
              {noStockAlerts
                .map((a) => `${a.machine} / ${a.shelf} — ${a.product}`)
                .join(", ")}
              . Procurement needed.
            </div>
          )}
        </div>
      )}

      {/* ── Summary strip ─────────────────────────────────────────────────── */}
      {generated && (
        <div className="grid grid-cols-4 gap-3 mb-6">
          {[
            ["Machines", machineCount],
            ["Lines", activeRows.length],
            ["Refill units", totalUnits],
            ["Swaps", swapCount],
          ].map(([label, val]) => (
            <div
              key={label as string}
              className="bg-neutral-50 dark:bg-neutral-900 rounded-xl p-4"
            >
              <div className="text-2xl font-medium leading-none">{val}</div>
              <div className="text-xs text-neutral-500 mt-1">{label}</div>
            </div>
          ))}
        </div>
      )}

      {/* ── Empty state ────────────────────────────────────────────────────── */}
      {!generated && !generating && (
        <div className="flex flex-col items-center justify-center py-20 text-center">
          <div className="text-4xl mb-3">🧠</div>
          <p className="text-sm font-medium text-neutral-600 dark:text-neutral-400 mb-1">
            Refill plan builder
          </p>
          <p className="text-xs text-neutral-400 max-w-sm">
            Select a filter and click <strong>Generate plan</strong> to compute tomorrow&apos;s
            refill plan. Review and edit before writing.
          </p>
        </div>
      )}

      {/* ── Plan table by machine ─────────────────────────────────────────── */}
      {generated &&
        Object.entries(byMachine).map(([machineName, rows]) => {
          const hasActive = rows.some(({ idx }) => !removed.has(idx));
          return (
            <div
              key={machineName}
              className="mb-4 border border-neutral-200 dark:border-neutral-800 rounded-xl overflow-hidden"
            >
              {/* Machine header */}
              <div className="flex items-center justify-between px-4 py-3 bg-neutral-50 dark:bg-neutral-900 border-b border-neutral-200 dark:border-neutral-800">
                <span className="font-medium text-sm">{machineName}</span>
                <span className="text-xs text-neutral-500">
                  {rows.filter(({ idx }) => !removed.has(idx)).length} active
                  lines ·{" "}
                  {rows
                    .filter(
                      ({ row, idx }) =>
                        !removed.has(idx) && row.action === "REFILL",
                    )
                    .reduce((s, { row, idx }) => s + (idx in editedQty ? editedQty[idx] : row.quantity), 0)}{" "}
                  units
                </span>
              </div>

              {/* Table */}
              <div className="overflow-x-auto">
                <table className="w-full text-xs">
                  <thead>
                    <tr className="text-left text-neutral-400 border-b border-neutral-100 dark:border-neutral-800">
                      <th className="px-4 py-2 font-medium">Shelf</th>
                      <th className="px-4 py-2 font-medium">Action</th>
                      <th className="px-4 py-2 font-medium">Product</th>
                      <th className="px-4 py-2 font-medium text-right">
                        Stock
                      </th>
                      <th className="px-4 py-2 font-medium text-right">Qty</th>
                      <th className="px-4 py-2 font-medium text-right">7d</th>
                      <th className="px-3 py-2" />
                    </tr>
                  </thead>
                  <tbody>
                    {rows.map(({ row, idx }) => (
                      <tr
                        key={idx}
                        className={`border-b border-neutral-50 dark:border-neutral-800/50 last:border-0 transition-opacity ${
                          removed.has(idx)
                            ? "opacity-30 line-through"
                            : "hover:bg-neutral-50/50 dark:hover:bg-neutral-900/30"
                        }`}
                      >
                        <td className="px-4 py-2.5 font-mono text-xs">
                          {priorityBadge(row.machine_priority)}{" "}
                          {row.shelf_code}
                        </td>
                        <td className="px-4 py-2.5">
                          {actionBadge(row.action)}
                        </td>
                        <td className="px-4 py-2.5 max-w-[200px]">
                          <div className="flex items-center">
                            {tierDot(row.tier)}
                            <div className="min-w-0">
                              <div className="truncate text-xs font-medium">
                                {row.pod_product_name}
                              </div>
                              <div className="truncate text-[10px] text-neutral-500">
                                {row.boonz_product_name}
                              </div>
                            </div>
                          </div>
                        </td>
                        <td className="px-4 py-2.5 text-right text-neutral-500 whitespace-nowrap">
                          {row.current_stock}/{row.max_stock}
                        </td>
                        <td className="px-4 py-2.5 text-right">
                          {row.action === "REMOVE" ? (
                            <span className="text-neutral-400">—</span>
                          ) : (
                            <input
                              type="number"
                              min={0}
                              max={row.max_stock}
                              value={
                                idx in editedQty ? editedQty[idx] : row.quantity
                              }
                              onChange={(e) => {
                                const v = parseInt(e.target.value) || 0;
                                setEditedQty((prev) => ({ ...prev, [idx]: v }));
                              }}
                              disabled={removed.has(idx)}
                              className="w-14 text-right rounded border border-neutral-300 dark:border-neutral-700 px-1.5 py-1 text-xs bg-white dark:bg-neutral-900 disabled:opacity-50"
                            />
                          )}
                        </td>
                        <td className="px-4 py-2.5 text-right text-neutral-500">
                          {row.sold_7d}
                        </td>
                        <td className="px-3 py-2.5 text-right">
                          <button
                            onClick={() =>
                              setRemoved((prev) => {
                                const n = new Set(prev);
                                n.has(idx) ? n.delete(idx) : n.add(idx);
                                return n;
                              })
                            }
                            className="text-[10px] text-neutral-400 hover:text-red-500 dark:hover:text-red-400 px-1 py-0.5 rounded"
                          >
                            {removed.has(idx) ? "Restore" : "×"}
                          </button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          );
        })}

      {/* ── Add Row Modal ──────────────────────────────────────────────────── */}
      {showAdd && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4">
          <div className="w-full max-w-md bg-white dark:bg-neutral-950 rounded-2xl shadow-2xl p-6">
            <div className="flex items-center justify-between mb-5">
              <h3 className="font-semibold text-base">Add plan row</h3>
              <button
                onClick={() => setShowAdd(false)}
                className="text-neutral-400 hover:text-neutral-600 text-lg"
              >
                ✕
              </button>
            </div>

            <div className="space-y-3">
              {/* Machine */}
              <div>
                <label className="block text-xs text-neutral-500 mb-1">
                  Machine <span className="text-red-500">*</span>
                </label>
                <select
                  value={addForm.machine_name}
                  onChange={(e) =>
                    setAddForm((f) => ({ ...f, machine_name: e.target.value }))
                  }
                  className="w-full rounded-lg border border-neutral-300 dark:border-neutral-700 px-3 py-2 text-sm bg-white dark:bg-neutral-900"
                >
                  <option value="">Select machine…</option>
                  {machineNames.map((m) => (
                    <option key={m} value={m}>
                      {m}
                    </option>
                  ))}
                </select>
              </div>

              {/* Shelf + Action */}
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs text-neutral-500 mb-1">
                    Shelf <span className="text-red-500">*</span>
                  </label>
                  <input
                    type="text"
                    placeholder="A01"
                    value={addForm.shelf_code}
                    onChange={(e) =>
                      setAddForm((f) => ({ ...f, shelf_code: e.target.value }))
                    }
                    className="w-full rounded-lg border border-neutral-300 dark:border-neutral-700 px-3 py-2 text-sm bg-white dark:bg-neutral-900"
                  />
                </div>
                <div>
                  <label className="block text-xs text-neutral-500 mb-1">
                    Action
                  </label>
                  <select
                    value={addForm.action}
                    onChange={(e) =>
                      setAddForm((f) => ({
                        ...f,
                        action: e.target.value as AddRowForm["action"],
                      }))
                    }
                    className="w-full rounded-lg border border-neutral-300 dark:border-neutral-700 px-3 py-2 text-sm bg-white dark:bg-neutral-900"
                  >
                    <option value="REFILL">REFILL</option>
                    <option value="ADD NEW">ADD NEW</option>
                    <option value="REMOVE">REMOVE</option>
                  </select>
                </div>
              </div>

              {/* Boonz product */}
              <div>
                <label className="block text-xs text-neutral-500 mb-1">
                  Boonz product name <span className="text-red-500">*</span>
                </label>
                <input
                  type="text"
                  placeholder="e.g. Evian - Regular"
                  value={addForm.boonz_product_name}
                  onChange={(e) =>
                    setAddForm((f) => ({
                      ...f,
                      boonz_product_name: e.target.value,
                    }))
                  }
                  className="w-full rounded-lg border border-neutral-300 dark:border-neutral-700 px-3 py-2 text-sm bg-white dark:bg-neutral-900"
                />
              </div>

              {/* Pod product */}
              <div>
                <label className="block text-xs text-neutral-500 mb-1">
                  Pod product name
                </label>
                <input
                  type="text"
                  placeholder="e.g. Evian (defaults to boonz name)"
                  value={addForm.pod_product_name}
                  onChange={(e) =>
                    setAddForm((f) => ({
                      ...f,
                      pod_product_name: e.target.value,
                    }))
                  }
                  className="w-full rounded-lg border border-neutral-300 dark:border-neutral-700 px-3 py-2 text-sm bg-white dark:bg-neutral-900"
                />
              </div>

              {/* Qty / Current / Max */}
              <div className="grid grid-cols-3 gap-3">
                <div>
                  <label className="block text-xs text-neutral-500 mb-1">
                    Qty
                  </label>
                  <input
                    type="number"
                    min={0}
                    value={addForm.quantity}
                    onChange={(e) =>
                      setAddForm((f) => ({
                        ...f,
                        quantity: parseInt(e.target.value) || 0,
                      }))
                    }
                    className="w-full rounded-lg border border-neutral-300 dark:border-neutral-700 px-3 py-2 text-sm bg-white dark:bg-neutral-900"
                  />
                </div>
                <div>
                  <label className="block text-xs text-neutral-500 mb-1">
                    Current stock
                  </label>
                  <input
                    type="number"
                    min={0}
                    value={addForm.current_stock}
                    onChange={(e) =>
                      setAddForm((f) => ({
                        ...f,
                        current_stock: parseInt(e.target.value) || 0,
                      }))
                    }
                    className="w-full rounded-lg border border-neutral-300 dark:border-neutral-700 px-3 py-2 text-sm bg-white dark:bg-neutral-900"
                  />
                </div>
                <div>
                  <label className="block text-xs text-neutral-500 mb-1">
                    Max stock
                  </label>
                  <input
                    type="number"
                    min={1}
                    value={addForm.max_stock}
                    onChange={(e) =>
                      setAddForm((f) => ({
                        ...f,
                        max_stock: parseInt(e.target.value) || 10,
                      }))
                    }
                    className="w-full rounded-lg border border-neutral-300 dark:border-neutral-700 px-3 py-2 text-sm bg-white dark:bg-neutral-900"
                  />
                </div>
              </div>

              {/* Comment */}
              <div>
                <label className="block text-xs text-neutral-500 mb-1">
                  Comment (optional)
                </label>
                <input
                  type="text"
                  value={addForm.comment}
                  onChange={(e) =>
                    setAddForm((f) => ({ ...f, comment: e.target.value }))
                  }
                  className="w-full rounded-lg border border-neutral-300 dark:border-neutral-700 px-3 py-2 text-sm bg-white dark:bg-neutral-900"
                />
              </div>
            </div>

            <div className="mt-5 flex gap-3">
              <button
                onClick={() => setShowAdd(false)}
                className="flex-1 rounded-xl border border-neutral-300 dark:border-neutral-700 py-2.5 text-sm font-medium text-neutral-600 dark:text-neutral-400 hover:bg-neutral-50 dark:hover:bg-neutral-900"
              >
                Cancel
              </button>
              <button
                onClick={addRow}
                disabled={
                  !addForm.machine_name ||
                  !addForm.shelf_code ||
                  !addForm.boonz_product_name
                }
                className="flex-1 rounded-xl bg-neutral-900 py-2.5 text-sm font-medium text-white hover:bg-neutral-800 disabled:opacity-40 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
              >
                Add row
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
