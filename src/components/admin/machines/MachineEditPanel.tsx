"use client";

import { useEffect, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { HW_FIELDS, Machine, PAYMENT_FIELDS, SimCard } from "@/types/machines";

interface MachineEditPanelProps {
  machine: Machine;
  onClose: () => void;
  onSave: (machineId: string, fields: Partial<Machine>) => Promise<void>;
  onSimChange: () => void;
}

const TAB_LABELS = [
  "Overview",
  "Permit & Contact",
  "Adyen & Payment",
  "Hardware & WiFi",
  "SIM Card",
];

const STATUS_OPTIONS = [
  "Active",
  "Inactive",
  "Maintenance",
  "Decommissioned",
  "Pending",
];

const LOCATION_TYPE_OPTIONS = [
  "Office",
  "Coworking",
  "Entertainment",
  "Retail",
  "Warehouse",
  "Other",
];

const PERMIT_STATUS_OPTIONS = ["Active", "Expired", "Pending", "Not Required"];

// ─── helpers ──────────────────────────────────────────────────────────────────

function daysUntil(dateStr: string | null): number | null {
  if (!dateStr) return null;
  const diff = new Date(dateStr).getTime() - Date.now();
  return Math.ceil(diff / (1000 * 60 * 60 * 24));
}

function str(v: string | null | undefined): string {
  return v ?? "";
}

// ─── sub-components ───────────────────────────────────────────────────────────

function Label({ children }: { children: React.ReactNode }) {
  return (
    <label className="block text-xs font-medium text-neutral-500 mb-1 uppercase tracking-wider">
      {children}
    </label>
  );
}

const inputCls =
  "w-full bg-[#1a1a2e] border border-neutral-700 rounded px-3 py-2 text-sm text-neutral-200 focus:outline-none focus:border-neutral-500 placeholder:text-neutral-600";

function TextInput({
  label,
  value,
  onChange,
  placeholder,
  type = "text",
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  type?: string;
}) {
  return (
    <div>
      <Label>{label}</Label>
      <input
        type={type}
        className={inputCls}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder={placeholder}
      />
    </div>
  );
}

function SelectInput({
  label,
  value,
  options,
  onChange,
  allowBlank,
}: {
  label: string;
  value: string;
  options: string[];
  onChange: (v: string) => void;
  allowBlank?: boolean;
}) {
  return (
    <div>
      <Label>{label}</Label>
      <select
        className={inputCls}
        value={value}
        onChange={(e) => onChange(e.target.value)}
      >
        {allowBlank && <option value="">—</option>}
        {options.map((o) => (
          <option key={o} value={o}>
            {o}
          </option>
        ))}
      </select>
    </div>
  );
}

function Toggle({
  label,
  value,
  onChange,
  prominent,
}: {
  label: string;
  value: boolean;
  onChange: (v: boolean) => void;
  prominent?: boolean;
}) {
  return (
    <div
      className={`flex items-center justify-between gap-3 ${prominent ? "bg-[#1a1a2e] border border-neutral-700 rounded px-3 py-2" : ""}`}
    >
      <span
        className={`text-sm ${prominent ? "text-neutral-200 font-medium" : "text-neutral-400"}`}
      >
        {label}
      </span>
      <div
        role="switch"
        aria-checked={value}
        onClick={() => onChange(!value)}
        className={`relative w-10 h-5 rounded-full cursor-pointer transition-colors duration-200 flex-shrink-0 ${
          value ? "bg-green-500" : "bg-neutral-700"
        }`}
      >
        <span
          className={`absolute top-0.5 w-4 h-4 bg-white rounded-full shadow transition-transform duration-200 ${
            value ? "translate-x-5" : "translate-x-0.5"
          }`}
        />
      </div>
    </div>
  );
}

function SectionHeader({ children }: { children: React.ReactNode }) {
  return (
    <h3 className="text-xs font-semibold text-neutral-500 uppercase tracking-wider mb-3 pb-2 border-b border-neutral-800">
      {children}
    </h3>
  );
}

function StatusPill({ status }: { status: string | null }) {
  const color =
    status === "Active"
      ? "bg-green-500/20 text-green-400 border-green-500/30"
      : status === "Maintenance"
        ? "bg-amber-500/20 text-amber-400 border-amber-500/30"
        : status === "Decommissioned"
          ? "bg-red-500/20 text-red-400 border-red-500/30"
          : "bg-neutral-700/50 text-neutral-400 border-neutral-600/30";

  return (
    <span
      className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium border ${color}`}
    >
      {status ?? "Unknown"}
    </span>
  );
}

function Toast({
  toast,
}: {
  toast: { message: string; type: "success" | "error" } | null;
}) {
  if (!toast) return null;
  return (
    <div
      className={`fixed bottom-6 right-6 z-[200] flex items-center gap-2 px-4 py-2.5 rounded-lg border text-sm font-medium shadow-lg transition-all ${
        toast.type === "success"
          ? "bg-green-900/80 border-green-600/50 text-green-300"
          : "bg-red-900/80 border-red-600/50 text-red-300"
      }`}
    >
      <span>{toast.type === "success" ? "✓" : "✗"}</span>
      {toast.message}
    </div>
  );
}

// ─── tab field maps ───────────────────────────────────────────────────────────

function getTabFields(tab: number, draft: Partial<Machine>): Partial<Machine> {
  const pick = (keys: (keyof Machine)[]): Partial<Machine> =>
    Object.fromEntries(
      keys.filter((k) => k in draft).map((k) => [k, draft[k]]),
    ) as Partial<Machine>;

  switch (tab) {
    case 0:
      return pick([
        "official_name",
        "status",
        "venue_group",
        "pod_number",
        "machine_number",
        "pod_location",
        "pod_address",
        "location_type",
        "freezone_location",
        "latitude",
        "longitude",
        "installation_date",
        "cabinet_count",
        "serial_number",
        "source_of_supply",
        "shipment_batch_nbr",
        "include_in_refill",
        "notes",
      ]);
    case 1:
      return pick([
        "trade_license_number",
        "permit_status",
        "permit_issue_date",
        "permit_expiry_date",
        "contact_person",
        "contact_phone",
        "contact_email",
        "contract_signed",
        "building_id",
        "previous_location",
        "repurposed_at",
      ]);
    case 2:
      return pick([
        "adyen_unique_terminal_id",
        "adyen_permanent_terminal_id",
        "adyen_status",
        "adyen_inventory_in_store",
        "adyen_store_code",
        "adyen_store_description",
        "adyen_fridge_assigned",
        "micron_app_id",
        "app_version",
        "micron_version",
        ...PAYMENT_FIELDS.map((f) => f.key),
      ]);
    case 3:
      return pick([
        ...HW_FIELDS.map((f) => f.key),
        "wifi_network_name",
        "wifi_mac_address",
        "wifi_device_hostname",
      ]);
    default:
      return {};
  }
}

// ─── main component ───────────────────────────────────────────────────────────

export default function MachineEditPanel({
  machine,
  onClose,
  onSave,
  onSimChange,
}: MachineEditPanelProps) {
  const [activeTab, setActiveTab] = useState(0);
  const [draft, setDraft] = useState<Partial<Machine>>({ ...machine });
  const [saving, setSaving] = useState(false);
  const [toast, setToast] = useState<{
    message: string;
    type: "success" | "error";
  } | null>(null);

  // SIM state
  const [simData, setSimData] = useState<SimCard | null>(null);
  const [unlinkedSims, setUnlinkedSims] = useState<
    Pick<SimCard, "sim_id" | "sim_ref" | "sim_serial" | "contact_number">[]
  >([]);
  const [selectedSimId, setSelectedSimId] = useState<string>("");
  const [simLoading, setSimLoading] = useState(false);
  const [revealPuk, setRevealPuk] = useState(false);
  const [simSaving, setSimSaving] = useState(false);

  // slide-in animation
  const [visible, setVisible] = useState(false);
  useEffect(() => {
    requestAnimationFrame(() => setVisible(true));
  }, []);

  // reset draft when machine changes
  useEffect(() => {
    setDraft({ ...machine });
  }, [machine]);

  // auto-dismiss toast
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => {
    if (toast) {
      if (toastTimer.current) clearTimeout(toastTimer.current);
      toastTimer.current = setTimeout(() => setToast(null), 3000);
    }
    return () => {
      if (toastTimer.current) clearTimeout(toastTimer.current);
    };
  }, [toast]);

  // fetch SIM data when tab 4 becomes active
  useEffect(() => {
    if (activeTab !== 4) return;
    let cancelled = false;
    setSimLoading(true);
    setRevealPuk(false);

    const supabase = createClient();

    (async () => {
      const { data: sim } = await supabase
        .from("sim_cards")
        .select("*")
        .eq("machine_id", machine.machine_id)
        .maybeSingle();

      const { data: unlinked } = await supabase
        .from("sim_cards")
        .select("sim_id, sim_ref, sim_serial, contact_number")
        .is("machine_id", null)
        .limit(10000);

      if (!cancelled) {
        setSimData(sim ?? null);
        setUnlinkedSims(unlinked ?? []);
        setSelectedSimId(unlinked?.[0]?.sim_id ?? "");
        setSimLoading(false);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [activeTab, machine.machine_id]);

  // ── field helpers ──────────────────────────────────────────────────────────

  const set = <K extends keyof Machine>(key: K, value: Machine[K]) =>
    setDraft((prev) => ({ ...prev, [key]: value }));

  const handleSave = async () => {
    setSaving(true);
    try {
      await onSave(machine.machine_id, getTabFields(activeTab, draft));
      setToast({ message: "Machine updated", type: "success" });
    } catch {
      setToast({ message: "Failed to save", type: "error" });
    } finally {
      setSaving(false);
    }
  };

  // ── SIM actions ────────────────────────────────────────────────────────────

  const handleUnlinkSim = async () => {
    if (!simData) return;
    setSimSaving(true);
    try {
      const supabase = createClient();
      await supabase
        .from("sim_cards")
        .update({ machine_id: null, machine_name: null })
        .eq("sim_id", simData.sim_id);
      setSimData(null);
      onSimChange();
      setToast({ message: "SIM unlinked", type: "success" });
    } catch {
      setToast({ message: "Failed to unlink SIM", type: "error" });
    } finally {
      setSimSaving(false);
    }
  };

  const handleLinkSim = async () => {
    if (!selectedSimId) return;
    setSimSaving(true);
    try {
      const supabase = createClient();
      await supabase
        .from("sim_cards")
        .update({
          machine_id: machine.machine_id,
          machine_name: machine.official_name,
        })
        .eq("sim_id", selectedSimId);
      // refetch
      const { data: sim } = await supabase
        .from("sim_cards")
        .select("*")
        .eq("machine_id", machine.machine_id)
        .maybeSingle();
      setSimData(sim ?? null);
      onSimChange();
      setToast({ message: "SIM linked", type: "success" });
    } catch {
      setToast({ message: "Failed to link SIM", type: "error" });
    } finally {
      setSimSaving(false);
    }
  };

  // ── close with animation ───────────────────────────────────────────────────

  const handleClose = () => {
    setVisible(false);
    setTimeout(onClose, 300);
  };

  // ── per-tab content ────────────────────────────────────────────────────────

  const renderOverview = () => (
    <div className="space-y-4">
      <div className="grid grid-cols-2 gap-4">
        <TextInput
          label="Official Name"
          value={str(draft.official_name)}
          onChange={(v) => set("official_name", v)}
        />
        <SelectInput
          label="Status"
          value={str(draft.status)}
          options={STATUS_OPTIONS}
          onChange={(v) => set("status", v)}
          allowBlank
        />
        <TextInput
          label="Venue Group"
          value={str(draft.venue_group)}
          onChange={(v) => set("venue_group", v)}
        />
        <TextInput
          label="Pod Number"
          value={str(draft.pod_number)}
          onChange={(v) => set("pod_number", v)}
        />
        <TextInput
          label="Machine Number"
          value={str(draft.machine_number)}
          onChange={(v) => set("machine_number", v)}
        />
        <TextInput
          label="Serial Number"
          value={str(draft.serial_number)}
          onChange={(v) => set("serial_number", v)}
        />
      </div>

      <TextInput
        label="Pod Location"
        value={str(draft.pod_location)}
        onChange={(v) => set("pod_location", v)}
      />

      <div>
        <Label>Pod Address</Label>
        <input
          className={inputCls}
          value={str(draft.pod_address)}
          onChange={(e) => set("pod_address", e.target.value)}
        />
      </div>

      <div className="grid grid-cols-2 gap-4">
        <SelectInput
          label="Location Type"
          value={str(draft.location_type)}
          options={LOCATION_TYPE_OPTIONS}
          onChange={(v) => set("location_type", v)}
          allowBlank
        />
        <div className="flex items-end">
          <Toggle
            label="Freezone Location"
            value={draft.freezone_location ?? false}
            onChange={(v) => set("freezone_location", v)}
          />
        </div>
        <TextInput
          label="Latitude"
          value={
            draft.latitude !== null && draft.latitude !== undefined
              ? String(draft.latitude)
              : ""
          }
          onChange={(v) => set("latitude", v === "" ? null : parseFloat(v))}
          type="number"
        />
        <TextInput
          label="Longitude"
          value={
            draft.longitude !== null && draft.longitude !== undefined
              ? String(draft.longitude)
              : ""
          }
          onChange={(v) => set("longitude", v === "" ? null : parseFloat(v))}
          type="number"
        />
        <TextInput
          label="Installation Date"
          value={str(draft.installation_date)}
          onChange={(v) => set("installation_date", v)}
          type="date"
        />
        <TextInput
          label="Cabinet Count"
          value={
            draft.cabinet_count !== null && draft.cabinet_count !== undefined
              ? String(draft.cabinet_count)
              : ""
          }
          onChange={(v) =>
            set("cabinet_count", v === "" ? null : parseInt(v, 10))
          }
          type="number"
        />
        <TextInput
          label="Source of Supply"
          value={str(draft.source_of_supply)}
          onChange={(v) => set("source_of_supply", v)}
        />
        <TextInput
          label="Shipment Batch #"
          value={str(draft.shipment_batch_nbr)}
          onChange={(v) => set("shipment_batch_nbr", v)}
        />
      </div>

      <Toggle
        label="Include in Refill Engine"
        value={draft.include_in_refill ?? false}
        onChange={(v) => set("include_in_refill", v)}
        prominent
      />

      <div>
        <Label>Notes</Label>
        <textarea
          className={`${inputCls} resize-none h-20`}
          value={str(draft.notes)}
          onChange={(e) => set("notes", e.target.value)}
        />
      </div>
    </div>
  );

  const renderPermitContact = () => {
    const expiryDays = daysUntil(draft.permit_expiry_date ?? null);

    return (
      <div className="space-y-4">
        <SectionHeader>Permit</SectionHeader>

        {expiryDays !== null && expiryDays <= 90 && (
          <div
            className={`flex items-center gap-2 px-3 py-2 rounded border text-sm ${
              expiryDays <= 30
                ? "bg-red-900/30 border-red-600/40 text-red-300"
                : "bg-amber-900/30 border-amber-600/40 text-amber-300"
            }`}
          >
            <span>⚠</span>
            <span>
              {expiryDays <= 0
                ? "Permit has expired"
                : `Expires in ${expiryDays} day${expiryDays === 1 ? "" : "s"}`}
            </span>
          </div>
        )}

        <div className="grid grid-cols-2 gap-4">
          <TextInput
            label="Trade License Number"
            value={str(draft.trade_license_number)}
            onChange={(v) => set("trade_license_number", v)}
          />
          <SelectInput
            label="Permit Status"
            value={str(draft.permit_status)}
            options={PERMIT_STATUS_OPTIONS}
            onChange={(v) => set("permit_status", v)}
            allowBlank
          />
          <TextInput
            label="Permit Issue Date"
            value={str(draft.permit_issue_date)}
            onChange={(v) => set("permit_issue_date", v)}
            type="date"
          />
          <TextInput
            label="Permit Expiry Date"
            value={str(draft.permit_expiry_date)}
            onChange={(v) => set("permit_expiry_date", v)}
            type="date"
          />
        </div>

        <SectionHeader>Contact</SectionHeader>

        <div className="grid grid-cols-2 gap-4">
          <TextInput
            label="Contact Person"
            value={str(draft.contact_person)}
            onChange={(v) => set("contact_person", v)}
          />
          <TextInput
            label="Contact Phone"
            value={str(draft.contact_phone)}
            onChange={(v) => set("contact_phone", v)}
            type="tel"
          />
          <div className="col-span-2">
            <TextInput
              label="Contact Email"
              value={str(draft.contact_email)}
              onChange={(v) => set("contact_email", v)}
              type="email"
            />
          </div>
        </div>

        <Toggle
          label="Contract Signed"
          value={draft.contract_signed ?? false}
          onChange={(v) => set("contract_signed", v)}
        />

        <SectionHeader>Location History</SectionHeader>

        <div className="grid grid-cols-2 gap-4">
          <TextInput
            label="Building ID"
            value={str(draft.building_id)}
            onChange={(v) => set("building_id", v)}
          />
          <TextInput
            label="Previous Location"
            value={str(draft.previous_location)}
            onChange={(v) => set("previous_location", v)}
          />
          <TextInput
            label="Repurposed At"
            value={str(draft.repurposed_at)}
            onChange={(v) => set("repurposed_at", v)}
            type="date"
          />
        </div>
      </div>
    );
  };

  const renderAdyenPayment = () => {
    const configuredCount = PAYMENT_FIELDS.filter(
      (f) => draft[f.key] === true,
    ).length;
    const configuredPct = Math.round(
      (configuredCount / PAYMENT_FIELDS.length) * 100,
    );

    return (
      <div className="space-y-5">
        <SectionHeader>Adyen</SectionHeader>

        <div className="grid grid-cols-2 gap-4">
          <TextInput
            label="Unique Terminal ID"
            value={str(draft.adyen_unique_terminal_id)}
            onChange={(v) => set("adyen_unique_terminal_id", v)}
          />
          <TextInput
            label="Permanent Terminal ID"
            value={str(draft.adyen_permanent_terminal_id)}
            onChange={(v) => set("adyen_permanent_terminal_id", v)}
          />
          <TextInput
            label="Adyen Status"
            value={str(draft.adyen_status)}
            onChange={(v) => set("adyen_status", v)}
          />
          <TextInput
            label="Inventory in Store"
            value={str(draft.adyen_inventory_in_store)}
            onChange={(v) => set("adyen_inventory_in_store", v)}
          />
          <TextInput
            label="Store Code"
            value={str(draft.adyen_store_code)}
            onChange={(v) => set("adyen_store_code", v)}
          />
          <TextInput
            label="Store Description"
            value={str(draft.adyen_store_description)}
            onChange={(v) => set("adyen_store_description", v)}
          />
          <div className="col-span-2">
            <TextInput
              label="Fridge Assigned"
              value={str(draft.adyen_fridge_assigned)}
              onChange={(v) => set("adyen_fridge_assigned", v)}
            />
          </div>
        </div>

        <SectionHeader>Micron / App</SectionHeader>

        <div className="grid grid-cols-3 gap-4">
          <TextInput
            label="Micron App ID"
            value={str(draft.micron_app_id)}
            onChange={(v) => set("micron_app_id", v)}
          />
          <TextInput
            label="App Version"
            value={str(draft.app_version)}
            onChange={(v) => set("app_version", v)}
          />
          <TextInput
            label="Micron Version"
            value={str(draft.micron_version)}
            onChange={(v) => set("micron_version", v)}
          />
        </div>

        <SectionHeader>Payment Configuration</SectionHeader>

        <div className="space-y-2">
          <div className="flex items-center justify-between mb-1">
            <span className="text-xs text-neutral-500">
              {configuredCount}/{PAYMENT_FIELDS.length} configured
            </span>
            <span className="text-xs font-mono text-neutral-400">
              {configuredPct}%
            </span>
          </div>
          <div className="w-full h-1.5 bg-neutral-800 rounded-full overflow-hidden">
            <div
              className={`h-full rounded-full transition-all duration-300 ${
                configuredPct === 100
                  ? "bg-green-500"
                  : configuredPct >= 60
                    ? "bg-amber-500"
                    : "bg-neutral-600"
              }`}
              style={{ width: `${configuredPct}%` }}
            />
          </div>
        </div>

        <div className="grid grid-cols-2 gap-3">
          {PAYMENT_FIELDS.map((f) => {
            const checked = draft[f.key] === true;
            return (
              <label
                key={f.key}
                className="flex items-center gap-2.5 cursor-pointer group"
              >
                <input
                  type="checkbox"
                  checked={checked}
                  onChange={(e) =>
                    set(f.key, e.target.checked as Machine[typeof f.key])
                  }
                  className="w-4 h-4 rounded border-neutral-600 bg-[#1a1a2e] accent-green-500 cursor-pointer"
                />
                <span className="text-sm text-neutral-400 group-hover:text-neutral-300 transition-colors">
                  {f.label}
                </span>
              </label>
            );
          })}
        </div>
      </div>
    );
  };

  const renderHardwareWifi = () => {
    const okCount = HW_FIELDS.filter((f) => draft[f.key] === true).length;
    const allOk = okCount === HW_FIELDS.length;

    return (
      <div className="space-y-5">
        <SectionHeader>Hardware Checklist</SectionHeader>

        <div className="flex items-center gap-2 mb-3">
          <span
            className={`inline-flex items-center px-2.5 py-1 rounded-full text-xs font-semibold border ${
              allOk
                ? "bg-green-900/30 border-green-600/40 text-green-300"
                : "bg-red-900/30 border-red-600/40 text-red-300"
            }`}
          >
            {allOk
              ? `${HW_FIELDS.length}/${HW_FIELDS.length} ✓`
              : `${okCount}/${HW_FIELDS.length} — ${HW_FIELDS.length - okCount} issue${HW_FIELDS.length - okCount === 1 ? "" : "s"}`}
          </span>
        </div>

        <div className="space-y-3">
          {HW_FIELDS.map((f) => {
            const checked = draft[f.key] === true;
            return (
              <label
                key={f.key}
                className="flex items-center gap-3 cursor-pointer group"
              >
                <input
                  type="checkbox"
                  checked={checked}
                  onChange={(e) =>
                    set(f.key, e.target.checked as Machine[typeof f.key])
                  }
                  className="w-4 h-4 rounded border-neutral-600 bg-[#1a1a2e] accent-green-500 cursor-pointer"
                />
                <span className="text-sm text-neutral-400 group-hover:text-neutral-300 transition-colors">
                  {f.label}
                </span>
              </label>
            );
          })}
        </div>

        <SectionHeader>WiFi</SectionHeader>

        <div className="space-y-4">
          <TextInput
            label="Network Name (SSID)"
            value={str(draft.wifi_network_name)}
            onChange={(v) => set("wifi_network_name", v)}
          />
          <TextInput
            label="MAC Address"
            value={str(draft.wifi_mac_address)}
            onChange={(v) => set("wifi_mac_address", v)}
          />
          <TextInput
            label="Device Hostname"
            value={str(draft.wifi_device_hostname)}
            onChange={(v) => set("wifi_device_hostname", v)}
          />
        </div>
      </div>
    );
  };

  const renderSimCard = () => {
    if (simLoading) {
      return (
        <div className="flex items-center justify-center h-32 text-neutral-500 text-sm">
          Loading SIM data…
        </div>
      );
    }

    if (simData) {
      const renewalDays = daysUntil(simData.sim_renewal);
      const renewalColor =
        renewalDays === null
          ? "text-neutral-500"
          : renewalDays < 30
            ? "text-red-400"
            : renewalDays < 90
              ? "text-amber-400"
              : "text-green-400";

      return (
        <div className="space-y-4">
          <SectionHeader>Linked SIM Card</SectionHeader>

          <div className="bg-[#1a1a2e] border border-neutral-700 rounded-lg p-4 space-y-3">
            <div className="grid grid-cols-2 gap-x-6 gap-y-3">
              <div>
                <p className="text-xs text-neutral-500 uppercase tracking-wider mb-0.5">
                  SIM Ref
                </p>
                <p className="text-sm font-mono text-neutral-200">
                  {simData.sim_ref ?? "—"}
                </p>
              </div>
              <div>
                <p className="text-xs text-neutral-500 uppercase tracking-wider mb-0.5">
                  Contact Number
                </p>
                <p className="text-sm font-mono text-neutral-200">
                  {simData.contact_number ?? "—"}
                </p>
              </div>
              <div>
                <p className="text-xs text-neutral-500 uppercase tracking-wider mb-0.5">
                  Serial
                </p>
                <p className="text-sm font-mono text-neutral-400 break-all">
                  {simData.sim_serial ?? "—"}
                </p>
              </div>
              <div>
                <p className="text-xs text-neutral-500 uppercase tracking-wider mb-0.5">
                  SIM Code
                </p>
                <p className="text-sm font-mono text-neutral-400">
                  {simData.sim_code ?? "—"}
                </p>
              </div>
              <div>
                <p className="text-xs text-neutral-500 uppercase tracking-wider mb-0.5">
                  Activation Date
                </p>
                <p className="text-sm text-neutral-300">
                  {simData.sim_date ?? "—"}
                </p>
              </div>
              <div>
                <p className="text-xs text-neutral-500 uppercase tracking-wider mb-0.5">
                  Renewal Date
                </p>
                <p className={`text-sm font-medium ${renewalColor}`}>
                  {simData.sim_renewal ?? "—"}
                  {renewalDays !== null && (
                    <span className="ml-1.5 text-xs opacity-80">
                      ({renewalDays < 0 ? "expired" : `${renewalDays}d`})
                    </span>
                  )}
                </p>
              </div>
            </div>

            <div className="border-t border-neutral-800 pt-3">
              <div className="flex items-center justify-between mb-2">
                <p className="text-xs text-neutral-500 uppercase tracking-wider">
                  PUK Codes
                </p>
                <button
                  onClick={() => setRevealPuk((v) => !v)}
                  className="text-xs text-neutral-400 hover:text-neutral-200 transition-colors underline underline-offset-2"
                >
                  {revealPuk ? "Hide" : "Reveal"}
                </button>
              </div>
              {revealPuk ? (
                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <p className="text-xs text-neutral-600 mb-0.5">PUK1</p>
                    <p className="text-sm font-mono text-amber-300">
                      {simData.puk1 ?? "—"}
                    </p>
                  </div>
                  <div>
                    <p className="text-xs text-neutral-600 mb-0.5">PUK2</p>
                    <p className="text-sm font-mono text-amber-300">
                      {simData.puk2 ?? "—"}
                    </p>
                  </div>
                </div>
              ) : (
                <p className="text-sm text-neutral-600 font-mono tracking-widest">
                  ●●●●●●●● ●●●●●●●●
                </p>
              )}
            </div>
          </div>

          <button
            onClick={handleUnlinkSim}
            disabled={simSaving}
            className="w-full flex items-center justify-center gap-2 px-4 py-2 rounded border border-red-700/50 bg-red-900/20 text-red-400 hover:bg-red-900/40 text-sm font-medium transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {simSaving ? "Unlinking…" : "Unlink SIM"}
          </button>
        </div>
      );
    }

    return (
      <div className="space-y-4">
        <div className="flex flex-col items-center justify-center py-10 gap-3 border border-dashed border-neutral-800 rounded-lg">
          <div className="w-10 h-10 rounded-full bg-neutral-800 flex items-center justify-center text-neutral-500 text-xl">
            ◻
          </div>
          <p className="text-sm text-neutral-500">No SIM card linked</p>
        </div>

        {unlinkedSims.length > 0 && (
          <div className="space-y-2">
            <Label>Link a SIM Card</Label>
            <select
              className={inputCls}
              value={selectedSimId}
              onChange={(e) => setSelectedSimId(e.target.value)}
            >
              {unlinkedSims.map((s) => (
                <option key={s.sim_id} value={s.sim_id}>
                  {s.sim_ref ?? s.sim_id}
                  {s.contact_number ? ` — ${s.contact_number}` : ""}
                </option>
              ))}
            </select>
            <button
              onClick={handleLinkSim}
              disabled={simSaving || !selectedSimId}
              className="w-full flex items-center justify-center gap-2 px-4 py-2 rounded border border-green-700/50 bg-green-900/20 text-green-400 hover:bg-green-900/40 text-sm font-medium transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {simSaving ? "Linking…" : "Link SIM"}
            </button>
          </div>
        )}

        {unlinkedSims.length === 0 && (
          <p className="text-xs text-neutral-600 text-center">
            No unlinked SIM cards available.
          </p>
        )}
      </div>
    );
  };

  const tabContent = [
    renderOverview,
    renderPermitContact,
    renderAdyenPayment,
    renderHardwareWifi,
    renderSimCard,
  ];

  // ── render ─────────────────────────────────────────────────────────────────

  return (
    <>
      {/* overlay */}
      <div
        className="fixed inset-0 z-[100] bg-black/60 transition-opacity duration-300"
        style={{ opacity: visible ? 1 : 0 }}
        onClick={handleClose}
        aria-hidden="true"
      />

      {/* panel */}
      <div
        className="fixed right-0 top-0 h-full z-[101] w-full max-w-2xl flex flex-col bg-[#0f0f18] border-l border-neutral-800 shadow-2xl transition-transform duration-300"
        style={{ transform: visible ? "translateX(0)" : "translateX(100%)" }}
        role="dialog"
        aria-label={`Edit ${machine.official_name}`}
      >
        {/* header */}
        <div className="flex items-center gap-3 px-5 py-4 border-b border-neutral-800 flex-shrink-0">
          <div className="flex-1 min-w-0">
            <h2 className="font-mono text-sm font-semibold text-neutral-100 truncate">
              {machine.official_name}
            </h2>
            <p className="text-xs text-neutral-600 font-mono mt-0.5">
              {machine.machine_id}
            </p>
          </div>
          <StatusPill status={machine.status} />
          <button
            onClick={handleClose}
            className="ml-2 p-1.5 rounded text-neutral-500 hover:text-neutral-200 hover:bg-neutral-800 transition-colors flex-shrink-0"
            aria-label="Close panel"
          >
            <svg
              className="w-4 h-4"
              fill="none"
              stroke="currentColor"
              strokeWidth={2}
              viewBox="0 0 24 24"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
        </div>

        {/* tabs */}
        <div className="flex border-b border-neutral-800 flex-shrink-0 overflow-x-auto">
          {TAB_LABELS.map((label, i) => (
            <button
              key={label}
              onClick={() => setActiveTab(i)}
              className={`px-4 py-2.5 text-xs font-medium whitespace-nowrap transition-colors border-b-2 -mb-px ${
                activeTab === i
                  ? "border-green-500 text-green-400"
                  : "border-transparent text-neutral-500 hover:text-neutral-300"
              }`}
            >
              {label}
            </button>
          ))}
        </div>

        {/* scrollable content */}
        <div className="flex-1 overflow-y-auto px-5 py-5 min-h-0">
          {tabContent[activeTab]()}
        </div>

        {/* footer — hide on SIM tab (has its own actions) */}
        {activeTab !== 4 && (
          <div className="flex items-center justify-end gap-3 px-5 py-4 border-t border-neutral-800 flex-shrink-0">
            <button
              onClick={handleClose}
              className="px-4 py-2 text-sm text-neutral-400 hover:text-neutral-200 transition-colors"
            >
              Cancel
            </button>
            <button
              onClick={handleSave}
              disabled={saving}
              className="px-5 py-2 rounded bg-green-600 hover:bg-green-500 disabled:bg-neutral-700 disabled:cursor-not-allowed text-white text-sm font-medium transition-colors min-w-[90px] flex items-center justify-center gap-2"
            >
              {saving ? (
                <>
                  <span className="inline-block w-3.5 h-3.5 border-2 border-white/30 border-t-white rounded-full animate-spin" />
                  Saving…
                </>
              ) : (
                "Save"
              )}
            </button>
          </div>
        )}
      </div>

      <Toast toast={toast} />
    </>
  );
}
