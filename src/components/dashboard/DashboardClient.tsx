"use client";

// PRD-087 — the command-center dashboard (v2, CS round).
// One aggregate RPC: get_dashboard_summary(p_include_vox). TWO universal
// controls drive everything — the Today/7d/30d period toggle and the
// incl./excl. VOX venue toggle. No filters inside panels. Panels are
// clubbed by theme: Sales & Performance · Operations Today · Supply ·
// Commercial.

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { PageHeader, StatCard, Badge } from "@/components/ui/primitives";

const font = "'Plus Jakarta Sans', sans-serif";

/* ── types ─────────────────────────────────────────────────────────────── */

type KpiBlock = {
  revenue: number;
  units: number;
  txns: number;
  default_rate: number;
};
type TopMachine = { machine: string; revenue: number; units: number };
type TopProduct = { product: string; revenue: number; units: number };
type PerPeriod<T> = { today: T; d7: T; d30: T };

// PERF split (PRD-087): sales block is fast + VOX-scoped (refetched on
// toggle); ops block is heavy + VOX-independent (server-cached, 60s).
export type DashboardSales = {
  generated_at: string;
  today: string;
  include_vox: boolean;
  trading_machines: number;
  kpis: PerPeriod<KpiBlock> & {
    daily: { d: string; revenue: number; units: number }[];
  };
  top_machines: PerPeriod<TopMachine[]>;
  top_products: PerPeriod<TopProduct[]>;
};

export type DashboardOps = {
  generated_at: string;
  refill_today: {
    machines: number;
    lines: number;
    packed: number;
    dispatched: number;
    not_filled: number;
    skipped: number;
    machine_statuses: {
      machine: string;
      lines: number;
      dispatched: number;
      packed: number;
      not_filled: number;
      done: boolean;
    }[];
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
  expiry: {
    units_14d: number;
    skus_14d: number;
    items: { product: string; units: number; days: number }[];
  };
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
  fleet: {
    active_machines: number;
    products: number;
  };
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

/* ── chrome ────────────────────────────────────────────────────────────── */

function ThemeHeading({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: 10,
        margin: "26px 0 12px",
        fontSize: 12,
        fontWeight: 800,
        letterSpacing: "0.14em",
        textTransform: "uppercase",
        color: "var(--brand)",
        fontFamily: font,
      }}
    >
      {children}
      <span style={{ flex: 1, height: 2, background: "var(--brand-tint)" }} />
    </div>
  );
}

function Panel({
  title,
  link,
  children,
  badge,
}: {
  title: string;
  link?: string;
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
            Open →
          </Link>
        )}
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>{children}</div>
    </div>
  );
}

function RevenueBars({ daily }: { daily: DashboardSales["kpis"]["daily"] }) {
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
          <rect
            key={x.d}
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
        );
      })}
    </svg>
  );
}

function RankBarList<T>({
  rows,
  label,
  value,
  units,
}: {
  rows: T[];
  label: (r: T) => string;
  value: (r: T) => number;
  units: (r: T) => number;
}) {
  const max = Math.max(...rows.map(value), 1);
  return (
    <div className="space-y-1.5">
      {rows.map((r, i) => (
        <div
          key={label(r)}
          className="flex items-center gap-2"
          style={{ fontSize: 12.5 }}
        >
          <span
            style={{
              width: 18,
              fontWeight: 800,
              color: "var(--muted-2)",
              fontVariantNumeric: "tabular-nums",
            }}
          >
            {i + 1}
          </span>
          <span
            style={{
              fontWeight: 600,
              color: "var(--ink)",
              width: 130,
              overflow: "hidden",
              textOverflow: "ellipsis",
              whiteSpace: "nowrap",
            }}
            title={label(r)}
          >
            {label(r)}
          </span>
          <div
            style={{
              flex: 1,
              height: 7,
              borderRadius: 4,
              background: "var(--line)",
              overflow: "hidden",
            }}
          >
            <div
              style={{
                width: `${(value(r) / max) * 100}%`,
                height: "100%",
                background: i === 0 ? "var(--gold)" : "var(--brand)",
              }}
            />
          </div>
          <span
            style={{
              width: 76,
              textAlign: "right",
              fontVariantNumeric: "tabular-nums",
              fontWeight: 700,
              color: "var(--ink)",
            }}
          >
            {Math.round(value(r)).toLocaleString()}
          </span>
          <span
            style={{
              width: 46,
              textAlign: "right",
              fontVariantNumeric: "tabular-nums",
              color: "var(--muted-2)",
              fontSize: 11,
            }}
          >
            {units(r)}u
          </span>
        </div>
      ))}
      {rows.length === 0 && (
        <p style={{ fontSize: 12, color: "var(--muted-2)" }}>
          No sales in this window.
        </p>
      )}
    </div>
  );
}

/* ── component ─────────────────────────────────────────────────────────── */

export default function DashboardClient({
  initialSales,
  ops,
}: {
  initialSales: DashboardSales;
  ops: DashboardOps;
}) {
  const [period, setPeriod] = useState<Period>("today");
  const [includeVox, setIncludeVox] = useState(initialSales.include_vox);
  const [sales, setSales] = useState<DashboardSales>(initialSales);
  const [refreshing, setRefreshing] = useState(false);

  // Universal VOX toggle → refetch ONLY the fast sales block (~100ms).
  useEffect(() => {
    if (includeVox === initialSales.include_vox && sales === initialSales)
      return;
    let alive = true;
    const supabase = createClient();
    supabase
      .rpc("get_dashboard_sales", { p_include_vox: includeVox })
      .then(({ data }) => {
        if (!alive) return;
        if (data) setSales(data as DashboardSales);
        setRefreshing(false);
      });
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [includeVox]);

  const summary = ops; // heavy blocks (server-cached, VOX-independent)
  const k = sales.kpis[period];
  const rt = summary.refill_today;
  const fillable = Math.max(rt.lines - rt.not_filled - rt.skipped, 0);
  const donePct =
    fillable > 0 ? Math.min((rt.dispatched / fillable) * 100, 100) : 0;
  const inv = summary.inventory;
  const invTotal = inv.machine_units + inv.wh_units;
  const topM = useMemo(() => sales.top_machines[period] ?? [], [sales, period]);
  const topP = useMemo(() => sales.top_products[period] ?? [], [sales, period]);
  const periodLabel = PERIODS.find((p) => p.key === period)?.label;

  const toggleBtn = (active: boolean): React.CSSProperties => ({
    padding: "8px 14px",
    fontSize: 12,
    fontWeight: active ? 700 : 500,
    background: active ? "var(--brand)" : "var(--surface)",
    color: active ? "white" : "var(--muted)",
    border: "none",
    cursor: "pointer",
    fontFamily: font,
  });

  return (
    <div
      className="p-8 max-w-7xl"
      style={{
        fontFamily: font,
        opacity: refreshing ? 0.6 : 1,
        transition: "opacity 0.2s",
      }}
    >
      <PageHeader
        title="Dashboard"
        subtitle={`${new Date(sales.today + "T00:00:00").toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long", year: "numeric" })} · ${sales.trading_machines} machines trading · ${summary.fleet.products} products`}
        actions={
          <div className="flex items-center gap-2 flex-wrap">
            {/* universal period toggle */}
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
                  style={toggleBtn(period === p.key)}
                >
                  {p.label}
                </button>
              ))}
            </div>
            {/* universal VOX scope toggle */}
            <div
              style={{
                display: "flex",
                border: "1px solid var(--line)",
                borderRadius: 8,
                overflow: "hidden",
              }}
            >
              <button
                onClick={() => {
                  setIncludeVox(true);
                  setRefreshing(true);
                }}
                style={toggleBtn(includeVox)}
              >
                Incl. VOX venue
              </button>
              <button
                onClick={() => {
                  setIncludeVox(false);
                  setRefreshing(true);
                }}
                style={toggleBtn(!includeVox)}
              >
                Excl. VOX venue
              </button>
            </div>
          </div>
        }
      />

      {/* ════ SALES & PERFORMANCE ════ */}
      <ThemeHeading>
        Sales & Performance — {periodLabel} · {includeVox ? "incl." : "excl."}{" "}
        VOX
      </ThemeHeading>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))",
          gap: 12,
          marginBottom: 14,
        }}
      >
        <StatCard label="Revenue" value={fmtAed(k.revenue)} sub={periodLabel} />
        <StatCard
          label="Units Sold"
          value={k.units.toLocaleString()}
          sub={periodLabel}
          accent="var(--gold)"
        />
        <StatCard
          label="Transactions"
          value={k.txns.toLocaleString()}
          sub={
            k.txns > 0
              ? `${(k.revenue / k.txns).toFixed(1)} AED avg basket`
              : "—"
          }
          accent="var(--chart-5)"
        />
        <StatCard
          label="Default Rate"
          value={`${k.default_rate}%`}
          sub="Adyen gap / matched sales (net of refunds & cash recovery)"
          accent="var(--chart-4)"
          valueColor={k.default_rate > 2 ? "var(--danger)" : "var(--ink)"}
        />
      </div>

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
          <span
            style={{
              fontSize: 11,
              fontWeight: 800,
              letterSpacing: "0.1em",
              textTransform: "uppercase",
              color: "var(--muted)",
            }}
          >
            Revenue — last 30 days
          </span>
          <span style={{ fontSize: 11, color: "var(--muted-2)" }}>
            {fmtAed(sales.kpis.d30.revenue)} total · gold bar = today
          </span>
        </div>
        <RevenueBars daily={sales.kpis.daily} />
      </div>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(340px, 1fr))",
          gap: 14,
        }}
      >
        <Panel title={`Top Machines — ${periodLabel}`} link="/app/performance">
          <RankBarList
            rows={topM}
            label={(r) => short(r.machine)}
            value={(r) => r.revenue}
            units={(r) => r.units}
          />
        </Panel>
        <Panel title={`Top Products — ${periodLabel}`} link="/app/products">
          <RankBarList
            rows={topP}
            label={(r) => r.product}
            value={(r) => r.units}
            units={(r) => r.units}
          />
        </Panel>
      </div>

      {/* ════ OPERATIONS TODAY ════ */}
      <ThemeHeading>Operations Today</ThemeHeading>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(340px, 1fr))",
          gap: 14,
        }}
      >
        <Panel
          title="Refill Today"
          link="/refill"
          badge={
            rt.lines === 0 ? (
              <Badge tone="muted">no route</Badge>
            ) : rt.dispatched >= fillable && fillable > 0 ? (
              <Badge tone="success">done</Badge>
            ) : (
              <Badge tone="warn">in progress</Badge>
            )
          }
        >
          {rt.lines === 0 ? (
            <p style={{ fontSize: 13, color: "var(--muted-2)" }}>
              No dispatch lines for today.
            </p>
          ) : (
            <>
              <div
                style={{
                  height: 10,
                  borderRadius: 5,
                  background: "var(--line)",
                  overflow: "hidden",
                  marginBottom: 8,
                }}
              >
                <div
                  style={{
                    width: `${donePct}%`,
                    height: "100%",
                    background: "var(--brand)",
                  }}
                />
              </div>
              <div
                className="flex flex-wrap gap-2 mb-3"
                style={{ fontSize: 12 }}
              >
                <Badge tone="muted">{rt.lines} lines</Badge>
                <Badge tone="gold">{rt.packed} packed</Badge>
                <Badge tone="success">{rt.dispatched} dispatched</Badge>
                {rt.not_filled > 0 && (
                  <Badge tone="warn">{rt.not_filled} not filled</Badge>
                )}
                {rt.skipped > 0 && (
                  <Badge tone="muted">{rt.skipped} skipped</Badge>
                )}
              </div>
              {/* per-machine status board */}
              <div className="space-y-1">
                {rt.machine_statuses.map((m) => {
                  const mFillable = Math.max(m.lines - m.not_filled, 0);
                  return (
                    <div
                      key={m.machine}
                      className="flex items-center gap-2"
                      style={{ fontSize: 12.5 }}
                    >
                      <Badge
                        tone={
                          m.done
                            ? "success"
                            : m.dispatched > 0 || m.packed > 0
                              ? "gold"
                              : "muted"
                        }
                      >
                        {m.done
                          ? "✓ done"
                          : m.dispatched > 0 || m.packed > 0
                            ? "on it"
                            : "waiting"}
                      </Badge>
                      <span style={{ fontWeight: 600, color: "var(--ink)" }}>
                        {short(m.machine)}
                      </span>
                      <span
                        style={{
                          marginLeft: "auto",
                          fontVariantNumeric: "tabular-nums",
                          color: "var(--muted)",
                          fontSize: 11.5,
                        }}
                      >
                        {m.dispatched}/{mFillable} lines
                        {m.not_filled > 0 && (
                          <span style={{ color: "var(--warn)" }}>
                            {" "}
                            · {m.not_filled} n/f
                          </span>
                        )}
                      </span>
                    </div>
                  );
                })}
              </div>
            </>
          )}
        </Panel>

        <Panel
          title="Machine Alerts"
          link="/refill"
          badge={
            <>
              {summary.health.p1_count > 0 && (
                <Badge tone="danger">{summary.health.p1_count} P1</Badge>
              )}
              {summary.health.p2_count > 0 && (
                <Badge tone="warn">{summary.health.p2_count} P2</Badge>
              )}
              {summary.health.p1_count === 0 &&
                summary.health.p2_count === 0 && (
                  <Badge tone="success">healthy</Badge>
                )}
              {summary.driver_requests.pending > 0 && (
                <Link href="/admin/driver-requests">
                  <Badge tone="brand">
                    {summary.driver_requests.pending} driver req.
                  </Badge>
                </Link>
              )}
            </>
          }
        >
          {summary.health.top_urgent.length === 0 ? (
            <p style={{ fontSize: 13, color: "var(--muted-2)" }}>
              No P1/P2 machines. All quiet.
            </p>
          ) : (
            <div className="space-y-1.5">
              {summary.health.top_urgent.map((m) => (
                <div
                  key={m.machine}
                  className="flex items-center gap-2"
                  style={{ fontSize: 13 }}
                >
                  <Badge tone={m.tier === "P1_RESTOCK" ? "danger" : "warn"}>
                    {m.tier === "P1_RESTOCK" ? "P1" : "P2"}
                  </Badge>
                  <span style={{ fontWeight: 600, color: "var(--ink)" }}>
                    {short(m.machine)}
                  </span>
                  <span
                    style={{
                      marginLeft: "auto",
                      fontVariantNumeric: "tabular-nums",
                      color: "var(--muted)",
                    }}
                  >
                    {m.score}
                  </span>
                </div>
              ))}
            </div>
          )}
        </Panel>
      </div>

      {/* ════ SUPPLY ════ */}
      <ThemeHeading>Supply</ThemeHeading>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(300px, 1fr))",
          gap: 14,
        }}
      >
        <Panel
          title="Inventory"
          link="/app/inventory"
          badge={
            inv.thin_count > 0 ? (
              <Badge tone="danger">{inv.thin_count} thin WH</Badge>
            ) : (
              <Badge tone="success">covered</Badge>
            )
          }
        >
          <div
            style={{
              height: 10,
              borderRadius: 5,
              overflow: "hidden",
              display: "flex",
              background: "var(--line)",
              marginBottom: 6,
            }}
          >
            <div
              style={{
                width: `${(inv.machine_units / Math.max(invTotal, 1)) * 100}%`,
                background: "var(--brand)",
              }}
            />
            <div style={{ flex: 1, background: "var(--gold)" }} />
          </div>
          <p style={{ fontSize: 11.5, color: "var(--muted)", marginBottom: 8 }}>
            <strong style={{ color: "var(--brand)" }}>
              {inv.machine_units.toLocaleString()}
            </strong>{" "}
            in machines ·{" "}
            <strong style={{ color: "var(--warn)" }}>
              {inv.wh_units.toLocaleString()}
            </strong>{" "}
            in warehouse
          </p>
          {inv.thin_top.map((t) => (
            <div
              key={t.product}
              className="flex items-center gap-2"
              style={{ fontSize: 12 }}
            >
              <span
                style={{
                  color: "var(--ink)",
                  fontWeight: 600,
                  overflow: "hidden",
                  textOverflow: "ellipsis",
                  whiteSpace: "nowrap",
                }}
              >
                {t.product}
              </span>
              <span
                style={{
                  marginLeft: "auto",
                  fontVariantNumeric: "tabular-nums",
                  color: "var(--muted)",
                  whiteSpace: "nowrap",
                }}
              >
                {t.machine_units}u out ·{" "}
                <span
                  style={{
                    color: t.wh_units === 0 ? "var(--danger)" : "var(--warn)",
                    fontWeight: 700,
                  }}
                >
                  {t.wh_units} WH
                </span>
              </span>
            </div>
          ))}
        </Panel>

        <Panel
          title="Expiry Risk"
          link="/app/inventory"
          badge={
            summary.expiry.units_14d > 0 ? (
              <Badge tone="warn">{summary.expiry.units_14d}u ≤ 14d</Badge>
            ) : (
              <Badge tone="success">clear</Badge>
            )
          }
        >
          {summary.expiry.items.length === 0 ? (
            <p style={{ fontSize: 13, color: "var(--muted-2)" }}>
              No warehouse stock expiring in the next 14 days.
            </p>
          ) : (
            <div className="space-y-1.5">
              {summary.expiry.items.map((e) => (
                <div
                  key={e.product}
                  className="flex items-center gap-2"
                  style={{ fontSize: 12.5 }}
                >
                  <Badge tone={e.days <= 7 ? "danger" : "warn"}>
                    {e.days}d
                  </Badge>
                  <span
                    style={{
                      color: "var(--ink)",
                      fontWeight: 600,
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {e.product}
                  </span>
                  <span
                    style={{
                      marginLeft: "auto",
                      fontVariantNumeric: "tabular-nums",
                      color: "var(--muted)",
                    }}
                  >
                    {e.units}u
                  </span>
                </div>
              ))}
            </div>
          )}
        </Panel>

        <Panel
          title="Procurement"
          link="/app/procurement"
          badge={
            summary.procurement.open_pos > 0 ? (
              <Badge tone="gold">{summary.procurement.open_pos} open POs</Badge>
            ) : (
              <Badge tone="muted">none open</Badge>
            )
          }
        >
          <div
            className="space-y-2"
            style={{ fontSize: 13, color: "var(--muted)" }}
          >
            <div className="flex items-center justify-between">
              <span>Units on order</span>
              <strong
                style={{
                  color: "var(--ink)",
                  fontVariantNumeric: "tabular-nums",
                }}
              >
                {summary.procurement.open_units.toLocaleString()}
              </strong>
            </div>
            <div className="flex items-center justify-between">
              <span>Value on order</span>
              <strong
                style={{
                  color: "var(--ink)",
                  fontVariantNumeric: "tabular-nums",
                }}
              >
                {fmtAed(summary.procurement.open_value)}
              </strong>
            </div>
            <div className="flex items-center justify-between">
              <span>Open lines</span>
              <strong
                style={{
                  color: "var(--ink)",
                  fontVariantNumeric: "tabular-nums",
                }}
              >
                {summary.procurement.open_lines}
              </strong>
            </div>
          </div>
        </Panel>
      </div>

      {/* ════ COMMERCIAL ════ */}
      <ThemeHeading>Commercial</ThemeHeading>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(340px, 1fr))",
          gap: 14,
        }}
      >
        <Panel title="Hot Leads" link="/app/sales-pipeline">
          {summary.hot_leads.length === 0 ? (
            <p style={{ fontSize: 13, color: "var(--muted-2)" }}>
              Pipeline quiet.
            </p>
          ) : (
            <div className="space-y-1.5">
              {summary.hot_leads.map((l) => (
                <div
                  key={l.company}
                  className="flex items-center gap-2"
                  style={{ fontSize: 12.5 }}
                >
                  <Badge
                    tone={
                      l.stage === "Awarded"
                        ? "success"
                        : l.stage === "Negotiation"
                          ? "gold"
                          : "muted"
                    }
                  >
                    {l.stage}
                  </Badge>
                  <span
                    style={{
                      fontWeight: 600,
                      color: "var(--ink)",
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {l.company}
                  </span>
                  <span
                    style={{
                      marginLeft: "auto",
                      fontSize: 11,
                      color: "var(--muted-2)",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {l.machines ? `${l.machines} mch` : ""}
                    {l.owner ? ` · ${l.owner}` : ""}
                    {l.follow_up
                      ? ` · f/u ${new Date(l.follow_up + "T00:00:00").toLocaleDateString("en-GB", { day: "numeric", month: "short" })}`
                      : ""}
                  </span>
                </div>
              ))}
            </div>
          )}
        </Panel>
      </div>

      <p
        style={{ fontSize: 11, color: "var(--muted-2)", margin: "16px 4px 0" }}
      >
        Sales {new Date(sales.generated_at).toLocaleTimeString()} · ops snapshot
        cached up to 60s — refresh the page for live numbers. Sales are
        refund-excluded. VOX toggle scopes by venue group (VOX cinemas + sister
        pods ACTIVATE / IFLY / MPMCC). Default rate = canonical PRD-023h:
        Adyen-matched gap ÷ matched sales, refunds and cash recovery credited.
        Expiry & inventory are fleet-wide.
      </p>
    </div>
  );
}
