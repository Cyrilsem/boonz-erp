"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";

// ─── Types ────────────────────────────────────────────────────────────────────

interface Supplier {
  supplier_id: string;
  supplier_code: string | null;
  supplier_acronym: string | null;
  supplier_name: string;
  contact_person: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  address: string | null;
  country: string | null;
  category: string | null;
  products_supplied: string | null;
  payment_terms: string | null;
  return_options: boolean | null;
  currency: string | null;
  payment_type: string | null;
  bank_details: string | null;
  contract_start_date: string | null;
  contract_end_date: string | null;
  status: string | null;
  rating: number | null;
  notes: string | null;
  procurement_type: string;
  created_at: string | null;
  updated_at: string | null;
  last_edited_at: string | null;
}

type SupplierDraft = Omit<Supplier, "supplier_id" | "created_at"> & {
  supplier_id?: string;
};

type StatusFilter = "All" | "Active" | "Inactive" | "Onboarding";
type ProcFilter = "All" | "supplier_delivered" | "walk_in";

// ─── Helpers ──────────────────────────────────────────────────────────────────

function formatTimestamp(ts: string | null): string {
  if (!ts) return "—";
  const d = new Date(ts);
  return d.toLocaleDateString("en-AE", {
    day: "numeric",
    month: "short",
    year: "2-digit",
  });
}

function formatDate(dateStr: string | null): string {
  if (!dateStr) return "—";
  const d = new Date(dateStr + "T00:00:00");
  return d.toLocaleDateString("en-AE", {
    day: "numeric",
    month: "short",
    year: "2-digit",
  });
}

function statusChip(status: string | null): React.CSSProperties {
  const s = (status ?? "Active").toLowerCase();
  if (s === "active") return { background: "#f0fdf4", color: "#065f46" };
  if (s === "onboarding") return { background: "#fffbeb", color: "#92400e" };
  return { background: "#f5f2ee", color: "#6b6860" };
}

function procTypeLabel(t: string | null): string {
  if (t === "supplier_delivered") return "Delivered";
  if (t === "walk_in") return "Walk-in";
  return t ?? "—";
}

function generateSupplierCode(existing: Supplier[]): string {
  const used = new Set(
    existing
      .map((s) => s.supplier_code ?? "")
      .filter((c) => /^SUP_\d{3}$/.test(c))
      .map((c) => parseInt(c.slice(4), 10)),
  );
  let n = 1;
  while (used.has(n)) n++;
  return `SUP_${String(n).padStart(3, "0")}`;
}

// ─── Tiny presentational components ───────────────────────────────────────────

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

function Field({
  label,
  value,
}: {
  label: string;
  value: React.ReactNode;
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
      <div style={{ fontSize: 14, color: "#0a0a0a", fontWeight: 500 }}>
        {value === null || value === undefined || value === "" ? "—" : value}
      </div>
    </div>
  );
}

const inputStyle: React.CSSProperties = {
  width: "100%",
  padding: "9px 12px",
  border: "1px solid #e8e4de",
  borderRadius: 8,
  fontSize: 13,
  color: "#0a0a0a",
  background: "white",
  fontFamily: "'Plus Jakarta Sans', sans-serif",
  outline: "none",
};

const labelStyle: React.CSSProperties = {
  fontSize: 10,
  fontWeight: 700,
  textTransform: "uppercase",
  letterSpacing: "0.08em",
  color: "#6b6860",
  display: "block",
  marginBottom: 4,
};

// ─── Edit form (shared by edit + add) ─────────────────────────────────────────

function EditFields({
  draft,
  onChange,
}: {
  draft: SupplierDraft;
  onChange: (patch: Partial<SupplierDraft>) => void;
}) {
  return (
    <>
      <SectionLabel>Identity</SectionLabel>

      <div style={{ marginBottom: 14 }}>
        <label style={labelStyle}>Supplier Name *</label>
        <input
          style={inputStyle}
          value={draft.supplier_name}
          onChange={(e) => onChange({ supplier_name: e.target.value })}
        />
      </div>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "1fr 1fr",
          gap: "0 16px",
        }}
      >
        <div style={{ marginBottom: 14 }}>
          <label style={labelStyle}>Supplier Code</label>
          <input
            style={inputStyle}
            placeholder="Auto-generated if blank"
            value={draft.supplier_code ?? ""}
            onChange={(e) => onChange({ supplier_code: e.target.value })}
          />
        </div>
        <div style={{ marginBottom: 14 }}>
          <label style={labelStyle}>Acronym</label>
          <input
            style={inputStyle}
            value={draft.supplier_acronym ?? ""}
            onChange={(e) => onChange({ supplier_acronym: e.target.value })}
          />
        </div>
        <div style={{ marginBottom: 14 }}>
          <label style={labelStyle}>Status</label>
          <select
            style={inputStyle}
            value={draft.status ?? "Active"}
            onChange={(e) => onChange({ status: e.target.value })}
          >
            <option value="Active">Active</option>
            <option value="Inactive">Inactive</option>
            <option value="Onboarding">Onboarding</option>
            <option value="Suspended">Suspended</option>
          </select>
        </div>
        <div style={{ marginBottom: 14 }}>
          <label style={labelStyle}>Procurement Type *</label>
          <select
            style={inputStyle}
            value={draft.procurement_type ?? "supplier_delivered"}
            onChange={(e) => onChange({ procurement_type: e.target.value })}
          >
            <option value="supplier_delivered">Supplier delivered</option>
            <option value="walk_in">Walk-in</option>
          </select>
        </div>
      </div>

      <SectionLabel>Contact</SectionLabel>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "1fr 1fr",
          gap: "0 16px",
        }}
      >
        <div style={{ marginBottom: 14 }}>
          <label style={labelStyle}>Contact Person</label>
          <input
            style={inputStyle}
            value={draft.contact_person ?? ""}
            onChange={(e) => onChange({ contact_person: e.target.value })}
          />
        </div>
        <div style={{ marginBottom: 14 }}>
          <label style={labelStyle}>Country</label>
          <input
            style={inputStyle}
            value={draft.country ?? ""}
            onChange={(e) => onChange({ country: e.target.value })}
          />
        </div>
        <div style={{ marginBottom: 14 }}>
          <label style={labelStyle}>Email</label>
          <input
            style={inputStyle}
            type="email"
            value={draft.contact_email ?? ""}
            onChange={(e) => onChange({ contact_email: e.target.value })}
          />
        </div>
        <div style={{ marginBottom: 14 }}>
          <label style={labelStyle}>Phone</label>
          <input
            style={inputStyle}
            type="tel"
            value={draft.contact_phone ?? ""}
            onChange={(e) => onChange({ contact_phone: e.target.value })}
          />
        </div>
      </div>

      <div style={{ marginBottom: 14 }}>
        <label style={labelStyle}>Address</label>
        <textarea
          style={{ ...inputStyle, resize: "vertical" }}
          rows={2}
          value={draft.address ?? ""}
          onChange={(e) => onChange({ address: e.target.value })}
        />
      </div>

      <SectionLabel>Catalog</SectionLabel>

      <div style={{ marginBottom: 14 }}>
        <label style={labelStyle}>Category</label>
        <input
          style={inputStyle}
          placeholder="e.g. Soft Drinks, Snacks"
          value={draft.category ?? ""}
          onChange={(e) => onChange({ category: e.target.value })}
        />
      </div>

      <div style={{ marginBottom: 14 }}>
        <label style={labelStyle}>Products Supplied</label>
        <textarea
          style={{ ...inputStyle, resize: "vertical" }}
          rows={2}
          placeholder="e.g. Mars, Snickers, Bounty"
          value={draft.products_supplied ?? ""}
          onChange={(e) => onChange({ products_supplied: e.target.value })}
        />
      </div>

      <SectionLabel>Commercial</SectionLabel>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "1fr 1fr",
          gap: "0 16px",
        }}
      >
        <div style={{ marginBottom: 14 }}>
          <label style={labelStyle}>Payment Terms</label>
          <input
            style={inputStyle}
            placeholder="e.g. Net 30"
            value={draft.payment_terms ?? ""}
            onChange={(e) => onChange({ payment_terms: e.target.value })}
          />
        </div>
        <div style={{ marginBottom: 14 }}>
          <label style={labelStyle}>Payment Type</label>
          <select
            style={inputStyle}
            value={draft.payment_type ?? ""}
            onChange={(e) => onChange({ payment_type: e.target.value })}
          >
            <option value="">{"— select —"}</option>
            <option value="bank_transfer">Bank Transfer</option>
            <option value="cheque">Cheque</option>
            <option value="cash">Cash</option>
            <option value="credit_card">Credit Card</option>
            <option value="other">Other</option>
          </select>
        </div>
        <div style={{ marginBottom: 14 }}>
          <label style={labelStyle}>Currency</label>
          <select
            style={inputStyle}
            value={draft.currency ?? "AED"}
            onChange={(e) => onChange({ currency: e.target.value })}
          >
            <option value="AED">AED</option>
            <option value="USD">USD</option>
            <option value="EUR">EUR</option>
            <option value="GBP">GBP</option>
            <option value="INR">INR</option>
          </select>
        </div>
        <div style={{ marginBottom: 14 }}>
          <label style={labelStyle}>Rating (1–5)</label>
          <input
            style={inputStyle}
            type="number"
            min={1}
            max={5}
            step={0.1}
            value={draft.rating ?? ""}
            onChange={(e) =>
              onChange({
                rating: e.target.value === "" ? null : Number(e.target.value),
              })
            }
          />
        </div>
      </div>

      <div style={{ marginBottom: 14 }}>
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
            checked={draft.return_options ?? false}
            onChange={(e) => onChange({ return_options: e.target.checked })}
            style={{ width: 16, height: 16, accentColor: "#24544a" }}
          />
          Accepts returns
        </label>
      </div>

      <div style={{ marginBottom: 14 }}>
        <label style={labelStyle}>Bank Details</label>
        <textarea
          style={{ ...inputStyle, resize: "vertical" }}
          rows={2}
          value={draft.bank_details ?? ""}
          onChange={(e) => onChange({ bank_details: e.target.value })}
        />
      </div>

      <SectionLabel>Contract</SectionLabel>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "1fr 1fr",
          gap: "0 16px",
        }}
      >
        <div style={{ marginBottom: 14 }}>
          <label style={labelStyle}>Contract Start</label>
          <input
            style={inputStyle}
            type="date"
            value={draft.contract_start_date ?? ""}
            onChange={(e) => onChange({ contract_start_date: e.target.value })}
          />
        </div>
        <div style={{ marginBottom: 14 }}>
          <label style={labelStyle}>Contract End</label>
          <input
            style={inputStyle}
            type="date"
            value={draft.contract_end_date ?? ""}
            onChange={(e) => onChange({ contract_end_date: e.target.value })}
          />
        </div>
      </div>

      <div style={{ marginBottom: 14 }}>
        <label style={labelStyle}>Notes</label>
        <textarea
          style={{ ...inputStyle, resize: "vertical" }}
          rows={3}
          value={draft.notes ?? ""}
          onChange={(e) => onChange({ notes: e.target.value })}
        />
      </div>
    </>
  );
}

// ─── Page ─────────────────────────────────────────────────────────────────────

const EMPTY_DRAFT: SupplierDraft = {
  supplier_code: null,
  supplier_acronym: null,
  supplier_name: "",
  contact_person: null,
  contact_email: null,
  contact_phone: null,
  address: null,
  country: "UAE",
  category: null,
  products_supplied: null,
  payment_terms: null,
  return_options: false,
  currency: "AED",
  payment_type: null,
  bank_details: null,
  contract_start_date: null,
  contract_end_date: null,
  status: "Active",
  rating: null,
  notes: null,
  procurement_type: "supplier_delivered",
  updated_at: null,
  last_edited_at: null,
};

export default function SuppliersPage() {
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [loading, setLoading] = useState(true);
  const [fetchKey, setFetchKey] = useState(0);

  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("All");
  const [procFilter, setProcFilter] = useState<ProcFilter>("All");

  const [selected, setSelected] = useState<Supplier | null>(null);
  const [editMode, setEditMode] = useState(false);
  const [editDraft, setEditDraft] = useState<SupplierDraft | null>(null);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const [addOpen, setAddOpen] = useState(false);
  const [addDraft, setAddDraft] = useState<SupplierDraft>({ ...EMPTY_DRAFT });
  const [addSaving, setAddSaving] = useState(false);
  const [addError, setAddError] = useState<string | null>(null);

  // ESC to close drawers
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      if (editMode) {
        setEditMode(false);
      } else if (selected) {
        setSelected(null);
      } else if (addOpen) {
        setAddOpen(false);
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [editMode, selected, addOpen]);

  // Load suppliers
  useEffect(() => {
    async function load() {
      const supabase = createClient();
      const { data, error } = await supabase
        .from("suppliers")
        .select("*")
        .order("supplier_name", { ascending: true });
      if (error) {
        console.error("suppliers fetch error:", error);
      }
      setSuppliers((data as Supplier[]) ?? []);
      setLoading(false);
    }
    load();
  }, [fetchKey]);

  const filtered = useMemo(() => {
    return suppliers.filter((s) => {
      if (search) {
        const q = search.toLowerCase();
        const hay = [
          s.supplier_name,
          s.supplier_code,
          s.supplier_acronym,
          s.contact_person,
          s.contact_email,
          s.contact_phone,
          s.category,
          s.products_supplied,
        ]
          .filter(Boolean)
          .join(" ")
          .toLowerCase();
        if (!hay.includes(q)) return false;
      }
      if (statusFilter !== "All" && (s.status ?? "Active") !== statusFilter)
        return false;
      if (procFilter !== "All" && s.procurement_type !== procFilter)
        return false;
      return true;
    });
  }, [suppliers, search, statusFilter, procFilter]);

  const counts = useMemo(() => {
    return {
      total: suppliers.length,
      active: suppliers.filter((s) => (s.status ?? "Active") === "Active")
        .length,
    };
  }, [suppliers]);

  function openSupplier(s: Supplier) {
    setSelected(s);
    setEditMode(false);
    setSaveError(null);
    setEditDraft({
      supplier_id: s.supplier_id,
      supplier_code: s.supplier_code,
      supplier_acronym: s.supplier_acronym,
      supplier_name: s.supplier_name,
      contact_person: s.contact_person,
      contact_email: s.contact_email,
      contact_phone: s.contact_phone,
      address: s.address,
      country: s.country,
      category: s.category,
      products_supplied: s.products_supplied,
      payment_terms: s.payment_terms,
      return_options: s.return_options,
      currency: s.currency,
      payment_type: s.payment_type,
      bank_details: s.bank_details,
      contract_start_date: s.contract_start_date,
      contract_end_date: s.contract_end_date,
      status: s.status,
      rating: s.rating,
      notes: s.notes,
      procurement_type: s.procurement_type,
      updated_at: s.updated_at,
      last_edited_at: s.last_edited_at,
    });
  }

  async function saveEdit() {
    if (!selected || !editDraft) return;
    if (!editDraft.supplier_name.trim()) {
      setSaveError("Supplier name is required");
      return;
    }
    setSaving(true);
    setSaveError(null);
    const supabase = createClient();
    const now = new Date().toISOString();
    const payload = {
      supplier_code: editDraft.supplier_code || null,
      supplier_acronym: editDraft.supplier_acronym || null,
      supplier_name: editDraft.supplier_name.trim(),
      contact_person: editDraft.contact_person || null,
      contact_email: editDraft.contact_email || null,
      contact_phone: editDraft.contact_phone || null,
      address: editDraft.address || null,
      country: editDraft.country || null,
      category: editDraft.category || null,
      products_supplied: editDraft.products_supplied || null,
      payment_terms: editDraft.payment_terms || null,
      return_options: editDraft.return_options ?? false,
      currency: editDraft.currency || "AED",
      payment_type: editDraft.payment_type || null,
      bank_details: editDraft.bank_details || null,
      contract_start_date: editDraft.contract_start_date || null,
      contract_end_date: editDraft.contract_end_date || null,
      status: editDraft.status || "Active",
      rating:
        editDraft.rating === null || editDraft.rating === undefined
          ? null
          : Number(editDraft.rating),
      notes: editDraft.notes || null,
      procurement_type: editDraft.procurement_type || "supplier_delivered",
      updated_at: now,
      last_edited_at: now,
    };
    const { error } = await supabase
      .from("suppliers")
      .update(payload)
      .eq("supplier_id", selected.supplier_id);
    setSaving(false);
    if (error) {
      setSaveError(error.message);
      return;
    }
    setEditMode(false);
    setSelected(null);
    setFetchKey((k) => k + 1);
  }

  async function addSupplier() {
    if (!addDraft.supplier_name.trim()) {
      setAddError("Supplier name is required");
      return;
    }
    setAddSaving(true);
    setAddError(null);
    const supabase = createClient();
    const code =
      addDraft.supplier_code?.trim() || generateSupplierCode(suppliers);
    const now = new Date().toISOString();
    const payload = {
      supplier_code: code,
      supplier_acronym: addDraft.supplier_acronym || null,
      supplier_name: addDraft.supplier_name.trim(),
      contact_person: addDraft.contact_person || null,
      contact_email: addDraft.contact_email || null,
      contact_phone: addDraft.contact_phone || null,
      address: addDraft.address || null,
      country: addDraft.country || "UAE",
      category: addDraft.category || null,
      products_supplied: addDraft.products_supplied || null,
      payment_terms: addDraft.payment_terms || null,
      return_options: addDraft.return_options ?? false,
      currency: addDraft.currency || "AED",
      payment_type: addDraft.payment_type || null,
      bank_details: addDraft.bank_details || null,
      contract_start_date: addDraft.contract_start_date || null,
      contract_end_date: addDraft.contract_end_date || null,
      status: addDraft.status || "Active",
      rating:
        addDraft.rating === null || addDraft.rating === undefined
          ? null
          : Number(addDraft.rating),
      notes: addDraft.notes || null,
      procurement_type: addDraft.procurement_type || "supplier_delivered",
      updated_at: now,
      last_edited_at: now,
    };
    const { error } = await supabase.from("suppliers").insert([payload]);
    setAddSaving(false);
    if (error) {
      setAddError(error.message);
      return;
    }
    setAddOpen(false);
    setAddDraft({ ...EMPTY_DRAFT });
    setFetchKey((k) => k + 1);
  }

  // ─── Render ────────────────────────────────────────────────────────────────

  return (
    <div className="p-8 max-w-7xl">
      {/* Header */}
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
            Suppliers
          </h1>
          <p style={{ color: "#6b6860", fontSize: 14, marginTop: 4 }}>
            {loading
              ? "Loading…"
              : `${counts.total} supplier${counts.total !== 1 ? "s" : ""} · ${counts.active} active`}
          </p>
        </div>
        <button
          onClick={() => {
            setAddDraft({ ...EMPTY_DRAFT });
            setAddError(null);
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
          + Add Supplier
        </button>
      </div>

      {/* Filters */}
      <div
        className="flex items-center gap-3 flex-wrap mb-6"
        style={{ borderBottom: "1px solid #e8e4de", paddingBottom: 16 }}
      >
        <input
          type="text"
          placeholder="Search name, code, contact, category…"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          style={{
            border: "1px solid #e8e4de",
            borderRadius: 8,
            padding: "7px 12px",
            fontSize: 14,
            width: 320,
            outline: "none",
            color: "#0a0a0a",
            background: "white",
          }}
        />
        {(["All", "Active", "Inactive", "Onboarding"] as const).map((s) => (
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
        <span style={{ width: 12 }} />
        {(
          [
            { v: "All", label: "All types" },
            { v: "supplier_delivered", label: "Delivered" },
            { v: "walk_in", label: "Walk-in" },
          ] as const
        ).map((p) => (
          <button
            key={p.v}
            onClick={() => setProcFilter(p.v as ProcFilter)}
            style={{
              border: "1px solid #e8e4de",
              borderRadius: 8,
              padding: "7px 14px",
              fontSize: 13,
              fontWeight: procFilter === p.v ? 600 : 400,
              background: procFilter === p.v ? "#24544a" : "white",
              color: procFilter === p.v ? "white" : "#6b6860",
              cursor: "pointer",
            }}
          >
            {p.label}
          </button>
        ))}
        {!loading && (
          <span style={{ marginLeft: "auto", fontSize: 13, color: "#6b6860" }}>
            {filtered.length} result{filtered.length !== 1 ? "s" : ""}
          </span>
        )}
      </div>

      {/* Table */}
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
                "Supplier",
                "Code",
                "Type",
                "Category",
                "Contact",
                "Currency",
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
              Array.from({ length: 6 }).map((_, i) => (
                <tr key={i} style={{ borderBottom: "1px solid #f5f2ee" }}>
                  {[180, 70, 90, 140, 140, 60, 70].map((w, j) => (
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
                  No suppliers match your filters.
                </td>
              </tr>
            ) : (
              filtered.map((s) => {
                const isSelected = selected?.supplier_id === s.supplier_id;
                const chip = statusChip(s.status);
                return (
                  <tr
                    key={s.supplier_id}
                    style={{
                      borderBottom: "1px solid #f5f2ee",
                      cursor: "pointer",
                      background: isSelected ? "#f0fdf4" : undefined,
                    }}
                    onClick={() => openSupplier(s)}
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
                      <div>{s.supplier_name}</div>
                      {s.supplier_acronym && (
                        <div
                          style={{
                            fontSize: 11,
                            color: "#6b6860",
                            fontWeight: 400,
                          }}
                        >
                          {s.supplier_acronym}
                        </div>
                      )}
                    </td>
                    <td
                      className="px-4 py-3"
                      style={{
                        fontFamily: "monospace",
                        fontSize: 13,
                        color: "#0a0a0a",
                      }}
                    >
                      {s.supplier_code ?? "—"}
                    </td>
                    <td className="px-4 py-3" style={{ color: "#0a0a0a" }}>
                      {procTypeLabel(s.procurement_type)}
                    </td>
                    <td
                      className="px-4 py-3 max-w-[220px] truncate"
                      style={{ color: "#6b6860" }}
                      title={s.category ?? undefined}
                    >
                      {s.category ?? "—"}
                    </td>
                    <td
                      className="px-4 py-3 max-w-[200px] truncate"
                      style={{ color: "#0a0a0a" }}
                      title={
                        [s.contact_person, s.contact_email, s.contact_phone]
                          .filter(Boolean)
                          .join(" · ") || undefined
                      }
                    >
                      {s.contact_person ?? s.contact_email ?? "—"}
                    </td>
                    <td className="px-4 py-3" style={{ color: "#6b6860" }}>
                      {s.currency ?? "—"}
                    </td>
                    <td className="px-4 py-3">
                      <span
                        style={{
                          display: "inline-block",
                          padding: "2px 10px",
                          borderRadius: 20,
                          fontSize: 11,
                          fontWeight: 600,
                          ...chip,
                        }}
                      >
                        {s.status ?? "Active"}
                      </span>
                    </td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>

      {/* ── Detail drawer ────────────────────────────────────────────────── */}
      {selected && (
        <div
          style={{
            position: "fixed",
            inset: 0,
            display: "flex",
            justifyContent: "flex-end",
            zIndex: 40,
          }}
        >
          <div
            style={{
              position: "absolute",
              inset: 0,
              background: "rgba(0,0,0,0.32)",
            }}
            onClick={() => {
              setSelected(null);
              setEditMode(false);
            }}
          />
          <div
            style={{
              position: "relative",
              width: 560,
              maxWidth: "100vw",
              background: "white",
              height: "100%",
              display: "flex",
              flexDirection: "column",
              boxShadow: "-4px 0 24px rgba(0,0,0,0.08)",
              fontFamily: "'Plus Jakarta Sans', sans-serif",
            }}
          >
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
                  {selected.supplier_name}
                </h2>
                <div
                  style={{
                    display: "flex",
                    gap: 8,
                    marginTop: 6,
                    alignItems: "center",
                  }}
                >
                  <span
                    style={{
                      display: "inline-block",
                      padding: "2px 10px",
                      borderRadius: 20,
                      fontSize: 11,
                      fontWeight: 600,
                      ...statusChip(selected.status),
                    }}
                  >
                    {selected.status ?? "Active"}
                  </span>
                  <span
                    style={{
                      fontSize: 11,
                      color: "#6b6860",
                      fontFamily: "monospace",
                    }}
                  >
                    {selected.supplier_code ?? "—"}
                  </span>
                </div>
              </div>
              <button
                onClick={() => {
                  setSelected(null);
                  setEditMode(false);
                }}
                style={{
                  fontSize: 20,
                  color: "#6b6860",
                  background: "none",
                  border: "none",
                  cursor: "pointer",
                }}
                aria-label="Close"
              >
                {"✕"}
              </button>
            </div>

            <div
              style={{
                flex: 1,
                overflow: "auto",
                padding: "4px 24px 24px",
              }}
            >
              {editMode && editDraft ? (
                <EditFields
                  draft={editDraft}
                  onChange={(patch) =>
                    setEditDraft((prev) => (prev ? { ...prev, ...patch } : prev))
                  }
                />
              ) : (
                <>
                  <SectionLabel>Identity</SectionLabel>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr",
                      gap: "0 20px",
                    }}
                  >
                    <Field label="Acronym" value={selected.supplier_acronym} />
                    <Field
                      label="Procurement"
                      value={procTypeLabel(selected.procurement_type)}
                    />
                  </div>

                  <SectionLabel>Contact</SectionLabel>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr",
                      gap: "0 20px",
                    }}
                  >
                    <Field
                      label="Contact Person"
                      value={selected.contact_person}
                    />
                    <Field label="Country" value={selected.country} />
                    <Field label="Email" value={selected.contact_email} />
                    <Field label="Phone" value={selected.contact_phone} />
                  </div>
                  {selected.address && (
                    <Field label="Address" value={selected.address} />
                  )}

                  <SectionLabel>Catalog</SectionLabel>
                  <Field label="Category" value={selected.category} />
                  <Field
                    label="Products Supplied"
                    value={selected.products_supplied}
                  />

                  <SectionLabel>Commercial</SectionLabel>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr",
                      gap: "0 20px",
                    }}
                  >
                    <Field
                      label="Payment Terms"
                      value={selected.payment_terms}
                    />
                    <Field
                      label="Payment Type"
                      value={selected.payment_type}
                    />
                    <Field label="Currency" value={selected.currency} />
                    <Field label="Rating" value={selected.rating} />
                    <Field
                      label="Returns"
                      value={selected.return_options ? "Yes" : "No"}
                    />
                  </div>
                  {selected.bank_details && (
                    <Field label="Bank Details" value={selected.bank_details} />
                  )}

                  <SectionLabel>Contract</SectionLabel>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr",
                      gap: "0 20px",
                    }}
                  >
                    <Field
                      label="Start"
                      value={formatDate(selected.contract_start_date)}
                    />
                    <Field
                      label="End"
                      value={formatDate(selected.contract_end_date)}
                    />
                  </div>
                  {selected.notes && (
                    <Field label="Notes" value={selected.notes} />
                  )}

                  <SectionLabel>Metadata</SectionLabel>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr",
                      gap: "0 20px",
                    }}
                  >
                    <Field
                      label="Created"
                      value={formatTimestamp(selected.created_at)}
                    />
                    <Field
                      label="Updated"
                      value={formatTimestamp(selected.updated_at)}
                    />
                  </div>
                </>
              )}
            </div>

            {/* Footer actions */}
            <div
              style={{
                borderTop: "1px solid #e8e4de",
                padding: "14px 24px",
                display: "flex",
                gap: 10,
                justifyContent: "flex-end",
                background: "white",
              }}
            >
              {saveError && (
                <div
                  style={{
                    marginRight: "auto",
                    color: "#dc2626",
                    fontSize: 13,
                    alignSelf: "center",
                  }}
                >
                  {saveError}
                </div>
              )}
              {editMode ? (
                <>
                  <button
                    onClick={() => {
                      setEditMode(false);
                      openSupplier(selected);
                    }}
                    disabled={saving}
                    style={{
                      padding: "8px 16px",
                      borderRadius: 8,
                      border: "1px solid #e8e4de",
                      background: "white",
                      color: "#6b6860",
                      fontSize: 14,
                      fontWeight: 500,
                      cursor: saving ? "not-allowed" : "pointer",
                    }}
                  >
                    Cancel
                  </button>
                  <button
                    onClick={saveEdit}
                    disabled={saving}
                    style={{
                      padding: "8px 16px",
                      borderRadius: 8,
                      border: "none",
                      background: "#24544a",
                      color: "white",
                      fontSize: 14,
                      fontWeight: 600,
                      cursor: saving ? "not-allowed" : "pointer",
                      opacity: saving ? 0.6 : 1,
                    }}
                  >
                    {saving ? "Saving…" : "Save changes"}
                  </button>
                </>
              ) : (
                <button
                  onClick={() => {
                    setEditMode(true);
                    setSaveError(null);
                  }}
                  style={{
                    padding: "8px 16px",
                    borderRadius: 8,
                    border: "none",
                    background: "#24544a",
                    color: "white",
                    fontSize: 14,
                    fontWeight: 600,
                    cursor: "pointer",
                  }}
                >
                  Edit
                </button>
              )}
            </div>
          </div>
        </div>
      )}

      {/* ── Add drawer ──────────────────────────────────────────────────── */}
      {addOpen && (
        <div
          style={{
            position: "fixed",
            inset: 0,
            display: "flex",
            justifyContent: "flex-end",
            zIndex: 40,
          }}
        >
          <div
            style={{
              position: "absolute",
              inset: 0,
              background: "rgba(0,0,0,0.32)",
            }}
            onClick={() => setAddOpen(false)}
          />
          <div
            style={{
              position: "relative",
              width: 560,
              maxWidth: "100vw",
              background: "white",
              height: "100%",
              display: "flex",
              flexDirection: "column",
              boxShadow: "-4px 0 24px rgba(0,0,0,0.08)",
              fontFamily: "'Plus Jakarta Sans', sans-serif",
            }}
          >
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
                New Supplier
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
                aria-label="Close"
              >
                {"✕"}
              </button>
            </div>

            <div
              style={{
                flex: 1,
                overflow: "auto",
                padding: "4px 24px 24px",
              }}
            >
              <EditFields
                draft={addDraft}
                onChange={(patch) =>
                  setAddDraft((prev) => ({ ...prev, ...patch }))
                }
              />
            </div>

            <div
              style={{
                borderTop: "1px solid #e8e4de",
                padding: "14px 24px",
                display: "flex",
                gap: 10,
                justifyContent: "flex-end",
                background: "white",
              }}
            >
              {addError && (
                <div
                  style={{
                    marginRight: "auto",
                    color: "#dc2626",
                    fontSize: 13,
                    alignSelf: "center",
                  }}
                >
                  {addError}
                </div>
              )}
              <button
                onClick={() => setAddOpen(false)}
                disabled={addSaving}
                style={{
                  padding: "8px 16px",
                  borderRadius: 8,
                  border: "1px solid #e8e4de",
                  background: "white",
                  color: "#6b6860",
                  fontSize: 14,
                  fontWeight: 500,
                  cursor: addSaving ? "not-allowed" : "pointer",
                }}
              >
                Cancel
              </button>
              <button
                onClick={addSupplier}
                disabled={addSaving}
                style={{
                  padding: "8px 16px",
                  borderRadius: 8,
                  border: "none",
                  background: "#24544a",
                  color: "white",
                  fontSize: 14,
                  fontWeight: 600,
                  cursor: addSaving ? "not-allowed" : "pointer",
                  opacity: addSaving ? 0.6 : 1,
                }}
              >
                {addSaving ? "Adding…" : "Add supplier"}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
