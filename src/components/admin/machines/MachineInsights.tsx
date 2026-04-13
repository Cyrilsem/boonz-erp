"use client";

import { useMemo, useState } from "react";
import type { Machine, SimCard } from "@/types/machines";
import { HW_FIELDS, PAYMENT_FIELDS } from "@/types/machines";

interface MachineInsightsProps {
  machines: Machine[];
  simMap: Map<string, SimCard>;
}

interface ActionItem {
  machine: Machine;
  issues: IssueTag[];
}

type IssueTag =
  | "HW issue"
  | "Permit expiring"
  | "No SIM"
  | "Inconsistent status";

const TAG_STYLES: Record<IssueTag, string> = {
  "HW issue": "bg-red-900/60 text-red-300 border border-red-700/50",
  "Permit expiring":
    "bg-amber-900/60 text-amber-300 border border-amber-700/50",
  "No SIM": "bg-yellow-900/60 text-yellow-300 border border-yellow-700/50",
  "Inconsistent status":
    "bg-orange-900/60 text-orange-300 border border-orange-700/50",
};

export default function MachineInsights({
  machines,
  simMap,
}: MachineInsightsProps) {
  const [open, setOpen] = useState(true);

  const today = useMemo(() => new Date(), []);
  const ninetyDaysMs = 90 * 24 * 60 * 60 * 1000;

  const stats = useMemo(() => {
    const total = machines.length;
    if (total === 0) {
      return {
        fleetHealth: 0,
        paymentConfig: 0,
        simCoverage: [0, 0] as [number, number],
        permitAlerts: 0,
      };
    }

    let hwOkCount = 0;
    let payOkCount = 0;
    let simLinkedCount = 0;
    let permitAlertCount = 0;

    for (const m of machines) {
      const hwOk = HW_FIELDS.every(({ key }) => m[key] === true);
      if (hwOk) hwOkCount++;

      const payOk = PAYMENT_FIELDS.every(({ key }) => m[key] === true);
      if (payOk) payOkCount++;

      if (simMap.has(m.machine_id)) simLinkedCount++;

      if (m.permit_expiry_date) {
        const expiry = new Date(m.permit_expiry_date);
        if (expiry.getTime() - today.getTime() < ninetyDaysMs) {
          permitAlertCount++;
        }
      }
    }

    return {
      fleetHealth: Math.round((hwOkCount / total) * 100),
      paymentConfig: Math.round((payOkCount / total) * 100),
      simCoverage: [simLinkedCount, total] as [number, number],
      permitAlerts: permitAlertCount,
    };
  }, [machines, simMap, today, ninetyDaysMs]);

  const actionItems = useMemo((): ActionItem[] => {
    return machines
      .map((m): ActionItem | null => {
        const issues: IssueTag[] = [];

        const hwFail = HW_FIELDS.some(({ key }) => m[key] === false);
        if (hwFail) issues.push("HW issue");

        if (m.permit_expiry_date) {
          const expiry = new Date(m.permit_expiry_date);
          if (expiry.getTime() - today.getTime() < ninetyDaysMs) {
            issues.push("Permit expiring");
          }
        }

        if (!simMap.has(m.machine_id)) issues.push("No SIM");

        if (m.status === "Inactive" && m.include_in_refill === true) {
          issues.push("Inconsistent status");
        }

        return issues.length > 0 ? { machine: m, issues } : null;
      })
      .filter((item): item is ActionItem => item !== null)
      .sort((a, b) => b.issues.length - a.issues.length);
  }, [machines, simMap, today, ninetyDaysMs]);

  const healthColor = (pct: number) => {
    if (pct >= 90) return "text-green-400";
    if (pct >= 60) return "text-amber-400";
    return "text-red-400";
  };

  return (
    <div className="space-y-4">
      {/* Stat cards */}
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        {/* Fleet Health */}
        <div className="rounded-lg border border-neutral-800 bg-[#0f0f18] p-4">
          <p className="text-[10px] font-medium uppercase tracking-widest text-neutral-500">
            Fleet Health
          </p>
          <p
            className={`mt-2 text-3xl font-mono font-bold ${healthColor(stats.fleetHealth)}`}
          >
            {stats.fleetHealth}%
          </p>
          <p className="mt-1 text-[11px] text-neutral-600">
            all HW checks passing
          </p>
        </div>

        {/* Payment Config */}
        <div className="rounded-lg border border-neutral-800 bg-[#0f0f18] p-4">
          <p className="text-[10px] font-medium uppercase tracking-widest text-neutral-500">
            Payment Config
          </p>
          <p
            className={`mt-2 text-3xl font-mono font-bold ${healthColor(stats.paymentConfig)}`}
          >
            {stats.paymentConfig}%
          </p>
          <p className="mt-1 text-[11px] text-neutral-600">fully configured</p>
        </div>

        {/* SIM Coverage */}
        <div className="rounded-lg border border-neutral-800 bg-[#0f0f18] p-4">
          <p className="text-[10px] font-medium uppercase tracking-widest text-neutral-500">
            SIM Coverage
          </p>
          <p className="mt-2 font-mono text-3xl font-bold text-neutral-100">
            {stats.simCoverage[0]}
            <span className="text-lg text-neutral-500">
              {" "}
              / {stats.simCoverage[1]}
            </span>
          </p>
          <p className="mt-1 text-[11px] text-neutral-600">
            machines with SIM linked
          </p>
        </div>

        {/* Permit Alerts */}
        <div className="rounded-lg border border-neutral-800 bg-[#0f0f18] p-4">
          <p className="text-[10px] font-medium uppercase tracking-widest text-neutral-500">
            Permit Alerts
          </p>
          <p
            className={`mt-2 text-3xl font-mono font-bold ${
              stats.permitAlerts === 0 ? "text-green-400" : "text-amber-400"
            }`}
          >
            {stats.permitAlerts}
          </p>
          <p className="mt-1 text-[11px] text-neutral-600">
            expiring within 90 days
          </p>
        </div>
      </div>

      {/* Action Required table */}
      <div className="rounded-lg border border-neutral-800 bg-[#0f0f18]">
        <button
          onClick={() => setOpen((v) => !v)}
          className="flex w-full items-center justify-between px-4 py-3 text-left transition-colors hover:bg-neutral-900/40"
        >
          <div className="flex items-center gap-2">
            <span className="text-xs font-semibold uppercase tracking-widest text-neutral-300">
              Action Required
            </span>
            {actionItems.length > 0 && (
              <span className="rounded-full bg-red-900/50 px-2 py-0.5 text-[10px] font-bold text-red-300">
                {actionItems.length}
              </span>
            )}
          </div>
          <span className="text-neutral-500 text-xs">{open ? "▲" : "▼"}</span>
        </button>

        {open && (
          <>
            {actionItems.length === 0 ? (
              <div className="px-4 py-8 text-center text-sm text-neutral-600">
                No action required — all machines look good.
              </div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-t border-neutral-800 bg-[#0a0a0f]">
                      <th className="px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-neutral-500">
                        Machine
                      </th>
                      <th className="px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-neutral-500">
                        Location
                      </th>
                      <th className="px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-neutral-500">
                        Issues
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {actionItems.map(({ machine, issues }, idx) => (
                      <tr
                        key={machine.machine_id}
                        className={`border-t border-neutral-800/60 ${
                          idx % 2 === 0 ? "bg-transparent" : "bg-neutral-900/20"
                        }`}
                      >
                        <td className="px-4 py-2.5 font-mono text-xs font-semibold text-neutral-100">
                          {machine.official_name}
                        </td>
                        <td className="px-4 py-2.5 text-xs text-neutral-400">
                          {machine.pod_location ?? "—"}
                        </td>
                        <td className="px-4 py-2.5">
                          <div className="flex flex-wrap gap-1">
                            {issues.map((tag) => (
                              <span
                                key={tag}
                                className={`rounded px-1.5 py-0.5 text-[10px] font-medium ${TAG_STYLES[tag]}`}
                              >
                                {tag}
                              </span>
                            ))}
                          </div>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}
