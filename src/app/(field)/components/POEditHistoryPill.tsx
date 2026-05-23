"use client";

// PRD-001 — Edit-history pill rendered next to the PO status badge.
// Tap → bottom-sheet listing every audit row from get_po_edit_history(po_id)
// with before → after deltas + actor name + reason.

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface EditEvent {
  event_id: string;
  po_line_id: string;
  actor_id: string | null;
  actor_name: string | null;
  actor_role: string | null;
  changed_at: string;
  before: Record<string, unknown>;
  after: Record<string, unknown>;
  reason: string;
}

interface POEditHistoryPillProps {
  poId: string;
  // Optional: parent can pass a refresh signal to re-fetch when an edit is saved.
  refreshKey?: number;
}

const FIELD_LABEL: Record<string, string> = {
  ordered_qty: "Qty",
  price_per_unit_aed: "Price",
  total_price_aed: "Total",
  expiry_date: "Expiry",
};

function formatRelative(iso: string): string {
  const then = new Date(iso).getTime();
  const now = Date.now();
  const diff = Math.floor((now - then) / 1000);
  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  if (diff < 30 * 86400) return `${Math.floor(diff / 86400)}d ago`;
  return new Date(iso).toLocaleDateString();
}

function formatValue(v: unknown): string {
  if (v === null || v === undefined) return "—";
  return String(v);
}

function diffPairs(
  before: Record<string, unknown>,
  after: Record<string, unknown>,
): { field: string; before: unknown; after: unknown }[] {
  const keys = new Set<string>([...Object.keys(before), ...Object.keys(after)]);
  const out: { field: string; before: unknown; after: unknown }[] = [];
  for (const k of keys) {
    if (FIELD_LABEL[k] === undefined) continue;
    const b = before[k] ?? null;
    const a = after[k] ?? null;
    if (b !== a) {
      out.push({ field: k, before: b, after: a });
    }
  }
  return out;
}

export function POEditHistoryPill({
  poId,
  refreshKey = 0,
}: POEditHistoryPillProps) {
  const [count, setCount] = useState<number>(0);
  const [events, setEvents] = useState<EditEvent[]>([]);
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      const supabase = createClient();
      const { data, error: rpcErr } = await supabase.rpc(
        "get_po_edit_history",
        { p_po_id: poId },
      );
      if (cancelled) return;
      if (rpcErr) {
        setError(rpcErr.message);
        setLoading(false);
        return;
      }
      const rows = (data ?? []) as EditEvent[];
      setEvents(rows);
      setCount(rows.length);
      setLoading(false);
    })();
    return () => {
      cancelled = true;
    };
  }, [poId, refreshKey]);

  if (count === 0) return null;

  return (
    <>
      <button
        onClick={(e) => {
          e.stopPropagation();
          setOpen(true);
        }}
        className="rounded-full bg-purple-100 px-2 py-0.5 text-xs font-medium text-purple-800 hover:bg-purple-200 dark:bg-purple-900 dark:text-purple-200 dark:hover:bg-purple-800"
        aria-label={`View ${count} edit${count === 1 ? "" : "s"} on this PO`}
      >
        ✎ {count} edit{count === 1 ? "" : "s"}
      </button>

      {open && (
        <div
          className="fixed inset-0 z-50 flex items-end justify-center bg-black/40"
          onClick={() => setOpen(false)}
        >
          <div
            className="relative flex max-h-[80vh] w-full max-w-2xl flex-col rounded-t-2xl bg-white p-4 dark:bg-neutral-950"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="mb-3 flex items-center justify-between">
              <div>
                <h2 className="text-base font-semibold">Edit history</h2>
                <p className="text-xs text-neutral-500">
                  {poId} · {count} edit{count === 1 ? "" : "s"}
                </p>
              </div>
              <button
                onClick={() => setOpen(false)}
                className="rounded-full p-2 text-neutral-500 hover:bg-neutral-100 dark:hover:bg-neutral-900"
                aria-label="Close edit history"
              >
                ✕
              </button>
            </div>

            <div className="-mx-2 flex-1 overflow-y-auto px-2">
              {loading ? (
                <p className="p-6 text-sm text-neutral-500">Loading…</p>
              ) : error ? (
                <p className="p-6 text-sm text-red-600 dark:text-red-400">
                  {error}
                </p>
              ) : (
                <ul className="space-y-3">
                  {events.map((ev) => {
                    const pairs = diffPairs(ev.before, ev.after);
                    return (
                      <li
                        key={ev.event_id}
                        className="rounded-lg border border-neutral-200 p-3 dark:border-neutral-800"
                      >
                        <div className="flex items-center justify-between gap-2">
                          <p className="text-xs font-medium text-neutral-700 dark:text-neutral-300">
                            {ev.actor_name ?? "Unknown user"}
                            {ev.actor_role && (
                              <span className="ml-1 text-neutral-400">
                                ({ev.actor_role})
                              </span>
                            )}
                          </p>
                          <p
                            className="text-xs text-neutral-400"
                            title={new Date(ev.changed_at).toLocaleString()}
                          >
                            {formatRelative(ev.changed_at)}
                          </p>
                        </div>
                        {pairs.length > 0 && (
                          <ul className="mt-2 space-y-1">
                            {pairs.map((p) => (
                              <li
                                key={p.field}
                                className="flex items-center gap-2 text-xs"
                              >
                                <span className="w-14 text-neutral-500">
                                  {FIELD_LABEL[p.field]}
                                </span>
                                <span className="font-mono text-red-600 line-through dark:text-red-400">
                                  {formatValue(p.before)}
                                </span>
                                <span className="text-neutral-400">→</span>
                                <span className="font-mono text-green-700 dark:text-green-400">
                                  {formatValue(p.after)}
                                </span>
                              </li>
                            ))}
                          </ul>
                        )}
                        <p className="mt-2 rounded bg-neutral-50 px-2 py-1 text-xs italic text-neutral-600 dark:bg-neutral-900 dark:text-neutral-400">
                          &ldquo;{ev.reason}&rdquo;
                        </p>
                      </li>
                    );
                  })}
                </ul>
              )}
            </div>
          </div>
        </div>
      )}
    </>
  );
}
