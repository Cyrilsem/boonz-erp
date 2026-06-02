"use client";

import { useState, useEffect, useCallback, useMemo, Fragment } from "react";
import Link from "next/link";
import { createBrowserClient } from "@supabase/ssr";
// RefillPlanReview removed from snapshot tab — plan review is in the Refill Planning tab
import { getDubaiDate } from "@/lib/utils/date";
import { DailyDispatchingTab } from "./DailyDispatchingTab";
import { RefillPlanningTab, type PlanRow } from "./RefillPlanningTab";
import { TrackerTab } from "./TrackerTab";
import { SignalsTab } from "./SignalsTab";

// ── Types ─────────────────────────────────────────────────────────────────────

type RefreshResult = {
  status: string;
  duration_seconds: number;
  sales: { status: string; upserted: number; skipped: number; total: number };
  device_status: { status: string; upserted: number; skipped: number };
  aisle: {
    status: string;
    upserted?: number;
    skipped?: number;
    reason?: string;
    message?: string;
  } | null;
  machines_online: number;
  machines_total: number;
  lookback_days: number;
  timestamp: string;
  error?: string;
};

type DeviceRow = {
  device_name: string;
  is_online: boolean;
  total_curr_stock: number;
  snapshot_at: string;
};

type SaleRow = {
  machine_name: string;
  machine_id: string;
  txn_count: number;
  total_revenue: number;
  total_units: number;
  total_cost: number;
  last_sale: string | null;
};

type SlotWithExpiry = {
  slot: string;
  product: string;
  current_stock: number;
  max_stock: number;
  fill_pct: number;
  expiry_days: number | null;
  expiry_qty: number | null;
  strategy: string | null;
  action_code: string | null;
  global_product_status: string | null;
  local_performance_role: string | null;
  local_product_strategy: string | null;
  suggested_product: string | null;
  units_sold_7d: number | null;
  product_base_score: number | null;
};

type ProgressMsg = { step: string; detail: string; elapsed: string };

type SlotReview = {
  slot: string;
  product: string;
  action: "KEEP" | "REPLACE" | "REDUCE" | "BOOST";
  suggested_product: string | null;
  substitution_reason: string;
  confidence: "HIGH" | "MEDIUM" | "LOW";
  priority: number;
};

type MachineReview = {
  machine_name: string;
  overall_assessment: string;
  anomalies: string[];
  slot_reviews: SlotReview[];
};

type MachineHealth = {
  machine_name: string;
  machine_id: string;
  is_online: boolean;
  total_stock: number;
  max_capacity: number;
  fill_pct: number;
  total_slots: number;
  slots_at_zero: number;
  slots_below_25pct: number;
  daily_velocity: number;
  days_until_empty: number;
  has_sensor_errors: boolean;
  machine_status: string;
  include_in_refill: boolean;
  recently_offline: boolean;
  expired_units: number;
  expiring_7d_units: number;
  expiring_30d_units: number;
  days_to_earliest_expiry: number | null;
  health_tier: "critical" | "warning" | "healthy" | "excluded";
  health_sort: number;
  machine_health_label: string;
  machine_strategy: string;
  dead_stock_count: number;
  local_hero_count: number;
  days_since_visit: number | null;
  pending_swap_count: number;
  is_picked_tomorrow: boolean;
  picker_reasons: string[] | null;
  // Picker v7 alignment (from get_machine_health v2)
  service_track: "main" | "vox";
  priority_tier: "P1_RESTOCK" | "P2_MAINTAIN" | "skip";
  priority_score: number;
};

// ── Helpers ───────────────────────────────────────────────────────────────────

function timeAgo(dateStr: string | null): string {
  if (!dateStr) return "—";
  const diff = Date.now() - new Date(dateStr).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

function fillBg(pct: number): string {
  if (pct === 0) return "bg-red-100 text-red-700";
  if (pct <= 25) return "bg-orange-100 text-orange-700";
  if (pct <= 50) return "bg-yellow-100 text-yellow-700";
  if (pct <= 75) return "bg-lime-100 text-lime-700";
  return "bg-green-100 text-green-700";
}

function fmt2(n: number): string {
  return n.toLocaleString("en-AE", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

function expiryDayClass(days: number): string {
  if (days < 0) return "text-red-600 font-bold";
  if (days <= 7) return "text-amber-600 font-semibold";
  if (days <= 30) return "text-yellow-600";
  return "text-gray-400";
}

function expiryDaysToDate(days: number): string {
  if (days < 0) return "EXPIRED";
  const d = new Date(Date.now() + days * 86400000);
  return d.toLocaleDateString("en-AE", {
    day: "numeric",
    month: "short",
    year: "2-digit",
  });
}

function healthLabelBadgeClass(label: string): string {
  if (label.includes("Star"))
    return "bg-emerald-100 text-emerald-800 border border-emerald-300";
  if (label.includes("Stable"))
    return "bg-yellow-100 text-yellow-800 border border-yellow-300";
  if (label.includes("At Risk"))
    return "bg-orange-100 text-orange-800 border border-orange-300";
  if (label.includes("Ramp-Up"))
    return "bg-blue-100 text-blue-800 border border-blue-300";
  if (label.includes("Zombie"))
    return "bg-red-100 text-red-800 border border-red-300";
  return "bg-gray-100 text-gray-700 border border-gray-200";
}

function strategyBadgeClass(strategy: string | null): string {
  if (!strategy) return "bg-gray-100 text-gray-500";
  if (strategy === "PROTECT") return "bg-green-100 text-green-700";
  if (strategy === "SUSTAIN") return "bg-blue-100 text-blue-700";
  if (strategy === "MAINTAIN") return "bg-gray-100 text-gray-600";
  if (strategy === "FIX MERCH") return "bg-orange-100 text-orange-700";
  if (strategy === "REMOVE") return "bg-red-100 text-red-700";
  if (strategy === "REPLACE") return "bg-orange-100 text-orange-700";
  return "bg-gray-100 text-gray-500";
}

function strategyTooltip(strategy: string | null): string {
  if (!strategy) return "";
  if (strategy === "PROTECT") return "High performer — keep fully stocked";
  if (strategy === "SUSTAIN")
    return "Standard performer — maintain current stock";
  if (strategy === "MAINTAIN")
    return "Low performer — refill only, don't expand";
  if (strategy === "FIX MERCH")
    return "Dead stock — needs product swap or removal";
  if (strategy === "REMOVE") return "Remove this product from this machine";
  return strategy;
}

// ── Card color by sort mode ───────────────────────────────────────────────
// Each sort mode gets its own color scale so the visual encoding matches
// what the user is looking at.

type CardStyle = { card: string; bar: string };
const EXCLUDED_STYLE: CardStyle = {
  card: "bg-gray-50 border-gray-200 opacity-50",
  bar: "bg-gray-200",
};

function statusCardColors(label: string): CardStyle {
  if (label.includes("Zombie"))
    return { card: "bg-red-50 border-red-300", bar: "bg-red-400" };
  if (label.includes("At Risk"))
    return { card: "bg-amber-50 border-amber-300", bar: "bg-amber-400" };
  if (label.includes("Ramp-Up"))
    return { card: "bg-blue-50 border-blue-300", bar: "bg-blue-400" };
  if (label.includes("Star"))
    return { card: "bg-green-50 border-green-200", bar: "bg-green-400" };
  if (label.includes("Stable"))
    return { card: "bg-yellow-50 border-yellow-200", bar: "bg-yellow-400" };
  return EXCLUDED_STYLE;
}

function tierCardColors(m: MachineHealth): CardStyle {
  // Priority mode colors by TIER (consistent within a group) instead of the
  // raw urgency score, so a low-score P1 doesn't render as "healthy green".
  if (m.service_track === "vox")
    return { card: "bg-slate-50 border-slate-200", bar: "bg-slate-300" };
  if (m.priority_tier === "P1_RESTOCK")
    return { card: "bg-red-50 border-red-300", bar: "bg-red-400" };
  if (m.priority_tier === "P2_MAINTAIN")
    return { card: "bg-amber-50 border-amber-200", bar: "bg-amber-400" };
  return { card: "bg-green-50 border-green-200", bar: "bg-green-400" };
}

function metricCardColors(
  value: number,
  thresholds: [number, number, number],
): CardStyle {
  // thresholds = [red, amber, yellow] — value below red = red, below amber = amber, etc.
  const [red, amber, yellow] = thresholds;
  if (value <= red)
    return { card: "bg-red-50 border-red-300", bar: "bg-red-400" };
  if (value <= amber)
    return { card: "bg-amber-50 border-amber-300", bar: "bg-amber-400" };
  if (value <= yellow)
    return { card: "bg-yellow-50 border-yellow-200", bar: "bg-yellow-400" };
  return { card: "bg-green-50 border-green-200", bar: "bg-green-400" };
}

function expiryCardColors(daysToExpiry: number | null): CardStyle {
  const d = daysToExpiry ?? 9999;
  if (d <= 7) return { card: "bg-red-50 border-red-300", bar: "bg-red-400" };
  if (d <= 30)
    return { card: "bg-amber-50 border-amber-300", bar: "bg-amber-400" };
  if (d <= 60)
    return { card: "bg-yellow-50 border-yellow-200", bar: "bg-yellow-400" };
  return { card: "bg-green-50 border-green-200", bar: "bg-green-400" };
}

// ── Component ─────────────────────────────────────────────────────────────────

export default function RefillPage() {
  const [tab, setTab] = useState<
    "snapshot" | "planning" | "dispatching" | "tracker" | "signals"
  >("snapshot");
  const [showTomorrow, setShowTomorrow] = useState(true);

  // ── Hoisted refill planning state (persists across tab switches) ──────────────
  const [planRows, setPlanRows] = useState<PlanRow[]>([]);
  const [editedQty, setEditedQty] = useState<Record<number, number>>({});
  const [removed, setRemoved] = useState<Set<number>>(new Set());
  const [generated, setGenerated] = useState(false);

  const dubaiToday = getDubaiDate();
  const dubaiTomorrow = (() => {
    const d = new Date(dubaiToday);
    d.setDate(d.getDate() + 1);
    return d.toISOString().split("T")[0];
  })();
  const selectedDate = showTomorrow ? dubaiTomorrow : dubaiToday;

  const [refreshing, setRefreshing] = useState(false);
  const [result, setResult] = useState<RefreshResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [lookbackDays, setLookbackDays] = useState(90);

  const [devices, setDevices] = useState<DeviceRow[]>([]);
  const [salesByMachine, setSalesByMachine] = useState<SaleRow[]>([]);
  const [lastRefresh, setLastRefresh] = useState<string | null>(null);
  const [salesCount, setSalesCount] = useState<number | null>(null);

  const [progressMessages, setProgressMessages] = useState<ProgressMsg[]>([]);
  const [machineHealth, setMachineHealth] = useState<MachineHealth[]>([]);
  const [sortBy, setSortBy] = useState<
    "priority" | "status" | "stock" | "fill" | "expiry"
  >("priority");

  // Card-grid filters: search box + clickable legend pills + swaps/dead chips.
  const [search, setSearch] = useState("");
  const [selectedPills, setSelectedPills] = useState<Set<string>>(new Set());
  const [attrSwaps, setAttrSwaps] = useState(false);
  const [attrDead, setAttrDead] = useState(false);
  // Pill labels are per-sort-mode, so reset the selection when the mode changes.
  useEffect(() => {
    setSelectedPills(new Set());
  }, [sortBy]);

  const [selectedMachine, setSelectedMachine] = useState<string | null>(null);
  const [machineSlots, setMachineSlots] = useState<SlotWithExpiry[]>([]);
  const [loadingAisles, setLoadingAisles] = useState(false);
  const [includeInRefill, setIncludeInRefill] = useState(true);
  const [modalSort, setModalSort] = useState<
    "slot" | "stock" | "fill" | "expiry"
  >("slot");

  const [reviewResults, setReviewResults] = useState<
    Record<string, MachineReview>
  >({});
  const [reviewing, setReviewing] = useState(false);
  const [reviewProgress, setReviewProgress] = useState<ProgressMsg[]>([]);
  const [reviewingAll, setReviewingAll] = useState(false);
  const [reviewAllProgress, setReviewAllProgress] = useState<ProgressMsg[]>([]);

  const [stockRefreshing, setStockRefreshing] = useState(false);
  const [stockRefreshMsg, setStockRefreshMsg] = useState<
    | { ok: true; slots: number; ts: string }
    | { ok: false; error: string }
    | null
  >(null);

  const getSupabase = useCallback(() => {
    return createBrowserClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    );
  }, []);

  // ── Load page data (re-runs when lookbackDays changes) ──────────────────────
  const loadData = useCallback(async () => {
    const supabase = getSupabase();

    // Device status — latest snapshot (used for lastRefresh timestamp)
    const { data: deviceData } = await supabase
      .from("weimi_device_status")
      .select(
        "device_name, is_online, total_curr_stock, snapshot_at, snapshot_date",
      )
      .not("device_name", "is", null)
      .order("snapshot_date", { ascending: false })
      .limit(10000);

    if (deviceData && deviceData.length > 0) {
      const latestDate = deviceData[0].snapshot_date;
      const latest = deviceData.filter((r) => r.snapshot_date === latestDate);
      setDevices(
        latest.map((d) => ({
          device_name: d.device_name,
          is_online: d.is_online,
          total_curr_stock: Math.max(d.total_curr_stock, 0),
          snapshot_at: d.snapshot_at,
        })),
      );
      setLastRefresh(latest[0]?.snapshot_at || null);
    }

    // Sales by machine (RPC with lookback filter)
    const { data: salesData } = await supabase
      .rpc("get_sales_by_machine", { lookback_days: lookbackDays })
      .limit(10000);
    if (salesData) setSalesByMachine(salesData as SaleRow[]);

    // Total sales row count
    const { count } = await supabase
      .from("sales_history")
      .select("*", { count: "exact", head: true });
    setSalesCount(count);

    // Machine health cards
    const { data: healthData } = await supabase
      .rpc("get_machine_health")
      .limit(10000);
    if (healthData)
      // Filter out WH warehouse machines — not field machines, should not appear in refill view
      setMachineHealth(
        (healthData as MachineHealth[]).filter(
          (m) => !m.machine_name.toUpperCase().startsWith("WH"),
        ),
      );
  }, [getSupabase, lookbackDays]);

  useEffect(() => {
    loadData();
  }, [loadData]);

  // ── Load slot + expiry detail when a machine card is clicked ────────────────
  const loadAisles = useCallback(
    async (machineName: string) => {
      setLoadingAisles(true);
      setMachineSlots([]);
      const supabase = getSupabase();
      const { data: slotsData } = await supabase
        .rpc("get_machine_slots_with_expiry", { p_machine_name: machineName })
        .limit(10000);
      setMachineSlots((slotsData as SlotWithExpiry[]) || []);
      setLoadingAisles(false);
    },
    [getSupabase],
  );

  useEffect(() => {
    setModalSort("slot");
    setReviewing(false);
    setReviewProgress([]);
    setStockRefreshMsg(null);
    if (!selectedMachine) {
      setMachineSlots([]);
      return;
    }
    const health = machineHealth.find(
      (m) => m.machine_name === selectedMachine,
    );
    setIncludeInRefill(health?.include_in_refill ?? true);
    loadAisles(selectedMachine);
  }, [selectedMachine, loadAisles, machineHealth]);

  // Escape key closes modal
  useEffect(() => {
    if (!selectedMachine) return;
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") setSelectedMachine(null);
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [selectedMachine]);

  // ── Refresh handler (SSE streaming with JSON fallback) ───────────────────────
  async function handleRefresh() {
    setRefreshing(true);
    setError(null);
    setResult(null);
    setProgressMessages([]);

    try {
      const supabase = getSupabase();
      const {
        data: { session },
      } = await supabase.auth.getSession();
      if (!session) {
        setError("Not authenticated. Please log in again.");
        return;
      }

      const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!;
      const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

      const response = await fetch(
        `${supabaseUrl}/functions/v1/refresh-stage1`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Accept: "text/event-stream",
            Authorization: `Bearer ${session.access_token}`,
            apikey: anonKey,
          },
          body: JSON.stringify({
            lookback_days: lookbackDays,
            skip_aisle: true,
          }),
        },
      );

      if (!response.ok) {
        const errData = await response.json().catch(() => ({}));
        setError(
          (errData as { error?: string }).error || `HTTP ${response.status}`,
        );
        return;
      }

      const contentType = response.headers.get("content-type") ?? "";

      if (!contentType.includes("text/event-stream")) {
        const data = (await response.json()) as RefreshResult & {
          error?: string;
        };
        if (data.status === "error") {
          setError(data.error ?? "Refresh failed");
        } else {
          setResult(data);
          await loadData();
        }
        return;
      }

      // ── SSE streaming path ────────────────────────────────────────────────
      const reader = response.body?.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      while (reader) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";

        for (const line of lines) {
          if (!line.startsWith("data: ")) continue;
          let event: Record<string, unknown>;
          try {
            event = JSON.parse(line.slice(6)) as Record<string, unknown>;
          } catch {
            continue;
          }

          const step = event.step as string;
          const detail = (event.detail as string) ?? "";
          const elapsed = (event.elapsed as string) ?? "";

          setProgressMessages((prev) => [...prev, { step, detail, elapsed }]);

          if (step === "done") {
            setResult(event as unknown as RefreshResult);
            await loadData();
          } else if (step === "error") {
            setError(detail || "Refresh failed");
          }
        }
      }
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Unknown error");
    } finally {
      setRefreshing(false);
    }
  }

  // ── Per-machine stock refresh ─────────────────────────────────────────────────
  async function handleStockRefresh(machineId: string) {
    setStockRefreshing(true);
    setStockRefreshMsg(null);
    try {
      const res = await fetch("/api/refill/stock-refresh", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ machine_id: machineId }),
      });
      const data = (await res.json()) as {
        slots_inserted?: number;
        report_timestamp?: string;
        error?: string;
      };
      if (!res.ok || data.error) {
        setStockRefreshMsg({
          ok: false,
          error: data.error ?? `HTTP ${res.status}`,
        });
      } else {
        setStockRefreshMsg({
          ok: true,
          slots: data.slots_inserted ?? 0,
          ts: data.report_timestamp ?? new Date().toISOString(),
        });
        await loadData();
      }
    } catch (e: unknown) {
      setStockRefreshMsg({
        ok: false,
        error: e instanceof Error ? e.message : "Unknown error",
      });
    } finally {
      setStockRefreshing(false);
    }
  }

  // ── Derived values ────────────────────────────────────────────────────────────
  const salesTotals = salesByMachine.reduce(
    (acc, r) => ({
      txn_count: acc.txn_count + Number(r.txn_count),
      total_units: acc.total_units + Number(r.total_units),
      total_revenue: acc.total_revenue + Number(r.total_revenue),
      total_cost: acc.total_cost + Number(r.total_cost),
    }),
    { txn_count: 0, total_units: 0, total_revenue: 0, total_cost: 0 },
  );

  // ── Refill-urgency score (higher = more urgent to visit) ────────────────
  // v7: single source of truth — the backend get_machine_health() computes
  // priority_score with the SAME formula as pick_machines_for_refill v7
  // (empty shelves + velocity/runway dominate; dead/stale/expiry secondary).
  // We just surface it here so card color + sort both key off one number.
  const refillUrgency = useCallback(
    (m: MachineHealth): number => m.priority_score ?? 0,
    [],
  );

  // Tier rank for sorting: P1 first, then P2, skip last.
  const tierRank = useCallback(
    (t: MachineHealth["priority_tier"]): number =>
      t === "P1_RESTOCK" ? 0 : t === "P2_MAINTAIN" ? 1 : 2,
    [],
  );

  // ── Card color resolver — adapts to active sort mode ──────────────────
  const getCardColors = useCallback(
    (m: MachineHealth, sort: typeof sortBy): CardStyle => {
      if (m.health_tier === "excluded") return EXCLUDED_STYLE;
      switch (sort) {
        case "priority":
          return tierCardColors(m);
        case "status":
          return statusCardColors(m.machine_health_label ?? "");
        case "stock":
          // Red ≤20 units, amber ≤50, yellow ≤80, green >80
          return metricCardColors(m.total_stock, [20, 50, 80]);
        case "fill":
          // Red ≤25%, amber ≤50%, yellow ≤70%, green >70%
          return metricCardColors(m.fill_pct, [25, 50, 70]);
        case "expiry":
          return expiryCardColors(m.days_to_earliest_expiry);
        default:
          return statusCardColors(m.machine_health_label ?? "");
      }
    },
    [refillUrgency],
  );

  const sortedMachines = useMemo(() => {
    // ── Status rank (Zombie worst → Stable best) ─────────────────────────
    const labelOrder: Record<string, number> = {
      Zombie: 0,
      "At Risk": 1,
      "Ramp-Up": 2,
      Star: 3,
      Stable: 4,
    };
    const labelRank = (label: string): number => {
      for (const key of Object.keys(labelOrder)) {
        if (label.includes(key)) return labelOrder[key];
      }
      return 99;
    };

    const sorted = [...machineHealth];
    switch (sortBy) {
      case "priority":
        // v7: main track first, then P1 before P2, then by score desc.
        // VOX (service_track='vox') sinks below all main rows (parallel
        // daily-on-the-spot track) — a dashed separator is rendered at the
        // main→vox boundary in the card grid.
        sorted.sort(
          (a, b) =>
            Number(a.service_track === "vox") -
              Number(b.service_track === "vox") ||
            tierRank(a.priority_tier) - tierRank(b.priority_tier) ||
            refillUrgency(b) - refillUrgency(a),
        );
        break;
      case "status":
        sorted.sort(
          (a, b) =>
            labelRank(a.machine_health_label) -
              labelRank(b.machine_health_label) || a.fill_pct - b.fill_pct,
        );
        break;
      case "stock":
        sorted.sort((a, b) => a.total_stock - b.total_stock);
        break;
      case "fill":
        sorted.sort((a, b) => a.fill_pct - b.fill_pct);
        break;
      case "expiry":
        sorted.sort((a, b) => {
          const aExp = a.days_to_earliest_expiry ?? 9999;
          const bExp = b.days_to_earliest_expiry ?? 9999;
          return aExp - bExp;
        });
        break;
    }
    // Excluded machines always at the end
    return sorted.sort((a, b) => {
      if (a.health_tier === "excluded" && b.health_tier !== "excluded")
        return 1;
      if (a.health_tier !== "excluded" && b.health_tier === "excluded")
        return -1;
      return 0;
    });
  }, [machineHealth, sortBy]);

  // ── Dynamic legend pills — adapts to sort mode ─────────────────────────
  type LegendPill = { label: string; count: number; bg: string; text: string };
  const legendPills = useMemo((): LegendPill[] => {
    const active = machineHealth.filter((m) => m.health_tier !== "excluded");
    const excluded = machineHealth.length - active.length;

    const bucket = (
      items: MachineHealth[],
      fn: (m: MachineHealth) => string,
    ): Record<string, number> => {
      const c: Record<string, number> = {};
      for (const m of items) {
        const k = fn(m);
        c[k] = (c[k] ?? 0) + 1;
      }
      return c;
    };

    let pills: LegendPill[] = [];
    switch (sortBy) {
      case "status": {
        const c = bucket(active, (m) => {
          const l = m.machine_health_label ?? "";
          if (l.includes("Zombie")) return "Zombie";
          if (l.includes("At Risk")) return "At Risk";
          if (l.includes("Ramp-Up")) return "Ramp-Up";
          if (l.includes("Star")) return "Star";
          if (l.includes("Stable")) return "Stable";
          return "Other";
        });
        pills = [
          {
            label: "zombie",
            count: c["Zombie"] ?? 0,
            bg: "bg-red-100",
            text: "text-red-700",
          },
          {
            label: "at risk",
            count: c["At Risk"] ?? 0,
            bg: "bg-amber-100",
            text: "text-amber-700",
          },
          {
            label: "ramp-up",
            count: c["Ramp-Up"] ?? 0,
            bg: "bg-blue-100",
            text: "text-blue-700",
          },
          {
            label: "stable",
            count: c["Stable"] ?? 0,
            bg: "bg-yellow-100",
            text: "text-yellow-700",
          },
          {
            label: "star",
            count: c["Star"] ?? 0,
            bg: "bg-green-100",
            text: "text-green-700",
          },
        ];
        break;
      }
      case "priority": {
        // v7 buckets: P1/P2 on the main track + a muted VOX (daily) count.
        const main = active.filter((m) => m.service_track !== "vox");
        const p1 = main.filter((m) => m.priority_tier === "P1_RESTOCK").length;
        const p2 = main.filter(
          (m) => m.priority_tier === "P2_MAINTAIN",
        ).length;
        const vox = active.filter((m) => m.service_track === "vox").length;
        pills = [
          {
            label: "P1 restock",
            count: p1,
            bg: "bg-red-100",
            text: "text-red-700",
          },
          {
            label: "P2 maintain",
            count: p2,
            bg: "bg-amber-100",
            text: "text-amber-700",
          },
          {
            label: "VOX (daily)",
            count: vox,
            bg: "bg-slate-100",
            text: "text-slate-600",
          },
        ];
        break;
      }
      case "stock": {
        const c = bucket(active, (m) => {
          if (m.total_stock <= 20) return "Very Low";
          if (m.total_stock <= 50) return "Low";
          if (m.total_stock <= 80) return "Moderate";
          return "Good";
        });
        pills = [
          {
            label: "very low",
            count: c["Very Low"] ?? 0,
            bg: "bg-red-100",
            text: "text-red-700",
          },
          {
            label: "low",
            count: c["Low"] ?? 0,
            bg: "bg-amber-100",
            text: "text-amber-700",
          },
          {
            label: "moderate",
            count: c["Moderate"] ?? 0,
            bg: "bg-yellow-100",
            text: "text-yellow-700",
          },
          {
            label: "good",
            count: c["Good"] ?? 0,
            bg: "bg-green-100",
            text: "text-green-700",
          },
        ];
        break;
      }
      case "fill": {
        const c = bucket(active, (m) => {
          if (m.fill_pct <= 25) return "Critical";
          if (m.fill_pct <= 50) return "Low";
          if (m.fill_pct <= 70) return "Moderate";
          return "Healthy";
        });
        pills = [
          {
            label: "≤25%",
            count: c["Critical"] ?? 0,
            bg: "bg-red-100",
            text: "text-red-700",
          },
          {
            label: "≤50%",
            count: c["Low"] ?? 0,
            bg: "bg-amber-100",
            text: "text-amber-700",
          },
          {
            label: "≤70%",
            count: c["Moderate"] ?? 0,
            bg: "bg-yellow-100",
            text: "text-yellow-700",
          },
          {
            label: ">70%",
            count: c["Healthy"] ?? 0,
            bg: "bg-green-100",
            text: "text-green-700",
          },
        ];
        break;
      }
      case "expiry": {
        const c = bucket(active, (m) => {
          const d = m.days_to_earliest_expiry ?? 9999;
          if (d <= 7) return "Urgent";
          if (d <= 30) return "Soon";
          if (d <= 60) return "Watch";
          return "Safe";
        });
        pills = [
          {
            label: "≤7d",
            count: c["Urgent"] ?? 0,
            bg: "bg-red-100",
            text: "text-red-700",
          },
          {
            label: "≤30d",
            count: c["Soon"] ?? 0,
            bg: "bg-amber-100",
            text: "text-amber-700",
          },
          {
            label: "≤60d",
            count: c["Watch"] ?? 0,
            bg: "bg-yellow-100",
            text: "text-yellow-700",
          },
          {
            label: ">60d",
            count: c["Safe"] ?? 0,
            bg: "bg-green-100",
            text: "text-green-700",
          },
        ];
        break;
      }
    }
    // Filter out zero-count pills, add excluded if any
    pills = pills.filter((p) => p.count > 0);
    if (excluded > 0)
      pills.push({
        label: "excluded",
        count: excluded,
        bg: "bg-gray-100",
        text: "text-gray-400",
      });
    return pills;
  }, [machineHealth, sortBy, refillUrgency]);

  // Map a pill label to a machine predicate (mirrors the legend buckets above)
  // so clicking a legend pill filters the grid. Keyed by the exact pill labels.
  const pillMatcher = useCallback(
    (label: string) =>
      (m: MachineHealth): boolean => {
        if (label === "excluded") return m.health_tier === "excluded";
        if (m.health_tier === "excluded") return false;
        switch (sortBy) {
          case "priority":
            if (label === "P1 restock")
              return (
                m.service_track !== "vox" && m.priority_tier === "P1_RESTOCK"
              );
            if (label === "P2 maintain")
              return (
                m.service_track !== "vox" && m.priority_tier === "P2_MAINTAIN"
              );
            if (label === "VOX (daily)") return m.service_track === "vox";
            return false;
          case "status": {
            const l = m.machine_health_label ?? "";
            if (label === "zombie") return l.includes("Zombie");
            if (label === "at risk") return l.includes("At Risk");
            if (label === "ramp-up") return l.includes("Ramp-Up");
            if (label === "stable") return l.includes("Stable");
            if (label === "star") return l.includes("Star");
            return false;
          }
          case "stock":
            if (label === "very low") return m.total_stock <= 20;
            if (label === "low")
              return m.total_stock > 20 && m.total_stock <= 50;
            if (label === "moderate")
              return m.total_stock > 50 && m.total_stock <= 80;
            if (label === "good") return m.total_stock > 80;
            return false;
          case "fill":
            if (label === "≤25%") return m.fill_pct <= 25;
            if (label === "≤50%") return m.fill_pct > 25 && m.fill_pct <= 50;
            if (label === "≤70%") return m.fill_pct > 50 && m.fill_pct <= 70;
            if (label === ">70%") return m.fill_pct > 70;
            return false;
          case "expiry": {
            const d = m.days_to_earliest_expiry ?? 9999;
            if (label === "≤7d") return d <= 7;
            if (label === "≤30d") return d > 7 && d <= 30;
            if (label === "≤60d") return d > 30 && d <= 60;
            if (label === ">60d") return d > 60;
            return false;
          }
        }
        return false;
      },
    [sortBy],
  );

  // Apply search + swaps/dead chips + selected legend pills on top of the sort.
  const displayedMachines = useMemo(() => {
    const q = search.trim().toLowerCase();
    return sortedMachines.filter((m) => {
      if (q && !m.machine_name.toLowerCase().includes(q)) return false;
      if (attrSwaps && m.pending_swap_count <= 0) return false;
      if (attrDead && m.dead_stock_count <= 0) return false;
      if (selectedPills.size > 0) {
        const matchAny = Array.from(selectedPills).some((lbl) =>
          pillMatcher(lbl)(m),
        );
        if (!matchAny) return false;
      }
      return true;
    });
  }, [sortedMachines, search, attrSwaps, attrDead, selectedPills, pillMatcher]);

  // Normalize a shelf/slot code so single-digit numbers are zero-padded:
  // "A1" → "A01", "B7" → "B07", "A12" → "A12" (untouched). This is for display
  // and stable lexicographic sort (A01, A02, ... A09, A10, A11 in order).
  const normalizeSlot = (raw: string | null | undefined): string => {
    if (!raw) return "—";
    const m = raw.match(/^([A-Za-z]+)(\d+)$/);
    if (!m) return raw;
    return `${m[1]}${m[2].padStart(2, "0")}`;
  };

  const sortedSlots = useMemo(() => {
    const sorted = [...machineSlots];
    switch (modalSort) {
      case "stock":
        sorted.sort((a, b) => a.current_stock - b.current_stock);
        break;
      case "fill":
        sorted.sort((a, b) => a.fill_pct - b.fill_pct);
        break;
      case "expiry":
        sorted.sort((a, b) => {
          const aExp = a.expiry_days ?? 9999;
          const bExp = b.expiry_days ?? 9999;
          return aExp - bExp;
        });
        break;
      default:
        // Default = sort by Slot (A01, A02, ... A10, A11, B01, ...)
        sorted.sort((a, b) =>
          normalizeSlot(a.slot).localeCompare(normalizeSlot(b.slot)),
        );
        break;
    }
    return sorted;
  }, [machineSlots, modalSort]);

  async function handleToggleRefill(machineName: string, include: boolean) {
    const supabase = getSupabase();
    const { error: rpcError } = await supabase.rpc("toggle_machine_refill", {
      p_machine_name: machineName,
      p_include: include,
    });
    if (!rpcError) {
      const { data: healthData } = await supabase
        .rpc("get_machine_health")
        .limit(10000);
      setMachineHealth(
        ((healthData as MachineHealth[]) || []).filter(
          (m) => !m.machine_name.toUpperCase().startsWith("WH"),
        ),
      );
      setIncludeInRefill(include);
    }
  }

  // ── Claude review — single machine (SSE) ────────────────────────────────────
  async function handleReviewMachine(machineName: string) {
    setReviewing(true);
    setReviewProgress([]);
    try {
      const supabase = getSupabase();
      const {
        data: { session },
      } = await supabase.auth.getSession();
      if (!session) {
        setReviewing(false);
        return;
      }
      const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!;
      const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
      const response = await fetch(
        `${supabaseUrl}/functions/v1/review-machine`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Accept: "text/event-stream",
            Authorization: `Bearer ${session.access_token}`,
            apikey: anonKey,
          },
          body: JSON.stringify({ machine_name: machineName }),
        },
      );
      if (!response.ok) {
        setReviewing(false);
        return;
      }
      const reader = response.body?.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      while (reader) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";
        for (const line of lines) {
          if (!line.startsWith("data: ")) continue;
          let event: Record<string, unknown>;
          try {
            event = JSON.parse(line.slice(6)) as Record<string, unknown>;
          } catch {
            continue;
          }
          const step = event.step as string;
          const detail = (event.detail as string) ?? "";
          setReviewProgress((prev) => [...prev, { step, detail, elapsed: "" }]);
          if (step === "done") {
            const results = event.results as MachineReview[] | undefined;
            if (results && results.length > 0) {
              setReviewResults((prev) => {
                const next = { ...prev };
                for (const r of results) next[r.machine_name] = r;
                return next;
              });
            }
          }
        }
      }
    } catch (e) {
      console.error("[review-machine]", e);
    } finally {
      setReviewing(false);
    }
  }

  // ── Claude review — all machines (SSE) ──────────────────────────────────────
  async function handleReviewAll() {
    setReviewingAll(true);
    setReviewAllProgress([]);
    try {
      const supabase = getSupabase();
      const {
        data: { session },
      } = await supabase.auth.getSession();
      if (!session) {
        setReviewingAll(false);
        return;
      }
      const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!;
      const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
      const response = await fetch(
        `${supabaseUrl}/functions/v1/review-machine`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Accept: "text/event-stream",
            Authorization: `Bearer ${session.access_token}`,
            apikey: anonKey,
          },
          body: JSON.stringify({ review_all: true }),
        },
      );
      if (!response.ok) {
        setReviewingAll(false);
        return;
      }
      const reader = response.body?.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      while (reader) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";
        for (const line of lines) {
          if (!line.startsWith("data: ")) continue;
          let event: Record<string, unknown>;
          try {
            event = JSON.parse(line.slice(6)) as Record<string, unknown>;
          } catch {
            continue;
          }
          const step = event.step as string;
          const detail = (event.detail as string) ?? "";
          setReviewAllProgress((prev) => [
            ...prev,
            { step, detail, elapsed: "" },
          ]);
          if (step === "done") {
            const results = event.results as MachineReview[] | undefined;
            if (results) {
              setReviewResults((prev) => {
                const next = { ...prev };
                for (const r of results) next[r.machine_name] = r;
                return next;
              });
            }
          }
        }
      }
    } catch (e) {
      console.error("[review-all]", e);
    } finally {
      setReviewingAll(false);
    }
  }

  const selectedHealth = machineHealth.find(
    (m) => m.machine_name === selectedMachine,
  );
  const modalTotalCapacity = machineSlots.reduce((s, a) => s + a.max_stock, 0);
  const modalTotalCurrent = machineSlots.reduce(
    (s, a) => s + a.current_stock,
    0,
  );

  // ── Render ────────────────────────────────────────────────────────────────────
  return (
    <div className="max-w-6xl mx-auto px-4 py-8 sm:px-6">
      {/* Header */}
      <div className="mb-8 flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold text-gray-900">Refill data</h1>
          <p className="text-sm text-gray-500 mt-1">
            Pull latest sales, inventory, and machine status from Weimi API
          </p>
          <div className="mt-2 flex items-center gap-3 text-xs">
            <Link
              href="/refill/drift"
              className="text-gray-500 hover:text-gray-900 underline-offset-2 hover:underline transition-colors"
            >
              Inventory drift &rarr;
            </Link>
          </div>
          {/* Today / Tomorrow toggle */}
          <div className="flex gap-2 items-center mt-3">
            <button
              onClick={() => setShowTomorrow(false)}
              className={`px-3 py-1 rounded text-sm font-medium transition-colors ${
                !showTomorrow
                  ? "bg-blue-600 text-white"
                  : "bg-gray-100 text-gray-600 hover:bg-gray-200"
              }`}
            >
              Today
            </button>
            <button
              onClick={() => setShowTomorrow(true)}
              className={`px-3 py-1 rounded text-sm font-medium transition-colors ${
                showTomorrow
                  ? "bg-blue-600 text-white"
                  : "bg-gray-100 text-gray-600 hover:bg-gray-200"
              }`}
            >
              Tomorrow
            </button>
          </div>
          <p className="text-xs text-gray-400 mt-1">{selectedDate}</p>
        </div>
      </div>

      {/* ── Tab bar ──────────────────────────────────────────────────────────── */}
      <div
        style={{
          borderBottom: "1px solid #e8e4de",
          marginBottom: 24,
          display: "flex",
        }}
      >
        {(
          [
            ["snapshot", "Stock Snapshot"],
            ["planning", "Refill Planning"],
            ["dispatching", "Refill Dispatch"],
            ["tracker", "Tracker"],
            ["signals", "Signals"],
          ] as const
        ).map(([t, label]) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            style={{
              padding: "12px 16px",
              fontSize: 12,
              fontWeight: tab === t ? 700 : 500,
              letterSpacing: "0.06em",
              textTransform: "uppercase" as const,
              color: tab === t ? "#0a0a0a" : "#6b6860",
              background: "none",
              border: "none",
              borderBottom:
                tab === t ? "3px solid #0a0a0a" : "3px solid transparent",
              marginBottom: -1,
              cursor: "pointer",
            }}
          >
            {label}
          </button>
        ))}
      </div>

      {/* ── Refill Dispatch tab ───────────────────────────────────────────────── */}
      {tab === "dispatching" && (
        <DailyDispatchingTab selectedDate={selectedDate} />
      )}

      {/* ── Refill Planning tab — RPC-driven plan builder ────────────────────── */}
      {tab === "planning" && (
        <RefillPlanningTab
          selectedDate={selectedDate}
          machineNames={machineHealth.map((m) => m.machine_name)}
          planRows={planRows}
          setPlanRows={setPlanRows}
          editedQty={editedQty}
          setEditedQty={setEditedQty}
          removed={removed}
          setRemoved={setRemoved}
          generated={generated}
          setGenerated={setGenerated}
        />
      )}

      {/* ── Tracker tab — Layer A action items ─────────────────────────────── */}
      {tab === "tracker" && <TrackerTab />}

      {/* ── Signals tab — all decision-feeding data sources ───────────────── */}
      {tab === "signals" && <SignalsTab />}

      {/* ── Stock Snapshot tab — machine health + slot drill-down ────────────── */}
      <div style={{ display: tab === "snapshot" ? undefined : "none" }}>
        {/* Controls card */}
        <div className="bg-white border border-gray-200 rounded-lg p-5 mb-6">
          <div className="flex items-center gap-4 flex-wrap">
            <button
              onClick={handleRefresh}
              disabled={refreshing}
              className={`px-5 py-2.5 rounded-lg font-medium text-sm transition-colors ${
                refreshing
                  ? "bg-gray-100 text-gray-400 cursor-not-allowed"
                  : "bg-gray-900 text-white hover:bg-gray-800 active:bg-gray-700"
              }`}
            >
              {refreshing ? (
                <span className="flex items-center gap-2">
                  <svg
                    className="animate-spin h-4 w-4"
                    viewBox="0 0 24 24"
                    fill="none"
                  >
                    <circle
                      className="opacity-25"
                      cx="12"
                      cy="12"
                      r="10"
                      stroke="currentColor"
                      strokeWidth="4"
                    />
                    <path
                      className="opacity-75"
                      fill="currentColor"
                      d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                    />
                  </svg>
                  Refreshing...
                </span>
              ) : (
                "Refresh data"
              )}
            </button>

            <button
              onClick={handleReviewAll}
              disabled={reviewingAll || refreshing}
              className={`px-4 py-2.5 rounded-lg font-medium text-sm transition-colors ${
                reviewingAll
                  ? "bg-gray-100 text-gray-400 cursor-not-allowed"
                  : "bg-purple-600 text-white hover:bg-purple-700 active:bg-purple-800"
              }`}
            >
              {reviewingAll ? (
                <span className="flex items-center gap-2">
                  <svg
                    className="animate-spin h-4 w-4"
                    viewBox="0 0 24 24"
                    fill="none"
                  >
                    <circle
                      className="opacity-25"
                      cx="12"
                      cy="12"
                      r="10"
                      stroke="currentColor"
                      strokeWidth="4"
                    />
                    <path
                      className="opacity-75"
                      fill="currentColor"
                      d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                    />
                  </svg>
                  Reviewing…
                </span>
              ) : (
                "🤖 Review All"
              )}
            </button>

            <div className="flex items-center gap-2 text-sm text-gray-600">
              <label htmlFor="lookback">Lookback:</label>
              <select
                id="lookback"
                value={lookbackDays}
                onChange={(e) => setLookbackDays(Number(e.target.value))}
                className="border border-gray-300 rounded-md px-2 py-1.5 text-sm bg-white"
                disabled={refreshing}
              >
                <option value={7}>7 days</option>
                <option value={30}>30 days</option>
                <option value={90}>90 days</option>
                <option value={180}>180 days</option>
                <option value={365}>365 days (backfill)</option>
              </select>
            </div>

            <div className="ml-auto flex items-center gap-4 text-xs text-gray-400">
              {salesCount !== null && (
                <span>{salesCount.toLocaleString()} sales rows in DB</span>
              )}
              {lastRefresh && (
                <span>
                  Last refresh:{" "}
                  {new Date(lastRefresh).toLocaleString("en-AE", {
                    timeZone: "Asia/Dubai",
                    day: "numeric",
                    month: "short",
                    hour: "2-digit",
                    minute: "2-digit",
                  })}
                </span>
              )}
            </div>
          </div>

          {/* Live SSE progress — visible while refreshing */}
          {refreshing && progressMessages.length > 0 && (
            <div className="mt-4 bg-blue-50 border border-blue-200 rounded-lg p-4 space-y-1">
              <p className="text-blue-700 font-medium text-sm flex items-center gap-2">
                <span className="inline-block w-4 h-4 border-2 border-blue-400 border-t-transparent rounded-full animate-spin" />
                Refreshing...
              </p>
              <div className="space-y-0.5 mt-2">
                {progressMessages.slice(-5).map((msg, i, arr) => (
                  <p
                    key={i}
                    className={`text-xs font-mono ${i === arr.length - 1 ? "text-blue-700" : "text-blue-400"}`}
                  >
                    → {msg.detail}
                    {msg.elapsed && (
                      <span className="text-blue-300"> ({msg.elapsed}s)</span>
                    )}
                  </p>
                ))}
              </div>
            </div>
          )}

          {/* Review All progress — visible while reviewing all machines */}
          {reviewingAll && reviewAllProgress.length > 0 && (
            <div className="mt-4 bg-purple-50 border border-purple-200 rounded-lg p-4 space-y-1">
              <p className="text-purple-700 font-medium text-sm flex items-center gap-2">
                <span className="inline-block w-4 h-4 border-2 border-purple-400 border-t-transparent rounded-full animate-spin" />
                Reviewing all machines with Claude…
              </p>
              <div className="space-y-0.5 mt-2">
                {reviewAllProgress.slice(-5).map((msg, i, arr) => (
                  <p
                    key={i}
                    className={`text-xs font-mono ${i === arr.length - 1 ? "text-purple-700" : "text-purple-400"}`}
                  >
                    → {msg.detail}
                  </p>
                ))}
              </div>
            </div>
          )}

          {/* Review All done badge */}
          {!reviewingAll && Object.keys(reviewResults).length > 0 && (
            <div className="mt-3 flex items-center gap-2 text-xs text-purple-700">
              <span className="w-2 h-2 rounded-full bg-purple-500" />
              {Object.keys(reviewResults).length} machine
              {Object.keys(reviewResults).length !== 1 ? "s" : ""} reviewed by
              Claude
            </div>
          )}

          {/* Success banner */}
          {!refreshing && result && result.status !== "error" && (
            <div className="mt-4 bg-green-50 border border-green-200 rounded-lg p-4">
              <div className="flex items-center gap-2 mb-3">
                <span className="w-2 h-2 rounded-full bg-green-500" />
                <span className="text-green-700 font-medium text-sm">
                  Refresh complete
                </span>
                {result.duration_seconds && (
                  <span className="text-xs text-green-500">
                    {result.duration_seconds}s
                  </span>
                )}
              </div>
              <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 text-sm">
                <div className="bg-white rounded px-3 py-2 border border-green-100">
                  <div className="text-gray-500 text-xs">Sales lines</div>
                  <div className="font-semibold text-gray-900">
                    {result.sales.upserted.toLocaleString()} upserted
                  </div>
                  {result.sales.skipped > 0 && (
                    <div className="text-xs text-amber-600">
                      {result.sales.skipped} skipped (unknown machine)
                    </div>
                  )}
                </div>
                <div className="bg-white rounded px-3 py-2 border border-green-100">
                  <div className="text-gray-500 text-xs">Machines</div>
                  <div className="font-semibold text-gray-900">
                    {result.machines_online}/{result.machines_total} synced
                  </div>
                </div>
                <div className="bg-white rounded px-3 py-2 border border-green-100">
                  <div className="text-gray-500 text-xs">Aisle snapshot</div>
                  <div className="font-semibold text-gray-900">
                    {result.aisle?.status === "ok"
                      ? `${result.aisle.upserted} slots`
                      : result.aisle?.reason === "skip_aisle_param"
                        ? "Skipped (manual)"
                        : result.aisle?.reason === "endpoint_not_confirmed"
                          ? "Endpoint TBD"
                          : "N/A"}
                  </div>
                </div>
              </div>
              <p className="text-xs text-gray-500 mt-3">
                Pulled {result.lookback_days} days of sales →{" "}
                {result.sales?.upserted?.toLocaleString()} transactions synced.
                Device status updated for {result.machines_total} machines.
                {result.sales?.skipped > 0 &&
                  ` ${result.sales.skipped} skipped (unknown machine).`}
              </p>
            </div>
          )}

          {error && (
            <div className="mt-4 bg-red-50 border border-red-200 rounded-lg p-4">
              <div className="flex items-start gap-2">
                <span className="w-2 h-2 rounded-full bg-red-500 mt-1.5 shrink-0" />
                <div>
                  <span className="text-red-700 text-sm font-medium">
                    Refresh failed
                  </span>
                  <p className="text-red-600 text-sm mt-0.5">{error}</p>
                </div>
              </div>
            </div>
          )}
        </div>

        {/* Machine health cards */}
        {machineHealth.length > 0 && (
          <div className="bg-white border border-gray-200 rounded-lg p-5 mb-6">
            {/* Header: tier counts + sort controls */}
            <div className="flex flex-wrap items-center justify-between gap-3 mb-4">
              <div className="flex flex-wrap items-center gap-2">
                <h2 className="text-base font-medium text-gray-900">
                  Machine health
                </h2>
                <div className="flex flex-wrap items-center gap-1.5 text-xs">
                  {legendPills.map((p) => {
                    const selected = selectedPills.has(p.label);
                    return (
                      <button
                        key={p.label}
                        type="button"
                        title="Click to filter by this group"
                        onClick={() =>
                          setSelectedPills((prev) => {
                            const next = new Set(prev);
                            if (next.has(p.label)) next.delete(p.label);
                            else next.add(p.label);
                            return next;
                          })
                        }
                        className={`px-2 py-0.5 rounded-full font-medium transition ${p.bg} ${p.text} ${
                          selected
                            ? "ring-2 ring-gray-500 ring-offset-1"
                            : "hover:opacity-80"
                        }`}
                      >
                        {p.count} {p.label}
                      </button>
                    );
                  })}
                </div>
              </div>
              <div className="flex items-center gap-1 text-xs text-gray-500">
                <span>Sort:</span>
                {(
                  ["priority", "status", "stock", "fill", "expiry"] as const
                ).map((opt) => (
                  <button
                    key={opt}
                    type="button"
                    onClick={() => setSortBy(opt)}
                    className={`px-2.5 py-1 rounded-md transition-colors ${
                      sortBy === opt
                        ? "bg-gray-900 text-white"
                        : "bg-gray-100 text-gray-600 hover:bg-gray-200"
                    }`}
                  >
                    {opt === "priority"
                      ? "Priority"
                      : opt === "status"
                        ? "Status"
                        : opt === "stock"
                          ? "Stock"
                          : opt === "fill"
                            ? "Fill %"
                            : "Expiry"}
                  </button>
                ))}
              </div>
            </div>
            {/* Search + attribute filters */}
            <div className="flex flex-wrap items-center gap-2 mb-3">
              <input
                type="text"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                placeholder="Search machines…"
                className="px-2.5 py-1 text-xs border border-gray-200 rounded-md w-48 focus:outline-none focus:ring-2 focus:ring-blue-300"
              />
              <button
                type="button"
                onClick={() => setAttrSwaps((s) => !s)}
                className={`px-2.5 py-1 text-xs rounded-md transition-colors ${
                  attrSwaps
                    ? "bg-purple-600 text-white"
                    : "bg-gray-100 text-gray-600 hover:bg-gray-200"
                }`}
              >
                📌 Has swaps
              </button>
              <button
                type="button"
                onClick={() => setAttrDead((s) => !s)}
                className={`px-2.5 py-1 text-xs rounded-md transition-colors ${
                  attrDead
                    ? "bg-red-600 text-white"
                    : "bg-gray-100 text-gray-600 hover:bg-gray-200"
                }`}
              >
                Has dead slots
              </button>
              {(search ||
                attrSwaps ||
                attrDead ||
                selectedPills.size > 0) && (
                <button
                  type="button"
                  onClick={() => {
                    setSearch("");
                    setAttrSwaps(false);
                    setAttrDead(false);
                    setSelectedPills(new Set());
                  }}
                  className="px-2.5 py-1 text-xs rounded-md bg-gray-100 text-gray-500 hover:bg-gray-200"
                >
                  Clear filters
                </button>
              )}
              <span className="text-xs text-gray-400 ml-auto">
                {displayedMachines.length} of {sortedMachines.length} shown
              </span>
            </div>
            <p className="text-xs text-gray-400 mb-3">
              Click a machine to see slot inventory
            </p>
            <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-2.5">
              {displayedMachines.map((m, i) => {
                const tc = getCardColors(m, sortBy);
                const prev = displayedMachines[i - 1];
                // v7: dashed separator at the main→vox boundary (priority sort only)
                const showVoxDivider =
                  sortBy === "priority" &&
                  m.service_track === "vox" &&
                  prev?.service_track !== "vox";

                return (
                  <Fragment key={m.machine_id}>
                    {showVoxDivider && (
                      <div className="col-span-full mt-2 mb-1 flex items-center gap-2 text-[10px] font-medium uppercase tracking-wide text-slate-400">
                        <span className="flex-1 border-t border-dashed border-slate-300" />
                        VOX · refilled daily on the spot
                        <span className="flex-1 border-t border-dashed border-slate-300" />
                      </div>
                    )}
                    <button
                      type="button"
                      onClick={() => setSelectedMachine(m.machine_name)}
                      className={`text-left border rounded-lg px-3 py-2.5 transition-all hover:ring-2 hover:ring-blue-300 focus:outline-none focus:ring-2 focus:ring-blue-400 ${tc.card}`}
                    >
                    {/* Health label badge + picked-tomorrow indicator */}
                    <div className="flex items-center gap-1 mb-1">
                      {m.machine_health_label && (
                        <div
                          className={`text-[9px] font-semibold px-1.5 py-0.5 rounded inline-block leading-tight ${healthLabelBadgeClass(m.machine_health_label)}`}
                        >
                          {m.machine_health_label}
                        </div>
                      )}
                      {m.is_picked_tomorrow && (
                        <span
                          title="Picked for tomorrow"
                          className="text-[11px] leading-none"
                        >
                          🎯
                        </span>
                      )}
                    </div>
                    <div className="mb-0.5">
                      <span className="text-xs font-medium text-gray-700 truncate leading-tight block">
                        {m.machine_name}
                      </span>
                      {m.machine_strategy && (
                        <span className="text-[10px] text-gray-400 leading-tight block truncate">
                          {m.machine_strategy}
                        </span>
                      )}
                    </div>
                    <div className="text-sm font-semibold text-gray-900 mt-1">
                      {m.total_stock.toLocaleString()}
                      <span className="text-[11px] text-gray-400 font-normal">
                        {" "}
                        / {m.max_capacity.toLocaleString()}
                      </span>
                    </div>
                    {/* Fill bar */}
                    <div className="mt-1.5 h-1 rounded-full bg-gray-200 overflow-hidden">
                      <div
                        className={`h-full rounded-full ${tc.bar}`}
                        style={{ width: `${Math.min(m.fill_pct, 100)}%` }}
                      />
                    </div>
                    {/* Quick stats: runway + visit + velocity + dead/hero + swaps */}
                    <div className="mt-1.5 text-[10px] text-gray-500 leading-tight flex flex-wrap gap-x-1.5">
                      {m.days_until_empty != null &&
                        m.days_until_empty < 999 && (
                          <span
                            className={
                              m.days_until_empty <= 3
                                ? "text-red-600 font-medium"
                                : ""
                            }
                          >
                            {m.days_until_empty}d runway
                          </span>
                        )}
                      {m.days_since_visit != null && (
                        <span
                          className={
                            m.days_since_visit >= 7
                              ? "text-amber-600 font-medium"
                              : ""
                          }
                        >
                          {m.days_since_visit}d ago
                        </span>
                      )}
                      {m.daily_velocity > 0 && (
                        <span>↗ {m.daily_velocity.toFixed(1)}/day</span>
                      )}
                      {m.dead_stock_count > 0 && (
                        <span className="text-red-500 font-medium">
                          {m.dead_stock_count}/{m.total_slots} dead
                        </span>
                      )}
                      {m.local_hero_count > 0 && (
                        <span className="text-green-600 font-medium">
                          {m.local_hero_count} hero
                        </span>
                      )}
                      {m.slots_at_zero > 0 && (
                        <span
                          className={
                            m.machine_health_label?.includes("Zombie")
                              ? "text-red-600 font-medium"
                              : ""
                          }
                        >
                          {m.slots_at_zero} empty
                        </span>
                      )}
                      {m.pending_swap_count > 0 && (
                        <span className="text-purple-600 font-medium">
                          📌 {m.pending_swap_count} swaps
                        </span>
                      )}
                    </div>
                    {/* Expiry badge */}
                    {m.expired_units > 0 ? (
                      <div className="mt-1 text-[10px] font-medium px-1 py-0.5 rounded bg-red-100 text-red-600 inline-block">
                        ⚠ {m.expired_units} expired
                      </div>
                    ) : m.expiring_7d_units > 0 ? (
                      <div className="mt-1 text-[10px] font-medium px-1 py-0.5 rounded bg-amber-100 text-amber-700 inline-block">
                        ⏰ {m.expiring_7d_units} exp. 7d
                      </div>
                    ) : m.expiring_30d_units > 0 ? (
                      <div className="mt-1 text-[10px] px-1 py-0.5 rounded bg-gray-100 text-gray-500 inline-block">
                        📅 {m.expiring_30d_units} exp. 30d
                      </div>
                    ) : null}
                    {/* Claude reviewed badge */}
                    {reviewResults[m.machine_name] && (
                      <div className="mt-1 text-[10px] text-purple-600 font-medium">
                        ✓ Reviewed
                      </div>
                    )}
                    {m.health_tier === "excluded" && (
                      <div className="mt-1 text-[10px] text-gray-400 italic">
                        excluded
                      </div>
                    )}
                    {m.has_sensor_errors && (
                      <div className="mt-1 text-[10px] text-amber-600 font-medium">
                        ⚠ sensor
                      </div>
                    )}
                  </button>
                  </Fragment>
                );
              })}
            </div>
            {displayedMachines.length === 0 && (
              <p className="text-center text-xs text-gray-400 py-8">
                No machines match these filters.
              </p>
            )}
          </div>
        )}

        {/* Sales summary table */}
        {salesByMachine.length > 0 && (
          <div className="bg-white border border-gray-200 rounded-lg p-5 mb-6">
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-base font-medium text-gray-900">
                Sales summary
              </h2>
              <span className="text-xs text-gray-400">
                Last {lookbackDays} days
              </span>
            </div>
            <div className="overflow-x-auto -mx-5 px-5">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-gray-200 text-gray-500 text-xs">
                    <th className="text-left py-2.5 pr-3 font-medium">
                      Machine
                    </th>
                    <th className="text-right py-2.5 px-2 font-medium">
                      Transactions
                    </th>
                    <th className="text-right py-2.5 px-2 font-medium">
                      Units sold
                    </th>
                    <th className="text-right py-2.5 px-2 font-medium">
                      Revenue (AED)
                    </th>
                    <th className="text-right py-2.5 px-2 font-medium">
                      Cost (AED)
                    </th>
                    <th className="text-right py-2.5 px-2 font-medium">
                      Margin (AED)
                    </th>
                    <th className="text-right py-2.5 pl-2 font-medium">
                      Last sale
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {salesByMachine.map((s) => {
                    const margin =
                      Number(s.total_revenue) - Number(s.total_cost);
                    return (
                      <tr
                        key={s.machine_id}
                        className="border-b border-gray-50 hover:bg-gray-50/50"
                      >
                        <td className="py-2 pr-3 font-medium text-gray-900">
                          {s.machine_name}
                        </td>
                        <td className="py-2 px-2 text-right text-gray-600 tabular-nums">
                          {Number(s.txn_count).toLocaleString()}
                        </td>
                        <td className="py-2 px-2 text-right text-gray-600 tabular-nums">
                          {Number(s.total_units).toLocaleString()}
                        </td>
                        <td className="py-2 px-2 text-right text-gray-700 tabular-nums font-medium">
                          {fmt2(Number(s.total_revenue))}
                        </td>
                        <td className="py-2 px-2 text-right text-gray-600 tabular-nums">
                          {fmt2(Number(s.total_cost))}
                        </td>
                        <td
                          className={`py-2 px-2 text-right tabular-nums font-medium ${margin >= 0 ? "text-green-700" : "text-red-600"}`}
                        >
                          {fmt2(margin)}
                        </td>
                        <td className="py-2 pl-2 text-right text-gray-400 text-xs tabular-nums">
                          {timeAgo(s.last_sale)}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
                <tfoot>
                  <tr className="border-t-2 border-gray-200 bg-gray-50 font-semibold text-gray-900">
                    <td className="py-2 pr-3 text-sm">Total</td>
                    <td className="py-2 px-2 text-right tabular-nums text-sm">
                      {salesTotals.txn_count.toLocaleString()}
                    </td>
                    <td className="py-2 px-2 text-right tabular-nums text-sm">
                      {salesTotals.total_units.toLocaleString()}
                    </td>
                    <td className="py-2 px-2 text-right tabular-nums text-sm">
                      {fmt2(salesTotals.total_revenue)}
                    </td>
                    <td className="py-2 px-2 text-right tabular-nums text-sm">
                      {fmt2(salesTotals.total_cost)}
                    </td>
                    <td
                      className={`py-2 px-2 text-right tabular-nums text-sm ${salesTotals.total_revenue - salesTotals.total_cost >= 0 ? "text-green-700" : "text-red-600"}`}
                    >
                      {fmt2(salesTotals.total_revenue - salesTotals.total_cost)}
                    </td>
                    <td className="py-2 pl-2" />
                  </tr>
                </tfoot>
              </table>
            </div>
          </div>
        )}

        {/* Empty state */}
        {devices.length === 0 && machineHealth.length === 0 && !refreshing && (
          <div className="bg-white border border-gray-200 rounded-lg p-12 text-center">
            <div className="text-gray-400 text-sm mb-2">No data yet</div>
            <p className="text-gray-500 text-sm">
              Click &quot;Refresh data&quot; to pull the latest from Weimi API
            </p>
          </div>
        )}

        {/* Machine Detail Modal */}
        {selectedMachine && (
          <div
            className="fixed inset-0 z-50 flex items-center justify-center p-4"
            onClick={(e) => {
              if (e.target === e.currentTarget) setSelectedMachine(null);
            }}
          >
            {/* Backdrop */}
            <div
              className="absolute inset-0 bg-black/40 backdrop-blur-sm"
              onClick={() => setSelectedMachine(null)}
            />

            {/* Panel */}
            <div className="relative z-10 w-full max-w-6xl max-h-[90vh] flex flex-col bg-white rounded-xl shadow-2xl overflow-hidden">
              {/* Modal header */}
              <div className="flex items-start justify-between gap-4 px-5 py-4 border-b border-gray-200">
                <div className="flex-1 min-w-0">
                  <h3 className="text-base font-semibold text-gray-900">
                    {selectedMachine}
                  </h3>
                  <div className="flex items-center gap-2 mt-1 flex-wrap">
                    {!loadingAisles && (
                      <span className="text-sm text-gray-500">
                        {modalTotalCurrent} / {modalTotalCapacity} units
                      </span>
                    )}
                    {selectedHealth?.machine_status === "Warehouse" && (
                      <span className="text-xs px-2 py-0.5 bg-gray-200 text-gray-600 rounded">
                        Warehouse
                      </span>
                    )}
                    {(selectedHealth?.expired_units ?? 0) > 0 && (
                      <span className="text-xs px-2 py-0.5 bg-red-100 text-red-700 rounded">
                        ⚠ {selectedHealth!.expired_units} expired
                      </span>
                    )}
                    {(selectedHealth?.expiring_7d_units ?? 0) > 0 && (
                      <span className="text-xs px-2 py-0.5 bg-amber-100 text-amber-700 rounded">
                        ⏰ {selectedHealth!.expiring_7d_units} expiring 7d
                      </span>
                    )}
                  </div>
                  {/* Include in refill toggle + Review button row */}
                  <div className="flex items-center gap-3 mt-3 flex-wrap">
                    {selectedHealth !== undefined && (
                      <label className="flex items-center gap-2 cursor-pointer select-none">
                        <span className="text-xs text-gray-600">
                          Include in refill
                        </span>
                        <div className="relative inline-flex items-center">
                          <input
                            type="checkbox"
                            checked={includeInRefill}
                            onChange={(e) =>
                              handleToggleRefill(
                                selectedMachine!,
                                e.target.checked,
                              )
                            }
                            className="sr-only peer"
                          />
                          <div className="w-10 h-5 bg-gray-200 peer-checked:bg-green-500 rounded-full transition-colors cursor-pointer" />
                          <div className="absolute left-0.5 top-0.5 w-4 h-4 bg-white rounded-full shadow transition-transform peer-checked:translate-x-5 pointer-events-none" />
                        </div>
                      </label>
                    )}
                    <button
                      type="button"
                      onClick={() =>
                        selectedMachine && handleReviewMachine(selectedMachine)
                      }
                      disabled={reviewing}
                      className={`text-xs px-3 py-1.5 rounded-lg font-medium transition-colors ${
                        reviewing
                          ? "bg-gray-100 text-gray-400 cursor-not-allowed"
                          : reviewResults[selectedMachine ?? ""]
                            ? "bg-purple-100 text-purple-700 hover:bg-purple-200"
                            : "bg-amber-100 text-amber-800 hover:bg-amber-200"
                      }`}
                    >
                      {reviewing ? (
                        <span className="flex items-center gap-1.5">
                          <svg
                            className="animate-spin h-3 w-3"
                            viewBox="0 0 24 24"
                            fill="none"
                          >
                            <circle
                              className="opacity-25"
                              cx="12"
                              cy="12"
                              r="10"
                              stroke="currentColor"
                              strokeWidth="4"
                            />
                            <path
                              className="opacity-75"
                              fill="currentColor"
                              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                            />
                          </svg>
                          Reviewing…
                        </span>
                      ) : reviewResults[selectedMachine ?? ""] ? (
                        "🤖 Re-review with Claude"
                      ) : (
                        "🤖 Review with Claude"
                      )}
                    </button>

                    {/* Refresh stock button */}
                    <button
                      type="button"
                      onClick={() => {
                        const machId = machineHealth.find(
                          (m) => m.machine_name === selectedMachine,
                        )?.machine_id;
                        if (machId) handleStockRefresh(machId);
                      }}
                      disabled={stockRefreshing}
                      className={`text-xs px-3 py-1.5 rounded-lg font-medium transition-colors ${
                        stockRefreshing
                          ? "bg-gray-100 text-gray-400 cursor-not-allowed"
                          : "bg-blue-50 text-blue-700 hover:bg-blue-100"
                      }`}
                    >
                      {stockRefreshing ? "Refreshing…" : "Refresh stock"}
                    </button>

                    {/* Stock refresh result */}
                    {stockRefreshMsg && (
                      <span
                        className={`text-xs ${
                          stockRefreshMsg.ok ? "text-green-600" : "text-red-600"
                        }`}
                      >
                        {stockRefreshMsg.ok
                          ? `${stockRefreshMsg.slots} slots updated · ${timeAgo(stockRefreshMsg.ts)}`
                          : stockRefreshMsg.error}
                      </span>
                    )}
                  </div>
                </div>
                <button
                  type="button"
                  onClick={() => setSelectedMachine(null)}
                  className="shrink-0 rounded-lg p-1.5 text-gray-400 hover:bg-gray-100 hover:text-gray-600 transition-colors"
                  aria-label="Close"
                >
                  <svg
                    className="w-5 h-5"
                    viewBox="0 0 20 20"
                    fill="currentColor"
                  >
                    <path
                      fillRule="evenodd"
                      d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z"
                      clipRule="evenodd"
                    />
                  </svg>
                </button>
              </div>

              {/* Modal body */}
              <div className="overflow-y-auto flex-1 px-5 py-4">
                {loadingAisles ? (
                  <div className="flex items-center justify-center py-12 text-gray-400 text-sm gap-2">
                    <svg
                      className="animate-spin h-4 w-4"
                      viewBox="0 0 24 24"
                      fill="none"
                    >
                      <circle
                        className="opacity-25"
                        cx="12"
                        cy="12"
                        r="10"
                        stroke="currentColor"
                        strokeWidth="4"
                      />
                      <path
                        className="opacity-75"
                        fill="currentColor"
                        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                      />
                    </svg>
                    Loading slots...
                  </div>
                ) : machineSlots.length === 0 ? (
                  <div className="text-center py-12 text-gray-400 text-sm">
                    No slot data available for this machine
                  </div>
                ) : (
                  <>
                    {/* Review progress — visible while Claude is reviewing */}
                    {reviewing && reviewProgress.length > 0 && (
                      <div className="mb-3 bg-purple-50 border border-purple-200 rounded-lg p-3">
                        <p className="text-purple-700 font-medium text-xs flex items-center gap-1.5 mb-1">
                          <span className="inline-block w-3 h-3 border-2 border-purple-400 border-t-transparent rounded-full animate-spin" />
                          Claude is reviewing…
                        </p>
                        {reviewProgress.slice(-3).map((msg, i, arr) => (
                          <p
                            key={i}
                            className={`text-xs font-mono ${i === arr.length - 1 ? "text-purple-700" : "text-purple-400"}`}
                          >
                            → {msg.detail}
                          </p>
                        ))}
                      </div>
                    )}

                    {/* Intelligence summary bar + urgency breakdown */}
                    {selectedHealth &&
                      (() => {
                        const h = selectedHealth;
                        const urgScore = refillUrgency(h);
                        // Build score breakdown for display
                        const reasons: {
                          label: string;
                          pts: number;
                          color: string;
                        }[] = [];
                        if (h.slots_at_zero > 0)
                          reasons.push({
                            label: `${h.slots_at_zero} empty shelves`,
                            pts: h.slots_at_zero * 15,
                            color: "text-red-600",
                          });
                        const nearEmpty = Math.max(
                          0,
                          h.slots_below_25pct - h.slots_at_zero,
                        );
                        if (nearEmpty > 0)
                          reasons.push({
                            label: `${nearEmpty} shelves <25%`,
                            pts: nearEmpty * 8,
                            color: "text-amber-600",
                          });
                        const runway = h.days_until_empty ?? 999;
                        if (runway <= 14) {
                          const rPts =
                            runway <= 1
                              ? 50
                              : runway <= 3
                                ? 35
                                : runway <= 7
                                  ? 20
                                  : 8;
                          reasons.push({
                            label: `${Math.round(runway)}d runway`,
                            pts: rPts,
                            color:
                              runway <= 3 ? "text-red-600" : "text-amber-600",
                          });
                        }
                        if (h.daily_velocity > 0)
                          reasons.push({
                            label: `↗ ${h.daily_velocity.toFixed(1)}/day velocity`,
                            pts: Math.round(Math.min(h.daily_velocity * 2, 30)),
                            color: "text-blue-600",
                          });
                        const daysSince = h.days_since_visit ?? 0;
                        if (daysSince >= 4) {
                          const vPts =
                            daysSince >= 14 ? 25 : daysSince >= 7 ? 15 : 5;
                          reasons.push({
                            label: `${daysSince}d since visit`,
                            pts: vPts,
                            color:
                              daysSince >= 7
                                ? "text-amber-600"
                                : "text-gray-600",
                          });
                        }
                        if (h.expired_units > 0)
                          reasons.push({
                            label: `${h.expired_units} expired units`,
                            pts: 20 + h.expired_units * 2,
                            color: "text-red-600",
                          });
                        if (h.pending_swap_count > 0)
                          reasons.push({
                            label: `${h.pending_swap_count} pending swaps`,
                            pts: h.pending_swap_count * 5,
                            color: "text-purple-600",
                          });
                        if (h.is_picked_tomorrow)
                          reasons.push({
                            label: "Picked for tomorrow",
                            pts: 40,
                            color: "text-blue-700",
                          });
                        if (h.fill_pct < 50) {
                          const fPts = h.fill_pct < 30 ? 15 : 8;
                          reasons.push({
                            label: `${h.fill_pct.toFixed(0)}% fill`,
                            pts: fPts,
                            color: "text-amber-600",
                          });
                        }
                        if (h.dead_stock_count > 0)
                          reasons.push({
                            label: `${h.dead_stock_count}/${h.total_slots} dead stock`,
                            pts: 0,
                            color: "text-red-600",
                          });
                        if (h.local_hero_count > 0)
                          reasons.push({
                            label: `${h.local_hero_count} hero${h.local_hero_count !== 1 ? "s" : ""}`,
                            pts: 0,
                            color: "text-green-600",
                          });

                        // Sort by points descending
                        reasons.sort((a, b) => b.pts - a.pts);

                        return (
                          <div className="mb-3 bg-gray-50 border border-gray-200 rounded-lg px-3 py-2.5 text-xs text-gray-600">
                            {/* Row 1: label + strategy + urgency score */}
                            <div className="flex flex-wrap items-center gap-x-3 gap-y-1 mb-1.5">
                              {h.machine_health_label && (
                                <span
                                  className={`font-semibold px-1.5 py-0.5 rounded ${healthLabelBadgeClass(h.machine_health_label)}`}
                                >
                                  {h.machine_health_label}
                                </span>
                              )}
                              {h.machine_strategy && (
                                <span className="text-gray-500">
                                  {h.machine_strategy}
                                </span>
                              )}
                              <span className="ml-auto text-[10px] font-mono text-gray-400">
                                urgency: {urgScore} pts
                              </span>
                            </div>
                            {/* Row 2: score breakdown — WHY this machine matters */}
                            {reasons.length > 0 && (
                              <div className="flex flex-wrap gap-x-2 gap-y-0.5 text-[10px] leading-relaxed">
                                {reasons.map((r, i) => (
                                  <span
                                    key={i}
                                    className={`${r.color} ${r.pts > 0 ? "font-medium" : ""}`}
                                  >
                                    {r.label}
                                    {r.pts > 0 ? ` (+${r.pts})` : ""}
                                  </span>
                                ))}
                              </div>
                            )}
                          </div>
                        );
                      })()}

                    {/* Sort controls */}
                    <div className="flex items-center gap-2 mb-3">
                      <span className="text-xs text-gray-500">Sort by:</span>
                      {(["slot", "stock", "fill", "expiry"] as const).map(
                        (opt) => (
                          <button
                            key={opt}
                            type="button"
                            onClick={() => setModalSort(opt)}
                            className={`text-xs px-2 py-1 rounded transition-colors ${
                              modalSort === opt
                                ? "bg-gray-800 text-white"
                                : "bg-gray-100 text-gray-600 hover:bg-gray-200"
                            }`}
                          >
                            {opt === "slot"
                              ? "Slot"
                              : opt === "stock"
                                ? "Stock ↑"
                                : opt === "fill"
                                  ? "Fill % ↑"
                                  : "Expiry ↑"}
                          </button>
                        ),
                      )}
                    </div>

                    {/* Slot intelligence table */}
                    <div className="overflow-x-auto -mx-5 px-5">
                      <table className="w-full text-sm min-w-[600px]">
                        <thead>
                          <tr className="border-b border-gray-200 text-gray-500 text-xs">
                            <th className="text-left py-2 pr-2 font-medium">
                              Slot
                            </th>
                            <th className="text-left py-2 px-2 font-medium">
                              Product
                            </th>
                            <th className="text-right py-2 px-2 font-medium">
                              Stock
                            </th>
                            <th className="text-right py-2 px-2 font-medium">
                              Fill
                            </th>
                            <th className="text-center py-2 px-2 font-medium">
                              Strategy
                            </th>
                            <th
                              className="text-center py-2 px-2 font-medium cursor-help"
                              title="Global product status across all machines"
                            >
                              Global
                            </th>
                            <th
                              className="text-center py-2 px-2 font-medium cursor-help"
                              title="Local performance role in this machine"
                            >
                              Local
                            </th>
                            <th className="text-right py-2 px-2 font-medium">
                              7d Sales
                            </th>
                            <th className="text-right py-2 px-2 font-medium">
                              Score
                            </th>
                            <th className="text-left py-2 px-2 font-medium">
                              Suggestion
                            </th>
                            <th className="text-right py-2 pl-2 font-medium">
                              Exp. Date
                            </th>
                            <th className="text-right py-2 pl-2 font-medium">
                              Exp. Qty
                            </th>
                          </tr>
                        </thead>
                        <tbody>
                          {sortedSlots.map((s, idx) => {
                            const claudeSlot = reviewResults[
                              selectedMachine ?? ""
                            ]?.slot_reviews.find((r) => r.slot === s.slot);
                            const isReplace =
                              claudeSlot?.action === "REPLACE" ||
                              s.strategy === "REPLACE";
                            const isRemove = s.strategy === "REMOVE";

                            return (
                              <tr
                                key={`${s.slot}-${idx}`}
                                className={`border-b border-gray-50 ${
                                  isReplace
                                    ? "bg-amber-50"
                                    : isRemove
                                      ? "bg-red-50/40"
                                      : ""
                                }`}
                              >
                                <td className="py-1.5 pr-2 font-mono text-xs text-gray-600">
                                  {normalizeSlot(s.slot)}
                                </td>
                                {/* Product */}
                                <td className="py-1.5 px-2 text-xs max-w-[160px]">
                                  <div className="text-gray-800 truncate">
                                    {s.product || "—"}
                                  </div>
                                  {claudeSlot?.suggested_product && (
                                    <div className="text-[10px] text-purple-700 font-medium truncate">
                                      🤖 {claudeSlot.suggested_product}
                                    </div>
                                  )}
                                </td>
                                {/* Stock */}
                                <td className="py-1.5 px-2 text-right tabular-nums text-xs text-gray-600 whitespace-nowrap">
                                  {s.current_stock}/{s.max_stock}
                                </td>
                                {/* Fill */}
                                <td className="py-1.5 px-2 text-right">
                                  <span
                                    className={`inline-block min-w-[2.5rem] text-center px-1 py-0.5 rounded text-[10px] font-medium ${fillBg(s.fill_pct)}`}
                                  >
                                    {s.fill_pct}%
                                  </span>
                                </td>
                                {/* Strategy */}
                                <td className="py-1.5 px-2 text-center">
                                  {s.strategy ? (
                                    <span
                                      title={strategyTooltip(s.strategy)}
                                      className={`text-[10px] px-1.5 py-0.5 rounded font-medium cursor-help ${strategyBadgeClass(s.strategy)}`}
                                    >
                                      {s.strategy}
                                    </span>
                                  ) : (
                                    <span className="text-gray-300 text-xs">
                                      —
                                    </span>
                                  )}
                                </td>
                                {/* Global */}
                                <td className="py-1.5 px-2 text-center text-sm">
                                  {s.global_product_status?.includes("💎") ? (
                                    <span
                                      title="Global Hero — top 20% product across all machines"
                                      className="cursor-help"
                                    >
                                      💎
                                    </span>
                                  ) : s.global_product_status?.includes(
                                      "📦",
                                    ) ? (
                                    <span
                                      title="Core Range — standard performer globally"
                                      className="cursor-help"
                                    >
                                      📦
                                    </span>
                                  ) : s.global_product_status?.includes(
                                      "🔻",
                                    ) ? (
                                    <span
                                      title="Global Drag — bottom 20% product across all machines"
                                      className="cursor-help"
                                    >
                                      🔻
                                    </span>
                                  ) : (
                                    <span className="text-gray-300 text-xs">
                                      —
                                    </span>
                                  )}
                                </td>
                                {/* Local */}
                                <td className="py-1.5 px-2 text-center text-sm">
                                  {s.local_performance_role?.includes("👑") ? (
                                    <span
                                      title="Local Hero — top performer in this machine"
                                      className="cursor-help"
                                    >
                                      👑
                                    </span>
                                  ) : s.local_performance_role?.includes(
                                      "💀",
                                    ) ? (
                                    <span
                                      title="Dead Stock — zero or near-zero sales in this machine"
                                      className="cursor-help"
                                    >
                                      💀
                                    </span>
                                  ) : s.local_performance_role?.includes(
                                      "✅",
                                    ) ? (
                                    <span
                                      title="Standard — normal performer in this machine"
                                      className="cursor-help"
                                    >
                                      ✅
                                    </span>
                                  ) : s.local_performance_role?.includes(
                                      "📊",
                                    ) ? (
                                    <span
                                      title="Standard — normal performer in this machine"
                                      className="cursor-help"
                                    >
                                      📊
                                    </span>
                                  ) : (
                                    <span className="text-gray-300 text-xs">
                                      —
                                    </span>
                                  )}
                                </td>
                                {/* 7d Sales */}
                                <td className="py-1.5 px-2 text-right tabular-nums text-xs">
                                  {s.units_sold_7d != null ? (
                                    <span
                                      className={
                                        s.units_sold_7d > 0
                                          ? "text-gray-900 font-semibold"
                                          : "text-gray-400"
                                      }
                                    >
                                      {s.units_sold_7d.toFixed(0)}
                                    </span>
                                  ) : (
                                    <span className="text-gray-300">—</span>
                                  )}
                                </td>
                                {/* Score */}
                                <td className="py-1.5 px-2 text-right tabular-nums text-xs text-gray-500">
                                  {s.product_base_score != null
                                    ? s.product_base_score.toFixed(1)
                                    : "—"}
                                </td>
                                {/* Suggestion */}
                                <td className="py-1.5 px-2 text-xs max-w-[140px]">
                                  {s.suggested_product ? (
                                    <span className="text-amber-700 truncate block">
                                      {s.suggested_product}
                                    </span>
                                  ) : (
                                    <span className="text-gray-300">—</span>
                                  )}
                                </td>
                                {/* Exp. Date */}
                                <td className="py-1.5 pl-2 text-right tabular-nums text-xs whitespace-nowrap">
                                  {s.expiry_days != null ? (
                                    <span
                                      className={expiryDayClass(s.expiry_days)}
                                    >
                                      {expiryDaysToDate(s.expiry_days)}
                                    </span>
                                  ) : (
                                    <span className="text-gray-300">—</span>
                                  )}
                                </td>
                                {/* Exp. Qty */}
                                <td className="py-1.5 pl-2 text-right tabular-nums text-xs">
                                  {s.expiry_qty != null ? (
                                    <span className="text-gray-600">
                                      {s.expiry_qty}
                                    </span>
                                  ) : (
                                    <span className="text-gray-300">—</span>
                                  )}
                                </td>
                              </tr>
                            );
                          })}
                        </tbody>
                      </table>
                    </div>

                    {/* Claude review results section */}
                    {reviewResults[selectedMachine ?? ""] && (
                      <div className="mt-5 border-t border-gray-100 pt-4">
                        <div className="flex items-center gap-2 mb-3">
                          <span className="text-sm font-medium text-purple-800">
                            🤖 Claude Review
                          </span>
                          <span className="text-xs text-gray-400">
                            {
                              reviewResults[
                                selectedMachine ?? ""
                              ].slot_reviews.filter(
                                (r) => r.action === "REPLACE",
                              ).length
                            }{" "}
                            replacements recommended
                          </span>
                        </div>

                        {/* Overall assessment */}
                        <div className="bg-purple-50 border border-purple-100 rounded-lg px-3 py-2.5 mb-3 text-xs text-purple-900 leading-relaxed">
                          {
                            reviewResults[selectedMachine ?? ""]
                              .overall_assessment
                          }
                        </div>

                        {/* Anomalies */}
                        {reviewResults[selectedMachine ?? ""].anomalies.length >
                          0 && (
                          <div className="flex flex-wrap gap-1.5 mb-3">
                            {reviewResults[selectedMachine ?? ""].anomalies.map(
                              (a, i) => (
                                <span
                                  key={i}
                                  className="text-[10px] px-2 py-0.5 rounded-full bg-amber-100 text-amber-800 font-medium"
                                >
                                  ⚠ {a}
                                </span>
                              ),
                            )}
                          </div>
                        )}

                        {/* Replacement recommendations */}
                        {reviewResults[selectedMachine ?? ""].slot_reviews
                          .filter((r) => r.action === "REPLACE")
                          .sort((a, b) => a.priority - b.priority)
                          .map((r) => (
                            <div
                              key={r.slot}
                              className="flex items-start gap-3 py-2 border-b border-gray-50 last:border-0"
                            >
                              <span className="font-mono text-xs text-gray-500 w-8 shrink-0 pt-0.5">
                                {r.slot}
                              </span>
                              <div className="flex-1 min-w-0">
                                <div className="flex items-center gap-2 flex-wrap">
                                  <span className="text-xs text-gray-700 font-medium">
                                    {r.product}
                                  </span>
                                  <span className="text-gray-400 text-xs">
                                    →
                                  </span>
                                  <span className="text-xs text-amber-800 font-semibold">
                                    {r.suggested_product ?? "TBD"}
                                  </span>
                                  <span
                                    className={`text-[10px] px-1.5 py-0.5 rounded font-medium ${
                                      r.confidence === "HIGH"
                                        ? "bg-green-100 text-green-700"
                                        : r.confidence === "MEDIUM"
                                          ? "bg-yellow-100 text-yellow-700"
                                          : "bg-gray-100 text-gray-500"
                                    }`}
                                  >
                                    {r.confidence}
                                  </span>
                                </div>
                                <p className="text-[10px] text-gray-500 mt-0.5 leading-snug">
                                  {r.substitution_reason}
                                </p>
                              </div>
                            </div>
                          ))}
                      </div>
                    )}
                  </>
                )}
              </div>
            </div>
          </div>
        )}
      </div>
      {/* end snapshot tab */}
    </div>
  );
}
