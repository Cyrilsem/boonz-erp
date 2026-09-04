"use client";

// PRD-112 §3.3 - Day Close.
//
// The reviewable note at the end of the day. The driver absorbed whatever the
// venue actually had and kept moving; this is where CS closes the loop:
// inventory closed, refill closed, gaps acknowledged.
//
// PRD-119 §4.2: expiry_check rows are no longer a gate. The tap already wrote
// the shelf record at apply_expiry_check time (acknowledged_at is stamped by
// the system at write time, not by a CS click) — this page shows them as a
// read-only log, alongside what the WM confirmed and what is still sitting in
// her queue. The acknowledge mechanism stays live for substitution / spot_buy /
// stock_unverified rows (PRD-112, unchanged by this PRD).
//
// Reads, no derived stock arithmetic on the client:
//   v_day_close_events    - what the drivers changed (Changes) and the gaps those
//                           changes opened (spot buys, unverified stock).
//   day_close_checks()    - the five close checks, computed live in one call.
//   refill_dispatching    - the plan-side gaps (not filled, shortfall, review) for
//                           the same date, plus open drift candidates.
//   v_wm_confirmations    - the live Warehouse Confirmations queue (PRD-119),
//                           not date-scoped — it is always "what's open right now".
//
// Write path for substitution / spot_buy / stock_unverified only:
// acknowledge_day_close_event / acknowledge_day_close. expiry_check rows write
// nowhere from this page — apply_expiry_check already wrote them at the tap.

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import {
  Badge,
  Card,
  StatCard,
  type BadgeTone,
} from "@/components/ui/primitives";

const font = "'Plus Jakarta Sans', sans-serif";

type EventKind =
  | "substitution"
  | "not_filled"
  | "shortfall"
  | "spot_buy"
  | "stock_unverified"
  // PRD-114: a driver's disposition on one expiring batch. Acknowledging a
  // Remove or a Sold archives that batch; Exists and Skip write no stock.
  | "expiry_check";

/** PRD-119 §4 payload keys. Read from the event rather than re-derived: severity
 *  is a backend fact and this screen must not compute a second opinion of it. */
type ExpiryCheckPayload = {
  pod_inventory_id?: string;
  product_name?: string;
  qty?: number | string;
  expiration_date?: string;
  new_expiry?: string;
  severity?: "expired" | "expiring" | "date_unverified";
  outcome?: "removed" | "not_there" | "date_read";
  disposition_event_id?: string;
};

type WmQueueLine = {
  line_id: string;
  source: "dispatch_return" | "driver_expiry_check";
  machine_name: string;
  boonz_product_name: string;
  qty: number;
  age_hours: number;
};

type DayCloseEvent = {
  id: string;
  event_date: string;
  kind: EventKind;
  machine_id: string;
  machine_name: string | null;
  dispatch_id: string | null;
  shelf_code: string | null;
  old_product: string | null;
  new_product: string | null;
  planned_qty: number | null;
  filled_qty: number | null;
  reason: string | null;
  source_tag: string | null;
  review_reason: string | null;
  needs_review: boolean | null;
  pod_action: string | null;
  created_by_name: string | null;
  created_at: string;
  acknowledged_at: string | null;
  acknowledged: boolean;
  payload: ExpiryCheckPayload | null;
};

type CloseCheck = {
  key: string;
  label: string;
  count: number;
  ok: boolean;
};

type DispatchGapRow = {
  dispatch_id: string;
  machine_id: string;
  boonz_product_id: string | null;
  quantity: number | null;
  filled_quantity: number | null;
  pack_outcome: string | null;
  not_filled_reason: string | null;
  needs_review: boolean | null;
  review_status: string | null;
  review_reason: string | null;
  packed: boolean | null;
  picked_up: boolean | null;
  cancelled: boolean | null;
  skipped: boolean | null;
  include: boolean | null;
  shelf_configurations: { shelf_code: string } | null;
};

type DriftCandidate = {
  candidate_id: string;
  machine_id: string;
  boonz_product_id: string | null;
  planned_qty: number | null;
  filled_qty: number | null;
  qty_gap: number | null;
  notes: string | null;
};

/** A gap is a thing CS has to look at that the driver did NOT self-serve. */
type Gap = {
  key: string;
  kind: "not_filled" | "shortfall" | "needs_review" | "drift";
  machine: string;
  shelf: string | null;
  product: string;
  planned: number | null;
  filled: number | null;
  note: string | null;
};

const GAP_META: Record<Gap["kind"], { label: string; tone: BadgeTone }> = {
  not_filled: { label: "not filled", tone: "warn" },
  shortfall: { label: "shortfall", tone: "gold" },
  needs_review: { label: "needs review", tone: "danger" },
  drift: { label: "drift open", tone: "brand" },
};

/** PRD-119 §4. What the driver's tap already did — said in the words of the
 *  consequence rather than the enum. This is a log of a write that already
 *  happened at the tap, not a description of what acknowledging will do. */
const EXPIRY_OUTCOME_LABEL: Record<string, string> = {
  removed: "driver pulled it (written off)",
  not_there: "not on the shelf (closed)",
  date_read: "driver read the label (date corrected)",
};

const REVIEW_REASON_LABEL: Record<string, string> = {
  substitution_spot_buy: "driver bought it himself",
  substitution_stock_unverified: "no warehouse batch matched",
  substitution_unmapped_product: "product is not mapped on this machine",
};

function qty(n: number | null | undefined): string {
  return n === null || n === undefined ? "-" : String(n);
}

/** postgres numeric -> number, preserving null. */
function num(v: number | string | null | undefined): number | null {
  if (v === null || v === undefined) return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

/** Everything the panel shows for one date. */
type DayCloseData = {
  date: string;
  events: DayCloseEvent[];
  checks: CloseCheck[] | null;
  gaps: Gap[];
  wmQueue: WmQueueLine[];
  error: string | null;
};

/**
 * Pure loader: reads, cross-references, returns. It holds no React state, so
 * the effect below can setState from inside a .then callback rather than
 * synchronously in the effect body (react-hooks/set-state-in-effect), which is
 * the same shape RefillLogTab uses.
 */
async function loadDayClose(selectedDate: string): Promise<DayCloseData> {
  const supabase = createClient();

  const [
    { data: eventData, error: eventErr },
    { data: checkData, error: checkErr },
    { data: lineData },
    { data: driftData },
    { data: machineData },
    { data: productData },
    { data: wmData },
  ] = await Promise.all([
    supabase
      .from("v_day_close_events")
      .select(
        "id, event_date, kind, machine_id, machine_name, dispatch_id, shelf_code, old_product, new_product, planned_qty, filled_qty, reason, source_tag, review_reason, needs_review, pod_action, created_by_name, created_at, acknowledged_at, acknowledged, payload",
      )
      .eq("event_date", selectedDate)
      .order("created_at", { ascending: true })
      .limit(10000),
    supabase.rpc("day_close_checks", { p_date: selectedDate }),
    supabase
      .from("refill_dispatching")
      .select(
        "dispatch_id, machine_id, boonz_product_id, quantity, filled_quantity, pack_outcome, not_filled_reason, needs_review, review_status, review_reason, packed, picked_up, cancelled, skipped, include, shelf_configurations(shelf_code)",
      )
      .eq("dispatch_date", selectedDate)
      .limit(10000),
    supabase
      .from("inventory_drift_candidates")
      .select(
        "candidate_id, machine_id, boonz_product_id, planned_qty, filled_qty, qty_gap, notes",
      )
      .eq("dispatch_date", selectedDate)
      .eq("status", "pending_review")
      .limit(10000),
    supabase.from("machines").select("machine_id, official_name").limit(10000),
    supabase
      .from("boonz_products")
      .select("product_id, boonz_product_name")
      .limit(10000),
    // PRD-119 §4.2: the live Warehouse Confirmations queue — not date-scoped,
    // always "what's open right now" regardless of which day is selected above.
    supabase
      .from("v_wm_confirmations")
      .select(
        "line_id, source, machine_name, boonz_product_name, qty, age_hours",
      )
      .order("age_hours", { ascending: false })
      .limit(10000),
  ]);

  const machineName: Record<string, string> = {};
  (
    (machineData ?? []) as {
      machine_id: string;
      official_name: string | null;
    }[]
  ).forEach((m) => {
    machineName[m.machine_id] = m.official_name ?? m.machine_id.slice(0, 8);
  });
  const productName: Record<string, string> = {};
  (
    (productData ?? []) as {
      product_id: string;
      boonz_product_name: string;
    }[]
  ).forEach((p) => {
    productName[p.product_id] = p.boonz_product_name;
  });

  // Gaps. The date filter already scopes this to one day, so the class checks
  // below are pure row-shape tests; cancelled / skipped / excluded lines are
  // inert by PRD-028 and are not gaps anybody has to close.
  const out: Gap[] = [];
  for (const r of (lineData ?? []) as unknown as DispatchGapRow[]) {
    if (r.include === false || r.cancelled === true || r.skipped === true)
      continue;
    const shelf = r.shelf_configurations?.shelf_code ?? null;
    const product = r.boonz_product_id
      ? (productName[r.boonz_product_id] ?? r.boonz_product_id.slice(0, 8))
      : "-";
    const machine = machineName[r.machine_id] ?? r.machine_id.slice(0, 8);
    // quantity / filled_quantity are postgres numeric. PostgREST emits them as
    // JSON numbers, but the shortfall branch compares and subtracts them, and a
    // string "10" < "9" would silently invent a gap. Coerced once, here.
    const filled = num(r.filled_quantity);
    const planned = num(r.quantity);

    if (r.pack_outcome === "not_filled" || r.not_filled_reason) {
      out.push({
        key: `nf-${r.dispatch_id}`,
        kind: "not_filled",
        machine,
        shelf,
        product,
        planned,
        filled: filled ?? 0,
        note: r.not_filled_reason,
      });
    } else if (
      filled !== null &&
      filled > 0 &&
      planned !== null &&
      filled < planned &&
      (r.packed === true || r.picked_up === true)
    ) {
      out.push({
        key: `sf-${r.dispatch_id}`,
        kind: "shortfall",
        machine,
        shelf,
        product,
        planned,
        filled,
        note: `${planned - filled} short`,
      });
    }

    // A row can be short AND flagged; the review is its own gap because it is
    // closed by a different action (CS review, not a re-pack).
    if (
      r.needs_review === true &&
      (r.review_status === null ||
        r.review_status === "none" ||
        r.review_status === "pending")
    ) {
      out.push({
        key: `nr-${r.dispatch_id}`,
        kind: "needs_review",
        machine,
        shelf,
        product,
        planned,
        filled,
        note: r.review_reason
          ? (REVIEW_REASON_LABEL[r.review_reason] ?? r.review_reason)
          : null,
      });
    }
  }
  for (const d of (driftData ?? []) as DriftCandidate[]) {
    out.push({
      key: `dr-${d.candidate_id}`,
      kind: "drift",
      machine: machineName[d.machine_id] ?? d.machine_id.slice(0, 8),
      shelf: null,
      product: d.boonz_product_id
        ? (productName[d.boonz_product_id] ?? d.boonz_product_id.slice(0, 8))
        : "-",
      planned: num(d.planned_qty),
      filled: num(d.filled_qty),
      note: d.notes ?? (d.qty_gap !== null ? `gap ${d.qty_gap}` : null),
    });
  }
  return {
    date: selectedDate,
    events: (eventData as DayCloseEvent[] | null) ?? [],
    checks: ((checkData as { checks?: CloseCheck[] } | null)?.checks ??
      null) as CloseCheck[] | null,
    gaps: out,
    wmQueue: (wmData as WmQueueLine[] | null) ?? [],
    error: eventErr?.message ?? checkErr?.message ?? null,
  };
}

export default function DayCloseTab({
  selectedDate,
}: {
  selectedDate: string;
}) {
  const [data, setData] = useState<DayCloseData | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [note, setNote] = useState("");
  const [showAcknowledged, setShowAcknowledged] = useState(false);
  const [ackErr, setAckErr] = useState<string | null>(null);

  // Stale results from a previous date are dropped rather than rendered under
  // the new date's header.
  const loading = data === null || data.date !== selectedDate;
  const events = useMemo(() => data?.events ?? [], [data]);
  const checks = data?.checks ?? null;
  const gaps = data?.gaps ?? [];
  const wmQueue = data?.wmQueue ?? [];
  const err = ackErr ?? data?.error ?? null;

  useEffect(() => {
    let alive = true;
    loadDayClose(selectedDate).then((d) => {
      if (alive) setData(d);
    });
    return () => {
      alive = false;
    };
  }, [selectedDate]);

  const refresh = useCallback(async () => {
    const d = await loadDayClose(selectedDate);
    setData(d);
  }, [selectedDate]);

  // PRD-114 §3.3: expiry_check rows sit under Changes, not Gaps. They are a
  // thing the driver DID and CS confirms, the same shape as a substitution -
  // not a hole someone still has to chase.
  const changes = useMemo(
    () =>
      events.filter(
        (e) => e.kind === "substitution" || e.kind === "expiry_check",
      ),
    [events],
  );
  // spot_buy / stock_unverified rows are the gap side of a substitution: the
  // change itself is recorded above, this is the part CS still has to chase.
  const eventGaps = useMemo(
    () =>
      events.filter(
        (e) => e.kind !== "substitution" && e.kind !== "expiry_check",
      ),
    [events],
  );
  const openCount = useMemo(
    () => events.filter((e) => !e.acknowledged).length,
    [events],
  );
  // PRD-119 §4.2: driver expiry taps are a read-only log now — count them
  // separately from the acknowledge-gated substitution/spot_buy/stock_unverified
  // rows so the summary reads "what Jojo did" rather than "what's still open".
  const expiryTapsApplied = useMemo(
    () => events.filter((e) => e.kind === "expiry_check").length,
    [events],
  );

  const visibleChanges = showAcknowledged
    ? changes
    : changes.filter((e) => !e.acknowledged);
  const visibleEventGaps = showAcknowledged
    ? eventGaps
    : eventGaps.filter((e) => !e.acknowledged);

  async function acknowledgeOne(id: string) {
    setBusyId(id);
    setAckErr(null);
    const supabase = createClient();
    const { error } = await supabase.rpc("acknowledge_day_close_event", {
      p_event_id: id,
      p_note: note.trim() || null,
    });
    setAckErr(error?.message ?? null);
    await refresh();
    setBusyId(null);
  }

  async function acknowledgeAll() {
    setBusyId("__all__");
    setAckErr(null);
    const supabase = createClient();
    const { error } = await supabase.rpc("acknowledge_day_close", {
      p_event_date: selectedDate,
      p_note: note.trim() || null,
    });
    setAckErr(error?.message ?? null);
    await refresh();
    setBusyId(null);
  }

  if (loading) {
    return (
      <div className="p-6" style={{ fontFamily: font, color: "var(--muted)" }}>
        Loading day close…
      </div>
    );
  }

  return (
    <div className="p-6" style={{ fontFamily: font }}>
      {err && (
        <div
          style={{
            background: "var(--danger-bg)",
            color: "var(--danger)",
            border: "1px solid var(--line)",
            borderRadius: 8,
            padding: "10px 12px",
            fontSize: 13,
            marginBottom: 16,
          }}
        >
          {err}
        </div>
      )}

      {/* ── Summary ─────────────────────────────────────────────────────────── */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-5 mb-6">
        <StatCard
          label="Driver taps applied"
          value={expiryTapsApplied}
          sub={selectedDate}
        />
        <StatCard
          label="WM queue open"
          value={wmQueue.length}
          accent={wmQueue.length > 0 ? "var(--warn)" : "var(--success)"}
        />
        <StatCard
          label="Gaps open"
          value={
            (gaps ?? []).length +
            eventGaps.filter((e) => !e.acknowledged).length
          }
          accent="var(--warn)"
        />
        <StatCard
          label="Awaiting acknowledge"
          value={openCount}
          accent={openCount > 0 ? "var(--warn)" : "var(--success)"}
        />
        <StatCard
          label="Checks red"
          value={(checks ?? []).filter((c) => !c.ok).length}
          accent={
            (checks ?? []).some((c) => !c.ok)
              ? "var(--danger)"
              : "var(--success)"
          }
        />
      </div>

      {/* ── Warehouse Confirmations queue (PRD-119 §4.1/§4.2) ──────────────────
          Read-only here — the WM confirms from her own tab. This is just
          visibility: what's still sitting in her queue, and for how long. */}
      <Card style={{ marginBottom: 20 }}>
        <div
          style={{
            fontSize: 11,
            fontWeight: 700,
            letterSpacing: "0.08em",
            textTransform: "uppercase",
            color: "var(--muted)",
            marginBottom: 10,
          }}
        >
          Warehouse Confirmations — open ({wmQueue.length})
        </div>
        {wmQueue.length === 0 ? (
          <div style={{ fontSize: 13, color: "var(--muted)" }}>
            Nothing waiting on the WM right now.
          </div>
        ) : (
          <ul style={{ display: "grid", gap: 6 }}>
            {wmQueue.map((line) => {
              const old = line.age_hours > 48;
              return (
                <li
                  key={line.line_id}
                  style={{
                    display: "flex",
                    alignItems: "center",
                    gap: 10,
                    fontSize: 13,
                  }}
                >
                  <span style={{ flex: 1 }}>
                    {line.boonz_product_name} · {line.machine_name} ·{" "}
                    {qty(line.qty)} units
                  </span>
                  <span
                    style={{
                      color: old ? "var(--danger)" : "var(--muted)",
                      fontWeight: old ? 700 : 400,
                    }}
                  >
                    {Math.round(line.age_hours)}h
                  </span>
                </li>
              );
            })}
          </ul>
        )}
      </Card>

      {/* ── Close checks (PRD §3.3.3) ───────────────────────────────────────── */}
      <Card style={{ marginBottom: 20 }}>
        <div
          style={{
            fontSize: 11,
            fontWeight: 700,
            letterSpacing: "0.08em",
            textTransform: "uppercase",
            color: "var(--muted)",
            marginBottom: 10,
          }}
        >
          Close checks
        </div>
        {checks === null ? (
          <div style={{ fontSize: 13, color: "var(--muted)" }}>
            Checks unavailable.
          </div>
        ) : (
          <ul style={{ display: "grid", gap: 6 }}>
            {checks.map((c) => (
              <li
                key={c.key}
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 10,
                  fontSize: 13,
                }}
              >
                <span
                  aria-hidden
                  style={{
                    width: 9,
                    height: 9,
                    borderRadius: 999,
                    flexShrink: 0,
                    background: c.ok ? "var(--success)" : "var(--danger)",
                  }}
                />
                <span style={{ flex: 1 }}>{c.label}</span>
                <span
                  style={{
                    color: c.ok ? "var(--success)" : "var(--danger)",
                    fontWeight: 700,
                  }}
                >
                  {c.ok ? "clear" : c.count}
                </span>
              </li>
            ))}
          </ul>
        )}
      </Card>

      {/* ── Acknowledge bar ─────────────────────────────────────────────────── */}
      <Card style={{ marginBottom: 20 }}>
        <div className="flex flex-wrap items-center gap-3">
          <input
            type="text"
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="Note recorded with the acknowledge (optional)"
            style={{
              flex: "1 1 260px",
              padding: "8px 10px",
              fontSize: 13,
              border: "1px solid var(--line)",
              borderRadius: 8,
              background: "var(--surface)",
              fontFamily: font,
            }}
          />
          <button
            onClick={acknowledgeAll}
            disabled={openCount === 0 || busyId !== null}
            style={{
              padding: "8px 14px",
              fontSize: 13,
              fontWeight: 700,
              borderRadius: 8,
              border: "none",
              cursor: openCount === 0 ? "not-allowed" : "pointer",
              opacity: openCount === 0 || busyId !== null ? 0.5 : 1,
              background: "#24544a",
              color: "#fff",
              fontFamily: font,
            }}
          >
            {busyId === "__all__"
              ? "Acknowledging…"
              : `Acknowledge all (${openCount})`}
          </button>
          <label
            style={{
              fontSize: 12,
              color: "var(--muted)",
              display: "flex",
              alignItems: "center",
              gap: 6,
            }}
          >
            <input
              type="checkbox"
              checked={showAcknowledged}
              onChange={(e) => setShowAcknowledged(e.target.checked)}
            />
            Show acknowledged
          </label>
        </div>
        <p style={{ fontSize: 11, color: "var(--muted-2)", marginTop: 8 }}>
          Acknowledging a substitution is what moves machine stock. Nothing on
          this page writes pod_inventory before you click.
        </p>
      </Card>

      {/* ── 1. Changes ──────────────────────────────────────────────────────── */}
      <SectionTitle>Changes ({visibleChanges.length})</SectionTitle>
      {visibleChanges.length === 0 ? (
        <Empty>
          {changes.length === 0
            ? "No product changes on this date."
            : "All changes acknowledged."}
        </Empty>
      ) : (
        <ul style={{ display: "grid", gap: 8, marginBottom: 24 }}>
          {visibleChanges.map((e) => (
            <li key={e.id}>
              <Card>
                <div className="flex flex-wrap items-center gap-2">
                  {/* PRD-119 §4: red for expired/expiring, amber for a DATE?
                      lot. Severity is read off the event, never recomputed
                      here - the backend decided it at tap time. */}
                  {e.kind === "expiry_check" && (
                    <Badge
                      tone={
                        e.payload?.severity === "date_unverified"
                          ? "warn"
                          : "danger"
                      }
                    >
                      {e.payload?.severity === "date_unverified"
                        ? "date?"
                        : (e.payload?.severity ?? "expiring")}
                    </Badge>
                  )}
                  <strong style={{ fontSize: 13 }}>{e.machine_name}</strong>
                  {e.shelf_code && <Badge tone="muted">{e.shelf_code}</Badge>}
                  {e.source_tag && <Badge tone="brand">{e.source_tag}</Badge>}
                  {e.needs_review && (
                    <Badge tone="warn">
                      {e.review_reason
                        ? (REVIEW_REASON_LABEL[e.review_reason] ??
                          e.review_reason)
                        : "needs review"}
                    </Badge>
                  )}
                  {e.kind === "expiry_check" ? (
                    <Badge tone="success">applied at tap</Badge>
                  ) : (
                    e.acknowledged && <Badge tone="success">acknowledged</Badge>
                  )}
                  <span style={{ flex: 1 }} />
                  {/* PRD-119 §4.2: expiry_check rows already wrote the shelf
                      record at apply_expiry_check time — nothing to acknowledge. */}
                  {e.kind !== "expiry_check" && !e.acknowledged && (
                    <button
                      onClick={() => acknowledgeOne(e.id)}
                      disabled={busyId !== null}
                      style={{
                        padding: "5px 11px",
                        fontSize: 12,
                        fontWeight: 700,
                        borderRadius: 7,
                        border: "1px solid var(--line)",
                        background: "var(--surface)",
                        cursor: "pointer",
                        opacity: busyId !== null ? 0.5 : 1,
                        fontFamily: font,
                      }}
                    >
                      {busyId === e.id ? "Closing…" : "Acknowledge"}
                    </button>
                  )}
                </div>
                {e.kind === "expiry_check" ? (
                  <>
                    <div style={{ fontSize: 13, marginTop: 6 }}>
                      <strong>{e.payload?.product_name ?? "?"}</strong>{" "}
                      <span style={{ color: "var(--muted)" }}>&rarr;</span>{" "}
                      <strong>
                        {EXPIRY_OUTCOME_LABEL[e.payload?.outcome ?? ""] ??
                          e.payload?.outcome ??
                          "?"}
                      </strong>
                    </div>
                    <div
                      style={{
                        fontSize: 12,
                        color: "var(--muted)",
                        marginTop: 3,
                      }}
                    >
                      {qty(num(e.payload?.qty ?? null))} unit
                      {Number(e.payload?.qty) === 1 ? "" : "s"} · expiry{" "}
                      {e.payload?.outcome === "date_read"
                        ? (e.payload?.new_expiry ?? "?")
                        : (e.payload?.expiration_date ?? "no date")}
                      {e.created_by_name ? ` · ${e.created_by_name}` : ""}
                    </div>
                  </>
                ) : (
                  <>
                    <div style={{ fontSize: 13, marginTop: 6 }}>
                      {e.old_product ?? "?"}{" "}
                      <span style={{ color: "var(--muted)" }}>&rarr;</span>{" "}
                      <strong>{e.new_product ?? "?"}</strong>
                    </div>
                    <div
                      style={{
                        fontSize: 12,
                        color: "var(--muted)",
                        marginTop: 3,
                      }}
                    >
                      filled {qty(e.filled_qty)} of {qty(e.planned_qty)} planned
                      {e.created_by_name ? ` · ${e.created_by_name}` : ""}
                      {e.reason ? ` · "${e.reason}"` : ""}
                    </div>
                  </>
                )}
                {e.acknowledged && e.pod_action && (
                  <div
                    style={{
                      fontSize: 11,
                      color: "var(--muted-2)",
                      marginTop: 3,
                    }}
                  >
                    pod_inventory: {e.pod_action.replace(/_/g, " ")}
                  </div>
                )}
              </Card>
            </li>
          ))}
        </ul>
      )}

      {/* ── 2. Gaps ─────────────────────────────────────────────────────────── */}
      <SectionTitle>
        Gaps ({visibleEventGaps.length + (gaps ?? []).length})
      </SectionTitle>
      {visibleEventGaps.length === 0 && (gaps ?? []).length === 0 ? (
        <Empty>Nothing open on this date.</Empty>
      ) : (
        <ul style={{ display: "grid", gap: 8, marginBottom: 24 }}>
          {visibleEventGaps.map((e) => (
            <li key={e.id}>
              <Card>
                <div className="flex flex-wrap items-center gap-2">
                  <Badge tone="danger">{e.kind.replace(/_/g, " ")}</Badge>
                  <strong style={{ fontSize: 13 }}>{e.machine_name}</strong>
                  {e.shelf_code && <Badge tone="muted">{e.shelf_code}</Badge>}
                  {e.acknowledged && <Badge tone="success">acknowledged</Badge>}
                  <span style={{ flex: 1 }} />
                  {!e.acknowledged && (
                    <button
                      onClick={() => acknowledgeOne(e.id)}
                      disabled={busyId !== null}
                      style={{
                        padding: "5px 11px",
                        fontSize: 12,
                        fontWeight: 700,
                        borderRadius: 7,
                        border: "1px solid var(--line)",
                        background: "var(--surface)",
                        cursor: "pointer",
                        opacity: busyId !== null ? 0.5 : 1,
                        fontFamily: font,
                      }}
                    >
                      {busyId === e.id ? "Closing…" : "Acknowledge"}
                    </button>
                  )}
                </div>
                <div style={{ fontSize: 13, marginTop: 6 }}>
                  {e.new_product ?? "-"} · {qty(e.filled_qty)} units
                </div>
                {e.review_reason && (
                  <div
                    style={{
                      fontSize: 12,
                      color: "var(--muted)",
                      marginTop: 3,
                    }}
                  >
                    {REVIEW_REASON_LABEL[e.review_reason] ?? e.review_reason}
                  </div>
                )}
              </Card>
            </li>
          ))}
          {(gaps ?? []).map((g) => {
            const meta = GAP_META[g.kind];
            return (
              <li key={g.key}>
                <Card>
                  <div className="flex flex-wrap items-center gap-2">
                    <Badge tone={meta.tone}>{meta.label}</Badge>
                    <strong style={{ fontSize: 13 }}>{g.machine}</strong>
                    {g.shelf && <Badge tone="muted">{g.shelf}</Badge>}
                  </div>
                  <div style={{ fontSize: 13, marginTop: 6 }}>{g.product}</div>
                  <div
                    style={{
                      fontSize: 12,
                      color: "var(--muted)",
                      marginTop: 3,
                    }}
                  >
                    planned {qty(g.planned)} · filled {qty(g.filled)}
                    {g.note ? ` · ${g.note}` : ""}
                  </div>
                </Card>
              </li>
            );
          })}
        </ul>
      )}

      <p style={{ fontSize: 11, color: "var(--muted-2)" }}>
        Drift candidates are reviewed on the{" "}
        <Link
          href="/refill/drift"
          style={{ color: "var(--brand)", textDecoration: "underline" }}
        >
          Inventory drift
        </Link>{" "}
        page; they are listed here so the day is closed against one list.
      </p>
    </div>
  );
}

function SectionTitle({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        fontSize: 11,
        fontWeight: 700,
        letterSpacing: "0.08em",
        textTransform: "uppercase",
        color: "var(--muted)",
        margin: "0 0 10px",
      }}
    >
      {children}
    </div>
  );
}

function Empty({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        fontSize: 13,
        color: "var(--muted)",
        padding: "12px 0 24px",
      }}
    >
      {children}
    </div>
  );
}
