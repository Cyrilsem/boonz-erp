"use client";

import { useEffect, useState, useCallback } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";

// ── Types ─────────────────────────────────────────────────────────────────────

interface DriftRow {
  product_id: string;
  boonz_product_name: string | null;
  wh_total: number | null;
  consumer_total: number | null;
  pod_total: number | null;
  unreconciled_consumer: number | null;
  in_flight_dispatches: number | null;
}

type CandidateStatus =
  | "pending_review"
  | "confirmed_drift"
  | "ignored"
  | "repaired";

interface CandidateRow {
  candidate_id: string;
  dispatch_id: string | null;
  machine_id: string | null;
  boonz_product_id: string | null;
  dispatch_date: string | null;
  action: string | null;
  planned_qty: number | null;
  filled_qty: number | null;
  qty_gap: number | null;
  wh_stock_current: number | null;
  pod_stock_current: number | null;
  status: CandidateStatus;
  notes: string | null;
  created_at: string;
  reviewed_at: string | null;
  reviewed_by: string | null;
}

interface MachineLookup {
  machine_id: string;
  official_name: string;
}

interface ProductLookup {
  product_id: string;
  boonz_product_name: string;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function shortId(uuid: string | null): string {
  if (!uuid) return "\u2014";
  return uuid.slice(0, 8);
}

function fmtNum(v: number | null | undefined): string {
  if (v == null) return "\u2014";
  const n = Number(v);
  return Number.isFinite(n) ? String(n) : "\u2014";
}

function fmtDate(d: string | null): string {
  if (!d) return "\u2014";
  return new Date(d + "T00:00:00").toLocaleDateString("en-GB", {
    day: "2-digit",
    month: "short",
    year: "2-digit",
  });
}

// ── Component ─────────────────────────────────────────────────────────────────

export default function InventoryDriftPage() {
  const [drift, setDrift] = useState<DriftRow[]>([]);
  const [candidates, setCandidates] = useState<CandidateRow[]>([]);
  const [machines, setMachines] = useState<Map<string, string>>(new Map());
  const [products, setProducts] = useState<Map<string, string>>(new Map());
  const [loading, setLoading] = useState(true);
  const [updatingId, setUpdatingId] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] =
    useState<CandidateStatus>("pending_review");

  const fetchAll = useCallback(async () => {
    const supabase = createClient();

    const [{ data: driftData }, { data: candidateData }] = await Promise.all([
      supabase
        .from("v_inventory_drift_check")
        .select(
          "product_id, boonz_product_name, wh_total, consumer_total, pod_total, unreconciled_consumer, in_flight_dispatches",
        )
        .limit(10000),
      supabase
        .from("inventory_drift_candidates")
        .select(
          "candidate_id, dispatch_id, machine_id, boonz_product_id, dispatch_date, action, planned_qty, filled_qty, qty_gap, wh_stock_current, pod_stock_current, status, notes, created_at, reviewed_at, reviewed_by",
        )
        .eq("status", statusFilter)
        .order("dispatch_date", { ascending: false })
        .limit(10000),
    ]);

    const driftRows = (driftData ?? []) as DriftRow[];
    const candidateRows = (candidateData ?? []) as CandidateRow[];

    setDrift(driftRows);
    setCandidates(candidateRows);

    // Resolve machine + product names referenced by candidates
    const machineIds = Array.from(
      new Set(candidateRows.map((r) => r.machine_id).filter(Boolean)),
    ) as string[];
    const productIds = Array.from(
      new Set(candidateRows.map((r) => r.boonz_product_id).filter(Boolean)),
    ) as string[];

    if (machineIds.length > 0) {
      const { data: machineData } = await supabase
        .from("machines")
        .select("machine_id, official_name")
        .in("machine_id", machineIds)
        .limit(10000);
      const map = new Map<string, string>();
      for (const m of (machineData ?? []) as MachineLookup[]) {
        map.set(m.machine_id, m.official_name);
      }
      setMachines(map);
    } else {
      setMachines(new Map());
    }

    if (productIds.length > 0) {
      const { data: productData } = await supabase
        .from("boonz_products")
        .select("product_id, boonz_product_name")
        .in("product_id", productIds)
        .limit(10000);
      const map = new Map<string, string>();
      for (const p of (productData ?? []) as ProductLookup[]) {
        map.set(p.product_id, p.boonz_product_name);
      }
      setProducts(map);
    } else {
      setProducts(new Map());
    }

    setLoading(false);
  }, [statusFilter]);

  useEffect(() => {
    setLoading(true);
    fetchAll();
  }, [fetchAll]);

  async function updateCandidateStatus(
    candidateId: string,
    nextStatus: CandidateStatus,
  ) {
    setUpdatingId(candidateId);
    try {
      const supabase = createClient();
      const {
        data: { user },
      } = await supabase.auth.getUser();

      await supabase
        .from("inventory_drift_candidates")
        .update({
          status: nextStatus,
          reviewed_at: new Date().toISOString(),
          reviewed_by: user?.id ?? null,
        })
        .eq("candidate_id", candidateId);

      await fetchAll();
    } finally {
      setUpdatingId(null);
    }
  }

  // ── Render ─────────────────────────────────────────────────────────────────

  const driftWithIssues = drift.filter(
    (r) =>
      Number(r.unreconciled_consumer ?? 0) !== 0 ||
      Number(r.in_flight_dispatches ?? 0) > 0,
  );

  return (
    <div className="max-w-6xl mx-auto px-4 py-8 sm:px-6">
      {/* Header */}
      <div className="mb-6 flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold text-gray-900">
            Inventory Drift
          </h1>
          <p className="text-sm text-gray-500 mt-1">
            Live three-way reconciliation (warehouse / consumer / pod) and
            historical underfill candidates needing operator review.
          </p>
        </div>
        <Link
          href="/refill"
          className="text-sm text-gray-600 hover:text-gray-900 transition-colors"
        >
          {"\u2190"} Back to Refill
        </Link>
      </div>

      {/* Live drift table */}
      <section className="mb-10">
        <h2
          style={{
            fontSize: 11,
            fontWeight: 600,
            letterSpacing: "0.06em",
            textTransform: "uppercase",
            color: "#6b6860",
            marginBottom: 8,
          }}
        >
          Current drift ({driftWithIssues.length} product
          {driftWithIssues.length === 1 ? "" : "s"} with non-zero state)
        </h2>
        <div
          style={{
            background: "white",
            border: "1px solid #e8e4de",
            borderRadius: 12,
            overflow: "hidden",
          }}
        >
          <table
            className="w-full text-sm"
            style={{ borderCollapse: "collapse" }}
          >
            <thead>
              <tr style={{ borderBottom: "1px solid #e8e4de" }}>
                {[
                  "Product",
                  "WH",
                  "Consumer",
                  "Pod",
                  "Unreconciled",
                  "In-flight",
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
                <tr>
                  <td
                    colSpan={6}
                    className="px-4 py-6 text-center"
                    style={{ color: "#6b6860" }}
                  >
                    {"Loading\u2026"}
                  </td>
                </tr>
              ) : driftWithIssues.length === 0 ? (
                <tr>
                  <td
                    colSpan={6}
                    className="px-4 py-6 text-center"
                    style={{ color: "#6b6860" }}
                  >
                    {"\u2713"} No drift detected. WH + consumer + pod are
                    reconciled.
                  </td>
                </tr>
              ) : (
                driftWithIssues.map((r) => {
                  const unrec = Number(r.unreconciled_consumer ?? 0);
                  return (
                    <tr
                      key={r.product_id}
                      style={{ borderBottom: "1px solid #f5f2ee" }}
                    >
                      <td
                        className="px-4 py-2"
                        style={{ color: "#0a0a0a", fontWeight: 500 }}
                      >
                        {r.boonz_product_name ?? "\u2014"}
                      </td>
                      <td className="px-4 py-2" style={{ color: "#6b6860" }}>
                        {fmtNum(r.wh_total)}
                      </td>
                      <td className="px-4 py-2" style={{ color: "#6b6860" }}>
                        {fmtNum(r.consumer_total)}
                      </td>
                      <td className="px-4 py-2" style={{ color: "#6b6860" }}>
                        {fmtNum(r.pod_total)}
                      </td>
                      <td
                        className="px-4 py-2"
                        style={{
                          color: unrec === 0 ? "#6b6860" : "#b04141",
                          fontWeight: unrec === 0 ? 400 : 600,
                        }}
                      >
                        {fmtNum(r.unreconciled_consumer)}
                      </td>
                      <td className="px-4 py-2" style={{ color: "#6b6860" }}>
                        {fmtNum(r.in_flight_dispatches)}
                      </td>
                    </tr>
                  );
                })
              )}
            </tbody>
          </table>
        </div>
      </section>

      {/* Historical candidates */}
      <section>
        <div className="mb-2 flex items-center justify-between gap-4">
          <h2
            style={{
              fontSize: 11,
              fontWeight: 600,
              letterSpacing: "0.06em",
              textTransform: "uppercase",
              color: "#6b6860",
            }}
          >
            Historical candidates ({candidates.length})
          </h2>
          <div className="flex items-center gap-2">
            {(
              [
                "pending_review",
                "confirmed_drift",
                "ignored",
                "repaired",
              ] as const
            ).map((s) => (
              <button
                key={s}
                onClick={() => setStatusFilter(s)}
                className={`px-2.5 py-1 rounded text-xs font-medium transition-colors ${
                  statusFilter === s
                    ? "bg-gray-900 text-white"
                    : "bg-gray-100 text-gray-600 hover:bg-gray-200"
                }`}
              >
                {s.replace("_", " ")}
              </button>
            ))}
          </div>
        </div>
        <div
          style={{
            background: "white",
            border: "1px solid #e8e4de",
            borderRadius: 12,
            overflow: "hidden",
          }}
        >
          <table
            className="w-full text-sm"
            style={{ borderCollapse: "collapse" }}
          >
            <thead>
              <tr style={{ borderBottom: "1px solid #e8e4de" }}>
                {[
                  "Dispatch",
                  "Machine",
                  "Product",
                  "Date",
                  "Action",
                  "Plan",
                  "Filled",
                  "Gap",
                  "WH now",
                  "Pod now",
                  "Status",
                  "",
                ].map((h, i) => (
                  <th
                    key={i}
                    className="text-left px-3 py-3"
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
                <tr>
                  <td
                    colSpan={12}
                    className="px-4 py-6 text-center"
                    style={{ color: "#6b6860" }}
                  >
                    {"Loading\u2026"}
                  </td>
                </tr>
              ) : candidates.length === 0 ? (
                <tr>
                  <td
                    colSpan={12}
                    className="px-4 py-6 text-center"
                    style={{ color: "#6b6860" }}
                  >
                    No candidates with status &ldquo;
                    {statusFilter.replace("_", " ")}&rdquo;.
                  </td>
                </tr>
              ) : (
                candidates.map((c) => {
                  const isUpdating = updatingId === c.candidate_id;
                  const machineName =
                    (c.machine_id && machines.get(c.machine_id)) || "\u2014";
                  const productName =
                    (c.boonz_product_id && products.get(c.boonz_product_id)) ||
                    "\u2014";
                  return (
                    <tr
                      key={c.candidate_id}
                      style={{ borderBottom: "1px solid #f5f2ee" }}
                    >
                      <td
                        className="px-3 py-2"
                        style={{
                          color: "#6b6860",
                          fontFamily:
                            "ui-monospace, SFMono-Regular, Menlo, monospace",
                          fontSize: 11,
                        }}
                      >
                        {shortId(c.dispatch_id)}
                      </td>
                      <td className="px-3 py-2" style={{ color: "#0a0a0a" }}>
                        {machineName}
                      </td>
                      <td className="px-3 py-2" style={{ color: "#0a0a0a" }}>
                        {productName}
                      </td>
                      <td
                        className="px-3 py-2"
                        style={{ color: "#6b6860", fontSize: 12 }}
                      >
                        {fmtDate(c.dispatch_date)}
                      </td>
                      <td className="px-3 py-2" style={{ color: "#6b6860" }}>
                        {c.action ?? "\u2014"}
                      </td>
                      <td
                        className="px-3 py-2"
                        style={{ color: "#6b6860", fontWeight: 500 }}
                      >
                        {fmtNum(c.planned_qty)}
                      </td>
                      <td className="px-3 py-2" style={{ color: "#6b6860" }}>
                        {fmtNum(c.filled_qty)}
                      </td>
                      <td
                        className="px-3 py-2"
                        style={{
                          color:
                            Number(c.qty_gap ?? 0) > 0 ? "#b04141" : "#6b6860",
                          fontWeight: 600,
                        }}
                      >
                        {fmtNum(c.qty_gap)}
                      </td>
                      <td className="px-3 py-2" style={{ color: "#6b6860" }}>
                        {fmtNum(c.wh_stock_current)}
                      </td>
                      <td className="px-3 py-2" style={{ color: "#6b6860" }}>
                        {fmtNum(c.pod_stock_current)}
                      </td>
                      <td className="px-3 py-2" style={{ color: "#6b6860" }}>
                        <span
                          style={{
                            fontSize: 11,
                            fontWeight: 600,
                            padding: "2px 6px",
                            borderRadius: 4,
                            background:
                              c.status === "confirmed_drift"
                                ? "rgba(176, 65, 65, 0.10)"
                                : c.status === "ignored"
                                  ? "rgba(107, 104, 96, 0.10)"
                                  : c.status === "repaired"
                                    ? "rgba(36, 84, 74, 0.10)"
                                    : "rgba(225, 180, 96, 0.18)",
                            color:
                              c.status === "confirmed_drift"
                                ? "#b04141"
                                : c.status === "ignored"
                                  ? "#6b6860"
                                  : c.status === "repaired"
                                    ? "#24544a"
                                    : "#b08930",
                          }}
                        >
                          {c.status.replace("_", " ")}
                        </span>
                      </td>
                      <td className="px-3 py-2">
                        {c.status === "pending_review" ? (
                          <div className="flex items-center gap-1">
                            <button
                              disabled={isUpdating}
                              onClick={() =>
                                updateCandidateStatus(
                                  c.candidate_id,
                                  "confirmed_drift",
                                )
                              }
                              className="px-2 py-1 text-xs rounded border border-red-200 text-red-700 hover:bg-red-50 disabled:opacity-50"
                              title="Confirm this is a real drift event"
                            >
                              Drift
                            </button>
                            <button
                              disabled={isUpdating}
                              onClick={() =>
                                updateCandidateStatus(
                                  c.candidate_id,
                                  "repaired",
                                )
                              }
                              className="px-2 py-1 text-xs rounded border border-emerald-200 text-emerald-700 hover:bg-emerald-50 disabled:opacity-50"
                              title="Mark as repaired (data already corrected)"
                            >
                              Repaired
                            </button>
                            <button
                              disabled={isUpdating}
                              onClick={() =>
                                updateCandidateStatus(c.candidate_id, "ignored")
                              }
                              className="px-2 py-1 text-xs rounded border border-gray-200 text-gray-600 hover:bg-gray-50 disabled:opacity-50"
                              title="Not a real drift event"
                            >
                              Ignore
                            </button>
                          </div>
                        ) : (
                          <button
                            disabled={isUpdating}
                            onClick={() =>
                              updateCandidateStatus(
                                c.candidate_id,
                                "pending_review",
                              )
                            }
                            className="px-2 py-1 text-xs rounded border border-gray-200 text-gray-500 hover:bg-gray-50 disabled:opacity-50"
                            title="Move back to pending review"
                          >
                            Reopen
                          </button>
                        )}
                      </td>
                    </tr>
                  );
                })
              )}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}
