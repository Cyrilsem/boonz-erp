"use client";

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface PendingRemoveRow {
  dispatch_id: string;
  machine: string;
  boonz_product_name: string;
  planned_qty: number;
  driver_confirmed_qty: number;
  driver_confirmed_at: string;
  dispatch_expiry: string | null;
  comment: string | null;
  hours_awaiting_approval: number;
  // Lazy-enriched from refill_dispatching after initial fetch
  pod_product_id?: string | null;
}

interface VariantOption {
  product_id: string; // boonz_product_id
  boonz_product_name: string;
}

interface VariantSplitEntry {
  boonz_product_id: string;
  boonz_product_name: string;
  qty: number;
  expiry: string;
}

/**
 * BUG-010 — WH-manager-side phase of the two-step REMOVE confirmation.
 * BUG-#2 (19-May report) — multi-variant split: when the parent dispatch's
 * pod_product has >1 boonz variant (e.g. Barebells with 3 flavours), WH
 * manager can split the total across the actual variants returned.
 *
 * Single-variant path: calls `wh_approve_remove_receipt` (existing RPC,
 *   wraps receive_dispatch_line with a single-expiry batch_breakdown).
 *
 * Multi-variant path: calls `wh_approve_remove_receipt_multivariant`
 *   (new RPC, creates a child Remove dispatch per variant, each one
 *   receive_dispatch_line'd so the correct WH batch is credited and the
 *   correct variant pod_inventory row is archived).
 */
export default function PendingRemoveApprovalsPanel() {
  const [rows, setRows] = useState<PendingRemoveRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [acting, setActing] = useState<string | null>(null);
  const [overrides, setOverrides] = useState<Record<string, number>>({});
  const [expiryOverrides, setExpiryOverrides] = useState<
    Record<string, string>
  >({});

  // Multi-variant state — per dispatch_id
  const [splitMode, setSplitMode] = useState<Record<string, boolean>>({});
  const [variantOptions, setVariantOptions] = useState<
    Record<string, VariantOption[]>
  >({}); // dispatch_id → available variants for its pod_product
  const [variantSplits, setVariantSplits] = useState<
    Record<string, VariantSplitEntry[]>
  >({}); // dispatch_id → driver's per-variant breakdown

  const fetchRows = useCallback(async () => {
    const supabase = createClient();
    const { data, error } = await supabase
      .from("v_pending_wh_remove_confirmations")
      .select("*");
    if (error) {
      console.error("[PendingRemoveApprovals] fetch failed:", error);
      setRows([]);
      setLoading(false);
      return;
    }
    const baseRows = (data ?? []) as unknown as PendingRemoveRow[];

    // Enrich with pod_product_id from refill_dispatching so we can decide
    // whether the multi-variant split toggle should be available.
    if (baseRows.length > 0) {
      const ids = baseRows.map((r) => r.dispatch_id);
      const { data: dispatchExtras } = await supabase
        .from("refill_dispatching")
        .select("dispatch_id, pod_product_id")
        .in("dispatch_id", ids);
      const podByDispatch = new Map<string, string | null>(
        (dispatchExtras ?? []).map((r) => [
          r.dispatch_id as string,
          (r.pod_product_id as string | null) ?? null,
        ]),
      );
      for (const r of baseRows) {
        r.pod_product_id = podByDispatch.get(r.dispatch_id) ?? null;
      }
    }
    setRows(baseRows);
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchRows();
  }, [fetchRows]);

  // Realtime: refetch on any dispatch row change
  useEffect(() => {
    const supabase = createClient();
    const ch = supabase
      .channel("pending_remove_approvals")
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "refill_dispatching" },
        () => fetchRows(),
      )
      .subscribe();
    return () => {
      supabase.removeChannel(ch);
    };
  }, [fetchRows]);

  // Lazy-load available variants for a pod_product when the user opens split mode
  const loadVariantsForRow = useCallback(
    async (row: PendingRemoveRow) => {
      if (!row.pod_product_id) {
        alert(
          "Cannot split — this dispatch has no pod_product_id linked. Approve as single variant.",
        );
        return;
      }
      if (variantOptions[row.dispatch_id]) return; // already loaded
      const supabase = createClient();
      const { data, error } = await supabase
        .from("product_mapping")
        .select(
          "boonz_product_id, boonz_products(product_id, boonz_product_name)",
        )
        .eq("pod_product_id", row.pod_product_id)
        .eq("status", "Active");
      if (error || !data) {
        console.error(
          "[PendingRemoveApprovals] variant lookup failed:",
          error,
        );
        return;
      }
      const opts: VariantOption[] = [];
      const seen = new Set<string>();
      for (const m of data as Array<{
        boonz_product_id: string;
        boonz_products:
          | { product_id: string; boonz_product_name: string }
          | { product_id: string; boonz_product_name: string }[]
          | null;
      }>) {
        const bp = Array.isArray(m.boonz_products)
          ? m.boonz_products[0]
          : m.boonz_products;
        const id = bp?.product_id ?? m.boonz_product_id;
        if (!id || seen.has(id)) continue;
        seen.add(id);
        opts.push({
          product_id: id,
          boonz_product_name: bp?.boonz_product_name ?? "(unnamed)",
        });
      }
      opts.sort((a, b) =>
        a.boonz_product_name.localeCompare(b.boonz_product_name),
      );
      setVariantOptions((prev) => ({ ...prev, [row.dispatch_id]: opts }));
      // Seed the split entries with all variants at qty=0, expiry = dispatch_expiry or ""
      const seedExpiry =
        expiryOverrides[row.dispatch_id] || row.dispatch_expiry || "";
      setVariantSplits((prev) => ({
        ...prev,
        [row.dispatch_id]: opts.map((v) => ({
          boonz_product_id: v.product_id,
          boonz_product_name: v.boonz_product_name,
          qty: 0,
          expiry: seedExpiry,
        })),
      }));
    },
    [variantOptions, expiryOverrides],
  );

  function toggleSplitMode(row: PendingRemoveRow) {
    const willOpen = !splitMode[row.dispatch_id];
    if (willOpen) {
      void loadVariantsForRow(row);
    }
    setSplitMode((prev) => ({ ...prev, [row.dispatch_id]: willOpen }));
  }

  function updateVariantEntry(
    dispatchId: string,
    idx: number,
    patch: Partial<VariantSplitEntry>,
  ) {
    setVariantSplits((prev) => {
      const list = prev[dispatchId] ?? [];
      const next = list.map((e, i) => (i === idx ? { ...e, ...patch } : e));
      return { ...prev, [dispatchId]: next };
    });
  }

  async function handleApproveSingleVariant(row: PendingRemoveRow) {
    setActing(row.dispatch_id);
    const supabase = createClient();
    const verifiedQty = overrides[row.dispatch_id] ?? row.driver_confirmed_qty;

    const chosenExpiry =
      expiryOverrides[row.dispatch_id] || row.dispatch_expiry || "";
    if (!chosenExpiry) {
      alert(
        "Enter an expiry date for this batch (the dispatch had no expiry). " +
          "The receipt will be credited to that batch in warehouse_inventory.",
      );
      setActing(null);
      return;
    }

    const breakdown = [{ expiry: chosenExpiry, qty: verifiedQty }];
    const reason =
      verifiedQty === row.driver_confirmed_qty
        ? `WH manager verified — qty matches driver count, batch ${chosenExpiry}`
        : `WH manager verified — adjusted ${row.driver_confirmed_qty}→${verifiedQty}, batch ${chosenExpiry}`;

    const {
      data: { user },
    } = await supabase.auth.getUser();
    const { error } = await supabase.rpc("wh_approve_remove_receipt", {
      p_dispatch_id: row.dispatch_id,
      p_actual_qty: verifiedQty,
      p_batch_breakdown: breakdown,
      p_approved_by: user?.id ?? null,
      p_reason: reason,
    });
    if (error) {
      alert(`Approve failed: ${error.message}`);
      console.error("[PendingRemoveApprovals] approve failed:", error);
    } else {
      await fetchRows();
    }
    setActing(null);
  }

  async function handleApproveMultiVariant(row: PendingRemoveRow) {
    const entries = (variantSplits[row.dispatch_id] ?? []).filter(
      (e) => e.qty > 0,
    );
    const sum = entries.reduce((s, e) => s + e.qty, 0);
    const target = overrides[row.dispatch_id] ?? row.driver_confirmed_qty;

    if (entries.length === 0) {
      alert("Add at least one variant with qty > 0, or close split mode.");
      return;
    }
    if (sum !== target) {
      alert(
        `Variant breakdown sums to ${sum}, but driver/verified qty is ${target}. ` +
          `Adjust per-variant quantities so they total ${target}.`,
      );
      return;
    }
    // Validate every variant has an expiry
    const missingExpiry = entries.find((e) => !e.expiry);
    if (missingExpiry) {
      alert(
        `Variant "${missingExpiry.boonz_product_name}" is missing batch expiry. ` +
          `Each variant credit needs its physical expiry date.`,
      );
      return;
    }

    setActing(row.dispatch_id);
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();

    const reason = `WH manager verified — ${entries.length} variants totalling ${sum} units`;
    const variantBreakdown = entries.map((e) => ({
      boonz_product_id: e.boonz_product_id,
      qty: e.qty,
      expiry: e.expiry,
    }));

    const { error } = await supabase.rpc(
      "wh_approve_remove_receipt_multivariant",
      {
        p_parent_dispatch_id: row.dispatch_id,
        p_variant_breakdown: variantBreakdown,
        p_approved_by: user?.id ?? null,
        p_reason: reason,
      },
    );
    if (error) {
      alert(`Multi-variant approve failed: ${error.message}`);
      console.error(
        "[PendingRemoveApprovals] multi-variant approve failed:",
        error,
      );
    } else {
      await fetchRows();
      // Clear per-row state for this dispatch
      setSplitMode((prev) => {
        const next = { ...prev };
        delete next[row.dispatch_id];
        return next;
      });
      setVariantSplits((prev) => {
        const next = { ...prev };
        delete next[row.dispatch_id];
        return next;
      });
    }
    setActing(null);
  }

  if (loading) return null;
  if (rows.length === 0) return null;

  return (
    <div className="mb-4 rounded-xl border-l-4 border-l-amber-400 border border-neutral-200 bg-amber-50 p-4 dark:border-neutral-800 dark:bg-amber-950/20">
      <div className="mb-3 flex items-center gap-2">
        <span className="text-base">🟡</span>
        <h3 className="text-sm font-bold uppercase tracking-wide text-amber-700 dark:text-amber-400">
          Returns awaiting your approval ({rows.length})
        </h3>
      </div>
      <p className="mb-3 text-xs text-amber-700/80 dark:text-amber-400/80">
        Driver confirmed these REMOVEs in the field. Warehouse stock + pod
        inventory will only update once you verify physical receipt. For
        multi-flavour returns, use <strong>Split by variant</strong> so each
        flavour is credited to the right batch.
      </p>
      <ul className="space-y-2">
        {rows.map((row) => {
          const editedQty =
            overrides[row.dispatch_id] ?? row.driver_confirmed_qty;
          const drifted = editedQty !== row.driver_confirmed_qty;
          const isSplit = !!splitMode[row.dispatch_id];
          const splits = variantSplits[row.dispatch_id] ?? [];
          const splitSum = splits.reduce((s, e) => s + (e.qty || 0), 0);
          const opts = variantOptions[row.dispatch_id] ?? [];
          return (
            <li
              key={row.dispatch_id}
              className="rounded-lg border border-amber-200 bg-white p-3 dark:border-amber-900 dark:bg-neutral-950"
            >
              <div className="mb-2 flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <p className="text-sm font-semibold">
                    {row.boonz_product_name}
                  </p>
                  <p className="text-xs text-neutral-500">
                    {row.machine}
                    {row.dispatch_expiry && (
                      <span className="ml-2">
                        exp{" "}
                        {new Date(row.dispatch_expiry).toLocaleDateString(
                          "en-GB",
                          { day: "2-digit", month: "short", year: "2-digit" },
                        )}
                      </span>
                    )}
                  </p>
                </div>
                <span className="shrink-0 text-xs text-neutral-400">
                  {Math.round(row.hours_awaiting_approval)}h ago
                </span>
              </div>
              <div className="mb-3 flex flex-wrap items-center gap-3 text-xs">
                <span className="text-neutral-500">
                  Planned: <strong>{row.planned_qty}</strong>
                </span>
                <span className="text-neutral-400">·</span>
                <span className="text-neutral-500">
                  Driver said: <strong>{row.driver_confirmed_qty}</strong>
                </span>
                <span className="text-neutral-400">·</span>
                <label className="flex items-center gap-2 text-neutral-500">
                  Verified:
                  <input
                    type="number"
                    min={0}
                    value={editedQty}
                    onChange={(e) =>
                      setOverrides((prev) => ({
                        ...prev,
                        [row.dispatch_id]: parseFloat(e.target.value) || 0,
                      }))
                    }
                    className="w-16 rounded border border-neutral-300 px-2 py-1 text-center text-sm dark:border-neutral-600 dark:bg-neutral-900"
                  />
                </label>
                {drifted && (
                  <span className="rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-amber-800 dark:bg-amber-900/40 dark:text-amber-300">
                    Δ {editedQty - row.driver_confirmed_qty}
                  </span>
                )}
              </div>

              {/* Single-variant expiry input — hidden when split mode active */}
              {!isSplit && (
                <div className="mb-3 flex items-center gap-2 text-xs">
                  <label className="flex items-center gap-2 text-neutral-500">
                    Batch expiry:
                    <input
                      type="date"
                      value={
                        expiryOverrides[row.dispatch_id] ??
                        row.dispatch_expiry ??
                        ""
                      }
                      onChange={(e) =>
                        setExpiryOverrides((prev) => ({
                          ...prev,
                          [row.dispatch_id]: e.target.value,
                        }))
                      }
                      className="rounded border border-neutral-300 px-2 py-1 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                    />
                  </label>
                  {!row.dispatch_expiry &&
                    !expiryOverrides[row.dispatch_id] && (
                      <span className="rounded bg-rose-100 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-rose-800 dark:bg-rose-900/40 dark:text-rose-300">
                        Required — dispatch had no expiry
                      </span>
                    )}
                </div>
              )}

              {/* Split-by-variant toggle + UI */}
              {row.pod_product_id && (
                <div className="mb-3">
                  <button
                    type="button"
                    onClick={() => toggleSplitMode(row)}
                    className="text-xs font-medium text-amber-700 underline hover:text-amber-900 dark:text-amber-300"
                  >
                    {isSplit
                      ? "← Cancel split, approve as single variant"
                      : `↳ Split by variant (driver returned ${editedQty} across multiple flavours)`}
                  </button>
                  {isSplit && (
                    <div className="mt-2 rounded border border-amber-200 bg-amber-50/50 p-2 dark:border-amber-900 dark:bg-amber-950/30">
                      <p className="mb-2 text-[11px] text-amber-800 dark:text-amber-300">
                        Enter the qty + batch expiry of each flavour the
                        driver physically returned. Total must equal{" "}
                        <strong>{editedQty}</strong>.
                      </p>
                      {opts.length === 0 ? (
                        <p className="text-xs text-neutral-500">
                          Loading variants…
                        </p>
                      ) : (
                        <ul className="space-y-1.5">
                          {splits.map((entry, idx) => (
                            <li
                              key={entry.boonz_product_id}
                              className="flex flex-wrap items-center gap-2 text-xs"
                            >
                              <span className="min-w-0 flex-1 truncate text-neutral-700 dark:text-neutral-300">
                                {entry.boonz_product_name}
                              </span>
                              <input
                                type="number"
                                min={0}
                                value={entry.qty}
                                onChange={(e) =>
                                  updateVariantEntry(row.dispatch_id, idx, {
                                    qty: parseFloat(e.target.value) || 0,
                                  })
                                }
                                placeholder="0"
                                className="w-14 rounded border border-neutral-300 px-2 py-1 text-center dark:border-neutral-600 dark:bg-neutral-900"
                              />
                              <input
                                type="date"
                                value={entry.expiry}
                                onChange={(e) =>
                                  updateVariantEntry(row.dispatch_id, idx, {
                                    expiry: e.target.value,
                                  })
                                }
                                className="rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
                              />
                            </li>
                          ))}
                        </ul>
                      )}
                      <div className="mt-2 flex items-center justify-between text-xs">
                        <span
                          className={
                            splitSum === editedQty
                              ? "font-semibold text-green-700 dark:text-green-400"
                              : "font-semibold text-rose-700 dark:text-rose-400"
                          }
                        >
                          Sum: {splitSum} / {editedQty}
                        </span>
                        {splitSum !== editedQty && (
                          <span className="text-rose-700 dark:text-rose-400">
                            {splitSum < editedQty
                              ? `Need ${editedQty - splitSum} more`
                              : `Over by ${splitSum - editedQty}`}
                          </span>
                        )}
                      </div>
                    </div>
                  )}
                </div>
              )}

              {row.comment && (
                <p className="mb-2 truncate text-xs text-neutral-500">
                  Note: {row.comment}
                </p>
              )}

              <button
                onClick={() =>
                  isSplit
                    ? handleApproveMultiVariant(row)
                    : handleApproveSingleVariant(row)
                }
                disabled={
                  acting === row.dispatch_id ||
                  (isSplit && splitSum !== editedQty)
                }
                className="w-full rounded-lg bg-green-600 py-2 text-sm font-medium text-white transition-colors hover:bg-green-700 disabled:opacity-50"
              >
                {acting === row.dispatch_id
                  ? "Approving…"
                  : isSplit
                    ? `✓ Approve ${splitSum} units across ${splits.filter((e) => e.qty > 0).length} variants`
                    : `✓ Approve receipt — credit ${editedQty} units to warehouse`}
              </button>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
