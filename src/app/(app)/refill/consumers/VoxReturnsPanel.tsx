"use client";

// PRD-040 Track C / C1.2: VOX Returns ledger view.
// Read-only surface over get_vox_returns (via /api/vox/returns). No mutation here:
// returns are written at receive time by receive_dispatch_line (PRD-034 B), never from this view.
// Renders inside the MAFE dashboard's .vr container so it inherits the existing table styling.
// Internal-only (staff names / source_of_supply / reasons) - the parent gates the tab behind an
// internal role and hides it on partner-facing (hideInternalLinks) mounts.

import { useCallback, useEffect, useMemo, useState } from "react";

interface VoxReturnRow {
  vox_return_id: string;
  dispatch_id: string | null;
  machine_id: string;
  machine_name: string | null;
  boonz_product_id: string | null;
  product_name: string | null;
  qty: number;
  expiry_date: string | null;
  source_of_supply: string | null;
  reason: string | null;
  received_at: string;
  received_by: string | null;
  received_by_name: string | null;
}

const today = () => new Date().toISOString().slice(0, 10);
const daysAgo = (n: number) =>
  new Date(Date.now() - n * 864e5).toISOString().slice(0, 10);

export default function VoxReturnsPanel() {
  const [dateFrom, setDateFrom] = useState(daysAgo(30));
  const [dateTo, setDateTo] = useState(today());
  const [machineId, setMachineId] = useState<string>("all");
  const [rows, setRows] = useState<VoxReturnRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setErr(null);
    try {
      const qs = new URLSearchParams({ date_from: dateFrom, date_to: dateTo });
      if (machineId !== "all") qs.set("machine_id", machineId);
      const res = await fetch(`/api/vox/returns?${qs.toString()}`);
      const body = await res.json();
      if (!res.ok) throw new Error(body?.error || `HTTP ${res.status}`);
      setRows(Array.isArray(body) ? body : []);
    } catch (e: any) {
      setErr(e.message || "Failed to load returns");
      setRows([]);
    } finally {
      setLoading(false);
    }
  }, [dateFrom, dateTo, machineId]);

  useEffect(() => {
    load();
  }, [load]);

  // Machine filter options are derived from the ledger itself (self-contained;
  // no coupling to the dashboard's machine list). The machine_id filter is applied
  // server-side via the RPC, but we keep the dropdown options from the unscoped set
  // is impractical with 0 rows, so options reflect whatever the current window returned.
  const machineOptions = useMemo(() => {
    const seen = new Map<string, string>();
    for (const r of rows) {
      if (r.machine_id && !seen.has(r.machine_id))
        seen.set(r.machine_id, r.machine_name || r.machine_id);
    }
    return Array.from(seen, ([id, name]) => ({ id, name })).sort((a, b) =>
      a.name.localeCompare(b.name),
    );
  }, [rows]);

  const totals = useMemo(() => {
    const units = rows.reduce((s, r) => s + (Number(r.qty) || 0), 0);
    const skus = new Set(rows.map((r) => r.boonz_product_id).filter(Boolean));
    const machines = new Set(rows.map((r) => r.machine_id).filter(Boolean));
    return { units, skus: skus.size, machines: machines.size };
  }, [rows]);

  const fmtDate = (s: string | null) => (s ? s.slice(0, 10) : "—");
  const fmtDateTime = (s: string) => {
    try {
      return new Date(s).toLocaleString("en-GB", {
        day: "2-digit",
        month: "short",
        hour: "2-digit",
        minute: "2-digit",
      });
    } catch {
      return s;
    }
  };

  return (
    <div style={{ padding: "0 4px" }}>
      <div
        className="cb"
        style={{ borderRadius: 6, marginBottom: 16, flexWrap: "wrap" }}
      >
        <span className="cbl">Returns period</span>
        <input
          type="date"
          value={dateFrom}
          max={dateTo}
          onChange={(e) => setDateFrom(e.target.value)}
        />
        <span style={{ color: "#6b6860", fontSize: 11 }}>to</span>
        <input
          type="date"
          value={dateTo}
          min={dateFrom}
          onChange={(e) => setDateTo(e.target.value)}
        />
        <div className="csep" />
        <span className="cbl">Machine</span>
        <select
          value={machineId}
          onChange={(e) => setMachineId(e.target.value)}
          style={{
            padding: "5px 10px",
            borderRadius: 4,
            fontSize: 11,
            border: "1px solid var(--border)",
            background: "var(--surface)",
            color: "var(--grey2)",
          }}
        >
          <option value="all">All VOX machines</option>
          {machineOptions.map((m) => (
            <option key={m.id} value={m.id}>
              {m.name}
            </option>
          ))}
        </select>
        <div className="csep" />
        <button className="rbtn" onClick={load} disabled={loading}>
          <span style={{ fontSize: 14, lineHeight: 1 }}>
            {loading ? "⏳" : "↻"}
          </span>
          Refresh
        </button>
      </div>

      {/* Footer totals surfaced as cards up top for quick read. */}
      <div style={{ display: "flex", gap: 12, marginBottom: 16, flexWrap: "wrap" }}>
        {[
          { l: "Returned units", v: totals.units.toLocaleString() },
          { l: "Distinct SKUs", v: totals.skus.toLocaleString() },
          { l: "Distinct machines", v: totals.machines.toLocaleString() },
        ].map((c) => (
          <div
            key={c.l}
            style={{
              flex: "1 1 140px",
              border: "1px solid var(--border)",
              borderRadius: 6,
              padding: "12px 16px",
              background: "var(--surface)",
            }}
          >
            <div
              style={{
                fontSize: 9.5,
                letterSpacing: ".1em",
                textTransform: "uppercase",
                color: "var(--grey)",
              }}
            >
              {c.l}
            </div>
            <div style={{ fontSize: 22, fontWeight: 600, marginTop: 4 }}>
              {c.v}
            </div>
          </div>
        ))}
      </div>

      <div
        style={{
          fontSize: 11,
          color: "var(--grey)",
          marginBottom: 10,
          lineHeight: 1.5,
        }}
      >
        VOX returns are logged at receive time and do <strong>not</strong> credit
        warehouse stock (PRD-034 no-WH-credit invariant). This ledger is read-only.
      </div>

      {err && (
        <div
          style={{
            padding: "10px 14px",
            borderRadius: 6,
            background: "#FEF2F2",
            color: "#991B1B",
            border: "1px solid #FECACA",
            fontSize: 12,
            marginBottom: 12,
          }}
        >
          {err}
        </div>
      )}

      <div className="tw">
        <table>
          <thead>
            <tr>
              <th>Date</th>
              <th>Machine</th>
              <th>Product</th>
              <th className="r">Qty</th>
              <th>Expiry</th>
              <th>Source of supply</th>
              <th>Reason</th>
              <th>Received by</th>
            </tr>
          </thead>
          <tbody>
            {loading && rows.length === 0 ? (
              <tr>
                <td colSpan={8} style={{ textAlign: "center", color: "var(--grey)" }}>
                  Loading…
                </td>
              </tr>
            ) : rows.length === 0 ? (
              <tr>
                <td colSpan={8} style={{ textAlign: "center", color: "var(--grey)" }}>
                  No VOX returns in this window.
                </td>
              </tr>
            ) : (
              rows.map((r) => (
                <tr key={r.vox_return_id}>
                  <td>{fmtDateTime(r.received_at)}</td>
                  <td>{r.machine_name || "—"}</td>
                  <td>{r.product_name || "—"}</td>
                  <td className="r">{Number(r.qty).toLocaleString()}</td>
                  <td>{fmtDate(r.expiry_date)}</td>
                  <td>{r.source_of_supply || "—"}</td>
                  <td>{r.reason || "—"}</td>
                  <td>{r.received_by_name || "—"}</td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
