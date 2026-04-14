"use client";

import { useState, useEffect } from "react";
import { createClient } from "@/lib/supabase/client";
import type { SimCard } from "@/types/machines";

interface MachineOption {
  machine_id: string;
  official_name: string;
}

interface SimCardDrawerProps {
  sim: SimCard | null; // null = new
  machines: MachineOption[];
  onClose: () => void;
  onSaved: () => void;
}

interface SimDraft {
  sim_ref: string;
  sim_serial: string;
  sim_code: string;
  sim_date: string;
  sim_renewal: string;
  contact_number: string;
  puk1: string;
  puk2: string;
  paid_by: string;
  machine_id: string;
  is_active: boolean;
  notes: string;
}

function emptyDraft(): SimDraft {
  return {
    sim_ref: "",
    sim_serial: "",
    sim_code: "",
    sim_date: "",
    sim_renewal: "",
    contact_number: "",
    puk1: "",
    puk2: "",
    paid_by: "",
    machine_id: "",
    is_active: true,
    notes: "",
  };
}

function simToDraft(sim: SimCard): SimDraft {
  return {
    sim_ref: sim.sim_ref ?? "",
    sim_serial: sim.sim_serial ?? "",
    sim_code: sim.sim_code ?? "",
    sim_date: sim.sim_date ?? "",
    sim_renewal: sim.sim_renewal ?? "",
    contact_number: sim.contact_number ?? "",
    puk1: sim.puk1 ?? "",
    puk2: sim.puk2 ?? "",
    paid_by: sim.paid_by ?? "",
    machine_id: sim.machine_id ?? "",
    is_active: sim.is_active ?? true,
    notes: sim.notes ?? "",
  };
}

const PAID_BY_OPTIONS = ["", "Boonz", "Client", "Other"];

export function SimCardDrawer({
  sim,
  machines,
  onClose,
  onSaved,
}: SimCardDrawerProps) {
  const [draft, setDraft] = useState<SimDraft>(emptyDraft);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setDraft(sim ? simToDraft(sim) : emptyDraft());
    setError(null);
  }, [sim]);

  function patch(p: Partial<SimDraft>) {
    setDraft((prev) => ({ ...prev, ...p }));
  }

  async function handleSave() {
    if (!draft.sim_ref.trim()) {
      setError("SIM Ref is required");
      return;
    }
    setSaving(true);
    setError(null);
    const supabase = createClient();

    const payload = {
      sim_ref: draft.sim_ref.trim(),
      sim_serial: draft.sim_serial.trim() || null,
      sim_code: draft.sim_code.trim() || null,
      sim_date: draft.sim_date || null,
      sim_renewal: draft.sim_renewal || null,
      contact_number: draft.contact_number.trim() || null,
      puk1: draft.puk1.trim() || null,
      puk2: draft.puk2.trim() || null,
      paid_by: draft.paid_by || null,
      machine_id: draft.machine_id || null,
      machine_name: draft.machine_id
        ? (machines.find((m) => m.machine_id === draft.machine_id)
            ?.official_name ?? null)
        : null,
      is_active: draft.is_active,
      notes: draft.notes.trim() || null,
    };

    let dbError;
    if (sim) {
      // update
      const res = await supabase
        .from("sim_cards")
        .update(payload)
        .eq("sim_id", sim.sim_id);
      dbError = res.error;
    } else {
      // insert — upsert on sim_ref
      const res = await supabase
        .from("sim_cards")
        .upsert(payload, { onConflict: "sim_ref" });
      dbError = res.error;
    }

    setSaving(false);
    if (dbError) {
      setError(dbError.message);
    } else {
      onSaved();
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex flex-col justify-end">
      <div className="absolute inset-0 bg-black/50" onClick={onClose} />
      <div className="relative z-10 max-h-[92vh] overflow-y-auto rounded-t-3xl bg-white px-4 pb-10 pt-5">
        <h3 className="mb-4 text-center text-base font-bold">
          {sim ? "Edit SIM Card" : "Add SIM Card"}
        </h3>

        {error && (
          <div className="mb-3 rounded-lg bg-red-50 px-3 py-2 text-xs text-red-700">
            {error}
          </div>
        )}

        <Field label="SIM Ref *">
          <input
            type="text"
            value={draft.sim_ref}
            onChange={(e) => patch({ sim_ref: e.target.value })}
            className={inputCls}
            placeholder="e.g. SIM-001"
          />
        </Field>

        <Field label="Serial (ICCID)">
          <input
            type="text"
            value={draft.sim_serial}
            onChange={(e) => patch({ sim_serial: e.target.value })}
            className={inputCls}
            placeholder="19-digit ICCID"
          />
        </Field>

        <Field label="Plan Code">
          <input
            type="text"
            value={draft.sim_code}
            onChange={(e) => patch({ sim_code: e.target.value })}
            className={inputCls}
          />
        </Field>

        <div className="flex gap-3">
          <div className="flex-1">
            <Field label="Activation Date">
              <input
                type="date"
                value={draft.sim_date}
                onChange={(e) => patch({ sim_date: e.target.value })}
                className={inputCls}
              />
            </Field>
          </div>
          <div className="flex-1">
            <Field label="Renewal Date">
              <input
                type="date"
                value={draft.sim_renewal}
                onChange={(e) => patch({ sim_renewal: e.target.value })}
                className={inputCls}
              />
            </Field>
          </div>
        </div>

        <Field label="Contact Number">
          <input
            type="text"
            value={draft.contact_number}
            onChange={(e) => patch({ contact_number: e.target.value })}
            className={inputCls}
          />
        </Field>

        <div className="flex gap-3">
          <div className="flex-1">
            <Field label="PUK 1">
              <input
                type="text"
                value={draft.puk1}
                onChange={(e) => patch({ puk1: e.target.value })}
                className={inputCls}
              />
            </Field>
          </div>
          <div className="flex-1">
            <Field label="PUK 2">
              <input
                type="text"
                value={draft.puk2}
                onChange={(e) => patch({ puk2: e.target.value })}
                className={inputCls}
              />
            </Field>
          </div>
        </div>

        <Field label="Paid By">
          <select
            value={draft.paid_by}
            onChange={(e) => patch({ paid_by: e.target.value })}
            className={inputCls}
          >
            {PAID_BY_OPTIONS.map((o) => (
              <option key={o} value={o}>
                {o || "— not set —"}
              </option>
            ))}
          </select>
        </Field>

        <Field label="Assigned Machine">
          <select
            value={draft.machine_id}
            onChange={(e) => patch({ machine_id: e.target.value })}
            className={inputCls}
          >
            <option value="">— unassigned —</option>
            {machines.map((m) => (
              <option key={m.machine_id} value={m.machine_id}>
                {m.official_name}
              </option>
            ))}
          </select>
        </Field>

        <Field label="Notes">
          <textarea
            value={draft.notes}
            onChange={(e) => patch({ notes: e.target.value })}
            rows={3}
            className={`${inputCls} resize-none`}
          />
        </Field>

        <label className="mb-4 flex items-center justify-between">
          <span className="text-sm text-gray-700">Active</span>
          <div
            role="switch"
            aria-checked={draft.is_active}
            onClick={() => patch({ is_active: !draft.is_active })}
            className={`relative inline-flex h-6 w-11 cursor-pointer items-center rounded-full transition-colors ${
              draft.is_active ? "bg-blue-600" : "bg-gray-200"
            }`}
          >
            <span
              className={`inline-block h-4 w-4 rounded-full bg-white shadow transition-transform ${
                draft.is_active ? "translate-x-6" : "translate-x-1"
              }`}
            />
          </div>
        </label>

        <button
          onClick={handleSave}
          disabled={saving}
          className="w-full rounded-2xl bg-blue-600 py-3 text-sm font-semibold text-white disabled:opacity-50"
        >
          {saving ? "Saving…" : sim ? "Save Changes" : "Add SIM Card"}
        </button>
      </div>
    </div>
  );
}

const inputCls =
  "w-full rounded-lg border border-gray-200 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none";

function Field({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="mb-3">
      <label className="mb-0.5 block text-xs text-gray-500">{label}</label>
      {children}
    </div>
  );
}
