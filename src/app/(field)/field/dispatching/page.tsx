"use client";

import { useEffect, useState, useCallback } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import { FieldHeader } from "../../components/field-header";

interface DispatchMachine {
  machine_id: string;
  official_name: string;
  pod_location: string | null;
  total: number;
  dispatched_count: number;
  all_dispatched: boolean;
}

export default function DispatchingPage() {
  const [machines, setMachines] = useState<DispatchMachine[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchMachines = useCallback(async () => {
    const supabase = createClient();
    const today = getDubaiDate();

    const { data: lines } = await supabase
      .from("refill_dispatching")
      .select(
        "dispatch_id, machine_id, picked_up, dispatched, machines!inner(official_name, pod_location)",
      )
      .eq("dispatch_date", today)
      .eq("include", true);

    if (!lines || lines.length === 0) {
      setMachines([]);
      setLoading(false);
      return;
    }

    const grouped = new Map<
      string,
      {
        machine_id: string;
        official_name: string;
        pod_location: string | null;
        total: number;
        picked_up_count: number;
        dispatched_count: number;
      }
    >();

    for (const line of lines) {
      const m = line.machines as unknown as {
        official_name: string;
        pod_location: string | null;
      };
      const existing = grouped.get(line.machine_id);
      if (existing) {
        existing.total += 1;
        if (line.picked_up) existing.picked_up_count += 1;
        if (line.dispatched) existing.dispatched_count += 1;
      } else {
        grouped.set(line.machine_id, {
          machine_id: line.machine_id,
          official_name: m.official_name,
          pod_location: m.pod_location,
          total: 1,
          picked_up_count: line.picked_up ? 1 : 0,
          dispatched_count: line.dispatched ? 1 : 0,
        });
      }
    }

    // Only include machines where ALL lines have been picked up
    const result: DispatchMachine[] = Array.from(grouped.values())
      .filter((m) => m.picked_up_count === m.total)
      .map((m) => ({
        machine_id: m.machine_id,
        official_name: m.official_name,
        pod_location: m.pod_location,
        total: m.total,
        dispatched_count: m.dispatched_count,
        all_dispatched: m.dispatched_count === m.total,
      }))
      .sort((a, b) => a.official_name.localeCompare(b.official_name));

    setMachines(result);
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchMachines();
  }, [fetchMachines]);

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") fetchMachines();
    }
    document.addEventListener("visibilitychange", handleVisibility);
    window.addEventListener("focus", fetchMachines);
    return () => {
      document.removeEventListener("visibilitychange", handleVisibility);
      window.removeEventListener("focus", fetchMachines);
    };
  }, [fetchMachines]);

  if (loading) {
    return (
      <>
        <FieldHeader title="Dispatching" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading dispatching…</p>
        </div>
      </>
    );
  }

  if (machines.length === 0) {
    return (
      <>
        <FieldHeader title="Dispatching" />
        <div className="flex flex-col items-center justify-center p-8 text-center">
          <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
            No machines collected yet
          </p>
          <p className="mt-1 text-sm text-neutral-500">
            Complete pickups first.
          </p>
        </div>
      </>
    );
  }

  const toDispatch = machines.filter((m) => !m.all_dispatched);
  const completed = machines.filter((m) => m.all_dispatched);

  return (
    <div className="px-4 py-4">
      <FieldHeader
        title="Dispatching"
        rightAction={
          <Link
            href="/field/dispatching/pick"
            className="text-sm text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300"
          >
            Pick List →
          </Link>
        }
      />

      {toDispatch.length > 0 && (
        <div className="mb-6">
          <h2 className="mb-2 text-sm font-semibold text-neutral-500 uppercase tracking-wide">
            To dispatch
          </h2>
          <ul className="space-y-2">
            {toDispatch.map((machine) => (
              <li key={machine.machine_id}>
                <Link
                  href={`/field/dispatching/${machine.machine_id}`}
                  className="flex items-center gap-3 rounded-lg border border-neutral-200 bg-white p-4 transition-colors hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950 dark:hover:bg-neutral-900"
                >
                  <div className="flex-1 min-w-0">
                    <p className="text-base font-semibold truncate">
                      {machine.official_name}
                    </p>
                    {machine.pod_location && (
                      <p className="text-sm text-neutral-500 truncate">
                        {machine.pod_location}
                      </p>
                    )}
                  </div>
                  <span className="shrink-0 rounded-full bg-neutral-100 px-2.5 py-0.5 text-xs font-medium dark:bg-neutral-800">
                    {machine.dispatched_count}/{machine.total} dispatched
                  </span>
                </Link>
              </li>
            ))}
          </ul>
        </div>
      )}

      {completed.length > 0 && (
        <div>
          <h2 className="mb-2 text-sm font-semibold text-neutral-500 uppercase tracking-wide">
            Completed
          </h2>
          <ul className="space-y-2">
            {completed.map((machine) => (
              <li
                key={machine.machine_id}
                className="flex items-center gap-3 rounded-lg border border-neutral-200 bg-white p-4 opacity-60 dark:border-neutral-800 dark:bg-neutral-950"
              >
                <div className="flex-1 min-w-0">
                  <p className="text-base font-semibold truncate">
                    {machine.official_name}
                  </p>
                  {machine.pod_location && (
                    <p className="text-sm text-neutral-500 truncate">
                      {machine.pod_location}
                    </p>
                  )}
                </div>
                <span className="shrink-0 rounded-full bg-green-100 px-2.5 py-0.5 text-xs font-medium text-green-800 dark:bg-green-900 dark:text-green-200">
                  Completed ✓
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
