"use client";

// PRD-087 — the command-center dashboard. One aggregate RPC
// (get_dashboard_summary, server-prefetched) + a client-side top-machines
// block with a 1/7/30-day lookback (get_sales_by_machine).

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { PageHeader, StatCard, Badge, SectionHeading } from "@/components/ui/primitives";

const font = "'Plus Jakarta Sans', sans-serif";

/* ── types ─────────────────────────────────────────────────────────────── */

type KpiBlock = { revenue: number; units: number; txns: number; margin: number };

export type DashboardSummary = {
  generated_at: string;
  today: string;
  kpis: {
    today: KpiBlock;
    d7: KpiBlock;
    d30: KpiBlock;
    daily: { d: string; revenue: number; units: number }[];
  };
  refill_today: {
    machines: number;
    lines: number;
    packed: number;
    dispatched: number;
    not_filled: number;
    skipped: number;
  };
  health: {
    p1_count: number;
    p2_count: number;
    top_urgent: { machine: string; tier: string; score: number }[];
  };
  inventory: {
    machine_units: number;
    wh_units: number;
    products: number;
    thin_count: number;
    thin_top: { product: string; machine_units: number; wh_units: number }[];
  };
  expiring: { product: string; units: number; days: number }[];
  procurement: {
    open_pos: number;
    open_lines: number;
    open_units: number;
    open_value: number;
  };
  hot_leads: {
    company: string;
    stage: string;
    machines: number | null;
    owner: string | null;
    follow_up: string | null;
  }[];
  driver_requests: { pending: number };
  fleet: { active_machines: number; trading_machines: number; products: number };
};

type TopMachineRow = {
  machine_name: string;
  machine_id: string;
  txn_count: number;
  total_revenue: number;
  total_units: number;
  total_cost: number;
  last_sale: string | null;
};

type Period = "today" | "d7" | "d30";
const PERIODS: { key: Period; label: string }[] = [
  { key: "today", label: "Today" },
  { key: "d7", label: "7 days" },
  { key: "d30", label: "30 days" },
];

const fmtAed = (n: number) => `${Math.round(n).toLocaleString()} AED`;
const short = (name: string) => {
  const p = name.split("-");
  return p.length >= 2 ? `${p[0]}-${p[1]}` : name;
};

/* ── panels chrome ─────────────────────────────────────────────────────── */

function Panel({
  title,
  link,
  linkLabel,
  children,
  badge,
}: {
  title: string;
  link?: string;
  linkLabel?: string;
  badge?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <div
      style={{
        background: "var(--surface)",
        border: "1px solid var(--line)",
        borderRadius: 10,
        padding: "14px 16px",
        display: "flex",
        flexDirection: "column",
        minWidth: 0,
      }}
    >
      <div className="flex items-center gap-2 mb-3">
        <span
          style={{
            fontSize: 11,
            fontWeight: 800,
            letterSpacing: "0.1em",
            textTransform: "uppercase",
            color: "var(--muted)",
          }}
        >
          {title}
        </span>
        {badge}
        <div style={{ flex: 1 }} />
        {link && (
          <Link
            href={link}
            style={{ fontSize: 11, fontWeight: 700, color: "var(--brand)" }}
          >
            {linkLabel ?? "Open →"}
          </Link>
        )}
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>{children}</div>
    </div>
  );
}

/* ── revenue spark (30d bars) ──────────────────────────────────────────── */

function RevenueBars({ daily }: { daily: DashboardSummary["kpis"]["daily"] }) {
  const w = 900;
  const h = 88;
  const max = Math.max(...daily.map((x) => x.revenue), 1);
  const bw = w / daily.length;
  return (
    <svg
      viewBox={`0 0 ${w} ${h + 16}`}
      style={{ width: "100%", height: 104, display: "block" }}
      preserveAspectRatio="none"
    >
      {daily.map((x, i) => {
        const bh = (x.revenue / max) * h;
        const isToday = i === daily.length - 1;
        return (
          <g key={x.d}>
            <rect
              x={i * bw + 1.5}
              y={h - bh}
              width={bw - 3}
              height={Math.max(bh, 1)}
              rx={2}
              fill={isToday ? "var(--gold)" : "var(--brand)"}
              opacity={isToday ? 1 : 0.55 + 0.45 * (x.revenue / max)}
            >
              <title>{`${x.d} · ${x.revenue.toLocaleString()} AED · ${x.units} units`}</title>
            </rect>
          </g>
        );
      })}
    </svg>
  );
}

/* ── component ─────────────────────────────────────────────────────────── */

export default function DashboardClient({
  summary,
  initialTopMachines,
}: {
  summary: DashboardSummary;
  initialTopMachines: TopMachineRow[];
}) {
  const [period, setPeriod] = useState<Period>("today");
  const [lookback, setLookback] = useState(7);
  const [topRows, setTopRows] = useState<TopMachineRow[]>(initialTopMachines);
  const [topLoading, setTopLoading] = useState(false);

  // top machines lookback toggle (1 / 7 / 30 days)
  useEffect(() => {
    if (lookback === 7 && topRows === initialTopMachines) return; // initial data
    let alive = true;
    const supabase = createClient();
    supabase
      .rpc("get_sales_by_machine", { lookback_days: lookback })
      .limit(10000)
      .then(({ data }) => {
        if (!alive) return;
        setTopRows(((data as TopMachineRow[]) ?? []).slice(0, 10));
        setTopLoading(false);
      });
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lookback]);

  const k = summary.kpis[period];
  const rt = summary.refill_today;
  const fillable = Math.max(rt.lines - rt.not_filled - rt.skipped, 0);
  const donePct =
    fillable > 0 ? Math.min((rt.dispatched / fillable) * 100, 100) : 0;

  const inv = summary.inventory;
  const invTotal = inv.machine_units + inv.wh_units;
  const top10 = useMemo(() => topRows.slice(0, 10), [topRows]);
  const maxRev = Math.max(...top10.map((r) => Number(r.total_revenue)), 1);

  return (
    <div className="p-8 max-w-7xl" style={{ fontFamily: font }}>
      <PageHeader
        title="Dashboard"
        subtitle={`${new Date(summary.today + "T00:00:00").toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long", year: "numeric" })} · ${summary.fleet.trading_machines} machines trading · ${summary.fleet.products} products`}
        actions={
          <div
            style={{
              display: "flex",
              border: "1px solid var(--line)",
              borderRadius: 8,
              overflow: "hidden",
            }}
          >
            {PERIODS.map((p) => (
              <button
                key={p.key}
                onClick={() => setPeriod(p.key)}
                style={{
                  padding: "8px 14px",
                  fontSize: 12,
                  fontWeight: period === p.key ? 700 : 500,
                  background: period === p.key ? "var(--brand)" : "var(--surface)",
                  color: period === p.key ? "white" : "var(--muted)",
                  border: "none",
                  cursor: "pointer",
                  fontFamily: font,
                }}
              >
                {p.label}
              </button>
            ))}
          </div>
        }
      />

      {/* ── KPI band ── */}
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))",
          gap: 12,
          marginBottom: 14,
        }}
      >
        <StatCard label="Revenue" value={fmtAed(k.revenue)} sub={PERIODS.find((p) => p.key === period)?.label} />
        <StatCard label="Units Sold" value={k.units.toLocaleString()} sub={`${k.txns.toLocaleString()} transactions`} accent="var(--gold)" />
        <StatCard label="Gross Margin" value={fmtAed(k.margin)} sub={k.revenue > 0 ? `${((k.margin / k.revenue) * 100).toFixed(0)}% of revenue` : "—"} accent="var(--chart-5)" />
        <StatCard
          label="Refill Today"
          value={`${rt.dispatched}/${fillable}`}
          sub={`${rt.machines} machines on route`}
          accent="var(--chart-3)"
        />
        <StatCard
          label="Needs Attention"
          value={String(summary.health.p1_count)}
          sub="P1 machines right now"
          accent="var(--danger)"
          valueColor={summary.health.p1_count > 0 ? "var(--danger)" : "var(--ink)"}
        />
      </div>

      {/* ── 30d revenue rhythm ── */}
      <div
        style={{
          background: "var(--surface)",
          border: "1px solid var(--line)",
          borderRadius: 10,
          padding: "12px 16px 4px",
          marginBottom: 14,
        }}
      >
        <div className="flex items-center gap-2">
          <span style={{ fontSize: 11, fontWeight: 800, letterSpacing: "0.1em", textTransform: "uppercase", color: "var(--muted)" }}>
            Revenue — last 30 days
          </span>
          <span style={{ fontSize: 11, color: "var(--muted-2)" }}>
            {fmtAed(summary.kpis.d30.revenue)} total · gold bar = today
          </span>
        </div>
        <RevenueBars daily={summary.kpis.daily} />
      </div>

      {/* ── panel grid ── */}
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(320px, 1fr))",
          gap: 14,
        }}
      >
        {/* Refill today */}
        <Panel
          title="Refill Today"
          link="/refill"
          badge={
            rt.lines === 0 ? <Badge tone="muted">no route</Badge> : rt.dispatched >= fillable && fillable > 0 ? <Badge tone="success">done</Badge> : <Badge tone="warn">in progress</Badge>
          }
        >
          {rt.lines === 0 ? (
            <p style={{ fontSize: 13, color: "var(--muted-2)" }}>
              No dispatch lines for today.
            </p>
          ) : (
            <>
              <div style={{ height: 10, borderRadius: 5, background: "var(--line)", overflow: "hidden", marginBottom: 10 }}>
                <div style={{ width: `${donePct}%`, height: "100%", background: "var(--brand)" }} />
              </div>
              <div className="flex flex-wrap gap-2" style={{ fontSize: 12, color: "var(--muted)" }}>
                <Badge tone="brand">{rt.machines} machines</Badge>
                <Badge tone="muted">{rt.lines} lines</Badge>
                <Badge tone="gold">{rt.packed} packed</Badge>
                <Badge tone="success">{rt.dispatched} dispatched</Badge>
                {rt.not_filled > 0 && <Badge tone="warn">{rt.not_filled} not filled</Badge>}
                {rt.skipped > 0 && <Badge tone="muted">{rt.skipped} skipped</Badge>}
              </div>
            </>
          )}
        </Panel>

        {/* Machine alerts */}
        <Panel
          title="Machine Alerts"
          link="/refill"
          badge={
            summary.health.p1_count > 0 ? <Badge tone="danger">{summary.health.p1_count} P1</Badge> : <Badge tone="success">healthy</Badge>
          }
        >
          {summary.health.top_urgent.length === 0 ? (
            <p style={{ fontSize: 13, color: "var(--muted-2)" }}>All quiet.</p>
          ) : (
            <div className="space-y-1.5">
              {summary.health.top_urgent.map((m) => (
                <div key={m.machine} className="flex items-center gap-2" style={{ fontSize: 13 }}>
                  <Badge tone={m.tier === "P1_RESTOCK" ? "danger" : m.tier === "P2_MAINTAIN" ? "warn" : "muted"}>
                    {m.tier === "P1_RESTOCK" ? "P1" : m.tier === "P2_MAINTAIN" ? "P2" : "–"}
                  </Badge>
                  <span style={{ fontWeight: 600, color: "var(--ink)" }}>{short(m.machine)}</span>
                  <span style={{ marginLeft: "auto", fontVariantNumeric: "tabular-nums", color: "var(--muted)" }}>
                    {m.score}
                  </span>
                </div>
              ))}
            </div>
          )}
        </Panel>

        {/* Top machines */}
        <Panel
          title="Top Machines"
          link="/app/performance"
          badge={
            <span style={{ display: "flex", gap: 2 }}>
              {[1, 7, 30].map((d) => (
                <button
                  key={d}
                  onClick={() => {
                    setLookback(d);
                    setTopLoading(true);
                  }}
                  style={{
                    padding: "2px 8px",
                    fontSize: 10,
                    fontWeight: lookback === d ? 800 : 500,
                    borderRadius: 5,
                    border: "1px solid var(--line)",
                    background: lookback === d ? "var(--brand)" : "var(--surface)",
                    color: lookback === d ? "white" : "var(--muted)",
                    cursor: "pointer",
                    fontFamily: font,
                  }}
                >
                  {d}d
                </button>
              ))}
            </span>
          }
        >
          {topLoading ? (
            <p style={{ fontSize: 12, color: "var(--muted-2)" }}>Loading…</p>
          ) : (
            <div className="space-y-1.5">
              {top10.map((r, i) => (
                <div key={r.machine_id} className="flex items-center gap-2" style={{ fontSize: 12.5 }}>
                  <span style={{ width: 18, fontWeight: 800, color: "var(--muted-2)", fontVariantNumeric: "tabular-nums" }}>
                    {i + 1}
                  </span>
                  <span style={{ fontWeight: 600, color: "var(--ink)", width: 110, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                    {short(r.machine_name)}
                  </span>
                  <div style={{ flex: 1, height: 7, borderRadius: 4, background: "var(--line)", overflow: "hidden" }}>
                    <div
                      style={{
                        width: `${(Number(r.total_revenue) / maxRev) * 100}%`,
                        height: "100%",
                        background: i === 0 ? "var(--gold)" : "var(--brand)",
                      }}
                    />
                  </div>
                  <span style={{ width: 86, textAlign: "right", fontVariantNumeric: "tabular-nums", fontWeight: 700, color: "var(--ink)" }}>
                    {Math.round(Number(r.total_revenue)).toLocaleString()}
                  </span>
                  <span style={{ width: 46, textAlign: "right", fontVariantNumeric: "tabular-nums", color: "var(--muted-2)", fontSize: 11 }}>
                    {Number(r.total_units)}u
                  </span>
                </div>
              ))}
            </div>
          )}
        </Panel>

        {/* Inventory posture */}
        <Panel
          title="Inventory"
          link="/app/inventory"
          badge={inv.thin_count > 0 ? <Badge tone="danger">{inv.thin_count} thin WH</Badge> : <Badge tone="success">covered</Badge>}
        >
          <div style={{ height: 10, borderRadius: 5, overflow: "hidden", display: "flex", background: "var(--line)", marginBottom: 6 }}>
            <div style={{ width: `${(inv.machine_units / Math.max(invTotal, 1)) * 100}%`, background: "var(--brand)" }} />
            <div style={{ flex: 1, background: "var(--gold)" }} />
          </div>
          <p style={{ fontSize: 11.5, color: "var(--muted)", marginBottom: 8 }}>
            <strong style={{ color: "var(--brand)" }}>{inv.machine_units.toLocaleString()}</strong> in machines ·{" "}
            <strong style={{ color: "var(--warn)" }}>{inv.wh_units.toLocaleString()}</strong> in warehouse · {inv.products} products
          </p>
          {inv.thin_top.map((t) => (
            <div key={t.product} className="flex items-center gap-2" style={{ fontSize: 12 }}>
              <span style={{ color: "var(--ink)", fontWeight: 600, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{t.product}</span>
              <span style={{ marginLeft: "auto", fontVariantNumeric: "tabular-nums", color: "var(--muted)" }}>
                {t.machine_units}u out · <span style={{ color: t.wh_units === 0 ? "var(--danger)" : "var(--warn)", fontWeight: 700 }}>{t.wh_units} WH</span>
              </span>
            </div>
          ))}
        </Panel>

        {/* Procurement + expiring */}
        <Panel
          title="Procurement"
          link="/app/procurement"
          badge={summary.procurement.open_pos > 0 ? <Badge tone="gold">{summary.procurement.open_pos} open POs</Badge> : <Badge tone="muted">none open</Badge>}
        >
          <p style={{ fontSize: 12.5, color: "var(--muted)", marginBottom: 10 }}>
            <strong style={{ color: "var(--ink)" }}>{summary.procurement.open_units.toLocaleString()}</strong> units on order ·{" "}
            <strong style={{ color: "var(--ink)" }}>{fmtAed(summary.procurement.open_value)}</strong> · {summary.procurement.open_lines} lines
          </p>
          <SectionHeading>WH expiry ≤ 14 days</SectionHeading>
          {summary.expiring.length === 0 ? (
            <p style={{ fontSize: 12, color: "var(--muted-2)" }}>Nothing at risk.</p>
          ) : (
            summary.expiring.map((e) => (
              <div key={e.product} className="flex items-center gap-2" style={{ fontSize: 12 }}>
                <span style={{ color: "var(--ink)", fontWeight: 600, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{e.product}</span>
                <span style={{ marginLeft: "auto", fontVariantNumeric: "tabular-nums" }}>
                  <Badge tone={e.days <= 7 ? "danger" : "warn"}>{e.units}u · {e.days}d</Badge>
                </span>
              </div>
            ))
          )}
        </Panel>

        {/* Hot leads + driver requests */}
        <Panel
          title="Hot Leads"
          link="/app/sales-pipeline"
          badge={
            summary.driver_requests.pending > 0 ? (
              <Link href="/admin/driver-requests">
                <Badge tone="warn">{summary.driver_requests.pending} driver requests</Badge>
              </Link>
            ) : undefined
          }
        >
          {summary.hot_leads.length === 0 ? (
            <p style={{ fontSize: 13, color: "var(--muted-2)" }}>Pipeline quiet.</p>
          ) : (
            <div className="space-y-1.5">
              {summary.hot_leads.map((l) => (
                <div key={l.company} className="flex items-center gap-2" style={{ fontSize: 12.5 }}>
                  <Badge tone={l.stage === "Awarded" ? "success" : l.stage === "Negotiation" ? "gold" : "muted"}>
                    {l.stage}
                  </Badge>
                  <span style={{ fontWeight: 600, color: "var(--ink)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                    {l.company}
                  </span>
                  <span style={{ marginLeft: "auto", fontSize: 11, color: "var(--muted-2)", whiteSpace: "nowrap" }}>
                    {l.machines ? `${l.machines} mch` : ""}
                    {l.owner ? ` · ${l.owner}` : ""}
                    {l.follow_up ? ` · f/u ${new Date(l.follow_up + "T00:00:00").toLocaleDateString("en-GB", { day: "numeric", month: "short" })}` : ""}
                  </span>
                </div>
              ))}
            </div>
          )}
        </Panel>
      </div>

      <p style={{ fontSize: 11, color: "var(--muted-2)", margin: "14px 4px 0" }}>
        Snapshot generated {new Date(summary.generated_at).toLocaleTimeString()} — refresh the page for live numbers. Sales figures are
        refund-excluded, WH pseudo-machines excluded; inventory split uses live
        shelf stock × mapping ratios.
      </p>
    </div>
  );
}
