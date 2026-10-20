"use client";

// PRD-145 P3-4: warehouse lots of 1 to 3 units sitting next to a lot of the same
// product with at least 5x the stock (the 19-20 Oct ghost lots that push pinned).
// Everyone sees the list; Zero is the warehouse manager's (warehouse role) and
// goes through zero_ghost_lot -> adjust_warehouse_stock. Lines pinned to a lot
// that goes to 0 move to the FEFO live lot on their own.

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface Candidate {
  wh_inventory_id: string;
  warehouse_name: string;
  boonz_product_name: string | null;
  expiration_date: string | null;
  warehouse_stock: number;
  big_lot_expiry: string | null;
  big_lot_stock: number;
  pinned_unpacked_rows: number;
}

export default function LotsToCountPanel() {
  const [rows, setRows] = useState<Candidate[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [isWarehouse, setIsWarehouse] = useState(false);
  const [zeroing, setZeroing] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(
    null,
  );
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    let cancelled = false;
    createClient()
      .rpc("get_ghost_lot_candidates")
      .then(({ data, error: err }) => {
        if (cancelled) return;
        if (err) setError(err.message);
        else {
          setError(null);
          setRows((data as Candidate[] | null) ?? []);
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
      setIsWarehouse(profile?.role === "warehouse");
    });
  }, []);

  async function zero(c: Candidate) {
    setBusy(true);
    setMessage(null);
    const { error: err } = await createClient().rpc("zero_ghost_lot", {
      p_wh_inventory_id: c.wh_inventory_id,
      p_reason: reason.trim(),
    });
    setBusy(false);
    if (err) {
      setMessage({ ok: false, text: err.message });
      return;
    }
    setMessage({
      ok: true,
      text: `${c.boonz_product_name ?? "Lot"} ${c.expiration_date ?? ""}: counted at 0`,
    });
    setZeroing(null);
    setReason("");
    setLoading(true);
    setReloadKey((k) => k + 1);
  }

  return (
    <div className="mt-6">
      <h2 className="text-sm font-semibold">Lots to count</h2>
      <p className="mb-3 text-xs text-neutral-500">
        Small lots next to a much bigger lot of the same product. Count them; if
        the shelf is empty, Zero moves any line pinned to them to a live lot.
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
        <p className="text-sm text-neutral-500">Loading lots…</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-neutral-500">No lots to count.</p>
      ) : (
        <ul className="space-y-2">
          {rows.map((c) => (
            <li
              key={c.wh_inventory_id}
              className="rounded-lg border border-neutral-200 bg-white px-4 py-2.5 dark:border-neutral-800 dark:bg-neutral-950"
            >
              <div className="flex items-center gap-3">
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-semibold">
                    {c.boonz_product_name ?? "-"}
                  </p>
                  <p className="text-xs text-neutral-500">
                    {c.warehouse_name} · {c.expiration_date ?? "no expiry"} ·{" "}
                    {c.warehouse_stock}u (next lot {c.big_lot_stock}u,{" "}
                    {c.big_lot_expiry ?? "no expiry"})
                    {c.pinned_unpacked_rows > 0 &&
                      ` · ${c.pinned_unpacked_rows} line(s) pinned`}
                  </p>
                </div>
                {isWarehouse && zeroing !== c.wh_inventory_id && (
                  <button
                    onClick={() => setZeroing(c.wh_inventory_id)}
                    className="shrink-0 rounded-lg border border-red-300 px-3 py-1.5 text-xs font-semibold text-red-700"
                  >
                    Zero
                  </button>
                )}
              </div>
              {isWarehouse && zeroing === c.wh_inventory_id && (
                <div className="mt-2 space-y-2">
                  <textarea
                    value={reason}
                    onChange={(e) => setReason(e.target.value)}
                    placeholder="Reason (required): e.g. counted, shelf empty"
                    rows={2}
                    className="w-full rounded-md border border-neutral-200 px-2 py-1 text-sm dark:border-neutral-700 dark:bg-neutral-900"
                  />
                  <div className="flex gap-2">
                    <button
                      disabled={busy || reason.trim().length < 5}
                      onClick={() => void zero(c)}
                      className="flex-1 rounded-lg bg-red-600 px-3 py-1.5 text-xs font-semibold text-white disabled:opacity-40"
                    >
                      {busy ? "Saving…" : "Confirm 0 units"}
                    </button>
                    <button
                      disabled={busy}
                      onClick={() => {
                        setZeroing(null);
                        setReason("");
                      }}
                      className="rounded-lg border border-neutral-200 px-3 py-1.5 text-xs dark:border-neutral-700"
                    >
                      Back
                    </button>
                  </div>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
