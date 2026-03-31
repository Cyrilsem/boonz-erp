"use client";

import { useState, useEffect, useCallback } from "react";
import { createBrowserClient } from "@supabase/ssr";

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

export default function RefillPage() {
  const [refreshing, setRefreshing] = useState(false);
  const [result, setResult] = useState<RefreshResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [lookbackDays, setLookbackDays] = useState(90);
  const [devices, setDevices] = useState<DeviceRow[]>([]);
  const [summaries, setSummaries] = useState<SummaryRow[]>([]);
  const [lastRefresh, setLastRefresh] = useState<string | null>(null);
  const [salesCount, setSalesCount] = useState<number | null>(null);

  const getSupabase = useCallback(() => {
    return createBrowserClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    );
  }, []);

  const loadData = useCallback(async () => {
    const supabase = getSupabase();

    // Device status — latest snapshot
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

    if (summaryData && summaryData.length > 0) {
      setSummaries(summaryData as SummaryRow[]);
    }

    // Sales count
    const { count } = await supabase
      .from("sales_history")
      .select("*", { count: "exact", head: true });

    setSalesCount(count);
  }, [getSupabase]);

  useEffect(() => {
    loadData();
  }, [loadData]);

  async function handleRefresh() {
    setRefreshing(true);
    setError(null);
    setResult(null);

    try {
      const supabase = getSupabase();
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session) {
        setError("Not authenticated. Please log in again.");
        return;
      }

      const resp = await fetch(
        `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/refresh-stage1`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${session.access_token}`,
            apikey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            lookback_days: lookbackDays,
            skip_aisle: true,
          }),
        },
      );

      const data = await resp.json();

      if (!resp.ok || data.status === "error") {
        setError(data.error || `HTTP ${resp.status}`);
      } else {
        setResult(data);
        await loadData();
      }
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : "Unknown error";
      setError(message);
    } finally {
      setRefreshing(false);
    }
  }

  const onlineDevices = devices.filter((d) => d.is_online);
  const offlineDevices = devices.filter((d) => !d.is_online);

  return (
    <div className="max-w-6xl mx-auto px-4 py-8 sm:px-6">
      {/* Header */}
      <div className="mb-8">
        <h1 className="text-2xl font-semibold text-gray-900">Refill data</h1>
        <p className="text-sm text-gray-500 mt-1">
          Pull latest sales, inventory, and machine status from Weimi API
        </p>
      </div>

      {/* Refresh controls */}
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

        {/* Success result */}
        {result && (
          <div className="mt-4 bg-green-50 border border-green-200 rounded-lg p-4">
            <div className="flex items-center gap-2 mb-3">
              <span className="w-2 h-2 rounded-full bg-green-500" />
              <span className="text-green-700 font-medium text-sm">
                Refresh complete
              </span>
              <span className="text-xs text-green-500">
                {result.duration_seconds}s
              </span>
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
                  {result.machines_online}/{result.machines_total} online
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
          </div>
        )}

        {/* Error result */}
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

      {/* Machine status grid */}
      {devices.length > 0 && (
        <div className="bg-white border border-gray-200 rounded-lg p-5 mb-6">
          <div className="flex items-center justify-between mb-4">
            <h2 className="text-base font-medium text-gray-900">
              Machine status
            </h2>
            <span className="text-xs text-gray-400">
              {onlineDevices.length} online, {offlineDevices.length} offline
            </span>
          </div>
          <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-2.5">
            {devices
              .sort((a, b) => {
                if (a.is_online !== b.is_online) return a.is_online ? -1 : 1;
                return a.device_name.localeCompare(b.device_name);
              })
              .map((m) => (
                <div
                  key={m.device_name}
                  className={`border rounded-lg px-3 py-2.5 ${
                    m.is_online
                      ? "border-green-200 bg-green-50/50"
                      : "border-gray-100 bg-gray-50/50 opacity-60"
                  }`}
                >
                  <div className="flex items-center justify-between gap-1">
                    <span className="text-xs font-medium text-gray-700 truncate">
                      {m.device_name}
                    </span>
                    <span
                      className={`w-1.5 h-1.5 rounded-full shrink-0 ${
                        m.is_online ? "bg-green-500" : "bg-gray-300"
                      }`}
                    />
                  </div>
                  <div className="text-lg font-semibold text-gray-900 mt-0.5">
                    {m.total_curr_stock}
                    <span className="text-[11px] text-gray-400 font-normal ml-0.5">
                      units
                    </span>
                  </div>
                </div>
              ))}
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
                  <th className="text-center py-2.5 px-2 font-medium">
                    Status
                  </th>
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
                {summaries
                  .sort((a, b) => (b.shortage_pct || 0) - (a.shortage_pct || 0))
                  .map((s) => (
                    <tr
                      key={s.machine_name}
                      className="border-b border-gray-50 hover:bg-gray-50/50"
                    >
                      <td className="py-2 pr-3 font-medium text-gray-900">
                        {s.machine_name}
                      </td>
                      <td className="py-2 px-2 text-center">
                        <span
                          className={`inline-block w-1.5 h-1.5 rounded-full ${
                            s.is_online ? "bg-green-500" : "bg-gray-300"
                          }`}
                        />
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
      {devices.length === 0 && summaries.length === 0 && !refreshing && (
        <div className="bg-white border border-gray-200 rounded-lg p-12 text-center">
          <div className="text-gray-400 text-sm mb-2">No data yet</div>
          <p className="text-gray-500 text-sm">
            Click &quot;Refresh data&quot; to pull the latest from Weimi API
          </p>
        </div>
      )}
    </div>
  );
}
