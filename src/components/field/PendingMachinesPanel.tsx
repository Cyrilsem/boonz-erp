"use client";

// PRD-144 P1-1: machines with open lines from an earlier day (packed, picked up
// or never packed, but not delivered, returned or cancelled). Everyone sees the
// list; Complete and Cancel are operator_admin only and go through
// resolve_incomplete_dispatch, which calls receive_dispatch_line /
// return_dispatch_line per line and reports each line's result.

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface OpenLine {
  dispatch_id: string;
  shelf_code: string | null;
  product: string | null;
  action: string;
  quantity: number;
  filled_quantity: number | null;
  packed: boolean;
  picked_up: boolean;
}

interface MachineDay {
  machine_id: string;
  official_name: string;
  dispatch_date: string;
  open_lines: number;
  lines: OpenLine[];
}

interface ResolveResult {
  status: string;
  lines_ok: number;
  lines_failed: number;
  lines_left_open: number;
  results: { dispatch_id: string; status: string; error?: string }[];
}

function lineState(l: OpenLine): string {
  if (l.picked_up) return "Picked up";
  if (l.packed) return "Packed";
  return "Not packed";
}

export default function PendingMachinesPanel() {
  const [rows, setRows] = useState<MachineDay[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [days, setDays] = useState(14);
  const [isAdmin, setIsAdmin] = useState(false);
  const [open, setOpen] = useState<string | null>(null);
  const [action, setAction] = useState<{
    key: string;
    mode: "complete" | "cancel";
  } | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(
    null,
  );

  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    let cancelled = false;
    createClient()
      .rpc("get_incomplete_dispatch_machines", { p_days: days })
      .then(({ data, error: err }) => {
        if (cancelled) return;
        if (err) setError(err.message);
        else {
          setError(null);
          setRows((data as MachineDay[] | null) ?? []);
        }
        setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [days, reloadKey]);

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getUser().then(async ({ data }) => {
      if (!data.user) return;
      const { data: profile } = await supabase
        .from("user_profiles")
        .select("role")
        .eq("id", data.user.id)
        .maybeSingle();
      setIsAdmin(
        profile?.role === "operator_admin" || profile?.role === "superadmin",
      );
    });
  }, []);

  async function resolve(m: MachineDay, mode: "complete" | "cancel") {
    const supabase = createClient();
    setBusy(true);
    setMessage(null);
    const { data, error: err } = await supabase.rpc(
      "resolve_incomplete_dispatch",
      {
        p_machine_id: m.machine_id,
        p_dispatch_date: m.dispatch_date,
        p_mode: mode,
        p_reason: reason.trim(),
      },
    );
    setBusy(false);
    if (err) {
      setMessage({ ok: false, text: err.message });
      return;
    }
    const r = data as ResolveResult;
    const failed = r.results.filter((x) => x.status === "error");
    setMessage({
      ok: failed.length === 0,
      text:
        `${m.official_name} ${m.dispatch_date}: ${r.lines_ok} line(s) ${mode === "complete" ? "completed" : "cancelled"}` +
        (r.lines_left_open > 0
          ? `, ${r.lines_left_open} Remove leg(s) left open`
          : "") +
        (failed.length > 0
          ? `, ${failed.length} failed: ${failed.map((f) => f.error).join(" · ")}`
          : ""),
    });
    setAction(null);
    setReason("");
    setLoading(true);
    setReloadKey((k) => k + 1);
  }

  return (
    <div>
      <div className="mb-3 flex items-center justify-between">
        <p className="text-xs text-neutral-500">
          Open lines from earlier days: not delivered, returned or cancelled.
        </p>
        <select
          value={days}
          onChange={(e) => {
            setLoading(true);
            setDays(Number(e.target.value));
          }}
          className="rounded-md border border-neutral-200 bg-white px-2 py-1 text-xs dark:border-neutral-700 dark:bg-neutral-900"
        >
          <option value={14}>Last 14 days</option>
          <option value={30}>Last 30 days</option>
          <option value={90}>Last 90 days</option>
        </select>
      </div>

      {message && (
        <div
          role="alert"
          className={`mb-3 rounded-lg px-3 py-2 text-sm ${
            message.ok
              ? "bg-emerald-50 text-emerald-800"
              : "bg-red-50 text-red-800"
          }`}
        >
          {message.text}
        </div>
      )}
      {error && (
        <div className="mb-3 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-800">
          {error}
        </div>
      )}
      {loading ? (
        <p className="text-sm text-neutral-500">Loading pending machines…</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-neutral-500">
          No pending machines in this window.
        </p>
      ) : (
        <ul className="space-y-2">
          {rows.map((m) => {
            const key = `${m.machine_id}:${m.dispatch_date}`;
            const isOpen = open === key;
            return (
              <li
                key={key}
                className="rounded-lg border border-amber-200 bg-white dark:border-amber-900 dark:bg-neutral-950"
              >
                <button
                  onClick={() => setOpen(isOpen ? null : key)}
                  className="flex w-full items-center gap-3 px-4 py-2.5 text-left"
                >
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-semibold">
                      {m.official_name}
                    </p>
                    <p className="text-xs text-neutral-500">
                      {m.dispatch_date}
                    </p>
                  </div>
                  <span className="shrink-0 rounded-full bg-amber-100 px-2 py-0.5 text-xs font-semibold text-amber-800">
                    {m.open_lines} open
                  </span>
                  <span className="shrink-0 text-xs text-neutral-400">
                    {isOpen ? "▲" : "▼"}
                  </span>
                </button>
                {isOpen && (
                  <div className="border-t border-neutral-100 px-4 py-2 dark:border-neutral-800">
                    {m.lines.map((l) => (
                      <div
                        key={l.dispatch_id}
                        className="flex items-center gap-2 py-1 text-sm"
                      >
                        <span className="w-8 shrink-0 font-mono text-xs text-neutral-400">
                          {l.shelf_code ?? "-"}
                        </span>
                        <span className="min-w-0 flex-1 truncate">
                          {l.action} · {l.product ?? "-"}
                        </span>
                        <span className="shrink-0 text-xs text-neutral-500">
                          ×{l.filled_quantity ?? l.quantity}
                        </span>
                        <span className="shrink-0 rounded bg-neutral-100 px-1.5 py-0.5 text-[11px] text-neutral-600 dark:bg-neutral-800 dark:text-neutral-300">
                          {lineState(l)}
                        </span>
                      </div>
                    ))}
                    {isAdmin && (
                      <div className="mt-2 border-t border-neutral-100 pt-2 dark:border-neutral-800">
                        {action?.key === key ? (
                          <div className="space-y-2">
                            <textarea
                              value={reason}
                              onChange={(e) => setReason(e.target.value)}
                              placeholder={
                                action.mode === "complete"
                                  ? "Reason (required): e.g. delivered, driver confirmed by phone"
                                  : "Reason (required): e.g. bags came back to the warehouse"
                              }
                              rows={2}
                              className="w-full rounded-md border border-neutral-200 px-2 py-1 text-sm dark:border-neutral-700 dark:bg-neutral-900"
                            />
                            <div className="flex gap-2">
                              <button
                                disabled={busy || reason.trim().length < 5}
                                onClick={() => resolve(m, action.mode)}
                                className={`flex-1 rounded-lg px-3 py-1.5 text-xs font-semibold text-white disabled:opacity-40 ${
                                  action.mode === "complete"
                                    ? "bg-[#24544a]"
                                    : "bg-red-600"
                                }`}
                              >
                                {busy
                                  ? "Saving…"
                                  : action.mode === "complete"
                                    ? "Confirm complete"
                                    : "Confirm cancel"}
                              </button>
                              <button
                                disabled={busy}
                                onClick={() => {
                                  setAction(null);
                                  setReason("");
                                }}
                                className="rounded-lg border border-neutral-200 px-3 py-1.5 text-xs dark:border-neutral-700"
                              >
                                Back
                              </button>
                            </div>
                            <p className="text-[11px] text-neutral-500">
                              {action.mode === "complete"
                                ? "Receives every open Refill / Add New line at its packed quantity. Remove legs stay open."
                                : "Returns every open Refill / Add New line to the warehouse and closes Remove legs at 0."}
                            </p>
                          </div>
                        ) : (
                          <div className="flex gap-2">
                            <button
                              onClick={() =>
                                setAction({ key, mode: "complete" })
                              }
                              className="flex-1 rounded-lg border border-[#24544a]/40 px-3 py-1.5 text-xs font-semibold text-[#24544a]"
                            >
                              Complete
                            </button>
                            <button
                              onClick={() => setAction({ key, mode: "cancel" })}
                              className="flex-1 rounded-lg border border-red-300 px-3 py-1.5 text-xs font-semibold text-red-700"
                            >
                              Cancel
                            </button>
                          </div>
                        )}
                      </div>
                    )}
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
