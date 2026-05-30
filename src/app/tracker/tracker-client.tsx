"use client";

import { useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";

export type Category = "Boonz" | "AKY" | "Gebran" | "Personal";
export type Status = "todo" | "in_progress" | "done";
export type Urgency = "low" | "medium" | "high";

export type AgendaItem = {
  id: string;
  category: Category;
  title: string;
  status: Status;
  urgency: Urgency;
  due_date: string | null;
  notes: string | null;
  sort_order: number;
};

const CATEGORIES: Category[] = ["Boonz", "AKY", "Gebran", "Personal"];

const CAT_ACCENT: Record<Category, string> = {
  Boonz: "#b8530f",
  AKY: "#1f7a5c",
  Gebran: "#5b4bb0",
  Personal: "#9c2b6b",
};

const STATUS_LABEL: Record<Status, string> = {
  todo: "To do",
  in_progress: "In progress",
  done: "Done",
};

const STATUS_STYLE: Record<Status, { bg: string; fg: string }> = {
  todo: { bg: "#f1efe9", fg: "#6b6354" },
  in_progress: { bg: "#fef0d9", fg: "#a86412" },
  done: { bg: "#dceede", fg: "#1f7a4c" },
};

const URGENCY_STYLE: Record<Urgency, { bg: string; fg: string; dot: string }> =
  {
    low: { bg: "#eef1f4", fg: "#5a6573", dot: "#9aa7b5" },
    medium: { bg: "#fff4e0", fg: "#9a6512", dot: "#e0a534" },
    high: { bg: "#fde6e2", fg: "#b23a23", dot: "#d6492c" },
  };

const URGENCY_RANK: Record<Urgency, number> = { high: 0, medium: 1, low: 2 };

type Filter = "all" | "open" | "done";

export default function TrackerClient({
  initialItems,
}: {
  initialItems: AgendaItem[];
}) {
  const supabase = useMemo(() => createClient(), []);
  const [items, setItems] = useState<AgendaItem[]>(initialItems);
  const [filter, setFilter] = useState<Filter>("all");
  const [query, setQuery] = useState("");
  const [activeCat, setActiveCat] = useState<Category | "All">("All");
  const [busy, setBusy] = useState(false);

  // ── helpers ────────────────────────────────────────────────────────────────
  function patchLocal(id: string, patch: Partial<AgendaItem>) {
    setItems((prev) =>
      prev.map((it) => (it.id === id ? { ...it, ...patch } : it)),
    );
  }

  async function updateItem(id: string, patch: Partial<AgendaItem>) {
    const prev = items.find((i) => i.id === id);
    patchLocal(id, patch);
    const { error } = await supabase
      .from("agenda_items")
      .update(patch)
      .eq("id", id);
    if (error && prev) {
      patchLocal(id, prev); // rollback
      alert("Could not save: " + error.message);
    }
  }

  function cycleStatus(it: AgendaItem) {
    const next: Status =
      it.status === "todo"
        ? "in_progress"
        : it.status === "in_progress"
          ? "done"
          : "todo";
    updateItem(it.id, { status: next });
  }

  async function addItem(category: Category, title: string) {
    const clean = title.trim();
    if (!clean) return;
    setBusy(true);
    const maxOrder = Math.max(
      0,
      ...items.filter((i) => i.category === category).map((i) => i.sort_order),
    );
    const { data, error } = await supabase
      .from("agenda_items")
      .insert({ category, title: clean, sort_order: maxOrder + 10 })
      .select(
        "id, category, title, status, urgency, due_date, notes, sort_order",
      )
      .single();
    setBusy(false);
    if (error || !data) {
      alert("Could not add: " + (error?.message ?? "unknown"));
      return;
    }
    setItems((prev) => [...prev, data as AgendaItem]);
  }

  async function deleteItem(id: string) {
    if (!confirm("Delete this item?")) return;
    const prev = items;
    setItems((p) => p.filter((i) => i.id !== id));
    const { error } = await supabase.from("agenda_items").delete().eq("id", id);
    if (error) {
      setItems(prev);
      alert("Could not delete: " + error.message);
    }
  }

  // ── derived ─────────────────────────────────────────────────────────────────
  const visibleCats = activeCat === "All" ? CATEGORIES : [activeCat];

  const totals = useMemo(() => {
    const done = items.filter((i) => i.status === "done").length;
    return { done, total: items.length };
  }, [items]);

  function itemsFor(cat: Category) {
    const q = query.trim().toLowerCase();
    return items
      .filter((i) => i.category === cat)
      .filter((i) =>
        filter === "all"
          ? true
          : filter === "done"
            ? i.status === "done"
            : i.status !== "done",
      )
      .filter(
        (i) =>
          !q ||
          i.title.toLowerCase().includes(q) ||
          (i.notes ?? "").toLowerCase().includes(q),
      )
      .sort((a, b) => {
        if (a.status === "done" && b.status !== "done") return 1;
        if (b.status === "done" && a.status !== "done") return -1;
        const u = URGENCY_RANK[a.urgency] - URGENCY_RANK[b.urgency];
        if (u !== 0) return u;
        return a.sort_order - b.sort_order;
      });
  }

  return (
    <div style={{ minHeight: "100vh", background: "#faf9f7" }}>
      <style>{`@import url('https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap');`}</style>
      <div
        style={{
          fontFamily: "'Plus Jakarta Sans', sans-serif",
          maxWidth: 1040,
          margin: "0 auto",
          padding: "32px 20px 80px",
          color: "#2b2620",
        }}
      >
        {/* Header */}
        <div style={{ marginBottom: 24 }}>
          <div
            style={{
              fontSize: 12,
              letterSpacing: 1.5,
              color: "#a8987f",
              fontWeight: 700,
            }}
          >
            PARTNER MEETING
          </div>
          <h1 style={{ fontSize: 30, fontWeight: 800, margin: "4px 0 6px" }}>
            Agenda Tracker
          </h1>
          <div style={{ fontSize: 14, color: "#7a7160" }}>
            {totals.done} of {totals.total} done · Boonz · AKY (Aky &amp;
            Gebran) · Personal
          </div>
        </div>

        {/* Controls */}
        <div
          style={{
            display: "flex",
            flexWrap: "wrap",
            gap: 8,
            alignItems: "center",
            marginBottom: 20,
          }}
        >
          <CatPill
            label="All"
            active={activeCat === "All"}
            onClick={() => setActiveCat("All")}
          />
          {CATEGORIES.map((c) => (
            <CatPill
              key={c}
              label={c}
              color={CAT_ACCENT[c]}
              active={activeCat === c}
              onClick={() => setActiveCat(c)}
            />
          ))}
          <div style={{ flex: 1 }} />
          <div
            style={{
              display: "flex",
              gap: 4,
              background: "#f1efe9",
              borderRadius: 8,
              padding: 3,
            }}
          >
            {(["all", "open", "done"] as Filter[]).map((f) => (
              <button
                key={f}
                onClick={() => setFilter(f)}
                style={{
                  border: "none",
                  cursor: "pointer",
                  fontSize: 13,
                  fontWeight: 600,
                  padding: "5px 12px",
                  borderRadius: 6,
                  background: filter === f ? "#fff" : "transparent",
                  color: filter === f ? "#2b2620" : "#8a8270",
                  boxShadow:
                    filter === f ? "0 1px 2px rgba(0,0,0,.06)" : "none",
                }}
              >
                {f === "all" ? "All" : f === "open" ? "Open" : "Done"}
              </button>
            ))}
          </div>
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search…"
            style={{
              border: "1px solid #e6e1d7",
              borderRadius: 8,
              padding: "7px 12px",
              fontSize: 13,
              minWidth: 160,
              outline: "none",
              background: "#fff",
            }}
          />
        </div>

        {/* Sections */}
        {visibleCats.map((cat) => {
          const list = itemsFor(cat);
          const all = items.filter((i) => i.category === cat);
          const done = all.filter((i) => i.status === "done").length;
          return (
            <section key={cat} style={{ marginBottom: 30 }}>
              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 10,
                  marginBottom: 10,
                }}
              >
                <span
                  style={{
                    width: 10,
                    height: 10,
                    borderRadius: 3,
                    background: CAT_ACCENT[cat],
                  }}
                />
                <h2 style={{ fontSize: 18, fontWeight: 800, margin: 0 }}>
                  {cat}
                </h2>
                <span
                  style={{ fontSize: 13, color: "#9a917f", fontWeight: 600 }}
                >
                  {done}/{all.length}
                </span>
                <div style={{ flex: 1 }} />
              </div>

              <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                {list.map((it) => (
                  <Row
                    key={it.id}
                    item={it}
                    onCycle={() => cycleStatus(it)}
                    onUpdate={(p) => updateItem(it.id, p)}
                    onDelete={() => deleteItem(it.id)}
                  />
                ))}
                {list.length === 0 && (
                  <div
                    style={{
                      fontSize: 13,
                      color: "#b3a98f",
                      padding: "6px 2px",
                    }}
                  >
                    Nothing here.
                  </div>
                )}
                <AddRow
                  accent={CAT_ACCENT[cat]}
                  busy={busy}
                  onAdd={(t) => addItem(cat, t)}
                />
              </div>
            </section>
          );
        })}
      </div>
    </div>
  );
}

// ── Category pill ────────────────────────────────────────────────────────────────
function CatPill({
  label,
  color = "#6b6354",
  active,
  onClick,
}: {
  label: string;
  color?: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      style={{
        border: active ? `1.5px solid ${color}` : "1.5px solid #e6e1d7",
        borderRadius: 999,
        padding: "6px 14px",
        fontSize: 13,
        fontWeight: 700,
        cursor: "pointer",
        background: active ? color : "#fff",
        color: active ? "#fff" : "#6b6354",
        fontFamily: "inherit",
      }}
    >
      {label}
    </button>
  );
}

// ── Row ────────────────────────────────────────────────────────────────────────
function Row({
  item,
  onCycle,
  onUpdate,
  onDelete,
}: {
  item: AgendaItem;
  onCycle: () => void;
  onUpdate: (patch: Partial<AgendaItem>) => void;
  onDelete: () => void;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(item.title);
  const [showNotes, setShowNotes] = useState(false);
  const done = item.status === "done";
  const u = URGENCY_STYLE[item.urgency];
  const s = STATUS_STYLE[item.status];

  function saveTitle() {
    const v = draft.trim();
    setEditing(false);
    if (v && v !== item.title) onUpdate({ title: v });
    else setDraft(item.title);
  }

  return (
    <div
      style={{
        background: "#fff",
        border: "1px solid #ece7dc",
        borderRadius: 10,
        padding: "10px 12px",
        boxShadow: "0 1px 2px rgba(40,30,10,.03)",
      }}
    >
      <div style={{ display: "flex", alignItems: "flex-start", gap: 10 }}>
        {/* status checkbox */}
        <button
          onClick={onCycle}
          title={STATUS_LABEL[item.status] + " (click to advance)"}
          style={{
            marginTop: 1,
            width: 20,
            height: 20,
            borderRadius: 6,
            cursor: "pointer",
            flexShrink: 0,
            border: done ? "none" : "2px solid #d6cfbe",
            background: done
              ? "#2f9e5e"
              : item.status === "in_progress"
                ? "#f0b24a"
                : "#fff",
            color: "#fff",
            fontSize: 12,
            lineHeight: "16px",
          }}
        >
          {done ? "✓" : item.status === "in_progress" ? "•" : ""}
        </button>

        {/* title + meta */}
        <div style={{ flex: 1, minWidth: 0 }}>
          {editing ? (
            <input
              autoFocus
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onBlur={saveTitle}
              onKeyDown={(e) => {
                if (e.key === "Enter") saveTitle();
                if (e.key === "Escape") {
                  setDraft(item.title);
                  setEditing(false);
                }
              }}
              style={{
                width: "100%",
                border: "1px solid #e0d9cc",
                borderRadius: 6,
                padding: "4px 8px",
                fontSize: 14,
                fontFamily: "inherit",
                outline: "none",
              }}
            />
          ) : (
            <div
              onDoubleClick={() => setEditing(true)}
              style={{
                fontSize: 14,
                fontWeight: 600,
                lineHeight: 1.4,
                color: done ? "#a39a88" : "#2b2620",
                textDecoration: done ? "line-through" : "none",
                cursor: "text",
              }}
            >
              {item.title}
            </div>
          )}

          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: 6,
              marginTop: 7,
              flexWrap: "wrap",
            }}
          >
            {/* status select */}
            <select
              value={item.status}
              onChange={(e) => onUpdate({ status: e.target.value as Status })}
              style={pillSelect(s.bg, s.fg)}
            >
              <option value="todo">To do</option>
              <option value="in_progress">In progress</option>
              <option value="done">Done</option>
            </select>

            {/* urgency select */}
            <select
              value={item.urgency}
              onChange={(e) => onUpdate({ urgency: e.target.value as Urgency })}
              style={pillSelect(u.bg, u.fg)}
            >
              <option value="high">High</option>
              <option value="medium">Medium</option>
              <option value="low">Low</option>
            </select>

            {/* due date */}
            <input
              type="date"
              value={item.due_date ?? ""}
              onChange={(e) => onUpdate({ due_date: e.target.value || null })}
              style={{
                border: "1px solid #e6e1d7",
                borderRadius: 999,
                padding: "3px 9px",
                fontSize: 12,
                color: item.due_date ? "#5a5346" : "#b3a98f",
                fontFamily: "inherit",
                background: "#fff",
              }}
            />

            <button onClick={() => setShowNotes((v) => !v)} style={textBtn}>
              {item.notes ? "📝 Notes" : "+ Note"}
            </button>
            <button onClick={() => setEditing(true)} style={textBtn}>
              Edit
            </button>
            <button onClick={onDelete} style={{ ...textBtn, color: "#c0492f" }}>
              Delete
            </button>
          </div>

          {showNotes && (
            <textarea
              defaultValue={item.notes ?? ""}
              placeholder="Discussion notes, decisions, owners…"
              onBlur={(e) => {
                const v = e.target.value.trim();
                if (v !== (item.notes ?? "")) onUpdate({ notes: v || null });
              }}
              rows={2}
              style={{
                width: "100%",
                marginTop: 8,
                border: "1px solid #e6e1d7",
                borderRadius: 8,
                padding: "7px 9px",
                fontSize: 13,
                fontFamily: "inherit",
                resize: "vertical",
                outline: "none",
                background: "#fcfbf8",
              }}
            />
          )}
        </div>
      </div>
    </div>
  );
}

// ── Add row ─────────────────────────────────────────────────────────────────────
function AddRow({
  accent,
  busy,
  onAdd,
}: {
  accent: string;
  busy: boolean;
  onAdd: (title: string) => void;
}) {
  const [val, setVal] = useState("");
  function submit() {
    if (!val.trim()) return;
    onAdd(val);
    setVal("");
  }
  return (
    <div style={{ display: "flex", gap: 8, marginTop: 2 }}>
      <input
        value={val}
        onChange={(e) => setVal(e.target.value)}
        onKeyDown={(e) => e.key === "Enter" && submit()}
        placeholder="Add an item…"
        style={{
          flex: 1,
          border: "1px dashed #d8d1c2",
          borderRadius: 9,
          padding: "9px 12px",
          fontSize: 14,
          fontFamily: "inherit",
          outline: "none",
          background: "transparent",
        }}
      />
      <button
        onClick={submit}
        disabled={busy || !val.trim()}
        style={{
          border: "none",
          borderRadius: 9,
          padding: "0 16px",
          fontSize: 14,
          fontWeight: 700,
          cursor: busy || !val.trim() ? "default" : "pointer",
          color: "#fff",
          background: val.trim() ? accent : "#d8d1c2",
          fontFamily: "inherit",
        }}
      >
        Add
      </button>
    </div>
  );
}

// ── shared styles ────────────────────────────────────────────────────────────────
function pillSelect(bg: string, fg: string): React.CSSProperties {
  return {
    appearance: "none",
    WebkitAppearance: "none",
    border: "none",
    borderRadius: 999,
    padding: "3px 10px",
    fontSize: 12,
    fontWeight: 700,
    background: bg,
    color: fg,
    cursor: "pointer",
    fontFamily: "inherit",
  };
}

const textBtn: React.CSSProperties = {
  border: "none",
  background: "transparent",
  color: "#8a8270",
  fontSize: 12,
  fontWeight: 600,
  cursor: "pointer",
  padding: "2px 4px",
  fontFamily: "inherit",
};
