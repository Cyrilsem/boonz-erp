"use client";

// PRD-087 R2+R6 — unified Driver Requests hub.
// One place for everything drivers raise from the field, grouped BY MACHINE:
//   · Additions   — lines added beyond the plan (v_driver_addition_review_queue),
//                   accept/reject via review_driver_addition; per-machine and
//                   global "Accept all" for the current auto-approve policy.
//   · Feedback    — shelf notes (v_driver_feedback_active), read-only signal
//                   consumed by the refill brain.
// Engine signals & the issue board stay in Refill & Dispatch (different data,
// not driver requests) — linked from the header for discoverability.

import { useCallback, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { Badge } from "@/components/ui/primitives";

const font = "'Plus Jakarta Sans', sans-serif";

interface AdditionRow {
  dispatch_id: string;
  dispatch_date: string;
  machine_name: string | null;
  shelf_code: string | null;
  pod_product_name: string | null;
  boonz_product_name: string | null;
  action: string;
  quantity: number;
  review_reason: string | null;
  last_edited_at: string | null;
}

interface FeedbackRow {
  feedback_id: string;
  machine_id: string;
  machine_official_name: string | null;
  slot_code: string | null;
  boonz_product_id: string | null;
  product_name: string | null;
  direction: "more" | "fewer" | "replace" | null;
  signal_source: "observation" | "customer_request" | "sale_anomaly";
  confidence: number;
  note_text: string;
  created_by: string | null;
  created_at: string;
}

type MachineGroup = {
  machine: string;
  additions: AdditionRow[];
  feedback: FeedbackRow[];
};

export default function DriverRequestsHub() {
  const [additions, setAdditions] = useState<AdditionRow[] | null>(null);
  const [feedback, setFeedback] = useState<FeedbackRow[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null); // dispatch_id | machine | "__all__"

  const load = useCallback(() => {
    const supabase = createClient();
    supabase
      .from("v_driver_addition_review_queue")
      .select("*")
      .order("dispatch_date", { ascending: false })
      .limit(10000)
      .then(({ data, error }) => {
        if (error) setErr(error.message);
        setAdditions((data as AdditionRow[]) ?? []);
      });
    supabase
      .from("v_driver_feedback_active")
      .select("*")
      .order("created_at", { ascending: false })
      .limit(10000)
      .then(({ data, error }) => {
        if (error) setErr((e) => e ?? error.message);
        setFeedback((data as FeedbackRow[]) ?? []);
      });
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const loading = additions === null || feedback === null;

  const groups: MachineGroup[] = useMemo(() => {
    const map = new Map<string, MachineGroup>();
    const get = (name: string) => {
      const key = name || "Unassigned";
      if (!map.has(key))
        map.set(key, { machine: key, additions: [], feedback: [] });
      return map.get(key)!;
    };
    (additions ?? []).forEach((a) => get(a.machine_name ?? "—").additions.push(a));
    (feedback ?? []).forEach((f) =>
      get(f.machine_official_name ?? f.machine_id.slice(0, 8)).feedback.push(f),
    );
    // machines with pending additions first, then by total volume
    return [...map.values()].sort(
      (a, b) =>
        b.additions.length - a.additions.length ||
        b.feedback.length - a.feedback.length ||
        a.machine.localeCompare(b.machine),
    );
  }, [additions, feedback]);

  const approveOne = useCallback(
    async (row: AdditionRow, decision: "accepted" | "rejected") => {
      setBusy(row.dispatch_id);
      setErr(null);
      const supabase = createClient();
      const { error } = await supabase.rpc("review_driver_addition", {
        p_dispatch_id: row.dispatch_id,
        p_decision: decision,
        p_reason:
          decision === "accepted" ? "bulk/auto-approve policy (PRD-087)" : null,
      });
      setBusy(null);
      if (error) {
        setErr(error.message);
        return false;
      }
      setAdditions((prev) =>
        (prev ?? []).filter((r) => r.dispatch_id !== row.dispatch_id),
      );
      return true;
    },
    [],
  );

  const approveMany = useCallback(
    async (rows: AdditionRow[], busyKey: string) => {
      if (rows.length === 0) return;
      if (
        !window.confirm(
          `Accept ${rows.length} driver addition${rows.length > 1 ? "s" : ""}? This logs each via review_driver_addition.`,
        )
      )
        return;
      setBusy(busyKey);
      setErr(null);
      const supabase = createClient();
      const done: string[] = [];
      for (const row of rows) {
        const { error } = await supabase.rpc("review_driver_addition", {
          p_dispatch_id: row.dispatch_id,
          p_decision: "accepted",
          p_reason: "bulk/auto-approve policy (PRD-087)",
        });
        if (error) {
          setErr(`${error.message} (stopped after ${done.length}/${rows.length})`);
          break;
        }
        done.push(row.dispatch_id);
      }
      setAdditions((prev) =>
        (prev ?? []).filter((r) => !done.includes(r.dispatch_id)),
      );
      setBusy(null);
    },
    [],
  );

  const pendingCount = additions?.length ?? 0;

  if (loading)
    return (
      <div
        style={{
          padding: 40,
          textAlign: "center",
          color: "var(--muted-2)",
          fontSize: 13,
          fontFamily: font,
        }}
      >
        Loading driver requests…
      </div>
    );

  return (
    <div style={{ fontFamily: font }}>
      {/* Toolbar */}
      <div className="flex items-center gap-3 flex-wrap mb-5">
        <Badge tone={pendingCount > 0 ? "warn" : "success"}>
          {pendingCount} addition{pendingCount === 1 ? "" : "s"} pending
        </Badge>
        <Badge tone="muted">{feedback?.length ?? 0} active feedback notes</Badge>
        <div style={{ flex: 1 }} />
        {pendingCount > 0 && (
          <button
            onClick={() => approveMany(additions ?? [], "__all__")}
            disabled={busy !== null}
            style={{
              padding: "8px 14px",
              fontSize: 12,
              fontWeight: 700,
              borderRadius: 8,
              border: "none",
              background: "var(--brand)",
              color: "white",
              cursor: "pointer",
            }}
          >
            {busy === "__all__" ? "Approving…" : `✓ Accept all ${pendingCount}`}
          </button>
        )}
        <button
          onClick={() => {
            setAdditions(null);
            setFeedback(null);
            load();
          }}
          style={{
            padding: "8px 12px",
            fontSize: 12,
            fontWeight: 600,
            borderRadius: 8,
            border: "1px solid var(--line)",
            background: "var(--surface)",
            color: "var(--muted)",
            cursor: "pointer",
          }}
        >
          ↻ Refresh
        </button>
      </div>

      {err && (
        <div
          style={{
            padding: 12,
            borderRadius: 8,
            background: "var(--danger-bg)",
            color: "var(--danger)",
            fontSize: 13,
            marginBottom: 14,
          }}
        >
          {err}
        </div>
      )}

      {groups.length === 0 && (
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
          Nothing from the field — no pending additions, no active feedback.
        </div>
      )}

      <div className="space-y-4">
        {groups.map((g) => (
          <div
            key={g.machine}
            style={{
              background: "var(--surface)",
              border: "1px solid var(--line)",
              borderRadius: 10,
              overflow: "hidden",
            }}
          >
            {/* Machine header */}
            <div
              className="flex items-center gap-3 flex-wrap"
              style={{
                padding: "10px 16px",
                borderBottom: "1px solid var(--line)",
                background: "var(--surface-2)",
              }}
            >
              <span style={{ fontWeight: 800, fontSize: 14, color: "var(--ink)" }}>
                {g.machine}
              </span>
              {g.additions.length > 0 && (
                <Badge tone="warn">{g.additions.length} pending</Badge>
              )}
              {g.feedback.length > 0 && (
                <Badge tone="brand">{g.feedback.length} notes</Badge>
              )}
              <div style={{ flex: 1 }} />
              {g.additions.length > 0 && (
                <button
                  onClick={() => approveMany(g.additions, g.machine)}
                  disabled={busy !== null}
                  style={{
                    padding: "5px 10px",
                    fontSize: 11,
                    fontWeight: 700,
                    borderRadius: 6,
                    border: "1px solid var(--brand)",
                    background: "var(--brand-tint)",
                    color: "var(--brand)",
                    cursor: "pointer",
                  }}
                >
                  {busy === g.machine ? "…" : "✓ Accept all"}
                </button>
              )}
            </div>

            {/* Additions */}
            {g.additions.map((r) => (
              <div
                key={r.dispatch_id}
                className="flex items-center gap-2 flex-wrap"
                style={{
                  padding: "8px 16px",
                  borderBottom: "1px solid var(--line)",
                  fontSize: 13,
                }}
              >
                <span style={{ fontWeight: 600, color: "var(--ink)" }}>
                  {r.boonz_product_name ?? r.pod_product_name ?? "—"}
                </span>
                <Badge tone="gold">
                  ⚑ {r.review_reason ?? "review"} · {r.quantity}u
                </Badge>
                <span style={{ fontSize: 11, color: "var(--muted)" }}>
                  {r.shelf_code ?? "—"} · {r.action} · {r.dispatch_date}
                </span>
                <div style={{ flex: 1 }} />
                <button
                  onClick={() => approveOne(r, "accepted")}
                  disabled={busy !== null}
                  style={{
                    padding: "4px 10px",
                    fontSize: 11,
                    fontWeight: 700,
                    borderRadius: 6,
                    border: "none",
                    background: "var(--success-bg)",
                    color: "var(--success)",
                    cursor: "pointer",
                  }}
                >
                  {busy === r.dispatch_id ? "…" : "✓ Accept"}
                </button>
                <button
                  onClick={() => approveOne(r, "rejected")}
                  disabled={busy !== null}
                  style={{
                    padding: "4px 10px",
                    fontSize: 11,
                    fontWeight: 700,
                    borderRadius: 6,
                    border: "1px solid var(--danger)",
                    background: "var(--surface)",
                    color: "var(--danger)",
                    cursor: "pointer",
                  }}
                >
                  ✗
                </button>
              </div>
            ))}

            {/* Feedback notes */}
            {g.feedback.map((f) => (
              <div
                key={f.feedback_id}
                style={{
                  padding: "8px 16px",
                  borderBottom: "1px solid var(--line)",
                  fontSize: 12.5,
                }}
              >
                <div className="flex items-center gap-2 flex-wrap">
                  {f.slot_code && <Badge tone="muted">{f.slot_code}</Badge>}
                  {f.product_name && (
                    <span style={{ fontWeight: 600, color: "var(--ink)" }}>
                      {f.product_name}
                    </span>
                  )}
                  {f.direction && <Badge tone="brand">{f.direction}</Badge>}
                  <Badge
                    tone={
                      f.signal_source === "customer_request"
                        ? "danger"
                        : f.signal_source === "sale_anomaly"
                          ? "warn"
                          : "muted"
                    }
                  >
                    {f.signal_source}
                  </Badge>
                  <span style={{ fontSize: 10, color: "var(--muted-2)" }}>
                    conf {f.confidence}/3
                  </span>
                  <span
                    style={{
                      marginLeft: "auto",
                      fontSize: 10,
                      color: "var(--muted-2)",
                    }}
                  >
                    {new Date(f.created_at).toLocaleString()}
                  </span>
                </div>
                <div style={{ marginTop: 2, color: "var(--muted)" }}>
                  {f.note_text}
                </div>
              </div>
            ))}
          </div>
        ))}
      </div>

      <p style={{ fontSize: 11, color: "var(--muted-2)", margin: "14px 4px" }}>
        Additions are accepted with an audit note via{" "}
        <code>review_driver_addition</code> — nothing changes the books
        silently. Feedback notes are read-only signal the refill brain consumes
        (weights: customer_request 3× · sale_anomaly 2× · observation 1×).
        Engine signals and the issue board live in Refill &amp; Dispatch →
        Signals / Issues.
      </p>
    </div>
  );
}
