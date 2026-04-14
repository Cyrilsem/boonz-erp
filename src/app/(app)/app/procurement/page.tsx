"use client";

import { useEffect, useState, useMemo } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";

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

  useEffect(() => {
    async function load() {
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
    }
    load();
  }, []);

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
        <Link
          href="/field/orders/new"
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
            textDecoration: "none",
          }}
        >
          + New PO
        </Link>
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
                    style={{ borderBottom: "1px solid #f5f2ee" }}
                    onMouseEnter={(e) =>
                      ((
                        e.currentTarget as HTMLTableRowElement
                      ).style.background = "#faf9f7")
                    }
                    onMouseLeave={(e) =>
                      ((
                        e.currentTarget as HTMLTableRowElement
                      ).style.background = "transparent")
                    }
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
                      <Link
                        href={`/field/receiving/${o.po_id}`}
                        style={{
                          fontSize: 12,
                          fontWeight: 600,
                          color: "#24544a",
                          textDecoration: "none",
                          border: "1px solid #24544a",
                          borderRadius: 6,
                          padding: "4px 10px",
                          display: "inline-block",
                          whiteSpace: "nowrap",
                        }}
                      >
                        View →
                      </Link>
                    </td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
