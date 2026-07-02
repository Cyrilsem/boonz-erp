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
  cross_cutting: boolean;
};

const CATEGORIES: Category[] = ["Boonz", "AKY", "Gebran", "Personal"];

const CAT_ACCENT: Record<Category, string> = {
  Boonz: "#b8530f",
  AKY: "#1f7a5c",
  Gebran: "#5b4bb0",
  Personal: "#9c2b6b",
};

// Soft tints used for the cross-cutting bridge gradient.
const CAT_TINT: Record<Category, string> = {
  Boonz: "#fbeada",
  AKY: "#e3f3ec",
  Gebran: "#ece8fb",
  Personal: "#fbe6f1",
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

// Solid status colour used for dots / borders in the Overview board.
const STATUS_DOT: Record<Status, string> = {
  todo: "#cfc7b4",
  in_progress: "#e0a534",
  done: "#2f9e5e",
};

type Filter = "all" | "open" | "done";

export default function TrackerClient({
  initialItems,
  allowedCategories = ["Boonz", "AKY", "Gebran", "Personal"],
  canEditMeta = true,
  canAdd = true,
}: {
  initialItems: AgendaItem[];
  allowedCategories?: Category[];
  canEditMeta?: boolean;
  canAdd?: boolean;
}) {
  const cats = allowedCategories;
  const supabase = useMemo(() => createClient(), []);
  const [items, setItems] = useState<AgendaItem[]>(initialItems);
  const [view, setView] = useState<"overview" | "detail">("overview");
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

  function setStatus(id: string, status: Status) {
    updateItem(id, { status });
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
        "id, category, title, status, urgency, due_date, notes, sort_order, cross_cutting",
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
  const visibleCats = activeCat === "All" ? cats : [activeCat];

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
            {totals.done} of {totals.total} done · {cats.join(" · ")}
          </div>
        </div>

        {/* Tabs */}
        <div
          style={{
            display: "flex",
            gap: 4,
            marginBottom: 20,
            borderBottom: "1px solid #ece7dc",
          }}
        >
          {(["overview", "detail"] as const).map((v) => (
            <button
              key={v}
              onClick={() => setView(v)}
              style={tabBtn(view === v)}
            >
              {v === "overview" ? "Overview" : "Detail"}
            </button>
          ))}
        </div>

        {view === "overview" ? (
          <OverviewView
            items={items}
            categories={cats}
            onCycle={cycleStatus}
            onSetStatus={setStatus}
          />
        ) : (
          <>
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
              {cats.length > 1 && (
                <CatPill
                  label="All"
                  active={activeCat === "All"}
                  onClick={() => setActiveCat("All")}
                />
              )}
              {cats.map((c) => (
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
                      style={{
                        fontSize: 13,
                        color: "#9a917f",
                        fontWeight: 600,
                      }}
                    >
                      {done}/{all.length}
                    </span>
                    <div style={{ flex: 1 }} />
                  </div>

                  <div
                    style={{ display: "flex", flexDirection: "column", gap: 8 }}
                  >
                    {list.map((it) => (
                      <Row
                        key={it.id}
                        item={it}
                        canEditMeta={canEditMeta}
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
                    {canAdd && (
                      <AddRow
                        accent={CAT_ACCENT[cat]}
                        busy={busy}
                        onAdd={(t) => addItem(cat, t)}
                      />
                    )}
                  </div>
                </section>
              );
            })}
          </>
        )}
      </div>
    </div>
  );
}

// ── Overview (executive board) ───────────────────────────────────────────────────
function combinedStatus(group: AgendaItem[]): Status {
  if (group.length && group.every((i) => i.status === "done")) return "done";
  if (group.some((i) => i.status !== "todo")) return "in_progress";
  return "todo";
}

type Bridge = {
  key: string;
  rows: AgendaItem[];
  title: string;
  minIdx: number;
  maxIdx: number;
};

function OverviewView({
  items,
  categories,
  onCycle,
  onSetStatus,
}: {
  items: AgendaItem[];
  categories: Category[];
  onCycle: (it: AgendaItem) => void;
  onSetStatus: (id: string, status: Status) => void;
}) {
  // Build one "bridge" per cross-cutting initiative. A bridge only forms when the
  // initiative touches 2+ of the *visible* categories — so it reads as a single
  // bar running across columns. If only one visible column is involved (e.g. a
  // partner who only sees Boonz), the row falls back to a normal chip.
  const grouped = new Map<string, AgendaItem[]>();
  for (const it of items.filter(
    (i) => i.cross_cutting && categories.includes(i.category),
  )) {
    const key = it.title
      .replace(/\s*\(with [^)]*\)\s*:?/i, " ")
      .replace(/\s+/g, " ")
      .trim();
    grouped.set(key, [...(grouped.get(key) ?? []), it]);
  }
  const bridges: Bridge[] = [];
  const bridgeRowIds = new Set<string>();
  for (const [key, rows] of grouped.entries()) {
    const idxs = rows
      .map((r) => categories.indexOf(r.category))
      .filter((i) => i >= 0);
    const distinct = new Set(idxs);
    if (distinct.size < 2) continue; // not a true cross-column bridge
    rows.forEach((r) => bridgeRowIds.add(r.id));
    bridges.push({
      key,
      rows,
      title: rows[0].title
        .replace(/\s*\(with [^)]*\)\s*:?/i, ": ")
        .replace(/:\s*:/, ":")
        .trim(),
      minIdx: Math.min(...idxs),
      maxIdx: Math.max(...idxs),
    });
  }

  // Columns covered by at least one bridge drop one row so the bridge sits above
  // them; uncovered columns rise to fill the full height.
  const covered = new Set<number>();
  for (const b of bridges)
    for (let i = b.minIdx; i <= b.maxIdx; i++) covered.add(i);
  const hasBridge = bridges.length > 0;
  const bridgeMin = hasBridge ? Math.min(...bridges.map((b) => b.minIdx)) : 0;
  const bridgeMax = hasBridge ? Math.max(...bridges.map((b) => b.maxIdx)) : 0;

  return (
    <div>
      {/* Legend */}
      <div
        style={{
          display: "flex",
          gap: 16,
          alignItems: "center",
          marginBottom: 16,
          flexWrap: "wrap",
        }}
      >
        {(["todo", "in_progress", "done"] as Status[]).map((s) => (
          <span
            key={s}
            style={{
              display: "flex",
              alignItems: "center",
              gap: 6,
              fontSize: 12,
              color: "#7a7160",
              fontWeight: 600,
            }}
          >
            <span
              style={{
                width: 11,
                height: 11,
                borderRadius: 3,
                background: STATUS_DOT[s],
              }}
            />
            {STATUS_LABEL[s]}
          </span>
        ))}
        <span
          style={{
            display: "flex",
            alignItems: "center",
            gap: 6,
            fontSize: 12,
            color: "#7a7160",
            fontWeight: 600,
          }}
        >
          <span style={{ fontSize: 14 }}>↔</span> Cross-program initiative
        </span>
        <span style={{ fontSize: 11.5, color: "#b3a98f" }}>
          tip: click a status dot to advance it
        </span>
      </div>

      <style>{`
        @media (max-width: 900px) {
          .ov-grid { grid-template-columns: repeat(2, minmax(0, 1fr)) !important; }
          .ov-grid > * { grid-column: auto !important; grid-row: auto !important; }
        }
        @media (max-width: 520px) {
          .ov-grid { grid-template-columns: 1fr !important; }
        }
      `}</style>

      {/* Board: one column per visible category, with cross-program bridges across the top */}
      <div
        className={categories.length > 1 ? "ov-grid" : undefined}
        style={{
          display: "grid",
          gridTemplateColumns: `repeat(${categories.length}, minmax(0, 1fr))`,
          gap: 14,
          alignItems: "start",
        }}
      >
        {/* Bridge lane — spans the columns its initiative touches, on row 1 */}
        {hasBridge && (
          <div
            style={{
              gridColumn: `${bridgeMin + 1} / ${bridgeMax + 2}`,
              gridRow: "1",
              display: "flex",
              flexDirection: "column",
              gap: 10,
              marginBottom: 4,
            }}
          >
            {bridges.map((b) => {
              const cs = combinedStatus(b.rows);
              const next: Status =
                cs === "todo"
                  ? "in_progress"
                  : cs === "in_progress"
                    ? "done"
                    : "todo";
              const left = categories[b.minIdx];
              const right = categories[b.maxIdx];
              return (
                <div
                  key={b.key}
                  style={{
                    display: "flex",
                    alignItems: "stretch",
                    borderRadius: 11,
                    overflow: "hidden",
                    border: "1px solid #e6dcc6",
                    boxShadow: "0 1px 3px rgba(40,30,10,.05)",
                  }}
                >
                  <Cap cat={left} side="left" />
                  <div
                    style={{
                      flex: 1,
                      display: "flex",
                      alignItems: "center",
                      gap: 10,
                      padding: "9px 14px",
                      background: `linear-gradient(90deg, ${CAT_TINT[left]}, ${CAT_TINT[right]})`,
                    }}
                  >
                    <span
                      style={{
                        fontSize: 13,
                        fontWeight: 700,
                        color: "#3a342c",
                        lineHeight: 1.35,
                        flex: 1,
                      }}
                    >
                      {b.title}
                    </span>
                    <span style={{ fontSize: 15, color: "#8a7e63" }}>↔</span>
                    <button
                      onClick={() =>
                        b.rows.forEach((r) => onSetStatus(r.id, next))
                      }
                      title="Click to advance both sides"
                      style={{
                        border: "none",
                        cursor: "pointer",
                        borderRadius: 999,
                        padding: "3px 11px",
                        fontSize: 11.5,
                        fontWeight: 700,
                        background: STATUS_STYLE[cs].bg,
                        color: STATUS_STYLE[cs].fg,
                        fontFamily: "inherit",
                        whiteSpace: "nowrap",
                      }}
                    >
                      {STATUS_LABEL[cs]}
                    </button>
                  </div>
                  <Cap cat={right} side="right" />
                </div>
              );
            })}
          </div>
        )}

        {/* Category columns */}
        {categories.map((cat, idx) => {
          const list = items
            .filter((i) => i.category === cat && !bridgeRowIds.has(i.id))
            .sort((a, b) => {
              if (a.status === "done" && b.status !== "done") return 1;
              if (b.status === "done" && a.status !== "done") return -1;
              return a.sort_order - b.sort_order;
            });
          const done = items.filter(
            (i) => i.category === cat && i.status === "done",
          ).length;
          const total = items.filter((i) => i.category === cat).length;
          const isCovered = covered.has(idx);
          return (
            <div
              key={cat}
              style={{
                gridColumn: `${idx + 1}`,
                gridRow: hasBridge ? (isCovered ? "2" : "1 / 3") : "1",
                background: "#fff",
                border: "1px solid #ece7dc",
                borderTop: `3px solid ${CAT_ACCENT[cat]}`,
                borderRadius: 12,
                padding: "12px 12px 14px",
              }}
            >
              <div
                style={{
                  display: "flex",
                  alignItems: "baseline",
                  gap: 7,
                  marginBottom: 10,
                }}
              >
                <span
                  style={{
                    fontSize: 15,
                    fontWeight: 800,
                    color: CAT_ACCENT[cat],
                  }}
                >
                  {cat}
                </span>
                <span
                  style={{ fontSize: 12, color: "#9a917f", fontWeight: 700 }}
                >
                  {done}/{total}
                </span>
              </div>
              <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
                {list.map((it) => (
                  <MiniChip key={it.id} item={it} onCycle={() => onCycle(it)} />
                ))}
                {list.length === 0 && (
                  <span style={{ fontSize: 12, color: "#b3a98f" }}>
                    No standalone items.
                  </span>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function Cap({ cat, side }: { cat: Category; side: "left" | "right" }) {
  return (
    <div
      style={{
        background: CAT_ACCENT[cat],
        color: "#fff",
        fontSize: 11,
        fontWeight: 800,
        letterSpacing: 0.3,
        display: "flex",
        alignItems: "center",
        padding: "0 12px",
        whiteSpace: "nowrap",
        ...(side === "left"
          ? { borderRight: "2px solid rgba(255,255,255,.35)" }
          : { borderLeft: "2px solid rgba(255,255,255,.35)" }),
      }}
    >
      {cat}
    </div>
  );
}

function MiniChip({
  item,
  onCycle,
}: {
  item: AgendaItem;
  onCycle: () => void;
}) {
  const done = item.status === "done";
  return (
    <div
      style={{
        display: "flex",
        alignItems: "flex-start",
        gap: 8,
        padding: "7px 8px",
        borderRadius: 8,
        background: done ? "#f6f4ef" : "#fcfbf8",
        border: "1px solid #efeae0",
        borderLeft: `3px solid ${STATUS_DOT[item.status]}`,
      }}
    >
      <button
        onClick={onCycle}
        title={STATUS_LABEL[item.status] + " — click to advance"}
        style={{
          marginTop: 2,
          width: 13,
          height: 13,
          borderRadius: "50%",
          flexShrink: 0,
          cursor: "pointer",
          border: "none",
          background: STATUS_DOT[item.status],
        }}
      />
      <span
        style={{
          fontSize: 12.5,
          lineHeight: 1.35,
          fontWeight: 500,
          color: done ? "#a39a88" : "#39342c",
          textDecoration: done ? "line-through" : "none",
        }}
      >
        {item.title}
      </span>
      {item.urgency === "high" && (
        <span
          title="High urgency"
          style={{
            marginLeft: "auto",
            color: "#d6492c",
            fontSize: 13,
            lineHeight: "16px",
          }}
        >
          !
        </span>
      )}
    </div>
  );
}

function tabBtn(active: boolean): React.CSSProperties {
  return {
    border: "none",
    background: "transparent",
    cursor: "pointer",
    fontSize: 15,
    fontWeight: 700,
    padding: "8px 10px",
    marginBottom: -1,
    color: active ? "#2b2620" : "#a8a08d",
    borderBottom: active ? "2.5px solid #2b2620" : "2.5px solid transparent",
    fontFamily: "inherit",
  };
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
  canEditMeta = true,
  onCycle,
  onUpdate,
  onDelete,
}: {
  item: AgendaItem;
  canEditMeta?: boolean;
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
              onDoubleClick={() => canEditMeta && setEditing(true)}
              style={{
                fontSize: 14,
                fontWeight: 600,
                lineHeight: 1.4,
                color: done ? "#a39a88" : "#2b2620",
                textDecoration: done ? "line-through" : "none",
                cursor: canEditMeta ? "text" : "default",
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

            {/* urgency */}
            {canEditMeta ? (
              <select
                value={item.urgency}
                onChange={(e) =>
                  onUpdate({ urgency: e.target.value as Urgency })
                }
                style={pillSelect(u.bg, u.fg)}
              >
                <option value="high">High</option>
                <option value="medium">Medium</option>
                <option value="low">Low</option>
              </select>
            ) : (
              <span style={{ ...pillSelect(u.bg, u.fg), cursor: "default" }}>
                {item.urgency === "high"
                  ? "High"
                  : item.urgency === "low"
                    ? "Low"
                    : "Medium"}
              </span>
            )}

            {/* due date */}
            {canEditMeta ? (
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
            ) : (
              item.due_date && (
                <span
                  style={{ fontSize: 12, color: "#5a5346", fontWeight: 600 }}
                >
                  due {item.due_date}
                </span>
              )
            )}

            <button onClick={() => setShowNotes((v) => !v)} style={textBtn}>
              {item.notes ? "📝 Notes" : "+ Note"}
            </button>
            {canEditMeta && (
              <>
                <button onClick={() => setEditing(true)} style={textBtn}>
                  Edit
                </button>
                <button
                  onClick={onDelete}
                  style={{ ...textBtn, color: "#c0492f" }}
                >
                  Delete
                </button>
              </>
            )}
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
