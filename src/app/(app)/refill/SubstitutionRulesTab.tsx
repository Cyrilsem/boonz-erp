"use client";

// ONE-LOOP-3 Job 1.8 (PRD-124): substitution rules table under /refill
// settings. List + add + deactivate, backed by substitution_rules via the
// add_substitution_rule / deactivate_substitution_rule RPCs (RLS on the table
// gives `authenticated` no write grants, so those RPCs are the only path).

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface PodProductOption {
  pod_product_id: string;
  pod_product_name: string;
}

interface SubstitutionRule {
  rule_id: string;
  priority: number;
  when_pod_product_id: string | null;
  when_pod_product_name: string | null;
  when_condition: string | null;
  then_pod_product_id: string | null;
  then_pod_product_name: string | null;
  then_qty_rule: string | null;
  never_if_on_machine: boolean;
  active: boolean;
  note: string | null;
  created_at: string;
}

export default function SubstitutionRulesTab() {
  const [rules, setRules] = useState<SubstitutionRule[]>([]);
  const [products, setProducts] = useState<PodProductOption[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showInactive, setShowInactive] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);

  const [whenId, setWhenId] = useState("");
  const [thenId, setThenId] = useState("");
  const [priority, setPriority] = useState(100);
  const [condition, setCondition] = useState("");
  const [qtyRule, setQtyRule] = useState("");
  const [neverIfOnMachine, setNeverIfOnMachine] = useState(true);
  const [note, setNote] = useState("");
  const [adding, setAdding] = useState(false);

  const fetchAll = useCallback(async () => {
    const supabase = createClient();
    const [{ data: ruleRows, error: ruleErr }, { data: prodRows }] =
      await Promise.all([
        supabase
          .from("substitution_rules")
          .select(
            "rule_id, priority, when_pod_product_id, when_condition, then_pod_product_id, then_qty_rule, never_if_on_machine, active, note, created_at",
          )
          .order("priority", { ascending: true })
          .limit(10000),
        supabase
          .from("pod_products")
          .select("pod_product_id, pod_product_name")
          .order("pod_product_name")
          .limit(10000),
      ]);
    if (ruleErr) {
      setError(ruleErr.message);
      setLoading(false);
      return;
    }
    const prods = (prodRows ?? []) as PodProductOption[];
    const nameById = new Map(
      prods.map((p) => [p.pod_product_id, p.pod_product_name]),
    );
    const shaped: SubstitutionRule[] = (ruleRows ?? []).map((r) => ({
      ...r,
      when_pod_product_name: nameById.get(r.when_pod_product_id ?? "") ?? null,
      then_pod_product_name: nameById.get(r.then_pod_product_id ?? "") ?? null,
    })) as SubstitutionRule[];
    setProducts(prods);
    setRules(shaped);
    setLoading(false);
  }, []);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial load, same pattern as sibling refill panels
    fetchAll();
  }, [fetchAll]);

  async function handleAdd() {
    setError(null);
    if (!whenId || !thenId) {
      setError("Pick both a 'when' and a 'then' product.");
      return;
    }
    if (whenId === thenId) {
      setError("A rule cannot substitute a product for itself.");
      return;
    }
    setAdding(true);
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    const { error: rpcErr } = await supabase.rpc("add_substitution_rule", {
      p_when_pod_product_id: whenId,
      p_then_pod_product_id: thenId,
      p_priority: priority,
      p_when_condition: condition || null,
      p_then_qty_rule: qtyRule || null,
      p_never_if_on_machine: neverIfOnMachine,
      p_note: note || null,
      p_caller: user?.id ?? null,
    });
    if (rpcErr) {
      setError(rpcErr.message);
      setAdding(false);
      return;
    }
    setWhenId("");
    setThenId("");
    setPriority(100);
    setCondition("");
    setQtyRule("");
    setNeverIfOnMachine(true);
    setNote("");
    setAdding(false);
    await fetchAll();
  }

  async function handleDeactivate(ruleId: string) {
    setBusy(ruleId);
    setError(null);
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    const { error: rpcErr } = await supabase.rpc(
      "deactivate_substitution_rule",
      { p_rule_id: ruleId, p_caller: user?.id ?? null },
    );
    if (rpcErr) {
      setError(rpcErr.message);
      setBusy(null);
      return;
    }
    setBusy(null);
    await fetchAll();
  }

  if (loading) return <p className="text-sm text-gray-500">Loading…</p>;

  const visibleRules = showInactive ? rules : rules.filter((r) => r.active);

  return (
    <div className="space-y-6">
      <div className="rounded-xl border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
        <h3 className="mb-3 text-sm font-bold uppercase tracking-wide text-neutral-700 dark:text-neutral-300">
          Add substitution rule
        </h3>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <label className="text-xs text-neutral-500">
            When (out of stock)
            <select
              value={whenId}
              onChange={(e) => setWhenId(e.target.value)}
              className="mt-1 w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
            >
              <option value="">select…</option>
              {products.map((p) => (
                <option key={p.pod_product_id} value={p.pod_product_id}>
                  {p.pod_product_name}
                </option>
              ))}
            </select>
          </label>
          <label className="text-xs text-neutral-500">
            Then substitute with
            <select
              value={thenId}
              onChange={(e) => setThenId(e.target.value)}
              className="mt-1 w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
            >
              <option value="">select…</option>
              {products.map((p) => (
                <option key={p.pod_product_id} value={p.pod_product_id}>
                  {p.pod_product_name}
                </option>
              ))}
            </select>
          </label>
          <label className="text-xs text-neutral-500">
            Priority (lower = tried first)
            <input
              type="number"
              value={priority}
              onChange={(e) => setPriority(Number(e.target.value) || 0)}
              className="mt-1 w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
            />
          </label>
          <label className="text-xs text-neutral-500">
            Condition (optional)
            <input
              type="text"
              value={condition}
              onChange={(e) => setCondition(e.target.value)}
              placeholder="e.g. out_of_stock"
              className="mt-1 w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
            />
          </label>
          <label className="text-xs text-neutral-500">
            Qty rule (optional)
            <input
              type="text"
              value={qtyRule}
              onChange={(e) => setQtyRule(e.target.value)}
              placeholder="e.g. same_qty"
              className="mt-1 w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
            />
          </label>
          <label className="flex items-center gap-2 text-xs text-neutral-500 mt-5">
            <input
              type="checkbox"
              checked={neverIfOnMachine}
              onChange={(e) => setNeverIfOnMachine(e.target.checked)}
            />
            Never substitute if the shelf already has this product
          </label>
        </div>
        <label className="mt-3 block text-xs text-neutral-500">
          Note
          <input
            type="text"
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="Why this rule exists"
            className="mt-1 w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
          />
        </label>
        <button
          onClick={handleAdd}
          disabled={adding}
          className="mt-3 rounded-lg bg-neutral-900 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900"
        >
          {adding ? "Adding…" : "+ Add rule"}
        </button>
      </div>

      {error && (
        <p className="rounded-lg bg-rose-50 px-3 py-2 text-xs text-rose-700 dark:bg-rose-950/30 dark:text-rose-400">
          {error}
        </p>
      )}

      <div className="rounded-xl border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
        <div className="mb-3 flex items-center justify-between">
          <h3 className="text-sm font-bold uppercase tracking-wide text-neutral-700 dark:text-neutral-300">
            Rules ({visibleRules.length})
          </h3>
          <label className="flex items-center gap-2 text-xs text-neutral-500">
            <input
              type="checkbox"
              checked={showInactive}
              onChange={(e) => setShowInactive(e.target.checked)}
            />
            Show deactivated
          </label>
        </div>
        <ul className="space-y-2">
          {visibleRules.map((r) => (
            <li
              key={r.rule_id}
              className={`rounded-lg border p-3 text-sm ${
                r.active
                  ? "border-neutral-200 dark:border-neutral-800"
                  : "border-neutral-100 bg-neutral-50 text-neutral-400 dark:border-neutral-900 dark:bg-neutral-900"
              }`}
            >
              <div className="flex items-start justify-between gap-2">
                <div>
                  <p>
                    <span className="font-mono text-xs text-neutral-400">
                      #{r.priority}
                    </span>{" "}
                    {r.when_pod_product_name ?? "(unknown)"} →{" "}
                    {r.then_pod_product_name ?? "(unknown)"}
                  </p>
                  <p className="mt-1 text-xs text-neutral-500">
                    {r.when_condition && <span>if {r.when_condition} · </span>}
                    {r.then_qty_rule && <span>{r.then_qty_rule} · </span>}
                    {r.never_if_on_machine
                      ? "never if already on shelf"
                      : "may substitute even if already on shelf"}
                  </p>
                  {r.note && (
                    <p className="mt-1 text-xs italic text-neutral-400">
                      {r.note}
                    </p>
                  )}
                </div>
                {r.active && (
                  <button
                    onClick={() => handleDeactivate(r.rule_id)}
                    disabled={busy === r.rule_id}
                    className="shrink-0 rounded border border-rose-300 px-2 py-1 text-xs font-medium text-rose-700 hover:bg-rose-50 disabled:opacity-50 dark:border-rose-800 dark:text-rose-400"
                  >
                    {busy === r.rule_id ? "…" : "Deactivate"}
                  </button>
                )}
                {!r.active && (
                  <span className="shrink-0 rounded bg-neutral-200 px-2 py-1 text-[10px] font-semibold uppercase text-neutral-500 dark:bg-neutral-800">
                    Inactive
                  </span>
                )}
              </div>
            </li>
          ))}
          {visibleRules.length === 0 && (
            <li className="text-sm text-neutral-400">No rules yet.</li>
          )}
        </ul>
      </div>
    </div>
  );
}
