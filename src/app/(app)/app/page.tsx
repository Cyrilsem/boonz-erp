"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";

// ─── Types ────────────────────────────────────────────────────────────────────

interface Stats {
  activeMachines: number;
  whStockItems: number;
  products: number;
  simCards: number;
}

interface DispatchRow {
  dispatch_id: string;
  dispatch_date: string;
  machine_name: string;
  product_name: string;
  filled_quantity: number | null;
  quantity: number;
}

interface ExpiringRow {
  wh_inventory_id: string;
  boonz_product_name: string;
  warehouse_stock: number;
  expiration_date: string;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function formatDate(dateStr: string): string {
  return new Date(dateStr + "T00:00:00").toLocaleDateString("en-GB", {
    day: "numeric",
    month: "short",
    year: "2-digit",
  });
}

function addDays(dateStr: string, n: number): string {
  const d = new Date(dateStr + "T00:00:00");
  d.setDate(d.getDate() + n);
  return d.toISOString().split("T")[0];
}

function daysDiff(a: string, b: string): number {
  return Math.floor(
    (new Date(b + "T00:00:00").getTime() -
      new Date(a + "T00:00:00").getTime()) /
      86_400_000,
  );
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function AppPage() {
  const [stats, setStats] = useState<Stats | null>(null);
  const [dispatches, setDispatches] = useState<DispatchRow[]>([]);
  const [expiring, setExpiring] = useState<ExpiringRow[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function load() {
      const supabase = createClient();
      const today = getDubaiDate();
      const threshold = addDays(today, 14);

      const [
        { count: activeMachines },
        { count: whStockItems },
        { count: products },
        { count: simCards },
        { data: dispatchData },
        { data: expiryData },
      ] = await Promise.all([
        supabase
          .from("machines")
          .select("*", { count: "exact", head: true })
          .eq("status", "Active"),
        supabase
          .from("warehouse_inventory")
          .select("*", { count: "exact", head: true })
          .eq("status", "Active")
          .gt("warehouse_stock", 0),
        supabase
          .from("boonz_products")
          .select("*", { count: "exact", head: true }),
        supabase
          .from("sim_cards")
          .select("*", { count: "exact", head: true })
          .eq("is_active", true),
        supabase
          .from("refill_dispatching")
          .select(
            `dispatch_id, dispatch_date, quantity, filled_quantity,
             machines!inner(official_name),
             pod_products(pod_product_name)`,
          )
          .eq("dispatched", true)
          .order("dispatch_date", { ascending: false })
          .order("created_at", { ascending: false })
          .limit(10),
        supabase
          .from("warehouse_inventory")
          .select(
            "wh_inventory_id, warehouse_stock, expiration_date, boonz_products(boonz_product_name)",
          )
          .eq("status", "Active")
          .gt("warehouse_stock", 0)
          .not("expiration_date", "is", null)
          .lte("expiration_date", threshold)
          .order("expiration_date", { ascending: true })
          .limit(10000),
      ]);

      setStats({
        activeMachines: activeMachines ?? 0,
        whStockItems: whStockItems ?? 0,
        products: products ?? 0,
        simCards: simCards ?? 0,
      });

      setDispatches(
        (dispatchData ?? []).map((row) => {
          const machine = row.machines as unknown as {
            official_name: string;
          } | null;
          const pod = row.pod_products as unknown as {
            pod_product_name: string;
          } | null;
          return {
            dispatch_id: row.dispatch_id,
            dispatch_date: row.dispatch_date,
            machine_name: machine?.official_name ?? "—",
            product_name: pod?.pod_product_name ?? "—",
            filled_quantity: row.filled_quantity as number | null,
            quantity: row.quantity ?? 0,
          };
        }),
      );

      setExpiring(
        (expiryData ?? []).map((row) => {
          const bp = row.boonz_products as unknown as {
            boonz_product_name: string;
          } | null;
          return {
            wh_inventory_id: row.wh_inventory_id,
            boonz_product_name: bp?.boonz_product_name ?? "—",
            warehouse_stock: row.warehouse_stock ?? 0,
            expiration_date: row.expiration_date,
          };
        }),
      );

      setLoading(false);
    }

    load();
  }, []);

  const today = getDubaiDate();

  // ── Stat cards ──────────────────────────────────────────────────────────────
  const statCards = [
    { label: "Active Machines", value: stats?.activeMachines, icon: "⊞" },
    { label: "WH Stock Items", value: stats?.whStockItems, icon: "▤" },
    { label: "Products", value: stats?.products, icon: "☐" },
    { label: "Active SIM Cards", value: stats?.simCards, icon: "◈" },
  ];

  return (
    <div className="p-6 max-w-5xl">
      <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100 mb-1">
        Dashboard
      </h1>
      <p className="text-sm text-gray-500 dark:text-gray-400 mb-6">
        {formatDate(today)}
      </p>

      {/* ── Stat cards ────────────────────────────────────────────────────── */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
        {statCards.map((card) => (
          <div
            key={card.label}
            className="rounded-xl border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-900 px-5 py-4"
          >
            <div className="flex items-center justify-between mb-2">
              <span className="text-xs font-medium text-neutral-500 dark:text-neutral-400 uppercase tracking-wide">
                {card.label}
              </span>
              <span className="text-neutral-400 dark:text-neutral-600 text-lg">
                {card.icon}
              </span>
            </div>
            {loading ? (
              <div className="h-8 w-16 animate-pulse rounded bg-neutral-100 dark:bg-neutral-800" />
            ) : (
              <p className="text-3xl font-bold text-gray-900 dark:text-gray-100">
                {card.value ?? 0}
              </p>
            )}
          </div>
        ))}
      </div>

      {/* ── Expiring stock alert ───────────────────────────────────────────── */}
      {!loading && expiring.length > 0 && (
        <div className="mb-8">
          <h2 className="text-sm font-semibold uppercase tracking-wide text-neutral-500 dark:text-neutral-400 mb-3">
            ⚠ Expiring WH Stock (next 14 days)
          </h2>
          <div className="rounded-xl border border-amber-200 bg-amber-50 dark:border-amber-900/50 dark:bg-amber-950/20 overflow-hidden">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-amber-200 dark:border-amber-900/50">
                  <th className="text-left px-4 py-2 font-medium text-amber-900 dark:text-amber-300">
                    Product
                  </th>
                  <th className="text-right px-4 py-2 font-medium text-amber-900 dark:text-amber-300">
                    Stock
                  </th>
                  <th className="text-right px-4 py-2 font-medium text-amber-900 dark:text-amber-300">
                    Expires
                  </th>
                </tr>
              </thead>
              <tbody>
                {expiring.map((row) => {
                  const daysLeft = daysDiff(today, row.expiration_date);
                  const urgent = daysLeft <= 7;
                  return (
                    <tr
                      key={row.wh_inventory_id}
                      className="border-b border-amber-100 dark:border-amber-900/30 last:border-0"
                    >
                      <td
                        className={`px-4 py-2 ${urgent ? "font-medium text-red-700 dark:text-red-400" : "text-amber-900 dark:text-amber-200"}`}
                      >
                        {row.boonz_product_name}
                      </td>
                      <td className="px-4 py-2 text-right text-amber-800 dark:text-amber-300">
                        {row.warehouse_stock}
                      </td>
                      <td
                        className={`px-4 py-2 text-right tabular-nums ${urgent ? "text-red-700 font-medium dark:text-red-400" : "text-amber-800 dark:text-amber-300"}`}
                      >
                        {formatDate(row.expiration_date)}
                        {urgent && (
                          <span className="ml-1 text-xs text-red-600 dark:text-red-400">
                            ({daysLeft}d)
                          </span>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* ── Recent dispatches ─────────────────────────────────────────────── */}
      <div>
        <h2 className="text-sm font-semibold uppercase tracking-wide text-neutral-500 dark:text-neutral-400 mb-3">
          Recent Dispatches
        </h2>
        <div className="rounded-xl border border-neutral-200 dark:border-neutral-800 overflow-hidden">
          <table className="w-full text-sm">
            <thead className="bg-neutral-50 dark:bg-neutral-900">
              <tr>
                <th className="text-left px-4 py-2 font-medium text-neutral-600 dark:text-neutral-400">
                  Date
                </th>
                <th className="text-left px-4 py-2 font-medium text-neutral-600 dark:text-neutral-400">
                  Machine
                </th>
                <th className="text-left px-4 py-2 font-medium text-neutral-600 dark:text-neutral-400">
                  Product
                </th>
                <th className="text-right px-4 py-2 font-medium text-neutral-600 dark:text-neutral-400">
                  Qty
                </th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                Array.from({ length: 5 }).map((_, i) => (
                  <tr
                    key={i}
                    className="border-t border-neutral-100 dark:border-neutral-800"
                  >
                    <td className="px-4 py-2">
                      <div className="h-4 w-20 animate-pulse rounded bg-neutral-100 dark:bg-neutral-800" />
                    </td>
                    <td className="px-4 py-2">
                      <div className="h-4 w-32 animate-pulse rounded bg-neutral-100 dark:bg-neutral-800" />
                    </td>
                    <td className="px-4 py-2">
                      <div className="h-4 w-28 animate-pulse rounded bg-neutral-100 dark:bg-neutral-800" />
                    </td>
                    <td className="px-4 py-2">
                      <div className="h-4 w-8 animate-pulse rounded bg-neutral-100 dark:bg-neutral-800 ml-auto" />
                    </td>
                  </tr>
                ))
              ) : dispatches.length === 0 ? (
                <tr>
                  <td
                    colSpan={4}
                    className="px-4 py-6 text-center text-neutral-400 dark:text-neutral-600"
                  >
                    No dispatches yet today.
                  </td>
                </tr>
              ) : (
                dispatches.map((row) => (
                  <tr
                    key={row.dispatch_id}
                    className="border-t border-neutral-100 dark:border-neutral-800 hover:bg-neutral-50 dark:hover:bg-neutral-900/50"
                  >
                    <td className="px-4 py-2 text-neutral-500 tabular-nums whitespace-nowrap">
                      {formatDate(row.dispatch_date)}
                    </td>
                    <td
                      className="px-4 py-2 text-neutral-800 dark:text-neutral-200 max-w-[160px] truncate"
                      title={row.machine_name}
                    >
                      {row.machine_name}
                    </td>
                    <td
                      className="px-4 py-2 text-neutral-700 dark:text-neutral-300 max-w-[180px] truncate"
                      title={row.product_name}
                    >
                      {row.product_name}
                    </td>
                    <td className="px-4 py-2 text-right tabular-nums text-neutral-700 dark:text-neutral-300">
                      {row.filled_quantity ?? row.quantity}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
