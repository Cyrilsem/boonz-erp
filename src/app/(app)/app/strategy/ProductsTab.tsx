"use client";

// PRD-142a section 7, Products tab: the Portfolio Map rebuilt on the fact
// layer. Scope / position / playbook chips / cluster / min units / label all,
// velocity x coverage map with median lines and prime-to-now trails, KPI strip,
// cluster table, full table, product x archetype heatmap, PO hygiene,
// quarantined and uncategorised lists, product drawer.

import { useEffect, useMemo, useRef, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  CartesianGrid,
  Cell,
  LabelList,
  Line,
  LineChart,
  ReferenceLine,
  ResponsiveContainer,
  Scatter,
  ScatterChart,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { createClient } from "@/lib/supabase/client";
import ProductDrawer from "./ProductDrawer";
import {
  aed,
  Card,
  Kpi,
  MATURITY_COLOR,
  num,
  pct,
  Pill,
  PLAYBOOK_COLOR,
  PLAYBOOK_LABEL,
  PLAYBOOK_ORDER,
  Segmented,
  sortRows,
  type Population,
} from "./shared";

/* eslint-disable @typescript-eslint/no-explicit-any */
export interface ProductRow {
  pod_product_id: string;
  name: string;
  cluster: string;
  cluster_label: string;
  maturity: string;
  months_live: number | null;
  units_8w: number | null;
  velocity: number | null;
  coverage: number | null;
  momentum: number | null;
  prime_velocity: number | null;
  prime_coverage: number | null;
  prime_units: number | null;
  prime_weeks_ago: number | null;
  retention: number | null;
  net_rev_8w: number | null;
  gp_8w: number | null;
  price_per_unit: number | null;
  aed_per_facing_week: number | null;
  wh_status: string | null;
  weeks_of_cover: number | null;
  open_po_units: number | null;
  playbook: string;
  fuel_risk: boolean;
  posture: string | null;
  posture_proposed: string | null;
  target_archetypes: string[] | null;
  series_units: number[];
  reason: Record<string, any>;
}

type Position = "current" | "prime" | "trails";

export default function ProductsTab() {
  const sb = useRef<SupabaseClient | null>(null);
  const [population, setPopulation] = useState<Population>("boonz");
  const [position, setPosition] = useState<Position>("trails");
  const [xMode, setXMode] = useState<"coverage" | "facing">("coverage");
  const [data, setData] = useState<any>(null);
  const [matrix, setMatrix] = useState<any>(null);
  const [error, setError] = useState<string | null>(null);
  const [chips, setChips] = useState<string[]>([]);
  const [cluster, setCluster] = useState("");
  const [minUnits, setMinUnits] = useState(8);
  const [labelAll, setLabelAll] = useState(false);
  const [openId, setOpenId] = useState<string | null>(null);
  const [sortKey, setSortKey] = useState<keyof ProductRow | null>("net_rev_8w");
  const [sortDir, setSortDir] = useState<1 | -1>(-1);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    sb.current = createClient();
    let cancelled = false;
    Promise.all([
      sb.current.rpc("get_strategy_products", {
        p_population: population,
        p_position: position,
      }),
      sb.current.rpc("get_strategy_product_archetype_matrix", {
        p_population: population,
      }),
    ]).then(([p, m]) => {
      if (cancelled) return;
      if (p.error || m.error) {
        setError((p.error ?? m.error)?.message ?? "load failed");
        return;
      }
      setError(null);
      setData(p.data);
      setMatrix(m.data);
    });
    return () => {
      cancelled = true;
    };
  }, [population, position, reload]);

  const products: ProductRow[] = useMemo(
    () => (data?.products ?? []) as ProductRow[],
    [data],
  );
  const live = useMemo(
    () =>
      products.filter(
        (p) => p.playbook !== "SUPERSEDED" && p.playbook !== "ANOMALY",
      ),
    [products],
  );
  const shown = useMemo(
    () =>
      live.filter(
        (p) =>
          (chips.length === 0 || chips.includes(p.playbook)) &&
          (!cluster || p.cluster === cluster) &&
          (p.units_8w ?? 0) >= minUnits,
      ),
    [live, chips, cluster, minUnits],
  );
  const sorted = useMemo(
    () => sortRows(shown, sortKey, sortDir),
    [shown, sortKey, sortDir],
  );
  const med = data?.medians ?? {};
  const kpis = data?.kpis ?? {};

  function xOf(p: ProductRow, prime: boolean) {
    if (xMode === "facing")
      return Math.max(
        0.1,
        ((prime ? p.prime_velocity : p.velocity) ?? 0) *
          (p.price_per_unit ?? 0),
      );
    return ((prime ? p.prime_coverage : p.coverage) ?? 0) * 100;
  }
  function yOf(p: ProductRow, prime: boolean) {
    return Math.max(0.1, (prime ? p.prime_velocity : p.velocity) ?? 0.1);
  }
  const points = shown
    .filter((p) =>
      position === "prime" ? p.prime_velocity !== null : p.velocity !== null,
    )
    .map((p) => ({
      id: p.pod_product_id,
      name: p.name,
      x: xOf(p, position === "prime"),
      y: yOf(p, position === "prime"),
      maturity: p.maturity,
      playbook: p.playbook,
      p,
    }));

  function toggleChip(c: string) {
    setChips(chips.includes(c) ? chips.filter((x) => x !== c) : [...chips, c]);
  }

  function th(label: string, key: keyof ProductRow) {
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

  const archetypes: { code: string; label: string }[] =
    matrix?.archetypes ?? [];
  const cellMap = useMemo(() => {
    const m = new Map<string, any>();
    for (const c of matrix?.cells ?? [])
      m.set(`${c.pod_product_id}|${c.archetype}`, c);
    return m;
  }, [matrix]);
  const heatProducts = sorted.slice(0, 25);

  return (
    <div className="space-y-4" data-testid="strategy-products">
      <div className="flex flex-wrap items-center gap-3">
        <Segmented
          value={population}
          onChange={setPopulation}
          options={[
            { value: "boonz", label: "Boonz sourcing" },
            { value: "partner", label: "Partner sourcing" },
            { value: "all", label: "All machines" },
          ]}
        />
        <Segmented
          value={position}
          onChange={setPosition}
          options={[
            { value: "current", label: "Current (8 wk)" },
            { value: "prime", label: "At prime" },
            { value: "trails", label: "Trails" },
          ]}
        />
        <Segmented
          value={xMode}
          onChange={setXMode}
          options={[
            { value: "coverage", label: "X: coverage" },
            { value: "facing", label: "X: AED per facing" },
          ]}
        />
        <select
          value={cluster}
          onChange={(e) => setCluster(e.target.value)}
          className="rounded-lg px-2 py-1 text-xs"
          style={{ border: "1px solid var(--line)" }}
        >
          <option value="">All clusters</option>
          {(data?.clusters ?? []).map((c: any) => (
            <option key={c.cluster} value={c.cluster}>
              {c.label}
            </option>
          ))}
        </select>
        <label
          className="flex items-center gap-2 text-xs"
          style={{ color: "var(--muted)" }}
        >
          Min units {minUnits}
          <input
            type="range"
            min={0}
            max={100}
            value={minUnits}
            onChange={(e) => setMinUnits(Number(e.target.value))}
          />
        </label>
        <label
          className="flex items-center gap-2 text-xs"
          style={{ color: "var(--muted)" }}
        >
          <input
            type="checkbox"
            checked={labelAll}
            onChange={(e) => setLabelAll(e.target.checked)}
          />{" "}
          Label all
        </label>
      </div>

      <div className="flex flex-wrap gap-2">
        {PLAYBOOK_ORDER.map((c) => (
          <button
            key={c}
            onClick={() => toggleChip(c)}
            className="rounded-full px-3 py-1 text-xs font-medium"
            style={
              chips.length === 0 || chips.includes(c)
                ? { background: PLAYBOOK_COLOR[c], color: "white" }
                : {
                    border: `1px solid ${PLAYBOOK_COLOR[c]}`,
                    color: PLAYBOOK_COLOR[c],
                  }
            }
          >
            {PLAYBOOK_LABEL[c]} {kpis.by_playbook?.[c] ?? 0}
          </button>
        ))}
        {chips.length > 0 && (
          <button onClick={() => setChips([])} className="text-xs underline">
            clear
          </button>
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
        <Kpi
          label="Products shown"
          value={kpis.products_shown ?? "–"}
          sub={`as of ${data?.as_of ?? "…"}`}
        />
        <Kpi label="Units, 8 weeks" value={num(kpis.units_8w, 0)} />
        <Kpi
          label="Net rev, 8 weeks"
          value={aed(kpis.net_rev_8w)}
          sub="ex-VAT"
        />
        <Kpi
          label="Medians"
          value={`${num(med.median_velocity, 2)}/wk · ${pct(med.median_coverage)}`}
          sub={`top quartile ${num(med.p75_velocity, 2)}/wk`}
        />
        <Kpi
          label="Proven demand not served"
          value={`${num(kpis.unserved_units_per_week, 0)} units/wk`}
          sub="Missed the wave, prime vs now"
        />
      </div>

      <Card
        title={`Velocity (units per selling machine-week, log scale) by ${xMode === "coverage" ? "coverage" : "AED per facing per week"}`}
      >
        <div style={{ height: 460 }}>
          <ResponsiveContainer>
            <ScatterChart margin={{ top: 16, right: 24, bottom: 28, left: 8 }}>
              <CartesianGrid stroke="var(--line)" />
              <XAxis
                type="number"
                dataKey="x"
                fontSize={11}
                name={xMode === "coverage" ? "Coverage %" : "AED per facing"}
                label={{
                  value:
                    xMode === "coverage"
                      ? "Coverage (% of selling machines)"
                      : "AED per facing per week",
                  position: "insideBottom",
                  offset: -14,
                  fontSize: 11,
                }}
              />
              <YAxis
                type="number"
                dataKey="y"
                scale="log"
                domain={[0.5, 40]}
                allowDataOverflow
                fontSize={11}
                label={{
                  value: "Velocity",
                  angle: -90,
                  position: "insideLeft",
                  fontSize: 11,
                }}
              />
              {xMode === "coverage" && med.median_coverage !== undefined && (
                <ReferenceLine
                  x={Number(med.median_coverage) * 100}
                  stroke="var(--muted-2)"
                  strokeDasharray="4 4"
                  label={{ value: "median", fontSize: 10, position: "top" }}
                />
              )}
              {med.median_velocity !== undefined && (
                <ReferenceLine
                  y={Number(med.median_velocity)}
                  stroke="var(--muted-2)"
                  strokeDasharray="4 4"
                  label={{ value: "median", fontSize: 10, position: "right" }}
                />
              )}
              <Tooltip
                content={({ payload }) => {
                  const pt = payload?.[0]?.payload as
                    (typeof points)[number] | undefined;
                  if (!pt?.p) return null;
                  const p = pt.p;
                  return (
                    <div
                      className="rounded-lg px-3 py-2 text-xs shadow"
                      style={{
                        background: "var(--surface)",
                        border: "1px solid var(--line)",
                        width: 240,
                      }}
                    >
                      <div className="font-semibold">{p.name}</div>
                      <div>
                        {PLAYBOOK_LABEL[p.playbook]} · {p.maturity} ·{" "}
                        {p.cluster_label}
                      </div>
                      <div>
                        Now {num(p.velocity, 2)}/wk @ {pct(p.coverage)} · prime{" "}
                        {num(p.prime_velocity, 2)} @ {pct(p.prime_coverage)}
                      </div>
                      <div>
                        WH {p.wh_status ?? "–"} · {aed(p.net_rev_8w)} in 8 wk
                      </div>
                      <div style={{ height: 50 }}>
                        <ResponsiveContainer>
                          <LineChart
                            data={(p.series_units ?? []).map((u, i) => ({
                              i,
                              u,
                            }))}
                          >
                            <Line
                              dataKey="u"
                              dot={false}
                              stroke="var(--brand)"
                              strokeWidth={1.5}
                              isAnimationActive={false}
                            />
                          </LineChart>
                        </ResponsiveContainer>
                      </div>
                    </div>
                  );
                }}
              />
              {position === "trails" &&
                shown
                  .filter(
                    (p) => p.prime_velocity !== null && p.velocity !== null,
                  )
                  .map((p) => (
                    <Scatter
                      key={`t-${p.pod_product_id}`}
                      data={[
                        { x: xOf(p, true), y: yOf(p, true) },
                        { x: xOf(p, false), y: yOf(p, false) },
                      ]}
                      line={{
                        stroke: PLAYBOOK_COLOR[p.playbook],
                        strokeOpacity: 0.35,
                      }}
                      shape={() => <g />}
                      isAnimationActive={false}
                    />
                  ))}
              <Scatter
                data={points}
                onClick={(d) => setOpenId((d as unknown as { id: string }).id)}
                isAnimationActive={false}
              >
                {points.map((d) => (
                  <Cell
                    key={d.id}
                    fill={MATURITY_COLOR[d.maturity] ?? "#7ba69b"}
                    stroke={PLAYBOOK_COLOR[d.playbook]}
                    strokeWidth={2}
                    cursor="pointer"
                  />
                ))}
                {labelAll && (
                  <LabelList dataKey="name" position="top" fontSize={9} />
                )}
              </Scatter>
            </ScatterChart>
          </ResponsiveContainer>
        </div>
        <div
          className="mt-1 flex flex-wrap gap-3 text-[11px]"
          style={{ color: "var(--muted)" }}
        >
          {Object.entries(MATURITY_COLOR).map(([k, c]) => (
            <span key={k} className="flex items-center gap-1">
              <span
                className="inline-block h-3 w-3 rounded-full"
                style={{ background: c }}
              />{" "}
              {k}
            </span>
          ))}
          <span>
            Outline = playbook. Trails run from prime to now. Click a point for
            the product drawer.
          </span>
        </div>
      </Card>

      <Card title="Clusters">
        <table className="w-full text-xs">
          <thead style={{ color: "var(--muted)" }}>
            <tr>
              <th className="px-2 py-1 text-left">Cluster</th>
              <th className="px-2 py-1 text-left">Net rev 8 wk</th>
              <th className="px-2 py-1 text-left">Products</th>
              <th className="px-2 py-1 text-left">Read</th>
            </tr>
          </thead>
          <tbody>
            {(data?.clusters ?? []).map((c: any) => (
              <tr
                key={c.cluster}
                style={{ borderTop: "1px solid var(--line)" }}
              >
                <td className="px-2 py-1 font-medium">{c.label}</td>
                <td className="px-2 py-1">{aed(c.net_rev_8w)}</td>
                <td className="px-2 py-1">{c.products}</td>
                <td className="px-2 py-1">{c.read}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Card>

      <Card title={`Products (${sorted.length})`}>
        <div className="overflow-x-auto">
          <table
            className="w-full text-xs"
            data-testid="strategy-product-table"
          >
            <thead style={{ color: "var(--muted)" }}>
              <tr>
                {th("Product", "name")}
                {th("Playbook", "playbook")}
                {th("Posture", "posture_proposed")}
                {th("Cluster", "cluster_label")}
                {th("Maturity", "months_live")}
                {th("Units 8w", "units_8w")}
                {th("Velocity", "velocity")}
                {th("Coverage", "coverage")}
                {th("Prime vel", "prime_velocity")}
                {th("Retention", "retention")}
                {th("Momentum", "momentum")}
                {th("Net rev 8w", "net_rev_8w")}
                {th("GP 8w", "gp_8w")}
                {th("AED/facing", "aed_per_facing_week")}
                {th("WH", "wh_status")}
                {th("Cover wk", "weeks_of_cover")}
                {th("Open PO", "open_po_units")}
              </tr>
            </thead>
            <tbody>
              {sorted.map((p) => (
                <tr
                  key={p.pod_product_id}
                  className="cursor-pointer hover:bg-[var(--brand-tint)]"
                  style={{ borderTop: "1px solid var(--line)" }}
                  onClick={() => setOpenId(p.pod_product_id)}
                >
                  <td className="whitespace-nowrap px-2 py-1.5 font-medium">
                    {p.name}
                    {p.fuel_risk ? " ⚠" : ""}
                  </td>
                  <td className="px-2 py-1.5">
                    <Pill color={PLAYBOOK_COLOR[p.playbook]}>
                      {PLAYBOOK_LABEL[p.playbook]}
                    </Pill>
                  </td>
                  <td className="whitespace-nowrap px-2 py-1.5">
                    {p.posture && <Pill color="#24544a">{p.posture}</Pill>}
                    {p.posture_proposed && p.posture_proposed !== p.posture && (
                      <Pill color="#24544a" outline>
                        {p.posture_proposed} (proposed)
                      </Pill>
                    )}
                  </td>
                  <td className="whitespace-nowrap px-2 py-1.5">
                    {p.cluster_label}
                  </td>
                  <td className="px-2 py-1.5">{p.maturity}</td>
                  <td className="px-2 py-1.5">{num(p.units_8w, 0)}</td>
                  <td className="px-2 py-1.5">{num(p.velocity, 2)}</td>
                  <td className="px-2 py-1.5">{pct(p.coverage)}</td>
                  <td className="px-2 py-1.5">{num(p.prime_velocity, 2)}</td>
                  <td className="px-2 py-1.5">{pct(p.retention)}</td>
                  <td className="px-2 py-1.5">
                    {p.momentum === null
                      ? "–"
                      : p.momentum > 0.15
                        ? "▲"
                        : p.momentum < -0.15
                          ? "▼"
                          : "▬"}
                  </td>
                  <td className="px-2 py-1.5">{num(p.net_rev_8w, 0)}</td>
                  <td className="px-2 py-1.5">{num(p.gp_8w, 0)}</td>
                  <td className="px-2 py-1.5">
                    {num(p.aed_per_facing_week, 1)}
                  </td>
                  <td className="px-2 py-1.5">{p.wh_status}</td>
                  <td className="px-2 py-1.5">{num(p.weeks_of_cover, 1)}</td>
                  <td className="px-2 py-1.5">{num(p.open_po_units, 0)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>

      <Card title="What works where: velocity per selling machine-week by archetype (cell shade = ratio to the product's fleet velocity)">
        <div className="overflow-x-auto">
          <table className="text-[11px]">
            <thead>
              <tr>
                <th className="px-2 py-1 text-left">Product</th>
                {archetypes.map((a) => (
                  <th key={a.code} className="px-2 py-1 text-left font-medium">
                    {a.label}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {heatProducts.map((p) => (
                <tr key={p.pod_product_id}>
                  <td className="whitespace-nowrap px-2 py-1">{p.name}</td>
                  {archetypes.map((a) => {
                    const c = cellMap.get(`${p.pod_product_id}|${a.code}`);
                    const r = c?.ratio ?? null;
                    const bg =
                      r === null
                        ? "transparent"
                        : r >= 1.2
                          ? "#15803d"
                          : r >= 0.8
                            ? "#7ba69b"
                            : r >= 0.5
                              ? "#e1b460"
                              : "#dc2626";
                    return (
                      <td
                        key={a.code}
                        className="px-2 py-1 text-center"
                        style={{
                          background: bg,
                          color: r === null ? "var(--muted-2)" : "white",
                          minWidth: 70,
                        }}
                        title={
                          c
                            ? `${c.velocity}/wk on ${c.machines} machines, ratio ${c.ratio}`
                            : "not sold"
                        }
                      >
                        {c ? `${num(c.velocity, 1)} (${c.machines})` : "·"}
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>

      <div className="grid gap-4 md:grid-cols-3">
        <Card title="PO hygiene: open POs on cooling or exiting products">
          {(data?.po_hygiene ?? []).length === 0 ? (
            <div className="text-sm" style={{ color: "var(--muted)" }}>
              None.
            </div>
          ) : (
            <ul className="space-y-1 text-xs">
              {(data?.po_hygiene ?? []).map((x: any) => (
                <li key={x.pod_product_id}>
                  <b>{x.name}</b> ({PLAYBOOK_LABEL[x.playbook]}):{" "}
                  {x.open_po_units} on order, {x.weeks_of_cover_from_po ?? "–"}{" "}
                  weeks of cover at {x.weekly_rate}/wk
                </li>
              ))}
            </ul>
          )}
        </Card>
        <Card title="Quarantined (superseded or anomaly)">
          <ul className="space-y-1 text-xs">
            {(data?.quarantined ?? []).map((x: any) => (
              <li key={x.pod_product_id}>
                <b>{x.name}</b> · {PLAYBOOK_LABEL[x.playbook]}
                {x.note ? ` · ${x.note}` : ""}
              </li>
            ))}
          </ul>
        </Card>
        <Card title="Uncategorised pods (fix the category)">
          <ul className="space-y-1 text-xs">
            {(data?.uncategorised ?? []).map((x: any) => (
              <li key={x.pod_product_id}>{x.name}</li>
            ))}
          </ul>
        </Card>
      </div>

      <ProductDrawer
        podProductId={openId}
        population={population}
        onClose={() => setOpenId(null)}
        onSaved={() => setReload((n) => n + 1)}
      />
    </div>
  );
}
