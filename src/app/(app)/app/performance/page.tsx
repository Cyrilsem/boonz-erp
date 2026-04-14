"use client";

import { useEffect, useState, useMemo, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
  CartesianGrid,
} from "recharts";

/* ------------------------------------------------------------------ */
/*  Types                                                              */
/* ------------------------------------------------------------------ */

interface SaleRow {
  transaction_id: string;
  machine_id: string;
  transaction_date: string;
  total_amount: number;
  paid_amount: number;
  qty: number;
  pod_product_name: string | null;
  boonz_product_id: string | null;
  delivery_status: string | null;
  refund_status: string | null;
}

interface MachineInfo {
  name: string;
  group: string;
}

type VenueGroup =
  | "All"
  | "ADDMIND"
  | "INDEPENDENT"
  | "OHMYDESK"
  | "VML"
  | "VOX"
  | "WPP";

const VENUE_GROUPS: VenueGroup[] = [
  "All",
  "ADDMIND",
  "INDEPENDENT",
  "OHMYDESK",
  "VML",
  "VOX",
  "WPP",
];

type Tab = "OVERVIEW" | "BY MACHINE" | "PRODUCTS" | "TRANSACTIONS";
const TABS: Tab[] = ["OVERVIEW", "BY MACHINE", "PRODUCTS", "TRANSACTIONS"];

const PAGE_SIZE = 50;

/* ------------------------------------------------------------------ */
/*  Helpers                                                            */
/* ------------------------------------------------------------------ */

function thirtyDaysAgo(today: string): string {
  const d = new Date(today + "T00:00:00");
  d.setDate(d.getDate() - 30);
  return d.toISOString().split("T")[0];
}

function fmtAed(n: number): string {
  return n.toLocaleString("en-AE", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

/* ------------------------------------------------------------------ */
/*  Styles                                                             */
/* ------------------------------------------------------------------ */

const font = "'Plus Jakarta Sans', sans-serif";

const cardStyle: React.CSSProperties = {
  background: "white",
  borderLeft: "4px solid #e1b460",
  borderRadius: 12,
  padding: "16px 20px",
  border: "1px solid #e8e4de",
  borderLeftWidth: 4,
  borderLeftColor: "#e1b460",
  borderLeftStyle: "solid",
};

const tableHeaderStyle: React.CSSProperties = {
  textAlign: "left",
  padding: "10px 12px",
  fontSize: 11,
  fontWeight: 600,
  letterSpacing: "0.06em",
  textTransform: "uppercase",
  color: "#6b6860",
  borderBottom: "2px solid #e8e4de",
  fontFamily: font,
};

const tableCellStyle: React.CSSProperties = {
  padding: "10px 12px",
  fontSize: 13,
  color: "#0a0a0a",
  borderBottom: "1px solid #f0ede8",
  fontFamily: font,
};

/* ------------------------------------------------------------------ */
/*  Component                                                          */
/* ------------------------------------------------------------------ */

export default function PerformancePage() {
  const today = getDubaiDate();

  /* --- state --- */
  const [dateFrom, setDateFrom] = useState(thirtyDaysAgo(today));
  const [dateTo, setDateTo] = useState(today);
  const [group, setGroup] = useState<VenueGroup>("All");
  const [activeTab, setActiveTab] = useState<Tab>("OVERVIEW");
  const [txnPage, setTxnPage] = useState(0);

  const [sales, setSales] = useState<SaleRow[]>([]);
  const [machineMap, setMachineMap] = useState<Record<string, MachineInfo>>({});
  const [loading, setLoading] = useState(true);
  const [fetchKey, setFetchKey] = useState(0); // bump to force refresh

  /* --- data fetch --- */
  useEffect(() => {
    let cancelled = false;
    async function load() {
      setLoading(true);
      const supabase = createClient();

      // Fetch machines
      const { data: machineData } = await supabase
        .from("machines")
        .select("machine_id, official_name, venue_group")
        .limit(10000);

      const mMap: Record<string, MachineInfo> = {};
      (machineData ?? []).forEach(
        (m: {
          machine_id: string;
          official_name: string | null;
          venue_group: string | null;
        }) => {
          mMap[m.machine_id] = {
            name: m.official_name ?? m.machine_id,
            group: m.venue_group ?? "UNKNOWN",
          };
        },
      );

      // Determine machine IDs for group filter
      let filterMachineIds: string[] | null = null;
      if (group !== "All") {
        filterMachineIds = Object.entries(mMap)
          .filter(([, v]) => v.group === group)
          .map(([k]) => k);
      }

      // Fetch sales
      let query = supabase
        .from("sales_history")
        .select(
          "transaction_id, machine_id, transaction_date, total_amount, paid_amount, qty, pod_product_name, boonz_product_id, delivery_status, refund_status",
        )
        .gte("transaction_date", `${dateFrom}T00:00:00`)
        .lte("transaction_date", `${dateTo}T23:59:59`)
        .eq("delivery_status", "Successful")
        .limit(10000);

      if (filterMachineIds !== null) {
        if (filterMachineIds.length === 0) {
          // No machines in this group — return empty
          if (!cancelled) {
            setMachineMap(mMap);
            setSales([]);
            setLoading(false);
          }
          return;
        }
        query = query.in("machine_id", filterMachineIds);
      }

      const { data: salesData } = await query;

      if (!cancelled) {
        setMachineMap(mMap);
        setSales((salesData as SaleRow[]) ?? []);
        setLoading(false);
      }
    }
    load();
    return () => {
      cancelled = true;
    };
  }, [dateFrom, dateTo, group, fetchKey]);

  // Reset txn page when filters change
  useEffect(() => {
    setTxnPage(0);
  }, [dateFrom, dateTo, group, fetchKey]);

  /* --- aggregations --- */
  const overview = useMemo(() => {
    const totalRevenue = sales.reduce((s, r) => s + (r.total_amount ?? 0), 0);
    const totalTxns = sales.length;
    const totalUnits = sales.reduce((s, r) => s + (r.qty ?? 0), 0);
    const avgPerTxn = totalTxns > 0 ? totalRevenue / totalTxns : 0;
    return { totalRevenue, totalTxns, totalUnits, avgPerTxn };
  }, [sales]);

  const dailyRevenue = useMemo(() => {
    const map: Record<string, number> = {};
    sales.forEach((r) => {
      const day = r.transaction_date?.split("T")[0] ?? "unknown";
      map[day] = (map[day] ?? 0) + (r.total_amount ?? 0);
    });
    return Object.entries(map)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([date, revenue]) => ({
        date,
        revenue: Math.round(revenue * 100) / 100,
      }));
  }, [sales]);

  const hourlyDistribution = useMemo(() => {
    const counts = new Array(24).fill(0);
    sales.forEach((r) => {
      if (r.transaction_date) {
        const h = new Date(r.transaction_date).getHours();
        counts[h]++;
      }
    });
    return counts.map((count, hour) => ({
      hour: String(hour).padStart(2, "0"),
      count,
    }));
  }, [sales]);

  const byMachine = useMemo(() => {
    const map: Record<
      string,
      { txns: number; units: number; revenue: number; lastSale: string }
    > = {};
    sales.forEach((r) => {
      const id = r.machine_id;
      if (!map[id]) map[id] = { txns: 0, units: 0, revenue: 0, lastSale: "" };
      map[id].txns++;
      map[id].units += r.qty ?? 0;
      map[id].revenue += r.total_amount ?? 0;
      if (r.transaction_date > map[id].lastSale)
        map[id].lastSale = r.transaction_date;
    });
    return Object.entries(map)
      .map(([machineId, d]) => ({
        machineId,
        name: machineMap[machineId]?.name ?? machineId,
        group: machineMap[machineId]?.group ?? "UNKNOWN",
        ...d,
        avgPerTxn: d.txns > 0 ? d.revenue / d.txns : 0,
      }))
      .sort((a, b) => b.revenue - a.revenue);
  }, [sales, machineMap]);

  const byProduct = useMemo(() => {
    const map: Record<
      string,
      { units: number; revenue: number; txns: number }
    > = {};
    sales.forEach((r) => {
      const name = r.pod_product_name ?? "Unknown Product";
      if (!map[name]) map[name] = { units: 0, revenue: 0, txns: 0 };
      map[name].units += r.qty ?? 0;
      map[name].revenue += r.total_amount ?? 0;
      map[name].txns++;
    });
    return Object.entries(map)
      .map(([product, d]) => ({
        product,
        ...d,
        avgPrice: d.txns > 0 ? d.revenue / d.txns : 0,
      }))
      .sort((a, b) => b.revenue - a.revenue);
  }, [sales]);

  const paginatedTxns = useMemo(() => {
    const sorted = [...sales].sort(
      (a, b) =>
        new Date(b.transaction_date).getTime() -
        new Date(a.transaction_date).getTime(),
    );
    const start = txnPage * PAGE_SIZE;
    return sorted.slice(start, start + PAGE_SIZE);
  }, [sales, txnPage]);

  const totalTxnPages = Math.ceil(sales.length / PAGE_SIZE);

  const handleRefresh = useCallback(() => setFetchKey((k) => k + 1), []);

  /* --- filter summary --- */
  const filterSummary = `${dateFrom} to ${dateTo}${group !== "All" ? ` | ${group}` : " | All Groups"}`;

  /* ---------------------------------------------------------------- */
  /*  Render                                                           */
  /* ---------------------------------------------------------------- */

  return (
    <div style={{ padding: "24px 32px", maxWidth: 1400, fontFamily: font }}>
      {/* Header */}
      <div style={{ marginBottom: 24 }}>
        <h1
          style={{
            fontWeight: 800,
            fontSize: 28,
            letterSpacing: "-0.02em",
            color: "#0a0a0a",
            margin: 0,
            fontFamily: font,
          }}
        >
          Performance
        </h1>
        <p style={{ color: "#6b6860", fontSize: 13, marginTop: 4 }}>
          {filterSummary}
        </p>
      </div>

      {/* Sticky filter bar */}
      <div
        style={{
          position: "sticky",
          top: 0,
          zIndex: 20,
          background: "#faf9f7",
          borderBottom: "1px solid #e8e4de",
          padding: "12px 0",
          marginBottom: 24,
          display: "flex",
          flexWrap: "wrap",
          gap: 12,
          alignItems: "center",
        }}
      >
        <label style={{ fontSize: 12, fontWeight: 600, color: "#6b6860" }}>
          FROM
          <input
            type="date"
            value={dateFrom}
            onChange={(e) => setDateFrom(e.target.value)}
            style={{
              marginLeft: 6,
              padding: "6px 10px",
              border: "1px solid #e8e4de",
              borderRadius: 8,
              fontSize: 13,
              fontFamily: font,
              color: "#0a0a0a",
              background: "white",
            }}
          />
        </label>
        <label style={{ fontSize: 12, fontWeight: 600, color: "#6b6860" }}>
          TO
          <input
            type="date"
            value={dateTo}
            onChange={(e) => setDateTo(e.target.value)}
            style={{
              marginLeft: 6,
              padding: "6px 10px",
              border: "1px solid #e8e4de",
              borderRadius: 8,
              fontSize: 13,
              fontFamily: font,
              color: "#0a0a0a",
              background: "white",
            }}
          />
        </label>
        <label style={{ fontSize: 12, fontWeight: 600, color: "#6b6860" }}>
          GROUP
          <select
            value={group}
            onChange={(e) => setGroup(e.target.value as VenueGroup)}
            style={{
              marginLeft: 6,
              padding: "6px 10px",
              border: "1px solid #e8e4de",
              borderRadius: 8,
              fontSize: 13,
              fontFamily: font,
              color: "#0a0a0a",
              background: "white",
            }}
          >
            {VENUE_GROUPS.map((g) => (
              <option key={g} value={g}>
                {g}
              </option>
            ))}
          </select>
        </label>
        <button
          onClick={handleRefresh}
          style={{
            padding: "6px 16px",
            background: "#24544a",
            color: "white",
            border: "none",
            borderRadius: 8,
            fontSize: 13,
            fontWeight: 600,
            fontFamily: font,
            cursor: "pointer",
          }}
        >
          Refresh
        </button>
      </div>

      {/* Tabs */}
      <div
        style={{
          display: "flex",
          gap: 0,
          borderBottom: "1px solid #e8e4de",
          marginBottom: 24,
        }}
      >
        {TABS.map((tab) => (
          <button
            key={tab}
            onClick={() => setActiveTab(tab)}
            style={{
              padding: "12px 16px",
              fontSize: 12,
              fontWeight: activeTab === tab ? 700 : 500,
              letterSpacing: "0.06em",
              textTransform: "uppercase",
              color: activeTab === tab ? "#0a0a0a" : "#6b6860",
              borderBottom:
                activeTab === tab
                  ? "3px solid #0a0a0a"
                  : "3px solid transparent",
              background: "none",
              border: "none",
              borderBottomWidth: 3,
              borderBottomStyle: "solid",
              borderBottomColor: activeTab === tab ? "#0a0a0a" : "transparent",
              cursor: "pointer",
              fontFamily: font,
            }}
          >
            {tab}
          </button>
        ))}
      </div>

      {/* Loading state */}
      {loading ? (
        <LoadingSkeleton />
      ) : sales.length === 0 ? (
        <div
          style={{
            textAlign: "center",
            padding: "60px 20px",
            color: "#6b6860",
            fontSize: 15,
            fontFamily: font,
          }}
        >
          No sales data for this selection
        </div>
      ) : (
        <>
          {activeTab === "OVERVIEW" && (
            <OverviewTab
              overview={overview}
              dailyRevenue={dailyRevenue}
              hourlyDistribution={hourlyDistribution}
            />
          )}
          {activeTab === "BY MACHINE" && <ByMachineTab data={byMachine} />}
          {activeTab === "PRODUCTS" && <ProductsTab data={byProduct} />}
          {activeTab === "TRANSACTIONS" && (
            <TransactionsTab
              data={paginatedTxns}
              machineMap={machineMap}
              page={txnPage}
              totalPages={totalTxnPages}
              onPageChange={setTxnPage}
            />
          )}
        </>
      )}
    </div>
  );
}

/* ================================================================== */
/*  Sub-components                                                     */
/* ================================================================== */

function LoadingSkeleton() {
  const shimmer: React.CSSProperties = {
    background: "linear-gradient(90deg, #f0ede8 25%, #faf9f7 50%, #f0ede8 75%)",
    backgroundSize: "200% 100%",
    animation: "shimmer 1.5s infinite",
    borderRadius: 12,
    height: 88,
  };
  return (
    <>
      <style>{`@keyframes shimmer { 0% { background-position: 200% 0; } 100% { background-position: -200% 0; } }`}</style>
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))",
          gap: 16,
          marginBottom: 24,
        }}
      >
        {[1, 2, 3, 4].map((i) => (
          <div key={i} style={shimmer} />
        ))}
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16 }}>
        <div style={{ ...shimmer, height: 280 }} />
        <div style={{ ...shimmer, height: 280 }} />
      </div>
    </>
  );
}

/* ------------------------------------------------------------------ */

function OverviewTab({
  overview,
  dailyRevenue,
  hourlyDistribution,
}: {
  overview: {
    totalRevenue: number;
    totalTxns: number;
    totalUnits: number;
    avgPerTxn: number;
  };
  dailyRevenue: { date: string; revenue: number }[];
  hourlyDistribution: { hour: string; count: number }[];
}) {
  const cards = [
    { label: "TOTAL REVENUE (AED)", value: fmtAed(overview.totalRevenue) },
    { label: "TRANSACTIONS", value: overview.totalTxns.toLocaleString() },
    { label: "UNITS SOLD", value: overview.totalUnits.toLocaleString() },
    { label: "AVG PER TRANSACTION", value: fmtAed(overview.avgPerTxn) },
  ];

  return (
    <>
      {/* Summary cards */}
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))",
          gap: 16,
          marginBottom: 32,
        }}
      >
        {cards.map((c) => (
          <div key={c.label} style={cardStyle}>
            <div
              style={{
                fontSize: 11,
                fontWeight: 600,
                letterSpacing: "0.06em",
                textTransform: "uppercase",
                color: "#6b6860",
                marginBottom: 8,
                fontFamily: font,
              }}
            >
              {c.label}
            </div>
            <div
              style={{
                fontSize: 24,
                fontWeight: 800,
                color: "#0a0a0a",
                fontFamily: font,
              }}
            >
              {c.value}
            </div>
          </div>
        ))}
      </div>

      {/* Charts */}
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(380px, 1fr))",
          gap: 24,
        }}
      >
        {/* Daily Revenue */}
        <div
          style={{
            background: "white",
            border: "1px solid #e8e4de",
            borderRadius: 12,
            padding: 20,
          }}
        >
          <div
            style={{
              fontSize: 13,
              fontWeight: 700,
              color: "#0a0a0a",
              marginBottom: 16,
              fontFamily: font,
            }}
          >
            Daily Revenue
          </div>
          <ResponsiveContainer width="100%" height={260}>
            <BarChart data={dailyRevenue}>
              <CartesianGrid strokeDasharray="3 3" stroke="#f0ede8" />
              <XAxis
                dataKey="date"
                tick={{ fontSize: 10, fill: "#6b6860" }}
                tickFormatter={(v: string) => v.slice(5)}
              />
              <YAxis tick={{ fontSize: 10, fill: "#6b6860" }} />
              <Tooltip
                contentStyle={{
                  borderRadius: 8,
                  border: "1px solid #e8e4de",
                  fontFamily: font,
                  fontSize: 12,
                }}
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                formatter={(value: any) => [
                  `AED ${fmtAed(Number(value))}`,
                  "Revenue",
                ]}
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                labelFormatter={(label: any) => String(label)}
              />
              <Bar dataKey="revenue" fill="#24544a" radius={[4, 4, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
        </div>

        {/* Hourly Distribution */}
        <div
          style={{
            background: "white",
            border: "1px solid #e8e4de",
            borderRadius: 12,
            padding: 20,
          }}
        >
          <div
            style={{
              fontSize: 13,
              fontWeight: 700,
              color: "#0a0a0a",
              marginBottom: 16,
              fontFamily: font,
            }}
          >
            Hourly Distribution
          </div>
          <ResponsiveContainer width="100%" height={260}>
            <BarChart data={hourlyDistribution}>
              <CartesianGrid strokeDasharray="3 3" stroke="#f0ede8" />
              <XAxis dataKey="hour" tick={{ fontSize: 10, fill: "#6b6860" }} />
              <YAxis tick={{ fontSize: 10, fill: "#6b6860" }} />
              <Tooltip
                contentStyle={{
                  borderRadius: 8,
                  border: "1px solid #e8e4de",
                  fontFamily: font,
                  fontSize: 12,
                }}
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                formatter={(value: any) => [Number(value), "Transactions"]}
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                labelFormatter={(label: any) => `Hour ${label}:00`}
              />
              <Bar dataKey="count" fill="#e1b460" radius={[4, 4, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
        </div>
      </div>
    </>
  );
}

/* ------------------------------------------------------------------ */

function ByMachineTab({
  data,
}: {
  data: {
    machineId: string;
    name: string;
    group: string;
    txns: number;
    units: number;
    revenue: number;
    avgPerTxn: number;
    lastSale: string;
  }[];
}) {
  return (
    <div style={{ overflowX: "auto" }}>
      <table
        style={{ width: "100%", borderCollapse: "collapse", minWidth: 700 }}
      >
        <thead>
          <tr>
            <th style={tableHeaderStyle}>Machine</th>
            <th style={tableHeaderStyle}>Group</th>
            <th style={{ ...tableHeaderStyle, textAlign: "right" }}>
              Transactions
            </th>
            <th style={{ ...tableHeaderStyle, textAlign: "right" }}>Units</th>
            <th style={{ ...tableHeaderStyle, textAlign: "right" }}>
              Revenue (AED)
            </th>
            <th style={{ ...tableHeaderStyle, textAlign: "right" }}>Avg/Txn</th>
            <th style={tableHeaderStyle}>Last Sale</th>
          </tr>
        </thead>
        <tbody>
          {data.map((row) => (
            <tr key={row.machineId}>
              <td style={tableCellStyle}>{row.name}</td>
              <td style={tableCellStyle}>
                <span
                  style={{
                    fontSize: 11,
                    fontWeight: 600,
                    padding: "2px 8px",
                    borderRadius: 4,
                    background: "#f0ede8",
                    color: "#6b6860",
                  }}
                >
                  {row.group}
                </span>
              </td>
              <td style={{ ...tableCellStyle, textAlign: "right" }}>
                {row.txns.toLocaleString()}
              </td>
              <td style={{ ...tableCellStyle, textAlign: "right" }}>
                {row.units.toLocaleString()}
              </td>
              <td
                style={{
                  ...tableCellStyle,
                  textAlign: "right",
                  fontWeight: 600,
                }}
              >
                {fmtAed(row.revenue)}
              </td>
              <td style={{ ...tableCellStyle, textAlign: "right" }}>
                {fmtAed(row.avgPerTxn)}
              </td>
              <td style={{ ...tableCellStyle, fontSize: 12, color: "#6b6860" }}>
                {row.lastSale
                  ? new Date(row.lastSale).toLocaleDateString("en-AE")
                  : "-"}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/* ------------------------------------------------------------------ */

function ProductsTab({
  data,
}: {
  data: {
    product: string;
    units: number;
    revenue: number;
    txns: number;
    avgPrice: number;
  }[];
}) {
  return (
    <div style={{ overflowX: "auto" }}>
      <table
        style={{ width: "100%", borderCollapse: "collapse", minWidth: 600 }}
      >
        <thead>
          <tr>
            <th style={tableHeaderStyle}>Product</th>
            <th style={{ ...tableHeaderStyle, textAlign: "right" }}>
              Units Sold
            </th>
            <th style={{ ...tableHeaderStyle, textAlign: "right" }}>
              Revenue (AED)
            </th>
            <th style={{ ...tableHeaderStyle, textAlign: "right" }}>
              Transactions
            </th>
            <th style={{ ...tableHeaderStyle, textAlign: "right" }}>
              Avg Price
            </th>
          </tr>
        </thead>
        <tbody>
          {data.map((row) => (
            <tr key={row.product}>
              <td style={tableCellStyle}>{row.product}</td>
              <td style={{ ...tableCellStyle, textAlign: "right" }}>
                {row.units.toLocaleString()}
              </td>
              <td
                style={{
                  ...tableCellStyle,
                  textAlign: "right",
                  fontWeight: 600,
                }}
              >
                {fmtAed(row.revenue)}
              </td>
              <td style={{ ...tableCellStyle, textAlign: "right" }}>
                {row.txns.toLocaleString()}
              </td>
              <td style={{ ...tableCellStyle, textAlign: "right" }}>
                {fmtAed(row.avgPrice)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/* ------------------------------------------------------------------ */

function TransactionsTab({
  data,
  machineMap,
  page,
  totalPages,
  onPageChange,
}: {
  data: SaleRow[];
  machineMap: Record<string, MachineInfo>;
  page: number;
  totalPages: number;
  onPageChange: (p: number) => void;
}) {
  const btnStyle: React.CSSProperties = {
    padding: "6px 16px",
    border: "1px solid #e8e4de",
    borderRadius: 8,
    background: "white",
    fontSize: 13,
    fontWeight: 600,
    fontFamily: font,
    cursor: "pointer",
    color: "#0a0a0a",
  };
  const btnDisabled: React.CSSProperties = {
    ...btnStyle,
    opacity: 0.4,
    cursor: "not-allowed",
  };

  return (
    <>
      <div style={{ overflowX: "auto" }}>
        <table
          style={{ width: "100%", borderCollapse: "collapse", minWidth: 700 }}
        >
          <thead>
            <tr>
              <th style={tableHeaderStyle}>Date/Time</th>
              <th style={tableHeaderStyle}>Machine</th>
              <th style={tableHeaderStyle}>Product</th>
              <th style={{ ...tableHeaderStyle, textAlign: "right" }}>Qty</th>
              <th style={{ ...tableHeaderStyle, textAlign: "right" }}>Price</th>
              <th style={tableHeaderStyle}>Status</th>
            </tr>
          </thead>
          <tbody>
            {data.map((txn) => (
              <tr key={txn.transaction_id}>
                <td
                  style={{
                    ...tableCellStyle,
                    fontSize: 12,
                    whiteSpace: "nowrap",
                  }}
                >
                  {new Date(txn.transaction_date).toLocaleString("en-AE")}
                </td>
                <td style={tableCellStyle}>
                  {machineMap[txn.machine_id]?.name ?? txn.machine_id}
                </td>
                <td style={tableCellStyle}>{txn.pod_product_name ?? "-"}</td>
                <td style={{ ...tableCellStyle, textAlign: "right" }}>
                  {txn.qty}
                </td>
                <td style={{ ...tableCellStyle, textAlign: "right" }}>
                  {fmtAed(txn.total_amount ?? 0)}
                </td>
                <td style={tableCellStyle}>
                  <span
                    style={{
                      fontSize: 11,
                      fontWeight: 600,
                      padding: "2px 8px",
                      borderRadius: 4,
                      background:
                        txn.delivery_status === "Successful"
                          ? "#d4edda"
                          : "#f8d7da",
                      color:
                        txn.delivery_status === "Successful"
                          ? "#155724"
                          : "#721c24",
                    }}
                  >
                    {txn.delivery_status ?? "-"}
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* Pagination */}
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          marginTop: 16,
          padding: "8px 0",
        }}
      >
        <button
          onClick={() => onPageChange(page - 1)}
          disabled={page === 0}
          style={page === 0 ? btnDisabled : btnStyle}
        >
          Previous
        </button>
        <span style={{ fontSize: 13, color: "#6b6860", fontFamily: font }}>
          Page {page + 1} of {totalPages || 1}
        </span>
        <button
          onClick={() => onPageChange(page + 1)}
          disabled={page >= totalPages - 1}
          style={page >= totalPages - 1 ? btnDisabled : btnStyle}
        >
          Next
        </button>
      </div>
    </>
  );
}
