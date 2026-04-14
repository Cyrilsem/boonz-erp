"use client";

import { useEffect, useState, useMemo } from "react";
import { createClient } from "@/lib/supabase/client";

// ── Types ──────────────────────────────────────────────────────────────────────

interface WHRow {
  wh_inventory_id: string;
  boonz_product_id: string;
  boonz_product_name: string;
  product_category: string | null;
  batch_id: string | null;
  wh_location: string | null;
  warehouse_stock: number;
  expiration_date: string | null;
  status: string;
}

type StatusFilter = "All" | "Active" | "Inactive";

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

// ── Page ───────────────────────────────────────────────────────────────────────

export default function InventoryPage() {
  const [rows, setRows] = useState<WHRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("Active");
  const [categoryFilter, setCategoryFilter] = useState("All");

  useEffect(() => {
    async function load() {
      const supabase = createClient();
      const { data } = await supabase
        .from("warehouse_inventory")
        .select(
          "wh_inventory_id, boonz_product_id, boonz_product_name, product_category, batch_id, wh_location, warehouse_stock, expiration_date, status",
        )
        .order("expiration_date", { ascending: true, nullsFirst: false })
        .limit(10000);
      setRows(data ?? []);
      setLoading(false);
    }
    load();
  }, []);

  const categories = useMemo(() => {
    const set = new Set<string>();
    for (const r of rows) if (r.product_category) set.add(r.product_category);
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
      if (categoryFilter !== "All" && r.product_category !== categoryFilter)
        return false;
      return true;
    });
  }, [rows, search, statusFilter, categoryFilter]);

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
              : `${filtered.length} batches · ${totalStock.toLocaleString()} units${expiredCount > 0 ? ` · ⚠ ${expiredCount} expired` : ""}`}
          </p>
        </div>
      </div>

      {/* Filter bar */}
      <div
        className="flex items-center gap-3 flex-wrap mb-6"
        style={{ borderBottom: "1px solid #e8e4de", paddingBottom: 16 }}
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
              {c === "All" ? "All categories" : c}
            </option>
          ))}
        </select>
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
                "Product",
                "Category",
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
            ) : filtered.length === 0 ? (
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
              filtered.map((r) => (
                <tr
                  key={r.wh_inventory_id}
                  style={{ borderBottom: "1px solid #f5f2ee" }}
                  onMouseEnter={(e) =>
                    ((e.currentTarget as HTMLTableRowElement).style.background =
                      "#faf9f7")
                  }
                  onMouseLeave={(e) =>
                    ((e.currentTarget as HTMLTableRowElement).style.background =
                      "transparent")
                  }
                >
                  <td
                    className="px-4 py-3"
                    style={{ fontWeight: 600, color: "#24544a" }}
                  >
                    {r.boonz_product_name}
                  </td>
                  <td className="px-4 py-3" style={{ color: "#6b6860" }}>
                    {r.product_category ?? "—"}
                  </td>
                  <td
                    className="px-4 py-3"
                    style={{
                      color: "#6b6860",
                      fontFamily: "monospace",
                      fontSize: 12,
                    }}
                  >
                    {r.batch_id ?? "—"}
                  </td>
                  <td className="px-4 py-3" style={{ color: "#0a0a0a" }}>
                    {r.wh_location ?? "—"}
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
    </div>
  );
}
