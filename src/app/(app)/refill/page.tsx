// PRD-087 P1 — server-prefetched refill page.
// Fetches the Stock Snapshot datasets on the server so the heatmap renders
// with the page instead of after a client-side loading flash.
import { createClient } from "@/lib/supabase/server";
import RefillPageClient, {
  type DeviceRow,
  type MachineHealth,
  type RefillInitialData,
} from "./RefillPageClient";

export const dynamic = "force-dynamic";

export default async function RefillPage() {
  const supabase = await createClient();

  const [deviceRes, countRes, healthRes] = await Promise.all([
    supabase
      .from("weimi_device_status")
      .select(
        "device_name, is_online, total_curr_stock, snapshot_at, snapshot_date",
      )
      .not("device_name", "is", null)
      .order("snapshot_date", { ascending: false })
      .limit(10000),
    supabase.from("sales_history").select("*", { count: "exact", head: true }),
    supabase.rpc("get_machine_health").limit(10000),
  ]);

  // Latest device snapshot only (same logic as the client refresher)
  let devices: DeviceRow[] = [];
  let lastRefresh: string | null = null;
  const deviceData = deviceRes.data;
  if (deviceData && deviceData.length > 0) {
    const latestDate = deviceData[0].snapshot_date;
    const latest = deviceData.filter(
      (r: { snapshot_date: string }) => r.snapshot_date === latestDate,
    );
    devices = latest.map(
      (d: {
        device_name: string;
        is_online: boolean;
        total_curr_stock: number;
        snapshot_at: string;
      }) => ({
        device_name: d.device_name,
        is_online: d.is_online,
        total_curr_stock: Math.max(d.total_curr_stock, 0),
        snapshot_at: d.snapshot_at,
      }),
    );
    lastRefresh = latest[0]?.snapshot_at || null;
  }

  // Machine health cards — exclude WH warehouse pseudo-machines
  const machineHealth = ((healthRes.data as MachineHealth[]) || []).filter(
    (m) => !m.machine_name.toUpperCase().startsWith("WH"),
  );

  const initialData: RefillInitialData = {
    devices,
    lastRefresh,
    machineHealth,
    salesCount: countRes.count ?? null,
  };

  return <RefillPageClient initialData={initialData} />;
}
