// PRD-087 PERF — server-side 60s cache for the HEAVY dashboard block.
// get_dashboard_ops() costs 2-5s (canonical v_machine_priority underneath);
// it is VOX-independent and tolerates 60s staleness, so we cache it across
// requests. Fetched via PostgREST with the anon key (SECURITY DEFINER RPC,
// no user-specific data) — cookie-free, so it is safe inside unstable_cache.
import { unstable_cache } from "next/cache";

async function fetchOps(): Promise<unknown> {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL!;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
  const res = await fetch(`${url}/rest/v1/rpc/get_dashboard_ops`, {
    method: "POST",
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
    },
    body: "{}",
    cache: "no-store",
  });
  if (!res.ok) throw new Error(`get_dashboard_ops ${res.status}`);
  return res.json();
}

export const getCachedDashboardOps = unstable_cache(
  fetchOps,
  ["dashboard-ops-v1"],
  { revalidate: 60 },
);

// Same treatment for the refill snapshot's heavy prefetch.
async function fetchMachineHealth(): Promise<unknown> {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL!;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
  const res = await fetch(`${url}/rest/v1/rpc/get_machine_health`, {
    method: "POST",
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
    },
    body: "{}",
    cache: "no-store",
  });
  if (!res.ok) throw new Error(`get_machine_health ${res.status}`);
  return res.json();
}

export const getCachedMachineHealth = unstable_cache(
  fetchMachineHealth,
  ["machine-health-v1"],
  { revalidate: 60 },
);
