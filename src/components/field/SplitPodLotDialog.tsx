"use client";

// PRD-144 P1-3: split one pod lot into two lots with their own expiry dates
// (the machine holds two dates under one row). Calls split_pod_lot, which
// keeps the total and logs every row change; the two quantities must add up
// to the lot's stock.

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

export default function SplitPodLotDialog({
  podInventoryId,
  productName,
  onClose,
  onSaved,
}: {
  podInventoryId: string;
  productName: string;
  onClose: () => void;
  onSaved?: () => void;
}) {
  const [lot, setLot] = useState<{
    current_stock: number;
    expiration_date: string | null;
  } | null>(null);
  const [qtyA, setQtyA] = useState("");
  const [dateA, setDateA] = useState("");
  const [dateB, setDateB] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    createClient()
      .from("pod_inventory")
      .select("current_stock, expiration_date")
      .eq("pod_inventory_id", podInventoryId)
      .maybeSingle()
      .then(({ data, error }) => {
        if (error || !data) {
          setMsg(error?.message ?? "Lot not found");
          return;
        }
        const l = {
          current_stock: Number(data.current_stock ?? 0),
          expiration_date: (data.expiration_date as string | null) ?? null,
        };
        setLot(l);
        setDateA(l.expiration_date ?? "");
      });
  }, [podInventoryId]);

  const total = lot?.current_stock ?? 0;
  const a = parseInt(qtyA) || 0;
  const b = total - a;
  const valid =
    lot !== null &&
    a > 0 &&
    b > 0 &&
    !!dateA &&
    !!dateB &&
    dateA !== dateB &&
    reason.trim().length >= 5;

  async function save() {
    if (!valid) return;
    setBusy(true);
    setMsg(null);
    const { error } = await createClient().rpc("split_pod_lot", {
      p_pod_inventory_id: podInventoryId,
      p_qty_a: a,
      p_date_a: dateA,
      p_qty_b: b,
      p_date_b: dateB,
      p_reason: reason.trim(),
    });
    setBusy(false);
    if (error) {
      setMsg(error.message);
      return;
    }
    onSaved?.();
    onClose();
  }

  return (
    <div className="fixed inset-0 z-50 flex flex-col justify-end">
      <div className="absolute inset-0 bg-black/40" onClick={onClose} />
      <div className="relative z-10 rounded-t-2xl bg-white px-4 pt-5 pb-10 shadow-xl dark:bg-neutral-900">
        <p className="text-base font-bold">Split lot</p>
        <p className="mb-3 text-sm text-neutral-500">
          {productName}
          {lot && (
            <>
              {" "}
              · {lot.current_stock} units · expires{" "}
              {lot.expiration_date ?? "not set"}
            </>
          )}
        </p>
        {lot && (
          <div className="space-y-2 text-sm">
            <div className="flex items-center gap-2">
              <input
                type="number"
                min={1}
                max={total - 1}
                value={qtyA}
                onChange={(e) => setQtyA(e.target.value)}
                placeholder="Qty"
                className="w-20 rounded border border-neutral-300 px-2 py-1 text-center dark:border-neutral-600 dark:bg-neutral-900"
              />
              <input
                type="date"
                value={dateA}
                onChange={(e) => setDateA(e.target.value)}
                className="flex-1 rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
              />
            </div>
            <div className="flex items-center gap-2">
              <span className="w-20 text-center font-semibold">
                {b > 0 ? b : "-"}
              </span>
              <input
                type="date"
                value={dateB}
                onChange={(e) => setDateB(e.target.value)}
                className="flex-1 rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
              />
            </div>
            <p className="text-xs text-neutral-500">
              The two lots must add up to {total}. The second quantity follows
              the first.
            </p>
            <textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={2}
              placeholder="Reason (required): e.g. two dates found on the shelf"
              className="w-full rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
            />
          </div>
        )}
        {msg && (
          <p role="alert" className="mt-2 text-sm text-red-600">
            {msg}
          </p>
        )}
        <div className="mt-3 flex gap-2">
          <button
            onClick={save}
            disabled={!valid || busy}
            className="flex-1 rounded-lg bg-[#24544a] px-3 py-2 text-sm font-semibold text-white disabled:opacity-40"
          >
            {busy ? "Saving…" : "Split lot"}
          </button>
          <button
            onClick={onClose}
            disabled={busy}
            className="rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-600"
          >
            Back
          </button>
        </div>
      </div>
    </div>
  );
}
