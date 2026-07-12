"use client";

// PRD-087 — Refill Log: the historical trace of everything dispatched.
// Reads refill_dispatching directly (no writes), grouped date → machine,
// with outcome badges per line so any past refill can be audited: what was
// planned, what was packed, what reached the machine, what came back.

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { Badge, type BadgeTone } from "@/components/ui/primitives";

const font = "'Plus Jakarta Sans', sans-serif";

type LogRow = {
  dispatch_id: string;
  machine_id: string;
  dispatch_date: string;
  action: string | null;
  quantity: number;
  filled_quantity: number | null;
  boonz_product_id: string | null;
  pod_product_id: string | null;
  packed: boolean;
  dispatched: boolean;
  returned: boolean | null;
  return_reason: string | null;
  skipped: boolean | null;
  skip_reason: string | null;
  cancelled: boolean | null;
  pack_outcome: string | null;
  not_filled_reason: string | null;
  comment: string | null;
  source_origin: string | null;
  is_m2m: boolean | null;
  last_edited_by_role: string | null;
  edit_count: number | null;
};

type Outcome =
  | "dispatched"
  | "packed"
  | "not_filled"
  | "returned"
  | "skipped"
  | "cancelled"
  | "pending";

function outcomeOf(r: LogRow): Outcome {
  if (r.cancelled) return "cancelled";
  if (r.skipped) return "skipped";
  if (r.returned) return "returned";
  if (r.pack_outcome === "not_filled" || r.not_filled_reason)
    return "not_filled";
  if (r.dispatched) return "dispatched";
  if (r.packed) return "packed";
  return "pending";
}

const OUTCOME_META: Record<Outcome, { label: string; tone: BadgeTone }> = {
  dispatched: { label: "dispatched", tone: "success" },
  packed: { label: "packed", tone: "gold" },
  not_filled: { label: "not filled", tone: "warn" },
  returned: { label: "returned", tone: "danger" },
  skipped: { label: "skipped", tone: "muted" },
  cancelled: { label: "cancelled", tone: "muted" },
  pending: { label: "pending", tone: "brand" },
};

const RANGES = [7, 14, 30, 90, 180] as const;

export default function RefillLogTab() {
  const [rowsOrNull, setRows] = useState<LogRow[] | null>(null);
  const [machineNames, setMachineNames] = useState<Record<string, string>>({});
  const [productNames, setProductNames] = useState<Record<string, string>>({});
  const [podNames, setPodNames] = useState<Record<string, string>>({});
  const [err, setErr] = useState<string | null>(null);
  const [days, setDays] = useState<number>(30);
  const [machineFilter, setMachineFilter] = useState("all");
  const [outcomeFilter, setOutcomeFilter] = useState<"all" | Outcome>("all");
  const [search, setSearch] = useState("");

  const loading = rowsOrNull === null;
  const rows = useMemo(() => rowsOrNull ?? [], [rowsOrNull]);

  // name maps (small tables, one fetch)
  useEffect(() => {
    const supabase = createClient();
    supabase
      .from("machines")
      .select("machine_id, official_name")
      .limit(10000)
      .then(({ data }) => {
        const m: Record<string, string> = {};
        (data ?? []).forEach(
          (r: { machine_id: string; official_name: string | null }) => {
            m[r.machine_id] = r.official_name ?? r.machine_id.slice(0, 8);
          },
        );
        setMachineNames(m);
      });
    supabase
      .from("boonz_products")
      .select("product_id, boonz_product_name")
      .limit(10000)
      .then(({ data }) => {
        const m: Record<string, string> = {};
        (data ?? []).forEach(
          (r: { product_id: string; boonz_product_name: string }) => {
            m[r.product_id] = r.boonz_product_name;
          },
        );
        setProductNames(m);
      });
    supabase
      .from("pod_products")
      .select("pod_product_id, pod_product_name")
      .limit(10000)
      .then(({ data }) => {
        const m: Record<string, string> = {};
        (data ?? []).forEach(
          (r: { pod_product_id: string; pod_product_name: string }) => {
            m[r.pod_product_id] = r.pod_product_name;
          },
        );
        setPodNames(m);
      });
  }, []);

  // log rows for the window
  useEffect(() => {
    let alive = true;
    const supabase = createClient();
    const from = new Date();
    from.setDate(from.getDate() - days);
    supabase
      .from("refill_dispatching")
      .select(
        "dispatch_id, machine_id, dispatch_date, action, quantity, filled_quantity, boonz_product_id, pod_product_id, packed, dispatched, returned, return_reason, skipped, skip_reason, cancelled, pack_outcome, not_filled_reason, comment, source_origin, is_m2m, last_edited_by_role, edit_count",
      )
      .gte("dispatch_date", from.toISOString().slice(0, 10))
      .order("dispatch_date", { ascending: false })
      .limit(10000)
      .then(({ data, error }) => {
        if (!alive) return;
        if (error) {
          setErr(error.message);
          setRows([]);
        } else {
          setErr(null);
          setRows((data as LogRow[]) ?? []);
        }
      });
    return () => {
      alive = false;
    };
  }, [days]);

  const machinesInLog = useMemo(() => {
    const s = new Set(rows.map((r) => r.machine_id));
    return [...s]
      .map((id) => ({ id, name: machineNames[id] ?? id.slice(0, 8) }))
      .sort((a, b) => a.name.localeCompare(b.name));
  }, [rows, machineNames]);

  const visible = useMemo(() => {
    const q = search.trim().toLowerCase();
    return rows.filter((r) => {
      if (machineFilter !== "all" && r.machine_id !== machineFilter)
        return false;
      if (outcomeFilter !== "all" && outcomeOf(r) !== outcomeFilter)
        return false;
      if (q) {
        const prod =
          (r.boonz_product_id ? productNames[r.boonz_product_id] : "") ||
          (r.pod_product_id ? podNames[r.pod_product_id] : "") ||
          "";
        const hay =
          `${prod} ${machineNames[r.machine_id] ?? ""} ${r.comment ?? ""} ${r.action ?? ""}`.toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });
  }, [
    rows,
    machineFilter,
    outcomeFilter,
    search,
    productNames,
    podNames,
    machineNames,
  ]);

  // date -> machine -> rows
  const grouped = useMemo(() => {
    const byDate = new Map<string, Map<string, LogRow[]>>();
    visible.forEach((r) => {
      if (!byDate.has(r.dispatch_date)) byDate.set(r.dispatch_date, new Map());
      const m = byDate.get(r.dispatch_date)!;
      if (!m.has(r.machine_id)) m.set(r.machine_id, []);
      m.get(r.machine_id)!.push(r);
    });
    return byDate;
  }, [visible]);

  const stats = useMemo(() => {
    const s: Record<Outcome, number> = {
      dispatched: 0,
      packed: 0,
      not_filled: 0,
      returned: 0,
      skipped: 0,
      cancelled: 0,
      pending: 0,
    };
    visible.forEach((r) => s[outcomeOf(r)]++);
    return s;
  }, [visible]);

  return (
    <div className="p-6" style={{ fontFamily: font }}>
      {/* Controls */}
      <div className="flex items-center gap-3 flex-wrap mb-4">
        <select
          value={days}
          onChange={(e) => {
            setDays(Number(e.target.value));
            setRows(null);
          }}
          style={{
            padding: "7px 10px",
            fontSize: 13,
            border: "1px solid var(--line)",
            borderRadius: 8,
            background: "var(--surface)",
            fontFamily: font,
          }}
        >
          {RANGES.map((d) => (
            <option key={d} value={d}>
              Last {d} days
            </option>
          ))}
        </select>
        <select
          value={machineFilter}
          onChange={(e) => setMachineFilter(e.target.value)}
          style={{
            padding: "7px 10px",
            fontSize: 13,
            border: "1px solid var(--line)",
            borderRadius: 8,
            background: "var(--surface)",
            fontFamily: font,
            maxWidth: 220,
          }}
        >
          <option value="all">All machines</option>
          {machinesInLog.map((m) => (
            <option key={m.id} value={m.id}>
              {m.name}
            </option>
          ))}
        </select>
        <select
          value={outcomeFilter}
          onChange={(e) => setOutcomeFilter(e.target.value as "all" | Outcome)}
          style={{
            padding: "7px 10px",
            fontSize: 13,
            border: "1px solid var(--line)",
            borderRadius: 8,
            background: "var(--surface)",
            fontFamily: font,
          }}
        >
          <option value="all">All outcomes</option>
          {(Object.keys(OUTCOME_META) as Outcome[]).map((o) => (
            <option key={o} value={o}>
              {OUTCOME_META[o].label}
            </option>
          ))}
        </select>
        <input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search product / machine / comment…"
          style={{
            padding: "7px 10px",
            fontSize: 13,
            border: "1px solid var(--line)",
            borderRadius: 8,
            minWidth: 240,
            fontFamily: font,
          }}
        />
        <div style={{ flex: 1 }} />
        <span style={{ fontSize: 12, color: "var(--muted)" }}>
          {visible.length.toLocaleString()} lines
        </span>
      </div>

      {/* Outcome tally */}
      <div className="flex items-center gap-2 flex-wrap mb-5">
        {(Object.keys(OUTCOME_META) as Outcome[]).map(
          (o) =>
            stats[o] > 0 && (
              <button
                key={o}
                onClick={() =>
                  setOutcomeFilter(outcomeFilter === o ? "all" : o)
                }
                style={{
                  background: "none",
                  border: "none",
                  padding: 0,
                  cursor: "pointer",
                  opacity:
                    outcomeFilter === "all" || outcomeFilter === o ? 1 : 0.4,
                }}
              >
                <Badge tone={OUTCOME_META[o].tone}>
                  {stats[o].toLocaleString()} {OUTCOME_META[o].label}
                </Badge>
              </button>
            ),
        )}
      </div>

      {err && (
        <div
          style={{
            padding: 12,
            borderRadius: 8,
            background: "var(--danger-bg)",
            color: "var(--danger)",
            fontSize: 13,
            marginBottom: 12,
          }}
        >
          {err}
        </div>
      )}

      {loading ? (
        <div
          style={{
            padding: 48,
            textAlign: "center",
            color: "var(--muted-2)",
            fontSize: 13,
          }}
        >
          Loading refill history…
        </div>
      ) : grouped.size === 0 ? (
        <div
          style={{
            padding: 48,
            textAlign: "center",
            border: "1px solid var(--line)",
            borderRadius: 10,
            background: "var(--surface)",
            color: "var(--muted-2)",
            fontSize: 13,
          }}
        >
          No refill lines match.
        </div>
      ) : (
        [...grouped.entries()].map(([date, machines]) => {
          const dayLines = [...machines.values()].reduce(
            (a, v) => a + v.length,
            0,
          );
          return (
            <div key={date} style={{ marginBottom: 22 }}>
              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 10,
                  fontSize: 12,
                  fontWeight: 800,
                  letterSpacing: "0.1em",
                  textTransform: "uppercase",
                  color: "var(--brand)",
                  margin: "0 0 8px",
                }}
              >
                {new Date(date + "T00:00:00").toLocaleDateString("en-GB", {
                  weekday: "short",
                  day: "numeric",
                  month: "short",
                  year: "numeric",
                })}
                <span
                  style={{
                    fontWeight: 500,
                    color: "var(--muted-2)",
                    letterSpacing: 0,
                    textTransform: "none",
                  }}
                >
                  {machines.size} machines · {dayLines} lines
                </span>
                <span
                  style={{ flex: 1, height: 1, background: "var(--line)" }}
                />
              </div>

              {[...machines.entries()]
                .sort((a, b) =>
                  (machineNames[a[0]] ?? "").localeCompare(
                    machineNames[b[0]] ?? "",
                  ),
                )
                .map(([mid, lines]) => (
                  <div
                    key={mid}
                    style={{
                      background: "var(--surface)",
                      border: "1px solid var(--line)",
                      borderRadius: 10,
                      marginBottom: 8,
                      overflow: "hidden",
                    }}
                  >
                    <div
                      className="flex items-center gap-2 flex-wrap"
                      style={{
                        padding: "7px 14px",
                        background: "var(--surface-2)",
                        borderBottom: "1px solid var(--line)",
                      }}
                    >
                      <span
                        style={{
                          fontWeight: 800,
                          fontSize: 13,
                          color: "var(--ink)",
                        }}
                      >
                        {machineNames[mid] ?? mid.slice(0, 8)}
                      </span>
                      <span style={{ fontSize: 11, color: "var(--muted-2)" }}>
                        {lines.length} lines ·{" "}
                        {lines.reduce(
                          (a, r) =>
                            a + (Number(r.filled_quantity ?? r.quantity) || 0),
                          0,
                        )}{" "}
                        units
                      </span>
                    </div>
                    {lines.map((r) => {
                      const o = outcomeOf(r);
                      const prod =
                        (r.boonz_product_id &&
                          productNames[r.boonz_product_id]) ||
                        (r.pod_product_id && podNames[r.pod_product_id]) ||
                        "—";
                      const qty = Number(r.filled_quantity ?? r.quantity) || 0;
                      const planned = Number(r.quantity) || 0;
                      const reason =
                        r.not_filled_reason || r.return_reason || r.skip_reason;
                      return (
                        <div
                          key={r.dispatch_id}
                          className="flex items-center gap-2 flex-wrap"
                          style={{
                            padding: "6px 14px",
                            borderBottom: "1px solid var(--line)",
                            fontSize: 12.5,
                          }}
                        >
                          <Badge tone={OUTCOME_META[o].tone}>
                            {OUTCOME_META[o].label}
                          </Badge>
                          <span
                            style={{ fontWeight: 600, color: "var(--ink)" }}
                          >
                            {prod}
                          </span>
                          <span
                            style={{
                              fontVariantNumeric: "tabular-nums",
                              color: "var(--muted)",
                            }}
                          >
                            {qty}u
                            {r.filled_quantity != null && planned !== qty
                              ? ` (planned ${planned})`
                              : ""}
                          </span>
                          {r.action && r.action.toLowerCase() !== "refill" && (
                            <Badge tone="muted">{r.action}</Badge>
                          )}
                          {r.is_m2m && <Badge tone="brand">M2M</Badge>}
                          {(r.edit_count ?? 0) > 0 && (
                            <span
                              style={{ fontSize: 10, color: "var(--muted-2)" }}
                            >
                              ✎ {r.edit_count}× {r.last_edited_by_role ?? ""}
                            </span>
                          )}
                          <span
                            style={{
                              marginLeft: "auto",
                              fontSize: 11,
                              color: "var(--muted-2)",
                              maxWidth: 340,
                              overflow: "hidden",
                              textOverflow: "ellipsis",
                              whiteSpace: "nowrap",
                            }}
                          >
                            {reason || r.comment || ""}
                          </span>
                        </div>
                      );
                    })}
                  </div>
                ))}
            </div>
          );
        })
      )}

      <p style={{ fontSize: 11, color: "var(--muted-2)", margin: "10px 4px" }}>
        Straight from <code>refill_dispatching</code> — every planned line with
        its final outcome, driver edits (✎), M2M transfers and reasons. Use the
        outcome chips to isolate returns or not-filled lines when tracing an
        issue. Capped at 10,000 lines per window.
      </p>
    </div>
  );
}
