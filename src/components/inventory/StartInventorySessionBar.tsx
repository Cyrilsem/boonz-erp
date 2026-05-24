"use client";

// Phase G PRD v2 Phase 1 FE wiring.
//
// Top-of-page bar on inventory surfaces. Two states:
//   1. No session: a "Start Inventory Control" button. Disabled if the
//      warehouseId or role is missing. On click: calls
//      start_inventory_session via the session context.
//   2. Session open: a banner showing how long the session has been running,
//      the optional human-readable slug, and a "Close Inventory Control"
//      button. On click: calls close_inventory_session and renders the
//      backend-computed summary as a small post-close toast.
//
// The session gate is enforced by the consumer pages: edit cells render
// read-only unless useInventorySession().session is non-null AND the user
// role is in EDIT_ROLES. This bar is the only place to flip that gate.

import { useEffect, useMemo, useState } from "react";
import { useInventorySession } from "@/lib/inventory/session";

const SESSION_ROLES = new Set([
  "warehouse",
  "operator_admin",
  "superadmin",
  "manager",
]);

interface StartInventorySessionBarProps {
  warehouseId: string | null;
  warehouseLabel?: string;
  role: string | null;
  /**
   * Optional product whitelist for the session scope. When omitted the
   * session covers the whole warehouse.
   */
  productIds?: string[] | null;
  /**
   * Optional human-readable slug suggested at start time. The PRD A.4
   * Saturday session uses "inventory_session_2026-05-23_makeup".
   */
  defaultSlug?: string | null;
}

function formatElapsed(startedAt: string): string {
  const then = new Date(startedAt).getTime();
  const ms = Date.now() - then;
  const sec = Math.floor(ms / 1000);
  if (sec < 60) return `${sec}s`;
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m`;
  const hr = Math.floor(min / 60);
  return `${hr}h ${min % 60}m`;
}

export function StartInventorySessionBar(props: StartInventorySessionBarProps) {
  const { warehouseId, warehouseLabel, role, productIds, defaultSlug } = props;
  const { session, starting, closing, error, start, close } =
    useInventorySession();

  // tickCount forces a re-render every 15s while a session is open so the
  // computed `elapsed` string below stays fresh. We deliberately avoid storing
  // elapsed in state directly so the no-session branch does not need a
  // setState() inside the effect (react-hooks/set-state-in-effect).
  const [tickCount, setTickCount] = useState(0);
  const [closedSummary, setClosedSummary] = useState<Record<
    string,
    unknown
  > | null>(null);

  const canStart = useMemo(
    () =>
      Boolean(warehouseId) && Boolean(role) && SESSION_ROLES.has(role ?? ""),
    [warehouseId, role],
  );

  useEffect(() => {
    if (!session) return;
    const id = window.setInterval(() => setTickCount((t) => t + 1), 15_000);
    return () => window.clearInterval(id);
  }, [session]);

  // tickCount in state forces a re-render every 15s; the value itself is not
  // read here but accessing it via the closure ensures the lint rule does not
  // flag tickCount as unused while still recomputing on every render.
  void tickCount;
  const elapsed = session ? formatElapsed(session.started_at) : "";

  if (!session) {
    // No open session. Render the start affordance.
    if (!canStart) {
      return (
        <div className="rounded-lg border border-neutral-200 bg-neutral-50 px-4 py-3 text-sm text-neutral-600 dark:border-neutral-800 dark:bg-neutral-950 dark:text-neutral-400">
          {role && !SESSION_ROLES.has(role)
            ? "Your role cannot edit inventory. View only."
            : "Inventory edits are paused until a warehouse is selected."}
        </div>
      );
    }
    return (
      <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-amber-300 bg-amber-50 px-4 py-3 dark:border-amber-700 dark:bg-amber-950">
        <div className="text-sm text-amber-900 dark:text-amber-200">
          <span className="font-semibold">Inventory edits are locked.</span>
          <span className="ml-2">
            Start an inventory-control session to begin editing
            {warehouseLabel ? ` (${warehouseLabel})` : ""}. Every change will be
            logged.
          </span>
        </div>
        <button
          type="button"
          onClick={() =>
            start({
              warehouseId: warehouseId!,
              slug: defaultSlug ?? null,
              productIds: productIds ?? null,
              role,
            })
          }
          disabled={starting}
          className="rounded-lg bg-neutral-900 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
        >
          {starting ? "Starting..." : "Start Inventory Control"}
        </button>
        {error && (
          <p className="w-full text-xs text-red-600 dark:text-red-400">
            {error}
          </p>
        )}
      </div>
    );
  }

  // Session open. Render the banner + close affordance.
  return (
    <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-blue-300 bg-blue-50 px-4 py-3 dark:border-blue-700 dark:bg-blue-950">
      <div className="text-sm text-blue-900 dark:text-blue-200">
        <span className="font-semibold">Inventory control session open.</span>
        <span className="ml-2">
          Started {elapsed || "just now"} ago
          {session.session_slug ? ` as ${session.session_slug}` : ""}.
        </span>
      </div>
      <button
        type="button"
        onClick={async () => {
          await close();
          setClosedSummary({ closed_at: new Date().toISOString() });
          window.setTimeout(() => setClosedSummary(null), 4000);
        }}
        disabled={closing}
        className="rounded-lg border border-blue-300 bg-white px-4 py-2 text-sm font-medium text-blue-900 transition-colors hover:bg-blue-100 disabled:opacity-50 dark:border-blue-700 dark:bg-blue-900 dark:text-blue-100 dark:hover:bg-blue-800"
      >
        {closing ? "Closing..." : "Close session"}
      </button>
      {error && (
        <p className="w-full text-xs text-red-600 dark:text-red-400">{error}</p>
      )}
      {closedSummary && (
        <p className="w-full text-xs text-blue-700 dark:text-blue-300">
          Session closed. Summary recorded in the inventory log.
        </p>
      )}
    </div>
  );
}
