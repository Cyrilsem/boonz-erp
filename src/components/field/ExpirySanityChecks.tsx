"use client";

// PRD-119 §4 - "Sanity checks - expiry" (re-scopes PRD-114 §3.2, same category,
// same style, new semantics).
//
// The tap now writes immediately through apply_expiry_check - the shelf record
// changes at the driver's tap (the unit physically left the shelf), not at a CS
// day-close acknowledge that historical evidence shows never comes (8 taps since
// 12 Aug, 0 ever acknowledged). A resolved row simply leaves the list; there is
// no locked/acknowledged state to hydrate or display here anymore.
//
// Two RPCs and nothing else:
//   get_expiry_sanity_checks(machine)                 - the open rows
//   apply_expiry_check(pod, outcome, qty?, new_expiry?) - the tap write
//
// Row conditions and answers:
//   expired / expiring (dated, <=3d)  -> Removed (count, pre-filled) · Not there
//   date_unverified (DATE?, no lot)   -> Date read (date picker) · Not there
// No Exists, no Skip - an expired or short-dated batch cannot stay on the shelf
// by staying silent about it.

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

type Severity = "expired" | "expiring" | "date_unverified";
type Outcome = "removed" | "not_there" | "date_read";

interface SanityRow {
  pod_inventory_id: string;
  shelf_id: string | null;
  shelf_code: string | null;
  boonz_product_id: string | null;
  product_name: string;
  qty: number;
  expiration_date: string | null;
  days_to_expiry: number | null;
  severity: Severity;
}

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

export default function ExpirySanityChecks({
  machineId,
  readOnly = false,
}: {
  machineId: string;
  readOnly?: boolean;
}) {
  const [rows, setRows] = useState<SanityRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [qtyDraft, setQtyDraft] = useState<Record<string, number>>({});
  const [dateDraft, setDateDraft] = useState<Record<string, string>>({});

  useEffect(() => {
    // Pure loader, resolved into state from inside .then rather than awaited in
    // the effect body: setState synchronously inside an effect trips
    // react-hooks/set-state-in-effect. Same shape DayCloseTab and RefillLogTab use.
    let alive = true;
    const supabase = createClient();
    supabase
      .rpc("get_expiry_sanity_checks", { p_machine_id: machineId })
      .then(({ data, error: rpcErr }) => {
        if (!alive) return;
        if (rpcErr) {
          setError(rpcErr.message);
          setLoading(false);
          return;
        }
        const r = (data ?? []) as SanityRow[];
        const qd: Record<string, number> = {};
        r.forEach((row) => {
          qd[row.pod_inventory_id] = row.qty;
        });
        setQtyDraft(qd);
        setRows(r);
        // Auto-expanded whenever any expired row exists. Amber-only stays
        // collapsed so a routine visit does not grow a wall of chips.
        setOpen(r.some((row) => row.severity === "expired"));
        setLoading(false);
      });
    return () => {
      alive = false;
    };
  }, [machineId]);

  async function submit(row: SanityRow, outcome: Outcome) {
    if (readOnly || busy) return;
    setBusy(row.pod_inventory_id);
    setError(null);
    const supabase = createClient();
    const params: Record<string, unknown> = {
      p_pod_inventory_id: row.pod_inventory_id,
      p_outcome: outcome,
      p_dry_run: false,
    };
    if (outcome === "removed") {
      params.p_qty = qtyDraft[row.pod_inventory_id] ?? row.qty;
    }
    if (outcome === "date_read") {
      const picked = dateDraft[row.pod_inventory_id];
      if (!picked) {
        setBusy(null);
        setError("Pick the date on the label first.");
        return;
      }
      params.p_new_expiry = picked;
    }
    const { error: rpcErr } = await supabase.rpc("apply_expiry_check", params);
    setBusy(null);
    if (rpcErr) {
      setError(rpcErr.message);
      return;
    }
    // The tap already changed the shelf record - drop the row rather than
    // waiting on a re-fetch. There is nothing left here to act on.
    setRows((prev) =>
      prev.filter((r) => r.pod_inventory_id !== row.pod_inventory_id),
    );
  }

  if (loading) return null;
  // A clean machine renders nothing at all. A machine whose checklist FAILED to
  // load must not render nothing - on a safety list, "no rows" and "could not
  // read the rows" look identical to the driver and only one of them means
  // there is nothing to check.
  if (rows.length === 0) {
    return error ? (
      <p className="mb-4 rounded-lg bg-rose-50 px-3 py-2 text-xs text-rose-700 dark:bg-rose-950/30 dark:text-rose-400">
        Could not load the expiry sanity checks: {error}. Check the shelves by
        eye and tell the office.
      </p>
    ) : null;
  }

  const nExpired = rows.filter((r) => r.severity === "expired").length;

  return (
    <div className="mb-4" data-tour="expiry-sanity-checks">
      <button
        onClick={() => setOpen((v) => !v)}
        className="mb-2 flex w-full items-center justify-between gap-2 text-left"
      >
        <h2 className="text-sm font-semibold uppercase tracking-wide text-neutral-500">
          Sanity checks - expiry
        </h2>
        <div className="flex shrink-0 items-center gap-1.5 text-xs">
          {nExpired > 0 && (
            <span className="rounded bg-red-100 px-1.5 py-0.5 font-semibold text-red-700 dark:bg-red-950/40 dark:text-red-400">
              {nExpired} expired
            </span>
          )}
          <span className="rounded bg-neutral-100 px-1.5 py-0.5 font-medium text-neutral-600 dark:bg-neutral-800 dark:text-neutral-300">
            {rows.length} open
          </span>
          <span className="text-neutral-400">{open ? "▾" : "▸"}</span>
        </div>
      </button>

      {open && (
        <>
          <p className="mb-2 text-xs text-neutral-400">
            Check each shelf and say what you found. Removing a lot updates the
            shelf record now.
          </p>

          {error && (
            <p className="mb-2 rounded-lg bg-rose-50 px-3 py-2 text-xs text-rose-700 dark:bg-rose-950/30 dark:text-rose-400">
              {error}
            </p>
          )}

          <ul className="space-y-2">
            {rows.map((row) => {
              const isRed =
                row.severity === "expired" || row.severity === "expiring";
              const isBusy = busy === row.pod_inventory_id;

              return (
                <li
                  key={row.pod_inventory_id}
                  className={`rounded-lg border p-3 ${
                    isRed
                      ? "border-red-200 bg-red-50 dark:border-red-900/60 dark:bg-red-950/20"
                      : "border-amber-200 bg-amber-50 dark:border-amber-900/60 dark:bg-amber-950/20"
                  }`}
                >
                  <div className="mb-2 flex items-start justify-between gap-2">
                    <div className="min-w-0 flex-1">
                      <p className="text-sm font-medium">{row.product_name}</p>
                      <p className="text-xs text-neutral-500">
                        {/* An off-shelf batch is real stock with no slot. Say
                            so rather than rendering an empty shelf label. */}
                        {row.shelf_code
                          ? `Shelf ${row.shelf_code}`
                          : "No shelf on record"}{" "}
                        · {row.qty} unit{Number(row.qty) === 1 ? "" : "s"}
                        {row.expiration_date
                          ? ` · ${formatDMY(row.expiration_date)}`
                          : " · no date on record"}
                      </p>
                    </div>
                    <span
                      className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${
                        isRed
                          ? "bg-red-100 text-red-700 dark:bg-red-950/40 dark:text-red-400"
                          : "bg-amber-100 text-amber-800 dark:bg-amber-950/40 dark:text-amber-400"
                      }`}
                    >
                      {row.severity === "expired"
                        ? "⚠ Expired"
                        : row.severity === "expiring"
                          ? expiryPhrase(row.days_to_expiry ?? 0)
                          : "DATE?"}
                    </span>
                  </div>

                  {isRed ? (
                    <div className="flex flex-wrap items-center gap-2">
                      <input
                        type="number"
                        min={1}
                        max={row.qty}
                        disabled={readOnly || isBusy}
                        value={qtyDraft[row.pod_inventory_id] ?? row.qty}
                        onChange={(e) =>
                          setQtyDraft((prev) => ({
                            ...prev,
                            [row.pod_inventory_id]: Math.max(
                              1,
                              Math.min(row.qty, Number(e.target.value) || 1),
                            ),
                          }))
                        }
                        className="w-16 rounded-lg border border-neutral-300 px-2 py-1.5 text-xs dark:border-neutral-700 dark:bg-neutral-950"
                      />
                      <button
                        disabled={readOnly || isBusy}
                        onClick={() => submit(row, "removed")}
                        className="flex-1 rounded-lg border border-neutral-800 bg-neutral-800 py-1.5 text-xs font-semibold text-white transition-colors disabled:opacity-50 dark:border-neutral-200 dark:bg-neutral-200 dark:text-neutral-900"
                      >
                        Removed
                      </button>
                      <button
                        disabled={readOnly || isBusy}
                        onClick={() => submit(row, "not_there")}
                        className="flex-1 rounded-lg border border-neutral-300 bg-white py-1.5 text-xs font-semibold text-neutral-600 hover:bg-neutral-50 disabled:opacity-50 dark:border-neutral-700 dark:bg-neutral-950 dark:text-neutral-300 dark:hover:bg-neutral-800"
                      >
                        Not there
                      </button>
                    </div>
                  ) : (
                    <div className="flex flex-wrap items-center gap-2">
                      <input
                        type="date"
                        disabled={readOnly || isBusy}
                        value={dateDraft[row.pod_inventory_id] ?? ""}
                        onChange={(e) =>
                          setDateDraft((prev) => ({
                            ...prev,
                            [row.pod_inventory_id]: e.target.value,
                          }))
                        }
                        className="rounded-lg border border-neutral-300 px-2 py-1.5 text-xs dark:border-neutral-700 dark:bg-neutral-950"
                      />
                      <button
                        disabled={
                          readOnly || isBusy || !dateDraft[row.pod_inventory_id]
                        }
                        onClick={() => submit(row, "date_read")}
                        className="flex-1 rounded-lg border border-neutral-800 bg-neutral-800 py-1.5 text-xs font-semibold text-white transition-colors disabled:opacity-50 dark:border-neutral-200 dark:bg-neutral-200 dark:text-neutral-900"
                      >
                        Date read
                      </button>
                      <button
                        disabled={readOnly || isBusy}
                        onClick={() => submit(row, "not_there")}
                        className="flex-1 rounded-lg border border-neutral-300 bg-white py-1.5 text-xs font-semibold text-neutral-600 hover:bg-neutral-50 disabled:opacity-50 dark:border-neutral-700 dark:bg-neutral-950 dark:text-neutral-300 dark:hover:bg-neutral-800"
                      >
                        Not there
                      </button>
                    </div>
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
