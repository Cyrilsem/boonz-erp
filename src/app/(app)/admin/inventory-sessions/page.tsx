"use client";

// Phase G P4 B.5: read-only viewer for inventory_control_session +
// inventory_control_attempt rows. RLS restricts visibility to
// manager/operator_admin/superadmin per PRD section 8.1.
//
// PRD-087 R5: session list regrouped BY DAY → BY WAREHOUSE/MACHINE within
// the day (newest day first). Purely presentational — same queries/RPCs.
// PRD-087 R7: standard chrome (p-8 max-w-7xl + PageHeader) and design
// tokens from globals.css via ui/primitives.

import { useCallback, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import {
  PageHeader,
  Card,
  Badge,
  SectionHeading,
  type BadgeTone,
} from "@/components/ui/primitives";

interface SessionRow {
  session_id: string;
  started_at: string;
  started_by: string | null;
  scope_warehouse_id: string | null;
  scope_product_ids: string[] | null;
  status: string;
  closed_at: string | null;
  summary: Record<string, unknown> | null;
}

interface AttemptRow {
  attempt_id: string;
  session_id: string;
  attempted_at: string;
  attempted_by: string | null;
  wh_inventory_id: string | null;
  target_path: string;
  boonz_product_id: string | null;
  warehouse_id: string | null;
  expiration_date: string | null;
  field_changed: string;
  old_value: unknown;
  new_value: unknown;
  rpc_called: string | null;
  result: string;
  error_message: string | null;
  reason: string | null;
}

const RESULT_FILTERS = [
  "all",
  "success",
  "blocked_rls",
  "blocked_trigger",
  "rpc_error",
  "validation_error",
  "network_error",
  "other",
];

// Attempt result → badge tone (design tokens, no raw hexes).
function resultTone(result: string): BadgeTone {
  switch (result) {
    case "success":
      return "success";
    case "blocked_rls":
    case "blocked_trigger":
      return "danger";
    case "rpc_error":
    case "validation_error":
      return "warn";
    case "network_error":
      return "brand";
    default:
      return "muted";
  }
}

function statusTone(status: string): BadgeTone {
  switch (status) {
    case "open":
      return "brand";
    case "closed":
      return "success";
    default:
      return "danger"; // aborted / unknown
  }
}

function fmtTime(iso: string | null): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("en-GB", {
    timeZone: "Asia/Dubai",
    dateStyle: "short",
    timeStyle: "medium",
  });
}

// Time-of-day only (used for the per-session start–end range).
function fmtClock(iso: string | null): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleTimeString("en-GB", {
    timeZone: "Asia/Dubai",
    hour: "2-digit",
    minute: "2-digit",
  });
}

// Stable YYYY-MM-DD key in Dubai time for day grouping.
function dayKey(iso: string): string {
  return new Date(iso).toLocaleDateString("en-CA", {
    timeZone: "Asia/Dubai",
  });
}

// Human day label, e.g. "Tue 7 Jul 2026".
function dayLabel(iso: string): string {
  return new Date(iso)
    .toLocaleDateString("en-GB", {
      timeZone: "Asia/Dubai",
      weekday: "short",
      day: "numeric",
      month: "short",
      year: "numeric",
    })
    .replace(",", "");
}

// Safe numeric read from the session summary jsonb
// (close_inventory_session writes attempt_total / success_count / …).
function summaryNum(
  summary: Record<string, unknown> | null,
  key: string,
): number {
  const v = summary?.[key];
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

interface ScopeGroup {
  scope: string; // warehouse / machine label
  sessions: SessionRow[];
}

interface DayGroup {
  key: string;
  label: string;
  sessionCount: number;
  attemptTotal: number;
  correctionTotal: number;
  scopes: ScopeGroup[];
}

export default function InventorySessionsPage() {
  const [sessions, setSessions] = useState<SessionRow[]>([]);
  const [loadingSessions, setLoadingSessions] = useState(true);
  const [sessionsError, setSessionsError] = useState<string | null>(null);

  const [selectedSessionId, setSelectedSessionId] = useState<string | null>(
    null,
  );
  const [attempts, setAttempts] = useState<AttemptRow[]>([]);
  const [loadingAttempts, setLoadingAttempts] = useState(false);
  const [attemptsError, setAttemptsError] = useState<string | null>(null);

  const [resultFilter, setResultFilter] = useState("all");
  const [search, setSearch] = useState("");

  const loadSessions = useCallback(async () => {
    setLoadingSessions(true);
    setSessionsError(null);
    const supabase = createClient();
    const { data, error } = await supabase
      .from("inventory_control_session")
      .select(
        "session_id, started_at, started_by, scope_warehouse_id, scope_product_ids, status, closed_at, summary",
      )
      .order("started_at", { ascending: false })
      .limit(200);
    setLoadingSessions(false);
    if (error) {
      setSessionsError(error.message);
      return;
    }
    setSessions((data ?? []) as SessionRow[]);
  }, []);

  useEffect(() => {
    void loadSessions();
  }, [loadSessions]);

  useEffect(() => {
    if (!selectedSessionId) {
      setAttempts([]);
      return;
    }
    let cancelled = false;
    (async () => {
      setLoadingAttempts(true);
      setAttemptsError(null);
      const supabase = createClient();
      const { data, error } = await supabase
        .from("inventory_control_attempt")
        .select(
          "attempt_id, session_id, attempted_at, attempted_by, wh_inventory_id, target_path, boonz_product_id, warehouse_id, expiration_date, field_changed, old_value, new_value, rpc_called, result, error_message, reason",
        )
        .eq("session_id", selectedSessionId)
        .order("attempted_at", { ascending: false })
        .limit(10000);
      if (cancelled) return;
      setLoadingAttempts(false);
      if (error) {
        setAttemptsError(error.message);
        return;
      }
      setAttempts((data ?? []) as AttemptRow[]);
    })();
    return () => {
      cancelled = true;
    };
  }, [selectedSessionId]);

  const filteredAttempts = useMemo(() => {
    const q = search.trim().toLowerCase();
    return attempts.filter((a) => {
      if (resultFilter !== "all" && a.result !== resultFilter) return false;
      if (!q) return true;
      const hay = [
        a.wh_inventory_id,
        a.boonz_product_id,
        a.field_changed,
        a.rpc_called,
        a.reason,
        a.error_message,
      ]
        .filter(Boolean)
        .join(" ")
        .toLowerCase();
      return hay.includes(q);
    });
  }, [attempts, resultFilter, search]);

  // PRD-087 R5 — group sessions by Dubai day, then by warehouse/machine
  // scope within the day. `sessions` is already ordered newest-first, so
  // Map insertion order gives newest day first with zero extra sorting.
  const dayGroups = useMemo<DayGroup[]>(() => {
    const map = new Map<string, DayGroup>();
    for (const s of sessions) {
      const key = dayKey(s.started_at);
      let group = map.get(key);
      if (!group) {
        group = {
          key,
          label: dayLabel(s.started_at),
          sessionCount: 0,
          attemptTotal: 0,
          correctionTotal: 0,
          scopes: [],
        };
        map.set(key, group);
      }
      group.sessionCount += 1;
      group.attemptTotal += summaryNum(s.summary, "attempt_total");
      group.correctionTotal += summaryNum(s.summary, "success_count");
      const scopeLabel = s.scope_warehouse_id ?? "All warehouses";
      let scope = group.scopes.find((g) => g.scope === scopeLabel);
      if (!scope) {
        scope = { scope: scopeLabel, sessions: [] };
        group.scopes.push(scope);
      }
      scope.sessions.push(s);
    }
    return Array.from(map.values());
  }, [sessions]);

  const selectedSession = sessions.find(
    (s) => s.session_id === selectedSessionId,
  );

  return (
    <div className="p-8 max-w-7xl">
      <PageHeader
        title="Inventory Sessions"
        subtitle="Read-only audit of inventory edit sessions and per-row attempts, grouped by day and warehouse. Visible to manager / operator_admin / superadmin only."
      />

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "380px 1fr",
          gap: 16,
          alignItems: "start",
        }}
      >
        <Card style={{ padding: 0, maxHeight: "75vh", overflow: "auto" }}>
          <div
            style={{
              padding: "8px 14px",
              borderBottom: "1px solid var(--line)",
              fontSize: 11,
              fontWeight: 700,
              textTransform: "uppercase",
              letterSpacing: "0.08em",
              color: "var(--muted)",
              background: "var(--surface-2)",
              display: "flex",
              justifyContent: "space-between",
              position: "sticky",
              top: 0,
              zIndex: 1,
            }}
          >
            <span>Sessions ({sessions.length})</span>
            <button
              onClick={() => void loadSessions()}
              style={{
                fontSize: 11,
                background: "none",
                border: "none",
                color: "var(--brand)",
                fontWeight: 700,
                cursor: "pointer",
              }}
            >
              refresh
            </button>
          </div>
          {loadingSessions && (
            <div style={{ padding: 14, fontSize: 13, color: "var(--muted)" }}>
              Loading…
            </div>
          )}
          {sessionsError && (
            <div style={{ padding: 14, fontSize: 13, color: "var(--danger)" }}>
              {sessionsError}
            </div>
          )}
          {!loadingSessions && sessions.length === 0 && (
            <div style={{ padding: 14, fontSize: 13, color: "var(--muted)" }}>
              No sessions yet.
            </div>
          )}
          <div style={{ padding: "0 14px 14px" }}>
            {dayGroups.map((day) => (
              <div key={day.key}>
                {/* Day group header: date + session count + day totals */}
                <SectionHeading>
                  {day.label}
                  <span
                    style={{
                      fontWeight: 500,
                      textTransform: "none",
                      letterSpacing: 0,
                      color: "var(--muted-2)",
                    }}
                  >
                    {day.sessionCount} session
                    {day.sessionCount === 1 ? "" : "s"} · {day.attemptTotal}{" "}
                    attempts · {day.correctionTotal} corrections
                  </span>
                </SectionHeading>
                {day.scopes.map((scope) => (
                  <div key={scope.scope} style={{ marginBottom: 10 }}>
                    {/* Warehouse / machine subgroup within the day */}
                    <div
                      style={{
                        fontSize: 11,
                        fontWeight: 700,
                        color: "var(--ink)",
                        fontFamily: "'Plus Jakarta Sans', sans-serif",
                        margin: "0 0 4px 2px",
                      }}
                    >
                      {scope.scope}
                    </div>
                    {scope.sessions.map((s) => {
                      const sel = s.session_id === selectedSessionId;
                      const attemptTotal = summaryNum(
                        s.summary,
                        "attempt_total",
                      );
                      const successCount = summaryNum(
                        s.summary,
                        "success_count",
                      );
                      return (
                        <button
                          key={s.session_id}
                          onClick={() => setSelectedSessionId(s.session_id)}
                          style={{
                            display: "block",
                            width: "100%",
                            textAlign: "left",
                            padding: "8px 10px",
                            marginBottom: 4,
                            border: sel
                              ? "1px solid var(--brand)"
                              : "1px solid var(--line)",
                            borderRadius: 8,
                            background: sel
                              ? "var(--brand-tint)"
                              : "var(--surface)",
                            cursor: "pointer",
                          }}
                        >
                          <div
                            style={{
                              display: "flex",
                              alignItems: "center",
                              gap: 8,
                              flexWrap: "wrap",
                            }}
                          >
                            <Badge tone={statusTone(s.status)}>
                              {s.status}
                            </Badge>
                            <span
                              style={{
                                fontSize: 11,
                                color: "var(--muted)",
                              }}
                            >
                              {fmtClock(s.started_at)} –{" "}
                              {s.closed_at ? fmtClock(s.closed_at) : "open"}
                            </span>
                          </div>
                          <div
                            style={{
                              fontSize: 11,
                              color: "var(--muted)",
                              marginTop: 3,
                            }}
                          >
                            by{" "}
                            <span style={{ fontFamily: "monospace" }}>
                              {s.started_by
                                ? s.started_by.slice(0, 8) + "…"
                                : "—"}
                            </span>
                            {s.summary ? (
                              <>
                                {" "}
                                · {attemptTotal} attempts · {successCount} ok
                              </>
                            ) : null}
                          </div>
                          <div
                            style={{
                              fontFamily: "monospace",
                              fontSize: 10,
                              color: "var(--muted-2)",
                              marginTop: 2,
                            }}
                          >
                            {s.session_id.slice(0, 18)}…
                          </div>
                        </button>
                      );
                    })}
                  </div>
                ))}
              </div>
            ))}
          </div>
        </Card>

        <Card style={{ padding: 0, minHeight: "75vh", overflow: "hidden" }}>
          {!selectedSessionId ? (
            <div
              style={{
                padding: 24,
                fontSize: 13,
                color: "var(--muted)",
                textAlign: "center",
              }}
            >
              Pick a session to inspect attempts.
            </div>
          ) : (
            <>
              <div
                style={{
                  padding: 12,
                  borderBottom: "1px solid var(--line)",
                  background: "var(--surface-2)",
                  display: "flex",
                  gap: 12,
                  flexWrap: "wrap",
                  alignItems: "center",
                }}
              >
                <div style={{ flex: "1 1 auto", minWidth: 200 }}>
                  <div
                    style={{
                      fontSize: 11,
                      fontWeight: 700,
                      letterSpacing: "0.08em",
                      textTransform: "uppercase",
                      color: "var(--muted)",
                    }}
                  >
                    Session
                  </div>
                  <div
                    style={{
                      fontFamily: "monospace",
                      fontSize: 12,
                      color: "var(--ink)",
                    }}
                  >
                    {selectedSession?.session_id}
                  </div>
                  <div
                    style={{
                      fontSize: 11,
                      color: "var(--muted)",
                      marginTop: 2,
                    }}
                  >
                    Started {fmtTime(selectedSession?.started_at ?? null)} ·
                    closed{" "}
                    {selectedSession?.closed_at
                      ? fmtTime(selectedSession.closed_at)
                      : "—"}
                  </div>
                </div>
                <select
                  value={resultFilter}
                  onChange={(e) => setResultFilter(e.target.value)}
                  style={{
                    padding: "4px 8px",
                    border: "1px solid var(--line)",
                    borderRadius: 6,
                    fontSize: 12,
                    background: "var(--surface)",
                    color: "var(--ink)",
                  }}
                >
                  {RESULT_FILTERS.map((r) => (
                    <option key={r} value={r}>
                      result: {r}
                    </option>
                  ))}
                </select>
                <input
                  type="text"
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  placeholder="search id / field / reason / error"
                  style={{
                    flex: "1 1 200px",
                    padding: "4px 8px",
                    border: "1px solid var(--line)",
                    borderRadius: 6,
                    fontSize: 12,
                    background: "var(--surface)",
                    color: "var(--ink)",
                  }}
                />
              </div>
              {loadingAttempts && (
                <div
                  style={{ padding: 16, fontSize: 13, color: "var(--muted)" }}
                >
                  Loading attempts…
                </div>
              )}
              {attemptsError && (
                <div
                  style={{ padding: 16, fontSize: 13, color: "var(--danger)" }}
                >
                  {attemptsError}
                </div>
              )}
              {!loadingAttempts && (
                <div style={{ overflowX: "auto" }}>
                  <table
                    style={{
                      width: "100%",
                      borderCollapse: "collapse",
                      fontSize: 12,
                    }}
                  >
                    <thead>
                      <tr
                        style={{
                          background: "var(--surface-2)",
                          borderBottom: "1px solid var(--line)",
                          textAlign: "left",
                        }}
                      >
                        <th style={{ padding: "8px 10px" }}>When</th>
                        <th style={{ padding: "8px 10px" }}>Result</th>
                        <th style={{ padding: "8px 10px" }}>Field</th>
                        <th style={{ padding: "8px 10px" }}>RPC</th>
                        <th style={{ padding: "8px 10px" }}>wh_inventory</th>
                        <th style={{ padding: "8px 10px" }}>Old → New</th>
                        <th style={{ padding: "8px 10px" }}>Reason</th>
                        <th style={{ padding: "8px 10px" }}>Error</th>
                      </tr>
                    </thead>
                    <tbody>
                      {filteredAttempts.map((a) => (
                        <tr
                          key={a.attempt_id}
                          style={{
                            borderBottom: "1px solid var(--line)",
                            verticalAlign: "top",
                          }}
                        >
                          <td
                            style={{
                              padding: "8px 10px",
                              whiteSpace: "nowrap",
                              color: "var(--muted)",
                            }}
                          >
                            {fmtTime(a.attempted_at)}
                          </td>
                          <td style={{ padding: "8px 10px" }}>
                            <Badge tone={resultTone(a.result)}>
                              {a.result}
                            </Badge>
                          </td>
                          <td style={{ padding: "8px 10px" }}>
                            {a.field_changed}
                          </td>
                          <td
                            style={{
                              padding: "8px 10px",
                              fontFamily: "monospace",
                              fontSize: 11,
                            }}
                          >
                            {a.rpc_called ?? "—"}
                          </td>
                          <td
                            style={{
                              padding: "8px 10px",
                              fontFamily: "monospace",
                              fontSize: 11,
                            }}
                          >
                            {a.wh_inventory_id
                              ? a.wh_inventory_id.slice(0, 8) + "…"
                              : "—"}
                          </td>
                          <td
                            style={{
                              padding: "8px 10px",
                              fontFamily: "monospace",
                              fontSize: 11,
                              maxWidth: 220,
                              overflow: "hidden",
                              textOverflow: "ellipsis",
                            }}
                          >
                            {JSON.stringify(a.old_value)} →{" "}
                            {JSON.stringify(a.new_value)}
                          </td>
                          <td
                            style={{
                              padding: "8px 10px",
                              maxWidth: 200,
                            }}
                          >
                            {a.reason ?? "—"}
                          </td>
                          <td
                            style={{
                              padding: "8px 10px",
                              color: "var(--danger)",
                              maxWidth: 220,
                            }}
                          >
                            {a.error_message ?? ""}
                          </td>
                        </tr>
                      ))}
                      {filteredAttempts.length === 0 && (
                        <tr>
                          <td
                            colSpan={8}
                            style={{
                              padding: 24,
                              textAlign: "center",
                              color: "var(--muted)",
                            }}
                          >
                            No attempts match the current filter.
                          </td>
                        </tr>
                      )}
                    </tbody>
                  </table>
                </div>
              )}
            </>
          )}
        </Card>
      </div>
    </div>
  );
}
