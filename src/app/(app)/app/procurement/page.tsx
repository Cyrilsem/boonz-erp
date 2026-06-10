"use client";

import { useEffect, useState, useMemo, useCallback, Fragment } from "react";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import { CancelPOLineDrawer } from "@/app/(field)/components/CancelPOLineDrawer";

// PRD-002: per-line lock + Cancel gating on the desktop PO drawer.
const EDIT_ROLES = new Set([
  "warehouse",
  "operator_admin",
  "superadmin",
  "manager",
]);

// ── Types ──────────────────────────────────────────────────────────────────────

interface POLine {
  po_line_id: string;
  po_id: string;
  purchase_date: string;
  ordered_qty: number | null;
  received_date: string | null;
  suppliers: { supplier_name: string };
}

interface POGroup {
  po_id: string;
  supplier_name: string;
  purchase_date: string;
  line_count: number;
  total_ordered: number;
  received_date: string | null;
}

interface PODetail {
  po_line_id: string;
  po_id: string;
  po_number: string | null;
  purchase_date: string;
  ordered_qty: number | null;
  received_date: string | null;
  received_qty: number | null;
  purchase_outcome: string | null;
  price_per_unit_aed: number | null;
  total_price_aed: number | null;
  expiry_date: string | null;
  boonz_product_id: string;
  boonz_products: { boonz_product_name: string };
}

interface NewPOLine {
  boonz_product_id: string;
  product_name: string;
  ordered_qty: number;
  price_per_unit_aed: number;
  expiry_date: string;
}

interface ProductOption {
  product_id: string;
  boonz_product_name: string;
}

interface POAddition {
  addition_id: string;
  boonz_product_id: string;
  qty: number;
  price_per_unit_aed: number | null;
  expiry_date: string | null;
  status: string;
  created_at: string;
  boonz_products: { boonz_product_name: string };
}

type TabFilter = "pending" | "all" | "demand";

interface DemandRow {
  boonz_product_id: string;
  boonz_product_name: string;
  pod_product_name: string;
  product_category: string;
  split_pct: number | null;
  sales_14d: number;
  variant_demand_14d: number;
  ctx_multiplier: number | null;
  forecast_demand: number | null;
  wh_stock: number;
  on_order: number;
  gap: number;
  suggested_qty: number;
  units_per_box: number | null;
  source_of_supply: string;
}

// PRD-3: pod-level demand (before mix_weight trickle-down) for the "Pod demand" sub-tab.
interface PodBreakdownEntry {
  boonz_product_id: string;
  boonz_product_name: string;
  mix_weight: number | null;
  split_pct: number | null;
  source_of_supply: string;
  attributed_14d: number;
  block_reason: string | null;
}

interface PodDemandRow {
  pod_product_id: string;
  pod_product_name: string;
  product_category: string;
  sales_14d: number;
  velocity_per_day: number;
  ctx_multiplier: number;
  forecast_demand: number;
  mapped_variant_count: number;
  pod_breakdown: PodBreakdownEntry[] | null;
}

// supplier_products row joined to its supplier name; the preferred-Active row per
// product resolves the SKU's supplier for the supplier-grouping layer (PRD-2).
interface SupplierProductMeta {
  boonz_product_id: string;
  supplier_id: string | null;
  supplier_name: string | null;
  last_unit_price_aed: number | null;
  last_ordered_date: string | null;
}

// v_procurement_blocked_products — products that may never enter a PO basket (PRD-1).
interface BlockedProduct {
  boonz_product_id: string;
  boonz_product_name: string;
  product_category: string | null;
  block_reason: string | null;
}

// "boonz" = Boonz buys & stocks it · "venue_team" = VOX/venue team sources it
type DemandSource = "boonz" | "venue_team";

// Two-level Demand surface: pod-product view vs boonz-SKU view (PRD-2).
type DemandView = "pod" | "sku";

// Sortable demand columns -> the DemandRow field each header sorts by.
type DemandSortKey =
  | "boonz_product_name"
  | "product_category"
  | "sales_14d"
  | "variant_demand_14d"
  | "forecast_demand"
  | "wh_stock"
  | "on_order"
  | "gap"
  | "suggested_qty";

// ── Helpers ────────────────────────────────────────────────────────────────────

function formatDate(dateStr: string | null): string {
  if (!dateStr) return "—";
  const d = new Date(dateStr + "T00:00:00");
  return d.toLocaleDateString("en-AE", {
    day: "numeric",
    month: "short",
    year: "numeric",
  });
}

// Canonical PO ids are PO-<year>-<random token>; create_purchase_order assigns the
// sequential po_number from po_number_seq, so the FE only supplies a unique p_po_id.
function genPoId(): string {
  const token = Array.from({ length: 8 }, () =>
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".charAt(
      Math.floor(Math.random() * 36),
    ),
  ).join("");
  return `PO-${new Date().getFullYear()}-${token}`;
}

// ── Page ───────────────────────────────────────────────────────────────────────

export default function ProcurementPage() {
  const [allOrders, setAllOrders] = useState<POGroup[]>([]);
  const [loading, setLoading] = useState(true);
  const [tab, setTab] = useState<TabFilter>("pending");
  const [search, setSearch] = useState("");

  // Drawer state
  const [selectedPO, setSelectedPO] = useState<POGroup | null>(null);
  const [poLines, setPOLines] = useState<PODetail[]>([]);
  const [poLoading, setPOLoading] = useState(false);

  // PRD-002: caller role + per-line Cancel drawer state.
  const [userRole, setUserRole] = useState<string | null>(null);
  const [cancellingLine, setCancellingLine] = useState<PODetail | null>(null);

  // Field additions state
  const [pendingAdditionsCount, setPendingAdditionsCount] = useState(0);
  const [poAdditions, setPoAdditions] = useState<POAddition[]>([]);
  const [receivingAddition, setReceivingAddition] = useState<string | null>(
    null,
  );

  // New PO modal state
  const [showNewPO, setShowNewPO] = useState(false);
  const [suppliers, setSuppliers] = useState<
    { supplier_id: string; supplier_name: string }[]
  >([]);
  const [products, setProducts] = useState<ProductOption[]>([]);
  const [newSupplier, setNewSupplier] = useState("");
  const [newDate, setNewDate] = useState(getDubaiDate());
  const [newLines, setNewLines] = useState<NewPOLine[]>([]);
  const [newSaving, setNewSaving] = useState(false);

  // Demand tab state
  const [demandRows, setDemandRows] = useState<DemandRow[]>([]);
  const [demandLoading, setDemandLoading] = useState(false);
  const [demandLoaded, setDemandLoaded] = useState(false);
  const [selectedDemandIds, setSelectedDemandIds] = useState<Set<string>>(
    new Set(),
  );
  const [demandDraftSupplier, setDemandDraftSupplier] = useState("");
  const [demandDraftSaving, setDemandDraftSaving] = useState(false);
  const [demandToast, setDemandToast] = useState<string | null>(null);
  // Sourcing view: Boonz-sourced (what we buy) vs venue/VOX-sourced (the venue
  // team supplies). Drives the get_procurement_demand p_source filter.
  const [demandSource, setDemandSource] = useState<DemandSource>("boonz");
  // Column sort for the demand table. Default: gap desc (most urgent first).
  const [demandSort, setDemandSort] = useState<{
    key: DemandSortKey;
    dir: "asc" | "desc";
  }>({ key: "gap", dir: "desc" });

  // PRD-2: two-level Demand surface. "sku" = boonz SKU view (supplier-grouped),
  // "pod" = pod-product view (PRD-3 RPC).
  const [demandView, setDemandView] = useState<DemandView>("pod");
  const [podRows, setPodRows] = useState<PodDemandRow[]>([]);
  const [podLoading, setPodLoading] = useState(false);
  const [podLoaded, setPodLoaded] = useState(false);
  const [expandedPodId, setExpandedPodId] = useState<string | null>(null);
  // Supplier resolution + blocked list for the SKU supplier-grouping layer.
  const [supplierMeta, setSupplierMeta] = useState<
    Map<string, SupplierProductMeta>
  >(new Map());
  const [blockedIds, setBlockedIds] = useState<Map<string, BlockedProduct>>(
    new Map(),
  );
  const [supplierMetaLoaded, setSupplierMetaLoaded] = useState(false);
  // Set-supplier action (writes supplier_products, RLS-gated). Target product id.
  const [setSupplierFor, setSetSupplierFor] = useState<DemandRow | null>(null);
  const [setSupplierChoice, setSetSupplierChoice] = useState("");
  const [setSupplierSaving, setSetSupplierSaving] = useState(false);
  const [collapsedBlocked, setCollapsedBlocked] = useState(true);

  const handleDemandSort = useCallback((key: DemandSortKey) => {
    setDemandSort((prev) =>
      prev.key === key
        ? { key, dir: prev.dir === "asc" ? "desc" : "asc" }
        : // first click: numbers default to desc, text to asc
          {
            key,
            dir:
              key === "boonz_product_name" || key === "product_category"
                ? "asc"
                : "desc",
          },
    );
  }, []);

  const sortedDemandRows = useMemo(() => {
    const { key, dir } = demandSort;
    const factor = dir === "asc" ? 1 : -1;
    return [...demandRows].sort((a, b) => {
      const av = a[key];
      const bv = b[key];
      if (typeof av === "string" || typeof bv === "string") {
        return String(av).localeCompare(String(bv)) * factor;
      }
      return ((av as number) - (bv as number)) * factor;
    });
  }, [demandRows, demandSort]);

  const loadDemand = useCallback(async (source: DemandSource) => {
    setDemandLoading(true);
    const supabase = createClient();
    const { data, error } = await supabase.rpc("get_procurement_demand", {
      p_lookback_days: 14,
      p_buffer_pct: 0.1,
      p_source: source,
    });
    if (!error) {
      setDemandRows((data ?? []) as DemandRow[]);
      setDemandLoaded(true);
    }
    setDemandLoading(false);
  }, []);

  // PRD-3: pod-level demand (before mix_weight trickle-down).
  const loadPodDemand = useCallback(async (source: DemandSource) => {
    setPodLoading(true);
    const supabase = createClient();
    const { data, error } = await supabase.rpc("get_procurement_demand_pod", {
      p_lookback_days: 14,
      p_source: source,
    });
    if (!error) {
      setPodRows((data ?? []) as PodDemandRow[]);
      setPodLoaded(true);
    }
    setPodLoading(false);
  }, []);

  // PRD-2: resolve each SKU's preferred-Active supplier + the blocked list, for
  // the supplier-grouping layer. supplier_products read is RLS read-all-authenticated;
  // v_procurement_blocked_products is the data-driven "Blocked" group source (PRD-1).
  const loadSupplierMeta = useCallback(async () => {
    const supabase = createClient();
    const [spRes, blockedRes] = await Promise.all([
      supabase
        .from("supplier_products")
        .select(
          "boonz_product_id, supplier_id, last_unit_price_aed, last_ordered_date, suppliers!inner(supplier_name)",
        )
        .eq("is_preferred", true)
        .eq("status", "Active")
        .limit(10000),
      supabase
        .from("v_procurement_blocked_products")
        .select(
          "boonz_product_id, boonz_product_name, product_category, block_reason",
        )
        .limit(10000),
    ]);
    const meta = new Map<string, SupplierProductMeta>();
    for (const row of (spRes.data ?? []) as unknown as Array<{
      boonz_product_id: string;
      supplier_id: string;
      last_unit_price_aed: number | null;
      last_ordered_date: string | null;
      suppliers: { supplier_name: string } | null;
    }>) {
      meta.set(row.boonz_product_id, {
        boonz_product_id: row.boonz_product_id,
        supplier_id: row.supplier_id,
        supplier_name: row.suppliers?.supplier_name ?? null,
        last_unit_price_aed: row.last_unit_price_aed,
        last_ordered_date: row.last_ordered_date,
      });
    }
    const blocked = new Map<string, BlockedProduct>();
    for (const b of (blockedRes.data ?? []) as BlockedProduct[]) {
      blocked.set(b.boonz_product_id, b);
    }
    setSupplierMeta(meta);
    setBlockedIds(blocked);
    setSupplierMetaLoaded(true);
  }, []);

  // Switch the VOX/Boonz toggle: clear selection and re-fetch BOTH views for the
  // new source (pod + sku), and refresh supplier resolution.
  const handleDemandSourceChange = useCallback(
    (source: DemandSource) => {
      if (source === demandSource) return;
      setDemandSource(source);
      setSelectedDemandIds(new Set());
      loadDemand(source);
      loadPodDemand(source);
    },
    [demandSource, loadDemand, loadPodDemand],
  );

  const handleTabChange = useCallback(
    (t: TabFilter) => {
      setTab(t);
      if (t === "demand") {
        if (!demandLoaded) loadDemand(demandSource);
        if (!podLoaded) loadPodDemand(demandSource);
        if (!supplierMetaLoaded) loadSupplierMeta();
        // Load suppliers for the "Create Draft PO" + set-supplier flows.
        if (suppliers.length === 0) {
          const supabase = createClient();
          supabase
            .from("suppliers")
            .select("supplier_id, supplier_name")
            .order("supplier_name")
            .limit(10000)
            .then(({ data }) => setSuppliers(data ?? []));
        }
      }
    },
    [
      demandLoaded,
      loadDemand,
      podLoaded,
      loadPodDemand,
      supplierMetaLoaded,
      loadSupplierMeta,
      suppliers.length,
      demandSource,
    ],
  );

  const fetchOrders = useCallback(async () => {
    const supabase = createClient();
    const { data } = await supabase
      .from("purchase_orders")
      .select(
        "po_line_id, po_id, purchase_date, ordered_qty, received_date, suppliers!inner(supplier_name)",
      )
      .order("purchase_date", { ascending: false })
      .limit(10000);

    if (!data || data.length === 0) {
      setAllOrders([]);
      setLoading(false);
      return;
    }

    const grouped = new Map<string, POGroup>();
    for (const line of data as unknown as POLine[]) {
      const existing = grouped.get(line.po_id);
      if (existing) {
        existing.line_count += 1;
        existing.total_ordered += line.ordered_qty ?? 0;
        if (!line.received_date) existing.received_date = null;
      } else {
        grouped.set(line.po_id, {
          po_id: line.po_id,
          supplier_name: line.suppliers.supplier_name,
          purchase_date: line.purchase_date,
          line_count: 1,
          total_ordered: line.ordered_qty ?? 0,
          received_date: line.received_date,
        });
      }
    }

    setAllOrders(
      Array.from(grouped.values()).sort(
        (a, b) =>
          new Date(b.purchase_date).getTime() -
          new Date(a.purchase_date).getTime(),
      ),
    );
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchOrders();
    (async () => {
      const supabase = createClient();
      const { count } = await supabase
        .from("po_additions")
        .select("addition_id", { count: "exact", head: true })
        .eq("status", "pending_receive");
      setPendingAdditionsCount(count ?? 0);

      // PRD-002: fetch caller role so the per-line lock + Cancel buttons can
      // gate themselves. EDIT_ROLES drives Cancel; received-line edits via
      // edit_purchase_order_line are superadmin-only.
      const {
        data: { user },
      } = await supabase.auth.getUser();
      if (user) {
        const { data: profile } = await supabase
          .from("user_profiles")
          .select("role")
          .eq("id", user.id)
          .single();
        setUserRole(profile?.role ?? null);
      }
    })();
  }, [fetchOrders]);

  // ESC key handler
  useEffect(() => {
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        if (showNewPO) setShowNewPO(false);
        else if (selectedPO) {
          setSelectedPO(null);
        }
      }
    };
    window.addEventListener("keydown", handleKey);
    return () => window.removeEventListener("keydown", handleKey);
  }, [selectedPO, showNewPO]);

  // Fetch PO detail lines when a PO is selected
  const openPODrawer = useCallback(async (po: POGroup) => {
    setSelectedPO(po);
    setPOLoading(true);
    const supabase = createClient();
    const { data } = await supabase
      .from("purchase_orders")
      .select(
        "po_line_id, po_id, po_number, purchase_date, ordered_qty, received_date, received_qty, purchase_outcome, price_per_unit_aed, total_price_aed, expiry_date, boonz_product_id, boonz_products!inner(boonz_product_name)",
      )
      .eq("po_id", po.po_id)
      .limit(10000);
    const { data: additionsData } = await supabase
      .from("po_additions")
      .select("*, boonz_products(boonz_product_name)")
      .eq("po_id", po.po_id)
      .order("created_at", { ascending: false })
      .limit(100);
    setPOLines((data ?? []) as unknown as PODetail[]);
    setPoAdditions((additionsData ?? []) as unknown as POAddition[]);
    setPOLoading(false);
  }, []);

  // Load suppliers + products for new PO form
  const openNewPO = useCallback(async () => {
    setShowNewPO(true);
    setNewLines([]);
    setNewSupplier("");
    setNewDate(getDubaiDate());
    const supabase = createClient();
    const [suppRes, prodRes] = await Promise.all([
      supabase
        .from("suppliers")
        .select("supplier_id, supplier_name")
        .order("supplier_name")
        .limit(10000),
      supabase
        .from("boonz_products")
        .select("product_id, boonz_product_name")
        .order("boonz_product_name")
        .limit(10000),
    ]);
    setSuppliers(suppRes.data ?? []);
    setProducts(prodRes.data ?? []);
  }, []);

  const toggleDemandRow = (id: string) => {
    setSelectedDemandIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const toggleAllDemand = () => {
    // Never select blocked products — create_purchase_order would reject the batch.
    const selectable = demandRows
      .map((r) => r.boonz_product_id)
      .filter((id) => !blockedIds.has(id));
    if (selectedDemandIds.size === selectable.length && selectable.length > 0) {
      setSelectedDemandIds(new Set());
    } else {
      setSelectedDemandIds(new Set(selectable));
    }
  };

  // PRD-2 supplier-grouping layer for the Boonz SKU view. Each gap row lands in
  // exactly one bucket: Blocked (PRD-1, never orderable) → its resolved preferred
  // supplier → Unassigned (no supplier_products row at all). Unassigned is pinned
  // to the top to force assignment; Blocked sinks to the bottom.
  const skuGroups = useMemo(() => {
    const unassigned: DemandRow[] = [];
    const blocked: DemandRow[] = [];
    const bySupplier = new Map<
      string,
      { supplier_id: string; supplier_name: string; rows: DemandRow[] }
    >();
    for (const r of sortedDemandRows) {
      if (blockedIds.has(r.boonz_product_id)) {
        blocked.push(r);
        continue;
      }
      const meta = supplierMeta.get(r.boonz_product_id);
      if (meta && meta.supplier_id) {
        const key = meta.supplier_id;
        const g = bySupplier.get(key);
        if (g) g.rows.push(r);
        else
          bySupplier.set(key, {
            supplier_id: meta.supplier_id,
            supplier_name: meta.supplier_name ?? "Unknown supplier",
            rows: [r],
          });
      } else {
        unassigned.push(r);
      }
    }
    const suppliers = Array.from(bySupplier.values())
      .map((g) => ({
        ...g,
        totalLines: g.rows.length,
        totalUnits: g.rows.reduce((s, r) => s + (r.suggested_qty ?? 0), 0),
      }))
      .sort((a, b) => a.supplier_name.localeCompare(b.supplier_name));
    return { unassigned, blocked, suppliers };
  }, [sortedDemandRows, supplierMeta, blockedIds]);

  // PRD-2: assign a preferred supplier to an "Unassigned" product. supplier_products
  // is NOT an Appendix-A protected entity, so a direct RLS-gated insert is the
  // canonical path (CLAUDE.md: direct client inserts over edge fns for simple writes).
  const submitSetSupplier = async () => {
    if (!setSupplierFor || !setSupplierChoice) return;
    setSetSupplierSaving(true);
    const supabase = createClient();
    const { error } = await supabase.from("supplier_products").insert({
      boonz_product_id: setSupplierFor.boonz_product_id,
      supplier_id: setSupplierChoice,
      is_preferred: true,
      status: "Active",
      notes: "set via procurement demand UI",
    });
    if (error) {
      setSetSupplierSaving(false);
      alert(`Failed to set supplier: ${error.message}`);
      return;
    }
    await loadSupplierMeta();
    setSetSupplierSaving(false);
    setSetSupplierFor(null);
    setSetSupplierChoice("");
    setDemandToast(
      `✓ Supplier assigned to ${setSupplierFor.boonz_product_name}`,
    );
    setTimeout(() => setDemandToast(null), 4000);
  };

  // One SKU row for the Boonz SKU view. `mode` controls the bucket styling:
  // "normal" = selectable orderable row · "unassigned" = shows a Set-supplier
  // action · "blocked" = struck-through, never selectable (PRD-1).
  const renderSkuRow = (
    r: DemandRow,
    mode: "normal" | "unassigned" | "blocked",
  ) => {
    const isSelected = selectedDemandIds.has(r.boonz_product_id);
    const blocked = mode === "blocked";
    const gapPct = r.variant_demand_14d > 0 ? r.gap / r.variant_demand_14d : 0;
    const gapColor =
      gapPct > 0.75 ? "#dc2626" : gapPct > 0.4 ? "#d97706" : "#0a0a0a";
    const blockReason = blockedIds.get(r.boonz_product_id)?.block_reason;
    return (
      <tr
        key={r.boonz_product_id}
        style={{
          borderBottom: "1px solid #f5f2ee",
          background: blocked ? "#fafafa" : isSelected ? "#f0fdf4" : undefined,
          cursor: blocked ? "default" : "pointer",
          opacity: blocked ? 0.6 : 1,
        }}
        onClick={
          blocked ? undefined : () => toggleDemandRow(r.boonz_product_id)
        }
      >
        <td className="px-4 py-3" onClick={(e) => e.stopPropagation()}>
          {blocked ? (
            <span title={`Blocked: ${blockReason ?? "never order"}`}>🚫</span>
          ) : (
            <input
              type="checkbox"
              checked={isSelected}
              onChange={() => toggleDemandRow(r.boonz_product_id)}
              style={{ cursor: "pointer" }}
            />
          )}
        </td>
        <td className="px-3 py-3">
          <div
            style={{
              fontWeight: 600,
              color: blocked ? "#6b6860" : "#24544a",
              fontSize: 13,
              textDecoration: blocked ? "line-through" : undefined,
            }}
          >
            {r.boonz_product_name}
          </div>
          <div style={{ fontSize: 11, color: "#6b6860", marginTop: 1 }}>
            {r.pod_product_name}
          </div>
        </td>
        <td className="px-3 py-3" style={{ color: "#6b6860", fontSize: 12 }}>
          {r.product_category ?? "—"}
        </td>
        <td className="px-3 py-3" style={{ color: "#0a0a0a", fontSize: 13 }}>
          {r.sales_14d.toFixed(0)}
        </td>
        <td className="px-3 py-3" style={{ color: "#0a0a0a", fontSize: 13 }}>
          {(r.forecast_demand ?? r.variant_demand_14d).toFixed(0)}
          {r.split_pct != null && r.split_pct < 100 && (
            <span style={{ fontSize: 10, color: "#6b6860", marginLeft: 4 }}>
              ({r.split_pct}%)
            </span>
          )}
        </td>
        <td
          className="px-3 py-3"
          style={{
            color: r.wh_stock === 0 ? "#dc2626" : "#0a0a0a",
            fontSize: 13,
            fontWeight: r.wh_stock === 0 ? 700 : 400,
          }}
        >
          {r.wh_stock.toFixed(0)}
        </td>
        <td
          className="px-3 py-3"
          style={{
            color: r.on_order > 0 ? "#2563eb" : "#9ca3af",
            fontSize: 13,
          }}
        >
          {r.on_order > 0 ? r.on_order.toFixed(0) : "—"}
        </td>
        <td className="px-3 py-3">
          <span style={{ fontWeight: 700, color: gapColor, fontSize: 13 }}>
            {r.gap.toFixed(0)}
          </span>
        </td>
        <td className="px-3 py-3">
          {blocked ? (
            <span style={{ fontSize: 11, color: "#b91c1c", fontWeight: 600 }}>
              {blockReason ?? "blocked"}
            </span>
          ) : mode === "unassigned" ? (
            <button
              onClick={(e) => {
                e.stopPropagation();
                setSetSupplierFor(r);
                setSetSupplierChoice("");
              }}
              style={{
                background: "#fff7ed",
                border: "1px solid #fdba74",
                borderRadius: 6,
                padding: "3px 10px",
                fontSize: 11,
                fontWeight: 600,
                color: "#9a3412",
                cursor: "pointer",
              }}
            >
              Set supplier
            </button>
          ) : (
            <>
              <span
                style={{
                  display: "inline-block",
                  background: "#fef9ee",
                  border: "1px solid #fbbf24",
                  borderRadius: 6,
                  padding: "2px 10px",
                  fontSize: 12,
                  fontWeight: 700,
                  color: "#92400e",
                }}
              >
                {r.suggested_qty.toFixed(0)}
              </span>
              {r.units_per_box ? (
                <span
                  style={{ fontSize: 10, color: "#6b6860", marginLeft: 6 }}
                  title={`Rounded up to a multiple of ${r.units_per_box} (box size)`}
                >
                  ×{r.units_per_box}
                </span>
              ) : (
                <span
                  style={{ fontSize: 10, color: "#d97706", marginLeft: 6 }}
                  title="No box size on file — qty not box-rounded"
                >
                  ⚠ no box
                </span>
              )}
            </>
          )}
        </td>
      </tr>
    );
  };

  const createDraftPOFromDemand = async () => {
    if (!demandDraftSupplier || selectedDemandIds.size === 0) return;
    setDemandDraftSaving(true);
    const supabase = createClient();

    // Canonical path: create_purchase_order handles po_number sequencing, the
    // driver task, the notification, the audit event AND the PRD-1 blocked-product
    // guardrail atomically. Never insert into purchase_orders directly from here.
    const selected = demandRows.filter((r) =>
      selectedDemandIds.has(r.boonz_product_id),
    );
    const { data, error } = await supabase.rpc("create_purchase_order", {
      p_po_id: genPoId(),
      p_supplier_id: demandDraftSupplier,
      p_purchase_date: getDubaiDate(),
      p_lines: selected.map((r) => ({
        boonz_product_id: r.boonz_product_id,
        ordered_qty: r.suggested_qty,
      })),
      p_force_driver_task: true,
    });

    if (error) {
      setDemandDraftSaving(false);
      alert(`Failed to create draft PO: ${error.message}`);
      return;
    }

    setDemandDraftSaving(false);
    setSelectedDemandIds(new Set());
    setDemandDraftSupplier("");
    const poNumber = (data as { po_number?: number } | null)?.po_number ?? "";
    setDemandToast(
      `✓ Draft PO #${poNumber} created with ${selected.length} line${selected.length !== 1 ? "s" : ""}`,
    );
    setTimeout(() => setDemandToast(null), 4000);
    // Refresh orders list
    setLoading(true);
    await fetchOrders();
  };

  const addNewLine = () => {
    setNewLines((prev) => [
      ...prev,
      {
        boonz_product_id: "",
        product_name: "",
        ordered_qty: 1,
        price_per_unit_aed: 0,
        expiry_date: "",
      },
    ]);
  };

  const updateNewLine = (
    idx: number,
    field: string,
    value: string | number,
  ) => {
    setNewLines((prev) =>
      prev.map((l, i) => (i === idx ? { ...l, [field]: value } : l)),
    );
  };

  const removeNewLine = (idx: number) => {
    setNewLines((prev) => prev.filter((_, i) => i !== idx));
  };

  // Canonical path: create_purchase_order assigns po_number from po_number_seq,
  // creates the driver task + notification + audit event, and enforces the PRD-1
  // blocked-product guardrail — all in one transaction. The previous hand-rolled
  // direct insert into purchase_orders + driver_tasks (and client-side po_number
  // computation, which was race-prone) is retired; never write the table directly.
  const saveNewPO = async () => {
    if (!newSupplier || newLines.length === 0) return;
    setNewSaving(true);
    const supabase = createClient();

    const { error } = await supabase.rpc("create_purchase_order", {
      p_po_id: genPoId(),
      p_supplier_id: newSupplier,
      p_purchase_date: newDate,
      p_lines: newLines.map((l) => ({
        boonz_product_id: l.boonz_product_id,
        ordered_qty: l.ordered_qty,
        price_per_unit_aed: l.price_per_unit_aed || null,
        expiry_date: l.expiry_date || null,
      })),
      p_force_driver_task: true,
    });
    if (error) {
      setNewSaving(false);
      alert(`Failed to save PO: ${error.message}`);
      return;
    }

    setNewSaving(false);
    setShowNewPO(false);
    setLoading(true);
    await fetchOrders();
  };

  // 2026-04-23: The inline "handleReceive" drawer receive flow was retired.
  // It was broken (no expiry input, no received_qty write, no FIFO batch
  // handling) and receiving now delegates to the canonical
  // /field/receiving/[poId] flow via a link in the drawer footer.
  // The receiveQtys / receiveLocations state and the handleReceive function
  // were removed at that time.

  const [additionToast, setAdditionToast] = useState<string | null>(null);

  // Issue #9: receive routes through receive_purchase_order_addition RPC.
  // Operator can pick the receiving warehouse instead of hardcoded WH_CENTRAL.
  const handleReceiveAddition = async (addition: POAddition) => {
    setReceivingAddition(addition.addition_id);
    const supabase = createClient();

    // Prompt operator to pick warehouse (default WH_CENTRAL)
    const choice = window.prompt(
      `Receive ${addition.qty}x ${addition.boonz_products.boonz_product_name} into which warehouse?\nType: WH_CENTRAL, WH_MM, or WH_MCC`,
      "WH_CENTRAL",
    );
    if (!choice) {
      setReceivingAddition(null);
      return;
    }
    const WH_CODE_TO_ID: Record<string, string> = {
      WH_CENTRAL: "4bebef68-9e36-4a5c-9c2c-142f8dbdae85",
      WH_MM: "0aef9ccf-32ad-4545-8413-29bebd931d0b",
      WH_MCC: "4fcfb52c-271f-4aa7-a373-3495e3271cd3",
    };
    const warehouseId = WH_CODE_TO_ID[choice.trim().toUpperCase()];
    if (!warehouseId) {
      alert(`Unknown warehouse "${choice}". Use WH_CENTRAL / WH_MM / WH_MCC.`);
      setReceivingAddition(null);
      return;
    }

    // Article 1 / Rule S1: canonical RPC (was direct .insert() — bypassed audit).
    const { data, error } = await supabase.rpc(
      "receive_purchase_order_addition",
      {
        p_addition_id: addition.addition_id,
        p_warehouse_id: warehouseId,
        p_expiry: addition.expiry_date ?? null,
        p_batch_id: null, // RPC formats default batch_id
      },
    );

    if (error) {
      alert(`Receive failed: ${error.message}`);
      setReceivingAddition(null);
      return;
    }
    if (data?.status === "already_received") {
      setAdditionToast("Already received — no duplicate created");
      setTimeout(() => setAdditionToast(null), 3000);
      setReceivingAddition(null);
      return;
    }

    // Optimistic: mark as received in local state
    setPoAdditions((prev) =>
      prev.map((a) =>
        a.addition_id === addition.addition_id
          ? { ...a, status: "received" }
          : a,
      ),
    );
    setPendingAdditionsCount((prev) => Math.max(0, prev - 1));
    setReceivingAddition(null);
    setAdditionToast(
      `✓ ${addition.qty}x ${addition.boonz_products.boonz_product_name} received into ${choice.trim().toUpperCase()}`,
    );
    setTimeout(() => setAdditionToast(null), 4000);
  };

  const displayed = useMemo(() => {
    let result = allOrders;
    if (tab === "pending") result = result.filter((o) => !o.received_date);
    if (search) {
      const q = search.toLowerCase();
      result = result.filter(
        (o) =>
          o.supplier_name.toLowerCase().includes(q) ||
          o.po_id.toLowerCase().includes(q),
      );
    }
    return result;
  }, [allOrders, tab, search]);

  const pendingCount = useMemo(
    () => allOrders.filter((o) => !o.received_date).length,
    [allOrders],
  );

  return (
    <div className="p-8 max-w-7xl">
      {/* Demand toast */}
      {demandToast && (
        <div
          style={{
            position: "fixed",
            top: 24,
            left: "50%",
            transform: "translateX(-50%)",
            zIndex: 200,
            background: "#24544a",
            color: "white",
            padding: "10px 20px",
            borderRadius: 8,
            fontSize: 13,
            fontWeight: 600,
            boxShadow: "0 4px 12px rgba(0,0,0,0.15)",
          }}
        >
          {demandToast}
        </div>
      )}
      {/* Addition toast */}
      {additionToast && (
        <div
          style={{
            position: "fixed",
            top: 24,
            left: "50%",
            transform: "translateX(-50%)",
            zIndex: 200,
            background: "#166534",
            color: "white",
            padding: "10px 20px",
            borderRadius: 8,
            fontSize: 13,
            fontWeight: 600,
            boxShadow: "0 4px 12px rgba(0,0,0,0.15)",
          }}
        >
          {additionToast}
        </div>
      )}
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
            Procurement
          </h1>
          <p style={{ color: "#6b6860", fontSize: 14, marginTop: 4 }}>
            {loading
              ? "Loading…"
              : `${allOrders.length} purchase orders · ${pendingCount} pending`}
          </p>
        </div>
        <button
          onClick={openNewPO}
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
          + New PO
        </button>
      </div>

      {/* Tab bar + search */}
      <div
        className="flex items-center gap-3 flex-wrap mb-6"
        style={{ borderBottom: "1px solid #e8e4de", paddingBottom: 16 }}
      >
        {(["pending", "all", "demand"] as const).map((t) => (
          <button
            key={t}
            onClick={() => handleTabChange(t)}
            style={{
              border: "1px solid #e8e4de",
              borderRadius: 8,
              padding: "7px 14px",
              fontSize: 13,
              fontWeight: tab === t ? 600 : 400,
              background:
                tab === t ? (t === "demand" ? "#24544a" : "#0a0a0a") : "white",
              color: tab === t ? "white" : "#6b6860",
              cursor: "pointer",
            }}
          >
            {t === "pending"
              ? `Pending (${pendingCount})`
              : t === "all"
                ? "All Orders"
                : "⚡ Demand"}
          </button>
        ))}
        {tab !== "demand" && (
          <>
            <input
              type="text"
              placeholder="Search supplier or PO ID…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              style={{
                border: "1px solid #e8e4de",
                borderRadius: 8,
                padding: "7px 12px",
                fontSize: 14,
                width: 260,
                outline: "none",
                color: "#0a0a0a",
                background: "white",
              }}
            />
            {!loading && (
              <span
                style={{ marginLeft: "auto", fontSize: 13, color: "#6b6860" }}
              >
                {displayed.length} result{displayed.length !== 1 ? "s" : ""}
              </span>
            )}
          </>
        )}
        {tab === "demand" && !demandLoading && demandLoaded && (
          <span style={{ marginLeft: "auto", fontSize: 13, color: "#6b6860" }}>
            {demandRows.length} SKU{demandRows.length !== 1 ? "s" : ""} need
            restocking
          </span>
        )}
        {tab === "demand" && (
          <button
            onClick={() => loadDemand(demandSource)}
            disabled={demandLoading}
            style={{
              marginLeft: tab === "demand" ? 0 : "auto",
              border: "1px solid #e8e4de",
              borderRadius: 8,
              padding: "7px 14px",
              fontSize: 12,
              fontWeight: 500,
              background: "white",
              color: "#6b6860",
              cursor: demandLoading ? "not-allowed" : "pointer",
            }}
          >
            {demandLoading ? "Loading…" : "↻ Refresh"}
          </button>
        )}
      </div>

      {pendingAdditionsCount > 0 && (
        <div
          style={{
            background: "#fef9ee",
            border: "1px solid #e1b460",
            borderRadius: 8,
            padding: "10px 14px",
            fontSize: 13,
            color: "#92400e",
            marginBottom: 14,
          }}
        >
          {"\u26A0"} {pendingAdditionsCount} field addition
          {pendingAdditionsCount > 1 ? "s" : ""} pending warehouse receive
          &mdash; review in PO detail
        </div>
      )}

      {/* ── Demand Tab View ─────────────────────────────────────────────────── */}
      {tab === "demand" && (
        <>
          {/* Sourcing toggle — Boonz-sourced (what we procure) vs venue/VOX-sourced
              (supplied by the venue team). Helps separate refill planning. */}
          <div
            style={{
              display: "inline-flex",
              border: "1px solid #e8e4de",
              borderRadius: 8,
              overflow: "hidden",
              marginBottom: 12,
            }}
          >
            {(
              [
                { key: "boonz", label: "Boonz Sourced" },
                { key: "venue_team", label: "VOX Sourced" },
              ] as { key: DemandSource; label: string }[]
            ).map((opt) => {
              const active = demandSource === opt.key;
              return (
                <button
                  key={opt.key}
                  onClick={() => handleDemandSourceChange(opt.key)}
                  disabled={demandLoading}
                  style={{
                    border: "none",
                    padding: "7px 16px",
                    fontSize: 12,
                    fontWeight: 600,
                    cursor: demandLoading ? "not-allowed" : "pointer",
                    background: active ? "#14532d" : "white",
                    color: active ? "white" : "#6b6860",
                  }}
                >
                  {opt.label}
                </button>
              );
            })}
          </div>

          <div
            style={{
              background: demandSource === "boonz" ? "#f0fdf4" : "#eff6ff",
              border:
                demandSource === "boonz"
                  ? "1px solid #bbf7d0"
                  : "1px solid #bfdbfe",
              borderRadius: 8,
              padding: "10px 14px",
              fontSize: 13,
              color: demandSource === "boonz" ? "#065f46" : "#1e40af",
              marginBottom: 14,
            }}
          >
            {demandSource === "boonz"
              ? "Boonz-sourced demand · last 14 days of sales · VOX-sourced products excluded · suggested qty includes 10% buffer"
              : "VOX-sourced demand · supplied by the venue team, not procured by Boonz · shown for refill planning only"}
          </div>

          {/* PRD-2 sub-tab switcher: Pod demand (pod-product level) vs Boonz SKU. */}
          <div
            style={{
              display: "inline-flex",
              gap: 6,
              marginBottom: 14,
              marginLeft: 12,
            }}
          >
            {(
              [
                { key: "pod", label: "Pod demand" },
                { key: "sku", label: "Boonz SKU" },
              ] as { key: DemandView; label: string }[]
            ).map((opt) => {
              const active = demandView === opt.key;
              return (
                <button
                  key={opt.key}
                  onClick={() => setDemandView(opt.key)}
                  style={{
                    border: "1px solid #e8e4de",
                    background: active ? "#24544a" : "white",
                    color: active ? "white" : "#6b6860",
                    borderRadius: 8,
                    padding: "6px 16px",
                    fontSize: 12,
                    fontWeight: 600,
                    cursor: "pointer",
                  }}
                >
                  {opt.label}
                </button>
              );
            })}
          </div>

          {demandView === "pod" ? (
            /* ── POD DEMAND (PRD-3 get_procurement_demand_pod) ────────────── */
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
                      "Pod product(s)",
                      "Category",
                      "14d Sales",
                      "Velocity/day",
                      "Ctx",
                      "Forecast 14d",
                      "Variants",
                    ].map((h) => (
                      <th
                        key={h}
                        className="text-left px-3 py-3"
                        style={{
                          fontSize: 11,
                          fontWeight: 500,
                          letterSpacing: "0.06em",
                          textTransform: "uppercase",
                          color: "#6b6860",
                          whiteSpace: "nowrap",
                        }}
                      >
                        {h}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {podLoading ? (
                    <tr>
                      <td
                        colSpan={7}
                        className="px-4 py-10 text-center"
                        style={{ color: "#6b6860" }}
                      >
                        Loading pod demand…
                      </td>
                    </tr>
                  ) : podRows.length === 0 ? (
                    <tr>
                      <td
                        colSpan={7}
                        className="px-4 py-10 text-center"
                        style={{ color: "#6b6860" }}
                      >
                        No pod demand for this source.
                      </td>
                    </tr>
                  ) : (
                    podRows.map((p) => {
                      const expanded = expandedPodId === p.pod_product_id;
                      const ctxOff = Math.abs(p.ctx_multiplier - 1) > 0.001;
                      return (
                        <Fragment key={p.pod_product_id}>
                          <tr
                            style={{
                              borderBottom: "1px solid #f5f2ee",
                              cursor: "pointer",
                            }}
                            onClick={() =>
                              setExpandedPodId(
                                expanded ? null : p.pod_product_id,
                              )
                            }
                          >
                            <td
                              className="px-3 py-3"
                              style={{
                                fontWeight: 600,
                                color: "#24544a",
                                fontSize: 13,
                              }}
                            >
                              <span style={{ marginRight: 6, opacity: 0.5 }}>
                                {expanded ? "▾" : "▸"}
                              </span>
                              {p.pod_product_name}
                            </td>
                            <td
                              className="px-3 py-3"
                              style={{ color: "#6b6860", fontSize: 12 }}
                            >
                              {p.product_category ?? "—"}
                            </td>
                            <td className="px-3 py-3" style={{ fontSize: 13 }}>
                              {p.sales_14d.toFixed(0)}
                            </td>
                            <td
                              className="px-3 py-3"
                              style={{ fontSize: 13, color: "#6b6860" }}
                            >
                              {p.velocity_per_day.toFixed(1)}
                            </td>
                            <td className="px-3 py-3">
                              {ctxOff ? (
                                <span
                                  title="Context factor applied (demand_context_factors)"
                                  style={{
                                    background:
                                      p.ctx_multiplier > 1
                                        ? "#ecfdf5"
                                        : "#fef2f2",
                                    border:
                                      p.ctx_multiplier > 1
                                        ? "1px solid #6ee7b7"
                                        : "1px solid #fca5a5",
                                    color:
                                      p.ctx_multiplier > 1
                                        ? "#047857"
                                        : "#b91c1c",
                                    borderRadius: 6,
                                    padding: "1px 7px",
                                    fontSize: 11,
                                    fontWeight: 700,
                                  }}
                                >
                                  ×{p.ctx_multiplier.toFixed(2)}
                                </span>
                              ) : (
                                <span
                                  style={{ color: "#9ca3af", fontSize: 12 }}
                                >
                                  ×1.0
                                </span>
                              )}
                            </td>
                            <td
                              className="px-3 py-3"
                              style={{ fontSize: 13, fontWeight: 700 }}
                            >
                              {p.forecast_demand.toFixed(0)}
                            </td>
                            <td
                              className="px-3 py-3"
                              style={{ color: "#6b6860", fontSize: 12 }}
                            >
                              {p.mapped_variant_count}
                            </td>
                          </tr>
                          {expanded && (
                            <tr style={{ background: "#faf9f7" }}>
                              <td colSpan={7} className="px-6 py-2">
                                <div style={{ fontSize: 12 }}>
                                  {(p.pod_breakdown ?? []).map((b) => (
                                    <div
                                      key={b.boonz_product_id}
                                      style={{
                                        display: "flex",
                                        gap: 8,
                                        padding: "2px 0",
                                        color: b.block_reason
                                          ? "#b91c1c"
                                          : "#0a0a0a",
                                        textDecoration: b.block_reason
                                          ? "line-through"
                                          : undefined,
                                      }}
                                    >
                                      <span style={{ minWidth: 220 }}>
                                        {b.boonz_product_name}
                                      </span>
                                      <span style={{ color: "#6b6860" }}>
                                        mix{" "}
                                        {b.mix_weight != null
                                          ? `${(b.mix_weight * 100).toFixed(0)}%`
                                          : "—"}
                                      </span>
                                      <span style={{ color: "#6b6860" }}>
                                        ≈ {b.attributed_14d} u
                                      </span>
                                      <span style={{ color: "#9ca3af" }}>
                                        {b.source_of_supply}
                                      </span>
                                      {b.block_reason && (
                                        <span style={{ fontWeight: 600 }}>
                                          🚫 {b.block_reason}
                                        </span>
                                      )}
                                    </div>
                                  ))}
                                </div>
                              </td>
                            </tr>
                          )}
                        </Fragment>
                      );
                    })
                  )}
                </tbody>
              </table>
            </div>
          ) : (
            /* ── BOONZ SKU (supplier-grouped) ─────────────────────────────── */
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
                    <th className="px-4 py-3" style={{ width: 36 }}>
                      <input
                        type="checkbox"
                        checked={
                          selectedDemandIds.size > 0 &&
                          selectedDemandIds.size ===
                            demandRows.filter(
                              (r) => !blockedIds.has(r.boonz_product_id),
                            ).length
                        }
                        onChange={toggleAllDemand}
                        style={{ cursor: "pointer" }}
                      />
                    </th>
                    {(
                      [
                        { h: "Product", key: "boonz_product_name" },
                        { h: "Category", key: "product_category" },
                        { h: "14d Sales", key: "sales_14d" },
                        { h: "Forecast", key: "forecast_demand" },
                        { h: "WH Stock", key: "wh_stock" },
                        { h: "On Order", key: "on_order" },
                        { h: "Gap", key: "gap" },
                        { h: "Suggested Qty", key: "suggested_qty" },
                      ] as { h: string; key: DemandSortKey }[]
                    ).map(({ h, key }) => {
                      const active = demandSort.key === key;
                      return (
                        <th
                          key={h}
                          onClick={() => handleDemandSort(key)}
                          className="text-left px-3 py-3"
                          style={{
                            fontSize: 11,
                            fontWeight: 500,
                            letterSpacing: "0.06em",
                            textTransform: "uppercase",
                            color: active ? "#14532d" : "#6b6860",
                            cursor: "pointer",
                            userSelect: "none",
                            whiteSpace: "nowrap",
                          }}
                          title="Sort"
                        >
                          {h}
                          <span
                            style={{
                              marginLeft: 4,
                              opacity: active ? 1 : 0.25,
                            }}
                          >
                            {active
                              ? demandSort.dir === "asc"
                                ? "↑"
                                : "↓"
                              : "↕"}
                          </span>
                        </th>
                      );
                    })}
                  </tr>
                </thead>
                <tbody>
                  {demandLoading ? (
                    Array.from({ length: 8 }).map((_, i) => (
                      <tr key={i} style={{ borderBottom: "1px solid #f5f2ee" }}>
                        {[36, 200, 100, 80, 80, 80, 70, 80].map((w, j) => (
                          <td key={j} className="px-3 py-3">
                            <div
                              className="animate-pulse rounded"
                              style={{
                                height: 13,
                                width: w,
                                background: "#f0ede8",
                              }}
                            />
                          </td>
                        ))}
                      </tr>
                    ))
                  ) : demandRows.length === 0 ? (
                    <tr>
                      <td
                        colSpan={9}
                        className="px-4 py-10 text-center"
                        style={{ color: "#6b6860" }}
                      >
                        No procurement demand detected — all products are
                        sufficiently stocked.
                      </td>
                    </tr>
                  ) : (
                    <>
                      {/* Unassigned — pinned top, forces supplier assignment */}
                      {skuGroups.unassigned.length > 0 && (
                        <>
                          <tr style={{ background: "#fff7ed" }}>
                            <td
                              colSpan={9}
                              className="px-4 py-2"
                              style={{
                                fontSize: 12,
                                fontWeight: 700,
                                color: "#9a3412",
                              }}
                            >
                              Unassigned · {skuGroups.unassigned.length} product
                              {skuGroups.unassigned.length !== 1
                                ? "s"
                                : ""}{" "}
                              with demand but no supplier — set one to build a
                              basket
                            </td>
                          </tr>
                          {skuGroups.unassigned.map((r) =>
                            renderSkuRow(r, "unassigned"),
                          )}
                        </>
                      )}
                      {/* Supplier baskets */}
                      {skuGroups.suppliers.map((g) => (
                        <Fragment key={g.supplier_id}>
                          <tr style={{ background: "#f0fdf4" }}>
                            <td
                              colSpan={9}
                              className="px-4 py-2"
                              style={{
                                fontSize: 12,
                                fontWeight: 700,
                                color: "#14532d",
                              }}
                            >
                              {g.supplier_name}
                            </td>
                          </tr>
                          {g.rows.map((r) => renderSkuRow(r, "normal"))}
                          <tr
                            style={{
                              background: "#fafafa",
                              borderBottom: "2px solid #e8e4de",
                            }}
                          >
                            <td
                              colSpan={9}
                              className="px-4 py-2"
                              style={{
                                fontSize: 11,
                                color: "#6b6860",
                                textAlign: "right",
                              }}
                            >
                              Basket: {g.totalLines} line
                              {g.totalLines !== 1 ? "s" : ""} ·{" "}
                              {g.totalUnits.toFixed(0)} units
                            </td>
                          </tr>
                        </Fragment>
                      ))}
                      {/* Blocked — collapsed, struck-through (PRD-1) */}
                      {skuGroups.blocked.length > 0 && (
                        <>
                          <tr
                            style={{ background: "#fef2f2", cursor: "pointer" }}
                            onClick={() => setCollapsedBlocked((v) => !v)}
                          >
                            <td
                              colSpan={9}
                              className="px-4 py-2"
                              style={{
                                fontSize: 12,
                                fontWeight: 700,
                                color: "#b91c1c",
                              }}
                            >
                              {collapsedBlocked ? "▸" : "▾"} Blocked ·{" "}
                              {skuGroups.blocked.length} product
                              {skuGroups.blocked.length !== 1 ? "s" : ""} that
                              can never be ordered (decommissioned /
                              never-order)
                            </td>
                          </tr>
                          {!collapsedBlocked &&
                            skuGroups.blocked.map((r) =>
                              renderSkuRow(r, "blocked"),
                            )}
                        </>
                      )}
                    </>
                  )}
                </tbody>
              </table>
            </div>
          )}

          {/* Create Draft PO bar — only meaningful in the SKU view */}
          {demandView === "sku" && selectedDemandIds.size > 0 && (
            <div
              style={{
                position: "fixed",
                bottom: 24,
                left: "50%",
                transform: "translateX(-50%)",
                background: "white",
                border: "1px solid #e8e4de",
                borderRadius: 12,
                boxShadow: "0 8px 32px rgba(0,0,0,0.12)",
                padding: "14px 20px",
                display: "flex",
                alignItems: "center",
                gap: 12,
                zIndex: 30,
                minWidth: 480,
              }}
            >
              <span
                style={{
                  fontSize: 13,
                  fontWeight: 600,
                  color: "#0a0a0a",
                  whiteSpace: "nowrap",
                }}
              >
                {selectedDemandIds.size} product
                {selectedDemandIds.size !== 1 ? "s" : ""} selected
              </span>
              <select
                value={demandDraftSupplier}
                onChange={(e) => setDemandDraftSupplier(e.target.value)}
                style={{
                  flex: 1,
                  border: "1px solid #e8e4de",
                  borderRadius: 8,
                  padding: "7px 10px",
                  fontSize: 13,
                  color: "#0a0a0a",
                  background: "white",
                }}
              >
                <option value="">Select supplier…</option>
                {suppliers.map((s) => (
                  <option key={s.supplier_id} value={s.supplier_id}>
                    {s.supplier_name}
                  </option>
                ))}
              </select>
              <button
                onClick={createDraftPOFromDemand}
                disabled={demandDraftSaving || !demandDraftSupplier}
                style={{
                  background:
                    demandDraftSaving || !demandDraftSupplier
                      ? "#e8e4de"
                      : "#24544a",
                  color:
                    demandDraftSaving || !demandDraftSupplier
                      ? "#6b6860"
                      : "white",
                  border: "none",
                  borderRadius: 8,
                  padding: "8px 18px",
                  fontSize: 13,
                  fontWeight: 600,
                  cursor:
                    demandDraftSaving || !demandDraftSupplier
                      ? "not-allowed"
                      : "pointer",
                  whiteSpace: "nowrap",
                }}
              >
                {demandDraftSaving ? "Creating…" : "Create Draft PO →"}
              </button>
              <button
                onClick={() => setSelectedDemandIds(new Set())}
                style={{
                  background: "none",
                  border: "none",
                  color: "#6b6860",
                  cursor: "pointer",
                  fontSize: 18,
                  lineHeight: 1,
                  padding: 2,
                }}
              >
                ✕
              </button>
            </div>
          )}

          {/* Set-supplier modal (Unassigned → supplier_products, RLS-gated) */}
          {setSupplierFor && (
            <div
              style={{
                position: "fixed",
                inset: 0,
                background: "rgba(0,0,0,0.35)",
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                zIndex: 50,
              }}
              onClick={() => !setSupplierSaving && setSetSupplierFor(null)}
            >
              <div
                onClick={(e) => e.stopPropagation()}
                style={{
                  background: "white",
                  borderRadius: 12,
                  padding: 24,
                  width: 420,
                  maxWidth: "90vw",
                  boxShadow: "0 12px 48px rgba(0,0,0,0.18)",
                }}
              >
                <div style={{ fontSize: 15, fontWeight: 700, marginBottom: 4 }}>
                  Set preferred supplier
                </div>
                <div
                  style={{ fontSize: 13, color: "#6b6860", marginBottom: 16 }}
                >
                  {setSupplierFor.boonz_product_name}
                </div>
                <select
                  value={setSupplierChoice}
                  onChange={(e) => setSetSupplierChoice(e.target.value)}
                  style={{
                    width: "100%",
                    border: "1px solid #e8e4de",
                    borderRadius: 8,
                    padding: "9px 10px",
                    fontSize: 13,
                    marginBottom: 18,
                  }}
                >
                  <option value="">Select supplier…</option>
                  {suppliers.map((s) => (
                    <option key={s.supplier_id} value={s.supplier_id}>
                      {s.supplier_name}
                    </option>
                  ))}
                </select>
                <div
                  style={{
                    display: "flex",
                    justifyContent: "flex-end",
                    gap: 8,
                  }}
                >
                  <button
                    onClick={() => setSetSupplierFor(null)}
                    disabled={setSupplierSaving}
                    style={{
                      background: "white",
                      border: "1px solid #e8e4de",
                      borderRadius: 8,
                      padding: "8px 16px",
                      fontSize: 13,
                      cursor: "pointer",
                      color: "#6b6860",
                    }}
                  >
                    Cancel
                  </button>
                  <button
                    onClick={submitSetSupplier}
                    disabled={setSupplierSaving || !setSupplierChoice}
                    style={{
                      background:
                        setSupplierSaving || !setSupplierChoice
                          ? "#e8e4de"
                          : "#24544a",
                      color:
                        setSupplierSaving || !setSupplierChoice
                          ? "#6b6860"
                          : "white",
                      border: "none",
                      borderRadius: 8,
                      padding: "8px 18px",
                      fontSize: 13,
                      fontWeight: 600,
                      cursor:
                        setSupplierSaving || !setSupplierChoice
                          ? "not-allowed"
                          : "pointer",
                    }}
                  >
                    {setSupplierSaving ? "Saving…" : "Assign supplier"}
                  </button>
                </div>
              </div>
            </div>
          )}
        </>
      )}

      {/* Table */}
      {tab !== "demand" && (
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
                  "PO ID",
                  "Supplier",
                  "Order Date",
                  "Lines",
                  "Total Units",
                  "Status",
                  "",
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
                    {[120, 160, 100, 60, 80, 80, 80].map((w, j) => (
                      <td key={j} className="px-4 py-3">
                        <div
                          className="animate-pulse rounded"
                          style={{
                            height: 14,
                            width: w,
                            background: "#f0ede8",
                          }}
                        />
                      </td>
                    ))}
                  </tr>
                ))
              ) : displayed.length === 0 ? (
                <tr>
                  <td
                    colSpan={7}
                    className="px-4 py-10 text-center"
                    style={{ color: "#6b6860" }}
                  >
                    {tab === "pending"
                      ? "No pending purchase orders."
                      : "No purchase orders found."}
                  </td>
                </tr>
              ) : (
                displayed.map((o) => {
                  const isPending = !o.received_date;
                  return (
                    <tr
                      key={o.po_id}
                      style={{
                        borderBottom: "1px solid #f5f2ee",
                        cursor: "pointer",
                        background:
                          selectedPO?.po_id === o.po_id ? "#f0fdf4" : undefined,
                      }}
                      onClick={() => openPODrawer(o)}
                      onMouseEnter={(e) => {
                        if (selectedPO?.po_id !== o.po_id)
                          (
                            e.currentTarget as HTMLTableRowElement
                          ).style.background = "#faf9f7";
                      }}
                      onMouseLeave={(e) => {
                        if (selectedPO?.po_id !== o.po_id)
                          (
                            e.currentTarget as HTMLTableRowElement
                          ).style.background =
                            selectedPO?.po_id === o.po_id
                              ? "#f0fdf4"
                              : "transparent";
                      }}
                    >
                      <td
                        className="px-4 py-3"
                        style={{
                          fontFamily: "monospace",
                          fontSize: 12,
                          color: "#6b6860",
                        }}
                      >
                        {o.po_id.slice(0, 8)}…
                      </td>
                      <td
                        className="px-4 py-3"
                        style={{ fontWeight: 600, color: "#24544a" }}
                      >
                        {o.supplier_name}
                      </td>
                      <td className="px-4 py-3" style={{ color: "#0a0a0a" }}>
                        {formatDate(o.purchase_date)}
                      </td>
                      <td className="px-4 py-3" style={{ color: "#0a0a0a" }}>
                        {o.line_count}
                      </td>
                      <td
                        className="px-4 py-3"
                        style={{ fontWeight: 600, color: "#0a0a0a" }}
                      >
                        {o.total_ordered.toLocaleString()}
                      </td>
                      <td className="px-4 py-3">
                        <span
                          style={{
                            display: "inline-block",
                            padding: "2px 10px",
                            borderRadius: 20,
                            fontSize: 11,
                            fontWeight: 600,
                            background: isPending ? "#fef9ee" : "#f0fdf4",
                            color: isPending ? "#b45309" : "#065f46",
                          }}
                        >
                          {isPending
                            ? "Pending"
                            : `Received ${formatDate(o.received_date)}`}
                        </span>
                      </td>
                      <td className="px-4 py-3">
                        <button
                          onClick={(e) => {
                            e.stopPropagation();
                            openPODrawer(o);
                          }}
                          style={{
                            fontSize: 12,
                            fontWeight: 600,
                            color: "#24544a",
                            background: "none",
                            border: "1px solid #24544a",
                            borderRadius: 6,
                            padding: "4px 10px",
                            cursor: "pointer",
                            whiteSpace: "nowrap",
                          }}
                        >
                          View →
                        </button>
                      </td>
                    </tr>
                  );
                })
              )}
            </tbody>
          </table>
        </div>
      )}

      {/* ── PO Detail Drawer ───────────────────────────────────────────────── */}
      {selectedPO && (
        <>
          <div
            onClick={() => {
              setSelectedPO(null);
            }}
            style={{
              position: "fixed",
              inset: 0,
              background: "rgba(0,0,0,0.25)",
              zIndex: 40,
            }}
          />
          <div
            style={{
              position: "fixed",
              top: 0,
              right: 0,
              bottom: 0,
              width: 560,
              maxWidth: "100vw",
              background: "white",
              zIndex: 50,
              boxShadow: "-4px 0 24px rgba(0,0,0,0.08)",
              display: "flex",
              flexDirection: "column",
              fontFamily: "'Plus Jakarta Sans', sans-serif",
            }}
          >
            {/* Header */}
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
                    fontSize: 18,
                    fontWeight: 800,
                    color: "#0a0a0a",
                    margin: 0,
                    letterSpacing: "-0.02em",
                  }}
                >
                  {selectedPO.supplier_name}
                </h2>
                <p style={{ fontSize: 12, color: "#6b6860", marginTop: 4 }}>
                  {poLines[0]?.po_number
                    ? poLines[0].po_number
                    : `PO ${selectedPO.po_id.slice(0, 8)}…`}{" "}
                  · {formatDate(selectedPO.purchase_date)}
                </p>
              </div>
              <button
                onClick={() => {
                  setSelectedPO(null);
                }}
                style={{
                  background: "none",
                  border: "none",
                  fontSize: 22,
                  color: "#6b6860",
                  cursor: "pointer",
                  padding: 4,
                  lineHeight: 1,
                }}
              >
                ✕
              </button>
            </div>

            {/* Content */}
            <div style={{ flex: 1, overflow: "auto", padding: "20px 24px" }}>
              <div
                style={{
                  fontSize: 10,
                  fontWeight: 500,
                  letterSpacing: "0.1em",
                  textTransform: "uppercase",
                  color: "#6b6860",
                  marginBottom: 12,
                }}
              >
                Line Items
              </div>

              {poLoading ? (
                <div
                  style={{ padding: 40, textAlign: "center", color: "#6b6860" }}
                >
                  Loading…
                </div>
              ) : (
                <table className="w-full text-sm" style={{ fontSize: 13 }}>
                  <thead>
                    <tr style={{ borderBottom: "1px solid #e8e4de" }}>
                      {[
                        "Product",
                        "Qty",
                        "Price",
                        "Expiry",
                        "Status",
                        "WH Loc",
                        "Actions",
                      ].map((h) => (
                        <th
                          key={h}
                          className="text-left py-2 px-2"
                          style={{
                            fontSize: 10,
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
                    {poLines.map((l) => {
                      // PRD-002: per-line lock + Cancel gating.
                      const isReceived =
                        (l.received_qty ?? 0) > 0 ||
                        l.purchase_outcome === "received";
                      const isCancelled =
                        l.purchase_outcome === "not_purchased";
                      const canCancelNow =
                        !isReceived &&
                        !isCancelled &&
                        !!userRole &&
                        EDIT_ROLES.has(userRole);
                      const showLock =
                        isReceived && !!userRole && userRole !== "superadmin";
                      return (
                        <tr
                          key={l.po_line_id}
                          style={{
                            borderBottom: "1px solid #f5f2ee",
                            textDecoration: isCancelled
                              ? "line-through"
                              : undefined,
                            color: isCancelled ? "#a3a39a" : undefined,
                          }}
                        >
                          <td
                            className="py-2 px-2"
                            style={{ fontWeight: 600, color: "#24544a" }}
                          >
                            {l.boonz_products.boonz_product_name}
                          </td>
                          <td
                            className="py-2 px-2"
                            style={{ color: "#0a0a0a" }}
                          >
                            {l.ordered_qty}
                          </td>
                          <td
                            className="py-2 px-2"
                            style={{ color: "#6b6860" }}
                          >
                            {l.price_per_unit_aed
                              ? `${l.price_per_unit_aed.toFixed(2)} AED`
                              : "—"}
                          </td>
                          <td
                            className="py-2 px-2"
                            style={{ color: "#6b6860" }}
                          >
                            {l.expiry_date ? formatDate(l.expiry_date) : "—"}
                          </td>
                          <td className="py-2 px-2">
                            {l.received_date ? (
                              <span
                                style={{
                                  fontSize: 11,
                                  color: "#065f46",
                                  fontWeight: 600,
                                }}
                              >
                                ✓ Received
                              </span>
                            ) : (
                              <span
                                style={{
                                  fontSize: 11,
                                  color: "#92400e",
                                  fontStyle: "italic",
                                }}
                              >
                                Pending
                              </span>
                            )}
                          </td>
                          <td className="py-2 px-2">
                            <span style={{ fontSize: 11, color: "#6b6860" }}>
                              —
                            </span>
                          </td>
                          <td className="py-2 px-2">
                            <div
                              style={{
                                display: "flex",
                                alignItems: "center",
                                gap: 6,
                              }}
                            >
                              {showLock && (
                                <span
                                  title="Received — only superadmin can edit"
                                  style={{ fontSize: 13 }}
                                >
                                  🔒
                                </span>
                              )}
                              {isCancelled && (
                                <span
                                  style={{
                                    fontSize: 10,
                                    fontWeight: 600,
                                    color: "#6b6860",
                                    background: "#e8e4de",
                                    borderRadius: 999,
                                    padding: "2px 6px",
                                  }}
                                >
                                  Not received
                                </span>
                              )}
                              {canCancelNow && (
                                <button
                                  onClick={() => setCancellingLine(l)}
                                  style={{
                                    fontSize: 11,
                                    fontWeight: 600,
                                    color: "#b91c1c",
                                    border: "1px solid #fca5a5",
                                    borderRadius: 6,
                                    padding: "2px 8px",
                                    background: "transparent",
                                  }}
                                >
                                  Cancel
                                </button>
                              )}
                            </div>
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              )}

              {/* Total */}
              {!poLoading && poLines.length > 0 && (
                <div
                  style={{
                    marginTop: 16,
                    padding: "12px 0",
                    borderTop: "1px solid #e8e4de",
                    display: "flex",
                    justifyContent: "space-between",
                    fontSize: 13,
                    color: "#6b6860",
                  }}
                >
                  <span>
                    {poLines.length} line{poLines.length !== 1 ? "s" : ""} ·{" "}
                    {selectedPO.total_ordered} units
                  </span>
                  {poLines.some((l) => l.total_price_aed) && (
                    <span style={{ fontWeight: 600, color: "#0a0a0a" }}>
                      Total:{" "}
                      {poLines
                        .reduce((sum, l) => sum + (l.total_price_aed ?? 0), 0)
                        .toFixed(2)}{" "}
                      AED
                    </span>
                  )}
                </div>
              )}

              {poAdditions.filter((a) => a.status === "pending_receive")
                .length > 0 && (
                <div
                  style={{
                    marginTop: 20,
                    background: "#fffbeb",
                    borderRadius: 6,
                    padding: "12px 16px",
                  }}
                >
                  <div
                    style={{
                      fontSize: 10,
                      fontWeight: 500,
                      letterSpacing: "0.1em",
                      textTransform: "uppercase",
                      color: "#92400e",
                      marginBottom: 12,
                    }}
                  >
                    Field Additions &mdash; Awaiting Receive
                  </div>
                  {poAdditions
                    .filter((a) => a.status === "pending_receive")
                    .map((a) => (
                      <div
                        key={a.addition_id}
                        style={{
                          display: "flex",
                          alignItems: "center",
                          justifyContent: "space-between",
                          padding: "8px 0",
                          borderBottom: "1px solid #fef3c7",
                        }}
                      >
                        <div>
                          <span style={{ fontWeight: 600, color: "#24544a" }}>
                            {a.boonz_products.boonz_product_name}
                          </span>
                          <span
                            style={{
                              marginLeft: 8,
                              fontSize: 12,
                              color: "#6b6860",
                            }}
                          >
                            &times;{a.qty}
                          </span>
                          {a.price_per_unit_aed && (
                            <span
                              style={{
                                marginLeft: 8,
                                fontSize: 12,
                                color: "#6b6860",
                              }}
                            >
                              {a.price_per_unit_aed.toFixed(2)} AED
                            </span>
                          )}
                        </div>
                        <button
                          onClick={() => handleReceiveAddition(a)}
                          disabled={
                            receivingAddition === a.addition_id ||
                            a.status === "received"
                          }
                          style={{
                            background:
                              a.status === "received" ? "#9ca3af" : "#f59e0b",
                            color: "white",
                            border: "none",
                            borderRadius: 6,
                            padding: "4px 12px",
                            fontSize: 12,
                            fontWeight: 600,
                            cursor:
                              a.status === "received"
                                ? "not-allowed"
                                : "pointer",
                          }}
                        >
                          {receivingAddition === a.addition_id
                            ? "\u2026"
                            : "Receive"}
                        </button>
                      </div>
                    ))}
                </div>
              )}
              {poAdditions.filter((a) => a.status === "received").length >
                0 && (
                <div
                  style={{
                    marginTop: 14,
                    background: "#f0fdf4",
                    borderRadius: 6,
                    padding: "12px 16px",
                  }}
                >
                  <div
                    style={{
                      fontSize: 10,
                      fontWeight: 500,
                      letterSpacing: "0.1em",
                      textTransform: "uppercase",
                      color: "#166534",
                      marginBottom: 12,
                    }}
                  >
                    Received Additions
                  </div>
                  {poAdditions
                    .filter((a) => a.status === "received")
                    .map((a) => (
                      <div
                        key={a.addition_id}
                        style={{
                          display: "flex",
                          alignItems: "center",
                          justifyContent: "space-between",
                          padding: "8px 0",
                          borderBottom: "1px solid #dcfce7",
                        }}
                      >
                        <div>
                          <span style={{ fontWeight: 600, color: "#24544a" }}>
                            {a.boonz_products.boonz_product_name}
                          </span>
                          <span
                            style={{
                              marginLeft: 8,
                              fontSize: 12,
                              color: "#6b6860",
                            }}
                          >
                            &times;{a.qty}
                          </span>
                        </div>
                        <span
                          style={{
                            background: "#bbf7d0",
                            color: "#166534",
                            borderRadius: 12,
                            padding: "2px 10px",
                            fontSize: 11,
                            fontWeight: 600,
                          }}
                        >
                          Received &#10003;
                        </span>
                      </div>
                    ))}
                </div>
              )}
            </div>

            {/* Footer — 2026-04-23: The inline drawer receive flow has been
                 retired. It never captured expiry date per batch, never set
                 received_qty, and never logged price adjustments — so warehouse
                 stock landed without expiry and the FIFO walker couldn't age
                 batches correctly. Receiving is now delegated to the canonical
                 /field/receiving/[poId] flow (which supports multi-batch expiry,
                 wh_location, editable price at receipt, and inventory_audit_log
                 writes). The button below opens that flow in a new tab so the
                 operator stays in-app while the warehouse manager receives. */}
            {!selectedPO.received_date && (
              <div
                style={{
                  padding: "14px 24px",
                  borderTop: "1px solid #e8e4de",
                }}
              >
                <a
                  href={`/field/receiving/${encodeURIComponent(selectedPO.po_id)}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  style={{
                    display: "block",
                    background: "#24544a",
                    color: "white",
                    borderRadius: 8,
                    padding: "10px 24px",
                    fontSize: 14,
                    fontWeight: 600,
                    border: "none",
                    cursor: "pointer",
                    width: "100%",
                    textAlign: "center",
                    textDecoration: "none",
                    boxSizing: "border-box",
                  }}
                >
                  Open Receiving Flow &nbsp;↗
                </a>
                <p
                  style={{
                    marginTop: 8,
                    fontSize: 11,
                    color: "#6b6860",
                    textAlign: "center",
                  }}
                >
                  Opens /field/receiving/{selectedPO.po_id} — enter qty, expiry
                  per batch, and warehouse location there.
                </p>
              </div>
            )}
          </div>
        </>
      )}

      {/* ── New PO Modal ──────────────────────────────────────────────────── */}
      {showNewPO && (
        <>
          <div
            onClick={() => setShowNewPO(false)}
            style={{
              position: "fixed",
              inset: 0,
              background: "rgba(0,0,0,0.25)",
              zIndex: 40,
            }}
          />
          <div
            style={{
              position: "fixed",
              top: 0,
              right: 0,
              bottom: 0,
              width: 560,
              maxWidth: "100vw",
              background: "white",
              zIndex: 50,
              boxShadow: "-4px 0 24px rgba(0,0,0,0.08)",
              display: "flex",
              flexDirection: "column",
              fontFamily: "'Plus Jakarta Sans', sans-serif",
            }}
          >
            {/* Header */}
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
                  fontSize: 18,
                  fontWeight: 800,
                  color: "#0a0a0a",
                  margin: 0,
                  letterSpacing: "-0.02em",
                }}
              >
                New Purchase Order
              </h2>
              <button
                onClick={() => setShowNewPO(false)}
                style={{
                  background: "none",
                  border: "none",
                  fontSize: 22,
                  color: "#6b6860",
                  cursor: "pointer",
                  padding: 4,
                  lineHeight: 1,
                }}
              >
                ✕
              </button>
            </div>

            {/* Form */}
            <div style={{ flex: 1, overflow: "auto", padding: "20px 24px" }}>
              {/* Supplier + Date */}
              <div
                style={{
                  display: "grid",
                  gridTemplateColumns: "1fr 1fr",
                  gap: 16,
                  marginBottom: 24,
                }}
              >
                <div>
                  <label
                    style={{
                      fontSize: 10,
                      fontWeight: 500,
                      letterSpacing: "0.08em",
                      textTransform: "uppercase",
                      color: "#6b6860",
                      display: "block",
                      marginBottom: 6,
                    }}
                  >
                    Supplier
                  </label>
                  <select
                    value={newSupplier}
                    onChange={(e) => setNewSupplier(e.target.value)}
                    style={{
                      width: "100%",
                      border: "1px solid #e8e4de",
                      borderRadius: 8,
                      padding: "8px 12px",
                      fontSize: 13,
                      color: "#0a0a0a",
                      background: "white",
                    }}
                  >
                    <option value="">Select…</option>
                    {suppliers.map((s) => (
                      <option key={s.supplier_id} value={s.supplier_id}>
                        {s.supplier_name}
                      </option>
                    ))}
                  </select>
                </div>
                <div>
                  <label
                    style={{
                      fontSize: 10,
                      fontWeight: 500,
                      letterSpacing: "0.08em",
                      textTransform: "uppercase",
                      color: "#6b6860",
                      display: "block",
                      marginBottom: 6,
                    }}
                  >
                    Purchase Date
                  </label>
                  <input
                    type="date"
                    value={newDate}
                    onChange={(e) => setNewDate(e.target.value)}
                    style={{
                      width: "100%",
                      border: "1px solid #e8e4de",
                      borderRadius: 8,
                      padding: "8px 12px",
                      fontSize: 13,
                      color: "#0a0a0a",
                    }}
                  />
                </div>
              </div>

              {/* Line items */}
              <div
                style={{
                  fontSize: 10,
                  fontWeight: 500,
                  letterSpacing: "0.1em",
                  textTransform: "uppercase",
                  color: "#6b6860",
                  marginBottom: 12,
                }}
              >
                Line Items
              </div>

              {newLines.map((line, idx) => (
                <div
                  key={idx}
                  style={{
                    display: "grid",
                    gridTemplateColumns: "1fr 70px 80px 110px 30px",
                    gap: 8,
                    marginBottom: 8,
                    alignItems: "center",
                  }}
                >
                  <select
                    value={line.boonz_product_id}
                    onChange={(e) => {
                      updateNewLine(idx, "boonz_product_id", e.target.value);
                      const p = products.find(
                        (p) => p.product_id === e.target.value,
                      );
                      if (p)
                        updateNewLine(
                          idx,
                          "product_name",
                          p.boonz_product_name,
                        );
                    }}
                    style={{
                      border: "1px solid #e8e4de",
                      borderRadius: 6,
                      padding: "6px 8px",
                      fontSize: 12,
                      color: "#0a0a0a",
                      background: "white",
                    }}
                  >
                    <option value="">Product…</option>
                    {products.map((p) => (
                      <option key={p.product_id} value={p.product_id}>
                        {p.boonz_product_name}
                      </option>
                    ))}
                  </select>
                  <input
                    type="number"
                    min={1}
                    value={line.ordered_qty}
                    onChange={(e) =>
                      updateNewLine(idx, "ordered_qty", Number(e.target.value))
                    }
                    placeholder="Qty"
                    style={{
                      border: "1px solid #e8e4de",
                      borderRadius: 6,
                      padding: "6px 8px",
                      fontSize: 12,
                      color: "#0a0a0a",
                    }}
                  />
                  <input
                    type="number"
                    min={0}
                    step={0.01}
                    value={line.price_per_unit_aed || ""}
                    onChange={(e) =>
                      updateNewLine(
                        idx,
                        "price_per_unit_aed",
                        Number(e.target.value),
                      )
                    }
                    placeholder="AED"
                    style={{
                      border: "1px solid #e8e4de",
                      borderRadius: 6,
                      padding: "6px 8px",
                      fontSize: 12,
                      color: "#0a0a0a",
                    }}
                  />
                  <input
                    type="date"
                    value={line.expiry_date}
                    onChange={(e) =>
                      updateNewLine(idx, "expiry_date", e.target.value)
                    }
                    style={{
                      border: "1px solid #e8e4de",
                      borderRadius: 6,
                      padding: "6px 8px",
                      fontSize: 11,
                      color: "#0a0a0a",
                    }}
                  />
                  <button
                    onClick={() => removeNewLine(idx)}
                    style={{
                      background: "none",
                      border: "none",
                      color: "#dc2626",
                      cursor: "pointer",
                      fontSize: 16,
                    }}
                  >
                    ✕
                  </button>
                </div>
              ))}

              <button
                onClick={addNewLine}
                style={{
                  background: "none",
                  border: "1px dashed #e8e4de",
                  borderRadius: 8,
                  padding: "10px",
                  width: "100%",
                  color: "#6b6860",
                  fontSize: 13,
                  cursor: "pointer",
                  marginTop: 4,
                }}
              >
                + Add Line
              </button>
            </div>

            {/* Footer */}
            <div
              style={{
                padding: "14px 24px",
                borderTop: "1px solid #e8e4de",
              }}
            >
              <button
                onClick={saveNewPO}
                disabled={
                  newSaving ||
                  !newSupplier ||
                  newLines.length === 0 ||
                  newLines.some((l) => !l.boonz_product_id)
                }
                style={{
                  background:
                    newSaving ||
                    !newSupplier ||
                    newLines.length === 0 ||
                    newLines.some((l) => !l.boonz_product_id)
                      ? "#e8e4de"
                      : "#24544a",
                  color:
                    newSaving ||
                    !newSupplier ||
                    newLines.length === 0 ||
                    newLines.some((l) => !l.boonz_product_id)
                      ? "#6b6860"
                      : "white",
                  borderRadius: 8,
                  padding: "10px 24px",
                  fontSize: 14,
                  fontWeight: 600,
                  border: "none",
                  cursor:
                    newSaving ||
                    !newSupplier ||
                    newLines.length === 0 ||
                    newLines.some((l) => !l.boonz_product_id)
                      ? "not-allowed"
                      : "pointer",
                  width: "100%",
                }}
              >
                {newSaving ? "Saving…" : "Create Purchase Order"}
              </button>
            </div>
          </div>
        </>
      )}

      {/* PRD-002: per-line Cancel drawer */}
      {cancellingLine && (
        <CancelPOLineDrawer
          poLineId={cancellingLine.po_line_id}
          productName={cancellingLine.boonz_products.boonz_product_name}
          orderedQty={cancellingLine.ordered_qty ?? 0}
          open={cancellingLine !== null}
          onClose={() => setCancellingLine(null)}
          onConfirmed={() => {
            // Re-fetch lines + the orders list so the cancelled line picks up
            // its not_purchased outcome immediately.
            if (selectedPO) {
              openPODrawer(selectedPO);
            }
            fetchOrders();
          }}
        />
      )}
    </div>
  );
}
