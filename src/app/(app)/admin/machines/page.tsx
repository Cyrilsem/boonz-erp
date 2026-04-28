"use client";

import { useState, useEffect, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Machine, SimCard } from "@/types/machines";
import MachineInsights from "@/components/admin/machines/MachineInsights";
import MachineTable from "@/components/admin/machines/MachineTable";
import MachineEditPanel from "@/components/admin/machines/MachineEditPanel";

type BulkAction =
  | "set_active"
  | "set_inactive"
  | "toggle_refill"
  | "export_csv";

interface ToastState {
  message: string;
  type: "success" | "error";
}

// CC-Article-1 (B.x.3): Repurpose dialog option lists. Mirrored from the
// field-PWA implementation at src/app/(field)/field/config/machines/page.tsx
// (lines 25 + 1427-1497). TODO B.x.3.b: hoist these into @/types/machines so
// both surfaces share one source of truth.
const REPURPOSE_LOCATION_TYPES = [
  "coworking",
  "office",
  "entertainment",
  "retail",
  "airport",
  "hotel",
  "warehouse",
  "other",
];

const REPURPOSE_SOURCES_OF_SUPPLY = ["BOONZ", "VOX", "LLFP"];

// Mirror of VENUE_GROUP_OPTIONS in src/app/(field)/field/config/machines/page.tsx:25
const REPURPOSE_VENUE_GROUPS = [
  "ADDMIND",
  "VOX",
  "VML",
  "WPP",
  "OHMYDESK",
  "INDEPENDENT",
];

interface RepurposeValues {
  official_name: string;
  pod_location: string;
  location_type: string;
  building_id: string;
  source_of_supply: string;
  venue_group: string;
}

const EMPTY_REPURPOSE_VALUES: RepurposeValues = {
  official_name: "",
  pod_location: "",
  location_type: "coworking",
  building_id: "",
  source_of_supply: "BOONZ",
  venue_group: "INDEPENDENT",
};

interface RepurposeResult {
  old_machine_id: string;
  new_machine_id: string;
  slots_archived: number;
  aliases_wired: number;
}

export default function MachinesPage() {
  const [machines, setMachines] = useState<Machine[]>([]);
  const [simMap, setSimMap] = useState<Map<string, SimCard>>(new Map());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editMachineId, setEditMachineId] = useState<string | null>(null);
  const [toast, setToast] = useState<ToastState | null>(null);
  const [showInsights, setShowInsights] = useState(true);

  // CC-Article-1 (B.x.3): Repurpose dialog state. Identity-shape machine
  // mutations route through this dialog → repurpose-machine edge fn →
  // repurpose_machine RPC (creates new row, archives old, wires aliases).
  const [repurposeMachineId, setRepurposeMachineId] = useState<string | null>(
    null,
  );
  const [repurposeStep, setRepurposeStep] = useState<
    "form" | "confirm" | "done"
  >("form");
  const [repurposeValues, setRepurposeValues] = useState<RepurposeValues>(
    EMPTY_REPURPOSE_VALUES,
  );
  const [repurposeResult, setRepurposeResult] =
    useState<RepurposeResult | null>(null);
  const [repurposing, setRepurposing] = useState(false);
  const [repurposeError, setRepurposeError] = useState<string | null>(null);

  const showToast = useCallback(
    (message: string, type: "success" | "error") => {
      setToast({ message, type });
      setTimeout(() => setToast(null), 3000);
    },
    [],
  );

  const fetchData = useCallback(async () => {
    setLoading(true);
    setError(null);

    const supabase = createClient();

    const { data: machinesData, error: machinesError } = await supabase
      .from("machines")
      .select("*")
      .limit(10000)
      .order("official_name");

    if (machinesError) {
      setError("Failed to load machines. " + machinesError.message);
      setLoading(false);
      return;
    }

    const { data: simsData } = await supabase
      .from("sim_cards")
      .select("*")
      .limit(10000);

    const map = new Map<string, SimCard>();
    for (const s of simsData ?? []) {
      if (s.machine_id) map.set(s.machine_id, s as SimCard);
    }

    setSimMap(map);
    setMachines((machinesData ?? []) as Machine[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  // CC-Article-1 (B.x.3): refill flag flips through canonical RPC
  // toggle_machine_refill(p_machine_name text, p_include boolean) — A.5b-patched
  // (sets app.via_rpc, writes write_audit_log row).
  const handleRefillToggle = useCallback(
    async (machineId: string, value: boolean) => {
      // Look up official_name for this machine_id (RPC is keyed by name, not id)
      const target = machines.find((m) => m.machine_id === machineId);
      if (!target) {
        showToast("Machine not found.", "error");
        return;
      }

      // Optimistic update
      setMachines((prev) =>
        prev.map((m) =>
          m.machine_id === machineId ? { ...m, include_in_refill: value } : m,
        ),
      );

      const supabase = createClient();
      const { error: rpcError } = await supabase.rpc("toggle_machine_refill", {
        p_machine_name: target.official_name,
        p_include: value,
      });

      if (rpcError) {
        // Revert on failure
        setMachines((prev) =>
          prev.map((m) =>
            m.machine_id === machineId
              ? { ...m, include_in_refill: !value }
              : m,
          ),
        );
        showToast("Failed to update refill flag.", "error");
      }
    },
    [machines, showToast],
  );

  const handleBulkAction = useCallback(
    async (action: BulkAction, machineIds: string[]) => {
      if (machineIds.length === 0) return;

      if (action === "export_csv") {
        const selected = machines.filter((m) =>
          machineIds.includes(m.machine_id),
        );
        const headers = [
          "machine_id",
          "official_name",
          "pod_number",
          "status",
          "venue_group",
          "pod_location",
          "pod_address",
          "include_in_refill",
          "installation_date",
          "adyen_status",
          "permit_expiry_date",
          "notes",
        ];
        const rows = selected.map((m) =>
          headers
            .map((h) => {
              const val = m[h as keyof Machine];
              if (val === null || val === undefined) return "";
              const str = String(val);
              return str.includes(",") ||
                str.includes('"') ||
                str.includes("\n")
                ? `"${str.replace(/"/g, '""')}"`
                : str;
            })
            .join(","),
        );
        const csv = [headers.join(","), ...rows].join("\n");
        const blob = new Blob([csv], { type: "text/csv" });
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = `machines_export_${new Date().toISOString().slice(0, 10)}.csv`;
        a.click();
        URL.revokeObjectURL(url);
        showToast(`Exported ${selected.length} machines as CSV.`, "success");
        return;
      }

      const supabase = createClient();

      if (action === "set_active" || action === "set_inactive") {
        const newStatus = action === "set_active" ? "Active" : "Inactive";
        const { error: updateError } = await supabase
          .from("machines")
          .update({ status: newStatus })
          .in("machine_id", machineIds);

        if (updateError) {
          showToast("Bulk status update failed.", "error");
          return;
        }
        setMachines((prev) =>
          prev.map((m) =>
            machineIds.includes(m.machine_id) ? { ...m, status: newStatus } : m,
          ),
        );
        showToast(
          `${machineIds.length} machine(s) set to ${newStatus}.`,
          "success",
        );
      }

      if (action === "toggle_refill") {
        // CC-Article-1 (B.x.3): bulk refill toggle now fans out per-row to the
        // canonical toggle_machine_refill RPC. There is no bulk RPC variant
        // today — Promise.all is acceptable for current fleet size (~50 rows
        // worst case). If the fleet grows past O(100), file a follow-up to
        // design a bulk variant (Dara → Cody).
        const firstMachine = machines.find((m) =>
          machineIds.includes(m.machine_id),
        );
        const newVal = !(firstMachine?.include_in_refill ?? false);
        const targets = machines.filter((m) =>
          machineIds.includes(m.machine_id),
        );

        const results = await Promise.allSettled(
          targets.map((m) =>
            supabase.rpc("toggle_machine_refill", {
              p_machine_name: m.official_name,
              p_include: newVal,
            }),
          ),
        );

        const succeededIds = targets
          .filter(
            (_, i) =>
              results[i].status === "fulfilled" &&
              !(results[i] as PromiseFulfilledResult<{ error: unknown }>).value
                .error,
          )
          .map((m) => m.machine_id);

        const failedCount = machineIds.length - succeededIds.length;

        if (succeededIds.length > 0) {
          setMachines((prev) =>
            prev.map((m) =>
              succeededIds.includes(m.machine_id)
                ? { ...m, include_in_refill: newVal }
                : m,
            ),
          );
        }

        if (failedCount > 0) {
          showToast(
            `${succeededIds.length} updated, ${failedCount} failed.`,
            "error",
          );
        } else {
          showToast(
            `${succeededIds.length} machine(s) refill ${newVal ? "enabled" : "disabled"}.`,
            "success",
          );
        }
      }
    },
    [machines, showToast],
  );

  const handleSave = useCallback(
    async (machineId: string, updates: Partial<Machine>) => {
      const supabase = createClient();
      const { error: updateError } = await supabase
        .from("machines")
        .update(updates)
        .eq("machine_id", machineId);

      if (updateError) {
        showToast("Failed to save machine.", "error");
        return;
      }

      setMachines((prev) =>
        prev.map((m) =>
          m.machine_id === machineId ? { ...m, ...updates } : m,
        ),
      );
      showToast("Machine saved.", "success");
      setEditMachineId(null);
    },
    [showToast],
  );

  // CC-Article-1 (B.x.3): open the Repurpose dialog with a fresh form, seeded
  // with the current machine's identity so the operator just edits the diff.
  const openRepurpose = useCallback(
    (machineId: string) => {
      const m = machines.find((x) => x.machine_id === machineId);
      if (!m) return;
      setRepurposeValues({
        official_name: "",
        pod_location: m.pod_location ?? "",
        location_type: (m.location_type ?? "coworking").toLowerCase(),
        building_id: m.building_id ?? "",
        source_of_supply: m.source_of_supply ?? "BOONZ",
        venue_group: m.venue_group ?? "INDEPENDENT",
      });
      setRepurposeStep("form");
      setRepurposeResult(null);
      setRepurposeError(null);
      setRepurposeMachineId(machineId);
    },
    [machines],
  );

  // CC-Article-1 (B.x.3): canonical repurpose path. Mirrors the field-PWA
  // implementation at src/app/(field)/field/config/machines/page.tsx:577.
  // Calls the repurpose-machine edge function which fronts repurpose_machine()
  // RPC. The RPC creates a new machines row, archives slot lifecycle, and
  // wires machine_name_aliases for WEIMI continuity.
  const handleRepurposeMachine = useCallback(async () => {
    if (!repurposeMachineId || !repurposeValues.official_name.trim()) return;
    setRepurposing(true);
    setRepurposeError(null);
    const supabase = createClient();
    try {
      const { data, error: fnError } = await supabase.functions.invoke(
        "repurpose-machine",
        {
          body: {
            p_old_machine_id: repurposeMachineId,
            p_new_official_name: repurposeValues.official_name.trim(),
            p_new_pod_location: repurposeValues.pod_location.trim() || null,
            p_new_location_type: repurposeValues.location_type,
            p_new_building_id: repurposeValues.building_id.trim() || null,
            p_new_source_of_supply: repurposeValues.source_of_supply || null,
            p_new_venue_group: repurposeValues.venue_group,
          },
        },
      );

      if (fnError) {
        // The edge function may return a JSON-encoded error.message — unwrap.
        let msg = fnError.message ?? "Unknown error";
        try {
          const parsed = JSON.parse(msg);
          msg = parsed.error ?? msg;
        } catch {
          /* not JSON, use as-is */
        }
        setRepurposeError(msg);
        setRepurposing(false);
        return;
      }

      const row = (Array.isArray(data) ? data[0] : data) as RepurposeResult;
      setRepurposeResult(row);
      setRepurposeStep("done");
      // Close the edit panel — the underlying machine_id is now archived,
      // operator should review the freshly-created row in the table.
      setEditMachineId(null);
      await fetchData();
    } catch (err: unknown) {
      setRepurposeError(
        err instanceof Error ? err.message : "Network error",
      );
    }
    setRepurposing(false);
  }, [repurposeMachineId, repurposeValues, fetchData]);

  const editMachine = editMachineId
    ? (machines.find((m) => m.machine_id === editMachineId) ?? null)
    : null;

  return (
    <div className="min-h-screen bg-[#0a0a0f] text-neutral-200">
      <div className="mx-auto max-w-[1600px] px-4 py-8 sm:px-6 lg:px-8">
        {/* Top bar */}
        <div className="mb-6 flex items-center justify-between gap-4 flex-wrap">
          <div>
            <h1 className="font-mono text-2xl font-bold tracking-tight text-neutral-100">
              Machine Fleet
            </h1>
            {!loading && !error && (
              <p className="mt-1 text-sm text-neutral-500">
                {machines.length} machine{machines.length !== 1 ? "s" : ""}
              </p>
            )}
          </div>
          <div className="flex items-center gap-3">
            <button
              onClick={() => setShowInsights((v) => !v)}
              className="rounded border border-neutral-700 px-3 py-1.5 text-xs text-neutral-400 hover:border-neutral-500 hover:text-neutral-200 transition-colors"
            >
              {showInsights ? "Collapse Insights" : "Expand Insights"}
            </button>
          </div>
        </div>

        {/* Loading skeleton */}
        {loading && (
          <div className="space-y-3">
            {/* Insights skeleton */}
            <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
              {[...Array(4)].map((_, i) => (
                <div
                  key={i}
                  className="h-24 animate-pulse rounded-lg border border-neutral-800 bg-neutral-800/40"
                />
              ))}
            </div>
            {/* Table skeleton */}
            <div className="space-y-2 rounded-lg border border-neutral-800 bg-[#0f0f18] p-4 mt-4">
              {[...Array(5)].map((_, i) => (
                <div
                  key={i}
                  className="h-9 animate-pulse rounded bg-neutral-800/60"
                  style={{ opacity: 1 - i * 0.15 }}
                />
              ))}
            </div>
          </div>
        )}

        {/* Error state */}
        {!loading && error && (
          <div className="flex flex-col items-center gap-4 rounded-lg border border-red-800/50 bg-red-900/20 p-10 text-center">
            <p className="text-sm text-red-300">{error}</p>
            <button
              onClick={fetchData}
              className="rounded border border-neutral-700 px-4 py-2 text-sm text-neutral-300 hover:border-neutral-500 hover:text-white"
            >
              Retry
            </button>
          </div>
        )}

        {/* Main content */}
        {!loading && !error && (
          <div className="space-y-6">
            {/* Collapsible Insights */}
            {showInsights && (
              <MachineInsights machines={machines} simMap={simMap} />
            )}

            {/* Machine Table */}
            <MachineTable
              machines={machines}
              simMap={simMap}
              onEdit={(id) => setEditMachineId(id)}
              onRefillToggle={handleRefillToggle}
              onBulkAction={handleBulkAction}
            />
          </div>
        )}
      </div>

      {/* Edit slide-over panel */}
      {editMachineId !== null && editMachine !== null && (
        <MachineEditPanel
          machine={editMachine}
          onSave={handleSave}
          onClose={() => setEditMachineId(null)}
          onSimChange={fetchData}
          onRepurpose={openRepurpose}
        />
      )}

      {/* Toast notification */}
      {toast && (
        <div
          className={`fixed bottom-6 right-6 z-50 flex items-center gap-2 rounded-lg border px-4 py-3 text-sm shadow-xl transition-all ${
            toast.type === "success"
              ? "border-emerald-700/50 bg-emerald-900/80 text-emerald-200"
              : "border-red-700/50 bg-red-900/80 text-red-200"
          }`}
        >
          <span>{toast.type === "success" ? "✓" : "✗"}</span>
          <span>{toast.message}</span>
        </div>
      )}

      {/* CC-Article-1 (B.x.3): Repurpose dialog. Identity-shape mutations on
          the machines table route through repurpose-machine edge fn →
          repurpose_machine RPC. Three-step flow: form → confirm → done.
          z-[150] sits above the MachineEditPanel slide-over (z-[100]/z-[101])
          so the dialog can be opened from inside the slide-over. */}
      {repurposeMachineId && (
        <div className="fixed inset-0 z-[150] flex items-center justify-center p-4">
          <div
            className="absolute inset-0 bg-black/70 backdrop-blur-sm"
            onClick={() => {
              if (!repurposing) setRepurposeMachineId(null);
            }}
          />
          <div className="relative z-10 w-full max-w-lg rounded-lg border border-neutral-700 bg-[#0f0f18] p-6 shadow-2xl max-h-[90vh] overflow-y-auto">
            {repurposeStep === "done" && repurposeResult ? (
              <div>
                <h3 className="mb-4 text-base font-semibold text-emerald-400">
                  Repurpose complete ✓
                </h3>
                <div className="space-y-2 text-sm text-neutral-300">
                  <p>
                    Old machine archived:{" "}
                    <span className="font-mono text-xs text-neutral-500">
                      {repurposeResult.old_machine_id}
                    </span>
                  </p>
                  <p>
                    New machine created:{" "}
                    <span className="font-mono text-xs text-neutral-500">
                      {repurposeResult.new_machine_id}
                    </span>
                  </p>
                  <p>
                    Slot lifecycle rows archived:{" "}
                    <strong className="text-neutral-100">
                      {repurposeResult.slots_archived}
                    </strong>
                  </p>
                  <p>
                    WEIMI aliases wired:{" "}
                    <strong className="text-neutral-100">
                      {repurposeResult.aliases_wired}
                    </strong>{" "}
                    <span className="text-xs text-neutral-500">
                      (old + new name → correct UUID)
                    </span>
                  </p>
                </div>
                <button
                  onClick={() => setRepurposeMachineId(null)}
                  className="mt-6 w-full rounded border border-neutral-700 bg-neutral-800 py-2.5 text-sm font-medium text-neutral-200 hover:bg-neutral-700"
                >
                  Done
                </button>
              </div>
            ) : repurposeStep === "confirm" ? (
              <div>
                <h3 className="mb-4 text-base font-semibold text-amber-300">
                  Confirm repurpose
                </h3>
                <div className="mb-4 rounded border border-amber-700/40 bg-amber-900/20 p-3 text-xs text-amber-200/90">
                  <p className="mb-1 font-semibold">
                    This action is irreversible.
                  </p>
                  <p>
                    The current machine will be archived (include_in_refill set
                    to false, status set to Inactive) and all its slot
                    lifecycle scores will be archived. A fresh machine row
                    will be created as{" "}
                    <strong className="text-amber-100">
                      {repurposeValues.official_name}
                    </strong>
                    .
                  </p>
                </div>
                {repurposeError && (
                  <div className="mb-3 rounded border border-red-700/50 bg-red-900/30 px-3 py-2 text-xs text-red-300">
                    {repurposeError}
                  </div>
                )}
                <div className="flex gap-2">
                  <button
                    onClick={handleRepurposeMachine}
                    disabled={repurposing}
                    className="flex-1 rounded bg-amber-700 py-2.5 text-sm font-semibold text-white disabled:opacity-50 hover:bg-amber-600"
                  >
                    {repurposing ? "Repurposing…" : "Confirm repurpose"}
                  </button>
                  <button
                    onClick={() => setRepurposeStep("form")}
                    disabled={repurposing}
                    className="rounded border border-neutral-700 px-5 py-2.5 text-sm font-medium text-neutral-300 disabled:opacity-50 hover:border-neutral-500"
                  >
                    Back
                  </button>
                </div>
              </div>
            ) : (
              <div>
                <h3 className="mb-1 text-base font-semibold text-neutral-100">
                  Repurpose machine
                </h3>
                <p className="mb-4 text-xs text-neutral-500">
                  New identity for{" "}
                  <strong className="text-neutral-300">
                    {
                      machines.find(
                        (m) => m.machine_id === repurposeMachineId,
                      )?.official_name
                    }
                  </strong>
                </p>
                <div className="space-y-3">
                  <div>
                    <label className="mb-1 block text-[11px] font-medium uppercase tracking-wider text-neutral-500">
                      New official name *
                    </label>
                    <input
                      type="text"
                      value={repurposeValues.official_name}
                      onChange={(e) =>
                        setRepurposeValues((p) => ({
                          ...p,
                          official_name: e.target.value,
                        }))
                      }
                      placeholder="e.g. JET-1016-0000-O1"
                      className="w-full rounded border border-neutral-700 bg-[#1a1a2e] px-3 py-2 text-sm text-neutral-200 focus:outline-none focus:border-neutral-500 placeholder:text-neutral-600"
                    />
                  </div>
                  <div>
                    <label className="mb-1 block text-[11px] font-medium uppercase tracking-wider text-neutral-500">
                      New pod location
                    </label>
                    <input
                      type="text"
                      value={repurposeValues.pod_location}
                      onChange={(e) =>
                        setRepurposeValues((p) => ({
                          ...p,
                          pod_location: e.target.value,
                        }))
                      }
                      className="w-full rounded border border-neutral-700 bg-[#1a1a2e] px-3 py-2 text-sm text-neutral-200 focus:outline-none focus:border-neutral-500"
                    />
                  </div>
                  <div className="grid grid-cols-2 gap-3">
                    <div>
                      <label className="mb-1 block text-[11px] font-medium uppercase tracking-wider text-neutral-500">
                        Location type
                      </label>
                      <select
                        value={repurposeValues.location_type}
                        onChange={(e) =>
                          setRepurposeValues((p) => ({
                            ...p,
                            location_type: e.target.value,
                          }))
                        }
                        className="w-full rounded border border-neutral-700 bg-[#1a1a2e] px-3 py-2 text-sm text-neutral-200 focus:outline-none focus:border-neutral-500"
                      >
                        {REPURPOSE_LOCATION_TYPES.map((t) => (
                          <option key={t} value={t}>
                            {t}
                          </option>
                        ))}
                      </select>
                    </div>
                    <div>
                      <label className="mb-1 block text-[11px] font-medium uppercase tracking-wider text-neutral-500">
                        Source of supply
                      </label>
                      <select
                        value={repurposeValues.source_of_supply}
                        onChange={(e) =>
                          setRepurposeValues((p) => ({
                            ...p,
                            source_of_supply: e.target.value,
                          }))
                        }
                        className="w-full rounded border border-neutral-700 bg-[#1a1a2e] px-3 py-2 text-sm text-neutral-200 focus:outline-none focus:border-neutral-500"
                      >
                        {REPURPOSE_SOURCES_OF_SUPPLY.map((s) => (
                          <option key={s} value={s}>
                            {s}
                          </option>
                        ))}
                      </select>
                    </div>
                  </div>
                  <div className="grid grid-cols-2 gap-3">
                    <div>
                      <label className="mb-1 block text-[11px] font-medium uppercase tracking-wider text-neutral-500">
                        Venue group
                      </label>
                      <select
                        value={repurposeValues.venue_group}
                        onChange={(e) =>
                          setRepurposeValues((p) => ({
                            ...p,
                            venue_group: e.target.value,
                          }))
                        }
                        className="w-full rounded border border-neutral-700 bg-[#1a1a2e] px-3 py-2 text-sm text-neutral-200 focus:outline-none focus:border-neutral-500"
                      >
                        {REPURPOSE_VENUE_GROUPS.map((g) => (
                          <option key={g} value={g}>
                            {g}
                          </option>
                        ))}
                      </select>
                    </div>
                    <div>
                      <label className="mb-1 block text-[11px] font-medium uppercase tracking-wider text-neutral-500">
                        Building ID (optional)
                      </label>
                      <input
                        type="text"
                        value={repurposeValues.building_id}
                        onChange={(e) =>
                          setRepurposeValues((p) => ({
                            ...p,
                            building_id: e.target.value,
                          }))
                        }
                        className="w-full rounded border border-neutral-700 bg-[#1a1a2e] px-3 py-2 text-sm text-neutral-200 focus:outline-none focus:border-neutral-500"
                      />
                    </div>
                  </div>
                </div>
                <div className="mt-5 flex gap-2">
                  <button
                    onClick={() => {
                      if (!repurposeValues.official_name.trim()) return;
                      setRepurposeStep("confirm");
                      setRepurposeError(null);
                    }}
                    disabled={!repurposeValues.official_name.trim()}
                    className="flex-1 rounded bg-amber-700 py-2.5 text-sm font-semibold text-white hover:bg-amber-600 disabled:opacity-40"
                  >
                    Review &amp; confirm
                  </button>
                  <button
                    onClick={() => setRepurposeMachineId(null)}
                    className="rounded border border-neutral-700 px-5 py-2.5 text-sm text-neutral-400 hover:border-neutral-500 hover:text-neutral-200"
                  >
                    Cancel
                  </button>
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
