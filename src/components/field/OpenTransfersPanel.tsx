"use client";

// PRD-144 P1-7: machine-to-machine transfers delivered at the destination
// whose source Remove leg is still open. Everyone sees the list; Close
// transfer is operator_admin only and goes through close_m2m_transfer, which
// calls approve_m2m_transfer (no warehouse movement) with a reason.

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface OpenTransfer {
  transfer_id: string;
  dispatch_date: string;
  source_machine: string;
  source_shelf: string | null;
  dest_machine: string;
  dest_shelf: string | null;
  product: string | null;
  source_qty: number;
  dest_received: number | null;
}

export default function OpenTransfersPanel() {
  const [rows, setRows] = useState<OpenTransfer[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [isAdmin, setIsAdmin] = useState(false);
  const [closing, setClosing] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(
    null,
  );
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    let cancelled = false;
    createClient()
      .rpc("get_open_m2m_transfers", { p_days: 30 })
      .then(({ data, error: err }) => {
        if (cancelled) return;
        if (err) setError(err.message);
        else {
          setError(null);
          setRows((data as OpenTransfer[] | null) ?? []);
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

  async function closeTransfer(t: OpenTransfer) {
    setBusy(true);
    setMessage(null);
    const { error: err } = await createClient().rpc("close_m2m_transfer", {
      p_transfer_id: t.transfer_id,
      p_reason: reason.trim(),
    });
    setBusy(false);
    if (err) {
      setMessage({ ok: false, text: err.message });
      return;
    }
    setMessage({
      ok: true,
      text: `${t.product ?? "Transfer"} ${t.source_machine} → ${t.dest_machine}: closed`,
    });
    setClosing(null);
    setReason("");
    setLoading(true);
    setReloadKey((k) => k + 1);
  }

  return (
    <div className="mt-6">
      <p className="mb-3 text-xs text-neutral-500">
        Machine transfers delivered at the destination, source leg still open.
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
        <p className="text-sm text-neutral-500">Loading open transfers…</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-neutral-500">No open transfers.</p>
      ) : (
        <ul className="space-y-2">
          {rows.map((t) => {
            const mismatch =
              t.dest_received !== null &&
              Number(t.dest_received) !== Number(t.source_qty);
            return (
              <li
                key={t.transfer_id}
                className="rounded-lg border border-neutral-200 bg-white px-4 py-2.5 dark:border-neutral-800 dark:bg-neutral-950"
              >
                <p className="truncate text-sm font-semibold">
                  {t.product ?? "-"}
                </p>
                <p className="text-xs text-neutral-500">
                  {t.dispatch_date} · {t.source_machine}
                  {t.source_shelf ? ` ${t.source_shelf}` : ""} →{" "}
                  {t.dest_machine}
                  {t.dest_shelf ? ` ${t.dest_shelf}` : ""}
                </p>
                <p
                  className={`text-xs ${mismatch ? "text-amber-700" : "text-neutral-500"}`}
                >
                  Source ×{t.source_qty} · received ×{t.dest_received ?? "-"}
                  {mismatch ? " (mismatch)" : ""}
                </p>
                {isAdmin &&
                  (closing === t.transfer_id ? (
                    <div className="mt-2 space-y-2">
                      <textarea
                        value={reason}
                        onChange={(e) => setReason(e.target.value)}
                        placeholder="Reason (required): e.g. delivered at destination, driver confirmed"
                        rows={2}
                        className="w-full rounded-md border border-neutral-200 px-2 py-1 text-sm dark:border-neutral-700 dark:bg-neutral-900"
                      />
                      <div className="flex gap-2">
                        <button
                          disabled={busy || reason.trim().length < 5}
                          onClick={() => closeTransfer(t)}
                          className="flex-1 rounded-lg bg-[#24544a] px-3 py-1.5 text-xs font-semibold text-white disabled:opacity-40"
                        >
                          {busy ? "Saving…" : "Confirm close"}
                        </button>
                        <button
                          disabled={busy}
                          onClick={() => {
                            setClosing(null);
                            setReason("");
                          }}
                          className="rounded-lg border border-neutral-200 px-3 py-1.5 text-xs dark:border-neutral-700"
                        >
                          Back
                        </button>
                      </div>
                      <p className="text-[11px] text-neutral-500">
                        Closes the source leg. Takes the moved units off the
                        source lane; no warehouse stock moves.
                      </p>
                    </div>
                  ) : (
                    <button
                      onClick={() => setClosing(t.transfer_id)}
                      className="mt-2 w-full rounded-lg border border-[#24544a]/40 px-3 py-1.5 text-xs font-semibold text-[#24544a]"
                    >
                      Close transfer
                    </button>
                  ))}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
