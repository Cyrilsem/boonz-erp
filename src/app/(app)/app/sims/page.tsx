"use client";

import { useEffect, useState, useMemo } from "react";
import { createClient } from "@/lib/supabase/client";

// ─── Types ────────────────────────────────────────────────────────────────────

interface SimCard {
  sim_id: string;
  sim_ref: string | null;
  sim_serial: string | null;
  sim_code: string | null;
  sim_date: string | null;
  sim_renewal: string | null;
  contact_number: string | null;
  puk1: string | null;
  puk2: string | null;
  machine_id: string | null;
  machine_name: string | null;
  is_active: boolean | null;
  notes: string | null;
  created_at: string | null;
  updated_at: string | null;
  paid_by: string | null;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function formatDate(dateStr: string | null): string {
  if (!dateStr) return "\u2014";
  const d = new Date(dateStr + "T00:00:00");
  return d.toLocaleDateString("en-AE", {
    day: "numeric",
    month: "short",
    year: "2-digit",
  });
}

function formatTimestamp(ts: string | null): string {
  if (!ts) return "\u2014";
  const d = new Date(ts);
  return d.toLocaleDateString("en-AE", {
    day: "numeric",
    month: "short",
    year: "2-digit",
  });
}

function renewalStyle(dateStr: string | null): React.CSSProperties {
  if (!dateStr) return { color: "#6b6860" };
  const days = Math.floor(
    (new Date(dateStr + "T00:00:00").getTime() - Date.now()) / 86400000,
  );
  if (days < 0) return { color: "#dc2626", fontWeight: 700 };
  if (days <= 30) return { color: "#d97706", fontWeight: 600 };
  return { color: "#6b6860" };
}

function daysUntilRenewal(dateStr: string | null): number | null {
  if (!dateStr) return null;
  return Math.floor(
    (new Date(dateStr + "T00:00:00").getTime() - Date.now()) / 86400000,
  );
}

function lastChars(str: string | null, n: number): string {
  if (!str) return "\u2014";
  return str.length > n ? str.slice(-n) : str;
}

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

// ─── Add SIM Form ─────────────────────────────────────────────────────────────

const EMPTY_FORM = {
  sim_ref: "",
  sim_serial: "",
  sim_code: "",
  sim_date: "",
  sim_renewal: "",
  contact_number: "",
  puk1: "",
  puk2: "",
  machine_name: "",
  paid_by: "",
  notes: "",
  is_active: true,
};

function FormField({
  label,
  name,
  value,
  onChange,
  type = "text",
  placeholder,
}: {
  label: string;
  name: string;
  value: string;
  onChange: (name: string, value: string) => void;
  type?: string;
  placeholder?: string;
}) {
  return (
    <div style={{ marginBottom: 16 }}>
      <label
        style={{
          display: "block",
          fontSize: 11,
          fontWeight: 500,
          letterSpacing: "0.06em",
          textTransform: "uppercase",
          color: "#6b6860",
          marginBottom: 4,
        }}
      >
        {label}
      </label>
      <input
        type={type}
        value={value}
        onChange={(e) => onChange(name, e.target.value)}
        placeholder={placeholder}
        style={{
          width: "100%",
          border: "1px solid #e8e4de",
          borderRadius: 8,
          padding: "8px 12px",
          fontSize: 14,
          color: "#0a0a0a",
          background: "white",
          outline: "none",
          fontFamily: "'Plus Jakarta Sans', sans-serif",
        }}
      />
    </div>
  );
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function SimsPage() {
  const [sims, setSims] = useState<SimCard[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState<
    "All" | "Active" | "Inactive"
  >("All");
  const [selected, setSelected] = useState<SimCard | null>(null);

  // Add SIM drawer
  const [addOpen, setAddOpen] = useState(false);
  const [addForm, setAddForm] = useState({ ...EMPTY_FORM });
  const [addSaving, setAddSaving] = useState(false);

  // ESC key to close drawers
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        setSelected(null);
        setAddOpen(false);
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, []);

  // Fetch SIM cards
  useEffect(() => {
    async function load() {
      const supabase = createClient();
      const { data, error } = await supabase
        .from("sim_cards")
        .select("*")
        .order("sim_renewal", { ascending: true, nullsFirst: false })
        .limit(10000);
      if (error) console.error("sim_cards fetch error:", error);
      setSims(data ?? []);
      setLoading(false);
    }
    load();
  }, []);

  // Expiring SIMs count (within 30 days or past)
  const expiringCount = useMemo(() => {
    return sims.filter((s) => {
      const d = daysUntilRenewal(s.sim_renewal);
      return d !== null && d <= 30;
    }).length;
  }, [sims]);

  // Filtered list
  const filtered = useMemo(() => {
    return sims.filter((s) => {
      if (search) {
        const q = search.toLowerCase();
        const matchRef = s.sim_ref?.toLowerCase().includes(q);
        const matchContact = s.contact_number?.toLowerCase().includes(q);
        const matchMachine = s.machine_name?.toLowerCase().includes(q);
        if (!matchRef && !matchContact && !matchMachine) return false;
      }
      if (statusFilter !== "All") {
        if (statusFilter === "Active" && s.is_active !== true) return false;
        if (statusFilter === "Inactive" && s.is_active !== false) return false;
      }
      return true;
    });
  }, [sims, search, statusFilter]);

  // Add form handler
  function handleFormChange(name: string, value: string) {
    setAddForm((prev) => ({ ...prev, [name]: value }));
  }

  async function handleAddSim() {
    setAddSaving(true);
    const supabase = createClient();
    const payload: Record<string, unknown> = {
      sim_ref: addForm.sim_ref || null,
      sim_serial: addForm.sim_serial || null,
      sim_code: addForm.sim_code || null,
      sim_date: addForm.sim_date || null,
      sim_renewal: addForm.sim_renewal || null,
      contact_number: addForm.contact_number || null,
      puk1: addForm.puk1 || null,
      puk2: addForm.puk2 || null,
      machine_name: addForm.machine_name || null,
      paid_by: addForm.paid_by || null,
      notes: addForm.notes || null,
      is_active: addForm.is_active,
    };
    const { data, error } = await supabase
      .from("sim_cards")
      .insert(payload)
      .select("*")
      .limit(10000);
    if (error) {
      console.error("add sim error:", error);
      alert("Failed to add SIM card: " + error.message);
    } else if (data && data.length > 0) {
      setSims((prev) => [...prev, data[0] as SimCard]);
      setAddForm({ ...EMPTY_FORM });
      setAddOpen(false);
    }
    setAddSaving(false);
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
            SIM Cards
          </h1>
          <p style={{ color: "#6b6860", fontSize: 14, marginTop: 4 }}>
            {loading
              ? "Loading\u2026"
              : `${sims.length} SIM cards${
                  expiringCount > 0
                    ? ` \u00b7 ${expiringCount} expiring soon`
                    : ""
                }`}
          </p>
        </div>
        <button
          onClick={() => {
            setAddForm({ ...EMPTY_FORM });
            setAddOpen(true);
          }}
          style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 6,
            background: "#24544a",
            color: "white",
            borderRadius: 8,
            padding: "8px 16px",
            fontSize: 14,
            fontWeight: 600,
            border: "none",
            cursor: "pointer",
          }}
        >
          + Add SIM
        </button>
      </div>

      {/* ── Alert banner ────────────────────────────────────────────────────── */}
      {!loading && expiringCount > 0 && (
        <div
          style={{
            background: "#fffbeb",
            borderLeft: "4px solid #d97706",
            borderRadius: 8,
            padding: "12px 16px",
            marginBottom: 20,
            fontSize: 14,
            color: "#92400e",
            fontWeight: 500,
          }}
        >
          {"\u26a0"} {expiringCount} SIM card{expiringCount !== 1 ? "s" : ""}{" "}
          expiring within 30 days
        </div>
      )}

      {/* ── Filter bar ──────────────────────────────────────────────────────── */}
      <div
        className="flex items-center gap-3 flex-wrap mb-6"
        style={{ borderBottom: "1px solid #e8e4de", paddingBottom: 16 }}
      >
        <input
          type="text"
          placeholder="Search SIM ref, contact, machine\u2026"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          style={{
            border: "1px solid #e8e4de",
            borderRadius: 8,
            padding: "7px 12px",
            fontSize: 14,
            width: 260,
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
                "SIM Ref",
                "Serial (last 8)",
                "Contact",
                "Machine",
                "Activation",
                "Renewal",
                "Paid By",
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
                  {[120, 90, 110, 140, 80, 80, 80, 70].map((w, j) => (
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
                  No SIM cards match your filters.
                </td>
              </tr>
            ) : (
              filtered.map((s) => {
                const active = s.is_active === true;
                const isSelected = selected?.sim_id === s.sim_id;
                return (
                  <tr
                    key={s.sim_id}
                    style={{
                      borderBottom: "1px solid #f5f2ee",
                      cursor: "pointer",
                      background: isSelected ? "#f0fdf4" : undefined,
                    }}
                    onClick={() => setSelected(s)}
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
                      {s.sim_ref ?? "\u2014"}
                    </td>
                    <td
                      className="px-4 py-3"
                      style={{
                        fontFamily: "monospace",
                        fontSize: 13,
                        color: "#0a0a0a",
                      }}
                    >
                      {lastChars(s.sim_serial, 8)}
                    </td>
                    <td className="px-4 py-3" style={{ color: "#0a0a0a" }}>
                      {s.contact_number ?? "\u2014"}
                    </td>
                    <td
                      className="px-4 py-3 max-w-[160px] truncate"
                      style={{ color: "#0a0a0a" }}
                      title={s.machine_name ?? undefined}
                    >
                      {s.machine_name ?? "\u2014"}
                    </td>
                    <td className="px-4 py-3" style={{ color: "#6b6860" }}>
                      {formatDate(s.sim_date)}
                    </td>
                    <td
                      className="px-4 py-3"
                      style={renewalStyle(s.sim_renewal)}
                    >
                      {formatDate(s.sim_renewal)}
                    </td>
                    <td className="px-4 py-3" style={{ color: "#6b6860" }}>
                      {s.paid_by ?? "\u2014"}
                    </td>
                    <td className="px-4 py-3">
                      <span
                        style={{
                          display: "inline-block",
                          padding: "2px 10px",
                          borderRadius: 20,
                          fontSize: 11,
                          fontWeight: 600,
                          background: active ? "#f0fdf4" : "#f5f2ee",
                          color: active ? "#065f46" : "#6b6860",
                        }}
                      >
                        {active ? "\u2713 Active" : "Inactive"}
                      </span>
                    </td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>

      {/* ── Detail slide-over drawer ────────────────────────────────────────── */}
      {selected && (
        <div className="fixed inset-0 z-50 flex">
          {/* Backdrop */}
          <div
            className="flex-1"
            style={{ background: "rgba(0,0,0,0.3)" }}
            onClick={() => setSelected(null)}
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
              <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
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
                    {selected.sim_ref ?? "SIM Card"}
                  </h2>
                  <span
                    style={{
                      display: "inline-block",
                      marginTop: 4,
                      padding: "2px 10px",
                      borderRadius: 20,
                      fontSize: 11,
                      fontWeight: 600,
                      background:
                        selected.is_active === true ? "#f0fdf4" : "#f5f2ee",
                      color:
                        selected.is_active === true ? "#065f46" : "#6b6860",
                    }}
                  >
                    {selected.is_active === true ? "\u2713 Active" : "Inactive"}
                  </span>
                </div>
              </div>
              <button
                onClick={() => setSelected(null)}
                style={{
                  fontSize: 20,
                  color: "#6b6860",
                  background: "none",
                  border: "none",
                  cursor: "pointer",
                }}
              >
                {"\u2715"}
              </button>
            </div>

            {/* Content */}
            <div
              style={{ flex: 1, overflow: "auto", padding: "4px 24px 24px" }}
            >
              {/* SIM Details */}
              <SectionLabel>SIM Details</SectionLabel>
              <div
                style={{
                  display: "grid",
                  gridTemplateColumns: "1fr 1fr",
                  gap: "0 20px",
                }}
              >
                <Field label="SIM Ref" value={selected.sim_ref} />
                <Field
                  label="SIM Serial"
                  value={
                    selected.sim_serial ? (
                      <span style={{ fontFamily: "monospace", fontSize: 13 }}>
                        {selected.sim_serial}
                      </span>
                    ) : (
                      "\u2014"
                    )
                  }
                />
                <Field
                  label="SIM Code"
                  value={
                    selected.sim_code ? (
                      <span style={{ fontFamily: "monospace", fontSize: 13 }}>
                        {selected.sim_code}
                      </span>
                    ) : (
                      "\u2014"
                    )
                  }
                />
                <Field label="Contact Number" value={selected.contact_number} />
                <Field
                  label="PUK1"
                  value={
                    selected.puk1 ? (
                      <span style={{ fontFamily: "monospace", fontSize: 13 }}>
                        {selected.puk1}
                      </span>
                    ) : (
                      "\u2014"
                    )
                  }
                />
                <Field
                  label="PUK2"
                  value={
                    selected.puk2 ? (
                      <span style={{ fontFamily: "monospace", fontSize: 13 }}>
                        {selected.puk2}
                      </span>
                    ) : (
                      "\u2014"
                    )
                  }
                />
              </div>

              {/* Assignment */}
              <SectionLabel>Assignment</SectionLabel>
              <div
                style={{
                  display: "grid",
                  gridTemplateColumns: "1fr 1fr",
                  gap: "0 20px",
                }}
              >
                <Field label="Machine" value={selected.machine_name} />
                <Field label="Paid By" value={selected.paid_by} />
              </div>

              {/* Dates */}
              <SectionLabel>Dates</SectionLabel>
              <div
                style={{
                  display: "grid",
                  gridTemplateColumns: "1fr 1fr",
                  gap: "0 20px",
                }}
              >
                <Field
                  label="Activation Date"
                  value={formatDate(selected.sim_date)}
                />
                <Field
                  label="Renewal Date"
                  value={
                    <span style={renewalStyle(selected.sim_renewal)}>
                      {formatDate(selected.sim_renewal)}
                    </span>
                  }
                />
                <Field
                  label="Created"
                  value={formatTimestamp(selected.created_at)}
                />
                <Field
                  label="Updated"
                  value={formatTimestamp(selected.updated_at)}
                />
              </div>

              {/* Notes */}
              {selected.notes && (
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
                    {selected.notes}
                  </div>
                </>
              )}
            </div>
          </div>
        </div>
      )}

      {/* ── Add SIM slide-over drawer ───────────────────────────────────────── */}
      {addOpen && (
        <div className="fixed inset-0 z-50 flex">
          {/* Backdrop */}
          <div
            className="flex-1"
            style={{ background: "rgba(0,0,0,0.3)" }}
            onClick={() => setAddOpen(false)}
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
              <h2
                style={{
                  fontSize: 20,
                  fontWeight: 800,
                  color: "#0a0a0a",
                  margin: 0,
                  letterSpacing: "-0.02em",
                }}
              >
                Add SIM Card
              </h2>
              <button
                onClick={() => setAddOpen(false)}
                style={{
                  fontSize: 20,
                  color: "#6b6860",
                  background: "none",
                  border: "none",
                  cursor: "pointer",
                }}
              >
                {"\u2715"}
              </button>
            </div>

            {/* Form content */}
            <div
              style={{ flex: 1, overflow: "auto", padding: "20px 24px 24px" }}
            >
              <FormField
                label="SIM Ref"
                name="sim_ref"
                value={addForm.sim_ref}
                onChange={handleFormChange}
                placeholder="e.g. SIM-001"
              />
              <FormField
                label="SIM Serial"
                name="sim_serial"
                value={addForm.sim_serial}
                onChange={handleFormChange}
                placeholder="Full serial number"
              />
              <FormField
                label="SIM Code"
                name="sim_code"
                value={addForm.sim_code}
                onChange={handleFormChange}
              />
              <FormField
                label="Contact Number"
                name="contact_number"
                value={addForm.contact_number}
                onChange={handleFormChange}
                placeholder="+971..."
              />
              <div
                style={{
                  display: "grid",
                  gridTemplateColumns: "1fr 1fr",
                  gap: "0 16px",
                }}
              >
                <FormField
                  label="PUK1"
                  name="puk1"
                  value={addForm.puk1}
                  onChange={handleFormChange}
                />
                <FormField
                  label="PUK2"
                  name="puk2"
                  value={addForm.puk2}
                  onChange={handleFormChange}
                />
              </div>
              <div
                style={{
                  display: "grid",
                  gridTemplateColumns: "1fr 1fr",
                  gap: "0 16px",
                }}
              >
                <FormField
                  label="Activation Date"
                  name="sim_date"
                  value={addForm.sim_date}
                  onChange={handleFormChange}
                  type="date"
                />
                <FormField
                  label="Renewal Date"
                  name="sim_renewal"
                  value={addForm.sim_renewal}
                  onChange={handleFormChange}
                  type="date"
                />
              </div>
              <FormField
                label="Machine Name"
                name="machine_name"
                value={addForm.machine_name}
                onChange={handleFormChange}
                placeholder="Assigned machine"
              />
              <FormField
                label="Paid By"
                name="paid_by"
                value={addForm.paid_by}
                onChange={handleFormChange}
              />
              <div style={{ marginBottom: 16 }}>
                <label
                  style={{
                    display: "block",
                    fontSize: 11,
                    fontWeight: 500,
                    letterSpacing: "0.06em",
                    textTransform: "uppercase",
                    color: "#6b6860",
                    marginBottom: 4,
                  }}
                >
                  Notes
                </label>
                <textarea
                  value={addForm.notes}
                  onChange={(e) => handleFormChange("notes", e.target.value)}
                  rows={3}
                  style={{
                    width: "100%",
                    border: "1px solid #e8e4de",
                    borderRadius: 8,
                    padding: "8px 12px",
                    fontSize: 14,
                    color: "#0a0a0a",
                    background: "white",
                    outline: "none",
                    resize: "vertical",
                    fontFamily: "'Plus Jakarta Sans', sans-serif",
                  }}
                />
              </div>
              <div style={{ marginBottom: 16 }}>
                <label
                  style={{
                    display: "flex",
                    alignItems: "center",
                    gap: 8,
                    fontSize: 14,
                    color: "#0a0a0a",
                    cursor: "pointer",
                  }}
                >
                  <input
                    type="checkbox"
                    checked={addForm.is_active}
                    onChange={(e) =>
                      setAddForm((prev) => ({
                        ...prev,
                        is_active: e.target.checked,
                      }))
                    }
                    style={{ width: 16, height: 16, accentColor: "#24544a" }}
                  />
                  Active
                </label>
              </div>
            </div>

            {/* Footer */}
            <div
              style={{
                padding: "14px 24px",
                borderTop: "1px solid #e8e4de",
                display: "flex",
                gap: 12,
              }}
            >
              <button
                onClick={() => setAddOpen(false)}
                style={{
                  padding: "10px 20px",
                  borderRadius: 8,
                  fontSize: 14,
                  fontWeight: 600,
                  border: "1px solid #e8e4de",
                  background: "white",
                  color: "#6b6860",
                  cursor: "pointer",
                }}
              >
                Cancel
              </button>
              <button
                onClick={handleAddSim}
                disabled={addSaving}
                style={{
                  padding: "10px 20px",
                  borderRadius: 8,
                  fontSize: 14,
                  fontWeight: 600,
                  border: "none",
                  background: addSaving ? "#9ca3af" : "#24544a",
                  color: "white",
                  cursor: addSaving ? "not-allowed" : "pointer",
                }}
              >
                {addSaving ? "Saving\u2026" : "Save SIM Card"}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
