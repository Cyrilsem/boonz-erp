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

interface VariantStock {
  boonzProductId: string;
  /** Short display name: boonz_product_name with pod prefix stripped */
  name: string;
  stock: number;
  /** How many units of this variant to pack (computed from split_pct) */
  packQty: number;
}

interface PackLine {
  dispatch_id: string;
  boonz_product_id: string;
  pod_product_id: string;
  shelf_code: string;
  pod_product_name: string;
  /**
   * Primary label shown on the card.
   * Single-variant: boonz_product_name (e.g. "Pepsi - Black").
   * Mix / REMOVE: pod_product_name (category header, e.g. "Krambals").
   */
  display_name: string;
  recommended_qty: number;
  packed_qty: number;
  action: LineAction;
  fifo_expiry: string | null;
  allocations: BatchAllocation[];
  warehouse_stock: number;
  /** Non-null only for mix products (pod_product maps to >1 boonz variant) */
  variantStocks: VariantStock[] | null;
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

/**
 * Strip the pod product name prefix from a boonz SKU name.
 * "Krambals - Forest Mushroom & Butter" → "Forest Mushroom & Butter"
 */
function stripPodPrefix(boonzName: string, podName: string): string {
  const prefix = podName + " - ";
  return boonzName.startsWith(prefix)
    ? boonzName.slice(prefix.length)
    : boonzName;
}

/**
 * Distribute totalQty among variants using split percentages.
 * - Only distributes among variants that have stock AND splitPct > 0.
 * - Falls back to equal distribution among in-stock variants if no splits.
 * - Uses floor + highest-fraction-first remainder to sum exactly to totalQty.
 */
function computeVariantQtys(
  totalQty: number,
  variants: { boonzId: string; splitPct: number; inStock: boolean }[],
): { boonzId: string; qty: number }[] {
  // Eligible: in-stock and has a split percentage
  let eligible = variants.filter((v) => v.inStock && v.splitPct > 0);

  // Fallback: equal distribution among all in-stock variants
  if (eligible.length === 0) {
    const inStock = variants.filter((v) => v.inStock);
    if (inStock.length === 0) return [];
    eligible = inStock.map((v) => ({ ...v, splitPct: 100 / inStock.length }));
  }

  const totalPct = eligible.reduce((s, v) => s + v.splitPct, 0);

  const raw = eligible.map((v) => ({
    boonzId: v.boonzId,
    raw: (v.splitPct / totalPct) * totalQty,
  }));

  const floored = raw.map((v) => ({ ...v, qty: Math.floor(v.raw) }));
  const remainder = totalQty - floored.reduce((s, v) => s + v.qty, 0);

  // Distribute remainder to variants with highest fractional parts
  const sorted = [...floored].sort((a, b) => b.raw - b.qty - (a.raw - a.qty));
  for (let i = 0; i < remainder; i++) sorted[i].qty += 1;

  return sorted.filter((v) => v.qty > 0);
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
        pod_product_id,
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

    // ── Step 1: Discover variant boonz IDs + names via product_mapping FK join
    // boonz_product_name fetched via FK join (bypasses direct RLS on boonz_products).
    const podProductIds = [
      ...new Set(
        dispatchLines
          .map((l) => l.pod_product_id)
          .filter((id): id is string => id !== null),
      ),
    ];

    // pod_product_id → [boonz_product_id, ...]  (global defaults only for variant discovery)
    const podToVariants = new Map<string, string[]>();
    // boonz_product_id → boonz_product_name
    const boonzIdToName = new Map<string, string>();
    // pod_product_id → (boonz_product_id → split_pct)  (machine-specific overrides global)
    const splitMap = new Map<string, Map<string, number>>();

    if (podProductIds.length > 0) {
      // 1a. Global defaults — variant discovery + names
      const { data: globalMappings } = await supabase
        .from("product_mapping")
        .select(
          "pod_product_id, boonz_product_id, boonz_products(boonz_product_name)",
        )
        .in("pod_product_id", podProductIds)
        .is("machine_id", null)
        .eq("is_global_default", true)
        .eq("status", "Active")
        .limit(1000);

      for (const m of globalMappings ?? []) {
        if (!m.pod_product_id || !m.boonz_product_id) continue;

        const list = podToVariants.get(m.pod_product_id) ?? [];
        list.push(m.boonz_product_id);
        podToVariants.set(m.pod_product_id, list);

        const bpRaw = m.boonz_products as unknown;
        const bp = (Array.isArray(bpRaw) ? bpRaw[0] : bpRaw) as {
          boonz_product_name: string | null;
        } | null;
        const bpName = bp?.boonz_product_name ?? null;
        if (bpName) boonzIdToName.set(m.boonz_product_id, bpName);
      }

      // 1b. Split percentages — machine-specific rows take priority over global.
      // Query both in one pass; ORDER BY machine_id NULLS LAST so non-null rows
      // are processed first and win when both exist for the same variant.
      const { data: splitRows } = await supabase
        .from("product_mapping")
        .select("pod_product_id, boonz_product_id, split_pct, machine_id")
        .in("pod_product_id", podProductIds)
        .or(`machine_id.eq.${machineId},machine_id.is.null`)
        .gt("split_pct", 0)
        .eq("status", "Active")
        .order("machine_id", { ascending: true, nullsFirst: false })
        .limit(1000);

      for (const row of splitRows ?? []) {
        if (!row.pod_product_id || !row.boonz_product_id) continue;
        if (!splitMap.has(row.pod_product_id))
          splitMap.set(row.pod_product_id, new Map());
        const podSplits = splitMap.get(row.pod_product_id)!;
        // First occurrence wins — machine-specific rows come first due to ORDER BY
        if (!podSplits.has(row.boonz_product_id)) {
          podSplits.set(row.boonz_product_id, row.split_pct ?? 0);
        }
      }
    }

    // Identify mix products (pod → >1 boonz variant)
    const mixPodIdSet = new Set(
      [...podToVariants.entries()]
        .filter(([, v]) => v.length > 1)
        .map(([pid]) => pid),
    );

    // ── Step 2: Fetch warehouse stock for ALL needed boonz IDs ───────────────
    const allBoonzIds = [
      ...new Set([
        ...dispatchLines
          .map((l) => l.boonz_product_id)
          .filter((id): id is string => id !== null),
        ...[...podToVariants.values()].flat(),
      ]),
    ];

    interface WBatch {
      wh_inventory_id: string;
      boonz_product_id: string;
      warehouse_stock: number;
      expiration_date: string | null;
    }

    let rawBatches: WBatch[] = [];

    if (allBoonzIds.length > 0) {
      const { data: batchData } = await supabase
        .from("warehouse_inventory")
        .select(
          "wh_inventory_id, boonz_product_id, warehouse_stock, expiration_date",
        )
        .in("boonz_product_id", allBoonzIds)
        .eq("status", "Active")
        .gt("warehouse_stock", 0)
        .order("expiration_date", { ascending: true, nullsFirst: false });

      rawBatches = (batchData ?? []) as WBatch[];
    }

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

    // ── Step 3: Build variantMap for mix products (packQty = 0 initially) ────
    // packQty is computed per dispatch line in Step 5 using the actual quantity.
    const variantMap = new Map<string, VariantStock[]>();

    for (const podId of mixPodIdSet) {
      const variants = podToVariants.get(podId) ?? [];

      const podLine = dispatchLines.find((l) => l.pod_product_id === podId);
      const podProductRow = podLine?.pod_products as
        | { pod_product_name: string }
        | undefined;
      const podName = podProductRow?.pod_product_name ?? "";

      variantMap.set(
        podId,
        variants.map((boonzId) => {
          const fullName = boonzIdToName.get(boonzId) ?? "";
          const shortName = fullName
            ? stripPodPrefix(fullName, podName)
            : fullName;
          return {
            boonzProductId: boonzId,
            name: shortName || fullName || boonzId,
            stock: stockMap.get(boonzId) ?? 0,
            packQty: 0, // filled per dispatch line in Step 5
          };
        }),
      );
    }

    // ── Step 4: FIFO allocation (single-variant, non-REMOVE lines only) ──────
    const sortedForAlloc = [...dispatchLines].sort((a, b) =>
      a.dispatch_id.localeCompare(b.dispatch_id),
    );
    const fifoMap: Record<
      string,
      { allocations: BatchAllocation[]; primary_expiry: string | null }
    > = {};

    for (const line of sortedForAlloc) {
      const isMixLine = line.pod_product_id
        ? mixPodIdSet.has(line.pod_product_id)
        : false;
      const isRemoveLine = (line.quantity ?? 0) === 0;

      if (isMixLine || isRemoveLine) {
        fifoMap[line.dispatch_id] = { allocations: [], primary_expiry: null };
        continue;
      }

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

    // ── Step 5: Map lines ─────────────────────────────────────────────────────
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
      const podId = line.pod_product_id ?? "";
      const isMix = mixPodIdSet.has(podId);

      // display_name: boonz SKU for single-variant, pod name for mix header / REMOVE
      let displayName = product.pod_product_name;
      if (!isMix) {
        const boonzId =
          line.boonz_product_id ?? podToVariants.get(podId)?.[0] ?? "";
        const boonzName = boonzIdToName.get(boonzId);
        if (boonzName) displayName = boonzName;
      }

      // For mix lines, compute per-variant pack quantities from split percentages.
      // Create a new array per line (don't mutate the shared variantMap entry).
      let variantStocks: VariantStock[] | null = variantMap.get(podId) ?? null;

      if (variantStocks && (line.quantity ?? 0) > 0) {
        const podSplits = splitMap.get(podId) ?? new Map<string, number>();
        const input = variantStocks.map((v) => ({
          boonzId: v.boonzProductId,
          splitPct: podSplits.get(v.boonzProductId) ?? 0,
          inStock: v.stock > 0,
        }));
        const qtys = computeVariantQtys(line.quantity ?? 0, input);
        const qtyByBoonzId = new Map(qtys.map((q) => [q.boonzId, q.qty]));
        variantStocks = variantStocks.map((v) => ({
          ...v,
          packQty: qtyByBoonzId.get(v.boonzProductId) ?? 0,
        }));
      }

      return {
        dispatch_id: line.dispatch_id,
        boonz_product_id: line.boonz_product_id ?? "",
        pod_product_id: podId,
        shelf_code: shelf.shelf_code,
        pod_product_name: product.pod_product_name,
        display_name: displayName,
        recommended_qty: line.quantity ?? 0,
        packed_qty:
          (line.filled_quantity as number | null) ?? line.quantity ?? 0,
        action: isPacked ? "packed" : null,
        fifo_expiry: fifo.primary_expiry,
        allocations: fifo.allocations,
        warehouse_stock: stockMap.get(line.boonz_product_id ?? "") ?? 0,
        variantStocks,
      };
    });

    mapped.sort((a, b) => a.shelf_code.localeCompare(b.shelf_code));
    setLines(mapped);

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
              const isRemove = line.recommended_qty === 0;
              const isMix = line.variantStocks !== null;
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
                  {/* Primary label */}
                  <p className="mb-0.5 flex flex-wrap items-center gap-1.5 text-sm font-medium">
                    {line.display_name}
                    {!isRemove &&
                      !isMix &&
                      (() => {
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

                  {/* Stock / FIFO / Remove / Mix breakdown ───────────────── */}
                  {isRemove ? (
                    <p className="mb-2 inline-flex items-center gap-1 rounded bg-neutral-100 px-2 py-0.5 text-xs text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400">
                      Remove from machine
                    </p>
                  ) : isMix ? (
                    /* Mix product — per-variant rows with split quantities */
                    <div className="mb-2">
                      {line.variantStocks!.every((v) => v.packQty === 0) ? (
                        <p className="text-xs font-medium text-red-600 dark:text-red-400">
                          Out of stock
                        </p>
                      ) : (
                        <div className="space-y-0.5 rounded-md border border-neutral-100 bg-neutral-50 px-2 py-1.5 dark:border-neutral-800 dark:bg-neutral-900">
                          {line
                            .variantStocks!.filter((v) => v.packQty > 0)
                            .map((v) => (
                              <div
                                key={v.boonzProductId}
                                className="flex items-center gap-2 text-xs"
                              >
                                <span className="flex-1 truncate text-neutral-700 dark:text-neutral-300">
                                  {v.name}
                                </span>
                                <span className="shrink-0 font-medium text-neutral-600 dark:text-neutral-400">
                                  Pack: {v.packQty}
                                </span>
                                <span
                                  className={`shrink-0 ${stockColor(v.stock, v.packQty)}`}
                                >
                                  Stock: {v.stock}
                                </span>
                              </div>
                            ))}
                        </div>
                      )}
                    </div>
                  ) : (
                    /* Single-variant — FIFO expiry + flat stock count */
                    <>
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
                    </>
                  )}

                  {/* Packed qty input (total for mix lines) */}
                  <div className="mb-2 flex items-center gap-2">
                    <label className="text-xs text-neutral-500">
                      {isMix ? "Total packed:" : "Packed qty:"}
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
                      disabled={isReadOnly || isRemove}
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
