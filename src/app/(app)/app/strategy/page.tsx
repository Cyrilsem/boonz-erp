"use client";

// PRD-142a: /app/strategy. Strategic oversight, two tabs (Machines, Products).
// Gated to the PRD-140 access area 'app.strategy' (operator_admin and
// superadmin); every RPC behind it also checks is_admin server-side.
// PRD-142b A5: ?tab=machines|products selects the tab (sidebar sub-entries
// deep link here); switching tabs keeps the URL in step.

import { Suspense } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useRequireArea } from "@/lib/auth/access";
import MachinesTab from "./MachinesTab";
import ProductsTab from "./ProductsTab";
import { Segmented } from "./shared";

type Tab = "machines" | "products";

export default function StrategyPage() {
  return (
    <Suspense fallback={null}>
      <StrategyPageInner />
    </Suspense>
  );
}

function StrategyPageInner() {
  const allowed = useRequireArea("app.strategy");
  const router = useRouter();
  const pathname = usePathname();
  const params = useSearchParams();
  const tab: Tab = params.get("tab") === "products" ? "products" : "machines";
  const setTab = (t: Tab) =>
    router.replace(`${pathname}?tab=${t}`, { scroll: false });

  if (!allowed) {
    return (
      <div className="p-6 text-sm" style={{ color: "var(--muted)" }}>
        Checking access…
      </div>
    );
  }

  return (
    <div className="space-y-4 p-4 md:p-6">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-bold" style={{ color: "var(--ink)" }}>
            Strategy
          </h1>
          <p className="text-sm" style={{ color: "var(--muted)" }}>
            What each machine and product is, how it is doing against its peers,
            and the posture the model proposes.
          </p>
        </div>
        <Segmented
          value={tab}
          onChange={setTab}
          options={[
            { value: "machines", label: "Machines" },
            { value: "products", label: "Products" },
          ]}
        />
      </div>
      {tab === "machines" ? <MachinesTab /> : <ProductsTab />}
    </div>
  );
}
