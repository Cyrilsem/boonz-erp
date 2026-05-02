"use client";

import { useEffect, useState, useMemo, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";

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

type TabFilter = "pending" | "all";

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
        "po_line_id, po_id, po_number, purchase_date, ordered_qty, received_date, price_per_unit_aed, total_price_aed, expiry_date, boonz_product_id, boonz_products!inner(boonz_product_name)",
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

  // AUDIT (2026-04-23): saveNewPO previously called .insert() with no error check and
  // cleared modal state unconditionally — meaning a failed insert (e.g. RLS WITH CHECK
  // mismatch) appeared successful. Fixed: chain .select(), check error, toast on failure.
  // handleReceive below was similarly unguarded but is the legacy inline-receive path
  // (not the field /receiving/<poId> flow). Added error handling there too.
  const saveNewPO = async () => {
    if (!newSupplier || newLines.length === 0) return;
    setNewSaving(true);
    const supabase = createClient();

    // 2026-04-23: Compute next sequential po_number from DB. Previously this
    // function set po_number = poId (a formatted string like "PO-2026-1234"),
    // which fails the int column type on purchase_orders.po_number — the silent
    // insert error behind the "PO never created successfully" reports.
    const { data: lastPo } = await supabase
      .from("purchase_orders")
      .select("po_number")
      .not("po_number", "is", null)
      .order("po_number", { ascending: false })
      .limit(1)
      .single();
    const nextNumber = (lastPo?.po_number ?? 9016) + 1;
    const poId = `PO-${new Date().getFullYear()}-${nextNumber}`;

    const rows = newLines.map((l) => ({
      po_id: poId,
      po_number: nextNumber,
      supplier_id: newSupplier,
      boonz_product_id: l.boonz_product_id,
      purchase_date: newDate,
      ordered_qty: l.ordered_qty,
      price_per_unit_aed: l.price_per_unit_aed || null,
      total_price_aed: l.price_per_unit_aed
        ? l.price_per_unit_aed * l.ordered_qty
        : null,
      expiry_date: l.expiry_date || null,
    }));
    const { error: insertErr } = await supabase
      .from("purchase_orders")
      .insert(rows)
      .select();
    if (insertErr) {
      setNewSaving(false);
      alert(`Failed to save PO: ${insertErr.message}`);
      return;
    }

    // 2026-04-23: Always insert a driver_tasks row so the PO surfaces on the
    // driver's /field/tasks list and the operator's open-orders view.
    // Previously saveNewPO wrote only to purchase_orders, so POs created from
    // this admin modal were invisible to drivers — same root cause as
    // PO-2026-0423-UC where the PO existed in DB but never appeared on tasks.
    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (user) {
      const productNames = newLines
        .map((l) => `${l.product_name} x${l.ordered_qty}`)
        .join(", ");
      const { error: taskErr } = await supabase.from("driver_tasks").insert({
        po_id: poId,
        po_number: nextNumber,
        supplier_id: newSupplier,
        status: "pending",
        created_by: user.id,
        notes: productNames,
      });
      if (taskErr) {
        // Non-fatal: PO is already saved. Log and surface a soft warning.
        console.error("[procurement] driver_task insert error:", taskErr);
        alert(
          `PO saved, but could not create driver task: ${taskErr.message}. Please contact admin.`,
        );
      }
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

  const handleReceiveAddition = async (addition: POAddition) => {
    setReceivingAddition(addition.addition_id);
    const supabase = createClient();

    // Guard: check if already received to prevent duplicate WH rows
    const { data: existing } = await supabase
      .from("po_additions")
      .select("status")
      .eq("addition_id", addition.addition_id)
      .single();

    if (existing?.status === "received") {
      setAdditionToast("Already received — no duplicate created");
      setTimeout(() => setAdditionToast(null), 3000);
      setReceivingAddition(null);
      return;
    }

    const {
      data: { user },
    } = await supabase.auth.getUser();
    const today = getDubaiDate();

    // Insert into warehouse_inventory
    await supabase.from("warehouse_inventory").insert({
      boonz_product_id: addition.boonz_product_id,
      warehouse_stock: addition.qty,
      status: "Active",
      snapshot_date: today,
      expiration_date: addition.expiry_date ?? null,
      warehouse_id: "4bebef68-9e36-4a5c-9c2c-142f8dbdae85", // WH_CENTRAL
      batch_id: `PO-ADDITION-${addition.addition_id.slice(0, 8)}`,
    });

    // Update po_additions
    await supabase
      .from("po_additions")
      .update({
        status: "received",
        received_at: new Date().toISOString(),
        received_by: user?.id,
      })
      .eq("addition_id", addition.addition_id);

    // Optimistic: mark as received in local state (don't remove — show as received)
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
      `✓ ${addition.qty} units of ${addition.boonz_products.boonz_product_name} added to warehouse`,
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
        {(["pending", "all"] as const).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            style={{
              border: "1px solid #e8e4de",
              borderRadius: 8,
              padding: "7px 14px",
              fontSize: 13,
              fontWeight: tab === t ? 600 : 400,
              background: tab === t ? "#0a0a0a" : "white",
              color: tab === t ? "white" : "#6b6860",
              cursor: "pointer",
            }}
          >
            {t === "pending" ? `Pending (${pendingCount})` : "All Orders"}
          </button>
        ))}
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
          <span style={{ marginLeft: "auto", fontSize: 13, color: "#6b6860" }}>
            {displayed.length} result{displayed.length !== 1 ? "s" : ""}
          </span>
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
                        style={{ height: 14, width: w, background: "#f0ede8" }}
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
                    {poLines.map((l) => (
                      <tr
                        key={l.po_line_id}
                        style={{ borderBottom: "1px solid #f5f2ee" }}
                      >
                        <td
                          className="py-2 px-2"
                          style={{ fontWeight: 600, color: "#24544a" }}
                        >
                          {l.boonz_products.boonz_product_name}
                        </td>
                        <td className="py-2 px-2" style={{ color: "#0a0a0a" }}>
                          {l.ordered_qty}
                        </td>
                        <td className="py-2 px-2" style={{ color: "#6b6860" }}>
                          {l.price_per_unit_aed
                            ? `${l.price_per_unit_aed.toFixed(2)} AED`
                            : "—"}
                        </td>
                        <td className="py-2 px-2" style={{ color: "#6b6860" }}>
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
                      </tr>
                    ))}
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
    </div>
  );
}
