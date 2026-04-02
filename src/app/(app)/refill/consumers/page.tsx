"use client";

import { useState, useEffect, useCallback, useMemo } from "react";
import {
  fetchVoxConsumerReport,
  aed,
  fmt,
  defaultRate,
  formatWallet,
  type VoxConsumerReport,
  type VoxPod,
} from "@/lib/vox-data";

type Tab = "overview" | "sites" | "products" | "payments" | "transactions";
type Pod = VoxPod;

// ── Small reusable pieces ─────────────────────────────────────────────────────

function KpiCard({
  label,
  value,
  sub,
  accent = false,
}: {
  label: string;
  value: string;
  sub?: string;
  accent?: boolean;
}) {
  return (
    <div
      className={`bg-white rounded-xl p-4 border shadow-sm ${
        accent ? "border-teal-200" : "border-gray-100"
      }`}
    >
      <p className="text-[10px] font-semibold text-gray-500 uppercase tracking-wider">
        {label}
      </p>
      <p
        className={`text-2xl font-bold mt-1 tabular-nums ${
          accent ? "text-teal-700" : "text-gray-900"
        }`}
      >
        {value}
      </p>
      {sub && <p className="text-[10px] text-gray-400 mt-0.5">{sub}</p>}
    </div>
  );
}

function Bar({
  value,
  max,
  color = "bg-teal-500",
}: {
  value: number;
  max: number;
  color?: string;
}) {
  const w = max > 0 ? Math.round((value / max) * 100) : 0;
  return (
    <div className="flex-1 bg-gray-100 rounded-full h-1.5">
      <div
        className={`${color} h-1.5 rounded-full transition-all`}
        style={{ width: `${w}%` }}
      />
    </div>
  );
}

function SectionCard({
  title,
  right,
  children,
}: {
  title: string;
  right?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden">
      <div className="px-5 py-4 border-b border-gray-100 flex items-center justify-between">
        <p className="text-[10px] font-semibold text-gray-500 uppercase tracking-wider">
          {title}
        </p>
        {right}
      </div>
      <div className="p-5">{children}</div>
    </div>
  );
}

function formatDateLabel(iso: string): string {
  // Parse as local date to avoid UTC-shift display issues
  const [y, m, d] = iso.split("-").map(Number);
  return new Date(y, m - 1, d).toLocaleDateString("en-AE", {
    day: "numeric",
    month: "short",
    year: "numeric",
  });
}

// ── Page ──────────────────────────────────────────────────────────────────────

export default function VoxConsumersPage() {
  const [pods, setPods] = useState<Pod[]>(["Mercato", "Mirdif"]);
  const [consolidated, setConsolidated] = useState(true);
  const [tab, setTab] = useState<Tab>("overview");
  const [data, setData] = useState<VoxConsumerReport | null>(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);
  const [startDate, setStartDate] = useState("2026-02-06");
  const [endDate, setEndDate] = useState(
    () => new Date().toISOString().split("T")[0],
  );

  // Preset ranges (computed once at mount)
  const presets = useMemo(() => {
    const d = new Date();
    const iso = (dt: Date) => dt.toISOString().split("T")[0];
    const ago = (n: number) => {
      const dt = new Date(d);
      dt.setDate(dt.getDate() - n);
      return iso(dt);
    };
    const todayIso = iso(d);
    return [
      { label: "Last 7d", start: ago(6), end: todayIso },
      { label: "Last 30d", start: ago(29), end: todayIso },
      {
        label: "This month",
        start: iso(new Date(d.getFullYear(), d.getMonth(), 1)),
        end: todayIso,
      },
      { label: "All time", start: "2026-02-06", end: todayIso },
    ];
  }, []);

  const todayStr = presets[3].end;

  const load = useCallback(async () => {
    if (pods.length === 0) return;
    setLoading(true);
    setErr(null);
    const result = await fetchVoxConsumerReport(
      pods,
      consolidated,
      startDate,
      endDate,
    );
    if (!result) setErr("Failed to load report. Check API connection.");
    else setData(result);
    setLoading(false);
  }, [pods, consolidated, startDate, endDate]);

  useEffect(() => {
    load();
  }, [load]);

  const togglePod = (pod: Pod) => {
    setPods((prev) =>
      prev.includes(pod)
        ? prev.length > 1
          ? prev.filter((p) => p !== pod)
          : prev
        : [...prev, pod],
    );
  };

  const s = data?.summary;
  const avgOrder = s && s.total_txns > 0 ? s.total_sales / s.total_txns : 0;

  // ── Aggregated chart data ─────────────────────────────────────────────────

  const { dailyAgg, maxDaily } = useMemo(() => {
    if (!data) return { dailyAgg: [] as [string, number][], maxDaily: 1 };
    const map = new Map<string, number>();
    for (const d of data.daily)
      map.set(d.date, (map.get(d.date) ?? 0) + d.amount);
    const sorted = Array.from(map.entries())
      .sort(([a], [b]) => a.localeCompare(b))
      .slice(-42);
    return {
      dailyAgg: sorted,
      maxDaily: Math.max(...sorted.map(([, v]) => v), 1),
    };
  }, [data]);

  const { hourlyAgg, maxHourly } = useMemo(() => {
    if (!data)
      return {
        hourlyAgg: [] as { hour: number; amount: number }[],
        maxHourly: 1,
      };
    const map = new Map<number, number>();
    for (const d of data.hourly)
      map.set(d.hour, (map.get(d.hour) ?? 0) + d.amount);
    const agg = Array.from({ length: 24 }, (_, h) => ({
      hour: h,
      amount: map.get(h) ?? 0,
    }));
    return {
      hourlyAgg: agg,
      maxHourly: Math.max(...agg.map((d) => d.amount), 1),
    };
  }, [data]);

  const { dowAgg, maxDow } = useMemo(() => {
    const labels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    if (!data)
      return { dowAgg: labels.map((dow) => ({ dow, amount: 0 })), maxDow: 1 };
    const map = new Map<number, number>();
    for (const d of data.dow)
      map.set(d.dow_n, (map.get(d.dow_n) ?? 0) + d.amount);
    const agg = labels.map((dow, i) => ({ dow, amount: map.get(i) ?? 0 }));
    return { dowAgg: agg, maxDow: Math.max(...agg.map((d) => d.amount), 1) };
  }, [data]);

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    <div className="min-h-full bg-gray-50">
      {/* ── Dark header ────────────────────────────────────────────────────── */}
      <div className="bg-zinc-900 text-white px-6 py-5">
        <div className="max-w-6xl mx-auto flex items-start justify-between gap-4 flex-wrap">
          <div>
            <h1 className="text-lg font-semibold tracking-tight">
              VOX Consumer Analytics
            </h1>
            <p className="text-xs text-zinc-400 mt-0.5">
              {s
                ? `${s.num_machines} machine${s.num_machines !== 1 ? "s" : ""} · ${formatDateLabel(startDate)} — ${formatDateLabel(endDate)}`
                : "Loading…"}
            </p>
          </div>

          <div className="flex items-center gap-2 flex-wrap">
            {/* Pod selector */}
            <div className="flex rounded-lg overflow-hidden border border-zinc-700">
              {(["Mercato", "Mirdif"] as Pod[]).map((pod) => (
                <button
                  key={pod}
                  onClick={() => togglePod(pod)}
                  className={`px-3 py-1.5 text-xs font-medium transition-colors ${
                    pods.includes(pod)
                      ? "bg-teal-600 text-white"
                      : "bg-zinc-800 text-zinc-400 hover:bg-zinc-700"
                  }`}
                >
                  {pod}
                </button>
              ))}
            </div>

            {/* Consolidated toggle */}
            <button
              onClick={() => setConsolidated((c) => !c)}
              className={`px-3 py-1.5 rounded-lg text-xs font-medium border transition-colors ${
                consolidated
                  ? "bg-zinc-700 text-white border-zinc-600"
                  : "bg-zinc-800 text-zinc-400 border-zinc-700 hover:bg-zinc-700"
              }`}
            >
              {consolidated ? "Consolidated" : "By Machine"}
            </button>

            <button
              onClick={load}
              disabled={loading}
              className="px-3 py-1.5 rounded-lg text-xs font-medium bg-zinc-800 text-zinc-400 border border-zinc-700 hover:bg-zinc-700 disabled:opacity-40 transition-colors"
            >
              {loading ? "…" : "↺ Refresh"}
            </button>
          </div>
        </div>
      </div>

      {/* ── Banners ─────────────────────────────────────────────────────────── */}
      {data && !s?.has_adyen_data && (
        <div className="bg-amber-50 border-b border-amber-200 px-6 py-2.5">
          <div className="max-w-6xl mx-auto text-xs text-amber-800">
            <strong>⚠️ Payment data not yet imported</strong> — revenue figures
            are Weimi POS only. Adyen fields show —.
          </div>
        </div>
      )}
      {data && s?.has_adyen_data && (s?.adyen_match_pct ?? 0) < 100 && (
        <div className="bg-sky-50 border-b border-sky-100 px-6 py-2.5">
          <div className="max-w-6xl mx-auto text-xs text-sky-700">
            ℹ️ Adyen match rate: <strong>{s?.adyen_match_pct ?? 0}%</strong> of
            transactions linked to payment data
          </div>
        </div>
      )}

      {/* ── Date range picker bar ───────────────────────────────────────────── */}
      <div className="border-b border-gray-200 bg-white px-6 py-3">
        <div className="max-w-6xl mx-auto flex flex-wrap items-center gap-3">
          {/* Preset buttons */}
          <div className="flex items-center gap-1.5 flex-wrap">
            {presets.map(({ label, start, end }) => (
              <button
                key={label}
                onClick={() => {
                  setStartDate(start);
                  setEndDate(end);
                }}
                className={`px-2.5 py-1 rounded text-xs font-medium transition-colors ${
                  startDate === start && endDate === end
                    ? "bg-teal-600 text-white"
                    : "bg-gray-50 border border-gray-200 text-gray-600 hover:bg-gray-100"
                }`}
              >
                {label}
              </button>
            ))}
          </div>

          {/* Date inputs */}
          <div className="flex items-center gap-2 text-xs">
            <span className="text-gray-400 shrink-0">From</span>
            <input
              type="date"
              value={startDate}
              min="2026-02-06"
              max={endDate}
              onChange={(e) => setStartDate(e.target.value)}
              className="border border-gray-200 rounded px-2 py-1 text-xs bg-white text-gray-700 focus:outline-none focus:ring-1 focus:ring-teal-500"
            />
            <span className="text-gray-400 shrink-0">To</span>
            <input
              type="date"
              value={endDate}
              min={startDate}
              max={todayStr}
              onChange={(e) => setEndDate(e.target.value)}
              className="border border-gray-200 rounded px-2 py-1 text-xs bg-white text-gray-700 focus:outline-none focus:ring-1 focus:ring-teal-500"
            />
          </div>

          {/* Current range label */}
          <span className="ml-auto text-[10px] text-gray-400 shrink-0">
            Showing: {formatDateLabel(startDate)} – {formatDateLabel(endDate)}
          </span>
        </div>
      </div>

      <div className="max-w-6xl mx-auto px-6 py-6">
        {/* ── Tab bar ──────────────────────────────────────────────────────── */}
        <div className="flex mb-6 border-b border-gray-200 overflow-x-auto">
          {(
            [
              ["overview", "Overview"],
              ["sites", "Sites & Machines"],
              ["products", "Products"],
              ["payments", "Payments"],
              ["transactions", "Transactions"],
            ] as [Tab, string][]
          ).map(([id, label]) => (
            <button
              key={id}
              onClick={() => setTab(id)}
              className={`px-4 py-2.5 text-sm font-medium whitespace-nowrap border-b-2 -mb-px transition-colors ${
                tab === id
                  ? "text-teal-700 border-teal-600"
                  : "text-gray-500 border-transparent hover:text-gray-700 hover:border-gray-300"
              }`}
            >
              {label}
            </button>
          ))}
        </div>

        {/* ── Loading / Error ───────────────────────────────────────────────── */}
        {loading && (
          <div className="flex items-center justify-center py-20 text-sm text-gray-400">
            Loading VOX consumer data…
          </div>
        )}
        {err && !loading && (
          <div className="bg-red-50 border border-red-200 rounded-xl px-5 py-4 text-sm text-red-700">
            {err}
          </div>
        )}

        {/* ── Tab content ──────────────────────────────────────────────────── */}
        {!loading && !err && data && s && (
          <>
            {/* ══════════════════════════ OVERVIEW ══════════════════════════ */}
            {tab === "overview" && (
              <div className="space-y-5">
                {/* Date range confirmation */}
                {s.date_range && (
                  <p className="text-xs text-gray-400">
                    <span className="font-medium text-gray-600">
                      {formatDateLabel(s.date_range.start)}
                    </span>
                    {" — "}
                    <span className="font-medium text-gray-600">
                      {formatDateLabel(s.date_range.end)}
                    </span>
                    {" · "}
                    {s.num_machines} machine
                    {s.num_machines !== 1 ? "s" : ""}
                  </p>
                )}

                {/* Primary KPIs */}
                <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
                  <KpiCard
                    label="Total Revenue"
                    value={aed(s.total_sales)}
                    sub="Weimi POS"
                    accent
                  />
                  <KpiCard label="Transactions" value={fmt(s.total_txns)} />
                  <KpiCard label="Units Sold" value={fmt(s.total_units)} />
                  <KpiCard
                    label="Avg Order"
                    value={aed(avgOrder, 1)}
                    sub={`across ${fmt(s.total_txns)} txns`}
                  />
                </div>

                {/* Adyen KPIs (only when available) */}
                {s.has_adyen_data && (
                  <div className="grid grid-cols-2 sm:grid-cols-3 gap-4">
                    <KpiCard
                      label="Captured (Adyen)"
                      value={aed(s.total_captured)}
                      sub="Adyen settled amount"
                    />
                    <KpiCard
                      label="Default Rate"
                      value={defaultRate(s.total_sales, s.total_captured)}
                      sub="(sales − captured) / sales"
                    />
                    <KpiCard
                      label="Adyen Match"
                      value={`${s.adyen_match_pct}%`}
                      sub="transactions matched"
                    />
                  </div>
                )}

                {/* Daily revenue bar chart */}
                {dailyAgg.length > 0 && (
                  <SectionCard title="Daily Revenue">
                    <div className="flex items-end gap-0.5 h-28 mb-2">
                      {dailyAgg.map(([date, amount]) => {
                        const h = Math.max(
                          Math.round((amount / maxDaily) * 100),
                          amount > 0 ? 2 : 0,
                        );
                        return (
                          <div
                            key={date}
                            className="flex-1 flex flex-col justify-end"
                            title={`${date.slice(5)}: ${aed(amount, 0)}`}
                          >
                            <div
                              className="w-full rounded-t bg-teal-500 hover:bg-teal-400 transition-colors cursor-default"
                              style={{ height: `${h}%` }}
                            />
                          </div>
                        );
                      })}
                    </div>
                    <div className="flex justify-between text-[10px] text-gray-400">
                      <span>{dailyAgg[0]?.[0]?.slice(5) ?? ""}</span>
                      <span className="text-gray-300">
                        {dailyAgg.length} days
                      </span>
                      <span>
                        {dailyAgg[dailyAgg.length - 1]?.[0]?.slice(5) ?? ""}
                      </span>
                    </div>
                  </SectionCard>
                )}

                {/* Hourly + DoW side by side */}
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <SectionCard title="Peak Hours">
                    <div className="flex items-end gap-0.5 h-16 mb-1">
                      {hourlyAgg.map(({ hour, amount }) => {
                        const h = Math.max(
                          Math.round((amount / maxHourly) * 100),
                          amount > 0 ? 3 : 0,
                        );
                        return (
                          <div
                            key={hour}
                            className="flex-1 flex flex-col justify-end"
                            title={`${hour}:00 — ${aed(amount, 0)}`}
                          >
                            <div
                              className={`w-full rounded-t ${amount > 0 ? "bg-teal-400 hover:bg-teal-300" : "bg-gray-100"} transition-colors cursor-default`}
                              style={{
                                height: `${Math.max(h, amount > 0 ? 6 : 0)}%`,
                              }}
                            />
                          </div>
                        );
                      })}
                    </div>
                    <div className="flex justify-between text-[10px] text-gray-400">
                      <span>00:00</span>
                      <span>23:00</span>
                    </div>
                  </SectionCard>

                  <SectionCard title="Day of Week">
                    <div className="space-y-2.5">
                      {dowAgg.map(({ dow, amount }) => (
                        <div key={dow} className="flex items-center gap-3">
                          <span className="text-xs text-gray-500 w-7 shrink-0 font-medium">
                            {dow}
                          </span>
                          <Bar value={amount} max={maxDow} />
                          <span className="text-xs tabular-nums text-gray-600 w-20 text-right shrink-0">
                            {aed(amount, 0)}
                          </span>
                        </div>
                      ))}
                    </div>
                  </SectionCard>
                </div>

                {/* Site split (only when both selected) */}
                {pods.length === 2 && (
                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    {[
                      {
                        label: "Mercato",
                        site: s.mercato,
                        accent: "text-violet-700",
                      },
                      {
                        label: "Mirdif",
                        site: s.mirdif,
                        accent: "text-blue-700",
                      },
                    ].map(({ label, site, accent }) => (
                      <div
                        key={label}
                        className="bg-white rounded-xl border border-gray-100 shadow-sm p-5"
                      >
                        <p className={`text-sm font-semibold mb-3 ${accent}`}>
                          {label}
                        </p>
                        <div className="grid grid-cols-2 gap-3">
                          {[
                            ["Revenue", aed(site.total, 0)],
                            ["Transactions", fmt(site.txns)],
                            ["Units", fmt(site.units)],
                            [
                              "Avg Order",
                              site.txns > 0
                                ? aed(site.total / site.txns, 1)
                                : "—",
                            ],
                          ].map(([lbl, val]) => (
                            <div key={lbl}>
                              <p className="text-[10px] text-gray-500 uppercase tracking-wide font-medium">
                                {lbl}
                              </p>
                              <p className="text-xl font-bold text-gray-900 tabular-nums mt-0.5">
                                {val}
                              </p>
                            </div>
                          ))}
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            )}

            {/* ══════════════════════ SITES & MACHINES ══════════════════════ */}
            {tab === "sites" && (
              <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden">
                <div className="px-5 py-4 border-b border-gray-100 flex items-center justify-between">
                  <p className="text-[10px] font-semibold text-gray-500 uppercase tracking-wider">
                    {consolidated ? "Revenue by Site" : "Revenue by Machine"}
                  </p>
                  <span className="text-xs text-gray-400">
                    {consolidated
                      ? `${pods.length} site${pods.length !== 1 ? "s" : ""}`
                      : `${data.machines.length} machine${data.machines.length !== 1 ? "s" : ""}`}
                  </span>
                </div>
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="bg-gray-50 text-gray-500 text-[10px] uppercase tracking-wider">
                        <th className="px-5 py-3 text-left font-medium">
                          {consolidated ? "Site" : "Machine"}
                        </th>
                        {!consolidated && (
                          <th className="px-5 py-3 text-left font-medium">
                            Site
                          </th>
                        )}
                        <th className="px-5 py-3 text-right font-medium">
                          Revenue
                        </th>
                        <th className="px-5 py-3 text-right font-medium">
                          Share
                        </th>
                        <th className="px-5 py-3 w-36" />
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-gray-50">
                      {(() => {
                        const rows = consolidated
                          ? Object.entries(
                              data.machines.reduce<Record<string, number>>(
                                (acc, m) => {
                                  acc[m.site] = (acc[m.site] ?? 0) + m.amount;
                                  return acc;
                                },
                                {},
                              ),
                            )
                              .map(([site, amount]) => ({
                                label: site,
                                site,
                                amount,
                              }))
                              .sort((a, b) => b.amount - a.amount)
                          : [...data.machines]
                              .sort((a, b) => b.amount - a.amount)
                              .map((m) => ({
                                label: m.machine,
                                site: m.site,
                                amount: m.amount,
                              }));

                        const total = rows.reduce(
                          (acc, r) => acc + r.amount,
                          0,
                        );
                        const maxAmt = Math.max(
                          ...rows.map((r) => r.amount),
                          1,
                        );

                        return rows.map((row) => (
                          <tr key={row.label} className="hover:bg-gray-50">
                            <td className="px-5 py-3 font-medium text-gray-900 tabular-nums">
                              {row.label}
                            </td>
                            {!consolidated && (
                              <td className="px-5 py-3 text-xs text-gray-400">
                                {row.site}
                              </td>
                            )}
                            <td className="px-5 py-3 text-right tabular-nums font-medium text-gray-900">
                              {aed(row.amount, 0)}
                            </td>
                            <td className="px-5 py-3 text-right tabular-nums text-gray-500 text-xs">
                              {total > 0
                                ? `${((row.amount / total) * 100).toFixed(1)}%`
                                : "—"}
                            </td>
                            <td className="px-5 py-3">
                              <Bar value={row.amount} max={maxAmt} />
                            </td>
                          </tr>
                        ));
                      })()}
                    </tbody>
                  </table>
                </div>
              </div>
            )}

            {/* ════════════════════════ PRODUCTS ════════════════════════════ */}
            {tab === "products" && (
              <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden">
                <div className="px-5 py-4 border-b border-gray-100 flex items-center justify-between">
                  <p className="text-[10px] font-semibold text-gray-500 uppercase tracking-wider">
                    Top Products by Revenue
                  </p>
                  <span className="text-xs text-gray-400">
                    {data.products.length} products
                  </span>
                </div>
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="bg-gray-50 text-gray-500 text-[10px] uppercase tracking-wider">
                        <th className="px-5 py-3 text-left font-medium w-8">
                          #
                        </th>
                        <th className="px-5 py-3 text-left font-medium">
                          Product
                        </th>
                        <th className="px-5 py-3 text-left font-medium">
                          Site
                        </th>
                        <th className="px-5 py-3 text-right font-medium">
                          Revenue
                        </th>
                        <th className="px-5 py-3 text-right font-medium">
                          Units
                        </th>
                        <th className="px-5 py-3 text-right font-medium">
                          Avg
                        </th>
                        <th className="px-5 py-3 w-36" />
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-gray-50">
                      {data.products.slice(0, 30).map((p, i) => {
                        const maxRev = data.products[0]?.revenue ?? 1;
                        const avgPrice = p.qty > 0 ? p.revenue / p.qty : 0;
                        return (
                          <tr
                            key={`${p.site}-${p.name}`}
                            className="hover:bg-gray-50"
                          >
                            <td className="px-5 py-2.5 text-gray-400 text-xs">
                              {i + 1}
                            </td>
                            <td className="px-5 py-2.5 font-medium text-gray-900 max-w-[200px] truncate">
                              {p.name}
                            </td>
                            <td className="px-5 py-2.5 text-xs text-gray-400">
                              {p.site}
                            </td>
                            <td className="px-5 py-2.5 text-right tabular-nums font-medium text-gray-900">
                              {aed(p.revenue, 0)}
                            </td>
                            <td className="px-5 py-2.5 text-right tabular-nums text-gray-500">
                              {fmt(p.qty)}
                            </td>
                            <td className="px-5 py-2.5 text-right tabular-nums text-gray-400 text-xs">
                              {aed(avgPrice, 1)}
                            </td>
                            <td className="px-5 py-2.5">
                              <Bar value={p.revenue} max={maxRev} />
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              </div>
            )}

            {/* ════════════════════════ PAYMENTS ════════════════════════════ */}
            {tab === "payments" && (
              <div className="space-y-5">
                {!s.has_adyen_data ? (
                  <div className="bg-amber-50 border border-amber-200 rounded-xl px-6 py-10 text-center">
                    <p className="text-3xl mb-3">⚠️</p>
                    <p className="font-semibold text-amber-900 text-base">
                      Adyen data not yet imported
                    </p>
                    <p className="text-sm text-amber-700 mt-1.5 max-w-sm mx-auto">
                      Payment breakdown (funding type, card brands, digital
                      wallets) will appear here once Adyen transaction data is
                      loaded into Supabase.
                    </p>
                  </div>
                ) : (
                  <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
                    {/* Funding sources */}
                    <SectionCard title="Funding Type">
                      <div className="space-y-3">
                        {data.funding.length === 0 ? (
                          <p className="text-sm text-gray-400">No data</p>
                        ) : (
                          (() => {
                            const maxF = Math.max(
                              ...data.funding.map((f) => f.sum),
                              1,
                            );
                            return data.funding.map((f) => (
                              <div key={`${f.site}-${f.source}`}>
                                <div className="flex justify-between text-xs mb-1">
                                  <span className="text-gray-600 capitalize">
                                    {f.source}
                                    <span className="text-gray-400 ml-1">
                                      · {f.site}
                                    </span>
                                  </span>
                                  <span className="tabular-nums font-medium text-gray-900">
                                    {aed(f.sum, 0)}
                                  </span>
                                </div>
                                <Bar
                                  value={f.sum}
                                  max={maxF}
                                  color="bg-violet-500"
                                />
                              </div>
                            ));
                          })()
                        )}
                      </div>
                    </SectionCard>

                    {/* Card brands */}
                    <SectionCard title="Card Brands">
                      <div className="space-y-3">
                        {data.cards.length === 0 ? (
                          <p className="text-sm text-gray-400">No data</p>
                        ) : (
                          (() => {
                            const maxC = Math.max(
                              ...data.cards.map((c) => c.sum),
                              1,
                            );
                            return data.cards.map((c) => (
                              <div key={`${c.site}-${c.method}`}>
                                <div className="flex justify-between text-xs mb-1">
                                  <span className="text-gray-600 capitalize">
                                    {c.method}
                                    <span className="text-gray-400 ml-1">
                                      · {c.site}
                                    </span>
                                  </span>
                                  <span className="tabular-nums font-medium text-gray-900">
                                    {fmt(c.count)}
                                  </span>
                                </div>
                                <Bar
                                  value={c.sum}
                                  max={maxC}
                                  color="bg-blue-500"
                                />
                              </div>
                            ));
                          })()
                        )}
                      </div>
                    </SectionCard>

                    {/* Digital wallets */}
                    <SectionCard title="Digital Wallets">
                      <div className="space-y-3">
                        {data.wallets.length === 0 ? (
                          <p className="text-sm text-gray-400">
                            No wallet data
                          </p>
                        ) : (
                          (() => {
                            const maxW = Math.max(
                              ...data.wallets.map((w) => w.sum),
                              1,
                            );
                            return data.wallets.map((w) => (
                              <div key={w.variant}>
                                <div className="flex justify-between text-xs mb-1">
                                  <span className="text-gray-600">
                                    {formatWallet(w.variant)}
                                  </span>
                                  <span className="tabular-nums font-medium text-gray-900">
                                    {fmt(w.count)}
                                  </span>
                                </div>
                                <Bar
                                  value={w.sum}
                                  max={maxW}
                                  color="bg-emerald-500"
                                />
                              </div>
                            ));
                          })()
                        )}
                      </div>
                    </SectionCard>
                  </div>
                )}
              </div>
            )}

            {/* ══════════════════════ TRANSACTIONS ══════════════════════════ */}
            {tab === "transactions" && (
              <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden">
                <div className="px-5 py-4 border-b border-gray-100 flex items-center justify-between">
                  <p className="text-[10px] font-semibold text-gray-500 uppercase tracking-wider">
                    Transaction Ledger
                  </p>
                  <div className="flex items-center gap-3">
                    {data.transactions.some((t) => t.disc) && (
                      <span className="text-[10px] text-amber-600 font-medium">
                        ⚠️ discrepancies highlighted
                      </span>
                    )}
                    <span className="text-xs text-gray-400">
                      Last {data.transactions.length}
                    </span>
                  </div>
                </div>
                <div className="overflow-x-auto">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="bg-gray-50 text-gray-500 text-[10px] uppercase tracking-wider">
                        <th className="px-4 py-3 text-left font-medium">
                          Date
                        </th>
                        <th className="px-4 py-3 text-left font-medium">
                          Time
                        </th>
                        <th className="px-4 py-3 text-left font-medium">
                          Machine
                        </th>
                        <th className="px-4 py-3 text-left font-medium">
                          Site
                        </th>
                        <th className="px-4 py-3 text-left font-medium">PSP</th>
                        <th className="px-4 py-3 text-left font-medium">
                          Funding
                        </th>
                        <th className="px-4 py-3 text-left font-medium">
                          Card
                        </th>
                        <th className="px-4 py-3 text-left font-medium">
                          Wallet
                        </th>
                        <th className="px-4 py-3 text-right font-medium">
                          Total
                        </th>
                        <th className="px-4 py-3 text-right font-medium">
                          Captured
                        </th>
                        <th className="px-4 py-3 text-right font-medium">
                          Units
                        </th>
                        <th className="px-4 py-3 text-left font-medium">
                          Items
                        </th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-gray-50">
                      {data.transactions.map((t, i) => (
                        <tr
                          key={i}
                          className={
                            t.disc
                              ? "bg-amber-50 border-l-2 border-amber-400"
                              : "hover:bg-gray-50"
                          }
                        >
                          <td className="px-4 py-2 text-gray-600 tabular-nums whitespace-nowrap">
                            {t.date}
                          </td>
                          <td className="px-4 py-2 text-gray-500 tabular-nums">
                            {t.time}
                          </td>
                          <td className="px-4 py-2 font-medium text-gray-900 tabular-nums whitespace-nowrap">
                            {t.machine}
                          </td>
                          <td className="px-4 py-2 text-gray-400">{t.site}</td>
                          <td className="px-4 py-2 text-gray-400 tabular-nums">
                            {t.psp}
                          </td>
                          <td className="px-4 py-2 text-gray-500 capitalize">
                            {t.funding}
                          </td>
                          <td className="px-4 py-2 text-gray-500 capitalize">
                            {t.card}
                          </td>
                          <td className="px-4 py-2 text-gray-500 whitespace-nowrap">
                            {t.wallet}
                          </td>
                          <td className="px-4 py-2 text-right tabular-nums font-medium text-gray-900 whitespace-nowrap">
                            {aed(t.total, 2)}
                          </td>
                          <td
                            className={`px-4 py-2 text-right tabular-nums whitespace-nowrap ${
                              t.disc
                                ? "text-amber-700 font-semibold"
                                : "text-gray-500"
                            }`}
                          >
                            {t.captured > 0 ? aed(t.captured, 2) : "—"}
                          </td>
                          <td className="px-4 py-2 text-right tabular-nums text-gray-500">
                            {t.units}
                          </td>
                          <td className="px-4 py-2 text-gray-400 max-w-[180px] truncate">
                            {t.items}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}
