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

  const filtered = useMemo(() => {
    return machines.filter((m) => {
      if (
        search &&
        !m.official_name.toLowerCase().includes(search.toLowerCase())
      )
        return false;
      if (statusFilter !== "All") {
        const isActive = m.status?.toLowerCase() === "active";
        if (statusFilter === "Active" && !isActive) return false;
        if (statusFilter === "Inactive" && isActive) return false;
      }
      if (groupFilter !== "All" && m.venue_group !== groupFilter) return false;
      return true;
    });
  }, [machines, search, statusFilter, groupFilter]);

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
    const supabase = createClient();
    const { error } = await supabase
      .from("machines")
      .update(editValues)
      .eq("machine_id", selected.machine_id);

    if (!error) {
      setMachines((prev) =>
        prev.map((m) =>
          m.machine_id === selected.machine_id
            ? ({ ...m, ...editValues } as Machine)
            : m,
        ),
      );
      setSelected({ ...selected, ...editValues } as Machine);
      setEditing(false);
      setEditValues({});
    } else {
      console.error("save error:", error);
    }
    setSaving(false);
  }, [selected, editValues]);

  // Close drawer and cancel edit
  const closeDrawer = useCallback(() => {
    setSelected(null);
    setEditing(false);
    setEditValues({});
  }, []);

  // ── Editable field components ─────────────────────────────────────────────

  function EditableField({
    label,
    field,
    type = "text",
  }: {
    label: string;
    field: keyof Machine;
    type?: string;
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
            marginBottom: 3,
          }}
        >
          {label}
        </div>
        <input
          type={type}
          value={
            ((editValues as Record<string, unknown>)[field] as string) ?? ""
          }
          onChange={(e) =>
            setEditValues((prev) => ({
              ...prev,
              [field]:
                type === "number"
                  ? e.target.value === ""
                    ? null
                    : Number(e.target.value)
                  : e.target.value,
            }))
          }
          style={inputStyle}
        />
      </div>
    );
  }

  function EditableBoolField({
    label,
    field,
  }: {
    label: string;
    field: keyof Machine;
  }) {
    const val = (editValues as Record<string, unknown>)[field] as
      | boolean
      | null;
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
            setEditValues((prev) => ({
              ...prev,
              [field]: val === true ? false : val === false ? null : true,
            }))
          }
          style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 6,
            padding: "5px 12px",
            borderRadius: 6,
            border: "1px solid #e8e4de",
            background:
              val === true ? "#f0fdf4" : val === false ? "#fef2f2" : "#faf9f7",
            color:
              val === true ? "#065f46" : val === false ? "#991b1b" : "#6b6860",
            fontSize: 13,
            fontWeight: 600,
            cursor: "pointer",
          }}
        >
          {val === true ? "Yes" : val === false ? "No" : "Not set"}
        </button>
      </div>
    );
  }

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
              <EditableField label="Official Name" field="official_name" />
              <EditableField label="Venue Group" field="venue_group" />
              <EditableField label="Location Type" field="location_type" />
              <EditableField label="Status" field="status" />
              <EditableField label="Location" field="pod_location" />
              <EditableField label="Address" field="pod_address" />
              <EditableField label="Supply Source" field="source_of_supply" />
              <EditableField
                label="Cabinets"
                field="cabinet_count"
                type="number"
              />
              <EditableBoolField
                label="Include in Refill"
                field="include_in_refill"
              />
              <EditableField
                label="Installation Date"
                field="installation_date"
                type="date"
              />
            </div>
            <SectionLabel>Contact</SectionLabel>
            <div style={grid2}>
              <EditableField label="Person" field="contact_person" />
              <EditableField label="Phone" field="contact_phone" />
              <EditableField label="Email" field="contact_email" type="email" />
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
              <EditableField label="Adyen Status" field="adyen_status" />
              <EditableBoolField
                label="Inventory In-Store"
                field="adyen_inventory_in_store"
              />
              <EditableField
                label="Unique Terminal ID"
                field="adyen_unique_terminal_id"
              />
              <EditableField
                label="Permanent Terminal ID"
                field="adyen_permanent_terminal_id"
              />
              <EditableField label="Store Code" field="adyen_store_code" />
              <EditableField
                label="Store Description"
                field="adyen_store_description"
              />
              <EditableBoolField
                label="Fridge Assigned"
                field="adyen_fridge_assigned"
              />
              <EditableField
                label="Shipment Batch"
                field="shipment_batch_nbr"
              />
            </div>
            <SectionLabel>Software</SectionLabel>
            <div style={grid2}>
              <EditableField label="Micron App ID" field="micron_app_id" />
              <EditableField label="App Version" field="app_version" />
              <EditableField label="Micron Version" field="micron_version" />
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
              />
              <EditableBoolField
                label="Micron BO Setup"
                field="payment_micron_bo_setup"
              />
              <EditableBoolField
                label="Adyen Store Created"
                field="payment_adyen_store_created"
              />
              <EditableBoolField
                label="Connect Store &rarr; Terminal"
                field="payment_connect_store_terminal"
              />
              <EditableBoolField
                label="General UI Updated"
                field="payment_general_ui_updated"
              />
              <EditableBoolField
                label="POS Hide Button"
                field="payment_pos_hide_button"
              />
              <EditableBoolField
                label="App Deployed"
                field="payment_app_deployed"
              />
              <EditableBoolField
                label="App Deployed Terminal"
                field="payment_app_deployed_terminal"
              />
              <EditableBoolField
                label="Kiosk Mode"
                field="payment_kiosk_mode"
              />
              <EditableBoolField label="Fan Test" field="payment_fan_test" />
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
              />
              <EditableBoolField
                label="Calibration OK"
                field="hw_calibration_ok"
              />
              <EditableBoolField
                label="Door Spring OK"
                field="hw_door_spring_ok"
              />
              <EditableBoolField
                label="Test Successful"
                field="hw_test_successful"
              />
            </div>
            <SectionLabel>Identity</SectionLabel>
            <div style={grid2}>
              <EditableField label="Serial Number" field="serial_number" />
              <EditableField
                label="Shipment Batch"
                field="shipment_batch_nbr"
              />
            </div>
          </>
        );

      case "wifi":
        return (
          <>
            <SectionLabel>WiFi Configuration</SectionLabel>
            <div style={grid2}>
              <EditableField label="Network Name" field="wifi_network_name" />
              <EditableField label="MAC Address" field="wifi_mac_address" />
              <EditableField
                label="Device Hostname"
                field="wifi_device_hostname"
              />
              <EditableField label="Serial Number" field="serial_number" />
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
          placeholder="Search machines\u2026"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          style={{
            border: "1px solid #e8e4de",
            borderRadius: 8,
            padding: "7px 12px",
            fontSize: 14,
            width: 240,
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
                  {[200, 80, 140, 100, 60, 50, 70].map((w, j) => (
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
                  colSpan={7}
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
