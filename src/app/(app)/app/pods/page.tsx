"use client";

import { useEffect, useState, useMemo } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";

// ─── Types ────────────────────────────────────────────────────────────────────

interface Machine {
  machine_id: string;
  official_name: string;
  venue_group: string | null;
  status: string | null;
  include_in_refill: boolean | null;
  pod_location: string | null;
  adyen_status: string | null;
  adyen_inventory_in_store: boolean | null;
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function PodsPage() {
  const [machines, setMachines] = useState<Machine[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState<
    "All" | "Active" | "Inactive"
  >("All");
  const [groupFilter, setGroupFilter] = useState("All");

  useEffect(() => {
    async function load() {
      const supabase = createClient();
      const { data } = await supabase
        .from("machines")
        .select(
          "machine_id, official_name, venue_group, status, include_in_refill, pod_location, adyen_status, adyen_inventory_in_store",
        )
        .order("official_name")
        .limit(10000);
      setMachines(data ?? []);
      setLoading(false);
    }
    load();
  }, []);

  // ── Derived lists ────────────────────────────────────────────────────────────
  const groups = useMemo(() => {
    const set = new Set<string>();
    for (const m of machines) if (m.venue_group) set.add(m.venue_group);
    return ["All", ...Array.from(set).sort()];
  }, [machines]);

  const filtered = useMemo(() => {
    return machines.filter((m) => {
      if (
        search &&
        !m.official_name.toLowerCase().includes(search.toLowerCase())
      )
        return false;
      if (statusFilter !== "All") {
        const isActive = m.status?.toLowerCase() === "active";
        if (statusFilter === "Active" && !isActive) return false;
        if (statusFilter === "Inactive" && isActive) return false;
      }
      if (groupFilter !== "All" && m.venue_group !== groupFilter) return false;
      return true;
    });
  }, [machines, search, statusFilter, groupFilter]);

  return (
    <div className="p-8 max-w-7xl">
      {/* ── Header ──────────────────────────────────────────────────────────── */}
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
            Pods
          </h1>
          <p style={{ color: "#6b6860", fontSize: 14, marginTop: 4 }}>
            {loading ? "Loading…" : `${machines.length} machines`}
          </p>
        </div>
        <Link
          href="/field/config/machines"
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
          Manage →
        </Link>
      </div>

      {/* ── Filter bar ──────────────────────────────────────────────────────── */}
      <div
        className="flex items-center gap-3 flex-wrap mb-6"
        style={{ borderBottom: "1px solid #e8e4de", paddingBottom: 16 }}
      >
        <input
          type="text"
          placeholder="Search machines…"
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
          value={groupFilter}
          onChange={(e) => setGroupFilter(e.target.value)}
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
          {groups.map((g) => (
            <option key={g} value={g}>
              {g === "All" ? "All groups" : g}
            </option>
          ))}
        </select>
        {!loading && (
          <span style={{ marginLeft: "auto", fontSize: 13, color: "#6b6860" }}>
            {filtered.length} result{filtered.length !== 1 ? "s" : ""}
          </span>
        )}
      </div>

      {/* ── Table ───────────────────────────────────────────────────────────── */}
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
                "Name",
                "Group",
                "Location",
                "Adyen Status",
                "In-Store",
                "Refill",
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
              Array.from({ length: 8 }).map((_, i) => (
                <tr key={i} style={{ borderBottom: "1px solid #f5f2ee" }}>
                  {[200, 80, 140, 100, 60, 50, 70].map((w, j) => (
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
                  No machines match your filters.
                </td>
              </tr>
            ) : (
              filtered.map((m) => {
                const isActive = m.status?.toLowerCase() === "active";
                return (
                  <tr
                    key={m.machine_id}
                    style={{
                      borderBottom: "1px solid #f5f2ee",
                      cursor: "pointer",
                    }}
                    onClick={() =>
                      (window.location.href = "/field/config/machines")
                    }
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
                      style={{ fontWeight: 600, color: "#24544a" }}
                    >
                      {m.official_name}
                    </td>
                    <td className="px-4 py-3" style={{ color: "#6b6860" }}>
                      {m.venue_group ?? "—"}
                    </td>
                    <td
                      className="px-4 py-3 max-w-[160px] truncate"
                      style={{ color: "#0a0a0a" }}
                      title={m.pod_location ?? undefined}
                    >
                      {m.pod_location ?? "—"}
                    </td>
                    <td className="px-4 py-3" style={{ color: "#6b6860" }}>
                      {m.adyen_status ?? "—"}
                    </td>
                    <td className="px-4 py-3 text-center">
                      {m.adyen_inventory_in_store ? (
                        <span style={{ color: "#24544a", fontWeight: 700 }}>
                          ✓
                        </span>
                      ) : (
                        <span style={{ color: "#d1ccc7" }}>—</span>
                      )}
                    </td>
                    <td className="px-4 py-3 text-center">
                      {m.include_in_refill ? (
                        <span style={{ color: "#24544a", fontWeight: 700 }}>
                          ✓
                        </span>
                      ) : (
                        <span style={{ color: "#d1ccc7" }}>—</span>
                      )}
                    </td>
                    <td className="px-4 py-3">
                      <span
                        style={{
                          display: "inline-block",
                          padding: "2px 10px",
                          borderRadius: 20,
                          fontSize: 11,
                          fontWeight: 600,
                          background: isActive ? "#f0fdf4" : "#f5f2ee",
                          color: isActive ? "#065f46" : "#6b6860",
                        }}
                      >
                        {m.status ?? "—"}
                      </span>
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
