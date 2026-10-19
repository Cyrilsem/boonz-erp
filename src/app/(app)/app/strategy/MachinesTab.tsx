"use client";

// PRD-142a section 7, Machines tab: population / window / era controls, KPI
// strip, posture 2x2, sortable table, review-proposals panel, detail drawer.

import { useEffect, useMemo, useRef, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  CartesianGrid,
  Cell,
  ReferenceLine,
  ResponsiveContainer,
  Scatter,
  ScatterChart,
  Tooltip,
  XAxis,
  YAxis,
  ZAxis,
} from "recharts";
import { createClient } from "@/lib/supabase/client";
import MachineDrawer from "./MachineDrawer";
import {
  aed,
  archetypeColor,
  Card,
  Kpi,
  num,
  pct,
  Pill,
  POSTURE_COLOR,
  POSTURE_LABEL,
  Segmented,
  sortRows,
} from "./shared";

export interface MachineRow {
  machine_id: string;
  official_name: string;
  venue_group: string | null;
  population: string;
  era_start: string;
  inception: string | null;
  age_days: number | null;
  window_days: number | null;
  units: number | null;
  net_rev: number | null;
  gross_profit: number | null;
  units_day: number | null;
  rev_day: number | null;
  gp_day: number | null;
  cogs_coverage: number | null;
  month_net_rev: number | null;
  month_full_months: number | null;
  life_net_rev: number | null;
  life_units: number | null;
  ticket: number | null;
  units_per_basket: number | null;
  card_share: number | null;
  peak_hours: number[] | null;
  peak_hour_share: number | null;
  weekend_share: number | null;
  weekday_lunch_share: number | null;
  drinks_share: number | null;
  top5_shelf_share: number | null;
  dead_shelf_pct: number | null;
  concentration: string | null;
  ramp_index: number | null;
  trend_30_vs_90: number | null;
  archetype: string | null;
  archetype_label: string | null;
  archetype_method: string | null;
  archetype_changed_at: string | null;
  benchmark_rev_day_90: number | null;
  benchmark_gp_day_90: number | null;
  posture: string | null;
  posture_proposed: string | null;
  diagnosis: string | null;
  performance_index: number | null;
  mix_gap: number | null;
  review_by: string | null;
  confirmed_at: string | null;
  rejected_posture: string | null;
  rejected_until: string | null;
  params: Record<string, unknown> | null;
  // PRD-142b A7: postures only apply to machines in refill.
  in_refill: boolean;
}

type Win = "30d" | "90d" | "12m" | "era";

export default function MachinesTab() {
  const sb = useRef<SupabaseClient | null>(null);
  const [population, setPopulation] = useState<"boonz" | "partner">("boonz");
  const [win, setWin] = useState<Win>("90d");
  const [allEras, setAllEras] = useState(false);
  const [rows, setRows] = useState<MachineRow[]>([]);
  const [asOf, setAsOf] = useState<string | null>(null);
  const [loadedKey, setLoadedKey] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [archFilter, setArchFilter] = useState<string>("");
  const [postureFilter, setPostureFilter] = useState<string>("");
  const [sortKey, setSortKey] = useState<keyof MachineRow | null>("rev_day");
  const [sortDir, setSortDir] = useState<1 | -1>(-1);
  const [openId, setOpenId] = useState<string | null>(null);
  const [reload, setReload] = useState(0);
  const [busy, setBusy] = useState<string | null>(null);
  const [rejecting, setRejecting] = useState<string | null>(null);
  const [rejectReason, setRejectReason] = useState("");

  const loading = loadedKey !== `${population}|${win}|${allEras}|${reload}`;

  useEffect(() => {
    sb.current = createClient();
    let cancelled = false;
    sb.current
      .rpc("get_strategy_machines", {
        p_population: population,
        p_window: win,
        p_all_eras: allEras,
      })
      .then(({ data, error: e }) => {
        if (cancelled) return;
        if (e) {
          setError(e.message);
          setRows([]);
        } else {
          setError(null);
          setRows((data?.machines ?? []) as MachineRow[]);
          setAsOf(data?.as_of ?? null);
        }
        setLoadedKey(`${population}|${win}|${allEras}|${reload}`);
      });
    return () => {
      cancelled = true;
    };
  }, [population, win, allEras, reload]);

  const archetypes = useMemo(
    () =>
      Array.from(new Set(rows.map((r) => r.archetype ?? "")))
        .filter(Boolean)
        .sort(),
    [rows],
  );

  const filtered = useMemo(
    () =>
      rows.filter(
        (r) =>
          (!archFilter || r.archetype === archFilter) &&
          (!postureFilter ||
            (r.posture ?? r.posture_proposed) === postureFilter),
      ),
    [rows, archFilter, postureFilter],
  );
  const sorted = useMemo(
    () => sortRows(filtered, sortKey, sortDir),
    [filtered, sortKey, sortDir],
  );

  const kpi = useMemo(() => {
    const units = rows.reduce((s, r) => s + (r.units ?? 0), 0);
    const covUnits = rows.reduce(
      (s, r) => s + (r.units ?? 0) * (r.cogs_coverage ?? 0),
      0,
    );
    const byPosture: Record<string, number> = {};
    for (const r of rows) {
      const p =
        r.in_refill === false
          ? "not in refill"
          : (r.posture ?? `${r.posture_proposed ?? "none"} (proposed)`);
      byPosture[p] = (byPosture[p] ?? 0) + 1;
    }
    return {
      machines: rows.length,
      revDay: rows.reduce((s, r) => s + (r.rev_day ?? 0), 0),
      gpDay: rows.reduce((s, r) => s + (r.gp_day ?? 0), 0),
      gpKnown: rows.some((r) => r.gp_day !== null),
      cogs: units > 0 ? covUnits / units : null,
      byPosture,
    };
  }, [rows]);

  const archCounts = useMemo(() => {
    const m: Record<string, { label: string; n: number }> = {};
    for (const r of rows) {
      const k = r.archetype ?? "none";
      m[k] = { label: r.archetype_label ?? k, n: (m[k]?.n ?? 0) + 1 };
    }
    return m;
  }, [rows]);

  const review = useMemo(
    () =>
      rows.filter(
        (r) =>
          r.in_refill !== false &&
          r.posture_proposed &&
          r.posture_proposed !== r.posture,
      ),
    [rows],
  );
  const pastReview = useMemo(() => {
    const today = new Date().toISOString().slice(0, 10);
    return rows.filter(
      (r) => r.in_refill !== false && r.review_by && r.review_by < today,
    );
  }, [rows]);
  const archChanged = useMemo(
    () => rows.filter((r) => r.archetype_changed_at),
    [rows],
  );

  async function accept(r: MachineRow) {
    if (!sb.current || !r.posture_proposed) return;
    setBusy(r.machine_id);
    const { error: e } = await sb.current.rpc("set_machine_strategy", {
      p_machine_id: r.machine_id,
      p_posture: r.posture_proposed,
      p_params: null,
      p_shelf_overrides: null,
      p_notes: null,
    });
    setBusy(null);
    if (e) setError(e.message);
    else setReload((n) => n + 1);
  }

  async function reject(r: MachineRow) {
    if (!sb.current || !rejectReason.trim()) return;
    setBusy(r.machine_id);
    const { error: e } = await sb.current.rpc(
      "reject_machine_strategy_proposal",
      {
        p_machine_id: r.machine_id,
        p_reason: rejectReason.trim(),
      },
    );
    setBusy(null);
    setRejecting(null);
    setRejectReason("");
    if (e) setError(e.message);
    else setReload((n) => n + 1);
  }

  function header(label: string, key: keyof MachineRow) {
    const active = sortKey === key;
    return (
      <th
        className="cursor-pointer whitespace-nowrap px-2 py-2 text-left font-medium"
        onClick={() => {
          if (active) setSortDir(sortDir === 1 ? -1 : 1);
          else {
            setSortKey(key);
            setSortDir(-1);
          }
        }}
      >
        {label}
        {active ? (sortDir === 1 ? " ▲" : " ▼") : ""}
      </th>
    );
  }

  const scatterData = rows
    .filter((r) => r.performance_index !== null)
    .map((r) => ({
      x: Math.max(-1, Math.min(1, r.mix_gap ?? 0)),
      y: Math.min(3, r.performance_index ?? 0),
      z: r.rev_day ?? 1,
      name: r.official_name,
      archetype: r.archetype,
      archetypeLabel: r.archetype_label,
      posture: r.posture ?? r.posture_proposed,
      id: r.machine_id,
      rawX: r.mix_gap,
      rawY: r.performance_index,
    }));

  return (
    <div className="space-y-4" data-testid="strategy-machines">
      <div className="flex flex-wrap items-center gap-3">
        <Segmented
          value={population}
          onChange={(v) => setPopulation(v)}
          options={[
            { value: "boonz", label: "Boonz sourcing" },
            { value: "partner", label: "Partner sourcing" },
          ]}
        />
        <Segmented
          value={win}
          onChange={(v) => setWin(v)}
          options={[
            { value: "30d", label: "30 days" },
            { value: "90d", label: "90 days" },
            { value: "12m", label: "12 months" },
            { value: "era", label: "Era" },
          ]}
        />
        <label
          className="flex items-center gap-2 text-xs"
          style={{ color: "var(--muted)" }}
        >
          <input
            type="checkbox"
            checked={allEras}
            onChange={(e) => setAllEras(e.target.checked)}
          />
          All eras
        </label>
        {asOf && (
          <span className="text-xs" style={{ color: "var(--muted-2)" }}>
            Features as of {asOf} (rebuilt nightly 03:30 Dubai). Revenue ex-VAT,
            net of refunds.
          </span>
        )}
      </div>

      {error && (
        <div
          className="rounded-lg px-3 py-2 text-sm"
          style={{ background: "var(--danger-bg)", color: "var(--danger)" }}
        >
          {error}
        </div>
      )}

      <div className="grid grid-cols-2 gap-3 md:grid-cols-5">
        <Kpi label="Machines" value={kpi.machines} />
        <Kpi
          label="Net rev per day"
          value={aed(kpi.revDay)}
          sub={`${win} window, summed`}
        />
        <Kpi
          label="Gross profit per day"
          value={kpi.gpKnown ? aed(kpi.gpDay) : "–"}
          sub={
            population === "partner"
              ? "Partner share not configured"
              : undefined
          }
        />
        <Kpi
          label="COGS coverage"
          value={pct(kpi.cogs)}
          sub="share of units with a cost"
        />
        <Kpi
          label="Machines by posture"
          value={
            <div className="flex flex-wrap gap-1 text-xs font-normal">
              {Object.entries(kpi.byPosture).map(([k, n]) => (
                <span key={k}>
                  {POSTURE_LABEL[k] ?? k.replace(/_/g, " ").toLowerCase()} {n}
                </span>
              ))}
            </div>
          }
        />
      </div>

      <div className="grid gap-4 lg:grid-cols-3">
        <div className="lg:col-span-2">
          <Card title="Posture map: worth it today (performance vs archetype benchmark) by where the problem is (mix gap)">
            <div style={{ height: 360 }}>
              <ResponsiveContainer>
                <ScatterChart
                  margin={{ top: 16, right: 24, bottom: 24, left: 8 }}
                >
                  <CartesianGrid stroke="var(--line)" />
                  <XAxis
                    type="number"
                    dataKey="x"
                    domain={[-1, 1]}
                    tickFormatter={(v) => `${Math.round(v * 100)}%`}
                    label={{
                      value: "Mix gap (inside the machine to the right)",
                      position: "insideBottom",
                      offset: -12,
                      fontSize: 11,
                    }}
                    fontSize={11}
                  />
                  <YAxis
                    type="number"
                    dataKey="y"
                    domain={[0, 3]}
                    tickFormatter={(v) => `${Math.round(v * 100)}%`}
                    label={{
                      value: "Performance index",
                      angle: -90,
                      position: "insideLeft",
                      fontSize: 11,
                    }}
                    fontSize={11}
                  />
                  <ZAxis type="number" dataKey="z" range={[40, 600]} />
                  <ReferenceLine
                    y={0.85}
                    stroke="var(--muted-2)"
                    strokeDasharray="4 4"
                    label={{
                      value: "Strong 85%",
                      position: "right",
                      fontSize: 10,
                    }}
                  />
                  <ReferenceLine
                    x={0.25}
                    stroke="var(--muted-2)"
                    strokeDasharray="4 4"
                    label={{
                      value: "Inside 25%",
                      position: "top",
                      fontSize: 10,
                    }}
                  />
                  <Tooltip
                    cursor={{ strokeDasharray: "3 3" }}
                    content={({ payload }) => {
                      const p = payload?.[0]?.payload as
                        (typeof scatterData)[number] | undefined;
                      if (!p) return null;
                      return (
                        <div
                          className="rounded-lg px-3 py-2 text-xs shadow"
                          style={{
                            background: "var(--surface)",
                            border: "1px solid var(--line)",
                          }}
                        >
                          <div className="font-semibold">{p.name}</div>
                          <div>{p.archetypeLabel}</div>
                          <div>
                            Performance {pct(p.rawY)} · Mix gap {pct(p.rawX)}
                          </div>
                          <div>
                            {POSTURE_LABEL[p.posture ?? ""] ?? "no posture"}
                          </div>
                        </div>
                      );
                    }}
                  />
                  <Scatter
                    data={scatterData}
                    onClick={(d) =>
                      setOpenId((d as unknown as { id: string }).id)
                    }
                  >
                    {scatterData.map((d) => (
                      <Cell
                        key={d.id}
                        fill={archetypeColor(d.archetype, archetypes)}
                        fillOpacity={0.8}
                        cursor="pointer"
                      />
                    ))}
                  </Scatter>
                </ScatterChart>
              </ResponsiveContainer>
            </div>
            <div
              className="mt-2 grid grid-cols-2 gap-2 text-[11px] md:grid-cols-4"
              style={{ color: "var(--muted)" }}
            >
              <div>Top left: Protect and grow</div>
              <div>Top right: Protect and grow (fix lanes)</div>
              <div>Bottom left: Watch and adapt (outside)</div>
              <div>Bottom right: Fix the mix (inside)</div>
            </div>
          </Card>
        </div>
        <Card title="Archetypes">
          <ul className="space-y-1 text-sm">
            {Object.entries(archCounts).map(([code, a]) => (
              <li
                key={code}
                className="flex items-center justify-between gap-2"
              >
                <button
                  className="flex items-center gap-2 text-left"
                  onClick={() => setArchFilter(archFilter === code ? "" : code)}
                >
                  <span
                    className="inline-block h-3 w-3 rounded-full"
                    style={{ background: archetypeColor(code, archetypes) }}
                  />
                  <span style={{ fontWeight: archFilter === code ? 700 : 400 }}>
                    {a.label}
                  </span>
                </button>
                <span style={{ color: "var(--muted)" }}>{a.n}</span>
              </li>
            ))}
          </ul>
          {archChanged.length > 0 && (
            <div className="mt-3 text-xs" style={{ color: "var(--warn)" }}>
              Archetype changed in the last 14 days:{" "}
              {archChanged.map((r) => r.official_name).join(", ")}
            </div>
          )}
        </Card>
      </div>

      <Card
        title={`Review proposals (${review.length})`}
        right={
          <span className="text-xs" style={{ color: "var(--muted)" }}>
            Accept confirms the proposed posture; edit in the drawer; reject
            suppresses it for 30 days.
          </span>
        }
      >
        <div data-testid="strategy-review-panel" className="space-y-2">
          {review.length === 0 && (
            <div className="text-sm" style={{ color: "var(--muted)" }}>
              No open proposals.
            </div>
          )}
          {review.map((r) => (
            <div
              key={r.machine_id}
              className="rounded-lg p-3"
              style={{ border: "1px solid var(--line)" }}
            >
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div className="flex flex-wrap items-center gap-2">
                  <button
                    className="font-semibold underline-offset-2 hover:underline"
                    onClick={() => setOpenId(r.machine_id)}
                  >
                    {r.official_name}
                  </button>
                  <span className="text-xs" style={{ color: "var(--muted)" }}>
                    {r.archetype_label}
                  </span>
                  <Pill
                    color={POSTURE_COLOR[r.posture ?? ""] ?? "#a3a09a"}
                    outline={!r.posture}
                  >
                    now: {POSTURE_LABEL[r.posture ?? ""] ?? "not set"}
                  </Pill>
                  <span>→</span>
                  <Pill
                    color={POSTURE_COLOR[r.posture_proposed ?? ""] ?? "#a3a09a"}
                  >
                    {POSTURE_LABEL[r.posture_proposed ?? ""]}
                  </Pill>
                </div>
                <div className="flex gap-2">
                  <button
                    disabled={busy === r.machine_id}
                    onClick={() => accept(r)}
                    className="rounded-lg px-3 py-1 text-xs font-medium text-white"
                    style={{ background: "var(--brand)" }}
                  >
                    Accept
                  </button>
                  <button
                    onClick={() => setOpenId(r.machine_id)}
                    className="rounded-lg px-3 py-1 text-xs"
                    style={{ border: "1px solid var(--line)" }}
                  >
                    Accept with edits
                  </button>
                  <button
                    onClick={() =>
                      setRejecting(
                        rejecting === r.machine_id ? null : r.machine_id,
                      )
                    }
                    className="rounded-lg px-3 py-1 text-xs"
                    style={{
                      border: "1px solid var(--line)",
                      color: "var(--danger)",
                    }}
                  >
                    Reject
                  </button>
                </div>
              </div>
              <div
                className="mt-1 text-sm"
                style={{ color: "var(--foreground)" }}
              >
                {r.diagnosis}
              </div>
              {rejecting === r.machine_id && (
                <div className="mt-2 flex gap-2">
                  <input
                    value={rejectReason}
                    onChange={(e) => setRejectReason(e.target.value)}
                    placeholder="Reason (required)"
                    className="flex-1 rounded-lg px-2 py-1 text-sm"
                    style={{ border: "1px solid var(--line)" }}
                  />
                  <button
                    disabled={!rejectReason.trim() || busy === r.machine_id}
                    onClick={() => reject(r)}
                    className="rounded-lg px-3 py-1 text-xs text-white"
                    style={{ background: "var(--danger)" }}
                  >
                    Confirm reject
                  </button>
                </div>
              )}
            </div>
          ))}
          {pastReview.length > 0 && (
            <div className="text-xs" style={{ color: "var(--warn)" }}>
              Past review date:{" "}
              {pastReview
                .map((r) => `${r.official_name} (${r.review_by})`)
                .join(", ")}
            </div>
          )}
        </div>
      </Card>

      <Card
        title="Machines"
        right={
          <div className="flex gap-2 text-xs">
            <select
              value={archFilter}
              onChange={(e) => setArchFilter(e.target.value)}
              className="rounded-lg px-2 py-1"
              style={{ border: "1px solid var(--line)" }}
            >
              <option value="">All archetypes</option>
              {archetypes.map((a) => (
                <option key={a} value={a}>
                  {archCounts[a]?.label ?? a}
                </option>
              ))}
            </select>
            <select
              value={postureFilter}
              onChange={(e) => setPostureFilter(e.target.value)}
              className="rounded-lg px-2 py-1"
              style={{ border: "1px solid var(--line)" }}
            >
              <option value="">All postures</option>
              {Object.entries(POSTURE_LABEL).map(([k, l]) => (
                <option key={k} value={k}>
                  {l}
                </option>
              ))}
            </select>
          </div>
        }
      >
        {loading ? (
          <div className="text-sm" style={{ color: "var(--muted)" }}>
            Loading…
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table
              className="w-full text-xs"
              data-testid="strategy-machine-table"
            >
              <thead style={{ color: "var(--muted)" }}>
                <tr>
                  {header("Machine", "official_name")}
                  {header("Archetype", "archetype")}
                  {header("Posture", "posture_proposed")}
                  {header("Age", "age_days")}
                  {header("Rev/day", "rev_day")}
                  {header("GP/day", "gp_day")}
                  {header("Units/day", "units_day")}
                  {header("Bench rev/day", "benchmark_rev_day_90")}
                  {header("Perf idx", "performance_index")}
                  {header("Mix gap", "mix_gap")}
                  {header("Avg month", "month_net_rev")}
                  {header("Era rev", "life_net_rev")}
                  {header("Ticket", "ticket")}
                  {header("Card", "card_share")}
                  {header("Lunch", "weekday_lunch_share")}
                  {header("Weekend", "weekend_share")}
                  {header("Drinks", "drinks_share")}
                  {header("Top5", "top5_shelf_share")}
                  {header("Dead", "dead_shelf_pct")}
                  {header("Ramp", "ramp_index")}
                  {header("COGS cov", "cogs_coverage")}
                </tr>
              </thead>
              <tbody>
                {sorted.map((r) => (
                  <tr
                    key={r.machine_id}
                    className="cursor-pointer hover:bg-[var(--brand-tint)]"
                    style={{ borderTop: "1px solid var(--line)" }}
                    onClick={() => setOpenId(r.machine_id)}
                  >
                    <td className="whitespace-nowrap px-2 py-1.5 font-medium">
                      {r.official_name}
                    </td>
                    <td className="whitespace-nowrap px-2 py-1.5">
                      <span
                        className="mr-1 inline-block h-2 w-2 rounded-full"
                        style={{
                          background: archetypeColor(r.archetype, archetypes),
                        }}
                      />
                      {r.archetype_label}
                      {r.archetype_method === "manual" ? " (manual)" : ""}
                    </td>
                    <td className="whitespace-nowrap px-2 py-1.5">
                      {r.in_refill === false && (
                        <Pill
                          color="#a3a09a"
                          outline
                          title="include_in_refill is off: the posture is kept but the engine ignores it and no new proposals are made"
                        >
                          not in refill
                        </Pill>
                      )}
                      {r.posture ? (
                        <Pill color={POSTURE_COLOR[r.posture]}>
                          {POSTURE_LABEL[r.posture]}
                        </Pill>
                      ) : null}
                      {r.posture_proposed &&
                        r.posture_proposed !== r.posture && (
                          <Pill
                            color={POSTURE_COLOR[r.posture_proposed]}
                            outline
                            title="Proposed by the model"
                          >
                            {POSTURE_LABEL[r.posture_proposed]} (proposed)
                          </Pill>
                        )}
                    </td>
                    <td className="px-2 py-1.5">{r.age_days}</td>
                    <td className="px-2 py-1.5">{num(r.rev_day, 0)}</td>
                    <td className="px-2 py-1.5">{num(r.gp_day, 0)}</td>
                    <td className="px-2 py-1.5">{num(r.units_day, 1)}</td>
                    <td className="px-2 py-1.5">
                      {num(r.benchmark_rev_day_90, 0)}
                    </td>
                    <td className="px-2 py-1.5">{pct(r.performance_index)}</td>
                    <td className="px-2 py-1.5">{pct(r.mix_gap)}</td>
                    <td className="px-2 py-1.5">{num(r.month_net_rev, 0)}</td>
                    <td className="px-2 py-1.5">{num(r.life_net_rev, 0)}</td>
                    <td className="px-2 py-1.5">{num(r.ticket, 2)}</td>
                    <td className="px-2 py-1.5">{pct(r.card_share)}</td>
                    <td className="px-2 py-1.5">
                      {pct(r.weekday_lunch_share)}
                    </td>
                    <td className="px-2 py-1.5">{pct(r.weekend_share)}</td>
                    <td className="px-2 py-1.5">{pct(r.drinks_share)}</td>
                    <td className="px-2 py-1.5" title={r.concentration ?? ""}>
                      {pct(r.top5_shelf_share)}
                    </td>
                    <td className="px-2 py-1.5">{pct(r.dead_shelf_pct)}</td>
                    <td className="px-2 py-1.5">
                      {r.ramp_index !== null ? num(r.ramp_index, 2) : ""}
                    </td>
                    <td className="px-2 py-1.5">{pct(r.cogs_coverage)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      <MachineDrawer
        machineId={openId}
        onClose={() => setOpenId(null)}
        onSaved={() => setReload((n) => n + 1)}
      />
    </div>
  );
}
