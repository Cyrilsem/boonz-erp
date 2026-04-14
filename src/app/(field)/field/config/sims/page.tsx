"use client";

export const dynamic = "force-dynamic";

import { useEffect, useState, useCallback } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { FieldHeader } from "../../../components/field-header";
import { SimCardTable } from "@/components/config/SimCardTable";
import { SimCardDrawer } from "@/components/config/SimCardDrawer";
import { getDubaiDate } from "@/lib/utils/date";
import type { SimCard } from "@/types/machines";

const CONFIG_ROLES = ["operator_admin", "superadmin", "manager", "warehouse"];

interface MachineOption {
  machine_id: string;
  official_name: string;
}

// Assign-to-machine modal
function AssignModal({
  sim,
  machines,
  onClose,
  onAssigned,
}: {
  sim: SimCard;
  machines: MachineOption[];
  onClose: () => void;
  onAssigned: () => void;
}) {
  const [machineId, setMachineId] = useState(sim.machine_id ?? "");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSave() {
    setSaving(true);
    setError(null);
    const supabase = createClient();
    const selectedMachine = machines.find((m) => m.machine_id === machineId);
    const { error: dbErr } = await supabase
      .from("sim_cards")
      .update({
        machine_id: machineId || null,
        machine_name: selectedMachine?.official_name ?? null,
      })
      .eq("sim_id", sim.sim_id);
    setSaving(false);
    if (dbErr) {
      setError(dbErr.message);
    } else {
      onAssigned();
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex flex-col justify-end">
      <div className="absolute inset-0 bg-black/50" onClick={onClose} />
      <div className="relative z-10 rounded-t-3xl bg-white px-4 pb-10 pt-5">
        <h3 className="mb-3 text-center text-base font-bold">
          Assign SIM — {sim.sim_ref}
        </h3>
        {error && (
          <p className="mb-2 rounded-lg bg-red-50 px-3 py-2 text-xs text-red-700">
            {error}
          </p>
        )}
        <label className="mb-1 block text-xs text-gray-500">Machine</label>
        <select
          value={machineId}
          onChange={(e) => setMachineId(e.target.value)}
          className="mb-4 w-full rounded-lg border border-gray-200 px-3 py-2 text-sm"
        >
          <option value="">— unassigned —</option>
          {machines.map((m) => (
            <option key={m.machine_id} value={m.machine_id}>
              {m.official_name}
            </option>
          ))}
        </select>
        <button
          onClick={handleSave}
          disabled={saving}
          className="w-full rounded-2xl bg-blue-600 py-3 text-sm font-semibold text-white disabled:opacity-50"
        >
          {saving ? "Saving…" : "Save Assignment"}
        </button>
      </div>
    </div>
  );
}

export default function SimsPage() {
  const router = useRouter();
  const [sims, setSims] = useState<SimCard[]>([]);
  const [machines, setMachines] = useState<MachineOption[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [showDrawer, setShowDrawer] = useState(false);
  const [editSim, setEditSim] = useState<SimCard | null>(null);
  const [assignSim, setAssignSim] = useState<SimCard | null>(null);

  const todayStr = getDubaiDate();

  const fetchData = useCallback(async () => {
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (!user) {
      router.push("/login");
      return;
    }
    const { data: profile } = await supabase
      .from("user_profiles")
      .select("role")
      .eq("id", user.id)
      .single();
    if (!profile || !CONFIG_ROLES.includes(profile.role)) {
      router.push("/field");
      return;
    }

    const [{ data: simData }, { data: machineData }] = await Promise.all([
      supabase
        .from("sim_cards")
        .select(
          "sim_id,sim_ref,sim_serial,sim_code,sim_date,sim_renewal,contact_number,puk1,puk2,paid_by,machine_id,machine_name,is_active,notes,created_at,updated_at",
        )
        .order("sim_ref", { ascending: true })
        .limit(10000),
      supabase
        .from("machines")
        .select("machine_id,official_name")
        .order("official_name", { ascending: true })
        .limit(10000),
    ]);

    setSims((simData as SimCard[]) ?? []);
    setMachines((machineData as MachineOption[]) ?? []);
    setLoading(false);
  }, [router]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  // Expiry banner: sims expiring within 30 days or already expired
  const expiringSoon = sims.filter((s) => {
    if (!s.sim_renewal) return false;
    const diff =
      new Date(s.sim_renewal).getTime() - new Date(todayStr).getTime();
    const days = diff / (1000 * 60 * 60 * 24);
    return days <= 30;
  });

  const filtered = sims.filter(
    (s) =>
      !search ||
      (s.sim_ref ?? "").toLowerCase().includes(search.toLowerCase()) ||
      (s.machine_name ?? "").toLowerCase().includes(search.toLowerCase()) ||
      (s.sim_serial ?? "").toLowerCase().includes(search.toLowerCase()),
  );

  function openEdit(sim: SimCard) {
    setEditSim(sim);
    setShowDrawer(true);
  }

  function openAdd() {
    setEditSim(null);
    setShowDrawer(true);
  }

  function handleAssignToggle(sim: SimCard) {
    setAssignSim(sim);
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="SIM Cards" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading…</p>
        </div>
      </>
    );
  }

  return (
    <div className="pb-24">
      <FieldHeader
        title="SIM Cards"
        rightAction={
          <button
            onClick={openAdd}
            className="rounded-lg bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white"
          >
            + Add
          </button>
        }
      />

      <div className="px-4 py-4">
        {/* Expiry banner */}
        {expiringSoon.length > 0 && (
          <div className="mb-4 rounded-xl bg-amber-50 px-4 py-3 text-sm text-amber-800">
            <strong>
              {expiringSoon.length} SIM{expiringSoon.length > 1 ? "s" : ""}
            </strong>{" "}
            expiring within 30 days or overdue:{" "}
            {expiringSoon.map((s) => s.sim_ref).join(", ")}
          </div>
        )}

        {/* Search */}
        <input
          type="search"
          placeholder="Search SIM ref, machine, serial…"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="mb-4 w-full rounded-lg border border-gray-200 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none"
        />

        <SimCardTable
          sims={filtered}
          todayStr={todayStr}
          onEdit={openEdit}
          onAssignToggle={handleAssignToggle}
        />
      </div>

      {showDrawer && (
        <SimCardDrawer
          sim={editSim}
          machines={machines}
          onClose={() => setShowDrawer(false)}
          onSaved={() => {
            setShowDrawer(false);
            fetchData();
          }}
        />
      )}

      {assignSim && (
        <AssignModal
          sim={assignSim}
          machines={machines}
          onClose={() => setAssignSim(null)}
          onAssigned={() => {
            setAssignSim(null);
            fetchData();
          }}
        />
      )}
    </div>
  );
}
