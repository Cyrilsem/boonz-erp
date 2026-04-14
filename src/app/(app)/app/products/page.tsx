"use client";

import { useEffect, useState, useMemo } from "react";
import { createClient } from "@/lib/supabase/client";

type Tab = "boonz" | "pod" | "mapping";

interface BoonzProduct {
  product_id: string;
  boonz_product_name: string;
  physical_type: string | null;
}

interface PodInventoryRow {
  boonz_product_id: string;
  machine_id: string;
  current_stock: number;
  status: string;
  expiration_date: string | null;
  batch_id: string | null;
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
  return { bg: "#f1efe8", text: "#5f5e5a", label: physical_type ?? "—" };
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

export default function ProductsPage() {
  const [activeTab, setActiveTab] = useState<Tab>("boonz");
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);

  const [products, setProducts] = useState<BoonzProduct[]>([]);
  const [podInventory, setPodInventory] = useState<PodInventoryRow[]>([]);
  const [, setMachines] = useState<
    { machine_id: string; official_name: string | null }[]
  >([]);

  useEffect(() => {
    const supabase = createClient();

    async function fetchAll() {
      setLoading(true);
      const [prodRes, podRes, machRes] = await Promise.all([
        supabase
          .from("boonz_products")
          .select("product_id, boonz_product_name, physical_type")
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

      if (prodRes.data) setProducts(prodRes.data);
      if (podRes.data) setPodInventory(podRes.data);
      if (machRes.data) setMachines(machRes.data);
      setLoading(false);
    }

    fetchAll();
  }, []);

  // --- Derived data ---

  const filteredProducts = useMemo(() => {
    if (!search.trim()) return products;
    const q = search.toLowerCase();
    return products.filter((p) =>
      p.boonz_product_name?.toLowerCase().includes(q),
    );
  }, [products, search]);

  // Pod tab: group inventory by product
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

  // Mapping tab
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

  // --- Styles ---

  const font = "'Plus Jakarta Sans', sans-serif";

  const tabStyle = (tab: Tab): React.CSSProperties => ({
    padding: "12px 16px",
    fontSize: 12,
    fontWeight: activeTab === tab ? 700 : 500,
    letterSpacing: "0.06em",
    textTransform: "uppercase",
    color: activeTab === tab ? "#0a0a0a" : "#6b6860",
    borderBottom:
      activeTab === tab ? "3px solid #0a0a0a" : "3px solid transparent",
    background: "none",
    border: "none",
    borderBottomStyle: "solid",
    borderBottomWidth: 3,
    borderBottomColor: activeTab === tab ? "#0a0a0a" : "transparent",
    cursor: "pointer",
    fontFamily: font,
    transition: "color 0.15s, border-color 0.15s",
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

  const countLabel: React.CSSProperties = {
    fontSize: 13,
    color: "#6b6860",
    fontFamily: font,
    marginBottom: 12,
  };

  // --- Subtitle ---
  const subtitle = `${products.length} products in catalogue \u00B7 ${podGrouped.size} active in pods`;

  return (
    <div
      style={{ padding: "32px 32px 64px", maxWidth: 1100, fontFamily: font }}
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
        <p
          style={{
            color: "#6b6860",
            fontSize: 14,
            marginTop: 4,
            fontFamily: font,
          }}
        >
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
        <button
          type="button"
          style={tabStyle("boonz")}
          onClick={() => {
            setActiveTab("boonz");
            setSearch("");
          }}
        >
          Boonz Product DB
        </button>
        <button
          type="button"
          style={tabStyle("pod")}
          onClick={() => {
            setActiveTab("pod");
            setSearch("");
          }}
        >
          Pod Product DB
        </button>
        <button
          type="button"
          style={tabStyle("mapping")}
          onClick={() => {
            setActiveTab("mapping");
            setSearch("");
          }}
        >
          Product Mapping
        </button>
      </div>

      {/* ========== TAB 1: Boonz Product DB ========== */}
      {activeTab === "boonz" && (
        <>
          {/* Search */}
          <div
            style={{
              marginBottom: 16,
              display: "flex",
              alignItems: "center",
              gap: 12,
            }}
          >
            <input
              type="text"
              placeholder="Search products..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              style={{
                padding: "10px 14px",
                fontSize: 13,
                border: "1px solid #e8e4de",
                borderRadius: 8,
                outline: "none",
                width: 280,
                fontFamily: font,
                background: "white",
              }}
            />
            <span style={countLabel}>
              {loading ? "..." : `${filteredProducts.length} products`}
            </span>
          </div>

          <div style={tableWrap}>
            <table style={{ width: "100%", borderCollapse: "collapse" }}>
              <thead>
                <tr>
                  <th style={thStyle}>Product Name</th>
                  <th style={thStyle}>Type</th>
                  <th style={thStyle}>ID</th>
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  <SkeletonRows cols={3} />
                ) : filteredProducts.length === 0 ? (
                  <tr>
                    <td
                      colSpan={3}
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
                    return (
                      <tr
                        key={p.product_id}
                        style={{ cursor: "default" }}
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
                        <td
                          style={{
                            ...tdStyle,
                            fontFamily: "monospace",
                            fontSize: 12,
                            color: "#6b6860",
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
          <p style={countLabel}>
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
          <p style={countLabel}>
            {loading
              ? "..."
              : `${mapped.length} mapped / ${unmapped.length} unmapped`}
          </p>

          {/* Mapped section */}
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

          {/* Unmapped section */}
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
    </div>
  );
}
