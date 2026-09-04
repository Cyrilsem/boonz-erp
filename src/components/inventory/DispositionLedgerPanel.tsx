"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface LedgerRow {
  event_id: string;
  created_at: string;
  actor_name: string | null;
  source: string;
  machine_name: string | null;
  boonz_product_name: string | null;
  sourcing_channel: string | null;
  qty: number;
  state: string;
  disposal_code: string | null;
  target_machine_name: string | null;
  value_aed: number | null;
  is_current: boolean;
}

interface RedeployOutcome {
  outcome_state: string | null;
  qty: number;
}

function monthKey(iso: string) {
  return iso.slice(0, 7);
}

/**
 * PRD-119 P4: disposition ledger + reports (waste by product/supplier/
 * machine/month with value, redeploy success rate). Reads
 * v_disposition_ledger and v_redeploy_outcomes (the canonical objects) and
 * aggregates client-side over a bounded window — no report-specific view per
 * dimension, avoiding metric proliferation (Article 16).
 */
export default function DispositionLedgerPanel() {
  const [rows, setRows] = useState<LedgerRow[]>([]);
  const [outcomes, setOutcomes] = useState<RedeployOutcome[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [monthsBack, setMonthsBack] = useState(3);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      setLoading(true);
      setError(null);
      const supabase = createClient();
      const since = new Date();
      since.setMonth(since.getMonth() - monthsBack);
      const [ledgerRes, outcomeRes] = await Promise.all([
        supabase
          .from("v_disposition_ledger")
          .select("*")
          .gte("created_at", since.toISOString())
          .order("created_at", { ascending: false })
          .limit(10000),
        supabase
          .from("v_redeploy_outcomes")
          .select("outcome_state, qty")
          .limit(10000),
      ]);
      if (cancelled) return;
      if (ledgerRes.error) {
        setError(ledgerRes.error.message);
        setRows([]);
      } else {
        setRows((ledgerRes.data ?? []) as LedgerRow[]);
      }
      setOutcomes((outcomeRes.data ?? []) as RedeployOutcome[]);
      setLoading(false);
    }
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial fetch, same pattern as sibling panels
    void load();
    return () => {
      cancelled = true;
    };
  }, [monthsBack]);

  const wasteRows = useMemo(
    () => rows.filter((r) => r.state === "waste" && r.is_current),
    [rows],
  );

  const byProduct = useMemo(() => {
    const m = new Map<string, { qty: number; value: number }>();
    for (const r of wasteRows) {
      const key = r.boonz_product_name ?? "(unknown)";
      const cur = m.get(key) ?? { qty: 0, value: 0 };
      cur.qty += r.qty;
      cur.value += r.value_aed ?? 0;
      m.set(key, cur);
    }
    return [...m.entries()]
      .sort((a, b) => b[1].value - a[1].value)
      .slice(0, 10);
  }, [wasteRows]);

  const byMachine = useMemo(() => {
    const m = new Map<string, { qty: number; value: number }>();
    for (const r of wasteRows) {
      const key = r.machine_name ?? "(warehouse)";
      const cur = m.get(key) ?? { qty: 0, value: 0 };
      cur.qty += r.qty;
      cur.value += r.value_aed ?? 0;
      m.set(key, cur);
    }
    return [...m.entries()]
      .sort((a, b) => b[1].value - a[1].value)
      .slice(0, 10);
  }, [wasteRows]);

  const bySupplier = useMemo(() => {
    const m = new Map<string, { qty: number; value: number }>();
    for (const r of wasteRows) {
      const key = r.sourcing_channel ?? "(unknown)";
      const cur = m.get(key) ?? { qty: 0, value: 0 };
      cur.qty += r.qty;
      cur.value += r.value_aed ?? 0;
      m.set(key, cur);
    }
    return [...m.entries()].sort((a, b) => b[1].value - a[1].value);
  }, [wasteRows]);

  const byMonth = useMemo(() => {
    const m = new Map<string, { qty: number; value: number }>();
    for (const r of wasteRows) {
      const key = monthKey(r.created_at);
      const cur = m.get(key) ?? { qty: 0, value: 0 };
      cur.qty += r.qty;
      cur.value += r.value_aed ?? 0;
      m.set(key, cur);
    }
    return [...m.entries()].sort((a, b) => (a[0] < b[0] ? 1 : -1));
  }, [wasteRows]);

  const redeploySuccess = useMemo(() => {
    const total = outcomes.length;
    const resolved = outcomes.filter((o) => o.outcome_state !== null);
    const success = outcomes.filter((o) => o.outcome_state === "redeployed");
    return {
      total,
      resolved: resolved.length,
      pending: total - resolved.length,
      success: success.length,
      rate:
        resolved.length > 0 ? (success.length / resolved.length) * 100 : null,
    };
  }, [outcomes]);

  const totalWasteValue = wasteRows.reduce((s, r) => s + (r.value_aed ?? 0), 0);

  if (loading) {
    return (
      <div className="rounded-lg border border-neutral-300 bg-neutral-50 p-4 text-sm dark:border-neutral-700 dark:bg-neutral-900">
        Loading disposition ledger…
      </div>
    );
  }
  if (error) {
    return (
      <div className="rounded-lg border border-rose-300 bg-rose-50 p-4 text-sm dark:border-rose-800 dark:bg-rose-950/20">
        <div className="font-semibold text-rose-800 dark:text-rose-200">
          Could not load disposition ledger
        </div>
        <div className="mt-1 text-xs text-rose-700 dark:text-rose-300">
          {error}
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2">
        <span className="text-sm font-semibold">Reports</span>
        <select
          value={monthsBack}
          onChange={(e) => setMonthsBack(Number(e.target.value))}
          className="ml-auto rounded border border-neutral-300 bg-white px-2 py-1 text-xs dark:border-neutral-700 dark:bg-neutral-900"
        >
          <option value={1}>Last 1 month</option>
          <option value={3}>Last 3 months</option>
          <option value={6}>Last 6 months</option>
          <option value={12}>Last 12 months</option>
        </select>
      </div>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <div className="rounded-lg border border-neutral-300 p-3 dark:border-neutral-700">
          <div className="text-[11px] text-neutral-500">Waste value</div>
          <div className="text-lg font-semibold">
            {totalWasteValue.toFixed(2)} AED
          </div>
        </div>
        <div className="rounded-lg border border-neutral-300 p-3 dark:border-neutral-700">
          <div className="text-[11px] text-neutral-500">Waste events</div>
          <div className="text-lg font-semibold">{wasteRows.length}</div>
        </div>
        <div className="rounded-lg border border-neutral-300 p-3 dark:border-neutral-700">
          <div className="text-[11px] text-neutral-500">
            Redeploy success rate
          </div>
          <div className="text-lg font-semibold">
            {redeploySuccess.rate === null
              ? "—"
              : `${redeploySuccess.rate.toFixed(0)}%`}
          </div>
          <div className="text-[10px] text-neutral-500">
            {redeploySuccess.success}/{redeploySuccess.resolved} resolved
          </div>
        </div>
        <div className="rounded-lg border border-neutral-300 p-3 dark:border-neutral-700">
          <div className="text-[11px] text-neutral-500">Redeploy pending</div>
          <div className="text-lg font-semibold">{redeploySuccess.pending}</div>
        </div>
      </div>

      <div className="grid gap-4 sm:grid-cols-3">
        <ReportTable title="Top waste by product" rows={byProduct} />
        <ReportTable title="Top waste by machine" rows={byMachine} />
        <ReportTable title="Waste by sourcing channel" rows={bySupplier} />
      </div>

      <ReportTable title="Waste by month" rows={byMonth} />

      <div>
        <div className="mb-2 text-sm font-semibold">
          Ledger ({rows.length} events)
        </div>
        <div className="max-h-96 overflow-auto rounded-lg border border-neutral-300 dark:border-neutral-700">
          <table className="w-full text-xs">
            <thead className="sticky top-0 bg-neutral-100 text-left dark:bg-neutral-900">
              <tr>
                <th className="px-3 py-2 font-semibold">When</th>
                <th className="px-3 py-2 font-semibold">Source</th>
                <th className="px-3 py-2 font-semibold">Product</th>
                <th className="px-3 py-2 font-semibold">Machine</th>
                <th className="px-3 py-2 font-semibold">State</th>
                <th className="px-3 py-2 text-right font-semibold">Qty</th>
                <th className="px-3 py-2 text-right font-semibold">Value</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-neutral-200 dark:divide-neutral-800">
              {rows.slice(0, 500).map((r) => (
                <tr key={r.event_id}>
                  <td className="px-3 py-1.5 font-mono text-neutral-500">
                    {new Date(r.created_at).toLocaleString()}
                  </td>
                  <td className="px-3 py-1.5">{r.source}</td>
                  <td className="px-3 py-1.5">{r.boonz_product_name ?? "—"}</td>
                  <td className="px-3 py-1.5">
                    {r.machine_name ?? r.target_machine_name ?? "—"}
                  </td>
                  <td className="px-3 py-1.5">
                    <span
                      className={`rounded px-1.5 py-0.5 text-[10px] font-semibold ${
                        r.state === "waste"
                          ? "bg-rose-100 text-rose-800 dark:bg-rose-900/40 dark:text-rose-200"
                          : r.state.startsWith("redeploy")
                            ? "bg-sky-100 text-sky-800 dark:bg-sky-900/40 dark:text-sky-200"
                            : "bg-neutral-100 text-neutral-700 dark:bg-neutral-800 dark:text-neutral-300"
                      }`}
                    >
                      {r.state}
                      {!r.is_current ? " (superseded)" : ""}
                    </span>
                  </td>
                  <td className="px-3 py-1.5 text-right font-mono">{r.qty}</td>
                  <td className="px-3 py-1.5 text-right font-mono">
                    {r.value_aed?.toFixed(2) ?? "—"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

function ReportTable({
  title,
  rows,
}: {
  title: string;
  rows: [string, { qty: number; value: number }][];
}) {
  return (
    <div className="rounded-lg border border-neutral-300 dark:border-neutral-700">
      <div className="border-b border-neutral-200 px-3 py-2 text-xs font-semibold dark:border-neutral-800">
        {title}
      </div>
      <table className="w-full text-xs">
        <tbody className="divide-y divide-neutral-200 dark:divide-neutral-800">
          {rows.length === 0 && (
            <tr>
              <td className="px-3 py-2 text-neutral-500">No data</td>
            </tr>
          )}
          {rows.map(([label, v]) => (
            <tr key={label}>
              <td className="px-3 py-1.5">{label}</td>
              <td className="px-3 py-1.5 text-right font-mono">{v.qty}</td>
              <td className="px-3 py-1.5 text-right font-mono text-neutral-500">
                {v.value.toFixed(2)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
