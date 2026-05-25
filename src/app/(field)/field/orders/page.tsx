"use client";

// B-6 — 2026-04-27: Orders list now shows driver task collection status alongside
// PO receiving status. "Pending" POs that the driver has already collected now
// show "In transit — collected by driver" rather than plain "Pending".

import { useEffect, useState, useCallback } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { FieldHeader } from "../../components/field-header";
import { EditPOLineDrawer } from "../../components/EditPOLineDrawer";
import { CancelPOLineDrawer } from "../../components/CancelPOLineDrawer";
import { POEditHistoryPill } from "../../components/POEditHistoryPill";

const EDIT_ROLES = new Set([
  "warehouse",
  "operator_admin",
  "superadmin",
  "manager",
]);

// ── Types ────────────────────────────────────────────────────────────────────

interface POGroup {
  po_id: string;
  supplier_name: string;
  purchase_date: string;
  line_count: number;
  total_ordered: number;
  total_received: number;
  received_date: string | null;
}

interface POLineDetail {
  po_line_id: string;
  boonz_product_name: string;
  ordered_qty: number;
  price_per_unit_aed: number | null;
  total_price_aed: number | null;
  expiry_date: string | null;
  // PRD-002: drive per-line lock + Cancel availability.
  received_qty: number | null;
  purchase_outcome: string | null;
}

// Driver task status keyed by po_id (B-6)
interface TaskStatus {
  status: "pending" | "acknowledged" | "collected" | "cancelled";
  outcome: string | null;
  collected_at: string | null;
}

type TabOption = "pending" | "all";

// ── Helpers ──────────────────────────────────────────────────────────────────

function formatDate(dateStr: string): string {
  const d = new Date(dateStr + "T00:00:00");
  return d.toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function CollectionBadge({ task }: { task: TaskStatus | undefined }) {
  if (!task) return null;

  switch (task.status) {
    case "acknowledged":
      return (
        <span className="rounded-full bg-blue-100 px-2 py-0.5 text-xs font-medium text-blue-800 dark:bg-blue-900 dark:text-blue-200">
          🚗 Driver on the way
        </span>
      );
    case "collected":
      return (
        <span className="rounded-full bg-indigo-100 px-2 py-0.5 text-xs font-medium text-indigo-800 dark:bg-indigo-900 dark:text-indigo-200">
          📦 In transit — awaiting WH receipt
        </span>
      );
    case "cancelled":
      return (
        <span className="rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-700 dark:bg-red-900 dark:text-red-300">
          ✗ Task cancelled
        </span>
      );
    default:
      return null;
  }
}

// ── Component ─────────────────────────────────────────────────────────────────

export default function OrdersPage() {
  const [orders, setOrders] = useState<POGroup[]>([]);
  const [taskMap, setTaskMap] = useState<Record<string, TaskStatus>>({});
  const [loading, setLoading] = useState(true);
  const [tab, setTab] = useState<TabOption>("pending");
  const [userRole, setUserRole] = useState<string | null>(null);
  const [editingPoId, setEditingPoId] = useState<string | null>(null);
  // PRD-002: per-line Cancel drawer state.
  const [cancellingLine, setCancellingLine] = useState<POLineDetail | null>(
    null,
  );
  const [refreshKey, setRefreshKey] = useState(0);
  const [expandedPoId, setExpandedPoId] = useState<string | null>(null);
  const [expandedLines, setExpandedLines] = useState<POLineDetail[]>([]);
  const [expandLoading, setExpandLoading] = useState(false);

  const fetchOrders = useCallback(async () => {
    const supabase = createClient();

    // Role check for Edit button visibility (PRD-001).
    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (user) {
      const { data: profile } = await supabase
        .from("user_profiles")
        .select("role")
        .eq("id", user.id)
        .single();
      setUserRole(profile?.role ?? null);
    }

    const { data: lines } = await supabase
      .from("purchase_orders")
      .select(
        `
        po_line_id,
        po_id,
        purchase_date,
        ordered_qty,
        received_qty,
        received_date,
        suppliers!inner(supplier_name)
      `,
      )
      .order("purchase_date", { ascending: false });

    if (!lines || lines.length === 0) {
      setOrders([]);
      setLoading(false);
      return;
    }

    // Group lines by po_id
    const grouped = new Map<string, POGroup>();
    for (const line of lines) {
      const s = line.suppliers as unknown as { supplier_name: string };
      const existing = grouped.get(line.po_id);
      const lineReceivedQty =
        (line.received_qty as number | null) ??
        (line.received_date ? (line.ordered_qty ?? 0) : 0);
      if (existing) {
        existing.line_count += 1;
        existing.total_ordered += line.ordered_qty ?? 0;
        existing.total_received += lineReceivedQty;
        if (!line.received_date) {
          existing.received_date = null;
        }
      } else {
        grouped.set(line.po_id, {
          po_id: line.po_id,
          supplier_name: s.supplier_name,
          purchase_date: line.purchase_date,
          line_count: 1,
          total_ordered: line.ordered_qty ?? 0,
          total_received: lineReceivedQty,
          received_date: line.received_date,
        });
      }
    }

    const result = Array.from(grouped.values()).sort((a, b) =>
      b.purchase_date.localeCompare(a.purchase_date),
    );

    setOrders(result);

    // B-6: Fetch driver task status for all POs so we can show collection state
    const poIds = result.map((o) => o.po_id);
    if (poIds.length > 0) {
      const { data: tasks } = await supabase
        .from("driver_tasks")
        .select("po_id, status, outcome, collected_at")
        .in("po_id", poIds);

      if (tasks) {
        const tm: Record<string, TaskStatus> = {};
        for (const t of tasks) {
          tm[t.po_id] = {
            status: t.status as TaskStatus["status"],
            outcome: t.outcome,
            collected_at: t.collected_at,
          };
        }
        setTaskMap(tm);
      }
    }

    setLoading(false);
  }, []);

  useEffect(() => {
    fetchOrders();
  }, [fetchOrders]);

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") fetchOrders();
    }
    document.addEventListener("visibilitychange", handleVisibility);
    window.addEventListener("focus", fetchOrders);
    return () => {
      document.removeEventListener("visibilitychange", handleVisibility);
      window.removeEventListener("focus", fetchOrders);
    };
  }, [fetchOrders]);

  async function toggleExpand(poId: string) {
    if (expandedPoId === poId) {
      setExpandedPoId(null);
      setExpandedLines([]);
      return;
    }

    setExpandedPoId(poId);
    setExpandedLines([]);
    setExpandLoading(true);

    const supabase = createClient();
    const { data } = await supabase
      .from("purchase_orders")
      .select(
        `
        po_line_id,
        ordered_qty,
        price_per_unit_aed,
        total_price_aed,
        expiry_date,
        received_qty,
        purchase_outcome,
        boonz_products!inner(boonz_product_name)
      `,
      )
      .eq("po_id", poId);

    if (data) {
      // PRD-002: stop deduplicating by product name. Each row is its own
      // actionable PO line (Edit / Cancel buttons need a stable po_line_id),
      // so we render one entry per po_line_id even when two batches of the
      // same product share a name.
      const mapped: POLineDetail[] = data.map((row) => {
        const p = row.boonz_products as unknown as {
          boonz_product_name: string;
        };
        return {
          po_line_id: row.po_line_id as string,
          boonz_product_name: p.boonz_product_name,
          ordered_qty: row.ordered_qty ?? 0,
          price_per_unit_aed: row.price_per_unit_aed,
          total_price_aed: row.total_price_aed,
          expiry_date: row.expiry_date,
          received_qty:
            row.received_qty != null ? Number(row.received_qty) : null,
          purchase_outcome: row.purchase_outcome ?? null,
        };
      });
      setExpandedLines(mapped);
    }

    setExpandLoading(false);
  }

  // Filter for pending tab: unreceived OR collected-but-not-WH-received
  const filtered =
    tab === "pending"
      ? orders.filter((o) => !o.received_date)
      : orders.slice(0, 30);

  if (loading) {
    return (
      <>
        <FieldHeader title="Purchase Orders" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading orders…</p>
        </div>
      </>
    );
  }

  return (
    <div className="px-4 py-4 pb-24">
      <FieldHeader title="Purchase Orders" />

      {/* Tabs */}
      <div className="mb-4 flex border-b border-neutral-200 dark:border-neutral-800">
        {[
          { label: "Pending", value: "pending" as TabOption },
          { label: "All orders", value: "all" as TabOption },
        ].map((t) => (
          <button
            key={t.value}
            onClick={() => {
              setTab(t.value);
              setExpandedPoId(null);
            }}
            className={`flex-1 py-2.5 text-sm font-medium transition-colors ${
              tab === t.value
                ? "border-b-2 border-neutral-900 text-neutral-900 dark:border-neutral-100 dark:text-neutral-100"
                : "text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300"
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {/* Orders */}
      {filtered.length === 0 ? (
        <div className="flex flex-col items-center justify-center p-8 text-center">
          <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
            {tab === "pending" ? "No pending orders" : "No orders found"}
          </p>
          <p className="mt-1 text-sm text-neutral-500">
            {tab === "pending"
              ? "All purchase orders have been received"
              : "Create your first PO"}
          </p>
        </div>
      ) : (
        <ul className="space-y-2">
          {filtered.map((order) => {
            const isExpanded = expandedPoId === order.po_id && tab === "all";
            const task = taskMap[order.po_id];

            return (
              <li key={order.po_id}>
                <div
                  className={`rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950 ${
                    tab === "all" ? "cursor-pointer" : ""
                  }`}
                  onClick={
                    tab === "all" ? () => toggleExpand(order.po_id) : undefined
                  }
                >
                  <div className="flex items-start justify-between gap-3 p-4">
                    <div className="min-w-0 flex-1">
                      <p className="text-base font-semibold truncate">
                        {order.po_id}
                      </p>
                      <p className="text-sm text-neutral-500">
                        {order.supplier_name}
                      </p>
                      <p className="text-xs text-neutral-400 mt-0.5">
                        {formatDate(order.purchase_date)} · {order.line_count}{" "}
                        {order.line_count === 1 ? "product" : "products"} ·{" "}
                        {order.total_ordered} units ordered
                      </p>
                      <div className="mt-1">
                        <POEditHistoryPill
                          poId={order.po_id}
                          refreshKey={refreshKey}
                        />
                      </div>
                    </div>
                    <div className="shrink-0 flex flex-col items-end gap-2">
                      {order.received_date ? (
                        order.total_received < order.total_ordered ? (
                          <span className="rounded-full bg-amber-100 px-2.5 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-900 dark:text-amber-200">
                            Partial · {order.total_received}/
                            {order.total_ordered} units
                          </span>
                        ) : (
                          <span className="rounded-full bg-green-100 px-2.5 py-0.5 text-xs font-medium text-green-800 dark:bg-green-900 dark:text-green-200">
                            Received {formatDate(order.received_date)}
                          </span>
                        )
                      ) : (
                        <>
                          {/* B-6: show collection state from driver_tasks */}
                          {task?.status === "collected" ||
                          task?.status === "acknowledged" ? (
                            <CollectionBadge task={task} />
                          ) : (
                            <span className="rounded-full bg-amber-100 px-2.5 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-900 dark:text-amber-200">
                              Pending
                            </span>
                          )}
                          {tab === "pending" && (
                            <div className="flex gap-1.5">
                              {userRole && EDIT_ROLES.has(userRole) && (
                                <button
                                  onClick={(e) => {
                                    e.stopPropagation();
                                    setEditingPoId(order.po_id);
                                  }}
                                  className="rounded-lg border border-neutral-300 px-3 py-1.5 text-xs font-medium text-neutral-700 transition-colors hover:bg-neutral-100 dark:border-neutral-600 dark:text-neutral-200 dark:hover:bg-neutral-900"
                                >
                                  Edit
                                </button>
                              )}
                              <Link
                                href={`/field/receiving/${encodeURIComponent(order.po_id)}`}
                                className="rounded-lg bg-neutral-900 px-3 py-1.5 text-xs font-medium text-white transition-colors hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
                              >
                                Receive
                              </Link>
                            </div>
                          )}
                        </>
                      )}
                      {tab === "all" && (
                        <span className="text-xs text-neutral-400">
                          {isExpanded ? "▲" : "▼"}
                        </span>
                      )}
                    </div>
                  </div>

                  {/* Expanded detail */}
                  <div
                    className="overflow-hidden transition-all duration-200"
                    style={{ maxHeight: isExpanded ? "600px" : "0px" }}
                  >
                    <div className="border-t border-neutral-100 px-4 pb-4 pt-3 dark:border-neutral-800">
                      {expandLoading ? (
                        <div className="space-y-2">
                          {[1, 2, 3].map((i) => (
                            <div
                              key={i}
                              className="h-6 animate-pulse rounded bg-neutral-100 dark:bg-neutral-800"
                            />
                          ))}
                        </div>
                      ) : (
                        <>
                          <table className="w-full text-xs">
                            <thead>
                              <tr className="text-left text-neutral-400">
                                <th className="pb-1 font-medium">Product</th>
                                <th className="pb-1 font-medium text-right">
                                  Qty
                                </th>
                                <th className="pb-1 font-medium text-right">
                                  Price
                                </th>
                                <th className="pb-1 font-medium text-right">
                                  Total
                                </th>
                                <th className="pb-1 font-medium text-right">
                                  Expiry
                                </th>
                                <th className="pb-1 font-medium text-right">
                                  {/* PRD-002: per-line actions */}
                                </th>
                              </tr>
                            </thead>
                            <tbody>
                              {expandedLines.map((line) => {
                                // PRD-002: per-line lock + Cancel gating.
                                const isReceived =
                                  (line.received_qty ?? 0) > 0 ||
                                  line.purchase_outcome === "received";
                                const isCancelled =
                                  line.purchase_outcome === "not_purchased";
                                const canCancelNow =
                                  !isReceived &&
                                  !isCancelled &&
                                  !!userRole &&
                                  EDIT_ROLES.has(userRole);
                                const showLock =
                                  isReceived &&
                                  !!userRole &&
                                  userRole !== "superadmin";
                                return (
                                  <tr
                                    key={line.po_line_id}
                                    className={`border-t border-neutral-50 dark:border-neutral-900 ${
                                      isCancelled
                                        ? "text-neutral-400 line-through"
                                        : ""
                                    }`}
                                  >
                                    <td className="py-1.5 pr-2 truncate max-w-[120px]">
                                      {line.boonz_product_name}
                                    </td>
                                    <td className="py-1.5 text-right">
                                      {line.ordered_qty}
                                    </td>
                                    <td className="py-1.5 text-right">
                                      {line.price_per_unit_aed != null
                                        ? `${line.price_per_unit_aed.toFixed(2)}`
                                        : "—"}
                                    </td>
                                    <td className="py-1.5 text-right">
                                      {line.total_price_aed != null
                                        ? `${line.total_price_aed.toFixed(2)}`
                                        : "—"}
                                    </td>
                                    <td className="py-1.5 text-right text-neutral-400">
                                      {line.expiry_date
                                        ? formatDate(line.expiry_date)
                                        : "—"}
                                    </td>
                                    <td className="py-1.5 pl-2 text-right">
                                      <div className="flex items-center justify-end gap-1.5">
                                        {showLock && (
                                          <span
                                            title="Received — only superadmin can edit"
                                            className="text-xs"
                                          >
                                            🔒
                                          </span>
                                        )}
                                        {isCancelled && (
                                          <span className="rounded-full bg-neutral-200 px-1.5 py-0.5 text-[10px] font-medium text-neutral-600 dark:bg-neutral-700 dark:text-neutral-300">
                                            Not received
                                          </span>
                                        )}
                                        {canCancelNow && (
                                          <button
                                            onClick={(e) => {
                                              e.stopPropagation();
                                              setCancellingLine(line);
                                            }}
                                            className="rounded border border-red-300 px-1.5 py-0.5 text-[10px] font-medium text-red-700 hover:bg-red-50 dark:border-red-700 dark:text-red-400 dark:hover:bg-red-950"
                                          >
                                            Cancel
                                          </button>
                                        )}
                                      </div>
                                    </td>
                                  </tr>
                                );
                              })}
                            </tbody>
                            <tfoot>
                              <tr className="border-t border-neutral-200 font-medium dark:border-neutral-700">
                                <td className="pt-1.5" colSpan={3}>
                                  Total
                                </td>
                                <td className="pt-1.5 text-right">
                                  {expandedLines
                                    .reduce(
                                      (sum, l) =>
                                        sum + (l.total_price_aed ?? 0),
                                      0,
                                    )
                                    .toFixed(2)}{" "}
                                  AED
                                </td>
                                <td colSpan={2} />
                              </tr>
                            </tfoot>
                          </table>

                          <div className="mt-3 flex gap-2">
                            {userRole && EDIT_ROLES.has(userRole) && (
                              <button
                                onClick={(e) => {
                                  e.stopPropagation();
                                  setEditingPoId(order.po_id);
                                }}
                                className="flex-1 rounded-lg border border-neutral-300 py-2 text-center text-xs font-medium text-neutral-700 transition-colors hover:bg-neutral-100 dark:border-neutral-600 dark:text-neutral-200 dark:hover:bg-neutral-900"
                              >
                                Edit
                              </button>
                            )}
                            {!order.received_date && (
                              <Link
                                href={`/field/receiving/${encodeURIComponent(order.po_id)}`}
                                onClick={(e) => e.stopPropagation()}
                                className="flex-1 rounded-lg bg-neutral-900 py-2 text-center text-xs font-medium text-white transition-colors hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
                              >
                                Receive
                              </Link>
                            )}
                          </div>
                        </>
                      )}
                    </div>
                  </div>
                </div>
              </li>
            );
          })}
        </ul>
      )}

      {/* FAB */}
      <Link
        href="/field/orders/new"
        className="fixed bottom-20 right-4 flex h-14 w-14 items-center justify-center rounded-full bg-neutral-900 text-2xl text-white shadow-lg transition-colors hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
      >
        +
      </Link>

      {/* PRD-001: Edit drawer. PRD-002: pass userRole so received lines are
          rendered read-only for non-superadmin callers. */}
      {editingPoId && (
        <EditPOLineDrawer
          poId={editingPoId}
          open={editingPoId !== null}
          onClose={() => setEditingPoId(null)}
          userRole={userRole}
          onSaved={() => {
            setRefreshKey((k) => k + 1);
            fetchOrders();
          }}
        />
      )}

      {/* PRD-002: per-line Cancel drawer */}
      {cancellingLine && (
        <CancelPOLineDrawer
          poLineId={cancellingLine.po_line_id}
          productName={cancellingLine.boonz_product_name}
          orderedQty={cancellingLine.ordered_qty}
          open={cancellingLine !== null}
          onClose={() => setCancellingLine(null)}
          onConfirmed={() => {
            setRefreshKey((k) => k + 1);
            fetchOrders();
            // refresh the expanded view so the cancelled line picks up its
            // not_purchased outcome immediately.
            if (expandedPoId) {
              const id = expandedPoId;
              setExpandedPoId(null);
              setTimeout(() => toggleExpand(id), 0);
            }
          }}
        />
      )}
    </div>
  );
}
