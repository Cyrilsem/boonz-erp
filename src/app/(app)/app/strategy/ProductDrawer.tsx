"use client";

// PRD-142a section 7: product detail drawer. Weekly series with the prime
// window shaded, best and worst machines, archetype bars, supply block,
// posture editor and history.

import { useEffect, useRef, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  Bar,
  BarChart,
  CartesianGrid,
  Line,
  LineChart,
  ReferenceArea,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { createClient } from "@/lib/supabase/client";
import {
  aed,
  Card,
  Drawer,
  Kpi,
  num,
  pct,
  Pill,
  PLAYBOOK_COLOR,
  PLAYBOOK_LABEL,
  PRODUCT_POSTURES,
  type Population,
} from "./shared";

/* eslint-disable @typescript-eslint/no-explicit-any */

function addDays(iso: string, days: number) {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export default function ProductDrawer({
  podProductId,
  population,
  onClose,
  onSaved,
}: {
  podProductId: string | null;
  population: Population;
  onClose: () => void;
  onSaved: () => void;
}) {
  const sb = useRef<SupabaseClient | null>(null);
  const [loaded, setLoaded] = useState<{ key: string; data: any }>({ key: "", data: null });
  const [error, setError] = useState<string | null>(null);
  const [posture, setPosture] = useState("");
  const [targets, setTargets] = useState("");
  const [notes, setNotes] = useState("");
  const [saving, setSaving] = useState(false);
  const [savedMsg, setSaved] = useState<{ key: string; msg: string } | null>(null);
  const [reload, setReload] = useState(0);
  const d = podProductId && loaded.key === podProductId ? loaded.data : null;
  const saved = savedMsg && savedMsg.key === podProductId ? savedMsg.msg : null;

  useEffect(() => {
    sb.current = createClient();
    if (!podProductId) return;
    let cancelled = false;
    sb.current
      .rpc("get_strategy_product_detail", {
        p_pod_product_id: podProductId,
        p_population: population,
      })
      .then(({ data, error: e }) => {
        if (cancelled) return;
        if (e) {
          setError(e.message);
          return;
        }
        setError(null);
        setLoaded({ key: podProductId, data });
        const s = data?.strategy ?? {};
        setPosture(s.posture ?? s.posture_proposed ?? "HOLD");
        setTargets((s.target_archetypes ?? []).join(", "));
        setNotes(s.notes ?? "");
      });
    return () => {
      cancelled = true;
    };
  }, [podProductId, population, reload]);

  async function save() {
    if (!sb.current || !podProductId) return;
    setSaving(true);
    const t = targets
      .split(",")
      .map((x) => x.trim())
      .filter(Boolean);
    const { error: e } = await sb.current.rpc("set_product_strategy", {
      p_pod_product_id: podProductId,
      p_posture: posture,
      p_target_archetypes: t.length ? t : null,
      p_notes: notes || null,
    });
    setSaving(false);
    if (e) {
      setError(e.message);
      return;
    }
    setSaved({ key: podProductId, msg: `Saved ${posture}.` });
    setReload((n) => n + 1);
    onSaved();
  }

  const pb = d?.playbook ?? {};
  const s = d?.strategy ?? {};
  const sup = d?.supply ?? {};
  const week0: string | undefined = d?.week0;
  const series = (pb.series_units ?? []).map((u: number, i: number) => ({
    week: week0 ? addDays(week0, 7 * i) : String(i),
    units: u,
    machines: pb.series_machines?.[i] ?? 0,
  }));
  const primeStart: string | undefined = pb.prime_week_start ?? undefined;
  const primeEnd = primeStart ? addDays(primeStart, 21) : undefined;
  const machines: any[] = d?.machines ?? [];

  return (
    <Drawer
      open={!!podProductId}
      onClose={onClose}
      title={
        <div data-testid="strategy-product-drawer">
          {pb.pod_product_name ?? "Product"}
          {pb.playbook && (
            <span className="ml-3 align-middle">
              <Pill color={PLAYBOOK_COLOR[pb.playbook]}>
                {PLAYBOOK_LABEL[pb.playbook]}
              </Pill>
            </span>
          )}
        </div>
      }
    >
      {error && (
        <div
          className="mb-3 rounded-lg px-3 py-2 text-sm"
          style={{ background: "var(--danger-bg)", color: "var(--danger)" }}
        >
          {error}
        </div>
      )}
      {!d ? (
        <div className="text-sm" style={{ color: "var(--muted)" }}>
          Loading…
        </div>
      ) : (
        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
            <Kpi
              label="Now (8 wk)"
              value={`${num(pb.velocity, 2)}/wk @ ${pct(pb.coverage)}`}
              sub={`${num(pb.cur_units, 0)} units · ${aed(pb.net_rev_8w)}`}
            />
            <Kpi
              label="Prime (best 4 wk)"
              value={`${num(pb.prime_velocity, 2)}/wk @ ${pct(pb.prime_coverage)}`}
              sub={
                pb.prime_week_start
                  ? `${pb.prime_weeks_ago} weeks ago · ${num(pb.prime_units, 0)} units`
                  : "no prime"
              }
            />
            <Kpi
              label="Retention"
              value={pct(pb.retention)}
              sub={`${pb.maturity} · ${num(pb.months_live, 1)} months`}
            />
            <Kpi
              label="Supply"
              value={sup.wh_status ?? "–"}
              sub={`WH ${sup.wh_units_central ?? "n/a"} · cover ${num(sup.weeks_of_cover, 1)} wk · PO ${num(sup.open_po_units, 0)} · deployed ${num(sup.deployed_units, 0)}`}
            />
          </div>

          <Card title="Why this label">
            <div className="text-xs" style={{ color: "var(--foreground)" }}>
              {Object.entries(pb.reason ?? {})
                .filter(([, v]) => v !== null)
                .map(
                  ([k, v]) =>
                    `${k.replace(/_/g, " ")}: ${typeof v === "number" ? num(v, 2) : String(v)}`,
                )
                .join(" · ")}
            </div>
          </Card>

          <Card title="Weekly units since the series start (prime window shaded)">
            <div style={{ height: 240 }}>
              <ResponsiveContainer>
                <LineChart
                  data={series}
                  margin={{ top: 8, right: 16, bottom: 8, left: 0 }}
                >
                  <CartesianGrid stroke="var(--line)" />
                  <XAxis dataKey="week" fontSize={10} />
                  <YAxis fontSize={10} />
                  <Tooltip />
                  {primeStart && primeEnd && (
                    <ReferenceArea
                      x1={primeStart}
                      x2={primeEnd}
                      fill="var(--gold)"
                      fillOpacity={0.25}
                    />
                  )}
                  <Line
                    dataKey="units"
                    dot={false}
                    stroke="var(--brand)"
                    strokeWidth={2}
                    name="Units"
                  />
                  <Line
                    dataKey="machines"
                    dot={false}
                    stroke="var(--chart-3)"
                    strokeDasharray="4 3"
                    name="Machines selling"
                  />
                </LineChart>
              </ResponsiveContainer>
            </div>
          </Card>

          <div className="grid gap-4 md:grid-cols-2">
            <Card title="Machines (8 weeks): best and worst">
              <table className="w-full text-xs">
                <thead style={{ color: "var(--muted)" }}>
                  <tr>
                    <th className="px-2 py-1 text-left">Machine</th>
                    <th className="px-2 py-1 text-left">Units</th>
                    <th className="px-2 py-1 text-left">Velocity</th>
                    <th className="px-2 py-1 text-left">Net rev</th>
                  </tr>
                </thead>
                <tbody>
                  {(machines.length > 10
                    ? [...machines.slice(0, 5), ...machines.slice(-5)]
                    : machines
                  ).map((m: any) => (
                    <tr
                      key={m.machine_id}
                      style={{ borderTop: "1px solid var(--line)" }}
                    >
                      <td className="px-2 py-1">{m.official_name}</td>
                      <td className="px-2 py-1">{m.units}</td>
                      <td className="px-2 py-1">{num(m.velocity, 2)}</td>
                      <td className="px-2 py-1">{num(m.net, 0)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </Card>
            <Card title="By archetype (units per selling machine-week)">
              <div style={{ height: 200 }}>
                <ResponsiveContainer>
                  <BarChart
                    data={d.archetypes ?? []}
                    layout="vertical"
                    margin={{ left: 40 }}
                  >
                    <XAxis type="number" fontSize={10} />
                    <YAxis
                      type="category"
                      dataKey="archetype"
                      fontSize={9}
                      width={140}
                    />
                    <Tooltip />
                    <Bar dataKey="velocity" fill="var(--chart-1)" />
                  </BarChart>
                </ResponsiveContainer>
              </div>
            </Card>
          </div>

          <Card title="Product posture">
            <div className="space-y-3 text-sm">
              <div className="flex flex-wrap gap-2">
                {PRODUCT_POSTURES.map((p) => (
                  <button
                    key={p}
                    onClick={() => setPosture(p)}
                    className="rounded-lg px-3 py-1 text-xs font-medium"
                    style={
                      posture === p
                        ? { background: "var(--brand)", color: "white" }
                        : {
                            border: "1px solid var(--brand)",
                            color: "var(--brand)",
                          }
                    }
                  >
                    {p}
                    {s.posture_proposed === p ? " (proposed)" : ""}
                  </button>
                ))}
              </div>
              <input
                value={targets}
                onChange={(e) => setTargets(e.target.value)}
                placeholder="Target archetypes, comma separated (GROW)"
                className="w-full rounded-lg px-2 py-1 text-xs"
                style={{ border: "1px solid var(--line)" }}
              />
              <textarea
                value={notes}
                onChange={(e) => setNotes(e.target.value)}
                placeholder="Notes"
                rows={2}
                className="w-full rounded-lg p-2 text-sm"
                style={{ border: "1px solid var(--line)" }}
              />
              <div className="flex items-center gap-3">
                <button
                  disabled={saving}
                  onClick={save}
                  className="rounded-lg px-4 py-1.5 text-sm font-medium text-white"
                  style={{ background: "var(--brand)" }}
                >
                  {saving ? "Saving…" : "Confirm posture"}
                </button>
                {saved && (
                  <span className="text-xs" style={{ color: "var(--success)" }}>
                    {saved}
                  </span>
                )}
                <span className="text-xs" style={{ color: "var(--muted)" }}>
                  Procurement and the swap pool read confirmed product postures
                  once PRD-142b ships.
                </span>
              </div>
              {(d.history ?? []).length > 0 && (
                <ul
                  className="space-y-1 text-xs"
                  style={{ color: "var(--muted)" }}
                >
                  {(d.history ?? []).map((h: any, i: number) => (
                    <li key={i}>
                      {new Date(h.changed_at).toLocaleString("en-GB", {
                        timeZone: "Asia/Dubai",
                      })}{" "}
                      · {h.source} · {JSON.stringify(h.old)} → {h.new?.posture}
                    </li>
                  ))}
                </ul>
              )}
            </div>
          </Card>
        </div>
      )}
    </Drawer>
  );
}
