"use client";

// PRD-142a: /app/strategy. Strategic oversight, two tabs (Machines, Products).
// Gated to the PRD-140 access area 'app.strategy' (operator_admin and
// superadmin); every RPC behind it also checks is_admin server-side.

import { useState } from "react";
import { useRequireArea } from "@/lib/auth/access";
import MachinesTab from "./MachinesTab";
import ProductsTab from "./ProductsTab";
import { Segmented } from "./shared";

export default function StrategyPage() {
  const allowed = useRequireArea("app.strategy");
  const [tab, setTab] = useState<"machines" | "products">("machines");

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
