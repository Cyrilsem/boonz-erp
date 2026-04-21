"use client";

import { useEffect, useState, useMemo, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";

type Tab = "boonz" | "pod" | "mapping";
type SortOption = "name" | "category" | "brand";
type StorageFilter = "all" | "ambient" | "cold" | "frozen";

const SOURCING_CHANNELS = [
  "Union Coop",
  "Amazon",
  "Supplier CF",
  "Supplier FH",
  "Supplier MG",
  "Supplier TD",
  "Arab Sweet, Jaleel",
  "Arab Sweet, Union Coop, Jaleel",
  "Leb",
  "Other",
];

interface BoonzProduct {
  product_id: string;
  boonz_product_name: string;
  physical_type: string | null;
  product_brand: string | null;
  product_sub_brand: string | null;
  product_category: string | null;
  category_group: string | null;
  product_weight_g: number | null;
  actual_weight_g: number | null;
  description: string | null;
  attr_healthy: boolean | null;
  attr_drink: boolean | null;
  attr_salty: boolean | null;
  attr_sweet: boolean | null;
  attr_30days: boolean | null;
  min_cost: number | null;
  max_cost: number | null;
  avg_cost: number | null;
  sourcing_channel: string | null;
  storage_temp_requirement: string | null;
}

interface ProductDraft {
  product_brand: string;
  product_sub_brand: string;
  product_category: string;
  category_group: string;
  product_weight_g: string;
  actual_weight_g: string;
  description: string;
  attr_healthy: boolean;
  attr_drink: boolean;
  attr_salty: boolean;
  attr_sweet: boolean;
  attr_30days: boolean;
  min_cost: string;
  max_cost: string;
  avg_cost: string;
  sourcing_channel: string;
  storage_temp_requirement: string;
}

interface PodInventoryRow {
  boonz_product_id: string;
  machine_id: string;
  current_stock: number;
  status: string;
  expiration_date: string | null;
  batch_id: string | null;
}

function rowToDraft(r: BoonzProduct): ProductDraft {
  return {
    product_brand: r.product_brand ?? "",
    product_sub_brand: r.product_sub_brand ?? "",
    product_category: r.product_category ?? "",
    category_group: r.category_group ?? "",
    product_weight_g: r.product_weight_g?.toString() ?? "",
    actual_weight_g: r.actual_weight_g?.toString() ?? "",
    description: r.description ?? "",
    attr_healthy: !!r.attr_healthy,
    attr_drink: !!r.attr_drink,
    attr_salty: !!r.attr_salty,
    attr_sweet: !!r.attr_sweet,
    attr_30days: !!r.attr_30days,
    min_cost: r.min_cost?.toString() ?? "",
    max_cost: r.max_cost?.toString() ?? "",
    avg_cost: r.avg_cost?.toString() ?? "",
    sourcing_channel: r.sourcing_channel ?? "",
    storage_temp_requirement: r.storage_temp_requirement ?? "ambient",
  };
}

function getTypeBadge(physical_type: string | null): {
  bg: string;
  text: string;
  label: string;
} {
  const t = (physical_type ?? "").toLowerCase();
  if (t.startsWith("bottle"))
    return { bg: "#e6f1fb", text: "#185fa5", label: physical_type ?? "bottle" };
  if (t.startsWith("can"))
    return { bg: "#eaf3de", text: "#3b6d11", label: physical_type ?? "can" };
  if (t.startsWith("bar"))
    return { bg: "#faeeda", text: "#854f0b", label: physical_type ?? "bar" };
  if (t.startsWith("bag"))
    return { bg: "#eeedfe", text: "#534ab7", label: physical_type ?? "bag" };
  if (t.startsWith("box"))
    return { bg: "#f1efe8", text: "#5f5e5a", label: physical_type ?? "box" };
  if (t.startsWith("cup"))
    return { bg: "#fce8f8", text: "#8b1a8a", label: physical_type ?? "cup" };
  if (t.startsWith("cake"))
    return { bg: "#fef3e2", text: "#a35c00", label: physical_type ?? "cake" };
  return { bg: "#f1efe8", text: "#5f5e5a", label: physical_type ?? "—" };
}

function StorageBadge({ value }: { value: string | null }) {
  const v = (value ?? "ambient").toLowerCase();
  const map: Record<string, { bg: string; text: string; label: string }> = {
    cold: { bg: "#e6f1fb", text: "#185fa5", label: "❄ Cold" },
    frozen: { bg: "#eeedfe", text: "#534ab7", label: "🧊 Frozen" },
    ambient: { bg: "#eaf3de", text: "#3b6d11", label: "Ambient" },
  };
  const s = map[v] ?? map.ambient;
  return (
    <span
      style={{
        display: "inline-block",
        padding: "2px 8px",
        borderRadius: 6,
        fontSize: 11,
        fontWeight: 600,
        background: s.bg,
        color: s.text,
      }}
    >
      {s.label}
    </span>
  );
}

function SkeletonRows({ cols }: { cols: number }) {
  return (
    <>
      {Array.from({ length: 6 }).map((_, i) => (
        <tr key={i}>
          {Array.from({ length: cols }).map((_, j) => (
            <td key={j} style={{ padding: "14px 16px" }}>
              <div
                className="animate-pulse"
                style={{
                  height: 14,
                  borderRadius: 6,
                  background: "#e8e4de",
                  width: j === 0 ? "60%" : "40%",
                }}
              />
            </td>
          ))}
        </tr>
      ))}
    </>
  );
}

const font = "'Plus Jakarta Sans', sans-serif";

const inputStyle: React.CSSProperties = {
  width: "100%",
  border: "1px solid #e8e4de",
  borderRadius: 8,
  padding: "8px 12px",
  fontSize: 14,
  color: "#0a0a0a",
  background: "white",
  fontFamily: font,
  outline: "none",
};

const labelStyle: React.CSSProperties = {
  display: "block",
  fontSize: 10,
  fontWeight: 700,
  letterSpacing: "0.1em",
  textTransform: "uppercase",
  color: "#6b6860",
  marginBottom: 6,
};

const sectionHead: React.CSSProperties = {
  fontSize: 10,
  fontWeight: 700,
  letterSpacing: "0.12em",
  textTransform: "uppercase",
  color: "#9c9790",
  marginBottom: 12,
  marginTop: 24,
};

export default function ProductsPage() {
  const [activeTab, setActiveTab] = useState<Tab>("boonz");
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [sortBy, setSortBy] = useState<SortOption>("name");
  const [storageFilter, setStorageFilter] = useState<StorageFilter>("all");

  const [products, setProducts] = useState<BoonzProduct[]>([]);
  const [podInventory, setPodInventory] = useState<PodInventoryRow[]>([]);
  const [, setMachines] = useState<
    { machine_id: string; official_name: string | null }[]
  >([]);

  // Drawer / detail panel
  const [selectedProduct, setSelectedProduct] = useState<BoonzProduct | null>(null);
  const [editMode, setEditMode] = useState(false);
  const [draft, setDraft] = useState<ProductDraft | null>(null);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  // ESC to close
  useEffect(() => {
    const h = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        setSelectedProduct(null);
        setEditMode(false);
      }
    };
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, []);

  const fetchAll = useCallback(async () => {
    setLoading(true);
    const supabase = createClient();
    const [prodRes, podRes, machRes] = await Promise.all([
      supabase
        .from("boonz_products")
        .select(
          "product_id, boonz_product_name, physical_type, product_brand, product_sub_brand, product_category, category_group, product_weight_g, actual_weight_g, description, attr_healthy, attr_drink, attr_salty, attr_sweet, attr_30days, min_cost, max_cost, avg_cost, sourcing_channel, storage_temp_requirement",
        )
        .order("boonz_product_name")
        .limit(10000),
      supabase
        .from("pod_inventory")
        .select(
          "boonz_product_id, machine_id, current_stock, status, expiration_date, batch_id",
        )
        .eq("status", "Active")
        .limit(10000),
      supabase
        .from("machines")
        .select("machine_id, official_name")
        .limit(10000),
    ]);

    if (prodRes.data) setProducts(prodRes.data as BoonzProduct[]);
    if (podRes.data) setPodInventory(podRes.data);
    if (machRes.data) setMachines(machRes.data);
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchAll();
  }, [fetchAll]);

  // --- Derived data ---

  const filteredProducts = useMemo(() => {
    let list = [...products];
    if (search.trim()) {
      const q = search.toLowerCase();
      list = list.filter(
        (p) =>
          p.boonz_product_name?.toLowerCase().includes(q) ||
          p.product_brand?.toLowerCase().includes(q) ||
          p.product_category?.toLowerCase().includes(q),
      );
    }
    if (storageFilter !== "all") {
      list = list.filter(
        (p) =>
          (p.storage_temp_requirement ?? "ambient").toLowerCase() ===
          storageFilter,
      );
    }
    if (sortBy === "category") {
      list.sort((a, b) =>
        (a.product_category ?? "").localeCompare(b.product_category ?? ""),
      );
    } else if (sortBy === "brand") {
      list.sort((a, b) =>
        (a.product_brand ?? "").localeCompare(b.product_brand ?? ""),
      );
    }
    // name: already sorted from DB
    return list;
  }, [products, search, storageFilter, sortBy]);

  const podGrouped = useMemo(() => {
    const map = new Map<
      string,
      { machineIds: Set<string>; totalStock: number; statuses: Set<string> }
    >();
    for (const row of podInventory) {
      let entry = map.get(row.boonz_product_id);
      if (!entry) {
        entry = { machineIds: new Set(), totalStock: 0, statuses: new Set() };
        map.set(row.boonz_product_id, entry);
      }
      entry.machineIds.add(row.machine_id);
      entry.totalStock += row.current_stock ?? 0;
      entry.statuses.add(row.status);
    }
    return map;
  }, [podInventory]);

  const podDistinctMachines = useMemo(() => {
    const s = new Set<string>();
    for (const row of podInventory) s.add(row.machine_id);
    return s.size;
  }, [podInventory]);

  const productMap = useMemo(() => {
    const m = new Map<string, BoonzProduct>();
    for (const p of products) m.set(p.product_id, p);
    return m;
  }, [products]);

  const { mapped, unmapped } = useMemo(() => {
    const podProductIds = new Set(podInventory.map((r) => r.boonz_product_id));
    const m: BoonzProduct[] = [];
    const u: BoonzProduct[] = [];
    for (const p of products) {
      if (podProductIds.has(p.product_id)) m.push(p);
      else u.push(p);
    }
    return { mapped: m, unmapped: u };
  }, [products, podInventory]);

  // --- Save product edits ---
  const handleSave = async () => {
    if (!selectedProduct || !draft) return;
    setSaving(true);
    setSaveError(null);
    const supabase = createClient();
    const update = {
      product_brand: draft.product_brand || null,
      product_sub_brand: draft.product_sub_brand || null,
      product_category: draft.product_category || null,
      category_group: draft.category_group || null,
      product_weight_g: draft.product_weight_g
        ? parseFloat(draft.product_weight_g)
        : null,
      actual_weight_g: draft.actual_weight_g
        ? parseFloat(draft.actual_weight_g)
        : null,
      description: draft.description || null,
      attr_healthy: draft.attr_healthy,
      attr_drink: draft.attr_drink,
      attr_salty: draft.attr_salty,
      attr_sweet: draft.attr_sweet,
      attr_30days: draft.attr_30days,
      min_cost: draft.min_cost ? parseFloat(draft.min_cost) : null,
      max_cost: draft.max_cost ? parseFloat(draft.max_cost) : null,
      avg_cost: draft.avg_cost ? parseFloat(draft.avg_cost) : null,
      sourcing_channel: draft.sourcing_channel || null,
      storage_temp_requirement: draft.storage_temp_requirement,
    };
    const { error } = await supabase
      .from("boonz_products")
      .update(update)
      .eq("product_id", selectedProduct.product_id);
    if (error) {
      setSaveError(error.message);
      setSaving(false);
      return;
    }
    // Update local state
    setProducts((prev) =>
      prev.map((p) =>
        p.product_id === selectedProduct.product_id
          ? {
              ...p,
              ...update,
              product_weight_g: update.product_weight_g,
              actual_weight_g: update.actual_weight_g,
              min_cost: update.min_cost,
              max_cost: update.max_cost,
              avg_cost: update.avg_cost,
            }
          : p,
      ),
    );
    setSelectedProduct((prev) =>
      prev ? { ...prev, ...update } : prev,
    );
    setSaving(false);
    setEditMode(false);
  };

  // --- Styles ---
  const tabStyle = (tab: Tab): React.CSSProperties => ({
    padding: "12px 16px",
    fontSize: 12,
    fontWeight: activeTab === tab ? 700 : 500,
    letterSpacing: "0.06em",
    textTransform: "uppercase",
    color: activeTab === tab ? "#0a0a0a" : "#6b6860",
    borderBottom: "none",
    borderBottomStyle: "solid",
    borderBottomWidth: 3,
    borderBottomColor: activeTab === tab ? "#0a0a0a" : "transparent",
    background: "none",
    border: "none",
    cursor: "pointer",
    fontFamily: font,
    transition: "color 0.15s, border-color 0.15s",
    paddingBottom: 13,
  });

  const tableWrap: React.CSSProperties = {
    background: "white",
    border: "1px solid #e8e4de",
    borderRadius: 12,
    overflow: "hidden",
  };

  const thStyle: React.CSSProperties = {
    padding: "12px 16px",
    fontSize: 11,
    fontWeight: 500,
    letterSpacing: "0.06em",
    textTransform: "uppercase",
    color: "#6b6860",
    textAlign: "left",
    borderBottom: "1px solid #e8e4de",
    fontFamily: font,
  };

  const tdStyle: React.CSSProperties = {
    padding: "14px 16px",
    fontSize: 13,
    color: "#0a0a0a",
    borderBottom: "1px solid #f5f2ee",
    fontFamily: font,
  };

  const nameCell: React.CSSProperties = {
    ...tdStyle,
    fontWeight: 600,
    color: "#24544a",
    cursor: "pointer",
  };

  const pillStyle = (bg: string, text: string): React.CSSProperties => ({
    display: "inline-block",
    padding: "3px 10px",
    borderRadius: 999,
    fontSize: 11,
    fontWeight: 600,
    background: bg,
    color: text,
    fontFamily: font,
  });

  const subtitle = `${products.length} products in catalogue \u00B7 ${podGrouped.size} active in pods`;

  const attrToggle = (
    active: boolean,
    label: string,
    onClick: () => void,
  ) => (
    <button
      key={label}
      type="button"
      onClick={onClick}
      style={{
        padding: "5px 12px",
        borderRadius: 999,
        fontSize: 12,
        fontWeight: 600,
        border: active ? "none" : "1px solid #e8e4de",
        background: active ? "#24544a" : "white",
        color: active ? "white" : "#6b6860",
        cursor: "pointer",
        fontFamily: font,
      }}
    >
      {label}
    </button>
  );

  return (
    <div
      style={{ padding: "32px 32px 64px", maxWidth: 1200, fontFamily: font }}
    >
      {/* Header */}
      <div style={{ marginBottom: 24 }}>
        <h1
          style={{
            fontFamily: font,
            fontWeight: 800,
            fontSize: 28,
            letterSpacing: "-0.02em",
            color: "#0a0a0a",
            margin: 0,
          }}
        >
          Products
        </h1>
        <p style={{ color: "#6b6860", fontSize: 14, marginTop: 4 }}>
          {loading ? "Loading..." : subtitle}
        </p>
      </div>

      {/* Tab bar */}
      <div
        style={{
          display: "flex",
          gap: 0,
          borderBottom: "1px solid #e8e4de",
          marginBottom: 24,
        }}
      >
        {(
          [
            { key: "boonz" as Tab, label: "Boonz Product DB" },
            { key: "pod" as Tab, label: "Pod Product DB" },
            { key: "mapping" as Tab, label: "Product Mapping" },
          ] as { key: Tab; label: string }[]
        ).map((t) => (
          <button
            key={t.key}
            type="button"
            style={{
              ...tabStyle(t.key),
              borderBottom:
                activeTab === t.key
                  ? "3px solid #0a0a0a"
                  : "3px solid transparent",
            }}
            onClick={() => {
              setActiveTab(t.key);
              setSearch("");
              setSelectedProduct(null);
              setEditMode(false);
            }}
          >
            {t.label}
          </button>
        ))}
      </div>

      {/* ========== TAB 1: Boonz Product DB ========== */}
      {activeTab === "boonz" && (
        <>
          {/* Filters row */}
          <div
            style={{
              marginBottom: 16,
              display: "flex",
              alignItems: "center",
              gap: 10,
              flexWrap: "wrap",
            }}
          >
            <input
              type="text"
              placeholder="Search by name, brand, or category…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              style={{
                padding: "9px 14px",
                fontSize: 13,
                border: "1px solid #e8e4de",
                borderRadius: 8,
                outline: "none",
                width: 300,
                fontFamily: font,
                background: "white",
              }}
            />

            {/* Storage filter */}
            {(
              [
                { key: "all" as StorageFilter, label: "All Storage" },
                { key: "ambient" as StorageFilter, label: "Ambient" },
                { key: "cold" as StorageFilter, label: "❄ Cold" },
                { key: "frozen" as StorageFilter, label: "🧊 Frozen" },
              ] as { key: StorageFilter; label: string }[]
            ).map((s) => (
              <button
                key={s.key}
                type="button"
                onClick={() => setStorageFilter(s.key)}
                style={{
                  padding: "7px 14px",
                  borderRadius: 8,
                  fontSize: 12,
                  fontWeight: storageFilter === s.key ? 700 : 500,
                  border: "1px solid #e8e4de",
                  background: storageFilter === s.key ? "#0a0a0a" : "white",
                  color: storageFilter === s.key ? "white" : "#6b6860",
                  cursor: "pointer",
                  fontFamily: font,
                }}
              >
                {s.label}
              </button>
            ))}

            {/* Sort */}
            <select
              value={sortBy}
              onChange={(e) => setSortBy(e.target.value as SortOption)}
              style={{
                border: "1px solid #e8e4de",
                borderRadius: 8,
                padding: "8px 12px",
                fontSize: 12,
                color: "#0a0a0a",
                background: "white",
                cursor: "pointer",
                marginLeft: "auto",
                fontFamily: font,
              }}
            >
              <option value="name">Sort: Name A–Z</option>
              <option value="category">Sort: Category</option>
              <option value="brand">Sort: Brand</option>
            </select>

            <span style={{ fontSize: 13, color: "#6b6860", fontFamily: font }}>
              {loading ? "…" : `${filteredProducts.length} products`}
            </span>
          </div>

          <div style={tableWrap}>
            <table style={{ width: "100%", borderCollapse: "collapse" }}>
              <thead>
                <tr>
                  <th style={thStyle}>Product Name</th>
                  <th style={thStyle}>Brand</th>
                  <th style={thStyle}>Category</th>
                  <th style={thStyle}>Storage</th>
                  <th style={thStyle}>Type</th>
                  <th style={thStyle}>Avg Cost</th>
                  <th style={thStyle}>ID</th>
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  <SkeletonRows cols={7} />
                ) : filteredProducts.length === 0 ? (
                  <tr>
                    <td
                      colSpan={7}
                      style={{
                        ...tdStyle,
                        textAlign: "center",
                        color: "#6b6860",
                      }}
                    >
                      No products found
                    </td>
                  </tr>
                ) : (
                  filteredProducts.map((p) => {
                    const badge = getTypeBadge(p.physical_type);
                    const isSelected =
                      selectedProduct?.product_id === p.product_id;
                    return (
                      <tr
                        key={p.product_id}
                        onClick={() => {
                          if (isSelected) {
                            setSelectedProduct(null);
                            setEditMode(false);
                          } else {
                            setSelectedProduct(p);
                            setDraft(rowToDraft(p));
                            setEditMode(false);
                            setSaveError(null);
                          }
                        }}
                        style={{
                          cursor: "pointer",
                          background: isSelected ? "#f0fdf4" : undefined,
                          borderBottom: "1px solid #f5f2ee",
                        }}
                        onMouseEnter={(e) => {
                          if (!isSelected)
                            e.currentTarget.style.background = "#faf9f7";
                        }}
                        onMouseLeave={(e) => {
                          if (!isSelected)
                            e.currentTarget.style.background = "white";
                        }}
                      >
                        <td style={nameCell}>{p.boonz_product_name}</td>
                        <td style={{ ...tdStyle, color: "#6b6860" }}>
                          {p.product_brand ?? "—"}
                        </td>
                        <td style={{ ...tdStyle, color: "#6b6860", fontSize: 12 }}>
                          {p.product_category ?? "—"}
                        </td>
                        <td style={tdStyle}>
                          <StorageBadge value={p.storage_temp_requirement} />
                        </td>
                        <td style={tdStyle}>
                          <span style={pillStyle(badge.bg, badge.text)}>
                            {badge.label}
                          </span>
                        </td>
                        <td style={{ ...tdStyle, color: "#6b6860" }}>
                          {p.avg_cost != null
                            ? `${p.avg_cost.toFixed(2)} AED`
                            : "—"}
                        </td>
                        <td
                          style={{
                            ...tdStyle,
                            fontFamily: "monospace",
                            fontSize: 12,
                            color: "#9c9790",
                          }}
                        >
                          {p.product_id.slice(0, 8)}
                        </td>
                      </tr>
                    );
                  })
                )}
              </tbody>
            </table>
          </div>
        </>
      )}

      {/* ========== TAB 2: Pod Product DB ========== */}
      {activeTab === "pod" && (
        <>
          <p style={{ fontSize: 13, color: "#6b6860", marginBottom: 12 }}>
            {loading
              ? "..."
              : `${podGrouped.size} active products across ${podDistinctMachines} machines`}
          </p>

          <div style={tableWrap}>
            <table style={{ width: "100%", borderCollapse: "collapse" }}>
              <thead>
                <tr>
                  <th style={thStyle}>Product</th>
                  <th style={thStyle}>Type</th>
                  <th style={thStyle}>Machines</th>
                  <th style={thStyle}>Total Stock</th>
                  <th style={thStyle}>Status</th>
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  <SkeletonRows cols={5} />
                ) : podGrouped.size === 0 ? (
                  <tr>
                    <td
                      colSpan={5}
                      style={{
                        ...tdStyle,
                        textAlign: "center",
                        color: "#6b6860",
                      }}
                    >
                      No active pod inventory
                    </td>
                  </tr>
                ) : (
                  Array.from(podGrouped.entries())
                    .sort((a, b) => {
                      const nameA =
                        productMap.get(a[0])?.boonz_product_name ?? "";
                      const nameB =
                        productMap.get(b[0])?.boonz_product_name ?? "";
                      return nameA.localeCompare(nameB);
                    })
                    .map(([productId, data]) => {
                      const prod = productMap.get(productId);
                      const badge = getTypeBadge(prod?.physical_type ?? null);
                      return (
                        <tr
                          key={productId}
                          onMouseEnter={(e) => {
                            e.currentTarget.style.background = "#faf9f7";
                          }}
                          onMouseLeave={(e) => {
                            e.currentTarget.style.background = "white";
                          }}
                        >
                          <td style={nameCell}>
                            {prod?.boonz_product_name ?? productId.slice(0, 8)}
                          </td>
                          <td style={tdStyle}>
                            <span style={pillStyle(badge.bg, badge.text)}>
                              {badge.label}
                            </span>
                          </td>
                          <td style={tdStyle}>{data.machineIds.size}</td>
                          <td style={tdStyle}>{data.totalStock}</td>
                          <td style={tdStyle}>
                            <span style={pillStyle("#eaf3de", "#3b6d11")}>
                              Active
                            </span>
                          </td>
                        </tr>
                      );
                    })
                )}
              </tbody>
            </table>
          </div>
        </>
      )}

      {/* ========== TAB 3: Product Mapping ========== */}
      {activeTab === "mapping" && (
        <>
          <p style={{ fontSize: 13, color: "#6b6860", marginBottom: 12 }}>
            {loading
              ? "..."
              : `${mapped.length} mapped / ${unmapped.length} unmapped`}
          </p>

          <h3
            style={{
              fontFamily: font,
              fontSize: 14,
              fontWeight: 700,
              color: "#0a0a0a",
              marginBottom: 8,
              marginTop: 0,
            }}
          >
            Mapped
          </h3>
          <div style={{ ...tableWrap, marginBottom: 32 }}>
            <table style={{ width: "100%", borderCollapse: "collapse" }}>
              <thead>
                <tr>
                  <th style={thStyle}>Product Name</th>
                  <th style={thStyle}>Machines</th>
                  <th style={thStyle}>Total Stock</th>
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  <SkeletonRows cols={3} />
                ) : mapped.length === 0 ? (
                  <tr>
                    <td
                      colSpan={3}
                      style={{
                        ...tdStyle,
                        textAlign: "center",
                        color: "#6b6860",
                      }}
                    >
                      No mapped products
                    </td>
                  </tr>
                ) : (
                  mapped.map((p) => {
                    const entry = podGrouped.get(p.product_id);
                    return (
                      <tr
                        key={p.product_id}
                        onMouseEnter={(e) => {
                          e.currentTarget.style.background = "#faf9f7";
                        }}
                        onMouseLeave={(e) => {
                          e.currentTarget.style.background = "white";
                        }}
                      >
                        <td style={nameCell}>{p.boonz_product_name}</td>
                        <td style={tdStyle}>{entry?.machineIds.size ?? 0}</td>
                        <td style={tdStyle}>{entry?.totalStock ?? 0}</td>
                      </tr>
                    );
                  })
                )}
              </tbody>
            </table>
          </div>

          <h3
            style={{
              fontFamily: font,
              fontSize: 14,
              fontWeight: 700,
              color: "#0a0a0a",
              marginBottom: 8,
            }}
          >
            Unmapped
          </h3>
          <div style={tableWrap}>
            <table style={{ width: "100%", borderCollapse: "collapse" }}>
              <thead>
                <tr>
                  <th style={thStyle}>Product Name</th>
                  <th style={thStyle}>Type</th>
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  <SkeletonRows cols={2} />
                ) : unmapped.length === 0 ? (
                  <tr>
                    <td
                      colSpan={2}
                      style={{
                        ...tdStyle,
                        textAlign: "center",
                        color: "#6b6860",
                      }}
                    >
                      All products are mapped
                    </td>
                  </tr>
                ) : (
                  unmapped.map((p) => {
                    const badge = getTypeBadge(p.physical_type);
                    return (
                      <tr
                        key={p.product_id}
                        onMouseEnter={(e) => {
                          e.currentTarget.style.background = "#faf9f7";
                        }}
                        onMouseLeave={(e) => {
                          e.currentTarget.style.background = "white";
                        }}
                      >
                        <td style={nameCell}>{p.boonz_product_name}</td>
                        <td style={tdStyle}>
                          <span style={pillStyle(badge.bg, badge.text)}>
                            {badge.label}
                          </span>
                        </td>
                      </tr>
                    );
                  })
                )}
              </tbody>
            </table>
          </div>
        </>
      )}

      {/* ========== Product Detail Drawer (Boonz tab) ========== */}
      {selectedProduct && activeTab === "boonz" && draft && (
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
            style={{ flex: 1, background: "rgba(0,0,0,0.25)" }}
            onClick={() => {
              setSelectedProduct(null);
              setEditMode(false);
            }}
          />
          {/* Panel */}
          <div
            style={{
              width: 560,
              background: "white",
              height: "100%",
              overflowY: "auto",
              display: "flex",
              flexDirection: "column",
              borderLeft: "1px solid #e8e4de",
              fontFamily: font,
            }}
          >
            {/* Header */}
            <div
              style={{
                display: "flex",
                alignItems: "flex-start",
                justifyContent: "space-between",
                padding: "20px 24px 16px",
                borderBottom: "1px solid #e8e4de",
                gap: 12,
              }}
            >
              <div>
                <h2
                  style={{
                    margin: 0,
                    fontSize: 17,
                    fontWeight: 700,
                    color: "#0a0a0a",
                    letterSpacing: "-0.01em",
                    lineHeight: 1.3,
                  }}
                >
                  {selectedProduct.boonz_product_name}
                </h2>
                <p
                  style={{
                    margin: "4px 0 0",
                    fontSize: 12,
                    color: "#6b6860",
                  }}
                >
                  {selectedProduct.product_brand ?? ""}
                  {selectedProduct.product_sub_brand
                    ? ` · ${selectedProduct.product_sub_brand}`
                    : ""}
                </p>
              </div>
              <button
                onClick={() => {
                  setSelectedProduct(null);
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
                  flexShrink: 0,
                }}
                aria-label="Close"
              >
                ✕
              </button>
            </div>

            {/* Body */}
            <div style={{ padding: "20px 24px", flex: 1 }}>
              {!editMode ? (
                /* ── Read-only view ─────────────────────────── */
                <>
                  {/* Identity */}
                  <p style={sectionHead}>Identity</p>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr",
                      gap: "12px 20px",
                      marginBottom: 8,
                    }}
                  >
                    {[
                      ["Brand", selectedProduct.product_brand],
                      ["Sub-brand", selectedProduct.product_sub_brand],
                      ["Category", selectedProduct.product_category],
                      ["Category Group", selectedProduct.category_group],
                    ].map(([label, val]) => (
                      <div key={label as string}>
                        <div
                          style={{
                            fontSize: 10,
                            fontWeight: 700,
                            letterSpacing: "0.1em",
                            textTransform: "uppercase",
                            color: "#6b6860",
                            marginBottom: 3,
                          }}
                        >
                          {label}
                        </div>
                        <div
                          style={{
                            fontSize: 14,
                            color: "#0a0a0a",
                            fontWeight: 500,
                          }}
                        >
                          {val ?? "—"}
                        </div>
                      </div>
                    ))}
                  </div>

                  {/* Physical */}
                  <p style={{ ...sectionHead, marginTop: 20 }}>Physical</p>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr",
                      gap: "12px 20px",
                      marginBottom: 8,
                    }}
                  >
                    {[
                      [
                        "Weight (g)",
                        selectedProduct.product_weight_g?.toString(),
                      ],
                      [
                        "Actual Weight (g)",
                        selectedProduct.actual_weight_g?.toString(),
                      ],
                    ].map(([label, val]) => (
                      <div key={label as string}>
                        <div
                          style={{
                            fontSize: 10,
                            fontWeight: 700,
                            letterSpacing: "0.1em",
                            textTransform: "uppercase",
                            color: "#6b6860",
                            marginBottom: 3,
                          }}
                        >
                          {label}
                        </div>
                        <div
                          style={{
                            fontSize: 14,
                            color: "#0a0a0a",
                            fontWeight: 500,
                          }}
                        >
                          {val ?? "—"}
                        </div>
                      </div>
                    ))}
                  </div>
                  {selectedProduct.description && (
                    <div style={{ marginBottom: 8 }}>
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
                        Description
                      </div>
                      <div
                        style={{
                          fontSize: 13,
                          color: "#0a0a0a",
                          lineHeight: 1.5,
                        }}
                      >
                        {selectedProduct.description}
                      </div>
                    </div>
                  )}

                  {/* Attributes */}
                  <p style={{ ...sectionHead, marginTop: 20 }}>Attributes</p>
                  <div
                    style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 8 }}
                  >
                    {[
                      ["Healthy", selectedProduct.attr_healthy],
                      ["Drink", selectedProduct.attr_drink],
                      ["Salty", selectedProduct.attr_salty],
                      ["Sweet", selectedProduct.attr_sweet],
                      ["30-day shelf", selectedProduct.attr_30days],
                    ].map(([label, val]) => (
                      <span
                        key={label as string}
                        style={{
                          padding: "4px 12px",
                          borderRadius: 999,
                          fontSize: 12,
                          fontWeight: 600,
                          background: val ? "#24544a" : "#f5f2ee",
                          color: val ? "white" : "#9c9790",
                        }}
                      >
                        {label as string}
                      </span>
                    ))}
                  </div>

                  {/* Storage */}
                  <p style={{ ...sectionHead, marginTop: 20 }}>Storage</p>
                  <div style={{ marginBottom: 8 }}>
                    <StorageBadge
                      value={selectedProduct.storage_temp_requirement}
                    />
                  </div>

                  {/* Cost */}
                  <p style={{ ...sectionHead, marginTop: 20 }}>Cost</p>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr 1fr",
                      gap: "12px 20px",
                      marginBottom: 8,
                    }}
                  >
                    {[
                      ["Min", selectedProduct.min_cost],
                      ["Max", selectedProduct.max_cost],
                      ["Avg", selectedProduct.avg_cost],
                    ].map(([label, val]) => (
                      <div key={label as string}>
                        <div
                          style={{
                            fontSize: 10,
                            fontWeight: 700,
                            letterSpacing: "0.1em",
                            textTransform: "uppercase",
                            color: "#6b6860",
                            marginBottom: 3,
                          }}
                        >
                          {label}
                        </div>
                        <div
                          style={{
                            fontSize: 14,
                            color: "#0a0a0a",
                            fontWeight: 600,
                          }}
                        >
                          {val != null
                            ? `${(val as number).toFixed(2)} AED`
                            : "—"}
                        </div>
                      </div>
                    ))}
                  </div>
                  {selectedProduct.sourcing_channel && (
                    <div>
                      <div
                        style={{
                          fontSize: 10,
                          fontWeight: 700,
                          letterSpacing: "0.1em",
                          textTransform: "uppercase",
                          color: "#6b6860",
                          marginBottom: 3,
                        }}
                      >
                        Sourcing Channel
                      </div>
                      <div
                        style={{
                          fontSize: 14,
                          color: "#0a0a0a",
                          fontWeight: 500,
                        }}
                      >
                        {selectedProduct.sourcing_channel}
                      </div>
                    </div>
                  )}
                </>
              ) : (
                /* ── Edit mode ──────────────────────────────── */
                <>
                  {/* IDENTITY */}
                  <p style={sectionHead}>Identity</p>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr",
                      gap: "14px 16px",
                    }}
                  >
                    {(
                      [
                        ["Brand *", "product_brand"],
                        ["Sub-brand *", "product_sub_brand"],
                        ["Category", "product_category"],
                        ["Category Group", "category_group"],
                      ] as [string, keyof ProductDraft][]
                    ).map(([label, key]) => (
                      <div key={key}>
                        <label style={labelStyle}>{label}</label>
                        <input
                          type="text"
                          value={draft[key] as string}
                          onChange={(e) =>
                            setDraft((d) =>
                              d ? { ...d, [key]: e.target.value } : d,
                            )
                          }
                          style={inputStyle}
                        />
                      </div>
                    ))}
                  </div>

                  {/* PHYSICAL */}
                  <p style={{ ...sectionHead, marginTop: 20 }}>Physical</p>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr",
                      gap: "14px 16px",
                    }}
                  >
                    {(
                      [
                        ["Weight (g)", "product_weight_g"],
                        ["Actual Weight (g)", "actual_weight_g"],
                      ] as [string, keyof ProductDraft][]
                    ).map(([label, key]) => (
                      <div key={key}>
                        <label style={labelStyle}>{label}</label>
                        <input
                          type="number"
                          step="any"
                          value={draft[key] as string}
                          onChange={(e) =>
                            setDraft((d) =>
                              d ? { ...d, [key]: e.target.value } : d,
                            )
                          }
                          style={inputStyle}
                        />
                      </div>
                    ))}
                  </div>
                  <div style={{ marginTop: 14 }}>
                    <label style={labelStyle}>Description</label>
                    <textarea
                      value={draft.description}
                      onChange={(e) =>
                        setDraft((d) =>
                          d ? { ...d, description: e.target.value } : d,
                        )
                      }
                      rows={3}
                      style={{
                        ...inputStyle,
                        resize: "vertical",
                        lineHeight: 1.5,
                      }}
                    />
                  </div>

                  {/* ATTRIBUTES */}
                  <p style={{ ...sectionHead, marginTop: 20 }}>Attributes</p>
                  <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                    {(
                      [
                        ["Healthy", "attr_healthy"],
                        ["Drink", "attr_drink"],
                        ["Salty", "attr_salty"],
                        ["Sweet", "attr_sweet"],
                        ["30-day shelf", "attr_30days"],
                      ] as [string, keyof ProductDraft][]
                    ).map(([label, key]) =>
                      attrToggle(draft[key] as boolean, label, () =>
                        setDraft((d) =>
                          d ? { ...d, [key]: !d[key] } : d,
                        ),
                      ),
                    )}
                  </div>

                  {/* STORAGE */}
                  <p style={{ ...sectionHead, marginTop: 20 }}>Storage</p>
                  <div
                    style={{ display: "flex", flexDirection: "column", gap: 8 }}
                  >
                    {[
                      {
                        value: "ambient",
                        label: "Ambient",
                        desc: "Can be staged in WH_MM / WH_MCC",
                      },
                      {
                        value: "cold",
                        label: "Cold ❄",
                        desc: "Requires refrigeration — ships from WH Central only",
                      },
                      {
                        value: "frozen",
                        label: "Frozen 🧊",
                        desc: "Requires freezer — ships from WH Central only",
                      },
                    ].map((opt) => (
                      <div
                        key={opt.value}
                        onClick={() =>
                          setDraft((d) =>
                            d
                              ? {
                                  ...d,
                                  storage_temp_requirement: opt.value,
                                }
                              : d,
                          )
                        }
                        style={{
                          border:
                            draft.storage_temp_requirement === opt.value
                              ? "2px solid #24544a"
                              : "1px solid #e8e4de",
                          borderRadius: 8,
                          padding: "10px 14px",
                          cursor: "pointer",
                          background:
                            draft.storage_temp_requirement === opt.value
                              ? "#f0fdf4"
                              : "white",
                        }}
                      >
                        <div
                          style={{
                            fontWeight: 600,
                            fontSize: 13,
                            color: "#0a0a0a",
                          }}
                        >
                          {opt.label}
                          {draft.storage_temp_requirement === opt.value && (
                            <span
                              style={{
                                marginLeft: 8,
                                color: "#24544a",
                                fontSize: 12,
                              }}
                            >
                              ✓ Selected
                            </span>
                          )}
                        </div>
                        <div
                          style={{
                            fontSize: 12,
                            color: "#6b6860",
                            marginTop: 2,
                          }}
                        >
                          {opt.desc}
                        </div>
                      </div>
                    ))}
                  </div>

                  {/* COST */}
                  <p style={{ ...sectionHead, marginTop: 20 }}>Cost</p>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr 1fr",
                      gap: "14px 16px",
                    }}
                  >
                    {(
                      [
                        ["Min", "min_cost"],
                        ["Max", "max_cost"],
                        ["Avg", "avg_cost"],
                      ] as [string, keyof ProductDraft][]
                    ).map(([label, key]) => (
                      <div key={key}>
                        <label style={labelStyle}>{label}</label>
                        <input
                          type="number"
                          step="0.01"
                          value={draft[key] as string}
                          onChange={(e) =>
                            setDraft((d) =>
                              d ? { ...d, [key]: e.target.value } : d,
                            )
                          }
                          style={inputStyle}
                        />
                      </div>
                    ))}
                  </div>
                  <div style={{ marginTop: 14 }}>
                    <label style={labelStyle}>Sourcing Channel</label>
                    <select
                      value={draft.sourcing_channel}
                      onChange={(e) =>
                        setDraft((d) =>
                          d ? { ...d, sourcing_channel: e.target.value } : d,
                        )
                      }
                      style={{ ...inputStyle, cursor: "pointer" }}
                    >
                      <option value="">— Select —</option>
                      {SOURCING_CHANNELS.map((c) => (
                        <option key={c} value={c}>
                          {c}
                        </option>
                      ))}
                    </select>
                  </div>

                  {saveError && (
                    <p
                      style={{
                        marginTop: 12,
                        color: "#dc2626",
                        fontSize: 13,
                      }}
                    >
                      {saveError}
                    </p>
                  )}
                </>
              )}
            </div>

            {/* Footer */}
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
                    fontFamily: font,
                  }}
                >
                  Edit Product
                </button>
              ) : (
                <>
                  <button
                    onClick={() => {
                      setEditMode(false);
                      setDraft(rowToDraft(selectedProduct));
                      setSaveError(null);
                    }}
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
                      fontFamily: font,
                    }}
                  >
                    Cancel
                  </button>
                  <button
                    onClick={handleSave}
                    disabled={saving}
                    style={{
                      flex: 1,
                      padding: "10px 0",
                      borderRadius: 8,
                      border: "none",
                      background: saving ? "#9c9790" : "#24544a",
                      color: "white",
                      fontSize: 14,
                      fontWeight: 600,
                      cursor: saving ? "not-allowed" : "pointer",
                      fontFamily: font,
                    }}
                  >
                    {saving ? "Saving…" : "Save Changes"}
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
