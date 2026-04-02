"use client";

import { useState, useEffect, useCallback, useMemo } from "react";
import { createBrowserClient } from "@supabase/ssr";

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

type SummaryRow = {
  machine_name: string;
  is_online: boolean;
  total_slots: number;
  total_capacity: number;
  total_current_stock: number;
  total_shortage: number;
  shortage_pct: number;
  slots_at_zero: number;
  slots_below_25pct: number;
  snapshot_date: string;
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
};

type RefillPlanRow = {
  id: string;
  plan_date: string;
  machine_name: string;
  machine_priority: number;
  shelf_code: string;
  pod_product_name: string;
  boonz_product_name: string;
  action: string;
  quantity: number;
  current_stock: number;
  max_stock: number;
  smart_target: number | null;
  tier: string | null;
  global_score: number | null;
  sold_7d: number | null;
  fill_pct: number | null;
  comment: string | null;
  operator_status: string;
  operator_comment: string | null;
};

type RefillPlanGroup = {
  machine_name: string;
  machine_priority: number;
  rows: RefillPlanRow[];
  total_units: number;
  refill_count: number;
  add_count: number;
  remove_count: number;
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

const tierColors: Record<string, { card: string; bar: string }> = {
  critical: { card: "bg-red-50 border-red-300", bar: "bg-red-400" },
  warning: { card: "bg-amber-50 border-amber-300", bar: "bg-amber-400" },
  healthy: { card: "bg-green-50 border-green-200", bar: "bg-green-400" },
  excluded: {
    card: "bg-gray-50 border-gray-200 opacity-50",
    bar: "bg-gray-200",
  },
};

// ── Component ─────────────────────────────────────────────────────────────────

export default function RefillPage() {
  const [refreshing, setRefreshing] = useState(false);
  const [result, setResult] = useState<RefreshResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [lookbackDays, setLookbackDays] = useState(90);

  const [devices, setDevices] = useState<DeviceRow[]>([]);
  const [summaries, setSummaries] = useState<SummaryRow[]>([]);
  const [salesByMachine, setSalesByMachine] = useState<SaleRow[]>([]);
  const [lastRefresh, setLastRefresh] = useState<string | null>(null);
  const [salesCount, setSalesCount] = useState<number | null>(null);

  const [progressMessages, setProgressMessages] = useState<ProgressMsg[]>([]);
  const [machineHealth, setMachineHealth] = useState<MachineHealth[]>([]);
  const [sortBy, setSortBy] = useState<
    "priority" | "stock" | "fill" | "expiry"
  >("priority");

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

  // ── Refill Plan state ────────────────────────────────────────────────────────
  const [planRows, setPlanRows] = useState<RefillPlanRow[]>([]);
  const [planDate, setPlanDate] = useState<string | null>(null);
  const [planExpanded, setPlanExpanded] = useState<string | null>(null);
  const [planComments, setPlanComments] = useState<Record<string, string>>({});
  const [planProcessing, setPlanProcessing] = useState<Set<string>>(new Set());
  const [planCollapsed, setPlanCollapsed] = useState(false);

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

    // Machine summaries from aisle view
    const { data: summaryData } = await supabase
      .from("v_machine_summary")
      .select("*")
      .limit(10000);
    if (summaryData && summaryData.length > 0)
      setSummaries(summaryData as SummaryRow[]);

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
    if (healthData) setMachineHealth(healthData as MachineHealth[]);
  }, [getSupabase, lookbackDays]);

  useEffect(() => {
    loadData();
  }, [loadData]);

  // ── Load pending refill plan ─────────────────────────────────────────────────
  const loadPlan = useCallback(async () => {
    const supabase = getSupabase();
    const { data } = await supabase
      .from("refill_plan_output")
      .select("*")
      .eq("operator_status", "pending")
      .order("machine_priority", { ascending: true })
      .order("shelf_code", { ascending: true })
      .limit(10000);
    if (data && data.length > 0) {
      setPlanRows(data as RefillPlanRow[]);
      setPlanDate((data[0] as RefillPlanRow).plan_date);
    } else {
      setPlanRows([]);
      setPlanDate(null);
    }
  }, [getSupabase]);

  useEffect(() => {
    loadPlan();
  }, [loadPlan]);

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

  const sortedMachines = useMemo(() => {
    const sorted = [...machineHealth];
    switch (sortBy) {
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
      default:
        sorted.sort(
          (a, b) => a.health_sort - b.health_sort || a.fill_pct - b.fill_pct,
        );
    }
    return sorted.sort((a, b) => {
      if (a.health_tier === "excluded" && b.health_tier !== "excluded")
        return 1;
      if (a.health_tier !== "excluded" && b.health_tier === "excluded")
        return -1;
      return 0;
    });
  }, [machineHealth, sortBy]);

  const tierCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const m of machineHealth) {
      counts[m.health_tier] = (counts[m.health_tier] ?? 0) + 1;
    }
    return counts;
  }, [machineHealth]);

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
        break;
    }
    return sorted;
  }, [machineSlots, modalSort]);

  const planGroups = useMemo((): RefillPlanGroup[] => {
    const map = new Map<string, RefillPlanRow[]>();
    for (const row of planRows) {
      if (!map.has(row.machine_name)) map.set(row.machine_name, []);
      map.get(row.machine_name)!.push(row);
    }
    return Array.from(map.entries()).map(([machine_name, rows]) => ({
      machine_name,
      machine_priority: rows[0].machine_priority,
      rows,
      total_units: rows.reduce((s, r) => s + (r.quantity ?? 0), 0),
      refill_count: rows.filter((r) => r.action === "Refill").length,
      add_count: rows.filter((r) => r.action === "Add New").length,
      remove_count: rows.filter((r) => r.action === "Remove").length,
    }));
  }, [planRows]);

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
      setMachineHealth((healthData as MachineHealth[]) || []);
      setIncludeInRefill(include);
    }
  }

  // ── Refill plan actions ──────────────────────────────────────────────────────
  async function handlePlanMachine(
    machineName: string,
    status: "approved" | "rejected",
  ) {
    setPlanProcessing((prev) => new Set([...prev, machineName]));
    const supabase = getSupabase();
    const comment = planComments[machineName] ?? "";
    await supabase
      .from("refill_plan_output")
      .update({
        operator_status: status,
        reviewed_at: new Date().toISOString(),
        operator_comment: comment || null,
      })
      .eq("machine_name", machineName)
      .eq("operator_status", "pending");
    setPlanRows((prev) => prev.filter((r) => r.machine_name !== machineName));
    setPlanProcessing((prev) => {
      const s = new Set(prev);
      s.delete(machineName);
      return s;
    });
    setPlanExpanded((prev) => (prev === machineName ? null : prev));
  }

  async function handlePlanRejectLine(id: string) {
    const supabase = getSupabase();
    await supabase
      .from("refill_plan_output")
      .update({
        operator_status: "rejected",
        reviewed_at: new Date().toISOString(),
      })
      .eq("id", id);
    setPlanRows((prev) => prev.filter((r) => r.id !== id));
  }

  async function handlePlanApproveAll() {
    const machines = [...new Set(planRows.map((r) => r.machine_name))];
    for (const m of machines) {
      await handlePlanMachine(m, "approved");
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
      <div className="mb-8">
        <h1 className="text-2xl font-semibold text-gray-900">Refill data</h1>
        <p className="text-sm text-gray-500 mt-1">
          Pull latest sales, inventory, and machine status from Weimi API
        </p>
      </div>

      {/* ── Refill Plan Section ─────────────────────────────────────────────── */}
      {planRows.length > 0 && (
        <div className="mb-6">
          {/* Section header */}
          <div className="flex items-center justify-between mb-3">
            <button
              onClick={() => setPlanCollapsed((c) => !c)}
              className="flex items-center gap-2 text-left"
            >
              <h2 className="text-base font-semibold text-gray-900">
                📋 Refill Plan —{" "}
                {planDate
                  ? new Date(planDate + "T00:00:00").toLocaleDateString(
                      "en-AE",
                      { day: "numeric", month: "long", year: "numeric" },
                    )
                  : ""}
              </h2>
              <span className="text-xs text-gray-400">
                {planCollapsed ? "▼" : "▲"}
              </span>
            </button>
            {!planCollapsed && (
              <div className="flex items-center gap-3">
                <span className="text-xs text-gray-500">
                  {planGroups.length} machine
                  {planGroups.length !== 1 ? "s" : ""} ·{" "}
                  {planRows.reduce((s, r) => s + (r.quantity ?? 0), 0)} units
                </span>
                <button
                  onClick={handlePlanApproveAll}
                  className="px-3 py-1.5 rounded-lg bg-green-600 text-white text-xs font-medium hover:bg-green-700 transition-colors"
                >
                  Approve All Machines
                </button>
              </div>
            )}
          </div>

          {!planCollapsed && (
            <div className="space-y-3">
              {planGroups.map((group) => {
                const isExpanded = planExpanded === group.machine_name;
                const isProcessing = planProcessing.has(group.machine_name);
                return (
                  <div
                    key={group.machine_name}
                    className="bg-white border border-gray-200 rounded-lg overflow-hidden"
                  >
                    {/* Machine card header */}
                    <button
                      onClick={() =>
                        setPlanExpanded((prev) =>
                          prev === group.machine_name
                            ? null
                            : group.machine_name,
                        )
                      }
                      className="w-full flex items-center justify-between px-4 py-3 text-left hover:bg-gray-50 transition-colors"
                    >
                      <div className="flex items-center gap-3 min-w-0">
                        <span className="font-medium text-sm text-gray-900 truncate">
                          {group.machine_name}
                        </span>
                        <span className="text-xs text-gray-400 shrink-0">
                          {group.rows.length} lines · {group.total_units} units
                        </span>
                        <div className="flex gap-1.5 shrink-0">
                          {group.refill_count > 0 && (
                            <span className="text-[10px] px-1.5 py-0.5 rounded bg-green-100 text-green-800 font-medium">
                              {group.refill_count} Refill
                            </span>
                          )}
                          {group.add_count > 0 && (
                            <span className="text-[10px] px-1.5 py-0.5 rounded bg-blue-100 text-blue-800 font-medium">
                              {group.add_count} Add
                            </span>
                          )}
                          {group.remove_count > 0 && (
                            <span className="text-[10px] px-1.5 py-0.5 rounded bg-red-100 text-red-800 font-medium">
                              {group.remove_count} Remove
                            </span>
                          )}
                        </div>
                      </div>
                      <span className="text-xs text-gray-400 shrink-0 ml-2">
                        {isExpanded ? "▲" : "▼"}
                      </span>
                    </button>

                    {/* Expanded content */}
                    {isExpanded && (
                      <div className="border-t border-gray-100">
                        {/* Line table */}
                        <div className="overflow-x-auto">
                          <table className="w-full text-xs">
                            <thead>
                              <tr className="bg-gray-50 text-gray-500 uppercase tracking-wide text-[10px]">
                                <th className="px-3 py-2 text-left font-medium">
                                  Shelf
                                </th>
                                <th className="px-3 py-2 text-left font-medium">
                                  Pod Product
                                </th>
                                <th className="px-3 py-2 text-left font-medium">
                                  Boonz Product
                                </th>
                                <th className="px-3 py-2 text-left font-medium">
                                  Action
                                </th>
                                <th className="px-3 py-2 text-right font-medium">
                                  Qty
                                </th>
                                <th className="px-3 py-2 text-right font-medium">
                                  Stock
                                </th>
                                <th className="px-3 py-2 text-center font-medium">
                                  Tier
                                </th>
                                <th className="px-3 py-2 text-left font-medium">
                                  Comment
                                </th>
                                <th className="px-3 py-2" />
                              </tr>
                            </thead>
                            <tbody className="divide-y divide-gray-50">
                              {group.rows.map((row) => {
                                const actionClass =
                                  row.action === "Refill"
                                    ? "bg-green-100 text-green-800"
                                    : row.action === "Add New"
                                      ? "bg-blue-100 text-blue-800"
                                      : row.action === "Remove"
                                        ? "bg-red-100 text-red-800"
                                        : "bg-gray-100 text-gray-700";
                                const tierEmoji =
                                  row.tier === "HERO"
                                    ? "🔥"
                                    : row.tier === "GOOD"
                                      ? "✅"
                                      : row.tier === "CORE"
                                        ? "📦"
                                        : row.tier === "DRAG"
                                          ? "🔻"
                                          : "—";
                                const tierClass =
                                  row.tier === "HERO"
                                    ? "bg-orange-100 text-orange-800"
                                    : row.tier === "GOOD"
                                      ? "bg-emerald-100 text-emerald-800"
                                      : row.tier === "CORE"
                                        ? "bg-gray-100 text-gray-800"
                                        : row.tier === "DRAG"
                                          ? "bg-red-100 text-red-800"
                                          : "";
                                const hasWarning = row.comment?.includes("⚠️");
                                return (
                                  <tr
                                    key={row.id}
                                    className={
                                      hasWarning
                                        ? "bg-yellow-50 border-l-4 border-yellow-400"
                                        : "hover:bg-gray-50"
                                    }
                                  >
                                    <td className="px-3 py-2 font-mono text-gray-500">
                                      {row.shelf_code}
                                    </td>
                                    <td className="px-3 py-2 text-gray-700 max-w-[140px] truncate">
                                      {row.pod_product_name}
                                    </td>
                                    <td className="px-3 py-2 text-gray-500 max-w-[140px] truncate">
                                      {row.boonz_product_name}
                                    </td>
                                    <td className="px-3 py-2">
                                      <span
                                        className={`px-1.5 py-0.5 rounded text-[10px] font-medium ${actionClass}`}
                                      >
                                        {row.action}
                                      </span>
                                    </td>
                                    <td className="px-3 py-2 text-right font-medium text-gray-900">
                                      {row.quantity}
                                    </td>
                                    <td className="px-3 py-2 text-right text-gray-500">
                                      {row.current_stock}/{row.max_stock}
                                    </td>
                                    <td className="px-3 py-2 text-center">
                                      {row.tier ? (
                                        <span
                                          className={`px-1 py-0.5 rounded text-[10px] font-medium ${tierClass}`}
                                        >
                                          {tierEmoji} {row.tier}
                                        </span>
                                      ) : (
                                        <span className="text-gray-300">—</span>
                                      )}
                                    </td>
                                    <td className="px-3 py-2 text-gray-500 max-w-[160px] truncate">
                                      {row.comment ?? ""}
                                    </td>
                                    <td className="px-2 py-2 text-right">
                                      <button
                                        onClick={() =>
                                          handlePlanRejectLine(row.id)
                                        }
                                        title="Reject this line"
                                        className="text-gray-300 hover:text-red-500 transition-colors text-xs"
                                      >
                                        ❌
                                      </button>
                                    </td>
                                  </tr>
                                );
                              })}
                            </tbody>
                          </table>
                        </div>

                        {/* Machine approve/reject controls */}
                        <div className="flex items-center gap-3 px-4 py-3 bg-gray-50 border-t border-gray-100">
                          <input
                            type="text"
                            value={planComments[group.machine_name] ?? ""}
                            onChange={(e) =>
                              setPlanComments((prev) => ({
                                ...prev,
                                [group.machine_name]: e.target.value,
                              }))
                            }
                            placeholder="Add comment (optional)…"
                            className="flex-1 min-w-0 text-xs rounded border border-gray-300 px-2 py-1.5 placeholder:text-gray-400"
                          />
                          <button
                            onClick={() =>
                              handlePlanMachine(group.machine_name, "approved")
                            }
                            disabled={isProcessing}
                            className="shrink-0 px-3 py-1.5 rounded bg-green-600 text-white text-xs font-medium hover:bg-green-700 disabled:opacity-50 transition-colors"
                          >
                            {isProcessing ? "…" : "✅ Approve All"}
                          </button>
                          <button
                            onClick={() =>
                              handlePlanMachine(group.machine_name, "rejected")
                            }
                            disabled={isProcessing}
                            className="shrink-0 px-3 py-1.5 rounded bg-red-600 text-white text-xs font-medium hover:bg-red-700 disabled:opacity-50 transition-colors"
                          >
                            {isProcessing ? "…" : "❌ Reject All"}
                          </button>
                        </div>
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}

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
                {tierCounts.critical != null && (
                  <span className="px-2 py-0.5 rounded-full bg-red-100 text-red-700 font-medium">
                    {tierCounts.critical} critical
                  </span>
                )}
                {tierCounts.warning != null && (
                  <span className="px-2 py-0.5 rounded-full bg-amber-100 text-amber-700 font-medium">
                    {tierCounts.warning} warning
                  </span>
                )}
                {tierCounts.healthy != null && (
                  <span className="px-2 py-0.5 rounded-full bg-green-100 text-green-700 font-medium">
                    {tierCounts.healthy} healthy
                  </span>
                )}
                {tierCounts.excluded != null && (
                  <span className="px-2 py-0.5 rounded-full bg-gray-100 text-gray-400 font-medium">
                    {tierCounts.excluded} excluded
                  </span>
                )}
              </div>
            </div>
            <div className="flex items-center gap-1 text-xs text-gray-500">
              <span>Sort:</span>
              {(["priority", "stock", "fill", "expiry"] as const).map((opt) => (
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
                    : opt === "stock"
                      ? "Stock"
                      : opt === "fill"
                        ? "Fill %"
                        : "Expiry"}
                </button>
              ))}
            </div>
          </div>
          <p className="text-xs text-gray-400 mb-3">
            Click a machine to see slot inventory
          </p>
          <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-2.5">
            {sortedMachines.map((m) => {
              const tc = tierColors[m.health_tier] ?? tierColors.excluded;

              return (
                <button
                  key={m.machine_id}
                  type="button"
                  onClick={() => setSelectedMachine(m.machine_name)}
                  className={`text-left border rounded-lg px-3 py-2.5 transition-all hover:ring-2 hover:ring-blue-300 focus:outline-none focus:ring-2 focus:ring-blue-400 ${tc.card}`}
                >
                  {/* Health label badge */}
                  {m.machine_health_label && (
                    <div
                      className={`text-[9px] font-semibold px-1.5 py-0.5 rounded mb-1 inline-block leading-tight ${healthLabelBadgeClass(m.machine_health_label)}`}
                    >
                      {m.machine_health_label}
                    </div>
                  )}
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
                  {/* Quick stats: velocity + dead/hero */}
                  <div className="mt-1.5 text-[10px] text-gray-500 leading-tight flex flex-wrap gap-x-1.5">
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
                          m.health_tier === "critical"
                            ? "text-red-600 font-medium"
                            : ""
                        }
                      >
                        {m.slots_at_zero} empty
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
              );
            })}
          </div>
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
                  <th className="text-left py-2.5 pr-3 font-medium">Machine</th>
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
                  const margin = Number(s.total_revenue) - Number(s.total_cost);
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

      {/* Inventory summary table */}
      {summaries.length > 0 && (
        <div className="bg-white border border-gray-200 rounded-lg p-5">
          <h2 className="text-base font-medium text-gray-900 mb-4">
            Inventory summary
          </h2>
          <div className="overflow-x-auto -mx-5 px-5">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-gray-200 text-gray-500 text-xs">
                  <th className="text-left py-2.5 pr-3 font-medium">Machine</th>
                  <th className="text-right py-2.5 px-2 font-medium">Slots</th>
                  <th className="text-right py-2.5 px-2 font-medium">
                    Capacity
                  </th>
                  <th className="text-right py-2.5 px-2 font-medium">
                    Current
                  </th>
                  <th className="text-right py-2.5 px-2 font-medium">
                    Shortage
                  </th>
                  <th className="text-right py-2.5 px-2 font-medium">Empty</th>
                </tr>
              </thead>
              <tbody>
                {[...summaries]
                  .sort((a, b) => (b.shortage_pct || 0) - (a.shortage_pct || 0))
                  .map((s) => (
                    <tr
                      key={s.machine_name}
                      className="border-b border-gray-50 hover:bg-gray-50/50"
                    >
                      <td className="py-2 pr-3 font-medium text-gray-900">
                        {s.machine_name}
                      </td>
                      <td className="py-2 px-2 text-right text-gray-600 tabular-nums">
                        {s.total_slots}
                      </td>
                      <td className="py-2 px-2 text-right text-gray-600 tabular-nums">
                        {s.total_capacity}
                      </td>
                      <td className="py-2 px-2 text-right text-gray-600 tabular-nums">
                        {s.total_current_stock}
                      </td>
                      <td className="py-2 px-2 text-right">
                        <span
                          className={`inline-block min-w-[3rem] text-center px-1.5 py-0.5 rounded text-xs font-medium ${
                            (s.shortage_pct || 0) > 50
                              ? "bg-red-100 text-red-700"
                              : (s.shortage_pct || 0) > 25
                                ? "bg-amber-100 text-amber-700"
                                : "bg-green-100 text-green-700"
                          }`}
                        >
                          {s.shortage_pct ?? 0}%
                        </span>
                      </td>
                      <td className="py-2 px-2 text-right text-gray-600 tabular-nums">
                        {s.slots_at_zero}
                      </td>
                    </tr>
                  ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* Empty state */}
      {devices.length === 0 &&
        summaries.length === 0 &&
        machineHealth.length === 0 &&
        !refreshing && (
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

                  {/* Intelligence summary bar */}
                  {selectedHealth && (
                    <div className="mb-3 bg-gray-50 border border-gray-200 rounded-lg px-3 py-2 text-xs text-gray-600 flex flex-wrap items-center gap-x-3 gap-y-1">
                      {selectedHealth.machine_health_label && (
                        <span
                          className={`font-semibold px-1.5 py-0.5 rounded ${healthLabelBadgeClass(selectedHealth.machine_health_label)}`}
                        >
                          {selectedHealth.machine_health_label}
                        </span>
                      )}
                      {selectedHealth.machine_strategy && (
                        <span className="text-gray-500">
                          {selectedHealth.machine_strategy}
                        </span>
                      )}
                      <span className="text-gray-400">·</span>
                      {selectedHealth.dead_stock_count > 0 && (
                        <span className="text-red-600 font-medium">
                          {selectedHealth.dead_stock_count}/
                          {selectedHealth.total_slots} dead stock
                        </span>
                      )}
                      {selectedHealth.local_hero_count > 0 && (
                        <span className="text-green-600 font-medium">
                          {selectedHealth.local_hero_count} hero
                          {selectedHealth.local_hero_count !== 1 ? "s" : ""}
                        </span>
                      )}
                      {selectedHealth.daily_velocity > 0 && (
                        <span>
                          ↗ {selectedHealth.daily_velocity.toFixed(1)}/day
                        </span>
                      )}
                    </div>
                  )}

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
                            Exp.
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
                                {s.slot}
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
                                ) : s.global_product_status?.includes("📦") ? (
                                  <span
                                    title="Core Range — standard performer globally"
                                    className="cursor-help"
                                  >
                                    📦
                                  </span>
                                ) : s.global_product_status?.includes("🔻") ? (
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
                                ) : s.local_performance_role?.includes("💀") ? (
                                  <span
                                    title="Dead Stock — zero or near-zero sales in this machine"
                                    className="cursor-help"
                                  >
                                    💀
                                  </span>
                                ) : s.local_performance_role?.includes("✅") ? (
                                  <span
                                    title="Standard — normal performer in this machine"
                                    className="cursor-help"
                                  >
                                    ✅
                                  </span>
                                ) : s.local_performance_role?.includes("📊") ? (
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
                              {/* Exp. */}
                              <td className="py-1.5 pl-2 text-right tabular-nums text-xs">
                                {s.expiry_days != null ? (
                                  <span
                                    className={expiryDayClass(s.expiry_days)}
                                  >
                                    {s.expiry_days}d
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
                            ].slot_reviews.filter((r) => r.action === "REPLACE")
                              .length
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
                                <span className="text-gray-400 text-xs">→</span>
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
  );
}
