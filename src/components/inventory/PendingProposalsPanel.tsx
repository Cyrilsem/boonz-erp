"use client";

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface PendingProposal {
  proposal_id: string;
  wh_inventory_id: string;
  current_status: string;
  proposed_status: string;
  reason: string;
  proposer_kind: string;
  proposer_name: string | null;
  proposed_at: string;
  current_status_drifted: boolean | null;
  // Enriched columns from v_pending_status_proposals
  boonz_product_name?: string | null;
  warehouse_name?: string | null;
  warehouse_stock?: number | null;
  consumer_stock?: number | null;
  expiration_date?: string | null;
}

/**
 * Surfaces every row in `v_pending_status_proposals` with confirm/reject buttons
 * that route through the `confirm_warehouse_status_proposal` /
 * `reject_warehouse_status_proposal` SECURITY DEFINER RPCs.
 *
 * Closes Issue #2 — without this panel, the propose triggers file proposals
 * with no UI to drain them.
 */
export default function PendingProposalsPanel() {
  const [proposals, setProposals] = useState<PendingProposal[]>([]);
  const [loading, setLoading] = useState(true);
  const [working, setWorking] = useState<string | null>(null);
  const [collapsed, setCollapsed] = useState(false);

  const fetchProposals = useCallback(async () => {
    const supabase = createClient();
    const { data, error } = await supabase
      .from("v_pending_status_proposals")
      .select("*")
      .order("proposed_at", { ascending: false });

    if (error) {
      console.error("Failed to load pending proposals:", error);
      setProposals([]);
    } else {
      setProposals((data ?? []) as PendingProposal[]);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchProposals();
  }, [fetchProposals]);

  async function decide(
    proposal_id: string,
    action: "confirm" | "reject",
    note?: string,
  ) {
    setWorking(proposal_id);
    const supabase = createClient();
    const fn =
      action === "confirm"
        ? "confirm_warehouse_status_proposal"
        : "reject_warehouse_status_proposal";

    const { error } = await supabase.rpc(fn, {
      p_proposal_id: proposal_id,
      p_note: note ?? null,
    });

    if (error) {
      console.error(`${fn} failed:`, error);
      alert(`${action} failed: ${error.message}`);
      setWorking(null);
      return;
    }

    setProposals((prev) => prev.filter((p) => p.proposal_id !== proposal_id));
    setWorking(null);
  }

  if (loading) {
    return (
      <div className="mb-4 rounded-lg border border-amber-300 bg-amber-50 p-4 text-sm dark:border-amber-700 dark:bg-amber-950/20">
        Loading pending status proposals…
      </div>
    );
  }

  if (proposals.length === 0) {
    return null; // hide the panel entirely when nothing to action
  }

  return (
    <div className="mb-4 rounded-lg border border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/20">
      <button
        onClick={() => setCollapsed((c) => !c)}
        className="flex w-full items-center justify-between p-3 text-left"
      >
        <div className="flex items-center gap-2">
          <span className="rounded-full bg-amber-500 px-2 py-0.5 text-xs font-semibold text-white">
            {proposals.length}
          </span>
          <span className="text-sm font-semibold">
            Pending status proposals
          </span>
          <span className="text-xs text-neutral-500">
            (system suggested status changes — your confirmation needed)
          </span>
        </div>
        <span className="text-neutral-400">{collapsed ? "▼" : "▲"}</span>
      </button>

      {!collapsed && (
        <ul className="divide-y divide-amber-200 px-3 pb-3 dark:divide-amber-800">
          {proposals.map((p) => (
            <li
              key={p.proposal_id}
              className="flex items-center gap-3 py-2 text-sm"
            >
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-2 truncate">
                  <span className="font-medium">
                    {p.boonz_product_name ?? "(unknown product)"}
                  </span>
                  {p.warehouse_name && (
                    <span className="font-mono text-xs text-neutral-500">
                      {p.warehouse_name}
                    </span>
                  )}
                  {p.expiration_date && (
                    <span className="text-xs text-neutral-500">
                      exp {p.expiration_date}
                    </span>
                  )}
                  {p.current_status_drifted && (
                    <span className="rounded bg-rose-200 px-1.5 py-0.5 text-[10px] font-semibold text-rose-900 dark:bg-rose-900 dark:text-rose-100">
                      DRIFTED
                    </span>
                  )}
                </div>
                <div className="mt-0.5 text-xs text-neutral-600 dark:text-neutral-400">
                  <span className="font-mono">{p.current_status}</span>
                  {" → "}
                  <span className="font-mono font-semibold">
                    {p.proposed_status}
                  </span>
                  {"  ·  "}
                  reason: {p.reason}
                  {"  ·  "}
                  proposer: {p.proposer_kind}
                  {p.proposer_name ? ` (${p.proposer_name})` : ""}
                </div>
              </div>
              <div className="shrink-0 flex gap-2">
                <button
                  onClick={() => decide(p.proposal_id, "confirm")}
                  disabled={working === p.proposal_id}
                  className="rounded bg-emerald-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-emerald-700 disabled:opacity-50"
                >
                  {working === p.proposal_id ? "…" : "Confirm"}
                </button>
                <button
                  onClick={() => decide(p.proposal_id, "reject")}
                  disabled={working === p.proposal_id}
                  className="rounded border border-neutral-300 px-3 py-1.5 text-xs font-medium text-neutral-700 hover:bg-neutral-100 disabled:opacity-50 dark:border-neutral-600 dark:text-neutral-200 dark:hover:bg-neutral-800"
                >
                  Reject
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
