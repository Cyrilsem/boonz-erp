"use client";

import { useEffect, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import { FieldHeader } from "../../../components/field-header";

// ─── Types ────────────────────────────────────────────────────────────────────

interface PickItem {
  machine_id: string;
  machine_name: string;
  shelf_code: string;
  pod_product_name: string;
  boonz_product_id: string;
  boonz_product_name: string;
  supplier: string;
  sku_pick_qty: number;
  warehouse_stock_available: number;
  is_blocker: boolean;
}

type GroupMode = "supplier" | "machine";

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function DispatchPickPage() {
  const [items, setItems] = useState<PickItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [groupBy, setGroupBy] = useState<GroupMode>("supplier");

  const fetchData = useCallback(async () => {
    const supabase = createClient();

    const { data } = await supabase
      .from("v_dispatch_pick_list")
      .select(
        "machine_id, machine_name, shelf_code, pod_product_name, boonz_product_id, boonz_product_name, supplier, sku_pick_qty, warehouse_stock_available",
      )
      .order("supplier")
      .order("machine_name")
      .limit(10000);

    if (data) {
      const mapped: PickItem[] = data.map((r) => ({
        machine_id: r.machine_id,
        machine_name: r.machine_name,
        shelf_code: r.shelf_code,
        pod_product_name: r.pod_product_name,
        boonz_product_id: r.boonz_product_id,
        boonz_product_name: r.boonz_product_name,
        supplier: r.supplier,
        sku_pick_qty: r.sku_pick_qty,
        warehouse_stock_available: r.warehouse_stock_available,
        is_blocker: r.warehouse_stock_available < r.sku_pick_qty,
      }));
      setItems(mapped);
    }

    setLoading(false);
  }, []);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  if (loading) {
    return (
      <>
        <FieldHeader title="Pick List" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading pick list…</p>
        </div>
      </>
    );
  }

  // KPIs
  const totalUnits = items.reduce((sum, i) => sum + i.sku_pick_qty, 0);
  const totalMachines = new Set(items.map((i) => i.machine_id)).size;
  const blockerCount = items.filter((i) => i.is_blocker).length;
  const uniqueSKUs = new Set(items.map((i) => i.boonz_product_id)).size;

  // Group maps
  const bySupplier = new Map<string, PickItem[]>();
  const byMachine = new Map<string, PickItem[]>();

  for (const item of items) {
    const sArr = bySupplier.get(item.supplier) ?? [];
    sArr.push(item);
    bySupplier.set(item.supplier, sArr);

    const mArr = byMachine.get(item.machine_name) ?? [];
    mArr.push(item);
    byMachine.set(item.machine_name, mArr);
  }

  const activeMap = groupBy === "supplier" ? bySupplier : byMachine;
  const groups = Array.from(activeMap.entries()).sort((a, b) =>
    a[0].localeCompare(b[0]),
  );

  return (
    <div className="pb-32">
      <FieldHeader title="Pick List" />

      <div className="px-4 pt-4">
        {/* KPI bar */}
        <div className="mb-4 grid grid-cols-4 gap-2">
          {[
            { label: "Units", value: totalUnits, warn: false },
            { label: "SKUs", value: uniqueSKUs, warn: false },
            { label: "Machines", value: totalMachines, warn: false },
            { label: "Blockers", value: blockerCount, warn: blockerCount > 0 },
          ].map((kpi) => (
            <div
              key={kpi.label}
              className={`rounded-lg border p-2 text-center ${
                kpi.warn
                  ? "border-red-200 bg-red-50 dark:border-red-800 dark:bg-red-900/20"
                  : "border-neutral-200 bg-neutral-50 dark:border-neutral-700 dark:bg-neutral-800/50"
              }`}
            >
              <p
                className={`text-lg font-bold ${kpi.warn ? "text-red-700 dark:text-red-300" : ""}`}
              >
                {kpi.value}
              </p>
              <p className="text-[10px] text-neutral-500">{kpi.label}</p>
            </div>
          ))}
        </div>

        {/* Group tabs */}
        <div className="mb-3 flex gap-2">
          {(["supplier", "machine"] as const).map((mode) => (
            <button
              key={mode}
              onClick={() => setGroupBy(mode)}
              className={`flex-1 rounded-md py-1.5 text-sm font-medium capitalize ${
                groupBy === mode
                  ? "bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900"
                  : "border border-neutral-300 text-neutral-600 dark:border-neutral-700 dark:text-neutral-400"
              }`}
            >
              By {mode}
            </button>
          ))}
        </div>

        {/* Groups */}
        {groups.map(([groupName, groupItems]) => {
          const groupUnits = groupItems.reduce((s, i) => s + i.sku_pick_qty, 0);
          const groupBlockers = groupItems.filter((i) => i.is_blocker).length;

          const sortedItems = [...groupItems].sort((a, b) => {
            if (a.is_blocker !== b.is_blocker) return a.is_blocker ? -1 : 1;
            return a.boonz_product_name.localeCompare(b.boonz_product_name);
          });

          return (
            <div
              key={groupName}
              className="mb-3 overflow-hidden rounded-lg border border-neutral-200 dark:border-neutral-700"
            >
              {/* Group header */}
              <div
                className={`flex items-center justify-between px-3 py-2 ${
                  groupBlockers > 0
                    ? "bg-red-50 dark:bg-red-900/20"
                    : "bg-neutral-50 dark:bg-neutral-800"
                }`}
              >
                <p className="text-sm font-semibold">{groupName}</p>
                <div className="flex items-center gap-2 text-xs text-neutral-500">
                  {groupBlockers > 0 && (
                    <span className="font-medium text-red-600 dark:text-red-400">
                      {groupBlockers} blocker{groupBlockers > 1 ? "s" : ""}
                    </span>
                  )}
                  <span>{groupUnits} units</span>
                </div>
              </div>

              {/* Items */}
              <div className="px-3">
                {sortedItems.map((item) => (
                  <div
                    key={`${item.machine_id}-${item.boonz_product_id}-${item.shelf_code}`}
                    className={`flex items-center justify-between border-b border-neutral-100 py-2.5 last:border-0 dark:border-neutral-800 ${
                      item.is_blocker ? "bg-red-50/60 dark:bg-red-900/10" : ""
                    }`}
                  >
                    <div className="min-w-0 flex-1 pr-2">
                      <p className="truncate text-sm font-medium">
                        {item.boonz_product_name}
                      </p>
                      <p className="truncate text-xs text-neutral-500">
                        {groupBy === "supplier"
                          ? item.machine_name
                          : item.supplier}{" "}
                        · {item.shelf_code}
                      </p>
                    </div>
                    <div className="shrink-0 text-right">
                      <p
                        className={`text-sm font-semibold ${item.is_blocker ? "text-red-600 dark:text-red-400" : ""}`}
                      >
                        {item.sku_pick_qty} units
                      </p>
                      <p
                        className={`text-xs ${item.is_blocker ? "text-red-500" : "text-neutral-400"}`}
                      >
                        {item.warehouse_stock_available} in stock
                        {item.is_blocker && " ⚠"}
                      </p>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          );
        })}

        {items.length === 0 && (
          <div className="mt-8 text-center">
            <p className="text-neutral-500">No items in pick list.</p>
          </div>
        )}
      </div>
    </div>
  );
}
