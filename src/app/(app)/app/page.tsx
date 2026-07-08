// PRD-087 — command-center dashboard. Server-prefetched aggregate
// (get_dashboard_summary v3) so the page renders with data; the two
// universal toggles (period, VOX scope) live in the client component.
import { createClient } from "@/lib/supabase/server";
import DashboardClient, {
  type DashboardSummary,
} from "@/components/dashboard/DashboardClient";

export const dynamic = "force-dynamic";

export default async function DashboardPage() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_dashboard_summary", {
    p_include_vox: true,
  });

  const summary = (data ?? null) as DashboardSummary | null;

  if (!summary) {
    return (
      <div className="p-8">
        <p style={{ color: "#6b6860", fontSize: 14 }}>
          Dashboard data unavailable{error ? `: ${error.message}` : "."}
        </p>
      </div>
    );
  }

  return <DashboardClient initialSummary={summary} />;
}
