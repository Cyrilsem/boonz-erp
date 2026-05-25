"use client";

// PRD-Phase-G v2 B.4: per-row movement trail drawer.
// Consumes the v_wh_inventory_movement_trail view (C.5). Lazy-loads when the
// section is expanded so the drawer's primary edit path stays snappy.

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface TrailEvent {
  wh_inventory_id: string;
  event_class:
    | "inventory_audit"
    | "write_audit"
    | "dispatch"
    | "po_provenance"
    | "control_attempt";
  event_time: string;
  actor: string | null;
  summary: string;
  payload: Record<string, unknown>;
}

interface MovementTrailProps {
  whInventoryId: string;
}

const CLASS_LABEL: Record<TrailEvent["event_class"], string> = {
  inventory_audit: "Inventory audit",
  write_audit: "Write audit",
  dispatch: "Dispatch",
  po_provenance: "PO provenance",
  control_attempt: "Control attempt",
};

const CLASS_COLOR: Record<TrailEvent["event_class"], string> = {
  inventory_audit: "#3b6d11",
  write_audit: "#185fa5",
  dispatch: "#854f0b",
  po_provenance: "#6b6860",
  control_attempt: "#7c2d12",
};

function formatEventTime(iso: string): string {
  const d = new Date(iso);
  return (
    d.toLocaleDateString("en-AE", {
      day: "numeric",
      month: "short",
      year: "2-digit",
    }) +
    " " +
    d.toLocaleTimeString("en-AE", { hour: "numeric", minute: "2-digit" })
  );
}

export function MovementTrail({ whInventoryId }: MovementTrailProps) {
  const [open, setOpen] = useState(false);
  const [events, setEvents] = useState<TrailEvent[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    // Reset when the row changes.
    setOpen(false);
    setEvents(null);
    setError(null);
  }, [whInventoryId]);

  async function loadTrail() {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const { data, error: err } = await supabase
      .from("v_wh_inventory_movement_trail")
      .select("*")
      .eq("wh_inventory_id", whInventoryId)
      .order("event_time", { ascending: false })
      .limit(500);
    setLoading(false);
    if (err) {
      setError(err.message);
      return;
    }
    setEvents((data as TrailEvent[]) ?? []);
  }

  function toggle() {
    const next = !open;
    setOpen(next);
    if (next && events === null && !loading) loadTrail();
  }

  return (
    <div
      style={{
        marginTop: 24,
        borderTop: "1px solid #e8e4de",
        paddingTop: 16,
      }}
    >
      <button
        type="button"
        onClick={toggle}
        style={{
          width: "100%",
          textAlign: "left",
          background: "transparent",
          border: "none",
          padding: 0,
          cursor: "pointer",
          fontSize: 11,
          fontWeight: 700,
          letterSpacing: "0.1em",
          textTransform: "uppercase",
          color: "#6b6860",
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
        }}
      >
        <span>Movement trail</span>
        <span style={{ fontSize: 14 }}>{open ? "−" : "+"}</span>
      </button>

      {open && (
        <div style={{ marginTop: 12 }}>
          {loading && (
            <p style={{ fontSize: 13, color: "#6b6860" }}>Loading trail…</p>
          )}
          {error && (
            <p style={{ fontSize: 13, color: "#dc2626" }}>
              Failed to load trail: {error}
            </p>
          )}
          {events && events.length === 0 && !loading && (
            <p style={{ fontSize: 13, color: "#6b6860" }}>
              No movement events recorded for this row.
            </p>
          )}
          {events && events.length > 0 && (
            <ul
              style={{
                listStyle: "none",
                padding: 0,
                margin: 0,
                display: "flex",
                flexDirection: "column",
                gap: 8,
              }}
            >
              {events.map((ev, idx) => (
                <li
                  key={idx}
                  style={{
                    border: "1px solid #f0ece5",
                    borderRadius: 6,
                    padding: "8px 10px",
                    background: "#faf9f7",
                  }}
                >
                  <div
                    style={{
                      display: "flex",
                      justifyContent: "space-between",
                      alignItems: "baseline",
                      gap: 8,
                      marginBottom: 4,
                    }}
                  >
                    <span
                      style={{
                        fontSize: 10,
                        fontWeight: 700,
                        letterSpacing: "0.1em",
                        textTransform: "uppercase",
                        color: CLASS_COLOR[ev.event_class],
                      }}
                    >
                      {CLASS_LABEL[ev.event_class]}
                    </span>
                    <span style={{ fontSize: 11, color: "#6b6860" }}>
                      {formatEventTime(ev.event_time)}
                    </span>
                  </div>
                  <p
                    style={{
                      margin: 0,
                      fontSize: 13,
                      color: "#0a0a0a",
                      wordBreak: "break-word",
                    }}
                  >
                    {ev.summary}
                  </p>
                  {ev.actor && (
                    <p
                      style={{
                        margin: "4px 0 0",
                        fontSize: 11,
                        color: "#6b6860",
                      }}
                    >
                      Actor: {ev.actor.slice(0, 8)}…
                    </p>
                  )}
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}
