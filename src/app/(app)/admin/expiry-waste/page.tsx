"use client";

import { useState } from "react";
import ExpiryWastePanel from "@/components/inventory/ExpiryWastePanel";
import WmAlertQueuePanel from "@/components/inventory/WmAlertQueuePanel";
import DispositionLedgerPanel from "@/components/inventory/DispositionLedgerPanel";

export const dynamic = "force-dynamic";

type Tab = "batches" | "alerts" | "reports";

const TABS: { id: Tab; label: string }[] = [
  { id: "batches", label: "Batches" },
  { id: "alerts", label: "Alerts" },
  { id: "reports", label: "Ledger & Reports" },
];

export default function ExpiryWastePage() {
  const [tab, setTab] = useState<Tab>("batches");

  return (
    <div className="mx-auto max-w-6xl space-y-4 p-4">
      <header>
        <h1 className="text-xl font-semibold">Expiry &amp; waste</h1>
        <p className="mt-1 text-sm text-neutral-600 dark:text-neutral-400">
          PRD-119 P4. Triage warehouse batches by days-to-expiry (write off or
          redeploy), work the WM attention queue, and read the disposition
          ledger and waste reports.
        </p>
      </header>

      <div className="flex gap-1 border-b border-neutral-200 dark:border-neutral-800">
        {TABS.map((t) => (
          <button
            key={t.id}
            onClick={() => setTab(t.id)}
            className={`rounded-t px-3 py-2 text-sm font-semibold ${
              tab === t.id
                ? "border-b-2 border-neutral-800 text-neutral-900 dark:border-neutral-100 dark:text-neutral-100"
                : "text-neutral-500 hover:text-neutral-800 dark:hover:text-neutral-200"
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {tab === "batches" && <ExpiryWastePanel />}
      {tab === "alerts" && <WmAlertQueuePanel />}
      {tab === "reports" && <DispositionLedgerPanel />}
    </div>
  );
}
