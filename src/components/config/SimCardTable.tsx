"use client";

import type { SimCard } from "@/types/machines";

interface SimCardTableProps {
  sims: SimCard[];
  todayStr: string; // YYYY-MM-DD (Dubai)
  onEdit: (sim: SimCard) => void;
  onAssignToggle: (sim: SimCard) => void;
}

function daysUntil(dateStr: string | null, today: string): number | null {
  if (!dateStr) return null;
  const diff = new Date(dateStr).getTime() - new Date(today).getTime();
  return Math.ceil(diff / (1000 * 60 * 60 * 24));
}

function RenewalBadge({
  renewalDate,
  today,
}: {
  renewalDate: string | null;
  today: string;
}) {
  if (!renewalDate) return <span className="text-gray-400">—</span>;
  const days = daysUntil(renewalDate, today);
  if (days === null) return <span className="text-gray-400">—</span>;

  let cls = "text-gray-600";
  if (days < 0) cls = "font-semibold text-red-600";
  else if (days <= 30) cls = "font-semibold text-amber-600";

  const label = days < 0 ? `${Math.abs(days)}d overdue` : `${days}d`;
  return (
    <span className={cls} title={renewalDate}>
      {renewalDate.slice(0, 10)} ({label})
    </span>
  );
}

function serialDisplay(serial: string | null): React.ReactNode {
  if (!serial) return <span className="text-gray-400">—</span>;
  const last8 = serial.slice(-8);
  return (
    <span title={serial} className="cursor-default font-mono text-xs">
      …{last8}
    </span>
  );
}

export function SimCardTable({
  sims,
  todayStr,
  onEdit,
  onAssignToggle,
}: SimCardTableProps) {
  if (sims.length === 0) {
    return (
      <p className="py-8 text-center text-sm text-gray-400">
        No SIM cards found
      </p>
    );
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[700px] text-sm">
        <thead>
          <tr className="border-b border-gray-100 text-left text-xs text-gray-500">
            <th className="pb-2 pr-3 font-medium">Ref</th>
            <th className="pb-2 pr-3 font-medium">Serial</th>
            <th className="pb-2 pr-3 font-medium">Renewal</th>
            <th className="pb-2 pr-3 font-medium">Machine</th>
            <th className="pb-2 pr-3 font-medium">Paid By</th>
            <th className="pb-2 pr-3 font-medium">Status</th>
            <th className="pb-2 font-medium">Actions</th>
          </tr>
        </thead>
        <tbody>
          {sims.map((sim) => (
            <tr
              key={sim.sim_id}
              className="border-b border-gray-50 last:border-0"
            >
              <td className="py-2 pr-3 font-medium text-gray-900">
                {sim.sim_ref ?? "—"}
              </td>
              <td className="py-2 pr-3">{serialDisplay(sim.sim_serial)}</td>
              <td className="py-2 pr-3">
                <RenewalBadge renewalDate={sim.sim_renewal} today={todayStr} />
              </td>
              <td className="py-2 pr-3 text-xs text-gray-700">
                {sim.machine_name ?? (
                  <span className="text-gray-400">Unassigned</span>
                )}
              </td>
              <td className="py-2 pr-3 text-xs text-gray-600">
                {sim.paid_by ?? <span className="text-gray-400">—</span>}
              </td>
              <td className="py-2 pr-3">
                <span
                  className={`inline-block rounded-full px-2 py-0.5 text-xs font-medium ${
                    sim.is_active
                      ? "bg-green-100 text-green-700"
                      : "bg-gray-100 text-gray-500"
                  }`}
                >
                  {sim.is_active ? "Active" : "Inactive"}
                </span>
              </td>
              <td className="py-2">
                <div className="flex items-center gap-2">
                  <button
                    onClick={() => onEdit(sim)}
                    className="rounded-lg border border-gray-200 px-2 py-1 text-xs hover:bg-gray-50"
                  >
                    Edit
                  </button>
                  <button
                    onClick={() => onAssignToggle(sim)}
                    className="rounded-lg border border-gray-200 px-2 py-1 text-xs hover:bg-gray-50"
                  >
                    {sim.machine_id ? "Unassign" : "Assign"}
                  </button>
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
