"use client";

// PRD-119 4.1, rebuilt per PRD-131 section 4b (2026-09-22). One lots table per line, always.
// Driver count is read only. Received is editable and accepts clear, overwrite and 0. Sum of
// the lots table must equal Received or Confirm is disabled. A gap between Received and driver
// count requires a reason. Confirm credits exactly the lots table via wm_confirm_line_split,
// nothing else. wm_confirm_line (the old single-line path) is removed: every confirm is now a
// one-or-more-row lots table, so there is exactly one Confirm code path instead of two.
//
// Still calling the existing wm_confirm_line_split RPC, per PRD-131 F5 instruction: the new
// wm_confirm_return RPC (with structured receipt_gap_qty/receipt_gap_reason columns and the
// VOX/venue-warehouse routing) is spec'd in PRD-131 section 4c and lands in a later session.
// Until then, the gap reason is appended to p_reason as free text so it is not lost, but it is
// not yet a queryable column -- see docs/PRD-131-movement-kind.md section 4c.

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

type LotOutcome = "restocked" | "redeploy_pending" | "waste";

interface QueueLine {
  line_id: string;
  source: "dispatch_return" | "driver_expiry_check";
  dispatch_id: string | null;
  machine_id: string;
  machine_name: string;
  shelf_id: string | null;
  shelf_code: string | null;
  boonz_product_id: string;
  boonz_product_name: string;
  pod_product_id: string | null;
  qty: number;
  expiry_date: string | null;
  dispatch_date: string;
  proposed_outcome: "redeploy" | "waste";
  proposed_target_machine_id: string | null;
  proposed_target_machine_name: string | null;
  proposed_waste_by: string | null;
  age_hours: number;
}

interface VariantOption {
  product_id: string;
  boonz_product_name: string;
}

interface LotEntry {
  key: string;
  boonz_product_id: string;
  qty: number | "";
  expiry: string;
  outcome: LotOutcome;
  target_machine_id: string;
  disposal_code: string;
}

const DISPOSAL_CODES = [
  "Waste",
  "Returning to supplier",
  "Returned to supplier",
] as const;

const GAP_REASONS = [
  "Miscount by driver",
  "Damaged",
  "Consumed",
  "Not found",
  "Other",
] as const;

let lotKeySeq = 0;
function newLotKey(): string {
  lotKeySeq += 1;
  return `lot-${lotKeySeq}`;
}

function formatDMY(iso: string | null): string {
  if (!iso) return "no date";
  const [y, m, d] = iso.split("-");
  return `${d}/${m}/${y}`;
}

function sourceLabel(source: QueueLine["source"]): string {
  return source === "driver_expiry_check" ? "expiry check" : "planned return";
}

export default function WarehouseConfirmationsPanel() {
  const [rows, setRows] = useState<QueueLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [acting, setActing] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Received count per line. "" is a valid, deliberate transient state -- it must never be
  // silently coerced to a fallback number, that coercion is exactly what broke the old input
  // (typing over a coerced-back "1" produced "133" in Simran's video).
  const [receivedEdit, setReceivedEdit] = useState<Record<string, number | "">>(
    {},
  );
  const [gapReasonEdit, setGapReasonEdit] = useState<
    Record<string, (typeof GAP_REASONS)[number] | "">
  >({});
  const [gapReasonOtherEdit, setGapReasonOtherEdit] = useState<
    Record<string, string>
  >({});
  const [lots, setLots] = useState<Record<string, LotEntry[]>>({});
  const [variantOptions, setVariantOptions] = useState<
    Record<string, VariantOption[]>
  >({});
  const [machineOptions, setMachineOptions] = useState<
    { machine_id: string; official_name: string }[]
  >([]);

  const fetchRows = useCallback(async () => {
    const supabase = createClient();
    const { data, error: fetchErr } = await supabase
      .from("v_wm_confirmations")
      .select("*")
      .order("age_hours", { ascending: false });
    if (fetchErr) {
      console.error("[WarehouseConfirmations] fetch failed:", fetchErr);
      setError(fetchErr.message);
      setRows([]);
      setLoading(false);
      return;
    }
    const r = (data ?? []) as QueueLine[];
    setRows(r);
    setReceivedEdit((prev) => {
      const next = { ...prev };
      r.forEach((row) => {
        if (!(row.line_id in next)) next[row.line_id] = row.qty;
      });
      return next;
    });
    setLots((prev) => {
      const next = { ...prev };
      r.forEach((row) => {
        if (!(row.line_id in next)) {
          next[row.line_id] = [
            {
              key: newLotKey(),
              boonz_product_id: row.boonz_product_id,
              qty: row.qty,
              expiry: row.expiry_date ?? "",
              outcome:
                row.proposed_outcome === "redeploy"
                  ? "redeploy_pending"
                  : "waste",
              target_machine_id: row.proposed_target_machine_id ?? "",
              disposal_code: "Waste",
            },
          ];
        }
      });
      return next;
    });
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchRows();
  }, [fetchRows]);

  useEffect(() => {
    const supabase = createClient();
    supabase
      .from("machines")
      .select("machine_id, official_name")
      .eq("status", "Active")
      .order("official_name")
      .limit(10000)
      .then(({ data }) => {
        setMachineOptions(
          (data ?? []) as { machine_id: string; official_name: string }[],
        );
      });
  }, []);

  const loadVariantsForRow = useCallback(
    async (row: QueueLine) => {
      if (variantOptions[row.line_id]) return;
      if (!row.pod_product_id) {
        // Expiry-check lines carry no pod_product_id -- the only lot option is the row's own
        // product, not a flavour family. Never leave this row with zero addable options.
        setVariantOptions((prev) => ({
          ...prev,
          [row.line_id]: [
            {
              product_id: row.boonz_product_id,
              boonz_product_name: row.boonz_product_name,
            },
          ],
        }));
        return;
      }
      const supabase = createClient();
      const { data, error: lookupErr } = await supabase
        .from("product_mapping")
        .select(
          "boonz_product_id, boonz_products(product_id, boonz_product_name)",
        )
        .eq("pod_product_id", row.pod_product_id)
        .eq("status", "Active");
      if (lookupErr || !data) {
        console.error(
          "[WarehouseConfirmations] variant lookup failed:",
          lookupErr,
        );
        setVariantOptions((prev) => ({
          ...prev,
          [row.line_id]: [
            {
              product_id: row.boonz_product_id,
              boonz_product_name: row.boonz_product_name,
            },
          ],
        }));
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
      setVariantOptions((prev) => ({ ...prev, [row.line_id]: opts }));
    },
    [variantOptions],
  );

  useEffect(() => {
    rows.forEach((row) => {
      void loadVariantsForRow(row);
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows]);

  function addLotRow(row: QueueLine) {
    const opts = variantOptions[row.line_id] ?? [];
    const defaultProduct = opts[0]?.product_id ?? row.boonz_product_id;
    setLots((prev) => ({
      ...prev,
      [row.line_id]: [
        ...(prev[row.line_id] ?? []),
        {
          key: newLotKey(),
          boonz_product_id: defaultProduct,
          qty: 0,
          expiry: "",
          outcome: "waste",
          target_machine_id: "",
          disposal_code: "Waste",
        },
      ],
    }));
  }

  function removeLotRow(lineId: string, key: string) {
    setLots((prev) => {
      const list = prev[lineId] ?? [];
      if (list.length <= 1) return prev; // always at least one row
      return { ...prev, [lineId]: list.filter((l) => l.key !== key) };
    });
  }

  function updateLot(lineId: string, key: string, patch: Partial<LotEntry>) {
    setLots((prev) => ({
      ...prev,
      [lineId]: (prev[lineId] ?? []).map((l) =>
        l.key === key ? { ...l, ...patch } : l,
      ),
    }));
  }

  function lotSum(lineId: string): number {
    return (lots[lineId] ?? []).reduce(
      (s, l) => s + (typeof l.qty === "number" ? l.qty : 0),
      0,
    );
  }

  function receivedValue(row: QueueLine): number | "" {
    return receivedEdit[row.line_id] ?? row.qty;
  }

  function gapFor(row: QueueLine): number | null {
    const received = receivedValue(row);
    if (received === "") return null;
    return received - row.qty;
  }

  async function confirm(row: QueueLine) {
    const received = receivedValue(row);
    if (received === "" || received < 0) {
      setError("Received must be a number, 0 or more.");
      return;
    }
    const rowLots = (lots[row.line_id] ?? []).filter(
      (l) => typeof l.qty === "number" && l.qty > 0,
    );
    if (rowLots.length === 0) {
      setError("Add at least one lot with qty > 0.");
      return;
    }
    const sum = rowLots.reduce((s, l) => s + (l.qty as number), 0);
    if (sum !== received) {
      setError(
        `Lots table sums to ${sum}, but Received is ${received}. They must match exactly.`,
      );
      return;
    }
    const missingExpiry = rowLots.find(
      (l) => l.outcome !== "waste" && !l.expiry,
    );
    if (missingExpiry) {
      setError("Every non-waste lot needs a batch expiry.");
      return;
    }
    const missingTarget = rowLots.find(
      (l) => l.outcome === "redeploy_pending" && !l.target_machine_id,
    );
    if (missingTarget) {
      setError("A redeploy lot needs a target machine.");
      return;
    }
    const gap = gapFor(row);
    let gapNote = "";
    if (gap !== null && gap !== 0) {
      const reason = gapReasonEdit[row.line_id];
      if (!reason) {
        setError(
          `Received (${received}) differs from driver count (${row.qty}) by ${gap}. Pick a gap reason.`,
        );
        return;
      }
      if (reason === "Other" && !gapReasonOtherEdit[row.line_id]?.trim()) {
        setError('Describe the "Other" gap reason.');
        return;
      }
      const reasonText =
        reason === "Other" ? gapReasonOtherEdit[row.line_id].trim() : reason;
      gapNote = ` | gap ${gap > 0 ? "+" : ""}${gap} vs driver count ${row.qty}: ${reasonText}`;
    }

    setActing(row.line_id);
    setError(null);
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();

    const p_splits = rowLots.map((l) => ({
      boonz_product_id: l.boonz_product_id,
      qty: l.qty,
      expiry: l.expiry || null,
      outcome: l.outcome,
      target_machine_id:
        l.outcome === "redeploy_pending" ? l.target_machine_id : null,
      disposal_code: l.outcome === "waste" ? l.disposal_code : null,
    }));

    const { error: rpcErr } = await supabase.rpc("wm_confirm_line_split", {
      p_line_id: row.line_id,
      p_splits,
      p_reason: `WM confirmed via Warehouse Confirmations queue (${row.source})${gapNote}`,
      p_caller: user?.id ?? null,
      p_dry_run: false,
    });

    if (rpcErr) {
      setError(rpcErr.message);
      setActing(null);
      return;
    }
    setActing(null);
    await fetchRows();
  }

  if (loading) return null;
  if (rows.length === 0) return null;

  return (
    <div className="mb-4 rounded-xl border-l-4 border-l-amber-400 border border-neutral-200 bg-amber-50 p-4 dark:border-neutral-800 dark:bg-amber-950/20">
      <div className="mb-3 flex items-center gap-2">
        <span className="text-base">📦</span>
        <h3 className="text-sm font-bold uppercase tracking-wide text-amber-700 dark:text-amber-400">
          Warehouse Confirmations ({rows.length})
        </h3>
      </div>
      <p className="mb-3 text-xs text-amber-700/80 dark:text-amber-400/80">
        Goods physically left a machine and are waiting on your receipt. Count
        what arrived as one or more lots, confirm this is the only write to
        stock and the disposition ledger for these lines.
      </p>

      {error && (
        <p className="mb-3 rounded-lg bg-rose-50 px-3 py-2 text-xs text-rose-700 dark:bg-rose-950/30 dark:text-rose-400">
          {error}
        </p>
      )}

      <ul className="space-y-2">
        {rows.map((row) => {
          const isOld = row.age_hours > 48;
          const isBusy = acting === row.line_id;
          const rowLots = lots[row.line_id] ?? [];
          const sum = lotSum(row.line_id);
          const received = receivedValue(row);
          const gap = gapFor(row);
          const gapReason = gapReasonEdit[row.line_id] ?? "";
          const vOpts = variantOptions[row.line_id] ?? [];
          const sumMatches = received !== "" && sum === received;
          const gapOk =
            gap === null ||
            gap === 0 ||
            (!!gapReason &&
              (gapReason !== "Other" ||
                !!gapReasonOtherEdit[row.line_id]?.trim()));
          const canConfirm = sumMatches && gapOk && !isBusy;

          return (
            <li
              key={row.line_id}
              className={`rounded-lg border p-3 dark:bg-neutral-950 ${
                isOld
                  ? "border-red-300 bg-red-50 dark:border-red-900"
                  : "border-amber-200 bg-white dark:border-amber-900"
              }`}
            >
              <div className="mb-2 flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <p className="text-sm font-semibold">
                    {row.boonz_product_name}
                  </p>
                  <p className="text-xs text-neutral-500">
                    {row.machine_name}
                    {row.shelf_code ? ` / ${row.shelf_code}` : ""} ·{" "}
                    {sourceLabel(row.source)}
                  </p>
                </div>
                <span
                  className={`shrink-0 text-xs ${isOld ? "font-semibold text-red-600 dark:text-red-400" : "text-neutral-400"}`}
                >
                  {Math.round(row.age_hours)}h ago
                </span>
              </div>

              <div className="mb-3 flex flex-wrap items-center gap-3 text-xs">
                <span className="flex items-center gap-2 text-neutral-500">
                  Driver count:{" "}
                  <strong className="text-neutral-700 dark:text-neutral-300">
                    {row.qty}
                  </strong>
                </span>
                <label className="flex items-center gap-2 text-neutral-500">
                  Received:
                  <input
                    type="number"
                    min={0}
                    disabled={isBusy}
                    value={received}
                    onChange={(e) => {
                      const v = e.target.value;
                      setReceivedEdit((prev) => ({
                        ...prev,
                        [row.line_id]: v === "" ? "" : Number(v),
                      }));
                    }}
                    className="w-16 rounded border border-neutral-300 px-2 py-1 text-center dark:border-neutral-600 dark:bg-neutral-900"
                  />
                </label>
                {gap !== null && gap !== 0 && (
                  <span className="font-semibold text-rose-700 dark:text-rose-400">
                    Gap: {gap > 0 ? "+" : ""}
                    {gap}
                  </span>
                )}
              </div>

              {gap !== null && gap !== 0 && (
                <div className="mb-3 flex flex-wrap items-center gap-2 text-xs">
                  <label className="flex items-center gap-2 text-neutral-500">
                    Gap reason:
                    <select
                      disabled={isBusy}
                      value={gapReason}
                      onChange={(e) =>
                        setGapReasonEdit((prev) => ({
                          ...prev,
                          [row.line_id]: e.target
                            .value as (typeof GAP_REASONS)[number],
                        }))
                      }
                      className="rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
                    >
                      <option value="">select…</option>
                      {GAP_REASONS.map((r) => (
                        <option key={r} value={r}>
                          {r}
                        </option>
                      ))}
                    </select>
                  </label>
                  {gapReason === "Other" && (
                    <input
                      type="text"
                      disabled={isBusy}
                      placeholder="describe"
                      value={gapReasonOtherEdit[row.line_id] ?? ""}
                      onChange={(e) =>
                        setGapReasonOtherEdit((prev) => ({
                          ...prev,
                          [row.line_id]: e.target.value,
                        }))
                      }
                      className="min-w-0 flex-1 rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
                    />
                  )}
                </div>
              )}

              <div className="mb-3 rounded border border-amber-200 bg-amber-50/50 p-2 dark:border-amber-900 dark:bg-amber-950/30">
                <p className="mb-2 text-[11px] text-amber-800 dark:text-amber-300">
                  Lots table -- one row per (flavour, expiry). Sum must equal
                  Received (<strong>{received === "" ? "?" : received}</strong>
                  ).
                </p>
                {vOpts.length === 0 ? (
                  <p className="text-xs text-neutral-500">Loading…</p>
                ) : (
                  <ul className="space-y-2">
                    {rowLots.map((lot) => (
                      <li
                        key={lot.key}
                        className="flex flex-wrap items-center gap-2 text-xs"
                      >
                        <select
                          disabled={isBusy}
                          value={lot.boonz_product_id}
                          onChange={(e) =>
                            updateLot(row.line_id, lot.key, {
                              boonz_product_id: e.target.value,
                            })
                          }
                          className="min-w-0 flex-1 rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
                        >
                          {vOpts.map((v) => (
                            <option key={v.product_id} value={v.product_id}>
                              {v.boonz_product_name}
                            </option>
                          ))}
                        </select>
                        <input
                          type="number"
                          min={0}
                          disabled={isBusy}
                          value={lot.qty}
                          onChange={(e) => {
                            const v = e.target.value;
                            updateLot(row.line_id, lot.key, {
                              qty: v === "" ? "" : Number(v),
                            });
                          }}
                          placeholder="0"
                          className="w-14 rounded border border-neutral-300 px-2 py-1 text-center dark:border-neutral-600 dark:bg-neutral-900"
                        />
                        <input
                          type="date"
                          disabled={isBusy}
                          value={lot.expiry}
                          onChange={(e) =>
                            updateLot(row.line_id, lot.key, {
                              expiry: e.target.value,
                            })
                          }
                          className="rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
                        />
                        <select
                          disabled={isBusy}
                          value={lot.outcome}
                          onChange={(e) =>
                            updateLot(row.line_id, lot.key, {
                              outcome: e.target.value as LotOutcome,
                            })
                          }
                          className="rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
                        >
                          <option value="restocked">Back to stock</option>
                          <option value="redeploy_pending">Redeploy</option>
                          <option value="waste">Waste</option>
                        </select>
                        {lot.outcome === "redeploy_pending" && (
                          <select
                            disabled={isBusy}
                            value={lot.target_machine_id}
                            onChange={(e) =>
                              updateLot(row.line_id, lot.key, {
                                target_machine_id: e.target.value,
                              })
                            }
                            className="rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
                          >
                            <option value="">target…</option>
                            {machineOptions.map((m) => (
                              <option key={m.machine_id} value={m.machine_id}>
                                {m.official_name}
                              </option>
                            ))}
                          </select>
                        )}
                        {lot.outcome === "waste" && (
                          <select
                            disabled={isBusy}
                            value={lot.disposal_code}
                            onChange={(e) =>
                              updateLot(row.line_id, lot.key, {
                                disposal_code: e.target.value,
                              })
                            }
                            className="rounded border border-neutral-300 px-2 py-1 dark:border-neutral-600 dark:bg-neutral-900"
                          >
                            {DISPOSAL_CODES.map((c) => (
                              <option key={c} value={c}>
                                {c}
                              </option>
                            ))}
                          </select>
                        )}
                        <button
                          type="button"
                          disabled={isBusy || rowLots.length <= 1}
                          onClick={() => removeLotRow(row.line_id, lot.key)}
                          className="text-neutral-400 hover:text-rose-600 disabled:opacity-30"
                          aria-label="Remove lot row"
                        >
                          ✕
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
                <div className="mt-2 flex items-center justify-between text-xs">
                  <button
                    type="button"
                    disabled={isBusy}
                    onClick={() => addLotRow(row)}
                    className="font-medium text-amber-700 underline hover:text-amber-900 dark:text-amber-300"
                  >
                    + add lot row
                  </button>
                  <span
                    className={
                      sumMatches
                        ? "font-semibold text-green-700 dark:text-green-400"
                        : "font-semibold text-rose-700 dark:text-rose-400"
                    }
                  >
                    Sum: {sum} / {received === "" ? "?" : received}
                  </span>
                </div>
              </div>

              <p className="mb-2 text-[11px] text-neutral-400">
                System proposed:{" "}
                {row.proposed_outcome === "redeploy"
                  ? `redeploy → ${row.proposed_target_machine_name ?? "?"}, waste by ${formatDMY(row.proposed_waste_by)}`
                  : "waste"}
              </p>

              <button
                onClick={() => confirm(row)}
                disabled={!canConfirm}
                className="w-full rounded-lg bg-green-600 py-2 text-sm font-medium text-white transition-colors hover:bg-green-700 disabled:opacity-50"
              >
                {isBusy
                  ? "Confirming…"
                  : `✓ Confirm ${sum} unit${sum === 1 ? "" : "s"} across ${rowLots.filter((l) => typeof l.qty === "number" && l.qty > 0).length} lot(s)`}
              </button>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
