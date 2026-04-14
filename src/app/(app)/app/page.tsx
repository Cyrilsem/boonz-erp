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
    <div className="p-8 max-w-5xl">
      {/* ── Page header ─────────────────────────────────────────────────────── */}
      <div className="mb-8">
        <h1
          style={{
            fontFamily: "'Plus Jakarta Sans', sans-serif",
            fontWeight: 800,
            fontSize: 28,
            letterSpacing: "-0.02em",
            color: "#0a0a0a",
            margin: 0,
          }}
        >
          Dashboard
        </h1>
        <p style={{ color: "#6b6860", fontSize: 14, marginTop: 4 }}>
          {formatDate(today)}
        </p>
      </div>

      {/* ── Stat cards ────────────────────────────────────────────────────── */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
        {statCards.map((card) => (
          <div
            key={card.label}
            style={{
              background: "white",
              border: "1px solid #e8e4de",
              borderLeft: "4px solid #e1b460",
              borderRadius: 12,
              padding: "20px 24px",
              transition: "border-color 0.15s",
            }}
            onMouseEnter={(e) => {
              (e.currentTarget as HTMLDivElement).style.borderColor = "#24544a";
              (e.currentTarget as HTMLDivElement).style.borderLeftColor =
                "#e1b460";
            }}
            onMouseLeave={(e) => {
              (e.currentTarget as HTMLDivElement).style.borderColor = "#e8e4de";
              (e.currentTarget as HTMLDivElement).style.borderLeftColor =
                "#e1b460";
            }}
          >
            <div className="flex items-center justify-between mb-3">
              <span
                style={{
                  fontSize: 11,
                  fontWeight: 500,
                  letterSpacing: "0.08em",
                  textTransform: "uppercase",
                  color: "#6b6860",
                }}
              >
                {card.label}
              </span>
              <span style={{ color: "#e1b460", fontSize: 18 }}>
                {card.icon}
              </span>
            </div>
            {loading ? (
              <div
                className="animate-pulse rounded"
                style={{
                  height: 40,
                  width: 64,
                  background: "#f0ede8",
                }}
              />
            ) : (
              <p
                style={{
                  fontSize: 32,
                  fontWeight: 800,
                  color: "#0a0a0a",
                  margin: 0,
                  lineHeight: 1,
                }}
              >
                {card.value ?? 0}
              </p>
            )}
          </div>
        ))}
      </div>

      {/* ── Expiring stock alert ───────────────────────────────────────────── */}
      {!loading && expiring.length > 0 && (
        <div className="mb-8">
          <p
            style={{
              fontSize: 11,
              fontWeight: 500,
              letterSpacing: "0.08em",
              textTransform: "uppercase",
              color: "#6b6860",
              marginBottom: 12,
            }}
          >
            ⚠ Expiring WH Stock (next 14 days)
          </p>
          <div
            style={{
              background: "#fff8ec",
              borderLeft: "4px solid #e1b460",
              borderRadius: 8,
              overflow: "hidden",
            }}
          >
            <table className="w-full text-sm">
              <thead>
                <tr style={{ borderBottom: "1px solid #f0e4c8" }}>
                  <th
                    className="text-left px-4 py-2"
                    style={{
                      fontSize: 11,
                      fontWeight: 500,
                      letterSpacing: "0.06em",
                      textTransform: "uppercase",
                      color: "#b8860b",
                    }}
                  >
                    Product
                  </th>
                  <th
                    className="text-right px-4 py-2"
                    style={{
                      fontSize: 11,
                      fontWeight: 500,
                      letterSpacing: "0.06em",
                      textTransform: "uppercase",
                      color: "#b8860b",
                    }}
                  >
                    Stock
                  </th>
                  <th
                    className="text-right px-4 py-2"
                    style={{
                      fontSize: 11,
                      fontWeight: 500,
                      letterSpacing: "0.06em",
                      textTransform: "uppercase",
                      color: "#b8860b",
                    }}
                  >
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
                      style={{ borderBottom: "1px solid #f5e8d0" }}
                    >
                      <td
                        className="px-4 py-2"
                        style={{
                          color: urgent ? "#dc2626" : "#92400e",
                          fontWeight: urgent ? 500 : 400,
                        }}
                      >
                        {row.boonz_product_name}
                      </td>
                      <td
                        className="px-4 py-2 text-right"
                        style={{ color: "#92400e" }}
                      >
                        {row.warehouse_stock}
                      </td>
                      <td
                        className="px-4 py-2 text-right tabular-nums"
                        style={{
                          color: urgent ? "#dc2626" : "#92400e",
                          fontWeight: urgent ? 500 : 400,
                        }}
                      >
                        {formatDate(row.expiration_date)}
                        {urgent && (
                          <span
                            className="ml-1 text-xs"
                            style={{ color: "#dc2626" }}
                          >
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
        <p
          style={{
            fontSize: 11,
            fontWeight: 500,
            letterSpacing: "0.08em",
            textTransform: "uppercase",
            color: "#6b6860",
            marginBottom: 12,
          }}
        >
          Recent Dispatches
        </p>
        <div
          style={{
            background: "white",
            border: "1px solid #e8e4de",
            borderRadius: 12,
            overflow: "hidden",
          }}
        >
          <table className="w-full text-sm">
            <thead>
              <tr style={{ borderBottom: "1px solid #e8e4de" }}>
                {["Date", "Machine", "Product", "Qty"].map((h, i) => (
                  <th
                    key={h}
                    className={
                      i === 3 ? "text-right px-4 py-3" : "text-left px-4 py-3"
                    }
                    style={{
                      fontSize: 11,
                      fontWeight: 500,
                      letterSpacing: "0.06em",
                      textTransform: "uppercase",
                      color: "#6b6860",
                    }}
                  >
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {loading ? (
                Array.from({ length: 5 }).map((_, i) => (
                  <tr key={i} style={{ borderBottom: "1px solid #f5f2ee" }}>
                    {[20, 32, 28, 8].map((w, j) => (
                      <td key={j} className="px-4 py-3">
                        <div
                          className="animate-pulse rounded"
                          style={{
                            height: 14,
                            width: `${w * 4}px`,
                            background: "#f0ede8",
                            marginLeft: j === 3 ? "auto" : 0,
                          }}
                        />
                      </td>
                    ))}
                  </tr>
                ))
              ) : dispatches.length === 0 ? (
                <tr>
                  <td
                    colSpan={4}
                    className="px-4 py-8 text-center"
                    style={{ color: "#6b6860" }}
                  >
                    No dispatches yet today.
                  </td>
                </tr>
              ) : (
                dispatches.map((row) => (
                  <tr
                    key={row.dispatch_id}
                    style={{ borderBottom: "1px solid #f5f2ee" }}
                    onMouseEnter={(e) =>
                      ((
                        e.currentTarget as HTMLTableRowElement
                      ).style.background = "#faf9f7")
                    }
                    onMouseLeave={(e) =>
                      ((
                        e.currentTarget as HTMLTableRowElement
                      ).style.background = "transparent")
                    }
                  >
                    <td
                      className="px-4 py-3 tabular-nums whitespace-nowrap"
                      style={{ color: "#6b6860" }}
                    >
                      {formatDate(row.dispatch_date)}
                    </td>
                    <td
                      className="px-4 py-3 max-w-[160px] truncate"
                      style={{ color: "#24544a", fontWeight: 500 }}
                      title={row.machine_name}
                    >
                      {row.machine_name}
                    </td>
                    <td
                      className="px-4 py-3 max-w-[180px] truncate"
                      style={{ color: "#0a0a0a" }}
                      title={row.product_name}
                    >
                      {row.product_name}
                    </td>
                    <td
                      className="px-4 py-3 text-right tabular-nums"
                      style={{ color: "#0a0a0a" }}
                    >
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
