"use client";

import { useState, useEffect, useMemo } from "react";
import { createClient } from "@/lib/supabase/client";
import Link from "next/link";

// ── Types ──────────────────────────────────────────────────────────────────────

type DispatchRow = {
  dispatch_date: string;
  shelf_id: string | null;
  action: string;
  quantity: number;
  comment: string | null;
  pod_product_name: string;
  machine_id: string;
  machine_name: string;
  pod_address: string | null;
  latitude: number | null;
  longitude: number | null;
  venue_group: string | null;
  building_id: string | null;
};

type MachineStop = {
  machine_id: string;
  machine_name: string;
  pod_address: string | null;
  latitude: number | null;
  longitude: number | null;
  venue_group: string | null;
  building_id: string | null;
  lines: DispatchRow[];
  actionable_count: number;
  total_units: number;
  trip: 1 | 2;
  cluster: "west" | "east" | "unknown";
};

type PackItem = {
  product: string;
  total_units: number;
  machines: string[];
};

// ── Helpers ────────────────────────────────────────────────────────────────────

/**
 * Count actionable lines:
 * - REFILL with qty >= 1  → 1 each
 * - SWAP pairs (Add New + Remove together) → each individual counts as 0.5,
 *   so a matched pair = 1
 * - Floor-only (qty = 1 REFILL) or REMOVE alone → 0.5 each
 */
function countActionable(lines: DispatchRow[]): number {
  let count = 0;
  for (const l of lines) {
    const action = (l.action ?? "").toLowerCase();
    if (action === "refill" && l.quantity >= 2) count += 1;
    else if (action === "refill" && l.quantity === 1) count += 0.5;
    else if (action === "add new") count += 0.5;
    else if (action === "remove") count += 0.5;
  }
  return count;
}

/** Lat < 25.12 = West (JLT, Marina, Harbour, Media City, JBR) */
function getCluster(lat: number | null): "west" | "east" | "unknown" {
  if (lat === null) return "unknown";
  return lat < 25.12 ? "west" : "east";
}

function mapsLink(
  lat: number | null,
  lng: number | null,
  name: string,
): string {
  if (lat && lng) return `https://maps.google.com/?q=${lat},${lng}`;
  return `https://maps.google.com/?q=${encodeURIComponent(name)}`;
}

function hasSpecialNote(comment: string | null): boolean {
  if (!comment) return false;
  const c = comment.toUpperCase();
  return (
    c.includes("AUDIT") || c.includes("PERISHABLE") || c.includes("EXPIRY")
  );
}

// ── Component ──────────────────────────────────────────────────────────────────

export default function DriverRoutePage() {
  const [rows, setRows] = useState<DispatchRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [expandedStops, setExpandedStops] = useState<Set<string>>(new Set());

  useEffect(() => {
    const supabase = createClient();
    (async () => {
      const { data, error } = await supabase.rpc("get_next_dispatch_route");
      if (!error && data) {
        setRows(data as DispatchRow[]);
      } else {
        // Fallback: manual query via view/join
        const { data: d2 } = await supabase
          .from("refill_dispatching")
          .select(
            `dispatch_date, shelf_id, action, quantity, comment,
             pod_product_id,
             machines!inner(machine_id, official_name, pod_address, latitude, longitude, venue_group, building_id),
             pod_products!inner(pod_product_name)`,
          )
          .eq("include", true)
          .eq("dispatched", false)
          .limit(10000);
        if (d2 && d2.length > 0) {
          // Find min dispatch_date
          const minDate = d2.reduce((m: string, r: Record<string, unknown>) => {
            const d = r.dispatch_date as string;
            return !m || d < m ? d : m;
          }, "");
          const filtered = d2
            .filter((r: Record<string, unknown>) => r.dispatch_date === minDate)
            .map((r: Record<string, unknown>) => {
              const m = r.machines as Record<string, unknown>;
              const pp = r.pod_products as Record<string, unknown>;
              return {
                dispatch_date: r.dispatch_date as string,
                shelf_id: r.shelf_id as string | null,
                action: r.action as string,
                quantity: r.quantity as number,
                comment: r.comment as string | null,
                pod_product_name: (pp?.pod_product_name ?? "") as string,
                machine_id: (m?.machine_id ?? "") as string,
                machine_name: (m?.official_name ?? "") as string,
                pod_address: (m?.pod_address ?? null) as string | null,
                latitude: (m?.latitude ?? null) as number | null,
                longitude: (m?.longitude ?? null) as number | null,
                venue_group: (m?.venue_group ?? null) as string | null,
                building_id: (m?.building_id ?? null) as string | null,
              } as DispatchRow;
            });
          setRows(filtered);
        }
      }
      setLoading(false);
    })();
  }, []);

  // ── Build machine stops ────────────────────────────────────────────────────
  const { trip1, trip2, packList, dispatchDate, totalStops, totalUnits } =
    useMemo(() => {
      if (rows.length === 0) {
        return {
          trip1: [] as MachineStop[],
          trip2: [] as MachineStop[],
          packList: [] as PackItem[],
          dispatchDate: "",
          totalStops: 0,
          totalUnits: 0,
        };
      }

      const dispatchDate = rows[0].dispatch_date;

      // Group by machine
      const machineMap = new Map<string, DispatchRow[]>();
      for (const row of rows) {
        if (!machineMap.has(row.machine_id)) machineMap.set(row.machine_id, []);
        machineMap.get(row.machine_id)!.push(row);
      }

      // Build raw stops
      const rawStops: MachineStop[] = Array.from(machineMap.entries()).map(
        ([machine_id, lines]) => {
          const r = lines[0];
          const cluster = getCluster(r.latitude);
          return {
            machine_id,
            machine_name: r.machine_name,
            pod_address: r.pod_address,
            latitude: r.latitude,
            longitude: r.longitude,
            venue_group: r.venue_group,
            building_id: r.building_id,
            lines,
            actionable_count: countActionable(lines),
            total_units: lines.reduce((s, l) => s + (l.quantity ?? 0), 0),
            trip: cluster === "east" ? 2 : 1,
            cluster,
          };
        },
      );

      // Apply minimum-stop rule: include if actionable >= 2 OR shares
      // building_id / pod_address with another stop that qualifies
      const qualifiedIds = new Set(
        rawStops
          .filter((s) => s.actionable_count >= 2)
          .map((s) => s.machine_id),
      );

      // Co-location check: if machine shares building_id or pod_address with
      // a qualified machine, include it regardless
      const qualifiedBuildingIds = new Set(
        rawStops
          .filter((s) => qualifiedIds.has(s.machine_id) && s.building_id)
          .map((s) => s.building_id!),
      );
      const qualifiedAddresses = new Set(
        rawStops
          .filter((s) => qualifiedIds.has(s.machine_id) && s.pod_address)
          .map((s) => s.pod_address!),
      );

      const includedStops = rawStops.filter(
        (s) =>
          qualifiedIds.has(s.machine_id) ||
          (s.building_id && qualifiedBuildingIds.has(s.building_id)) ||
          (s.pod_address && qualifiedAddresses.has(s.pod_address)),
      );

      // Sort within each trip by longitude west→east
      const sortedStops = [...includedStops].sort((a, b) => {
        if (a.trip !== b.trip) return a.trip - b.trip;
        const lngA = a.longitude ?? 55.3;
        const lngB = b.longitude ?? 55.3;
        return lngA - lngB;
      });

      const trip1 = sortedStops.filter((s) => s.trip === 1);
      const trip2 = sortedStops.filter((s) => s.trip === 2);

      // Pack list (route order, all stops)
      const productMap = new Map<
        string,
        { units: number; machines: Set<string> }
      >();
      for (const stop of sortedStops) {
        for (const line of stop.lines) {
          if (!line.pod_product_name) continue;
          if (!productMap.has(line.pod_product_name)) {
            productMap.set(line.pod_product_name, {
              units: 0,
              machines: new Set(),
            });
          }
          const entry = productMap.get(line.pod_product_name)!;
          entry.units += line.quantity ?? 0;
          entry.machines.add(stop.machine_name);
        }
      }
      const packList: PackItem[] = Array.from(productMap.entries())
        .map(([product, { units, machines }]) => ({
          product,
          total_units: units,
          machines: Array.from(machines),
        }))
        .sort((a, b) => b.total_units - a.total_units);

      const totalStops = sortedStops.length;
      const totalUnits = sortedStops.reduce((s, st) => s + st.total_units, 0);

      return { trip1, trip2, packList, dispatchDate, totalStops, totalUnits };
    }, [rows]);

  // ── Full route URL ─────────────────────────────────────────────────────────
  const allStops = [...trip1, ...trip2];
  const fullRouteUrl =
    allStops.filter((s) => s.latitude && s.longitude).length >= 2
      ? `https://www.google.com/maps/dir/${allStops
          .filter((s) => s.latitude && s.longitude)
          .map((s) => `${s.latitude},${s.longitude}`)
          .join("/")}`
      : null;

  function toggleStop(id: string) {
    setExpandedStops((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  // ── Render helpers ─────────────────────────────────────────────────────────
  function StopCard({
    stop,
    accent,
  }: {
    stop: MachineStop;
    accent: "blue" | "orange";
  }) {
    const expanded = expandedStops.has(stop.machine_id);
    const borderColor =
      accent === "blue" ? "border-blue-300" : "border-orange-300";
    const headerBg = accent === "blue" ? "bg-blue-50" : "bg-orange-50";
    const badgeBg =
      accent === "blue"
        ? "bg-blue-100 text-blue-800"
        : "bg-orange-100 text-orange-800";
    const mapsUrl = mapsLink(stop.latitude, stop.longitude, stop.machine_name);

    return (
      <div
        className={`border-2 ${borderColor} rounded-xl overflow-hidden mb-4`}
      >
        {/* Header */}
        <div className={`${headerBg} px-4 py-3`}>
          <div className="flex items-start justify-between gap-3">
            <button
              onClick={() => toggleStop(stop.machine_id)}
              className="flex-1 text-left"
            >
              <div className="font-semibold text-gray-900 text-base leading-tight">
                {stop.machine_name}
              </div>
              {stop.pod_address && (
                <div className="text-sm text-gray-500 mt-0.5">
                  {stop.pod_address}
                </div>
              )}
            </button>
            <div className="flex items-center gap-2 flex-shrink-0">
              <span
                className={`text-xs font-semibold px-2.5 py-1 rounded-full ${badgeBg}`}
              >
                {stop.lines.length} line{stop.lines.length !== 1 ? "s" : ""} ·{" "}
                {stop.total_units} unit{stop.total_units !== 1 ? "s" : ""}
              </span>
              <a
                href={mapsUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="text-xs font-medium text-blue-600 underline whitespace-nowrap"
                onClick={(e) => e.stopPropagation()}
              >
                📍 Maps
              </a>
            </div>
          </div>
          <button
            onClick={() => toggleStop(stop.machine_id)}
            className="text-xs text-gray-400 mt-1"
          >
            {expanded ? "▲ collapse" : "▼ expand actions"}
          </button>
        </div>

        {/* Lines */}
        {expanded && (
          <div className="divide-y divide-gray-100">
            {stop.lines.map((line, i) => {
              const isSpecial = hasSpecialNote(line.comment);
              return (
                <div
                  key={i}
                  className="px-4 py-3 flex items-start justify-between gap-3"
                >
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 flex-wrap">
                      <span className="text-xs font-mono text-gray-400">
                        {line.shelf_id ?? "—"}
                      </span>
                      <span className="font-medium text-sm text-gray-900 truncate">
                        {line.pod_product_name}
                      </span>
                      {isSpecial && (
                        <span className="bg-yellow-100 text-yellow-800 text-xs font-bold px-2 py-0.5 rounded">
                          ⚠️ {line.comment}
                        </span>
                      )}
                    </div>
                    {line.comment && !isSpecial && (
                      <p className="text-xs text-gray-400 mt-0.5">
                        {line.comment}
                      </p>
                    )}
                  </div>
                  <div className="flex-shrink-0 text-right">
                    <div className="text-sm font-semibold text-gray-900">
                      {line.quantity} unit{line.quantity !== 1 ? "s" : ""}
                    </div>
                    <div className="text-xs text-gray-400">{line.action}</div>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>
    );
  }

  // ── UI ─────────────────────────────────────────────────────────────────────
  if (loading) {
    return (
      <div className="max-w-2xl mx-auto px-4 py-12 text-center text-gray-400">
        Loading route…
      </div>
    );
  }

  if (rows.length === 0) {
    return (
      <div className="max-w-2xl mx-auto px-4 py-12 text-center">
        <p className="text-gray-500 text-lg font-medium">
          No pending dispatches
        </p>
        <p className="text-gray-400 text-sm mt-2">
          Approve a refill plan in{" "}
          <Link href="/refill" className="text-blue-600 underline">
            /refill
          </Link>{" "}
          to generate a route.
        </p>
      </div>
    );
  }

  const formattedDate = dispatchDate
    ? new Date(dispatchDate + "T00:00:00").toLocaleDateString("en-AE", {
        weekday: "long",
        day: "numeric",
        month: "long",
      })
    : "";

  return (
    <div className="max-w-2xl mx-auto px-4 py-6">
      {/* Page header */}
      <div className="flex items-start justify-between mb-6 gap-4">
        <div>
          <Link
            href="/refill"
            className="text-xs text-gray-400 hover:text-gray-600 mb-1 inline-block"
          >
            ← Back to Refill
          </Link>
          <h1 className="text-xl font-bold text-gray-900">🗺️ Driver Route</h1>
          <p className="text-sm text-gray-500 mt-0.5">{formattedDate}</p>
          <div className="flex gap-3 mt-2 text-sm text-gray-600">
            <span className="font-medium">{totalStops} stops</span>
            <span>·</span>
            <span className="font-medium">{totalUnits} total units</span>
            {trip2.length > 0 && (
              <>
                <span>·</span>
                <span>2 trips</span>
              </>
            )}
          </div>
        </div>
        {fullRouteUrl && (
          <a
            href={fullRouteUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="flex-shrink-0 bg-blue-600 text-white text-sm font-semibold px-4 py-2.5 rounded-xl hover:bg-blue-700 active:bg-blue-800 transition-colors text-center"
          >
            Open Full Route
            <br />
            <span className="text-xs font-normal opacity-80">in Maps</span>
          </a>
        )}
      </div>

      {/* Trip 1 */}
      {trip1.length > 0 && (
        <section className="mb-8">
          <div className="flex items-center gap-2 mb-3">
            <span className="bg-blue-600 text-white text-xs font-bold px-3 py-1 rounded-full">
              Trip 1 — Morning
            </span>
            <span className="text-xs text-gray-400">
              West corridor · {trip1.length} stop{trip1.length !== 1 ? "s" : ""}
            </span>
          </div>
          {trip1.map((stop) => (
            <StopCard key={stop.machine_id} stop={stop} accent="blue" />
          ))}
        </section>
      )}

      {/* Trip 2 */}
      {trip2.length > 0 && (
        <section className="mb-8">
          <div className="flex items-center gap-2 mb-3">
            <span className="bg-orange-500 text-white text-xs font-bold px-3 py-1 rounded-full">
              Trip 2 — Afternoon
            </span>
            <span className="text-xs text-gray-400">
              East corridor · {trip2.length} stop
              {trip2.length !== 1 ? "s" : ""}
            </span>
          </div>
          {trip2.map((stop) => (
            <StopCard key={stop.machine_id} stop={stop} accent="orange" />
          ))}
        </section>
      )}

      {/* Pack list */}
      {packList.length > 0 && (
        <section className="mt-2 mb-8">
          <h2 className="text-base font-semibold text-gray-800 mb-3">
            📦 Warehouse Pack List
          </h2>
          <p className="text-xs text-gray-400 mb-3">
            Pack in reverse route order — first stop on top.
          </p>
          <div className="bg-white border border-gray-200 rounded-xl overflow-hidden">
            <table className="w-full text-sm">
              <thead>
                <tr className="bg-gray-50 border-b border-gray-200">
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-gray-500 uppercase tracking-wide">
                    Product
                  </th>
                  <th className="text-right px-4 py-2.5 text-xs font-semibold text-gray-500 uppercase tracking-wide">
                    Units
                  </th>
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-gray-500 uppercase tracking-wide hidden sm:table-cell">
                    Machines
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-100">
                {packList.map((item) => (
                  <tr key={item.product}>
                    <td className="px-4 py-3 font-medium text-gray-900">
                      {item.product}
                    </td>
                    <td className="px-4 py-3 text-right font-bold text-gray-900">
                      {item.total_units}
                    </td>
                    <td className="px-4 py-3 text-xs text-gray-400 hidden sm:table-cell">
                      {item.machines.join(", ")}
                    </td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr className="bg-gray-50 border-t border-gray-200">
                  <td className="px-4 py-2.5 text-xs font-semibold text-gray-600">
                    Total
                  </td>
                  <td className="px-4 py-2.5 text-right text-sm font-bold text-gray-900">
                    {packList.reduce((s, i) => s + i.total_units, 0)}
                  </td>
                  <td className="hidden sm:table-cell" />
                </tr>
              </tfoot>
            </table>
          </div>
        </section>
      )}
    </div>
  );
}
