"use client";

import { useState, useEffect, useCallback, useMemo } from "react";
import { createClient } from "@/lib/supabase/client";

// ── Constants ─────────────────────────────────────────────────────────────────

const WH_CENTRAL_ID = "4bebef68-9e36-4a5c-9c2c-142f8dbdae85";

// ── Types ─────────────────────────────────────────────────────────────────────

/** One aggregated line in the Leg 1 staging-transfer summary */
type Leg1Item = {
  staging_warehouse_name: string; // e.g. "WH_MM" or "WH_MCC"
  boonz_product_name: string;
  pod_product_name: string;
  total_qty: number;
  machines: string[]; // which machines need this product from staging
};

type RefillPlanRow = {
  id: string;
  plan_date: string;
  machine_name: string;
  machine_priority: number;
  shelf_code: string;
  pod_product_name: string;
  boonz_product_name: string;
  action: string;
  quantity: number;
  current_stock: number;
  max_stock: number;
  smart_target: number | null;
  tier: string | null;
  global_score: number | null;
  sold_7d: number | null;
  fill_pct: number | null;
  comment: string | null;
  operator_status: string;
  operator_comment: string | null;
};

type RefillPlanGroup = {
  machine_name: string;
  machine_priority: number;
  rows: RefillPlanRow[];
  total_units: number;
  refill_count: number;
  add_count: number;
  remove_count: number;
};

// ── Component ─────────────────────────────────────────────────────────────────

export function RefillPlanReview({ selectedDate }: { selectedDate?: string }) {
  const [planRows, setPlanRows] = useState<RefillPlanRow[]>([]);
  const [planDate, setPlanDate] = useState<string | null>(null);
  const [planExpanded, setPlanExpanded] = useState<string | null>(null);
  const [planComments, setPlanComments] = useState<Record<string, string>>({});
  const [planProcessing, setPlanProcessing] = useState<Set<string>>(new Set());
  const [planCollapsed, setPlanCollapsed] = useState(false);
  const [planToast, setPlanToast] = useState<string | null>(null);
  /** boonz_product_name → total Active warehouse stock across all warehouses */
  const [warehouseStockMap, setWarehouseStockMap] = useState<
    Map<string, number>
  >(new Map());
  /** Leg 1 staging-transfer requirements (WH_CENTRAL → WH_MM / WH_MCC) */
  const [leg1Items, setLeg1Items] = useState<Leg1Item[]>([]);

  const loadPlan = useCallback(async () => {
    const supabase = createClient();
    let query = supabase
      .from("refill_plan_output")
      .select("*")
      .eq("operator_status", "pending")
      .order("machine_priority", { ascending: true })
      .order("shelf_code", { ascending: true })
      .limit(10000);
    if (selectedDate) {
      query = query.eq("plan_date", selectedDate);
    }
    const { data } = await query;
    if (data && data.length > 0) {
      setPlanRows(data as RefillPlanRow[]);
      setPlanDate((data[0] as RefillPlanRow).plan_date);

      // Batch-fetch total Active warehouse stock for all products in the plan
      // so the operator can see zero-stock blockers before approving.
      const names = [
        ...new Set(
          (data as RefillPlanRow[])
            .filter((r) => r.action !== "Remove")
            .map((r) => r.boonz_product_name)
            .filter(Boolean),
        ),
      ];
      if (names.length > 0) {
        const { data: stockRows } = await supabase
          .from("warehouse_inventory")
          .select(
            "boonz_product_id, warehouse_stock, boonz_products(boonz_product_name)",
          )
          .eq("status", "Active")
          .limit(5000);
        const stockMap = new Map<string, number>();
        for (const row of stockRows ?? []) {
          const name = (
            row.boonz_products as unknown as {
              boonz_product_name: string;
            } | null
          )?.boonz_product_name;
          if (!name) continue;
          stockMap.set(
            name,
            (stockMap.get(name) ?? 0) + Number(row.warehouse_stock ?? 0),
          );
        }
        setWarehouseStockMap(stockMap);
      }

      // ── Leg 1: staging-transfer requirements ─────────────────────────────
      // For machines whose primary warehouse is NOT WH_CENTRAL (i.e. staging
      // warehouses like WH_MM / WH_MCC), aggregate plan lines so the warehouse
      // manager knows what to move from WH_CENTRAL before the driver arrives.
      const machineNames = [
        ...new Set((data as RefillPlanRow[]).map((r) => r.machine_name)),
      ];
      const { data: machineRows } = await supabase
        .from("machines")
        .select("official_name, primary_warehouse_id, warehouses(name)")
        .in("official_name", machineNames)
        .neq("primary_warehouse_id", WH_CENTRAL_ID);

      const stagingMachineMap = new Map<string, string>(); // machine_name → staging WH name
      for (const m of machineRows ?? []) {
        const whName = (m.warehouses as unknown as { name: string } | null)
          ?.name;
        if (whName) stagingMachineMap.set(m.official_name as string, whName);
      }

      const leg1Map = new Map<string, Leg1Item>(); // key: "WH_MCC|boonz_product_name"
      for (const row of data as RefillPlanRow[]) {
        if (row.action === "Remove") continue;
        const whName = stagingMachineMap.get(row.machine_name);
        if (!whName) continue;
        const key = `${whName}|${row.boonz_product_name}`;
        if (!leg1Map.has(key)) {
          leg1Map.set(key, {
            staging_warehouse_name: whName,
            boonz_product_name: row.boonz_product_name,
            pod_product_name: row.pod_product_name,
            total_qty: 0,
            machines: [],
          });
        }
        const item = leg1Map.get(key)!;
        item.total_qty += row.quantity ?? 0;
        if (!item.machines.includes(row.machine_name)) {
          item.machines.push(row.machine_name);
        }
      }
      setLeg1Items(
        Array.from(leg1Map.values()).sort(
          (a, b) =>
            a.staging_warehouse_name.localeCompare(b.staging_warehouse_name) ||
            a.boonz_product_name.localeCompare(b.boonz_product_name),
        ),
      );
    } else {
      setPlanRows([]);
      setPlanDate(null);
      setWarehouseStockMap(new Map());
      setLeg1Items([]);
    }
  }, [selectedDate]);

  useEffect(() => {
    loadPlan();
  }, [loadPlan]);

  const planGroups = useMemo((): RefillPlanGroup[] => {
    const map = new Map<string, RefillPlanRow[]>();
    for (const row of planRows) {
      if (!map.has(row.machine_name)) map.set(row.machine_name, []);
      map.get(row.machine_name)!.push(row);
    }
    return Array.from(map.entries()).map(([machine_name, rows]) => ({
      machine_name,
      machine_priority: rows[0].machine_priority,
      rows,
      total_units: rows.reduce((s, r) => s + (r.quantity ?? 0), 0),
      refill_count: rows.filter((r) => r.action === "Refill").length,
      add_count: rows.filter((r) => r.action === "Add New").length,
      remove_count: rows.filter((r) => r.action === "Remove").length,
    }));
  }, [planRows]);

  /** Returns true if this plan row is a zero-warehouse-stock blocker */
  function isZeroStockBlocker(row: RefillPlanRow): boolean {
    if (row.action === "Remove") return false;
    if (!row.boonz_product_name) return false;
    const stock = warehouseStockMap.get(row.boonz_product_name);
    // Only flag when the map is loaded AND stock is confirmed zero (not just missing)
    return warehouseStockMap.size > 0 && stock === 0;
  }

  async function handlePlanMachine(
    machineName: string,
    status: "approved" | "rejected",
  ) {
    setPlanProcessing((prev) => new Set([...prev, machineName]));
    const supabase = createClient();
    const comment = planComments[machineName] ?? "";
    await supabase
      .from("refill_plan_output")
      .update({
        operator_status: status,
        reviewed_at: new Date().toISOString(),
        operator_comment: comment || null,
      })
      .eq("machine_name", machineName)
      .eq("operator_status", "pending");

    if (status === "approved" && planDate) {
      const { data: dispatched } = await supabase.rpc("push_plan_to_dispatch", {
        p_plan_date: planDate,
        p_machine_name: machineName,
      });
      const count = typeof dispatched === "number" ? dispatched : 0;
      setPlanToast(
        `✅ ${count} line${count !== 1 ? "s" : ""} pushed to dispatch`,
      );
      setTimeout(() => setPlanToast(null), 3000);
    }

    setPlanRows((prev) => prev.filter((r) => r.machine_name !== machineName));
    setPlanProcessing((prev) => {
      const s = new Set(prev);
      s.delete(machineName);
      return s;
    });
    setPlanExpanded((prev) => (prev === machineName ? null : prev));
  }

  async function handlePlanRejectLine(id: string) {
    const supabase = createClient();
    await supabase
      .from("refill_plan_output")
      .update({
        operator_status: "rejected",
        reviewed_at: new Date().toISOString(),
      })
      .eq("id", id);
    setPlanRows((prev) => prev.filter((r) => r.id !== id));
  }

  async function handlePlanApproveAll() {
    const machines = [...new Set(planRows.map((r) => r.machine_name))];
    for (const m of machines) {
      await handlePlanMachine(m, "approved");
    }
  }

  // ── Leg 1 rendering helpers ────────────────────────────────────────────────
  // NOTE: this useMemo MUST stay above the early-return so the hook is always
  // called in the same order regardless of planRows length (Rules of Hooks).

  /** Group leg1Items by staging warehouse name */
  const leg1ByWarehouse = useMemo(() => {
    const map = new Map<string, Leg1Item[]>();
    for (const item of leg1Items) {
      if (!map.has(item.staging_warehouse_name))
        map.set(item.staging_warehouse_name, []);
      map.get(item.staging_warehouse_name)!.push(item);
    }
    return Array.from(map.entries()).sort((a, b) => a[0].localeCompare(b[0]));
  }, [leg1Items]);

  if (planRows.length === 0) return null;

  return (
    <>
      {/* Toast — floats above everything */}
      {planToast && (
        <div className="fixed top-4 left-1/2 -translate-x-1/2 z-50 bg-green-700 text-white text-sm font-medium px-4 py-2 rounded-lg shadow-lg">
          {planToast}
        </div>
      )}

      <div className="bg-white rounded-xl shadow-sm border border-gray-100 p-6 mb-6">
        {/* Card label */}
        <p className="text-xs font-semibold tracking-wider text-gray-500 uppercase mb-4">
          📋 Refill Plan
        </p>

        {/* Section header */}
        <div className="flex items-center justify-between mb-3">
          <button
            onClick={() => setPlanCollapsed((c) => !c)}
            className="flex items-center gap-2 text-left"
          >
            <h2 className="text-base font-semibold text-gray-900">
              📋 Refill Plan —{" "}
              {planDate
                ? new Date(planDate + "T00:00:00").toLocaleDateString("en-AE", {
                    day: "numeric",
                    month: "long",
                    year: "numeric",
                  })
                : ""}
            </h2>
            <span className="text-xs text-gray-400">
              {planCollapsed ? "▼" : "▲"}
            </span>
          </button>
          {!planCollapsed && (
            <div className="flex items-center gap-3">
              <span className="text-xs text-gray-500">
                {planGroups.length} machine
                {planGroups.length !== 1 ? "s" : ""} ·{" "}
                {planRows.reduce((s, r) => s + (r.quantity ?? 0), 0)} units
              </span>
              <button
                onClick={handlePlanApproveAll}
                className="px-3 py-1.5 rounded-lg bg-green-600 text-white text-xs font-medium hover:bg-green-700 transition-colors"
              >
                Approve All Machines
              </button>
            </div>
          )}
        </div>

        {!planCollapsed && (
          <div className="space-y-3">
            {planGroups.map((group) => {
              const isExpanded = planExpanded === group.machine_name;
              const isProcessing = planProcessing.has(group.machine_name);
              const blockerCount = group.rows.filter(isZeroStockBlocker).length;
              return (
                <div
                  key={group.machine_name}
                  className={`bg-white border rounded-lg overflow-hidden ${blockerCount > 0 ? "border-red-300" : "border-gray-200"}`}
                >
                  {/* Machine card header */}
                  <button
                    onClick={() =>
                      setPlanExpanded((prev) =>
                        prev === group.machine_name ? null : group.machine_name,
                      )
                    }
                    className="w-full flex items-center justify-between px-4 py-3 text-left hover:bg-gray-50 transition-colors"
                  >
                    <div className="flex items-center gap-3 min-w-0">
                      <span className="font-medium text-sm text-gray-900 truncate">
                        {group.machine_name}
                      </span>
                      <span className="text-xs text-gray-400 shrink-0">
                        {group.rows.length} lines · {group.total_units} units
                      </span>
                      <div className="flex gap-1.5 shrink-0">
                        {group.refill_count > 0 && (
                          <span className="text-[10px] px-1.5 py-0.5 rounded bg-green-100 text-green-800 font-medium">
                            {group.refill_count} Refill
                          </span>
                        )}
                        {group.add_count > 0 && (
                          <span className="text-[10px] px-1.5 py-0.5 rounded bg-blue-100 text-blue-800 font-medium">
                            {group.add_count} Add
                          </span>
                        )}
                        {group.remove_count > 0 && (
                          <span className="text-[10px] px-1.5 py-0.5 rounded bg-red-100 text-red-800 font-medium">
                            {group.remove_count} Remove
                          </span>
                        )}
                        {blockerCount > 0 && (
                          <span className="text-[10px] px-1.5 py-0.5 rounded bg-red-200 text-red-800 font-semibold">
                            ⛔ {blockerCount} no stock
                          </span>
                        )}
                      </div>
                    </div>
                    <span className="text-xs text-gray-400 shrink-0 ml-2">
                      {isExpanded ? "▲" : "▼"}
                    </span>
                  </button>

                  {/* Expanded content */}
                  {isExpanded && (
                    <div className="border-t border-gray-100">
                      {/* Line table */}
                      <div className="overflow-x-auto">
                        <table className="w-full text-xs">
                          <thead>
                            <tr className="bg-gray-50 text-gray-500 uppercase tracking-wide text-[10px]">
                              <th className="px-3 py-2 text-left font-medium">
                                Shelf
                              </th>
                              <th className="px-3 py-2 text-left font-medium">
                                Pod Product
                              </th>
                              <th className="px-3 py-2 text-left font-medium">
                                Boonz Product
                              </th>
                              <th className="px-3 py-2 text-left font-medium">
                                Action
                              </th>
                              <th className="px-3 py-2 text-right font-medium">
                                Qty
                              </th>
                              <th className="px-3 py-2 text-right font-medium">
                                Stock
                              </th>
                              <th className="px-3 py-2 text-center font-medium">
                                Tier
                              </th>
                              <th className="px-3 py-2 text-left font-medium">
                                Comment
                              </th>
                              <th className="px-3 py-2" />
                            </tr>
                          </thead>
                          <tbody className="divide-y divide-gray-50">
                            {group.rows.map((row) => {
                              const actionClass =
                                row.action === "Refill"
                                  ? "bg-green-100 text-green-800"
                                  : row.action === "Add New"
                                    ? "bg-blue-100 text-blue-800"
                                    : row.action === "Remove"
                                      ? "bg-red-100 text-red-800"
                                      : "bg-gray-100 text-gray-700";
                              const tierEmoji =
                                row.tier === "HERO"
                                  ? "🔥"
                                  : row.tier === "GOOD"
                                    ? "✅"
                                    : row.tier === "CORE"
                                      ? "📦"
                                      : row.tier === "DRAG"
                                        ? "🔻"
                                        : "—";
                              const tierClass =
                                row.tier === "HERO"
                                  ? "bg-orange-100 text-orange-800"
                                  : row.tier === "GOOD"
                                    ? "bg-emerald-100 text-emerald-800"
                                    : row.tier === "CORE"
                                      ? "bg-gray-100 text-gray-800"
                                      : row.tier === "DRAG"
                                        ? "bg-red-100 text-red-800"
                                        : "";
                              const hasWarning = row.comment?.includes("⚠️");
                              const isBlocker = isZeroStockBlocker(row);
                              return (
                                <tr
                                  key={row.id}
                                  className={
                                    isBlocker
                                      ? "bg-red-50 border-l-4 border-red-500"
                                      : hasWarning
                                        ? "bg-yellow-50 border-l-4 border-yellow-400"
                                        : "hover:bg-gray-50"
                                  }
                                >
                                  <td className="px-3 py-2 font-mono text-gray-500">
                                    {row.shelf_code}
                                  </td>
                                  <td className="px-3 py-2 text-gray-700 max-w-[140px] truncate">
                                    {row.pod_product_name}
                                  </td>
                                  <td className="px-3 py-2 text-gray-500 max-w-[140px] truncate">
                                    {row.boonz_product_name}
                                  </td>
                                  <td className="px-3 py-2">
                                    <span
                                      className={`px-1.5 py-0.5 rounded text-[10px] font-medium ${actionClass}`}
                                    >
                                      {row.action}
                                    </span>
                                  </td>
                                  <td className="px-3 py-2 text-right font-medium text-gray-900">
                                    {row.quantity}
                                  </td>
                                  <td className="px-3 py-2 text-right text-gray-500">
                                    {row.current_stock}/{row.max_stock}
                                  </td>
                                  <td className="px-3 py-2 text-center">
                                    {row.tier ? (
                                      <span
                                        className={`px-1 py-0.5 rounded text-[10px] font-medium ${tierClass}`}
                                      >
                                        {tierEmoji} {row.tier}
                                      </span>
                                    ) : (
                                      <span className="text-gray-300">—</span>
                                    )}
                                  </td>
                                  <td className="px-3 py-2 max-w-[180px]">
                                    {isBlocker && (
                                      <span className="mr-1 inline-flex items-center rounded bg-red-100 px-1.5 py-0.5 text-[10px] font-semibold text-red-700">
                                        ⛔ 0 stock
                                      </span>
                                    )}
                                    <span className="truncate text-gray-500 text-xs">
                                      {row.comment ?? ""}
                                    </span>
                                  </td>
                                  <td className="px-2 py-2 text-right">
                                    <button
                                      onClick={() =>
                                        handlePlanRejectLine(row.id)
                                      }
                                      title="Reject this line"
                                      className="text-gray-300 hover:text-red-500 transition-colors text-xs"
                                    >
                                      ❌
                                    </button>
                                  </td>
                                </tr>
                              );
                            })}
                          </tbody>
                        </table>
                      </div>

                      {/* Machine approve/reject controls */}
                      <div className="flex items-center gap-3 px-4 py-3 bg-gray-50 border-t border-gray-100">
                        <input
                          type="text"
                          value={planComments[group.machine_name] ?? ""}
                          onChange={(e) =>
                            setPlanComments((prev) => ({
                              ...prev,
                              [group.machine_name]: e.target.value,
                            }))
                          }
                          placeholder="Add comment (optional)…"
                          className="flex-1 min-w-0 text-xs rounded border border-gray-300 px-2 py-1.5 placeholder:text-gray-400"
                        />
                        <button
                          onClick={() =>
                            handlePlanMachine(group.machine_name, "approved")
                          }
                          disabled={isProcessing}
                          className="shrink-0 px-3 py-1.5 rounded bg-green-600 text-white text-xs font-medium hover:bg-green-700 disabled:opacity-50 transition-colors"
                        >
                          {isProcessing ? "…" : "✅ Approve All"}
                        </button>
                        <button
                          onClick={() =>
                            handlePlanMachine(group.machine_name, "rejected")
                          }
                          disabled={isProcessing}
                          className="shrink-0 px-3 py-1.5 rounded bg-red-600 text-white text-xs font-medium hover:bg-red-700 disabled:opacity-50 transition-colors"
                        >
                          {isProcessing ? "…" : "❌ Reject All"}
                        </button>
                      </div>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* ── Leg 1 — Staging Transfers ─────────────────────────────────────── */}
      {leg1ByWarehouse.length > 0 && (
        <div className="bg-white rounded-xl shadow-sm border border-amber-200 p-6 mb-6">
          <p className="text-xs font-semibold tracking-wider text-amber-600 uppercase mb-4">
            🚛 Leg 1 — Staging Transfers
          </p>
          <div className="flex items-center justify-between mb-3">
            <h2 className="text-base font-semibold text-gray-900">
              WH_CENTRAL → Staging
            </h2>
            <span className="text-xs text-gray-500">
              Move before driver departs
            </span>
          </div>

          <div className="space-y-4">
            {leg1ByWarehouse.map(([whName, items]) => {
              const totalUnits = items.reduce((s, i) => s + i.total_qty, 0);
              return (
                <div
                  key={whName}
                  className="overflow-hidden rounded-lg border border-amber-100"
                >
                  {/* Warehouse sub-header */}
                  <div className="flex items-center justify-between bg-amber-50 px-4 py-2">
                    <span className="text-sm font-semibold text-amber-900">
                      📦 {whName}
                    </span>
                    <span className="text-xs text-amber-700">
                      {items.length} SKU{items.length !== 1 ? "s" : ""} ·{" "}
                      {totalUnits} units
                    </span>
                  </div>

                  {/* Product lines */}
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="bg-gray-50 text-gray-500 uppercase tracking-wide text-[10px]">
                        <th className="px-3 py-2 text-left font-medium">
                          Boonz Product
                        </th>
                        <th className="px-3 py-2 text-left font-medium">
                          Pod Product
                        </th>
                        <th className="px-3 py-2 text-right font-medium">
                          Qty
                        </th>
                        <th className="px-3 py-2 text-left font-medium">
                          Machines
                        </th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-gray-50">
                      {items.map((item) => (
                        <tr
                          key={`${item.staging_warehouse_name}|${item.boonz_product_name}`}
                          className="hover:bg-gray-50"
                        >
                          <td className="px-3 py-2 font-medium text-gray-800 max-w-[160px] truncate">
                            {item.boonz_product_name}
                          </td>
                          <td className="px-3 py-2 text-gray-500 max-w-[140px] truncate">
                            {item.pod_product_name}
                          </td>
                          <td className="px-3 py-2 text-right font-semibold text-gray-900">
                            {item.total_qty}
                          </td>
                          <td className="px-3 py-2 text-gray-400">
                            <div className="flex flex-wrap gap-1">
                              {item.machines.map((m) => (
                                <span
                                  key={m}
                                  className="rounded bg-gray-100 px-1.5 py-0.5 text-[10px] text-gray-600"
                                >
                                  {m}
                                </span>
                              ))}
                            </div>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              );
            })}
          </div>
        </div>
      )}
    </>
  );
}
