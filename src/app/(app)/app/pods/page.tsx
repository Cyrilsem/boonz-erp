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
  pod_address: string | null;
  adyen_status: string | null;
  adyen_inventory_in_store: boolean | null;
  location_type: string | null;
  contact_person: string | null;
  contact_phone: string | null;
  contact_email: string | null;
  installation_date: string | null;
  notes: string | null;
  serial_number: string | null;
  adyen_unique_terminal_id: string | null;
  adyen_store_code: string | null;
  micron_app_id: string | null;
  app_version: string | null;
  wifi_network_name: string | null;
  payment_terminal_installed: boolean | null;
  hw_compressor_ok: boolean | null;
  hw_calibration_ok: boolean | null;
  hw_door_spring_ok: boolean | null;
  hw_test_successful: boolean | null;
  cabinet_count: number | null;
  source_of_supply: string | null;
}

type DrawerTab = "overview" | "setup";

// ─── Drawer Field component ──────────────────────────────────────────────────

function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div style={{ marginBottom: 14 }}>
      <div
        style={{
          fontSize: 10,
          fontWeight: 500,
          letterSpacing: "0.08em",
          textTransform: "uppercase",
          color: "#6b6860",
          marginBottom: 3,
        }}
      >
        {label}
      </div>
      <div style={{ fontSize: 14, color: "#0a0a0a" }}>{value ?? "—"}</div>
    </div>
  );
}

function BoolField({ label, value }: { label: string; value: boolean | null }) {
  return (
    <Field
      label={label}
      value={
        value === true ? (
          <span style={{ color: "#24544a", fontWeight: 600 }}>Yes</span>
        ) : value === false ? (
          <span style={{ color: "#6b6860" }}>No</span>
        ) : (
          "—"
        )
      }
    />
  );
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
  const [selected, setSelected] = useState<Machine | null>(null);
  const [drawerTab, setDrawerTab] = useState<DrawerTab>("overview");

  useEffect(() => {
    async function load() {
      const supabase = createClient();
      const { data } = await supabase
        .from("machines")
        .select(
          "machine_id, official_name, venue_group, status, include_in_refill, pod_location, pod_address, adyen_status, adyen_inventory_in_store, location_type, contact_person, contact_phone, contact_email, installation_date, notes, serial_number, adyen_unique_terminal_id, adyen_store_code, micron_app_id, app_version, wifi_network_name, payment_terminal_installed, hw_compressor_ok, hw_calibration_ok, hw_door_spring_ok, hw_test_successful, cabinet_count, source_of_supply",
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
                      background:
                        selected?.machine_id === m.machine_id
                          ? "#f0fdf4"
                          : undefined,
                    }}
                    onClick={() => {
                      setSelected(m);
                      setDrawerTab("overview");
                    }}
                    onMouseEnter={(e) => {
                      if (selected?.machine_id !== m.machine_id)
                        (
                          e.currentTarget as HTMLTableRowElement
                        ).style.background = "#faf9f7";
                    }}
                    onMouseLeave={(e) => {
                      if (selected?.machine_id !== m.machine_id)
                        (
                          e.currentTarget as HTMLTableRowElement
                        ).style.background = "transparent";
                    }}
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
                        <span style={{ color: "#9a948e" }}>—</span>
                      )}
                    </td>
                    <td className="px-4 py-3 text-center">
                      {m.include_in_refill ? (
                        <span style={{ color: "#24544a", fontWeight: 700 }}>
                          ✓
                        </span>
                      ) : (
                        <span style={{ color: "#9a948e" }}>—</span>
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

      {/* ── Slide-over drawer ──────────────────────────────────────────────── */}
      {selected && (
        <>
          {/* Backdrop */}
          <div
            onClick={() => setSelected(null)}
            style={{
              position: "fixed",
              inset: 0,
              background: "rgba(0,0,0,0.25)",
              zIndex: 40,
            }}
          />
          {/* Drawer */}
          <div
            style={{
              position: "fixed",
              top: 0,
              right: 0,
              bottom: 0,
              width: 520,
              maxWidth: "100vw",
              background: "white",
              zIndex: 50,
              boxShadow: "-4px 0 24px rgba(0,0,0,0.08)",
              display: "flex",
              flexDirection: "column",
              fontFamily: "'Plus Jakarta Sans', sans-serif",
            }}
          >
            {/* Drawer header */}
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
                  {selected.official_name}
                </h2>
                <span
                  style={{
                    display: "inline-block",
                    marginTop: 4,
                    padding: "2px 10px",
                    borderRadius: 20,
                    fontSize: 11,
                    fontWeight: 600,
                    background:
                      selected.status?.toLowerCase() === "active"
                        ? "#f0fdf4"
                        : "#f5f2ee",
                    color:
                      selected.status?.toLowerCase() === "active"
                        ? "#065f46"
                        : "#6b6860",
                  }}
                >
                  {selected.status ?? "—"}
                </span>
              </div>
              <button
                onClick={() => setSelected(null)}
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

            {/* Drawer tabs */}
            <div
              style={{
                display: "flex",
                borderBottom: "1px solid #e8e4de",
              }}
            >
              {(["overview", "setup"] as const).map((t) => (
                <button
                  key={t}
                  onClick={() => setDrawerTab(t)}
                  style={{
                    flex: 1,
                    padding: "10px 16px",
                    fontSize: 13,
                    fontWeight: drawerTab === t ? 700 : 400,
                    color: drawerTab === t ? "#24544a" : "#6b6860",
                    background: "none",
                    border: "none",
                    borderBottom:
                      drawerTab === t
                        ? "2px solid #24544a"
                        : "2px solid transparent",
                    cursor: "pointer",
                  }}
                >
                  {t === "overview" ? "Overview" : "Setup Config"}
                </button>
              ))}
            </div>

            {/* Drawer content */}
            <div style={{ flex: 1, overflow: "auto", padding: "20px 24px" }}>
              {drawerTab === "overview" ? (
                <>
                  <div
                    style={{
                      fontSize: 10,
                      fontWeight: 500,
                      letterSpacing: "0.1em",
                      textTransform: "uppercase",
                      color: "#6b6860",
                      marginBottom: 16,
                    }}
                  >
                    Machine Details
                  </div>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr",
                      gap: "0 20px",
                    }}
                  >
                    <Field label="Venue Group" value={selected.venue_group} />
                    <Field
                      label="Location Type"
                      value={selected.location_type}
                    />
                    <Field label="Location" value={selected.pod_location} />
                    <Field label="Address" value={selected.pod_address} />
                    <Field
                      label="Supply Source"
                      value={selected.source_of_supply}
                    />
                    <Field
                      label="Cabinets"
                      value={selected.cabinet_count?.toString()}
                    />
                    <BoolField
                      label="Include in Refill"
                      value={selected.include_in_refill}
                    />
                    <Field
                      label="Installation Date"
                      value={selected.installation_date}
                    />
                  </div>

                  <div
                    style={{
                      fontSize: 10,
                      fontWeight: 500,
                      letterSpacing: "0.1em",
                      textTransform: "uppercase",
                      color: "#6b6860",
                      margin: "24px 0 16px",
                    }}
                  >
                    Contact
                  </div>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr",
                      gap: "0 20px",
                    }}
                  >
                    <Field label="Person" value={selected.contact_person} />
                    <Field label="Phone" value={selected.contact_phone} />
                    <Field label="Email" value={selected.contact_email} />
                  </div>

                  <div
                    style={{
                      fontSize: 10,
                      fontWeight: 500,
                      letterSpacing: "0.1em",
                      textTransform: "uppercase",
                      color: "#6b6860",
                      margin: "24px 0 16px",
                    }}
                  >
                    Adyen Payment
                  </div>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr",
                      gap: "0 20px",
                    }}
                  >
                    <Field label="Adyen Status" value={selected.adyen_status} />
                    <BoolField
                      label="Inventory In-Store"
                      value={selected.adyen_inventory_in_store}
                    />
                    <Field
                      label="Terminal ID"
                      value={selected.adyen_unique_terminal_id}
                    />
                    <Field
                      label="Store Code"
                      value={selected.adyen_store_code}
                    />
                  </div>

                  {selected.notes && (
                    <>
                      <div
                        style={{
                          fontSize: 10,
                          fontWeight: 500,
                          letterSpacing: "0.1em",
                          textTransform: "uppercase",
                          color: "#6b6860",
                          margin: "24px 0 8px",
                        }}
                      >
                        Notes
                      </div>
                      <div
                        style={{
                          fontSize: 13,
                          color: "#4a4845",
                          background: "#faf9f7",
                          borderRadius: 8,
                          padding: "12px 14px",
                          lineHeight: 1.5,
                        }}
                      >
                        {selected.notes}
                      </div>
                    </>
                  )}
                </>
              ) : (
                <>
                  <div
                    style={{
                      fontSize: 10,
                      fontWeight: 500,
                      letterSpacing: "0.1em",
                      textTransform: "uppercase",
                      color: "#6b6860",
                      marginBottom: 16,
                    }}
                  >
                    Hardware
                  </div>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr",
                      gap: "0 20px",
                    }}
                  >
                    <Field
                      label="Serial Number"
                      value={selected.serial_number}
                    />
                    <Field
                      label="Micron App ID"
                      value={selected.micron_app_id}
                    />
                    <Field label="App Version" value={selected.app_version} />
                    <Field
                      label="Wi-Fi Network"
                      value={selected.wifi_network_name}
                    />
                    <BoolField
                      label="Payment Terminal"
                      value={selected.payment_terminal_installed}
                    />
                  </div>

                  <div
                    style={{
                      fontSize: 10,
                      fontWeight: 500,
                      letterSpacing: "0.1em",
                      textTransform: "uppercase",
                      color: "#6b6860",
                      margin: "24px 0 16px",
                    }}
                  >
                    Hardware Checks
                  </div>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr",
                      gap: "0 20px",
                    }}
                  >
                    <BoolField
                      label="Compressor OK"
                      value={selected.hw_compressor_ok}
                    />
                    <BoolField
                      label="Calibration OK"
                      value={selected.hw_calibration_ok}
                    />
                    <BoolField
                      label="Door Spring OK"
                      value={selected.hw_door_spring_ok}
                    />
                    <BoolField
                      label="Test Successful"
                      value={selected.hw_test_successful}
                    />
                  </div>
                </>
              )}
            </div>

            {/* Drawer footer */}
            <div
              style={{
                padding: "14px 24px",
                borderTop: "1px solid #e8e4de",
              }}
            >
              <Link
                href="/field/config/machines"
                style={{
                  display: "inline-flex",
                  alignItems: "center",
                  gap: 6,
                  background: "#24544a",
                  color: "white",
                  borderRadius: 8,
                  padding: "8px 20px",
                  fontSize: 14,
                  fontWeight: 600,
                  textDecoration: "none",
                }}
              >
                Manage →
              </Link>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
