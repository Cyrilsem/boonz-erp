"use client";

import { useState, useCallback, useEffect } from "react";
import { createBrowserClient } from "@supabase/ssr";
import { machineShortId } from "@/lib/utils/machine-id";

// ── Types ──────────────────────────────────────────────────────────────────────

// Canonical action vocabulary — matches pod_refill_plan.action and the
// add_pod_refill_row CHECK constraint exactly. Display labels are mapped
// separately in actionBadge / ACTION_LABELS.
export type RefillAction = "REFILL" | "ADD_NEW" | "REMOVE" | "M2W";

const ACTION_LABELS: Record<RefillAction, string> = {
  REFILL: "REFILL",
  ADD_NEW: "ADD NEW",
  REMOVE: "REMOVE",
  M2W: "MOVE TO WH",
};

export type PlanRow = {
  machine_name: string;
  machine_priority: number;
  shelf_code: string;
  pod_product_name: string;
  boonz_product_name: string;
  action: RefillAction;
  quantity: number;
  current_stock: number;
  max_stock: number;
  smart_target: number;
  tier: string;
  global_score: number;
  sold_7d: number;
  fill_pct: number;
  comment: string;
  // Pod-level draft fields (populated when loading from pod_refill_plan)
  machine_id?: string;
  shelf_id?: string;
  pod_product_id?: string;
  velocity_30d?: number;
  signal?: string;
  clamp_reason?: string;
  source_origin?: string;
  has_intent?: boolean;
  status?: string;
};

type PlanAlert = {
  type: string;
  machine?: string;
  shelf?: string;
  product?: string;
  msg?: string;
  reason?: string;
};

// F4 (Refill v2): action-first add-row form. machine_name + shelf_id +
// pod_product_id all resolve to real identifiers, so the row is persisted via
// add_pod_refill_row (no more identifier-less local-only rows that the commit
// had to silently skip). current_stock/max_stock are autofill context only and
// are NOT sent to the RPC (add_pod_refill_row does not take them).
type AddRowForm = {
  action: RefillAction;
  machine_name: string;
  shelf_id: string;
  pod_product_id: string;
  quantity: number;
  comment: string;
};

type ViewMode = "empty" | "draft" | "pending";

// PRD-031 WS-4: refill execution accuracy (canonical view v_refill_accuracy via get_refill_plan_accuracy)
export type AccuracyLine = {
  machine_name: string;
  shelf_code: string;
  pod_product_name: string;
  action: string;
  pod_intent: number;
  dispatched_qty: number;
  shelf_gap: number;
  wh_short: boolean;
  shortfall: number;
  status: "ok" | "wh_short" | "leak" | "over";
};
type AccuracySummary = {
  lines: AccuracyLine[];
  summary: {
    shelf_pods: number;
    ok: number;
    wh_short: number;
    leak: number;
    over: number;
    total_intent: number;
    total_dispatched: number;
    total_gap: number;
    intent_fill_ratio: number;
    gap_fill_ratio: number;
    verdict: "pass" | "flag" | "block";
  };
};

// ── Helpers ────────────────────────────────────────────────────────────────────

function actionBadge(action: string) {
  const styles: Record<string, string> = {
    REFILL: "bg-blue-100 text-blue-700 ",
    REMOVE: "bg-red-100 text-red-700 ",
    ADD_NEW: "bg-green-100 text-green-700 ",
    M2W: "bg-purple-100 text-purple-700 ",
  };
  const label = ACTION_LABELS[action as RefillAction] ?? action;
  return (
    <span
      className={`inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-semibold ${
        styles[action] ?? "bg-gray-100 text-gray-600"
      }`}
    >
      {label}
    </span>
  );
}

function signalBadge(signal: string | undefined) {
  if (!signal) return null;
  const styles: Record<string, string> = {
    STAR: "bg-yellow-100 text-yellow-800",
    DOUBLE_DOWN: "bg-green-100 text-green-800",
    KEEP: "bg-blue-100 text-blue-700",
    KEEP_GROWING: "bg-cyan-100 text-cyan-700",
    RAMPING: "bg-purple-100 text-purple-700",
    WIND_DOWN: "bg-orange-100 text-orange-700",
    DEAD: "bg-red-100 text-red-700",
    ROTATE_OUT: "bg-amber-100 text-amber-700",
  };
  return (
    <span
      className={`inline-flex items-center rounded-full px-1.5 py-0.5 text-[9px] font-medium ${
        styles[signal] ?? "bg-gray-100 text-gray-600"
      }`}
    >
      {signal.replace(/_/g, " ")}
    </span>
  );
}

function tierDot(tier: string) {
  const colors: Record<string, string> = {
    double_down: "bg-green-500",
    keep: "bg-blue-500",
    monitor: "bg-amber-500",
    discontinue: "bg-red-500",
  };
  return (
    <span
      className={`inline-block w-2 h-2 rounded-full mr-1.5 flex-shrink-0 ${
        colors[tier] ?? "bg-gray-400"
      }`}
    />
  );
}

function priorityBadge(p: number) {
  if (p === 1)
    return <span className="text-[9px] font-bold text-red-600 ">P1</span>;
  if (p === 2)
    return <span className="text-[9px] font-bold text-amber-600 ">P2</span>;
  return null;
}

const BLANK_FORM: AddRowForm = {
  action: "REFILL",
  machine_name: "",
  shelf_id: "",
  pod_product_id: "",
  quantity: 1,
  comment: "",
};

// ── Component ──────────────────────────────────────────────────────────────────

export function RefillPlanningTab({
  selectedDate,
  machineNames,
  planRows,
  setPlanRows,
  editedQty,
  setEditedQty,
  removed,
  setRemoved,
  generated,
  setGenerated,
}: {
  selectedDate: string;
  machineNames: string[];
  planRows: PlanRow[];
  setPlanRows: React.Dispatch<React.SetStateAction<PlanRow[]>>;
  editedQty: Record<number, number>;
  setEditedQty: React.Dispatch<React.SetStateAction<Record<number, number>>>;
  removed: Set<number>;
  setRemoved: React.Dispatch<React.SetStateAction<Set<number>>>;
  generated: boolean;
  setGenerated: React.Dispatch<React.SetStateAction<boolean>>;
}) {
  const [loading, setLoading] = useState(false);
  const [alerts, setAlerts] = useState<PlanAlert[]>([]);
  const [writeResult, setWriteResult] = useState<{
    ok: boolean;
    msg: string;
  } | null>(null);
  const [loadResult, setLoadResult] = useState<{
    ok: boolean;
    msg: string;
  } | null>(null);
  const [approving, setApproving] = useState(false);
  const [approveResult, setApproveResult] = useState<{
    ok: boolean;
    msg: string;
  } | null>(null);

  // Draft commit state
  const [committing, setCommitting] = useState(false);
  const [commitResult, setCommitResult] = useState<{
    ok: boolean;
    msg: string;
  } | null>(null);

  // PRD-033 / Track C C2: pre-commit REMOVE-without-replace gate. Populated by
  // check_remove_without_replace at commit time; when status='block' the commit
  // is refused unless the operator ticks Override. No client re-derivation: the
  // flagged set and pickable_units come straight from the RPC.
  const [removeGate, setRemoveGate] = useState<{
    status: string;
    flagged: Array<{
      machine: string;
      shelf: string;
      add_pod_product: string;
      add_qty: number;
      pickable_units: number;
    }>;
  } | null>(null);
  const [removeGateOverride, setRemoveGateOverride] = useState(false);

  // PRD-033 / Track C C2: re-stitch (reopen) controls for the pending view.
  // Machine-level: reopen_stitched_rows takes machine_ids[] and (optionally)
  // shelf_ids[]; passing shelf_ids=null reopens every stitched shelf for the
  // selected machines. Then stitch_pod_to_boonz(date,false) re-resolves them.
  const [reopenSel, setReopenSel] = useState<Set<string>>(new Set());
  const [reopenReason, setReopenReason] = useState("");
  const [reopenBusy, setReopenBusy] = useState(false);
  const [reopenResult, setReopenResult] = useState<{
    ok: boolean;
    msg: string;
  } | null>(null);

  // PRD-011 Bug 1: the plan_date the loaded draft was generated for. Distinct
  // from `selectedDate` (the date-picker value), which can drift from the
  // draft, e.g. cron generates a 2026-05-25 draft at 8pm 2026-05-24 and CS
  // opens the page on the 25th with a picker default of 2026-05-26.
  const [draftPlanDate, setDraftPlanDate] = useState<string | null>(null);

  // PRD-011 Bug 3: per-row restore state for superseded rows.
  const [restoringIdx, setRestoringIdx] = useState<number | null>(null);
  const [restoreToast, setRestoreToast] = useState<{
    ok: boolean;
    msg: string;
  } | null>(null);

  // View mode: empty | draft (pod_refill_plan) | pending (refill_plan_output)
  const [viewMode, setViewMode] = useState<ViewMode>("empty");

  // PRD-031 WS-4: refill accuracy gate (intent vs dispatched vs gap per shelf-pod)
  const [accuracy, setAccuracy] = useState<AccuracySummary | null>(null);

  // PRD-019 C2: compact all-rows planning view (v_refill_planning_compact).
  type CompactRow = {
    machine_name: string;
    slot: string;
    product: string | null;
    current_stock: number | null;
    max_stock: number | null;
    fill_pct: number | null;
    stance: string | null;
    global_badge: string | null;
    local_badge: string | null;
    sales_7d: number | null;
    final_score: number | null;
    planned_action: string | null;
    planned_qty: number | null;
    wh_availability: number | null;
    wh_unsourceable: boolean | null;
    edit_comment: string | null;
    add_comment: string | null;
    clamp_reason: string | null;
    is_configured: boolean | null;
  };
  const [compactRows, setCompactRows] = useState<CompactRow[]>([]);
  const [compactOpen, setCompactOpen] = useState(false);
  const [compactLoading, setCompactLoading] = useState(false);
  // PRD-019c: Machine is the default sort (machine_name ASC, then slot ASC).
  const [compactSort, setCompactSort] = useState<
    "machine" | "fill" | "slot" | "stock" | "score"
  >("machine");
  // PRD-019c: client-side filters over the already-fetched compact rows.
  const [fltStance, setFltStance] = useState<Set<string>>(new Set());
  const [fltWhUnsourceable, setFltWhUnsourceable] = useState(false);
  const [fltNeedsRefill, setFltNeedsRefill] = useState(false);
  const [fltMachines, setFltMachines] = useState<Set<string>>(new Set());
  // Hide unconfigured + empty shelves (e.g. AMZ second cabinet) by default.
  const [hideUnconfigured, setHideUnconfigured] = useState(true);

  // Add row modal
  const [showAdd, setShowAdd] = useState(false);
  const [addForm, setAddForm] = useState<AddRowForm>(BLANK_FORM);
  const [addBusy, setAddBusy] = useState(false);
  const [addError, setAddError] = useState<string | null>(null);
  // F4: catalogs for the forced product dropdown + per-machine shelf resolver,
  // hydrated when a draft loads. pod_products is the canonical product list;
  // shelvesByMachine maps machine_name -> its non-phantom shelves.
  const [podProducts, setPodProducts] = useState<
    Array<{ id: string; name: string }>
  >([]);
  const [shelvesByMachine, setShelvesByMachine] = useState<
    Record<string, Array<{ shelf_id: string; shelf_code: string }>>
  >({});

  // PRD-033 / Track C C2: convert_shelf modal (draft mode). Swaps a slot's
  // product in one action (REMOVE/M2W the old + ADD_NEW the new). Headroom is
  // read live from v_shelf_capacity (no client-side capacity math); the RPC
  // clamps qty to it server-side. return_mode is one of wh/m2m/truck_transfer/
  // unknown (the RPC validates).
  const [convertRow, setConvertRow] = useState<{
    machine_id: string;
    shelf_id: string;
    shelf_code: string;
    machine_name: string;
    old_pod_product_id: string;
    old_pod_product_name: string;
  } | null>(null);
  const [convertNewProd, setConvertNewProd] = useState("");
  const [convertQty, setConvertQty] = useState("");
  const [convertMode, setConvertMode] = useState("wh");
  const [convertReason, setConvertReason] = useState("");
  const [convertHeadroom, setConvertHeadroom] = useState<number | null>(null);
  const [convertBusy, setConvertBusy] = useState(false);
  const [convertResult, setConvertResult] = useState<{
    ok: boolean;
    msg: string;
  } | null>(null);

  // machine_name → adyen_store_code lookup
  const [machineCodeByName, setMachineCodeByName] = useState<
    Record<string, string | null>
  >({});

  // PRD-015 AC#13: per-machine include/exclude toggle (machine_name -> included).
  // Default included; synced to machines_to_visit.is_included via canonical RPCs.
  const [inclusion, setInclusion] = useState<Record<string, boolean>>({});
  const [inclusionBusy, setInclusionBusy] = useState(false);

  const supabase = createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  );

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data } = await supabase
        .from("machines")
        .select("official_name, adyen_store_code");
      if (cancelled || !data) return;
      const map: Record<string, string | null> = {};
      for (const m of data as Array<{
        official_name: string;
        adyen_store_code: string | null;
      }>) {
        map[m.official_name] = m.adyen_store_code;
      }
      setMachineCodeByName(map);
    })();
    return () => {
      cancelled = true;
    };
  }, [supabase]);

  // ── Auto-load draft on mount ──────────────────────────────────────────────
  // Fires once when the tab opens. If the 8pm cron has already generated a
  // draft for selectedDate, it appears immediately — no "Load draft" click needed.
  const [autoLoaded, setAutoLoaded] = useState(false);

  // ── Load draft (pod_refill_plan via RPC) ──────────────────────────────────
  const loadDraft = useCallback(async () => {
    setLoading(true);
    setLoadResult(null);
    setCommitResult(null);
    setApproveResult(null);
    setRemoved(new Set());
    setEditedQty({});
    setDraftPlanDate(null);

    const { data, error } = await supabase.rpc("get_pod_refill_draft", {
      p_plan_date: selectedDate,
    });

    setLoading(false);
    if (error) {
      setLoadResult({ ok: false, msg: `Load failed: ${error.message}` });
      return;
    }
    if (!data || (data as unknown[]).length === 0) {
      setLoadResult({
        ok: false,
        msg: `No draft found for ${selectedDate}. The 8pm cron may not have run yet.`,
      });
      return;
    }

    // PRD-011 Bug 1: capture the draft's actual plan_date so commitDraft
    // can pass it through the RPC chain (instead of selectedDate, which
    // may not match if CS opened the page on a different day).
    const firstRow = (data as Record<string, unknown>[])[0];
    const planDateFromDraft = (firstRow.plan_date as string) ?? selectedDate;
    setDraftPlanDate(planDateFromDraft);

    const rows: PlanRow[] = (data as Record<string, unknown>[]).map((r) => ({
      machine_name: r.machine_name as string,
      machine_priority: 5,
      shelf_code: r.shelf_code as string,
      pod_product_name: r.pod_product_name as string,
      boonz_product_name: "", // not yet stitched
      action: r.action as PlanRow["action"],
      quantity: (r.qty as number) ?? 0,
      current_stock: (r.current_stock as number) ?? 0,
      max_stock: (r.max_stock as number) ?? 0,
      smart_target: 0,
      tier: "",
      global_score: 0,
      sold_7d: 0,
      fill_pct: (r.fill_pct as number) ?? 0,
      comment: "",
      // Draft-specific
      machine_id: r.machine_id as string,
      shelf_id: r.shelf_id as string,
      pod_product_id: r.pod_product_id as string,
      velocity_30d: r.velocity_30d as number | undefined,
      signal: r.signal as string | undefined,
      clamp_reason: r.clamp_reason as string | undefined,
      source_origin: r.source_origin as string | undefined,
      has_intent: r.has_intent as boolean | undefined,
      status: r.status as string | undefined,
    }));

    setPlanRows(rows);
    setGenerated(true);
    setViewMode("draft");
    setAccuracy(null); // accuracy applies to the dispatched (pending) plan only

    // PRD-015 AC#13: hydrate include/exclude state from machines_to_visit.
    // Graceful: if is_included is not yet deployed, default every machine to included.
    const incl: Record<string, boolean> = {};
    const nameById: Record<string, string> = {};
    for (const r of rows)
      if (r.machine_id) nameById[r.machine_id] = r.machine_name;
    const { data: mtv, error: mtvErr } = await supabase
      .from("machines_to_visit")
      .select("machine_id, is_included")
      .eq("plan_date", planDateFromDraft);
    if (!mtvErr && mtv) {
      for (const m of mtv as Array<{
        machine_id: string;
        is_included: boolean;
      }>) {
        const nm = nameById[m.machine_id];
        if (nm) incl[nm] = m.is_included !== false;
      }
    }
    for (const r of rows)
      if (!(r.machine_name in incl)) incl[r.machine_name] = true;
    setInclusion(incl);

    // F4: hydrate the add-row catalogs — the canonical product list (forced
    // dropdown) and each draft machine's non-phantom shelves (shelf dropdown +
    // shelf_id resolution). Both .limit(10000) per the query-size rule.
    const machineIds = [
      ...new Set(rows.map((r) => r.machine_id).filter(Boolean)),
    ] as string[];
    const { data: prods } = await supabase
      .from("pod_products")
      .select("pod_product_id, pod_product_name")
      .order("pod_product_name")
      .limit(10000);
    setPodProducts(
      (
        (prods as Array<{
          pod_product_id: string;
          pod_product_name: string;
        }>) ?? []
      ).map((p) => ({ id: p.pod_product_id, name: p.pod_product_name })),
    );
    const byMachineShelves: Record<
      string,
      Array<{ shelf_id: string; shelf_code: string }>
    > = {};
    if (machineIds.length) {
      const nameByMachineId: Record<string, string> = {};
      for (const r of rows)
        if (r.machine_id) nameByMachineId[r.machine_id] = r.machine_name;
      const { data: shelves } = await supabase
        .from("shelf_configurations")
        .select("machine_id, shelf_id, shelf_code")
        .in("machine_id", machineIds)
        .eq("is_phantom", false)
        .limit(10000);
      for (const s of (shelves as Array<{
        machine_id: string;
        shelf_id: string;
        shelf_code: string;
      }>) ?? []) {
        const nm = nameByMachineId[s.machine_id];
        if (!nm) continue;
        (byMachineShelves[nm] ??= []).push({
          shelf_id: s.shelf_id,
          shelf_code: s.shelf_code,
        });
      }
      for (const nm of Object.keys(byMachineShelves))
        byMachineShelves[nm].sort((a, b) =>
          a.shelf_code.localeCompare(b.shelf_code),
        );
    }
    setShelvesByMachine(byMachineShelves);

    setLoadResult({
      ok: true,
      msg: `Draft loaded — ${rows.length} rows across ${new Set(rows.map((r) => r.machine_name)).size} machines`,
    });
  }, [
    selectedDate,
    supabase,
    setPlanRows,
    setGenerated,
    setRemoved,
    setEditedQty,
  ]);

  // Auto-load on mount (or when selectedDate changes)
  useEffect(() => {
    if (!autoLoaded && !generated) {
      setAutoLoaded(true);
      loadDraft();
    }
  }, [autoLoaded, generated, loadDraft]);

  // ── Load pending plan (refill_plan_output — post-stitch) ─────────────────
  const loadPendingPlan = useCallback(async () => {
    setLoading(true);
    setLoadResult(null);
    setCommitResult(null);
    setApproveResult(null);
    setRemoved(new Set());
    setEditedQty({});

    // WS7: enriched reader joins live shelf stock + 7d sales (refill_plan_output stores 0/0 placeholders).
    const { data, error } = await supabase.rpc(
      "get_refill_plan_output_enriched",
      { p_plan_date: selectedDate },
    );

    setLoading(false);
    if (error) {
      setLoadResult({ ok: false, msg: `Load failed: ${error.message}` });
      return;
    }
    if (!data || data.length === 0) {
      setLoadResult({
        ok: false,
        msg: `No pending plan found for ${selectedDate}`,
      });
      return;
    }

    const rows: PlanRow[] = data.map((r: Record<string, unknown>) => ({
      machine_name: r.machine_name as string,
      machine_priority: (r.machine_priority as number) ?? 5,
      shelf_code: r.shelf_code as string,
      pod_product_name: r.pod_product_name as string,
      boonz_product_name: r.boonz_product_name as string,
      action: r.action as PlanRow["action"],
      quantity: (r.quantity as number) ?? 0,
      current_stock: (r.current_stock as number) ?? 0,
      max_stock: (r.max_stock as number) ?? 0,
      smart_target: (r.smart_target as number) ?? 0,
      tier: (r.tier as string) ?? "keep",
      global_score: (r.global_score as number) ?? 0,
      sold_7d: (r.sold_7d as number) ?? 0,
      fill_pct: (r.fill_pct as number) ?? 0,
      comment: (r.comment as string) ?? "",
    }));

    setPlanRows(rows);
    setGenerated(true);
    setViewMode("pending");
    setLoadResult({
      ok: true,
      msg: `Loaded ${rows.length} pending lines for ${selectedDate}`,
    });

    // PRD-031 WS-4: load the accuracy gate (intent vs dispatched vs gap) for this plan
    const { data: accData, error: accErr } = await supabase.rpc(
      "get_refill_plan_accuracy",
      { p_plan_date: selectedDate },
    );
    if (!accErr && accData) {
      setAccuracy(accData as AccuracySummary);
    } else {
      setAccuracy(null);
    }
  }, [
    selectedDate,
    supabase,
    setPlanRows,
    setGenerated,
    setRemoved,
    setEditedQty,
  ]);

  // ── PRD-033 / Track C C2: reopen stitched rows then re-stitch ────────────
  const reopenSelected = useCallback(async () => {
    if (reopenSel.size === 0 || reopenReason.trim().length < 10) return;
    setReopenBusy(true);
    setReopenResult(null);
    try {
      const names = [...reopenSel];
      // Resolve machine_name -> machine_id (the enriched pending reader returns
      // names only). reopen_stitched_rows is keyed by machine_id.
      const { data: machineRows, error: mErr } = await supabase
        .from("machines")
        .select("machine_id, official_name")
        .in("official_name", names)
        .limit(10000);
      if (mErr) throw new Error(`Machine lookup failed: ${mErr.message}`);
      const ids = (machineRows ?? []).map(
        (m) => (m as { machine_id: string }).machine_id,
      );
      if (ids.length === 0) throw new Error("No matching machines resolved.");

      // shelf_ids=null -> reopen every stitched shelf for these machines.
      const { data: reopenData, error: reErr } = await supabase.rpc(
        "reopen_stitched_rows",
        {
          p_plan_date: selectedDate,
          p_machine_ids: ids,
          p_shelf_ids: null,
          p_reason: reopenReason.trim(),
        },
      );
      if (reErr) throw new Error(reErr.message);
      const res = reopenData as {
        status?: string;
        reopened?: number;
        message?: string;
      } | null;
      if (res?.status === "blocked") {
        // Surface the guard reason verbatim (dispatched/reviewed output).
        throw new Error(
          res.message ??
            "Some selected rows have dispatched/reviewed output and cannot be reopened.",
        );
      }

      // Re-resolve the reopened rows against current warehouse stock.
      const { error: stErr } = await supabase.rpc("stitch_pod_to_boonz", {
        p_plan_date: selectedDate,
        p_dry_run: false,
      });
      if (stErr) {
        throw new Error(
          `Reopened ${res?.reopened ?? 0} row(s) but the re-stitch failed: ${stErr.message}`,
        );
      }

      setReopenResult({
        ok: true,
        msg: `Reopened ${res?.reopened ?? 0} row(s) across ${ids.length} machine(s) and re-stitched. Reloading the plan…`,
      });
      setReopenSel(new Set());
      setReopenReason("");
      await loadPendingPlan();
    } catch (err) {
      setReopenResult({
        ok: false,
        msg: err instanceof Error ? err.message : "Reopen failed",
      });
    } finally {
      setReopenBusy(false);
    }
  }, [reopenSel, reopenReason, selectedDate, supabase, loadPendingPlan]);

  // ── PRD-033 / Track C C2: open the convert_shelf modal for a draft row ────
  const openConvert = useCallback(
    async (row: PlanRow) => {
      if (!row.machine_id || !row.shelf_id || !row.pod_product_id) return;
      setConvertRow({
        machine_id: row.machine_id,
        shelf_id: row.shelf_id,
        shelf_code: row.shelf_code,
        machine_name: row.machine_name,
        old_pod_product_id: row.pod_product_id,
        old_pod_product_name: row.pod_product_name,
      });
      setConvertNewProd("");
      setConvertQty("");
      setConvertMode("wh");
      setConvertReason("");
      setConvertResult(null);
      setConvertHeadroom(null);
      // Live headroom from the canonical capacity view (no client-side math).
      const { data, error } = await supabase
        .from("v_shelf_capacity")
        .select("headroom")
        .eq("shelf_id", row.shelf_id)
        .maybeSingle();
      if (!error && data) {
        setConvertHeadroom((data as { headroom: number | null }).headroom);
      }
    },
    [supabase],
  );

  const submitConvert = useCallback(async () => {
    if (!convertRow || !convertNewProd) return;
    const qty = Number(convertQty);
    if (!Number.isFinite(qty) || qty < 0) {
      setConvertResult({ ok: false, msg: "Enter a valid quantity (>= 0)." });
      return;
    }
    setConvertBusy(true);
    setConvertResult(null);
    try {
      const planDate = draftPlanDate ?? selectedDate;
      const { data, error } = await supabase.rpc("convert_shelf", {
        p_plan_date: planDate,
        p_machine_id: convertRow.machine_id,
        p_shelf_id: convertRow.shelf_id,
        p_old_pod_product_id: convertRow.old_pod_product_id,
        p_new_pod_product_id: convertNewProd,
        p_new_qty: Math.trunc(qty),
        p_return_mode: convertMode,
        p_reason: convertReason.trim() || null,
      });
      if (error) throw new Error(error.message);
      const res = data as {
        added?: { qty?: number; requested_qty?: number; clamp_reason?: string };
      } | null;
      const added = res?.added;
      const clampNote =
        added?.clamp_reason === "capacity_capped"
          ? ` (clamped to ${added?.qty} by shelf capacity; you asked for ${added?.requested_qty})`
          : "";
      setConvertResult({
        ok: true,
        msg: `Converted. Old product set to remove, new product added at ${added?.qty ?? Math.trunc(qty)}${clampNote}. Re-stitch on commit. Reloading draft…`,
      });
      setConvertRow(null);
      await loadDraft();
    } catch (err) {
      setConvertResult({
        ok: false,
        msg: err instanceof Error ? err.message : "Convert failed",
      });
    } finally {
      setConvertBusy(false);
    }
  }, [
    convertRow,
    convertNewProd,
    convertQty,
    convertMode,
    convertReason,
    draftPlanDate,
    selectedDate,
    supabase,
    loadDraft,
  ]);

  // ── Commit draft (finalize → stitch → auto-dispatch) ─────────────────────
  const commitDraft = useCallback(async () => {
    setCommitting(true);
    setCommitResult(null);

    try {
      // PRD-011 Bug 1: every RPC in the chain must use the draft's actual
      // plan_date, not the date-picker selectedDate.
      if (!draftPlanDate) {
        throw new Error("No draft loaded — load a draft before committing");
      }
      const planDate = draftPlanDate;

      // PRD-019 D1/D2: take the single-writer lock for this plan_date so a
      // chat-engine rebuild cannot collide with this Commit mid-chain. Released
      // in the finally below. The engines refuse to run under another context.
      const { error: lockErr } = await supabase.rpc(
        "acquire_refill_plan_lock",
        {
          p_plan_date: planDate,
          p_context: "commit",
        },
      );
      if (lockErr) {
        throw new Error(
          `Cannot commit: ${lockErr.message}. Another writer (chat or a parallel commit) holds this plan_date.`,
        );
      }

      // Honor the per-machine include/exclude toggle in the commit itself.
      // Previously the checkbox was cosmetic: the persist loops below walked
      // every machine's staged edits/removals regardless of inclusion, so an
      // excluded machine's broken row could still abort the whole Commit
      // (2026-05-31 WPP-1002 / A01 incident).
      const isRowIncluded = (machineName: string) =>
        inclusion[machineName] !== false;
      const includedMachineNames = [
        ...new Set(planRows.map((r) => r.machine_name)),
      ].filter(isRowIncluded);

      // PRD-011 Bug 2 Step 0a: persist inline quantity edits BEFORE Gate 1
      // approves the draft. Without this, the stitch silently uses the
      // engine-generated quantities and CS's edits are lost.
      for (const [rowIndexStr, newQty] of Object.entries(editedQty)) {
        const rowIndex = Number(rowIndexStr);
        const row = planRows[rowIndex];
        if (!row) continue;
        // Skip excluded machines — their rows are not part of this commit.
        if (!isRowIncluded(row.machine_name)) continue;
        // An unsaved manual row (no resolved identifiers) was never persisted,
        // so there is nothing to edit in the DB. Skip rather than abort the
        // whole commit. (Manual adds should go through add_pod_refill_row.)
        if (!row.machine_id || !row.shelf_id || !row.pod_product_id) {
          continue;
        }
        const { error: editErr } = await supabase.rpc("edit_pod_refill_row", {
          p_plan_date: planDate,
          p_machine_id: row.machine_id,
          p_shelf_id: row.shelf_id,
          p_pod_product_id: row.pod_product_id,
          p_action: row.action,
          p_new_qty: newQty,
          p_reason: "FE inline edit",
          p_conductor_session: null,
        });
        if (editErr) {
          throw new Error(
            `Edit persist failed at ${row.machine_name}/${row.shelf_code} (${row.pod_product_name}): ${editErr.message}`,
          );
        }
      }

      // PRD-011 Bug 2 Step 0b: persist client-side row removals as qty=0
      // edits so finalize + stitch see them.
      for (const rowIndex of removed) {
        const row = planRows[rowIndex];
        if (!row) continue;
        // Skip excluded machines.
        if (!isRowIncluded(row.machine_name)) continue;
        // An unsaved manual row with no resolved identifiers was never written
        // to pod_refill_plan, so there is nothing to remove. Drop it from local
        // state silently instead of aborting the commit with "missing pod
        // identifiers" (2026-05-31 WPP-1002 / A01 "Plaay Truffle 2pcs" orphan).
        if (!row.machine_id || !row.shelf_id || !row.pod_product_id) {
          continue;
        }
        const { error: removeErr } = await supabase.rpc("edit_pod_refill_row", {
          p_plan_date: planDate,
          p_machine_id: row.machine_id,
          p_shelf_id: row.shelf_id,
          p_pod_product_id: row.pod_product_id,
          p_action: row.action,
          p_new_qty: 0,
          p_reason: "FE row removal",
          p_conductor_session: null,
        });
        if (removeErr) {
          throw new Error(
            `Row removal persist failed at ${row.machine_name}/${row.shelf_code} (${row.pod_product_name}): ${removeErr.message}`,
          );
        }
      }

      // Edits are now durable in pod_refill_plan; clear FE staging state
      // so a second click does not try to re-apply.
      setEditedQty({});
      setRemoved(new Set());

      // PRD-033 / Track C C2: REMOVE-without-replace gate. Evaluate the FINAL
      // post-edit plan (edits/removals above are now durable). If any shelf is a
      // REMOVE paired with an ADD_NEW that resolves to 0 pickable WH units, the
      // RPC returns status='block'. Refuse the commit unless the operator has
      // explicitly ticked Override. The RPC is the sole source of truth — no
      // client-side re-derivation of pickable stock.
      const { data: gateData, error: gateErr } = await supabase.rpc(
        "check_remove_without_replace",
        { p_plan_date: planDate },
      );
      if (gateErr) {
        throw new Error(`Pre-commit safety check failed: ${gateErr.message}`);
      }
      const gate = gateData as {
        status?: string;
        flagged?: Array<{
          machine: string;
          shelf: string;
          add_pod_product: string;
          add_qty: number;
          pickable_units: number;
        }>;
      } | null;
      const gateFlagged = gate?.flagged ?? [];
      setRemoveGate(
        gate?.status
          ? { status: gate.status, flagged: gateFlagged }
          : null,
      );
      if (gate?.status === "block" && !removeGateOverride) {
        throw new Error(
          `REMOVE-without-replace gate blocked the commit: ${gateFlagged.length} shelf(s) would strip a slot whose paired new product has 0 pickable warehouse units. Review the flagged shelves below; fix the plan, or tick "Override" and re-commit to proceed anyway.`,
        );
      }

      // PRD-019 E4: ONE atomic call replaces the multi-step saga (approve_pod ->
      // scoped finalize -> stitch -> approve_refill + the post-write invariants).
      // It runs in a single DB transaction that rolls back entirely on any
      // failure, so the pipeline can never land "stitched but dispatch empty".
      // The RPC resolves names -> ids and verifies counts server-side.
      const { data: commitData, error: commitErr } = await supabase.rpc(
        "commit_refill_plan_atomic",
        { p_plan_date: planDate, p_machine_names: includedMachineNames },
      );
      if (commitErr) throw new Error(`Commit failed: ${commitErr.message}`);
      const c = commitData as {
        status?: string;
        output_rows?: number;
        dispatch_rows?: number;
        machines?: number;
        soft_flags?: { machine: string; note: string }[];
        error?: string;
      } | null;
      if (!c || c.status !== "ok") {
        throw new Error(`Commit failed: ${c?.error ?? "unknown error"}`);
      }

      // PRD-019 E2 soft flag: machines that committed but produced no actionable
      // dispatch lines (everything blocked/dropped). Reported, never a rollback.
      const softFlags = c.soft_flags ?? [];
      const softLine =
        softFlags.length > 0
          ? ` Note: ${softFlags.length} machine(s) committed with no actionable lines (${softFlags
              .map((s) => s.machine)
              .join(", ")}).`
          : "";

      setCommitting(false);
      setCommitResult({
        ok: true,
        msg: `Plan committed for ${planDate} — VERIFIED ${c.output_rows ?? 0} approved boonz rows and ${c.dispatch_rows ?? 0} dispatch lines across ${c.machines ?? 0} machine(s). Drivers will see it.${softLine}`,
      });

      // Clear state — plan is now live
      setPlanRows([]);
      setGenerated(false);
      setViewMode("empty");
      setDraftPlanDate(null);
    } catch (err) {
      setCommitting(false);
      setCommitResult({
        ok: false,
        msg: err instanceof Error ? err.message : "Unknown error during commit",
      });
    } finally {
      // PRD-019 D1: always release the single-writer lock, even on failure.
      if (draftPlanDate) {
        await supabase.rpc("release_refill_plan_lock", {
          p_plan_date: draftPlanDate,
        });
      }
    }
  }, [
    draftPlanDate,
    supabase,
    planRows,
    removed,
    editedQty,
    inclusion,
    setPlanRows,
    setGenerated,
    setEditedQty,
    setRemoved,
    removeGateOverride,
  ]);

  // ── PRD-019 C2: load the compact all-rows planning view ─────────────────
  const loadCompact = useCallback(async () => {
    setCompactLoading(true);
    try {
      const machineNames = [...new Set(planRows.map((r) => r.machine_name))];
      let q = supabase
        .from("v_refill_planning_compact")
        .select(
          "machine_name, slot, product, current_stock, max_stock, fill_pct, stance, global_badge, local_badge, sales_7d, final_score, planned_action, planned_qty, wh_availability, wh_unsourceable, edit_comment, add_comment, clamp_reason, is_configured",
        )
        .limit(10000);
      // Scope to the machines on screen when a draft is loaded; else show all.
      if (machineNames.length > 0) q = q.in("machine_name", machineNames);
      const { data, error } = await q;
      if (!error && data) setCompactRows(data as CompactRow[]);
    } finally {
      setCompactLoading(false);
    }
  }, [supabase, planRows]);

  // ── PRD-011 Bug 3: restore a superseded row to draft ────────────────────
  const restoreSupersededRow = useCallback(
    async (idx: number) => {
      const row = planRows[idx];
      if (!row) return;
      if (!draftPlanDate) {
        setRestoreToast({ ok: false, msg: "No draft loaded" });
        return;
      }
      if (!row.machine_id || !row.shelf_id || !row.pod_product_id) {
        setRestoreToast({
          ok: false,
          msg: `Cannot restore — row is missing pod identifiers (${row.machine_name}/${row.shelf_code})`,
        });
        return;
      }
      setRestoringIdx(idx);
      const { error } = await supabase.rpc("restore_pod_refill_row", {
        p_plan_date: draftPlanDate,
        p_machine_id: row.machine_id,
        p_shelf_id: row.shelf_id,
        p_pod_product_id: row.pod_product_id,
        p_action: row.action,
      });
      setRestoringIdx(null);
      if (error) {
        setRestoreToast({
          ok: false,
          msg: `Restore failed: ${error.message}`,
        });
        return;
      }
      setPlanRows((prev) =>
        prev.map((r, i) => (i === idx ? { ...r, status: "draft" } : r)),
      );
      setRestoreToast({
        ok: true,
        msg: `Restored ${row.machine_name}/${row.shelf_code} (${row.pod_product_name})`,
      });
    },
    [planRows, draftPlanDate, supabase, setPlanRows],
  );

  // ── Approve pending plan (existing flow) ──────────────────────────────────
  const approvePlan = useCallback(async () => {
    setApproving(true);
    setApproveResult(null);

    const names = [
      ...new Set(
        planRows.filter((_, i) => !removed.has(i)).map((r) => r.machine_name),
      ),
    ];

    const { data, error } = await supabase.rpc("approve_refill_plan", {
      p_plan_date: selectedDate,
      p_machine_names: names,
    });

    setApproving(false);
    if (error) {
      setApproveResult({ ok: false, msg: `Approval failed: ${error.message}` });
      return;
    }
    const result = data as {
      status?: string;
      dispatching_rows_written?: number;
    } | null;
    setApproveResult({
      ok: true,
      msg: `Plan approved — ${result?.dispatching_rows_written ?? 0} dispatching lines written for ${selectedDate}`,
    });
    setPlanRows([]);
    setGenerated(false);
    setViewMode("empty");
  }, [planRows, removed, selectedDate, supabase, setPlanRows, setGenerated]);

  // ── Add row (F4: persisted via add_pod_refill_row) ─────────────────────────
  // Resolves machine_id from the loaded draft (the machine dropdown only offers
  // machines already in the plan), shelf_id + pod_product_id come straight from
  // the dropdowns, so the row is written to pod_refill_plan immediately instead
  // of living as an identifier-less local row that the commit would skip. On
  // success we reload the draft so the new row appears with real identifiers and
  // restitch-on-commit picks it up.
  const addRow = useCallback(async () => {
    const machineId = planRows.find(
      (r) => r.machine_name === addForm.machine_name && r.machine_id,
    )?.machine_id;
    if (!machineId || !addForm.shelf_id || !addForm.pod_product_id) return;
    const planDate = draftPlanDate ?? selectedDate;
    setAddBusy(true);
    setAddError(null);
    const { error } = await supabase.rpc("add_pod_refill_row", {
      p_plan_date: planDate,
      p_machine_id: machineId,
      p_shelf_id: addForm.shelf_id,
      p_pod_product_id: addForm.pod_product_id,
      p_action: addForm.action,
      p_qty: addForm.quantity,
      p_reason:
        addForm.comment || `Manual add — ${ACTION_LABELS[addForm.action]}`,
    });
    setAddBusy(false);
    if (error) {
      setAddError(error.message);
      return;
    }
    setShowAdd(false);
    setAddForm(BLANK_FORM);
    await loadDraft();
  }, [addForm, planRows, draftPlanDate, selectedDate, supabase, loadDraft]);

  // ── Derived ──────────────────────────────────────────────────────────────
  const activeRows = planRows.filter((_, i) => !removed.has(i));
  const totalUnits = activeRows
    .filter((r) => r.action === "REFILL" || r.action === "ADD_NEW")
    .reduce((s, r) => {
      const realIdx = planRows.indexOf(r);
      return s + (realIdx in editedQty ? editedQty[realIdx] : r.quantity);
    }, 0);
  const swapCount = activeRows.filter((r) => r.action === "REMOVE").length;
  const isDraft = viewMode === "draft";

  // Group by machine
  const byMachine = planRows.reduce(
    (acc, row, idx) => {
      if (!acc[row.machine_name]) acc[row.machine_name] = [];
      acc[row.machine_name].push({ row, idx });
      return acc;
    },
    {} as Record<string, { row: PlanRow; idx: number }[]>,
  );

  // PRD-015 AC#13: inclusion-aware derived state.
  const machineIdByName: Record<string, string> = {};
  for (const r of planRows)
    if (r.machine_id) machineIdByName[r.machine_name] = r.machine_id;
  const isIncluded = (name: string) => inclusion[name] !== false;
  const cardMachineNames = Object.keys(byMachine);
  const totalMachines = cardMachineNames.length;
  const includedNames = cardMachineNames.filter(isIncluded);
  const excludedNames = cardMachineNames.filter((n) => !isIncluded(n));
  const includedCount = includedNames.length;
  // included first (preserve picker order), excluded sink to the bottom.
  const sortedMachineEntries: Array<[string, { row: PlanRow; idx: number }[]]> =
    [...includedNames, ...excludedNames].map((n) => [n, byMachine[n]]);

  async function toggleMachine(name: string) {
    if (!draftPlanDate) return;
    const next = !isIncluded(name);
    setInclusion((prev) => ({ ...prev, [name]: next })); // optimistic
    const machineId = machineIdByName[name];
    if (!machineId) return;
    const { error } = await supabase.rpc("set_machine_inclusion", {
      p_plan_date: draftPlanDate,
      p_machine_id: machineId,
      p_is_included: next,
    });
    if (error) {
      setInclusion((prev) => ({ ...prev, [name]: !next })); // revert
      setRestoreToast({ ok: false, msg: `Toggle failed: ${error.message}` });
    }
  }

  async function setAllInclusion(val: boolean) {
    if (!draftPlanDate || inclusionBusy) return;
    setInclusionBusy(true);
    const prev = inclusion;
    setInclusion(() => {
      const next: Record<string, boolean> = {};
      for (const n of cardMachineNames) next[n] = val;
      return next;
    });
    const { error } = await supabase.rpc("bulk_set_machine_inclusion", {
      p_plan_date: draftPlanDate,
      p_is_included: val,
    });
    setInclusionBusy(false);
    if (error) {
      setInclusion(prev); // revert
      setRestoreToast({
        ok: false,
        msg: `Bulk toggle failed: ${error.message}`,
      });
    }
  }

  const noStockAlerts = alerts.filter((a) => a.type === "no_stock");
  const warnAlerts = alerts.filter((a) => a.type === "warning");

  // ── PRD-019c: client-side filter + sort over the compact rows ─────────────
  const STANCE_OPTIONS = [
    "DOUBLE DOWN",
    "STAR",
    "KEEP",
    "WIND DOWN",
    "ROTATE OUT",
    "DEAD",
    "WATCH",
    "RAMPING",
  ];
  const compactMachines = [
    ...new Set(compactRows.map((r) => r.machine_name)),
  ].sort((a, b) => a.localeCompare(b));
  const activeFilterCount =
    fltStance.size +
    fltMachines.size +
    (fltWhUnsourceable ? 1 : 0) +
    (fltNeedsRefill ? 1 : 0) +
    (hideUnconfigured ? 1 : 0);
  const clearCompactFilters = () => {
    setFltStance(new Set());
    setFltMachines(new Set());
    setFltWhUnsourceable(false);
    setFltNeedsRefill(false);
    setHideUnconfigured(false);
  };
  // Filters compose: AND across categories, OR within a multi-select.
  const visibleCompactRows = [...compactRows]
    .filter((r) => {
      // "Hide unconfigured/empty": is_configured=false AND no stock AND no plan.
      if (
        hideUnconfigured &&
        r.is_configured === false &&
        (r.current_stock ?? 0) === 0 &&
        r.planned_qty == null
      )
        return false;
      if (fltMachines.size > 0 && !fltMachines.has(r.machine_name))
        return false;
      if (fltStance.size > 0 && !(r.stance != null && fltStance.has(r.stance)))
        return false;
      if (
        fltWhUnsourceable &&
        !(r.wh_unsourceable === true || (r.wh_availability ?? 0) === 0)
      )
        return false;
      if (fltNeedsRefill && !((r.planned_qty ?? 0) > 0)) return false;
      return true;
    })
    .sort((a, b) => {
      if (compactSort === "stock")
        return (a.current_stock ?? 0) - (b.current_stock ?? 0);
      if (compactSort === "score")
        return (b.final_score ?? 0) - (a.final_score ?? 0);
      if (compactSort === "fill") return (a.fill_pct ?? 0) - (b.fill_pct ?? 0);
      // "machine" (default) and "slot": machine_name ASC, then natural slot ASC.
      return (
        a.machine_name.localeCompare(b.machine_name) ||
        a.slot.localeCompare(b.slot, undefined, { numeric: true })
      );
    });

  // ── Render ────────────────────────────────────────────────────────────────
  return (
    <div>
      {/* ── PRD-019 C2: compact all-rows planning view ──────────────────── */}
      <div className="bg-white border border-gray-200 rounded-xl p-5 mb-6">
        <div className="flex items-center gap-3 flex-wrap mb-3">
          <button
            onClick={() => {
              const next = !compactOpen;
              setCompactOpen(next);
              if (next && compactRows.length === 0) loadCompact();
            }}
            className="flex items-center gap-2 px-4 py-2 rounded-lg border border-gray-200 text-sm font-medium text-gray-700 hover:bg-gray-50"
          >
            {compactOpen ? "▾" : "▸"} Compact view (all slots)
          </button>
          {compactOpen && (
            <>
              <button
                onClick={loadCompact}
                disabled={compactLoading}
                className="px-3 py-1.5 rounded-lg border border-gray-200 text-xs font-medium text-gray-600 hover:bg-gray-50 disabled:opacity-50"
              >
                {compactLoading ? "Loading…" : "↻ Refresh"}
              </button>
              <div className="flex items-center gap-1 text-xs text-gray-500">
                Sort:
                {(["machine", "fill", "slot", "stock", "score"] as const).map(
                  (k) => (
                    <button
                      key={k}
                      onClick={() => setCompactSort(k)}
                      className={`px-2 py-1 rounded ${
                        compactSort === k
                          ? "bg-gray-900 text-white"
                          : "border border-gray-200 text-gray-600 hover:bg-gray-50"
                      }`}
                    >
                      {k === "fill"
                        ? "Fill %"
                        : k.charAt(0).toUpperCase() + k.slice(1)}
                    </button>
                  ),
                )}
              </div>
            </>
          )}
        </div>

        {/* ── PRD-019c: client-side filter bar (no refetch) ─────────────────── */}
        {compactOpen && (
          <div className="flex flex-col gap-2 mb-3 text-xs">
            <div className="flex items-center gap-2 flex-wrap">
              <span className="text-gray-500">Stance:</span>
              {STANCE_OPTIONS.map((s) => {
                const on = fltStance.has(s);
                return (
                  <button
                    key={s}
                    onClick={() =>
                      setFltStance((prev) => {
                        const next = new Set(prev);
                        if (next.has(s)) next.delete(s);
                        else next.add(s);
                        return next;
                      })
                    }
                    className={`px-2 py-1 rounded ${
                      on
                        ? "bg-gray-900 text-white"
                        : "border border-gray-200 text-gray-600 hover:bg-gray-50"
                    }`}
                  >
                    {s}
                  </button>
                );
              })}
            </div>
            <div className="flex items-center gap-2 flex-wrap">
              <button
                onClick={() => setFltWhUnsourceable((v) => !v)}
                className={`px-2 py-1 rounded ${
                  fltWhUnsourceable
                    ? "bg-red-600 text-white"
                    : "border border-gray-200 text-gray-600 hover:bg-gray-50"
                }`}
              >
                WH unsourceable
              </button>
              <button
                onClick={() => setFltNeedsRefill((v) => !v)}
                className={`px-2 py-1 rounded ${
                  fltNeedsRefill
                    ? "bg-gray-900 text-white"
                    : "border border-gray-200 text-gray-600 hover:bg-gray-50"
                }`}
              >
                Needs refill
              </button>
              <button
                onClick={() => setHideUnconfigured((v) => !v)}
                className={`px-2 py-1 rounded ${
                  hideUnconfigured
                    ? "bg-gray-900 text-white"
                    : "border border-gray-200 text-gray-600 hover:bg-gray-50"
                }`}
              >
                {hideUnconfigured ? "Hiding unconfigured" : "Show unconfigured"}
              </button>
              <span className="text-gray-400">
                {visibleCompactRows.length} of {compactRows.length} rows
                {activeFilterCount > 0
                  ? ` · ${activeFilterCount} filter${
                      activeFilterCount === 1 ? "" : "s"
                    } active`
                  : ""}
              </span>
              {activeFilterCount > 0 && (
                <button
                  onClick={clearCompactFilters}
                  className="px-2 py-1 rounded border border-gray-200 text-gray-600 hover:bg-gray-50"
                >
                  Clear
                </button>
              )}
            </div>
            {compactMachines.length > 0 && (
              <div className="flex items-center gap-2 flex-wrap">
                <span className="text-gray-500">Machine:</span>
                {compactMachines.map((m) => {
                  const on = fltMachines.has(m);
                  return (
                    <button
                      key={m}
                      onClick={() =>
                        setFltMachines((prev) => {
                          const next = new Set(prev);
                          if (next.has(m)) next.delete(m);
                          else next.add(m);
                          return next;
                        })
                      }
                      className={`px-2 py-1 rounded font-mono ${
                        on
                          ? "bg-gray-900 text-white"
                          : "border border-gray-200 text-gray-600 hover:bg-gray-50"
                      }`}
                    >
                      {machineShortId(m)}
                    </button>
                  );
                })}
              </div>
            )}
          </div>
        )}

        {compactOpen && (
          <div className="overflow-x-auto">
            <table className="w-full text-xs">
              <thead>
                <tr className="text-left text-gray-500 border-b border-gray-200">
                  <th className="py-2 pr-3">Machine</th>
                  <th className="py-2 pr-3">Slot</th>
                  <th className="py-2 pr-3">Product</th>
                  <th className="py-2 pr-3">Stock</th>
                  <th className="py-2 pr-3">Fill %</th>
                  <th className="py-2 pr-3">Stance</th>
                  <th className="py-2 pr-3">Global</th>
                  <th className="py-2 pr-3">Local</th>
                  <th className="py-2 pr-3">7d</th>
                  <th className="py-2 pr-3">Score</th>
                  <th className="py-2 pr-3">Planned</th>
                  <th className="py-2 pr-3">WH Avail</th>
                  <th className="py-2 pr-3">Notes</th>
                </tr>
              </thead>
              <tbody>
                {visibleCompactRows.map((r, i) => (
                  <tr
                    key={`${r.machine_name}-${r.slot}-${i}`}
                    className="border-b border-gray-100"
                  >
                    <td className="py-1.5 pr-3 whitespace-nowrap text-gray-600">
                      {r.machine_name}
                    </td>
                    <td className="py-1.5 pr-3 font-mono">{r.slot}</td>
                    <td className="py-1.5 pr-3">{r.product ?? "—"}</td>
                    <td className="py-1.5 pr-3 whitespace-nowrap">
                      {r.current_stock ?? 0}/{r.max_stock ?? 0}
                    </td>
                    <td className="py-1.5 pr-3">
                      {r.fill_pct == null ? "—" : `${r.fill_pct}%`}
                    </td>
                    <td className="py-1.5 pr-3">{r.stance ?? "—"}</td>
                    <td className="py-1.5 pr-3">{r.global_badge ?? "—"}</td>
                    <td className="py-1.5 pr-3">{r.local_badge ?? "—"}</td>
                    <td className="py-1.5 pr-3">{r.sales_7d ?? 0}</td>
                    <td className="py-1.5 pr-3">{r.final_score ?? 0}</td>
                    <td className="py-1.5 pr-3 whitespace-nowrap">
                      {r.planned_action
                        ? `${r.planned_action} ${r.planned_qty ?? 0}`
                        : "—"}
                    </td>
                    <td
                      className={`py-1.5 pr-3 ${
                        r.wh_unsourceable
                          ? "text-red-600 font-semibold"
                          : "text-gray-700"
                      }`}
                    >
                      {r.wh_availability ?? 0}
                      {r.wh_unsourceable ? " ⚠" : ""}
                    </td>
                    <td className="py-1.5 pr-3 text-gray-500">
                      {r.clamp_reason === "capacity_capped" ? "capped " : ""}
                      {r.edit_comment ?? r.add_comment ?? ""}
                    </td>
                  </tr>
                ))}
                {visibleCompactRows.length === 0 && !compactLoading && (
                  <tr>
                    <td colSpan={13} className="py-3 text-center text-gray-400">
                      {compactRows.length === 0
                        ? "No rows. Load a draft or click Refresh."
                        : "No rows match the active filters."}
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* ── Controls ──────────────────────────────────────────────────── */}
      <div className="bg-white border border-gray-200 rounded-xl p-5 mb-6">
        <div className="flex items-center gap-3 flex-wrap">
          {/* Load draft (primary) */}
          <button
            onClick={loadDraft}
            disabled={loading}
            className="flex items-center gap-2 px-4 py-2 rounded-lg bg-gray-900 text-white text-sm font-medium hover:bg-gray-800 disabled:opacity-50"
          >
            {loading && viewMode !== "pending" ? "Loading…" : "Load draft"}
          </button>

          {/* Load pending plan (secondary — post-stitch) */}
          <button
            onClick={loadPendingPlan}
            disabled={loading}
            className="flex items-center gap-2 px-4 py-2 rounded-lg border border-gray-200 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50"
          >
            {loading && viewMode === "pending"
              ? "Loading…"
              : "↓ Load pending plan"}
          </button>

          {/* Add row */}
          {generated && (
            <button
              onClick={() => {
                setAddError(null);
                setAddForm(BLANK_FORM);
                setShowAdd(true);
              }}
              className="px-4 py-2 rounded-lg border border-gray-200 text-sm font-medium text-gray-700 hover:bg-gray-50"
            >
              + Add row
            </button>
          )}
        </div>

        {/* Load result */}
        {loadResult && (
          <div
            className={`mt-3 rounded-lg px-3 py-2 text-sm font-medium ${
              loadResult.ok
                ? "bg-blue-50 text-blue-700"
                : "bg-amber-50 text-amber-700"
            }`}
          >
            {loadResult.ok ? "✓ " : "⚠ "}
            {loadResult.msg}
          </div>
        )}

        {/* Mode indicator */}
        {generated && (
          <div className="mt-2 flex items-center gap-2">
            <span
              className={`inline-flex items-center rounded-full px-2.5 py-0.5 text-[10px] font-semibold ${
                isDraft
                  ? "bg-purple-100 text-purple-700"
                  : "bg-blue-100 text-blue-700"
              }`}
            >
              {isDraft ? "DRAFT (pod level)" : "PENDING (boonz level)"}
            </span>
            {isDraft && (
              <span className="text-[10px] text-gray-400">
                Edit quantities below, then commit to finalize + stitch +
                dispatch
              </span>
            )}
          </div>
        )}

        {/* PRD-011 Bug 1: warning when the loaded draft is for a different
            date than the picker shows. Catches the cron-vs-picker drift. */}
        {generated &&
          isDraft &&
          draftPlanDate &&
          draftPlanDate !== selectedDate && (
            <div className="mt-3 rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-xs font-medium text-amber-800">
              ⚠ Draft loaded for {draftPlanDate}, but date picker shows{" "}
              {selectedDate}. Commit will use {draftPlanDate}.
            </div>
          )}

        {/* Commit button (draft mode) */}
        {generated && isDraft && activeRows.length > 0 && (
          <button
            onClick={commitDraft}
            disabled={committing || !draftPlanDate || includedCount === 0}
            title={
              !draftPlanDate
                ? "No draft loaded"
                : includedCount === 0
                  ? "All machines excluded. Include at least one to commit."
                  : undefined
            }
            className="mt-3 flex items-center gap-2 px-5 py-2.5 rounded-lg bg-emerald-700 text-white text-sm font-semibold hover:bg-emerald-800 disabled:opacity-50"
          >
            {committing
              ? "Committing…"
              : !draftPlanDate
                ? "No draft loaded"
                : includedCount === 0
                  ? "Commit (0 machines)"
                  : `Commit (${includedCount} machine${includedCount === 1 ? "" : "s"}) for ${draftPlanDate} — finalize + stitch + dispatch`}
          </button>
        )}

        {/* Approve button (pending mode) */}
        {generated && !isDraft && activeRows.length > 0 && (
          <button
            onClick={approvePlan}
            disabled={approving}
            className="mt-3 flex items-center gap-2 px-5 py-2 rounded-lg bg-emerald-700 text-white text-sm font-medium hover:bg-emerald-800 disabled:opacity-50"
          >
            {approving ? "Approving…" : "Approve & Dispatch"}
          </button>
        )}

        {/* PRD-033 / Track C C2: reopen stitched rows + re-stitch (pending mode,
            operator_admin only — the RPC enforces the role). Reverts the selected
            machines' stitched rows to approved, then re-stitches against current
            warehouse stock. */}
        {generated && !isDraft && activeRows.length > 0 && (
          <details className="mt-3 rounded-lg border border-neutral-300 bg-neutral-50 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-900">
            <summary className="cursor-pointer font-medium text-neutral-700 dark:text-neutral-200">
              Re-stitch machines (reopen stitched rows)
            </summary>
            <div className="mt-2 text-xs text-neutral-600 dark:text-neutral-400">
              Pick the machines to reopen, give a reason (min 10 chars), then
              reopen + re-stitch. Refuses any machine whose output is already
              dispatched or reviewed.
            </div>
            <div className="mt-2 flex flex-wrap gap-2">
              {[...new Set(planRows.map((r) => r.machine_name))]
                .sort()
                .map((mn) => {
                  const on = reopenSel.has(mn);
                  return (
                    <label
                      key={mn}
                      className={`flex items-center gap-1.5 rounded border px-2 py-1 text-xs ${
                        on
                          ? "border-amber-400 bg-amber-50 text-amber-800 dark:bg-amber-950/30 dark:text-amber-200"
                          : "border-neutral-300 dark:border-neutral-700"
                      }`}
                    >
                      <input
                        type="checkbox"
                        checked={on}
                        onChange={(e) => {
                          setReopenSel((prev) => {
                            const next = new Set(prev);
                            if (e.target.checked) next.add(mn);
                            else next.delete(mn);
                            return next;
                          });
                        }}
                      />
                      {mn}
                    </label>
                  );
                })}
            </div>
            <div className="mt-2 flex flex-wrap items-center gap-2">
              <input
                type="text"
                value={reopenReason}
                onChange={(e) => setReopenReason(e.target.value)}
                placeholder="Reason (min 10 chars), e.g. WH recount changed pickable stock"
                className="min-w-[280px] flex-1 rounded border border-neutral-300 px-2 py-1 text-xs dark:border-neutral-700 dark:bg-neutral-950"
              />
              <button
                onClick={reopenSelected}
                disabled={
                  reopenBusy ||
                  reopenSel.size === 0 ||
                  reopenReason.trim().length < 10
                }
                className="rounded bg-amber-600 px-3 py-1 text-xs font-semibold text-white hover:bg-amber-700 disabled:opacity-50"
              >
                {reopenBusy
                  ? "Reopening…"
                  : `Reopen & re-stitch (${reopenSel.size})`}
              </button>
            </div>
            {reopenResult && (
              <div
                className={`mt-2 rounded px-2 py-1 text-xs font-medium ${
                  reopenResult.ok
                    ? "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/30 dark:text-emerald-200"
                    : "bg-red-50 text-red-700 dark:bg-red-950/30 dark:text-red-200"
                }`}
              >
                {reopenResult.ok ? "✓ " : "✗ "}
                {reopenResult.msg}
              </div>
            )}
          </details>
        )}

        {/* Commit result */}
        {commitResult && (
          <div
            className={`mt-2 rounded-lg px-3 py-2 text-sm font-medium ${
              commitResult.ok
                ? "bg-emerald-50 text-emerald-700"
                : "bg-red-50 text-red-700"
            }`}
          >
            {commitResult.ok ? "✓ " : "✗ "}
            {commitResult.msg}
          </div>
        )}

        {/* PRD-033 / Track C C2: REMOVE-without-replace gate banner. Shows the
            shelves flagged by check_remove_without_replace and the Override that
            unblocks the commit. Values come straight from the RPC. */}
        {removeGate?.status === "block" && (
          <div className="mt-2 rounded-lg border border-amber-300 bg-amber-50 px-3 py-2.5 text-sm">
            <div className="font-semibold text-amber-800">
              ⚠ Remove-without-replace: {removeGate.flagged.length} shelf
              {removeGate.flagged.length === 1 ? "" : "s"} would lose stock with
              no pickable warehouse replacement.
            </div>
            <div className="mt-2 overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="text-left text-amber-700">
                    <th className="py-1 pr-3">Machine</th>
                    <th className="py-1 pr-3">Shelf</th>
                    <th className="py-1 pr-3">New product (ADD)</th>
                    <th className="py-1 pr-3 text-right">Add qty</th>
                    <th className="py-1 pr-3 text-right">Pickable WH</th>
                  </tr>
                </thead>
                <tbody>
                  {removeGate.flagged.map((f, i) => (
                    <tr key={i} className="border-t border-amber-200">
                      <td className="py-1 pr-3">{f.machine}</td>
                      <td className="py-1 pr-3">{f.shelf}</td>
                      <td className="py-1 pr-3">{f.add_pod_product}</td>
                      <td className="py-1 pr-3 text-right">{f.add_qty}</td>
                      <td className="py-1 pr-3 text-right font-semibold text-red-700">
                        {f.pickable_units}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <label className="mt-2 flex items-center gap-2 text-xs text-amber-800">
              <input
                type="checkbox"
                checked={removeGateOverride}
                onChange={(e) => setRemoveGateOverride(e.target.checked)}
              />
              Override: commit anyway (I accept these shelves will lose stock).
            </label>
          </div>
        )}

        {/* Approval result */}
        {approveResult && (
          <div
            className={`mt-2 rounded-lg px-3 py-2 text-sm font-medium ${
              approveResult.ok
                ? "bg-emerald-50 text-emerald-700"
                : "bg-red-50 text-red-700"
            }`}
          >
            {approveResult.ok ? "✓ " : "✗ "}
            {approveResult.msg}
          </div>
        )}

        {/* PRD-011 Bug 3: per-row restore toast */}
        {restoreToast && (
          <div
            className={`mt-2 flex items-center justify-between rounded-lg px-3 py-2 text-xs font-medium ${
              restoreToast.ok
                ? "bg-emerald-50 text-emerald-700"
                : "bg-red-50 text-red-700"
            }`}
          >
            <span>
              {restoreToast.ok ? "✓ " : "✗ "}
              {restoreToast.msg}
            </span>
            <button
              onClick={() => setRestoreToast(null)}
              className="ml-2 text-[10px] opacity-60 hover:opacity-100"
            >
              dismiss
            </button>
          </div>
        )}
      </div>

      {/* ── Alerts ────────────────────────────────────────────────────── */}
      {(noStockAlerts.length > 0 || warnAlerts.length > 0) && (
        <div className="mb-5 space-y-2">
          {warnAlerts.map((a, i) => (
            <div
              key={i}
              className="rounded-lg bg-amber-50 border border-amber-200 px-3 py-2 text-xs text-amber-700"
            >
              ⚠ {a.msg}
            </div>
          ))}
          {noStockAlerts.length > 0 && (
            <div className="rounded-lg bg-red-50 border border-red-200 px-3 py-2 text-xs text-red-700">
              No WH stock for{" "}
              {noStockAlerts
                .map((a) => `${a.machine} / ${a.shelf} — ${a.product}`)
                .join(", ")}
              . Procurement needed.
            </div>
          )}
        </div>
      )}

      {/* ── Summary strip ─────────────────────────────────────────────── */}
      {generated && (
        <div className="grid grid-cols-4 gap-3 mb-6">
          {[
            ["Machines", Object.keys(byMachine).length],
            ["Lines", activeRows.length],
            [isDraft ? "Total units" : "Refill units", totalUnits],
            ["Swaps", swapCount],
          ].map(([label, val]) => (
            <div key={label as string} className="bg-gray-50 rounded-xl p-4">
              <div className="text-2xl font-medium leading-none">{val}</div>
              <div className="text-xs text-gray-500 mt-1">{label}</div>
            </div>
          ))}
        </div>
      )}

      {/* ── PRD-031 WS-4: refill accuracy gate ────────────────────────── */}
      {generated && !isDraft && accuracy && (
        <div
          className={`rounded-xl border p-4 mb-6 ${
            accuracy.summary.verdict === "block"
              ? "border-red-300 bg-red-50"
              : accuracy.summary.verdict === "flag"
                ? "border-amber-300 bg-amber-50"
                : "border-green-300 bg-green-50"
          }`}
        >
          <div className="flex items-center justify-between gap-3">
            <div className="flex items-center gap-2">
              <span className="text-sm font-medium">
                {accuracy.summary.verdict === "block"
                  ? `🚫 Accuracy: ${accuracy.summary.leak} leak line(s) — pod intent not reaching the shelf`
                  : accuracy.summary.verdict === "flag"
                    ? `⚠️ Accuracy: under-fill (gap fill ${Math.round(
                        accuracy.summary.gap_fill_ratio * 100,
                      )}%)`
                    : "✅ Accuracy: pod intent survives to the shelf"}
              </span>
            </div>
            <div className="text-xs text-gray-600">
              intent {accuracy.summary.total_dispatched}/
              {accuracy.summary.total_intent} ·{" "}
              {Math.round(accuracy.summary.intent_fill_ratio * 100)}% · gap fill{" "}
              {Math.round(accuracy.summary.gap_fill_ratio * 100)}%
            </div>
          </div>
          {accuracy.lines.filter((l) => l.status !== "ok").length > 0 && (
            <div className="mt-3 overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="text-left text-gray-500">
                    <th className="py-1 pr-3 font-medium">Machine</th>
                    <th className="py-1 pr-3 font-medium">Shelf</th>
                    <th className="py-1 pr-3 font-medium">Product</th>
                    <th className="py-1 pr-3 font-medium text-right">Intent</th>
                    <th className="py-1 pr-3 font-medium text-right">
                      Dispatched
                    </th>
                    <th className="py-1 pr-3 font-medium text-right">Gap</th>
                    <th className="py-1 pr-3 font-medium">Status</th>
                  </tr>
                </thead>
                <tbody>
                  {accuracy.lines
                    .filter((l) => l.status !== "ok")
                    .map((l, i) => (
                      <tr key={i} className="border-t border-black/5">
                        <td className="py-1 pr-3">{l.machine_name}</td>
                        <td className="py-1 pr-3">{l.shelf_code}</td>
                        <td className="py-1 pr-3">{l.pod_product_name}</td>
                        <td className="py-1 pr-3 text-right">{l.pod_intent}</td>
                        <td className="py-1 pr-3 text-right">
                          {l.dispatched_qty}
                        </td>
                        <td className="py-1 pr-3 text-right">{l.shelf_gap}</td>
                        <td className="py-1 pr-3">
                          <span
                            className={`px-1.5 py-0.5 rounded text-[10px] font-medium ${
                              l.status === "leak"
                                ? "bg-red-100 text-red-700"
                                : l.status === "wh_short"
                                  ? "bg-amber-100 text-amber-700"
                                  : "bg-gray-100 text-gray-600"
                            }`}
                          >
                            {l.status === "wh_short"
                              ? "WH short"
                              : l.status === "leak"
                                ? "leak"
                                : l.status}
                          </span>
                        </td>
                      </tr>
                    ))}
                </tbody>
              </table>
              <p className="text-[10px] text-gray-400 mt-2">
                leak = intent missing with shelf room and no warehouse shortage
                (pod-to-dispatch loss). WH short = warehouse genuinely out (not
                a leak). Excludes lines that filled correctly.
              </p>
            </div>
          )}
        </div>
      )}

      {/* ── Empty state ────────────────────────────────────────────────── */}
      {!generated && (
        <div className="flex flex-col items-center justify-center py-20 text-center">
          <div className="text-4xl mb-3">🧠</div>
          <p className="text-sm font-medium text-gray-600 mb-1">
            {loading ? "Loading draft…" : "No draft yet for this date"}
          </p>
          <p className="text-xs text-gray-400 max-w-sm">
            {loading
              ? "Pulling the latest from the engine"
              : "Drafts are auto-generated at 8pm Dubai. If it’s past 8pm, try reloading or check the cron logs."}
          </p>
        </div>
      )}

      {/* ── PRD-015 AC#13: include/exclude route bar ───────────────────── */}
      {generated && isDraft && (
        <div className="flex items-center justify-between gap-3 mb-3 px-1">
          <span className="text-xs text-gray-600">
            {includedCount} of {totalMachines} machines selected
            {excludedNames.length > 0 && (
              <span className="text-gray-400">
                {" "}
                · {excludedNames.length} excluded
              </span>
            )}
          </span>
          <div className="flex items-center gap-2">
            <button
              onClick={() => setAllInclusion(true)}
              disabled={inclusionBusy || !draftPlanDate}
              className="text-[11px] font-medium text-gray-600 hover:text-gray-900 px-2 py-1 rounded border border-gray-200 disabled:opacity-50"
            >
              Include all
            </button>
            <button
              onClick={() => setAllInclusion(false)}
              disabled={inclusionBusy || !draftPlanDate}
              className="text-[11px] font-medium text-gray-600 hover:text-gray-900 px-2 py-1 rounded border border-gray-200 disabled:opacity-50"
            >
              Exclude all
            </button>
          </div>
        </div>
      )}

      {/* ── Plan table by machine ─────────────────────────────────────── */}
      {generated &&
        sortedMachineEntries.map(([machineName, rows]) => {
          const included = isIncluded(machineName);
          return (
            <div
              key={machineName}
              className={`mb-4 border rounded-xl overflow-hidden ${
                included ? "border-gray-200" : "border-gray-100 opacity-50"
              }`}
            >
              {/* Machine header */}
              <div className="flex items-center justify-between px-4 py-3 bg-gray-50 border-b border-gray-200">
                <div className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    checked={included}
                    onChange={() => toggleMachine(machineName)}
                    title={
                      included
                        ? "Included in this route"
                        : "Excluded from this route"
                    }
                    className="h-4 w-4 cursor-pointer accent-emerald-600"
                  />
                  <span className="font-medium text-sm">{machineName}</span>
                  {machineShortId(machineCodeByName[machineName]) && (
                    <span className="font-mono text-[11px] tracking-wider text-gray-400">
                      {machineShortId(machineCodeByName[machineName])}
                    </span>
                  )}
                </div>
                <span className="text-xs text-gray-500">
                  {rows.filter(({ idx }) => !removed.has(idx)).length} active
                  lines ·{" "}
                  {rows
                    .filter(
                      ({ row, idx }) =>
                        !removed.has(idx) &&
                        (row.action === "REFILL" || row.action === "ADD_NEW"),
                    )
                    .reduce(
                      (s, { row, idx }) =>
                        s + (idx in editedQty ? editedQty[idx] : row.quantity),
                      0,
                    )}{" "}
                  units
                </span>
              </div>

              {/* Excluded machines collapse to a compact line (AC#13) */}
              {!included && (
                <div className="px-4 py-2 text-[11px] text-gray-400">
                  Excluded from this route — {rows.length} line
                  {rows.length === 1 ? "" : "s"} hidden. Re-include to commit.
                </div>
              )}

              {/* Table (hidden when machine is excluded) */}
              {included && (
                <div className="overflow-x-auto">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="text-left text-gray-400 border-b border-gray-100 ">
                        <th className="px-4 py-2 font-medium">Shelf</th>
                        <th className="px-4 py-2 font-medium">Action</th>
                        <th className="px-4 py-2 font-medium">Product</th>
                        {isDraft && (
                          <th className="px-4 py-2 font-medium">Signal</th>
                        )}
                        <th className="px-4 py-2 font-medium text-right">
                          Stock
                        </th>
                        <th className="px-4 py-2 font-medium text-right">
                          Qty
                        </th>
                        {isDraft && (
                          <th className="px-4 py-2 font-medium text-right">
                            v30d
                          </th>
                        )}
                        {!isDraft && (
                          <th className="px-4 py-2 font-medium text-right">
                            7d
                          </th>
                        )}
                        <th className="px-3 py-2" />
                      </tr>
                    </thead>
                    <tbody>
                      {rows.map(({ row, idx }) => (
                        <tr
                          key={idx}
                          className={`border-b border-gray-100/50 last:border-0 transition-opacity ${
                            removed.has(idx)
                              ? "opacity-30 line-through"
                              : "hover:bg-gray-50"
                          }`}
                        >
                          <td className="px-4 py-2.5 font-mono text-xs">
                            {priorityBadge(row.machine_priority)}{" "}
                            {row.shelf_code}
                          </td>
                          <td className="px-4 py-2.5">
                            {actionBadge(row.action)}
                          </td>
                          <td className="px-4 py-2.5 max-w-[200px]">
                            <div className="flex items-center">
                              {!isDraft && tierDot(row.tier)}
                              <div className="min-w-0">
                                <div className="truncate text-xs font-medium">
                                  {row.pod_product_name}
                                </div>
                                {!isDraft && row.boonz_product_name && (
                                  <div className="truncate text-[10px] text-gray-500">
                                    {row.boonz_product_name}
                                  </div>
                                )}
                                {isDraft && row.clamp_reason && (
                                  <div className="truncate text-[10px] text-gray-400">
                                    {row.clamp_reason.replace(/_/g, " ")}
                                  </div>
                                )}
                              </div>
                            </div>
                          </td>
                          {isDraft && (
                            <td className="px-4 py-2.5">
                              {signalBadge(row.signal)}
                            </td>
                          )}
                          <td className="px-4 py-2.5 text-right text-gray-500 whitespace-nowrap">
                            {row.current_stock}/{row.max_stock}
                            {isDraft && row.fill_pct != null && (
                              <span className="ml-1 text-[9px] text-gray-400">
                                ({Math.round(row.fill_pct)}%)
                              </span>
                            )}
                          </td>
                          <td className="px-4 py-2.5 text-right">
                            {row.action === "REMOVE" ? (
                              <span className="text-gray-400">—</span>
                            ) : (
                              <input
                                type="number"
                                min={0}
                                max={row.max_stock}
                                value={
                                  idx in editedQty
                                    ? editedQty[idx]
                                    : row.quantity
                                }
                                onChange={(e) => {
                                  const v = parseInt(e.target.value) || 0;
                                  setEditedQty((prev) => ({
                                    ...prev,
                                    [idx]: v,
                                  }));
                                }}
                                disabled={removed.has(idx)}
                                className="w-14 text-right rounded border border-gray-200 px-1.5 py-1 text-xs bg-white disabled:opacity-50"
                              />
                            )}
                          </td>
                          {isDraft && (
                            <td className="px-4 py-2.5 text-right text-gray-500">
                              {row.velocity_30d?.toFixed(1) ?? "—"}
                            </td>
                          )}
                          {!isDraft && (
                            <td className="px-4 py-2.5 text-right text-gray-500">
                              {row.sold_7d}
                            </td>
                          )}
                          <td className="px-3 py-2.5 text-right">
                            {row.status === "superseded" ? (
                              // PRD-011 Bug 3: DB-side superseded row. The
                              // Restore button calls restore_pod_refill_row so
                              // the change reaches the database, not just FE
                              // state.
                              <button
                                onClick={() => restoreSupersededRow(idx)}
                                disabled={restoringIdx === idx}
                                className="text-[10px] font-medium text-amber-600 hover:text-amber-800 px-1 py-0.5 rounded disabled:opacity-50"
                                title="Flip status from superseded back to draft"
                              >
                                {restoringIdx === idx
                                  ? "Restoring…"
                                  : "Restore (superseded)"}
                              </button>
                            ) : (
                              <button
                                onClick={() =>
                                  setRemoved((prev) => {
                                    const n = new Set(prev);
                                    n.has(idx) ? n.delete(idx) : n.add(idx);
                                    return n;
                                  })
                                }
                                className="text-[10px] text-gray-400 hover:text-red-500 px-1 py-0.5 rounded"
                              >
                                {removed.has(idx) ? "Restore" : "×"}
                              </button>
                            )}
                            {/* PRD-033 / Track C C2: convert this slot's product. */}
                            {isDraft &&
                              row.machine_id &&
                              row.shelf_id &&
                              row.pod_product_id && (
                                <button
                                  onClick={() => openConvert(row)}
                                  className="ml-1 text-[10px] font-medium text-indigo-600 hover:text-indigo-800 px-1 py-0.5 rounded"
                                  title="Convert this slot to a different product (convert_shelf)"
                                >
                                  Convert
                                </button>
                              )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          );
        })}

      {/* ── Add Row Modal ──────────────────────────────────────────────── */}
      {showAdd && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4">
          <div className="w-full max-w-md bg-white rounded-2xl shadow-2xl p-6">
            <div className="flex items-center justify-between mb-5">
              <h3 className="font-semibold text-base">Add plan row</h3>
              <button
                onClick={() => setShowAdd(false)}
                className="text-gray-400 hover:text-gray-600 text-lg"
              >
                ✕
              </button>
            </div>

            <div className="space-y-3">
              {/* Action first — drives what the row means */}
              <div>
                <label className="block text-xs text-gray-500 mb-1">
                  Action <span className="text-red-500">*</span>
                </label>
                <div className="grid grid-cols-4 gap-1.5">
                  {(
                    ["REFILL", "ADD_NEW", "REMOVE", "M2W"] as RefillAction[]
                  ).map((a) => (
                    <button
                      key={a}
                      type="button"
                      onClick={() => setAddForm((f) => ({ ...f, action: a }))}
                      className={`rounded-lg px-2 py-2 text-[11px] font-semibold border transition ${
                        addForm.action === a
                          ? "border-gray-900 bg-gray-900 text-white"
                          : "border-gray-200 bg-white text-gray-600 hover:bg-gray-50"
                      }`}
                    >
                      {ACTION_LABELS[a]}
                    </button>
                  ))}
                </div>
              </div>

              {/* Machine — only machines already in the loaded draft (so the
                  machine_id resolves and the row can be persisted). */}
              <div>
                <label className="block text-xs text-gray-500 mb-1">
                  Machine <span className="text-red-500">*</span>
                </label>
                <select
                  value={addForm.machine_name}
                  onChange={(e) =>
                    setAddForm((f) => ({
                      ...f,
                      machine_name: e.target.value,
                      shelf_id: "", // reset shelf when machine changes
                    }))
                  }
                  className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm bg-white"
                >
                  <option value="">Select machine…</option>
                  {cardMachineNames.map((m) => (
                    <option key={m} value={m}>
                      {m}
                    </option>
                  ))}
                </select>
                {cardMachineNames.length === 0 && (
                  <p className="mt-1 text-[11px] text-amber-600">
                    Load a draft first — rows are added to machines already in
                    the plan.
                  </p>
                )}
              </div>

              {/* Shelf — resolved to shelf_id from the machine's configuration */}
              <div>
                <label className="block text-xs text-gray-500 mb-1">
                  Shelf <span className="text-red-500">*</span>
                </label>
                <select
                  value={addForm.shelf_id}
                  disabled={!addForm.machine_name}
                  onChange={(e) =>
                    setAddForm((f) => ({ ...f, shelf_id: e.target.value }))
                  }
                  className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm bg-white disabled:bg-gray-50 disabled:text-gray-400"
                >
                  <option value="">
                    {addForm.machine_name
                      ? "Select shelf…"
                      : "Pick a machine first"}
                  </option>
                  {(shelvesByMachine[addForm.machine_name] ?? []).map((s) => (
                    <option key={s.shelf_id} value={s.shelf_id}>
                      {s.shelf_code}
                    </option>
                  ))}
                </select>
                {/* Autofill context: if the chosen shelf already has a draft row,
                    show its live stock so CS picks a sensible qty. */}
                {(() => {
                  const ctx = planRows.find(
                    (r) =>
                      r.machine_name === addForm.machine_name &&
                      r.shelf_id === addForm.shelf_id,
                  );
                  return ctx ? (
                    <p className="mt-1 text-[11px] text-gray-500">
                      Shelf currently: {ctx.pod_product_name} · stock{" "}
                      {ctx.current_stock}/{ctx.max_stock}
                    </p>
                  ) : null;
                })()}
              </div>

              {/* Forced product dropdown — resolves to pod_product_id. No free
                  text: this is the root-cause fix for identifier-less rows. */}
              <div>
                <label className="block text-xs text-gray-500 mb-1">
                  Product <span className="text-red-500">*</span>
                </label>
                <select
                  value={addForm.pod_product_id}
                  onChange={(e) =>
                    setAddForm((f) => ({
                      ...f,
                      pod_product_id: e.target.value,
                    }))
                  }
                  className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm bg-white"
                >
                  <option value="">Select product…</option>
                  {podProducts.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name}
                    </option>
                  ))}
                </select>
              </div>

              {/* Qty */}
              <div>
                <label className="block text-xs text-gray-500 mb-1">
                  {addForm.action === "REMOVE" || addForm.action === "M2W"
                    ? "Quantity to remove"
                    : "Quantity"}
                </label>
                <input
                  type="number"
                  min={0}
                  value={addForm.quantity}
                  onChange={(e) =>
                    setAddForm((f) => ({
                      ...f,
                      quantity: parseInt(e.target.value) || 0,
                    }))
                  }
                  className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm bg-white"
                />
              </div>

              {/* Comment */}
              <div>
                <label className="block text-xs text-gray-500 mb-1">
                  Reason / comment (optional)
                </label>
                <input
                  type="text"
                  value={addForm.comment}
                  onChange={(e) =>
                    setAddForm((f) => ({ ...f, comment: e.target.value }))
                  }
                  className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm bg-white"
                />
              </div>

              {addError && (
                <p className="text-xs text-red-600 bg-red-50 border border-red-100 rounded-lg px-3 py-2">
                  {addError}
                </p>
              )}
            </div>

            <div className="mt-5 flex gap-3">
              <button
                onClick={() => setShowAdd(false)}
                className="flex-1 rounded-xl border border-gray-200 py-2.5 text-sm font-medium text-gray-600 hover:bg-gray-50"
              >
                Cancel
              </button>
              <button
                onClick={addRow}
                disabled={
                  addBusy ||
                  !addForm.machine_name ||
                  !addForm.shelf_id ||
                  !addForm.pod_product_id
                }
                className="flex-1 rounded-xl bg-gray-900 py-2.5 text-sm font-medium text-white hover:bg-gray-800 disabled:opacity-40 "
              >
                {addBusy ? "Adding…" : "Add row"}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* PRD-033 / Track C C2: convert_shelf modal. */}
      {convertRow && (
        <div
          className="fixed inset-0 z-[200] flex items-center justify-center bg-black/40 p-4"
          onClick={() => !convertBusy && setConvertRow(null)}
        >
          <div
            className="w-full max-w-md rounded-2xl bg-white p-5 shadow-xl"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="text-sm font-semibold text-gray-900">
              Convert shelf {convertRow.shelf_code} @ {convertRow.machine_name}
            </div>
            <div className="mt-1 text-xs text-gray-500">
              Removes <strong>{convertRow.old_pod_product_name}</strong> and adds
              the new product in one step. Re-stitch happens on commit.
            </div>

            <label className="mt-3 block text-xs font-medium text-gray-700">
              New product
            </label>
            <select
              value={convertNewProd}
              onChange={(e) => setConvertNewProd(e.target.value)}
              className="mt-1 w-full rounded-lg border border-gray-300 px-2 py-1.5 text-sm"
            >
              <option value="">Select a product…</option>
              {podProducts
                .filter((p) => p.id !== convertRow.old_pod_product_id)
                .map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.name}
                  </option>
                ))}
            </select>

            <div className="mt-3 flex gap-3">
              <div className="flex-1">
                <label className="block text-xs font-medium text-gray-700">
                  New qty
                  {convertHeadroom !== null && (
                    <span className="ml-1 font-normal text-gray-400">
                      (shelf headroom {convertHeadroom})
                    </span>
                  )}
                </label>
                <input
                  type="number"
                  min={0}
                  value={convertQty}
                  onChange={(e) => setConvertQty(e.target.value)}
                  className="mt-1 w-full rounded-lg border border-gray-300 px-2 py-1.5 text-sm"
                />
              </div>
              <div className="flex-1">
                <label className="block text-xs font-medium text-gray-700">
                  Return mode
                </label>
                <select
                  value={convertMode}
                  onChange={(e) => setConvertMode(e.target.value)}
                  className="mt-1 w-full rounded-lg border border-gray-300 px-2 py-1.5 text-sm"
                >
                  <option value="wh">wh (return to warehouse / M2W)</option>
                  <option value="m2m">m2m (machine to machine)</option>
                  <option value="truck_transfer">truck_transfer</option>
                  <option value="unknown">unknown</option>
                </select>
              </div>
            </div>

            <label className="mt-3 block text-xs font-medium text-gray-700">
              Reason (optional)
            </label>
            <input
              type="text"
              value={convertReason}
              onChange={(e) => setConvertReason(e.target.value)}
              placeholder="why this conversion"
              className="mt-1 w-full rounded-lg border border-gray-300 px-2 py-1.5 text-sm"
            />

            {convertResult && !convertResult.ok && (
              <div className="mt-2 rounded-lg bg-red-50 px-2 py-1.5 text-xs text-red-700">
                {convertResult.msg}
              </div>
            )}

            <div className="mt-4 flex gap-2">
              <button
                onClick={() => setConvertRow(null)}
                disabled={convertBusy}
                className="flex-1 rounded-xl border border-gray-300 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-40"
              >
                Cancel
              </button>
              <button
                onClick={submitConvert}
                disabled={convertBusy || !convertNewProd || convertQty === ""}
                className="flex-1 rounded-xl bg-indigo-600 py-2 text-sm font-medium text-white hover:bg-indigo-700 disabled:opacity-40"
              >
                {convertBusy ? "Converting…" : "Convert"}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* PRD-033 / Track C C2: convert success toast (errors render in-modal). */}
      {convertResult?.ok && (
        <div className="fixed bottom-6 right-6 z-[210] max-w-sm rounded-lg bg-emerald-50 px-4 py-2.5 text-sm font-medium text-emerald-800 shadow-lg">
          ✓ {convertResult.msg}
        </div>
      )}
    </div>
  );
}
