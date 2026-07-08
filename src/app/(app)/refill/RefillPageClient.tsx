"use client";

import { useState } from "react";
import Link from "next/link";
import { getDubaiDate } from "@/lib/utils/date";
import { DailyDispatchingTab } from "./DailyDispatchingTab";
import { RefillPlanningTab, type PlanRow } from "./RefillPlanningTab";
import { TrackerTab } from "./TrackerTab";
import { SignalsTab } from "./SignalsTab";
import SnapshotTab, { type RefillInitialData } from "./SnapshotTab";

// PRD-087 P3: the Stock Snapshot feature (types, helpers, state, handlers and
// JSX) lives in SnapshotTab.tsx. The snapshot types are re-exported here so
// the server component (page.tsx) keeps importing them from RefillPageClient.
export type {
  DeviceRow,
  MachineHealth,
  RefillInitialData,
} from "./SnapshotTab";

// ── Component ───────────────────────────────────────────────────────────────────

export default function RefillPageClient({
  initialData,
}: {
  initialData?: RefillInitialData;
}) {
  const [tab, setTab] = useState<
    "snapshot" | "planning" | "dispatching" | "signals" | "issues"
  >("snapshot");
  const [showTomorrow, setShowTomorrow] = useState(true);

  // ── Hoisted refill planning state (persists across tab switches) ──────────────
  const [planRows, setPlanRows] = useState<PlanRow[]>([]);
  const [editedQty, setEditedQty] = useState<Record<number, number>>({});
  const [removed, setRemoved] = useState<Set<number>>(new Set());
  const [generated, setGenerated] = useState(false);

  // PRD-087 P3: SnapshotTab owns the machineHealth data; it reports the
  // machine name list up so the Refill Planning tab stays in sync.
  const [machineNames, setMachineNames] = useState<string[]>(
    (initialData?.machineHealth ?? []).map((m) => m.machine_name),
  );

  const dubaiToday = getDubaiDate();
  const dubaiTomorrow = (() => {
    const d = new Date(dubaiToday);
    d.setDate(d.getDate() + 1);
    return d.toISOString().split("T")[0];
  })();
  const selectedDate = showTomorrow ? dubaiTomorrow : dubaiToday;

  // ── Render ────────────────────────────────────────────────────────────────────
  return (
    <div className="max-w-6xl mx-auto px-4 py-8 sm:px-6">
      {/* Header */}
      <div className="mb-8 flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold text-gray-900">Refill data</h1>
          <p className="text-sm text-gray-500 mt-1">
            Pull latest sales, inventory, and machine status from Weimi API
          </p>
          <div className="mt-2 flex items-center gap-3 text-xs">
            <Link
              href="/refill/drift"
              className="text-gray-500 hover:text-gray-900 underline-offset-2 hover:underline transition-colors"
            >
              Inventory drift &rarr;
            </Link>
          </div>
          {/* Today / Tomorrow toggle */}
          <div className="flex gap-2 items-center mt-3">
            <button
              onClick={() => setShowTomorrow(false)}
              className={`px-3 py-1 rounded text-sm font-medium transition-colors ${
                !showTomorrow
                  ? "bg-blue-600 text-white"
                  : "bg-gray-100 text-gray-600 hover:bg-gray-200"
              }`}
            >
              Today
            </button>
            <button
              onClick={() => setShowTomorrow(true)}
              className={`px-3 py-1 rounded text-sm font-medium transition-colors ${
                showTomorrow
                  ? "bg-blue-600 text-white"
                  : "bg-gray-100 text-gray-600 hover:bg-gray-200"
              }`}
            >
              Tomorrow
            </button>
          </div>
          <p className="text-xs text-gray-400 mt-1">{selectedDate}</p>
        </div>
      </div>

      {/* ── Tab bar ──────────────────────────────────────────────────────────── */}
      <div
        style={{
          borderBottom: "1px solid #e8e4de",
          marginBottom: 24,
          display: "flex",
        }}
      >
        {(
          [
            ["snapshot", "Stock Snapshot"],
            ["planning", "Refill Planning"],
            ["dispatching", "Refill Dispatch"],
            ["signals", "Signals"],
            ["issues", "Issues"],
          ] as const
        ).map(([t, label]) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            style={{
              padding: "12px 16px",
              fontSize: 12,
              fontWeight: tab === t ? 700 : 500,
              letterSpacing: "0.06em",
              textTransform: "uppercase" as const,
              color: tab === t ? "#0a0a0a" : "#6b6860",
              background: "none",
              border: "none",
              borderBottom:
                tab === t ? "3px solid #0a0a0a" : "3px solid transparent",
              marginBottom: -1,
              cursor: "pointer",
            }}
          >
            {label}
          </button>
        ))}
      </div>

      {/* ── Refill Dispatch tab ───────────────────────────────────────────────── */}
      {tab === "dispatching" && (
        <DailyDispatchingTab selectedDate={selectedDate} />
      )}

      {/* ── Refill Planning tab — RPC-driven plan builder ────────────────────── */}
      {tab === "planning" && (
        <RefillPlanningTab
          selectedDate={selectedDate}
          machineNames={machineNames}
          planRows={planRows}
          setPlanRows={setPlanRows}
          editedQty={editedQty}
          setEditedQty={setEditedQty}
          removed={removed}
          setRemoved={setRemoved}
          generated={generated}
          setGenerated={setGenerated}
        />
      )}

      {/* ── Signals tab — PRD-055: the single operator notes channel (engine-aware) ── */}
      {tab === "signals" && <SignalsTab />}

      {/* ── Issues tab — PRD-055: CS-facing bug/action board (v_action_tracker_issues);
           replaces the retired Tracker tab. Field Capture removed (folded into Signals). ── */}
      {tab === "issues" && <TrackerTab />}

      {/* ── Stock Snapshot tab — machine health + slot drill-down ────────────── */}
      <div style={{ display: tab === "snapshot" ? undefined : "none" }}>
        <SnapshotTab
          initialData={initialData}
          onMachineNamesChange={setMachineNames}
        />
      </div>
      {/* end snapshot tab */}
    </div>
  );
}
