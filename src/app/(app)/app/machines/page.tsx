"use client";

import { useEffect, useState, useMemo, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";

// ─── Types ────────────────────────────────────────────────────────────────────

interface Machine {
  machine_id: string;
  official_name: string;
  venue_group: string | null;
  status: string | null;
  include_in_refill: boolean | null;
  pod_location: string | null;
  pod_address: string | null;
  adyen_status: string | null;
  adyen_inventory_in_store: boolean | null;
  adyen_unique_terminal_id: string | null;
  adyen_permanent_terminal_id: string | null;
  adyen_store_code: string | null;
  adyen_fridge_assigned: boolean | null;
  adyen_store_description: string | null;
  location_type: string | null;
  contact_person: string | null;
  contact_phone: string | null;
  contact_email: string | null;
  installation_date: string | null;
  notes: string | null;
  serial_number: string | null;
  shipment_batch_nbr: string | null;
  micron_app_id: string | null;
  app_version: string | null;
  micron_version: string | null;
  wifi_network_name: string | null;
  wifi_mac_address: string | null;
  wifi_device_hostname: string | null;
  payment_terminal_installed: boolean | null;
  payment_micron_bo_setup: boolean | null;
  payment_adyen_store_created: boolean | null;
  payment_connect_store_terminal: boolean | null;
  payment_general_ui_updated: boolean | null;
  payment_pos_hide_button: boolean | null;
  payment_app_deployed: boolean | null;
  payment_app_deployed_terminal: boolean | null;
  payment_kiosk_mode: boolean | null;
  payment_fan_test: boolean | null;
  hw_compressor_ok: boolean | null;
  hw_calibration_ok: boolean | null;
  hw_door_spring_ok: boolean | null;
  hw_test_successful: boolean | null;
  cabinet_count: number | null;
  source_of_supply: string | null;
}

type DrawerTab = "overview" | "adyen" | "payment" | "hardware" | "wifi";

const DRAWER_TABS: { key: DrawerTab; label: string }[] = [
  { key: "overview", label: "Overview" },
  { key: "adyen", label: "Adyen" },
  { key: "payment", label: "Payment" },
  { key: "hardware", label: "Hardware" },
  { key: "wifi", label: "WiFi" },
];

// Dropdown option lists — values MUST match the DB CHECK constraints exactly.
// status     -> machines_status_check
// location_type -> machines_location_type_check (lowercase!)
// venue_group   -> machines_venue_group_check (uppercase!)
// adyen_status has no check constraint; values below mirror what's in use.
const STATUS_OPTIONS = [
  "Active",
  "Inactive",
  "Maintenance",
  "Pending",
  "Valid",
  "Online today",
  "Switched off",
  "Scheduled",
  "Warehouse",
];
const LOCATION_TYPE_OPTIONS = [
  "office",
  "coworking",
  "entertainment",
  "warehouse",
];
// venue_group options now come from the venue_groups lookup table at runtime —
// see useEffect that populates `venueGroups` state. The list below is only used
// as a defensive fallback if the fetch fails.
const VENUE_GROUP_FALLBACK = [
  "ADDMIND",
  "VOX",
  "VML",
  "WPP",
  "OHMYDESK",
  "INDEPENDENT",
  "GRIT",
  "NOVO",
];
const ADYEN_STATUS_OPTIONS = [
  "Online today",
  "Switched off",
  "Switched on Non-Functional",
];

const MACHINE_COLS =
  "machine_id, official_name, venue_group, status, include_in_refill, pod_location, pod_address, adyen_status, adyen_inventory_in_store, adyen_unique_terminal_id, adyen_permanent_terminal_id, adyen_store_code, adyen_fridge_assigned, adyen_store_description, location_type, contact_person, contact_phone, contact_email, installation_date, notes, serial_number, shipment_batch_nbr, micron_app_id, app_version, micron_version, wifi_network_name, wifi_mac_address, wifi_device_hostname, payment_terminal_installed, payment_micron_bo_setup, payment_adyen_store_created, payment_connect_store_terminal, payment_general_ui_updated, payment_pos_hide_button, payment_app_deployed, payment_app_deployed_terminal, payment_kiosk_mode, payment_fan_test, hw_compressor_ok, hw_calibration_ok, hw_door_spring_ok, hw_test_successful, cabinet_count, source_of_supply";

// ─── Styles ───────────────────────────────────────────────────────────────────

const inputStyle: React.CSSProperties = {
  width: "100%",
  border: "1px solid #e8e4de",
  borderRadius: 6,
  padding: "6px 10px",
  fontSize: 14,
  color: "#0a0a0a",
  outline: "none",
  background: "white",
};

const cancelBtnStyle: React.CSSProperties = {
  flex: 1,
  padding: "10px 20px",
  borderRadius: 8,
  fontSize: 14,
  fontWeight: 600,
  border: "1px solid #e8e4de",
  background: "white",
  color: "#6b6860",
  cursor: "pointer",
};

const saveBtnStyle: React.CSSProperties = {
  flex: 2,
  padding: "10px 20px",
  borderRadius: 8,
  fontSize: 14,
  fontWeight: 600,
  border: "none",
  background: "#24544a",
  color: "white",
  cursor: "pointer",
};

const editBtnStyle: React.CSSProperties = {
  display: "inline-flex",
  alignItems: "center",
  gap: 6,
  background: "#24544a",
  color: "white",
  padding: "10px 20px",
  borderRadius: 8,
  border: "none",
  fontSize: 14,
  fontWeight: 600,
  cursor: "pointer",
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

function SectionLabel({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        fontSize: 10,
        fontWeight: 500,
        letterSpacing: "0.1em",
        textTransform: "uppercase",
        color: "#6b6860",
        marginBottom: 14,
        marginTop: 24,
      }}
    >
      {children}
    </div>
  );
}

function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div style={{ marginBottom: 14 }}>
      <div
        style={{
          fontSize: 10,
          fontWeight: 500,
          letterSpacing: "0.08em",
          textTransform: "uppercase",
          color: "#6b6860",
          marginBottom: 3,
        }}
      >
        {label}
      </div>
      <div style={{ fontSize: 14, color: "#0a0a0a", fontWeight: 500 }}>
        {value ?? "\u2014"}
      </div>
    </div>
  );
}

function BoolField({ label, value }: { label: string; value: boolean | null }) {
  return (
    <Field
      label={label}
      value={
        value === true ? (
          <span style={{ color: "#24544a", fontWeight: 700 }}>
            &#10003; Yes
          </span>
        ) : value === false ? (
          <span style={{ color: "#9ca3af" }}>&mdash; No</span>
        ) : (
          <span style={{ color: "#9ca3af" }}>&mdash;</span>
        )
      }
    />
  );
}

// ─── Editable components ──────────────────────────────────────────────────────
// NOTE: these live at module scope so React keeps the same component identity
// across renders of the parent. If they were declared inside the parent, every
// keystroke would create a new function reference, React would unmount and
// remount the <input>, and the user would lose focus after each character.

function FieldLabel({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        fontSize: 10,
        fontWeight: 500,
        letterSpacing: "0.08em",
        textTransform: "uppercase",
        color: "#6b6860",
        marginBottom: 3,
      }}
    >
      {children}
    </div>
  );
}

function EditableField({
  label,
  field,
  value,
  onChange,
  type = "text",
}: {
  label: string;
  field: string;
  value: string;
  onChange: (field: string, v: string | number | null) => void;
  type?: string;
}) {
  return (
    <div style={{ marginBottom: 14 }}>
      <FieldLabel>{label}</FieldLabel>
      <input
        type={type}
        value={value}
        onChange={(e) => {
          const raw = e.target.value;
          const next =
            type === "number" ? (raw === "" ? null : Number(raw)) : raw;
          onChange(field, next);
        }}
        style={inputStyle}
      />
    </div>
  );
}

function EditableSelect({
  label,
  field,
  value,
  options,
  onChange,
  allowBlank = true,
}: {
  label: string;
  field: string;
  value: string;
  options: string[];
  onChange: (field: string, v: string | null) => void;
  allowBlank?: boolean;
}) {
  return (
    <div style={{ marginBottom: 14 }}>
      <FieldLabel>{label}</FieldLabel>
      <select
        value={value}
        onChange={(e) =>
          onChange(field, e.target.value === "" ? null : e.target.value)
        }
        style={{ ...inputStyle, cursor: "pointer" }}
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

/**
 * Same as EditableSelect, but the dropdown ends with an "+ Add new…" sentinel.
 * Picking it calls onAddNew() instead of setting the value to that string.
 */
function EditableSelectWithAdd({
  label,
  field,
  value,
  options,
  onChange,
  onAddNew,
  addLabel = "+ Add new…",
  allowBlank = true,
}: {
  label: string;
  field: string;
  value: string;
  options: string[];
  onChange: (field: string, v: string | null) => void;
  onAddNew: () => void;
  addLabel?: string;
  allowBlank?: boolean;
}) {
  const ADD_SENTINEL = "__add_new__";
  return (
    <div style={{ marginBottom: 14 }}>
      <FieldLabel>{label}</FieldLabel>
      <select
        value={value}
        onChange={(e) => {
          const v = e.target.value;
          if (v === ADD_SENTINEL) {
            onAddNew();
            return;
          }
          onChange(field, v === "" ? null : v);
        }}
        style={{ ...inputStyle, cursor: "pointer" }}
      >
        {allowBlank && <option value="">—</option>}
        {options.map((o) => (
          <option key={o} value={o}>
            {o}
          </option>
        ))}
        <option value={ADD_SENTINEL} style={{ fontStyle: "italic" }}>
          {addLabel}
        </option>
      </select>
    </div>
  );
}

function EditableBoolField({
  label,
  field,
  value,
  onChange,
}: {
  label: string;
  field: string;
  value: boolean | null;
  onChange: (field: string, v: boolean | null) => void;
}) {
  return (
    <div style={{ marginBottom: 14 }}>
      <div
        style={{
          fontSize: 10,
          fontWeight: 500,
          letterSpacing: "0.08em",
          textTransform: "uppercase",
          color: "#6b6860",
          marginBottom: 6,
        }}
      >
        {label}
      </div>
      <button
        type="button"
        onClick={() =>
          onChange(
            field,
            value === true ? false : value === false ? null : true,
          )
        }
        style={{
          display: "inline-flex",
          alignItems: "center",
          gap: 6,
          padding: "5px 12px",
          borderRadius: 6,
          border: "1px solid #e8e4de",
          background:
            value === true
              ? "#f0fdf4"
              : value === false
                ? "#fef2f2"
                : "#faf9f7",
          color:
            value === true
              ? "#065f46"
              : value === false
                ? "#991b1b"
                : "#6b6860",
          fontSize: 13,
          fontWeight: 600,
          cursor: "pointer",
        }}
      >
        {value === true ? "Yes" : value === false ? "No" : "Not set"}
      </button>
    </div>
  );
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function MachinesPage() {
  const [machines, setMachines] = useState<Machine[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState<
    "All" | "Active" | "Inactive"
  >("All");
  const [groupFilter, setGroupFilter] = useState("All");
  const [selected, setSelected] = useState<Machine | null>(null);
  const [drawerTab, setDrawerTab] = useState<DrawerTab>("overview");

  // Edit mode state
  const [editing, setEditing] = useState(false);
  const [editValues, setEditValues] = useState<Partial<Machine>>({});
  const [saving, setSaving] = useState(false);
  const [toast, setToast] = useState<{
    message: string;
    type: "success" | "error";
  } | null>(null);

  // Venue groups (from the venue_groups lookup table)
  const [venueGroups, setVenueGroups] = useState<string[]>(
    VENUE_GROUP_FALLBACK,
  );

  // "Add new venue group" modal state
  const [addGroupOpen, setAddGroupOpen] = useState(false);
  const [newGroupCode, setNewGroupCode] = useState("");
  const [newGroupName, setNewGroupName] = useState("");
  const [addingGroup, setAddingGroup] = useState(false);

  // Load venue_groups once on mount
  useEffect(() => {
    async function loadGroups() {
      const supabase = createClient();
      const { data, error } = await supabase
        .from("venue_groups")
        .select("code")
        .eq("active", true)
        .order("code")
        .limit(10000);
      if (error) {
        console.error("venue_groups fetch error:", error);
        return;
      }
      setVenueGroups((data ?? []).map((r) => r.code as string));
    }
    loadGroups();
  }, []);

  const handleAddVenueGroup = useCallback(async () => {
    const code = newGroupCode.trim().toUpperCase();
    const name = newGroupName.trim() || code;
    if (!code) {
      setToast({ message: "Group code is required.", type: "error" });
      return;
    }
    setAddingGroup(true);
    const supabase = createClient();
    const { error } = await supabase
      .from("venue_groups")
      .insert({ code, display_name: name });
    if (error) {
      setToast({
        message: `Could not add group: ${error.message}`,
        type: "error",
      });
      setAddingGroup(false);
      return;
    }
    setVenueGroups((prev) =>
      prev.includes(code) ? prev : [...prev, code].sort(),
    );
    // Auto-select the new group on the row being edited
    setEditValues((prev) => ({ ...prev, venue_group: code }));
    setAddGroupOpen(false);
    setNewGroupCode("");
    setNewGroupName("");
    setAddingGroup(false);
    setToast({ message: `Added venue group "${code}".`, type: "success" });
  }, [newGroupCode, newGroupName]);

  // Auto-dismiss toast after 4s
  useEffect(() => {
    if (!toast) return;
    const id = setTimeout(() => setToast(null), 4000);
    return () => clearTimeout(id);
  }, [toast]);

  // Stable update callback for child fields — prevents focus-loss cascade
  const updateField = useCallback(
    (field: string, value: string | number | boolean | null) => {
      setEditValues((prev) => ({ ...prev, [field]: value }));
    },
    [],
  );

  // ESC key to close drawer / cancel edit
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        if (editing) {
          setEditing(false);
          setEditValues({});
        } else {
          setSelected(null);
        }
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [editing]);

  useEffect(() => {
    async function load() {
      const supabase = createClient();
      const { data, error } = await supabase
        .from("machines")
        .select(MACHINE_COLS)
        .order("official_name")
        .limit(10000);
      if (error) console.error("machines fetch error:", error);
      setMachines(data ?? []);
      setLoading(false);
    }
    load();
  }, []);

  const groups = useMemo(() => {
    const set = new Set<string>();
    for (const m of machines) if (m.venue_group) set.add(m.venue_group);
    return ["All", ...Array.from(set).sort()];
  }, [machines]);

  // Device Number = the numeric suffix of adyen_store_code (e.g. "BOONZ_82160817" -> "82160817").
  // It's how operators identify the physical device in the field / Adyen back office.
  const deviceNumber = useCallback((m: Machine): string | null => {
    if (!m.adyen_store_code) return null;
    return m.adyen_store_code.replace(/^BOONZ_/i, "");
  }, []);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return machines.filter((m) => {
      if (q) {
        // Match on official_name OR Device Number (the stripped adyen_store_code).
        // Also match the raw adyen_store_code so pasting "BOONZ_82160817" works.
        const nameHit = m.official_name.toLowerCase().includes(q);
        const dev = deviceNumber(m);
        const devHit = dev !== null && dev.toLowerCase().includes(q);
        const storeHit =
          !!m.adyen_store_code &&
          m.adyen_store_code.toLowerCase().includes(q);
        if (!nameHit && !devHit && !storeHit) return false;
      }
      if (statusFilter !== "All") {
        const isActive = m.status?.toLowerCase() === "active";
        if (statusFilter === "Active" && !isActive) return false;
        if (statusFilter === "Inactive" && isActive) return false;
      }
      if (groupFilter !== "All" && m.venue_group !== groupFilter) return false;
      return true;
    });
  }, [machines, search, statusFilter, groupFilter, deviceNumber]);

  // ── Edit helpers ────────────────────────────────────────────────────────────

  const startEditing = useCallback(() => {
    if (!selected) return;
    setEditing(true);
    setEditValues({ ...selected });
  }, [selected]);

  const cancelEditing = useCallback(() => {
    setEditing(false);
    setEditValues({});
  }, []);

  const handleSave = useCallback(async () => {
    if (!selected) return;
    setSaving(true);

    // Build a diff: only send fields that actually changed, and never the PK.
    // Sending the full row (including machine_id) can trip RLS WITH CHECK
    // clauses and triggers, causing silent save failures.
    const diff: Record<string, unknown> = {};
    for (const key of Object.keys(editValues)) {
      if (key === "machine_id") continue;
      const newVal = (editValues as Record<string, unknown>)[key];
      const oldVal = (selected as unknown as Record<string, unknown>)[key];
      // Normalize empty strings to null for nullable columns
      const normalized = newVal === "" ? null : newVal;
      if (normalized !== oldVal) diff[key] = normalized;
    }

    if (Object.keys(diff).length === 0) {
      setToast({ message: "No changes to save.", type: "success" });
      setEditing(false);
      setEditValues({});
      setSaving(false);
      return;
    }

    const supabase = createClient();
    const { error } = await supabase
      .from("machines")
      .update(diff)
      .eq("machine_id", selected.machine_id);

    if (!error) {
      setMachines((prev) =>
        prev.map((m) =>
          m.machine_id === selected.machine_id
            ? ({ ...m, ...diff } as Machine)
            : m,
        ),
      );
      setSelected({ ...selected, ...diff } as Machine);
      setEditing(false);
      setEditValues({});
      setToast({ message: "Changes saved.", type: "success" });
    } else {
      console.error("save error:", error);
      setToast({
        message: `Save failed: ${error.message}`,
        type: "error",
      });
    }
    setSaving(false);
  }, [selected, editValues]);

  // Close drawer and cancel edit
  const closeDrawer = useCallback(() => {
    setSelected(null);
    setEditing(false);
    setEditValues({});
  }, []);

  // ── Small prop-binding helpers ────────────────────────────────────────────
  // These just close over editValues/updateField and forward to the
  // stable module-scope components above. They are NOT React components
  // themselves (lowercase-named), so React doesn't treat them as types.
  const strVal = (f: keyof Machine) =>
    ((editValues as Record<string, unknown>)[f] as string | null) ?? "";
  const boolVal = (f: keyof Machine) =>
    (editValues as Record<string, unknown>)[f] as boolean | null;

  // ── Drawer content renderer ─────────────────────────────────────────────────

  function renderDrawerContent(m: Machine) {
    const grid2 = {
      display: "grid",
      gridTemplateColumns: "1fr 1fr",
      gap: "0 20px",
    } as const;

    if (editing) {
      return renderEditContent(grid2);
    }

    switch (drawerTab) {
      case "overview":
        return (
          <>
            <SectionLabel>Machine Details</SectionLabel>
            <div style={grid2}>
              <Field label="Venue Group" value={m.venue_group} />
              <Field label="Location Type" value={m.location_type} />
              <Field label="Location" value={m.pod_location} />
              <Field label="Address" value={m.pod_address} />
              <Field label="Supply Source" value={m.source_of_supply} />
              <Field label="Cabinets" value={m.cabinet_count?.toString()} />
              <BoolField
                label="Include in Refill"
                value={m.include_in_refill}
              />
              <Field label="Installation Date" value={m.installation_date} />
            </div>
            <SectionLabel>Contact</SectionLabel>
            <div style={grid2}>
              <Field label="Person" value={m.contact_person} />
              <Field label="Phone" value={m.contact_phone} />
              <Field label="Email" value={m.contact_email} />
            </div>
            {m.notes && (
              <>
                <SectionLabel>Notes</SectionLabel>
                <div
                  style={{
                    fontSize: 13,
                    color: "#4a4845",
                    background: "#faf9f7",
                    borderRadius: 8,
                    padding: "12px 14px",
                    lineHeight: 1.5,
                  }}
                >
                  {m.notes}
                </div>
              </>
            )}
          </>
        );

      case "adyen":
        return (
          <>
            <SectionLabel>Adyen Configuration</SectionLabel>
            <div style={grid2}>
              <Field label="Adyen Status" value={m.adyen_status} />
              <BoolField
                label="Inventory In-Store"
                value={m.adyen_inventory_in_store}
              />
              <Field
                label="Unique Terminal ID"
                value={m.adyen_unique_terminal_id}
              />
              <Field
                label="Permanent Terminal ID"
                value={m.adyen_permanent_terminal_id}
              />
              <Field label="Store Code" value={m.adyen_store_code} />
              <Field
                label="Store Description"
                value={m.adyen_store_description}
              />
              <BoolField
                label="Fridge Assigned"
                value={m.adyen_fridge_assigned}
              />
              <Field label="Shipment Batch" value={m.shipment_batch_nbr} />
            </div>
            <SectionLabel>Software</SectionLabel>
            <div style={grid2}>
              <Field label="Micron App ID" value={m.micron_app_id} />
              <Field label="App Version" value={m.app_version} />
              <Field label="Micron Version" value={m.micron_version} />
            </div>
          </>
        );

      case "payment":
        return (
          <>
            <SectionLabel>Payment Setup Checklist</SectionLabel>
            <div style={grid2}>
              <BoolField
                label="Terminal Installed"
                value={m.payment_terminal_installed}
              />
              <BoolField
                label="Micron BO Setup"
                value={m.payment_micron_bo_setup}
              />
              <BoolField
                label="Adyen Store Created"
                value={m.payment_adyen_store_created}
              />
              <BoolField
                label="Connect Store &rarr; Terminal"
                value={m.payment_connect_store_terminal}
              />
              <BoolField
                label="General UI Updated"
                value={m.payment_general_ui_updated}
              />
              <BoolField
                label="POS Hide Button"
                value={m.payment_pos_hide_button}
              />
              <BoolField label="App Deployed" value={m.payment_app_deployed} />
              <BoolField
                label="App Deployed Terminal"
                value={m.payment_app_deployed_terminal}
              />
              <BoolField label="Kiosk Mode" value={m.payment_kiosk_mode} />
              <BoolField label="Fan Test" value={m.payment_fan_test} />
            </div>
          </>
        );

      case "hardware":
        return (
          <>
            <SectionLabel>Hardware Checks</SectionLabel>
            <div style={grid2}>
              <BoolField label="Compressor OK" value={m.hw_compressor_ok} />
              <BoolField label="Calibration OK" value={m.hw_calibration_ok} />
              <BoolField label="Door Spring OK" value={m.hw_door_spring_ok} />
              <BoolField label="Test Successful" value={m.hw_test_successful} />
            </div>
            <SectionLabel>Identity</SectionLabel>
            <div style={grid2}>
              <Field label="Serial Number" value={m.serial_number} />
              <Field label="Shipment Batch" value={m.shipment_batch_nbr} />
            </div>
          </>
        );

      case "wifi":
        return (
          <>
            <SectionLabel>WiFi Configuration</SectionLabel>
            <div style={grid2}>
              <Field label="Network Name" value={m.wifi_network_name} />
              <Field label="MAC Address" value={m.wifi_mac_address} />
              <Field label="Device Hostname" value={m.wifi_device_hostname} />
              <Field label="Serial Number" value={m.serial_number} />
            </div>
          </>
        );
    }
  }

  // ── Edit mode content ───────────────────────────────────────────────────────

  function renderEditContent(grid2: React.CSSProperties) {
    switch (drawerTab) {
      case "overview":
        return (
          <>
            <SectionLabel>Machine Details</SectionLabel>
            <div style={grid2}>
              <EditableField
                label="Official Name"
                field="official_name"
                value={strVal("official_name")}
                onChange={updateField}
              />
              <EditableSelectWithAdd
                label="Venue Group"
                field="venue_group"
                value={strVal("venue_group")}
                options={venueGroups}
                onChange={updateField}
                onAddNew={() => setAddGroupOpen(true)}
                addLabel="+ Add new venue group…"
              />
              <EditableSelect
                label="Location Type"
                field="location_type"
                value={strVal("location_type")}
                options={LOCATION_TYPE_OPTIONS}
                onChange={updateField}
              />
              <EditableSelect
                label="Status"
                field="status"
                value={strVal("status")}
                options={STATUS_OPTIONS}
                onChange={updateField}
              />
              <EditableField
                label="Location"
                field="pod_location"
                value={strVal("pod_location")}
                onChange={updateField}
              />
              <EditableField
                label="Address"
                field="pod_address"
                value={strVal("pod_address")}
                onChange={updateField}
              />
              <EditableField
                label="Supply Source"
                field="source_of_supply"
                value={strVal("source_of_supply")}
                onChange={updateField}
              />
              <EditableField
                label="Cabinets"
                field="cabinet_count"
                type="number"
                value={strVal("cabinet_count")}
                onChange={updateField}
              />
              <EditableBoolField
                label="Include in Refill"
                field="include_in_refill"
                value={boolVal("include_in_refill")}
                onChange={updateField}
              />
              <EditableField
                label="Installation Date"
                field="installation_date"
                type="date"
                value={strVal("installation_date")}
                onChange={updateField}
              />
            </div>
            <SectionLabel>Contact</SectionLabel>
            <div style={grid2}>
              <EditableField
                label="Person"
                field="contact_person"
                value={strVal("contact_person")}
                onChange={updateField}
              />
              <EditableField
                label="Phone"
                field="contact_phone"
                value={strVal("contact_phone")}
                onChange={updateField}
              />
              <EditableField
                label="Email"
                field="contact_email"
                type="email"
                value={strVal("contact_email")}
                onChange={updateField}
              />
            </div>
            <SectionLabel>Notes</SectionLabel>
            <div style={{ marginBottom: 14 }}>
              <textarea
                value={(editValues.notes as string) ?? ""}
                onChange={(e) =>
                  setEditValues((prev) => ({ ...prev, notes: e.target.value }))
                }
                rows={4}
                style={{
                  ...inputStyle,
                  resize: "vertical",
                  fontFamily: "'Plus Jakarta Sans', sans-serif",
                }}
              />
            </div>
          </>
        );

      case "adyen":
        return (
          <>
            <SectionLabel>Adyen Configuration</SectionLabel>
            <div style={grid2}>
              <EditableSelect
                label="Adyen Status"
                field="adyen_status"
                value={strVal("adyen_status")}
                options={ADYEN_STATUS_OPTIONS}
                onChange={updateField}
              />
              <EditableBoolField
                label="Inventory In-Store"
                field="adyen_inventory_in_store"
                value={boolVal("adyen_inventory_in_store")}
                onChange={updateField}
              />
              <EditableField
                label="Unique Terminal ID"
                field="adyen_unique_terminal_id"
                value={strVal("adyen_unique_terminal_id")}
                onChange={updateField}
              />
              <EditableField
                label="Permanent Terminal ID"
                field="adyen_permanent_terminal_id"
                value={strVal("adyen_permanent_terminal_id")}
                onChange={updateField}
              />
              <EditableField
                label="Store Code"
                field="adyen_store_code"
                value={strVal("adyen_store_code")}
                onChange={updateField}
              />
              <EditableField
                label="Store Description"
                field="adyen_store_description"
                value={strVal("adyen_store_description")}
                onChange={updateField}
              />
              <EditableBoolField
                label="Fridge Assigned"
                field="adyen_fridge_assigned"
                value={boolVal("adyen_fridge_assigned")}
                onChange={updateField}
              />
              <EditableField
                label="Shipment Batch"
                field="shipment_batch_nbr"
                value={strVal("shipment_batch_nbr")}
                onChange={updateField}
              />
            </div>
            <SectionLabel>Software</SectionLabel>
            <div style={grid2}>
              <EditableField
                label="Micron App ID"
                field="micron_app_id"
                value={strVal("micron_app_id")}
                onChange={updateField}
              />
              <EditableField
                label="App Version"
                field="app_version"
                value={strVal("app_version")}
                onChange={updateField}
              />
              <EditableField
                label="Micron Version"
                field="micron_version"
                value={strVal("micron_version")}
                onChange={updateField}
              />
            </div>
          </>
        );

      case "payment":
        return (
          <>
            <SectionLabel>Payment Setup Checklist</SectionLabel>
            <div style={grid2}>
              <EditableBoolField
                label="Terminal Installed"
                field="payment_terminal_installed"
                value={boolVal("payment_terminal_installed")}
                onChange={updateField}
              />
              <EditableBoolField
                label="Micron BO Setup"
                field="payment_micron_bo_setup"
                value={boolVal("payment_micron_bo_setup")}
                onChange={updateField}
              />
              <EditableBoolField
                label="Adyen Store Created"
                field="payment_adyen_store_created"
                value={boolVal("payment_adyen_store_created")}
                onChange={updateField}
              />
              <EditableBoolField
                label="Connect Store &rarr; Terminal"
                field="payment_connect_store_terminal"
                value={boolVal("payment_connect_store_terminal")}
                onChange={updateField}
              />
              <EditableBoolField
                label="General UI Updated"
                field="payment_general_ui_updated"
                value={boolVal("payment_general_ui_updated")}
                onChange={updateField}
              />
              <EditableBoolField
                label="POS Hide Button"
                field="payment_pos_hide_button"
                value={boolVal("payment_pos_hide_button")}
                onChange={updateField}
              />
              <EditableBoolField
                label="App Deployed"
                field="payment_app_deployed"
                value={boolVal("payment_app_deployed")}
                onChange={updateField}
              />
              <EditableBoolField
                label="App Deployed Terminal"
                field="payment_app_deployed_terminal"
                value={boolVal("payment_app_deployed_terminal")}
                onChange={updateField}
              />
              <EditableBoolField
                label="Kiosk Mode"
                field="payment_kiosk_mode"
                value={boolVal("payment_kiosk_mode")}
                onChange={updateField}
              />
              <EditableBoolField
                label="Fan Test"
                field="payment_fan_test"
                value={boolVal("payment_fan_test")}
                onChange={updateField}
              />
            </div>
          </>
        );

      case "hardware":
        return (
          <>
            <SectionLabel>Hardware Checks</SectionLabel>
            <div style={grid2}>
              <EditableBoolField
                label="Compressor OK"
                field="hw_compressor_ok"
                value={boolVal("hw_compressor_ok")}
                onChange={updateField}
              />
              <EditableBoolField
                label="Calibration OK"
                field="hw_calibration_ok"
                value={boolVal("hw_calibration_ok")}
                onChange={updateField}
              />
              <EditableBoolField
                label="Door Spring OK"
                field="hw_door_spring_ok"
                value={boolVal("hw_door_spring_ok")}
                onChange={updateField}
              />
              <EditableBoolField
                label="Test Successful"
                field="hw_test_successful"
                value={boolVal("hw_test_successful")}
                onChange={updateField}
              />
            </div>
            <SectionLabel>Identity</SectionLabel>
            <div style={grid2}>
              <EditableField
                label="Serial Number"
                field="serial_number"
                value={strVal("serial_number")}
                onChange={updateField}
              />
              <EditableField
                label="Shipment Batch"
                field="shipment_batch_nbr"
                value={strVal("shipment_batch_nbr")}
                onChange={updateField}
              />
            </div>
          </>
        );

      case "wifi":
        return (
          <>
            <SectionLabel>WiFi Configuration</SectionLabel>
            <div style={grid2}>
              <EditableField
                label="Network Name"
                field="wifi_network_name"
                value={strVal("wifi_network_name")}
                onChange={updateField}
              />
              <EditableField
                label="MAC Address"
                field="wifi_mac_address"
                value={strVal("wifi_mac_address")}
                onChange={updateField}
              />
              <EditableField
                label="Device Hostname"
                field="wifi_device_hostname"
                value={strVal("wifi_device_hostname")}
                onChange={updateField}
              />
              <EditableField
                label="Serial Number"
                field="serial_number"
                value={strVal("serial_number")}
                onChange={updateField}
              />
            </div>
          </>
        );
    }
  }

  return (
    <div className="p-8 max-w-7xl">
      {/* ── Header ──────────────────────────────────────────────────────────── */}
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1
            style={{
              fontFamily: "'Plus Jakarta Sans', sans-serif",
              fontWeight: 800,
              fontSize: 28,
              letterSpacing: "-0.02em",
              color: "#0a0a0a",
              margin: 0,
            }}
          >
            Machines
          </h1>
          <p style={{ color: "#6b6860", fontSize: 14, marginTop: 4 }}>
            {loading ? "Loading\u2026" : `${machines.length} machines`}
          </p>
        </div>
      </div>

      {/* ── Filter bar ──────────────────────────────────────────────────────── */}
      <div
        className="flex items-center gap-3 flex-wrap mb-6"
        style={{ borderBottom: "1px solid #e8e4de", paddingBottom: 16 }}
      >
        <input
          type="text"
          placeholder="Search by name or device number\u2026"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          style={{
            border: "1px solid #e8e4de",
            borderRadius: 8,
            padding: "7px 12px",
            fontSize: 14,
            width: 280,
            outline: "none",
            color: "#0a0a0a",
            background: "white",
          }}
        />
        {(["All", "Active", "Inactive"] as const).map((s) => (
          <button
            key={s}
            onClick={() => setStatusFilter(s)}
            style={{
              border: "1px solid #e8e4de",
              borderRadius: 8,
              padding: "7px 14px",
              fontSize: 13,
              fontWeight: statusFilter === s ? 600 : 400,
              background: statusFilter === s ? "#0a0a0a" : "white",
              color: statusFilter === s ? "white" : "#6b6860",
              cursor: "pointer",
            }}
          >
            {s}
          </button>
        ))}
        <select
          value={groupFilter}
          onChange={(e) => setGroupFilter(e.target.value)}
          style={{
            border: "1px solid #e8e4de",
            borderRadius: 8,
            padding: "7px 12px",
            fontSize: 13,
            color: "#0a0a0a",
            background: "white",
            cursor: "pointer",
          }}
        >
          {groups.map((g) => (
            <option key={g} value={g}>
              {g === "All" ? "All groups" : g}
            </option>
          ))}
        </select>
        {!loading && (
          <span style={{ marginLeft: "auto", fontSize: 13, color: "#6b6860" }}>
            {filtered.length} result{filtered.length !== 1 ? "s" : ""}
          </span>
        )}
      </div>

      {/* ── Table ───────────────────────────────────────────────────────────── */}
      <div
        style={{
          background: "white",
          border: "1px solid #e8e4de",
          borderRadius: 12,
          overflow: "hidden",
        }}
      >
        <table className="w-full text-sm">
          <thead>
            <tr style={{ borderBottom: "1px solid #e8e4de" }}>
              {[
                "Name",
                "Device #",
                "Group",
                "Location",
                "Adyen Status",
                "In-Store",
                "Refill",
                "Status",
              ].map((h) => (
                <th
                  key={h}
                  className="text-left px-4 py-3"
                  style={{
                    fontSize: 11,
                    fontWeight: 500,
                    letterSpacing: "0.06em",
                    textTransform: "uppercase",
                    color: "#6b6860",
                  }}
                >
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {loading ? (
              Array.from({ length: 8 }).map((_, i) => (
                <tr key={i} style={{ borderBottom: "1px solid #f5f2ee" }}>
                  {[200, 90, 80, 140, 100, 60, 50, 70].map((w, j) => (
                    <td key={j} className="px-4 py-3">
                      <div
                        className="animate-pulse rounded"
                        style={{ height: 14, width: w, background: "#f0ede8" }}
                      />
                    </td>
                  ))}
                </tr>
              ))
            ) : filtered.length === 0 ? (
              <tr>
                <td
                  colSpan={8}
                  className="px-4 py-10 text-center"
                  style={{ color: "#6b6860" }}
                >
                  No machines match your filters.
                </td>
              </tr>
            ) : (
              filtered.map((m) => {
                const isActive = m.status?.toLowerCase() === "active";
                const isSelected = selected?.machine_id === m.machine_id;
                return (
                  <tr
                    key={m.machine_id}
                    style={{
                      borderBottom: "1px solid #f5f2ee",
                      cursor: "pointer",
                      background: isSelected ? "#f0fdf4" : undefined,
                    }}
                    onClick={() => {
                      setSelected(m);
                      setDrawerTab("overview");
                      setEditing(false);
                      setEditValues({});
                    }}
                    onMouseEnter={(e) => {
                      if (!isSelected)
                        (
                          e.currentTarget as HTMLTableRowElement
                        ).style.background = "#faf9f7";
                    }}
                    onMouseLeave={(e) => {
                      if (!isSelected)
                        (
                          e.currentTarget as HTMLTableRowElement
                        ).style.background = "transparent";
                    }}
                  >
                    <td
                      className="px-4 py-3"
                      style={{ fontWeight: 600, color: "#24544a" }}
                    >
                      {m.official_name}
                    </td>
                    <td
                      className="px-4 py-3"
                      style={{
                        color: "#6b6860",
                        fontFamily:
                          "ui-monospace, SFMono-Regular, Menlo, monospace",
                        fontSize: 12,
                      }}
                      title={m.adyen_store_code ?? undefined}
                    >
                      {deviceNumber(m) ?? "—"}
                    </td>
                    <td className="px-4 py-3" style={{ color: "#6b6860" }}>
                      {m.venue_group ?? "\u2014"}
                    </td>
                    <td
                      className="px-4 py-3 max-w-[160px] truncate"
                      style={{ color: "#0a0a0a" }}
                      title={m.pod_location ?? undefined}
                    >
                      {m.pod_location ?? "\u2014"}
                    </td>
                    <td className="px-4 py-3" style={{ color: "#6b6860" }}>
                      {m.adyen_status ?? "\u2014"}
                    </td>
                    <td className="px-4 py-3 text-center">
                      {m.adyen_inventory_in_store ? (
                        <span style={{ color: "#24544a", fontWeight: 700 }}>
                          &#10003;
                        </span>
                      ) : (
                        <span style={{ color: "#9ca3af" }}>&mdash;</span>
                      )}
                    </td>
                    <td className="px-4 py-3 text-center">
                      {m.include_in_refill ? (
                        <span style={{ color: "#24544a", fontWeight: 700 }}>
                          &#10003;
                        </span>
                      ) : (
                        <span style={{ color: "#9ca3af" }}>&mdash;</span>
                      )}
                    </td>
                    <td className="px-4 py-3">
                      <span
                        style={{
                          display: "inline-block",
                          padding: "2px 10px",
                          borderRadius: 20,
                          fontSize: 11,
                          fontWeight: 600,
                          background: isActive ? "#f0fdf4" : "#f5f2ee",
                          color: isActive ? "#065f46" : "#6b6860",
                        }}
                      >
                        {m.status ?? "\u2014"}
                      </span>
                    </td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>

      {/* ── Add new venue group modal ──────────────────────────────────────── */}
      {addGroupOpen && (
        <div
          style={{
            position: "fixed",
            inset: 0,
            zIndex: 250,
            background: "rgba(0,0,0,0.4)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
          onClick={() => !addingGroup && setAddGroupOpen(false)}
        >
          <div
            onClick={(e) => e.stopPropagation()}
            style={{
              background: "white",
              borderRadius: 12,
              padding: 24,
              width: 400,
              maxWidth: "90vw",
              fontFamily: "'Plus Jakarta Sans', sans-serif",
              boxShadow: "0 20px 50px rgba(0,0,0,0.18)",
            }}
          >
            <h3
              style={{
                fontSize: 18,
                fontWeight: 800,
                color: "#0a0a0a",
                marginTop: 0,
                marginBottom: 4,
                letterSpacing: "-0.01em",
              }}
            >
              Add Venue Group
            </h3>
            <p style={{ fontSize: 13, color: "#6b6860", marginBottom: 18 }}>
              Code is uppercase and used as the unique identifier in the
              database.
            </p>
            <div style={{ marginBottom: 14 }}>
              <FieldLabel>Code</FieldLabel>
              <input
                value={newGroupCode}
                onChange={(e) =>
                  setNewGroupCode(e.target.value.toUpperCase())
                }
                placeholder="e.g. NOVO"
                autoFocus
                style={inputStyle}
              />
            </div>
            <div style={{ marginBottom: 18 }}>
              <FieldLabel>Display Name</FieldLabel>
              <input
                value={newGroupName}
                onChange={(e) => setNewGroupName(e.target.value)}
                placeholder="e.g. NOVO Cinemas"
                style={inputStyle}
              />
            </div>
            <div style={{ display: "flex", gap: 8 }}>
              <button
                onClick={() => setAddGroupOpen(false)}
                disabled={addingGroup}
                style={cancelBtnStyle}
              >
                Cancel
              </button>
              <button
                onClick={handleAddVenueGroup}
                disabled={addingGroup || !newGroupCode.trim()}
                style={{
                  ...saveBtnStyle,
                  opacity:
                    addingGroup || !newGroupCode.trim() ? 0.6 : 1,
                  cursor:
                    addingGroup || !newGroupCode.trim()
                      ? "not-allowed"
                      : "pointer",
                }}
              >
                {addingGroup ? "Adding\u2026" : "Add Group"}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Toast ──────────────────────────────────────────────────────────── */}
      {toast && (
        <div
          style={{
            position: "fixed",
            bottom: 24,
            right: 24,
            zIndex: 200,
            display: "flex",
            alignItems: "center",
            gap: 8,
            padding: "10px 16px",
            borderRadius: 8,
            fontSize: 14,
            fontWeight: 600,
            boxShadow: "0 10px 25px rgba(0,0,0,0.12)",
            background: toast.type === "success" ? "#ecfdf5" : "#fef2f2",
            color: toast.type === "success" ? "#065f46" : "#991b1b",
            border:
              toast.type === "success"
                ? "1px solid #a7f3d0"
                : "1px solid #fecaca",
          }}
        >
          <span>{toast.type === "success" ? "\u2713" : "\u2715"}</span>
          {toast.message}
        </div>
      )}

      {/* ── Slide-over drawer ──────────────────────────────────────────────── */}
      {selected && (
        <div className="fixed inset-0 z-50 flex">
          {/* Backdrop */}
          <div
            className="flex-1"
            style={{ background: "rgba(0,0,0,0.3)" }}
            onClick={closeDrawer}
          />
          {/* Panel */}
          <div
            style={{
              width: 520,
              maxWidth: "100vw",
              background: "white",
              height: "100%",
              display: "flex",
              flexDirection: "column",
              boxShadow: "-4px 0 24px rgba(0,0,0,0.08)",
              fontFamily: "'Plus Jakarta Sans', sans-serif",
            }}
          >
            {/* Header */}
            <div
              style={{
                padding: "20px 24px",
                borderBottom: "1px solid #e8e4de",
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between",
              }}
            >
              <div>
                <h2
                  style={{
                    fontSize: 20,
                    fontWeight: 800,
                    color: "#0a0a0a",
                    margin: 0,
                    letterSpacing: "-0.02em",
                  }}
                >
                  {selected.official_name}
                </h2>
                <p style={{ color: "#6b6860", fontSize: 13, marginTop: 2 }}>
                  {selected.venue_group ?? "\u2014"} &middot;{" "}
                  {selected.status ?? "\u2014"}
                  {editing && (
                    <span
                      style={{
                        marginLeft: 8,
                        fontSize: 11,
                        fontWeight: 700,
                        color: "#e1b460",
                        textTransform: "uppercase",
                        letterSpacing: "0.06em",
                      }}
                    >
                      Editing
                    </span>
                  )}
                </p>
              </div>
              <button
                onClick={closeDrawer}
                style={{
                  fontSize: 20,
                  color: "#6b6860",
                  background: "none",
                  border: "none",
                  cursor: "pointer",
                }}
              >
                &#10005;
              </button>
            </div>

            {/* Tabs */}
            <div
              style={{
                display: "flex",
                borderBottom: "1px solid #e8e4de",
              }}
            >
              {DRAWER_TABS.map((t) => (
                <button
                  key={t.key}
                  onClick={() => setDrawerTab(t.key)}
                  style={{
                    flex: 1,
                    padding: "10px 8px",
                    fontSize: 12,
                    fontWeight: drawerTab === t.key ? 700 : 400,
                    color: drawerTab === t.key ? "#24544a" : "#6b6860",
                    background: "none",
                    border: "none",
                    borderBottom:
                      drawerTab === t.key
                        ? "2px solid #24544a"
                        : "2px solid transparent",
                    cursor: "pointer",
                  }}
                >
                  {t.label}
                </button>
              ))}
            </div>

            {/* Content */}
            <div
              style={{ flex: 1, overflow: "auto", padding: "4px 24px 24px" }}
            >
              {renderDrawerContent(selected)}
            </div>

            {/* Footer */}
            <div
              style={{
                padding: "14px 24px",
                borderTop: "1px solid #e8e4de",
              }}
            >
              {editing ? (
                <div style={{ display: "flex", gap: 8 }}>
                  <button onClick={cancelEditing} style={cancelBtnStyle}>
                    Cancel
                  </button>
                  <button
                    onClick={handleSave}
                    disabled={saving}
                    style={{
                      ...saveBtnStyle,
                      opacity: saving ? 0.7 : 1,
                      cursor: saving ? "not-allowed" : "pointer",
                    }}
                  >
                    {saving ? "Saving\u2026" : "Save Changes"}
                  </button>
                </div>
              ) : (
                <button onClick={startEditing} style={editBtnStyle}>
                  Edit Machine
                </button>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
