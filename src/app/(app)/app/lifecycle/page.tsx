"use client";

import { useEffect, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
  Cell,
} from "recharts";

// ── Types ─────────────────────────────────────────────────────────────────────

interface KPIs {
  total_slots: number;
  avg_score: number;
  dark_machines: number;
  rotate_or_dead: number; // % of slots with signal ROTATE OUT or DEAD
}

interface ScoreBucket {
  label: string; // "0–1", "1–2", …
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

type Tab = "overview" | "scatter" | "products";

const SIGNAL_COLORS: Record<string, string> = {
  "DOUBLE DOWN": "#16a34a",
  "KEEP GROWING": "#4ade80",
  KEEP: "#a3e635",
  WATCH: "#facc15",
  "WIND DOWN": "#fb923c",
  "ROTATE OUT": "#f87171",
  "DEAD — SWAP NOW": "#dc2626",
};

const SEVERITY_COLORS: Record<string, string> = {
  critical: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200",
  warning:
    "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200",
  info: "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200",
};

// ── Main page ─────────────────────────────────────────────────────────────────

export default function LifecyclePage() {
  const [tab, setTab] = useState<Tab>("overview");
  const [kpis, setKpis] = useState<KPIs | null>(null);
  const [scoreDist, setScoreDist] = useState<ScoreBucket[]>([]);
  const [signalDist, setSignalDist] = useState<SignalRow[]>([]);
  const [dqFlags, setDqFlags] = useState<DQFlag[]>([]);
  const [loading, setLoading] = useState(true);
  const [running, setRunning] = useState(false);
  const [lastRun, setLastRun] = useState<string | null>(null);

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

    // KPIs
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

    // Score distribution (buckets 0–1, 1–2, …, 9–10)
    const buckets = Array.from({ length: 10 }, (_, i) => ({
      label: `${i}–${i + 1}`,
      count: 0,
    }));
    for (const s of slots) {
      const idx = Math.min(9, Math.floor(Number(s.score)));
      buckets[idx].count++;
    }
    setScoreDist(buckets);

    // Signal distribution
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

    // DQ flags
    setDqFlags(
      flags.map((f) => ({
        ...f,
        machine_name: f.machine_id
          ? (machineNameMap.get(f.machine_id) ?? f.machine_id)
          : null,
      })),
    );

    // Last evaluated_at from slot_lifecycle
    const lastEvRes = await supabase
      .from("slot_lifecycle")
      .select("last_evaluated_at")
      .not("last_evaluated_at", "is", null)
      .order("last_evaluated_at", { ascending: false })
      .limit(1)
      .single();
    if (lastEvRes.data?.last_evaluated_at) {
      setLastRun(lastEvRes.data.last_evaluated_at);
    }

    setLoading(false);
  }, []);

  useEffect(() => {
    fetchOverview();
  }, [fetchOverview]);

  async function handleRunNow() {
    setRunning(true);
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
      {/* Header */}
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

      {/* Tabs */}
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
                ? "Score Matrix"
                : "Products"}
          </button>
        ))}
      </div>

      {/* Tab content */}
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
          <PlaceholderTab label="Score Matrix (Sprint 4)" />
        )}
        {tab === "products" && (
          <PlaceholderTab label="Products Analysis (Sprint 5)" />
        )}
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
      {/* KPI row */}
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

      {/* Charts row */}
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        {/* Score distribution */}
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
                {scoreDist.map((entry, i) => (
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

        {/* Signal distribution */}
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

      {/* DQ panel */}
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
                  className={`mt-0.5 shrink-0 rounded px-1.5 py-0.5 text-xs font-medium ${
                    SEVERITY_COLORS[f.severity] ?? SEVERITY_COLORS.info
                  }`}
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

// ── Helpers ───────────────────────────────────────────────────────────────────

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
        className={`mt-1 text-2xl font-bold ${
          highlight === "red"
            ? "text-red-600 dark:text-red-400"
            : "text-neutral-900 dark:text-neutral-100"
        }`}
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

function PlaceholderTab({ label }: { label: string }) {
  return (
    <div className="flex h-64 items-center justify-center rounded-lg border border-dashed border-neutral-300 dark:border-neutral-700">
      <p className="text-sm text-neutral-400">{label}</p>
    </div>
  );
}
