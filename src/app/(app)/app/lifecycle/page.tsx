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
  LabelList,
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

/** Up to 5 distinct colors for multi-member clusters; singletons get gray. */
const CLUSTER_COLORS = ["#3b82f6", "#8b5cf6", "#f59e0b", "#10b981", "#ef4444"];
const SINGLETON_COLOR = "#9ca3af";

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

/** One dot per product — product+overall mode */
interface OverallPoint {
  xj: number;
  yj: number;
  x: number;
  y: number;
  z: number;
  pod_product_id: string;
  product_name: string;
  product_family_id: string | null;
  family_name: string | null;
  signal: string;
  velocity_real: number;
  machine_count: number;
  best_location_type: string | null;
  worst_location_type: string | null;
}

/**
 * One augmented slot — covers all machine-scope chart combinations.
 * Colour is pre-assigned for cluster coloring mode.
 */
interface SlotPoint {
  xj: number;
  yj: number;
  x: number;
  y: number;
  z: number;
  velocity_real: number;
  machine_id: string;
  machine_name: string;
  location_type: string;
  pod_product_id: string;
  pod_product_name: string;
  product_family_id: string | null;
  family_name: string | null;
  shelf_code: string;
  signal: string;
  /** Pre-computed cluster colour; used when toggleA=cluster+toggleB=machine */
  clusterColor: string;
}

/** One dot per product family — cluster+overall mode */
interface ClusterPoint {
  xj: number;
  yj: number;
  x: number;
  y: number;
  z: number;
  family_id: string;
  family_name: string;
  member_count: number;
  member_names: string;
  velocity_real: number;
  signal: string;
}

/** Deviation table row */
interface DeviationRow {
  product_name: string;
  family_name: string | null;
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

type Tab = "overview" | "matrix" | "products";
type ToggleA = "product" | "cluster";
type ToggleB = "overall" | "machine";

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

function signalFromScore(score: number, trend: number): string {
  if (score >= 8.5) return trend >= 5 ? "DOUBLE DOWN" : "KEEP GROWING";
  if (score >= 6.5)
    return trend >= 6.5 ? "DOUBLE DOWN" : trend >= 4 ? "KEEP GROWING" : "KEEP";
  if (score >= 4.5) return trend >= 6.5 ? "WATCH" : "KEEP";
  if (score >= 2.5) return trend >= 5 ? "WATCH" : "WIND DOWN";
  if (score >= 1.0) return "ROTATE OUT";
  return "DEAD — SWAP NOW";
}

function computeFamilyScore(
  members: Array<{
    x: number;
    y: number;
    velocity_real: number;
  }>,
): { score: number; trend: number; total_velocity: number } {
  if (members.length === 0) return { score: 5, trend: 5, total_velocity: 0 };
  let wScore = 0,
    wV = 0,
    trendSum = 0,
    totalV = 0;
  for (const m of members) {
    const w = Math.max(m.velocity_real, 0.01);
    wScore += m.x * w;
    wV += w;
    trendSum += m.y;
    totalV += m.velocity_real;
  }
  return {
    score: Number((wScore / wV).toFixed(2)),
    trend: Number((trendSum / members.length).toFixed(2)),
    total_velocity: Number(totalV.toFixed(2)),
  };
}

function truncateLabel(text: string, max: number): string {
  if (text.length <= max) return text;
  return text.substring(0, max - 1) + "…";
}

// ── Page ──────────────────────────────────────────────────────────────────────

export default function LifecyclePage() {
  const [tab, setTab] = useState<Tab>("overview");
  const [kpis, setKpis] = useState<KPIs | null>(null);
  const [scoreDist, setScoreDist] = useState<ScoreBucket[]>([]);
  const [signalDist, setSignalDist] = useState<SignalRow[]>([]);
  const [dqFlags, setDqFlags] = useState<DQFlag[]>([]);

  // Scatter / matrix tab data
  const [overallPts, setOverallPts] = useState<OverallPoint[]>([]);
  const [allSlots, setAllSlots] = useState<SlotPoint[]>([]);
  const [deviationRows, setDeviationRows] = useState<DeviationRow[]>([]);
  const [scatterMachines, setScatterMachines] = useState<MachineOption[]>([]);
  const [scatterProducts, setScatterProducts] = useState<ProductOption[]>([]);
  /** family_id → cluster colour (multi-member = from palette, singleton = gray) */
  const [clusterColors, setClusterColors] = useState<Record<string, string>>(
    {},
  );

  // Matrix controls — two independent MECE toggles
  const [toggleA, setToggleA] = useState<ToggleA>("product");
  const [toggleB, setToggleB] = useState<ToggleB>("overall");
  const [productId, setProductId] = useState<string | null>(null);
  const [clusterId, setClusterId] = useState<string | null>(null);
  /** null = "All machines"; string = specific machine */
  const [machineId, setMachineId] = useState<string | null>(null);
  const [showSingletons, setShowSingletons] = useState(false);

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
    const t = p.get("tab");
    // Accept both "matrix" (new) and "scatter" (old migration)
    if (t === "matrix" || t === "scatter") setTab("matrix");
    else if (t === "overview") setTab("overview");
    else if (t === "products") setTab("products");

    const ta = p.get("toggleA");
    if (ta === "cluster") setToggleA("cluster");

    const tb = p.get("toggleB");
    if (tb === "machine") setToggleB("machine");

    const pid = p.get("product");
    if (pid) setProductId(pid);
    const cid = p.get("cluster");
    if (cid) setClusterId(cid);
    const mid = p.get("machine");
    if (mid) setMachineId(mid);
    setShowSingletons(p.get("singletons") === "1");

    // Migrate old ?view= params (from even earlier builds)
    if (!ta && !tb) {
      const v = p.get("view") ?? p.get("group");
      if (v === "cluster") setToggleA("cluster");
      const s = p.get("scope");
      if (s === "machine") setToggleB("machine");
      const oldMid = p.get("machine_id");
      if (oldMid) setMachineId(oldMid);
      const oldPid = p.get("pod_product_id");
      if (oldPid) setProductId(oldPid);
      const oldFid = p.get("family_id");
      if (oldFid) setClusterId(oldFid);
    }
  }, []);

  useEffect(() => {
    if (!urlInitialized.current) return;
    const p = new URLSearchParams();
    p.set("tab", tab);
    if (tab === "matrix") {
      p.set("toggleA", toggleA);
      p.set("toggleB", toggleB);
      if (productId) p.set("product", productId);
      if (clusterId) p.set("cluster", clusterId);
      if (toggleB === "machine" && machineId) p.set("machine", machineId);
      if (toggleA === "cluster" && showSingletons) p.set("singletons", "1");
    }
    const qs = p.toString();
    window.history.replaceState(
      {},
      "",
      qs ? `?${qs}` : window.location.pathname,
    );
  }, [tab, toggleA, toggleB, productId, clusterId, machineId, showSingletons]);

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

    const [globRes, slotsRes, machinesRes, podsRes, familiesRes] =
      await Promise.all([
        supabase
          .from("product_lifecycle_global")
          .select(
            "pod_product_id,score,trend_component,total_velocity_30d,machine_count,signal,best_location_type,worst_location_type",
          )
          .limit(10000),
        supabase
          .from("slot_lifecycle")
          .select(
            "machine_id,pod_product_id,shelf_code,shelf_id,score,trend_component,signal,velocity_30d",
          )
          .eq("archived", false)
          .limit(10000),
        supabase
          .from("machines")
          .select("machine_id,official_name,location_type,include_in_refill")
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
    const slots = slotsRes.data ?? [];
    const machines = machinesRes.data ?? [];
    const pods = podsRes.data ?? [];
    const families = familiesRes.data ?? [];

    const machineMap = new Map(machines.map((m) => [m.machine_id, m]));
    const podMap = new Map(pods.map((p) => [p.pod_product_id, p]));
    const globMap = new Map(globs.map((g) => [g.pod_product_id, g]));
    const familyMap = new Map(families.map((f) => [f.product_family_id, f]));

    // ── Overall points (product+overall) ─────────────────────────────────
    const pts: OverallPoint[] = globs
      .filter((g) => (g.machine_count ?? 0) > 0)
      .map((g) => {
        const pod = podMap.get(g.pod_product_id);
        const fid = pod?.product_family_id ?? null;
        const fam = fid ? familyMap.get(fid) : null;
        const rx = Number(g.score),
          ry = Number(g.trend_component);
        return {
          pod_product_id: g.pod_product_id,
          product_name: pod?.pod_product_name ?? g.pod_product_id,
          product_family_id: fid ?? null,
          family_name: fam?.family_name ?? null,
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

    // ── Cluster colour mapping ────────────────────────────────────────────
    // Use product counts from overallPts (products with lifecycle data)
    const familyCountFromPts = new Map<string, number>();
    for (const p of pts) {
      if (p.product_family_id) {
        familyCountFromPts.set(
          p.product_family_id,
          (familyCountFromPts.get(p.product_family_id) ?? 0) + 1,
        );
      }
    }
    const multiMemberFids = [...familyCountFromPts.entries()]
      .filter(([, c]) => c >= 2)
      .sort(([idA], [idB]) => {
        const a = familyMap.get(idA)?.family_name ?? "";
        const b = familyMap.get(idB)?.family_name ?? "";
        return a.localeCompare(b);
      });
    const colorRecord: Record<string, string> = {};
    multiMemberFids.forEach(([fid], i) => {
      colorRecord[fid] = CLUSTER_COLORS[Math.min(i, CLUSTER_COLORS.length - 1)];
    });
    setClusterColors(colorRecord);

    // ── All slots (machine-scope modes) ──────────────────────────────────
    const builtSlots: SlotPoint[] = slots.flatMap((s) => {
      const machine = machineMap.get(s.machine_id ?? "");
      const pod = podMap.get(s.pod_product_id ?? "");
      const fid = pod?.product_family_id ?? null;
      const fam = fid ? familyMap.get(fid) : null;
      const jid = `${s.machine_id ?? ""}:${s.shelf_id ?? s.shelf_code ?? ""}`;
      const rx = Number(s.score),
        ry = Number(s.trend_component);
      return [
        {
          x: rx,
          y: ry,
          xj: Math.max(0, Math.min(10, rx + jitter(jid, 0.2, "x"))),
          yj: Math.max(0, Math.min(10, ry + jitter(jid, 0.2, "y"))),
          z: Math.max(1, Math.min(10, Number(s.velocity_30d) * 10)),
          velocity_real: Number(s.velocity_30d),
          machine_id: s.machine_id ?? "",
          machine_name: machine?.official_name ?? "Unknown",
          location_type: machine?.location_type ?? "unknown",
          pod_product_id: s.pod_product_id ?? "",
          pod_product_name: pod?.pod_product_name ?? "Unknown",
          product_family_id: fid,
          family_name: fam?.family_name ?? null,
          shelf_code: s.shelf_code ?? "—",
          signal: s.signal ?? "KEEP",
          clusterColor: fid
            ? (colorRecord[fid] ?? SINGLETON_COLOR)
            : SINGLETON_COLOR,
        },
      ];
    });
    setAllSlots(builtSlots);

    // ── Deviation table rows ──────────────────────────────────────────────
    const devRows: DeviationRow[] = slots.flatMap((s) => {
      const glob = globMap.get(s.pod_product_id ?? "");
      if (!glob) return [];
      const machine = machineMap.get(s.machine_id ?? "");
      const pod = podMap.get(s.pod_product_id ?? "");
      const fid = pod?.product_family_id ?? null;
      const fam = fid ? familyMap.get(fid) : null;
      const localScore = Number(s.score);
      const globalScore = Number(glob.score);
      return [
        {
          product_name: pod?.pod_product_name ?? "Unknown",
          family_name: fam?.family_name ?? null,
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

    // ── Machine list ──────────────────────────────────────────────────────
    setScatterMachines(
      machines
        .filter((m) => m.include_in_refill)
        .map((m) => ({
          machine_id: m.machine_id,
          official_name: m.official_name,
        }))
        .sort((a, b) => a.official_name.localeCompare(b.official_name)),
    );

    // ── Product list ──────────────────────────────────────────────────────
    setScatterProducts(
      globs
        .filter((g) => (g.machine_count ?? 0) > 0)
        .map((g) => {
          const pod = podMap.get(g.pod_product_id);
          return {
            pod_product_id: g.pod_product_id,
            pod_product_name: pod?.pod_product_name ?? g.pod_product_id,
          };
        })
        .sort((a, b) => a.pod_product_name.localeCompare(b.pod_product_name)),
    );
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
    if (tab === "matrix") fetchScatter();
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
        if (tab === "matrix") fetchScatter();
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
        {(["overview", "matrix", "products"] as Tab[]).map((t) => (
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
              : t === "matrix"
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
        {tab === "matrix" && (
          <ScatterTab
            overallPts={overallPts}
            allSlots={allSlots}
            deviationRows={deviationRows}
            machines={scatterMachines}
            products={scatterProducts}
            clusterColors={clusterColors}
            toggleA={toggleA}
            toggleB={toggleB}
            productId={productId}
            clusterId={clusterId}
            machineId={machineId}
            showSingletons={showSingletons}
            onToggleAChange={(a) => {
              setToggleA(a);
              // Changing grouping resets its own dropdown; preserves B side
              setProductId(null);
              setClusterId(null);
            }}
            onToggleBChange={(b) => {
              setToggleB(b);
              // Changing scope preserves A side; resets machine to "All"
              setMachineId(null);
            }}
            onProductChange={setProductId}
            onClusterChange={setClusterId}
            onMachineChange={setMachineId}
            onShowSingletonsChange={setShowSingletons}
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

// ── Searchable Select ─────────────────────────────────────────────────────────

function SearchableSelect({
  label,
  value,
  onChange,
  options,
  allLabel,
  disabled,
}: {
  label: string;
  value: string | null;
  onChange: (v: string | null) => void;
  options: { value: string; label: string }[];
  allLabel: string;
  disabled?: boolean;
}) {
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  const selectedLabel = value
    ? (options.find((o) => o.value === value)?.label ?? "")
    : allLabel;

  const filtered = query.trim()
    ? options.filter((o) => o.label.toLowerCase().includes(query.toLowerCase()))
    : options;

  useEffect(() => {
    function handle(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false);
        setQuery("");
      }
    }
    document.addEventListener("mousedown", handle);
    return () => document.removeEventListener("mousedown", handle);
  }, []);

  return (
    <div ref={ref} className="relative min-w-[180px]">
      <p className="mb-1 text-xs font-medium text-neutral-500">{label}</p>
      <button
        disabled={disabled}
        onClick={() => {
          if (!disabled) setOpen((o) => !o);
        }}
        className={`flex w-full items-center justify-between gap-2 rounded border px-2.5 py-1.5 text-xs text-left transition-colors ${
          disabled
            ? "cursor-not-allowed border-neutral-200 bg-neutral-50 text-neutral-400 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-600"
            : "border-neutral-300 bg-white hover:border-neutral-400 dark:border-neutral-600 dark:bg-neutral-900 dark:text-neutral-100"
        }`}
      >
        <span className="truncate">{disabled ? "—" : selectedLabel}</span>
        {!disabled && (
          <span className="shrink-0 text-neutral-400">{open ? "▴" : "▾"}</span>
        )}
      </button>

      {open && !disabled && (
        <div className="absolute z-50 mt-1 w-full min-w-[220px] rounded border border-neutral-200 bg-white shadow-xl dark:border-neutral-700 dark:bg-neutral-900">
          <div className="border-b border-neutral-100 p-1.5 dark:border-neutral-800">
            <input
              autoFocus
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Search…"
              className="w-full rounded border border-neutral-200 px-2 py-1 text-xs focus:outline-none dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100"
            />
          </div>
          <div className="max-h-56 overflow-y-auto">
            <button
              onClick={() => {
                onChange(null);
                setOpen(false);
                setQuery("");
              }}
              className={`w-full px-3 py-2 text-left text-xs hover:bg-neutral-50 dark:hover:bg-neutral-800 ${
                !value
                  ? "font-semibold text-neutral-900 dark:text-neutral-100"
                  : "text-neutral-500"
              }`}
            >
              {allLabel}
            </button>
            {filtered.map((o) => (
              <button
                key={o.value}
                onClick={() => {
                  onChange(o.value);
                  setOpen(false);
                  setQuery("");
                }}
                className={`w-full truncate px-3 py-2 text-left text-xs hover:bg-neutral-50 dark:hover:bg-neutral-800 ${
                  value === o.value
                    ? "font-semibold text-neutral-900 dark:text-neutral-100"
                    : "text-neutral-600 dark:text-neutral-400"
                }`}
              >
                {o.label}
              </button>
            ))}
            {filtered.length === 0 && (
              <p className="px-3 py-2 text-xs text-neutral-400">No results</p>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

// ── Scatter / Matrix Tab ──────────────────────────────────────────────────────

type AnyChartPoint = OverallPoint | SlotPoint | ClusterPoint;

function ScatterTab({
  overallPts,
  allSlots,
  deviationRows,
  machines,
  products,
  clusterColors,
  toggleA,
  toggleB,
  productId,
  clusterId,
  machineId,
  showSingletons,
  onToggleAChange,
  onToggleBChange,
  onProductChange,
  onClusterChange,
  onMachineChange,
  onShowSingletonsChange,
}: {
  overallPts: OverallPoint[];
  allSlots: SlotPoint[];
  deviationRows: DeviationRow[];
  machines: MachineOption[];
  products: ProductOption[];
  clusterColors: Record<string, string>;
  toggleA: ToggleA;
  toggleB: ToggleB;
  productId: string | null;
  clusterId: string | null;
  machineId: string | null;
  showSingletons: boolean;
  onToggleAChange: (a: ToggleA) => void;
  onToggleBChange: (b: ToggleB) => void;
  onProductChange: (id: string | null) => void;
  onClusterChange: (id: string | null) => void;
  onMachineChange: (id: string | null) => void;
  onShowSingletonsChange: (v: boolean) => void;
}) {
  // Deviation table local state
  const [devSearch, setDevSearch] = useState("");
  const [devSortCol, setDevSortCol] = useState<keyof DeviationRow>("deviation");
  const [devSortDir, setDevSortDir] = useState<"asc" | "desc">("desc");
  const [devPage, setDevPage] = useState(0);

  // Reset deviation sort default when toggleA changes
  useEffect(() => {
    if (toggleA === "cluster") {
      setDevSortCol("family_name");
      setDevSortDir("asc");
    } else {
      setDevSortCol("deviation");
      setDevSortDir("desc");
    }
  }, [toggleA]);

  // ── All cluster points (derived from overallPts) ──────────────────────
  const allClusterPts = useMemo((): ClusterPoint[] => {
    let overrides: Record<string, string> = {};
    try {
      overrides = JSON.parse(
        localStorage.getItem(FAMILY_OVERRIDES_KEY) ?? "{}",
      );
    } catch {}

    const byFamily = new Map<string, OverallPoint[]>();
    for (const p of overallPts) {
      const fid = p.product_family_id;
      if (!fid) continue;
      if (!byFamily.has(fid)) byFamily.set(fid, []);
      byFamily.get(fid)!.push(p);
    }

    const pts: ClusterPoint[] = [];
    for (const [fid, members] of byFamily) {
      const computed = computeFamilyScore(members);
      const familyName = members[0].family_name ?? "Unknown family";
      const signal =
        overrides[fid] ?? signalFromScore(computed.score, computed.trend);
      const allNames = members.map((m) => m.product_name).join(", ");
      const memberNames =
        allNames.length > 80 ? allNames.substring(0, 79) + "…" : allNames;
      const rx = computed.score,
        ry = computed.trend;
      pts.push({
        family_id: fid,
        family_name: familyName,
        member_count: members.length,
        member_names: memberNames,
        x: rx,
        y: ry,
        xj: Math.max(0, Math.min(10, rx + jitter(fid, 0.2, "x"))),
        yj: Math.max(0, Math.min(10, ry + jitter(fid, 0.2, "y"))),
        z: Math.max(1, Math.min(12, computed.total_velocity)),
        velocity_real: computed.total_velocity,
        signal,
      });
    }
    return pts;
  }, [overallPts]);

  // ── Dropdown A options ────────────────────────────────────────────────
  const productOptions = useMemo(
    () =>
      products.map((p) => ({
        value: p.pod_product_id,
        label: p.pod_product_name,
      })),
    [products],
  );

  const clusterOptions = useMemo(
    () =>
      allClusterPts
        .filter((c) => showSingletons || c.member_count >= 2)
        .map((c) => ({ value: c.family_id, label: c.family_name }))
        .sort((a, b) => a.label.localeCompare(b.label)),
    [allClusterPts, showSingletons],
  );

  // ── Chart data (8 combinations) ───────────────────────────────────────
  const chartData: AnyChartPoint[] = useMemo(() => {
    if (toggleB === "overall") {
      // ── product + overall ─────────────────────────────────────────────
      if (toggleA === "product") {
        if (productId)
          return overallPts.filter((p) => p.pod_product_id === productId);
        return overallPts;
      }
      // ── cluster + overall ─────────────────────────────────────────────
      if (clusterId)
        return allClusterPts.filter((c) => c.family_id === clusterId);
      return allClusterPts.filter((c) => showSingletons || c.member_count >= 2);
    }

    // ── machine mode — filter allSlots ────────────────────────────────
    let rows = allSlots;
    if (machineId) rows = rows.filter((s) => s.machine_id === machineId);
    if (toggleA === "product" && productId)
      rows = rows.filter((s) => s.pod_product_id === productId);
    if (toggleA === "cluster" && clusterId)
      rows = rows.filter((s) => s.product_family_id === clusterId);
    return rows;
  }, [
    toggleA,
    toggleB,
    productId,
    clusterId,
    machineId,
    showSingletons,
    overallPts,
    allSlots,
    allClusterPts,
  ]);

  // ── Determine if we're in cluster-coloring mode ───────────────────────
  const isClusterColorMode = toggleA === "cluster" && toggleB === "machine";

  // ── Labeled dot IDs ───────────────────────────────────────────────────
  const labeledIds = useMemo(() => {
    const ids = new Set<string>();
    // Only use selective labeling for large fleet-wide datasets
    if (chartData.length <= 50) return ids; // empty = label all

    if (toggleA === "product" && toggleB === "overall" && !productId) {
      for (const d of overallPts) {
        if (d.x >= 8.5 || d.x < 1.0) ids.add(d.pod_product_id);
      }
      [...overallPts]
        .sort((a, b) => b.velocity_real - a.velocity_real)
        .slice(0, 5)
        .forEach((d) => ids.add(d.pod_product_id));
    } else if (toggleA === "cluster" && toggleB === "overall" && !clusterId) {
      const pts = allClusterPts.filter(
        (c) => showSingletons || c.member_count >= 2,
      );
      for (const d of pts) {
        if (d.x >= 8.5 || d.x < 1.0) ids.add(d.family_id);
      }
      [...pts]
        .sort((a, b) => b.velocity_real - a.velocity_real)
        .slice(0, 5)
        .forEach((d) => ids.add(d.family_id));
    } else if (toggleB === "machine") {
      // Large slot views — label HERO / DEAD + top 5 velocity
      for (const d of chartData) {
        const sig = (d as { signal?: string }).signal ?? "";
        if (sig === "DOUBLE DOWN" || sig === "DEAD — SWAP NOW") {
          const id =
            (d as OverallPoint).pod_product_id ??
            (d as SlotPoint).shelf_code ??
            "";
          ids.add(id);
        }
      }
      [...chartData]
        .sort(
          (a, b) =>
            (b as { velocity_real: number }).velocity_real -
            (a as { velocity_real: number }).velocity_real,
        )
        .slice(0, 5)
        .forEach((d) => {
          const id =
            (d as SlotPoint).shelf_code ??
            (d as OverallPoint).pod_product_id ??
            "";
          ids.add(id);
        });
    }
    return ids;
  }, [
    toggleA,
    toggleB,
    productId,
    clusterId,
    showSingletons,
    chartData,
    overallPts,
    allClusterPts,
  ]);

  // ── Deviation table ───────────────────────────────────────────────────
  const DEV_COLS: (keyof DeviationRow)[] = [
    "product_name",
    "family_name",
    "machine_name",
    "shelf_code",
    "location_type",
    "velocity",
    "local_score",
    "global_score",
    "deviation",
    "signal",
  ];

  const familyMemberIds = useMemo(() => {
    if (toggleA !== "cluster" || !clusterId) return null;
    return new Set(
      overallPts
        .filter((p) => p.product_family_id === clusterId)
        .map((p) => p.pod_product_id),
    );
  }, [toggleA, clusterId, overallPts]);

  const filteredDevRows = useMemo(() => {
    let rows = deviationRows;
    // Scope filter
    if (toggleB === "machine" && machineId)
      rows = rows.filter((r) => r.machine_id === machineId);
    // Group filter
    if (toggleA === "product" && productId)
      rows = rows.filter((r) => r.pod_product_id === productId);
    else if (familyMemberIds)
      rows = rows.filter((r) => familyMemberIds.has(r.pod_product_id));
    // Text search
    if (devSearch) {
      const q = devSearch.toLowerCase();
      rows = rows.filter(
        (r) =>
          r.product_name.toLowerCase().includes(q) ||
          r.machine_name.toLowerCase().includes(q) ||
          (r.family_name ?? "").toLowerCase().includes(q),
      );
    }
    return [...rows].sort((a, b) => {
      const va = a[devSortCol] ?? "",
        vb = b[devSortCol] ?? "";
      if (typeof va === "number" && typeof vb === "number")
        return devSortDir === "asc" ? va - vb : vb - va;
      return devSortDir === "asc"
        ? String(va).localeCompare(String(vb))
        : String(vb).localeCompare(String(va));
    });
  }, [
    deviationRows,
    toggleA,
    toggleB,
    machineId,
    productId,
    familyMemberIds,
    devSearch,
    devSortCol,
    devSortDir,
  ]);

  const totalDevPages = Math.ceil(filteredDevRows.length / DEV_PAGE_SIZE);
  const pagedDevRows = filteredDevRows.slice(
    devPage * DEV_PAGE_SIZE,
    (devPage + 1) * DEV_PAGE_SIZE,
  );

  useEffect(() => {
    setDevPage(0);
  }, [toggleA, toggleB, machineId, productId, clusterId, devSearch]);

  function toggleSort(col: keyof DeviationRow) {
    if (devSortCol === col)
      setDevSortDir((d) => (d === "asc" ? "desc" : "asc"));
    else {
      setDevSortCol(col);
      setDevSortDir(col === "family_name" ? "asc" : "desc");
    }
  }

  // ── Chart helpers ─────────────────────────────────────────────────────
  const QUADRANT_LABELS = [
    { x: 7.5, y: 8, text: "Double down", color: "#16a34a" },
    { x: 1.5, y: 8, text: "Watch closely", color: "#4ade80" },
    { x: 7.5, y: 1.5, text: "Protect", color: "#facc15" },
    { x: 1.5, y: 1.5, text: "Rotate out", color: "#f87171" },
  ];

  function getSignalColor(signal: string) {
    return SIGNAL_COLORS[signal] ?? "#a3a3a3";
  }

  function dotCount(): string {
    const n = chartData.length;
    if (toggleB === "overall") {
      if (toggleA === "product") return `${n} product${n !== 1 ? "s" : ""}`;
      return `${n} cluster${n !== 1 ? "s" : ""}`;
    }
    return `${n} slot${n !== 1 ? "s" : ""}`;
  }

  // ── Dot colour per cell ───────────────────────────────────────────────
  function dotColor(pt: AnyChartPoint): string {
    if (isClusterColorMode) {
      return (pt as SlotPoint).clusterColor ?? SINGLETON_COLOR;
    }
    return getSignalColor((pt as { signal?: string }).signal ?? "KEEP");
  }

  // ── Label list renderer ───────────────────────────────────────────────
  function renderBubbleLabel(
    props: Record<string, unknown>,
  ): React.ReactElement {
    const x = props.x as number | undefined;
    const y = props.y as number | undefined;
    const index = props.index as number | undefined;
    if (x == null || y == null || index == null || index >= chartData.length)
      return <g />;
    const item = chartData[index];

    const useSelective = chartData.length > 50 && labeledIds.size > 0;
    let shouldLabel = !useSelective;
    let labelText = "";

    if (toggleB === "overall" && toggleA === "product") {
      const p = item as OverallPoint;
      if (useSelective) shouldLabel = labeledIds.has(p.pod_product_id);
      labelText = truncateLabel(p.product_name, 20);
    } else if (toggleB === "overall" && toggleA === "cluster") {
      const p = item as ClusterPoint;
      if (useSelective) shouldLabel = labeledIds.has(p.family_id);
      labelText = truncateLabel(p.family_name, 20);
    } else if (toggleB === "machine") {
      const p = item as SlotPoint;
      if (useSelective)
        shouldLabel =
          labeledIds.has(p.shelf_code) || labeledIds.has(p.pod_product_id);
      // In machine mode label shelf code (compact); in product+machine also show product name
      if (machineId && !productId && toggleA === "product") {
        labelText = truncateLabel(p.shelf_code, 5);
      } else if (!machineId || productId) {
        labelText = truncateLabel(p.machine_name, 12);
      } else {
        labelText = truncateLabel(p.shelf_code, 5);
      }
    }

    if (!shouldLabel || !labelText) return <g />;
    return (
      <text
        x={x}
        y={y}
        dy={-8}
        fontSize={10}
        fontWeight={500}
        fill="#6b7280"
        textAnchor="middle"
        pointerEvents="none"
      >
        {labelText}
      </text>
    );
  }

  // ── Deviation table description ───────────────────────────────────────
  const devDesc = [
    toggleB === "machine" && machineId ? "filtered to machine" : null,
    toggleA === "product" && productId ? "filtered to product" : null,
    toggleA === "cluster" && clusterId ? "filtered to cluster" : null,
  ]
    .filter(Boolean)
    .join(" · ");

  // ── Cluster legend (shown when coloring by cluster) ───────────────────
  const multiMemberClusters = useMemo(
    () =>
      allClusterPts
        .filter((c) => c.member_count >= 2)
        .sort((a, b) => a.family_name.localeCompare(b.family_name)),
    [allClusterPts],
  );

  // Z axis range — shrink dots for dense datasets
  const zRange: [number, number] = chartData.length > 100 ? [6, 80] : [20, 200];

  return (
    <div className="space-y-4">
      {/* ── Two-column controls ── */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        {/* ── Column A ── */}
        <div className="space-y-2 rounded-lg border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950">
          {/* Toggle A */}
          <div className="flex items-center gap-2">
            <span className="text-xs font-medium text-neutral-500">
              Grouping
            </span>
            <div className="flex overflow-hidden rounded border border-neutral-300 dark:border-neutral-600">
              {(["product", "cluster"] as ToggleA[]).map((a) => (
                <button
                  key={a}
                  onClick={() => onToggleAChange(a)}
                  className={`px-3 py-1 text-xs font-medium transition-colors ${
                    toggleA === a
                      ? "bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900"
                      : "bg-white text-neutral-600 hover:bg-neutral-50 dark:bg-neutral-900 dark:text-neutral-400 dark:hover:bg-neutral-800"
                  }`}
                >
                  {a === "product" ? "Product" : "Cluster"}
                </button>
              ))}
            </div>
          </div>

          {/* Dropdown A — always visible */}
          <SearchableSelect
            label={toggleA === "product" ? "Product" : "Cluster"}
            value={toggleA === "product" ? productId : clusterId}
            onChange={toggleA === "product" ? onProductChange : onClusterChange}
            options={toggleA === "product" ? productOptions : clusterOptions}
            allLabel={toggleA === "product" ? "All products" : "All clusters"}
          />

          {/* Singletons checkbox — only when cluster mode */}
          {toggleA === "cluster" && (
            <label className="flex cursor-pointer items-center gap-1.5 text-xs text-neutral-600 dark:text-neutral-400">
              <input
                type="checkbox"
                checked={showSingletons}
                onChange={(e) => onShowSingletonsChange(e.target.checked)}
                className="h-3.5 w-3.5 rounded"
              />
              Show singleton families
            </label>
          )}
        </div>

        {/* ── Column B ── */}
        <div className="space-y-2 rounded-lg border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950">
          {/* Toggle B */}
          <div className="flex items-center gap-2">
            <span className="text-xs font-medium text-neutral-500">Scope</span>
            <div className="flex overflow-hidden rounded border border-neutral-300 dark:border-neutral-600">
              {(["overall", "machine"] as ToggleB[]).map((b) => (
                <button
                  key={b}
                  onClick={() => onToggleBChange(b)}
                  className={`px-3 py-1 text-xs font-medium transition-colors ${
                    toggleB === b
                      ? "bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900"
                      : "bg-white text-neutral-600 hover:bg-neutral-50 dark:bg-neutral-900 dark:text-neutral-400 dark:hover:bg-neutral-800"
                  }`}
                >
                  {b === "overall" ? "Overall" : "Machine"}
                </button>
              ))}
            </div>
          </div>

          {/* Dropdown B — only when Machine scope */}
          <SearchableSelect
            label="Machine"
            value={machineId}
            onChange={onMachineChange}
            options={machines.map((m) => ({
              value: m.machine_id,
              label: m.official_name,
            }))}
            allLabel="All machines"
            disabled={toggleB === "overall"}
          />

          {/* Dot count */}
          <p className="text-xs text-neutral-400">{dotCount()}</p>
        </div>
      </div>

      {/* ── Matrix chart ── */}
      <div className="relative rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
        {/* Quadrant watermarks */}
        <div className="pointer-events-none absolute inset-0 p-4">
          <div className="relative h-full w-full">
            {QUADRANT_LABELS.map((q) => (
              <span
                key={q.text}
                className="absolute text-xs font-semibold opacity-20"
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

        {chartData.length === 0 ? (
          <div className="flex h-[420px] items-center justify-center">
            <p className="max-w-sm text-center text-sm text-neutral-400 leading-relaxed">
              {toggleA === "cluster" && toggleB === "overall" && !showSingletons
                ? 'No multi-member clusters yet. Enable "Show singleton families" or wait for auto-clustering to find more groups.'
                : "No data for this combination."}
            </p>
          </div>
        ) : (
          <ResponsiveContainer width="100%" height={420}>
            <ScatterChart margin={{ top: 20, right: 16, bottom: 24, left: 0 }}>
              <CartesianGrid strokeDasharray="3 3" opacity={0.15} />
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
              <ZAxis type="number" dataKey="z" range={zRange} />
              <ReferenceLine x={5} stroke="#a3a3a3" strokeDasharray="4 2" />
              <ReferenceLine y={5} stroke="#a3a3a3" strokeDasharray="4 2" />
              <Tooltip
                cursor={false}
                content={({ payload }) => {
                  if (!payload?.length) return null;
                  const d = payload[0].payload as OverallPoint &
                    SlotPoint &
                    ClusterPoint;
                  const sig = d.signal ?? "KEEP";
                  const scoreStr = `${d.x.toFixed(2)} (${bracketName(d.x)})`;
                  const trendStr = `${d.y.toFixed(2)} (${trendDirection(d.y)})`;
                  return (
                    <div className="min-w-[200px] rounded border border-neutral-200 bg-white p-3 text-xs shadow-lg dark:border-neutral-700 dark:bg-neutral-900">
                      {/* product + overall */}
                      {toggleB === "overall" && toggleA === "product" && (
                        <>
                          <p className="max-w-[220px] truncate font-semibold text-sm">
                            {d.product_name}
                          </p>
                          <p className="mb-1.5 text-neutral-500">
                            {d.machine_count} machine
                            {d.machine_count !== 1 ? "s" : ""}
                            {d.family_name ? ` · ${d.family_name}` : ""}
                          </p>
                        </>
                      )}
                      {/* cluster + overall */}
                      {toggleB === "overall" && toggleA === "cluster" && (
                        <>
                          <p className="font-semibold text-sm">
                            {d.family_name}
                          </p>
                          <p className="mb-1 text-neutral-500">
                            {d.member_count} product
                            {d.member_count !== 1 ? "s" : ""}
                          </p>
                          <p className="mb-1.5 leading-relaxed text-neutral-400">
                            {d.member_names}
                          </p>
                        </>
                      )}
                      {/* machine mode */}
                      {toggleB === "machine" && (
                        <>
                          <p className="font-semibold text-sm">
                            {d.shelf_code}
                          </p>
                          <p className="mb-0.5 text-neutral-600 dark:text-neutral-400">
                            {d.pod_product_name}
                          </p>
                          <p className="mb-1.5 text-neutral-500">
                            {d.machine_name} · {d.location_type}
                            {d.family_name ? ` · ${d.family_name}` : ""}
                          </p>
                        </>
                      )}
                      <div className="space-y-0.5 text-neutral-700 dark:text-neutral-300">
                        <p>Score: {scoreStr}</p>
                        <p>Trend: {trendStr}</p>
                        <p>
                          Velocity: {d.velocity_real.toFixed(2)} units/day
                          {toggleB === "overall" && toggleA === "cluster"
                            ? " (cluster total)"
                            : ""}
                        </p>
                        {toggleB === "overall" &&
                          toggleA === "product" &&
                          d.best_location_type && (
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
              <Scatter data={chartData} fillOpacity={0.75}>
                {chartData.map((pt, i) => (
                  <Cell key={i} fill={dotColor(pt)} />
                ))}
                <LabelList
                  dataKey="xj"
                  content={
                    renderBubbleLabel as unknown as (
                      props: object,
                    ) => React.ReactElement
                  }
                />
              </Scatter>
            </ScatterChart>
          </ResponsiveContainer>
        )}

        <p className="mt-1 text-center text-xs text-neutral-400">
          Dot positions are slightly jittered for visibility — exact values
          shown in tooltip.
        </p>

        {/* Legend */}
        {isClusterColorMode ? (
          <div className="mt-2 flex flex-wrap gap-3">
            {multiMemberClusters.map((c, i) => (
              <span
                key={c.family_id}
                className="flex items-center gap-1 text-xs"
              >
                <span
                  className="inline-block h-2.5 w-2.5 rounded-full"
                  style={{
                    backgroundColor:
                      clusterColors[c.family_id] ??
                      CLUSTER_COLORS[Math.min(i, CLUSTER_COLORS.length - 1)],
                  }}
                />
                {c.family_name}
              </span>
            ))}
            <span className="flex items-center gap-1 text-xs">
              <span
                className="inline-block h-2.5 w-2.5 rounded-full"
                style={{ backgroundColor: SINGLETON_COLOR }}
              />
              Other
            </span>
          </div>
        ) : (
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
        )}
      </div>

      {/* ── Deviation table ── */}
      <div className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950">
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-neutral-200 px-4 py-3 dark:border-neutral-800">
          <div>
            <h2 className="text-sm font-semibold text-neutral-700 dark:text-neutral-300">
              Local vs global score
            </h2>
            <p className="mt-0.5 text-xs text-neutral-400">
              {filteredDevRows.length} rows
              {devDesc ? ` · ${devDesc}` : ""}
            </p>
          </div>
          <input
            type="text"
            placeholder="Search product, machine or family…"
            value={devSearch}
            onChange={(e) => setDevSearch(e.target.value)}
            className="w-56 rounded border border-neutral-300 px-2.5 py-1.5 text-xs focus:outline-none dark:border-neutral-600 dark:bg-neutral-900 dark:text-neutral-100"
          />
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-xs">
            <thead>
              <tr className="border-b border-neutral-100 bg-neutral-50 text-neutral-500 dark:border-neutral-800 dark:bg-neutral-900">
                {DEV_COLS.map((col) => (
                  <th
                    key={col}
                    onClick={() => toggleSort(col)}
                    className="cursor-pointer select-none whitespace-nowrap px-3 py-2 text-left font-medium uppercase tracking-wide hover:text-neutral-700 dark:hover:text-neutral-300"
                  >
                    {col === "product_name"
                      ? "Product"
                      : col === "family_name"
                        ? "Family"
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
                      // Drill: click row in fleet-product-overall → switch to that machine
                      if (
                        toggleA === "product" &&
                        toggleB === "overall" &&
                        !productId
                      ) {
                        onToggleBChange("machine");
                        onMachineChange(row.machine_id);
                      }
                    }}
                    className={`${
                      toggleA === "product" &&
                      toggleB === "overall" &&
                      !productId
                        ? "cursor-pointer hover:bg-neutral-50 dark:hover:bg-neutral-900"
                        : ""
                    } ${devBg}`}
                  >
                    <td className="max-w-[140px] truncate px-3 py-2 font-medium text-neutral-800 dark:text-neutral-200">
                      {row.product_name}
                    </td>
                    <td className="max-w-[120px] truncate px-3 py-2 text-neutral-500">
                      {row.family_name ?? (
                        <span className="text-neutral-300 dark:text-neutral-600">
                          —
                        </span>
                      )}
                    </td>
                    <td className="max-w-[130px] truncate px-3 py-2 text-neutral-600 dark:text-neutral-400">
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
                        className="inline-block whitespace-nowrap rounded px-1.5 py-0.5 font-medium"
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
                    colSpan={DEV_COLS.length}
                    className="px-4 py-6 text-center text-neutral-400"
                  >
                    No rows match
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>

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
    return (
      (signalFilter === "all" || sig === signalFilter) &&
      (!search ||
        p.pod_product_name.toLowerCase().includes(search.toLowerCase()) ||
        (p.family_name ?? "").toLowerCase().includes(search.toLowerCase()))
    );
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

      <div className="overflow-hidden rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950">
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
