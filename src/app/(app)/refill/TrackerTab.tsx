"use client";

import { useState, useEffect, useCallback } from "react";
import { createBrowserClient } from "@supabase/ssr";

// ── Types ────────────────────────────────────────────────────────────────────

type ActionItem = {
  action_id: string;
  type: string;
  title: string;
  description: string | null;
  machine_name: string | null;
  status: string;
  priority: string;
  assignee: string | null;
  due_date: string | null;
  source: string | null;
  created_at: string;
  updated_at: string;
  resolved_at: string | null;
};

type FilterType = "all" | "bug" | "driver_feedback" | "intent" | "decommission" | "task" | "other";
type FilterStatus = "all" | "open" | "in_progress" | "done" | "dismissed";
type Category = "tech" | "refill" | "products" | "others";

const CATEGORIES: { key: Category; label: string; icon: string; types: string[] }[] = [
  { key: "tech", label: "Tech", icon: "🛠", types: ["bug"] },
  { key: "refill", label: "Refill", icon: "🚚", types: ["driver_feedback", "task"] },
  { key: "products", label: "Products", icon: "📦", types: ["decommission", "intent"] },
  { key: "others", label: "Others", icon: "📋", types: ["other"] },
];

const CATEGORY_COLORS: Record<Category, { bg: string; border: string; header: string }> = {
  tech: { bg: "#fef2f2", border: "#fecaca", header: "#991b1b" },
  refill: { bg: "#eff6ff", border: "#bfdbfe", header: "#1e40af" },
  products: { bg: "#fff7ed", border: "#fed7aa", header: "#9a3412" },
  others: { bg: "#f9fafb", border: "#e5e7eb", header: "#6b7280" },
};

function getCategory(type: string): Category {
  for (const cat of CATEGORIES) {
    if (cat.types.includes(type)) return cat.key;
  }
  return "others";
}

const TYPE_LABELS: Record<string, string> = {
  bug: "Bug",
  driver_feedback: "Driver Feedback",
  intent: "Intent",
  decommission: "Decommission",
  task: "Task",
  other: "Other",
};

const STATUS_COLORS: Record<string, { bg: string; text: string }> = {
  open: { bg: "#fef3c7", text: "#92400e" },
  in_progress: { bg: "#dbeafe", text: "#1e40af" },
  done: { bg: "#d1fae5", text: "#065f46" },
  dismissed: { bg: "#f3f4f6", text: "#6b7280" },
};

const PRIORITY_COLORS: Record<string, { bg: string; text: string }> = {
  critical: { bg: "#fee2e2", text: "#991b1b" },
  high: { bg: "#ffedd5", text: "#9a3412" },
  medium: { bg: "#fef9c3", text: "#854d0e" },
  low: { bg: "#f0fdf4", text: "#166534" },
};

const TYPE_COLORS: Record<string, { bg: string; text: string }> = {
  bug: { bg: "#fee2e2", text: "#991b1b" },
  driver_feedback: { bg: "#dbeafe", text: "#1e40af" },
  intent: { bg: "#ede9fe", text: "#5b21b6" },
  decommission: { bg: "#ffedd5", text: "#9a3412" },
  task: { bg: "#d1fae5", text: "#065f46" },
  other: { bg: "#f3f4f6", text: "#6b7280" },
};

// ── Component ────────────────────────────────────────────────────────────────

export function TrackerTab() {
  const supabase = createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  );

  const [items, setItems] = useState<ActionItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [filterCategory, setFilterCategory] = useState<"all" | Category>("all");
  const [filterStatus, setFilterStatus] = useState<FilterStatus>("open");
  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);

  // Form state
  const [formType, setFormType] = useState<string>("task");
  const [formTitle, setFormTitle] = useState("");
  const [formDesc, setFormDesc] = useState("");
  const [formMachine, setFormMachine] = useState("");
  const [formPriority, setFormPriority] = useState("medium");
  const [formAssignee, setFormAssignee] = useState("");
  const [formDueDate, setFormDueDate] = useState("");

  const fetchItems = useCallback(async () => {
    setLoading(true);
    let query = supabase
      .from("action_tracker")
      .select("*")
      .order("created_at", { ascending: false });

    if (filterCategory !== "all") {
      const cat = CATEGORIES.find((c) => c.key === filterCategory);
      if (cat) query = query.in("type", cat.types);
    }
    if (filterStatus !== "all") query = query.eq("status", filterStatus);

    const { data, error } = await query;
    if (!error && data) setItems(data as ActionItem[]);
    setLoading(false);
  }, [filterCategory, filterStatus]);

  useEffect(() => {
    fetchItems();
  }, [fetchItems]);

  const updateStatus = async (id: string, newStatus: string) => {
    const updates: Record<string, unknown> = {
      status: newStatus,
      updated_at: new Date().toISOString(),
    };
    if (newStatus === "done" || newStatus === "dismissed") {
      updates.resolved_at = new Date().toISOString();
    }
    if (newStatus === "open" || newStatus === "in_progress") {
      updates.resolved_at = null;
    }
    await supabase.from("action_tracker").update(updates).eq("action_id", id);
    fetchItems();
  };

  const handleSubmit = async () => {
    if (!formTitle.trim()) return;
    const row = {
      type: formType,
      title: formTitle.trim(),
      description: formDesc.trim() || null,
      machine_name: formMachine.trim() || null,
      priority: formPriority,
      assignee: formAssignee.trim() || null,
      due_date: formDueDate || null,
      status: "open" as const,
    };

    if (editingId) {
      await supabase
        .from("action_tracker")
        .update({ ...row, updated_at: new Date().toISOString() })
        .eq("action_id", editingId);
      setEditingId(null);
    } else {
      await supabase.from("action_tracker").insert(row);
    }

    setFormTitle("");
    setFormDesc("");
    setFormMachine("");
    setFormPriority("medium");
    setFormAssignee("");
    setFormDueDate("");
    setShowForm(false);
    fetchItems();
  };

  const startEdit = (item: ActionItem) => {
    setEditingId(item.action_id);
    setFormType(item.type);
    setFormTitle(item.title);
    setFormDesc(item.description || "");
    setFormMachine(item.machine_name || "");
    setFormPriority(item.priority);
    setFormAssignee(item.assignee || "");
    setFormDueDate(item.due_date || "");
    setShowForm(true);
  };

  const deleteItem = async (id: string) => {
    await supabase.from("action_tracker").delete().eq("action_id", id);
    fetchItems();
  };

  // ── Counts ──
  const openCount = items.filter((i) => i.status === "open").length;
  const inProgressCount = items.filter((i) => i.status === "in_progress").length;

  // ── Styles ──
  const badge = (colors: { bg: string; text: string }, label: string) => (
    <span
      style={{
        display: "inline-block",
        padding: "2px 8px",
        borderRadius: 4,
        fontSize: 11,
        fontWeight: 600,
        background: colors.bg,
        color: colors.text,
        textTransform: "uppercase",
        letterSpacing: "0.03em",
      }}
    >
      {label}
    </span>
  );

  const btnStyle = (active: boolean): React.CSSProperties => ({
    padding: "6px 12px",
    fontSize: 12,
    fontWeight: active ? 700 : 400,
    background: active ? "#0a0a0a" : "#f5f3ee",
    color: active ? "#fff" : "#6b6860",
    border: "1px solid " + (active ? "#0a0a0a" : "#e8e4de"),
    borderRadius: 6,
    cursor: "pointer",
  });

  const inputStyle: React.CSSProperties = {
    width: "100%",
    padding: "8px 12px",
    fontSize: 13,
    border: "1px solid #e8e4de",
    borderRadius: 6,
    background: "#fff",
    outline: "none",
  };

  return (
    <div>
      {/* ── Summary cards ──────────────────────────────────────────────── */}
      <div style={{ display: "flex", gap: 12, marginBottom: 20 }}>
        <div
          style={{
            flex: 1,
            background: "#fef3c7",
            borderRadius: 8,
            padding: "14px 18px",
          }}
        >
          <div style={{ fontSize: 11, color: "#92400e", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.05em" }}>
            Open
          </div>
          <div style={{ fontSize: 28, fontWeight: 700, color: "#92400e" }}>
            {openCount}
          </div>
        </div>
        <div
          style={{
            flex: 1,
            background: "#dbeafe",
            borderRadius: 8,
            padding: "14px 18px",
          }}
        >
          <div style={{ fontSize: 11, color: "#1e40af", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.05em" }}>
            In progress
          </div>
          <div style={{ fontSize: 28, fontWeight: 700, color: "#1e40af" }}>
            {inProgressCount}
          </div>
        </div>
        <div
          style={{
            flex: 1,
            background: "#f5f3ee",
            borderRadius: 8,
            padding: "14px 18px",
          }}
        >
          <div style={{ fontSize: 11, color: "#6b6860", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.05em" }}>
            Total shown
          </div>
          <div style={{ fontSize: 28, fontWeight: 700, color: "#0a0a0a" }}>
            {items.length}
          </div>
        </div>
      </div>

      {/* ── Filters + Add button ───────────────────────────────────────── */}
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          marginBottom: 16,
          flexWrap: "wrap",
          gap: 8,
        }}
      >
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
          <button onClick={() => setFilterCategory("all")} style={btnStyle(filterCategory === "all")}>All</button>
          {CATEGORIES.map((cat) => (
            <button
              key={cat.key}
              onClick={() => setFilterCategory(cat.key)}
              style={filterCategory === cat.key
                ? { ...btnStyle(false), background: CATEGORY_COLORS[cat.key].bg, color: CATEGORY_COLORS[cat.key].header, borderColor: CATEGORY_COLORS[cat.key].border, fontWeight: 700 }
                : btnStyle(false)}
            >
              {cat.icon} {cat.label}
            </button>
          ))}
        </div>
        <div style={{ display: "flex", gap: 6 }}>
          {(["all", "open", "in_progress", "done", "dismissed"] as FilterStatus[]).map(
            (s) => (
              <button key={s} onClick={() => setFilterStatus(s)} style={btnStyle(filterStatus === s)}>
                {s === "all" ? "All" : s === "in_progress" ? "In progress" : s.charAt(0).toUpperCase() + s.slice(1)}
              </button>
            )
          )}
        </div>
      </div>

      <div style={{ marginBottom: 16 }}>
        <button
          onClick={() => {
            setEditingId(null);
            setFormType("task");
            setFormTitle("");
            setFormDesc("");
            setFormMachine("");
            setFormPriority("medium");
            setFormAssignee("");
            setFormDueDate("");
            setShowForm(!showForm);
          }}
          style={{
            padding: "8px 20px",
            fontSize: 13,
            fontWeight: 600,
            background: "#0a0a0a",
            color: "#fff",
            border: "none",
            borderRadius: 6,
            cursor: "pointer",
          }}
        >
          {showForm ? "Cancel" : "+ Add action item"}
        </button>
      </div>

      {/* ── Add/Edit form ──────────────────────────────────────────────── */}
      {showForm && (
        <div
          style={{
            background: "#fafaf8",
            border: "1px solid #e8e4de",
            borderRadius: 8,
            padding: 20,
            marginBottom: 20,
          }}
        >
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 12, marginBottom: 12 }}>
            <div>
              <label style={{ fontSize: 11, fontWeight: 600, color: "#6b6860", textTransform: "uppercase" }}>Type</label>
              <select value={formType} onChange={(e) => setFormType(e.target.value)} style={inputStyle}>
                <option value="bug">Bug</option>
                <option value="driver_feedback">Driver Feedback</option>
                <option value="decommission">Decommission</option>
                <option value="intent">Intent</option>
                <option value="task">Task</option>
                <option value="other">Other</option>
              </select>
            </div>
            <div>
              <label style={{ fontSize: 11, fontWeight: 600, color: "#6b6860", textTransform: "uppercase" }}>Priority</label>
              <select value={formPriority} onChange={(e) => setFormPriority(e.target.value)} style={inputStyle}>
                <option value="critical">Critical</option>
                <option value="high">High</option>
                <option value="medium">Medium</option>
                <option value="low">Low</option>
              </select>
            </div>
            <div>
              <label style={{ fontSize: 11, fontWeight: 600, color: "#6b6860", textTransform: "uppercase" }}>Machine</label>
              <input value={formMachine} onChange={(e) => setFormMachine(e.target.value)} placeholder="e.g. JET-1016-0000-O1" style={inputStyle} />
            </div>
          </div>
          <div style={{ marginBottom: 12 }}>
            <label style={{ fontSize: 11, fontWeight: 600, color: "#6b6860", textTransform: "uppercase" }}>Title</label>
            <input value={formTitle} onChange={(e) => setFormTitle(e.target.value)} placeholder="Action item title" style={inputStyle} />
          </div>
          <div style={{ marginBottom: 12 }}>
            <label style={{ fontSize: 11, fontWeight: 600, color: "#6b6860", textTransform: "uppercase" }}>Description</label>
            <textarea value={formDesc} onChange={(e) => setFormDesc(e.target.value)} placeholder="Details..." rows={3} style={{ ...inputStyle, resize: "vertical" }} />
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12, marginBottom: 16 }}>
            <div>
              <label style={{ fontSize: 11, fontWeight: 600, color: "#6b6860", textTransform: "uppercase" }}>Assignee</label>
              <input value={formAssignee} onChange={(e) => setFormAssignee(e.target.value)} placeholder="Name" style={inputStyle} />
            </div>
            <div>
              <label style={{ fontSize: 11, fontWeight: 600, color: "#6b6860", textTransform: "uppercase" }}>Due date</label>
              <input type="date" value={formDueDate} onChange={(e) => setFormDueDate(e.target.value)} style={inputStyle} />
            </div>
          </div>
          <button
            onClick={handleSubmit}
            style={{
              padding: "10px 24px",
              fontSize: 13,
              fontWeight: 600,
              background: "#0a0a0a",
              color: "#fff",
              border: "none",
              borderRadius: 6,
              cursor: "pointer",
            }}
          >
            {editingId ? "Update" : "Add item"}
          </button>
        </div>
      )}

      {/* ── Items list — grouped by category ────────────────────────── */}
      {loading ? (
        <div style={{ textAlign: "center", padding: 40, color: "#6b6860" }}>Loading...</div>
      ) : items.length === 0 ? (
        <div style={{ textAlign: "center", padding: 40, color: "#6b6860" }}>No action items match filters</div>
      ) : (
        <div style={{ display: "flex", flexDirection: "column", gap: 24 }}>
          {CATEGORIES.map((cat) => {
            const catItems = items.filter((i) => getCategory(i.type) === cat.key);
            if (catItems.length === 0) return null;
            const colors = CATEGORY_COLORS[cat.key];
            return (
              <div key={cat.key}>
                {/* ── Category header ── */}
                <div
                  style={{
                    display: "flex",
                    alignItems: "center",
                    gap: 8,
                    marginBottom: 10,
                    paddingBottom: 8,
                    borderBottom: `2px solid ${colors.border}`,
                  }}
                >
                  <span style={{ fontSize: 16 }}>{cat.icon}</span>
                  <span style={{ fontSize: 14, fontWeight: 700, color: colors.header, textTransform: "uppercase", letterSpacing: "0.06em" }}>
                    {cat.label}
                  </span>
                  <span style={{ fontSize: 12, fontWeight: 600, color: colors.header, background: colors.bg, padding: "2px 8px", borderRadius: 10 }}>
                    {catItems.length}
                  </span>
                </div>
                {/* ── Category items ── */}
                <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                  {catItems.map((item) => (
                    <div
                      key={item.action_id}
                      style={{
                        background: "#fff",
                        border: "1px solid #e8e4de",
                        borderRadius: 8,
                        padding: "14px 18px",
                        borderLeft: `4px solid ${PRIORITY_COLORS[item.priority]?.text || "#6b6860"}`,
                      }}
                    >
                      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 6 }}>
                        <div style={{ display: "flex", gap: 6, alignItems: "center", flexWrap: "wrap" }}>
                          {badge(TYPE_COLORS[item.type] || TYPE_COLORS.other, TYPE_LABELS[item.type] || item.type)}
                          {badge(PRIORITY_COLORS[item.priority] || PRIORITY_COLORS.medium, item.priority)}
                          {badge(STATUS_COLORS[item.status] || STATUS_COLORS.open, item.status.replace("_", " "))}
                          {item.machine_name && (
                            <span style={{ fontSize: 11, color: "#6b6860", fontFamily: "monospace" }}>{item.machine_name}</span>
                          )}
                        </div>
                        <div style={{ display: "flex", gap: 4, flexShrink: 0 }}>
                          {item.status === "open" && (
                            <button onClick={() => updateStatus(item.action_id, "in_progress")} style={{ fontSize: 11, padding: "3px 8px", background: "#dbeafe", color: "#1e40af", border: "none", borderRadius: 4, cursor: "pointer", fontWeight: 600 }}>
                              Start
                            </button>
                          )}
                          {(item.status === "open" || item.status === "in_progress") && (
                            <button onClick={() => updateStatus(item.action_id, "done")} style={{ fontSize: 11, padding: "3px 8px", background: "#d1fae5", color: "#065f46", border: "none", borderRadius: 4, cursor: "pointer", fontWeight: 600 }}>
                              Done
                            </button>
                          )}
                          <button onClick={() => startEdit(item)} style={{ fontSize: 11, padding: "3px 8px", background: "#f5f3ee", color: "#6b6860", border: "none", borderRadius: 4, cursor: "pointer" }}>
                            Edit
                          </button>
                          <button onClick={() => updateStatus(item.action_id, "dismissed")} style={{ fontSize: 11, padding: "3px 8px", background: "#f3f4f6", color: "#9ca3af", border: "none", borderRadius: 4, cursor: "pointer" }}>
                            Dismiss
                          </button>
                        </div>
                      </div>
                      <div style={{ fontSize: 14, fontWeight: 600, color: "#0a0a0a", marginBottom: 4 }}>
                        {item.title}
                      </div>
                      {item.description && (
                        <div style={{ fontSize: 12, color: "#6b6860", lineHeight: 1.5, whiteSpace: "pre-wrap" }}>
                          {item.description}
                        </div>
                      )}
                      <div style={{ display: "flex", gap: 12, marginTop: 8, fontSize: 11, color: "#9ca3af" }}>
                        <span>Created {new Date(item.created_at).toLocaleDateString()}</span>
                        {item.assignee && <span>Assignee: {item.assignee}</span>}
                        {item.due_date && <span>Due: {item.due_date}</span>}
                        {item.source && <span>Source: {item.source}</span>}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
