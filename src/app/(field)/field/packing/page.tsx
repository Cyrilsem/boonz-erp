"use client";

import { useEffect, useState, useCallback, Suspense } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { machineShortId } from "@/lib/utils/machine-id";
import { FieldHeader } from "../../components/field-header";
import { usePageTour } from "../../components/onboarding/use-page-tour";
import Tour from "../../components/onboarding/tour";
import { useFieldPackDate } from "../_lib/use-field-pack-date";
import { PackAheadBanner, PackDateToggle } from "../_lib/pack-date-controls";

interface PackingMachine {
  machine_id: string;
  official_name: string;
  adyen_store_code: string | null;
  /**
   * PRD-107 A5: progress is resolved/packable, both from the canonical view.
   * The FE no longer counts lines to build its own denominator - counting every
   * included line put Remove legs in the denominator, which is what stranded
   * MC-2004 at "32/39" while the server gate had zero unresolved lines.
   */
  packable_n: number;
  resolved_n: number;
  /** Remove / Machine To Warehouse legs: real work, but never a pack gate. */
  driver_action_n: number;
  /** PRD-107: canonical readiness from v_dispatch_pack_progress. */
  is_pack_complete: boolean;
  pack_confirmed: boolean;
  /** PRD-020: machine finished as Complete but Partial (skipped or not_filled > 0) */
  is_partial: boolean;
}

// PRD-111: default export wraps the inner component in <Suspense> — required by
// the App Router as soon as a client page reads useSearchParams (the pack-date
// hook does), otherwise the static-render bailout check fails the build.
export default function PackingPage() {
  return (
    <Suspense
      fallback={
        <>
          <FieldHeader title="Packing" />
          <div className="flex items-center justify-center p-8">
            <p className="text-neutral-500">Loading packing list…</p>
          </div>
        </>
      }
    >
      <PackingPageInner />
    </Suspense>
  );
}

function PackingPageInner() {
  const [machines, setMachines] = useState<PackingMachine[]>([]);
  const [loading, setLoading] = useState(true);
  const { showTour, tourSteps, completeTour } = usePageTour("packing");
  // PRD-111: the packer-selected dispatch date (today by default, ?d=tomorrow).
  const { selectedDate, isTomorrow, setTomorrow, dateQuery } =
    useFieldPackDate();

  const fetchMachines = useCallback(async () => {
    setLoading(true);
    const supabase = createClient();

    const { data: lines } = await supabase
      .from("refill_dispatching")
      .select(
        "dispatch_id, machine_id, packed, dispatched, skipped, cancelled, pack_outcome, not_filled_reason, machines!refill_dispatching_machine_id_fkey!inner(official_name, adyen_store_code)",
      )
      .eq("dispatch_date", selectedDate)
      .eq("include", true);

    if (!lines || lines.length === 0) {
      setMachines([]);
      setLoading(false);
      return;
    }

    // PRD-107 A5 / Article 16: v_dispatch_pack_progress is THE pack-close state.
    // ready_to_pack_close is the exact negation of confirm_machine_packed's
    // unresolved predicate, so the board and the server gate cannot disagree.
    // pack_confirmed still comes from v_machine_pack_status because that is a
    // confirmation-record fact, not a progress fact.
    const [{ data: progressRows }, { data: confirmRows }] = await Promise.all([
      supabase
        .from("v_dispatch_pack_progress")
        .select(
          "machine_id, packable_n, resolved_n, driver_action_n, not_filled_n, skipped_n, ready_to_pack_close",
        )
        .eq("dispatch_date", selectedDate)
        .limit(10000),
      supabase
        .from("v_machine_pack_status")
        .select("machine_id, pack_confirmed")
        .eq("dispatch_date", selectedDate)
        .limit(10000),
    ]);
    const confirmedByMachine = new Map<string, boolean>(
      (confirmRows ?? []).map((c) => [
        c.machine_id as string,
        !!c.pack_confirmed,
      ]),
    );
    const statusByMachine = new Map<
      string,
      {
        is_pack_complete: boolean;
        pack_confirmed: boolean;
        is_partial: boolean;
        packable_n: number;
        resolved_n: number;
        driver_action_n: number;
      }
    >(
      (progressRows ?? []).map((s) => [
        s.machine_id as string,
        {
          is_pack_complete: !!s.ready_to_pack_close,
          pack_confirmed:
            confirmedByMachine.get(s.machine_id as string) ?? false,
          // PRD-020: partial = finished with at least one skipped or not_filled line.
          is_partial:
            Number(s.skipped_n ?? 0) > 0 || Number(s.not_filled_n ?? 0) > 0,
          packable_n: Number(s.packable_n ?? 0),
          resolved_n: Number(s.resolved_n ?? 0),
          driver_action_n: Number(s.driver_action_n ?? 0),
        },
      ]),
    );

    // PRD-087 (CS rule): dispatch dominates packing — a machine whose
    // fillable lines are all dispatched shows Complete here even if the pack
    // was only partially ticked. Compute per-machine dispatch completeness.
    const dispatchDone = new Map<string, { fillable: number; disp: number }>();
    for (const line of lines as unknown as {
      machine_id: string;
      dispatched: boolean;
      skipped: boolean | null;
      cancelled: boolean | null;
      pack_outcome: string | null;
      not_filled_reason: string | null;
    }[]) {
      if (line.cancelled) continue;
      const d = dispatchDone.get(line.machine_id) ?? { fillable: 0, disp: 0 };
      const inert =
        !!line.skipped ||
        line.pack_outcome === "not_filled" ||
        line.not_filled_reason != null;
      if (!inert) d.fillable += 1;
      if (line.dispatched) d.disp += 1;
      dispatchDone.set(line.machine_id, d);
    }
    const isDispatchComplete = (machineId: string) => {
      const d = dispatchDone.get(machineId);
      return !!d && d.disp >= d.fillable && d.fillable + d.disp > 0;
    };

    const grouped = new Map<string, PackingMachine>();

    for (const line of lines) {
      const m = line.machines as unknown as {
        official_name: string;
        adyen_store_code: string | null;
      };
      const existing = grouped.get(line.machine_id);
      if (!existing) {
        const status = statusByMachine.get(line.machine_id);
        const dispatchedComplete = isDispatchComplete(line.machine_id);
        grouped.set(line.machine_id, {
          machine_id: line.machine_id,
          official_name: m.official_name,
          adyen_store_code: m.adyen_store_code,
          // PRD-107 A5: counts come from the view, never from counting lines here.
          packable_n: status?.packable_n ?? 0,
          resolved_n: status?.resolved_n ?? 0,
          driver_action_n: status?.driver_action_n ?? 0,
          // dispatch dominance: fully-dispatched ⇒ pack shows complete
          is_pack_complete:
            (status?.is_pack_complete ?? false) || dispatchedComplete,
          pack_confirmed:
            (status?.pack_confirmed ?? false) || dispatchedComplete,
          is_partial: status?.is_partial ?? false,
        });
      }
    }

    const sorted = Array.from(grouped.values()).sort((a, b) =>
      a.official_name.localeCompare(b.official_name),
    );
    setMachines(sorted);
    setLoading(false);
  }, [selectedDate]);

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

  // PRD-111: the date control stays mounted in every state — a packer who lands
  // on an empty Tomorrow must be able to flip back without hitting the back button.
  const dateControls = (
    <>
      <PackDateToggle
        isTomorrow={isTomorrow}
        setTomorrow={setTomorrow}
        selectedDate={selectedDate}
      />
      {isTomorrow && <PackAheadBanner selectedDate={selectedDate} />}
    </>
  );

  if (loading) {
    return (
      <div className="px-4 py-4">
        <FieldHeader title="Packing" />
        {dateControls}
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading packing list…</p>
        </div>
      </div>
    );
  }

  if (machines.length === 0) {
    return (
      <div className="px-4 py-4">
        <FieldHeader title="Packing" />
        {dateControls}
        <div className="flex flex-col items-center justify-center p-8 text-center">
          <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
            {isTomorrow
              ? "No machines to pack tomorrow"
              : "No machines to pack today"}
          </p>
          {/* PRD-111 guardrail: never silently fall back to today's data. */}
          <p className="mt-1 text-sm text-neutral-500">
            No plan pushed for {selectedDate} yet
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="px-4 py-4">
      <FieldHeader title="Packing" />
      {dateControls}
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
                href={`/field/packing/${machine.machine_id}${dateQuery}`}
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
                    {machine.resolved_n}/{machine.packable_n} packed
                    {machine.driver_action_n > 0 && (
                      <span className="text-neutral-400">
                        {" "}
                        · +{machine.driver_action_n} driver action
                        {machine.driver_action_n === 1 ? "" : "s"}
                      </span>
                    )}
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
