"use client";

import { useEffect, useState, useCallback } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import { machineShortId } from "@/lib/utils/machine-id";
import { FieldHeader } from "../../components/field-header";
import { usePageTour } from "../../components/onboarding/use-page-tour";
import Tour from "../../components/onboarding/tour";

interface PackingMachine {
  machine_id: string;
  official_name: string;
  adyen_store_code: string | null;
  sku_count: number;
  packed_count: number;
  /** PRD-030 Article 16: canonical readiness from v_machine_pack_status */
  is_pack_complete: boolean;
  pack_confirmed: boolean;
  /** PRD-020: machine finished as Complete but Partial (skipped or not_filled > 0) */
  is_partial: boolean;
}

export default function PackingPage() {
  const [machines, setMachines] = useState<PackingMachine[]>([]);
  const [loading, setLoading] = useState(true);
  const { showTour, tourSteps, completeTour } = usePageTour("packing");

  const fetchMachines = useCallback(async () => {
    const supabase = createClient();
    const today = getDubaiDate();

    const { data: lines } = await supabase
      .from("refill_dispatching")
      .select(
        "dispatch_id, machine_id, packed, machines!refill_dispatching_machine_id_fkey!inner(official_name, adyen_store_code)",
      )
      .eq("dispatch_date", today)
      .eq("include", true);

    if (!lines || lines.length === 0) {
      setMachines([]);
      setLoading(false);
      return;
    }

    // PRD-030 Article 16: read canonical pack readiness instead of counting
    // packed lines client-side. is_pack_complete is true once every included
    // line is resolved (packed / not_filled / skipped), so not_filled lines
    // don't hold the machine below 100%.
    const { data: statusRows } = await supabase
      .from("v_machine_pack_status")
      .select(
        "machine_id, is_pack_complete, pack_confirmed, not_filled, skipped, total_included, resolved",
      )
      .eq("dispatch_date", today)
      .limit(10000);
    const statusByMachine = new Map<
      string,
      {
        is_pack_complete: boolean;
        pack_confirmed: boolean;
        is_partial: boolean;
      }
    >(
      (statusRows ?? []).map((s) => [
        s.machine_id as string,
        {
          is_pack_complete: !!s.is_pack_complete,
          pack_confirmed: !!s.pack_confirmed,
          // PRD-020: partial = finished with at least one skipped or not_filled line.
          is_partial:
            Number(s.skipped ?? 0) > 0 || Number(s.not_filled ?? 0) > 0,
        },
      ]),
    );

    const grouped = new Map<string, PackingMachine>();

    for (const line of lines) {
      const m = line.machines as unknown as {
        official_name: string;
        adyen_store_code: string | null;
      };
      const existing = grouped.get(line.machine_id);
      if (existing) {
        existing.sku_count += 1;
        if (line.packed) existing.packed_count += 1;
      } else {
        const status = statusByMachine.get(line.machine_id);
        grouped.set(line.machine_id, {
          machine_id: line.machine_id,
          official_name: m.official_name,
          adyen_store_code: m.adyen_store_code,
          sku_count: 1,
          packed_count: line.packed ? 1 : 0,
          is_pack_complete: status?.is_pack_complete ?? false,
          pack_confirmed: status?.pack_confirmed ?? false,
          is_partial: status?.is_partial ?? false,
        });
      }
    }

    const sorted = Array.from(grouped.values()).sort((a, b) =>
      a.official_name.localeCompare(b.official_name),
    );
    setMachines(sorted);
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchMachines();
  }, [fetchMachines]);

  // Re-fetch when returning from detail page (visibility change)
  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") {
        fetchMachines();
      }
    }
    document.addEventListener("visibilitychange", handleVisibility);
    // Also re-fetch on window focus (covers back navigation)
    window.addEventListener("focus", fetchMachines);
    return () => {
      document.removeEventListener("visibilitychange", handleVisibility);
      window.removeEventListener("focus", fetchMachines);
    };
  }, [fetchMachines]);

  if (loading) {
    return (
      <>
        <FieldHeader title="Packing" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading packing list…</p>
        </div>
      </>
    );
  }

  if (machines.length === 0) {
    return (
      <>
        <FieldHeader title="Packing" />
        <div className="flex flex-col items-center justify-center p-8 text-center">
          <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
            No machines to pack today
          </p>
        </div>
      </>
    );
  }

  return (
    <div className="px-4 py-4">
      <FieldHeader title="Packing" />
      {showTour && tourSteps.length > 0 && (
        <Tour
          steps={tourSteps}
          onComplete={completeTour}
          onSkip={completeTour}
        />
      )}
      <ul data-tour="packing-list" className="space-y-2">
        {machines.map((machine, idx) => {
          // PRD-030 Article 16: readiness is canonical (is_pack_complete), not a
          // client-side packed-count match. pack_confirmed shows the sub-state.
          const ready = machine.is_pack_complete;
          return (
            <li key={machine.machine_id}>
              <Link
                href={`/field/packing/${machine.machine_id}`}
                className="flex items-center gap-3 rounded-lg border border-neutral-200 bg-white p-4 transition-colors hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950 dark:hover:bg-neutral-900"
              >
                <div className="flex-1 min-w-0">
                  <div className="flex items-baseline gap-2">
                    <p className="text-base font-semibold truncate">
                      {machine.official_name}
                    </p>
                    {machineShortId(machine.adyen_store_code) && (
                      <span className="shrink-0 font-mono text-xs tracking-wider text-neutral-400">
                        {machineShortId(machine.adyen_store_code)}
                      </span>
                    )}
                  </div>
                  <p className="text-sm text-neutral-500">
                    {machine.packed_count}/{machine.sku_count} packed
                  </p>
                </div>
                <span
                  {...(idx === 0 ? { "data-tour": "packing-status" } : {})}
                  className={`shrink-0 rounded-full px-2.5 py-0.5 text-xs font-medium ${
                    ready && machine.is_partial
                      ? "bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-200"
                      : ready
                        ? "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"
                        : "bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400"
                  }`}
                >
                  {/* PRD-020 (AC-5): a partial finish is amber "Partial", never a
                      red / incomplete state. */}
                  {machine.pack_confirmed
                    ? machine.is_partial
                      ? "Confirmed (partial)"
                      : "Confirmed"
                    : ready
                      ? machine.is_partial
                        ? "Partial"
                        : "Ready"
                      : "Packing"}
                </span>
              </Link>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
