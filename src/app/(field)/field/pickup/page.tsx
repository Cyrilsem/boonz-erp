"use client";

import { useEffect, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import { FieldHeader } from "../../components/field-header";

type DispatchAction = "Refill" | "Add New" | "Remove";

interface PickupLine {
  dispatch_id: string;
  /** Planned action type — drives the colored badge so driver knows what to pack vs collect */
  dispatch_action: DispatchAction;
  shelf_code: string | null;
  pod_product_name: string;
  quantity: number;
  filled_quantity: number;
  dispatched: boolean;
  returned: boolean;
}

interface PickupMachine {
  machine_id: string;
  official_name: string;
  line_count: number;
  all_picked_up: boolean;
  lines: PickupLine[];
}

export default function PickupPage() {
  const [machines, setMachines] = useState<PickupMachine[]>([]);
  const [loading, setLoading] = useState(true);
  const [confirming, setConfirming] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<string | null>(null);

  const fetchMachines = useCallback(async () => {
    const supabase = createClient();
    const today = getDubaiDate();

    // Today's packed-but-not-picked-up lines only.
    // (Historical leftovers auto-release at 23:59 Dubai via the eod_auto_release_unpicked cron.)
    const { data: lines } = await supabase
      .from("refill_dispatching")
      .select(
        `
        dispatch_id, machine_id, action, packed, picked_up, quantity,
        filled_quantity, dispatched, returned,
        machines!inner(official_name),
        shelf_configurations(shelf_code),
        pod_products(pod_product_name)
      `,
      )
      .eq("dispatch_date", today)
      .eq("include", true)
      .eq("picked_up", false)
      .eq("dispatched", false);

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
        total: number;
        packed_count: number;
        picked_up_count: number;
        lines: PickupLine[];
      }
    >();

    for (const line of lines) {
      const m = line.machines as unknown as { official_name: string };
      const shelf = line.shelf_configurations as unknown as {
        shelf_code: string;
      } | null;
      const product = line.pod_products as unknown as {
        pod_product_name: string;
      } | null;

      const existing = grouped.get(line.machine_id);
      const pickupLine: PickupLine = {
        dispatch_id: line.dispatch_id,
        dispatch_action: (((line as Record<string, unknown>).action as string) ?? "Refill") as DispatchAction,
        shelf_code: shelf?.shelf_code ?? null,
        pod_product_name: product?.pod_product_name ?? "Transfer",
        quantity: line.quantity ?? 0,
        filled_quantity:
          (line.filled_quantity as number | null) ?? line.quantity ?? 0,
        dispatched: !!(line.dispatched as boolean | null),
        returned: !!(line.returned as boolean | null),
      };

      if (existing) {
        existing.total += 1;
        if (line.packed) existing.packed_count += 1;
        if (line.picked_up) existing.picked_up_count += 1;
        existing.lines.push(pickupLine);
      } else {
        grouped.set(line.machine_id, {
          machine_id: line.machine_id,
          official_name: m.official_name,
          total: 1,
          packed_count: line.packed ? 1 : 0,
          picked_up_count: line.picked_up ? 1 : 0,
          lines: [pickupLine],
        });
      }
    }

    // Only include machines where ALL lines are packed
    const result: PickupMachine[] = Array.from(grouped.values())
      .filter((m) => m.packed_count === m.total)
      .map((m) => ({
        machine_id: m.machine_id,
        official_name: m.official_name,
        line_count: m.total,
        all_picked_up: m.picked_up_count === m.total,
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

  async function handleConfirmPickup(machineId: string) {
    setConfirming(machineId);
    const supabase = createClient();

    // Gather every dispatch_id for this machine from current state.
    const machine = machines.find((m) => m.machine_id === machineId);
    const dispatchIds = machine?.lines.map((l) => l.dispatch_id) ?? [];
    if (dispatchIds.length === 0) {
      setConfirming(null);
      return;
    }

    // Article 1 / Rule S1: route through the canonical RPC instead of direct table update.
    const { error } = await supabase.rpc("mark_picked_up", {
      p_dispatch_ids: dispatchIds,
    });

    if (error) {
      console.error("mark_picked_up failed:", error);
      alert(`Confirm pickup failed: ${error.message}`);
      setConfirming(null);
      return;
    }

    setMachines((prev) =>
      prev.map((m) =>
        m.machine_id === machineId ? { ...m, all_picked_up: true } : m,
      ),
    );
    setExpanded(null);
    setConfirming(null);
  }

  function toggleExpanded(machineId: string) {
    setExpanded((prev) => (prev === machineId ? null : machineId));
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="Pickup" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading pickup list…</p>
        </div>
      </>
    );
  }

  const readyMachines = machines.filter((m) => !m.all_picked_up);
  const collectedMachines = machines.filter((m) => m.all_picked_up);

  const RefreshButton = () => (
    <div className="flex justify-end px-4 pt-1 pb-2">
      <button
        onClick={fetchMachines}
        className="shrink-0 rounded border border-neutral-300 px-2 py-1.5 text-xs text-neutral-500 transition-colors hover:bg-neutral-100 dark:border-neutral-600 dark:text-neutral-400 dark:hover:bg-neutral-800"
      >
        ↺ Refresh
      </button>
    </div>
  );

  if (machines.length === 0) {
    return (
      <>
        <FieldHeader title="Pickup" />
        <RefreshButton />
        <div className="flex flex-col items-center justify-center p-8 text-center">
          <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
            No machines ready for pickup
          </p>
          <p className="mt-1 text-sm text-neutral-500">
            Warehouse is still packing
          </p>
        </div>
      </>
    );
  }

  return (
    <div className="px-4 py-4">
      <FieldHeader title="Pickup" />
      <div className="mb-3 flex justify-end">
        <button
          onClick={fetchMachines}
          className="shrink-0 rounded border border-neutral-300 px-2 py-1.5 text-xs text-neutral-500 transition-colors hover:bg-neutral-100 dark:border-neutral-600 dark:text-neutral-400 dark:hover:bg-neutral-800"
        >
          ↺ Refresh
        </button>
      </div>

      {readyMachines.length > 0 && (
        <div className="mb-6">
          <h2 className="mb-2 text-sm font-semibold text-neutral-500 uppercase tracking-wide">
            Ready for pickup
          </h2>
          <ul className="space-y-2">
            {readyMachines.map((machine) => {
              const isExpanded = expanded === machine.machine_id;
              return (
                <li
                  key={machine.machine_id}
                  className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950"
                >
                  <button
                    onClick={() => toggleExpanded(machine.machine_id)}
                    className="flex w-full items-center gap-3 p-4 text-left"
                  >
                    <div className="flex-1 min-w-0">
                      <p className="text-base font-semibold truncate">
                        {machine.official_name}
                      </p>
                      <p className="text-sm text-neutral-500">
                        {machine.line_count} items
                      </p>
                    </div>
                    <span className="shrink-0 text-neutral-400">
                      {isExpanded ? "▲" : "▼"}
                    </span>
                  </button>

                  {isExpanded && (
                    <div className="border-t border-neutral-200 px-4 pb-4 dark:border-neutral-800">
                      {/* Legend — quick reference so driver knows the badge colors */}
                      <div className="mt-3 flex flex-wrap gap-1.5 text-[10px]">
                        <span className="rounded bg-sky-50 px-1.5 py-0.5 font-semibold uppercase text-sky-700 dark:bg-sky-950/40 dark:text-sky-400">
                          Refill
                        </span>
                        <span className="rounded bg-purple-50 px-1.5 py-0.5 font-semibold uppercase text-purple-700 dark:bg-purple-950/40 dark:text-purple-400">
                          Add new
                        </span>
                        <span className="rounded bg-rose-50 px-1.5 py-0.5 font-semibold uppercase text-rose-700 dark:bg-rose-950/40 dark:text-rose-400">
                          Remove
                        </span>
                        <span className="text-neutral-400">·</span>
                        <span className="text-neutral-500">
                          Pack only Refill + Add new. Remove = collect from machine.
                        </span>
                      </div>
                      <ul className="mt-3 space-y-1">
                        {machine.lines.map((line) => {
                          const actionBadge =
                            line.dispatch_action === "Remove"
                              ? "rose"
                              : line.dispatch_action === "Add New"
                                ? "purple"
                                : "sky";
                          const badgeClass = {
                            rose: "bg-rose-50 text-rose-700 dark:bg-rose-950/40 dark:text-rose-400",
                            purple:
                              "bg-purple-50 text-purple-700 dark:bg-purple-950/40 dark:text-purple-400",
                            sky: "bg-sky-50 text-sky-700 dark:bg-sky-950/40 dark:text-sky-400",
                          }[actionBadge];
                          const qty =
                            line.filled_quantity > 0
                              ? line.filled_quantity
                              : line.quantity;
                          const qtyDisplay =
                            line.dispatch_action === "Remove"
                              ? `−${qty}`
                              : `×${qty}`;
                          const qtyClass =
                            line.dispatch_action === "Remove"
                              ? "text-rose-700 dark:text-rose-400 font-medium"
                              : "text-neutral-500";
                          return (
                            <li
                              key={line.dispatch_id}
                              className="flex items-center gap-2 rounded bg-neutral-50 px-3 py-2 text-sm dark:bg-neutral-900"
                            >
                              <span className="font-mono text-xs text-neutral-400 shrink-0">
                                {line.shelf_code ?? "—"}
                              </span>
                              <span
                                className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase ${badgeClass}`}
                              >
                                {line.dispatch_action}
                              </span>
                              <span className="flex-1 truncate">
                                {line.pod_product_name}
                              </span>
                              <span className={`shrink-0 ml-2 ${qtyClass}`}>
                                {qtyDisplay}
                              </span>
                            </li>
                          );
                        })}
                      </ul>
                      <button
                        onClick={() => handleConfirmPickup(machine.machine_id)}
                        disabled={confirming === machine.machine_id}
                        className="mt-3 w-full rounded-lg bg-neutral-900 py-2.5 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
                      >
                        {confirming === machine.machine_id
                          ? "Confirming…"
                          : "Confirm pickup"}
                      </button>
                    </div>
                  )}
                </li>
              );
            })}
          </ul>
        </div>
      )}

      {collectedMachines.length > 0 && (
        <div>
          <h2 className="mb-2 text-sm font-semibold text-neutral-500 uppercase tracking-wide">
            Collected
          </h2>
          <ul className="space-y-2">
            {collectedMachines.map((machine) => {
              const isExpanded = expanded === machine.machine_id;
              return (
                <li
                  key={machine.machine_id}
                  className="rounded-lg border border-neutral-200 bg-white opacity-70 dark:border-neutral-800 dark:bg-neutral-950"
                >
                  <button
                    onClick={() => toggleExpanded(machine.machine_id)}
                    className="flex w-full items-center gap-3 p-4 text-left"
                  >
                    <div className="flex-1 min-w-0">
                      <p className="text-base font-semibold truncate">
                        {machine.official_name}
                      </p>
                      <p className="text-sm text-neutral-500">
                        {machine.line_count} items
                      </p>
                    </div>
                    <span className="shrink-0 rounded-full bg-green-100 px-2.5 py-0.5 text-xs font-medium text-green-800 dark:bg-green-900 dark:text-green-200">
                      Collected ✓
                    </span>
                    <span className="shrink-0 text-neutral-400 ml-1">
                      {isExpanded ? "▲" : "▼"}
                    </span>
                  </button>

                  {isExpanded && (
                    <div className="border-t border-neutral-200 px-4 pb-4 dark:border-neutral-800">
                      <ul className="mt-3 space-y-1">
                        {machine.lines.map((line) => {
                          const actionLabel = line.dispatched
                            ? "Added"
                            : line.returned
                              ? "Returned"
                              : "Pending";
                          const actionClass = line.dispatched
                            ? "bg-green-100 text-green-700 dark:bg-green-900/40 dark:text-green-300"
                            : line.returned
                              ? "bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-300"
                              : "bg-neutral-100 text-neutral-500 dark:bg-neutral-800 dark:text-neutral-400";
                          return (
                            <li
                              key={line.dispatch_id}
                              className="flex items-center gap-2 rounded bg-neutral-50 px-3 py-2 text-sm dark:bg-neutral-900"
                            >
                              <span
                                className={`shrink-0 rounded-full px-2 py-0.5 text-xs font-medium ${actionClass}`}
                              >
                                {actionLabel}
                              </span>
                              <span className="flex-1 truncate">
                                {line.pod_product_name}
                              </span>
                              <span className="shrink-0 text-xs text-neutral-400">
                                {line.quantity}→{line.filled_quantity}
                              </span>
                            </li>
                          );
                        })}
                      </ul>
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
