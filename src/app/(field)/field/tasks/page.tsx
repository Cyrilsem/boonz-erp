"use client";

import { useEffect, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import { FieldHeader } from "../../components/field-header";
import { usePageTour } from "../../components/onboarding/use-page-tour";
import Tour from "../../components/onboarding/tour";

interface DriverTask {
  task_id: string;
  po_id: string;
  po_number: number;
  supplier_name: string;
  procurement_type: "walk_in" | "supplier_delivered";
  is_forced: boolean;
  status: "pending" | "acknowledged" | "collected" | "cancelled";
  notes: string | null;
  created_at: string;
  acknowledged_at: string | null;
  collected_at: string | null;
}

interface POLineDetail {
  po_line_id: string;
  boonz_product_name: string;
  ordered_qty: number;
  price_per_unit_aed: number | null;
  total_price_aed: number | null;
}

type Outcome =
  | "purchased_full"
  | "purchased_partial"
  | "not_available"
  | "other";

const OUTCOME_OPTIONS: { value: Outcome; label: string; icon: string }[] = [
  { value: "purchased_full", label: "Full", icon: "✅" },
  { value: "purchased_partial", label: "Partial", icon: "⚠️" },
  { value: "not_available", label: "N/A", icon: "❌" },
  { value: "other", label: "Other", icon: "📝" },
];

function formatDateTime(isoStr: string): string {
  const d = new Date(isoStr);
  return (
    d.toLocaleDateString("en-US", { month: "short", day: "numeric" }) +
    " at " +
    d.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" })
  );
}

function StatusBadge({ status }: { status: DriverTask["status"] }) {
  switch (status) {
    case "pending":
      return (
        <span className="rounded-full bg-neutral-100 px-2 py-0.5 text-xs font-medium text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400">
          Pending
        </span>
      );
    case "acknowledged":
      return (
        <span className="rounded-full bg-blue-100 px-2 py-0.5 text-xs font-medium text-blue-700 dark:bg-blue-900 dark:text-blue-300">
          On my way
        </span>
      );
    case "collected":
      return (
        <span className="rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700 dark:bg-green-900 dark:text-green-300">
          Collected ✓
        </span>
      );
    case "cancelled":
      return (
        <span className="rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-700 dark:bg-red-900 dark:text-red-300">
          Cancelled
        </span>
      );
  }
}

export default function TasksPage() {
  const [tasks, setTasks] = useState<DriverTask[]>([]);
  const [loading, setLoading] = useState(true);
  const [updatingId, setUpdatingId] = useState<string | null>(null);
  const { showTour, tourSteps, completeTour } = usePageTour("tasks");

  // Accordion state
  const [expandedTaskId, setExpandedTaskId] = useState<string | null>(null);
  const [expandedLines, setExpandedLines] = useState<POLineDetail[]>([]);
  const [expandLoading, setExpandLoading] = useState(false);

  // Per-line outcome state keyed by boonz_product_name (unique within a PO)
  const [lineOutcomes, setLineOutcomes] = useState<Record<string, Outcome>>({});
  const [lineQtys, setLineQtys] = useState<Record<string, number>>({});
  const [lineComments, setLineComments] = useState<Record<string, string>>({});

  const fetchTasks = useCallback(async () => {
    const supabase = createClient();

    const { data } = await supabase
      .from("driver_tasks")
      .select(
        `
        task_id,
        po_id,
        po_number,
        status,
        notes,
        is_forced,
        created_at,
        acknowledged_at,
        collected_at,
        suppliers!inner(supplier_name, procurement_type)
      `,
      )
      .order("created_at", { ascending: false });

    if (!data || data.length === 0) {
      setTasks([]);
      setLoading(false);
      return;
    }

    const mapped: DriverTask[] = data
      .filter((row) => {
        // Only show tasks for walk_in suppliers OR emergency-forced tasks
        const s = row.suppliers as unknown as { supplier_name: string; procurement_type: string };
        return s.procurement_type === "walk_in" || row.is_forced === true;
      })
      .map((row) => {
        const s = row.suppliers as unknown as { supplier_name: string; procurement_type: string };
        return {
          task_id: row.task_id,
          po_id: row.po_id,
          po_number: row.po_number,
          supplier_name: s.supplier_name,
          procurement_type: s.procurement_type as DriverTask["procurement_type"],
          is_forced: row.is_forced ?? false,
          status: row.status as DriverTask["status"],
          notes: row.notes,
          created_at: row.created_at,
          acknowledged_at: row.acknowledged_at,
          collected_at: row.collected_at,
        };
      });

    setTasks(mapped);
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchTasks();
  }, [fetchTasks]);

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") fetchTasks();
    }
    document.addEventListener("visibilitychange", handleVisibility);
    window.addEventListener("focus", fetchTasks);
    return () => {
      document.removeEventListener("visibilitychange", handleVisibility);
      window.removeEventListener("focus", fetchTasks);
    };
  }, [fetchTasks]);

  function resetLineState() {
    setLineOutcomes({});
    setLineQtys({});
    setLineComments({});
  }

  async function toggleExpand(task: DriverTask) {
    if (expandedTaskId === task.task_id) {
      setExpandedTaskId(null);
      setExpandedLines([]);
      resetLineState();
      return;
    }

    setExpandedTaskId(task.task_id);
    setExpandedLines([]);
    setExpandLoading(true);
    resetLineState();

    const supabase = createClient();
    console.log("[Tasks] fetching PO lines for po_id:", task.po_id);
    const { data, error } = await supabase
      .from("purchase_orders")
      .select(
        `
        po_line_id,
        po_id,
        ordered_qty,
        price_per_unit_aed,
        total_price_aed,
        boonz_product_id,
        boonz_products ( boonz_product_name )
      `,
      )
      .eq("po_id", task.po_id);

    console.log("[Tasks] PO lines result:", data, error);

    if (data) {
      const mapped: POLineDetail[] = data.map((row) => {
        const p = row.boonz_products as unknown as {
          boonz_product_name: string;
        } | null;
        return {
          po_line_id: row.po_line_id,
          boonz_product_name: p?.boonz_product_name ?? row.boonz_product_id,
          ordered_qty: row.ordered_qty ?? 0,
          price_per_unit_aed: row.price_per_unit_aed,
          total_price_aed: row.total_price_aed,
        };
      });
      setExpandedLines(mapped);
    }

    setExpandLoading(false);
  }

  async function acknowledge(taskId: string) {
    setUpdatingId(taskId);
    const supabase = createClient();
    await supabase
      .from("driver_tasks")
      .update({
        status: "acknowledged",
        acknowledged_at: new Date().toISOString(),
      })
      .eq("task_id", taskId);
    await fetchTasks();
    setUpdatingId(null);
  }

  function allLinesHaveOutcome(): boolean {
    if (expandedLines.length === 0) return false;
    return expandedLines.every((l) => !!lineOutcomes[l.po_line_id]);
  }

  async function markCollected(taskId: string) {
    if (!allLinesHaveOutcome()) return;

    setUpdatingId(taskId);

    // Build per-line detail for outcome_comment
    const lineDetail = expandedLines.map((l) => ({
      po_line_id: l.po_line_id,
      product_name: l.boonz_product_name,
      outcome: lineOutcomes[l.po_line_id],
      qty_purchased:
        lineOutcomes[l.po_line_id] === "purchased_partial"
          ? (lineQtys[l.po_line_id] ?? null)
          : null,
      comment: lineComments[l.po_line_id] || null,
    }));

    // Summary outcome: 'purchased_full' only if every line was full
    const summaryOutcome: Outcome = lineDetail.every(
      (l) => l.outcome === "purchased_full",
    )
      ? "purchased_full"
      : "purchased_partial";

    const supabase = createClient();
    await supabase
      .from("driver_tasks")
      .update({
        status: "collected",
        collected_at: new Date().toISOString(),
        outcome: summaryOutcome,
        outcome_qty: null,
        outcome_comment: JSON.stringify({ lines: lineDetail }),
      })
      .eq("task_id", taskId);

    setExpandedTaskId(null);
    resetLineState();
    await fetchTasks();
    setUpdatingId(null);
  }

  async function cancelTask(taskId: string) {
    if (!confirm("Cancel this task?")) return;

    setUpdatingId(taskId);
    const supabase = createClient();
    await supabase
      .from("driver_tasks")
      .update({
        status: "cancelled",
        outcome: "other" as const,
        outcome_comment: "Cancelled by driver",
      })
      .eq("task_id", taskId);

    setExpandedTaskId(null);
    resetLineState();
    await fetchTasks();
    setUpdatingId(null);
  }

  const pending = tasks.filter(
    (t) => t.status === "pending" || t.status === "acknowledged",
  );
  const completed = tasks.filter(
    (t) => t.status === "collected" || t.status === "cancelled",
  );

  if (loading) {
    return (
      <>
        <FieldHeader title="Tasks" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading tasks…</p>
        </div>
      </>
    );
  }

  return (
    <div className="px-4 py-4 pb-24">
      <FieldHeader title="Tasks" />
      {showTour && tourSteps.length > 0 && pending.length > 0 && (
        <Tour
          steps={tourSteps}
          onComplete={completeTour}
          onSkip={completeTour}
        />
      )}

      {/* Pending */}
      <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-neutral-500">
        Pending
      </h2>
      {pending.length === 0 ? (
        <p className="mb-6 text-sm text-neutral-400 text-center py-4">
          No tasks assigned yet
        </p>
      ) : (
        <ul className="mb-6 space-y-2">
          {pending.map((task, idx) => {
            const isExpanded = expandedTaskId === task.task_id;
            const canSubmit = isExpanded && allLinesHaveOutcome();

            return (
              <li
                key={task.task_id}
                {...(idx === 0 ? { "data-tour": "task-card" } : {})}
                className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950"
              >
                {/* Card header — tappable */}
                <div
                  className="cursor-pointer p-4"
                  onClick={() => toggleExpand(task)}
                >
                  <div className="flex items-start justify-between gap-2 mb-2">
                    <div className="min-w-0 flex-1">
                      <p className="text-sm font-semibold">
                        {task.supplier_name}
                        {task.is_forced && (
                          <span className="ml-2 rounded-full bg-amber-100 px-1.5 py-0.5 text-[10px] font-semibold text-amber-700 dark:bg-amber-900 dark:text-amber-300">
                            🚨 Emergency pick-up
                          </span>
                        )}
                      </p>
                      <p className="text-xs text-neutral-500">{task.po_id}</p>
                      <p className="text-xs text-neutral-400 mt-0.5">
                        {formatDateTime(task.created_at)}
                      </p>
                    </div>
                    <div className="flex items-center gap-2">
                      <StatusBadge status={task.status} />
                      <span className="text-xs text-neutral-400">
                        {isExpanded ? "▲" : "▼"}
                      </span>
                    </div>
                  </div>
                  {task.notes && (
                    <p className="text-sm text-neutral-600 dark:text-neutral-400">
                      {task.notes}
                    </p>
                  )}
                </div>

                {/* Collapsed: show acknowledge only */}
                {!isExpanded && task.status === "pending" && (
                  <div className="px-4 pb-4">
                    <button
                      onClick={() => acknowledge(task.task_id)}
                      disabled={updatingId === task.task_id}
                      className="w-full rounded-lg border border-blue-300 py-2 text-xs font-medium text-blue-700 transition-colors hover:bg-blue-50 disabled:opacity-50 dark:border-blue-700 dark:text-blue-400 dark:hover:bg-blue-950"
                    >
                      {updatingId === task.task_id
                        ? "Updating…"
                        : "Acknowledge"}
                    </button>
                  </div>
                )}

                {/* Expanded accordion — no inner max-height cap so long POs
                    (e.g. PO-2026-0423-UC with 27 lines) are fully scrollable
                    via the page scroll. Previously maxHeight:1200px + overflow-hidden
                    clipped the last ~18 products out of view. */}
                <div className={isExpanded ? "" : "hidden"}>
                  <div className="border-t border-neutral-100 px-4 pb-4 pt-3 dark:border-neutral-800">
                    {expandLoading ? (
                      <div className="space-y-2">
                        {[1, 2, 3].map((i) => (
                          <div
                            key={i}
                            className="h-10 animate-pulse rounded bg-neutral-100 dark:bg-neutral-800"
                          />
                        ))}
                      </div>
                    ) : (
                      <>
                        {/* Acknowledge inside accordion for pending */}
                        {task.status === "pending" && (
                          <button
                            onClick={() => acknowledge(task.task_id)}
                            disabled={updatingId === task.task_id}
                            className="mb-4 w-full rounded-lg border border-blue-300 py-2 text-xs font-medium text-blue-700 transition-colors hover:bg-blue-50 disabled:opacity-50 dark:border-blue-700 dark:text-blue-400 dark:hover:bg-blue-950"
                          >
                            {updatingId === task.task_id
                              ? "Updating…"
                              : "Acknowledge"}
                          </button>
                        )}

                        {/* Per-line outcome entry */}
                        <p className="text-xs font-semibold text-neutral-500 uppercase tracking-wide mb-3">
                          Confirm outcome per product
                        </p>

                        <div className="space-y-4">
                          {expandedLines.map((line) => {
                            const key = line.po_line_id;
                            const lineOutcome = lineOutcomes[key];

                            return (
                              <div
                                key={key}
                                className="rounded-lg border border-neutral-100 p-3 dark:border-neutral-800"
                              >
                                {/* Product info */}
                                <p className="text-sm font-semibold mb-0.5 truncate">
                                  {line.boonz_product_name}
                                </p>
                                <p className="text-xs text-neutral-500 mb-2">
                                  Ordered {line.ordered_qty}
                                  {line.price_per_unit_aed != null && (
                                    <>
                                      {" "}
                                      · {line.price_per_unit_aed.toFixed(
                                        2,
                                      )}{" "}
                                      AED/unit
                                    </>
                                  )}
                                  {line.total_price_aed != null && (
                                    <>
                                      {" "}
                                      · Total {line.total_price_aed.toFixed(
                                        2,
                                      )}{" "}
                                      AED
                                    </>
                                  )}
                                </p>

                                {/* Outcome pills */}
                                <div className="flex flex-wrap gap-1 mb-2">
                                  {OUTCOME_OPTIONS.map((opt) => (
                                    <button
                                      key={opt.value}
                                      onClick={() =>
                                        setLineOutcomes((prev) => ({
                                          ...prev,
                                          [key]: opt.value,
                                        }))
                                      }
                                      className={`rounded-full px-2 py-0.5 text-xs font-medium transition-colors ${
                                        lineOutcome === opt.value
                                          ? "bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900"
                                          : "bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700"
                                      }`}
                                    >
                                      {opt.icon} {opt.label}
                                    </button>
                                  ))}
                                </div>

                                {/* Partial qty */}
                                {lineOutcome === "purchased_partial" && (
                                  <input
                                    type="number"
                                    min={0}
                                    value={lineQtys[key] ?? ""}
                                    onChange={(e) =>
                                      setLineQtys((prev) => ({
                                        ...prev,
                                        [key]: e.target.value
                                          ? parseFloat(e.target.value)
                                          : 0,
                                      }))
                                    }
                                    placeholder="Qty purchased"
                                    className="mb-1.5 w-full rounded border border-neutral-300 px-2 py-1 text-xs placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
                                  />
                                )}

                                {/* Per-line comment */}
                                <input
                                  type="text"
                                  value={lineComments[key] ?? ""}
                                  onChange={(e) =>
                                    setLineComments((prev) => ({
                                      ...prev,
                                      [key]: e.target.value,
                                    }))
                                  }
                                  placeholder="Note (optional)"
                                  className="w-full rounded border border-neutral-200 px-2 py-1 text-xs placeholder:text-neutral-400 dark:border-neutral-700 dark:bg-neutral-900"
                                />
                              </div>
                            );
                          })}
                        </div>

                        {/* Action buttons */}
                        <div className="mt-4 space-y-2">
                          <button
                            onClick={() => markCollected(task.task_id)}
                            disabled={!canSubmit || updatingId === task.task_id}
                            className="w-full rounded-lg bg-neutral-900 py-2.5 text-xs font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-40 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
                          >
                            {updatingId === task.task_id
                              ? "Saving…"
                              : canSubmit
                                ? "Mark as collected"
                                : `Select outcome for all ${expandedLines.length} product${expandedLines.length !== 1 ? "s" : ""}`}
                          </button>
                          <button
                            onClick={() => cancelTask(task.task_id)}
                            disabled={updatingId === task.task_id}
                            className="w-full rounded-lg border border-red-300 py-2 text-xs font-medium text-red-600 transition-colors hover:bg-red-50 disabled:opacity-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950"
                          >
                            {updatingId === task.task_id
                              ? "Saving…"
                              : "Mark as cancelled"}
                          </button>
                        </div>
                      </>
                    )}
                  </div>
                </div>
              </li>
            );
          })}
        </ul>
      )}

      {/* Completed */}
      <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-neutral-500">
        Completed
      </h2>
      {completed.length === 0 ? (
        <p className="text-sm text-neutral-400 text-center py-4">
          No completed tasks
        </p>
      ) : (
        <ul className="space-y-2">
          {completed.map((task) => (
            <li
              key={task.task_id}
              className="rounded-lg border border-neutral-200 bg-white p-4 opacity-60 dark:border-neutral-800 dark:bg-neutral-950"
            >
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-semibold">{task.supplier_name}</p>
                  <p className="text-xs text-neutral-500">{task.po_id}</p>
                  <p className="text-xs text-neutral-400 mt-0.5">
                    {formatDateTime(task.created_at)}
                  </p>
                  {task.notes && (
                    <p className="text-xs text-neutral-500 mt-1">
                      {task.notes}
                    </p>
                  )}
                </div>
                <StatusBadge status={task.status} />
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
