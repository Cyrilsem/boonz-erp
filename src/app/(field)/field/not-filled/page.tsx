"use client";

import { useEffect, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import { FieldHeader } from "../../components/field-header";

// PRD-030 partial-pack / no-dark-stage: read-only fleet view of today's
// not-filled lines from the canonical v_not_filled_lines view (Article 16).
// kind: 'full_not_filled' (whole line packed 0) | 'partial_remainder' (shortfall
// after a partial pack). Grouped by machine, no client-side re-derivation.

interface NotFilledRow {
  machine_id: string;
  machine_name: string | null;
  shelf_code: string | null;
  pod_product_name: string | null;
  boonz_product_name: string | null;
  planned_quantity: number;
  filled_quantity: number;
  shortfall: number;
  kind: "full_not_filled" | "partial_remainder";
}

interface MachineGroup {
  machine_id: string;
  machine_name: string;
  rows: NotFilledRow[];
}

export default function NotFilledPage() {
  const [groups, setGroups] = useState<MachineGroup[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchRows = useCallback(async () => {
    const supabase = createClient();
    const today = getDubaiDate();

    const { data: rows } = await supabase
      .from("v_not_filled_lines")
      .select(
        "machine_id, machine_name, shelf_code, pod_product_name, boonz_product_name, planned_quantity, filled_quantity, shortfall, kind",
      )
      .eq("dispatch_date", today)
      .limit(10000);

    if (!rows || rows.length === 0) {
      setGroups([]);
      setLoading(false);
      return;
    }

    const grouped = new Map<string, MachineGroup>();
    for (const r of rows as unknown as NotFilledRow[]) {
      const existing = grouped.get(r.machine_id);
      if (existing) {
        existing.rows.push(r);
      } else {
        grouped.set(r.machine_id, {
          machine_id: r.machine_id,
          machine_name: r.machine_name ?? "—",
          rows: [r],
        });
      }
    }

    const sorted = Array.from(grouped.values())
      .map((g) => ({
        ...g,
        rows: g.rows.sort((a, b) =>
          (a.shelf_code ?? "").localeCompare(b.shelf_code ?? ""),
        ),
      }))
      .sort((a, b) => a.machine_name.localeCompare(b.machine_name));

    setGroups(sorted);
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchRows();
  }, [fetchRows]);

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") fetchRows();
    }
    document.addEventListener("visibilitychange", handleVisibility);
    window.addEventListener("focus", fetchRows);
    return () => {
      document.removeEventListener("visibilitychange", handleVisibility);
      window.removeEventListener("focus", fetchRows);
    };
  }, [fetchRows]);

  if (loading) {
    return (
      <>
        <FieldHeader title="Not Filled" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading not-filled lines…</p>
        </div>
      </>
    );
  }

  if (groups.length === 0) {
    return (
      <>
        <FieldHeader title="Not Filled" />
        <div className="flex flex-col items-center justify-center p-8 text-center">
          <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
            Nothing unfilled today
          </p>
          <p className="mt-1 text-sm text-neutral-500">
            Every planned line was packed in full.
          </p>
        </div>
      </>
    );
  }

  return (
    <div className="px-4 py-4">
      <FieldHeader title="Not Filled" />
      <div className="space-y-4">
        {groups.map((g) => (
          <div
            key={g.machine_id}
            className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950"
          >
            <div className="flex items-baseline justify-between border-b border-neutral-200 px-4 py-2.5 dark:border-neutral-800">
              <p className="text-base font-semibold truncate">
                {g.machine_name}
              </p>
              <span className="shrink-0 text-xs text-neutral-400">
                {g.rows.length} line{g.rows.length !== 1 ? "s" : ""}
              </span>
            </div>
            <ul className="divide-y divide-neutral-100 dark:divide-neutral-900">
              {g.rows.map((r, idx) => (
                <li
                  key={idx}
                  className="flex flex-col gap-1 px-4 py-2.5 text-sm"
                >
                  <div className="flex items-center gap-2">
                    <span className="shrink-0 font-mono text-xs text-neutral-400">
                      {r.shelf_code ?? "—"}
                    </span>
                    <span
                      className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase ${
                        r.kind === "partial_remainder"
                          ? "bg-orange-50 text-orange-700 dark:bg-orange-950/30 dark:text-orange-400"
                          : "bg-amber-50 text-amber-700 dark:bg-amber-950/30 dark:text-amber-400"
                      }`}
                    >
                      {r.kind === "partial_remainder"
                        ? "Partial"
                        : "Not filled"}
                    </span>
                    <span className="flex-1 truncate">
                      {r.boonz_product_name ?? r.pod_product_name ?? "—"}
                    </span>
                  </div>
                  <p className="pl-7 text-xs text-neutral-500 dark:text-neutral-400">
                    Planned {r.planned_quantity}, packed {r.filled_quantity} —
                    short {r.shortfall}
                  </p>
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>
    </div>
  );
}
