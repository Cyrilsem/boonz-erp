"use client";

// PRD-022 — Price review.
//
// The queue of advisory price flags raised by procurement_price_sync_and_flag.
// Nothing here ever blocked a warehouse write: by the time a row lands on this
// page the goods are received and the money is recorded. This page exists to
// close the loop on the flag, and it has exactly two ways to do that:
//
//   Fix    — correct_procurement_unit_price_v1. Dry-run first, always: the
//            preview shows the old and new line totals and the delta before a
//            single row moves. Confirm applies it and writes the audit row.
//   Confirm— review_price_flag_v1 with verdict 'confirmed_correct'. The price
//            was right; the flag was noise. Clears it with a note on the record.
//
// Both are RPCs (Articles 1, 3, 4, 8). This page performs no table writes.

import { useCallback, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";

const REVIEW_ROLES = new Set(["operator_admin", "superadmin", "manager"]);

interface FlagRow {
  source_table: "po_additions" | "purchase_orders";
  row_id: string;
  po_id: string;
  boonz_product_name: string;
  row_date: string | null;
  qty: number | null;
  unit_aed: number | null;
  total_aed: number | null;
  status: string | null;
  pricing_status: string | null;
  flag_code: string;
  price_flag: {
    code: string;
    peer_median_unit_aed: number | null;
    peer_observations: number | null;
    unit_vs_median_pct: number | null;
    suggested_unit_aed: number | null;
    backfilled?: boolean;
    flagged_at?: string;
  } | null;
}

interface DryRun {
  status: string;
  qty: number;
  old_unit_aed: number;
  new_unit_aed: number;
  old_line_total_aed: number;
  new_line_total_aed: number;
  delta_aed: number;
}

const CODE_COPY: Record<string, string> = {
  LOOKS_LIKE_LINE_TOTAL:
    "The unit price looks like a whole line total — it is roughly the peer median multiplied by the quantity.",
  PRICE_HIGH: "The unit price is more than double the peer median.",
  PRICE_LOW: "The unit price is under a tenth of the peer median.",
  UNPRICED_RECEIPT:
    "Goods were received with no money recorded against the line. Advisory only — reprice it, or confirm the receipt really was free.",
};

const aed = (n: number | null | undefined) =>
  n == null ? "—" : `${Number(n).toFixed(2)} AED`;

export default function PriceReviewPage() {
  const [rows, setRows] = useState<FlagRow[]>([]);
  const [role, setRole] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [banner, setBanner] = useState<{
    tone: "ok" | "err";
    msg: string;
  } | null>(null);

  // Per-row working state, keyed by row_id.
  const [newUnit, setNewUnit] = useState<Record<string, number | null>>({});
  const [reason, setReason] = useState<Record<string, string>>({});
  const [preview, setPreview] = useState<Record<string, DryRun>>({});

  const fetchRows = useCallback(async () => {
    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (user) {
      const { data: profile } = await supabase
        .from("user_profiles")
        .select("role")
        .eq("id", user.id)
        .single();
      setRole(profile?.role ?? null);
    }
    const { data } = await supabase
      .from("v_po_price_flags")
      .select("*")
      .limit(10000);
    setRows((data ?? []) as unknown as FlagRow[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchRows();
  }, [fetchRows]);

  const canReview = role != null && REVIEW_ROLES.has(role);

  // Worst first: a line total typed into a unit-price field is the costliest
  // mistake, then unexplained highs, then the rest.
  const ordered = useMemo(() => {
    const rank: Record<string, number> = {
      LOOKS_LIKE_LINE_TOTAL: 0,
      PRICE_HIGH: 1,
      PRICE_LOW: 2,
      UNPRICED_RECEIPT: 3,
    };
    return [...rows].sort(
      (a, b) =>
        (rank[a.flag_code] ?? 9) - (rank[b.flag_code] ?? 9) ||
        (b.row_date ?? "").localeCompare(a.row_date ?? ""),
    );
  }, [rows]);

  async function runDryRun(r: FlagRow) {
    const unit = newUnit[r.row_id];
    if (unit == null || !(unit > 0)) {
      setBanner({ tone: "err", msg: "Enter a corrected unit price first." });
      return;
    }
    setBusy(r.row_id);
    const supabase = createClient();
    const { data, error } = await supabase.rpc(
      "correct_procurement_unit_price_v1",
      {
        p_table: r.source_table,
        p_row_id: r.row_id,
        p_new_unit: unit,
        p_reason: reason[r.row_id] ?? "price review",
        p_dry_run: true,
      },
    );
    setBusy(null);
    const res = data as (DryRun & { error?: string }) | null;
    if (error || res?.status === "error") {
      setBanner({
        tone: "err",
        msg: error?.message ?? res?.error ?? "Preview failed.",
      });
      return;
    }
    if (res) setPreview((p) => ({ ...p, [r.row_id]: res }));
  }

  async function applyFix(r: FlagRow) {
    const unit = newUnit[r.row_id];
    const why = (reason[r.row_id] ?? "").trim();
    if (unit == null || !(unit > 0)) return;
    if (why.length < 10) {
      setBanner({
        tone: "err",
        msg: "Give a reason of at least 10 characters — it goes on the audit record.",
      });
      return;
    }
    setBusy(r.row_id);
    const supabase = createClient();
    const { data, error } = await supabase.rpc(
      "correct_procurement_unit_price_v1",
      {
        p_table: r.source_table,
        p_row_id: r.row_id,
        p_new_unit: unit,
        p_reason: why,
        p_dry_run: false,
      },
    );
    const res = data as { status?: string; error?: string } | null;
    if (error || res?.status !== "ok") {
      setBusy(null);
      setBanner({
        tone: "err",
        msg: error?.message ?? res?.error ?? "Correction failed.",
      });
      return;
    }

    // The correction moves the price; the flag is a separate record and is
    // closed explicitly so the verdict lands in procurement_events too.
    const { error: revErr } = await supabase.rpc("review_price_flag_v1", {
      p_table: r.source_table,
      p_row_id: r.row_id,
      p_verdict: "corrected",
      p_note: why,
    });
    setBusy(null);
    if (revErr) {
      setBanner({
        tone: "err",
        msg: `Price corrected, but the flag did not close: ${revErr.message}`,
      });
    } else {
      setBanner({
        tone: "ok",
        msg: `${r.boonz_product_name} corrected to ${unit.toFixed(2)} /unit and the flag closed.`,
      });
    }
    setPreview((p) => {
      const n = { ...p };
      delete n[r.row_id];
      return n;
    });
    fetchRows();
  }

  async function confirmCorrect(r: FlagRow) {
    const why = (reason[r.row_id] ?? "").trim();
    if (why.length < 10) {
      setBanner({
        tone: "err",
        msg: "Say why the price is correct — at least 10 characters, it goes on the record.",
      });
      return;
    }
    setBusy(r.row_id);
    const supabase = createClient();
    const { data, error } = await supabase.rpc("review_price_flag_v1", {
      p_table: r.source_table,
      p_row_id: r.row_id,
      p_verdict: "confirmed_correct",
      p_note: why,
    });
    setBusy(null);
    const res = data as { status?: string; error?: string } | null;
    if (error || res?.status !== "ok") {
      setBanner({
        tone: "err",
        msg: error?.message ?? res?.error ?? "Could not close the flag.",
      });
      return;
    }
    setBanner({
      tone: "ok",
      msg: `${r.boonz_product_name} confirmed correct — flag cleared.`,
    });
    fetchRows();
  }

  if (loading) {
    return (
      <div style={{ padding: 32, color: "#6b6860" }}>Loading price flags…</div>
    );
  }

  if (!canReview) {
    return (
      <div style={{ padding: 32 }}>
        <h1 style={{ fontSize: 20, fontWeight: 700, marginBottom: 8 }}>
          Price review
        </h1>
        <p style={{ color: "#6b6860", fontSize: 14 }}>
          This page is for operator admins and managers. Your role
          {role ? ` (${role})` : ""} cannot review price flags.
        </p>
      </div>
    );
  }

  return (
    <div style={{ padding: 32, maxWidth: 1100 }}>
      <h1 style={{ fontSize: 20, fontWeight: 700, marginBottom: 4 }}>
        Price review
      </h1>
      <p style={{ color: "#6b6860", fontSize: 13, marginBottom: 20 }}>
        Advisory flags raised on received purchase lines and field additions.
        None of these blocked a receipt — the goods are in and the money is
        recorded. Correct the price, or confirm it was right all along.
      </p>

      {banner && (
        <div
          style={{
            marginBottom: 16,
            padding: "10px 12px",
            borderRadius: 8,
            fontSize: 13,
            background: banner.tone === "ok" ? "#ecfdf5" : "#fef2f2",
            color: banner.tone === "ok" ? "#065f46" : "#991b1b",
            border: `1px solid ${banner.tone === "ok" ? "#a7f3d0" : "#fecaca"}`,
          }}
        >
          {banner.msg}
        </div>
      )}

      {ordered.length === 0 ? (
        <div
          style={{
            padding: 24,
            borderRadius: 8,
            background: "#ecfdf5",
            color: "#065f46",
            fontSize: 14,
          }}
        >
          No open price flags. Every received line is either priced within range
          or has been reviewed.
        </div>
      ) : (
        <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
          {ordered.map((r) => {
            const pv = preview[r.row_id];
            const suggested = r.price_flag?.suggested_unit_aed ?? null;
            return (
              <div
                key={`${r.source_table}:${r.row_id}`}
                style={{
                  border: "1px solid #e7e5e0",
                  borderRadius: 10,
                  padding: 16,
                  background: "#fff",
                }}
              >
                <div
                  style={{
                    display: "flex",
                    justifyContent: "space-between",
                    gap: 12,
                    flexWrap: "wrap",
                  }}
                >
                  <div>
                    <div style={{ fontWeight: 600, fontSize: 15 }}>
                      {r.boonz_product_name}
                    </div>
                    <div
                      style={{ color: "#6b6860", fontSize: 12, marginTop: 2 }}
                    >
                      {r.po_id} · {r.row_date ?? "—"} ·{" "}
                      {r.source_table === "po_additions"
                        ? "field addition"
                        : "PO line"}
                      {r.status ? ` · ${r.status}` : ""}
                      {r.pricing_status && r.pricing_status !== "priced"
                        ? ` · ${r.pricing_status}`
                        : ""}
                      {r.price_flag?.backfilled ? " · backfilled" : ""}
                    </div>
                  </div>
                  <span
                    style={{
                      alignSelf: "flex-start",
                      background: "#fef3c7",
                      color: "#92400e",
                      borderRadius: 999,
                      padding: "3px 10px",
                      fontSize: 11,
                      fontWeight: 700,
                    }}
                  >
                    {r.flag_code.replace(/_/g, " ")}
                  </span>
                </div>

                <p style={{ fontSize: 13, color: "#44403c", margin: "10px 0" }}>
                  {CODE_COPY[r.flag_code] ?? "Flagged for review."}
                </p>

                <div
                  style={{
                    display: "grid",
                    gridTemplateColumns: "repeat(auto-fit, minmax(120px, 1fr))",
                    gap: 8,
                    fontSize: 12,
                    background: "#faf9f7",
                    borderRadius: 6,
                    padding: 10,
                  }}
                >
                  <div>
                    <div style={{ color: "#8a8780" }}>Qty</div>
                    <div style={{ fontWeight: 600 }}>{r.qty ?? "—"}</div>
                  </div>
                  <div>
                    <div style={{ color: "#8a8780" }}>Recorded unit</div>
                    <div style={{ fontWeight: 600 }}>{aed(r.unit_aed)}</div>
                  </div>
                  <div>
                    <div style={{ color: "#8a8780" }}>Line total</div>
                    <div style={{ fontWeight: 600 }}>{aed(r.total_aed)}</div>
                  </div>
                  <div>
                    <div style={{ color: "#8a8780" }}>Peer median</div>
                    <div style={{ fontWeight: 600 }}>
                      {aed(r.price_flag?.peer_median_unit_aed)}
                      {r.price_flag?.peer_observations != null && (
                        <span style={{ color: "#8a8780", fontWeight: 400 }}>
                          {" "}
                          (n={r.price_flag.peer_observations})
                        </span>
                      )}
                    </div>
                  </div>
                </div>

                {suggested != null && (
                  <p
                    style={{
                      marginTop: 10,
                      fontSize: 13,
                      fontWeight: 600,
                      color: "#92400e",
                    }}
                  >
                    Did you mean {Number(suggested).toFixed(2)} /unit?{" "}
                    <button
                      onClick={() =>
                        setNewUnit((p) => ({
                          ...p,
                          [r.row_id]: Number(suggested),
                        }))
                      }
                      style={{
                        fontSize: 12,
                        textDecoration: "underline",
                        color: "#92400e",
                        background: "none",
                        border: "none",
                        cursor: "pointer",
                        padding: 0,
                      }}
                    >
                      use it
                    </button>
                  </p>
                )}

                <div
                  style={{
                    display: "flex",
                    gap: 8,
                    marginTop: 12,
                    flexWrap: "wrap",
                    alignItems: "flex-end",
                  }}
                >
                  <div style={{ width: 150 }}>
                    <label
                      style={{
                        display: "block",
                        fontSize: 11,
                        color: "#8a8780",
                        marginBottom: 2,
                      }}
                    >
                      Corrected unit (AED)
                    </label>
                    <input
                      type="number"
                      min={0}
                      step="0.0001"
                      value={newUnit[r.row_id] ?? ""}
                      onChange={(e) =>
                        setNewUnit((p) => ({
                          ...p,
                          [r.row_id]:
                            e.target.value === ""
                              ? null
                              : parseFloat(e.target.value),
                        }))
                      }
                      style={{
                        width: "100%",
                        border: "1px solid #e7e5e0",
                        borderRadius: 6,
                        padding: "6px 8px",
                        fontSize: 13,
                      }}
                    />
                  </div>
                  <div style={{ flex: 1, minWidth: 240 }}>
                    <label
                      style={{
                        display: "block",
                        fontSize: 11,
                        color: "#8a8780",
                        marginBottom: 2,
                      }}
                    >
                      Reason / note (min 10 chars — goes on the audit record)
                    </label>
                    <input
                      type="text"
                      value={reason[r.row_id] ?? ""}
                      onChange={(e) =>
                        setReason((p) => ({ ...p, [r.row_id]: e.target.value }))
                      }
                      placeholder="e.g. bill Tr40090951 confirms 8pc at 75.60"
                      style={{
                        width: "100%",
                        border: "1px solid #e7e5e0",
                        borderRadius: 6,
                        padding: "6px 8px",
                        fontSize: 13,
                      }}
                    />
                  </div>
                </div>

                {pv && (
                  <div
                    style={{
                      marginTop: 10,
                      padding: 10,
                      borderRadius: 6,
                      background: "#eff6ff",
                      border: "1px solid #bfdbfe",
                      fontSize: 12,
                      color: "#1e40af",
                    }}
                  >
                    <strong>Preview (nothing written yet).</strong> {pv.qty} ×{" "}
                    {Number(pv.old_unit_aed).toFixed(4)} ={" "}
                    {aed(pv.old_line_total_aed)} → {pv.qty} ×{" "}
                    {Number(pv.new_unit_aed).toFixed(4)} ={" "}
                    {aed(pv.new_line_total_aed)}. Change to the line:{" "}
                    <strong>
                      {Number(pv.delta_aed) > 0 ? "+" : ""}
                      {aed(pv.delta_aed)}
                    </strong>
                    .
                  </div>
                )}

                <div style={{ display: "flex", gap: 8, marginTop: 12 }}>
                  <button
                    disabled={busy === r.row_id}
                    onClick={() => runDryRun(r)}
                    style={{
                      padding: "7px 14px",
                      borderRadius: 6,
                      border: "1px solid #d6d3cd",
                      background: "#fff",
                      fontSize: 13,
                      cursor: "pointer",
                    }}
                  >
                    Preview fix
                  </button>
                  <button
                    disabled={busy === r.row_id || !pv}
                    onClick={() => applyFix(r)}
                    title={!pv ? "Preview the fix first" : undefined}
                    style={{
                      padding: "7px 14px",
                      borderRadius: 6,
                      border: "none",
                      background: pv ? "#1c1917" : "#d6d3cd",
                      color: "#fff",
                      fontSize: 13,
                      cursor: pv ? "pointer" : "not-allowed",
                    }}
                  >
                    Apply correction
                  </button>
                  <button
                    disabled={busy === r.row_id}
                    onClick={() => confirmCorrect(r)}
                    style={{
                      padding: "7px 14px",
                      borderRadius: 6,
                      border: "1px solid #a7f3d0",
                      background: "#ecfdf5",
                      color: "#065f46",
                      fontSize: 13,
                      cursor: "pointer",
                    }}
                  >
                    Price is correct — clear flag
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
