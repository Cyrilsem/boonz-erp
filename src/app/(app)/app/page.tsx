// PRD-087 — command-center dashboard. Server-prefetched: one aggregate RPC
// (get_dashboard_summary) + initial 7-day top machines, so the page renders
// with data (no client loading flash). Replaces the old thin stat-card page.
import { createClient } from "@/lib/supabase/server";
import DashboardClient, {
  type DashboardSummary,
} from "@/components/dashboard/DashboardClient";

export const dynamic = "force-dynamic";

export default async function DashboardPage() {
  const supabase = await createClient();

  const [summaryRes, topRes] = await Promise.all([
    supabase.rpc("get_dashboard_summary"),
    supabase.rpc("get_sales_by_machine", { lookback_days: 7 }).limit(10),
  ]);

  const summary = (summaryRes.data ?? null) as DashboardSummary | null;

  if (!summary) {
    return (
      <div className="p-8">
        <p style={{ color: "#6b6860", fontSize: 14 }}>
          Dashboard data unavailable
          {summaryRes.error ? `: ${summaryRes.error.message}` : "."}
        </p>
      </div>
    );
  }

  return (
    <DashboardClient
      summary={summary}
      initialTopMachines={topRes.data ?? []}
    />
  );
}
