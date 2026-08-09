"use client";

import { useEffect, useMemo, useState, useTransition } from "react";
import {
  driverSubstituteDispatchLine,
  listSubstituteProducts,
  type SubstitutionSourceTag,
} from "@/app/(field)/field/_actions/dispatch-edits";

/**
 * PRD-112 §3.2 - "Change product".
 *
 * The driver is standing at the machine and the venue has a different flavor than
 * the plan. Two taps, under ten seconds, zero approvals: pick what actually went
 * in the shelf, say how many, tap a reason chip. The RPC never refuses on business
 * grounds - anything it could not verify comes back ok with a review flag and lands
 * in the Day Close panel for CS the same evening.
 */

interface Props {
  open: boolean;
  onClose: () => void;
  dispatchId: string;
  machineId: string;
  /** Product currently on the line, shown so the driver can see what he is replacing */
  currentProductName: string;
  shelfCode: string;
  /** Planned quantity - pre-fills the qty field, since a like-for-like swap is the common case */
  plannedQty: number;
  revalidate?: string;
  onSuccess?: (result: {
    needsReview: boolean;
    reviewReason?: string | null;
  }) => void;
}

const REASON_CHIPS: {
  key: string;
  label: string;
  reason: string;
  tag: SubstitutionSourceTag | undefined;
}[] = [
  {
    key: "flavor",
    label: "Venue had different flavor",
    reason: "venue had different flavor",
    tag: "venue",
  },
  {
    key: "oos",
    label: "Out of stock",
    reason: "out of stock",
    tag: undefined,
  },
  { key: "spot", label: "Spot buy", reason: "spot buy", tag: "spot" },
  { key: "other", label: "Other", reason: "", tag: undefined },
];

export function ChangeProductDialog({
  open,
  onClose,
  dispatchId,
  machineId,
  currentProductName,
  shelfCode,
  plannedQty,
  revalidate,
  onSuccess,
}: Props) {
  const [isPending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [products, setProducts] = useState<
    { product_id: string; name: string; venue: boolean }[]
  >([]);
  const [loadingProducts, setLoadingProducts] = useState(false);
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<{
    product_id: string;
    name: string;
  } | null>(null);
  const [qty, setQty] = useState<number>(plannedQty > 0 ? plannedQty : 1);
  const [chip, setChip] = useState<string>("flavor");
  const [otherReason, setOtherReason] = useState("");

  useEffect(() => {
    if (!open) return;
    setLoadingProducts(true);
    (async () => {
      const r = await listSubstituteProducts(machineId);
      if (r.ok) setProducts(r.data);
      setLoadingProducts(false);
    })();
  }, [open, machineId]);

  // Venue-mapped products first (PRD §3.2) - on a VOX machine those are the
  // flavors the venue itself stocks, which is what he is usually reaching for.
  const visible = useMemo(() => {
    const q = query.trim().toLowerCase();
    const filtered = q
      ? products.filter((p) => p.name.toLowerCase().includes(q))
      : products;
    return filtered.slice(0, 60);
  }, [products, query]);

  if (!open) return null;

  function handleSubmit() {
    setError(null);
    if (!selected) {
      setError("Pick the product you actually filled");
      return;
    }
    const c = REASON_CHIPS.find((x) => x.key === chip);
    const reason =
      chip === "other" ? otherReason.trim() : (c?.reason ?? "substitution");

    startTransition(async () => {
      const res = await driverSubstituteDispatchLine({
        dispatchId,
        newBoonzProductId: selected.product_id,
        filledQty: qty,
        reason: reason || "substitution",
        sourceTag: c?.tag,
        revalidate,
      });
      if (res.ok) {
        onSuccess?.({
          needsReview: res.data?.after?.needs_review === true,
          reviewReason: res.data?.after?.review_reason ?? null,
        });
        onClose();
      } else {
        setError(res.error ?? "Change failed");
      }
    });
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/60 p-0 sm:items-center sm:p-4">
      <div className="max-h-[92vh] w-full max-w-md overflow-y-auto rounded-t-2xl bg-white p-4 shadow-lg sm:rounded-lg dark:bg-slate-900">
        <div className="mb-3 flex items-start justify-between">
          <div>
            <h3 className="text-lg font-semibold">Change product</h3>
            <p className="text-xs text-slate-500">
              Shelf {shelfCode} · replacing {currentProductName}
            </p>
          </div>
          <button
            onClick={onClose}
            aria-label="Close"
            className="text-slate-400 hover:text-slate-600"
          >
            ✕
          </button>
        </div>

        <label className="block text-sm">
          What did you actually fill?
          <input
            type="text"
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              if (selected) setSelected(null);
            }}
            placeholder="Search products on this machine"
            className="mt-1 w-full rounded border px-2 py-2"
          />
        </label>

        {loadingProducts && (
          <p className="mt-2 text-xs text-slate-500">Loading products…</p>
        )}

        {!selected && !loadingProducts && (
          <ul className="mt-2 max-h-56 overflow-y-auto rounded border">
            {visible.map((p) => (
              <li
                key={p.product_id}
                onClick={() => {
                  setSelected({ product_id: p.product_id, name: p.name });
                  setQuery(p.name);
                }}
                className="flex cursor-pointer items-center justify-between px-3 py-2.5 text-sm hover:bg-slate-100 dark:hover:bg-slate-800"
              >
                <span>{p.name}</span>
                {p.venue && (
                  <span className="ml-2 shrink-0 rounded bg-emerald-50 px-1.5 py-0.5 text-[10px] font-semibold text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-400">
                    VENUE
                  </span>
                )}
              </li>
            ))}
            {visible.length === 0 && (
              <li className="px-3 py-2 text-sm text-slate-500">
                No products match.
              </li>
            )}
          </ul>
        )}

        {selected && (
          <p className="mt-2 text-xs text-blue-700">
            ✓ {selected.name} - tap the field above to change
          </p>
        )}

        <label className="mt-3 block text-sm">
          How many went in?
          <input
            type="number"
            min={1}
            value={qty}
            onChange={(e) => setQty(Number(e.target.value))}
            className="mt-1 w-full rounded border px-2 py-2"
          />
        </label>

        <div className="mt-3">
          <p className="text-sm">Why?</p>
          <div className="mt-1 flex flex-wrap gap-2">
            {REASON_CHIPS.map((c) => (
              <button
                key={c.key}
                onClick={() => setChip(c.key)}
                className={`rounded-full border px-3 py-1.5 text-xs font-medium transition-colors ${
                  chip === c.key
                    ? "border-blue-500 bg-blue-50 text-blue-700 dark:bg-blue-950/40 dark:text-blue-300"
                    : "border-slate-200 text-slate-600 dark:border-slate-700 dark:text-slate-400"
                }`}
              >
                {c.label}
              </button>
            ))}
          </div>
          {chip === "other" && (
            <input
              type="text"
              value={otherReason}
              onChange={(e) => setOtherReason(e.target.value)}
              placeholder="Say what happened"
              className="mt-2 w-full rounded border px-2 py-2 text-sm"
            />
          )}
        </div>

        <p className="mt-3 text-xs text-slate-500">
          Saved straight away. Head office reviews it at day close - you do not
          need approval to keep going.
        </p>

        {error && (
          <p className="mt-3 rounded bg-red-50 px-3 py-2 text-sm text-red-700">
            {error}
          </p>
        )}

        <div className="mt-4 flex justify-end gap-2">
          <button
            onClick={onClose}
            disabled={isPending}
            className="min-h-[44px] rounded border px-4 text-sm"
          >
            Cancel
          </button>
          <button
            onClick={handleSubmit}
            disabled={isPending}
            className="min-h-[44px] rounded bg-blue-600 px-4 text-sm font-medium text-white disabled:opacity-50"
          >
            {isPending ? "Saving…" : "Save change"}
          </button>
        </div>
      </div>
    </div>
  );
}
