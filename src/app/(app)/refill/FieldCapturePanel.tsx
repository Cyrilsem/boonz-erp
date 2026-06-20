"use client";

// PRD-036 Phase B: field-time batch + expiry capture.
// Captures qty + expiry + new-purchase flag per line and submits through the
// canonical writer log_manual_refill (Rule S1: no direct table writes; S2: the
// rpc() call site is a greppable literal). For new_purchase=true the writer
// creates a WH receipt batch with the captured expiry then places to the pod;
// for replacement/existing-stock (new_purchase=false) it FEFO-decrements WH then
// places. Replaces the "Error in the Data: log it on paper" backlog.

import { useState, useEffect, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";

type Opt = { id: string; name: string };

type CaptureRow = {
  key: string;
  boonz_product_id: string;
  shelf_code: string;
  qty: string;
  expiration_date: string;
  new_purchase: boolean;
};

// PRD-036 Phase B step 3: unresolved field corrections (driver_feedback.resolved=false).
type UnloggedCorrection = {
  feedback_id: string;
  machine_name: string | null;
  shelf_code: string | null;
  boonz_product_name: string | null;
  requested_qty: number | null;
  feedback_type: string | null;
  note: string | null;
  created_at: string;
};

let rowSeq = 0;
function blankRow(): CaptureRow {
  rowSeq += 1;
  return {
    key: `r${rowSeq}`,
    boonz_product_id: "",
    shelf_code: "",
    qty: "",
    expiration_date: "",
    new_purchase: false,
  };
}

export function FieldCapturePanel() {
  const planDate = getDubaiDate();

  const [machines, setMachines] = useState<Opt[]>([]);
  const [warehouses, setWarehouses] = useState<Opt[]>([]);
  const [products, setProducts] = useState<Opt[]>([]);
  const [machineName, setMachineName] = useState("");
  const [warehouseId, setWarehouseId] = useState("");
  const [rows, setRows] = useState<CaptureRow[]>([blankRow()]);
  const [submitting, setSubmitting] = useState(false);
  const [result, setResult] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [unlogged, setUnlogged] = useState<UnloggedCorrection[]>([]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const supabase = createClient();
      const [mRes, wRes, pRes, fRes] = await Promise.all([
        supabase
          .from("machines")
          .select("machine_id, official_name")
          .order("official_name")
          .limit(10000),
        supabase.from("warehouses").select("warehouse_id, name").limit(10000),
        supabase
          .from("boonz_products")
          .select("product_id, boonz_product_name")
          .order("boonz_product_name")
          .limit(10000),
        // PRD-036 Phase B step 3: unresolved field corrections to surface.
        supabase
          .from("driver_feedback")
          .select(
            "feedback_id, machine_name, shelf_code, boonz_product_name, requested_qty, feedback_type, note, created_at",
          )
          .eq("resolved", false)
          .order("created_at", { ascending: false })
          .limit(10000),
      ]);
      if (cancelled) return;
      setUnlogged((fRes.data ?? []) as UnloggedCorrection[]);
      setMachines(
        (mRes.data ?? [])
          .filter(
            (m) => !(m.official_name as string)?.toUpperCase().startsWith("WH"),
          )
          .map((m) => ({
            id: m.machine_id as string,
            name: m.official_name as string,
          })),
      );
      setWarehouses(
        (wRes.data ?? []).map((w) => ({
          id: w.warehouse_id as string,
          name: w.name as string,
        })),
      );
      setProducts(
        (pRes.data ?? []).map((p) => ({
          id: p.product_id as string,
          name: p.boonz_product_name as string,
        })),
      );
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const updateRow = useCallback((key: string, patch: Partial<CaptureRow>) => {
    setRows((rs) => rs.map((r) => (r.key === key ? { ...r, ...patch } : r)));
  }, []);

  async function submit() {
    setError(null);
    setResult(null);
    if (!machineName) return setError("Pick a machine");
    if (!warehouseId) return setError("Pick a source warehouse");
    const lines = rows
      .filter((r) => r.boonz_product_id && r.shelf_code && Number(r.qty) > 0)
      .map((r) => ({
        boonz_product_id: r.boonz_product_id,
        shelf_code: r.shelf_code.trim(),
        qty: Number(r.qty),
        expiration_date: r.expiration_date || null,
        new_purchase: r.new_purchase,
      }));
    if (lines.length === 0) return setError("Add at least one complete line");
    const bad = lines.find((l) => l.new_purchase && !l.expiration_date);
    if (bad)
      return setError(
        "A new-purchase line needs an expiry date (it creates the WH batch)",
      );

    setSubmitting(true);
    const supabase = createClient();
    const { data, error: rpcErr } = await supabase.rpc("log_manual_refill", {
      p_machine_name: machineName,
      p_source_warehouse_id: warehouseId,
      p_refill_date: planDate,
      p_lines: lines,
      p_reason: "field_capture",
    });
    setSubmitting(false);
    if (rpcErr) {
      setError(rpcErr.message);
      return;
    }
    const r = data as {
      lines_processed?: number;
      total_units_to_pod?: number;
      shortfall_warning?: string | null;
    } | null;
    setResult(
      `Captured ${r?.lines_processed ?? 0} line(s), ${r?.total_units_to_pod ?? 0} units to pod.` +
        (r?.shortfall_warning ? ` ⚠ ${r.shortfall_warning}` : ""),
    );
    setRows([blankRow()]);
  }

  const inputCls =
    "border border-gray-300 rounded px-2 py-1 text-sm dark:bg-neutral-900 dark:border-neutral-700";

  return (
    <div className="space-y-4">
      <p className="text-sm text-gray-600">
        Field batch capture ({planDate}). Records a physical placement (new
        purchase, replacement, or partial) straight into the warehouse + pod via
        the canonical path. No more paper backlog.
      </p>

      {error && (
        <div className="rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-800">
          {error}
        </div>
      )}
      {result && (
        <div className="rounded-lg border border-green-300 bg-green-50 p-3 text-sm text-green-800">
          {result}
        </div>
      )}

      {unlogged.length > 0 && (
        <div className="rounded-lg border border-amber-300 bg-amber-50 p-3 dark:border-amber-700 dark:bg-amber-950/20">
          <p className="mb-2 text-sm font-semibold text-amber-800 dark:text-amber-300">
            Unlogged field corrections ({unlogged.length})
          </p>
          <ul className="space-y-1 text-xs text-amber-900 dark:text-amber-200">
            {unlogged.slice(0, 50).map((u) => (
              <li key={u.feedback_id}>
                <span className="font-medium">{u.machine_name ?? "—"}</span>
                {u.shelf_code ? ` · ${u.shelf_code}` : ""} ·{" "}
                {u.boonz_product_name ?? "—"}
                {u.requested_qty != null ? ` · qty ${u.requested_qty}` : ""}
                {u.feedback_type ? ` · ${u.feedback_type}` : ""}
                {u.note ? ` — ${u.note}` : ""}
              </li>
            ))}
          </ul>
          <p className="mt-2 text-[11px] text-amber-700 dark:text-amber-400">
            Capture each below; it clears when the correction is logged
            (driver_feedback.resolved).
          </p>
        </div>
      )}

      <div className="flex flex-wrap gap-3">
        <label className="text-sm">
          <span className="mr-2 text-gray-600">Machine</span>
          <select
            value={machineName}
            onChange={(e) => setMachineName(e.target.value)}
            className={inputCls}
          >
            <option value="">— select —</option>
            {machines.map((m) => (
              <option key={m.id} value={m.name}>
                {m.name}
              </option>
            ))}
          </select>
        </label>
        <label className="text-sm">
          <span className="mr-2 text-gray-600">Source WH</span>
          <select
            value={warehouseId}
            onChange={(e) => setWarehouseId(e.target.value)}
            className={inputCls}
          >
            <option value="">— select —</option>
            {warehouses.map((w) => (
              <option key={w.id} value={w.id}>
                {w.name}
              </option>
            ))}
          </select>
        </label>
      </div>

      <div className="space-y-2">
        {rows.map((r) => (
          <div
            key={r.key}
            className="flex flex-wrap items-center gap-2 rounded-lg border border-gray-200 p-2 dark:border-neutral-700"
          >
            <select
              value={r.boonz_product_id}
              onChange={(e) =>
                updateRow(r.key, { boonz_product_id: e.target.value })
              }
              className={`${inputCls} min-w-[200px]`}
            >
              <option value="">— product —</option>
              {products.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </select>
            <input
              type="text"
              placeholder="shelf (e.g. A1)"
              value={r.shelf_code}
              onChange={(e) => updateRow(r.key, { shelf_code: e.target.value })}
              className={`${inputCls} w-24`}
            />
            <input
              type="number"
              min={0}
              placeholder="qty"
              value={r.qty}
              onChange={(e) => updateRow(r.key, { qty: e.target.value })}
              className={`${inputCls} w-16`}
            />
            <input
              type="date"
              value={r.expiration_date}
              onChange={(e) =>
                updateRow(r.key, { expiration_date: e.target.value })
              }
              className={inputCls}
            />
            <label className="flex items-center gap-1 text-xs text-gray-700 dark:text-gray-300">
              <input
                type="checkbox"
                checked={r.new_purchase}
                onChange={(e) =>
                  updateRow(r.key, { new_purchase: e.target.checked })
                }
              />
              New purchase
            </label>
            <button
              onClick={() =>
                setRows((rs) =>
                  rs.length > 1 ? rs.filter((x) => x.key !== r.key) : rs,
                )
              }
              className="ml-auto rounded border border-gray-300 px-2 py-1 text-xs"
            >
              ✕
            </button>
          </div>
        ))}
      </div>

      <div className="flex gap-2">
        <button
          onClick={() => setRows((rs) => [...rs, blankRow()])}
          className="rounded-lg border border-gray-300 px-3 py-1.5 text-sm"
        >
          + Add line
        </button>
        <button
          onClick={submit}
          disabled={submitting}
          className="rounded-lg bg-black px-4 py-1.5 text-sm font-medium text-white disabled:opacity-40"
        >
          {submitting ? "Capturing…" : "Capture to WH + pod"}
        </button>
      </div>
    </div>
  );
}
