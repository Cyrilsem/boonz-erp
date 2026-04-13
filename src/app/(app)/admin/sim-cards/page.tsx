"use client";

import { useState, useEffect, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Machine, SimCard } from "@/types/machines";
import SimCardsTable from "@/components/admin/sim-cards/SimCardsTable";

export default function SimCardsPage() {
  const [sims, setSims] = useState<SimCard[]>([]);
  const [machines, setMachines] = useState<Machine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchData = useCallback(async () => {
    setLoading(true);
    setError(null);

    const supabase = createClient();

    const { data: simsData, error: simsError } = await supabase
      .from("sim_cards")
      .select("*")
      .limit(10000)
      .order("sim_renewal", { ascending: true });

    if (simsError) {
      setError("Failed to load SIM cards. " + simsError.message);
      setLoading(false);
      return;
    }

    const { data: machinesData } = await supabase
      .from("machines")
      .select("machine_id, official_name")
      .order("official_name")
      .limit(10000);

    setSims((simsData ?? []) as SimCard[]);
    setMachines((machinesData ?? []) as Machine[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  return (
    <div className="min-h-screen bg-[#0a0a0f] text-neutral-200">
      <div className="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
        {/* Page header */}
        <div className="mb-6">
          <h1 className="font-mono text-2xl font-bold tracking-tight text-neutral-100">
            SIM Cards
          </h1>
          {!loading && !error && (
            <p className="mt-1 text-sm text-neutral-500">
              {sims.length} card{sims.length !== 1 ? "s" : ""} total
            </p>
          )}
        </div>

        {/* Loading skeleton */}
        {loading && (
          <div className="space-y-2 rounded-lg border border-neutral-800 bg-[#0f0f18] p-4">
            {[...Array(3)].map((_, i) => (
              <div
                key={i}
                className="h-8 animate-pulse rounded bg-neutral-800/60"
                style={{ opacity: 1 - i * 0.25 }}
              />
            ))}
          </div>
        )}

        {/* Error state */}
        {!loading && error && (
          <div className="flex flex-col items-center gap-4 rounded-lg border border-red-800/50 bg-red-900/20 p-8 text-center">
            <p className="text-sm text-red-300">{error}</p>
            <button
              onClick={fetchData}
              className="rounded border border-neutral-700 px-4 py-2 text-sm text-neutral-300 hover:border-neutral-500 hover:text-white"
            >
              Retry
            </button>
          </div>
        )}

        {/* Main content */}
        {!loading && !error && (
          <SimCardsTable
            sims={sims}
            machines={machines}
            onRefresh={fetchData}
          />
        )}
      </div>
    </div>
  );
}
