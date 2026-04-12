"use client";

import { useState } from "react";

// ─── Types ────────────────────────────────────────────────────────────────────

export interface ShelfSlot {
  shelf_id: string;
  shelf_code: string;
  row_label: string;
  door_side: string;
  pod_product_name: string;
  target_qty: number;
  current_stock: number;
  refill_qty: number;
  fill_pct: number;
  last_snapshot_at: string | null;
  // cabinet_count: 1 = single-door (A side only), 2 = double-door (A and B sides).
  // Derived at query time from aisle_code prefixes in v_live_shelf_stock.
  cabinet_count: number;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function fillBarColor(pct: number): string {
  if (pct >= 70) return "bg-green-500";
  if (pct >= 30) return "bg-amber-400";
  return "bg-red-500";
}

function fillBadgeClass(pct: number): string {
  if (pct >= 70)
    return "text-green-700 bg-green-50 dark:text-green-300 dark:bg-green-900/30";
  if (pct >= 30)
    return "text-amber-700 bg-amber-50 dark:text-amber-300 dark:bg-amber-900/30";
  return "text-red-700 bg-red-50 dark:text-red-300 dark:bg-red-900/30";
}

// ─── Component ────────────────────────────────────────────────────────────────

export function ShelfGrid({ slots }: { slots: ShelfSlot[] }) {
  const [activeDoor, setActiveDoor] = useState<"A" | "B">("A");

  // cabinet_count is derived at query time from aisle_code prefixes in v_live_shelf_stock.
  // Single-door machines have only A-prefixed slots; double-door have both A and B.
  const isDoubleDoor = (slots[0]?.cabinet_count ?? 1) === 2;
  const visibleSlots = slots.filter((s) => s.door_side === activeDoor);

  // All unique row labels, sorted
  const allRowLabels = Array.from(
    new Set(slots.map((s) => s.row_label)),
  ).sort();

  // Build row → slots map for active door
  const rowMap = new Map<string, ShelfSlot[]>();
  for (const slot of visibleSlots) {
    const arr = rowMap.get(slot.row_label) ?? [];
    arr.push(slot);
    rowMap.set(slot.row_label, arr);
  }
  for (const [, arr] of rowMap) {
    arr.sort((a, b) => a.shelf_code.localeCompare(b.shelf_code));
  }

  // KPIs (across all doors)
  const totalSlots = slots.length;
  const needsRefill = slots.filter((s) => s.refill_qty > 0).length;
  const empty = slots.filter((s) => s.current_stock === 0).length;
  const avgFill =
    totalSlots > 0
      ? Math.round(slots.reduce((sum, s) => sum + s.fill_pct, 0) / totalSlots)
      : 0;

  if (slots.length === 0) {
    return (
      <div className="mt-8 text-center">
        <p className="text-neutral-500">No planogram data for this machine.</p>
      </div>
    );
  }

  return (
    <div>
      {/* KPI bar */}
      <div className="mb-4 grid grid-cols-4 gap-2">
        {[
          { label: "Slots", value: totalSlots, warn: false },
          { label: "Needs Refill", value: needsRefill, warn: needsRefill > 0 },
          { label: "Empty", value: empty, warn: empty > 0 },
          { label: "Avg Fill", value: `${avgFill}%`, warn: false },
        ].map((kpi) => (
          <div
            key={kpi.label}
            className={`rounded-lg border p-2 text-center ${
              kpi.warn
                ? "border-amber-200 bg-amber-50 dark:border-amber-800 dark:bg-amber-900/20"
                : "border-neutral-200 bg-neutral-50 dark:border-neutral-700 dark:bg-neutral-800/50"
            }`}
          >
            <p
              className={`text-lg font-bold ${kpi.warn ? "text-amber-700 dark:text-amber-300" : ""}`}
            >
              {kpi.value}
            </p>
            <p className="text-[10px] text-neutral-500">{kpi.label}</p>
          </div>
        ))}
      </div>

      {/* Door tabs */}
      {isDoubleDoor && (
        <div className="mb-3 flex gap-2">
          {(["A", "B"] as const).map((door) => (
            <button
              key={door}
              onClick={() => setActiveDoor(door)}
              className={`flex-1 rounded-md py-1.5 text-sm font-medium ${
                activeDoor === door
                  ? "bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900"
                  : "border border-neutral-300 text-neutral-600 dark:border-neutral-700 dark:text-neutral-400"
              }`}
            >
              Door {door}
            </button>
          ))}
        </div>
      )}

      {/* Planogram grid */}
      {allRowLabels.map((row) => {
        const rowSlots = rowMap.get(row) ?? [];
        if (rowSlots.length === 0) return null;
        return (
          <div key={row} className="mb-3">
            <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-neutral-400">
              {row}
            </p>
            <div
              className="grid gap-2"
              style={{
                gridTemplateColumns: `repeat(${rowSlots.length}, minmax(0, 1fr))`,
              }}
            >
              {rowSlots.map((slot) => (
                <div
                  key={slot.shelf_id}
                  className="rounded-lg border border-neutral-200 bg-white p-2 dark:border-neutral-700 dark:bg-neutral-800"
                >
                  <p className="text-[10px] font-medium text-neutral-400">
                    {slot.shelf_code}
                  </p>
                  <p className="mt-0.5 line-clamp-2 text-[11px] font-semibold leading-tight">
                    {slot.pod_product_name}
                  </p>
                  {/* Fill bar */}
                  <div className="mt-1.5 h-1.5 w-full overflow-hidden rounded-full bg-neutral-200 dark:bg-neutral-700">
                    <div
                      className={`h-full rounded-full ${fillBarColor(slot.fill_pct)}`}
                      style={{ width: `${Math.min(slot.fill_pct, 100)}%` }}
                    />
                  </div>
                  <div className="mt-1 flex items-center justify-between">
                    <span
                      className={`rounded px-1 py-0.5 text-[9px] font-medium ${fillBadgeClass(slot.fill_pct)}`}
                    >
                      {slot.fill_pct}%
                    </span>
                    <span className="text-[9px] text-neutral-500">
                      {slot.current_stock}/{slot.target_qty}
                    </span>
                  </div>
                  {slot.refill_qty > 0 && (
                    <p className="mt-0.5 text-[9px] font-medium text-amber-600 dark:text-amber-400">
                      +{slot.refill_qty}
                    </p>
                  )}
                </div>
              ))}
            </div>
          </div>
        );
      })}
    </div>
  );
}
