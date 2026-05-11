"use client";

import { useEffect, useState, useMemo, useCallback, Fragment } from "react";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";

// ── Types ──────────────────────────────────────────────────────────────────────

interface DispatchLine {
  dispatch_id: string;
  machine_id: string;
  boonz_product_id: string;
  action: string | null;
  quantity: number | null;
  filled_quantity: number | null;
  packed: boolean;
  picked_up: boolean;
  dispatched: boolean;
  expiry_date: string | null;
  shelf_code: string | null;
  machines: {
    official_name: string;
    pod_location: string | null;
    venue_group: string | null;
  };
  boonz_products: {
    boonz_product_name: string;
  } | null;
}

interface MachineSummary {
  machine_id: string;
  official_name: string;
  pod_location: string | null;
  venue_group: string | null;
  total: number;
  planned_qty: number;
  filled_qty: number;
  packed_count: number;
  picked_up_count: number;
  dispatched_count: number;
  lines: DispatchLine[];
}

type MachineStage = "pack" | "pickup" | "dispatch" | "complete";

// ── Helpers ────────────────────────────────────────────────────────────────────

function formatExpiry(dateStr: string): string {
  return new Date(dateStr + "T00:00:00").toLocaleDateString("en-GB", {
    day: "2-digit",
    month: "short",
    year: "2-digit",
  });
}

interface SliceRow {
  dispatch_id: string;
  qty: number;
  expiry_date: string | null;
}

interface LineGroup {
  key: string;
  shelf_code: string | null;
  boonz_product_name: string;
  action: string | null;
  plan_qty: number;
  total_filled: number;
  earliest_expiry: string | null;
  packed: boolean;
  picked_up: boolean;
  dispatched: boolean;
  slices: SliceRow[];
}

function buildSortedGroups(lines: DispatchLine[]): LineGroup[] {
  const groups = new Map<string, LineGroup>();
  for (const l of lines) {
    const key = `${l.shelf_code ?? ""}|${l.boonz_product_id}|${l.action ?? ""}`;
    const qty = Number(l.quantity ?? 0);
    const filled = Number(l.filled_quantity ?? 0);
    const existing = groups.get(key);
    if (!existing) {
      groups.set(key, {
        key,
        shelf_code: l.shelf_code ?? null,
        boonz_product_name: l.boonz_products?.boonz_product_name ?? "\u2014",
        action: l.action,
        plan_qty: qty,
        total_filled: filled,
        earliest_expiry: l.expiry_date,
        packed: l.packed ?? false,
        picked_up: l.picked_up ?? false,
        dispatched: l.dispatched ?? false,
        slices: [
          {
            dispatch_id: l.dispatch_id,
            qty: filled || qty,
            expiry_date: l.expiry_date,
          },
        ],
      });
    } else {
      existing.plan_qty = Math.max(existing.plan_qty, qty);
      existing.total_filled += filled;
      if (
        l.expiry_date &&
        (!existing.earliest_expiry || l.expiry_date < existing.earliest_expiry)
      ) {
        existing.earliest_expiry = l.expiry_date;
      }
      existing.packed = existing.packed && (l.packed ?? false);
      existing.picked_up = existing.picked_up && (l.picked_up ?? false);
      existing.dispatched = existing.dispatched && (l.dispatched ?? false);
      existing.slices.push({
        dispatch_id: l.dispatch_id,
        qty: filled || qty,
        expiry_date: l.expiry_date,
      });
    }
  }

  const sorted = Array.from(groups.values()).sort((a, b) => {
    if (a.shelf_code == null && b.shelf_code == null) return 0;
    if (a.shelf_code == null) return 1;
    if (b.shelf_code == null) return -1;
    return a.shelf_code.localeCompare(b.shelf_code);
  });

  for (const g of sorted) {
    g.slices.sort((a, b) => {
      if (a.expiry_date == null && b.expiry_date == null) return 0;
      if (a.expiry_date == null) return 1;
      if (b.expiry_date == null) return -1;
      return a.expiry_date.localeCompare(b.expiry_date);
    });
  }

  return sorted;
}

function getMachineStage(m: MachineSummary): MachineStage {
  if (m.packed_count < m.total) return "pack";
  if (m.picked_up_count < m.total) return "pickup";
  if (m.dispatched_count < m.total) return "dispatch";
  return "complete";
}

// ── Component ──────────────────────────────────────────────────────────────────

export function DailyDispatchingTab({
  selectedDate,
}: {
  selectedDate: string;
}) {
  const [lines, setLines] = useState<DispatchLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [expandedMachines, setExpandedMachines] = useState<Set<string>>(
    new Set(),
  );
  const [updatingMachine, setUpdatingMachine] = useState<string | null>(null);

  const queryDate = selectedDate || getDubaiDate();

  // ── Fetch ──────────────────────────────────────────────────────────────────

  const fetchData = useCallback(async () => {
    const supabase = createClient();
    const { data } = await supabase
      .from("refill_dispatching")
      .select(
        "dispatch_id, machine_id, boonz_product_id, action, quantity, filled_quantity, packed, picked_up, dispatched, expiry_date, machines!inner(official_name, pod_location, venue_group), boonz_products(boonz_product_name), shelf_configurations!inner(shelf_code)",
      )
      .eq("dispatch_date", queryDate)
      .eq("include", true)
      .limit(10000);

    setLines(
      (data ?? []).map((d) => {
        const shelf = d.shelf_configurations as unknown as {
          shelf_code: string | null;
        } | null;
        return {
          ...d,
          shelf_code: shelf?.shelf_code ?? null,
          machines: d.machines as unknown as DispatchLine["machines"],
          boonz_products:
            d.boonz_products as unknown as DispatchLine["boonz_products"],
        };
      }),
    );
    setLoading(false);
  }, [queryDate]);

  useEffect(() => {
    setLoading(true);
    fetchData();
  }, [fetchData]);

  // ── Aggregate by machine ─────────────────────────────────────────────────

  const machines = useMemo<MachineSummary[]>(() => {
    const map = new Map<string, MachineSummary>();
    for (const l of lines) {
      const existing = map.get(l.machine_id);
      const qty = l.quantity ?? 0;
      const filled = l.filled_quantity ?? 0;
      if (existing) {
        existing.total += 1;
        existing.planned_qty += qty;
        existing.filled_qty += filled;
        if (l.packed) existing.packed_count += 1;
        if (l.picked_up) existing.picked_up_count += 1;
        if (l.dispatched) existing.dispatched_count += 1;
        existing.lines.push(l);
      } else {
        map.set(l.machine_id, {
          machine_id: l.machine_id,
          official_name: l.machines.official_name,
          pod_location: l.machines.pod_location,
          venue_group: l.machines.venue_group,
          total: 1,
          planned_qty: qty,
          filled_qty: filled,
          packed_count: l.packed ? 1 : 0,
          picked_up_count: l.picked_up ? 1 : 0,
          dispatched_count: l.dispatched ? 1 : 0,
          lines: [l],
        });
      }
    }
    return Array.from(map.values()).sort((a, b) =>
      a.official_name.localeCompare(b.official_name),
    );
  }, [lines]);

  // ── Summary totals (machine-level) ───────────────────────────────────────

  const totals = useMemo(() => {
    const totalMachines = machines.length;
    const packedMachines = machines.filter(
      (m) => m.packed_count === m.total,
    ).length;
    const pickedUpMachines = machines.filter(
      (m) => m.picked_up_count === m.total,
    ).length;
    const dispatchedMachines = machines.filter(
      (m) => m.dispatched_count === m.total,
    ).length;
    return {
      totalLines: lines.length,
      totalMachines,
      packedMachines,
      pickedUpMachines,
      dispatchedMachines,
    };
  }, [lines, machines]);

  // ── Toggle expand ────────────────────────────────────────────────────────

  function toggleExpand(machineId: string) {
    setExpandedMachines((prev) => {
      const next = new Set(prev);
      if (next.has(machineId)) next.delete(machineId);
      else next.add(machineId);
      return next;
    });
  }

  // ── Bulk update handler ──────────────────────────────────────────────────

  async function handleBulkUpdate(
    machineId: string,
    field: "packed" | "picked_up" | "dispatched",
  ) {
    setUpdatingMachine(machineId);
    try {
      const supabase = createClient();
      // Build the update payload: set the target field and all preceding fields to true
      const updatePayload: Record<string, boolean> = {};
      if (field === "packed") {
        updatePayload.packed = true;
      } else if (field === "picked_up") {
        updatePayload.packed = true;
        updatePayload.picked_up = true;
      } else if (field === "dispatched") {
        updatePayload.packed = true;
        updatePayload.picked_up = true;
        updatePayload.dispatched = true;
      }

      await supabase
        .from("refill_dispatching")
        .update(updatePayload)
        .eq("machine_id", machineId)
        .eq("dispatch_date", queryDate)
        .eq("include", true);

      // B2: when admin marks all dispatched, also materialize inventory —
      // pod_inventory rows + return any underfilled units back to WH.
      if (field === "dispatched") {
        const { error: rpcErr } = await supabase.rpc(
          "receive_all_dispatches_for_machine",
          {
            p_machine_id: machineId,
            p_dispatch_date: queryDate,
          },
        );
        if (rpcErr) {
          console.error(
            "[DailyDispatching] receive_all_dispatches_for_machine error:",
            rpcErr,
          );
        }
      }

      await fetchData();
    } finally {
      setUpdatingMachine(null);
    }
  }

  // ── Render helpers ───────────────────────────────────────────────────────

  function renderActionButton(m: MachineSummary) {
    const stage = getMachineStage(m);
    const isUpdating = updatingMachine === m.machine_id;

    if (stage === "complete") {
      return (
        <span
          style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 4,
            fontSize: 12,
            fontWeight: 700,
            color: "#24544a",
            background: "rgba(36, 84, 74, 0.08)",
            borderRadius: 6,
            padding: "5px 12px",
          }}
        >
          <span style={{ fontSize: 14 }}>&#10003;</span> Complete
        </span>
      );
    }

    const config: Record<
      Exclude<MachineStage, "complete">,
      {
        label: string;
        field: "packed" | "picked_up" | "dispatched";
        bg: string;
        border: string;
        color: string;
      }
    > = {
      pack: {
        label: "Mark All Packed",
        field: "packed",
        bg: "#24544a",
        border: "#24544a",
        color: "#ffffff",
      },
      pickup: {
        label: "Mark All Picked Up",
        field: "picked_up",
        bg: "#ffffff",
        border: "#24544a",
        color: "#24544a",
      },
      dispatch: {
        label: "Mark All Dispatched",
        field: "dispatched",
        bg: "#e1b460",
        border: "#e1b460",
        color: "#0a0a0a",
      },
    };

    const c = config[stage];

    return (
      <button
        disabled={isUpdating}
        onClick={(e) => {
          e.stopPropagation();
          handleBulkUpdate(m.machine_id, c.field);
        }}
        style={{
          fontSize: 12,
          fontWeight: 600,
          fontFamily: "'Plus Jakarta Sans', sans-serif",
          color: c.color,
          background: c.bg,
          border: `1px solid ${c.border}`,
          borderRadius: 6,
          padding: "5px 12px",
          cursor: isUpdating ? "wait" : "pointer",
          opacity: isUpdating ? 0.6 : 1,
          whiteSpace: "nowrap",
          transition: "opacity 0.15s ease",
        }}
      >
        {isUpdating ? "Updating..." : c.label}
      </button>
    );
  }

  function renderStatusIcon(value: boolean) {
    return (
      <span
        style={{
          fontSize: 13,
          fontWeight: 700,
          color: value ? "#24544a" : "#d0cdc7",
        }}
      >
        {value ? "\u2713" : "\u2014"}
      </span>
    );
  }

  // ── Stat cards ─────────────────────────────────────────────────────────────

  const statCards = [
    { label: "Machines", value: totals.totalMachines, color: "#0a0a0a" },
    { label: "Lines", value: totals.totalLines, color: "#0a0a0a" },
    {
      label: "Packed",
      value: `${totals.packedMachines}/${totals.totalMachines}`,
      color: "#24544a",
    },
    {
      label: "Picked Up",
      value: `${totals.pickedUpMachines}/${totals.totalMachines}`,
      color: "#1d4439",
    },
    {
      label: "Dispatched",
      value: `${totals.dispatchedMachines}/${totals.totalMachines}`,
      color: "#e1b460",
    },
  ];

  // ── Main render ────────────────────────────────────────────────────────────

  return (
    <div>
      {/* Stat cards */}
      <div
        className="grid gap-4 mb-6"
        style={{ gridTemplateColumns: "repeat(auto-fill, minmax(160px, 1fr))" }}
      >
        {statCards.map((card) => (
          <div
            key={card.label}
            style={{
              background: "white",
              border: "1px solid #e8e4de",
              borderLeft: `4px solid ${card.color}`,
              borderRadius: 12,
              padding: "16px 20px",
            }}
          >
            <p
              style={{
                fontSize: 11,
                fontWeight: 500,
                letterSpacing: "0.06em",
                textTransform: "uppercase",
                color: "#6b6860",
                marginBottom: 6,
              }}
            >
              {card.label}
            </p>
            <p
              style={{
                fontSize: 28,
                fontWeight: 800,
                fontFamily: "'Plus Jakarta Sans', sans-serif",
                letterSpacing: "-0.02em",
                color: card.color,
                margin: 0,
              }}
            >
              {loading ? "\u2014" : card.value}
            </p>
          </div>
        ))}
      </div>

      {/* Machine table */}
      <div
        style={{
          background: "white",
          border: "1px solid #e8e4de",
          borderRadius: 12,
          overflow: "hidden",
        }}
      >
        <table
          className="w-full text-sm"
          style={{ borderCollapse: "collapse" }}
        >
          <thead>
            <tr style={{ borderBottom: "1px solid #e8e4de" }}>
              {[
                "Machine",
                "Location",
                "Group",
                "Lines",
                "Planned",
                "Progress",
                "Action",
              ].map((h) => (
                <th
                  key={h}
                  className="text-left px-4 py-3"
                  style={{
                    fontSize: 11,
                    fontWeight: 500,
                    letterSpacing: "0.06em",
                    textTransform: "uppercase",
                    color: "#6b6860",
                  }}
                >
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {loading ? (
              Array.from({ length: 6 }).map((_, i) => (
                <tr key={i} style={{ borderBottom: "1px solid #f5f2ee" }}>
                  {[200, 140, 100, 60, 80, 140, 120].map((w, j) => (
                    <td key={j} className="px-4 py-3">
                      <div
                        className="animate-pulse rounded"
                        style={{ height: 14, width: w, background: "#f0ede8" }}
                      />
                    </td>
                  ))}
                </tr>
              ))
            ) : machines.length === 0 ? (
              <tr>
                <td
                  colSpan={7}
                  className="px-4 py-10 text-center"
                  style={{ color: "#6b6860" }}
                >
                  No dispatch lines for {queryDate}.
                </td>
              </tr>
            ) : (
              machines.map((m) => {
                const isExpanded = expandedMachines.has(m.machine_id);
                // 3-stage progress: pack + pickup + dispatch each contribute 1/3
                // of the bar. e.g. all packed + all picked up + none dispatched = ~66%.
                const dispatchPct =
                  m.total > 0
                    ? Math.round(
                        ((m.packed_count +
                          m.picked_up_count +
                          m.dispatched_count) /
                          (m.total * 3)) *
                          100,
                      )
                    : 0;
                const allDone = m.dispatched_count === m.total;

                return (
                  <MachineRow
                    key={m.machine_id}
                    machine={m}
                    isExpanded={isExpanded}
                    dispatchPct={dispatchPct}
                    allDone={allDone}
                    onToggle={() => toggleExpand(m.machine_id)}
                    actionButton={renderActionButton(m)}
                    renderStatusIcon={renderStatusIcon}
                  />
                );
              })
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// ── Machine Row Sub-Component ──────────────────────────────────────────────────

function MachineRow({
  machine: m,
  isExpanded,
  dispatchPct,
  allDone,
  onToggle,
  actionButton,
  renderStatusIcon,
}: {
  machine: MachineSummary;
  isExpanded: boolean;
  dispatchPct: number;
  allDone: boolean;
  onToggle: () => void;
  actionButton: React.ReactNode;
  renderStatusIcon: (v: boolean) => React.ReactNode;
}) {
  return (
    <>
      {/* Main machine row */}
      <tr
        onClick={onToggle}
        style={{
          borderBottom: isExpanded ? "none" : "1px solid #f5f2ee",
          cursor: "pointer",
          transition: "background 0.1s ease",
        }}
        onMouseEnter={(e) =>
          ((e.currentTarget as HTMLTableRowElement).style.background =
            "#faf9f7")
        }
        onMouseLeave={(e) =>
          ((e.currentTarget as HTMLTableRowElement).style.background =
            "transparent")
        }
      >
        <td className="px-4 py-3" style={{ fontWeight: 600, color: "#24544a" }}>
          <span
            style={{ display: "inline-flex", alignItems: "center", gap: 8 }}
          >
            <span
              style={{
                display: "inline-block",
                width: 16,
                fontSize: 10,
                color: "#6b6860",
                transition: "transform 0.15s ease",
                transform: isExpanded ? "rotate(90deg)" : "rotate(0deg)",
              }}
            >
              &#9654;
            </span>
            {m.official_name}
          </span>
        </td>
        <td
          className="px-4 py-3 max-w-[140px] truncate"
          style={{ color: "#6b6860" }}
          title={m.pod_location ?? undefined}
        >
          {m.pod_location ?? "\u2014"}
        </td>
        <td
          className="px-4 py-3 max-w-[100px] truncate"
          style={{ color: "#6b6860", fontSize: 12 }}
          title={m.venue_group ?? undefined}
        >
          {m.venue_group ?? "\u2014"}
        </td>
        <td className="px-4 py-3" style={{ color: "#0a0a0a", fontWeight: 600 }}>
          {m.total}
        </td>
        <td className="px-4 py-3" style={{ color: "#0a0a0a" }}>
          {m.planned_qty}
        </td>
        <td className="px-4 py-3" style={{ minWidth: 140 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <div
              style={{
                flex: 1,
                height: 6,
                background: "#f0ede8",
                borderRadius: 3,
                overflow: "hidden",
              }}
            >
              <div
                style={{
                  height: "100%",
                  width: `${dispatchPct}%`,
                  background: allDone ? "#24544a" : "#e1b460",
                  borderRadius: 3,
                  transition: "width 0.3s ease",
                }}
              />
            </div>
            <span style={{ fontSize: 11, color: "#6b6860", minWidth: 32 }}>
              {dispatchPct}%
            </span>
          </div>
          <div
            style={{
              display: "flex",
              gap: 12,
              marginTop: 4,
              fontSize: 11,
              color: "#6b6860",
            }}
          >
            <span>
              P {m.packed_count}/{m.total}
            </span>
            <span>
              U {m.picked_up_count}/{m.total}
            </span>
            <span>
              D {m.dispatched_count}/{m.total}
            </span>
          </div>
        </td>
        <td className="px-4 py-3">{actionButton}</td>
      </tr>

      {/* Expanded detail rows */}
      {isExpanded && (
        <tr style={{ borderBottom: "1px solid #f5f2ee" }}>
          <td colSpan={7} style={{ padding: 0 }}>
            <div
              style={{
                background: "#faf9f7",
                borderTop: "1px solid #e8e4de",
                borderBottom: "1px solid #e8e4de",
                padding: "0 16px",
              }}
            >
              <table
                className="w-full text-sm"
                style={{ borderCollapse: "collapse" }}
              >
                <thead>
                  <tr>
                    {[
                      "Product",
                      "Action",
                      "Qty",
                      "Filled",
                      "Expiry",
                      "Packed",
                      "Picked Up",
                      "Dispatched",
                    ].map((h) => (
                      <th
                        key={h}
                        className="text-left px-3 py-2"
                        style={{
                          fontSize: 10,
                          fontWeight: 500,
                          letterSpacing: "0.06em",
                          textTransform: "uppercase",
                          color: "#6b6860",
                          borderBottom: "1px solid #e8e4de",
                        }}
                      >
                        {h}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {buildSortedGroups(m.lines).map((g) => (
                    <Fragment key={g.key}>
                      <tr style={{ borderBottom: "1px solid #f0ede8" }}>
                        <td
                          className="px-3 py-2"
                          style={{ color: "#0a0a0a", fontWeight: 500 }}
                        >
                          {g.shelf_code && (
                            <span
                              style={{
                                display: "inline-block",
                                marginRight: 8,
                                padding: "2px 6px",
                                fontSize: 11,
                                fontFamily:
                                  "ui-monospace, SFMono-Regular, Menlo, monospace",
                                color: "#6b6860",
                                background: "#f0ede8",
                                borderRadius: 4,
                              }}
                            >
                              {g.shelf_code}
                            </span>
                          )}
                          {g.boonz_product_name}
                        </td>
                        <td className="px-3 py-2" style={{ color: "#6b6860" }}>
                          <span
                            style={{
                              fontSize: 11,
                              fontWeight: 600,
                              padding: "2px 6px",
                              borderRadius: 4,
                              background:
                                g.action === "refill"
                                  ? "rgba(36, 84, 74, 0.08)"
                                  : g.action === "collect"
                                    ? "rgba(225, 180, 96, 0.15)"
                                    : "transparent",
                              color:
                                g.action === "refill"
                                  ? "#24544a"
                                  : g.action === "collect"
                                    ? "#b08930"
                                    : "#6b6860",
                            }}
                          >
                            {g.action ?? "\u2014"}
                          </span>
                        </td>
                        <td
                          className="px-3 py-2"
                          style={{ color: "#0a0a0a", fontWeight: 600 }}
                        >
                          {g.plan_qty}
                        </td>
                        <td className="px-3 py-2" style={{ color: "#6b6860" }}>
                          {g.total_filled}/{g.plan_qty}
                        </td>
                        <td
                          className="px-3 py-2"
                          style={{ color: "#6b6860", fontSize: 12 }}
                        >
                          {g.earliest_expiry
                            ? formatExpiry(g.earliest_expiry)
                            : "\u2014"}
                        </td>
                        <td className="px-3 py-2 text-center">
                          {renderStatusIcon(g.packed)}
                        </td>
                        <td className="px-3 py-2 text-center">
                          {renderStatusIcon(g.picked_up)}
                        </td>
                        <td className="px-3 py-2 text-center">
                          {renderStatusIcon(g.dispatched)}
                        </td>
                      </tr>
                      {g.slices.length > 1 &&
                        g.slices.map((s, idx) => (
                          <tr
                            key={`${g.key}-slice-${idx}`}
                            style={{
                              borderBottom: "1px solid #f0ede8",
                              fontSize: 12,
                              color: "#6b6860",
                            }}
                          >
                            <td
                              className="px-3 py-1"
                              style={{ paddingLeft: 40 }}
                              colSpan={2}
                            >
                              <span style={{ marginRight: 8 }}>&#8627;</span>
                              &#215;{s.qty}
                            </td>
                            <td className="px-3 py-1" colSpan={2}>
                              {s.expiry_date
                                ? formatExpiry(s.expiry_date)
                                : "No expiry"}
                            </td>
                            <td colSpan={4} />
                          </tr>
                        ))}
                    </Fragment>
                  ))}
                </tbody>
              </table>
            </div>
          </td>
        </tr>
      )}
    </>
  );
}
