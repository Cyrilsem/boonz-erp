import { NextRequest, NextResponse } from "next/server";
import { createClient as createServiceClient } from "@supabase/supabase-js";
import { createClient } from "@/lib/supabase/server";

type Aisle = {
  showName?: string;
  goodsName?: string;
  currStock?: number;
  maxStock?: number;
  price?: number;
};
type Layer = { aisles?: Aisle[] };
type Cabinet = { layers?: Layer[] };

export async function POST(req: NextRequest) {
  // Auth check via session cookie
  const supabaseAuth = await createClient();
  const {
    data: { user },
  } = await supabaseAuth.auth.getUser();
  if (!user) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const body = (await req.json().catch(() => ({}))) as { machine_id?: string };
  const machine_id = body.machine_id;
  if (!machine_id) {
    return NextResponse.json({ error: "machine_id required" }, { status: 400 });
  }

  // Service role for DB reads + RPC writes
  const supabase = createServiceClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
  );

  // Get latest door_statuses snapshot for this machine
  const { data: deviceData } = await supabase
    .from("weimi_device_status")
    .select("door_statuses")
    .eq("machine_id", machine_id)
    .order("snapshot_at", { ascending: false })
    .limit(1)
    .single();

  if (!deviceData?.door_statuses) {
    return NextResponse.json(
      { error: "No device snapshot found — run Refresh data first" },
      { status: 404 },
    );
  }

  // Parse slots from cabinets → layers → aisles
  const cabinets = deviceData.door_statuses as Cabinet[];
  const slots: Array<{
    slot_name: string;
    pod_product_name: string;
    current_stock: number;
    max_stock: number;
    actual_selling_price?: number;
  }> = [];

  for (const cabinet of cabinets ?? []) {
    for (const layer of cabinet.layers ?? []) {
      for (const aisle of layer.aisles ?? []) {
        if (!aisle.showName) continue;
        slots.push({
          slot_name: aisle.showName,
          pod_product_name: aisle.goodsName ?? "",
          current_stock: Math.max(Number(aisle.currStock ?? 0), 0),
          max_stock: Math.max(Number(aisle.maxStock ?? 0), 0),
          actual_selling_price: aisle.price ? aisle.price / 100 : undefined,
        });
      }
    }
  }

  if (slots.length === 0) {
    return NextResponse.json(
      { error: "No slots found in device snapshot" },
      { status: 422 },
    );
  }

  const { data: rpcRows, error: rpcError } = await supabase.rpc(
    "upsert_refill_stock_snapshot",
    {
      p_machine_id: machine_id,
      p_slots: slots,
      p_source: "manual_refresh",
    },
  );

  if (rpcError) {
    return NextResponse.json({ error: rpcError.message }, { status: 422 });
  }

  const row = Array.isArray(rpcRows) ? rpcRows[0] : rpcRows;
  return NextResponse.json({
    slots_inserted: row?.slots_inserted ?? slots.length,
    report_timestamp: row?.report_timestamp ?? new Date().toISOString(),
  });
}
