"use client";

// PRD-114 §3.2 - "Sanity checks - expired products".
//
// The refill plan tells the driver what to PUT IN. Nothing told him what to
// CHECK. This is one more category at the END of the dispatch line list, styled
// exactly like the shelf groups above it, listing every batch already expired or
// expiring within 7 days, with a disposition chip per row.
//
// Two RPCs and nothing else. It never SELECTs pod_inventory and never writes
// day_close_events by hand - `authenticated` holds no write verb on that table,
// so it could not even if it tried (Article 3 / S-308, pinned by golden fixture
// 114 seq 20).
//
//   get_expiry_sanity_checks(machine)  - the rows
//   record_expiry_check(pod, outcome)  - one day_close_events row per batch
//
// A tap moves NO stock. Stock moves at day-close acknowledge, when CS clicks,
// through the existing archival path. That is the whole point of the design and
// it is why this component has no confirm dialog: nothing it does is irreversible
// before someone in the office looks at it.
//
// `severity` is decided by the backend, never sent from here. record_expiry_check
// recomputes it from the ledger and the real clock, so an expired row cannot be
// talked into accepting Exists by a client that renders the wrong chips.

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";

type Severity = "expired" | "expiring";
type Outcome = "exists" | "sold" | "remove" | "skip";

interface SanityRow {
  pod_inventory_id: string;
  shelf_id: string | null;
  shelf_code: string | null;
  boonz_product_id: string | null;
  product_name: string;
  qty: number;
  expiration_date: string;
  days_to_expiry: number;
  severity: Severity;
}

/** Chips a row offers. An expired batch cannot "exist and stay" - it either
 *  already sold or the driver pulls it. The backend enforces this too. */
const CHIPS: Record<Severity, { key: Outcome; label: string }[]> = {
  expired: [
    { key: "sold", label: "Sold" },
    { key: "remove", label: "Remove" },
  ],
  expiring: [
    { key: "exists", label: "Exists" },
    { key: "sold", label: "Sold" },
    { key: "remove", label: "Remove" },
    { key: "skip", label: "Skip" },
  ],
};

function formatDMY(iso: string): string {
  const [y, m, d] = iso.split("-");
  return `${d}/${m}/${y}`;
}

/** "expired 14 days ago" / "expires in 3 days" / "expires today" */
function expiryPhrase(days: number): string {
  if (days < 0)
    return `expired ${Math.abs(days)} day${days === -1 ? "" : "s"} ago`;
  if (days === 0) return "expires today";
  return `expires in ${days} day${days === 1 ? "" : "s"}`;
}

/** Everything the category needs for one machine on one date. Holds no React
 *  state, so the effect below can resolve it from a .then callback. */
type ChecksData = {
  rows: SanityRow[];
  outcomes: Record<string, Outcome>;
  locked: Record<string, boolean>;
  error: string | null;
};

async function loadChecks(
  machineId: string,
  eventDate?: string,
): Promise<ChecksData> {
  const empty = { rows: [], outcomes: {}, locked: {} };
  const supabase = createClient();

  const { data, error: rpcErr } = await supabase.rpc(
    "get_expiry_sanity_checks",
    { p_machine_id: machineId },
  );
  if (rpcErr) return { ...empty, error: rpcErr.message };
  const rows = (data ?? []) as SanityRow[];

  // Hydrate any dispositions already recorded for this machine on THIS date, so
  // a driver who reloads mid-visit does not lose what he already ticked. The
  // date filter is load-bearing: without it yesterday's disposition on the same
  // batch would render as today's answer.
  const { data: evData } = await supabase
    .from("v_day_close_events")
    .select("payload, acknowledged")
    .eq("kind", "expiry_check")
    .eq("machine_id", machineId)
    .eq("event_date", eventDate ?? getDubaiDate())
    .limit(10000);

  const outcomes: Record<string, Outcome> = {};
  const locked: Record<string, boolean> = {};
  (
    (evData ?? []) as {
      payload: { pod_inventory_id?: string; outcome?: Outcome } | null;
      acknowledged: boolean | null;
    }[]
  ).forEach((e) => {
    const pid = e.payload?.pod_inventory_id;
    const out = e.payload?.outcome;
    if (!pid || !out) return;
    outcomes[pid] = out;
    if (e.acknowledged) locked[pid] = true;
  });

  return { rows, outcomes, locked, error: null };
}

export default function ExpirySanityChecks({
  machineId,
  eventDate,
  readOnly = false,
}: {
  machineId: string;
  /** The trip date this check belongs to. Defaults to today (Dubai) backend-side. */
  eventDate?: string;
  readOnly?: boolean;
}) {
  const [rows, setRows] = useState<SanityRow[]>([]);
  const [outcomes, setOutcomes] = useState<Record<string, Outcome>>({});
  const [locked, setLocked] = useState<Record<string, boolean>>({});
  const [saving, setSaving] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    // Pure loader, resolved into state from inside .then rather than awaited in
    // the effect body: setState synchronously inside an effect trips
    // react-hooks/set-state-in-effect. Same shape DayCloseTab and RefillLogTab use.
    let alive = true;
    loadChecks(machineId, eventDate).then((res) => {
      if (!alive) return;
      setError(res.error);
      setRows(res.rows);
      setOutcomes(res.outcomes);
      setLocked(res.locked);
      // Auto-expanded whenever any expired row exists (§3.2). Amber-only stays
      // collapsed so a routine visit does not grow a wall of chips.
      setOpen(res.rows.some((r) => r.severity === "expired"));
      setLoading(false);
    });
    return () => {
      alive = false;
    };
  }, [machineId, eventDate]);

  async function tap(row: SanityRow, outcome: Outcome) {
    if (readOnly || locked[row.pod_inventory_id]) return;
    setSaving(row.pod_inventory_id);
    setError(null);
    const supabase = createClient();
    const { error: rpcErr } = await supabase.rpc("record_expiry_check", {
      p_pod_inventory_id: row.pod_inventory_id,
      p_outcome: outcome,
      ...(eventDate ? { p_event_date: eventDate } : {}),
    });
    setSaving(null);
    if (rpcErr) {
      setError(rpcErr.message);
      return;
    }
    setOutcomes((prev) => ({ ...prev, [row.pod_inventory_id]: outcome }));
  }

  if (loading) return null;
  // A clean machine renders nothing at all (§4.4). A machine whose checklist
  // FAILED to load must not render nothing - on a safety list, "no rows" and
  // "could not read the rows" look identical to the driver and only one of them
  // means there is nothing to check.
  if (rows.length === 0) {
    return error ? (
      <p className="mb-4 rounded-lg bg-rose-50 px-3 py-2 text-xs text-rose-700 dark:bg-rose-950/30 dark:text-rose-400">
        Could not load the expiry sanity checks: {error}. Check the shelves by
        eye and tell the office.
      </p>
    ) : null;
  }

  const nExpired = rows.filter((r) => r.severity === "expired").length;
  const nDone = rows.filter((r) => outcomes[r.pod_inventory_id]).length;

  return (
    <div className="mb-4" data-tour="expiry-sanity-checks">
      <button
        onClick={() => setOpen((v) => !v)}
        className="mb-2 flex w-full items-center justify-between gap-2 text-left"
      >
        <h2 className="text-sm font-semibold uppercase tracking-wide text-neutral-500">
          Sanity checks - expired products
        </h2>
        <div className="flex shrink-0 items-center gap-1.5 text-xs">
          {nExpired > 0 && (
            <span className="rounded bg-red-100 px-1.5 py-0.5 font-semibold text-red-700 dark:bg-red-950/40 dark:text-red-400">
              {nExpired} expired
            </span>
          )}
          <span className="rounded bg-neutral-100 px-1.5 py-0.5 font-medium text-neutral-600 dark:bg-neutral-800 dark:text-neutral-300">
            {nDone}/{rows.length}
          </span>
          <span className="text-neutral-400">{open ? "▾" : "▸"}</span>
        </div>
      </button>

      {open && (
        <>
          <p className="mb-2 text-xs text-neutral-400">
            Check each shelf and say what you found. Nothing moves stock now -
            the office closes these at day close.
          </p>

          {error && (
            <p className="mb-2 rounded-lg bg-rose-50 px-3 py-2 text-xs text-rose-700 dark:bg-rose-950/30 dark:text-rose-400">
              {error}
            </p>
          )}

          <ul className="space-y-2">
            {rows.map((row) => {
              const isExpired = row.severity === "expired";
              const chosen = outcomes[row.pod_inventory_id];
              const isLocked = readOnly || locked[row.pod_inventory_id];
              const busy = saving === row.pod_inventory_id;

              return (
                <li
                  key={row.pod_inventory_id}
                  className={`rounded-lg border p-3 ${
                    isExpired
                      ? "border-red-200 bg-red-50 dark:border-red-900/60 dark:bg-red-950/20"
                      : "border-amber-200 bg-amber-50 dark:border-amber-900/60 dark:bg-amber-950/20"
                  }`}
                >
                  <div className="mb-2 flex items-start justify-between gap-2">
                    <div className="min-w-0 flex-1">
                      <p className="text-sm font-medium">{row.product_name}</p>
                      <p className="text-xs text-neutral-500">
                        {/* An off-shelf batch is real stock with no slot. Say so
                            rather than rendering an empty shelf label. */}
                        {row.shelf_code
                          ? `Shelf ${row.shelf_code}`
                          : "No shelf on record"}{" "}
                        · {row.qty} unit{Number(row.qty) === 1 ? "" : "s"} ·{" "}
                        {formatDMY(row.expiration_date)}
                      </p>
                    </div>
                    <span
                      className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${
                        isExpired
                          ? "bg-red-100 text-red-700 dark:bg-red-950/40 dark:text-red-400"
                          : "bg-amber-100 text-amber-800 dark:bg-amber-950/40 dark:text-amber-400"
                      }`}
                    >
                      {isExpired
                        ? "⚠ Expired"
                        : expiryPhrase(row.days_to_expiry)}
                    </span>
                  </div>

                  <div className="flex flex-wrap gap-2">
                    {CHIPS[row.severity].map((chip) => {
                      const active = chosen === chip.key;
                      return (
                        <button
                          key={chip.key}
                          disabled={isLocked || busy}
                          onClick={() => tap(row, chip.key)}
                          className={`flex-1 rounded-lg border py-1.5 text-xs font-semibold transition-colors ${
                            active
                              ? "border-neutral-800 bg-neutral-800 text-white dark:border-neutral-200 dark:bg-neutral-200 dark:text-neutral-900"
                              : "border-neutral-300 bg-white text-neutral-600 hover:bg-neutral-50 disabled:opacity-50 dark:border-neutral-700 dark:bg-neutral-950 dark:text-neutral-300 dark:hover:bg-neutral-800"
                          }`}
                        >
                          {active ? "✓ " : ""}
                          {chip.label}
                        </button>
                      );
                    })}
                  </div>

                  {isExpired && !chosen && (
                    <p className="mt-2 text-[11px] text-red-700 dark:text-red-400">
                      This one cannot stay on the shelf. Say whether it sold or
                      you pulled it.
                    </p>
                  )}
                  {locked[row.pod_inventory_id] && (
                    <p className="mt-2 text-[11px] text-neutral-500">
                      Closed by the office - call them to reopen it.
                    </p>
                  )}
                </li>
              );
            })}
          </ul>
        </>
      )}
    </div>
  );
}
