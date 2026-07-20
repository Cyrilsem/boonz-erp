"use client";

// PRD-087 P4 — Product Performance: live, auto-updating replica of the
// Product Desk velocity catalogue (active-week basis, refunds excluded).
// Data: get_product_velocity_ledger(p_weeks, p_scope) — read-only RPC.

import { useState, useEffect, useMemo, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import { StatCard, Badge } from "@/components/ui/primitives";

const font = "'Plus Jakarta Sans', sans-serif";

type TopMachine = { machine: string; units: number };

type LedgerRow = {
  product_name: string;
  total_units: number;
  active_weeks: number;
  avg_per_week: number;
  machine_count: number;
  top_machines: TopMachine[];
  weekly_units: number[];
  week_start_dates: string[];
  current_week_units: number;
  first_sale_date: string;
  is_new: boolean;
};

const SCOPES: { value: string; label: string }[] = [
  { value: "non_vox", label: "Boonz Sourcing" },
  { value: "vox", label: "Partner Sourcing (VOX · LVLUP)" },
  { value: "all", label: "All machines" },
  { value: "AMAZON", label: "Amazon" },
  { value: "ADDMIND", label: "Addmind" },
  { value: "GRIT", label: "GRIT" },
  { value: "NOVO", label: "Novo" },
  { value: "OHMYDESK", label: "OhmyDesk" },
  { value: "VML", label: "VML" },
  { value: "WPP", label: "WPP" },
  { value: "INDEPENDENT", label: "Independent" },
];

const WEEK_OPTIONS = [4, 6, 8, 12];

// Editorial section breaks (rank quartiles, catalogue style)
const SECTIONS = [
  "The Heavy Rotation",
  "The Upper Middle",
  "The Lower Middle",
  "The Long Tail",
];

function shortMachine(name: string): string {
  const parts = name.split("-");
  return parts.length >= 2 ? `${parts[0]}-${parts[1]}` : name;
}

function weekLabel(iso: string): string {
  const d = new Date(iso + "T00:00:00");
  return `${d.getDate()}/${d.getMonth() + 1}`;
}

function mondayOf(iso: string): string {
  const d = new Date(iso + "T00:00:00");
  const day = (d.getDay() + 6) % 7; // Mon=0
  d.setDate(d.getDate() - day);
  return d.toISOString().slice(0, 10);
}

function Sparkline({ values, isNew }: { values: number[]; isNew: boolean }) {
  const w = 96;
  const h = 26;
  const max = Math.max(...values, 1);
  const step = values.length > 1 ? w / (values.length - 1) : w;
  const pts = values
    .map(
      (v, i) =>
        `${(i * step).toFixed(1)},${(h - 3 - (v / max) * (h - 6)).toFixed(1)}`,
    )
    .join(" ");
  return (
    <svg width={w} height={h} style={{ display: "block" }}>
      <polyline
        points={pts}
        fill="none"
        stroke={isNew ? "var(--gold)" : "var(--brand)"}
        strokeWidth={1.8}
        strokeLinejoin="round"
        strokeLinecap="round"
      />
    </svg>
  );
}

export default function ProductPerformanceTab() {
  // rows === null → loading (reset in the filter change handlers, not in the
  // effect, so the effect never calls setState synchronously).
  const [rowsOrNull, setRows] = useState<LedgerRow[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [scope, setScope] = useState("non_vox");
  const [weeks, setWeeks] = useState(6);
  const [level, setLevel] = useState<"pod" | "boonz">("pod");
  const [search, setSearch] = useState("");

  const loading = rowsOrNull === null;
  const rows = useMemo(() => rowsOrNull ?? [], [rowsOrNull]);

  useEffect(() => {
    let alive = true;
    const supabase = createClient();
    supabase
      .rpc("get_product_velocity_ledger", {
        p_weeks: weeks,
        p_scope: scope,
        p_level: level,
      })
      .then(({ data, error }) => {
        if (!alive) return;
        if (error) {
          setErr(error.message);
          setRows([]);
        } else {
          setErr(null);
          setRows(
            ((data as LedgerRow[]) || []).map((r) => ({
              ...r,
              total_units: Number(r.total_units),
              avg_per_week: Number(r.avg_per_week),
              machine_count: Number(r.machine_count),
              current_week_units: Number(r.current_week_units),
              weekly_units: (r.weekly_units || []).map(Number),
            })),
          );
        }
      });
    return () => {
      alive = false;
    };
  }, [scope, weeks, level]);

  const changeScope = (v: string) => {
    setScope(v);
    setRows(null);
  };
  const changeWeeks = (v: number) => {
    setWeeks(v);
    setRows(null);
  };
  const changeLevel = (v: "pod" | "boonz") => {
    setLevel(v);
    setRows(null);
  };

  const weekDates = useMemo(() => rows[0]?.week_start_dates ?? [], [rows]);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter(
      (r) =>
        r.product_name.toLowerCase().includes(q) ||
        (r.top_machines || []).some((t) => t.machine.toLowerCase().includes(q)),
    );
  }, [rows, search]);

  // Hero KPIs follow the ACTIVE FILTER (CS: filtering by product should
  // update the totals), so a search for "coca" shows coca-only volume.
  const hero = useMemo(() => {
    const total = filtered.reduce((a, r) => a + r.total_units, 0);
    const top = filtered[0];
    return {
      total,
      pace: weeks > 0 ? total / weeks : 0,
      skus: filtered.length,
      topName: top?.product_name ?? "—",
      topAvg: top?.avg_per_week ?? 0,
      topShare: total > 0 && top ? (top.total_units / total) * 100 : 0,
      isFiltered: filtered.length !== rows.length,
    };
  }, [filtered, rows.length, weeks]);

  // Section boundary indexes on the UNFILTERED ranking (quartiles)
  const sectionAt = useCallback(
    (rankIdx: number): string | null => {
      if (rows.length < 8) return null;
      const q = Math.ceil(rows.length / 4);
      if (rankIdx === 0) return SECTIONS[0];
      if (rankIdx === q) return SECTIONS[1];
      if (rankIdx === q * 2) return SECTIONS[2];
      if (rankIdx === q * 3) return SECTIONS[3];
      return null;
    },
    [rows.length],
  );

  const exportCsv = useCallback(() => {
    const head = [
      "rank",
      "product",
      "avg_per_week",
      "total_units",
      "active_weeks",
      "machines",
      ...weekDates.map(weekLabel),
      "this_week",
      "top_machines",
    ];
    const lines = rows.map((r, i) =>
      [
        i + 1,
        `"${r.product_name.replace(/"/g, '""')}"`,
        r.avg_per_week,
        r.total_units,
        r.active_weeks,
        r.machine_count,
        ...r.weekly_units,
        r.current_week_units,
        `"${(r.top_machines || [])
          .map((t) => `${shortMachine(t.machine)} ${t.units}`)
          .join(" · ")}"`,
      ].join(","),
    );
    const blob = new Blob([[head.join(","), ...lines].join("\n")], {
      type: "text/csv",
    });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `product_velocity_${level}_${scope}_${weeks}w.csv`;
    a.click();
    URL.revokeObjectURL(url);
  }, [rows, weekDates, scope, weeks, level]);

  const label = SCOPES.find((s) => s.value === scope)?.label ?? scope;

  return (
    <div style={{ fontFamily: font }}>
      {/* ── Controls ── */}
      <div
        style={{
          display: "flex",
          flexWrap: "wrap",
          gap: 10,
          alignItems: "center",
          marginBottom: 18,
        }}
      >
        {/* Level toggle — as-sold shelf names vs boonz products (mapping split) */}
        <div
          style={{
            display: "flex",
            border: "1px solid var(--line)",
            borderRadius: 8,
            overflow: "hidden",
          }}
        >
          {(
            [
              ["pod", "As sold"],
              ["boonz", "Boonz products"],
            ] as const
          ).map(([k, l]) => (
            <button
              key={k}
              onClick={() => changeLevel(k)}
              style={{
                padding: "7px 12px",
                fontSize: 12,
                fontWeight: level === k ? 700 : 500,
                background: level === k ? "var(--brand)" : "var(--surface)",
                color: level === k ? "white" : "var(--muted)",
                border: "none",
                cursor: "pointer",
                fontFamily: font,
              }}
            >
              {l}
            </button>
          ))}
        </div>
        <select
          value={scope}
          onChange={(e) => changeScope(e.target.value)}
          style={{
            padding: "7px 10px",
            fontSize: 13,
            border: "1px solid var(--line)",
            borderRadius: 8,
            background: "var(--surface)",
            fontFamily: font,
          }}
        >
          {SCOPES.map((s) => (
            <option key={s.value} value={s.value}>
              {s.label}
            </option>
          ))}
        </select>
        <select
          value={weeks}
          onChange={(e) => changeWeeks(Number(e.target.value))}
          style={{
            padding: "7px 10px",
            fontSize: 13,
            border: "1px solid var(--line)",
            borderRadius: 8,
            background: "var(--surface)",
            fontFamily: font,
          }}
        >
          {WEEK_OPTIONS.map((w) => (
            <option key={w} value={w}>
              Last {w} complete weeks
            </option>
          ))}
        </select>
        <input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search product or machine…"
          style={{
            padding: "7px 10px",
            fontSize: 13,
            border: "1px solid var(--line)",
            borderRadius: 8,
            minWidth: 220,
            fontFamily: font,
          }}
        />
        <div style={{ flex: 1 }} />
        <button
          onClick={exportCsv}
          disabled={rows.length === 0}
          style={{
            padding: "7px 14px",
            fontSize: 12,
            fontWeight: 600,
            border: "1px solid var(--line)",
            borderRadius: 8,
            background: "var(--surface)",
            cursor: "pointer",
            color: "var(--muted)",
            fontFamily: font,
          }}
        >
          ⇩ CSV
        </button>
      </div>

      {/* ── Hero band ── */}
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(160px, 1fr))",
          gap: 12,
          marginBottom: 20,
        }}
      >
        <StatCard
          label={hero.isFiltered ? "Units (filtered)" : "Total Units"}
          value={hero.total.toLocaleString()}
          sub={`${weeks} complete weeks · ${label}${hero.isFiltered ? ` · "${search.trim()}"` : ""}`}
        />
        <StatCard
          label={hero.isFiltered ? "Pace (filtered)" : "Fleet Pace"}
          value={Math.round(hero.pace).toLocaleString()}
          sub="units / week"
          accent="var(--gold)"
        />
        <StatCard
          label={hero.isFiltered ? "Matching SKUs" : "Active SKUs"}
          value={String(hero.skus)}
          sub={hero.isFiltered ? `of ${rows.length} active` : "sold ≥ 1 unit"}
          accent="var(--chart-5)"
        />
        <StatCard
          label="Top SKU"
          value={`${Math.round(hero.topAvg)}/wk`}
          sub={`${hero.topName} · ${hero.topShare.toFixed(1)}% of units`}
          accent="var(--chart-3)"
        />
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

      {/* ── Ledger ── */}
      <div
        style={{
          background: "var(--surface)",
          border: "1px solid var(--line)",
          borderRadius: 10,
          overflowX: "auto",
        }}
      >
        <table
          style={{ width: "100%", borderCollapse: "collapse", minWidth: 900 }}
        >
          <thead>
            <tr
              style={{
                borderBottom: "1px solid var(--line)",
                fontSize: 10,
                letterSpacing: "0.08em",
                color: "var(--muted)",
              }}
            >
              <th style={{ textAlign: "left", padding: "10px 8px 10px 16px" }}>
                #
              </th>
              <th style={{ textAlign: "left", padding: "10px 8px" }}>
                PRODUCT · TOP MACHINES (UNITS, {weeks}W)
              </th>
              {weekDates.map((d) => (
                <th
                  key={d}
                  style={{
                    textAlign: "right",
                    padding: "10px 6px",
                    fontVariantNumeric: "tabular-nums",
                  }}
                >
                  {weekLabel(d)}
                </th>
              ))}
              <th
                style={{
                  textAlign: "right",
                  padding: "10px 6px",
                  color: "var(--muted-2)",
                }}
              >
                THIS WK
              </th>
              <th style={{ textAlign: "center", padding: "10px 6px" }}>
                TREND
              </th>
              <th style={{ textAlign: "right", padding: "10px 16px 10px 6px" }}>
                AVG/WK
              </th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr>
                <td
                  colSpan={weekDates.length + 5}
                  style={{
                    padding: 40,
                    textAlign: "center",
                    color: "var(--muted-2)",
                    fontSize: 13,
                  }}
                >
                  Loading ledger…
                </td>
              </tr>
            ) : (
              filtered.map((r) => {
                const rank = rows.indexOf(r);
                const section = search.trim() ? null : sectionAt(rank);
                const launchWeek = mondayOf(r.first_sale_date);
                return (
                  <RowBlock
                    key={r.product_name}
                    r={r}
                    rank={rank}
                    section={section}
                    launchWeek={launchWeek}
                    colCount={weekDates.length + 5}
                  />
                );
              })
            )}
            {!loading && filtered.length === 0 && (
              <tr>
                <td
                  colSpan={weekDates.length + 5}
                  style={{
                    padding: 40,
                    textAlign: "center",
                    color: "var(--muted-2)",
                    fontSize: 13,
                  }}
                >
                  No products match.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <p style={{ fontSize: 11, color: "var(--muted-2)", margin: "10px 4px" }}>
        Units / active week · refunds &amp; failed deliveries excluded ·
        products launched mid-window carry a <Badge tone="gold">nW</Badge> badge
        and are averaged over their active weeks only; pre-launch weeks show as
        dots. Live from sales data — always current.
        {level === "boonz" && (
          <>
            {" "}
            <strong>Boonz-product view:</strong> mixed shelves (Chocolate Bar,
            Coca Cola Mix, Soft Drinks Mix, Krambals &amp; Zigi…) are split into
            their Boonz products using each machine&apos;s product-mapping
            ratios — modeled, since sales don&apos;t record the exact flavor
            picked.
          </>
        )}
      </p>
    </div>
  );
}

function RowBlock({
  r,
  rank,
  section,
  launchWeek,
  colCount,
}: {
  r: LedgerRow;
  rank: number;
  section: string | null;
  launchWeek: string;
  colCount: number;
}) {
  return (
    <>
      {section && (
        <tr>
          <td
            colSpan={colCount}
            style={{
              padding: "14px 16px 6px",
              fontSize: 11,
              fontWeight: 800,
              letterSpacing: "0.14em",
              color: "var(--brand)",
              borderBottom: "2px solid var(--brand)",
              textTransform: "uppercase",
            }}
          >
            {section}
          </td>
        </tr>
      )}
      <tr style={{ borderBottom: "1px solid var(--line)" }}>
        <td
          style={{
            padding: "10px 8px 10px 16px",
            fontSize: 18,
            fontWeight: 800,
            color: "var(--muted-2)",
            fontVariantNumeric: "tabular-nums",
            verticalAlign: "top",
            width: 42,
          }}
        >
          {String(rank + 1).padStart(2, "0")}
        </td>
        <td style={{ padding: "10px 8px", verticalAlign: "top" }}>
          <div style={{ fontSize: 13.5, fontWeight: 700, color: "var(--ink)" }}>
            {r.product_name}
            {r.is_new && (
              <span style={{ marginLeft: 6, verticalAlign: "middle" }}>
                <Badge tone="gold">{r.active_weeks}W</Badge>
              </span>
            )}
          </div>
          <div style={{ fontSize: 11, color: "var(--muted)", marginTop: 1 }}>
            {(r.top_machines || [])
              .map((t) => `${shortMachine(t.machine)} ${t.units}`)
              .join(" · ")}
            {r.machine_count > (r.top_machines || []).length &&
              ` · ${r.machine_count} MCH`}
          </div>
        </td>
        {r.weekly_units.map((u, i) => {
          const preLaunch = r.week_start_dates[i] < launchWeek;
          return (
            <td
              key={i}
              style={{
                textAlign: "right",
                padding: "10px 6px",
                fontSize: 12.5,
                color: preLaunch ? "var(--muted-2)" : "var(--foreground)",
                fontVariantNumeric: "tabular-nums",
              }}
            >
              {preLaunch ? "·" : u}
            </td>
          );
        })}
        <td
          style={{
            textAlign: "right",
            padding: "10px 6px",
            fontSize: 12.5,
            color: "var(--muted-2)",
            fontVariantNumeric: "tabular-nums",
          }}
        >
          {r.current_week_units}
        </td>
        <td style={{ padding: "6px 6px", textAlign: "center" }}>
          <Sparkline values={r.weekly_units} isNew={r.is_new} />
        </td>
        <td
          style={{
            textAlign: "right",
            padding: "10px 16px 10px 6px",
            fontSize: 14,
            fontWeight: 800,
            color: "var(--ink)",
            fontVariantNumeric: "tabular-nums",
          }}
        >
          {r.avg_per_week}
        </td>
      </tr>
    </>
  );
}
