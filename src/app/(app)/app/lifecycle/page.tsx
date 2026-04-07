"use client";

import { useEffect, useState, useCallback, useRef, useMemo } from "react";
import { createClient } from "@/lib/supabase/client";
import { jitter } from "@/lib/lifecycle/jitter";
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
  Cell,
  ScatterChart,
  Scatter,
  ZAxis,
  ReferenceLine,
  CartesianGrid,
} from "recharts";

// ── Constants ─────────────────────────────────────────────────────────────────

const SIGNAL_COLORS: Record<string, string> = {
  "DOUBLE DOWN": "#16a34a",
  "KEEP GROWING": "#4ade80",
  KEEP: "#a3e635",
  WATCH: "#facc15",
  "WIND DOWN": "#fb923c",
  "ROTATE OUT": "#f87171",
  "DEAD — SWAP NOW": "#dc2626",
};

const SEVERITY_PILL: Record<string, string> = {
  critical: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200",
  warning:
    "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200",
  info: "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200",
};

const LOC_TYPES = ["all", "office", "coworking", "entertainment", "warehouse"];
const FAMILY_OVERRIDES_KEY = "boonz_lifecycle_family_overrides_v1";
const DEV_PAGE_SIZE = 25;

// ── Types ─────────────────────────────────────────────────────────────────────

interface KPIs {
  total_slots: number;
  avg_score: number;
  dark_machines: number;
  rotate_or_dead: number;
}
interface ScoreBucket {
  label: string;
  count: number;
}
interface SignalRow {
  signal: string;
  count: number;
}
interface DQFlag {
  flag_id: string;
  flag_type: string;
  severity: string;
  scope: string;
  machine_id: string | null;
  machine_name: string | null;
  message: string;
  detected_at: string;
}

/** One dot per product — Overall mode */
interface OverallPoint {
  xj: number;
  yj: number;
  x: number;
  y: number;
  z: number;
  pod_product_id: string;
  product_name: string;
  signal: string;
  velocity_real: number;
  machine_count: number;
  best_location_type: string | null;
  worst_location_type: string | null;
}

/** One dot per slot in a single machine — Machine mode */
interface MachineSlotPoint {
  xj: number;
  yj: number;
  x: number;
  y: number;
  z: number;
  velocity_real: number;
  shelf_code: string;
  pod_product_name: string;
  signal: string;
}

/** One dot per slot for a single product across the fleet — Product mode */
interface ProductSlotPoint {
  xj: number;
  yj: number;
  x: number;
  y: number;
  z: number;
  velocity_real: number;
  machine_id: string;
  machine_name: string;
  location_type: string;
  shelf_code: string;
  signal: string;
}

/** Deviation table row */
interface DeviationRow {
  product_name: string;
  machine_name: string;
  machine_id: string;
  pod_product_id: string;
  location_type: string;
  shelf_code: string;
  velocity: number;
  local_score: number;
  global_score: number;
  deviation: number;
  signal: string;
}

interface MachineOption {
  machine_id: string;
  official_name: string;
}
interface ProductOption {
  pod_product_id: string;
  pod_product_name: string;
}

interface ProductRow {
  pod_product_id: string;
  pod_product_name: string;
  score: number;
  trend: number;
  velocity_30d: number;
  machine_count: number;
  signal: string;
  best_location_type: string | null;
  worst_location_type: string | null;
  family_id: string | null;
  family_name: string | null;
}

type Tab = "overview" | "scatter" | "products";
type ScatterView = "overall" | "machine" | "product";

// ── Helpers ───────────────────────────────────────────────────────────────────

function bracketName(score: number): string {
  if (score < 1.0) return "RETIRED";
  if (score < 2.5) return "WIND DOWN";
  if (score < 4.5) return "TRIAL";
  if (score < 6.5) return "RAMP";
  if (score < 8.5) return "CORE";
  return "HERO";
}

function trendDirection(trend: number): string {
  if (trend > 6.5) return "rising";
  if (trend < 3.5) return "falling";
  return "flat";
}

// ── Page ──────────────────────────────────────────────────────────────────────

export default function LifecyclePage() {
  const [tab, setTab] = useState<Tab>("overview");
  const [kpis, setKpis] = useState<KPIs | null>(null);
  const [scoreDist, setScoreDist] = useState<ScoreBucket[]>([]);
  const [signalDist, setSignalDist] = useState<SignalRow[]>([]);
  const [dqFlags, setDqFlags] = useState<DQFlag[]>([]);

  // Scatter tab data
  const [overallPts, setOverallPts] = useState<OverallPoint[]>([]);
  const [scatterMachines, setScatterMachines] = useState<MachineOption[]>([]);
  const [scatterProducts, setScatterProducts] = useState<ProductOption[]>([]);
  const [deviationRows, setDeviationRows] = useState<DeviationRow[]>([]);
  const [scatterView, setScatterView] = useState<ScatterView>("overall");
  const [scatterMachineId, setScatterMachineId] = useState<string | null>(null);
  const [scatterProductId, setScatterProductId] = useState<string | null>(null);

  // Tab 3 data
  const [products, setProducts] = useState<ProductRow[]>([]);

  const [loading, setLoading] = useState(true);
  const [running, setRunning] = useState(false);
  const [lastRun, setLastRun] = useState<string | null>(null);
  const scatterLoaded = useRef(false);
  const productsLoaded = useRef(false);
  const urlInitialized = useRef(false);

  // ── URL sync ──────────────────────────────────────────────────────────────
  useEffect(() => {
    if (urlInitialized.current) return;
    urlInitialized.current = true;
    const p = new URLSearchParams(window.location.search);
    const t = p.get("tab") as Tab | null;
    if (t && ["overview", "scatter", "products"].includes(t)) setTab(t);
    const v = p.get("view") as ScatterView | null;
    if (v === "machine") {
      setScatterView("machine");
      const mid = p.get("machine_id");
      if (mid) setScatterMachineId(mid);
    } else if (v === "product") {
      setScatterView("product");
      const pid = p.get("pod_product_id");
      if (pid) setScatterProductId(pid);
    }
  }, []);

  useEffect(() => {
    if (!urlInitialized.current) return;
    const p = new URLSearchParams(window.location.search);
    p.set("tab", tab);
    if (tab === "scatter") {
      if (scatterView === "machine" && scatterMachineId) {
        p.set("view", "machine");
        p.set("machine_id", scatterMachineId);
        p.delete("pod_product_id");
      } else if (scatterView === "product" && scatterProductId) {
        p.set("view", "product");
        p.set("pod_product_id", scatterProductId);
        p.delete("machine_id");
      } else {
        p.set("view", "overall");
        p.delete("machine_id");
        p.delete("pod_product_id");
      }
    } else {
      p.delete("view");
      p.delete("machine_id");
      p.delete("pod_product_id");
    }
    const qs = p.toString();
    window.history.replaceState(
      {},
      "",
      qs ? `?${qs}` : window.location.pathname,
    );
  }, [tab, scatterView, scatterMachineId, scatterProductId]);

  // ── Data fetches ──────────────────────────────────────────────────────────
  const fetchOverview = useCallback(async () => {
    const supabase = createClient();
    const [slotsRes, flagsRes, machinesRes] = await Promise.all([
      supabase
        .from("slot_lifecycle")
        .select("score,signal")
        .eq("archived", false)
        .limit(10000),
      supabase
        .from("lifecycle_data_quality_flags")
        .select(
          "flag_id,flag_type,severity,scope,machine_id,message,detected_at",
        )
        .is("resolved_at", null)
        .order("detected_at", { ascending: false })
        .limit(200),
      supabase.from("machines").select("machine_id,official_name").limit(10000),
    ]);

    const slots = slotsRes.data ?? [];
    const flags = flagsRes.data ?? [];
    const machines = machinesRes.data ?? [];
    const machineNameMap = new Map(
      machines.map((m) => [m.machine_id, m.official_name]),
    );

    const avgScore =
      slots.length > 0
        ? slots.reduce((s, r) => s + Number(r.score), 0) / slots.length
        : 0;
    const darkCount = flags.filter(
      (f) => f.flag_type === "MACHINE_DARK",
    ).length;
    const rotateOrDead = slots.filter((s) =>
      ["ROTATE OUT", "DEAD — SWAP NOW"].includes(s.signal ?? ""),
    ).length;

    setKpis({
      total_slots: slots.length,
      avg_score: Math.round(avgScore * 100) / 100,
      dark_machines: darkCount,
      rotate_or_dead:
        slots.length > 0 ? Math.round((rotateOrDead / slots.length) * 100) : 0,
    });

    const buckets = Array.from({ length: 10 }, (_, i) => ({
      label: `${i}–${i + 1}`,
      count: 0,
    }));
    for (const s of slots)
      buckets[Math.min(9, Math.floor(Number(s.score)))].count++;
    setScoreDist(buckets);

    const sigMap = new Map<string, number>();
    for (const s of slots) {
      const sig = s.signal ?? "KEEP";
      sigMap.set(sig, (sigMap.get(sig) ?? 0) + 1);
    }
    const sigOrder = [
      "DOUBLE DOWN",
      "KEEP GROWING",
      "KEEP",
      "WATCH",
      "WIND DOWN",
      "ROTATE OUT",
      "DEAD — SWAP NOW",
    ];
    setSignalDist(
      sigOrder
        .filter((s) => sigMap.has(s))
        .map((s) => ({ signal: s, count: sigMap.get(s)! })),
    );
    setDqFlags(
      flags.map((f) => ({
        ...f,
        machine_name: f.machine_id
          ? (machineNameMap.get(f.machine_id) ?? f.machine_id)
          : null,
      })),
    );

    const lastEvRes = await supabase
      .from("slot_lifecycle")
      .select("last_evaluated_at")
      .not("last_evaluated_at", "is", null)
      .order("last_evaluated_at", { ascending: false })
      .limit(1)
      .single();
    if (lastEvRes.data?.last_evaluated_at)
      setLastRun(lastEvRes.data.last_evaluated_at);
    setLoading(false);
  }, []);

  const fetchScatter = useCallback(async () => {
    if (scatterLoaded.current) return;
    scatterLoaded.current = true;
    const supabase = createClient();

    const [globRes, slotsRes, machinesRes, podsRes] = await Promise.all([
      supabase
        .from("product_lifecycle_global")
        .select(
          "pod_product_id,score,trend_component,total_velocity_30d,machine_count,signal,best_location_type,worst_location_type",
        )
        .limit(10000),
      supabase
        .from("slot_lifecycle")
        .select(
          "machine_id,pod_product_id,shelf_code,score,signal,velocity_30d",
        )
        .eq("archived", false)
        .limit(10000),
      supabase
        .from("machines")
        .select("machine_id,official_name,location_type,include_in_refill")
        .limit(10000),
      supabase
        .from("pod_products")
        .select("pod_product_id,pod_product_name")
        .limit(10000),
    ]);

    const globs = globRes.data ?? [];
    const slots = slotsRes.data ?? [];
    const machines = machinesRes.data ?? [];
    const pods = podsRes.data ?? [];

    const machineMap = new Map(machines.map((m) => [m.machine_id, m]));
    const podMap = new Map(pods.map((p) => [p.pod_product_id, p]));
    const globMap = new Map(globs.map((g) => [g.pod_product_id, g]));

    // Overall mode: one dot per product (from product_lifecycle_global)
    // Jitter is visual only — real values shown in tooltip
    const pts: OverallPoint[] = globs
      .filter((g) => (g.machine_count ?? 0) > 0)
      .map((g) => {
        const pod = podMap.get(g.pod_product_id);
        const rx = Number(g.score);
        const ry = Number(g.trend_component);
        return {
          pod_product_id: g.pod_product_id,
          product_name: pod?.pod_product_name ?? g.pod_product_id,
          x: rx,
          y: ry,
          xj: Math.max(
            0,
            Math.min(10, rx + jitter(g.pod_product_id, 0.2, "x")),
          ),
          yj: Math.max(
            0,
            Math.min(10, ry + jitter(g.pod_product_id, 0.2, "y")),
          ),
          z: Math.max(1, Math.min(12, Number(g.total_velocity_30d))),
          velocity_real: Number(g.total_velocity_30d),
          signal: g.signal ?? "KEEP",
          machine_count: g.machine_count ?? 0,
          best_location_type: g.best_location_type ?? null,
          worst_location_type: g.worst_location_type ?? null,
        };
      });
    setOverallPts(pts);

    // Deviation table: all active slots joined with global score
    const devRows: DeviationRow[] = slots.flatMap((s) => {
      const glob = globMap.get(s.pod_product_id ?? "");
      if (!glob) return [];
      const machine = machineMap.get(s.machine_id ?? "");
      const pod = podMap.get(s.pod_product_id ?? "");
      const localScore = Number(s.score);
      const globalScore = Number(glob.score);
      return [
        {
          product_name: pod?.pod_product_name ?? "Unknown",
          machine_name: machine?.official_name ?? "Unknown",
          machine_id: s.machine_id ?? "",
          pod_product_id: s.pod_product_id ?? "",
          location_type: machine?.location_type ?? "unknown",
          shelf_code: s.shelf_code ?? "—",
          velocity: Number(s.velocity_30d),
          local_score: localScore,
          global_score: globalScore,
          deviation: Math.round((localScore - globalScore) * 100) / 100,
          signal: s.signal ?? "KEEP",
        },
      ];
    });
    setDeviationRows(devRows);

    // Machine list for selector
    const machineOptions: MachineOption[] = machines
      .filter((m) => m.include_in_refill)
      .map((m) => ({
        machine_id: m.machine_id,
        official_name: m.official_name,
      }))
      .sort((a, b) => a.official_name.localeCompare(b.official_name));
    setScatterMachines(machineOptions);

    // Product list for selector (only products with lifecycle data)
    const productOptions: ProductOption[] = globs
      .filter((g) => (g.machine_count ?? 0) > 0)
      .map((g) => {
        const pod = podMap.get(g.pod_product_id);
        return {
          pod_product_id: g.pod_product_id,
          pod_product_name: pod?.pod_product_name ?? g.pod_product_id,
        };
      })
      .sort((a, b) => a.pod_product_name.localeCompare(b.pod_product_name));
    setScatterProducts(productOptions);
  }, []);

  const fetchProducts = useCallback(async () => {
    if (productsLoaded.current) return;
    productsLoaded.current = true;
    const supabase = createClient();

    const [globRes, podsRes, familiesRes] = await Promise.all([
      supabase
        .from("product_lifecycle_global")
        .select(
          "pod_product_id,score,trend_component,total_velocity_30d,machine_count,signal,best_location_type,worst_location_type",
        )
        .limit(10000),
      supabase
        .from("pod_products")
        .select("pod_product_id,pod_product_name,product_family_id")
        .limit(10000),
      supabase
        .from("product_families")
        .select("product_family_id,family_name")
        .limit(10000),
    ]);

    const globs = globRes.data ?? [];
    const pods = podsRes.data ?? [];
    const families = familiesRes.data ?? [];
    const podMap = new Map(pods.map((p) => [p.pod_product_id, p]));
    const familyMap = new Map(families.map((f) => [f.product_family_id, f]));

    const rows: ProductRow[] = globs.map((g) => {
      const pod = podMap.get(g.pod_product_id);
      const fam = pod?.product_family_id
        ? familyMap.get(pod.product_family_id)
        : null;
      return {
        pod_product_id: g.pod_product_id,
        pod_product_name: pod?.pod_product_name ?? g.pod_product_id,
        score: Number(g.score),
        trend: Number(g.trend_component),
        velocity_30d: Number(g.total_velocity_30d),
        machine_count: g.machine_count ?? 0,
        signal: g.signal ?? "KEEP",
        best_location_type: g.best_location_type,
        worst_location_type: g.worst_location_type,
        family_id: pod?.product_family_id ?? null,
        family_name: fam?.family_name ?? null,
      };
    });
    rows.sort((a, b) => b.score - a.score);
    setProducts(rows);
  }, []);

  useEffect(() => {
    fetchOverview();
  }, [fetchOverview]);
  useEffect(() => {
    if (tab === "scatter") fetchScatter();
    if (tab === "products") fetchProducts();
  }, [tab, fetchScatter, fetchProducts]);

  async function handleRunNow() {
    setRunning(true);
    scatterLoaded.current = false;
    productsLoaded.current = false;
    try {
      const supabase = createClient();
      const {
        data: { session },
      } = await supabase.auth.getSession();
      const token = session?.access_token;
      const res = await fetch(
        `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/evaluate-lifecycle`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
          },
          body: "{}",
        },
      );
      if (res.ok) {
        await fetchOverview();
        if (tab === "scatter") fetchScatter();
        if (tab === "products") fetchProducts();
      }
    } finally {
      setRunning(false);
    }
  }

  if (loading) {
    return (
      <div className="flex h-full items-center justify-center">
        <p className="text-neutral-500">Loading lifecycle data…</p>
      </div>
    );
  }

  return (
    <div className="flex flex-col h-full">
      <div className="flex items-center justify-between border-b border-neutral-200 px-6 py-4 dark:border-neutral-800">
        <div>
          <h1 className="text-xl font-semibold">Product Lifecycle</h1>
          {lastRun && (
            <p className="text-xs text-neutral-500 mt-0.5">
              Last evaluated:{" "}
              {new Date(lastRun).toLocaleString(undefined, {
                dateStyle: "medium",
                timeStyle: "short",
              })}
            </p>
          )}
        </div>
        <button
          onClick={handleRunNow}
          disabled={running}
          className="rounded-lg border border-neutral-300 px-3 py-1.5 text-sm font-medium text-neutral-700 transition-colors hover:bg-neutral-100 disabled:opacity-50 dark:border-neutral-600 dark:text-neutral-300 dark:hover:bg-neutral-800"
        >
          {running ? "Running…" : "▶ Run now"}
        </button>
      </div>

      <div className="flex gap-1 border-b border-neutral-200 px-6 dark:border-neutral-800">
        {(["overview", "scatter", "products"] as Tab[]).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`px-4 py-2.5 text-sm font-medium capitalize transition-colors border-b-2 -mb-px ${
              tab === t
                ? "border-neutral-900 text-neutral-900 dark:border-neutral-100 dark:text-neutral-100"
                : "border-transparent text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300"
            }`}
          >
            {t === "overview"
              ? "Overview"
              : t === "scatter"
                ? "Score matrix"
                : "Products"}
          </button>
        ))}
      </div>

      <div className="flex-1 overflow-y-auto p-6">
        {tab === "overview" && (
          <OverviewTab
            kpis={kpis!}
            scoreDist={scoreDist}
            signalDist={signalDist}
            dqFlags={dqFlags}
          />
        )}
        {tab === "scatter" && (
          <ScatterTab
            overallPts={overallPts}
            machines={scatterMachines}
            products={scatterProducts}
            deviationRows={deviationRows}
            viewMode={scatterView}
            selectedMachineId={scatterMachineId}
            selectedProductId={scatterProductId}
            onViewModeChange={(v) => {
              setScatterView(v);
              if (v !== "machine") setScatterMachineId(null);
              if (v !== "product") setScatterProductId(null);
            }}
            onMachineChange={setScatterMachineId}
            onProductChange={setScatterProductId}
          />
        )}
        {tab === "products" && <ProductsTab products={products} />}
      </div>
    </div>
  );
}

// ── Overview Tab ──────────────────────────────────────────────────────────────

function OverviewTab({
  kpis,
  scoreDist,
  signalDist,
  dqFlags,
}: {
  kpis: KPIs;
  scoreDist: ScoreBucket[];
  signalDist: SignalRow[];
  dqFlags: DQFlag[];
}) {
  return (
    <div className="space-y-6">
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <KpiCard label="Slots scored" value={kpis.total_slots.toString()} />
        <KpiCard
          label="Avg score"
          value={kpis.avg_score.toFixed(2)}
          sub="/ 10"
        />
        <KpiCard
          label="Dark machines"
          value={kpis.dark_machines.toString()}
          highlight={kpis.dark_machines > 0 ? "red" : undefined}
        />
        <KpiCard
          label="Rotate / Dead"
          value={`${kpis.rotate_or_dead}%`}
          sub="of slots"
          highlight={kpis.rotate_or_dead > 20 ? "red" : undefined}
        />
      </div>

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <div className="rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
          <h2 className="mb-3 text-sm font-semibold text-neutral-700 dark:text-neutral-300">
            Score distribution
          </h2>
          <ResponsiveContainer width="100%" height={200}>
            <BarChart
              data={scoreDist}
              margin={{ top: 4, right: 4, left: -20, bottom: 0 }}
            >
              <XAxis dataKey="label" tick={{ fontSize: 11 }} interval={0} />
              <YAxis tick={{ fontSize: 11 }} />
              <Tooltip
                formatter={(v) => [v, "slots"]}
                contentStyle={{ fontSize: 12 }}
              />
              <Bar dataKey="count" radius={[3, 3, 0, 0]}>
                {scoreDist.map((_, i) => (
                  <Cell
                    key={i}
                    fill={
                      i <= 1
                        ? "#dc2626"
                        : i <= 3
                          ? "#f87171"
                          : i <= 5
                            ? "#facc15"
                            : i <= 7
                              ? "#4ade80"
                              : "#16a34a"
                    }
                  />
                ))}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        </div>

        <div className="rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
          <h2 className="mb-3 text-sm font-semibold text-neutral-700 dark:text-neutral-300">
            Signal distribution
          </h2>
          {signalDist.length === 0 ? (
            <p className="text-sm text-neutral-500">No data</p>
          ) : (
            <ul className="space-y-2">
              {signalDist.map((row) => {
                const total = signalDist.reduce((s, r) => s + r.count, 0);
                const pct = total > 0 ? (row.count / total) * 100 : 0;
                return (
                  <li key={row.signal} className="flex items-center gap-2">
                    <span className="w-32 shrink-0 text-xs font-medium text-neutral-700 dark:text-neutral-300">
                      {row.signal}
                    </span>
                    <div className="flex-1 overflow-hidden rounded-full bg-neutral-100 dark:bg-neutral-800 h-3">
                      <div
                        className="h-full rounded-full"
                        style={{
                          width: `${pct}%`,
                          backgroundColor:
                            SIGNAL_COLORS[row.signal] ?? "#a3a3a3",
                        }}
                      />
                    </div>
                    <span className="w-10 text-right text-xs text-neutral-500">
                      {row.count}
                    </span>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </div>

      <div className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950">
        <div className="flex items-center justify-between border-b border-neutral-200 px-4 py-3 dark:border-neutral-800">
          <h2 className="text-sm font-semibold text-neutral-700 dark:text-neutral-300">
            Data quality flags
            {dqFlags.length > 0 && (
              <span className="ml-2 rounded-full bg-neutral-100 px-2 py-0.5 text-xs text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400">
                {dqFlags.length}
              </span>
            )}
          </h2>
        </div>
        {dqFlags.length === 0 ? (
          <p className="px-4 py-6 text-sm text-neutral-500">
            No active flags ✓
          </p>
        ) : (
          <ul className="divide-y divide-neutral-100 dark:divide-neutral-800">
            {dqFlags.slice(0, 50).map((f) => (
              <li key={f.flag_id} className="flex items-start gap-3 px-4 py-3">
                <span
                  className={`mt-0.5 shrink-0 rounded px-1.5 py-0.5 text-xs font-medium ${SEVERITY_PILL[f.severity] ?? SEVERITY_PILL.info}`}
                >
                  {f.severity}
                </span>
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-medium text-neutral-800 dark:text-neutral-200">
                    {f.flag_type.replace(/_/g, " ")}
                    {f.machine_name && (
                      <span className="ml-1 font-normal text-neutral-500">
                        — {f.machine_name}
                      </span>
                    )}
                  </p>
                  <p className="text-xs text-neutral-500">{f.message}</p>
                </div>
                <span className="shrink-0 text-xs text-neutral-400">
                  {new Date(f.detected_at).toLocaleDateString()}
                </span>
              </li>
            ))}
            {dqFlags.length > 50 && (
              <li className="px-4 py-2 text-xs text-neutral-500">
                +{dqFlags.length - 50} more flags…
              </li>
            )}
          </ul>
        )}
      </div>
    </div>
  );
}

// ── Scatter Tab ───────────────────────────────────────────────────────────────

function ScatterTab({
  overallPts,
  machines,
  products,
  deviationRows,
  viewMode,
  selectedMachineId,
  selectedProductId,
  onViewModeChange,
  onMachineChange,
  onProductChange,
}: {
  overallPts: OverallPoint[];
  machines: MachineOption[];
  products: ProductOption[];
  deviationRows: DeviationRow[];
  viewMode: ScatterView;
  selectedMachineId: string | null;
  selectedProductId: string | null;
  onViewModeChange: (v: ScatterView) => void;
  onMachineChange: (id: string | null) => void;
  onProductChange: (id: string | null) => void;
}) {
  const [locFilter, setLocFilter] = useState("all");

  // Lazy slot fetches inside the tab
  const [machineSlots, setMachineSlots] = useState<MachineSlotPoint[]>([]);
  const [productSlots, setProductSlots] = useState<ProductSlotPoint[]>([]);
  const [slotsLoading, setSlotsLoading] = useState(false);

  // Deviation table state
  const [devSearch, setDevSearch] = useState("");
  const [devSortCol, setDevSortCol] = useState<keyof DeviationRow>("deviation");
  const [devSortDir, setDevSortDir] = useState<"asc" | "desc">("desc");
  const [devPage, setDevPage] = useState(0);

  // Fetch machine slots
  useEffect(() => {
    if (viewMode !== "machine" || !selectedMachineId) {
      setMachineSlots([]);
      return;
    }
    setSlotsLoading(true);
    const supabase = createClient();
    Promise.all([
      supabase
        .from("slot_lifecycle")
        .select(
          "shelf_id,shelf_code,score,trend_component,velocity_30d,signal,pod_product_id",
        )
        .eq("machine_id", selectedMachineId)
        .eq("archived", false)
        .limit(10000),
      supabase
        .from("pod_products")
        .select("pod_product_id,pod_product_name")
        .limit(10000),
    ]).then(([slotsRes, podsRes]) => {
      const slots = slotsRes.data ?? [];
      const pods = podsRes.data ?? [];
      const podMap = new Map(
        pods.map((p) => [p.pod_product_id, p.pod_product_name]),
      );
      // Jitter is visual only — real values shown in tooltip
      setMachineSlots(
        slots.map((s) => {
          const jid = `${selectedMachineId}:${s.shelf_id ?? s.shelf_code ?? ""}`;
          const rx = Number(s.score),
            ry = Number(s.trend_component);
          return {
            x: rx,
            y: ry,
            xj: Math.max(0, Math.min(10, rx + jitter(jid, 0.2, "x"))),
            yj: Math.max(0, Math.min(10, ry + jitter(jid, 0.2, "y"))),
            z: Math.max(1, Math.min(10, Number(s.velocity_30d) * 10)),
            velocity_real: Number(s.velocity_30d),
            shelf_code: s.shelf_code ?? "—",
            pod_product_name: podMap.get(s.pod_product_id ?? "") ?? "Unknown",
            signal: s.signal ?? "KEEP",
          };
        }),
      );
      setSlotsLoading(false);
    });
  }, [viewMode, selectedMachineId]);

  // Fetch product slots
  useEffect(() => {
    if (viewMode !== "product" || !selectedProductId) {
      setProductSlots([]);
      return;
    }
    setSlotsLoading(true);
    const supabase = createClient();
    Promise.all([
      supabase
        .from("slot_lifecycle")
        .select(
          "shelf_id,shelf_code,score,trend_component,velocity_30d,signal,machine_id",
        )
        .eq("pod_product_id", selectedProductId)
        .eq("archived", false)
        .limit(10000),
      supabase
        .from("machines")
        .select("machine_id,official_name,location_type")
        .limit(10000),
    ]).then(([slotsRes, machinesRes]) => {
      const slots = slotsRes.data ?? [];
      const machines2 = machinesRes.data ?? [];
      const machineMap = new Map(machines2.map((m) => [m.machine_id, m]));
      // Jitter is visual only — real values shown in tooltip
      setProductSlots(
        slots.map((s) => {
          const m = machineMap.get(s.machine_id ?? "");
          const jid = `${s.machine_id ?? ""}:${s.shelf_id ?? s.shelf_code ?? ""}`;
          const rx = Number(s.score),
            ry = Number(s.trend_component);
          return {
            x: rx,
            y: ry,
            xj: Math.max(0, Math.min(10, rx + jitter(jid, 0.2, "x"))),
            yj: Math.max(0, Math.min(10, ry + jitter(jid, 0.2, "y"))),
            z: Math.max(1, Math.min(10, Number(s.velocity_30d) * 10)),
            velocity_real: Number(s.velocity_30d),
            machine_id: s.machine_id ?? "",
            machine_name: m?.official_name ?? "Unknown",
            location_type: m?.location_type ?? "unknown",
            shelf_code: s.shelf_code ?? "—",
            signal: s.signal ?? "KEEP",
          };
        }),
      );
      setSlotsLoading(false);
    });
  }, [viewMode, selectedProductId]);

  // Chart data for active mode
  const overallFiltered =
    viewMode === "overall"
      ? overallPts.filter(
          (p) => locFilter === "all" /* loc filter N/A for global pts */,
        )
      : [];
  // For overall mode we don't have per-slot location, so loc filter is hidden

  const chartData: (OverallPoint | MachineSlotPoint | ProductSlotPoint)[] =
    viewMode === "overall"
      ? overallPts
      : viewMode === "machine"
        ? machineSlots
        : productSlots;

  // Deviation table filtered data
  const filteredDevRows = useMemo(() => {
    let rows = deviationRows;
    if (viewMode === "machine" && selectedMachineId) {
      rows = rows.filter((r) => r.machine_id === selectedMachineId);
    } else if (viewMode === "product" && selectedProductId) {
      rows = rows.filter((r) => r.pod_product_id === selectedProductId);
    }
    if (devSearch) {
      const q = devSearch.toLowerCase();
      rows = rows.filter(
        (r) =>
          r.product_name.toLowerCase().includes(q) ||
          r.machine_name.toLowerCase().includes(q),
      );
    }
    return [...rows].sort((a, b) => {
      const va = a[devSortCol],
        vb = b[devSortCol];
      if (typeof va === "number" && typeof vb === "number")
        return devSortDir === "asc" ? va - vb : vb - va;
      return devSortDir === "asc"
        ? String(va).localeCompare(String(vb))
        : String(vb).localeCompare(String(va));
    });
  }, [
    deviationRows,
    viewMode,
    selectedMachineId,
    selectedProductId,
    devSearch,
    devSortCol,
    devSortDir,
  ]);

  const totalDevPages = Math.ceil(filteredDevRows.length / DEV_PAGE_SIZE);
  const pagedDevRows = filteredDevRows.slice(
    devPage * DEV_PAGE_SIZE,
    (devPage + 1) * DEV_PAGE_SIZE,
  );

  // Reset to page 0 when filter changes
  useEffect(() => {
    setDevPage(0);
  }, [viewMode, selectedMachineId, selectedProductId, devSearch]);

  function toggleSort(col: keyof DeviationRow) {
    if (devSortCol === col)
      setDevSortDir((d) => (d === "asc" ? "desc" : "asc"));
    else {
      setDevSortCol(col);
      setDevSortDir("desc");
    }
  }

  const QUADRANT_LABELS = [
    { x: 7.5, y: 8, text: "Double down", color: "#16a34a" },
    { x: 1.5, y: 8, text: "Watch closely", color: "#4ade80" },
    { x: 7.5, y: 1.5, text: "Protect", color: "#facc15" },
    { x: 1.5, y: 1.5, text: "Rotate out", color: "#f87171" },
  ];

  function getSignalColor(signal: string) {
    return SIGNAL_COLORS[signal] ?? "#a3a3a3";
  }

  function dotLabel() {
    if (slotsLoading) return "Loading…";
    if (viewMode === "overall") return `${overallPts.length} products`;
    if (viewMode === "machine") return `${machineSlots.length} slots`;
    return `${productSlots.length} slots`;
  }

  return (
    <div className="space-y-4">
      {/* ── Controls ── */}
      <div className="flex flex-wrap items-center gap-3">
        {/* View mode */}
        <div className="flex items-center gap-2">
          <label className="text-xs font-medium text-neutral-500">View</label>
          <select
            value={viewMode}
            onChange={(e) => onViewModeChange(e.target.value as ScatterView)}
            className="rounded border border-neutral-300 px-2 py-1 text-xs focus:outline-none dark:border-neutral-600 dark:bg-neutral-900 dark:text-neutral-100"
          >
            <option value="overall">Overall (one dot per product)</option>
            <option value="machine">By machine</option>
            <option value="product">By product</option>
          </select>
        </div>

        {/* Machine picker */}
        {viewMode === "machine" && (
          <select
            value={selectedMachineId ?? ""}
            onChange={(e) => onMachineChange(e.target.value || null)}
            className="rounded border border-neutral-300 px-2 py-1 text-xs focus:outline-none dark:border-neutral-600 dark:bg-neutral-900 dark:text-neutral-100"
          >
            <option value="">— pick a machine —</option>
            {machines.map((m) => (
              <option key={m.machine_id} value={m.machine_id}>
                {m.official_name}
              </option>
            ))}
          </select>
        )}

        {/* Product picker */}
        {viewMode === "product" && (
          <select
            value={selectedProductId ?? ""}
            onChange={(e) => onProductChange(e.target.value || null)}
            className="rounded border border-neutral-300 px-2 py-1 text-xs focus:outline-none dark:border-neutral-600 dark:bg-neutral-900 dark:text-neutral-100"
          >
            <option value="">— pick a product —</option>
            {products.map((p) => (
              <option key={p.pod_product_id} value={p.pod_product_id}>
                {p.pod_product_name}
              </option>
            ))}
          </select>
        )}

        <span className="text-xs text-neutral-500">{dotLabel()}</span>
      </div>

      {/* ── Matrix chart ── */}
      <div className="relative rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
        {/* Quadrant labels */}
        <div className="pointer-events-none absolute inset-0 p-4">
          <div className="relative h-full w-full">
            {QUADRANT_LABELS.map((q) => (
              <span
                key={q.text}
                className="absolute text-xs font-semibold opacity-25"
                style={{
                  color: q.color,
                  left: `${(q.x / 10) * 100}%`,
                  top: `${100 - (q.y / 10) * 100}%`,
                  transform: "translate(-50%, -50%)",
                }}
              >
                {q.text}
              </span>
            ))}
          </div>
        </div>

        <ResponsiveContainer width="100%" height={420}>
          <ScatterChart margin={{ top: 16, right: 16, bottom: 24, left: 0 }}>
            <CartesianGrid strokeDasharray="3 3" opacity={0.15} />
            {/* xj/yj are jittered chart positions; real x/y preserved for tooltip */}
            <XAxis
              type="number"
              dataKey="xj"
              domain={[0, 10]}
              name="Score"
              label={{
                value: "Score",
                position: "insideBottomRight",
                offset: -4,
                fontSize: 11,
              }}
              tick={{ fontSize: 11 }}
            />
            <YAxis
              type="number"
              dataKey="yj"
              domain={[0, 10]}
              name="Trend"
              label={{
                value: "Trend",
                angle: -90,
                position: "insideLeft",
                fontSize: 11,
              }}
              tick={{ fontSize: 11 }}
            />
            <ZAxis type="number" dataKey="z" range={[20, 200]} />
            <ReferenceLine x={5} stroke="#a3a3a3" strokeDasharray="4 2" />
            <ReferenceLine y={5} stroke="#a3a3a3" strokeDasharray="4 2" />
            <Tooltip
              cursor={false}
              content={({ payload }) => {
                if (!payload?.length) return null;
                const d = payload[0].payload as OverallPoint &
                  MachineSlotPoint &
                  ProductSlotPoint;
                const sig = d.signal ?? "KEEP";
                // d.x and d.y are the real (un-jittered) values
                const scoreStr = `${d.x.toFixed(2)} (${bracketName(d.x)})`;
                const trendStr = `${d.y.toFixed(2)} (${trendDirection(d.y)})`;
                return (
                  <div className="rounded border border-neutral-200 bg-white p-3 text-xs shadow-lg dark:border-neutral-700 dark:bg-neutral-900 min-w-[200px]">
                    {viewMode === "overall" ? (
                      <>
                        <p className="font-semibold text-sm truncate max-w-[220px]">
                          {d.product_name}
                        </p>
                        <p className="text-neutral-500 mb-1.5">
                          {d.machine_count} machine
                          {d.machine_count !== 1 ? "s" : ""}
                        </p>
                      </>
                    ) : viewMode === "machine" ? (
                      <>
                        <p className="font-semibold text-sm">{d.shelf_code}</p>
                        <p className="text-neutral-500 mb-1.5">
                          {d.pod_product_name}
                        </p>
                      </>
                    ) : (
                      <>
                        <p className="font-semibold text-sm truncate max-w-[220px]">
                          {d.machine_name}
                        </p>
                        <p className="text-neutral-500 mb-1.5">
                          {d.location_type} · {d.shelf_code}
                        </p>
                      </>
                    )}
                    <div className="space-y-0.5 text-neutral-700 dark:text-neutral-300">
                      <p>Score: {scoreStr}</p>
                      <p>Trend: {trendStr}</p>
                      <p>Velocity: {d.velocity_real.toFixed(2)} units/day</p>
                      {viewMode === "overall" && d.best_location_type && (
                        <p className="text-neutral-500">
                          Best: {d.best_location_type}
                        </p>
                      )}
                    </div>
                    <span
                      className="mt-1.5 inline-block rounded px-1.5 py-0.5 text-xs font-medium"
                      style={{
                        backgroundColor: getSignalColor(sig) + "33",
                        color: getSignalColor(sig),
                      }}
                    >
                      {sig}
                    </span>
                  </div>
                );
              }}
            />
            <Scatter data={chartData} fillOpacity={0.7}>
              {(chartData as Array<{ signal?: string }>).map((pt, i) => (
                <Cell key={i} fill={getSignalColor(pt.signal ?? "KEEP")} />
              ))}
            </Scatter>
          </ScatterChart>
        </ResponsiveContainer>

        <p className="mt-1 text-xs text-neutral-400 text-center">
          Dot positions are slightly jittered for visibility — exact values
          shown in tooltip.
        </p>

        {/* Legend */}
        <div className="mt-2 flex flex-wrap gap-3">
          {Object.entries(SIGNAL_COLORS).map(([sig, color]) => (
            <span key={sig} className="flex items-center gap-1 text-xs">
              <span
                className="inline-block h-2.5 w-2.5 rounded-full"
                style={{ backgroundColor: color }}
              />
              {sig}
            </span>
          ))}
        </div>
      </div>

      {/* ── Deviation table ── */}
      <div className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950">
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-neutral-200 px-4 py-3 dark:border-neutral-800">
          <div>
            <h2 className="text-sm font-semibold text-neutral-700 dark:text-neutral-300">
              Local vs global score
            </h2>
            <p className="text-xs text-neutral-400 mt-0.5">
              {filteredDevRows.length} rows
              {viewMode === "machine" &&
                selectedMachineId &&
                " · filtered to machine"}
              {viewMode === "product" &&
                selectedProductId &&
                " · filtered to product"}
            </p>
          </div>
          <input
            type="text"
            placeholder="Search product or machine…"
            value={devSearch}
            onChange={(e) => setDevSearch(e.target.value)}
            className="rounded border border-neutral-300 px-2.5 py-1.5 text-xs focus:outline-none dark:border-neutral-600 dark:bg-neutral-900 dark:text-neutral-100 w-52"
          />
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-xs">
            <thead>
              <tr className="border-b border-neutral-100 bg-neutral-50 text-neutral-500 dark:border-neutral-800 dark:bg-neutral-900">
                {(
                  [
                    "product_name",
                    "machine_name",
                    "shelf_code",
                    "location_type",
                    "velocity",
                    "local_score",
                    "global_score",
                    "deviation",
                    "signal",
                  ] as (keyof DeviationRow)[]
                ).map((col) => (
                  <th
                    key={col}
                    onClick={() => toggleSort(col)}
                    className="cursor-pointer select-none px-3 py-2 text-left font-medium uppercase tracking-wide hover:text-neutral-700 dark:hover:text-neutral-300 whitespace-nowrap"
                  >
                    {col === "product_name"
                      ? "Product"
                      : col === "machine_name"
                        ? "Machine"
                        : col === "shelf_code"
                          ? "Shelf"
                          : col === "location_type"
                            ? "Location"
                            : col === "velocity"
                              ? "Vel/day"
                              : col === "local_score"
                                ? "Local"
                                : col === "global_score"
                                  ? "Global"
                                  : col === "deviation"
                                    ? "Deviation"
                                    : "Signal"}
                    {devSortCol === col && (
                      <span className="ml-1">
                        {devSortDir === "asc" ? "↑" : "↓"}
                      </span>
                    )}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-neutral-50 dark:divide-neutral-800/50">
              {pagedDevRows.map((row, i) => {
                const devColor =
                  row.deviation >= 1.0
                    ? "#16a34a"
                    : row.deviation <= -1.0
                      ? "#dc2626"
                      : "#a3a3a3";
                const devBg =
                  row.deviation >= 1.0
                    ? "bg-green-50 dark:bg-green-950/30"
                    : row.deviation <= -1.0
                      ? "bg-red-50 dark:bg-red-950/30"
                      : "";
                return (
                  <tr
                    key={i}
                    onClick={() => {
                      if (viewMode === "overall") {
                        onViewModeChange("machine");
                        onMachineChange(row.machine_id);
                      }
                    }}
                    className={`${viewMode === "overall" ? "cursor-pointer hover:bg-neutral-50 dark:hover:bg-neutral-900" : ""} ${devBg}`}
                  >
                    <td className="max-w-[160px] truncate px-3 py-2 font-medium text-neutral-800 dark:text-neutral-200">
                      {row.product_name}
                    </td>
                    <td className="max-w-[140px] truncate px-3 py-2 text-neutral-600 dark:text-neutral-400">
                      {row.machine_name}
                    </td>
                    <td className="px-3 py-2 font-mono text-neutral-500">
                      {row.shelf_code}
                    </td>
                    <td className="px-3 py-2 capitalize text-neutral-500">
                      {row.location_type}
                    </td>
                    <td className="px-3 py-2 text-right font-mono text-neutral-500">
                      {row.velocity.toFixed(2)}
                    </td>
                    <td className="px-3 py-2 text-right font-mono">
                      {row.local_score.toFixed(2)}
                    </td>
                    <td className="px-3 py-2 text-right font-mono text-neutral-500">
                      {row.global_score.toFixed(2)}
                    </td>
                    <td className="px-3 py-2 text-right">
                      <span
                        className="inline-block rounded px-1.5 py-0.5 font-mono font-medium"
                        style={{
                          color: devColor,
                          backgroundColor: devColor + "22",
                        }}
                      >
                        {row.deviation >= 0 ? "+" : ""}
                        {row.deviation.toFixed(2)}
                      </span>
                    </td>
                    <td className="px-3 py-2">
                      <span
                        className="inline-block rounded px-1.5 py-0.5 font-medium whitespace-nowrap"
                        style={{
                          color: SIGNAL_COLORS[row.signal] ?? "#a3a3a3",
                          backgroundColor:
                            (SIGNAL_COLORS[row.signal] ?? "#a3a3a3") + "33",
                        }}
                      >
                        {row.signal}
                      </span>
                    </td>
                  </tr>
                );
              })}
              {pagedDevRows.length === 0 && (
                <tr>
                  <td
                    colSpan={9}
                    className="px-4 py-6 text-center text-neutral-400"
                  >
                    No rows match
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>

        {/* Pagination */}
        {totalDevPages > 1 && (
          <div className="flex items-center justify-between border-t border-neutral-100 px-4 py-2 dark:border-neutral-800">
            <button
              onClick={() => setDevPage((p) => Math.max(0, p - 1))}
              disabled={devPage === 0}
              className="text-xs text-neutral-500 hover:text-neutral-700 disabled:opacity-40 dark:hover:text-neutral-300"
            >
              ← Prev
            </button>
            <span className="text-xs text-neutral-400">
              Page {devPage + 1} of {totalDevPages}
            </span>
            <button
              onClick={() =>
                setDevPage((p) => Math.min(totalDevPages - 1, p + 1))
              }
              disabled={devPage >= totalDevPages - 1}
              className="text-xs text-neutral-500 hover:text-neutral-700 disabled:opacity-40 dark:hover:text-neutral-300"
            >
              Next →
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

// ── Products Tab ──────────────────────────────────────────────────────────────

function ProductsTab({ products }: { products: ProductRow[] }) {
  const [search, setSearch] = useState("");
  const [signalFilter, setSignalFilter] = useState("all");
  const [overrides, setOverrides] = useState<Record<string, string>>(() => {
    try {
      return JSON.parse(localStorage.getItem(FAMILY_OVERRIDES_KEY) ?? "{}");
    } catch {
      return {};
    }
  });

  const signals = [
    "all",
    "DOUBLE DOWN",
    "KEEP GROWING",
    "KEEP",
    "WATCH",
    "WIND DOWN",
    "ROTATE OUT",
    "DEAD — SWAP NOW",
  ];

  function getDisplaySignal(row: ProductRow): string {
    if (row.family_id && overrides[row.family_id])
      return overrides[row.family_id];
    return row.signal;
  }
  function toggleFamilyOverride(familyId: string, current: string) {
    const next = { ...overrides };
    if (next[familyId]) delete next[familyId];
    else next[familyId] = current;
    setOverrides(next);
    localStorage.setItem(FAMILY_OVERRIDES_KEY, JSON.stringify(next));
  }

  const filtered = products.filter((p) => {
    const sig = getDisplaySignal(p);
    const matchesSig = signalFilter === "all" || sig === signalFilter;
    const matchesSearch =
      !search ||
      p.pod_product_name.toLowerCase().includes(search.toLowerCase()) ||
      (p.family_name ?? "").toLowerCase().includes(search.toLowerCase());
    return matchesSig && matchesSearch;
  });

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-3">
        <input
          type="text"
          placeholder="Search products…"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="rounded-lg border border-neutral-300 px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-neutral-400 dark:border-neutral-600 dark:bg-neutral-900 dark:text-neutral-100"
        />
        <select
          value={signalFilter}
          onChange={(e) => setSignalFilter(e.target.value)}
          className="rounded-lg border border-neutral-300 px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-neutral-400 dark:border-neutral-600 dark:bg-neutral-900 dark:text-neutral-100"
        >
          {signals.map((s) => (
            <option key={s} value={s}>
              {s === "all" ? "All signals" : s}
            </option>
          ))}
        </select>
        <span className="self-center text-xs text-neutral-500">
          {filtered.length} products
        </span>
        {Object.keys(overrides).length > 0 && (
          <button
            onClick={() => {
              setOverrides({});
              localStorage.removeItem(FAMILY_OVERRIDES_KEY);
            }}
            className="self-center text-xs text-amber-600 hover:underline dark:text-amber-400"
          >
            Clear {Object.keys(overrides).length} family override
            {Object.keys(overrides).length > 1 ? "s" : ""}
          </button>
        )}
      </div>

      <div className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950 overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-neutral-200 bg-neutral-50 text-xs uppercase tracking-wide text-neutral-500 dark:border-neutral-800 dark:bg-neutral-900">
                <th className="px-4 py-2.5 text-left font-medium">Product</th>
                <th className="px-4 py-2.5 text-left font-medium">Family</th>
                <th className="px-3 py-2.5 text-right font-medium">Score</th>
                <th className="px-3 py-2.5 text-right font-medium">Trend</th>
                <th className="px-3 py-2.5 text-right font-medium">Vel/day</th>
                <th className="px-3 py-2.5 text-right font-medium">Mach.</th>
                <th className="px-4 py-2.5 text-left font-medium">Signal</th>
                <th className="px-4 py-2.5 text-left font-medium">Best loc</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-neutral-100 dark:divide-neutral-800">
              {filtered.slice(0, 200).map((row) => {
                const displaySig = getDisplaySignal(row);
                const isOverridden =
                  !!row.family_id && !!overrides[row.family_id];
                return (
                  <tr
                    key={row.pod_product_id}
                    className="hover:bg-neutral-50 dark:hover:bg-neutral-900"
                  >
                    <td className="max-w-[200px] truncate px-4 py-2.5 font-medium">
                      {row.pod_product_name}
                    </td>
                    <td className="px-4 py-2.5 text-neutral-500">
                      {row.family_name ? (
                        <span className="truncate">{row.family_name}</span>
                      ) : (
                        <span className="text-neutral-300 dark:text-neutral-600">
                          —
                        </span>
                      )}
                    </td>
                    <td className="px-3 py-2.5 text-right font-mono">
                      {row.score.toFixed(2)}
                    </td>
                    <td className="px-3 py-2.5 text-right font-mono text-neutral-500">
                      {row.trend.toFixed(2)}
                    </td>
                    <td className="px-3 py-2.5 text-right font-mono text-neutral-500">
                      {row.velocity_30d.toFixed(1)}
                    </td>
                    <td className="px-3 py-2.5 text-right text-neutral-500">
                      {row.machine_count}
                    </td>
                    <td className="px-4 py-2.5">
                      <button
                        onClick={() =>
                          row.family_id
                            ? toggleFamilyOverride(row.family_id, displaySig)
                            : undefined
                        }
                        title={
                          row.family_id
                            ? isOverridden
                              ? "Clear family override"
                              : "Pin signal for this family"
                            : undefined
                        }
                        className={`rounded px-1.5 py-0.5 text-xs font-medium ${row.family_id ? "cursor-pointer hover:opacity-80" : ""} ${isOverridden ? "ring-2 ring-amber-400" : ""}`}
                        style={{
                          backgroundColor:
                            (SIGNAL_COLORS[displaySig] ?? "#a3a3a3") + "33",
                          color: SIGNAL_COLORS[displaySig] ?? "#a3a3a3",
                        }}
                      >
                        {displaySig}
                      </button>
                    </td>
                    <td className="px-4 py-2.5 text-xs capitalize text-neutral-500">
                      {row.best_location_type ?? "—"}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          {filtered.length > 200 && (
            <p className="px-4 py-2 text-xs text-neutral-500">
              Showing 200 of {filtered.length} — use search to narrow
            </p>
          )}
        </div>
      </div>
    </div>
  );
}

// ── KpiCard ───────────────────────────────────────────────────────────────────

function KpiCard({
  label,
  value,
  sub,
  highlight,
}: {
  label: string;
  value: string;
  sub?: string;
  highlight?: "red";
}) {
  return (
    <div className="rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
      <p className="text-xs font-medium uppercase tracking-wide text-neutral-500">
        {label}
      </p>
      <p
        className={`mt-1 text-2xl font-bold ${highlight === "red" ? "text-red-600 dark:text-red-400" : "text-neutral-900 dark:text-neutral-100"}`}
      >
        {value}
        {sub && (
          <span className="ml-1 text-sm font-normal text-neutral-500">
            {sub}
          </span>
        )}
      </p>
    </div>
  );
}
