"use client";

// PRD-142a section 7: machine detail drawer. KPI cards, T+ adoption vs fleet
// median, hour and weekday profiles, shelf grid by quadrant, product table
// (here vs fleet vs siblings), category balance, posture editor and history.

import { useEffect, useRef, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  Bar,
  BarChart,
  CartesianGrid,
  Legend,
  Line,
  LineChart,
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
  MACHINE_POSTURES,
  num,
  pct,
  Pill,
  POSTURE_COLOR,
  POSTURE_LABEL,
  Segmented,
} from "./shared";

/* eslint-disable @typescript-eslint/no-explicit-any */
type Detail = Record<string, any>;

const QUADRANT_COLOR: Record<string, string> = {
  Prime: "#15803d",
  "Volume-cheap": "#7ba69b",
  "Premium-slow": "#e1b460",
  Weak: "#b5804a",
  Dead: "#dc2626",
  "Too new": "#1d4ed8",
  Empty: "#e7e5e0",
};
const WEEKDAY = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

interface ShelfOverride {
  shelf_code: string;
  action: "lock" | "reset" | "swap_now";
  note?: string;
}

export default function MachineDrawer({
  machineId,
  onClose,
  onSaved,
}: {
  machineId: string | null;
  onClose: () => void;
  onSaved: () => void;
}) {
  const sb = useRef<SupabaseClient | null>(null);
  const [loaded, setLoaded] = useState<{ key: string; data: Detail | null }>({
    key: "",
    data: null,
  });
  const [error, setError] = useState<string | null>(null);
  const [metric, setMetric] = useState<"rev" | "units">("rev");
  const [posture, setPosture] = useState<string>("");
  const [params, setParams] = useState<Record<string, any>>({});
  const [overrides, setOverrides] = useState<ShelfOverride[]>([]);
  const [notes, setNotes] = useState("");
  const [saving, setSaving] = useState(false);
  const [savedMsg, setSaved] = useState<{ key: string; msg: string } | null>(
    null,
  );
  const [reload, setReload] = useState(0);
  const d = machineId && loaded.key === machineId ? loaded.data : null;
  const saved = savedMsg && savedMsg.key === machineId ? savedMsg.msg : null;

  useEffect(() => {
    sb.current = createClient();
    if (!machineId) return;
    let cancelled = false;
    sb.current
      .rpc("get_strategy_machine_detail", { p_machine_id: machineId })
      .then(({ data, error: e }) => {
        if (cancelled) return;
        if (e) {
          setError(e.message);
          return;
        }
        setError(null);
        setLoaded({ key: machineId, data: data as Detail });
        const s = (data as Detail)?.strategy ?? {};
        const p = s.posture ?? s.posture_proposed ?? "PROTECT_GROW";
        setPosture(p);
        setParams(
          s.params ?? (data as Detail)?.posture_defaults?.[p]?.params ?? {},
        );
        setOverrides((s.shelf_overrides ?? []) as ShelfOverride[]);
        setNotes(s.notes ?? "");
      });
    return () => {
      cancelled = true;
    };
  }, [machineId, reload]);

  function choosePosture(p: string) {
    setPosture(p);
    setParams(d?.posture_defaults?.[p]?.params ?? {});
  }

  async function save() {
    if (!sb.current || !machineId) return;
    setSaving(true);
    const { error: e } = await sb.current.rpc("set_machine_strategy", {
      p_machine_id: machineId,
      p_posture: posture,
      p_params: params,
      p_shelf_overrides: overrides,
      p_notes: notes || null,
    });
    setSaving(false);
    if (e) {
      setError(e.message);
      return;
    }
    setSaved({ key: machineId, msg: `Saved ${POSTURE_LABEL[posture]}.` });
    setReload((n) => n + 1);
    onSaved();
  }

  const f = d?.features ?? {};
  const s = d?.strategy ?? {};
  const shelves: any[] = d?.shelves ?? [];
  const cabinets = Array.from(
    new Set(shelves.map((x) => String(x.shelf_code).slice(0, 1))),
  ).sort();

  return (
    <Drawer
      open={!!machineId}
      onClose={onClose}
      title={
        <div data-testid="strategy-machine-drawer">
          {d?.machine?.official_name ?? "Machine"}
          {d?.archetype && (
            <span
              className="ml-3 text-sm font-normal"
              style={{ color: "var(--muted)" }}
            >
              {d.archetype.label}
              {d.archetype.base && d.archetype.base !== d.archetype.code
                ? ` (base ${d.archetype.base})`
                : ""}
              {" · "}era since {d.machine.era_start} · day {d.machine.age_days}
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
          {s.proposed_reason && (
            <Card title="Diagnosis">
              <div className="flex flex-wrap items-center gap-2 text-sm">
                {s.posture_proposed && (
                  <Pill color={POSTURE_COLOR[s.posture_proposed]}>
                    Proposed: {POSTURE_LABEL[s.posture_proposed]}
                  </Pill>
                )}
                {s.posture && (
                  <Pill color={POSTURE_COLOR[s.posture]}>
                    Confirmed: {POSTURE_LABEL[s.posture]}
                  </Pill>
                )}
                <span>{s.proposed_reason}</span>
              </div>
            </Card>
          )}

          <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
            <Kpi
              label="Net rev per day (90d)"
              value={aed(f.rev_day_90)}
              sub={`${num(f.units_day_90, 1)} units/day`}
            />
            <Kpi
              label="GP per day (90d)"
              value={aed(f.gp_day_90)}
              sub={f.gp_day_90 === null ? "no cost basis" : undefined}
            />
            <Kpi
              label="Average full month"
              value={aed(
                (d.monthly ?? [])
                  .filter((m: any) => m.full_month)
                  .reduce(
                    (a: number, m: any, _i: number, arr: any[]) =>
                      a + Number(m.net) / arr.length,
                    0,
                  ) || null,
              )}
              sub={`${(d.monthly ?? []).filter((m: any) => m.full_month).length} full months`}
            />
            <Kpi
              label="Lifetime (current era)"
              value={aed(
                (d.daily ?? []).reduce(
                  (a: number, x: any) => a + Number(x.net ?? 0),
                  0,
                ),
              )}
              sub={`${(d.daily ?? []).reduce((a: number, x: any) => a + Number(x.units ?? 0), 0)} units`}
            />
          </div>

          <Card
            title="Adoption since first sale (T+ days) vs fleet median"
            right={
              <Segmented
                value={metric}
                onChange={setMetric}
                options={[
                  { value: "rev", label: "Revenue" },
                  { value: "units", label: "Units" },
                ]}
              />
            }
          >
            <div style={{ height: 240 }}>
              <ResponsiveContainer>
                <LineChart
                  data={d.adoption ?? []}
                  margin={{ top: 8, right: 16, bottom: 8, left: 0 }}
                >
                  <CartesianGrid stroke="var(--line)" />
                  <XAxis dataKey="day_index" fontSize={11} />
                  <YAxis fontSize={11} />
                  <Tooltip />
                  <Legend wrapperStyle={{ fontSize: 11 }} />
                  <Line
                    type="monotone"
                    dot={false}
                    dataKey={metric === "rev" ? "cum_rev" : "cum_units"}
                    name="This machine (cumulative)"
                    stroke="var(--brand)"
                    strokeWidth={2}
                  />
                  <Line
                    type="monotone"
                    dot={false}
                    dataKey={
                      metric === "rev" ? "fleet_cum_rev" : "fleet_cum_units"
                    }
                    name="Fleet median (cumulative)"
                    stroke="var(--gold)"
                    strokeDasharray="5 4"
                    strokeWidth={2}
                  />
                </LineChart>
              </ResponsiveContainer>
            </div>
          </Card>

          <div className="grid gap-4 md:grid-cols-2">
            <Card title="Hour of day (units, 90 days)">
              <div style={{ height: 180 }}>
                <ResponsiveContainer>
                  <BarChart data={d.hours ?? []}>
                    <XAxis dataKey="hour" fontSize={10} />
                    <YAxis fontSize={10} />
                    <Tooltip />
                    <Bar dataKey="units" fill="var(--chart-1)" />
                  </BarChart>
                </ResponsiveContainer>
              </div>
            </Card>
            <Card title="Weekday (net rev, 90 days)">
              <div style={{ height: 180 }}>
                <ResponsiveContainer>
                  <BarChart
                    data={(d.weekdays ?? []).map((w: any) => ({
                      ...w,
                      day: WEEKDAY[w.isodow],
                    }))}
                  >
                    <XAxis dataKey="day" fontSize={10} />
                    <YAxis fontSize={10} />
                    <Tooltip />
                    <Bar dataKey="net" fill="var(--chart-2)" />
                  </BarChart>
                </ResponsiveContainer>
              </div>
            </Card>
          </div>

          <Card title="Shelves (90 days, coloured by quadrant against all population lanes)">
            <div className="mb-2 flex flex-wrap gap-2 text-[11px]">
              {Object.entries(QUADRANT_COLOR).map(([k, c]) => (
                <span key={k} className="flex items-center gap-1">
                  <span
                    className="inline-block h-3 w-3 rounded"
                    style={{ background: c }}
                  />{" "}
                  {k}
                </span>
              ))}
            </div>
            {cabinets.map((cab) => (
              <div
                key={cab}
                className="mb-2 grid grid-cols-4 gap-1.5 md:grid-cols-8"
              >
                {shelves
                  .filter((x) => String(x.shelf_code).startsWith(cab))
                  .map((x) => (
                    <div
                      key={x.shelf_code}
                      className="rounded-md p-1.5 text-[10px] leading-tight"
                      style={{
                        background: QUADRANT_COLOR[x.quadrant] ?? "#e7e5e0",
                        color:
                          x.quadrant === "Empty" ||
                          x.quadrant === "Premium-slow"
                            ? "var(--ink)"
                            : "white",
                      }}
                      title={`${x.quadrant} · rev rank ${pct(x.rev_pct_rank)} · units rank ${pct(x.units_pct_rank)}`}
                    >
                      <div className="font-semibold">
                        {x.shelf_code} · {x.size_class}
                      </div>
                      <div className="truncate">
                        {x.product ?? x.shelf_product_name ?? "empty"}
                      </div>
                      <div>
                        {num(x.units_slot_day, 2)} u/d ·{" "}
                        {num(x.rev_slot_day, 1)} AED/d
                      </div>
                      {x.slot_age_days !== null && (
                        <div>age {x.slot_age_days}d</div>
                      )}
                    </div>
                  ))}
              </div>
            ))}
          </Card>

          <Card title="Products here vs fleet vs siblings (units per selling week, 90 days)">
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead style={{ color: "var(--muted)" }}>
                  <tr>
                    <th className="px-2 py-1 text-left">Product</th>
                    <th className="px-2 py-1 text-left">Units</th>
                    <th className="px-2 py-1 text-left">Net rev</th>
                    <th className="px-2 py-1 text-left">GP (costed)</th>
                    <th className="px-2 py-1 text-left">Share</th>
                    <th className="px-2 py-1 text-left">Here</th>
                    <th className="px-2 py-1 text-left">Fleet median</th>
                    <th className="px-2 py-1 text-left">Siblings</th>
                    <th className="px-2 py-1 text-left">Read</th>
                  </tr>
                </thead>
                <tbody>
                  {(d.products ?? []).map((p: any) => (
                    <tr
                      key={p.pod_product_id}
                      style={{ borderTop: "1px solid var(--line)" }}
                    >
                      <td className="px-2 py-1">{p.pod_product_name}</td>
                      <td className="px-2 py-1">{p.units}</td>
                      <td className="px-2 py-1">{num(p.net, 0)}</td>
                      <td className="px-2 py-1">{num(p.gp_on_costed, 0)}</td>
                      <td className="px-2 py-1">{pct(p.unit_share)}</td>
                      <td className="px-2 py-1">{num(p.velocity_here, 2)}</td>
                      <td className="px-2 py-1">
                        {num(p.velocity_fleet_median, 2)}
                      </td>
                      <td className="px-2 py-1">
                        {num(p.velocity_siblings, 2)}
                      </td>
                      <td className="px-2 py-1">
                        <Pill
                          color={
                            p.label === "Local hero"
                              ? "#15803d"
                              : p.label === "Underperformer"
                                ? "#dc2626"
                                : "#6b6860"
                          }
                        >
                          {p.label}
                        </Pill>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Card>

          <Card title="Category balance (share of lanes vs share of net rev, 90 days)">
            <div style={{ height: 220 }}>
              <ResponsiveContainer>
                <BarChart
                  data={(d.category_balance ?? []).map((c: any) => ({
                    ...c,
                    lanes: Number(c.lane_share) * 100,
                    rev: Number(c.rev_share) * 100,
                  }))}
                  layout="vertical"
                  margin={{ left: 40 }}
                >
                  <XAxis type="number" fontSize={10} unit="%" />
                  <YAxis
                    type="category"
                    dataKey="cluster_label"
                    fontSize={10}
                    width={150}
                  />
                  <Tooltip formatter={(v) => `${Number(v).toFixed(0)}%`} />
                  <Legend wrapperStyle={{ fontSize: 11 }} />
                  <Bar dataKey="lanes" name="Lanes" fill="var(--chart-3)" />
                  <Bar dataKey="rev" name="Net rev" fill="var(--chart-1)" />
                </BarChart>
              </ResponsiveContainer>
            </div>
            <div className="mt-1 text-xs" style={{ color: "var(--muted)" }}>
              {(d.category_balance ?? [])
                .filter((c: any) => c.read !== "balanced")
                .map((c: any) => `${c.cluster_label} ${c.read}`)
                .join(" · ") || "No cluster is 15 points off balance."}
            </div>
          </Card>

          <Card title="Posture editor">
            <div
              className="space-y-3 text-sm"
              data-testid="strategy-posture-editor"
            >
              <div className="flex flex-wrap gap-2">
                {MACHINE_POSTURES.map((p) => (
                  <button
                    key={p}
                    onClick={() => choosePosture(p)}
                    className="rounded-lg px-3 py-1 text-xs font-medium"
                    style={
                      posture === p
                        ? { background: POSTURE_COLOR[p], color: "white" }
                        : {
                            border: `1px solid ${POSTURE_COLOR[p]}`,
                            color: POSTURE_COLOR[p],
                          }
                    }
                  >
                    {POSTURE_LABEL[p]}
                    {s.posture_proposed === p ? " (proposed)" : ""}
                  </button>
                ))}
              </div>
              <div className="grid gap-2 md:grid-cols-3">
                {Object.entries(params).map(([k, v]) => (
                  <label
                    key={k}
                    className="flex items-center justify-between gap-2 rounded-lg px-2 py-1"
                    style={{ border: "1px solid var(--line)" }}
                  >
                    <span className="text-xs">{k.replace(/_/g, " ")}</span>
                    {typeof v === "boolean" ? (
                      <input
                        type="checkbox"
                        checked={v}
                        onChange={(e) =>
                          setParams({ ...params, [k]: e.target.checked })
                        }
                      />
                    ) : (
                      <input
                        value={String(v)}
                        onChange={(e) =>
                          setParams({
                            ...params,
                            [k]:
                              typeof v === "number"
                                ? Number(e.target.value)
                                : e.target.value,
                          })
                        }
                        className="w-28 rounded px-1 text-xs"
                        style={{ border: "1px solid var(--line)" }}
                      />
                    )}
                  </label>
                ))}
              </div>
              <div>
                <div className="mb-1 text-xs" style={{ color: "var(--muted)" }}>
                  Shelf overrides (applied by the engine in PRD-142b)
                </div>
                {overrides.map((o, i) => (
                  <div key={i} className="mb-1 flex gap-2">
                    <select
                      value={o.shelf_code}
                      onChange={(e) =>
                        setOverrides(
                          overrides.map((x, j) =>
                            j === i ? { ...x, shelf_code: e.target.value } : x,
                          ),
                        )
                      }
                      className="rounded px-1 text-xs"
                      style={{ border: "1px solid var(--line)" }}
                    >
                      {shelves.map((x) => (
                        <option key={x.shelf_code} value={x.shelf_code}>
                          {x.shelf_code}
                        </option>
                      ))}
                    </select>
                    <select
                      value={o.action}
                      onChange={(e) =>
                        setOverrides(
                          overrides.map((x, j) =>
                            j === i
                              ? {
                                  ...x,
                                  action: e.target
                                    .value as ShelfOverride["action"],
                                }
                              : x,
                          ),
                        )
                      }
                      className="rounded px-1 text-xs"
                      style={{ border: "1px solid var(--line)" }}
                    >
                      <option value="lock">lock</option>
                      <option value="reset">reset</option>
                      <option value="swap_now">swap now</option>
                    </select>
                    <input
                      value={o.note ?? ""}
                      placeholder="note"
                      onChange={(e) =>
                        setOverrides(
                          overrides.map((x, j) =>
                            j === i ? { ...x, note: e.target.value } : x,
                          ),
                        )
                      }
                      className="flex-1 rounded px-1 text-xs"
                      style={{ border: "1px solid var(--line)" }}
                    />
                    <button
                      onClick={() =>
                        setOverrides(overrides.filter((_, j) => j !== i))
                      }
                      className="text-xs"
                      style={{ color: "var(--danger)" }}
                    >
                      remove
                    </button>
                  </div>
                ))}
                <button
                  onClick={() =>
                    setOverrides([
                      ...overrides,
                      {
                        shelf_code: shelves[0]?.shelf_code ?? "A01",
                        action: "lock",
                      },
                    ])
                  }
                  className="text-xs underline"
                >
                  Add shelf override
                </button>
              </div>
              <textarea
                value={notes}
                onChange={(e) => setNotes(e.target.value)}
                placeholder="Notes"
                className="w-full rounded-lg p-2 text-sm"
                style={{ border: "1px solid var(--line)" }}
                rows={2}
              />
              <div className="flex items-center gap-3">
                <button
                  disabled={saving || !posture}
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
                  The engine reads confirmed postures once PRD-142b ships; until
                  then this is recorded only.
                </span>
              </div>
            </div>
          </Card>

          <Card title="Posture and archetype history">
            {(d.history ?? []).length === 0 ? (
              <div className="text-sm" style={{ color: "var(--muted)" }}>
                No changes yet.
              </div>
            ) : (
              <ul className="space-y-1 text-xs">
                {(d.history ?? []).map((h: any, i: number) => (
                  <li key={i}>
                    {new Date(h.changed_at).toLocaleString("en-GB", {
                      timeZone: "Asia/Dubai",
                    })}{" "}
                    · {h.field} · {h.source} · {JSON.stringify(h.old)} →{" "}
                    {JSON.stringify(h.new?.posture ?? h.new)}
                  </li>
                ))}
              </ul>
            )}
            <div className="mt-2 text-xs" style={{ color: "var(--muted)" }}>
              Eras:{" "}
              {(d.eras ?? [])
                .map(
                  (e: any) =>
                    `${e.venue_label} ${e.era_start} to ${e.era_end ?? "now"}`,
                )
                .join(" · ")}
            </div>
          </Card>
        </div>
      )}
    </Drawer>
  );
}
