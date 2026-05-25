"use client";

// Phase G P4 B.5: read-only viewer for inventory_control_session +
// inventory_control_attempt rows. RLS restricts visibility to
// manager/operator_admin/superadmin per PRD section 8.1.

import { useCallback, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";

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

function resultColor(result: string): { bg: string; fg: string } {
  switch (result) {
    case "success":
      return { bg: "#dcfce7", fg: "#166534" };
    case "blocked_rls":
    case "blocked_trigger":
      return { bg: "#fee2e2", fg: "#991b1b" };
    case "rpc_error":
    case "validation_error":
      return { bg: "#fef3c7", fg: "#854d0e" };
    case "network_error":
      return { bg: "#e0e7ff", fg: "#3730a3" };
    default:
      return { bg: "#f3f4f6", fg: "#374151" };
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

  const selectedSession = sessions.find(
    (s) => s.session_id === selectedSessionId,
  );

  return (
    <div style={{ padding: 24, maxWidth: 1400, margin: "0 auto" }}>
      <header style={{ marginBottom: 16 }}>
        <h1 style={{ fontSize: 22, fontWeight: 600, margin: 0 }}>
          Inventory control sessions
        </h1>
        <p
          style={{
            margin: "4px 0 0 0",
            fontSize: 13,
            color: "#6b7280",
          }}
        >
          Read-only audit of inventory edit sessions and per-row attempts.
          Visible to manager / operator_admin / superadmin only.
        </p>
      </header>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "320px 1fr",
          gap: 16,
          alignItems: "start",
        }}
      >
        <section
          style={{
            border: "1px solid #e5e7eb",
            borderRadius: 8,
            background: "white",
            maxHeight: "75vh",
            overflow: "auto",
          }}
        >
          <div
            style={{
              padding: "8px 12px",
              borderBottom: "1px solid #e5e7eb",
              fontSize: 11,
              fontWeight: 700,
              textTransform: "uppercase",
              letterSpacing: "0.08em",
              color: "#6b7280",
              background: "#f9fafb",
              display: "flex",
              justifyContent: "space-between",
            }}
          >
            <span>Sessions ({sessions.length})</span>
            <button
              onClick={() => void loadSessions()}
              style={{
                fontSize: 11,
                background: "none",
                border: "none",
                color: "#3b82f6",
                cursor: "pointer",
              }}
            >
              refresh
            </button>
          </div>
          {loadingSessions && (
            <div style={{ padding: 12, fontSize: 13, color: "#6b7280" }}>
              Loading…
            </div>
          )}
          {sessionsError && (
            <div style={{ padding: 12, fontSize: 13, color: "#b91c1c" }}>
              {sessionsError}
            </div>
          )}
          {!loadingSessions && sessions.length === 0 && (
            <div style={{ padding: 12, fontSize: 13, color: "#6b7280" }}>
              No sessions yet.
            </div>
          )}
          <ul style={{ listStyle: "none", padding: 0, margin: 0 }}>
            {sessions.map((s) => {
              const sel = s.session_id === selectedSessionId;
              return (
                <li key={s.session_id}>
                  <button
                    onClick={() => setSelectedSessionId(s.session_id)}
                    style={{
                      display: "block",
                      width: "100%",
                      textAlign: "left",
                      padding: "10px 12px",
                      border: "none",
                      borderBottom: "1px solid #f3f4f6",
                      background: sel ? "#eff6ff" : "white",
                      cursor: "pointer",
                    }}
                  >
                    <div
                      style={{
                        fontFamily: "monospace",
                        fontSize: 11,
                        color: "#374151",
                      }}
                    >
                      {s.session_id.slice(0, 18)}…
                    </div>
                    <div style={{ fontSize: 12, marginTop: 2 }}>
                      <span
                        style={{
                          padding: "1px 6px",
                          borderRadius: 4,
                          fontWeight: 600,
                          fontSize: 10,
                          background:
                            s.status === "open"
                              ? "#dbeafe"
                              : s.status === "closed"
                                ? "#dcfce7"
                                : "#fee2e2",
                          color:
                            s.status === "open"
                              ? "#1e40af"
                              : s.status === "closed"
                                ? "#166534"
                                : "#991b1b",
                        }}
                      >
                        {s.status}
                      </span>
                      <span
                        style={{
                          marginLeft: 8,
                          color: "#6b7280",
                          fontSize: 11,
                        }}
                      >
                        {fmtTime(s.started_at)}
                      </span>
                    </div>
                  </button>
                </li>
              );
            })}
          </ul>
        </section>

        <section
          style={{
            border: "1px solid #e5e7eb",
            borderRadius: 8,
            background: "white",
            minHeight: "75vh",
          }}
        >
          {!selectedSessionId ? (
            <div
              style={{
                padding: 24,
                fontSize: 13,
                color: "#6b7280",
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
                  borderBottom: "1px solid #e5e7eb",
                  background: "#f9fafb",
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
                      color: "#6b7280",
                    }}
                  >
                    Session
                  </div>
                  <div
                    style={{
                      fontFamily: "monospace",
                      fontSize: 12,
                      color: "#111827",
                    }}
                  >
                    {selectedSession?.session_id}
                  </div>
                  <div style={{ fontSize: 11, color: "#6b7280", marginTop: 2 }}>
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
                    border: "1px solid #d1d5db",
                    borderRadius: 6,
                    fontSize: 12,
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
                    border: "1px solid #d1d5db",
                    borderRadius: 6,
                    fontSize: 12,
                  }}
                />
              </div>
              {loadingAttempts && (
                <div style={{ padding: 16, fontSize: 13, color: "#6b7280" }}>
                  Loading attempts…
                </div>
              )}
              {attemptsError && (
                <div style={{ padding: 16, fontSize: 13, color: "#b91c1c" }}>
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
                          background: "#f9fafb",
                          borderBottom: "1px solid #e5e7eb",
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
                      {filteredAttempts.map((a) => {
                        const col = resultColor(a.result);
                        return (
                          <tr
                            key={a.attempt_id}
                            style={{
                              borderBottom: "1px solid #f3f4f6",
                              verticalAlign: "top",
                            }}
                          >
                            <td
                              style={{
                                padding: "8px 10px",
                                whiteSpace: "nowrap",
                                color: "#6b7280",
                              }}
                            >
                              {fmtTime(a.attempted_at)}
                            </td>
                            <td style={{ padding: "8px 10px" }}>
                              <span
                                style={{
                                  padding: "2px 6px",
                                  borderRadius: 4,
                                  fontWeight: 600,
                                  fontSize: 11,
                                  background: col.bg,
                                  color: col.fg,
                                }}
                              >
                                {a.result}
                              </span>
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
                                color: "#b91c1c",
                                maxWidth: 220,
                              }}
                            >
                              {a.error_message ?? ""}
                            </td>
                          </tr>
                        );
                      })}
                      {filteredAttempts.length === 0 && (
                        <tr>
                          <td
                            colSpan={8}
                            style={{
                              padding: 24,
                              textAlign: "center",
                              color: "#6b7280",
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
        </section>
      </div>
    </div>
  );
}
