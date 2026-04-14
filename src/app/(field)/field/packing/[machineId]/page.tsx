"use client";

import { useEffect, useState, useCallback } from "react";
import { useParams } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import { FieldHeader } from "../../../components/field-header";
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
  /** Earliest expiry date across all in-stock batches (FIFO first), null if no expiry recorded */
  earliestExpiry: string | null;
  /** Individual warehouse_inventory batch rows for this variant, ordered expiry ASC */
  batches: { wh_inventory_id: string; expiry: string | null; stock: number }[];
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
  /** Batch rows for single-variant non-remove lines — same shape as VariantStock.batches */
  singleBatches:
    | { wh_inventory_id: string; expiry: string | null; stock: number }[]
    | null;
}

interface MachineInfo {
  official_name: string;
  pod_location: string | null;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/** Format a YYYY-MM-DD date string as "12 Jul 26" */
function formatExpiry(dateStr: string): string {
  return new Date(dateStr + "T00:00:00").toLocaleDateString("en-GB", {
    day: "numeric",
    month: "short",
    year: "2-digit",
  });
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

  /**
   * Per-batch pick quantities for mix lines.
   * Shape: { [dispatch_id]: { [wh_inventory_id]: qty } }
   * Initialized via FIFO from packQty; user edits batch inputs directly.
   */
  const [batchPickQtys, setBatchPickQtys] = useState<
    Record<string, Record<string, number>>
  >({});

  /** dispatch_ids that showed zero-total warning when Packed was clicked */
  const [zeroQtyWarnings, setZeroQtyWarnings] = useState<Set<string>>(
    new Set(),
  );
  /**
   * boonz_product_id → total qty already packed to OTHER machines today
   * (packed=true, dispatched=false). Used for double-allocation warnings.
   */
  const [committedByProduct, setCommittedByProduct] = useState<
    Map<string, number>
  >(new Map());
  /** `${boonz_product_id}|||${expiry_date ?? 'null'}` → committed qty (per-batch FIFO key) */
  const [committedByBatch, setCommittedByBatch] = useState<Map<string, number>>(
    new Map(),
  );

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
        expiry_date,
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

    // Fetch ALL Active warehouse batches unconditionally so the query runs
    // even when allBoonzIds is empty (e.g. dispatch lines with null boonz_product_id).
    const { data: rawBatchData } = await supabase
      .from("warehouse_inventory")
      .select(
        "wh_inventory_id, boonz_product_id, warehouse_stock, expiration_date",
      )
      .eq("status", "Active")
      .gt("warehouse_stock", 0)
      .order("expiration_date", { ascending: true, nullsFirst: false })
      .limit(10000);

    const rawBatches: WBatch[] = (rawBatchData ?? []) as WBatch[];

    const batchPool = new Map<
      string,
      {
        wh_inventory_id: string;
        expiry_date: string | null;
        available: number;
      }[]
    >();
    const stockMap = new Map<string, number>();

    // earliestExpiry: boonz_product_id → earliest non-null expiration_date
    const earliestExpiryMap = new Map<string, string>();

    // batchMap: boonz_product_id → ordered batch list for FIFO picking guide
    const batchMap = new Map<
      string,
      { wh_inventory_id: string; expiry: string | null; stock: number }[]
    >();

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
      // Track earliest expiry (rows are already ordered ASC NULLS LAST)
      if (b.expiration_date) {
        const existing = earliestExpiryMap.get(b.boonz_product_id);
        if (!existing || b.expiration_date < existing) {
          earliestExpiryMap.set(b.boonz_product_id, b.expiration_date);
        }
      }
      // Accumulate per-batch rows for the picking guide (order preserved from query)
      if (!batchMap.has(b.boonz_product_id))
        batchMap.set(b.boonz_product_id, []);
      batchMap.get(b.boonz_product_id)!.push({
        wh_inventory_id: b.wh_inventory_id,
        expiry: b.expiration_date,
        stock: b.warehouse_stock ?? 0,
      });
    }

    // whStockMap: exact key `${boonz_product_id}|||${expiry ?? 'null'}` → stock
    // Used so a stale expiry_date on a dispatch line (from a prior refill cycle)
    // can still fall back to total Active stock when the exact batch is gone.
    const whStockMap = new Map<string, number>();
    // whBatchInfoMap / whIdToStock: needed to cap initBatchPickQtys after committed fetch
    const whBatchInfoMap = new Map<
      string,
      { boonz_product_id: string; expiry: string | null }
    >();
    const whIdToStock = new Map<string, number>();
    for (const b of rawBatches) {
      const key = `${b.boonz_product_id}|||${b.expiration_date ?? "null"}`;
      whStockMap.set(
        key,
        (whStockMap.get(key) ?? 0) + (b.warehouse_stock ?? 0),
      );
      whBatchInfoMap.set(b.wh_inventory_id, {
        boonz_product_id: b.boonz_product_id,
        expiry: b.expiration_date,
      });
      whIdToStock.set(b.wh_inventory_id, b.warehouse_stock ?? 0);
    }
    // stockMap already serves as whTotalMap: boonz_product_id → total Active stock

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
            earliestExpiry: earliestExpiryMap.get(boonzId) ?? null,
            batches: batchMap.get(boonzId) ?? [],
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

      const isRemoveLine = (line.quantity ?? 0) === 0;
      const singleBatches =
        !isMix && !isRemoveLine
          ? (batchMap.get(line.boonz_product_id ?? "") ?? [])
          : null;

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
        warehouse_stock: (() => {
          const bpId = line.boonz_product_id ?? "";
          const lineExpiry = (line.expiry_date as string | null) ?? null;
          const exactKey = `${bpId}|||${lineExpiry ?? "null"}`;
          const exact = whStockMap.get(exactKey) ?? 0;
          const total = stockMap.get(bpId) ?? 0;
          // If the exact batch the dispatch line was last packed against is now
          // exhausted/inactive, fall back to total Active stock for this SKU so
          // the "No stock found" warning only fires when the product is truly OOS.
          return exact > 0 ? exact : total;
        })(),
        variantStocks,
        singleBatches,
      };
    });

    mapped.sort((a, b) => a.shelf_code.localeCompare(b.shelf_code));
    setLines(mapped);

    // Initialise batchPickQtys: FIFO distribute each variant's packQty across its batches
    // Initialise batchPickQtys: FIFO-fill batches for both mix and single-variant lines
    const initBatchPickQtys: Record<string, Record<string, number>> = {};

    const fillBatches = (
      dispatchId: string,
      batches: { wh_inventory_id: string; stock: number }[],
      qty: number,
    ) => {
      if (!initBatchPickQtys[dispatchId]) initBatchPickQtys[dispatchId] = {};
      let remaining = qty;
      for (const batch of batches) {
        const take = Math.min(batch.stock, remaining);
        initBatchPickQtys[dispatchId][batch.wh_inventory_id] = take;
        remaining -= take;
        if (remaining <= 0) break;
      }
      // Remaining batches default to 0
      for (const batch of batches) {
        if (!(batch.wh_inventory_id in initBatchPickQtys[dispatchId])) {
          initBatchPickQtys[dispatchId][batch.wh_inventory_id] = 0;
        }
      }
    };

    for (const line of mapped) {
      if (line.variantStocks) {
        // Mix: distribute each variant's packQty across its own batches
        for (const v of line.variantStocks) {
          fillBatches(line.dispatch_id, v.batches, v.packQty);
        }
      } else if (line.singleBatches !== null) {
        // Single-variant: distribute recommended_qty across batches
        fillBatches(line.dispatch_id, line.singleBatches, line.recommended_qty);
      }
    }
    // Fetch committed (packed=true, dispatched=false) for other machines today
    const { data: committedRows } = await supabase
      .from("refill_dispatching")
      .select("boonz_product_id, expiry_date, filled_quantity, quantity")
      .eq("dispatch_date", today)
      .eq("packed", true)
      .eq("dispatched", false)
      .eq("include", true)
      .neq("machine_id", machineId)
      .limit(10000);

    const committedMap = new Map<string, number>();
    const committedBatchMap = new Map<string, number>();
    for (const row of committedRows ?? []) {
      if (!row.boonz_product_id) continue;
      const qty =
        (row.filled_quantity as number | null) ??
        (row.quantity as number | null) ??
        0;
      committedMap.set(
        row.boonz_product_id,
        (committedMap.get(row.boonz_product_id) ?? 0) + qty,
      );
      const bk = `${row.boonz_product_id}|||${(row.expiry_date as string | null) ?? "null"}`;
      committedBatchMap.set(bk, (committedBatchMap.get(bk) ?? 0) + qty);
    }
    setCommittedByProduct(committedMap);
    setCommittedByBatch(committedBatchMap);

    // Cap initBatchPickQtys to batchAvailable (WH stock minus committed to other machines)
    for (const dispatchId of Object.keys(initBatchPickQtys)) {
      for (const whId of Object.keys(initBatchPickQtys[dispatchId])) {
        const info = whBatchInfoMap.get(whId);
        if (!info) continue;
        const bk = `${info.boonz_product_id}|||${info.expiry ?? "null"}`;
        const committed = committedBatchMap.get(bk) ?? 0;
        const rawStock = whIdToStock.get(whId) ?? 0;
        const available = Math.max(0, rawStock - committed);
        initBatchPickQtys[dispatchId][whId] = Math.min(
          initBatchPickQtys[dispatchId][whId],
          available,
        );
      }
    }
    setBatchPickQtys(initBatchPickQtys);

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

  function variantTotal(dispatchId: string): number {
    return Object.values(batchPickQtys[dispatchId] ?? {}).reduce(
      (s, n) => s + n,
      0,
    );
  }

  function handleMarkAllPacked() {
    setLines((prev) =>
      prev.map((l) => ({
        ...l,
        action: "packed" as LineAction,
        // For single-variant lines keep recommended_qty; mix lines use variantQtys
        packed_qty: l.variantStocks ? l.packed_qty : l.recommended_qty,
      })),
    );
  }

  // ── Save ────────────────────────────────────────────────────────────────────

  async function handleConfirmPacking() {
    setSaving(true);
    const supabase = createClient();

    for (const line of lines) {
      if (line.action === "packed") {
        const filledQty =
          batchPickQtys[line.dispatch_id] !== undefined
            ? variantTotal(line.dispatch_id)
            : line.packed_qty;

        await supabase
          .from("refill_dispatching")
          .update({
            packed: true,
            filled_quantity: filledQty,
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
            include: false,
          })
          .eq("dispatch_id", line.dispatch_id);
      }
    }

    setSaving(false);
    setSaved(true);
    setEditingAfterSave(false);
  }

  // Intercept Packed button for mix lines: show warning if total = 0
  function handlePackedClick(line: PackLine) {
    const hasTable = line.variantStocks !== null || line.singleBatches !== null;
    if (hasTable && variantTotal(line.dispatch_id) === 0) {
      setZeroQtyWarnings((prev) => new Set([...prev, line.dispatch_id]));
    }
    updateAction(line.dispatch_id, "packed");
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

              // Committed stock from other machines today (single-variant only)
              const lineCommitted =
                !isRemove && !isMix
                  ? (committedByProduct.get(line.boonz_product_id) ?? 0)
                  : 0;
              const lineAvailable = line.warehouse_stock - lineCommitted;
              // Per-batch total available — used for hard cap on Packed button
              const totalBatchAvailable =
                !isRemove &&
                !isMix &&
                line.singleBatches &&
                line.singleBatches.length > 0
                  ? line.singleBatches.reduce((sum, b) => {
                      const bk = `${line.boonz_product_id}|||${b.expiry ?? "null"}`;
                      const bc = committedByBatch.get(bk) ?? 0;
                      return sum + Math.max(0, b.stock - bc);
                    }, 0)
                  : lineAvailable;
              const fullyCommitted =
                !isRemove &&
                !isMix &&
                lineCommitted > 0 &&
                totalBatchAvailable <= 0;

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
                    /* Mix product — per-variant editable qty inputs */
                    <div className="mb-2">
                      {line.variantStocks!.every(
                        (v) => v.packQty === 0 && v.stock === 0,
                      ) ? (
                        <p className="text-xs font-medium text-amber-600 dark:text-amber-400">
                          ⚠ No warehouse stock — skip or receive new stock
                        </p>
                      ) : (
                        <div className="space-y-2">
                          {line
                            .variantStocks!.filter(
                              (v) => v.packQty > 0 || v.stock > 0,
                            )
                            .map((v) => {
                              const variantPickTotal = v.batches.reduce(
                                (sum, b) =>
                                  sum +
                                  (batchPickQtys[line.dispatch_id]?.[
                                    b.wh_inventory_id
                                  ] ?? 0),
                                0,
                              );
                              return (
                                <div key={v.boonzProductId}>
                                  <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-neutral-700 dark:text-neutral-300">
                                    {v.name}
                                  </div>
                                  <div className="w-full overflow-hidden rounded-lg border border-neutral-200 divide-y divide-neutral-100 dark:divide-neutral-800 dark:border-neutral-700">
                                    {/* Header row */}
                                    <div className="grid grid-cols-4 bg-neutral-50 px-3 py-1.5 text-xs font-medium text-neutral-500 dark:bg-neutral-900 dark:text-neutral-400">
                                      <span>Expiry</span>
                                      <span>In Stock</span>
                                      <span>Pick Qty</span>
                                      <span>Age</span>
                                    </div>
                                    {/* Batch rows */}
                                    {v.batches.map((b) => {
                                      const pickQty =
                                        batchPickQtys[line.dispatch_id]?.[
                                          b.wh_inventory_id
                                        ] ?? 0;
                                      const batchKey = `${v.boonzProductId}|||${b.expiry ?? "null"}`;
                                      const batchCommitted =
                                        committedByBatch.get(batchKey) ?? 0;
                                      const batchAvailable = Math.max(
                                        0,
                                        b.stock - batchCommitted,
                                      );
                                      const days = b.expiry
                                        ? Math.ceil(
                                            (new Date(
                                              b.expiry + "T00:00:00",
                                            ).getTime() -
                                              Date.now()) /
                                              86400000,
                                          )
                                        : null;
                                      const urgencyColor =
                                        days === null
                                          ? "text-neutral-400 dark:text-neutral-500"
                                          : days <= 30
                                            ? "text-red-500 font-medium dark:text-red-400"
                                            : days <= 60
                                              ? "text-amber-500 dark:text-amber-400"
                                              : "text-neutral-400 dark:text-neutral-500";
                                      return (
                                        <div
                                          key={b.wh_inventory_id}
                                          className="grid grid-cols-4 items-center px-3 py-2 text-sm hover:bg-neutral-50 dark:hover:bg-neutral-900"
                                        >
                                          <span
                                            className={`font-mono text-xs ${urgencyColor}`}
                                          >
                                            {b.expiry
                                              ? formatExpiry(b.expiry)
                                              : "—"}
                                          </span>
                                          <span className="text-xs text-neutral-600 dark:text-neutral-400">
                                            {b.stock}u
                                          </span>
                                          <input
                                            type="number"
                                            min={0}
                                            max={batchAvailable}
                                            value={pickQty}
                                            disabled={
                                              isReadOnly || batchAvailable === 0
                                            }
                                            onChange={(e) => {
                                              const val = Math.min(
                                                batchAvailable,
                                                Math.max(
                                                  0,
                                                  parseInt(e.target.value) || 0,
                                                ),
                                              );
                                              setBatchPickQtys((prev) => ({
                                                ...prev,
                                                [line.dispatch_id]: {
                                                  ...(prev[line.dispatch_id] ??
                                                    {}),
                                                  [b.wh_inventory_id]: val,
                                                },
                                              }));
                                              setZeroQtyWarnings((prev) => {
                                                if (!prev.has(line.dispatch_id))
                                                  return prev;
                                                const next = new Set(prev);
                                                next.delete(line.dispatch_id);
                                                return next;
                                              });
                                            }}
                                            className={`w-14 rounded border px-1 py-0.5 text-center text-sm focus:outline-none focus:border-blue-400 disabled:opacity-50 dark:bg-neutral-800 dark:text-neutral-200 ${
                                              pickQty >= batchAvailable &&
                                              batchAvailable > 0
                                                ? "border-amber-400"
                                                : "border-neutral-300 dark:border-neutral-600"
                                            }`}
                                          />
                                          <span
                                            className={`text-xs ${urgencyColor}`}
                                          >
                                            {days !== null ? `${days}d` : "—"}
                                          </span>
                                        </div>
                                      );
                                    })}
                                    {/* Total row */}
                                    <div className="grid grid-cols-4 border-t border-neutral-200 bg-neutral-50 px-3 py-1.5 dark:border-neutral-800 dark:bg-neutral-900">
                                      <span className="col-span-2 text-xs text-neutral-500">
                                        Total picked
                                      </span>
                                      <span className="text-sm font-semibold text-neutral-800 dark:text-neutral-200">
                                        {variantPickTotal}
                                      </span>
                                      <span />
                                    </div>
                                    {/* Double-allocation warning for this variant */}
                                    {(() => {
                                      const vc =
                                        committedByProduct.get(
                                          v.boonzProductId,
                                        ) ?? 0;
                                      if (vc === 0) return null;
                                      const va = v.stock - vc;
                                      return (
                                        <div className="border-t border-neutral-100 px-3 py-2 text-xs dark:border-neutral-800">
                                          <span className="text-neutral-500">
                                            WH: {v.stock}u
                                          </span>
                                          {" | "}
                                          <span className="text-amber-600 dark:text-amber-400">
                                            Committed: {vc}
                                          </span>
                                          {" | "}
                                          <span
                                            className={
                                              va > 0
                                                ? "text-green-700 dark:text-green-400"
                                                : "text-red-600 dark:text-red-400"
                                            }
                                          >
                                            Avail: {va}
                                          </span>
                                          {va <= 0 && (
                                            <p className="mt-1 font-medium text-red-600 dark:text-red-400">
                                              ✗ Fully committed to other
                                              machines
                                            </p>
                                          )}
                                        </div>
                                      );
                                    })()}
                                  </div>
                                </div>
                              );
                            })}
                        </div>
                      )}
                      {/* Zero-qty warning */}
                      {zeroQtyWarnings.has(line.dispatch_id) && (
                        <p className="mt-1 text-xs text-amber-600 dark:text-amber-400">
                          Enter at least 1 unit across variants
                        </p>
                      )}
                    </div>
                  ) : (
                    /* Single-variant — per-batch pick table (same layout as mix) */
                    <div className="mb-2">
                      {!line.singleBatches ||
                      line.singleBatches.length === 0 ? (
                        line.warehouse_stock > 0 ? (
                          /* Batch detail unavailable but Active stock exists (e.g.
                             dispatch line still carries a stale expiry from a prior
                             refill cycle while the fresh batch is a different row) */
                          <p className="inline-flex items-center gap-1 rounded bg-neutral-100 px-2 py-0.5 text-xs text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400">
                            {line.warehouse_stock} units available in warehouse
                          </p>
                        ) : (
                          <p className="inline-flex items-center gap-1 rounded bg-amber-50 px-2 py-0.5 text-xs text-amber-700 dark:bg-amber-900/30 dark:text-amber-300">
                            ⚠ No stock found in warehouse
                          </p>
                        )
                      ) : (
                        <div className="w-full overflow-hidden rounded-lg border border-neutral-200 divide-y divide-neutral-100 dark:divide-neutral-800 dark:border-neutral-700">
                          {/* Header row */}
                          <div className="grid grid-cols-4 bg-neutral-50 px-3 py-1.5 text-xs font-medium text-neutral-500 dark:bg-neutral-900 dark:text-neutral-400">
                            <span>Expiry</span>
                            <span>In Stock</span>
                            <span>Pick Qty</span>
                            <span>Age</span>
                          </div>
                          {/* Batch rows */}
                          {line.singleBatches.map((b) => {
                            const pickQty =
                              batchPickQtys[line.dispatch_id]?.[
                                b.wh_inventory_id
                              ] ?? 0;
                            const batchKey = `${line.boonz_product_id}|||${b.expiry ?? "null"}`;
                            const batchCommitted =
                              committedByBatch.get(batchKey) ?? 0;
                            const batchAvailable = Math.max(
                              0,
                              b.stock - batchCommitted,
                            );
                            const days = b.expiry
                              ? Math.ceil(
                                  (new Date(b.expiry + "T00:00:00").getTime() -
                                    Date.now()) /
                                    86400000,
                                )
                              : null;
                            const urgencyColor =
                              days === null
                                ? "text-neutral-400 dark:text-neutral-500"
                                : days <= 30
                                  ? "text-red-500 font-medium dark:text-red-400"
                                  : days <= 60
                                    ? "text-amber-500 dark:text-amber-400"
                                    : "text-neutral-400 dark:text-neutral-500";
                            return (
                              <div
                                key={b.wh_inventory_id}
                                className="grid grid-cols-4 items-center px-3 py-2 text-sm hover:bg-neutral-50 dark:hover:bg-neutral-900"
                              >
                                <span
                                  className={`font-mono text-xs ${urgencyColor}`}
                                >
                                  {b.expiry ? formatExpiry(b.expiry) : "—"}
                                </span>
                                <span className="text-xs text-neutral-600 dark:text-neutral-400">
                                  {b.stock}u
                                </span>
                                <input
                                  type="number"
                                  min={0}
                                  max={batchAvailable}
                                  value={pickQty}
                                  disabled={isReadOnly || batchAvailable === 0}
                                  onChange={(e) => {
                                    const val = Math.min(
                                      batchAvailable,
                                      Math.max(
                                        0,
                                        parseInt(e.target.value) || 0,
                                      ),
                                    );
                                    setBatchPickQtys((prev) => ({
                                      ...prev,
                                      [line.dispatch_id]: {
                                        ...(prev[line.dispatch_id] ?? {}),
                                        [b.wh_inventory_id]: val,
                                      },
                                    }));
                                    setZeroQtyWarnings((prev) => {
                                      if (!prev.has(line.dispatch_id))
                                        return prev;
                                      const next = new Set(prev);
                                      next.delete(line.dispatch_id);
                                      return next;
                                    });
                                  }}
                                  className={`w-14 rounded border px-1 py-0.5 text-center text-sm focus:outline-none focus:border-blue-400 disabled:opacity-50 dark:bg-neutral-800 dark:text-neutral-200 ${
                                    pickQty >= batchAvailable &&
                                    batchAvailable > 0
                                      ? "border-amber-400"
                                      : "border-neutral-300 dark:border-neutral-600"
                                  }`}
                                />
                                <span className={`text-xs ${urgencyColor}`}>
                                  {days !== null ? `${days}d` : "—"}
                                </span>
                              </div>
                            );
                          })}
                          {/* Total row */}
                          <div className="grid grid-cols-4 border-t border-neutral-200 bg-neutral-50 px-3 py-1.5 dark:border-neutral-800 dark:bg-neutral-900">
                            <span className="col-span-2 text-xs text-neutral-500">
                              Total picked
                            </span>
                            <span className="text-sm font-semibold text-neutral-800 dark:text-neutral-200">
                              {variantTotal(line.dispatch_id)}
                            </span>
                            <span />
                          </div>
                          {/* Double-allocation warning */}
                          {lineCommitted > 0 && (
                            <div className="border-t border-neutral-100 px-3 py-2 text-xs dark:border-neutral-800">
                              <span className="text-neutral-500">
                                WH: {line.warehouse_stock}u
                              </span>
                              {" | "}
                              <span className="text-amber-600 dark:text-amber-400">
                                Committed: {lineCommitted}
                              </span>
                              {" | "}
                              <span
                                className={
                                  lineAvailable > 0
                                    ? "text-green-700 dark:text-green-400"
                                    : "text-red-600 dark:text-red-400"
                                }
                              >
                                Available: {lineAvailable}
                              </span>
                              {lineAvailable <= 0 && (
                                <p className="mt-1 font-medium text-red-600 dark:text-red-400">
                                  ✗ No stock available — fully committed to
                                  other machines
                                </p>
                              )}
                              {lineAvailable > 0 &&
                                lineAvailable < line.recommended_qty && (
                                  <p className="mt-1 text-red-600 dark:text-red-400">
                                    ⚠ Only {lineAvailable} available —{" "}
                                    {lineCommitted} committed to other machines
                                  </p>
                                )}
                            </div>
                          )}
                        </div>
                      )}
                      {/* Zero-qty warning */}
                      {zeroQtyWarnings.has(line.dispatch_id) && (
                        <p className="mt-1 text-xs text-amber-600 dark:text-amber-400">
                          Enter at least 1 unit
                        </p>
                      )}
                    </div>
                  )}

                  {/* Action toggle */}
                  {!isReadOnly && (
                    <div className="flex gap-2">
                      <button
                        onClick={() => handlePackedClick(line)}
                        disabled={fullyCommitted}
                        className={`flex-1 rounded-lg border py-1.5 text-xs font-semibold transition-colors disabled:cursor-not-allowed disabled:opacity-40 ${
                          line.action === "packed"
                            ? "border-green-400 bg-green-50 text-green-700 dark:bg-green-950/40 dark:text-green-400"
                            : "border-neutral-200 text-neutral-500 hover:bg-neutral-50 dark:border-neutral-700 dark:hover:bg-neutral-800"
                        }`}
                      >
                        {fullyCommitted ? "✗ No stock" : "✓ Packed"}
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
