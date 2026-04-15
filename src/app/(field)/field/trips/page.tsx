"use client";

import { useEffect, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import { FieldHeader } from "../../components/field-header";

type StopStatus =
  | "done"
  | "in_progress"
  | "ready_to_dispatch"
  | "ready_for_pickup"
  | "packing";

interface TripStop {
  machine_id: string;
  official_name: string;
  pod_location: string | null;
  pod_address: string | null;
  sku_count: number;
  packed_count: number;
  picked_up_count: number;
  dispatched_count: number;
  status: StopStatus;
}

function deriveStatus(
  total: number,
  packed: number,
  pickedUp: number,
  dispatched: number,
): StopStatus {
  if (dispatched === total) return "done";
  if (dispatched > 0) return "in_progress";
  if (pickedUp === total) return "ready_to_dispatch";
  if (packed === total) return "ready_for_pickup";
  return "packing";
}

const statusConfig: Record<StopStatus, { label: string; className: string }> = {
  done: {
    label: "Done ✓",
    className:
      "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200",
  },
  in_progress: {
    label: "In progress",
    className: "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200",
  },
  ready_to_dispatch: {
    label: "Ready to dispatch",
    className:
      "bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-200",
  },
  ready_for_pickup: {
    label: "Ready for pickup",
    className:
      "bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-200",
  },
  packing: {
    label: "Packing…",
    className:
      "bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400",
  },
};

export default function TripsPage() {
  const [stops, setStops] = useState<TripStop[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchStops = useCallback(async () => {
    const supabase = createClient();
    const today = getDubaiDate();

    const { data: lines } = await supabase
      .from("refill_dispatching")
      .select(
        "dispatch_id, machine_id, packed, picked_up, dispatched, machines!inner(official_name, pod_location, pod_address)",
      )
      .eq("dispatch_date", today)
      .eq("include", true);

    if (!lines || lines.length === 0) {
      setStops([]);
      setLoading(false);
      return;
    }

    const grouped = new Map<string, Omit<TripStop, "status">>();

    for (const line of lines) {
      const m = line.machines as unknown as {
        official_name: string;
        pod_location: string | null;
        pod_address: string | null;
      };
      const existing = grouped.get(line.machine_id);
      if (existing) {
        existing.sku_count += 1;
        if (line.packed) existing.packed_count += 1;
        if (line.picked_up) existing.picked_up_count += 1;
        if (line.dispatched) existing.dispatched_count += 1;
      } else {
        grouped.set(line.machine_id, {
          machine_id: line.machine_id,
          official_name: m.official_name,
          pod_location: m.pod_location,
          pod_address: m.pod_address,
          sku_count: 1,
          packed_count: line.packed ? 1 : 0,
          picked_up_count: line.picked_up ? 1 : 0,
          dispatched_count: line.dispatched ? 1 : 0,
        });
      }
    }

    const result: TripStop[] = Array.from(grouped.values())
      .map((s) => ({
        ...s,
        status: deriveStatus(
          s.sku_count,
          s.packed_count,
          s.picked_up_count,
          s.dispatched_count,
        ),
      }))
      .sort((a, b) => a.official_name.localeCompare(b.official_name));

    setStops(result);
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchStops();
  }, [fetchStops]);

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") fetchStops();
    }
    document.addEventListener("visibilitychange", handleVisibility);
    window.addEventListener("focus", fetchStops);
    return () => {
      document.removeEventListener("visibilitychange", handleVisibility);
      window.removeEventListener("focus", fetchStops);
    };
  }, [fetchStops]);

  if (loading) {
    return (
      <>
        <FieldHeader title="Today's Trips" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading trips…</p>
        </div>
      </>
    );
  }

  if (stops.length === 0) {
    return (
      <>
        <FieldHeader title="Today's Trips" />
        <div className="flex flex-col items-center justify-center p-8 text-center">
          <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
            No stops for today
          </p>
        </div>
      </>
    );
  }

  return (
    <div className="px-4 py-4">
      <FieldHeader title="Today's Trips" />
      <ul className="space-y-2">
        {stops.map((stop, idx) => {
          const cfg = statusConfig[stop.status];
          return (
            <li key={stop.machine_id}>
              <div className="flex items-center gap-3 rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
                <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-neutral-100 text-sm font-semibold dark:bg-neutral-800">
                  {idx + 1}
                </span>
                <div className="flex-1 min-w-0">
                  <p className="text-base font-semibold truncate">
                    {stop.official_name}
                  </p>
                  {(stop.pod_location || stop.pod_address) && (
                    <p className="text-sm text-neutral-500 truncate">
                      {[stop.pod_location, stop.pod_address]
                        .filter(Boolean)
                        .join(" · ")}
                    </p>
                  )}
                </div>
                <span className="shrink-0 rounded-full bg-neutral-100 px-2.5 py-0.5 text-xs font-medium dark:bg-neutral-800">
                  {stop.sku_count} lines
                </span>
                <span
                  className={`shrink-0 rounded-full px-2.5 py-0.5 text-xs font-medium ${cfg.className}`}
                >
                  {cfg.label}
                </span>
              </div>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
