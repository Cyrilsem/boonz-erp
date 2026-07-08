// PRD-087 — command-center dashboard, PERF split:
//  · get_dashboard_sales (fast, ~100ms, VOX-scoped) fetched live;
//  · get_dashboard_ops (heavy, 2-5s) via 60s server cache → instant TTFB
//    for every visit after the first each minute.
import { createClient } from "@/lib/supabase/server";
import { getCachedDashboardOps } from "@/lib/dashboard/cached-ops";
import DashboardClient, {
  type DashboardSales,
  type DashboardOps,
} from "@/components/dashboard/DashboardClient";

export const dynamic = "force-dynamic";

export default async function DashboardPage() {
  const supabase = await createClient();

  const [salesRes, opsRaw] = await Promise.all([
    supabase.rpc("get_dashboard_sales", { p_include_vox: true }),
    getCachedDashboardOps().catch(() => null),
  ]);

  const sales = (salesRes.data ?? null) as DashboardSales | null;
  const ops = (opsRaw ?? null) as DashboardOps | null;

  if (!sales || !ops) {
    return (
      <div className="p-8">
        <p style={{ color: "#6b6860", fontSize: 14 }}>
          Dashboard data unavailable
          {salesRes.error ? `: ${salesRes.error.message}` : "."}
        </p>
      </div>
    );
  }

  return <DashboardClient initialSales={sales} ops={ops} />;
}
