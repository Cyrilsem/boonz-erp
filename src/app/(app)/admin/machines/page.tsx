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

export default function MachinesPage() {
  const [machines, setMachines] = useState<Machine[]>([]);
  const [simMap, setSimMap] = useState<Map<string, SimCard>>(new Map());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editMachineId, setEditMachineId] = useState<string | null>(null);
  const [toast, setToast] = useState<ToastState | null>(null);
  const [showInsights, setShowInsights] = useState(true);

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

  const handleRefillToggle = useCallback(
    async (machineId: string, value: boolean) => {
      // Optimistic update
      setMachines((prev) =>
        prev.map((m) =>
          m.machine_id === machineId ? { ...m, include_in_refill: value } : m,
        ),
      );

      const supabase = createClient();
      const { error: updateError } = await supabase
        .from("machines")
        .update({ include_in_refill: value })
        .eq("machine_id", machineId);

      if (updateError) {
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
    [showToast],
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
        // Determine current state of first selected and flip all to opposite
        const firstMachine = machines.find((m) =>
          machineIds.includes(m.machine_id),
        );
        const newVal = !(firstMachine?.include_in_refill ?? false);

        const { error: updateError } = await supabase
          .from("machines")
          .update({ include_in_refill: newVal })
          .in("machine_id", machineIds);

        if (updateError) {
          showToast("Bulk refill toggle failed.", "error");
          return;
        }
        setMachines((prev) =>
          prev.map((m) =>
            machineIds.includes(m.machine_id)
              ? { ...m, include_in_refill: newVal }
              : m,
          ),
        );
        showToast(
          `${machineIds.length} machine(s) refill ${newVal ? "enabled" : "disabled"}.`,
          "success",
        );
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
    </div>
  );
}
