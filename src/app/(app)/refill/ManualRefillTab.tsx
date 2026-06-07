"use client";

// ManualRefillTab — manual-first refill flow (Stax, 2026-06-04).
// Flow: pick machines from health-style cards -> create_refill_plan (engine NOT run)
// -> per-machine shelf-level edit (refill qty / add / swap / remove) -> Submit.
// Submit chain DELIBERATELY skips engine_finalize_pod (it supersedes manual draft rows
// and rebuilds only from empty engine staging). See BOONZ BRAIN/spec_manual_refill_fe_stax.md.
// All writes go through canonical RPCs (Rule S1). Every rpc() call site is greppable (S2).

import { useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";

// ── Types ───────────────────────────────────────────────────────────────────

type MachineCard = {
  machine_id: string;
  machine_name: string;
  fill_pct: number;
  slots_at_zero: number;
  days_until_empty: number;
  health_tier: "critical" | "warning" | "healthy" | "excluded";
  pending_swap_count: number;
};

type Slot = {
  slot: string;
  product: string;
  current_stock: number;
  max_stock: number;
  fill_pct: number;
  expiry_days: number | null;
  refill_qty: number | null;
  suggested_product: string | null;
  shelf_id: string | null;
  pod_product_id: string | null;
  suggested_pod_product_id: string | null;
};

type Substitute = {
  rank: number;
  pod_product_id: string;
  pod_product_name: string;
  pearson_score: number;
  source: string;
  wh_stock_units: number;
  reason: string;
};

type RowStatus = { kind: "ok" | "err"; msg: string };

const TIER_CARD: Record<MachineCard["health_tier"], string> = {
  critical: "bg-red-50 border-red-300",
  warning: "bg-amber-50 border-amber-300",
  healthy: "bg-green-50 border-green-200",
  excluded: "bg-gray-50 border-gray-200 opacity-60",
};

// ── Component ─────────────────────────────────────────────────────────────────

export function ManualRefillTab() {
  const supabase = createClient();
  const planDate = getDubaiDate(); // today; the 8pm cron owns tomorrow

  const [step, setStep] = useState<"select" | "edit" | "done">("select");
  const [machines, setMachines] = useState<MachineCard[]>([]);
  const [loadingCards, setLoadingCards] = useState(false);
  const [selected, setSelected] = useState<Map<string, string>>(new Map()); // id -> name
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // edit step
  const [editIndex, setEditIndex] = useState(0);
  const [slots, setSlots] = useState<Slot[]>([]);
  const [loadingSlots, setLoadingSlots] = useState(false);
  const [rowStatus, setRowStatus] = useState<Record<string, RowStatus>>({});
  const [qtyInput, setQtyInput] = useState<Record<string, string>>({});
  const [subs, setSubs] = useState<Record<string, Substitute[]>>({});

  const [submitting, setSubmitting] = useState(false);
  const [submitResult, setSubmitResult] = useState<string | null>(null);

  const selectedList = Array.from(selected.entries()); // [id, name][]

  // ── Step 1: load machine cards ──────────────────────────────────────────────
  const loadCards = useCallback(async () => {
    setLoadingCards(true);
    setError(null);
    const { data, error } = await supabase.rpc("get_machine_health").limit(10000);
    if (error) setError(error.message);
    else
      setMachines(
        ((data as MachineCard[]) || []).filter(
          (m) => !m.machine_name?.toUpperCase().startsWith("WH"),
        ),
      );
    setLoadingCards(false);
  }, [supabase]);

  function toggle(m: MachineCard) {
    setSelected((prev) => {
      const next = new Map(prev);
      if (next.has(m.machine_id)) next.delete(m.machine_id);
      else next.set(m.machine_id, m.machine_name);
      return next;
    });
  }

  // ── Step 1 -> 2: create the plan (engine NOT run) ───────────────────────────
  async function createPlan() {
    if (selected.size === 0) return;
    setCreating(true);
    setError(null);
    const { error } = await supabase.rpc("create_refill_plan", {
      p_plan_date: planDate,
      p_machine_ids: Array.from(selected.keys()),
    });
    setCreating(false);
    if (error) {
      setError(error.message);
      return;
    }
    setEditIndex(0);
    setStep("edit");
    void loadSlots(0);
  }

  // ── Step 2: per-machine shelf view ──────────────────────────────────────────
  const loadSlots = useCallback(
    async (index: number) => {
      const entry = selectedList[index];
      if (!entry) return;
      setLoadingSlots(true);
      setRowStatus({});
      setQtyInput({});
      setSubs({});
      const { data, error } = await supabase
        .rpc("get_machine_slots_with_expiry", { p_machine_name: entry[1] })
        .limit(10000);
      if (error) setError(error.message);
      setSlots(((data as Slot[]) || []).filter((s) => s.shelf_id));
      setLoadingSlots(false);
    },
    [supabase, selectedList],
  );

  function currentMachine(): [string, string] | undefined {
    return selectedList[editIndex];
  }

  async function setRefill(s: Slot) {
    const m = currentMachine();
    if (!m || !s.shelf_id || !s.pod_product_id) return;
    const qty = Number(qtyInput[s.slot] ?? s.refill_qty ?? 0);
    const { error } = await supabase.rpc("add_pod_refill_row", {
      p_plan_date: planDate,
      p_machine_id: m[0],
      p_shelf_id: s.shelf_id,
      p_pod_product_id: s.pod_product_id,
      p_action: "REFILL",
      p_qty: qty,
      p_reason: "manual refill",
    });
    setRowStatus((r) => ({
      ...r,
      [s.slot]: error
        ? { kind: "err", msg: error.message }
        : { kind: "ok", msg: `Refill ${qty}` },
    }));
  }

  async function removeShelf(s: Slot) {
    const m = currentMachine();
    if (!m || !s.shelf_id || !s.pod_product_id) return;
    const { error } = await supabase.rpc("add_pod_refill_row", {
      p_plan_date: planDate,
      p_machine_id: m[0],
      p_shelf_id: s.shelf_id,
      p_pod_product_id: s.pod_product_id,
      p_action: "REMOVE",
      p_qty: s.current_stock, // remove what is physically there (warehouse return)
      p_reason: "manual remove to warehouse",
    });
    setRowStatus((r) => ({
      ...r,
      [s.slot]: error
        ? { kind: "err", msg: error.message }
        : { kind: "ok", msg: `Remove ${s.current_stock} -> WH` },
    }));
  }

  async function loadSubs(s: Slot) {
    const m = currentMachine();
    if (!m || !s.shelf_id || !s.pod_product_id) return;
    const { data, error } = await supabase.rpc("find_substitutes_for_shelf", {
      p_plan_date: planDate,
      p_machine_id: m[0],
      p_shelf_id: s.shelf_id,
      p_anchor_pod_product_id: s.pod_product_id,
      p_top_n: 5,
      p_aggressiveness_pct: 50,
    });
    if (error) {
      setRowStatus((r) => ({ ...r, [s.slot]: { kind: "err", msg: error.message } }));
      return;
    }
    setSubs((x) => ({ ...x, [s.slot]: (data as Substitute[]) || [] }));
  }

  async function doSwap(s: Slot, newPodId: string, newName: string) {
    const m = currentMachine();
    if (!m || !s.shelf_id || !s.pod_product_id) return;
    const { error } = await supabase.rpc("swap_pod_refill_row", {
      p_plan_date: planDate,
      p_machine_id: m[0],
      p_shelf_id: s.shelf_id,
      p_old_pod_product_id: s.pod_product_id,
      p_new_pod_product_id: newPodId,
      p_action: "REFILL",
      p_reason: `manual swap to ${newName}`,
    });
    setRowStatus((r) => ({
      ...r,
      [s.slot]: error
        ? { kind: "err", msg: error.message }
        : { kind: "ok", msg: `Swap -> ${newName}` },
    }));
    setSubs((x) => ({ ...x, [s.slot]: [] }));
  }

  function gotoMachine(index: number) {
    setEditIndex(index);
    void loadSlots(index);
  }

  // ── Step 3: submit (manual chain, SKIP finalize) ────────────────────────────
  async function submitAll() {
    setSubmitting(true);
    setError(null);
    setSubmitResult(null);
    const names = selectedList.map(([, name]) => name);
    try {
      const a = await supabase.rpc("approve_pod_refill_plan", {
        p_plan_date: planDate,
        p_machine_names: names,
      });
      if (a.error) throw new Error(`Approve: ${a.error.message}`);

      const st = await supabase.rpc("stitch_pod_to_boonz", {
        p_plan_date: planDate,
        p_dry_run: false,
      });
      if (st.error) throw new Error(`Stitch: ${st.error.message}`);

      const d = await supabase.rpc("approve_refill_plan", {
        p_plan_date: planDate,
        p_machine_names: names,
      });
      if (d.error) throw new Error(`Dispatch: ${d.error.message}`);

      setSubmitResult(
        `Submitted ${names.length} machine(s) for ${planDate}. Drivers will see it on pickup.`,
      );
      setStep("done");
    } catch (e) {
      setError(e instanceof Error ? e.message : "submit failed");
    } finally {
      setSubmitting(false);
    }
  }

  // ── Render ──────────────────────────────────────────────────────────────────

  return (
    <div className="space-y-4">
      {error && (
        <div className="bg-red-50 border border-red-300 text-red-800 rounded-lg p-3 text-sm">
          {error}
        </div>
      )}

      {step === "select" && (
        <div className="space-y-4">
          <div className="flex items-center justify-between">
            <p className="text-sm text-gray-600">
              Pick the machines to refill today ({planDate}). The engine is not run;
              you decide every shelf.
            </p>
            <div className="flex gap-2">
              <button
                onClick={loadCards}
                disabled={loadingCards}
                className="px-4 py-2 rounded-lg border border-gray-300 text-sm font-medium"
              >
                {loadingCards ? "Loading…" : machines.length ? "Reload" : "Load machines"}
              </button>
              <button
                onClick={createPlan}
                disabled={selected.size === 0 || creating}
                className="px-4 py-2 rounded-lg bg-black text-white text-sm font-medium disabled:opacity-40"
              >
                {creating ? "Creating…" : `Refill selected (${selected.size})`}
              </button>
            </div>
          </div>

          <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-3">
            {machines.map((m) => {
              const on = selected.has(m.machine_id);
              return (
                <button
                  key={m.machine_id}
                  onClick={() => toggle(m)}
                  className={`text-left border rounded-lg p-3 transition ${TIER_CARD[m.health_tier]} ${
                    on ? "ring-2 ring-black" : ""
                  }`}
                >
                  <div className="flex items-start justify-between gap-2">
                    <span className="font-semibold text-sm">{m.machine_name}</span>
                    <input type="checkbox" checked={on} readOnly className="mt-1" />
                  </div>
                  <div className="text-xs text-gray-600 mt-1">
                    Fill {Math.round(m.fill_pct)}% · {m.slots_at_zero} empty ·{" "}
                    {m.days_until_empty}d left
                    {m.pending_swap_count > 0 && ` · 📌 ${m.pending_swap_count}`}
                  </div>
                </button>
              );
            })}
          </div>
        </div>
      )}

      {step === "edit" && (
        <div className="space-y-4">
          <div className="flex items-center justify-between flex-wrap gap-2">
            <div className="flex items-center gap-2 text-sm">
              <span className="font-semibold">
                {currentMachine()?.[1]} ({editIndex + 1}/{selectedList.length})
              </span>
            </div>
            <div className="flex gap-2">
              <button
                onClick={() => gotoMachine(Math.max(0, editIndex - 1))}
                disabled={editIndex === 0}
                className="px-3 py-1.5 rounded border border-gray-300 text-sm disabled:opacity-40"
              >
                ← Prev
              </button>
              {editIndex < selectedList.length - 1 ? (
                <button
                  onClick={() => gotoMachine(editIndex + 1)}
                  className="px-3 py-1.5 rounded border border-gray-300 text-sm"
                >
                  Next →
                </button>
              ) : (
                <button
                  onClick={submitAll}
                  disabled={submitting}
                  className="px-4 py-1.5 rounded bg-black text-white text-sm font-medium disabled:opacity-40"
                >
                  {submitting ? "Submitting…" : "Submit & push"}
                </button>
              )}
            </div>
          </div>

          {loadingSlots ? (
            <p className="text-sm text-gray-500">Loading shelves…</p>
          ) : (
            <div className="space-y-2">
              {slots.map((s) => {
                const st = rowStatus[s.slot];
                const slotSubs = subs[s.slot];
                return (
                  <div key={s.slot} className="border border-gray-200 rounded-lg p-3">
                    <div className="flex items-center justify-between gap-3 flex-wrap">
                      <div className="min-w-[200px]">
                        <span className="font-medium text-sm">{s.slot}</span>{" "}
                        <span className="text-sm text-gray-700">{s.product}</span>
                        <div className="text-xs text-gray-500">
                          {s.current_stock}/{s.max_stock} ({Math.round(s.fill_pct)}%)
                          {s.expiry_days != null && ` · exp ${s.expiry_days}d`}
                          {s.suggested_product && ` · 🤖 ${s.suggested_product}`}
                        </div>
                      </div>
                      <div className="flex items-center gap-2">
                        <input
                          type="number"
                          min={0}
                          placeholder={String(s.refill_qty ?? 0)}
                          value={qtyInput[s.slot] ?? ""}
                          onChange={(e) =>
                            setQtyInput((q) => ({ ...q, [s.slot]: e.target.value }))
                          }
                          className="w-16 border border-gray-300 rounded px-2 py-1 text-sm"
                        />
                        <button
                          onClick={() => setRefill(s)}
                          className="px-2.5 py-1 rounded bg-blue-600 text-white text-xs"
                        >
                          Refill
                        </button>
                        <button
                          onClick={() => loadSubs(s)}
                          className="px-2.5 py-1 rounded border border-gray-300 text-xs"
                        >
                          Swap
                        </button>
                        <button
                          onClick={() => removeShelf(s)}
                          className="px-2.5 py-1 rounded border border-red-300 text-red-700 text-xs"
                        >
                          Remove
                        </button>
                      </div>
                    </div>

                    {slotSubs && slotSubs.length > 0 && (
                      <div className="mt-2 border-t border-gray-100 pt-2 flex flex-wrap gap-2">
                        {slotSubs.map((sub) => (
                          <button
                            key={sub.pod_product_id}
                            onClick={() => doSwap(s, sub.pod_product_id, sub.pod_product_name)}
                            className="px-2 py-1 rounded bg-gray-100 text-xs"
                            title={`${sub.reason} · WH ${sub.wh_stock_units}`}
                          >
                            {sub.pod_product_name} ({sub.pearson_score.toFixed(2)})
                          </button>
                        ))}
                      </div>
                    )}

                    {st && (
                      <div
                        className={`mt-1 text-xs ${
                          st.kind === "ok" ? "text-green-700" : "text-red-700"
                        }`}
                      >
                        {st.msg}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}

      {step === "done" && (
        <div className="bg-green-50 border border-green-300 text-green-800 rounded-lg p-4 text-sm">
          {submitResult}
          <div className="mt-3">
            <button
              onClick={() => {
                setStep("select");
                setSelected(new Map());
                setSlots([]);
                setSubmitResult(null);
              }}
              className="px-4 py-2 rounded-lg border border-gray-300 text-sm font-medium"
            >
              Start another
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
