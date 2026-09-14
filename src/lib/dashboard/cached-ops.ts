// PRD-087 PERF — server-side 60s cache for heavy dashboard/refill reads.
// ROOT-CAUSE FIX: the anon API role has statement_timeout=3s while
// get_machine_health runs 2-5s, so calling the heavy functions directly with
// the anon key timed out and blanked the FE. We now read tiny DB-side
// snapshots (app_cache, refreshed every 2 min by pg_cron AS postgres) via
// get_machine_health_cached / get_dashboard_ops_cached — instant, timeout-proof.
import { unstable_cache } from "next/cache";

async function rpcAnon(fn: string): Promise<unknown> {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL!;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
  const res = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
    },
    body: "{}",
    cache: "no-store",
  });
  if (!res.ok) throw new Error(`${fn} ${res.status}`);
  return res.json();
}

export const getCachedDashboardOps = unstable_cache(
  async () => rpcAnon("get_dashboard_ops_cached"),
  ["dashboard-ops-v2"],
  { revalidate: 60 },
);

export const getCachedMachineHealth = unstable_cache(
  async () => {
    const j = (await rpcAnon("get_machine_health_cached")) as {
      rows?: unknown[];
      refreshed_at?: string | null;
    } | null;
    // PRD-122 T6 (R6): expose the DB-side app_cache.refreshed_at alongside the
    // rows so the FE can stamp the grid with the cache's true age instead of
    // silently treating a stale snapshot as live data.
    return { rows: j?.rows ?? [], refreshedAt: j?.refreshed_at ?? null };
  },
  ["machine-health-v3"],
  { revalidate: 60 },
);
