"use client";

// Product × Machine lifecycle heatmap.
// Reads live (read-only) from slot_lifecycle + machines + pod_products +
// product_lifecycle_global. No writes. Stax rules: S9 (RLS-aware, 0-row safe),
// S10 (per-call client).

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { fetchInactiveProductIds } from "./lifecycleStatus";

interface Cell {
  score: number; // slot-weighted avg score for this product×machine
  signal: string; // worst signal across the slots
  vel: number; // summed 30d velocity
  n: number; // slot count
}

const SIGNAL_FULL: Record<string, string> = {
  STAR: "Star",
  "DOUBLE DOWN": "Double Down",
  "KEEP GROWING": "Keep Growing",
  KEEP: "Keep",
  RAMPING: "Ramping",
  WATCH: "Watch",
  "WIND DOWN": "Wind Down",
  "ROTATE OUT": "Rotate Out",
  "DEAD — SWAP NOW": "Dead — Swap Now",
};
const REC: Record<string, string> = {
  STAR: "Protect & expand.",
  "DOUBLE DOWN": "Add facings — strong seller.",
  "KEEP GROWING": "Hold, trending up.",
  KEEP: "Maintain.",
  RAMPING: "Newly placed — give 2–3 cycles.",
  WATCH: "Watch one more cycle.",
  "WIND DOWN": "Cut facings, don't re-pour deep.",
  "ROTATE OUT": "Rotate out next visit.",
  "DEAD — SWAP NOW": "Pull & swap NOW. Zero sales.",
};
// worst-first severity for the per-cell rollup
const SEV: Record<string, number> = {
  "DEAD — SWAP NOW": 1,
  "ROTATE OUT": 2,
  "WIND DOWN": 3,
  WATCH: 4,
  RAMPING: 5,
  KEEP: 6,
  "KEEP GROWING": 7,
  "DOUBLE DOWN": 8,
  STAR: 9,
};

const LOC_LABEL: Record<string, string> = {
  office: "OFFICE",
  coworking: "COWORKING",
  entertainment: "ENTERTAINMENT",
};
const LOC_ORDER: Record<string, number> = {
  office: 0,
  coworking: 1,
  entertainment: 2,
};

function scoreColor(s: number): string {
  const v = Math.max(0, Math.min(10, s));
  if (v <= 5) {
    const t = v / 5;
    return `rgb(200,${Math.round(70 + t * 130)},60)`;
  }
  const t = (v - 5) / 5;
  return `rgb(${Math.round(200 - t * 150)},200,${Math.round(60 + t * 40)})`;
}
function shortMachine(m: string): string {
  const parts = m.split("-");
  return parts.length >= 2 ? `${parts[0]}-${parts[1]}` : m;
}

function Kpi({ v, l, color }: { v: string; l: string; color?: string }) {
  return (
    <div className="rounded-lg border border-neutral-200 bg-neutral-50 px-4 py-2.5 dark:border-neutral-800 dark:bg-neutral-900">
      <div className="text-xl font-bold" style={color ? { color } : undefined}>
        {v}
      </div>
      <div className="text-[10px] uppercase tracking-wide text-neutral-500">
        {l}
      </div>
    </div>
  );
}

type Filter = "all" | "office" | "coworking" | "entertainment";

export default function HeatmapTab() {
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);
  const [cells, setCells] = useState<
    { m: string; lt: string; p: string; cell: Cell }[]
  >([]);
  const [divest, setDivest] = useState<Set<string>>(new Set());
  // product names flagged inactive (excluded from analysis)
  const [inactiveNames, setInactiveNames] = useState<Set<string>>(new Set());
  const [filter, setFilter] = useState<Filter>("all");
  const [divestOnly, setDivestOnly] = useState(false);
  const [showInactive, setShowInactive] = useState(false);
  const [tip, setTip] = useState<{
    x: number;
    y: number;
    head: string;
    body: string;
  } | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const supabase = createClient();
        const inactiveIds = await fetchInactiveProductIds();
        const [slotsRes, machinesRes, podsRes, globRes] = await Promise.all([
          supabase
            .from("slot_lifecycle")
            .select("machine_id,pod_product_id,score,signal,velocity_30d")
            .eq("is_current", true)
            .eq("archived", false)
            .limit(20000),
          supabase
            .from("machines")
            .select("machine_id,official_name,location_type,include_in_refill")
            .limit(10000),
          supabase
            .from("pod_products")
            .select("pod_product_id,pod_product_name")
            .limit(10000),
          supabase
            .from("product_lifecycle_global")
            .select("pod_product_id,signal,slot_count")
            .limit(10000),
        ]);
        if (cancelled) return;
        const slots = slotsRes.data ?? [];
        const machines = machinesRes.data ?? [];
        const pods = podsRes.data ?? [];
        const globs = globRes.data ?? [];

        const mMap = new Map(machines.map((m) => [m.machine_id, m]));
        const pMap = new Map(
          pods.map((p) => [p.pod_product_id, p.pod_product_name as string]),
        );
        const inNames = new Set<string>();
        inactiveIds.forEach((id) => {
          const nm = pMap.get(id);
          if (nm) inNames.add(nm);
        });
        setInactiveNames(inNames);

        // divest = global signal DEAD/ROTATE AND deployed (slot_count >= 1)
        const dv = new Set<string>();
        for (const g of globs) {
          if (
            (g.signal === "DEAD — SWAP NOW" || g.signal === "ROTATE OUT") &&
            (g.slot_count ?? 0) >= 1
          ) {
            const name = pMap.get(g.pod_product_id);
            if (name) dv.add(name);
          }
        }

        // aggregate slots → product×machine cells
        const agg = new Map<
          string,
          {
            m: string;
            lt: string;
            p: string;
            sum: number;
            vel: number;
            n: number;
            sev: number;
            sig: string;
          }
        >();
        for (const s of slots) {
          const mach = mMap.get(s.machine_id);
          if (!mach || mach.include_in_refill !== true) continue;
          const pname = pMap.get(s.pod_product_id);
          if (!pname) continue;
          const mn = mach.official_name as string;
          const key = `${mn}|||${pname}`;
          const sev = SEV[s.signal ?? "KEEP"] ?? 6;
          const cur = agg.get(key);
          if (!cur) {
            agg.set(key, {
              m: mn,
              lt: (mach.location_type as string) ?? "other",
              p: pname,
              sum: Number(s.score),
              vel: Number(s.velocity_30d ?? 0),
              n: 1,
              sev,
              sig: s.signal ?? "KEEP",
            });
          } else {
            cur.sum += Number(s.score);
            cur.vel += Number(s.velocity_30d ?? 0);
            cur.n += 1;
            if (sev < cur.sev) {
              cur.sev = sev;
              cur.sig = s.signal ?? "KEEP";
            }
          }
        }
        const out = Array.from(agg.values()).map((a) => ({
          m: a.m,
          lt: a.lt,
          p: a.p,
          cell: {
            score: Math.round((a.sum / a.n) * 10) / 10,
            signal: a.sig,
            vel: Math.round(a.vel * 100) / 100,
            n: a.n,
          },
        }));
        setCells(out);
        setDivest(dv);
        setLoading(false);
      } catch (e) {
        if (!cancelled) {
          setErr(e instanceof Error ? e.message : String(e));
          setLoading(false);
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const { machines, products, grid, prodAvg, stats } = useMemo(() => {
    const grid = new Map<string, Cell>();
    const locOf = new Map<string, string>();
    const prodPairs = new Map<string, [number, number]>(); // p -> [sum, n]
    for (const c of cells) {
      grid.set(`${c.p}|||${c.m}`, c.cell);
      locOf.set(c.m, c.lt);
      const pr = prodPairs.get(c.p) ?? [0, 0];
      pr[0] += c.cell.score * c.cell.n;
      pr[1] += c.cell.n;
      prodPairs.set(c.p, pr);
    }
    const prodAvg = new Map<string, number>();
    prodPairs.forEach((v, k) => prodAvg.set(k, v[1] ? v[0] / v[1] : 0));

    const machines = Array.from(locOf.keys());
    machines.sort((a, b) => {
      const la = LOC_ORDER[locOf.get(a) ?? "z"] ?? 9;
      const lb = LOC_ORDER[locOf.get(b) ?? "z"] ?? 9;
      return la - lb || a.localeCompare(b);
    });

    const products = Array.from(prodAvg.keys());
    products.sort((a, b) => {
      const da = divest.has(a) ? 0 : 1;
      const db = divest.has(b) ? 0 : 1;
      return da - db || (prodAvg.get(a) ?? 0) - (prodAvg.get(b) ?? 0);
    });

    // stats: overall + scenarios + signal distribution — EXCLUDE inactive products
    const activeCells = cells.filter((c) => !inactiveNames.has(c.p));
    let sum = 0,
      n = 0;
    const sig: Record<string, number> = {};
    let dead = 0,
      rot = 0,
      ramp = 0;
    for (const c of activeCells) {
      sum += c.cell.score * c.cell.n;
      n += c.cell.n;
      sig[c.cell.signal] = (sig[c.cell.signal] ?? 0) + c.cell.n;
      if (c.cell.signal === "DEAD — SWAP NOW") dead += c.cell.n;
      else if (c.cell.signal === "ROTATE OUT") rot += c.cell.n;
      else if (c.cell.signal === "RAMPING") ramp += c.cell.n;
    }
    const overall = n ? sum / n : 0;
    const scen = (rt?: number, mt?: number) => {
      let s2 = 0,
        n2 = 0;
      for (const c of activeCells) {
        let sc = c.cell.score;
        if (
          rt != null &&
          (c.cell.signal === "DEAD — SWAP NOW" ||
            c.cell.signal === "ROTATE OUT")
        )
          sc = rt;
        else if (mt != null && c.cell.signal === "RAMPING")
          sc = Math.max(sc, mt);
        s2 += sc * c.cell.n;
        n2 += c.cell.n;
      }
      return n2 ? s2 / n2 : 0;
    };
    const stats = {
      overall,
      slots: n,
      dead,
      rot,
      ramp,
      both: scen(6.5, 7.0),
    };
    return { machines, products, grid, prodAvg, stats };
  }, [cells, divest, inactiveNames]);

  if (loading)
    return <p className="text-neutral-500 text-sm">Loading heatmap…</p>;
  if (err)
    return (
      <p className="text-red-600 text-sm">Failed to load heatmap: {err}</p>
    );
  if (!cells.length)
    return <p className="text-neutral-500 text-sm">No lifecycle data.</p>;

  const visMachines =
    filter === "all"
      ? machines
      : machines.filter((m) => {
          const c = cells.find((x) => x.m === m);
          return c?.lt === filter;
        });
  let visProducts = divestOnly
    ? products.filter((p) => divest.has(p))
    : products;
  if (!showInactive)
    visProducts = visProducts.filter((p) => !inactiveNames.has(p));

  // header location groups
  const groups: { lt: string; span: number }[] = [];
  for (const m of visMachines) {
    const lt = cells.find((x) => x.m === m)?.lt ?? "other";
    const last = groups[groups.length - 1];
    if (last && last.lt === lt) last.span += 1;
    else groups.push({ lt, span: 1 });
  }

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-base font-semibold">Heatmap — Product × Machine</h2>
        <p className="text-xs text-neutral-500">
          {products.length} products × {machines.length} machines ·{" "}
          {stats.slots} active slots. Rows ordered worst-first; ◆ = fleet-wide
          divest candidate. Hover any cell for signal, velocity and the
          recommended action.
        </p>
      </div>

      <div className="flex flex-wrap gap-2.5">
        <Kpi v={stats.overall.toFixed(2)} l="Overall now /10" color="#d68910" />
        <Kpi
          v={String(stats.dead + stats.rot)}
          l="Dead + Rotate slots"
          color="#c0392b"
        />
        <Kpi v={String(stats.ramp)} l="Ramping (maturing)" />
        <Kpi v={stats.both.toFixed(2)} l="Achievable target" color="#1e8449" />
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <span className="text-xs text-neutral-500">Filter:</span>
        {(["all", "office", "coworking", "entertainment"] as Filter[]).map(
          (f) => (
            <button
              key={f}
              onClick={() => setFilter(f)}
              className={`rounded-md border px-2.5 py-1 text-xs capitalize transition-colors ${
                filter === f
                  ? "border-neutral-900 bg-neutral-900 text-white dark:border-neutral-100 dark:bg-neutral-100 dark:text-neutral-900"
                  : "border-neutral-300 text-neutral-600 dark:border-neutral-700 dark:text-neutral-300"
              }`}
            >
              {f}
            </button>
          ),
        )}
        <button
          onClick={() => setDivestOnly((v) => !v)}
          className={`rounded-md border px-2.5 py-1 text-xs transition-colors ${
            divestOnly
              ? "border-red-600 bg-red-600 text-white"
              : "border-neutral-300 text-neutral-600 dark:border-neutral-700 dark:text-neutral-300"
          }`}
        >
          Divest only
        </button>
        {inactiveNames.size > 0 && (
          <button
            onClick={() => setShowInactive((v) => !v)}
            className={`rounded-md border px-2.5 py-1 text-xs transition-colors ${
              showInactive
                ? "border-neutral-900 bg-neutral-900 text-white dark:border-neutral-100 dark:bg-neutral-100 dark:text-neutral-900"
                : "border-neutral-300 text-neutral-600 dark:border-neutral-700 dark:text-neutral-300"
            }`}
          >
            {showInactive
              ? "Hide inactive"
              : `Show inactive (${inactiveNames.size})`}
          </button>
        )}
      </div>

      <div
        className="overflow-auto rounded-lg border border-neutral-200 dark:border-neutral-800"
        style={{ maxHeight: "68vh" }}
      >
        <table className="border-separate" style={{ borderSpacing: 0 }}>
          <thead>
            <tr>
              <th
                rowSpan={2}
                className="sticky left-0 top-0 z-20 bg-neutral-100 px-2 py-1.5 text-left text-xs font-semibold dark:bg-neutral-900"
                style={{ minWidth: 210 }}
              >
                Product \ Machine
              </th>
              {groups.map((g, i) => (
                <th
                  key={i}
                  colSpan={g.span}
                  className="sticky top-0 z-10 bg-neutral-100 text-[10px] tracking-wider text-neutral-600 dark:bg-neutral-900"
                  style={{ height: 22 }}
                >
                  {LOC_LABEL[g.lt] ?? g.lt.toUpperCase()}
                </th>
              ))}
            </tr>
            <tr>
              {visMachines.map((m) => (
                <th
                  key={m}
                  className="sticky bg-neutral-100 text-[9px] text-neutral-500 dark:bg-neutral-900"
                  style={{ top: 22, height: 74, width: 30 }}
                >
                  <div
                    style={{
                      writingMode: "vertical-rl",
                      transform: "rotate(180deg)",
                      margin: "0 auto",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {shortMachine(m)}
                  </div>
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {visProducts.map((p) => {
              const isDv = divest.has(p);
              const isInactive = inactiveNames.has(p);
              return (
                <tr key={p} style={isInactive ? { opacity: 0.4 } : undefined}>
                  <th
                    className={`sticky left-0 z-10 px-2 py-1 text-left text-[11px] font-medium ${
                      isDv
                        ? "bg-red-50 dark:bg-red-950"
                        : "bg-neutral-50 dark:bg-neutral-900"
                    }`}
                    style={{
                      minWidth: 210,
                      maxWidth: 210,
                      whiteSpace: "nowrap",
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                    }}
                    title={p}
                  >
                    {p}
                    {isInactive && (
                      <span className="ml-1 rounded bg-neutral-300 px-1 text-[8px] uppercase text-neutral-700 dark:bg-neutral-700 dark:text-neutral-200">
                        inactive
                      </span>
                    )}
                    <span className="float-right font-bold text-neutral-400">
                      {(prodAvg.get(p) ?? 0).toFixed(1)}
                    </span>
                  </th>
                  {visMachines.map((m) => {
                    const c = grid.get(`${p}|||${m}`);
                    if (!c)
                      return (
                        <td
                          key={m}
                          className="bg-neutral-100/40 dark:bg-neutral-900/40"
                          style={{ width: 30, height: 24 }}
                        />
                      );
                    return (
                      <td
                        key={m}
                        style={{
                          width: 30,
                          height: 24,
                          background: scoreColor(c.score),
                          color: "#10151a",
                          fontWeight: 700,
                          fontSize: 10,
                          textAlign: "center",
                          position: "relative",
                          cursor: "default",
                        }}
                        onMouseMove={(e) =>
                          setTip({
                            x: e.clientX,
                            y: e.clientY,
                            head: `${m} · ${p}`,
                            body: `score ${c.score} · ${SIGNAL_FULL[c.signal] ?? c.signal} · v30 ${c.vel} · ${c.n} slot(s) — ${REC[c.signal] ?? ""}`,
                          })
                        }
                        onMouseLeave={() => setTip(null)}
                      >
                        {c.score % 1 === 0 ? c.score : c.score.toFixed(1)}
                        {isDv && (
                          <span
                            style={{
                              position: "absolute",
                              top: 1,
                              right: 2,
                              fontSize: 7,
                              color: "#3a0d0d",
                            }}
                          >
                            ◆
                          </span>
                        )}
                      </td>
                    );
                  })}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <p className="text-[11px] text-neutral-500">
        Cell value = lifecycle score (0–10). Colour: red ≤2, amber ~5, green ≥8.
        Live from slot_lifecycle.
      </p>

      {tip && (
        <div
          className="pointer-events-none fixed z-50 max-w-xs rounded-lg border border-neutral-700 bg-neutral-900 px-3 py-2 text-xs text-white shadow-lg"
          style={{
            left: Math.min(tip.x + 14, window.innerWidth - 290),
            top: Math.min(tip.y + 14, window.innerHeight - 90),
          }}
        >
          <div className="font-semibold text-amber-300">{tip.head}</div>
          <div className="mt-0.5 leading-snug">{tip.body}</div>
        </div>
      )}
    </div>
  );
}
