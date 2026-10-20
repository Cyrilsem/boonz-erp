"use client";

// PRD-145 P3-7: pod_inventory rows whose product is not what WEIMI shows on the
// lane (no product_mapping row to the lane's pod product), or that sit on a
// shelf missing from the latest WEIMI snapshot. Everyone sees the counts; Clear
// is operator_admin only and goes through clear_pod_orphan_rows, which refuses
// until the WEIMI snapshot is newer than the machine's last refill. The nightly
// job only counts, it never clears.

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface MachineSummary {
  machine_id: string;
  machine_name: string;
  orphan_rows: number;
  orphan_units: number;
  snapshot_at: string | null;
  clear_ok: boolean;
  clear_reason: string;
  nightly_rows: number | null;
  nightly_at: string | null;
}

interface OrphanRow {
  pod_inventory_id: string;
  shelf_code: string;
  boonz_product_name: string | null;
  current_stock: number;
  weimi_product_name: string | null;
  reason: "not_mapped_to_weimi_pod" | "shelf_not_in_snapshot";
}

const dubaiTime = (iso: string | null) =>
  iso
    ? new Date(iso).toLocaleString("en-GB", {
        timeZone: "Asia/Dubai",
        day: "numeric",
        month: "short",
        hour: "2-digit",
        minute: "2-digit",
      })
    : "-";

export default function PodOrphanRowsPanel() {
  const [rows, setRows] = useState<MachineSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [isAdmin, setIsAdmin] = useState(false);
  const [open, setOpen] = useState<string | null>(null);
  const [detail, setDetail] = useState<Record<string, OrphanRow[]>>({});
  const [clearing, setClearing] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(
    null,
  );
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    let cancelled = false;
    createClient()
      .rpc("get_pod_orphan_summary")
      .then(({ data, error: err }) => {
        if (cancelled) return;
        if (err) setError(err.message);
        else {
          setError(null);
          setRows((data as MachineSummary[] | null) ?? []);
        }
        setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [reloadKey]);

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

  async function toggle(m: MachineSummary) {
    if (open === m.machine_id) {
      setOpen(null);
      return;
    }
    setOpen(m.machine_id);
    if (detail[m.machine_id]) return;
    const { data, error: err } = await createClient().rpc(
      "get_pod_orphan_rows",
      { p_machine_id: m.machine_id },
    );
    if (err) {
      setMessage({ ok: false, text: err.message });
      return;
    }
    setDetail((d) => ({
      ...d,
      [m.machine_id]: (data as OrphanRow[] | null) ?? [],
    }));
  }

  async function clear(m: MachineSummary) {
    setBusy(true);
    setMessage(null);
    const { data, error: err } = await createClient().rpc(
      "clear_pod_orphan_rows",
      { p_machine_id: m.machine_id, p_reason: reason.trim() },
    );
    setBusy(false);
    if (err) {
      setMessage({ ok: false, text: err.message });
      return;
    }
    const r = data as { rows: number; status: string };
    setMessage({
      ok: true,
      text: `${m.machine_name}: ${r.rows} row(s) set to 0`,
    });
    setClearing(null);
    setReason("");
    setDetail((d) => {
      const next = { ...d };
      delete next[m.machine_id];
      return next;
    });
    setLoading(true);
    setReloadKey((k) => k + 1);
  }

  const nightlyAt = rows.find((r) => r.nightly_at)?.nightly_at ?? null;

  return (
    <div className="mt-6">
      <h2 className="text-sm font-semibold">Pod rows off WEIMI</h2>
      <p className="mb-3 text-xs text-neutral-500">
        Stock rows for a product WEIMI does not show on that lane. Nightly
        check: {nightlyAt ? dubaiTime(nightlyAt) : "not run yet"}.
      </p>

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
        <p className="text-sm text-neutral-500">Loading pod rows…</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-neutral-500">Every pod row matches WEIMI.</p>
      ) : (
        <ul className="space-y-2">
          {rows.map((m) => {
            const isOpen = open === m.machine_id;
            return (
              <li
                key={m.machine_id}
                className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950"
              >
                <button
                  onClick={() => void toggle(m)}
                  className="flex w-full items-center gap-3 px-4 py-2.5 text-left"
                >
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-semibold">
                      {m.machine_name}
                    </p>
                    <p className="text-xs text-neutral-500">
                      WEIMI {dubaiTime(m.snapshot_at)}
                      {m.nightly_rows != null && ` · nightly ${m.nightly_rows}`}
                    </p>
                  </div>
                  <span className="shrink-0 rounded-full bg-neutral-100 px-2 py-0.5 text-xs font-semibold text-neutral-700 dark:bg-neutral-800 dark:text-neutral-200">
                    {m.orphan_rows} rows · {m.orphan_units} u
                  </span>
                  <span className="shrink-0 text-xs text-neutral-400">
                    {isOpen ? "▲" : "▼"}
                  </span>
                </button>
                {isOpen && (
                  <div className="border-t border-neutral-100 px-4 py-2 dark:border-neutral-800">
                    {(detail[m.machine_id] ?? []).map((r) => (
                      <div
                        key={r.pod_inventory_id}
                        className="flex items-center gap-2 py-1 text-sm"
                      >
                        <span className="w-8 shrink-0 font-mono text-xs text-neutral-400">
                          {r.shelf_code}
                        </span>
                        <span className="min-w-0 flex-1 truncate">
                          {r.boonz_product_name ?? "-"}
                          <span className="text-xs text-neutral-500">
                            {r.reason === "shelf_not_in_snapshot"
                              ? " · shelf not in WEIMI"
                              : ` · WEIMI: ${r.weimi_product_name ?? "-"}`}
                          </span>
                        </span>
                        <span className="shrink-0 text-xs text-neutral-500">
                          ×{r.current_stock}
                        </span>
                      </div>
                    ))}
                    {isAdmin && (
                      <div className="mt-2 border-t border-neutral-100 pt-2 dark:border-neutral-800">
                        {!m.clear_ok ? (
                          <p className="text-xs text-amber-700">
                            Clear waits: {m.clear_reason}
                          </p>
                        ) : clearing === m.machine_id ? (
                          <div className="space-y-2">
                            <textarea
                              value={reason}
                              onChange={(e) => setReason(e.target.value)}
                              placeholder="Reason (required): e.g. WEIMI after the 20 Oct refill"
                              rows={2}
                              className="w-full rounded-md border border-neutral-200 px-2 py-1 text-sm dark:border-neutral-700 dark:bg-neutral-900"
                            />
                            <div className="flex gap-2">
                              <button
                                disabled={busy || reason.trim().length < 5}
                                onClick={() => void clear(m)}
                                className="flex-1 rounded-lg bg-red-600 px-3 py-1.5 text-xs font-semibold text-white disabled:opacity-40"
                              >
                                {busy
                                  ? "Clearing…"
                                  : `Set ${m.orphan_rows} rows to 0`}
                              </button>
                              <button
                                disabled={busy}
                                onClick={() => {
                                  setClearing(null);
                                  setReason("");
                                }}
                                className="rounded-lg border border-neutral-200 px-3 py-1.5 text-xs dark:border-neutral-700"
                              >
                                Back
                              </button>
                            </div>
                          </div>
                        ) : (
                          <button
                            onClick={() => setClearing(m.machine_id)}
                            className="w-full rounded-lg border border-red-300 px-3 py-1.5 text-xs font-semibold text-red-700"
                          >
                            Clear
                          </button>
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
