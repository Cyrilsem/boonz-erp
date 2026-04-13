"use client";

import { useMemo, useRef, useState, useCallback } from "react";
import type { Machine, SimCard } from "@/types/machines";
import { PAYMENT_FIELDS, HW_FIELDS } from "@/types/machines";

type SortField =
  | "official_name"
  | "venue_group"
  | "pod_location"
  | "adyen_status"
  | "updated_at";
type SortDir = "asc" | "desc";
type BulkAction =
  | "set_active"
  | "set_inactive"
  | "toggle_refill"
  | "export_csv";

interface MachineTableProps {
  machines: Machine[];
  simMap: Map<string, SimCard>;
  onEdit: (machineId: string) => void;
  onRefillToggle: (machineId: string, value: boolean) => void;
  onBulkAction: (action: BulkAction, machineIds: string[]) => void;
}

const PAGE_SIZE = 25;

const STATUS_BORDER: Record<string, string> = {
  Active: "border-l-green-500",
  Inactive: "border-l-red-500",
  Maintenance: "border-l-amber-500",
  Decommissioned: "border-l-neutral-600",
};

const STATUS_DOT: Record<string, string> = {
  Active: "bg-green-500",
  Inactive: "bg-red-500",
  Maintenance: "bg-amber-500",
  Decommissioned: "bg-neutral-600",
};

function relativeTime(dateStr: string | null): string {
  if (!dateStr) return "—";
  const diff = Date.now() - new Date(dateStr).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  const months = Math.floor(days / 30);
  return `${months}mo ago`;
}

function paymentScore(m: Machine): number {
  return PAYMENT_FIELDS.filter(({ key }) => m[key] === true).length;
}

function hwScore(m: Machine): { pass: number; total: number } {
  const pass = HW_FIELDS.filter(({ key }) => m[key] === true).length;
  return { pass, total: HW_FIELDS.length };
}

function simStatus(
  machineId: string,
  simMap: Map<string, SimCard>,
): "ok" | "warn" | "none" {
  const sim = simMap.get(machineId);
  if (!sim) return "none";
  if (!sim.sim_renewal) return "ok";
  const renewalDiff = new Date(sim.sim_renewal).getTime() - Date.now();
  return renewalDiff < 90 * 24 * 60 * 60 * 1000 ? "warn" : "ok";
}

export default function MachineTable({
  machines,
  simMap,
  onEdit,
  onRefillToggle,
  onBulkAction,
}: MachineTableProps) {
  const [search, setSearch] = useState("");
  const [filterStatus, setFilterStatus] = useState("All");
  const [filterVenue, setFilterVenue] = useState("All");
  const [filterRefill, setFilterRefill] = useState("All");
  const [sortField, setSortField] = useState<SortField>("official_name");
  const [sortDir, setSortDir] = useState<SortDir>("asc");
  const [page, setPage] = useState(1);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [bulkMenuOpen, setBulkMenuOpen] = useState(false);
  const lastSelectedIdx = useRef<number | null>(null);

  const venueGroups = useMemo(() => {
    const groups = Array.from(
      new Set(machines.map((m) => m.venue_group).filter(Boolean)),
    ).sort();
    return groups;
  }, [machines]);

  const filtered = useMemo(() => {
    let result = machines;

    if (search.trim()) {
      const q = search.trim().toLowerCase();
      result = result.filter(
        (m) =>
          m.official_name.toLowerCase().includes(q) ||
          (m.pod_location ?? "").toLowerCase().includes(q) ||
          (m.venue_group ?? "").toLowerCase().includes(q),
      );
    }

    if (filterStatus !== "All") {
      result = result.filter((m) => m.status === filterStatus);
    }

    if (filterVenue !== "All") {
      result = result.filter((m) => m.venue_group === filterVenue);
    }

    if (filterRefill === "Yes") {
      result = result.filter((m) => m.include_in_refill === true);
    } else if (filterRefill === "No") {
      result = result.filter((m) => m.include_in_refill === false);
    }

    return result;
  }, [machines, search, filterStatus, filterVenue, filterRefill]);

  const sorted = useMemo(() => {
    return [...filtered].sort((a, b) => {
      const av = (a[sortField] ?? "") as string;
      const bv = (b[sortField] ?? "") as string;
      const cmp = av.localeCompare(bv);
      return sortDir === "asc" ? cmp : -cmp;
    });
  }, [filtered, sortField, sortDir]);

  const totalPages = Math.max(1, Math.ceil(sorted.length / PAGE_SIZE));
  const safePage = Math.min(page, totalPages);
  const pageSlice = sorted.slice(
    (safePage - 1) * PAGE_SIZE,
    safePage * PAGE_SIZE,
  );

  const handleSort = useCallback(
    (field: SortField) => {
      if (sortField === field) {
        setSortDir((d) => (d === "asc" ? "desc" : "asc"));
      } else {
        setSortField(field);
        setSortDir("asc");
      }
      setPage(1);
    },
    [sortField],
  );

  const handleFilterChange = useCallback(() => {
    setPage(1);
    setSelected(new Set());
    lastSelectedIdx.current = null;
  }, []);

  const handleSearchChange = (v: string) => {
    setSearch(v);
    setPage(1);
    setSelected(new Set());
    lastSelectedIdx.current = null;
  };

  const handleCheckbox = useCallback(
    (machineId: string, rowIdx: number, shiftKey: boolean) => {
      setSelected((prev) => {
        const next = new Set(prev);
        if (shiftKey && lastSelectedIdx.current !== null) {
          const start = Math.min(lastSelectedIdx.current, rowIdx);
          const end = Math.max(lastSelectedIdx.current, rowIdx);
          const rangeIds = pageSlice
            .slice(start, end + 1)
            .map((m) => m.machine_id);
          const allSelected = rangeIds.every((id) => next.has(id));
          if (allSelected) {
            rangeIds.forEach((id) => next.delete(id));
          } else {
            rangeIds.forEach((id) => next.add(id));
          }
        } else {
          if (next.has(machineId)) {
            next.delete(machineId);
          } else {
            next.add(machineId);
          }
        }
        lastSelectedIdx.current = rowIdx;
        return next;
      });
    },
    [pageSlice],
  );

  const handleSelectAll = useCallback(() => {
    if (pageSlice.every((m) => selected.has(m.machine_id))) {
      setSelected((prev) => {
        const next = new Set(prev);
        pageSlice.forEach((m) => next.delete(m.machine_id));
        return next;
      });
    } else {
      setSelected((prev) => {
        const next = new Set(prev);
        pageSlice.forEach((m) => next.add(m.machine_id));
        return next;
      });
    }
  }, [pageSlice, selected]);

  const selectedIds = Array.from(selected);

  const SortIndicator = ({ field }: { field: SortField }) => {
    if (sortField !== field)
      return <span className="ml-1 text-neutral-700">↕</span>;
    return (
      <span className="ml-1 text-neutral-300">
        {sortDir === "asc" ? "↑" : "↓"}
      </span>
    );
  };

  const thClass =
    "px-3 py-2.5 text-left text-[10px] font-medium uppercase tracking-wider text-neutral-500 select-none";
  const thSortClass = `${thClass} cursor-pointer hover:text-neutral-300 transition-colors`;

  return (
    <div className="space-y-3">
      {/* Controls bar */}
      <div className="flex flex-wrap items-center gap-2">
        <input
          type="text"
          value={search}
          onChange={(e) => handleSearchChange(e.target.value)}
          placeholder="Search machines..."
          className="h-8 min-w-[200px] rounded border border-neutral-700 bg-neutral-900 px-3 text-xs text-neutral-200 placeholder-neutral-600 outline-none focus:border-neutral-500"
        />

        <select
          value={filterStatus}
          onChange={(e) => {
            setFilterStatus(e.target.value);
            handleFilterChange();
          }}
          className="h-8 rounded border border-neutral-700 bg-neutral-900 px-2 text-xs text-neutral-300 outline-none focus:border-neutral-500"
        >
          {["All", "Active", "Inactive", "Maintenance", "Decommissioned"].map(
            (s) => (
              <option key={s} value={s}>
                {s === "All" ? "All statuses" : s}
              </option>
            ),
          )}
        </select>

        <select
          value={filterVenue}
          onChange={(e) => {
            setFilterVenue(e.target.value);
            handleFilterChange();
          }}
          className="h-8 max-w-[180px] rounded border border-neutral-700 bg-neutral-900 px-2 text-xs text-neutral-300 outline-none focus:border-neutral-500"
        >
          <option value="All">All venues</option>
          {venueGroups.map((g) => (
            <option key={g} value={g}>
              {g}
            </option>
          ))}
        </select>

        <select
          value={filterRefill}
          onChange={(e) => {
            setFilterRefill(e.target.value);
            handleFilterChange();
          }}
          className="h-8 rounded border border-neutral-700 bg-neutral-900 px-2 text-xs text-neutral-300 outline-none focus:border-neutral-500"
        >
          <option value="All">Refill: All</option>
          <option value="Yes">Refill: Yes</option>
          <option value="No">Refill: No</option>
        </select>

        <div className="ml-auto flex items-center gap-3">
          <span className="text-xs text-neutral-500">
            {filtered.length < machines.length
              ? `Showing ${filtered.length} of ${machines.length} machines`
              : `${machines.length} machine${machines.length !== 1 ? "s" : ""}`}
          </span>

          {selectedIds.length > 0 && (
            <div className="relative">
              <button
                onClick={() => setBulkMenuOpen((v) => !v)}
                className="flex h-8 items-center gap-1.5 rounded border border-neutral-600 bg-neutral-800 px-3 text-xs text-neutral-200 hover:bg-neutral-700 transition-colors"
              >
                Bulk Actions
                <span className="rounded-full bg-neutral-600 px-1.5 py-0.5 text-[10px]">
                  {selectedIds.length}
                </span>
                <span className="text-neutral-500">▼</span>
              </button>
              {bulkMenuOpen && (
                <div className="absolute right-0 top-9 z-20 w-48 rounded border border-neutral-700 bg-[#0f0f18] py-1 shadow-xl">
                  {(
                    [
                      ["set_active", "Set Active"],
                      ["set_inactive", "Set Inactive"],
                      ["toggle_refill", "Toggle Refill"],
                      ["export_csv", "Export CSV"],
                    ] as [BulkAction, string][]
                  ).map(([action, label]) => (
                    <button
                      key={action}
                      onClick={() => {
                        onBulkAction(action, selectedIds);
                        setBulkMenuOpen(false);
                      }}
                      className="w-full px-3 py-2 text-left text-xs text-neutral-300 hover:bg-neutral-800 hover:text-neutral-100 transition-colors"
                    >
                      {label}
                    </button>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>
      </div>

      {/* Table */}
      <div className="overflow-x-auto rounded-lg border border-neutral-800">
        <table className="w-full text-sm">
          <thead>
            <tr className="bg-[#0f0f18]">
              <th className={thClass} style={{ width: 36 }}>
                <input
                  type="checkbox"
                  checked={
                    pageSlice.length > 0 &&
                    pageSlice.every((m) => selected.has(m.machine_id))
                  }
                  onChange={handleSelectAll}
                  className="accent-indigo-500"
                />
              </th>
              <th
                className={thSortClass}
                onClick={() => handleSort("official_name")}
                style={{ minWidth: 180 }}
              >
                Machine <SortIndicator field="official_name" />
              </th>
              <th
                className={thSortClass}
                onClick={() => handleSort("venue_group")}
              >
                Venue <SortIndicator field="venue_group" />
              </th>
              <th
                className={thSortClass}
                onClick={() => handleSort("pod_location")}
              >
                Location <SortIndicator field="pod_location" />
              </th>
              <th
                className={thSortClass}
                onClick={() => handleSort("adyen_status")}
              >
                Adyen <SortIndicator field="adyen_status" />
              </th>
              <th className={thClass}>Payment</th>
              <th className={thClass}>HW</th>
              <th className={thClass}>SIM</th>
              <th className={thClass}>Refill</th>
              <th
                className={thSortClass}
                onClick={() => handleSort("updated_at")}
              >
                Updated <SortIndicator field="updated_at" />
              </th>
            </tr>
          </thead>
          <tbody>
            {pageSlice.length === 0 ? (
              <tr>
                <td
                  colSpan={10}
                  className="px-4 py-12 text-center text-sm text-neutral-600"
                >
                  No machines match the current filters.
                </td>
              </tr>
            ) : (
              pageSlice.map((m, rowIdx) => {
                const isSelected = selected.has(m.machine_id);
                const borderClass =
                  STATUS_BORDER[m.status ?? ""] ?? "border-l-neutral-700";
                const dotClass = STATUS_DOT[m.status ?? ""] ?? "bg-neutral-700";
                const payScore = paymentScore(m);
                const payColor =
                  payScore === 10
                    ? "text-green-400"
                    : payScore >= 5
                      ? "text-amber-400"
                      : "text-red-400";
                const payBarColor =
                  payScore === 10
                    ? "bg-green-500"
                    : payScore >= 5
                      ? "bg-amber-500"
                      : "bg-red-500";
                const hw = hwScore(m);
                const simStat = simStatus(m.machine_id, simMap);

                return (
                  <tr
                    key={m.machine_id}
                    onClick={() => onEdit(m.machine_id)}
                    className={`cursor-pointer border-t border-neutral-800/60 border-l-4 ${borderClass} transition-colors ${
                      isSelected
                        ? "bg-[#1a1a2e]"
                        : "bg-[#0a0a0f] hover:bg-[#141420]"
                    }`}
                  >
                    {/* Checkbox */}
                    <td
                      className="px-3 py-2.5"
                      onClick={(e) => e.stopPropagation()}
                    >
                      <input
                        type="checkbox"
                        checked={isSelected}
                        onChange={(e) =>
                          handleCheckbox(
                            m.machine_id,
                            rowIdx,
                            e.nativeEvent instanceof MouseEvent
                              ? (e.nativeEvent as MouseEvent).shiftKey
                              : false,
                          )
                        }
                        onClick={(e) => {
                          e.stopPropagation();
                          handleCheckbox(
                            m.machine_id,
                            rowIdx,
                            (e as React.MouseEvent).shiftKey,
                          );
                        }}
                        className="accent-indigo-500"
                      />
                    </td>

                    {/* Machine name + status dot */}
                    <td className="px-3 py-2.5">
                      <div className="flex items-center gap-2">
                        <span
                          className={`h-1.5 w-1.5 flex-shrink-0 rounded-full ${dotClass}`}
                        />
                        <span className="font-mono text-xs font-bold text-neutral-100">
                          {m.official_name}
                        </span>
                      </div>
                    </td>

                    {/* Venue */}
                    <td className="px-3 py-2.5 text-xs text-neutral-400">
                      {m.venue_group || "—"}
                    </td>

                    {/* Location */}
                    <td className="max-w-[160px] px-3 py-2.5">
                      <span
                        className="block truncate text-xs text-neutral-400"
                        title={m.pod_location ?? ""}
                      >
                        {m.pod_location || "—"}
                      </span>
                    </td>

                    {/* Adyen status */}
                    <td className="px-3 py-2.5 text-xs text-neutral-400">
                      {m.adyen_status || "—"}
                    </td>

                    {/* Payment % */}
                    <td className="px-3 py-2.5">
                      <div className="flex items-center gap-1.5">
                        <span
                          className={`font-mono text-xs font-semibold ${payColor}`}
                        >
                          {payScore}/10
                        </span>
                        <div className="h-1 w-14 overflow-hidden rounded-full bg-neutral-800">
                          <div
                            className={`h-full rounded-full ${payBarColor}`}
                            style={{ width: `${(payScore / 10) * 100}%` }}
                          />
                        </div>
                      </div>
                    </td>

                    {/* HW */}
                    <td className="px-3 py-2.5 font-mono text-xs">
                      {hw.pass === hw.total ? (
                        <span className="text-green-400">✓</span>
                      ) : (
                        <span className="text-red-400">
                          ✗ {hw.pass}/{hw.total}
                        </span>
                      )}
                    </td>

                    {/* SIM */}
                    <td className="px-3 py-2.5">
                      {simStat === "none" ? (
                        <span className="text-neutral-600 text-xs">—</span>
                      ) : simStat === "ok" ? (
                        <span
                          className="inline-block h-2 w-2 rounded-full bg-green-500"
                          title="SIM linked"
                        />
                      ) : (
                        <span
                          className="inline-block h-2 w-2 rounded-full bg-amber-400"
                          title="SIM renewal <90 days"
                        />
                      )}
                    </td>

                    {/* Refill toggle */}
                    <td
                      className="px-3 py-2.5"
                      onClick={(e) => e.stopPropagation()}
                    >
                      <button
                        role="switch"
                        aria-checked={m.include_in_refill}
                        onClick={(e) => {
                          e.stopPropagation();
                          onRefillToggle(m.machine_id, !m.include_in_refill);
                        }}
                        className={`relative inline-flex h-4 w-7 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 focus:outline-none ${
                          m.include_in_refill
                            ? "bg-indigo-600"
                            : "bg-neutral-700"
                        }`}
                      >
                        <span
                          className={`inline-block h-3 w-3 transform rounded-full bg-white shadow transition duration-200 ${
                            m.include_in_refill
                              ? "translate-x-3"
                              : "translate-x-0"
                          }`}
                        />
                      </button>
                    </td>

                    {/* Updated */}
                    <td className="px-3 py-2.5 text-xs text-neutral-600">
                      {relativeTime(m.updated_at)}
                    </td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="flex items-center justify-between text-xs text-neutral-500">
          <span>
            Page {safePage} of {totalPages}
          </span>
          <div className="flex gap-1">
            <button
              onClick={() => setPage(1)}
              disabled={safePage === 1}
              className="rounded border border-neutral-800 bg-neutral-900 px-2 py-1 hover:bg-neutral-800 disabled:opacity-30"
            >
              «
            </button>
            <button
              onClick={() => setPage((p) => Math.max(1, p - 1))}
              disabled={safePage === 1}
              className="rounded border border-neutral-800 bg-neutral-900 px-2 py-1 hover:bg-neutral-800 disabled:opacity-30"
            >
              ‹
            </button>
            {Array.from({ length: Math.min(5, totalPages) }, (_, i) => {
              const start = Math.max(1, Math.min(safePage - 2, totalPages - 4));
              const p = start + i;
              return (
                <button
                  key={p}
                  onClick={() => setPage(p)}
                  className={`rounded border px-2 py-1 ${
                    p === safePage
                      ? "border-indigo-700 bg-indigo-900/50 text-indigo-300"
                      : "border-neutral-800 bg-neutral-900 hover:bg-neutral-800"
                  }`}
                >
                  {p}
                </button>
              );
            })}
            <button
              onClick={() => setPage((p) => Math.min(totalPages, p + 1))}
              disabled={safePage === totalPages}
              className="rounded border border-neutral-800 bg-neutral-900 px-2 py-1 hover:bg-neutral-800 disabled:opacity-30"
            >
              ›
            </button>
            <button
              onClick={() => setPage(totalPages)}
              disabled={safePage === totalPages}
              className="rounded border border-neutral-800 bg-neutral-900 px-2 py-1 hover:bg-neutral-800 disabled:opacity-30"
            >
              »
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
