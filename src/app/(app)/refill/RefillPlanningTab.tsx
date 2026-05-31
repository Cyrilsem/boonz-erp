"use client";

import { useState, useCallback, useEffect } from "react";
import { createBrowserClient } from "@supabase/ssr";
import { machineShortId } from "@/lib/utils/machine-id";

// ── Types ──────────────────────────────────────────────────────────────────────

export type PlanRow = {
  machine_name: string;
  machine_priority: number;
  shelf_code: string;
  pod_product_name: string;
  boonz_product_name: string;
  action: "REFILL" | "REMOVE" | "ADD NEW";
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

type AddRowForm = {
  machine_name: string;
  shelf_code: string;
  action: "REFILL" | "ADD NEW" | "REMOVE";
  pod_product_name: string;
  boonz_product_name: string;
  quantity: number;
  current_stock: number;
  max_stock: number;
  comment: string;
};

type ViewMode = "empty" | "draft" | "pending";

// ── Helpers ────────────────────────────────────────────────────────────────────

function actionBadge(action: string) {
  const styles: Record<string, string> = {
    REFILL: "bg-blue-100 text-blue-700 ",
    REMOVE: "bg-red-100 text-red-700 ",
    "ADD NEW": "bg-green-100 text-green-700 ",
  };
  return (
    <span
      className={`inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-semibold ${
        styles[action] ?? "bg-gray-100 text-gray-600"
      }`}
    >
      {action}
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
  machine_name: "",
  shelf_code: "",
  action: "REFILL",
  pod_product_name: "",
  boonz_product_name: "",
  quantity: 1,
  current_stock: 0,
  max_stock: 10,
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

  // Add row modal
  const [showAdd, setShowAdd] = useState(false);
  const [addForm, setAddForm] = useState<AddRowForm>(BLANK_FORM);

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

    const { data, error } = await supabase
      .from("refill_plan_output")
      .select("*")
      .eq("plan_date", selectedDate)
      .eq("operator_status", "pending")
      .order("shelf_code")
      .order("action", { ascending: false });

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
  }, [
    selectedDate,
    supabase,
    setPlanRows,
    setGenerated,
    setRemoved,
    setEditedQty,
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

      // PRD-011 Bug 2 Step 0a: persist inline quantity edits BEFORE Gate 1
      // approves the draft. Without this, the stitch silently uses the
      // engine-generated quantities and CS's edits are lost.
      for (const [rowIndexStr, newQty] of Object.entries(editedQty)) {
        const rowIndex = Number(rowIndexStr);
        const row = planRows[rowIndex];
        if (!row) continue;
        if (!row.machine_id || !row.shelf_id || !row.pod_product_id) {
          throw new Error(
            `Edit persist failed at row ${rowIndex} (${row.machine_name}/${row.shelf_code}): missing pod identifiers`,
          );
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
        if (!row.machine_id || !row.shelf_id || !row.pod_product_id) {
          throw new Error(
            `Row removal persist failed at row ${rowIndex} (${row.machine_name}/${row.shelf_code}): missing pod identifiers`,
          );
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

      // Step 1: Approve pod_refill_plan (Gate 1)
      const { error: approveErr } = await supabase.rpc(
        "approve_pod_refill_plan",
        { p_plan_date: planDate },
      );
      if (approveErr) throw new Error(`Gate 1 failed: ${approveErr.message}`);

      // Step 2: Finalize (conflict resolution)
      const { error: finalizeErr } = await supabase.rpc("engine_finalize_pod", {
        p_plan_date: planDate,
      });
      if (finalizeErr)
        throw new Error(`Finalize failed: ${finalizeErr.message}`);

      // Step 3: Stitch (pod → boonz via SQL join) — commit mode
      const { data: stitchData, error: stitchErr } = await supabase.rpc(
        "stitch_pod_to_boonz",
        { p_plan_date: planDate, p_dry_run: false },
      );
      if (stitchErr) throw new Error(`Stitch failed: ${stitchErr.message}`);

      const stitchResult = stitchData as {
        rows_written?: number;
        machines?: number;
      } | null;

      // Step 4: Approve boonz-level plan (auto-create dispatching)
      const activeMachines = [...new Set(planRows.map((r) => r.machine_name))];
      const { data: dispatchData, error: dispatchErr } = await supabase.rpc(
        "approve_refill_plan",
        { p_plan_date: planDate, p_machine_names: activeMachines },
      );
      if (dispatchErr)
        throw new Error(`Dispatch failed: ${dispatchErr.message}`);

      const dispResult = dispatchData as {
        dispatching_rows_written?: number;
      } | null;

      setCommitting(false);
      setCommitResult({
        ok: true,
        msg: `Plan committed for ${planDate} — ${stitchResult?.rows_written ?? "?"} boonz rows stitched, ${dispResult?.dispatching_rows_written ?? "?"} dispatch lines created. Drivers will see it.`,
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
    }
  }, [
    draftPlanDate,
    supabase,
    planRows,
    removed,
    editedQty,
    setPlanRows,
    setGenerated,
    setEditedQty,
    setRemoved,
  ]);

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

  // ── Add row ──────────────────────────────────────────────────────────────
  const addRow = useCallback(() => {
    if (
      !addForm.machine_name ||
      !addForm.shelf_code ||
      !addForm.boonz_product_name
    )
      return;
    const newRow: PlanRow = {
      machine_name: addForm.machine_name,
      machine_priority: 5,
      shelf_code: addForm.shelf_code.toUpperCase(),
      pod_product_name: addForm.pod_product_name || addForm.boonz_product_name,
      boonz_product_name: addForm.boonz_product_name,
      action: addForm.action,
      quantity: addForm.quantity,
      current_stock: addForm.current_stock,
      max_stock: addForm.max_stock,
      smart_target: addForm.quantity + addForm.current_stock,
      tier: "keep",
      global_score: 0,
      sold_7d: 0,
      fill_pct:
        addForm.max_stock > 0
          ? Math.round((addForm.current_stock / addForm.max_stock) * 100)
          : 0,
      comment: addForm.comment || `Manual addition — ${addForm.action}`,
    };
    setPlanRows((prev) => [...prev, newRow]);
    setShowAdd(false);
    setAddForm(BLANK_FORM);
    if (!generated) setGenerated(true);
  }, [addForm, generated]);

  // ── Derived ──────────────────────────────────────────────────────────────
  const activeRows = planRows.filter((_, i) => !removed.has(i));
  const totalUnits = activeRows
    .filter((r) => r.action === "REFILL" || r.action === "ADD NEW")
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

  // ── Render ────────────────────────────────────────────────────────────────
  return (
    <div>
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
              onClick={() => setShowAdd(true)}
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
                        (row.action === "REFILL" || row.action === "ADD NEW"),
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
              {/* Machine */}
              <div>
                <label className="block text-xs text-gray-500 mb-1">
                  Machine <span className="text-red-500">*</span>
                </label>
                <select
                  value={addForm.machine_name}
                  onChange={(e) =>
                    setAddForm((f) => ({ ...f, machine_name: e.target.value }))
                  }
                  className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm bg-white"
                >
                  <option value="">Select machine…</option>
                  {machineNames.map((m) => (
                    <option key={m} value={m}>
                      {m}
                    </option>
                  ))}
                </select>
              </div>

              {/* Shelf + Action */}
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs text-gray-500 mb-1">
                    Shelf <span className="text-red-500">*</span>
                  </label>
                  <input
                    type="text"
                    placeholder="A01"
                    value={addForm.shelf_code}
                    onChange={(e) =>
                      setAddForm((f) => ({ ...f, shelf_code: e.target.value }))
                    }
                    className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm bg-white"
                  />
                </div>
                <div>
                  <label className="block text-xs text-gray-500 mb-1">
                    Action
                  </label>
                  <select
                    value={addForm.action}
                    onChange={(e) =>
                      setAddForm((f) => ({
                        ...f,
                        action: e.target.value as AddRowForm["action"],
                      }))
                    }
                    className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm bg-white"
                  >
                    <option value="REFILL">REFILL</option>
                    <option value="ADD NEW">ADD NEW</option>
                    <option value="REMOVE">REMOVE</option>
                  </select>
                </div>
              </div>

              {/* Boonz product */}
              <div>
                <label className="block text-xs text-gray-500 mb-1">
                  Boonz product name <span className="text-red-500">*</span>
                </label>
                <input
                  type="text"
                  placeholder="e.g. Evian - Regular"
                  value={addForm.boonz_product_name}
                  onChange={(e) =>
                    setAddForm((f) => ({
                      ...f,
                      boonz_product_name: e.target.value,
                    }))
                  }
                  className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm bg-white"
                />
              </div>

              {/* Pod product */}
              <div>
                <label className="block text-xs text-gray-500 mb-1">
                  Pod product name
                </label>
                <input
                  type="text"
                  placeholder="e.g. Evian (defaults to boonz name)"
                  value={addForm.pod_product_name}
                  onChange={(e) =>
                    setAddForm((f) => ({
                      ...f,
                      pod_product_name: e.target.value,
                    }))
                  }
                  className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm bg-white"
                />
              </div>

              {/* Qty / Current / Max */}
              <div className="grid grid-cols-3 gap-3">
                <div>
                  <label className="block text-xs text-gray-500 mb-1">
                    Qty
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
                <div>
                  <label className="block text-xs text-gray-500 mb-1">
                    Current stock
                  </label>
                  <input
                    type="number"
                    min={0}
                    value={addForm.current_stock}
                    onChange={(e) =>
                      setAddForm((f) => ({
                        ...f,
                        current_stock: parseInt(e.target.value) || 0,
                      }))
                    }
                    className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm bg-white"
                  />
                </div>
                <div>
                  <label className="block text-xs text-gray-500 mb-1">
                    Max stock
                  </label>
                  <input
                    type="number"
                    min={1}
                    value={addForm.max_stock}
                    onChange={(e) =>
                      setAddForm((f) => ({
                        ...f,
                        max_stock: parseInt(e.target.value) || 10,
                      }))
                    }
                    className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm bg-white"
                  />
                </div>
              </div>

              {/* Comment */}
              <div>
                <label className="block text-xs text-gray-500 mb-1">
                  Comment (optional)
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
                  !addForm.machine_name ||
                  !addForm.shelf_code ||
                  !addForm.boonz_product_name
                }
                className="flex-1 rounded-xl bg-gray-900 py-2.5 text-sm font-medium text-white hover:bg-gray-800 disabled:opacity-40 "
              >
                Add row
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
