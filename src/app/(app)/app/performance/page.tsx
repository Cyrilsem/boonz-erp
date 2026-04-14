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
  LineChart,
  Line,
  ScatterChart,
  Scatter,
  ZAxis,
  Cell,
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
  cost_amount: number | null;
}

interface AdyenTxn {
  adyen_txn_id: string;
  machine_id: string;
  creation_date: string;
  value_aed: number | null;
  captured_amount_value: number | null;
  status: string | null;
  payment_method: string | null;
  funding_source: string | null;
  store_description: string | null;
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

type Tab =
  | "OVERVIEW"
  | "SITES & MACHINES"
  | "PRODUCTS"
  | "PAYMENTS"
  | "TRANSACTIONS";

const VENUE_GROUPS: VenueGroup[] = [
  "All",
  "ADDMIND",
  "INDEPENDENT",
  "OHMYDESK",
  "VML",
  "VOX",
  "WPP",
];

const TABS: Tab[] = [
  "OVERVIEW",
  "SITES & MACHINES",
  "PRODUCTS",
  "PAYMENTS",
  "TRANSACTIONS",
];

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

function getISOWeek(dateStr: string): string {
  const d = new Date(dateStr + "T00:00:00");
  d.setDate(d.getDate() + 3 - ((d.getDay() + 6) % 7));
  const week1 = new Date(d.getFullYear(), 0, 4);
  const weekNum =
    1 +
    Math.round(
      ((d.getTime() - week1.getTime()) / 86400000 -
        3 +
        ((week1.getDay() + 6) % 7)) /
        7,
    );
  return `W${weekNum}`;
}

function getDayOfWeek(dateStr: string): string {
  const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const d = new Date(dateStr + "T00:00:00");
  return days[d.getDay()];
}

/* ------------------------------------------------------------------ */
/*  Styles                                                             */
/* ------------------------------------------------------------------ */

const font = "'Plus Jakarta Sans', sans-serif";

const cardStyle: React.CSSProperties = {
  background: "white",
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

const dateInputStyle: React.CSSProperties = {
  padding: "5px 10px",
  border: "1px solid #e8e4de",
  borderRadius: 4,
  fontSize: 12,
  fontFamily: font,
  color: "#0a0a0a",
  background: "white",
};

const selectStyle: React.CSSProperties = {
  padding: "5px 10px",
  border: "1px solid #e8e4de",
  borderRadius: 4,
  fontSize: 12,
  fontFamily: font,
  color: "#0a0a0a",
  background: "white",
};

const tooltipStyle = {
  borderRadius: 8,
  border: "1px solid #e8e4de",
  fontFamily: font,
  fontSize: 12,
};

const chartBoxStyle: React.CSSProperties = {
  background: "white",
  border: "1px solid #e8e4de",
  borderRadius: 12,
  padding: 20,
};

const chartTitleStyle: React.CSSProperties = {
  fontSize: 13,
  fontWeight: 700,
  color: "#0a0a0a",
  marginBottom: 16,
  fontFamily: font,
};

const statusBadgeColors: Record<string, { bg: string; color: string }> = {
  SettledBulk: { bg: "#f0fdf4", color: "#065f46" },
  Cancelled: { bg: "#f5f2ee", color: "#6b6860" },
  Refused: { bg: "#fef2f2", color: "#991b1b" },
  RefundedBulk: { bg: "#fffbeb", color: "#92400e" },
  Expired: { bg: "#f5f2ee", color: "#6b6860" },
  Authorised: { bg: "#e6f1fb", color: "#185fa5" },
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
  const [adyenTxns, setAdyenTxns] = useState<AdyenTxn[]>([]);
  const [machineMap, setMachineMap] = useState<Record<string, MachineInfo>>({});
  const [loading, setLoading] = useState(true);
  const [fetchKey, setFetchKey] = useState(0);
  const [lastUpdated, setLastUpdated] = useState<string | null>(null);

  /* --- data fetch --- */
  useEffect(() => {
    let cancelled = false;
    async function load() {
      setLoading(true);
      setTxnPage(0);
      const supabase = createClient();

      // 1. Fetch machines
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

      // 2. Determine machine IDs for group filter
      let filterMachineIds: string[] | null = null;
      if (group !== "All") {
        filterMachineIds = Object.entries(mMap)
          .filter(([, v]) => v.group === group)
          .map(([k]) => k);
      }

      if (filterMachineIds !== null && filterMachineIds.length === 0) {
        if (!cancelled) {
          setMachineMap(mMap);
          setSales([]);
          setAdyenTxns([]);
          setLoading(false);
          setLastUpdated(
            new Date().toLocaleTimeString("en-AE", {
              hour: "2-digit",
              minute: "2-digit",
              timeZone: "Asia/Dubai",
            }),
          );
        }
        return;
      }

      // 3. Fetch sales_history
      const { data: salesData } = await supabase
        .from("sales_history")
        .select(
          "transaction_id, machine_id, transaction_date, total_amount, paid_amount, qty, pod_product_name, boonz_product_id, delivery_status, refund_status, cost_amount",
        )
        .gte("transaction_date", `${dateFrom}T00:00:00`)
        .lte("transaction_date", `${dateTo}T23:59:59`)
        .eq("delivery_status", "Successful")
        .limit(10000);

      // 4. Fetch adyen_transactions
      const { data: adyenData } = await supabase
        .from("adyen_transactions")
        .select(
          "adyen_txn_id, machine_id, creation_date, value_aed, captured_amount_value, status, payment_method, funding_source, store_description",
        )
        .gte("creation_date", `${dateFrom}T00:00:00`)
        .lte("creation_date", `${dateTo}T23:59:59`)
        .limit(10000);

      if (!cancelled) {
        setMachineMap(mMap);

        // Filter by machineIds client-side if group selected
        let filteredSales = (salesData as SaleRow[]) ?? [];
        let filteredAdyen = (adyenData as AdyenTxn[]) ?? [];
        if (filterMachineIds !== null) {
          const idSet = new Set(filterMachineIds);
          filteredSales = filteredSales.filter((s) => idSet.has(s.machine_id));
          filteredAdyen = filteredAdyen.filter((a) => idSet.has(a.machine_id));
        }

        setSales(filteredSales);
        setAdyenTxns(filteredAdyen);
        setLoading(false);
        setLastUpdated(
          new Date().toLocaleTimeString("en-AE", {
            hour: "2-digit",
            minute: "2-digit",
            timeZone: "Asia/Dubai",
          }),
        );
      }
    }
    load();
    return () => {
      cancelled = true;
    };
  }, [dateFrom, dateTo, group, fetchKey]);

  /* --- Payment default strip aggregations --- */
  const paymentDefault = useMemo(() => {
    const totalSales = sales.reduce((s, r) => s + (r.total_amount ?? 0), 0);
    const totalCaptured = adyenTxns
      .filter((a) => a.status === "SettledBulk")
      .reduce((s, a) => s + (a.value_aed ?? 0), 0);
    const gap = totalSales - totalCaptured;
    const defaultRate = totalSales > 0 ? (gap / totalSales) * 100 : 0;
    return {
      totalSales: Math.round(totalSales * 100) / 100,
      totalCaptured: Math.round(totalCaptured * 100) / 100,
      gap: Math.round(gap * 100) / 100,
      defaultRate: Math.round(defaultRate * 100) / 100,
    };
  }, [sales, adyenTxns]);

  /* --- overview aggregations --- */
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

  const weeklyRevenue = useMemo(() => {
    const map: Record<string, number> = {};
    sales.forEach((r) => {
      const day = r.transaction_date?.split("T")[0] ?? "";
      if (!day) return;
      const week = getISOWeek(day);
      map[week] = (map[week] ?? 0) + (r.total_amount ?? 0);
    });
    return Object.entries(map)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([week, revenue]) => ({
        week,
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

  const dayOfWeekRevenue = useMemo(() => {
    const map: Record<string, number> = {};
    const dayOrder = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    dayOrder.forEach((d) => {
      map[d] = 0;
    });
    sales.forEach((r) => {
      const day = r.transaction_date?.split("T")[0] ?? "";
      if (!day) return;
      const dow = getDayOfWeek(day);
      map[dow] = (map[dow] ?? 0) + (r.total_amount ?? 0);
    });
    return dayOrder.map((day) => ({
      day,
      revenue: Math.round((map[day] ?? 0) * 100) / 100,
    }));
  }, [sales]);

  /* --- product aggregation --- */
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

  /* --- transactions pagination --- */
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

  /* --- tab bar styles --- */
  const tabBarStyle: React.CSSProperties = {
    position: "sticky",
    top: 0,
    zIndex: 100,
    background: "rgba(250,249,247,0.97)",
    backdropFilter: "blur(12px)",
    borderBottom: "1px solid #e8e4de",
    display: "flex",
    alignItems: "center",
    padding: "0 24px",
    flexWrap: "wrap",
  };

  const tabStyle = (active: boolean): React.CSSProperties => ({
    padding: "12px 16px",
    fontSize: 12,
    fontWeight: active ? 700 : 500,
    letterSpacing: "0.06em",
    textTransform: "uppercase",
    color: active ? "#0a0a0a" : "#6b6860",
    cursor: "pointer",
    background: "none",
    border: "none",
    borderBottomWidth: 3,
    borderBottomStyle: "solid",
    borderBottomColor: active ? "#0a0a0a" : "transparent",
    whiteSpace: "nowrap",
    fontFamily: font,
  });

  /* ---------------------------------------------------------------- */
  /*  Render                                                           */
  /* ---------------------------------------------------------------- */

  return (
    <div style={{ fontFamily: font }}>
      {/* Tab bar */}
      <div style={tabBarStyle}>
        <span
          style={{
            fontFamily: font,
            fontWeight: 800,
            fontSize: 15,
            padding: "14px 24px 14px 0",
            borderRight: "1px solid #e8e4de",
            marginRight: 8,
            letterSpacing: "-0.5px",
          }}
        >
          Performance
        </span>
        {TABS.map((t) => (
          <button
            key={t}
            onClick={() => setActiveTab(t)}
            style={tabStyle(activeTab === t)}
          >
            {t}
          </button>
        ))}
        <div
          style={{
            marginLeft: "auto",
            fontSize: 10,
            color: "#6b6860",
            display: "flex",
            gap: 16,
            alignItems: "center",
          }}
        >
          {lastUpdated && <span>Updated {lastUpdated}</span>}
        </div>
      </div>

      {/* Filter bar */}
      <div
        style={{
          background: "#f5f2ee",
          borderBottom: "1px solid #e8e4de",
          padding: "10px 24px",
          display: "flex",
          alignItems: "center",
          gap: 14,
          flexWrap: "wrap",
        }}
      >
        <span
          style={{
            fontSize: 10,
            color: "#6b6860",
            textTransform: "uppercase",
            letterSpacing: "0.1em",
          }}
        >
          PERIOD
        </span>
        <input
          type="date"
          value={dateFrom}
          onChange={(e) => setDateFrom(e.target.value)}
          style={dateInputStyle}
        />
        <input
          type="date"
          value={dateTo}
          onChange={(e) => setDateTo(e.target.value)}
          style={dateInputStyle}
        />
        <div
          style={{
            width: 1,
            height: 20,
            background: "#e8e4de",
            margin: "0 4px",
          }}
        />
        <span
          style={{
            fontSize: 10,
            color: "#6b6860",
            textTransform: "uppercase",
            letterSpacing: "0.1em",
          }}
        >
          GROUP
        </span>
        <select
          value={group}
          onChange={(e) => setGroup(e.target.value as VenueGroup)}
          style={selectStyle}
        >
          {VENUE_GROUPS.map((g) => (
            <option key={g} value={g}>
              {g}
            </option>
          ))}
        </select>
        <button
          onClick={handleRefresh}
          style={{
            padding: "5px 12px",
            borderRadius: 4,
            fontSize: 11,
            cursor: "pointer",
            border: "1px solid #e8e4de",
            background: "white",
            color: "#6b6860",
            display: "flex",
            alignItems: "center",
            gap: 6,
          }}
        >
          &#8634; Refresh
        </button>
      </div>

      {/* Payment Default Strip */}
      <div
        style={{
          background: "#24544a",
          padding: "10px 24px",
          display: "flex",
          alignItems: "center",
          gap: 10,
          flexWrap: "wrap",
        }}
      >
        <span
          style={{
            fontSize: 10,
            fontWeight: 700,
            letterSpacing: "0.12em",
            textTransform: "uppercase",
            color: "white",
          }}
        >
          PAYMENT DEFAULT
        </span>
        <span style={{ fontSize: 11, color: "rgba(255,255,255,0.7)" }}>
          Total Weimi
        </span>
        <span style={{ fontSize: 13, fontWeight: 700, color: "white" }}>
          AED {fmtAed(paymentDefault.totalSales)}
        </span>
        <span style={{ fontSize: 11, color: "rgba(255,255,255,0.7)" }}>
          Captured Adyen
        </span>
        <span style={{ fontSize: 13, fontWeight: 700, color: "#e1b460" }}>
          AED {fmtAed(paymentDefault.totalCaptured)}
        </span>
        <span style={{ fontSize: 11, color: "rgba(255,255,255,0.7)" }}>
          Gap
        </span>
        <span style={{ fontSize: 13, fontWeight: 700, color: "#dc2626" }}>
          AED {fmtAed(paymentDefault.gap)}
        </span>
        <span style={{ fontSize: 11, color: "rgba(255,255,255,0.7)" }}>
          Default
        </span>
        <span
          style={{
            fontSize: 13,
            fontWeight: 700,
            color: paymentDefault.defaultRate > 5 ? "#dc2626" : "#e1b460",
          }}
        >
          {paymentDefault.defaultRate.toFixed(1)}%
        </span>
      </div>

      {/* Content */}
      <div style={{ padding: "28px 24px", maxWidth: 1400, margin: "0 auto" }}>
        {loading ? (
          <LoadingSkeleton />
        ) : sales.length === 0 && adyenTxns.length === 0 ? (
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
                weeklyRevenue={weeklyRevenue}
                hourlyDistribution={hourlyDistribution}
                dayOfWeekRevenue={dayOfWeekRevenue}
              />
            )}
            {activeTab === "SITES & MACHINES" && (
              <SitesAndMachinesTab sales={sales} machineMap={machineMap} />
            )}
            {activeTab === "PRODUCTS" && (
              <ProductsTab
                data={byProduct}
                totalRevenue={overview.totalRevenue}
              />
            )}
            {activeTab === "PAYMENTS" && <PaymentsTab adyenTxns={adyenTxns} />}
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
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "1fr 1fr",
          gap: 16,
        }}
      >
        <div style={{ ...shimmer, height: 280 }} />
        <div style={{ ...shimmer, height: 280 }} />
      </div>
    </>
  );
}

/* ------------------------------------------------------------------ */
/*  OVERVIEW TAB                                                       */
/* ------------------------------------------------------------------ */

function OverviewTab({
  overview,
  dailyRevenue,
  weeklyRevenue,
  hourlyDistribution,
  dayOfWeekRevenue,
}: {
  overview: {
    totalRevenue: number;
    totalTxns: number;
    totalUnits: number;
    avgPerTxn: number;
  };
  dailyRevenue: { date: string; revenue: number }[];
  weeklyRevenue: { week: string; revenue: number }[];
  hourlyDistribution: { hour: string; count: number }[];
  dayOfWeekRevenue: { day: string; revenue: number }[];
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

      {/* Charts 2x2 */}
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(380px, 1fr))",
          gap: 24,
        }}
      >
        {/* Daily Revenue */}
        <div style={chartBoxStyle}>
          <div style={chartTitleStyle}>Daily Revenue</div>
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
                contentStyle={tooltipStyle}
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

        {/* Week-on-Week */}
        <div style={chartBoxStyle}>
          <div style={chartTitleStyle}>Week-on-Week Revenue</div>
          <ResponsiveContainer width="100%" height={260}>
            <BarChart data={weeklyRevenue}>
              <CartesianGrid strokeDasharray="3 3" stroke="#f0ede8" />
              <XAxis dataKey="week" tick={{ fontSize: 10, fill: "#6b6860" }} />
              <YAxis tick={{ fontSize: 10, fill: "#6b6860" }} />
              <Tooltip
                contentStyle={tooltipStyle}
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                formatter={(value: any) => [
                  `AED ${fmtAed(Number(value))}`,
                  "Revenue",
                ]}
              />
              <Bar dataKey="revenue" fill="#24544a" radius={[4, 4, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
        </div>

        {/* Hourly Distribution */}
        <div style={chartBoxStyle}>
          <div style={chartTitleStyle}>Hourly Distribution</div>
          <ResponsiveContainer width="100%" height={260}>
            <BarChart data={hourlyDistribution}>
              <CartesianGrid strokeDasharray="3 3" stroke="#f0ede8" />
              <XAxis dataKey="hour" tick={{ fontSize: 10, fill: "#6b6860" }} />
              <YAxis tick={{ fontSize: 10, fill: "#6b6860" }} />
              <Tooltip
                contentStyle={tooltipStyle}
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                formatter={(value: any) => [Number(value), "Transactions"]}
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                labelFormatter={(label: any) => `Hour ${label}:00`}
              />
              <Bar dataKey="count" fill="#e1b460" radius={[4, 4, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
        </div>

        {/* Day of Week */}
        <div style={chartBoxStyle}>
          <div style={chartTitleStyle}>Day of Week Revenue</div>
          <ResponsiveContainer width="100%" height={260}>
            <BarChart data={dayOfWeekRevenue}>
              <CartesianGrid strokeDasharray="3 3" stroke="#f0ede8" />
              <XAxis dataKey="day" tick={{ fontSize: 10, fill: "#6b6860" }} />
              <YAxis tick={{ fontSize: 10, fill: "#6b6860" }} />
              <Tooltip
                contentStyle={tooltipStyle}
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                formatter={(value: any) => [
                  `AED ${fmtAed(Number(value))}`,
                  "Revenue",
                ]}
              />
              <Bar dataKey="revenue" fill="#24544a" radius={[4, 4, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
        </div>
      </div>
    </>
  );
}

/* ------------------------------------------------------------------ */
/*  SITES & MACHINES TAB                                               */
/* ------------------------------------------------------------------ */

function SitesAndMachinesTab({
  sales,
  machineMap,
}: {
  sales: SaleRow[];
  machineMap: Record<string, MachineInfo>;
}) {
  // Group sales by venue_group
  const venueGroupData = useMemo(() => {
    const groups: Record<
      string,
      { revenue: number; txns: number; units: number; sales: SaleRow[] }
    > = {};

    sales.forEach((s) => {
      const groupName = machineMap[s.machine_id]?.group ?? "UNKNOWN";
      if (!groups[groupName])
        groups[groupName] = { revenue: 0, txns: 0, units: 0, sales: [] };
      groups[groupName].revenue += s.total_amount ?? 0;
      groups[groupName].txns++;
      groups[groupName].units += s.qty ?? 0;
      groups[groupName].sales.push(s);
    });

    return Object.entries(groups)
      .sort(([, a], [, b]) => b.revenue - a.revenue)
      .map(([name, data]) => ({ name, ...data }));
  }, [sales, machineMap]);

  return (
    <>
      {venueGroupData.map((grp) => {
        // Daily trend for this group
        const dailyMap: Record<string, number> = {};
        grp.sales.forEach((s) => {
          const day = s.transaction_date?.split("T")[0] ?? "";
          dailyMap[day] = (dailyMap[day] ?? 0) + (s.total_amount ?? 0);
        });
        const dailyData = Object.entries(dailyMap)
          .sort(([a], [b]) => a.localeCompare(b))
          .map(([date, revenue]) => ({
            date,
            revenue: Math.round(revenue * 100) / 100,
          }));

        // Machine breakdown
        const machineBreakdown: Record<string, number> = {};
        grp.sales.forEach((s) => {
          const name = machineMap[s.machine_id]?.name ?? s.machine_id;
          machineBreakdown[name] =
            (machineBreakdown[name] ?? 0) + (s.total_amount ?? 0);
        });
        const machineData = Object.entries(machineBreakdown)
          .sort(([, a], [, b]) => b - a)
          .map(([name, revenue]) => ({
            name,
            revenue: Math.round(revenue * 100) / 100,
          }));

        return (
          <div
            key={grp.name}
            style={{
              background: "white",
              border: "1px solid #e8e4de",
              borderRadius: 6,
              padding: "18px 20px",
              marginBottom: 16,
            }}
          >
            {/* Group header */}
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                alignItems: "center",
                marginBottom: 16,
              }}
            >
              <div>
                <h3
                  style={{
                    fontSize: 15,
                    fontWeight: 700,
                    color: "#0a0a0a",
                    margin: 0,
                    fontFamily: font,
                  }}
                >
                  {grp.name}
                </h3>
                <span style={{ fontSize: 11, color: "#6b6860" }}>
                  {grp.txns} txns &middot; {grp.units} units
                </span>
              </div>
              <span
                style={{
                  fontSize: 20,
                  fontWeight: 800,
                  color: "#24544a",
                  fontFamily: font,
                }}
              >
                AED {fmtAed(grp.revenue)}
              </span>
            </div>

            {/* Daily trend line chart */}
            <div style={{ marginBottom: 16 }}>
              <div
                style={{
                  fontSize: 11,
                  color: "#6b6860",
                  marginBottom: 8,
                }}
              >
                Daily Trend
              </div>
              <ResponsiveContainer width="100%" height={120}>
                <LineChart data={dailyData}>
                  <XAxis
                    dataKey="date"
                    tick={{ fontSize: 9, fill: "#6b6860" }}
                    tickFormatter={(v: string) => v.slice(5)}
                  />
                  <YAxis tick={{ fontSize: 9, fill: "#6b6860" }} width={50} />
                  <Tooltip
                    contentStyle={tooltipStyle}
                    // eslint-disable-next-line @typescript-eslint/no-explicit-any
                    formatter={(value: any) => [
                      `AED ${fmtAed(Number(value))}`,
                      "Revenue",
                    ]}
                  />
                  <Line
                    type="monotone"
                    dataKey="revenue"
                    stroke="#24544a"
                    strokeWidth={2}
                    dot={false}
                  />
                </LineChart>
              </ResponsiveContainer>
            </div>

            {/* Machine breakdown horizontal bars */}
            <div
              style={{
                fontSize: 11,
                color: "#6b6860",
                marginBottom: 8,
              }}
            >
              Machine Revenue
            </div>
            {machineData.map((m) => {
              const pct = grp.revenue > 0 ? (m.revenue / grp.revenue) * 100 : 0;
              return (
                <div
                  key={m.name}
                  style={{
                    display: "flex",
                    alignItems: "center",
                    gap: 10,
                    marginBottom: 6,
                  }}
                >
                  <span
                    style={{
                      fontSize: 11,
                      color: "#6b6860",
                      width: 180,
                      whiteSpace: "nowrap",
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      flexShrink: 0,
                    }}
                  >
                    {m.name}
                  </span>
                  <div
                    style={{
                      flex: 1,
                      height: 6,
                      background: "#e8e4de",
                      borderRadius: 2,
                      overflow: "hidden",
                    }}
                  >
                    <div
                      style={{
                        height: "100%",
                        borderRadius: 2,
                        background: "#24544a",
                        width: `${pct}%`,
                        transition: "width 0.8s ease",
                      }}
                    />
                  </div>
                  <span
                    style={{
                      fontSize: 11,
                      color: "#0a0a0a",
                      width: 80,
                      textAlign: "right",
                      fontWeight: 500,
                    }}
                  >
                    AED {fmtAed(m.revenue)}
                  </span>
                  <span
                    style={{
                      fontSize: 10,
                      color: "#6b6860",
                      width: 35,
                      textAlign: "right",
                    }}
                  >
                    {pct.toFixed(0)}%
                  </span>
                </div>
              );
            })}
          </div>
        );
      })}
    </>
  );
}

/* ------------------------------------------------------------------ */
/*  PRODUCTS TAB                                                       */
/* ------------------------------------------------------------------ */

function ProductsTab({
  data,
  totalRevenue,
}: {
  data: {
    product: string;
    units: number;
    revenue: number;
    txns: number;
    avgPrice: number;
  }[];
  totalRevenue: number;
}) {
  const productBubbles = data.map((p) => ({
    name: p.product,
    x: p.units,
    y: Math.round(p.avgPrice * 100) / 100,
    z: p.revenue,
  }));

  const topProducts = data.slice(0, 15).map((p) => ({
    product: p.product,
    revenue: Math.round(p.revenue * 100) / 100,
  }));

  return (
    <>
      {/* Volume vs Value bubble chart */}
      <div style={{ ...chartBoxStyle, marginBottom: 24 }}>
        <div style={chartTitleStyle}>Volume vs Value</div>
        <ResponsiveContainer width="100%" height={350}>
          <ScatterChart>
            <CartesianGrid strokeDasharray="3 3" stroke="#f0ede8" />
            <XAxis
              dataKey="x"
              name="Units"
              tick={{ fontSize: 10, fill: "#6b6860" }}
              label={{
                value: "Units Sold",
                position: "bottom",
                fontSize: 11,
                fill: "#6b6860",
              }}
            />
            <YAxis
              dataKey="y"
              name="Avg Price"
              tick={{ fontSize: 10, fill: "#6b6860" }}
              label={{
                value: "Avg Price (AED)",
                angle: -90,
                position: "left",
                fontSize: 11,
                fill: "#6b6860",
              }}
            />
            <ZAxis dataKey="z" range={[50, 400]} name="Revenue" />
            <Tooltip
              cursor={{ strokeDasharray: "3 3" }}
              contentStyle={tooltipStyle}
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              formatter={(value: any, name: any) => [
                name === "Revenue" ? `AED ${fmtAed(Number(value))}` : value,
                name,
              ]}
            />
            <Scatter data={productBubbles} fill="#24544a" fillOpacity={0.6}>
              {productBubbles.map((_, i) => (
                <Cell key={i} fill={i % 2 === 0 ? "#24544a" : "#e1b460"} />
              ))}
            </Scatter>
          </ScatterChart>
        </ResponsiveContainer>
      </div>

      {/* Revenue by Product horizontal bar chart */}
      <div style={{ ...chartBoxStyle, marginBottom: 24 }}>
        <div style={chartTitleStyle}>Revenue by Product (Top 15)</div>
        <ResponsiveContainer
          width="100%"
          height={Math.max(300, topProducts.length * 28)}
        >
          <BarChart data={topProducts} layout="vertical" margin={{ left: 150 }}>
            <CartesianGrid strokeDasharray="3 3" stroke="#f0ede8" />
            <XAxis type="number" tick={{ fontSize: 10, fill: "#6b6860" }} />
            <YAxis
              type="category"
              dataKey="product"
              tick={{ fontSize: 10, fill: "#6b6860" }}
              width={140}
            />
            <Tooltip
              contentStyle={tooltipStyle}
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              formatter={(value: any) => [
                `AED ${fmtAed(Number(value))}`,
                "Revenue",
              ]}
            />
            <Bar dataKey="revenue" fill="#24544a" radius={[0, 3, 3, 0]} />
          </BarChart>
        </ResponsiveContainer>
      </div>

      {/* Product detail table */}
      <div style={chartBoxStyle}>
        <div style={chartTitleStyle}>Product Detail</div>
        <div style={{ overflowX: "auto" }}>
          <table
            style={{
              width: "100%",
              borderCollapse: "collapse",
              minWidth: 650,
            }}
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
                  Share %
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
                    {totalRevenue > 0
                      ? ((row.revenue / totalRevenue) * 100).toFixed(1)
                      : "0.0"}
                    %
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
      </div>
    </>
  );
}

/* ------------------------------------------------------------------ */
/*  PAYMENTS TAB                                                       */
/* ------------------------------------------------------------------ */

function PaymentsTab({ adyenTxns }: { adyenTxns: AdyenTxn[] }) {
  const settled = useMemo(
    () => adyenTxns.filter((a) => a.status === "SettledBulk"),
    [adyenTxns],
  );

  const summaryCards = useMemo(() => {
    const totalCaptured = settled.reduce((s, a) => s + (a.value_aed ?? 0), 0);
    const totalCount = settled.length;
    const avg = totalCount > 0 ? totalCaptured / totalCount : 0;
    return { totalCaptured, totalCount, avg };
  }, [settled]);

  // Funding source breakdown
  const fundingBreakdown = useMemo(() => {
    const map: Record<string, number> = {};
    settled.forEach((a) => {
      const src = a.funding_source ?? "UNKNOWN";
      map[src] = (map[src] ?? 0) + (a.value_aed ?? 0);
    });
    const total = Object.values(map).reduce((s, v) => s + v, 0);
    return Object.entries(map)
      .sort(([, a], [, b]) => b - a)
      .map(([source, value]) => ({
        source,
        value: Math.round(value * 100) / 100,
        pct: total > 0 ? (value / total) * 100 : 0,
      }));
  }, [settled]);

  // Payment method breakdown
  const methodBreakdown = useMemo(() => {
    const map: Record<string, number> = {};
    settled.forEach((a) => {
      const method = a.payment_method ?? "unknown";
      map[method] = (map[method] ?? 0) + (a.value_aed ?? 0);
    });
    const total = Object.values(map).reduce((s, v) => s + v, 0);
    const methodLabels: Record<string, string> = {
      mc: "Mastercard",
      visa: "Visa",
      amex: "AMEX",
      maestro: "Maestro",
      cup: "UnionPay",
    };
    return Object.entries(map)
      .sort(([, a], [, b]) => b - a)
      .map(([method, value]) => ({
        method: methodLabels[method] ?? method,
        value: Math.round(value * 100) / 100,
        pct: total > 0 ? (value / total) * 100 : 0,
      }));
  }, [settled]);

  // Status breakdown
  const statusBreakdown = useMemo(() => {
    const map: Record<string, { count: number; total: number }> = {};
    adyenTxns.forEach((a) => {
      const status = a.status ?? "Unknown";
      if (!map[status]) map[status] = { count: 0, total: 0 };
      map[status].count++;
      map[status].total += a.value_aed ?? 0;
    });
    const grandTotal = Object.values(map).reduce((s, v) => s + v.total, 0);
    return Object.entries(map)
      .sort(([, a], [, b]) => b.total - a.total)
      .map(([status, d]) => ({
        status,
        count: d.count,
        total: Math.round(d.total * 100) / 100,
        pct: grandTotal > 0 ? (d.total / grandTotal) * 100 : 0,
      }));
  }, [adyenTxns]);

  const maxFundingValue = Math.max(...fundingBreakdown.map((f) => f.value), 1);
  const maxMethodValue = Math.max(...methodBreakdown.map((m) => m.value), 1);

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
        <div style={cardStyle}>
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
            TOTAL CAPTURED (AED)
          </div>
          <div
            style={{
              fontSize: 24,
              fontWeight: 800,
              color: "#0a0a0a",
              fontFamily: font,
            }}
          >
            AED {fmtAed(summaryCards.totalCaptured)}
          </div>
        </div>
        <div style={cardStyle}>
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
            TOTAL TRANSACTIONS
          </div>
          <div
            style={{
              fontSize: 24,
              fontWeight: 800,
              color: "#0a0a0a",
              fontFamily: font,
            }}
          >
            {summaryCards.totalCount.toLocaleString()}
          </div>
        </div>
        <div style={cardStyle}>
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
            AVG TRANSACTION
          </div>
          <div
            style={{
              fontSize: 24,
              fontWeight: 800,
              color: "#0a0a0a",
              fontFamily: font,
            }}
          >
            AED {fmtAed(summaryCards.avg)}
          </div>
        </div>
      </div>

      {/* Funding source breakdown */}
      <div style={{ ...chartBoxStyle, marginBottom: 24 }}>
        <div style={chartTitleStyle}>Funding Source Breakdown</div>
        {fundingBreakdown.map((f) => (
          <div
            key={f.source}
            style={{
              display: "flex",
              alignItems: "center",
              gap: 10,
              marginBottom: 8,
            }}
          >
            <span
              style={{
                fontSize: 12,
                color: "#6b6860",
                width: 100,
                flexShrink: 0,
                fontWeight: 500,
              }}
            >
              {f.source}
            </span>
            <div
              style={{
                flex: 1,
                height: 8,
                background: "#e8e4de",
                borderRadius: 3,
                overflow: "hidden",
              }}
            >
              <div
                style={{
                  height: "100%",
                  borderRadius: 3,
                  background: "#24544a",
                  width: `${(f.value / maxFundingValue) * 100}%`,
                  transition: "width 0.8s ease",
                }}
              />
            </div>
            <span
              style={{
                fontSize: 12,
                color: "#0a0a0a",
                width: 90,
                textAlign: "right",
                fontWeight: 600,
              }}
            >
              AED {fmtAed(f.value)}
            </span>
            <span
              style={{
                fontSize: 11,
                color: "#6b6860",
                width: 40,
                textAlign: "right",
              }}
            >
              {f.pct.toFixed(1)}%
            </span>
          </div>
        ))}
      </div>

      {/* Payment method breakdown */}
      <div style={{ ...chartBoxStyle, marginBottom: 24 }}>
        <div style={chartTitleStyle}>Payment Method Breakdown</div>
        {methodBreakdown.map((m) => (
          <div
            key={m.method}
            style={{
              display: "flex",
              alignItems: "center",
              gap: 10,
              marginBottom: 8,
            }}
          >
            <span
              style={{
                fontSize: 12,
                color: "#6b6860",
                width: 100,
                flexShrink: 0,
                fontWeight: 500,
              }}
            >
              {m.method}
            </span>
            <div
              style={{
                flex: 1,
                height: 8,
                background: "#e8e4de",
                borderRadius: 3,
                overflow: "hidden",
              }}
            >
              <div
                style={{
                  height: "100%",
                  borderRadius: 3,
                  background: "#e1b460",
                  width: `${(m.value / maxMethodValue) * 100}%`,
                  transition: "width 0.8s ease",
                }}
              />
            </div>
            <span
              style={{
                fontSize: 12,
                color: "#0a0a0a",
                width: 90,
                textAlign: "right",
                fontWeight: 600,
              }}
            >
              AED {fmtAed(m.value)}
            </span>
            <span
              style={{
                fontSize: 11,
                color: "#6b6860",
                width: 40,
                textAlign: "right",
              }}
            >
              {m.pct.toFixed(1)}%
            </span>
          </div>
        ))}
      </div>

      {/* Status breakdown table */}
      <div style={chartBoxStyle}>
        <div style={chartTitleStyle}>Status Breakdown</div>
        <div style={{ overflowX: "auto" }}>
          <table
            style={{
              width: "100%",
              borderCollapse: "collapse",
              minWidth: 500,
            }}
          >
            <thead>
              <tr>
                <th style={tableHeaderStyle}>Status</th>
                <th style={{ ...tableHeaderStyle, textAlign: "right" }}>
                  Count
                </th>
                <th style={{ ...tableHeaderStyle, textAlign: "right" }}>
                  Total AED
                </th>
                <th style={{ ...tableHeaderStyle, textAlign: "right" }}>
                  % of Total
                </th>
              </tr>
            </thead>
            <tbody>
              {statusBreakdown.map((row) => {
                const badge = statusBadgeColors[row.status] ?? {
                  bg: "#f5f2ee",
                  color: "#6b6860",
                };
                return (
                  <tr key={row.status}>
                    <td style={tableCellStyle}>
                      <span
                        style={{
                          fontSize: 11,
                          fontWeight: 600,
                          padding: "2px 8px",
                          borderRadius: 4,
                          background: badge.bg,
                          color: badge.color,
                        }}
                      >
                        {row.status}
                      </span>
                    </td>
                    <td
                      style={{
                        ...tableCellStyle,
                        textAlign: "right",
                      }}
                    >
                      {row.count.toLocaleString()}
                    </td>
                    <td
                      style={{
                        ...tableCellStyle,
                        textAlign: "right",
                        fontWeight: 600,
                      }}
                    >
                      {fmtAed(row.total)}
                    </td>
                    <td
                      style={{
                        ...tableCellStyle,
                        textAlign: "right",
                      }}
                    >
                      {row.pct.toFixed(1)}%
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}

/* ------------------------------------------------------------------ */
/*  TRANSACTIONS TAB                                                   */
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
          style={{
            width: "100%",
            borderCollapse: "collapse",
            minWidth: 700,
          }}
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
                          ? "#f0fdf4"
                          : "#fef2f2",
                      color:
                        txn.delivery_status === "Successful"
                          ? "#065f46"
                          : "#991b1b",
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
