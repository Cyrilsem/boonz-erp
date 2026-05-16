"use client";

import { useState, useEffect, useCallback } from "react";
import { createBrowserClient } from "@supabase/ssr";

// ── Types ────────────────────────────────────────────────────────────────────

type PendingSwap = {
  machine_name: string;
  remove_pod_product_name: string;
  add_pod_product_name: string;
  notes: string | null;
  created_at: string;
};

type DecomWhStock = {
  boonz_product_name: string;
  wh_inventory_id: string;
  warehouse_stock: number;
  expiration_date: string | null;
  warehouse_name: string | null;
};

type GhostPodInventory = {
  machine_name: string;
  machine_status: string;
  boonz_product_name: string;
  current_stock: number;
  status: string;
  shelf_id: string | null;
};

type StaleDispatch = {
  dispatch_date: string;
  machine_name: string;
  action: string;
  boonz_product_name: string;
  quantity: number;
  dispatched: boolean;
  picked_up: boolean;
  packed: boolean;
  returned: boolean;
};

type StaleVisit = {
  machine_name: string;
  last_refill_date: string;
  days_since_last_refill: number;
};

type SignalCategory = "swaps" | "decom_wh" | "ghost_pods" | "stale_dispatch" | "stale_visits";

const SIGNAL_META: Record<SignalCategory, { label: string; icon: string; description: string; color: string; borderColor: string; headerColor: string }> = {
  swaps: {
    label: "Pending Swaps",
    icon: "🔄",
    description: "planned_swaps with status='pending' — these feed into the advisory and engine SWAP pass",
    color: "#eff6ff",
    borderColor: "#bfdbfe",
    headerColor: "#1e40af",
  },
  decom_wh: {
    label: "Decom WH Stock",
    icon: "🗑️",
    description: "Decommissioned products still Active in warehouse_inventory — triggers drain signals",
    color: "#fff7ed",
    borderColor: "#fed7aa",
    headerColor: "#9a3412",
  },
  ghost_pods: {
    label: "Ghost Pod Inventory",
    icon: "👻",
    description: "pod_inventory rows with status='Active' on Inactive machines — noise, should be archived",
    color: "#fef2f2",
    borderColor: "#fecaca",
    headerColor: "#991b1b",
  },
  stale_dispatch: {
    label: "Stale Dispatches",
    icon: "📦",
    description: "refill_dispatching rows that are dispatched but not picked_up (and not returned) — may indicate field issues",
    color: "#faf5ff",
    borderColor: "#e9d5ff",
    headerColor: "#6b21a8",
  },
  stale_visits: {
    label: "Stale Visits (>10d)",
    icon: "⏰",
    description: "Machines with no approved refill in >10 days — may need attention or are genuinely low-velocity",
    color: "#fefce8",
    borderColor: "#fef08a",
    headerColor: "#854d0e",
  },
};

// ── Component ────────────────────────────────────────────────────────────────

export function SignalsTab() {
  const supabase = createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  );

  const [loading, setLoading] = useState(true);
  const [swaps, setSwaps] = useState<PendingSwap[]>([]);
  const [decomWh, setDecomWh] = useState<DecomWhStock[]>([]);
  const [ghostPods, setGhostPods] = useState<GhostPodInventory[]>([]);
  const [staleDispatches, setStaleDispatches] = useState<StaleDispatch[]>([]);
  const [staleVisits, setStaleVisits] = useState<StaleVisit[]>([]);
  const [expandedSection, setExpandedSection] = useState<SignalCategory | null>(null);

  const fetchSignals = useCallback(async () => {
    setLoading(true);

    // 1. Pending swaps
    const { data: swapData } = await supabase
      .from("planned_swaps")
      .select("machine_name, remove_pod_product_name, add_pod_product_name, notes, created_at")
      .eq("status", "pending")
      .order("created_at", { ascending: false });

    if (swapData) setSwaps(swapData as PendingSwap[]);

    // 2. Decommissioned WH stock (Ritz + Loacker Quadratini)
    const { data: decomData } = await supabase.rpc("get_decom_wh_signals");
    if (decomData) setDecomWh(decomData as DecomWhStock[]);

    // 3. Ghost pod_inventory (Active on Inactive machines)
    const { data: ghostData } = await supabase.rpc("get_ghost_pod_signals");
    if (ghostData) setGhostPods(ghostData as GhostPodInventory[]);

    // 4. Stale dispatches (dispatched=true, picked_up=false, returned=false, dispatch_date < today)
    const { data: staleDispData } = await supabase.rpc("get_stale_dispatch_signals");
    if (staleDispData) setStaleDispatches(staleDispData as StaleDispatch[]);

    // 5. Stale visits (>10 days since last approved refill)
    const { data: staleVisitData } = await supabase.rpc("get_stale_visit_signals");
    if (staleVisitData) setStaleVisits(staleVisitData as StaleVisit[]);

    setLoading(false);
  }, []);

  useEffect(() => {
    fetchSignals();
  }, [fetchSignals]);

  const toggle = (section: SignalCategory) => {
    setExpandedSection(expandedSection === section ? null : section);
  };

  const signalCounts: Record<SignalCategory, number> = {
    swaps: swaps.length,
    decom_wh: decomWh.length,
    ghost_pods: ghostPods.length,
    stale_dispatch: staleDispatches.length,
    stale_visits: staleVisits.length,
  };

  const totalSignals = Object.values(signalCounts).reduce((a, b) => a + b, 0);

  return (
    <div>
      {/* ── Header ──────────────────────────────────────────────── */}
      <div style={{ marginBottom: 20 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 8 }}>
          <h2 style={{ fontSize: 16, fontWeight: 700, color: "#0a0a0a", margin: 0 }}>
            Decision Signals
          </h2>
          <span style={{ fontSize: 12, fontWeight: 600, color: "#6b6860", background: "#f5f3ee", padding: "3px 10px", borderRadius: 10 }}>
            {totalSignals} active
          </span>
          <button
            onClick={fetchSignals}
            disabled={loading}
            style={{
              marginLeft: "auto",
              padding: "6px 14px",
              fontSize: 12,
              fontWeight: 500,
              background: "#fff",
              color: "#6b6860",
              border: "1px solid #e8e4de",
              borderRadius: 6,
              cursor: loading ? "wait" : "pointer",
            }}
          >
            {loading ? "Loading…" : "↻ Refresh"}
          </button>
        </div>
        <p style={{ fontSize: 12, color: "#9ca3af", margin: 0, lineHeight: 1.5 }}>
          All data sources that feed into refill decisions. If something unexpected appears in the plan, check here first.
        </p>
      </div>

      {loading ? (
        <div style={{ textAlign: "center", padding: 40, color: "#6b6860" }}>Loading signals...</div>
      ) : (
        <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
          {(Object.keys(SIGNAL_META) as SignalCategory[]).map((cat) => {
            const meta = SIGNAL_META[cat];
            const count = signalCounts[cat];
            const isExpanded = expandedSection === cat;

            return (
              <div
                key={cat}
                style={{
                  background: "#fff",
                  border: `1px solid ${count > 0 ? meta.borderColor : "#e8e4de"}`,
                  borderLeft: `4px solid ${count > 0 ? meta.headerColor : "#d1d5db"}`,
                  borderRadius: 8,
                  overflow: "hidden",
                }}
              >
                {/* ── Section header (clickable) ── */}
                <button
                  onClick={() => toggle(cat)}
                  style={{
                    display: "flex",
                    alignItems: "center",
                    gap: 10,
                    width: "100%",
                    padding: "14px 18px",
                    background: count > 0 ? meta.color : "#fafafa",
                    border: "none",
                    cursor: "pointer",
                    textAlign: "left",
                  }}
                >
                  <span style={{ fontSize: 18 }}>{meta.icon}</span>
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 13, fontWeight: 700, color: count > 0 ? meta.headerColor : "#9ca3af" }}>
                      {meta.label}
                    </div>
                    <div style={{ fontSize: 11, color: "#9ca3af", marginTop: 2 }}>
                      {meta.description}
                    </div>
                  </div>
                  <span
                    style={{
                      fontSize: 13,
                      fontWeight: 700,
                      color: count > 0 ? meta.headerColor : "#d1d5db",
                      background: count > 0 ? "#fff" : "#f3f4f6",
                      padding: "4px 12px",
                      borderRadius: 12,
                      border: `1px solid ${count > 0 ? meta.borderColor : "#e5e7eb"}`,
                    }}
                  >
                    {count}
                  </span>
                  <span style={{ fontSize: 12, color: "#9ca3af", transform: isExpanded ? "rotate(180deg)" : "none", transition: "transform 0.2s" }}>
                    ▼
                  </span>
                </button>

                {/* ── Expanded content ── */}
                {isExpanded && count > 0 && (
                  <div style={{ padding: "0 18px 14px", borderTop: `1px solid ${meta.borderColor}` }}>
                    {cat === "swaps" && (
                      <table style={{ width: "100%", fontSize: 12, borderCollapse: "collapse", marginTop: 12 }}>
                        <thead>
                          <tr style={{ borderBottom: "1px solid #e8e4de", color: "#6b6860", fontSize: 11, textTransform: "uppercase", letterSpacing: "0.04em" }}>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Machine</th>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Remove</th>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Add</th>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Notes</th>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Created</th>
                          </tr>
                        </thead>
                        <tbody>
                          {swaps.map((s, i) => (
                            <tr key={i} style={{ borderBottom: "1px solid #f5f3ee" }}>
                              <td style={{ padding: "8px 4px", fontFamily: "monospace", fontWeight: 600 }}>{s.machine_name}</td>
                              <td style={{ padding: "8px 4px", color: "#dc2626" }}>{s.remove_pod_product_name}</td>
                              <td style={{ padding: "8px 4px", color: "#16a34a" }}>{s.add_pod_product_name}</td>
                              <td style={{ padding: "8px 4px", color: "#6b6860", maxWidth: 200, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{s.notes || "—"}</td>
                              <td style={{ padding: "8px 4px", color: "#9ca3af" }}>{new Date(s.created_at).toLocaleDateString()}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    )}

                    {cat === "decom_wh" && (
                      <table style={{ width: "100%", fontSize: 12, borderCollapse: "collapse", marginTop: 12 }}>
                        <thead>
                          <tr style={{ borderBottom: "1px solid #e8e4de", color: "#6b6860", fontSize: 11, textTransform: "uppercase", letterSpacing: "0.04em" }}>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Product</th>
                            <th style={{ textAlign: "right", padding: "8px 4px", fontWeight: 600 }}>WH Stock</th>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Expiry</th>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Warehouse</th>
                          </tr>
                        </thead>
                        <tbody>
                          {decomWh.map((d, i) => (
                            <tr key={i} style={{ borderBottom: "1px solid #f5f3ee" }}>
                              <td style={{ padding: "8px 4px", fontWeight: 600 }}>{d.boonz_product_name}</td>
                              <td style={{ padding: "8px 4px", textAlign: "right", fontWeight: 700, color: "#9a3412" }}>{d.warehouse_stock}</td>
                              <td style={{ padding: "8px 4px", color: "#6b6860" }}>{d.expiration_date || "—"}</td>
                              <td style={{ padding: "8px 4px", color: "#6b6860" }}>{d.warehouse_name || "—"}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    )}

                    {cat === "ghost_pods" && (
                      <table style={{ width: "100%", fontSize: 12, borderCollapse: "collapse", marginTop: 12 }}>
                        <thead>
                          <tr style={{ borderBottom: "1px solid #e8e4de", color: "#6b6860", fontSize: 11, textTransform: "uppercase", letterSpacing: "0.04em" }}>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Machine</th>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Machine Status</th>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Product</th>
                            <th style={{ textAlign: "right", padding: "8px 4px", fontWeight: 600 }}>Stock</th>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Pod Status</th>
                          </tr>
                        </thead>
                        <tbody>
                          {ghostPods.map((g, i) => (
                            <tr key={i} style={{ borderBottom: "1px solid #f5f3ee" }}>
                              <td style={{ padding: "8px 4px", fontFamily: "monospace", fontWeight: 600 }}>{g.machine_name}</td>
                              <td style={{ padding: "8px 4px" }}>
                                <span style={{ fontSize: 11, padding: "2px 6px", borderRadius: 4, background: "#fee2e2", color: "#991b1b", fontWeight: 600 }}>
                                  {g.machine_status}
                                </span>
                              </td>
                              <td style={{ padding: "8px 4px" }}>{g.boonz_product_name}</td>
                              <td style={{ padding: "8px 4px", textAlign: "right" }}>{g.current_stock}</td>
                              <td style={{ padding: "8px 4px", color: "#6b6860" }}>{g.status}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    )}

                    {cat === "stale_dispatch" && (
                      <table style={{ width: "100%", fontSize: 12, borderCollapse: "collapse", marginTop: 12 }}>
                        <thead>
                          <tr style={{ borderBottom: "1px solid #e8e4de", color: "#6b6860", fontSize: 11, textTransform: "uppercase", letterSpacing: "0.04em" }}>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Date</th>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Machine</th>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Action</th>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Product</th>
                            <th style={{ textAlign: "right", padding: "8px 4px", fontWeight: 600 }}>Qty</th>
                            <th style={{ textAlign: "center", padding: "8px 4px", fontWeight: 600 }}>State</th>
                          </tr>
                        </thead>
                        <tbody>
                          {staleDispatches.map((d, i) => (
                            <tr key={i} style={{ borderBottom: "1px solid #f5f3ee" }}>
                              <td style={{ padding: "8px 4px", color: "#6b6860" }}>{d.dispatch_date}</td>
                              <td style={{ padding: "8px 4px", fontFamily: "monospace", fontWeight: 600 }}>{d.machine_name}</td>
                              <td style={{ padding: "8px 4px" }}>{d.action}</td>
                              <td style={{ padding: "8px 4px" }}>{d.boonz_product_name}</td>
                              <td style={{ padding: "8px 4px", textAlign: "right", fontWeight: 600 }}>{d.quantity}</td>
                              <td style={{ padding: "8px 4px", textAlign: "center", fontSize: 11 }}>
                                {d.returned ? (
                                  <span style={{ background: "#fef3c7", color: "#92400e", padding: "2px 6px", borderRadius: 4, fontWeight: 600 }}>Returned</span>
                                ) : d.packed && !d.picked_up ? (
                                  <span style={{ background: "#e9d5ff", color: "#6b21a8", padding: "2px 6px", borderRadius: 4, fontWeight: 600 }}>Packed, not picked</span>
                                ) : (
                                  <span style={{ background: "#fee2e2", color: "#991b1b", padding: "2px 6px", borderRadius: 4, fontWeight: 600 }}>Dispatched, stuck</span>
                                )}
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    )}

                    {cat === "stale_visits" && (
                      <table style={{ width: "100%", fontSize: 12, borderCollapse: "collapse", marginTop: 12 }}>
                        <thead>
                          <tr style={{ borderBottom: "1px solid #e8e4de", color: "#6b6860", fontSize: 11, textTransform: "uppercase", letterSpacing: "0.04em" }}>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Machine</th>
                            <th style={{ textAlign: "left", padding: "8px 4px", fontWeight: 600 }}>Last Refill</th>
                            <th style={{ textAlign: "right", padding: "8px 4px", fontWeight: 600 }}>Days Since</th>
                          </tr>
                        </thead>
                        <tbody>
                          {staleVisits.map((v, i) => (
                            <tr key={i} style={{ borderBottom: "1px solid #f5f3ee" }}>
                              <td style={{ padding: "8px 4px", fontFamily: "monospace", fontWeight: 600 }}>{v.machine_name}</td>
                              <td style={{ padding: "8px 4px", color: "#6b6860" }}>{v.last_refill_date}</td>
                              <td style={{ padding: "8px 4px", textAlign: "right", fontWeight: 700, color: v.days_since_last_refill > 20 ? "#dc2626" : "#854d0e" }}>
                                {v.days_since_last_refill}d
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    )}
                  </div>
                )}

                {isExpanded && count === 0 && (
                  <div style={{ padding: "12px 18px", borderTop: `1px solid ${meta.borderColor}`, color: "#9ca3af", fontSize: 12 }}>
                    ✓ Clean — no signals from this source
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
