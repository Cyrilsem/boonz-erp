"use client";

import { useEffect, useState, useCallback } from "react";
import { useParams } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import { FieldHeader } from "../../../components/field-header";
import type { DispatchAction, ExpiryWarning } from "@/lib/dispatch-types";
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
  shelf_id: string | null;
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
  /** Raw DB filled_quantity — null if line has never been packed */
  filled_quantity: number | null;
  action: LineAction;
  /** DB packed boolean — true if this line was already packed+saved in a prior session */
  packed: boolean;
  fifo_expiry: string | null;
  /** Saved expiry_date from the DB (set when line was previously packed) */
  expiry_date: string | null;
  allocations: BatchAllocation[];
  warehouse_stock: number;
  /** Non-null only for mix products (pod_product maps to >1 boonz variant) */
  variantStocks: VariantStock[] | null;
  /** Batch rows for single-variant non-remove lines — same shape as VariantStock.batches */
  singleBatches:
    | { wh_inventory_id: string; expiry: string | null; stock: number }[]
    | null;
  /** Boonz SKU name — shown as section header inside the card */
  boonz_display_name: string | null;
  /** Extra slice dispatch_ids absorbed into this card (from prior multi-batch save) */
  extraSliceIds: string[];
  /** Per-expiry packed quantities from absorbed extra slices: expiry → filled_quantity */
  extraSlicePacked: { expiry: string | null; qty: number }[];
  /** Raw action from refill_dispatching (Refill, Add New, Remove) */
  dispatch_action: DispatchAction | string; // string fallback for legacy values
  /** Raw comment from refill_dispatching */
  dispatch_comment: string | null;
  /** Source warehouse UUID */
  from_warehouse_id: string | null;
  /** Source warehouse display name (e.g. "WH_CENTRAL", "WH_MM") */
  from_warehouse_name: string | null;
  /** Expiry flag set by the refill engine at plan-write time */
  expiry_warning: ExpiryWarning | null;
  /** Whether this item was returned on a prior dispatch run */
  returned: boolean;
  /** Reason recorded when item was returned */
  return_reason: string | null;
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

// ─── WH stock helpers (module-level, reusable) ───────────────────────────────

/**
 * Restore `qty` units back to warehouse_inventory for the given expiry batch.
 * Called when a previously-packed line is skipped (WH deduction reversal).
 */
async function restoreWarehouseStock(
  sb: ReturnType<typeof createClient>,
  boonzProductId: string,
  expiry: string | null,
  qty: number,
): Promise<void> {
  if (expiry) {
    const { data: batch } = await sb
      .from("warehouse_inventory")
      .select("wh_inventory_id, warehouse_stock")
      .eq("boonz_product_id", boonzProductId)
      .eq("expiration_date", expiry)
      .maybeSingle(); // include Inactive rows — may need to reactivate

    if (batch) {
      const newStock = (batch.warehouse_stock ?? 0) + qty;
      await sb
        .from("warehouse_inventory")
        .update({ warehouse_stock: newStock, status: "Active" })
        .eq("wh_inventory_id", batch.wh_inventory_id);
      return;
    }
  }

  // Defensive fallback: batch not found — create a new WH row
  // (should not occur in normal flow)
  await sb.from("warehouse_inventory").insert({
    boonz_product_id: boonzProductId,
    warehouse_stock: qty,
    expiration_date: expiry,
    status: "Active",
    snapshot_date: getDubaiDate(),
  });
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
  const [whWarnMsg, setWhWarnMsg] = useState<string>("");
  /** B3.1: skipped-but-recoverable lines (include=false, packed=false) */
  const [skippedLines, setSkippedLines] = useState<
    {
      dispatch_id: string;
      shelf_code: string;
      display_name: string;
      quantity: number;
    }[]
  >([]);

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

    // Fetch warehouse name map for source-warehouse display
    const { data: warehouseRows } = await supabase
      .from("warehouses")
      .select("warehouse_id, name");
    const whNameMap = new Map<string, string>(
      (warehouseRows ?? []).map((w) => [w.warehouse_id as string, w.name as string]),
    );

    const { data: dispatchLines } = await supabase
      .from("refill_dispatching")
      .select(
        `
        dispatch_id,
        boonz_product_id,
        pod_product_id,
        shelf_id,
        quantity,
        filled_quantity,
        packed,
        returned,
        return_reason,
        expiry_date,
        expiry_warning,
        from_warehouse_id,
        action,
        comment,
        shelf_configurations!inner(shelf_code),
        pod_products!inner(pod_product_name)
      `,
      )
      .eq("dispatch_date", today)
      .eq("include", true)
      .eq("machine_id", machineId);

    // B3.1 Issue 6: fetch skipped-but-recoverable lines (include=false)
    // so the UI can show an "Un-skip" affordance.
    const { data: skippedRaw } = await supabase
      .from("refill_dispatching")
      .select(
        `
        dispatch_id,
        quantity,
        shelf_configurations(shelf_code),
        pod_products(pod_product_name)
      `,
      )
      .eq("dispatch_date", today)
      .eq("include", false)
      .eq("packed", false)
      .eq("machine_id", machineId)
      .limit(10000);

    setSkippedLines(
      (skippedRaw ?? []).map((r) => {
        const shelf = r.shelf_configurations as unknown as {
          shelf_code: string | null;
        } | null;
        const prod = r.pod_products as unknown as {
          pod_product_name: string | null;
        } | null;
        return {
          dispatch_id: r.dispatch_id,
          shelf_code: shelf?.shelf_code ?? "—",
          display_name: prod?.pod_product_name ?? "—",
          quantity: Number(r.quantity ?? 0),
        };
      }),
    );

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

    // Direct name lookup for dispatch-line boonz IDs (ensures correct name
    // even when product_mapping doesn't carry the FK-joined name for this SKU)
    const directBoonzIds = dispatchLines
      .map((l) => l.boonz_product_id)
      .filter((id): id is string => id !== null && !boonzIdToName.has(id));
    if (directBoonzIds.length > 0) {
      // Fix: use product_id (the actual PK) not boonz_product_id
      const { data: directNames } = await supabase
        .from("boonz_products")
        .select("product_id, boonz_product_name")
        .in("product_id", [...new Set(directBoonzIds)])
        .limit(1000);
      for (const row of directNames ?? []) {
        if (row.boonz_product_name && row.product_id) {
          boonzIdToName.set(row.product_id as string, row.boonz_product_name as string);
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

    // Fetch Active warehouse batches for relevant boonz products only.
    // When allBoonzIds is empty (e.g. dispatch lines with null boonz_product_id),
    // skip the query entirely — no warehouse rows needed.
    const { data: rawBatchData } =
      allBoonzIds.length > 0
        ? await supabase
            .from("warehouse_inventory")
            .select(
              "wh_inventory_id, boonz_product_id, warehouse_stock, expiration_date",
            )
            .in("boonz_product_id", allBoonzIds)
            .eq("status", "Active")
            .gt("warehouse_stock", 0)
            .order("expiration_date", { ascending: true, nullsFirst: false })
            .limit(10000)
        : { data: [] };

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
      // A line is only mix if the pod has >1 variant AND this line has no
      // boonz_product_id (refill engine left it for packing to split).
      // If the line already has a boonz_product_id, it's a single-variant line.
      const isMixLine =
        !line.boonz_product_id &&
        !!line.pod_product_id &&
        mixPodIdSet.has(line.pod_product_id);
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
      // A line is only mix if the pod has >1 variant AND this line has no
      // boonz_product_id (refill engine left it for packing to split).
      const isMix = !line.boonz_product_id && mixPodIdSet.has(podId);

      // Resolve boonz product name for section header inside card
      const boonzDisplayName = (() => {
        const boonzId =
          line.boonz_product_id ?? podToVariants.get(podId)?.[0] ?? "";
        return boonzIdToName.get(boonzId) ?? null;
      })();
      // display_name: boonz_product_name for single-variant lines (brand-accurate),
      // pod_product_name for mix lines (category header) or when boonz name unavailable.
      const displayName =
        !isMix && boonzDisplayName ? boonzDisplayName : product.pod_product_name;

      // For mix lines, compute per-variant pack quantities from split percentages.
      // Create a new array per line (don't mutate the shared variantMap entry).
      // Only use variantStocks for actual mix lines — single-variant lines with a
      // boonz_product_id use singleBatches directly (no split_pct distribution).
      let variantStocks: VariantStock[] | null = isMix
        ? (variantMap.get(podId) ?? null)
        : null;

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
        shelf_id: (line.shelf_id as string | null) ?? null,
        shelf_code: shelf.shelf_code,
        pod_product_name: product.pod_product_name,
        display_name: displayName,
        recommended_qty: line.quantity ?? 0,
        packed_qty:
          (line.filled_quantity as number | null) ?? line.quantity ?? 0,
        filled_quantity: (line.filled_quantity as number | null) ?? null,
        action: isPacked ? "packed" : null,
        packed: isPacked,
        fifo_expiry: fifo.primary_expiry,
        expiry_date: (line.expiry_date as string | null) ?? null,
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
        boonz_display_name: boonzDisplayName,
        extraSliceIds: [],
        extraSlicePacked: [],
        dispatch_action:
          ((line as Record<string, unknown>).action as string) ?? "Refill",
        dispatch_comment:
          ((line as Record<string, unknown>).comment as string | null) ?? null,
        from_warehouse_id:
          (line.from_warehouse_id as string | null) ?? null,
        from_warehouse_name: (() => {
          const whId = line.from_warehouse_id as string | null;
          return whId ? (whNameMap.get(whId) ?? null) : null;
        })(),
        expiry_warning:
          (line.expiry_warning as
            | "expiring_soon"
            | "expired"
            | "no_expiry"
            | null) ?? null,
        returned: !!((line as Record<string, unknown>).returned as boolean | null),
        return_reason:
          ((line as Record<string, unknown>).return_reason as string | null) ?? null,
      };
    });

    mapped.sort((a, b) => a.shelf_code.localeCompare(b.shelf_code));

    // ── Merge extra slice lines back into their primary card ────────────
    // When multi-batch packing creates extra dispatch lines (same boonz_product_id,
    // different expiry), merge them into one card so the user sees one card per
    // variant with all batch rows. The extra slices' filled_qty+expiry are tracked
    // in extraSlicePacked for batchPickQtys initialization.
    const mergedMap = new Map<string, PackLine>();
    const mergedList: PackLine[] = [];

    for (const line of mapped) {
      const isRemove = line.recommended_qty === 0 && !line.packed;
      const isMix = line.variantStocks !== null;
      // Only merge single-variant non-remove packed lines
      if (isRemove || isMix) {
        mergedList.push(line);
        continue;
      }
      const key = `${line.boonz_product_id}|||${line.shelf_code}`;
      const existing = mergedMap.get(key);
      if (!existing) {
        mergedMap.set(key, line);
        mergedList.push(line);
      } else {
        // Absorb this line into the existing primary
        existing.extraSliceIds.push(line.dispatch_id);
        if (
          line.packed &&
          line.filled_quantity != null &&
          line.filled_quantity > 0
        ) {
          existing.extraSlicePacked.push({
            expiry: line.expiry_date,
            qty: line.filled_quantity,
          });
        }
        // Sum recommended qty from absorbed lines
        existing.recommended_qty += line.recommended_qty;
        // If either is packed, the primary is packed
        if (line.packed && !existing.packed) {
          existing.packed = true;
          existing.action = "packed";
        }
      }
    }

    // ── Inject synthetic batch rows for packed expiries not in WH ────────
    // When a packed line's expiry no longer exists in warehouse_inventory (stock = 0
    // or batch consumed), add a synthetic batch row so edit mode can show and adjust it.
    for (const line of mergedList) {
      if (!line.packed || !line.singleBatches) continue;
      const existingExpiries = new Set(
        line.singleBatches.map((b) => b.expiry ?? "__null__"),
      );
      // Collect all packed expiries (primary + extra slices)
      const packedExpiries: { expiry: string | null; qty: number }[] = [];
      if (line.expiry_date && (line.filled_quantity ?? 0) > 0) {
        packedExpiries.push({
          expiry: line.expiry_date,
          qty: line.filled_quantity!,
        });
      }
      for (const s of line.extraSlicePacked) {
        packedExpiries.push({ expiry: s.expiry, qty: s.qty });
      }
      for (const pe of packedExpiries) {
        const key = pe.expiry ?? "__null__";
        if (!existingExpiries.has(key)) {
          // Synthetic batch: WH stock = 0, unique placeholder ID for batchPickQtys
          line.singleBatches.push({
            wh_inventory_id: `packed-${line.dispatch_id}-${key}`,
            expiry: pe.expiry,
            stock: 0,
          });
          existingExpiries.add(key);
        }
      }
      // Re-sort by expiry ASC NULLS LAST
      line.singleBatches.sort((a, b) => {
        if (a.expiry === b.expiry) return 0;
        if (a.expiry === null) return 1;
        if (b.expiry === null) return -1;
        return a.expiry.localeCompare(b.expiry);
      });
    }

    setLines(mergedList);

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

    for (const line of mergedList) {
      if (line.variantStocks) {
        // Mix: distribute each variant's packQty across its own batches.
        // If already packed and a saved expiry_date exists, pin the fill to
        // the matching batch (same logic as single-variant below).
        for (const v of line.variantStocks) {
          if (line.action === "packed" && line.expiry_date) {
            const match = v.batches.find((b) => b.expiry === line.expiry_date);
            if (match) {
              if (!initBatchPickQtys[line.dispatch_id])
                initBatchPickQtys[line.dispatch_id] = {};
              for (const b of v.batches) {
                initBatchPickQtys[line.dispatch_id][b.wh_inventory_id] =
                  b === match ? v.packQty : 0;
              }
              continue;
            }
          }
          fillBatches(line.dispatch_id, v.batches, v.packQty);
        }
      } else if (line.singleBatches !== null) {
        // Single-variant: if already packed, pin saved quantities per expiry batch.
        // Handles merged lines: primary's filled_quantity + extraSlicePacked entries.
        if (
          line.action === "packed" &&
          (line.expiry_date || line.extraSlicePacked.length > 0)
        ) {
          if (!initBatchPickQtys[line.dispatch_id])
            initBatchPickQtys[line.dispatch_id] = {};
          // Build expiry→qty map from primary + extra slices
          const packedByExpiry = new Map<string, number>();
          if (
            line.expiry_date &&
            line.filled_quantity != null &&
            line.filled_quantity > 0
          ) {
            packedByExpiry.set(
              line.expiry_date ?? "__null__",
              line.filled_quantity,
            );
          }
          for (const slice of line.extraSlicePacked) {
            const key = slice.expiry ?? "__null__";
            packedByExpiry.set(key, (packedByExpiry.get(key) ?? 0) + slice.qty);
          }
          if (packedByExpiry.size > 0) {
            for (const b of line.singleBatches) {
              const bKey = b.expiry ?? "__null__";
              initBatchPickQtys[line.dispatch_id][b.wh_inventory_id] =
                packedByExpiry.get(bKey) ?? 0;
              // Clear after use so duplicate batches with same expiry don't double-count
              packedByExpiry.delete(bKey);
            }
            continue;
          }
        }
        // Unpacked or no matching batch — fall back to FIFO
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

  function updateSwapAction(
    addId: string,
    removeId: string | null,
    action: LineAction,
  ) {
    setLines((prev) =>
      prev.map((l) =>
        l.dispatch_id === addId ||
        (removeId !== null && l.dispatch_id === removeId)
          ? { ...l, action }
          : l,
      ),
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
    setWhWarnMsg("");
    const supabase = createClient();
    const warnings: string[] = [];

    for (const line of lines) {
      if (line.action === "packed") {
        // ── B3.1 RPC-only path ───────────────────────────────────────────
        // pack_dispatch_line does: WH→consumer reservation, parent qty
        // reconciliation (via OB-2 trigger on child INSERT), atomic audit.
        // NO legacy inline WH UPDATE or child INSERT exists below.
        const batchQtys = batchPickQtys[line.dispatch_id];
        const isMixLine = line.variantStocks !== null;

        // Fetch existing extra-slice state; preserve frozen (picked_up /
        // dispatched) rows — these must not be touched. Clear only rows
        // still in the packed-not-yet-picked-up phase so the RPC can
        // spawn fresh children via the OB-2 trigger.
        const frozenKeys = new Set<string>();
        const keyOf = (bpId: string | null, exp: string | null) =>
          `${bpId ?? ""}__${exp ?? ""}`;

        if (line.extraSliceIds.length > 0) {
          const { data: existingSlices, error: fetchErr } = await supabase
            .from("refill_dispatching")
            .select(
              "dispatch_id, boonz_product_id, expiry_date, picked_up, dispatched",
            )
            .in("dispatch_id", line.extraSliceIds);
          if (fetchErr) {
            console.error("[B3.1] fetch extra slices failed", fetchErr);
            warnings.push(
              `${line.pod_product_name}: failed to read existing slices — skipped`,
            );
            continue;
          }
          const deletableIds: string[] = [];
          for (const row of existingSlices ?? []) {
            if (row.picked_up === true || row.dispatched === true) {
              frozenKeys.add(keyOf(row.boonz_product_id, row.expiry_date));
            } else {
              deletableIds.push(row.dispatch_id);
            }
          }
          if (deletableIds.length > 0) {
            const { error: delErr } = await supabase
              .from("refill_dispatching")
              .delete()
              .in("dispatch_id", deletableIds);
            if (delErr) {
              console.error("[B3.1] delete stale slices failed", delErr);
              warnings.push(
                `${line.pod_product_name}: could not clear stale slices — skipped`,
              );
              continue;
            }
          }
        }

        // Re-pack of an already-packed parent is not supported by the RPC
        // (protect_packed_dispatch_row trigger blocks identity changes).
        // Surface a clear message instead of falling back to legacy.
        if (line.packed) {
          warnings.push(
            `${line.pod_product_name}: already packed — refresh to edit`,
          );
          continue;
        }

        // Build per-batch pick list. Every pick carries its own
        // boonz_product_id so mix lines (one parent → multiple variants)
        // pack atomically in one RPC call.
        interface Pick {
          wh_inventory_id: string;
          qty: number;
          boonz_product_id: string;
        }
        const picks: Pick[] = [];

        if (isMixLine && line.variantStocks) {
          for (const v of line.variantStocks) {
            for (const b of v.batches) {
              const qty = batchQtys?.[b.wh_inventory_id] ?? 0;
              if (qty <= 0) continue;
              if (frozenKeys.has(keyOf(v.boonzProductId, b.expiry))) continue;
              picks.push({
                wh_inventory_id: b.wh_inventory_id,
                qty,
                boonz_product_id: v.boonzProductId,
              });
            }
          }
        } else {
          for (const b of line.singleBatches ?? []) {
            const qty = batchQtys?.[b.wh_inventory_id] ?? 0;
            if (qty <= 0) continue;
            if (frozenKeys.has(keyOf(line.boonz_product_id, b.expiry)))
              continue;
            picks.push({
              wh_inventory_id: b.wh_inventory_id,
              qty,
              boonz_product_id: line.boonz_product_id,
            });
          }
        }

        // Zero picks: user intentionally packed 0 qty (e.g. shelf cleared,
        // product swapped out). Mark the dispatch line as packed with qty=0
        // so the shelf counts as done — no WH stock is deducted.
        if (picks.length === 0) {
          console.log(
            `[B3.1] ${line.pod_product_name}: packed with qty=0 — marking done`,
          );
          const { error: zeroErr } = await supabase
            .from("refill_dispatching")
            .update({ packed: true, filled_quantity: 0 })
            .eq("dispatch_id", line.dispatch_id);
          if (zeroErr) {
            console.error(
              `[B3.1] Zero-pack update failed for ${line.pod_product_name}:`,
              zeroErr.message,
            );
            warnings.push(`${line.pod_product_name}: ${zeroErr.message}`);
          }
          continue;
        }

        // Diagnostic telemetry — used to verify mix lines are taking the
        // RPC path (zero legacy fallback expected).
        const distinctBpids = new Set(picks.map((p) => p.boonz_product_id));
        console.log(
          `[B3.1] Packing ${line.pod_product_name} (dispatch ${line.dispatch_id}):`,
          {
            isMixLine,
            variantCount: distinctBpids.size,
            totalPickQty: picks.reduce((s, p) => s + p.qty, 0),
            plannedQty: line.recommended_qty,
            picksCount: picks.length,
          },
        );

        const { data: rpcData, error: rpcErr } = await supabase.rpc(
          "pack_dispatch_line",
          { p_dispatch_id: line.dispatch_id, p_picks: picks },
        );
        if (rpcErr) {
          console.error(
            `[B3.1] Pack RPC failed for ${line.pod_product_name}:`,
            rpcErr.message,
          );
          warnings.push(`${line.pod_product_name}: ${rpcErr.message}`);
          continue;
        }
        console.log(`[B3.1] Packed via RPC: ${line.pod_product_name}`, rpcData);
      } else if (line.action === "skip") {
        // If this line was already packed (WH was deducted), restore WH stock first.
        // SCENARIO B (admin sets include=false directly in DB) must be handled manually.
        const wasAlreadyPacked = line.packed && line.packed_qty > 0;
        if (wasAlreadyPacked && line.boonz_product_id) {
          try {
            await restoreWarehouseStock(
              supabase,
              line.boonz_product_id,
              line.expiry_date,
              line.packed_qty,
            );
          } catch (err) {
            console.error("[Pack] WH restore failed:", err);
          }
        }

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

    if (warnings.length > 0) {
      setWhWarnMsg(warnings.join(" · "));
    }

    // B3.1 Issue 8: re-fetch authoritative state after the save loop so
    // the UI reflects packed=true, filled_quantity, and any RPC-spawned
    // child rows — no optimistic caching.
    await fetchData();

    setSaving(false);
    setSaved(true);
    setEditingAfterSave(false);
  }

  async function handleUnskip(dispatchId: string) {
    const supabase = createClient();
    const { error } = await supabase
      .from("refill_dispatching")
      .update({ include: true })
      .eq("dispatch_id", dispatchId);
    if (error) {
      console.error("[B3.1] un-skip failed", error);
      setWhWarnMsg(`Un-skip failed: ${error.message}`);
      return;
    }
    await fetchData();
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

  // ── Group lines by action category ──────────────────────────────────────────
  // Separate returned items from active packing lines
  const returnedLines = lines.filter((l) => l.returned);
  const activeLines = lines.filter((l) => !l.returned);

  // Pair Add New ↔ Remove by position (engine generates matched pairs)
  const addNewLines = activeLines.filter((l) => l.dispatch_action === "Add New");
  const removeLines = activeLines.filter((l) => l.dispatch_action === "Remove");
  const refillLines = activeLines.filter(
    (l) => l.dispatch_action !== "Add New" && l.dispatch_action !== "Remove",
  );

  const swapPairs = addNewLines.map((addLine, i) => ({
    addLine,
    removeLine: removeLines[i] ?? null,
  }));
  // Removes without an Add New partner
  const standaloneRemoves = removeLines.slice(addNewLines.length);

  // IDs for quick lookup
  const swapAddIds = new Set(addNewLines.map((l) => l.dispatch_id));
  const swapRemoveIds = new Set(
    swapPairs
      .filter((p) => p.removeLine !== null)
      .map((p) => p.removeLine!.dispatch_id),
  );

  type ActionSection = {
    key: string;
    icon: string;
    title: string;
    lines: PackLine[];
  };

  const sections: ActionSection[] = [];

  // Section 1: Pack these items — Refill lines only (+ Add, misc non-swap/non-remove)
  if (refillLines.length > 0) {
    sections.push({
      key: "pack",
      icon: "📦",
      title: "Pack these items",
      lines: refillLines,
    });
  }

  // Section 2: Swaps — paired Add New + Remove
  if (swapPairs.length > 0) {
    sections.push({
      key: "swap",
      icon: "🔄",
      title: "Swaps",
      lines: swapPairs.flatMap((p) =>
        p.removeLine ? [p.removeLine, p.addLine] : [p.addLine],
      ),
    });
  }

  // Section 3: Standalone removes (no swap partner)
  if (standaloneRemoves.length > 0) {
    sections.push({
      key: "remove",
      icon: "❌",
      title: "Remove from machine",
      lines: standaloneRemoves,
    });
  }

  // Section 4: Previously returned items (read-only history)
  if (returnedLines.length > 0) {
    sections.push({
      key: "returned",
      icon: "↩",
      title: "Previously returned",
      lines: returnedLines,
    });
  }

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
      {whWarnMsg && (
        <div className="mb-4 rounded-xl bg-amber-50 px-4 py-3 text-sm text-amber-800 dark:bg-amber-950/30 dark:text-amber-300">
          ⚠ {whWarnMsg}
        </div>
      )}

      {sections.map((section) => (
        <div key={section.key} className="mb-6">
          <h2
            className={`mb-3 flex items-center gap-2 text-sm font-bold uppercase tracking-wide ${
              section.key === "remove"
                ? "text-red-600 dark:text-red-400"
                : section.key === "swap"
                  ? "text-blue-600 dark:text-blue-400"
                  : section.key === "returned"
                    ? "text-neutral-400 dark:text-neutral-500"
                    : "text-neutral-700 dark:text-neutral-300"
            }`}
          >
            <span className="text-base">{section.icon}</span> {section.title}
            <span className="ml-auto text-xs font-normal text-neutral-400">
              {section.key === "swap"
                ? `${swapPairs.length} pair${swapPairs.length !== 1 ? "s" : ""}`
                : `${section.lines.length} item${section.lines.length !== 1 ? "s" : ""}`}
            </span>
          </h2>
          <ul className="space-y-2">
            {/* ── SWAP SECTION: combined cards ── */}
            {section.key === "swap" &&
              swapPairs.map((pair, pairIdx) => {
                const addLine = pair.addLine;
                const removeLine = pair.removeLine;
                const bothPacked =
                  addLine.action === "packed" &&
                  (!removeLine || removeLine.action === "packed");
                const isMix = addLine.variantStocks !== null;

                // Committed stock for the Add line
                const addCommitted = !isMix
                  ? (committedByProduct.get(addLine.boonz_product_id) ?? 0)
                  : 0;
                const addAvailable = addLine.warehouse_stock - addCommitted;
                const totalBatchAvailable =
                  !isMix &&
                  addLine.singleBatches &&
                  addLine.singleBatches.length > 0
                    ? addLine.singleBatches.reduce((sum, b) => {
                        const bk = `${addLine.boonz_product_id}|||${b.expiry ?? "null"}`;
                        const bc = committedByBatch.get(bk) ?? 0;
                        return sum + Math.max(0, b.stock - bc);
                      }, 0)
                    : addAvailable;
                const fullyCommitted =
                  !isMix && addCommitted > 0 && totalBatchAvailable <= 0;

                return (
                  <li
                    key={`swap-${pairIdx}`}
                    className={`rounded-lg border border-blue-200 bg-white p-0 overflow-hidden dark:border-blue-900 dark:bg-neutral-950 ${
                      bothPacked
                        ? "border-l-4 border-l-green-400"
                        : "border-l-[3px] border-l-blue-400"
                    }`}
                  >
                    {/* Swap header */}
                    <div className="flex items-center gap-2 bg-blue-50 px-3 py-2 text-xs font-bold uppercase tracking-wide text-blue-700 dark:bg-blue-950/30 dark:text-blue-400">
                      <span className="text-sm">🔄</span> SWAP
                    </div>

                    {/* Remove sub-section */}
                    {removeLine && (
                      <div className="border-b border-blue-100 bg-red-50/60 px-3 py-2.5 dark:border-blue-900 dark:bg-red-950/20">
                        <p className="flex flex-wrap items-center gap-1.5 text-sm">
                          <span className="rounded bg-red-100 px-1.5 py-0.5 text-xs font-semibold text-red-700 dark:bg-red-900/40 dark:text-red-400">
                            ❌ REMOVE
                          </span>
                          <span className="rounded bg-red-100 px-1.5 py-0.5 text-xs font-mono text-red-400 dark:bg-red-900/40 dark:text-red-500">
                            {removeLine.shelf_code}
                          </span>
                          <span className="font-medium">
                            {removeLine.display_name}
                          </span>
                          <span className="text-xs text-red-500 dark:text-red-400">
                            · {removeLine.recommended_qty || "—"} units
                          </span>
                        </p>
                      </div>
                    )}

                    {/* Arrow separator */}
                    <div className="flex items-center gap-2 px-3 py-1.5 text-xs text-neutral-400 dark:text-neutral-500">
                      <span>↓</span> replace with
                    </div>

                    {/* Add sub-section */}
                    <div className="px-3 pb-3">
                      <p className="mb-1 flex flex-wrap items-center gap-1.5 text-sm">
                        <span className="rounded bg-green-100 px-1.5 py-0.5 text-xs font-semibold text-green-700 dark:bg-green-900/40 dark:text-green-400">
                          ✅ PACK
                        </span>
                        <span className="rounded bg-neutral-100 px-1.5 py-0.5 text-xs font-mono text-neutral-400 dark:bg-neutral-800 dark:text-neutral-500">
                          {addLine.shelf_code}
                        </span>
                        <span className="font-medium">
                          {addLine.display_name}
                        </span>
                        <span className="text-xs text-neutral-500 dark:text-neutral-400">
                          · {addLine.recommended_qty} units
                        </span>
                      </p>

                      {/* Batch/FIFO rows for Add line */}
                      {isMix ? (
                        <div className="mb-2">
                          {addLine.variantStocks!.every(
                            (v) => v.packQty === 0 && v.stock === 0,
                          ) ? (
                            <p className="text-xs font-medium text-amber-600 dark:text-amber-400">
                              ⚠ No warehouse stock
                            </p>
                          ) : (
                            <div className="space-y-2">
                              {addLine
                                .variantStocks!.filter(
                                  (v) => v.packQty > 0 || v.stock > 0,
                                )
                                .map((v) => {
                                  const vpTotal = v.batches.reduce(
                                    (sum, b) =>
                                      sum +
                                      (batchPickQtys[addLine.dispatch_id]?.[
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
                                        <div className="grid grid-cols-4 bg-neutral-50 px-3 py-1.5 text-xs font-medium text-neutral-500 dark:bg-neutral-900 dark:text-neutral-400">
                                          <span>Expiry</span>
                                          <span>In Stock</span>
                                          <span>Pick Qty</span>
                                          <span>Age</span>
                                        </div>
                                        {v.batches.map((b) => {
                                          const pickQty =
                                            batchPickQtys[
                                              addLine.dispatch_id
                                            ]?.[b.wh_inventory_id] ?? 0;
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
                                              <div className="flex flex-col leading-tight">
                                                <span
                                                  className={`font-mono text-xs ${urgencyColor}`}
                                                >
                                                  {b.expiry
                                                    ? formatExpiry(b.expiry)
                                                    : "—"}
                                                </span>
                                                <span
                                                  className="truncate text-[10px] text-neutral-500 dark:text-neutral-400"
                                                  title={v.name}
                                                >
                                                  {v.name}
                                                </span>
                                              </div>
                                              <span className="text-xs text-neutral-600 dark:text-neutral-400">
                                                {b.stock}u
                                              </span>
                                              <input
                                                type="number"
                                                min={0}
                                                max={batchAvailable}
                                                value={pickQty}
                                                disabled={
                                                  isReadOnly ||
                                                  batchAvailable === 0
                                                }
                                                onChange={(e) => {
                                                  const val = Math.min(
                                                    batchAvailable,
                                                    Math.max(
                                                      0,
                                                      parseInt(
                                                        e.target.value,
                                                      ) || 0,
                                                    ),
                                                  );
                                                  setBatchPickQtys((prev) => ({
                                                    ...prev,
                                                    [addLine.dispatch_id]: {
                                                      ...(prev[
                                                        addLine.dispatch_id
                                                      ] ?? {}),
                                                      [b.wh_inventory_id]: val,
                                                    },
                                                  }));
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
                                                {days !== null
                                                  ? `${days}d`
                                                  : "—"}
                                              </span>
                                            </div>
                                          );
                                        })}
                                        <div className="grid grid-cols-4 border-t border-neutral-200 bg-neutral-50 px-3 py-1.5 dark:border-neutral-800 dark:bg-neutral-900">
                                          <span className="col-span-2 text-xs text-neutral-500">
                                            Total picked
                                          </span>
                                          <span className="text-sm font-semibold text-neutral-800 dark:text-neutral-200">
                                            {vpTotal}
                                          </span>
                                          <span />
                                        </div>
                                      </div>
                                    </div>
                                  );
                                })}
                            </div>
                          )}
                        </div>
                      ) : !addLine.singleBatches ||
                        addLine.singleBatches.length === 0 ? (
                        addLine.warehouse_stock > 0 ? (
                          <p className="mb-2 inline-flex items-center gap-1 rounded bg-neutral-100 px-2 py-0.5 text-xs text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400">
                            {addLine.warehouse_stock} units available in
                            warehouse
                          </p>
                        ) : (
                          <p className="mb-2 inline-flex items-center gap-1 rounded bg-amber-50 px-2 py-0.5 text-xs text-amber-700 dark:bg-amber-900/30 dark:text-amber-300">
                            ⚠ No stock found in warehouse
                          </p>
                        )
                      ) : (
                        <div className="mb-2 w-full overflow-hidden rounded-lg border border-neutral-200 divide-y divide-neutral-100 dark:divide-neutral-800 dark:border-neutral-700">
                          <div className="grid grid-cols-4 bg-neutral-50 px-3 py-1.5 text-xs font-medium text-neutral-500 dark:bg-neutral-900 dark:text-neutral-400">
                            <span>Expiry</span>
                            <span>In Stock</span>
                            <span>Pick Qty</span>
                            <span>Age</span>
                          </div>
                          {addLine.singleBatches.map((b) => {
                            const pickQty =
                              batchPickQtys[addLine.dispatch_id]?.[
                                b.wh_inventory_id
                              ] ?? 0;
                            const batchKey = `${addLine.boonz_product_id}|||${b.expiry ?? "null"}`;
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
                                <div className="flex flex-col leading-tight">
                                  <span
                                    className={`font-mono text-xs ${urgencyColor}`}
                                  >
                                    {b.expiry ? formatExpiry(b.expiry) : "—"}
                                  </span>
                                  <span
                                    className="truncate text-[10px] text-neutral-500 dark:text-neutral-400"
                                    title={stripPodPrefix(
                                      addLine.boonz_display_name ??
                                        addLine.display_name,
                                      addLine.pod_product_name,
                                    )}
                                  >
                                    {stripPodPrefix(
                                      addLine.boonz_display_name ??
                                        addLine.display_name,
                                      addLine.pod_product_name,
                                    )}
                                  </span>
                                </div>
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
                                      [addLine.dispatch_id]: {
                                        ...(prev[addLine.dispatch_id] ?? {}),
                                        [b.wh_inventory_id]: val,
                                      },
                                    }));
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
                          <div className="grid grid-cols-4 border-t border-neutral-200 bg-neutral-50 px-3 py-1.5 dark:border-neutral-800 dark:bg-neutral-900">
                            <span className="col-span-2 text-xs text-neutral-500">
                              Total picked
                            </span>
                            <span className="text-sm font-semibold text-neutral-800 dark:text-neutral-200">
                              {variantTotal(addLine.dispatch_id)}
                            </span>
                            <span />
                          </div>
                        </div>
                      )}

                      {/* Confirm swap packed button */}
                      {!isReadOnly && (
                        <button
                          onClick={() => {
                            handlePackedClick(addLine);
                            updateSwapAction(
                              addLine.dispatch_id,
                              removeLine?.dispatch_id ?? null,
                              "packed",
                            );
                          }}
                          disabled={fullyCommitted}
                          className={`mt-2 w-full rounded-lg border py-2 text-xs font-semibold transition-colors disabled:cursor-not-allowed disabled:opacity-40 ${
                            bothPacked
                              ? "border-green-400 bg-green-50 text-green-700 dark:bg-green-950/40 dark:text-green-400"
                              : "border-blue-300 bg-[#1e3a5f] text-white hover:bg-[#172e4d] dark:border-blue-800"
                          }`}
                        >
                          {bothPacked
                            ? "✓ Swap confirmed"
                            : fullyCommitted
                              ? "✗ No stock"
                              : "✓ Confirm swap packed"}
                        </button>
                      )}
                      {isReadOnly && bothPacked && (
                        <p className="mt-2 text-xs font-medium text-green-600 dark:text-green-400">
                          ✓ Swap confirmed
                        </p>
                      )}
                    </div>
                  </li>
                );
              })}

            {/* ── PACK / REMOVE SECTIONS: individual cards ── */}
            {section.key !== "swap" &&
              section.lines.map((line) => {
                // ── Previously returned: read-only greyed card ────────────
                if (section.key === "returned") {
                  return (
                    <li
                      key={line.dispatch_id}
                      className="rounded-lg border border-neutral-200 bg-neutral-50 p-3 opacity-60 dark:border-neutral-800 dark:bg-neutral-900/50"
                    >
                      <p className="mb-0.5 flex flex-wrap items-center gap-1.5 text-sm font-medium text-neutral-400 dark:text-neutral-500">
                        <span className="rounded bg-neutral-200 px-1.5 py-0.5 text-xs font-mono text-neutral-400 dark:bg-neutral-800 dark:text-neutral-500">
                          {line.shelf_code}
                        </span>
                        {line.from_warehouse_name && (
                          <span className="rounded bg-blue-50 px-1.5 py-0.5 text-xs font-medium text-blue-400 dark:bg-blue-950/20 dark:text-blue-600">
                            📦 {line.from_warehouse_name}
                          </span>
                        )}
                        <span className="rounded bg-orange-100 px-1.5 py-0.5 text-xs font-semibold text-orange-600 dark:bg-orange-950/30 dark:text-orange-400">
                          ↩ RETURNED
                        </span>
                        {line.display_name}
                      </p>
                      {line.return_reason && (
                        <p className="mt-1 text-xs italic text-neutral-400 dark:text-neutral-500">
                          Reason: {line.return_reason}
                        </p>
                      )}
                      {line.dispatch_comment && (
                        <p className="mt-0.5 text-xs italic text-neutral-400 dark:text-neutral-500">
                          💬 {line.dispatch_comment}
                        </p>
                      )}
                      <p className="mt-1 text-xs text-neutral-400 dark:text-neutral-500">
                        {line.recommended_qty} units · not packed this run
                      </p>
                    </li>
                  );
                }

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

                const borderClass = isRemove
                  ? "border-l-[3px] border-l-red-300"
                  : line.action === "packed"
                    ? "border-l-4 border-l-green-400"
                    : line.action === "skip"
                      ? "border-l-4 border-l-neutral-300 opacity-60"
                      : "";

                // ── REMOVE CARD — completely different layout ──────────────
                if (isRemove) {
                  return (
                    <li
                      key={line.dispatch_id}
                      className={`rounded-lg border border-red-200 bg-red-50 p-3 dark:border-red-900 dark:bg-red-950/30 ${borderClass}`}
                    >
                      <p className="mb-0.5 flex flex-wrap items-center gap-1.5 text-sm font-medium">
                        <span className="rounded bg-red-100 px-1.5 py-0.5 text-xs font-mono text-red-400 dark:bg-red-900/40 dark:text-red-500">
                          {line.shelf_code}
                        </span>
                        {line.display_name}
                        {swapRemoveIds.has(line.dispatch_id) ? (
                          <span className="rounded bg-red-100 px-1.5 py-0.5 text-xs font-semibold text-red-700 dark:bg-red-900/30 dark:text-red-400">
                            SWAP OUT
                          </span>
                        ) : (
                          <span className="rounded bg-red-200 px-1.5 py-0.5 text-xs font-semibold uppercase tracking-wide text-red-700 dark:bg-red-900/40 dark:text-red-400">
                            REMOVE FROM MACHINE
                          </span>
                        )}
                      </p>
                      <p className="mb-2 text-xs text-red-500 dark:text-red-400">
                        Take these out of the machine on arrival
                      </p>
                      {line.dispatch_comment && (
                        <p className="mb-2 text-xs italic text-red-400 dark:text-red-500">
                          💬 {line.dispatch_comment}
                        </p>
                      )}
                      {!isReadOnly && (
                        <button
                          onClick={() =>
                            updateAction(line.dispatch_id, "packed")
                          }
                          className={`w-full rounded-lg border py-1.5 text-xs font-semibold transition-colors ${
                            line.action === "packed"
                              ? "border-green-400 bg-green-50 text-green-700 dark:bg-green-950/40 dark:text-green-400"
                              : "border-red-300 text-red-600 hover:bg-red-100 dark:border-red-800 dark:hover:bg-red-900/40"
                          }`}
                        >
                          {line.action === "packed"
                            ? "✓ Confirmed removed"
                            : "✓ Confirm removed"}
                        </button>
                      )}
                      {isReadOnly && line.action === "packed" && (
                        <p className="text-xs font-medium text-green-600 dark:text-green-400">
                          ✓ Confirmed removed
                        </p>
                      )}
                    </li>
                  );
                }

                return (
                  <li
                    key={line.dispatch_id}
                    className={`rounded-lg border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950 ${borderClass}`}
                  >
                    {/* Primary label */}
                    <p className="mb-0.5 flex flex-wrap items-center gap-1.5 text-sm font-medium">
                      <span className="rounded bg-neutral-100 px-1.5 py-0.5 text-xs font-mono text-neutral-400 dark:bg-neutral-800 dark:text-neutral-500">
                        {line.shelf_code}
                      </span>
                      {/* Warehouse source badge */}
                      {line.from_warehouse_name && (
                        <span className="rounded bg-blue-50 px-1.5 py-0.5 text-xs font-medium text-blue-600 dark:bg-blue-950/40 dark:text-blue-400">
                          📦 {line.from_warehouse_name}
                        </span>
                      )}
                      {line.display_name}
                      {line.dispatch_action === "Add New" && (
                        <span className="rounded bg-blue-100 px-1.5 py-0.5 text-xs font-semibold text-blue-700 dark:bg-blue-900/30 dark:text-blue-400">
                          NEW
                        </span>
                      )}
                      {swapAddIds.has(line.dispatch_id) && (
                        <span className="rounded bg-blue-100 px-1.5 py-0.5 text-xs font-semibold text-blue-700 dark:bg-blue-900/30 dark:text-blue-400">
                          SWAP IN
                        </span>
                      )}
                      {/* Expiry warning: check engine flag first, then date-based fallback */}
                      {line.expiry_warning === "expired" ? (
                        <span className="rounded px-1 py-0.5 text-xs font-semibold bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400">
                          ⚠ EXPIRED
                        </span>
                      ) : line.expiry_warning === "expiring_soon" ? (
                        <span className="rounded px-1 py-0.5 text-xs font-semibold bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400">
                          ⚠ Expires soon
                        </span>
                      ) : (
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
                          const todayD = new Date();
                          todayD.setHours(0, 0, 0, 0);
                          const exp = new Date(expiry + "T00:00:00");
                          const soon = new Date(todayD);
                          soon.setDate(soon.getDate() + 30);
                          if (exp < todayD) {
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
                        })()
                      )}
                    </p>
                    <p className="mb-1 text-xs text-neutral-400">
                      Recommended: {line.recommended_qty} units
                    </p>
                    {line.dispatch_comment && (
                      <p className="mb-2 text-xs italic text-neutral-500 dark:text-neutral-400">
                        💬 {line.dispatch_comment}
                      </p>
                    )}

                    {/* Stock / FIFO / Mix breakdown ────────────────────────── */}
                    {isMix ? (
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
                                            <div className="flex flex-col leading-tight">
                                              <span
                                                className={`font-mono text-xs ${urgencyColor}`}
                                              >
                                                {b.expiry
                                                  ? formatExpiry(b.expiry)
                                                  : "—"}
                                              </span>
                                              <span
                                                className="truncate text-[10px] text-neutral-500 dark:text-neutral-400"
                                                title={v.name}
                                              >
                                                {v.name}
                                              </span>
                                            </div>
                                            <span className="text-xs text-neutral-600 dark:text-neutral-400">
                                              {b.stock}u
                                            </span>
                                            <input
                                              type="number"
                                              min={0}
                                              max={batchAvailable}
                                              value={pickQty}
                                              disabled={
                                                isReadOnly ||
                                                batchAvailable === 0
                                              }
                                              onChange={(e) => {
                                                const val = Math.min(
                                                  batchAvailable,
                                                  Math.max(
                                                    0,
                                                    parseInt(e.target.value) ||
                                                      0,
                                                  ),
                                                );
                                                setBatchPickQtys((prev) => ({
                                                  ...prev,
                                                  [line.dispatch_id]: {
                                                    ...(prev[
                                                      line.dispatch_id
                                                    ] ?? {}),
                                                    [b.wh_inventory_id]: val,
                                                  },
                                                }));
                                                setZeroQtyWarnings((prev) => {
                                                  if (
                                                    !prev.has(line.dispatch_id)
                                                  )
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
                                      {/* B3.1 Issue 7: per-batch availability.
                                          Summed across batches — stays positive
                                          if any single batch is pickable. */}
                                      {(() => {
                                        const vCommitted = v.batches.reduce(
                                          (s, b) =>
                                            s +
                                            (committedByBatch.get(
                                              `${v.boonzProductId}|||${b.expiry ?? "null"}`,
                                            ) ?? 0),
                                          0,
                                        );
                                        const vAvail = v.batches.reduce(
                                          (s, b) =>
                                            s +
                                            Math.max(
                                              0,
                                              b.stock -
                                                (committedByBatch.get(
                                                  `${v.boonzProductId}|||${b.expiry ?? "null"}`,
                                                ) ?? 0),
                                            ),
                                          0,
                                        );
                                        if (vCommitted === 0) return null;
                                        return (
                                          <div className="border-t border-neutral-100 px-3 py-2 text-xs dark:border-neutral-800">
                                            <span className="text-neutral-500">
                                              WH: {v.stock}u
                                            </span>
                                            {" | "}
                                            <span className="text-amber-600 dark:text-amber-400">
                                              Committed: {vCommitted}
                                            </span>
                                            {" | "}
                                            <span
                                              className={
                                                vAvail > 0
                                                  ? "text-green-700 dark:text-green-400"
                                                  : "text-red-600 dark:text-red-400"
                                              }
                                            >
                                              Avail: {vAvail}
                                            </span>
                                            {vAvail <= 0 && (
                                              <p className="mt-1 font-medium text-red-600 dark:text-red-400">
                                                ✗ All batches fully committed
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
                        {line.boonz_display_name &&
                          line.boonz_display_name !== line.display_name && (
                            <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-neutral-700 dark:text-neutral-300">
                              {line.boonz_display_name}
                            </div>
                          )}
                        {/* Packed summary — shows what was packed before editing */}
                        {line.packed && !line.action && (
                          <div className="mb-2 rounded bg-green-50 px-2.5 py-1.5 text-xs text-green-700 dark:bg-green-950/30 dark:text-green-400">
                            <p>
                              Packed: {line.filled_quantity ?? 0} unit
                              {line.filled_quantity !== 1 ? "s" : ""}
                              {line.expiry_date
                                ? ` · ${formatExpiry(line.expiry_date)}`
                                : " · No expiry"}
                            </p>
                            {line.extraSlicePacked.map((slice, i) => (
                              <p key={i}>
                                Packed: {slice.qty} unit
                                {slice.qty !== 1 ? "s" : ""}
                                {slice.expiry
                                  ? ` · ${formatExpiry(slice.expiry)}`
                                  : " · No expiry"}
                              </p>
                            ))}
                          </div>
                        )}
                        {!line.singleBatches ||
                        line.singleBatches.length === 0 ? (
                          line.warehouse_stock > 0 ? (
                            <p className="inline-flex items-center gap-1 rounded bg-neutral-100 px-2 py-0.5 text-xs text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400">
                              {line.warehouse_stock} units available in
                              warehouse
                            </p>
                          ) : line.packed && (line.filled_quantity ?? 0) > 0 ? (
                            /* WH stock is 0 but line was packed — show packed-only batch rows for editing */
                            <p className="inline-flex items-center gap-1 rounded bg-neutral-100 px-2 py-0.5 text-xs text-neutral-500 dark:bg-neutral-800 dark:text-neutral-400">
                              WH stock depleted — packed qty shown above
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
                                  <div className="flex flex-col leading-tight">
                                    <span
                                      className={`font-mono text-xs ${urgencyColor}`}
                                    >
                                      {b.expiry ? formatExpiry(b.expiry) : "—"}
                                    </span>
                                    <span
                                      className="truncate text-[10px] text-neutral-500 dark:text-neutral-400"
                                      title={stripPodPrefix(
                                        line.boonz_display_name ??
                                          line.display_name,
                                        line.pod_product_name,
                                      )}
                                    >
                                      {stripPodPrefix(
                                        line.boonz_display_name ??
                                          line.display_name,
                                        line.pod_product_name,
                                      )}
                                    </span>
                                  </div>
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
                            {/* B3.1 Issue 7: per-batch availability sum.
                                totalBatchAvailable clamps negatives per row,
                                so one fully-committed batch can't block the
                                others from being picked. */}
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
                                    totalBatchAvailable > 0
                                      ? "text-green-700 dark:text-green-400"
                                      : "text-red-600 dark:text-red-400"
                                  }
                                >
                                  Available: {totalBatchAvailable}
                                </span>
                                {totalBatchAvailable <= 0 && (
                                  <p className="mt-1 font-medium text-red-600 dark:text-red-400">
                                    ✗ All batches fully committed — no stock
                                    pickable for this machine
                                  </p>
                                )}
                                {totalBatchAvailable > 0 &&
                                  totalBatchAvailable <
                                    line.recommended_qty && (
                                    <p className="mt-1 text-red-600 dark:text-red-400">
                                      ⚠ Only {totalBatchAvailable} available —{" "}
                                      {lineCommitted} committed to other
                                      machines
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

      {/* B3.1 Issue 6: skipped items recovery */}
      {skippedLines.length > 0 && (
        <div className="mb-6">
          <h2 className="mb-3 flex items-center gap-2 text-sm font-bold uppercase tracking-wide text-neutral-500 dark:text-neutral-400">
            <span className="text-base">⏭</span> Skipped items
            <span className="ml-auto text-xs font-normal text-neutral-400">
              {skippedLines.length} item
              {skippedLines.length !== 1 ? "s" : ""}
            </span>
          </h2>
          <ul className="space-y-1">
            {skippedLines.map((s) => (
              <li
                key={s.dispatch_id}
                className="flex items-center justify-between rounded-lg border border-neutral-200 bg-neutral-50 px-3 py-2 text-sm dark:border-neutral-800 dark:bg-neutral-900"
              >
                <span className="flex items-center gap-2 min-w-0">
                  <span className="rounded bg-neutral-200 px-1.5 py-0.5 text-xs font-mono text-neutral-500 dark:bg-neutral-800 dark:text-neutral-400">
                    {s.shelf_code}
                  </span>
                  <span className="truncate text-neutral-600 dark:text-neutral-400">
                    {s.display_name}
                  </span>
                  <span className="shrink-0 text-xs text-neutral-400">
                    — {s.quantity}u
                  </span>
                </span>
                <button
                  onClick={() => handleUnskip(s.dispatch_id)}
                  className="shrink-0 text-xs font-medium text-blue-600 hover:text-blue-800 dark:text-blue-400 dark:hover:text-blue-300"
                >
                  ↩ Un-skip
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}

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
