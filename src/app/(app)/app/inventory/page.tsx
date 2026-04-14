"use client";

import { useEffect, useState, useMemo, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";

// ── Types ──────────────────────────────────────────────────────────────────────

interface WHRowRaw {
  wh_inventory_id: string;
  boonz_product_id: string;
  batch_id: string | null;
  wh_location: string | null;
  warehouse_stock: number;
  expiration_date: string | null;
  status: string;
  boonz_products: {
    boonz_product_name: string;
    physical_type: string | null;
  };
}

interface WHRow {
  wh_inventory_id: string;
  boonz_product_id: string;
  boonz_product_name: string;
  physical_type: string | null;
  batch_id: string | null;
  wh_location: string | null;
  warehouse_stock: number;
  expiration_date: string | null;
  status: string;
}

type StatusFilter = "All" | "Active" | "Inactive";
type ExpiryFilter = "all" | "expired" | "3d" | "7d" | "30d";
type SortOption = "expiry" | "name" | "stockHigh" | "stockLow";

// ── Helpers ────────────────────────────────────────────────────────────────────

function expiryLabel(dateStr: string | null): string {
  if (!dateStr) return "—";
  const d = new Date(dateStr + "T00:00:00");
  return d.toLocaleDateString("en-AE", {
    day: "numeric",
    month: "short",
    year: "2-digit",
  });
}

function expiryStyle(dateStr: string | null): React.CSSProperties {
  if (!dateStr) return { color: "#6b6860" };
  const days = Math.floor(
    (new Date(dateStr + "T00:00:00").getTime() - Date.now()) / 86400000,
  );
  if (days < 0) return { color: "#dc2626", fontWeight: 700 };
  if (days <= 7) return { color: "#d97706", fontWeight: 600 };
  if (days <= 30) return { color: "#ca8a04" };
  return { color: "#6b6860" };
}

function daysLeftLabel(dateStr: string | null): {
  text: string;
  color: string;
} {
  if (!dateStr) return { text: "—", color: "#6b6860" };
  const days = Math.floor(
    (new Date(dateStr + "T00:00:00").getTime() - Date.now()) / 86400000,
  );
  if (days < 0) return { text: `${Math.abs(days)}d overdue`, color: "#dc2626" };
  if (days === 0) return { text: "Today", color: "#dc2626" };
  if (days <= 7) return { text: `${days}d left`, color: "#d97706" };
  if (days <= 30) return { text: `${days}d left`, color: "#ca8a04" };
  return { text: `${days}d left`, color: "#6b6860" };
}

const Field = ({ label, value }: { label: string; value: React.ReactNode }) => (
  <div style={{ marginBottom: 16 }}>
    <div
      style={{
        fontSize: 10,
        fontWeight: 700,
        letterSpacing: "0.1em",
        textTransform: "uppercase",
        color: "#6b6860",
        marginBottom: 4,
      }}
    >
      {label}
    </div>
    <div style={{ fontSize: 14, color: "#0a0a0a", fontWeight: 500 }}>
      {value ?? "—"}
    </div>
  </div>
);

// ── Page ───────────────────────────────────────────────────────────────────────

export default function InventoryPage() {
  const [rows, setRows] = useState<WHRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("Active");
  const [categoryFilter, setCategoryFilter] = useState("All");
  const [fetchKey, setFetchKey] = useState(0);

  // Drawer state
  const [selectedBatch, setSelectedBatch] = useState<WHRow | null>(null);
  const [editMode, setEditMode] = useState(false);
  const [editStatus, setEditStatus] = useState<string>("");
  const [editExpiry, setEditExpiry] = useState<string>("");
  const [editStock, setEditStock] = useState<number>(0);

  // Extended filters
  const [expiryFilter, setExpiryFilter] = useState<ExpiryFilter>("all");
  const [hideEmpty, setHideEmpty] = useState(false);
  const [sortBy, setSortBy] = useState<SortOption>("expiry");

  // ESC key handler
  useEffect(() => {
    const h = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        setSelectedBatch(null);
        setEditMode(false);
      }
    };
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, []);

  // Fetch inventory
  const fetchInventory = useCallback(async () => {
    setLoading(true);
    const supabase = createClient();
    const { data, error } = await supabase
      .from("warehouse_inventory")
      .select(
        "wh_inventory_id, boonz_product_id, batch_id, wh_location, warehouse_stock, expiration_date, status, boonz_products!inner(boonz_product_name, physical_type)",
      )
      .order("expiration_date", { ascending: true, nullsFirst: false })
      .limit(10000);

    if (error) console.error("warehouse_inventory fetch error:", error);

    const mapped: WHRow[] = ((data ?? []) as unknown as WHRowRaw[]).map(
      (r) => ({
        wh_inventory_id: r.wh_inventory_id,
        boonz_product_id: r.boonz_product_id,
        boonz_product_name: r.boonz_products.boonz_product_name,
        physical_type: r.boonz_products.physical_type,
        batch_id: r.batch_id,
        wh_location: r.wh_location,
        warehouse_stock: r.warehouse_stock,
        expiration_date: r.expiration_date,
        status: r.status,
      }),
    );
    setRows(mapped);
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchInventory();
  }, [fetchInventory, fetchKey]);

  const categories = useMemo(() => {
    const set = new Set<string>();
    for (const r of rows) if (r.physical_type) set.add(r.physical_type);
    return ["All", ...Array.from(set).sort()];
  }, [rows]);

  const filtered = useMemo(() => {
    return rows.filter((r) => {
      if (
        search &&
        !r.boonz_product_name.toLowerCase().includes(search.toLowerCase())
      )
        return false;
      if (statusFilter !== "All" && r.status !== statusFilter) return false;
      if (categoryFilter !== "All" && r.physical_type !== categoryFilter)
        return false;
      if (hideEmpty && r.warehouse_stock === 0) return false;
      if (expiryFilter !== "all") {
        const daysLeft = r.expiration_date
          ? Math.floor(
              (new Date(r.expiration_date + "T00:00:00").getTime() -
                Date.now()) /
                86400000,
            )
          : null;
        if (expiryFilter === "expired" && (daysLeft === null || daysLeft >= 0))
          return false;
        if (
          expiryFilter === "3d" &&
          (daysLeft === null || daysLeft < 0 || daysLeft > 3)
        )
          return false;
        if (
          expiryFilter === "7d" &&
          (daysLeft === null || daysLeft < 0 || daysLeft > 7)
        )
          return false;
        if (
          expiryFilter === "30d" &&
          (daysLeft === null || daysLeft < 0 || daysLeft > 30)
        )
          return false;
      }
      return true;
    });
  }, [rows, search, statusFilter, categoryFilter, hideEmpty, expiryFilter]);

  const sorted = useMemo(() => {
    const arr = [...filtered];
    if (sortBy === "name")
      arr.sort((a, b) =>
        a.boonz_product_name.localeCompare(b.boonz_product_name),
      );
    else if (sortBy === "stockHigh")
      arr.sort((a, b) => b.warehouse_stock - a.warehouse_stock);
    else if (sortBy === "stockLow")
      arr.sort((a, b) => a.warehouse_stock - b.warehouse_stock);
    // 'expiry' is already the default sort from DB
    return arr;
  }, [filtered, sortBy]);

  const totalStock = useMemo(
    () => filtered.reduce((sum, r) => sum + (r.warehouse_stock ?? 0), 0),
    [filtered],
  );

  const expiredCount = useMemo(
    () =>
      filtered.filter(
        (r) =>
          r.expiration_date &&
          new Date(r.expiration_date + "T00:00:00") < new Date(),
      ).length,
    [filtered],
  );

  const handleSave = async () => {
    if (!selectedBatch) return;
    const supabase = createClient();
    const { error } = await supabase
      .from("warehouse_inventory")
      .update({
        status: editStatus,
        expiration_date: editExpiry || null,
        warehouse_stock: editStock,
      })
      .eq("wh_inventory_id", selectedBatch.wh_inventory_id);

    if (!error) {
      setSelectedBatch(null);
      setEditMode(false);
      setFetchKey((k) => k + 1);
    }
  };

  const expiryOptions: { key: ExpiryFilter; label: string }[] = [
    { key: "all", label: "All Expiry" },
    { key: "expired", label: "Expired" },
    { key: "3d", label: "\u22643 days" },
    { key: "7d", label: "\u22647 days" },
    { key: "30d", label: "\u226430 days" },
  ];

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
            Warehouse Inventory
          </h1>
          <p style={{ color: "#6b6860", fontSize: 14, marginTop: 4 }}>
            {loading
              ? "Loading…"
              : `${filtered.length} batches \u00b7 ${totalStock.toLocaleString()} units${expiredCount > 0 ? ` \u00b7 ${expiredCount} expired` : ""}`}
          </p>
        </div>
      </div>

      {/* Filter bar — Row 1 */}
      <div
        className="flex items-center gap-3 flex-wrap"
        style={{ paddingBottom: 12 }}
      >
        <input
          type="text"
          placeholder="Search products…"
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
          value={categoryFilter}
          onChange={(e) => setCategoryFilter(e.target.value)}
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
          {categories.map((c) => (
            <option key={c} value={c}>
              {c === "All" ? "All types" : c}
            </option>
          ))}
        </select>
        {!loading && (
          <span style={{ marginLeft: "auto", fontSize: 13, color: "#6b6860" }}>
            {filtered.length} result{filtered.length !== 1 ? "s" : ""}
          </span>
        )}
      </div>

      {/* Filter bar — Row 2: Expiry range, Hide empty, Sort */}
      <div
        className="flex items-center gap-3 flex-wrap mb-6"
        style={{ borderBottom: "1px solid #e8e4de", paddingBottom: 16 }}
      >
        {expiryOptions.map((o) => (
          <button
            key={o.key}
            onClick={() => setExpiryFilter(o.key)}
            style={{
              border: "1px solid #e8e4de",
              borderRadius: 8,
              padding: "7px 14px",
              fontSize: 13,
              fontWeight: expiryFilter === o.key ? 600 : 400,
              background: expiryFilter === o.key ? "#0a0a0a" : "white",
              color: expiryFilter === o.key ? "white" : "#6b6860",
              cursor: "pointer",
            }}
          >
            {o.label}
          </button>
        ))}

        <button
          onClick={() => setHideEmpty((v) => !v)}
          style={{
            border: "1px solid #e8e4de",
            borderRadius: 8,
            padding: "7px 14px",
            fontSize: 13,
            fontWeight: hideEmpty ? 600 : 400,
            background: hideEmpty ? "#0a0a0a" : "white",
            color: hideEmpty ? "white" : "#6b6860",
            cursor: "pointer",
          }}
        >
          Hide empty
        </button>

        <select
          value={sortBy}
          onChange={(e) => setSortBy(e.target.value as SortOption)}
          style={{
            border: "1px solid #e8e4de",
            borderRadius: 8,
            padding: "7px 12px",
            fontSize: 13,
            color: "#0a0a0a",
            background: "white",
            cursor: "pointer",
            marginLeft: "auto",
          }}
        >
          <option value="expiry">Sort: Expiry date</option>
          <option value="name">Sort: Name A-Z</option>
          <option value="stockHigh">Sort: Stock high-low</option>
          <option value="stockLow">Sort: Stock low-high</option>
        </select>
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
                "Product",
                "Type",
                "Batch",
                "Location",
                "Stock",
                "Expiry",
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
              Array.from({ length: 10 }).map((_, i) => (
                <tr key={i} style={{ borderBottom: "1px solid #f5f2ee" }}>
                  {[200, 100, 80, 100, 60, 80, 60].map((w, j) => (
                    <td key={j} className="px-4 py-3">
                      <div
                        className="animate-pulse rounded"
                        style={{ height: 14, width: w, background: "#f0ede8" }}
                      />
                    </td>
                  ))}
                </tr>
              ))
            ) : sorted.length === 0 ? (
              <tr>
                <td
                  colSpan={7}
                  className="px-4 py-10 text-center"
                  style={{ color: "#6b6860" }}
                >
                  No inventory batches match your filters.
                </td>
              </tr>
            ) : (
              sorted.map((r) => (
                <tr
                  key={r.wh_inventory_id}
                  onClick={() => {
                    setSelectedBatch(r);
                    setEditMode(false);
                    setEditStatus(r.status);
                    setEditExpiry(r.expiration_date ?? "");
                    setEditStock(Number(r.warehouse_stock));
                  }}
                  style={{
                    cursor: "pointer",
                    borderBottom: "1px solid #f5f2ee",
                    background:
                      selectedBatch?.wh_inventory_id === r.wh_inventory_id
                        ? "#f0fdf4"
                        : undefined,
                  }}
                  onMouseEnter={(e) => {
                    if (selectedBatch?.wh_inventory_id !== r.wh_inventory_id) {
                      (
                        e.currentTarget as HTMLTableRowElement
                      ).style.background = "#faf9f7";
                    }
                  }}
                  onMouseLeave={(e) => {
                    if (selectedBatch?.wh_inventory_id !== r.wh_inventory_id) {
                      (
                        e.currentTarget as HTMLTableRowElement
                      ).style.background = "transparent";
                    }
                  }}
                >
                  <td
                    className="px-4 py-3"
                    style={{ fontWeight: 600, color: "#24544a" }}
                  >
                    {r.boonz_product_name}
                  </td>
                  <td className="px-4 py-3" style={{ color: "#6b6860" }}>
                    {r.physical_type ?? "\u2014"}
                  </td>
                  <td
                    className="px-4 py-3"
                    style={{
                      color: "#6b6860",
                      fontFamily: "monospace",
                      fontSize: 12,
                    }}
                  >
                    {r.batch_id ?? "\u2014"}
                  </td>
                  <td className="px-4 py-3" style={{ color: "#0a0a0a" }}>
                    {r.wh_location ?? "\u2014"}
                  </td>
                  <td
                    className="px-4 py-3"
                    style={{ fontWeight: 700, color: "#0a0a0a" }}
                  >
                    {(r.warehouse_stock ?? 0).toLocaleString()}
                  </td>
                  <td
                    className="px-4 py-3"
                    style={expiryStyle(r.expiration_date)}
                  >
                    {expiryLabel(r.expiration_date)}
                  </td>
                  <td className="px-4 py-3">
                    <span
                      style={{
                        display: "inline-block",
                        padding: "2px 10px",
                        borderRadius: 20,
                        fontSize: 11,
                        fontWeight: 600,
                        background:
                          r.status === "Active" ? "#f0fdf4" : "#f5f2ee",
                        color: r.status === "Active" ? "#065f46" : "#6b6860",
                      }}
                    >
                      {r.status}
                    </span>
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      {/* Drawer */}
      {selectedBatch && (
        <div
          style={{
            position: "fixed",
            inset: 0,
            zIndex: 50,
            display: "flex",
          }}
        >
          {/* Backdrop */}
          <div
            style={{ flex: 1, background: "rgba(0,0,0,0.3)" }}
            onClick={() => {
              setSelectedBatch(null);
              setEditMode(false);
            }}
          />
          {/* Panel */}
          <div
            style={{
              width: 520,
              background: "white",
              height: "100%",
              overflowY: "auto",
              display: "flex",
              flexDirection: "column",
              borderLeft: "1px solid #e8e4de",
              fontFamily: "'Plus Jakarta Sans', sans-serif",
            }}
          >
            {/* Drawer header */}
            <div
              style={{
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between",
                padding: "20px 24px",
                borderBottom: "1px solid #e8e4de",
              }}
            >
              <h2
                style={{
                  margin: 0,
                  fontSize: 18,
                  fontWeight: 700,
                  color: "#0a0a0a",
                  letterSpacing: "-0.01em",
                }}
              >
                {selectedBatch.boonz_product_name}
              </h2>
              <button
                onClick={() => {
                  setSelectedBatch(null);
                  setEditMode(false);
                }}
                style={{
                  background: "none",
                  border: "none",
                  fontSize: 22,
                  cursor: "pointer",
                  color: "#6b6860",
                  padding: "4px 8px",
                  lineHeight: 1,
                }}
                aria-label="Close"
              >
                ✕
              </button>
            </div>

            {/* Drawer body */}
            <div style={{ padding: "24px", flex: 1 }}>
              {!editMode ? (
                <>
                  <Field
                    label="Product Name"
                    value={selectedBatch.boonz_product_name}
                  />
                  <Field
                    label="Stock"
                    value={
                      <span style={{ fontWeight: 700 }}>
                        {(selectedBatch.warehouse_stock ?? 0).toLocaleString()}
                      </span>
                    }
                  />
                  <Field
                    label="Status"
                    value={
                      <span
                        style={{
                          display: "inline-block",
                          padding: "2px 10px",
                          borderRadius: 20,
                          fontSize: 12,
                          fontWeight: 600,
                          background:
                            selectedBatch.status === "Active"
                              ? "#f0fdf4"
                              : selectedBatch.status === "Expired"
                                ? "#fef2f2"
                                : "#f5f2ee",
                          color:
                            selectedBatch.status === "Active"
                              ? "#065f46"
                              : selectedBatch.status === "Expired"
                                ? "#dc2626"
                                : "#6b6860",
                        }}
                      >
                        {selectedBatch.status}
                      </span>
                    }
                  />
                  <Field
                    label="Expiry Date"
                    value={expiryLabel(selectedBatch.expiration_date)}
                  />
                  <Field
                    label="Days Left"
                    value={(() => {
                      const dl = daysLeftLabel(selectedBatch.expiration_date);
                      return (
                        <span style={{ color: dl.color, fontWeight: 600 }}>
                          {dl.text}
                        </span>
                      );
                    })()}
                  />
                  <Field
                    label="Location"
                    value={selectedBatch.wh_location ?? "\u2014"}
                  />
                  <Field
                    label="Batch ID"
                    value={
                      selectedBatch.batch_id ? (
                        <span style={{ fontFamily: "monospace", fontSize: 13 }}>
                          {selectedBatch.batch_id}
                        </span>
                      ) : (
                        "\u2014"
                      )
                    }
                  />
                  <Field
                    label="Physical Type"
                    value={selectedBatch.physical_type ?? "\u2014"}
                  />
                </>
              ) : (
                <>
                  {/* Edit mode */}
                  <div style={{ marginBottom: 20 }}>
                    <label
                      style={{
                        display: "block",
                        fontSize: 10,
                        fontWeight: 700,
                        letterSpacing: "0.1em",
                        textTransform: "uppercase",
                        color: "#6b6860",
                        marginBottom: 6,
                      }}
                    >
                      Status
                    </label>
                    <select
                      value={editStatus}
                      onChange={(e) => setEditStatus(e.target.value)}
                      style={{
                        width: "100%",
                        border: "1px solid #e8e4de",
                        borderRadius: 8,
                        padding: "8px 12px",
                        fontSize: 14,
                        color: "#0a0a0a",
                        background: "white",
                        cursor: "pointer",
                      }}
                    >
                      <option value="Active">Active</option>
                      <option value="Inactive">Inactive</option>
                      <option value="Expired">Expired</option>
                    </select>
                  </div>

                  <div style={{ marginBottom: 20 }}>
                    <label
                      style={{
                        display: "block",
                        fontSize: 10,
                        fontWeight: 700,
                        letterSpacing: "0.1em",
                        textTransform: "uppercase",
                        color: "#6b6860",
                        marginBottom: 6,
                      }}
                    >
                      Expiry Date
                    </label>
                    <input
                      type="date"
                      value={editExpiry}
                      onChange={(e) => setEditExpiry(e.target.value)}
                      style={{
                        width: "100%",
                        border: "1px solid #e8e4de",
                        borderRadius: 8,
                        padding: "8px 12px",
                        fontSize: 14,
                        color: "#0a0a0a",
                        background: "white",
                      }}
                    />
                  </div>

                  <div style={{ marginBottom: 20 }}>
                    <label
                      style={{
                        display: "block",
                        fontSize: 10,
                        fontWeight: 700,
                        letterSpacing: "0.1em",
                        textTransform: "uppercase",
                        color: "#6b6860",
                        marginBottom: 6,
                      }}
                    >
                      Stock Quantity
                    </label>
                    <input
                      type="number"
                      min={0}
                      value={editStock}
                      onChange={(e) => setEditStock(Number(e.target.value))}
                      style={{
                        width: "100%",
                        border: "1px solid #e8e4de",
                        borderRadius: 8,
                        padding: "8px 12px",
                        fontSize: 14,
                        color: "#0a0a0a",
                        background: "white",
                      }}
                    />
                  </div>
                </>
              )}
            </div>

            {/* Drawer footer */}
            <div
              style={{
                padding: "16px 24px",
                borderTop: "1px solid #e8e4de",
                display: "flex",
                gap: 12,
              }}
            >
              {!editMode ? (
                <button
                  onClick={() => setEditMode(true)}
                  style={{
                    flex: 1,
                    padding: "10px 0",
                    borderRadius: 8,
                    border: "none",
                    background: "#24544a",
                    color: "white",
                    fontSize: 14,
                    fontWeight: 600,
                    cursor: "pointer",
                    fontFamily: "'Plus Jakarta Sans', sans-serif",
                  }}
                >
                  Edit Batch
                </button>
              ) : (
                <>
                  <button
                    onClick={() => setEditMode(false)}
                    style={{
                      flex: 1,
                      padding: "10px 0",
                      borderRadius: 8,
                      border: "1px solid #e8e4de",
                      background: "white",
                      color: "#6b6860",
                      fontSize: 14,
                      fontWeight: 600,
                      cursor: "pointer",
                      fontFamily: "'Plus Jakarta Sans', sans-serif",
                    }}
                  >
                    Cancel
                  </button>
                  <button
                    onClick={handleSave}
                    style={{
                      flex: 1,
                      padding: "10px 0",
                      borderRadius: 8,
                      border: "none",
                      background: "#24544a",
                      color: "white",
                      fontSize: 14,
                      fontWeight: 600,
                      cursor: "pointer",
                      fontFamily: "'Plus Jakarta Sans', sans-serif",
                    }}
                  >
                    Save Changes
                  </button>
                </>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
