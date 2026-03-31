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

type AisleRow = {
  slot: string;
  product: string;
  current: number;
  max: number;
  layer: string;
  fillPct: number;
};

type DoorLayer = {
  layer: string;
  aisles?: Array<{
    showName: string;
    goodsName: string;
    currStock: number;
    maxStock: number;
  }>;
};

type DoorCabinet = { layers?: DoorLayer[] };

type ProgressMsg = { step: string; detail: string; elapsed: string };

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
};

type ExpiryDetail = {
  boonz_product_name: string;
  boonz_product_id: string;
  total_qty: number;
  earliest_expiry: string;
  days_until_expiry: number;
  expired_qty: number;
  expiring_7d_qty: number;
  expiring_30d_qty: number;
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
  const [machineAisles, setMachineAisles] = useState<AisleRow[]>([]);
  const [expiryData, setExpiryData] = useState<ExpiryDetail[]>([]);
  const [loadingAisles, setLoadingAisles] = useState(false);
  const [includeInRefill, setIncludeInRefill] = useState(true);
  const [modalSort, setModalSort] = useState<
    "slot" | "stock" | "fill" | "expiry"
  >("slot");

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

  // ── Load aisle + expiry detail when a machine card is clicked ───────────────
  const loadAisles = useCallback(
    async (machineName: string) => {
      setLoadingAisles(true);
      setMachineAisles([]);
      setExpiryData([]);
      const supabase = getSupabase();
      const today = new Date().toISOString().split("T")[0];

      // Fetch aisles and expiry in parallel
      const [todayResult, expiryResult] = await Promise.all([
        supabase
          .from("weimi_device_status")
          .select("door_statuses")
          .eq("device_name", machineName)
          .eq("snapshot_date", today)
          .maybeSingle(),
        supabase
          .rpc("get_machine_expiry_detail", { p_machine_name: machineName })
          .limit(10000),
      ]);

      let row: { door_statuses: unknown } | null = todayResult.data;

      // Fall back to latest snapshot if today's not available
      if (!row) {
        const { data: latestData } = await supabase
          .from("weimi_device_status")
          .select("door_statuses")
          .eq("device_name", machineName)
          .order("snapshot_date", { ascending: false })
          .limit(1)
          .maybeSingle();
        row = latestData;
      }

      if (row?.door_statuses) {
        const aisles: AisleRow[] = [];
        const cabinets = row.door_statuses as DoorCabinet[];
        for (const cab of cabinets) {
          for (const layer of cab.layers ?? []) {
            for (const aisle of layer.aisles ?? []) {
              aisles.push({
                slot: aisle.showName,
                product: aisle.goodsName,
                current: aisle.currStock,
                max: aisle.maxStock,
                layer: layer.layer,
                fillPct:
                  aisle.maxStock > 0
                    ? Math.round((aisle.currStock / aisle.maxStock) * 100)
                    : 0,
              });
            }
          }
        }
        setMachineAisles(aisles);
      }

      if (expiryResult.data) {
        setExpiryData(expiryResult.data as ExpiryDetail[]);
      }

      setLoadingAisles(false);
    },
    [getSupabase],
  );

  useEffect(() => {
    setModalSort("slot");
    if (!selectedMachine) {
      setMachineAisles([]);
      setExpiryData([]);
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

  // Build expiry lookup map for modal table
  const expiryMap = useMemo(() => {
    const map = new Map<string, ExpiryDetail>();
    for (const ex of expiryData) {
      map.set(ex.boonz_product_name.toLowerCase(), ex);
    }
    return map;
  }, [expiryData]);

  const findExpiry = useCallback(
    (productName: string): ExpiryDetail | null => {
      if (!productName) return null;
      const lower = productName.toLowerCase();
      if (expiryMap.has(lower)) return expiryMap.get(lower)!;
      for (const [key, val] of expiryMap) {
        if (key.includes(lower) || lower.includes(key)) return val;
      }
      return null;
    },
    [expiryMap],
  );

  const sortedAisles = useMemo(() => {
    const sorted = [...machineAisles];
    switch (modalSort) {
      case "stock":
        sorted.sort((a, b) => a.current - b.current);
        break;
      case "fill":
        sorted.sort((a, b) => a.fillPct - b.fillPct);
        break;
      case "expiry":
        sorted.sort((a, b) => {
          const aExp = findExpiry(a.product)?.days_until_expiry ?? 9999;
          const bExp = findExpiry(b.product)?.days_until_expiry ?? 9999;
          return aExp - bExp;
        });
        break;
      default:
        break;
    }
    return sorted;
  }, [machineAisles, modalSort, findExpiry]);

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

  const selectedHealth = machineHealth.find(
    (m) => m.machine_name === selectedMachine,
  );
  const modalTotalCapacity = machineAisles.reduce((s, a) => s + a.max, 0);
  const modalTotalCurrent = machineAisles.reduce((s, a) => s + a.current, 0);

  // Expiry summary for modal header
  const modalExpiredCount = expiryData.reduce(
    (s, e) => s + (e.expired_qty ?? 0),
    0,
  );
  const modalExpiring7dCount = expiryData.reduce(
    (s, e) => s + (e.expiring_7d_qty ?? 0),
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
                  <div className="mb-1">
                    <span className="text-xs font-medium text-gray-700 truncate leading-tight block">
                      {m.machine_name}
                    </span>
                  </div>
                  <div className="text-sm font-semibold text-gray-900">
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
                  <div className="mt-1.5 text-[10px] text-gray-500 leading-tight">
                    {m.daily_velocity > 0 && (
                      <span>↗ {m.daily_velocity.toFixed(1)}/day · </span>
                    )}
                    {m.slots_at_zero > 0 ? (
                      <span
                        className={
                          m.health_tier === "critical"
                            ? "text-red-600 font-medium"
                            : ""
                        }
                      >
                        {m.slots_at_zero} empty
                      </span>
                    ) : (
                      m.daily_velocity === 0 && (
                        <span className="text-gray-400">{m.fill_pct}%</span>
                      )
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
          <div className="relative z-10 w-full max-w-3xl max-h-[85vh] flex flex-col bg-white rounded-xl shadow-2xl overflow-hidden">
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
                  {modalExpiredCount > 0 && (
                    <span className="text-xs px-2 py-0.5 bg-red-100 text-red-700 rounded">
                      ⚠ {modalExpiredCount} expired
                    </span>
                  )}
                  {modalExpiring7dCount > 0 && (
                    <span className="text-xs px-2 py-0.5 bg-amber-100 text-amber-700 rounded">
                      ⏰ {modalExpiring7dCount} expiring 7d
                    </span>
                  )}
                </div>
                {/* Include in refill toggle */}
                {selectedHealth !== undefined && (
                  <div className="flex items-center gap-2 mt-3">
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
                  </div>
                )}
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
              ) : machineAisles.length === 0 ? (
                <div className="text-center py-12 text-gray-400 text-sm">
                  No slot data available for today&apos;s snapshot
                </div>
              ) : (
                <>
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
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-gray-200 text-gray-500 text-xs">
                        <th className="text-left py-2 pr-3 font-medium">
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
                        <th className="text-right py-2 px-2 font-medium">
                          Exp. days
                        </th>
                        <th className="text-right py-2 pl-2 font-medium">
                          Exp. qty
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      {sortedAisles.map((a, i) => {
                        const ex = findExpiry(a.product);
                        return (
                          <tr
                            key={`${a.slot}-${i}`}
                            className="border-b border-gray-50"
                          >
                            <td className="py-1.5 pr-3 font-mono text-xs text-gray-600">
                              {a.slot}
                            </td>
                            <td className="py-1.5 px-2 text-gray-800 text-xs">
                              {a.product || "—"}
                            </td>
                            <td className="py-1.5 px-2 text-right tabular-nums text-xs text-gray-600">
                              {a.current} / {a.max}
                            </td>
                            <td className="py-1.5 px-2 text-right">
                              <span
                                className={`inline-block min-w-[3rem] text-center px-1.5 py-0.5 rounded text-xs font-medium ${fillBg(a.fillPct)}`}
                              >
                                {a.fillPct}%
                              </span>
                            </td>
                            <td className="py-1.5 px-2 text-right tabular-nums text-xs">
                              {ex != null ? (
                                <span
                                  className={expiryDayClass(
                                    ex.days_until_expiry,
                                  )}
                                >
                                  {ex.days_until_expiry < 0
                                    ? `${ex.days_until_expiry}d`
                                    : `${ex.days_until_expiry}d`}
                                </span>
                              ) : (
                                <span className="text-gray-300">—</span>
                              )}
                            </td>
                            <td className="py-1.5 pl-2 text-right tabular-nums text-xs">
                              {ex && ex.expired_qty > 0 ? (
                                <span className="text-red-600 font-medium">
                                  {ex.expired_qty} exp
                                </span>
                              ) : ex && ex.expiring_7d_qty > 0 ? (
                                <span className="text-amber-600">
                                  {ex.expiring_7d_qty} exp
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
                </>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
