"use client";

// PRD-087 R4 — Stock Overview: where every product's units live right now.
// In-machine (Active pod inventory) vs warehouse stock (Active, unquarantined,
// unexpired; VOX consignment sentinels excluded). Feeds procurement decisions:
// low WH cover on a fast seller = buy signal. Data: get_stock_overview() RPC.

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { StatCard, Badge } from "@/components/ui/primitives";

const font = "'Plus Jakarta Sans', sans-serif";

type Row = {
  boonz_product_id: string;
  product_name: string;
  machine_units: number;
  machine_count: number;
  wh_units: number;
  wh_batches: number;
  wh_by_warehouse: Record<string, number>;
  nearest_wh_expiry: string | null;
  total_units: number;
};

type SortKey = "total" | "machine" | "wh" | "cover";

export default function StockOverviewTab() {
  const [rowsOrNull, setRows] = useState<Row[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [sortKey, setSortKey] = useState<SortKey>("total");
  const [onlyLowWh, setOnlyLowWh] = useState(false);

  const loading = rowsOrNull === null;
  const rows = useMemo(() => rowsOrNull ?? [], [rowsOrNull]);

  useEffect(() => {
    let alive = true;
    const supabase = createClient();
    supabase.rpc("get_stock_overview").then(({ data, error }) => {
      if (!alive) return;
      if (error) {
        setErr(error.message);
        setRows([]);
      } else {
        setRows(
          ((data as Row[]) || []).map((r) => ({
            ...r,
            machine_units: Number(r.machine_units),
            wh_units: Number(r.wh_units),
            total_units: Number(r.total_units),
            machine_count: Number(r.machine_count),
            wh_batches: Number(r.wh_batches),
          })),
        );
      }
    });
    return () => {
      alive = false;
    };
  }, []);

  const totals = useMemo(
    () => ({
      machine: rows.reduce((a, r) => a + r.machine_units, 0),
      wh: rows.reduce((a, r) => a + r.wh_units, 0),
      products: rows.length,
      lowWh: rows.filter((r) => r.machine_units > 0 && r.wh_units < r.machine_units * 0.5).length,
    }),
    [rows],
  );

  const visible = useMemo(() => {
    const q = search.trim().toLowerCase();
    let v = rows;
    if (q) v = v.filter((r) => r.product_name.toLowerCase().includes(q));
    if (onlyLowWh)
      v = v.filter(
        (r) => r.machine_units > 0 && r.wh_units < r.machine_units * 0.5,
      );
    const sorters: Record<SortKey, (a: Row, b: Row) => number> = {
      total: (a, b) => b.total_units - a.total_units,
      machine: (a, b) => b.machine_units - a.machine_units,
      wh: (a, b) => b.wh_units - a.wh_units,
      cover: (a, b) =>
        a.wh_units / Math.max(a.machine_units, 1) -
        b.wh_units / Math.max(b.machine_units, 1),
    };
    return [...v].sort(sorters[sortKey]);
  }, [rows, search, sortKey, onlyLowWh]);

  const maxTotal = Math.max(...rows.map((r) => r.total_units), 1);

  return (
    <div style={{ fontFamily: font }}>
      {/* Summary band */}
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(160px, 1fr))",
          gap: 12,
          marginBottom: 18,
        }}
      >
        <StatCard
          label="In Machines"
          value={totals.machine.toLocaleString()}
          sub="Active units on shelves"
        />
        <StatCard
          label="In Warehouse"
          value={totals.wh.toLocaleString()}
          sub="Active, unquarantined, in-date"
          accent="var(--gold)"
        />
        <StatCard
          label="Products Stocked"
          value={String(totals.products)}
          sub="with units anywhere"
          accent="var(--chart-5)"
        />
        <StatCard
          label="Thin WH Cover"
          value={String(totals.lowWh)}
          sub="WH < 50% of deployed units"
          accent="var(--danger)"
          valueColor={totals.lowWh > 0 ? "var(--danger)" : "var(--ink)"}
        />
      </div>

      {/* Controls */}
      <div className="flex items-center gap-3 flex-wrap mb-4">
        <input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search product…"
          style={{
            padding: "7px 10px",
            fontSize: 13,
            border: "1px solid var(--line)",
            borderRadius: 8,
            minWidth: 220,
            fontFamily: font,
          }}
        />
        <select
          value={sortKey}
          onChange={(e) => setSortKey(e.target.value as SortKey)}
          style={{
            padding: "7px 10px",
            fontSize: 13,
            border: "1px solid var(--line)",
            borderRadius: 8,
            background: "var(--surface)",
            fontFamily: font,
          }}
        >
          <option value="total">Sort: total units</option>
          <option value="machine">Sort: in machines</option>
          <option value="wh">Sort: in warehouse</option>
          <option value="cover">Sort: thinnest WH cover</option>
        </select>
        <label
          style={{
            display: "flex",
            alignItems: "center",
            gap: 6,
            fontSize: 12,
            color: "var(--muted)",
            cursor: "pointer",
          }}
        >
          <input
            type="checkbox"
            checked={onlyLowWh}
            onChange={(e) => setOnlyLowWh(e.target.checked)}
          />
          Only thin WH cover
        </label>
      </div>

      {err && (
        <div
          style={{
            padding: 12,
            borderRadius: 8,
            background: "var(--danger-bg)",
            color: "var(--danger)",
            fontSize: 13,
            marginBottom: 12,
          }}
        >
          {err}
        </div>
      )}

      {/* Table */}
      <div
        style={{
          background: "var(--surface)",
          border: "1px solid var(--line)",
          borderRadius: 10,
          overflowX: "auto",
        }}
      >
        <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 760 }}>
          <thead>
            <tr
              style={{
                borderBottom: "1px solid var(--line)",
                fontSize: 10,
                letterSpacing: "0.08em",
                color: "var(--muted)",
                textTransform: "uppercase",
              }}
            >
              <th style={{ textAlign: "left", padding: "10px 8px 10px 16px" }}>
                Product
              </th>
              <th style={{ textAlign: "left", padding: "10px 8px", width: 220 }}>
                Split
              </th>
              <th style={{ textAlign: "right", padding: "10px 8px" }}>
                In machines
              </th>
              <th style={{ textAlign: "right", padding: "10px 8px" }}>MCH</th>
              <th style={{ textAlign: "right", padding: "10px 8px" }}>
                Warehouse
              </th>
              <th style={{ textAlign: "left", padding: "10px 8px" }}>
                WH breakdown
              </th>
              <th style={{ textAlign: "right", padding: "10px 16px 10px 8px" }}>
                Total
              </th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr>
                <td
                  colSpan={7}
                  style={{ padding: 40, textAlign: "center", color: "var(--muted-2)", fontSize: 13 }}
                >
                  Loading stock overview…
                </td>
              </tr>
            ) : visible.length === 0 ? (
              <tr>
                <td
                  colSpan={7}
                  style={{ padding: 40, textAlign: "center", color: "var(--muted-2)", fontSize: 13 }}
                >
                  No products match.
                </td>
              </tr>
            ) : (
              visible.map((r) => {
                const thin =
                  r.machine_units > 0 && r.wh_units < r.machine_units * 0.5;
                const mPct = (r.machine_units / Math.max(r.total_units, 1)) * 100;
                const barW = (r.total_units / maxTotal) * 100;
                return (
                  <tr
                    key={r.boonz_product_id}
                    style={{ borderBottom: "1px solid var(--line)", fontSize: 13 }}
                  >
                    <td style={{ padding: "9px 8px 9px 16px", fontWeight: 600, color: "var(--ink)" }}>
                      {r.product_name}
                      {thin && (
                        <span style={{ marginLeft: 6 }}>
                          <Badge tone="danger">thin WH</Badge>
                        </span>
                      )}
                    </td>
                    <td style={{ padding: "9px 8px" }}>
                      {/* machine vs WH split bar, width ∝ total */}
                      <div
                        style={{
                          height: 10,
                          width: `${Math.max(barW, 4)}%`,
                          minWidth: 24,
                          borderRadius: 5,
                          overflow: "hidden",
                          display: "flex",
                          background: "var(--line)",
                        }}
                        title={`${r.machine_units} in machines · ${r.wh_units} in WH`}
                      >
                        <div style={{ width: `${mPct}%`, background: "var(--brand)" }} />
                        <div style={{ flex: 1, background: "var(--gold)" }} />
                      </div>
                    </td>
                    <td style={{ textAlign: "right", padding: "9px 8px", fontVariantNumeric: "tabular-nums", color: "var(--brand)", fontWeight: 700 }}>
                      {r.machine_units.toLocaleString()}
                    </td>
                    <td style={{ textAlign: "right", padding: "9px 8px", fontVariantNumeric: "tabular-nums", color: "var(--muted)" }}>
                      {r.machine_count}
                    </td>
                    <td style={{ textAlign: "right", padding: "9px 8px", fontVariantNumeric: "tabular-nums", color: thin ? "var(--danger)" : "var(--warn)", fontWeight: 700 }}>
                      {r.wh_units.toLocaleString()}
                    </td>
                    <td style={{ padding: "9px 8px", fontSize: 11, color: "var(--muted)" }}>
                      {Object.entries(r.wh_by_warehouse || {})
                        .map(([w, u]) => `${w} ${Number(u).toLocaleString()}`)
                        .join(" · ") || "—"}
                    </td>
                    <td style={{ textAlign: "right", padding: "9px 16px 9px 8px", fontVariantNumeric: "tabular-nums", fontWeight: 800, color: "var(--ink)" }}>
                      {r.total_units.toLocaleString()}
                    </td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>

      <p style={{ fontSize: 11, color: "var(--muted-2)", margin: "10px 4px" }}>
        <span style={{ color: "var(--brand)", fontWeight: 700 }}>■ green</span>{" "}
        = units live in machines ·{" "}
        <span style={{ color: "var(--gold)", fontWeight: 700 }}>■ gold</span> =
        warehouse stock (Active, unquarantined, in-date; VOX consignment
        sentinels excluded). Thin WH cover = warehouse holds less than half of
        what&apos;s deployed — a procurement signal for fast movers.
      </p>
    </div>
  );
}
