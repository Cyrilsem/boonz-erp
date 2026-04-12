"use client";

import { useEffect, useState, useCallback } from "react";
import { useParams } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import { FieldHeader } from "../../../components/field-header";
import { getExpiryStyle } from "@/app/(field)/utils/expiry";

// ─── Types ────────────────────────────────────────────────────────────────────

type LineAction = "packed" | "skip" | null;

interface BatchAllocation {
  wh_inventory_id: string;
  expiry_date: string | null;
  qty: number;
}

interface PackLine {
  dispatch_id: string;
  boonz_product_id: string;
  shelf_code: string;
  pod_product_name: string;
  recommended_qty: number;
  packed_qty: number;
  action: LineAction;
  fifo_expiry: string | null;
  allocations: BatchAllocation[];
  warehouse_stock: number;
}

interface MachineInfo {
  official_name: string;
  pod_location: string | null;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function formatDMY(date: string | null): string {
  if (!date) return "—";
  return new Date(date + "T00:00:00").toLocaleDateString("en-GB", {
    day: "2-digit",
    month: "short",
    year: "2-digit",
  });
}

function stockColor(stock: number, planned: number): string {
  if (stock === 0) return "text-red-600 dark:text-red-400";
  if (stock < planned) return "text-amber-600 dark:text-amber-400";
  return "text-green-600 dark:text-green-400";
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function PackingDetailPage() {
  const params = useParams<{ machineId: string }>();
  const machineId = params.machineId;

  const [machine, setMachine] = useState<MachineInfo | null>(null);
  const [lines, setLines] = useState<PackLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [editingAfterSave, setEditingAfterSave] = useState(false);

  const fetchData = useCallback(async () => {
    const supabase = createClient();
    const today = getDubaiDate();

    const { data: machineData } = await supabase
      .from("machines")
      .select("official_name, pod_location")
      .eq("machine_id", machineId)
      .single();

    if (machineData) setMachine(machineData);

    const { data: dispatchLines } = await supabase
      .from("refill_dispatching")
      .select(
        `
        dispatch_id,
        boonz_product_id,
        quantity,
        filled_quantity,
        packed,
        shelf_configurations!inner(shelf_code),
        pod_products!inner(pod_product_name)
      `,
      )
      .eq("dispatch_date", today)
      .eq("include", true)
      .eq("machine_id", machineId);

    if (!dispatchLines) {
      setLines([]);
      setLoading(false);
      return;
    }

    // ── FIFO batch fetch ────────────────────────────────────────────────────
    const boonzProductIds = dispatchLines
      .map((l) => l.boonz_product_id)
      .filter((id): id is string => id !== null);

    interface WBatch {
      wh_inventory_id: string;
      boonz_product_id: string;
      warehouse_stock: number;
      expiration_date: string | null;
    }

    let rawBatches: WBatch[] = [];

    if (boonzProductIds.length > 0) {
      const { data: batchData } = await supabase
        .from("warehouse_inventory")
        .select(
          "wh_inventory_id, boonz_product_id, warehouse_stock, expiration_date",
        )
        .in("boonz_product_id", boonzProductIds)
        .eq("status", "Active")
        .gt("warehouse_stock", 0)
        .order("expiration_date", { ascending: true, nullsFirst: false });

      rawBatches = (batchData ?? []) as WBatch[];
    }

    // Build mutable batch pool per product (already FIFO-ordered from DB)
    const batchPool = new Map<
      string,
      {
        wh_inventory_id: string;
        expiry_date: string | null;
        available: number;
      }[]
    >();
    const stockMap = new Map<string, number>();

    for (const b of rawBatches) {
      if (!batchPool.has(b.boonz_product_id))
        batchPool.set(b.boonz_product_id, []);
      batchPool.get(b.boonz_product_id)!.push({
        wh_inventory_id: b.wh_inventory_id,
        expiry_date: b.expiration_date,
        available: b.warehouse_stock ?? 0,
      });
      stockMap.set(
        b.boonz_product_id,
        (stockMap.get(b.boonz_product_id) ?? 0) + (b.warehouse_stock ?? 0),
      );
    }

    // FIFO allocation — sort by dispatch_id for determinism
    const sortedForAlloc = [...dispatchLines].sort((a, b) =>
      a.dispatch_id.localeCompare(b.dispatch_id),
    );
    const fifoMap: Record<
      string,
      { allocations: BatchAllocation[]; primary_expiry: string | null }
    > = {};

    for (const line of sortedForAlloc) {
      const productId = line.boonz_product_id ?? "";
      const batches = batchPool.get(productId) ?? [];
      let remaining = line.quantity ?? 0;
      const allocations: BatchAllocation[] = [];

      for (const batch of batches) {
        if (remaining <= 0) break;
        if (batch.available <= 0) continue;
        const take = Math.min(batch.available, remaining);
        allocations.push({
          wh_inventory_id: batch.wh_inventory_id,
          expiry_date: batch.expiry_date,
          qty: take,
        });
        batch.available -= take;
        remaining -= take;
      }

      fifoMap[line.dispatch_id] = {
        allocations,
        primary_expiry: allocations[0]?.expiry_date ?? null,
      };
    }

    // Map lines
    const mapped: PackLine[] = dispatchLines.map((line) => {
      const shelf = line.shelf_configurations as unknown as {
        shelf_code: string;
      };
      const product = line.pod_products as unknown as {
        pod_product_name: string;
      };
      const fifo = fifoMap[line.dispatch_id] ?? {
        allocations: [],
        primary_expiry: null,
      };
      const isPacked = !!line.packed;
      return {
        dispatch_id: line.dispatch_id,
        boonz_product_id: line.boonz_product_id ?? "",
        shelf_code: shelf.shelf_code,
        pod_product_name: product.pod_product_name,
        recommended_qty: line.quantity ?? 0,
        packed_qty:
          (line.filled_quantity as number | null) ?? line.quantity ?? 0,
        action: isPacked ? "packed" : null,
        fifo_expiry: fifo.primary_expiry,
        allocations: fifo.allocations,
        warehouse_stock: stockMap.get(line.boonz_product_id ?? "") ?? 0,
      };
    });

    mapped.sort((a, b) => a.shelf_code.localeCompare(b.shelf_code));
    setLines(mapped);

    // If all already packed on load, show read-only
    const allResolved =
      mapped.length > 0 && mapped.every((l) => l.action !== null);
    if (allResolved) setSaved(true);

    setLoading(false);
  }, [machineId]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  // ── Line helpers ────────────────────────────────────────────────────────────

  function updateAction(dispatchId: string, action: LineAction) {
    setLines((prev) =>
      prev.map((l) => (l.dispatch_id === dispatchId ? { ...l, action } : l)),
    );
  }

  function updatePackedQty(dispatchId: string, value: number) {
    setLines((prev) =>
      prev.map((l) =>
        l.dispatch_id === dispatchId
          ? { ...l, packed_qty: Math.max(0, value) }
          : l,
      ),
    );
  }

  function handleMarkAllPacked() {
    setLines((prev) =>
      prev.map((l) => ({
        ...l,
        action: "packed" as LineAction,
        packed_qty: l.recommended_qty,
      })),
    );
  }

  // ── Save ────────────────────────────────────────────────────────────────────

  async function handleConfirmPacking() {
    setSaving(true);
    const supabase = createClient();

    for (const line of lines) {
      if (line.action === "packed") {
        await supabase
          .from("refill_dispatching")
          .update({
            packed: true,
            filled_quantity: line.packed_qty,
            expiry_date: line.fifo_expiry ?? null,
          })
          .eq("dispatch_id", line.dispatch_id);
      } else if (line.action === "skip") {
        await supabase
          .from("refill_dispatching")
          .update({
            packed: false,
            filled_quantity: 0,
            expiry_date: null,
          })
          .eq("dispatch_id", line.dispatch_id);
      }
    }

    setSaving(false);
    setSaved(true);
    setEditingAfterSave(false);
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="Machine Detail" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading packing details…</p>
        </div>
      </>
    );
  }

  const allActioned = lines.length > 0 && lines.every((l) => l.action !== null);
  const packedCount = lines.filter((l) => l.action === "packed").length;
  const skippedCount = lines.filter((l) => l.action === "skip").length;
  const pendingCount = lines.filter((l) => l.action === null).length;
  const isReadOnly = saved && !editingAfterSave;

  const grouped = new Map<string, PackLine[]>();
  for (const line of lines) {
    const existing = grouped.get(line.shelf_code) ?? [];
    existing.push(line);
    grouped.set(line.shelf_code, existing);
  }
  const shelves = Array.from(grouped.entries()).sort((a, b) =>
    a[0].localeCompare(b[0]),
  );

  return (
    <div className="px-4 py-4 pb-40">
      <FieldHeader
        title="Machine Detail"
        rightAction={
          <Link
            href={`/field/shelf-view/${machineId}`}
            className="text-sm text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300"
          >
            Shelf View →
          </Link>
        }
      />

      {machine && (
        <div className="mb-4">
          <h1 className="text-xl font-semibold">{machine.official_name}</h1>
          {machine.pod_location && (
            <p className="text-sm text-neutral-500">{machine.pod_location}</p>
          )}
        </div>
      )}

      {/* Save summary */}
      {saved && (
        <div className="mb-4 rounded-xl bg-green-50 px-4 py-3 text-sm dark:bg-green-950/30">
          <span className="font-medium text-green-700 dark:text-green-400">
            ✓ {packedCount} items packed
          </span>
          {skippedCount > 0 && (
            <span className="ml-3 font-medium text-neutral-500 dark:text-neutral-400">
              — {skippedCount} skipped
            </span>
          )}
        </div>
      )}

      {shelves.map(([shelfCode, shelfLines]) => (
        <div key={shelfCode} className="mb-4">
          <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-neutral-500">
            Shelf {shelfCode}
          </h2>
          <ul className="space-y-2">
            {shelfLines.map((line) => {
              const hasStock = line.allocations.length > 0;
              const isMultiBatch = line.allocations.length > 1;

              const borderClass =
                line.action === "packed"
                  ? "border-l-4 border-l-green-400"
                  : line.action === "skip"
                    ? "border-l-4 border-l-neutral-300 opacity-60"
                    : "";

              return (
                <li
                  key={line.dispatch_id}
                  className={`rounded-lg border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950 ${borderClass}`}
                >
                  {/* Product name + recommended qty */}
                  <p className="mb-0.5 flex flex-wrap items-center gap-1.5 text-sm font-medium">
                    {line.pod_product_name}
                    {(() => {
                      const expiry = line.fifo_expiry;
                      if (expiry === null) {
                        return (
                          <span className="rounded px-1 py-0.5 text-xs font-normal bg-neutral-100 text-neutral-500 dark:bg-neutral-800 dark:text-neutral-400">
                            No expiry date
                          </span>
                        );
                      }
                      const today = new Date();
                      today.setHours(0, 0, 0, 0);
                      const exp = new Date(expiry + "T00:00:00");
                      const soon = new Date(today);
                      soon.setDate(soon.getDate() + 30);
                      if (exp < today) {
                        return (
                          <span className="rounded px-1 py-0.5 text-xs font-normal bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400">
                            ⚠ EXPIRED
                          </span>
                        );
                      }
                      if (exp <= soon) {
                        return (
                          <span className="rounded px-1 py-0.5 text-xs font-normal bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400">
                            ⚠ Expires soon
                          </span>
                        );
                      }
                      return null;
                    })()}
                  </p>
                  <p className="mb-2 text-xs text-neutral-400">
                    Recommended: {line.recommended_qty} units
                  </p>

                  {/* FIFO expiry display (unchanged logic) */}
                  {!hasStock ? (
                    <p className="mb-2 inline-flex items-center gap-1 rounded bg-amber-50 px-2 py-0.5 text-xs text-amber-700 dark:bg-amber-900/30 dark:text-amber-300">
                      ⚠ No stock found in warehouse
                    </p>
                  ) : isMultiBatch ? (
                    <div className="mb-2 space-y-0.5 rounded bg-amber-50 px-2 py-1 dark:bg-amber-900/20">
                      {line.allocations.map((a, i) => {
                        const style = getExpiryStyle(a.expiry_date);
                        return (
                          <p key={i} className="text-xs">
                            <span className="font-bold">Qty: {a.qty}</span>
                            {"  "}
                            <span className="font-bold">Expiry:</span>{" "}
                            <span className={style.qtyColor}>
                              {formatDMY(a.expiry_date)}
                            </span>
                          </p>
                        );
                      })}
                    </div>
                  ) : (
                    <p className="mb-2 text-xs">
                      <span className="font-bold">
                        Qty: {line.allocations[0].qty}
                      </span>
                      {"  "}
                      <span className="font-bold">Expiry:</span>{" "}
                      <span
                        className={
                          getExpiryStyle(line.allocations[0].expiry_date)
                            .qtyColor
                        }
                      >
                        {formatDMY(line.allocations[0].expiry_date)}
                      </span>
                    </p>
                  )}

                  <p className="mb-2 text-xs">
                    <span
                      className={stockColor(
                        line.warehouse_stock,
                        line.recommended_qty,
                      )}
                    >
                      {line.warehouse_stock} in stock
                    </span>
                  </p>

                  {/* Packed qty input */}
                  <div className="mb-2 flex items-center gap-2">
                    <label className="text-xs text-neutral-500">
                      Packed qty:
                    </label>
                    <input
                      type="number"
                      min={0}
                      value={line.packed_qty}
                      onChange={(e) =>
                        updatePackedQty(
                          line.dispatch_id,
                          parseFloat(e.target.value) || 0,
                        )
                      }
                      disabled={isReadOnly}
                      className="w-20 rounded border border-neutral-300 px-2 py-1 text-center text-sm disabled:opacity-50 dark:border-neutral-600 dark:bg-neutral-900"
                    />
                  </div>

                  {/* Action toggle */}
                  {!isReadOnly && (
                    <div className="flex gap-2">
                      <button
                        onClick={() => updateAction(line.dispatch_id, "packed")}
                        className={`flex-1 rounded-lg border py-1.5 text-xs font-semibold transition-colors ${
                          line.action === "packed"
                            ? "border-green-400 bg-green-50 text-green-700 dark:bg-green-950/40 dark:text-green-400"
                            : "border-neutral-200 text-neutral-500 hover:bg-neutral-50 dark:border-neutral-700 dark:hover:bg-neutral-800"
                        }`}
                      >
                        ✓ Packed
                      </button>
                      <button
                        onClick={() => updateAction(line.dispatch_id, "skip")}
                        className={`flex-1 rounded-lg border py-1.5 text-xs font-semibold transition-colors ${
                          line.action === "skip"
                            ? "border-neutral-400 bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-300"
                            : "border-neutral-200 text-neutral-500 hover:bg-neutral-50 dark:border-neutral-700 dark:hover:bg-neutral-800"
                        }`}
                      >
                        ✗ Skip
                      </button>
                    </div>
                  )}
                </li>
              );
            })}
          </ul>
        </div>
      ))}

      {/* Bottom bar */}
      <div className="fixed bottom-14 left-0 right-0 border-t border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
        {isReadOnly ? (
          <button
            onClick={() => {
              setSaved(false);
              setEditingAfterSave(true);
            }}
            className="w-full rounded-lg border border-neutral-300 py-3 text-sm font-medium text-neutral-700 transition-colors hover:bg-neutral-50 dark:border-neutral-600 dark:text-neutral-300 dark:hover:bg-neutral-800"
          >
            Edit
          </button>
        ) : (
          <div className="space-y-2">
            <button
              onClick={handleMarkAllPacked}
              className="w-full rounded-lg border border-neutral-300 py-2.5 text-sm font-medium text-neutral-700 transition-colors hover:bg-neutral-50 dark:border-neutral-600 dark:text-neutral-300 dark:hover:bg-neutral-800"
            >
              Mark all as packed
            </button>
            <button
              onClick={handleConfirmPacking}
              disabled={!allActioned || saving}
              className="w-full rounded-lg bg-neutral-900 py-3 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
            >
              {saving
                ? "Saving…"
                : allActioned
                  ? `Confirm packing (${packedCount} packed${skippedCount > 0 ? `, ${skippedCount} skipped` : ""})`
                  : `Confirm packing — ${pendingCount} pending`}
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
