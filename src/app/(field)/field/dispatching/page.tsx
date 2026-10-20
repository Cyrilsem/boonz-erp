"use client";

import { useEffect, useState, useCallback, Suspense } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import { machineShortId } from "@/lib/utils/machine-id";
import { FieldHeader } from "../../components/field-header";
import PendingMachinesPanel from "@/components/field/PendingMachinesPanel";
import PodOrphanRowsPanel from "@/components/field/PodOrphanRowsPanel";
import LotsToCountPanel from "@/components/field/LotsToCountPanel";

interface DispatchLineInfo {
  shelf_code: string | null;
  product_name: string | null;
  qty: number;
  expiry_date: string | null;
}

interface DispatchMachine {
  machine_id: string;
  official_name: string;
  pod_location: string | null;
  adyen_store_code: string | null;
  total: number;
  dispatched_count: number;
  all_dispatched: boolean;
  lines: DispatchLineInfo[];
  /** PRD-141 item 17: undelivered bags from an earlier day, still in the van. */
  older_in_transit: { date: string; bags: number } | null;
}

function formatShortDate(dateStr: string): string {
  const d = new Date(dateStr + "T00:00:00");
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

// PRD-144 P1-1: Today (this page as it was) and Pending (earlier days with open lines).
type DispatchTab = "today" | "pending";

function DispatchTabs({
  tab,
  onChange,
}: {
  tab: DispatchTab;
  onChange: (t: DispatchTab) => void;
}) {
  return (
    <div className="mt-3 mb-3 flex rounded-lg bg-neutral-100 p-1 text-sm dark:bg-neutral-900">
      {(["today", "pending"] as DispatchTab[]).map((t) => (
        <button
          key={t}
          onClick={() => onChange(t)}
          className={`flex-1 rounded-md py-1.5 font-semibold ${
            tab === t
              ? "bg-white text-[#24544a] shadow-sm dark:bg-neutral-800"
              : "text-neutral-500"
          }`}
        >
          {t === "today" ? "Today" : "Pending"}
        </button>
      ))}
    </div>
  );
}

// useSearchParams() needs a Suspense boundary or the static build bails out
// (same wrapper as the pod inventory page).
export default function DispatchingPage() {
  return (
    <Suspense
      fallback={
        <>
          <FieldHeader title="Dispatching" />
          <div className="flex items-center justify-center p-8">
            <p className="text-neutral-500">Loading dispatching…</p>
          </div>
        </>
      }
    >
      <DispatchingPageInner />
    </Suspense>
  );
}

function DispatchingPageInner() {
  const searchParams = useSearchParams();
  const [tab, setTab] = useState<DispatchTab>(
    searchParams?.get("tab") === "pending" ? "pending" : "today",
  );
  const tabs = <DispatchTabs tab={tab} onChange={setTab} />;
  if (tab === "pending") {
    return (
      <div className="px-4 py-4">
        <FieldHeader title="Dispatching" />
        {tabs}
        <PendingMachinesPanel />
        <PodOrphanRowsPanel />
        <LotsToCountPanel />
      </div>
    );
  }
  return <TodayDispatching tabs={tabs} />;
}

function TodayDispatching({ tabs }: { tabs: React.ReactNode }) {
  const [machines, setMachines] = useState<DispatchMachine[]>([]);
  const [loading, setLoading] = useState(true);
  const [expandedMachine, setExpandedMachine] = useState<string | null>(null);

  const fetchMachines = useCallback(async () => {
    const supabase = createClient();
    const today = getDubaiDate();

    const { data: lines } = await supabase
      .from("refill_dispatching")
      .select(
        "dispatch_id, machine_id, picked_up, dispatched, returned, quantity, filled_quantity, expiry_date, machines!refill_dispatching_machine_id_fkey!inner(official_name, pod_location, adyen_store_code), shelf_configurations(shelf_code), pod_products(pod_product_name)",
      )
      .eq("dispatch_date", today)
      .eq("include", true)
      // PRD-044: physical subset only — not_filled lines never get picked_up,
      // and skipped/cancelled lines are inert (PRD-028); none of them belong
      // in the dispatch list or its progress counts.
      .eq("skipped", false)
      .eq("cancelled", false)
      .eq("picked_up", true);

    if (!lines || lines.length === 0) {
      setMachines([]);
      setLoading(false);
      return;
    }

    // PRD-030 Article 16: a machine is ready to dispatch when
    // v_machine_pack_status.is_pickup_complete (computed over the physical
    // subset) — not_filled / skipped lines must not hold dispatch below 100%.
    const { data: statusRows } = await supabase
      .from("v_machine_pack_status")
      .select("machine_id, is_pickup_complete")
      .eq("dispatch_date", today)
      .limit(10000);
    // PRD-141 item 17: bags from an earlier day that were never delivered.
    const { data: olderTransit } = await supabase
      .from("v_machine_pack_status")
      .select("machine_id, dispatch_date, in_transit_n")
      .eq("in_transit", true)
      .lt("dispatch_date", today)
      .limit(10000);
    const olderTransitByMachine = new Map<
      string,
      { date: string; bags: number }
    >();
    for (const t of olderTransit ?? []) {
      const prev = olderTransitByMachine.get(t.machine_id as string);
      olderTransitByMachine.set(t.machine_id as string, {
        date:
          prev && prev.date < (t.dispatch_date as string)
            ? prev.date
            : (t.dispatch_date as string),
        bags: (prev?.bags ?? 0) + Number(t.in_transit_n ?? 0),
      });
    }
    const pickupCompleteByMachine = new Map<string, boolean>(
      (statusRows ?? []).map((s) => [
        s.machine_id as string,
        !!s.is_pickup_complete,
      ]),
    );

    const grouped = new Map<
      string,
      {
        machine_id: string;
        official_name: string;
        pod_location: string | null;
        adyen_store_code: string | null;
        total: number;
        picked_up_count: number;
        dispatched_count: number;
        lines: DispatchLineInfo[];
      }
    >();

    for (const line of lines) {
      const m = line.machines as unknown as {
        official_name: string;
        pod_location: string | null;
        adyen_store_code: string | null;
      };
      const shelf = line.shelf_configurations as unknown as {
        shelf_code: string;
      } | null;
      const product = line.pod_products as unknown as {
        pod_product_name: string;
      } | null;
      const lineInfo: DispatchLineInfo = {
        shelf_code: shelf?.shelf_code ?? null,
        product_name: product?.pod_product_name ?? null,
        qty: (line.filled_quantity as number | null) ?? line.quantity ?? 0,
        expiry_date: (line.expiry_date as string | null) ?? null,
      };
      const existing = grouped.get(line.machine_id);
      if (existing) {
        existing.total += 1;
        if (line.picked_up) existing.picked_up_count += 1;
        if (line.dispatched || line.returned) existing.dispatched_count += 1;
        existing.lines.push(lineInfo);
      } else {
        grouped.set(line.machine_id, {
          machine_id: line.machine_id,
          official_name: m.official_name,
          pod_location: m.pod_location,
          adyen_store_code: m.adyen_store_code,
          total: 1,
          picked_up_count: line.picked_up ? 1 : 0,
          dispatched_count: line.dispatched || line.returned ? 1 : 0,
          lines: [lineInfo],
        });
      }
    }

    // PRD-030 Article 16: ready-to-dispatch is canonical (is_pickup_complete over
    // the physical subset), not "every line picked up".
    const result: DispatchMachine[] = Array.from(grouped.values())
      .filter((m) => pickupCompleteByMachine.get(m.machine_id) ?? false)
      .map((m) => ({
        machine_id: m.machine_id,
        official_name: m.official_name,
        pod_location: m.pod_location,
        adyen_store_code: m.adyen_store_code,
        total: m.total,
        dispatched_count: m.dispatched_count,
        all_dispatched: m.dispatched_count === m.total,
        older_in_transit: olderTransitByMachine.get(m.machine_id) ?? null,
        lines: m.lines.sort((a, b) =>
          (a.shelf_code ?? "").localeCompare(b.shelf_code ?? ""),
        ),
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
        <div className="px-4">{tabs}</div>
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
        <div className="px-4">{tabs}</div>
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
  // PRD-087: don't echo the machine name as its own location
  const locationOf = (m: DispatchMachine) =>
    m.pod_location && m.pod_location.trim() !== m.official_name
      ? m.pod_location
      : null;

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
      {tabs}

      {/* Day progress strip */}
      <div className="mt-3 mb-4 flex items-center gap-3">
        <div className="h-2 flex-1 overflow-hidden rounded-full bg-neutral-100 dark:bg-neutral-800">
          <div
            className="h-full rounded-full bg-[#24544a] transition-all"
            style={{
              width: `${machines.length > 0 ? (completed.length / machines.length) * 100 : 0}%`,
            }}
          />
        </div>
        <span className="shrink-0 text-xs font-semibold text-neutral-500 tabular-nums">
          {completed.length}/{machines.length} machines done
        </span>
      </div>

      {toDispatch.length > 0 && (
        <div className="mb-6">
          <h2 className="mb-2 text-xs font-bold text-[#24544a] uppercase tracking-widest">
            To dispatch · {toDispatch.length}
          </h2>
          <ul className="space-y-1.5">
            {toDispatch.map((machine) => (
              <li key={machine.machine_id}>
                <Link
                  href={`/field/dispatching/${machine.machine_id}`}
                  className="flex items-center gap-3 rounded-lg border border-neutral-200 bg-white px-4 py-2.5 transition-colors hover:border-[#24544a]/40 hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950 dark:hover:bg-neutral-900"
                >
                  <div className="flex-1 min-w-0">
                    <div className="flex items-baseline gap-2">
                      <p className="text-sm font-semibold truncate">
                        {machine.official_name}
                      </p>
                      {machineShortId(machine.adyen_store_code) && (
                        <span className="shrink-0 font-mono text-[11px] tracking-wider text-neutral-400">
                          {machineShortId(machine.adyen_store_code)}
                        </span>
                      )}
                      {locationOf(machine) && (
                        <span className="hidden sm:inline shrink-0 text-xs text-neutral-400 truncate">
                          · {locationOf(machine)}
                        </span>
                      )}
                    </div>
                  </div>
                  {machine.older_in_transit && (
                    <span className="shrink-0 rounded-full bg-red-100 px-2 py-0.5 text-[11px] font-semibold text-red-800">
                      +{machine.older_in_transit.bags} bags from{" "}
                      {formatShortDate(machine.older_in_transit.date)}
                    </span>
                  )}
                  <span className="shrink-0 rounded-full bg-[#faf3e3] px-2.5 py-0.5 text-xs font-semibold text-[#b45309]">
                    {machine.dispatched_count}/{machine.total}
                  </span>
                  <span className="shrink-0 text-neutral-300">→</span>
                </Link>
              </li>
            ))}
          </ul>
        </div>
      )}

      {completed.length > 0 && (
        <div>
          <h2 className="mb-2 text-xs font-bold text-neutral-400 uppercase tracking-widest">
            Completed · {completed.length}
          </h2>
          <ul className="space-y-1.5">
            {completed.map((machine) => {
              const isExpanded = expandedMachine === machine.machine_id;
              return (
                <li key={machine.machine_id}>
                  <button
                    onClick={() =>
                      setExpandedMachine((prev) =>
                        prev === machine.machine_id ? null : machine.machine_id,
                      )
                    }
                    className="flex w-full items-center gap-3 rounded-lg border border-neutral-200 bg-white px-4 py-2 text-left opacity-70 transition-opacity hover:opacity-100 dark:border-neutral-800 dark:bg-neutral-950"
                  >
                    <span className="shrink-0 text-emerald-600">✓</span>
                    <div className="flex-1 min-w-0">
                      <div className="flex items-baseline gap-2">
                        <p className="text-sm font-semibold truncate">
                          {machine.official_name}
                        </p>
                        {machineShortId(machine.adyen_store_code) && (
                          <span className="shrink-0 font-mono text-[11px] tracking-wider text-neutral-400">
                            {machineShortId(machine.adyen_store_code)}
                          </span>
                        )}
                        {locationOf(machine) && (
                          <span className="hidden sm:inline shrink-0 text-xs text-neutral-400 truncate">
                            · {locationOf(machine)}
                          </span>
                        )}
                      </div>
                    </div>
                    <span className="shrink-0 text-xs text-neutral-400 tabular-nums">
                      {machine.total} lines
                    </span>
                    <span className="shrink-0 text-xs text-neutral-400">
                      {isExpanded ? "▲" : "▼"}
                    </span>
                  </button>
                  {isExpanded && (
                    <div className="mt-1 rounded-lg border border-neutral-100 bg-neutral-50 px-3 py-2 dark:border-neutral-800 dark:bg-neutral-900">
                      {machine.lines.map((line, idx) => (
                        <div
                          key={idx}
                          className="flex items-center gap-2 py-1.5 text-sm"
                        >
                          <span className="shrink-0 w-8 text-xs font-mono text-neutral-400">
                            {line.shelf_code ?? "—"}
                          </span>
                          <span className="flex-1 min-w-0 truncate text-neutral-700 dark:text-neutral-300">
                            {line.product_name ?? "—"}
                          </span>
                          <span className="shrink-0 font-medium text-neutral-600 dark:text-neutral-400">
                            ×{line.qty}
                          </span>
                          {line.expiry_date && (
                            <span className="shrink-0 text-xs text-neutral-400">
                              {formatShortDate(line.expiry_date)}
                            </span>
                          )}
                        </div>
                      ))}
                    </div>
                  )}
                </li>
              );
            })}
          </ul>
        </div>
      )}
    </div>
  );
}
