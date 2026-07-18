"use client";

// PRD-036 Phase B / PRD-100 RC-02: field-time batch + expiry capture.
// Captures qty + expiry + on-the-spot-purchase flag per line and submits
// through the canonical writer record_actual_refill (Rule S1: no direct table
// writes; S2: the rpc() call site is a greppable literal).
//
// RC-02 (Batch 2): submit was refactored from log_manual_refill to
// record_actual_refill. log_manual_refill is LEGACY — it pre-dates the
// refill_events / refill_event_lines ledger and does not produce a dry-run
// preview. record_actual_refill writes the pod + warehouse + refill_plan_output
// log AND the refill_events ledger atomically, with p_dry_run=true validation
// first (nothing applied) and p_dry_run=false on operator confirm.
//
// Sourcing semantics (CS hard rule 3 — empty shelves must always be fillable):
// - normal line  -> action 'refill' with warehouse_id: FEFO-style WH decrement
//   then pod placement.
// - "Bought on the spot" line -> action 'refill' WITHOUT warehouse_id: pod-only
//   placement (stock never entered the warehouse), expiry required so the pod
//   batch is honest. No phantom WH decrement.
//
// This component was previously dead code under src/app/(app)/refill/ —
// it is now mounted at /field/capture (RC-02) and deep-linked from the
// field inventory disposition flow.

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

/** Prefill passed by the inventory disposition flow (deep link). */
export interface CapturePrefill {
  boonz_product_id?: string;
  qty?: string;
  expiration_date?: string;
  warehouse_id?: string;
}

// record_actual_refill p_lines element (live signature verified 2026-07-18).
type RefillLine = {
  action: "refill";
  boonz_product_id: string;
  shelf_code: string;
  qty: number;
  set_mode: "delta";
  expiration_date: string | null;
  warehouse_id: string | null;
  notes: string | null;
};

type RecordActualRefillResponse = {
  status?: "dry_run_ok" | "applied" | "failed";
  event_id?: string;
  machine?: string;
  plan_date?: string;
  lines?: number;
  failed_at_line?: number;
  error?: string;
} | null;

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
function blankRow(prefill?: CapturePrefill): CaptureRow {
  rowSeq += 1;
  return {
    key: `r${rowSeq}`,
    boonz_product_id: prefill?.boonz_product_id ?? "",
    shelf_code: "",
    qty: prefill?.qty ?? "",
    expiration_date: prefill?.expiration_date ?? "",
    new_purchase: false,
  };
}

export function FieldCapturePanel({ prefill }: { prefill?: CapturePrefill }) {
  const planDate = getDubaiDate();

  const [machines, setMachines] = useState<Opt[]>([]);
  const [warehouses, setWarehouses] = useState<Opt[]>([]);
  const [products, setProducts] = useState<Opt[]>([]);
  // PRD-075 WS-B hardening: machine-scoped product ids + fill-to-cap defaults,
  // derived from the machine's live shelves (v_live_shelf_stock -> product_mapping).
  const [scopedProductIds, setScopedProductIds] = useState<Set<string>>(
    new Set(),
  );
  const [freeByProduct, setFreeByProduct] = useState<Record<string, number>>(
    {},
  );
  const [machineName, setMachineName] = useState("");
  const [warehouseId, setWarehouseId] = useState(prefill?.warehouse_id ?? "");
  const [rows, setRows] = useState<CaptureRow[]>([blankRow(prefill)]);
  const [submitting, setSubmitting] = useState(false);
  const [result, setResult] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [unlogged, setUnlogged] = useState<UnloggedCorrection[]>([]);
  // RC-02: dry-run preview gate. Holds the exact payload that was validated so
  // Confirm applies precisely what the operator previewed. Any edit clears it.
  const [preview, setPreview] = useState<{
    lines: RefillLine[];
    lineCount: number;
  } | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const supabase = createClient();
      const [mRes, wRes, pRes, fRes] = await Promise.all([
        supabase
          .from("machines")
          .select("machine_id, official_name")
          .eq("status", "Active")
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
    setPreview(null); // edited after preview -> must re-preview
    setRows((rs) => rs.map((r) => (r.key === key ? { ...r, ...patch } : r)));
  }, []);

  // PRD-075 WS-B: when a machine is picked, scope the product list to what is
  // actually mapped on ITS shelves and remember free capacity per product
  // (fill-to-cap qty default). Falls back to the full list if lookup fails.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const machineId = machines.find((m) => m.name === machineName)?.id;
      if (!machineId) {
        setScopedProductIds(new Set());
        setFreeByProduct({});
        return;
      }
      const supabase = createClient();
      const { data: slots } = await supabase
        .from("v_live_shelf_stock")
        .select("pod_product_id, current_stock, max_stock")
        .eq("machine_id", machineId)
        .limit(10000);
      const podIds = [
        ...new Set(
          (slots ?? [])
            .map((s) => s.pod_product_id as string | null)
            .filter((x): x is string => !!x),
        ),
      ];
      if (podIds.length === 0) {
        if (!cancelled) {
          setScopedProductIds(new Set());
          setFreeByProduct({});
        }
        return;
      }
      const { data: maps } = await supabase
        .from("product_mapping")
        .select("boonz_product_id, pod_product_id")
        .in("pod_product_id", podIds)
        .eq("status", "Active")
        .limit(10000);
      if (cancelled) return;
      const freeByPod: Record<string, number> = {};
      for (const s of slots ?? []) {
        if (!s.pod_product_id) continue;
        freeByPod[s.pod_product_id as string] =
          (freeByPod[s.pod_product_id as string] ?? 0) +
          Math.max(
            0,
            ((s.max_stock as number) ?? 0) - ((s.current_stock as number) ?? 0),
          );
      }
      const ids = new Set<string>();
      const free: Record<string, number> = {};
      for (const m of maps ?? []) {
        const b = m.boonz_product_id as string;
        ids.add(b);
        free[b] = Math.max(
          free[b] ?? 0,
          freeByPod[m.pod_product_id as string] ?? 0,
        );
      }
      setScopedProductIds(ids);
      setFreeByProduct(free);
    })();
    return () => {
      cancelled = true;
    };
  }, [machineName, machines]);

  function buildLines(): RefillLine[] | string {
    if (!machineName) return "Pick a machine";
    const complete = rows.filter(
      (r) => r.boonz_product_id && r.shelf_code && Number(r.qty) > 0,
    );
    if (complete.length === 0) return "Add at least one complete line";
    const needsWh = complete.some((r) => !r.new_purchase);
    if (needsWh && !warehouseId)
      return "Pick a source warehouse (or mark lines as bought on the spot)";
    const bad = complete.find((l) => l.new_purchase && !l.expiration_date);
    if (bad)
      return "An on-the-spot purchase line needs an expiry date (it creates the pod batch)";
    return complete.map((r) => ({
      action: "refill" as const,
      boonz_product_id: r.boonz_product_id,
      shelf_code: r.shelf_code.trim(),
      qty: Number(r.qty),
      set_mode: "delta" as const,
      expiration_date: r.expiration_date || null,
      // CS hard rule 3: on-the-spot sourcing never decrements the warehouse —
      // record_actual_refill only touches WH stock when warehouse_id is set.
      warehouse_id: r.new_purchase ? null : warehouseId,
      notes: r.new_purchase ? "on_spot_purchase" : null,
    }));
  }

  async function callRecordActualRefill(lines: RefillLine[], dryRun: boolean) {
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    // Live signature (verified): record_actual_refill(p_machine_name text,
    // p_plan_date date, p_lines jsonb, p_source text, p_actor uuid,
    // p_reason text, p_dry_run boolean) -> jsonb
    return supabase.rpc("record_actual_refill", {
      p_machine_name: machineName,
      p_plan_date: planDate,
      p_lines: lines,
      p_source: "field_capture",
      p_actor: user?.id ?? null,
      p_reason: "field_capture",
      p_dry_run: dryRun,
    });
  }

  async function submit(dryRun: boolean) {
    setError(null);
    setResult(null);
    const linesOrError = dryRun ? buildLines() : (preview?.lines ?? null);
    if (typeof linesOrError === "string") return setError(linesOrError);
    if (!linesOrError) return setError("Preview first, then confirm.");
    const lines = linesOrError;

    // PRD-075 WS-B: offline-tolerant submit - never lose typed lines. Rows are
    // only cleared on confirmed success; network failures keep state + prompt retry.
    if (typeof navigator !== "undefined" && !navigator.onLine) {
      return setError(
        "You look offline — your lines are kept. Reconnect and try again.",
      );
    }
    setSubmitting(true);
    let data: RecordActualRefillResponse = null;
    let rpcErr: { message: string } | null = null;
    try {
      const res = await callRecordActualRefill(lines, dryRun);
      data = res.data as RecordActualRefillResponse;
      rpcErr = res.error;
    } catch {
      rpcErr = {
        message:
          "Network error — your lines are kept. Reconnect and try again.",
      };
    }
    setSubmitting(false);
    if (rpcErr) {
      setPreview(null);
      setError(rpcErr.message);
      return;
    }
    if (data?.status === "failed") {
      setPreview(null);
      setError(
        `Rejected${data.failed_at_line ? ` at line ${data.failed_at_line}` : ""}: ${
          data.error ?? "unknown error"
        }`,
      );
      return;
    }
    if (dryRun) {
      // dry_run_ok: nothing was applied — show the gate.
      setPreview({ lines, lineCount: data?.lines ?? lines.length });
      return;
    }
    setPreview(null);
    setResult(
      `Applied ${data?.lines ?? lines.length} line(s) to ${machineName} (event ${
        data?.event_id ?? "?"
      }).`,
    );
    setRows([blankRow()]);
  }

  const inputCls =
    "border border-gray-300 rounded px-2 py-1 text-sm dark:bg-neutral-900 dark:border-neutral-700";

  return (
    <div className="space-y-4">
      <p className="text-sm text-gray-600">
        Field refill capture ({planDate}). Records a physical placement
        (warehouse-sourced or bought on the spot) straight into the pod +
        warehouse + refill ledger via the canonical path. Preview validates
        everything first; nothing is written until you confirm.
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
            onChange={(e) => {
              setPreview(null);
              setMachineName(e.target.value);
            }}
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
            onChange={(e) => {
              setPreview(null);
              setWarehouseId(e.target.value);
            }}
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
              onChange={(e) => {
                const id = e.target.value;
                // fill-to-cap default when qty untouched (PRD-075 WS-B)
                const free = freeByProduct[id];
                updateRow(r.key, {
                  boonz_product_id: id,
                  ...(r.qty === "" && free && free > 0
                    ? { qty: String(free) }
                    : {}),
                });
              }}
              className={`${inputCls} min-w-[200px]`}
            >
              <option value="">— product —</option>
              {(scopedProductIds.size > 0
                ? // keep a deep-linked/selected product visible even when the
                  // machine scope would filter it out
                  products.filter(
                    (p) =>
                      scopedProductIds.has(p.id) || p.id === r.boonz_product_id,
                  )
                : products
              ).map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                  {freeByProduct[p.id] ? ` (fits ${freeByProduct[p.id]})` : ""}
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
              Bought on the spot
            </label>
            <button
              onClick={() => {
                setPreview(null);
                setRows((rs) =>
                  rs.length > 1 ? rs.filter((x) => x.key !== r.key) : rs,
                );
              }}
              className="ml-auto rounded border border-gray-300 px-2 py-1 text-xs"
            >
              ✕
            </button>
          </div>
        ))}
      </div>

      {preview && (
        <div className="rounded-lg border border-blue-300 bg-blue-50 p-3 text-sm text-blue-900 dark:border-blue-800 dark:bg-blue-950/30 dark:text-blue-200">
          <p className="font-semibold">
            Preview OK — {preview.lineCount} line(s) to {machineName}. Nothing
            written yet.
          </p>
          <ul className="mt-1 space-y-0.5 text-xs">
            {preview.lines.map((l, i) => (
              <li key={i}>
                {l.qty} ×{" "}
                {products.find((p) => p.id === l.boonz_product_id)?.name ??
                  l.boonz_product_id}{" "}
                → shelf {l.shelf_code}
                {l.warehouse_id
                  ? ` (from ${
                      warehouses.find((w) => w.id === l.warehouse_id)?.name ??
                      "WH"
                    })`
                  : " (bought on the spot — no WH decrement)"}
                {l.expiration_date ? ` · exp ${l.expiration_date}` : ""}
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="flex gap-2">
        <button
          onClick={() => {
            setPreview(null);
            setRows((rs) => [...rs, blankRow()]);
          }}
          className="rounded-lg border border-gray-300 px-3 py-1.5 text-sm"
        >
          + Add line
        </button>
        {!preview ? (
          <button
            onClick={() => void submit(true)}
            disabled={submitting}
            className="rounded-lg bg-black px-4 py-1.5 text-sm font-medium text-white disabled:opacity-40"
          >
            {submitting ? "Checking…" : "Preview capture"}
          </button>
        ) : (
          <button
            onClick={() => void submit(false)}
            disabled={submitting}
            className="rounded-lg bg-green-700 px-4 py-1.5 text-sm font-medium text-white disabled:opacity-40"
          >
            {submitting ? "Applying…" : "Confirm & apply"}
          </button>
        )}
      </div>
    </div>
  );
}
