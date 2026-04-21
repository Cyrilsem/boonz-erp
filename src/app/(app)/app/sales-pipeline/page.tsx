"use client";

import { useEffect, useState, useMemo, useCallback, useRef } from "react";
import { createClient } from "@/lib/supabase/client";

// ─── Types ────────────────────────────────────────────────────────────────────

interface SalesLead {
  id: string;
  lead_ref: string | null;
  lead_owner: string | null;
  company_name: string;
  engagement_status: string;
  funnel_stage: string;
  priority_order: number | null;
  estimated_machines: number | null;
  relationship_type: string | null;
  contact_person: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  area: string | null;
  location_address: string | null;
  location_type: string | null;
  date_initiated: string | null;
  rev_share: number | null;
  last_contact_date: string | null;
  next_follow_up_date: string | null;
  installation_date: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
}

interface Activity {
  id: string;
  lead_id: string;
  activity_type: string;
  content: string;
  reminder_date: string | null;
  created_by: string | null;
  created_at: string;
}

// ─── Constants ────────────────────────────────────────────────────────────────

const FUNNEL_STAGES = ["Lead", "Initiated", "Qualification", "Negotiation", "Awarded", "Installed"];
const ENGAGEMENT_STATUSES = ["Active", "Inactive", "Closed-Won", "Closed-Lost"];
const PRIORITY_ORDERS = [1, 2, 3, 4, 5];
const PRIORITY_LABELS: Record<number, string> = {
  1: "🏆 Tier 1 — Installed / Hot",
  2: "🔥 Tier 2 — Active Pipeline",
  3: "💬 Tier 3 — In Discussion",
  4: "🌀 Tier 4 — Slow / Stalled",
  5: "❄️  Tier 5 — Cold List",
};
const OWNER_COLORS: Record<string, string> = {
  CS: "#10b981",
  RK: "#3b82f6",
  CE: "#f59e0b",
  HR: "#8b5cf6",
  "CS/RK": "#ec4899",
};
const STAGE_COLORS: Record<string, { bg: string; text: string }> = {
  Lead:         { bg: "#f1f0ee", text: "#6b6860" },
  Initiated:    { bg: "#dbeafe", text: "#1d4ed8" },
  Qualification:{ bg: "#fef9c3", text: "#a16207" },
  Negotiation:  { bg: "#fce7f3", text: "#be185d" },
  Awarded:      { bg: "#fef3c7", text: "#92400e" },
  Installed:    { bg: "#d1fae5", text: "#065f46" },
};
const ENGAGEMENT_COLORS: Record<string, { bg: string; text: string }> = {
  Active:       { bg: "#d1fae5", text: "#065f46" },
  Inactive:     { bg: "#f1f0ee", text: "#6b6860" },
  "Closed-Won": { bg: "#dbeafe", text: "#1d4ed8" },
  "Closed-Lost":{ bg: "#fee2e2", text: "#b91c1c" },
};
const ACTIVITY_ICONS: Record<string, string> = {
  note:     "📝",
  call:     "📞",
  email:    "✉️",
  meeting:  "🤝",
  reminder: "🔔",
};
const LOCATION_ICONS: Record<string, string> = {
  Office:               "🏢",
  "Co-Working":         "💼",
  Coworking:            "💼",
  Hospital:             "🏥",
  Hospitals:            "🏥",
  Gym:                  "💪",
  "Entertainment Centers": "🎭",
  Hotels:               "🏨",
  "Building Common Area":"🏗️",
  Government:           "🏛️",
  "Goverment":          "🏛️",
};

const EMPTY_LEAD: Omit<SalesLead, "id" | "created_at" | "updated_at"> = {
  lead_ref: "",
  lead_owner: "CS",
  company_name: "",
  engagement_status: "Active",
  funnel_stage: "Lead",
  priority_order: 5,
  estimated_machines: 1,
  relationship_type: "Direct",
  contact_person: "",
  contact_email: "",
  contact_phone: "",
  area: "",
  location_address: "",
  location_type: "Office",
  date_initiated: new Date().toISOString().slice(0, 10),
  rev_share: 0,
  last_contact_date: "",
  next_follow_up_date: "",
  installation_date: "",
  notes: "",
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

function fmt(dateStr: string | null | undefined): string {
  if (!dateStr) return "—";
  const d = new Date(dateStr + "T00:00:00");
  return d.toLocaleDateString("en-AE", { day: "numeric", month: "short", year: "2-digit" });
}

function followUpStyle(date: string | null): React.CSSProperties {
  if (!date) return { color: "#9ca3af" };
  const days = Math.floor((new Date(date + "T00:00:00").getTime() - Date.now()) / 86400000);
  if (days < 0) return { color: "#dc2626", fontWeight: 700 };
  if (days <= 7) return { color: "#d97706", fontWeight: 600 };
  return { color: "#6b6860" };
}

function ownerBadge(owner: string | null) {
  if (!owner) return null;
  const color = OWNER_COLORS[owner] ?? "#6b6860";
  return (
    <span style={{
      background: color + "22",
      color,
      border: `1px solid ${color}44`,
      borderRadius: 4,
      padding: "1px 6px",
      fontSize: 10,
      fontWeight: 700,
      letterSpacing: "0.04em",
    }}>{owner}</span>
  );
}

function stageBadge(stage: string) {
  const c = STAGE_COLORS[stage] ?? { bg: "#f1f0ee", text: "#6b6860" };
  return (
    <span style={{
      background: c.bg, color: c.text,
      borderRadius: 4, padding: "2px 8px",
      fontSize: 10, fontWeight: 600, letterSpacing: "0.04em",
    }}>{stage}</span>
  );
}

function engagementBadge(status: string) {
  const c = ENGAGEMENT_COLORS[status] ?? { bg: "#f1f0ee", text: "#6b6860" };
  return (
    <span style={{
      background: c.bg, color: c.text,
      borderRadius: 4, padding: "2px 8px",
      fontSize: 10, fontWeight: 600, letterSpacing: "0.04em",
    }}>{status}</span>
  );
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function StatCard({ label, value, sub, color }: { label: string; value: string | number; sub?: string; color?: string }) {
  return (
    <div style={{
      background: "white",
      border: "1px solid #e8e4de",
      borderRadius: 12,
      padding: "16px 20px",
      minWidth: 0,
    }}>
      <div style={{ fontSize: 11, fontWeight: 600, letterSpacing: "0.08em", textTransform: "uppercase", color: "#6b6860", marginBottom: 6 }}>
        {label}
      </div>
      <div style={{ fontSize: 26, fontWeight: 800, letterSpacing: "-0.02em", color: color ?? "#0a0a0a" }}>
        {value}
      </div>
      {sub && <div style={{ fontSize: 11, color: "#9ca3af", marginTop: 2 }}>{sub}</div>}
    </div>
  );
}

function SelectField({ label, value, options, onChange }: {
  label: string;
  value: string;
  options: string[];
  onChange: (v: string) => void;
}) {
  return (
    <div style={{ marginBottom: 14 }}>
      <label style={{ display: "block", fontSize: 10, fontWeight: 700, letterSpacing: "0.08em", textTransform: "uppercase", color: "#6b6860", marginBottom: 4 }}>{label}</label>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        style={{ width: "100%", padding: "8px 10px", border: "1px solid #e8e4de", borderRadius: 8, fontSize: 13, color: "#0a0a0a", background: "white", fontFamily: "'Plus Jakarta Sans', sans-serif" }}
      >
        {options.map(o => <option key={o} value={o}>{o}</option>)}
      </select>
    </div>
  );
}

function InputField({ label, value, onChange, type = "text", placeholder }: {
  label: string; value: string; onChange: (v: string) => void; type?: string; placeholder?: string;
}) {
  return (
    <div style={{ marginBottom: 14 }}>
      <label style={{ display: "block", fontSize: 10, fontWeight: 700, letterSpacing: "0.08em", textTransform: "uppercase", color: "#6b6860", marginBottom: 4 }}>{label}</label>
      {type === "textarea" ? (
        <textarea
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder={placeholder}
          rows={3}
          style={{ width: "100%", padding: "8px 10px", border: "1px solid #e8e4de", borderRadius: 8, fontSize: 13, color: "#0a0a0a", background: "white", fontFamily: "'Plus Jakarta Sans', sans-serif", resize: "vertical" }}
        />
      ) : (
        <input
          type={type}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder={placeholder}
          style={{ width: "100%", padding: "8px 10px", border: "1px solid #e8e4de", borderRadius: 8, fontSize: 13, color: "#0a0a0a", background: "white", fontFamily: "'Plus Jakarta Sans', sans-serif" }}
        />
      )}
    </div>
  );
}

// ─── Lead Card ────────────────────────────────────────────────────────────────

function LeadCard({
  lead,
  onDragStart,
  onClick,
}: {
  lead: SalesLead;
  onDragStart: (id: string) => void;
  onClick: (lead: SalesLead) => void;
}) {
  const locIcon = LOCATION_ICONS[lead.location_type ?? ""] ?? "📍";
  const overdueFollowUp = lead.next_follow_up_date
    ? new Date(lead.next_follow_up_date + "T00:00:00") < new Date()
    : false;

  return (
    <div
      draggable
      onDragStart={(e) => {
        e.dataTransfer.effectAllowed = "move";
        onDragStart(lead.id);
      }}
      onClick={() => onClick(lead)}
      style={{
        background: "white",
        border: "1px solid #e8e4de",
        borderRadius: 10,
        padding: "12px 14px",
        cursor: "grab",
        userSelect: "none",
        boxShadow: "0 1px 3px rgba(0,0,0,0.06)",
        transition: "box-shadow 0.15s",
      }}
      onMouseEnter={(e) => {
        (e.currentTarget as HTMLDivElement).style.boxShadow = "0 4px 12px rgba(0,0,0,0.12)";
        (e.currentTarget as HTMLDivElement).style.borderColor = "#24544a";
      }}
      onMouseLeave={(e) => {
        (e.currentTarget as HTMLDivElement).style.boxShadow = "0 1px 3px rgba(0,0,0,0.06)";
        (e.currentTarget as HTMLDivElement).style.borderColor = "#e8e4de";
      }}
    >
      {/* Top row: company + owner badge */}
      <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: 8, marginBottom: 8 }}>
        <div style={{ fontSize: 13, fontWeight: 700, color: "#0a0a0a", lineHeight: 1.3 }}>
          {lead.company_name}
        </div>
        {ownerBadge(lead.lead_owner)}
      </div>

      {/* Tags row */}
      <div style={{ display: "flex", flexWrap: "wrap", gap: 4, marginBottom: 8 }}>
        {lead.area && (
          <span style={{ fontSize: 10, background: "#f5f4f2", color: "#6b6860", borderRadius: 4, padding: "2px 6px" }}>
            📍 {lead.area}
          </span>
        )}
        {lead.location_type && (
          <span style={{ fontSize: 10, background: "#f5f4f2", color: "#6b6860", borderRadius: 4, padding: "2px 6px" }}>
            {locIcon} {lead.location_type}
          </span>
        )}
        {(lead.estimated_machines ?? 0) > 0 && (
          <span style={{ fontSize: 10, background: "#f0fdf4", color: "#166534", borderRadius: 4, padding: "2px 6px" }}>
            🖥️ {lead.estimated_machines}m
          </span>
        )}
      </div>

      {/* Follow-up row */}
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginTop: 4 }}>
        {lead.next_follow_up_date ? (
          <div style={{ fontSize: 10, ...followUpStyle(lead.next_follow_up_date) }}>
            {overdueFollowUp ? "⚠️ " : "📅 "}Follow-up {fmt(lead.next_follow_up_date)}
          </div>
        ) : lead.last_contact_date ? (
          <div style={{ fontSize: 10, color: "#9ca3af" }}>
            Last: {fmt(lead.last_contact_date)}
          </div>
        ) : (
          <div style={{ fontSize: 10, color: "#d1d5db" }}>No contact date</div>
        )}
        {lead.rev_share != null && lead.rev_share > 0 && (
          <span style={{ fontSize: 10, background: "#fef3c7", color: "#92400e", borderRadius: 4, padding: "1px 5px" }}>
            {lead.rev_share}% RS
          </span>
        )}
      </div>

      {/* Notes snippet */}
      {lead.notes && (
        <div style={{
          marginTop: 8,
          fontSize: 11,
          color: "#9ca3af",
          borderTop: "1px solid #f5f4f2",
          paddingTop: 6,
          whiteSpace: "nowrap",
          overflow: "hidden",
          textOverflow: "ellipsis",
        }}>
          💬 {lead.notes}
        </div>
      )}
    </div>
  );
}

// ─── Kanban Column ────────────────────────────────────────────────────────────

function KanbanColumn({
  title,
  leads,
  isDropTarget,
  onDragOver,
  onDragLeave,
  onDrop,
  onDragStart,
  onCardClick,
}: {
  title: string;
  leads: SalesLead[];
  isDropTarget: boolean;
  onDragOver: (e: React.DragEvent) => void;
  onDragLeave: () => void;
  onDrop: (e: React.DragEvent) => void;
  onDragStart: (id: string) => void;
  onCardClick: (lead: SalesLead) => void;
}) {
  return (
    <div
      onDragOver={(e) => { e.preventDefault(); onDragOver(e); }}
      onDragLeave={onDragLeave}
      onDrop={onDrop}
      style={{
        minWidth: 240,
        width: 260,
        flexShrink: 0,
        background: isDropTarget ? "#f0fdf4" : "#f8f7f5",
        border: isDropTarget ? "2px dashed #24544a" : "1px solid #e8e4de",
        borderRadius: 12,
        padding: "12px 10px",
        transition: "background 0.15s, border 0.15s",
      }}
    >
      {/* Column header */}
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 10, paddingBottom: 8, borderBottom: "1px solid #e8e4de" }}>
        <span style={{ fontSize: 11, fontWeight: 700, letterSpacing: "0.06em", textTransform: "uppercase", color: "#374151" }}>
          {title}
        </span>
        <span style={{
          background: leads.length > 0 ? "#0a0a0a" : "#e8e4de",
          color: leads.length > 0 ? "white" : "#9ca3af",
          borderRadius: 10,
          padding: "1px 7px",
          fontSize: 11,
          fontWeight: 700,
        }}>
          {leads.length}
        </span>
      </div>

      {/* Cards */}
      <div style={{ display: "flex", flexDirection: "column", gap: 8, minHeight: 60 }}>
        {leads.map((lead) => (
          <LeadCard
            key={lead.id}
            lead={lead}
            onDragStart={onDragStart}
            onClick={onCardClick}
          />
        ))}
        {leads.length === 0 && (
          <div style={{ textAlign: "center", padding: "16px 8px", color: "#d1d5db", fontSize: 11 }}>
            Drop here
          </div>
        )}
      </div>
    </div>
  );
}

// ─── Lead Drawer ──────────────────────────────────────────────────────────────

function LeadDrawer({
  lead,
  onClose,
  onSaved,
}: {
  lead: SalesLead | "new";
  onClose: () => void;
  onSaved: () => void;
}) {
  const isNew = lead === "new";
  const [form, setForm] = useState<Omit<SalesLead, "id" | "created_at" | "updated_at">>(
    isNew ? { ...EMPTY_LEAD } : { ...lead as SalesLead }
  );
  const [editMode, setEditMode] = useState(isNew);
  const [saving, setSaving] = useState(false);
  const [activities, setActivities] = useState<Activity[]>([]);
  const [loadingAct, setLoadingAct] = useState(!isNew);
  const [newAct, setNewAct] = useState({ type: "note", content: "", reminder_date: "", created_by: "CS" });
  const [savingAct, setSavingAct] = useState(false);

  // Load activities for existing leads
  useEffect(() => {
    if (isNew) return;
    const leadId = (lead as SalesLead).id;
    const supabase = createClient();
    supabase
      .from("sales_lead_activities")
      .select("*")
      .eq("lead_id", leadId)
      .order("created_at", { ascending: false })
      .limit(100)
      .then(({ data }) => {
        setActivities((data as Activity[]) ?? []);
        setLoadingAct(false);
      });
  }, [isNew, lead]);

  function setField(key: keyof typeof form, value: string | number | null) {
    setForm((prev) => ({ ...prev, [key]: value }));
  }

  async function handleSave() {
    setSaving(true);
    const supabase = createClient();
    const payload = {
      lead_ref: form.lead_ref || null,
      lead_owner: form.lead_owner || null,
      company_name: form.company_name,
      engagement_status: form.engagement_status,
      funnel_stage: form.funnel_stage,
      priority_order: form.priority_order,
      estimated_machines: form.estimated_machines,
      relationship_type: form.relationship_type || null,
      contact_person: form.contact_person || null,
      contact_email: form.contact_email || null,
      contact_phone: form.contact_phone || null,
      area: form.area || null,
      location_address: form.location_address || null,
      location_type: form.location_type || null,
      date_initiated: form.date_initiated || null,
      rev_share: form.rev_share,
      last_contact_date: form.last_contact_date || null,
      next_follow_up_date: form.next_follow_up_date || null,
      installation_date: form.installation_date || null,
      notes: form.notes || null,
    };

    if (isNew) {
      const { error } = await supabase.from("sales_leads").insert(payload);
      if (error) { alert("Error saving: " + error.message); setSaving(false); return; }
    } else {
      const { error } = await supabase
        .from("sales_leads")
        .update(payload)
        .eq("id", (lead as SalesLead).id);
      if (error) { alert("Error saving: " + error.message); setSaving(false); return; }
    }
    setSaving(false);
    setEditMode(false);
    onSaved();
  }

  async function handleAddActivity() {
    if (!newAct.content.trim() || isNew) return;
    setSavingAct(true);
    const supabase = createClient();
    const { data, error } = await supabase
      .from("sales_lead_activities")
      .insert({
        lead_id: (lead as SalesLead).id,
        activity_type: newAct.type,
        content: newAct.content.trim(),
        reminder_date: newAct.reminder_date || null,
        created_by: newAct.created_by || null,
      })
      .select("*")
      .single();
    if (!error && data) {
      setActivities((prev) => [data as Activity, ...prev]);
      setNewAct({ type: "note", content: "", reminder_date: "", created_by: newAct.created_by });
    }
    setSavingAct(false);
  }

  // Close on ESC
  useEffect(() => {
    const h = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, [onClose]);

  return (
    <>
      {/* Backdrop */}
      <div
        onClick={onClose}
        style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.3)", zIndex: 40 }}
      />

      {/* Panel */}
      <div style={{
        position: "fixed", right: 0, top: 0, bottom: 0,
        width: 520,
        background: "white",
        zIndex: 50,
        display: "flex",
        flexDirection: "column",
        boxShadow: "-8px 0 40px rgba(0,0,0,0.12)",
        fontFamily: "'Plus Jakarta Sans', sans-serif",
      }}>
        {/* Header */}
        <div style={{ padding: "20px 24px 16px", borderBottom: "1px solid #e8e4de", display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: 12, flexShrink: 0 }}>
          <div style={{ flex: 1, minWidth: 0 }}>
            {editMode ? (
              <input
                value={form.company_name}
                onChange={(e) => setField("company_name", e.target.value)}
                placeholder="Company name"
                style={{ fontSize: 20, fontWeight: 800, color: "#0a0a0a", border: "none", borderBottom: "2px solid #24544a", outline: "none", width: "100%", fontFamily: "'Plus Jakarta Sans', sans-serif", background: "transparent", padding: "2px 0" }}
              />
            ) : (
              <h2 style={{ margin: 0, fontSize: 20, fontWeight: 800, color: "#0a0a0a", letterSpacing: "-0.02em" }}>
                {form.company_name || "New Lead"}
              </h2>
            )}
            <div style={{ display: "flex", gap: 6, marginTop: 8, flexWrap: "wrap", alignItems: "center" }}>
              {ownerBadge(form.lead_owner)}
              {stageBadge(form.funnel_stage)}
              {engagementBadge(form.engagement_status)}
              {form.lead_ref && <span style={{ fontSize: 10, color: "#9ca3af" }}>{form.lead_ref}</span>}
            </div>
          </div>
          <div style={{ display: "flex", gap: 8, alignItems: "center", flexShrink: 0 }}>
            {!isNew && !editMode && (
              <button
                onClick={() => setEditMode(true)}
                style={{ background: "#f5f4f2", border: "none", borderRadius: 8, padding: "6px 12px", fontSize: 12, fontWeight: 600, cursor: "pointer", color: "#374151" }}
              >
                ✎ Edit
              </button>
            )}
            {editMode && (
              <>
                <button
                  onClick={() => { setEditMode(false); if (isNew) onClose(); }}
                  style={{ background: "#f5f4f2", border: "none", borderRadius: 8, padding: "6px 12px", fontSize: 12, fontWeight: 600, cursor: "pointer", color: "#374151" }}
                >
                  Cancel
                </button>
                <button
                  onClick={handleSave}
                  disabled={saving || !form.company_name}
                  style={{ background: saving ? "#d1d5db" : "#24544a", border: "none", borderRadius: 8, padding: "6px 14px", fontSize: 12, fontWeight: 600, cursor: saving ? "not-allowed" : "pointer", color: "white" }}
                >
                  {saving ? "Saving…" : isNew ? "Add Lead" : "Save Changes"}
                </button>
              </>
            )}
            <button onClick={onClose} style={{ background: "transparent", border: "none", fontSize: 18, cursor: "pointer", color: "#6b6860", padding: "4px 8px", lineHeight: 1 }}>
              ×
            </button>
          </div>
        </div>

        {/* Scrollable content */}
        <div style={{ flex: 1, overflowY: "auto", padding: "20px 24px" }}>

          {/* ── Stage & Status ── */}
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
            {editMode ? (
              <>
                <SelectField label="Funnel Stage" value={form.funnel_stage} options={FUNNEL_STAGES} onChange={(v) => setField("funnel_stage", v)} />
                <SelectField label="Engagement" value={form.engagement_status} options={ENGAGEMENT_STATUSES} onChange={(v) => setField("engagement_status", v)} />
                <SelectField label="Priority Order" value={String(form.priority_order ?? 5)} options={PRIORITY_ORDERS.map(String)} onChange={(v) => setField("priority_order", Number(v))} />
                <SelectField label="Lead Owner" value={form.lead_owner ?? ""} options={["CS", "RK", "CE", "HR", "CS/RK"]} onChange={(v) => setField("lead_owner", v)} />
              </>
            ) : (
              <>
                <ViewField label="Funnel Stage">{stageBadge(form.funnel_stage)}</ViewField>
                <ViewField label="Engagement">{engagementBadge(form.engagement_status)}</ViewField>
                <ViewField label="Priority">{PRIORITY_LABELS[form.priority_order ?? 5] ?? `Tier ${form.priority_order}`}</ViewField>
                <ViewField label="Lead Owner">{ownerBadge(form.lead_owner)}</ViewField>
              </>
            )}
          </div>

          <Divider label="Contact" />

          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
            {editMode ? (
              <>
                <InputField label="Contact Person" value={form.contact_person ?? ""} onChange={(v) => setField("contact_person", v)} />
                <InputField label="Phone" value={form.contact_phone ?? ""} onChange={(v) => setField("contact_phone", v)} />
                <InputField label="Email" value={form.contact_email ?? ""} onChange={(v) => setField("contact_email", v)} type="email" />
                <InputField label="Relationship" value={form.relationship_type ?? ""} onChange={(v) => setField("relationship_type", v)} />
              </>
            ) : (
              <>
                <ViewField label="Contact">{form.contact_person}</ViewField>
                <ViewField label="Phone">{form.contact_phone}</ViewField>
                <ViewField label="Email">{form.contact_email ? <a href={`mailto:${form.contact_email}`} style={{ color: "#24544a" }}>{form.contact_email}</a> : "—"}</ViewField>
                <ViewField label="Relationship">{form.relationship_type}</ViewField>
              </>
            )}
          </div>

          <Divider label="Location" />

          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
            {editMode ? (
              <>
                <InputField label="Area" value={form.area ?? ""} onChange={(v) => setField("area", v)} />
                <InputField label="Location Type" value={form.location_type ?? ""} onChange={(v) => setField("location_type", v)} />
                <div style={{ gridColumn: "1 / -1" }}>
                  <InputField label="Address / Maps Link" value={form.location_address ?? ""} onChange={(v) => setField("location_address", v)} />
                </div>
              </>
            ) : (
              <>
                <ViewField label="Area">{form.area}</ViewField>
                <ViewField label="Location Type">{form.location_type ? `${LOCATION_ICONS[form.location_type] ?? "📍"} ${form.location_type}` : "—"}</ViewField>
                <ViewField label="Address" style={{ gridColumn: "1 / -1" }}>
                  {form.location_address?.startsWith("http") ? (
                    <a href={form.location_address} target="_blank" rel="noreferrer" style={{ color: "#24544a", fontSize: 12 }}>📍 Open in Maps</a>
                  ) : form.location_address || "—"}
                </ViewField>
              </>
            )}
          </div>

          <Divider label="Commercials" />

          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 12 }}>
            {editMode ? (
              <>
                <InputField label="Est. Machines" value={String(form.estimated_machines ?? "")} onChange={(v) => setField("estimated_machines", v ? Number(v) : null)} type="number" />
                <InputField label="Rev Share %" value={String(form.rev_share ?? "")} onChange={(v) => setField("rev_share", v ? Number(v) : null)} type="number" />
                <InputField label="Lead Ref" value={form.lead_ref ?? ""} onChange={(v) => setField("lead_ref", v)} />
              </>
            ) : (
              <>
                <ViewField label="Est. Machines">{form.estimated_machines != null ? `${form.estimated_machines} machine${form.estimated_machines !== 1 ? "s" : ""}` : "—"}</ViewField>
                <ViewField label="Rev Share">{form.rev_share != null ? `${form.rev_share}%` : "—"}</ViewField>
                <ViewField label="Lead Ref">{form.lead_ref}</ViewField>
              </>
            )}
          </div>

          <Divider label="Dates" />

          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
            {editMode ? (
              <>
                <InputField label="Date Initiated" value={form.date_initiated ?? ""} onChange={(v) => setField("date_initiated", v)} type="date" />
                <InputField label="Last Contact" value={form.last_contact_date ?? ""} onChange={(v) => setField("last_contact_date", v)} type="date" />
                <InputField label="Next Follow-Up" value={form.next_follow_up_date ?? ""} onChange={(v) => setField("next_follow_up_date", v)} type="date" />
                <InputField label="Installation Date" value={form.installation_date ?? ""} onChange={(v) => setField("installation_date", v)} type="date" />
              </>
            ) : (
              <>
                <ViewField label="Date Initiated">{fmt(form.date_initiated)}</ViewField>
                <ViewField label="Last Contact">{fmt(form.last_contact_date)}</ViewField>
                <ViewField label="Next Follow-Up">
                  <span style={followUpStyle(form.next_follow_up_date)}>
                    {fmt(form.next_follow_up_date)}
                  </span>
                </ViewField>
                <ViewField label="Installation">{fmt(form.installation_date)}</ViewField>
              </>
            )}
          </div>

          <Divider label="Notes" />
          {editMode ? (
            <InputField label="Notes" value={form.notes ?? ""} onChange={(v) => setField("notes", v)} type="textarea" />
          ) : (
            <div style={{ fontSize: 13, color: "#374151", lineHeight: 1.6, background: "#f8f7f5", borderRadius: 8, padding: "10px 12px", minHeight: 40 }}>
              {form.notes || <span style={{ color: "#9ca3af" }}>No notes yet</span>}
            </div>
          )}

          {/* ── Activity Log ── */}
          {!isNew && (
            <>
              <Divider label="Activity Log" />

              {/* Add activity */}
              <div style={{ background: "#f8f7f5", borderRadius: 10, padding: "12px 14px", marginBottom: 16 }}>
                <div style={{ display: "flex", gap: 8, marginBottom: 8 }}>
                  <select
                    value={newAct.type}
                    onChange={(e) => setNewAct((p) => ({ ...p, type: e.target.value }))}
                    style={{ border: "1px solid #e8e4de", borderRadius: 6, padding: "6px 8px", fontSize: 12, background: "white", fontFamily: "'Plus Jakarta Sans', sans-serif", color: "#0a0a0a" }}
                  >
                    {Object.keys(ACTIVITY_ICONS).map((t) => (
                      <option key={t} value={t}>{ACTIVITY_ICONS[t]} {t.charAt(0).toUpperCase() + t.slice(1)}</option>
                    ))}
                  </select>
                  <select
                    value={newAct.created_by}
                    onChange={(e) => setNewAct((p) => ({ ...p, created_by: e.target.value }))}
                    style={{ border: "1px solid #e8e4de", borderRadius: 6, padding: "6px 8px", fontSize: 12, background: "white", fontFamily: "'Plus Jakarta Sans', sans-serif", color: "#0a0a0a" }}
                  >
                    {["CS", "RK", "CE", "HR"].map((o) => <option key={o} value={o}>{o}</option>)}
                  </select>
                  {newAct.type === "reminder" && (
                    <input
                      type="date"
                      value={newAct.reminder_date}
                      onChange={(e) => setNewAct((p) => ({ ...p, reminder_date: e.target.value }))}
                      style={{ border: "1px solid #e8e4de", borderRadius: 6, padding: "6px 8px", fontSize: 12, background: "white", fontFamily: "'Plus Jakarta Sans', sans-serif", color: "#0a0a0a" }}
                    />
                  )}
                </div>
                <div style={{ display: "flex", gap: 8 }}>
                  <input
                    value={newAct.content}
                    onChange={(e) => setNewAct((p) => ({ ...p, content: e.target.value }))}
                    placeholder="Add a note, call summary, or reminder…"
                    onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); handleAddActivity(); }}}
                    style={{ flex: 1, border: "1px solid #e8e4de", borderRadius: 6, padding: "8px 10px", fontSize: 12, background: "white", fontFamily: "'Plus Jakarta Sans', sans-serif", color: "#0a0a0a", outline: "none" }}
                  />
                  <button
                    onClick={handleAddActivity}
                    disabled={savingAct || !newAct.content.trim()}
                    style={{ background: "#24544a", border: "none", borderRadius: 6, padding: "8px 14px", fontSize: 12, fontWeight: 600, cursor: "pointer", color: "white", flexShrink: 0 }}
                  >
                    {savingAct ? "…" : "Add"}
                  </button>
                </div>
              </div>

              {/* Activity list */}
              {loadingAct ? (
                <div style={{ color: "#9ca3af", fontSize: 12, textAlign: "center", padding: 16 }}>Loading…</div>
              ) : activities.length === 0 ? (
                <div style={{ color: "#9ca3af", fontSize: 12, textAlign: "center", padding: 16 }}>No activity yet. Add your first note above.</div>
              ) : (
                <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                  {activities.map((act) => (
                    <div key={act.id} style={{ display: "flex", gap: 10, padding: "10px 12px", background: "white", border: "1px solid #e8e4de", borderRadius: 8 }}>
                      <div style={{ fontSize: 16, flexShrink: 0, marginTop: 1 }}>{ACTIVITY_ICONS[act.activity_type] ?? "📝"}</div>
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontSize: 12, color: "#374151", lineHeight: 1.5 }}>{act.content}</div>
                        <div style={{ display: "flex", gap: 8, marginTop: 4, flexWrap: "wrap" }}>
                          {act.reminder_date && (
                            <span style={{ fontSize: 10, color: "#d97706" }}>🔔 Reminder: {fmt(act.reminder_date)}</span>
                          )}
                          <span style={{ fontSize: 10, color: "#9ca3af" }}>
                            {act.created_by && <>{act.created_by} · </>}
                            {new Date(act.created_at).toLocaleDateString("en-AE", { day: "numeric", month: "short", year: "2-digit", hour: "2-digit", minute: "2-digit" })}
                          </span>
                        </div>
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </>
          )}
        </div>
      </div>
    </>
  );
}

function ViewField({ label, children, style }: { label: string; children: React.ReactNode; style?: React.CSSProperties }) {
  return (
    <div style={{ marginBottom: 2, ...style }}>
      <div style={{ fontSize: 10, fontWeight: 700, letterSpacing: "0.08em", textTransform: "uppercase", color: "#6b6860", marginBottom: 3 }}>{label}</div>
      <div style={{ fontSize: 13, color: "#0a0a0a", fontWeight: 500, minHeight: 18 }}>
        {children ?? <span style={{ color: "#d1d5db" }}>—</span>}
      </div>
    </div>
  );
}

function Divider({ label }: { label: string }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 10, margin: "20px 0 14px" }}>
      <div style={{ fontSize: 10, fontWeight: 700, letterSpacing: "0.1em", textTransform: "uppercase", color: "#6b6860", whiteSpace: "nowrap" }}>{label}</div>
      <div style={{ flex: 1, height: 1, background: "#e8e4de" }} />
    </div>
  );
}

// ─── Main Page ────────────────────────────────────────────────────────────────

type TabType = "funnel" | "engagement" | "order";

export default function SalesPipelinePage() {
  const [leads, setLeads] = useState<SalesLead[]>([]);
  const [loading, setLoading] = useState(true);
  const [activeTab, setActiveTab] = useState<TabType>("funnel");
  const [selectedLead, setSelectedLead] = useState<SalesLead | "new" | null>(null);
  const [draggingId, setDraggingId] = useState<string | null>(null);
  const [dragOverColumn, setDragOverColumn] = useState<string | null>(null);
  const [filterOwner, setFilterOwner] = useState("All");
  const [filterEngagement, setFilterEngagement] = useState<string[]>(
    ENGAGEMENT_STATUSES.filter((s) => s !== "Inactive")
  );
  const [filterOverdue, setFilterOverdue] = useState(false);
  const [search, setSearch] = useState("");
  const [fetchKey, setFetchKey] = useState(0);

  // Fetch leads
  useEffect(() => {
    const supabase = createClient();
    supabase
      .from("sales_leads")
      .select("*")
      .order("priority_order", { ascending: true })
      .order("company_name", { ascending: true })
      .limit(500)
      .then(({ data, error }) => {
        if (error) console.error("sales_leads fetch:", error);
        setLeads((data as SalesLead[]) ?? []);
        setLoading(false);
      });
  }, [fetchKey]);

  // Stats
  const totalLeads = leads.length;
  const activeCount = leads.filter((l) => l.engagement_status === "Active").length;
  const wonCount = leads.filter((l) => l.engagement_status === "Closed-Won").length;
  const totalMachines = leads.reduce((a, l) => a + (l.estimated_machines ?? 0), 0);
  const overdueCount = leads.filter((l) => {
    if (!l.next_follow_up_date) return false;
    return new Date(l.next_follow_up_date + "T00:00:00") < new Date();
  }).length;
  const wonMachines = leads.filter((l) => l.engagement_status === "Closed-Won").reduce((a, l) => a + (l.estimated_machines ?? 0), 0);

  // Filter & search
  const filtered = useMemo(() => {
    return leads.filter((l) => {
      if (filterOwner !== "All" && l.lead_owner !== filterOwner) return false;
      if (filterEngagement.length < ENGAGEMENT_STATUSES.length && !filterEngagement.includes(l.engagement_status)) return false;
      if (filterOverdue) {
        if (!l.next_follow_up_date) return false;
        if (new Date(l.next_follow_up_date + "T00:00:00") >= new Date()) return false;
      }
      if (search) {
        const q = search.toLowerCase();
        if (
          !l.company_name.toLowerCase().includes(q) &&
          !(l.contact_person?.toLowerCase().includes(q)) &&
          !(l.area?.toLowerCase().includes(q)) &&
          !(l.notes?.toLowerCase().includes(q))
        ) return false;
      }
      return true;
    });
  }, [leads, filterOwner, filterEngagement, filterOverdue, search]);

  // Kanban columns
  const columns: string[] = useMemo(() => {
    if (activeTab === "funnel") return FUNNEL_STAGES;
    if (activeTab === "engagement") return ENGAGEMENT_STATUSES;
    return PRIORITY_ORDERS.map(String);
  }, [activeTab]);

  function getColumnKey(lead: SalesLead): string {
    if (activeTab === "funnel") return lead.funnel_stage;
    if (activeTab === "engagement") return lead.engagement_status;
    return String(lead.priority_order ?? 5);
  }

  // Drag handlers
  const handleDragStart = useCallback((id: string) => setDraggingId(id), []);

  const handleDrop = useCallback(async (col: string) => {
    if (!draggingId) return;
    setDragOverColumn(null);
    const supabase = createClient();
    const patch: Record<string, unknown> = {};
    if (activeTab === "funnel") patch.funnel_stage = col;
    else if (activeTab === "engagement") patch.engagement_status = col;
    else patch.priority_order = Number(col);

    setLeads((prev) =>
      prev.map((l) => (l.id === draggingId ? { ...l, ...patch } : l))
    );

    const { error } = await supabase
      .from("sales_leads")
      .update(patch)
      .eq("id", draggingId);
    if (error) {
      console.error("drag update error:", error);
      setFetchKey((k) => k + 1);
    }
    setDraggingId(null);
  }, [draggingId, activeTab]);

  const columnLabel = (col: string) => {
    if (activeTab === "order") return PRIORITY_LABELS[Number(col)] ?? `Tier ${col}`;
    return col;
  };

  return (
    <div style={{ padding: "32px 32px 48px", minHeight: "100vh", background: "#fafaf9", fontFamily: "'Plus Jakarta Sans', sans-serif" }}>

      {/* ── Header ── */}
      <div style={{ display: "flex", alignItems: "flex-end", justifyContent: "space-between", marginBottom: 28 }}>
        <div>
          <h1 style={{ margin: 0, fontSize: 28, fontWeight: 800, color: "#0a0a0a", letterSpacing: "-0.02em" }}>
            Sales Pipeline
          </h1>
          <p style={{ margin: "4px 0 0", color: "#6b6860", fontSize: 14 }}>
            {loading ? "Loading…" : `${totalLeads} leads tracked across all stages`}
          </p>
        </div>
        <button
          onClick={() => setSelectedLead("new")}
          style={{
            background: "#24544a", color: "white", border: "none", borderRadius: 10,
            padding: "10px 20px", fontSize: 13, fontWeight: 700, cursor: "pointer",
            boxShadow: "0 2px 8px rgba(36,84,74,0.3)",
          }}
        >
          + Add Lead
        </button>
      </div>

      {/* ── Stats ── */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(5, 1fr)", gap: 12, marginBottom: 28 }}>
        <StatCard label="Total Leads" value={totalLeads} sub="All stages" />
        <StatCard label="Active Pipeline" value={activeCount} sub={`${totalMachines - wonMachines} est. machines`} color="#24544a" />
        <StatCard label="Closed-Won" value={wonCount} sub={`${wonMachines} machines installed`} color="#1d4ed8" />
        <StatCard label="Overdue Follow-Ups" value={overdueCount} sub="Need attention" color={overdueCount > 0 ? "#dc2626" : "#6b6860"} />
        <StatCard label="Total Est. Machines" value={totalMachines} sub="Across all leads" />
      </div>

      {/* ── Toolbar ── */}
      <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 20, flexWrap: "wrap" }}>

        {/* Tabs */}
        <div style={{ display: "flex", background: "#f1f0ee", borderRadius: 10, padding: 3, gap: 2 }}>
          {(["funnel", "engagement", "order"] as TabType[]).map((tab) => (
            <button
              key={tab}
              onClick={() => setActiveTab(tab)}
              style={{
                background: activeTab === tab ? "white" : "transparent",
                border: "none", borderRadius: 7,
                padding: "7px 16px", fontSize: 12, fontWeight: 600,
                cursor: "pointer",
                color: activeTab === tab ? "#0a0a0a" : "#6b6860",
                boxShadow: activeTab === tab ? "0 1px 4px rgba(0,0,0,0.1)" : "none",
                transition: "all 0.15s",
              }}
            >
              {tab === "funnel" ? "⬡ Funnel" : tab === "engagement" ? "◈ Engagement" : "⬛ Order"}
            </button>
          ))}
        </div>

        {/* Search */}
        <input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search companies, contacts, areas…"
          style={{
            border: "1px solid #e8e4de", borderRadius: 8, padding: "8px 12px",
            fontSize: 13, color: "#0a0a0a", background: "white",
            fontFamily: "'Plus Jakarta Sans', sans-serif",
            outline: "none", width: 240,
          }}
        />

        {/* Owner filter */}
        <div style={{ display: "flex", gap: 4 }}>
          {["All", "CS", "RK", "CE", "HR", "CS/RK"].map((o) => (
            <button
              key={o}
              onClick={() => setFilterOwner(o)}
              style={{
                background: filterOwner === o ? (OWNER_COLORS[o] ?? "#0a0a0a") : "#f1f0ee",
                color: filterOwner === o ? "white" : "#6b6860",
                border: "none", borderRadius: 6,
                padding: "5px 10px", fontSize: 11, fontWeight: 600,
                cursor: "pointer", transition: "all 0.15s",
              }}
            >
              {o}
            </button>
          ))}
        </div>

        {/* Engagement multi-select filter */}
        <div style={{ display: "flex", gap: 4, alignItems: "center" }}>
          {ENGAGEMENT_STATUSES.map((s) => {
            const active = filterEngagement.includes(s);
            const c = ENGAGEMENT_COLORS[s];
            return (
              <button
                key={s}
                onClick={() =>
                  setFilterEngagement((prev) =>
                    prev.includes(s)
                      ? prev.filter((x) => x !== s)
                      : [...prev, s]
                  )
                }
                style={{
                  background: active ? c.bg : "#f1f0ee",
                  color: active ? c.text : "#9ca3af",
                  border: active ? `1px solid ${c.text}44` : "1px solid transparent",
                  borderRadius: 6,
                  padding: "5px 10px", fontSize: 11, fontWeight: 600,
                  cursor: "pointer", transition: "all 0.15s",
                  textDecoration: active ? "none" : "line-through",
                  opacity: active ? 1 : 0.6,
                }}
              >
                {s}
              </button>
            );
          })}
        </div>

        {/* Overdue toggle */}
        <button
          onClick={() => setFilterOverdue((v) => !v)}
          style={{
            background: filterOverdue ? "#fee2e2" : "#f1f0ee",
            color: filterOverdue ? "#b91c1c" : "#6b6860",
            border: filterOverdue ? "1px solid #fca5a5" : "1px solid transparent",
            borderRadius: 6,
            padding: "5px 11px", fontSize: 11, fontWeight: 700,
            cursor: "pointer", transition: "all 0.15s",
            display: "flex", alignItems: "center", gap: 5,
          }}
        >
          ⚠️ Overdue{overdueCount > 0 && (
            <span style={{
              background: filterOverdue ? "#b91c1c" : "#dc2626",
              color: "white",
              borderRadius: 8,
              padding: "0px 5px",
              fontSize: 10,
              fontWeight: 800,
            }}>{overdueCount}</span>
          )}
        </button>

        {/* Count */}
        {filtered.length !== totalLeads && (
          <span style={{ fontSize: 12, color: "#9ca3af" }}>
            Showing {filtered.length} of {totalLeads}
          </span>
        )}
      </div>

      {/* ── Kanban Board ── */}
      {loading ? (
        <div style={{ textAlign: "center", padding: 80, color: "#9ca3af" }}>Loading pipeline…</div>
      ) : (
        <div style={{ display: "flex", gap: 12, overflowX: "auto", paddingBottom: 24, alignItems: "flex-start" }}>
          {columns.map((col) => {
            const colLeads = filtered.filter((l) => getColumnKey(l) === col);
            return (
              <KanbanColumn
                key={col}
                title={columnLabel(col)}
                leads={colLeads}
                isDropTarget={dragOverColumn === col}
                onDragOver={() => setDragOverColumn(col)}
                onDragLeave={() => setDragOverColumn((prev) => (prev === col ? null : prev))}
                onDrop={() => handleDrop(col)}
                onDragStart={handleDragStart}
                onCardClick={(lead) => setSelectedLead(lead)}
              />
            );
          })}
        </div>
      )}

      {/* ── Lead Drawer ── */}
      {selectedLead !== null && (
        <LeadDrawer
          lead={selectedLead}
          onClose={() => setSelectedLead(null)}
          onSaved={() => {
            setSelectedLead(null);
            setFetchKey((k) => k + 1);
          }}
        />
      )}
    </div>
  );
}
