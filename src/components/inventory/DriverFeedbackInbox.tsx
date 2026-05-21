"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface FeedbackRow {
  feedback_id: string;
  machine_id: string;
  machine_official_name: string | null;
  slot_code: string | null;
  boonz_product_id: string | null;
  product_name: string | null;
  direction: "more" | "fewer" | "replace" | null;
  signal_source: "observation" | "customer_request" | "sale_anomaly";
  confidence: number;
  note_text: string;
  created_by: string | null;
  created_at: string;
}

type DirectionFilter = "all" | "more" | "fewer" | "replace";
type SourceFilter = "all" | "observation" | "customer_request" | "sale_anomaly";

/**
 * PRD-009 acceptance criterion #4: admin "feedback inbox" so CS can audit
 * driver signal. Reads `v_driver_feedback_active` (active, non-superseded
 * rows). Filters by direction + signal_source so CS can quickly see
 * "customer_request more" rows separately from observational chatter.
 *
 * Read-only. Supersedence is via a deferred RPC (see migration footer).
 */
export default function DriverFeedbackInbox() {
  const [rows, setRows] = useState<FeedbackRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [directionFilter, setDirectionFilter] =
    useState<DirectionFilter>("all");
  const [sourceFilter, setSourceFilter] = useState<SourceFilter>("all");

  const fetchRows = useCallback(async () => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const { data, error: fetchError } = await supabase
      .from("v_driver_feedback_active")
      .select("*")
      .limit(10000)
      .order("created_at", { ascending: false });

    if (fetchError) {
      setError(fetchError.message);
      setRows([]);
    } else {
      setRows((data ?? []) as FeedbackRow[]);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial fetch; same pattern as sibling panels in src/components/inventory/
    void fetchRows();
  }, [fetchRows]);

  const visible = useMemo(() => {
    return rows.filter((r) => {
      if (directionFilter !== "all" && r.direction !== directionFilter)
        return false;
      if (sourceFilter !== "all" && r.signal_source !== sourceFilter)
        return false;
      return true;
    });
  }, [rows, directionFilter, sourceFilter]);

  if (loading) {
    return (
      <div className="rounded-lg border border-neutral-300 bg-neutral-50 p-4 text-sm dark:border-neutral-700 dark:bg-neutral-900">
        Loading driver feedback…
      </div>
    );
  }

  if (error) {
    return (
      <div className="rounded-lg border border-rose-300 bg-rose-50 p-4 text-sm dark:border-rose-800 dark:bg-rose-950/20">
        <div className="font-semibold text-rose-800 dark:text-rose-200">
          Could not load driver feedback
        </div>
        <div className="mt-1 text-xs text-rose-700 dark:text-rose-300">
          {error}
        </div>
        <div className="mt-2 text-xs text-neutral-500">
          The view <code>v_driver_feedback_active</code> ships with PRD-009
          migration <code>20260521232618_*</code>. If this is a fresh
          environment, that migration may not be applied yet.
        </div>
      </div>
    );
  }

  if (rows.length === 0) {
    return (
      <div className="rounded-lg border border-neutral-300 bg-neutral-50 p-4 text-sm dark:border-neutral-700 dark:bg-neutral-900">
        No active driver feedback yet. As soon as the field PWA capture surface
        ships, notes will arrive here automatically.
      </div>
    );
  }

  return (
    <div className="rounded-lg border border-sky-300 bg-sky-50/40 dark:border-sky-800 dark:bg-sky-950/10">
      <div className="flex flex-wrap items-center gap-3 p-3">
        <span className="rounded-full bg-sky-600 px-2 py-0.5 text-xs font-semibold text-white">
          {visible.length}
        </span>
        <span className="text-sm font-semibold">Driver feedback (active)</span>

        <select
          value={directionFilter}
          onChange={(e) =>
            setDirectionFilter(e.target.value as DirectionFilter)
          }
          className="ml-auto rounded border border-sky-300 bg-white px-2 py-1 text-xs dark:border-sky-700 dark:bg-neutral-900"
        >
          <option value="all">All directions</option>
          <option value="more">more</option>
          <option value="fewer">fewer</option>
          <option value="replace">replace</option>
        </select>

        <select
          value={sourceFilter}
          onChange={(e) => setSourceFilter(e.target.value as SourceFilter)}
          className="rounded border border-sky-300 bg-white px-2 py-1 text-xs dark:border-sky-700 dark:bg-neutral-900"
        >
          <option value="all">All sources</option>
          <option value="customer_request">customer_request (3×)</option>
          <option value="sale_anomaly">sale_anomaly (2×)</option>
          <option value="observation">observation (1×)</option>
        </select>
      </div>

      <ul className="divide-y divide-sky-200 px-3 pb-3 dark:divide-sky-800">
        {visible.map((r) => {
          const sourceBadge =
            r.signal_source === "customer_request"
              ? "bg-rose-200 text-rose-900 dark:bg-rose-900 dark:text-rose-100"
              : r.signal_source === "sale_anomaly"
                ? "bg-amber-200 text-amber-900 dark:bg-amber-900 dark:text-amber-100"
                : "bg-neutral-200 text-neutral-700 dark:bg-neutral-800 dark:text-neutral-200";

          return (
            <li key={r.feedback_id} className="py-2 text-sm">
              <div className="flex items-center gap-2">
                <span className="font-mono text-xs text-neutral-500">
                  {r.machine_official_name ?? r.machine_id.slice(0, 8)}
                </span>
                {r.slot_code && (
                  <span className="rounded bg-neutral-200 px-1.5 py-0.5 font-mono text-[10px] font-semibold text-neutral-700 dark:bg-neutral-800 dark:text-neutral-200">
                    {r.slot_code}
                  </span>
                )}
                {r.product_name && (
                  <span className="text-xs font-medium">{r.product_name}</span>
                )}
                {r.direction && (
                  <span className="rounded bg-sky-200 px-1.5 py-0.5 text-[10px] font-semibold text-sky-900 dark:bg-sky-800 dark:text-sky-100">
                    {r.direction}
                  </span>
                )}
                <span
                  className={`rounded px-1.5 py-0.5 text-[10px] font-semibold ${sourceBadge}`}
                >
                  {r.signal_source}
                </span>
                <span className="text-[10px] text-neutral-500">
                  conf {r.confidence}/3
                </span>
                <span className="ml-auto text-[10px] text-neutral-500">
                  {new Date(r.created_at).toLocaleString()}
                </span>
              </div>
              <div className="mt-1 text-xs text-neutral-700 dark:text-neutral-300">
                {r.note_text}
              </div>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
