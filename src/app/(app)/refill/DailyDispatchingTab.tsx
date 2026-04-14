"use client";

import { useEffect, useState, useMemo } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";

// ── Types ──────────────────────────────────────────────────────────────────────

interface DispatchLine {
  dispatch_id: string;
  machine_id: string;
  quantity: number | null;
  filled_quantity: number | null;
  packed: boolean;
  picked_up: boolean;
  dispatched: boolean;
  machines: {
    official_name: string;
    pod_location: string | null;
  };
}

interface MachineSummary {
  machine_id: string;
  official_name: string;
  pod_location: string | null;
  total: number;
  planned_qty: number;
  packed_count: number;
  picked_up_count: number;
  dispatched_count: number;
  filled_qty: number;
}

// ── Component ──────────────────────────────────────────────────────────────────

export function DailyDispatchingTab({
  selectedDate,
}: {
  selectedDate: string;
}) {
  const [lines, setLines] = useState<DispatchLine[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function load() {
      setLoading(true);
      const supabase = createClient();
      const today = getDubaiDate();
      const queryDate = selectedDate || today;

      const { data } = await supabase
        .from("refill_dispatching")
        .select(
          "dispatch_id, machine_id, quantity, filled_quantity, packed, picked_up, dispatched, machines!inner(official_name, pod_location)",
        )
        .eq("dispatch_date", queryDate)
        .eq("include", true)
        .limit(10000);

      setLines(
        (data ?? []).map((d) => ({
          ...d,
          machines: d.machines as unknown as {
            official_name: string;
            pod_location: string | null;
          },
        })),
      );
      setLoading(false);
    }
    load();
  }, [selectedDate]);

  // ── Aggregate by machine ─────────────────────────────────────────────────────

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
      } else {
        map.set(l.machine_id, {
          machine_id: l.machine_id,
          official_name: l.machines.official_name,
          pod_location: l.machines.pod_location,
          total: 1,
          planned_qty: qty,
          filled_qty: filled,
          packed_count: l.packed ? 1 : 0,
          picked_up_count: l.picked_up ? 1 : 0,
          dispatched_count: l.dispatched ? 1 : 0,
        });
      }
    }
    return Array.from(map.values()).sort((a, b) =>
      a.official_name.localeCompare(b.official_name),
    );
  }, [lines]);

  // ── Summary totals ────────────────────────────────────────────────────────────

  const totals = useMemo(
    () => ({
      totalLines: lines.length,
      totalMachines: machines.length,
      packed: lines.filter((l) => l.packed).length,
      pickedUp: lines.filter((l) => l.picked_up).length,
      dispatched: lines.filter((l) => l.dispatched).length,
    }),
    [lines, machines],
  );

  // ── Render ────────────────────────────────────────────────────────────────────

  const statCards = [
    { label: "Machines", value: totals.totalMachines, color: "#0a0a0a" },
    { label: "Lines Planned", value: totals.totalLines, color: "#0a0a0a" },
    { label: "Packed", value: totals.packed, color: "#24544a" },
    { label: "Picked Up", value: totals.pickedUp, color: "#1d4439" },
    { label: "Dispatched", value: totals.dispatched, color: "#e1b460" },
  ];

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
              {loading ? "—" : card.value}
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
        <table className="w-full text-sm">
          <thead>
            <tr style={{ borderBottom: "1px solid #e8e4de" }}>
              {[
                "Machine",
                "Location",
                "Lines",
                "Planned Qty",
                "Packed",
                "Picked Up",
                "Dispatched",
                "Progress",
                "",
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
                  {[200, 140, 60, 80, 60, 70, 80, 120, 60].map((w, j) => (
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
                  colSpan={9}
                  className="px-4 py-10 text-center"
                  style={{ color: "#6b6860" }}
                >
                  No dispatch lines for {selectedDate}.
                </td>
              </tr>
            ) : (
              machines.map((m) => {
                const dispatchPct =
                  m.total > 0
                    ? Math.round((m.dispatched_count / m.total) * 100)
                    : 0;
                const allDone = m.dispatched_count === m.total;
                const allPacked = m.packed_count === m.total;

                return (
                  <tr
                    key={m.machine_id}
                    style={{ borderBottom: "1px solid #f5f2ee" }}
                    onMouseEnter={(e) =>
                      ((
                        e.currentTarget as HTMLTableRowElement
                      ).style.background = "#faf9f7")
                    }
                    onMouseLeave={(e) =>
                      ((
                        e.currentTarget as HTMLTableRowElement
                      ).style.background = "transparent")
                    }
                  >
                    <td
                      className="px-4 py-3"
                      style={{ fontWeight: 600, color: "#24544a" }}
                    >
                      {m.official_name}
                    </td>
                    <td
                      className="px-4 py-3 max-w-[140px] truncate"
                      style={{ color: "#6b6860" }}
                      title={m.pod_location ?? undefined}
                    >
                      {m.pod_location ?? "—"}
                    </td>
                    <td
                      className="px-4 py-3"
                      style={{ color: "#0a0a0a", fontWeight: 600 }}
                    >
                      {m.total}
                    </td>
                    <td className="px-4 py-3" style={{ color: "#0a0a0a" }}>
                      {m.planned_qty}
                    </td>
                    <td className="px-4 py-3">
                      <span
                        style={{
                          color: allPacked ? "#24544a" : "#6b6860",
                          fontWeight: allPacked ? 700 : 400,
                        }}
                      >
                        {m.packed_count}/{m.total}
                      </span>
                    </td>
                    <td className="px-4 py-3" style={{ color: "#6b6860" }}>
                      {m.picked_up_count}/{m.total}
                    </td>
                    <td className="px-4 py-3">
                      <span
                        style={{
                          color: allDone ? "#24544a" : "#6b6860",
                          fontWeight: allDone ? 700 : 400,
                        }}
                      >
                        {m.dispatched_count}/{m.total}
                      </span>
                    </td>
                    <td className="px-4 py-3" style={{ minWidth: 120 }}>
                      <div
                        style={{
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
                      <span
                        style={{
                          fontSize: 11,
                          color: "#6b6860",
                          marginTop: 2,
                          display: "block",
                        }}
                      >
                        {dispatchPct}%
                      </span>
                    </td>
                    <td className="px-4 py-3">
                      <Link
                        href={`/field/dispatching/${m.machine_id}`}
                        style={{
                          fontSize: 12,
                          fontWeight: 600,
                          color: "#24544a",
                          textDecoration: "none",
                          border: "1px solid #24544a",
                          borderRadius: 6,
                          padding: "4px 10px",
                          display: "inline-block",
                          whiteSpace: "nowrap",
                        }}
                      >
                        Dispatch →
                      </Link>
                    </td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
