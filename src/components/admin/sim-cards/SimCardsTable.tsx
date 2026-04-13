"use client";

import { useState, useEffect, useCallback, useMemo } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Machine, SimCard } from "@/types/machines";

interface SimCardsTableProps {
  sims: SimCard[];
  machines: Machine[];
  onRefresh: () => void;
}

type FilterTab = "all" | "linked" | "unassigned" | "expiring" | "expired";

const INPUT_CLS =
  "bg-[#1a1a2e] border border-neutral-700 rounded px-2 py-1 text-xs text-neutral-200 focus:outline-none focus:border-neutral-500";

function formatDate(dateStr: string | null): string {
  if (!dateStr) return "—";
  const d = new Date(dateStr);
  const months = [
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
  ];
  const dd = String(d.getUTCDate()).padStart(2, "0");
  const mon = months[d.getUTCMonth()];
  const yy = String(d.getUTCFullYear()).slice(-2);
  return `${dd} ${mon} ${yy}`;
}

function daysUntil(dateStr: string | null): number | null {
  if (!dateStr) return null;
  const diff = new Date(dateStr).getTime() - Date.now();
  return Math.ceil(diff / (1000 * 60 * 60 * 24));
}

interface RenewalBadgeProps {
  days: number | null;
}

function RenewalBadge({ days }: RenewalBadgeProps) {
  if (days === null) return <span className="text-neutral-600 text-xs">—</span>;
  if (days <= 0)
    return (
      <span className="inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-bold bg-red-900/60 text-red-300 border border-red-700/50">
        Expired
      </span>
    );
  if (days <= 30)
    return (
      <span className="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold bg-red-900/60 text-red-300 border border-red-700/50">
        ⚠ {days}d
      </span>
    );
  if (days <= 90)
    return (
      <span className="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold bg-amber-900/60 text-amber-300 border border-amber-700/50">
        {days}d
      </span>
    );
  return (
    <span className="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-medium bg-green-900/30 text-green-400 border border-green-800/40">
      <span className="h-1.5 w-1.5 rounded-full bg-green-400 inline-block" />
      {days}d
    </span>
  );
}

interface FormState {
  sim_ref: string;
  sim_serial: string;
  sim_code: string;
  contact_number: string;
  sim_date: string;
  sim_renewal: string;
  machine_id: string;
  is_active: boolean;
}

const EMPTY_FORM: FormState = {
  sim_ref: "",
  sim_serial: "",
  sim_code: "",
  contact_number: "",
  sim_date: "",
  sim_renewal: "",
  machine_id: "",
  is_active: true,
};

function simToForm(s: SimCard): FormState {
  return {
    sim_ref: s.sim_ref ?? "",
    sim_serial: s.sim_serial ?? "",
    sim_code: s.sim_code ?? "",
    contact_number: s.contact_number ?? "",
    sim_date: s.sim_date ? s.sim_date.slice(0, 10) : "",
    sim_renewal: s.sim_renewal ? s.sim_renewal.slice(0, 10) : "",
    machine_id: s.machine_id ?? "",
    is_active: s.is_active ?? true,
  };
}

export default function SimCardsTable({
  sims,
  machines,
  onRefresh,
}: SimCardsTableProps) {
  const [activeTab, setActiveTab] = useState<FilterTab>("all");
  const [showAddForm, setShowAddForm] = useState(false);
  const [editSimId, setEditSimId] = useState<string | null>(null);
  const [form, setForm] = useState<FormState>(EMPTY_FORM);
  const [saving, setSaving] = useState(false);

  const today = useMemo(() => Date.now(), []);

  const expiringSoonCount = useMemo(() => {
    return sims.filter((s) => {
      const d = daysUntil(s.sim_renewal);
      return d !== null && d > 0 && d <= 90;
    }).length;
  }, [sims]);

  const filtered = useMemo(() => {
    switch (activeTab) {
      case "linked":
        return sims.filter((s) => s.machine_id !== null);
      case "unassigned":
        return sims.filter((s) => s.machine_id === null);
      case "expiring": {
        return sims.filter((s) => {
          const d = daysUntil(s.sim_renewal);
          return d !== null && d > 0 && d <= 90;
        });
      }
      case "expired": {
        return sims.filter((s) => {
          const d = daysUntil(s.sim_renewal);
          return d !== null && d <= 0;
        });
      }
      default:
        return sims;
    }
  }, [sims, activeTab]);

  const handleToggleActive = useCallback(
    async (sim: SimCard) => {
      const supabase = createClient();
      await supabase
        .from("sim_cards")
        .update({ is_active: !sim.is_active })
        .eq("sim_id", sim.sim_id);
      onRefresh();
    },
    [onRefresh],
  );

  const handleUnlink = useCallback(
    async (simId: string) => {
      const supabase = createClient();
      await supabase
        .from("sim_cards")
        .update({ machine_id: null, machine_name: null })
        .eq("sim_id", simId);
      onRefresh();
    },
    [onRefresh],
  );

  const handleDelete = useCallback(
    async (simId: string) => {
      if (!confirm("Delete this SIM card? This cannot be undone.")) return;
      const supabase = createClient();
      await supabase.from("sim_cards").delete().eq("sim_id", simId);
      onRefresh();
    },
    [onRefresh],
  );

  const openAdd = useCallback(() => {
    setEditSimId(null);
    setForm(EMPTY_FORM);
    setShowAddForm(true);
  }, []);

  const openEdit = useCallback((sim: SimCard) => {
    setShowAddForm(false);
    setEditSimId(sim.sim_id);
    setForm(simToForm(sim));
  }, []);

  const handleCancel = useCallback(() => {
    setShowAddForm(false);
    setEditSimId(null);
    setForm(EMPTY_FORM);
  }, []);

  const handleSave = useCallback(async () => {
    setSaving(true);
    const supabase = createClient();

    const linkedMachine = machines.find(
      (m) => m.machine_id === form.machine_id,
    );

    const payload = {
      sim_ref: form.sim_ref || null,
      sim_serial: form.sim_serial || null,
      sim_code: form.sim_code || null,
      contact_number: form.contact_number || null,
      sim_date: form.sim_date || null,
      sim_renewal: form.sim_renewal || null,
      machine_id: form.machine_id || null,
      machine_name: linkedMachine?.official_name ?? null,
      is_active: form.is_active,
    };

    if (editSimId) {
      await supabase.from("sim_cards").update(payload).eq("sim_id", editSimId);
    } else {
      await supabase.from("sim_cards").insert(payload);
    }

    setSaving(false);
    setShowAddForm(false);
    setEditSimId(null);
    setForm(EMPTY_FORM);
    onRefresh();
  }, [form, editSimId, machines, onRefresh]);

  const tabs: { id: FilterTab; label: string }[] = [
    { id: "all", label: "All" },
    { id: "linked", label: "Linked" },
    { id: "unassigned", label: "Unassigned" },
    { id: "expiring", label: "Expiring Soon (<90d)" },
    { id: "expired", label: "Expired" },
  ];

  function FormRow() {
    return (
      <tr className="bg-[#1a1a2e] border-t border-neutral-700">
        <td className="px-3 py-2">
          <input
            className={INPUT_CLS}
            placeholder="Ref"
            value={form.sim_ref}
            onChange={(e) =>
              setForm((f) => ({ ...f, sim_ref: e.target.value }))
            }
          />
        </td>
        <td className="px-3 py-2">
          <input
            className={INPUT_CLS}
            placeholder="Serial"
            value={form.sim_serial}
            onChange={(e) =>
              setForm((f) => ({ ...f, sim_serial: e.target.value }))
            }
          />
        </td>
        <td className="px-3 py-2">
          <input
            className={INPUT_CLS}
            placeholder="Code"
            value={form.sim_code}
            onChange={(e) =>
              setForm((f) => ({ ...f, sim_code: e.target.value }))
            }
          />
        </td>
        <td className="px-3 py-2">
          <input
            className={INPUT_CLS}
            placeholder="Contact #"
            value={form.contact_number}
            onChange={(e) =>
              setForm((f) => ({ ...f, contact_number: e.target.value }))
            }
          />
        </td>
        <td className="px-3 py-2">
          <input
            type="date"
            className={INPUT_CLS}
            value={form.sim_date}
            onChange={(e) =>
              setForm((f) => ({ ...f, sim_date: e.target.value }))
            }
          />
        </td>
        <td className="px-3 py-2">
          <input
            type="date"
            className={INPUT_CLS}
            value={form.sim_renewal}
            onChange={(e) =>
              setForm((f) => ({ ...f, sim_renewal: e.target.value }))
            }
          />
        </td>
        <td className="px-3 py-2">
          <select
            className={INPUT_CLS}
            value={form.machine_id}
            onChange={(e) =>
              setForm((f) => ({ ...f, machine_id: e.target.value }))
            }
          >
            <option value="">Unassigned</option>
            {machines.map((m) => (
              <option key={m.machine_id} value={m.machine_id}>
                {m.official_name}
              </option>
            ))}
          </select>
        </td>
        <td className="px-3 py-2 text-center">
          <input
            type="checkbox"
            checked={form.is_active}
            onChange={(e) =>
              setForm((f) => ({ ...f, is_active: e.target.checked }))
            }
            className="accent-emerald-500"
          />
        </td>
        <td className="px-3 py-2">
          <div className="flex items-center gap-2">
            <button
              onClick={handleSave}
              disabled={saving}
              className="rounded bg-emerald-700 px-2.5 py-1 text-[11px] font-semibold text-white hover:bg-emerald-600 disabled:opacity-50"
            >
              {saving ? "Saving…" : "Save"}
            </button>
            <button
              onClick={handleCancel}
              className="rounded border border-neutral-700 px-2.5 py-1 text-[11px] text-neutral-400 hover:text-neutral-200"
            >
              Cancel
            </button>
          </div>
        </td>
      </tr>
    );
  }

  return (
    <div className="space-y-4">
      {/* Expiry banner */}
      {expiringSoonCount > 0 && (
        <div className="flex items-center gap-2 rounded-lg border border-amber-700/50 bg-amber-900/20 px-4 py-2.5 text-sm text-amber-300">
          <span>⚠</span>
          <span>
            <strong>{expiringSoonCount}</strong> SIM(s) expiring within 90 days
          </span>
        </div>
      )}

      {/* Header row: tabs + Add button */}
      <div className="flex items-center justify-between gap-2 flex-wrap">
        <div className="flex gap-1 flex-wrap">
          {tabs.map((t) => (
            <button
              key={t.id}
              onClick={() => setActiveTab(t.id)}
              className={`rounded px-3 py-1.5 text-xs font-medium transition-colors ${
                activeTab === t.id
                  ? "bg-neutral-700 text-neutral-100"
                  : "text-neutral-500 hover:text-neutral-300"
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>
        <button
          onClick={openAdd}
          className="rounded bg-indigo-700 px-3 py-1.5 text-xs font-semibold text-white hover:bg-indigo-600"
        >
          + Add SIM
        </button>
      </div>

      {/* Table */}
      <div className="overflow-x-auto rounded-lg border border-neutral-800">
        <table className="w-full text-sm">
          <thead>
            <tr className="bg-[#0f0f18] border-b border-neutral-800">
              {[
                "SIM Ref",
                "Serial",
                "Code",
                "Contact #",
                "Activated",
                "Renewal",
                "Linked Machine",
                "Active",
                "Actions",
              ].map((h) => (
                <th
                  key={h}
                  className="px-3 py-2.5 text-left text-[10px] font-medium uppercase tracking-wider text-neutral-500 whitespace-nowrap"
                >
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {/* Inline add form row at top */}
            {showAddForm && <FormRow />}

            {filtered.length === 0 && !showAddForm && (
              <tr>
                <td
                  colSpan={9}
                  className="px-4 py-10 text-center text-sm text-neutral-600"
                >
                  No SIM cards found.
                </td>
              </tr>
            )}

            {filtered.map((sim, idx) => {
              const isEditing = editSimId === sim.sim_id;
              const days = daysUntil(sim.sim_renewal);
              const serial = sim.sim_serial ?? "";
              const serialDisplay =
                serial.length > 8 ? "…" + serial.slice(-8) : serial;

              if (isEditing) {
                return <FormRow key={sim.sim_id} />;
              }

              return (
                <tr
                  key={sim.sim_id}
                  className={`border-t border-neutral-800/60 transition-colors hover:bg-neutral-900/30 ${
                    idx % 2 === 0 ? "bg-transparent" : "bg-neutral-900/10"
                  }`}
                >
                  <td className="px-3 py-2.5 font-mono text-xs text-neutral-200">
                    {sim.sim_ref ?? "—"}
                  </td>
                  <td
                    className="px-3 py-2.5 font-mono text-xs text-neutral-400 cursor-default"
                    title={serial || undefined}
                  >
                    {serialDisplay || "—"}
                  </td>
                  <td className="px-3 py-2.5 text-xs text-neutral-400">
                    {sim.sim_code ?? "—"}
                  </td>
                  <td className="px-3 py-2.5 text-xs text-neutral-400">
                    {sim.contact_number ?? "—"}
                  </td>
                  <td className="px-3 py-2.5 text-xs text-neutral-400 whitespace-nowrap">
                    {formatDate(sim.sim_date)}
                  </td>
                  <td className="px-3 py-2.5 whitespace-nowrap">
                    <div className="flex flex-col gap-0.5">
                      <span className="text-xs text-neutral-400">
                        {formatDate(sim.sim_renewal)}
                      </span>
                      <RenewalBadge days={days} />
                    </div>
                  </td>
                  <td className="px-3 py-2.5 text-xs">
                    {sim.machine_name ? (
                      <span className="font-mono text-neutral-200">
                        {sim.machine_name}
                      </span>
                    ) : (
                      <span className="text-neutral-600">Unassigned</span>
                    )}
                  </td>
                  <td className="px-3 py-2.5 text-center">
                    <button
                      onClick={() => handleToggleActive(sim)}
                      className={`relative inline-flex h-4 w-7 items-center rounded-full transition-colors ${
                        sim.is_active ? "bg-emerald-600" : "bg-neutral-700"
                      }`}
                      title={
                        sim.is_active
                          ? "Active — click to deactivate"
                          : "Inactive — click to activate"
                      }
                    >
                      <span
                        className={`inline-block h-3 w-3 transform rounded-full bg-white transition-transform ${
                          sim.is_active ? "translate-x-3.5" : "translate-x-0.5"
                        }`}
                      />
                    </button>
                  </td>
                  <td className="px-3 py-2.5">
                    <div className="flex items-center gap-2">
                      <button
                        onClick={() => openEdit(sim)}
                        className="rounded border border-neutral-700 px-2 py-0.5 text-[11px] text-neutral-300 hover:border-neutral-500 hover:text-white"
                      >
                        Edit
                      </button>
                      {sim.machine_id && (
                        <button
                          onClick={() => handleUnlink(sim.sim_id)}
                          className="rounded border border-neutral-700 px-2 py-0.5 text-[11px] text-neutral-400 hover:border-neutral-500 hover:text-neutral-200"
                        >
                          Unlink
                        </button>
                      )}
                      <button
                        onClick={() => handleDelete(sim.sim_id)}
                        className="rounded p-1 text-neutral-600 hover:text-red-400 transition-colors"
                        title="Delete SIM"
                      >
                        <svg
                          xmlns="http://www.w3.org/2000/svg"
                          className="h-3.5 w-3.5"
                          viewBox="0 0 20 20"
                          fill="currentColor"
                        >
                          <path
                            fillRule="evenodd"
                            d="M9 2a1 1 0 00-.894.553L7.382 4H4a1 1 0 000 2v10a2 2 0 002 2h8a2 2 0 002-2V6a1 1 0 100-2h-3.382l-.724-1.447A1 1 0 0011 2H9zM7 8a1 1 0 012 0v6a1 1 0 11-2 0V8zm5-1a1 1 0 00-1 1v6a1 1 0 102 0V8a1 1 0 00-1-1z"
                            clipRule="evenodd"
                          />
                        </svg>
                      </button>
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
