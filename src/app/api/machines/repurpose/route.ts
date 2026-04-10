// app/api/machines/repurpose/route.ts
// Calls repurpose_machine() with service_role so the client never needs elevated privileges.
import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

export async function POST(req: NextRequest) {
  try {
    const body = await req.json();

    const supabase = createClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.SUPABASE_SERVICE_ROLE_KEY!,
    );

    const { data, error } = await supabase.rpc("repurpose_machine", {
      p_old_machine_id: body.p_old_machine_id,
      p_new_official_name: body.p_new_official_name,
      p_new_pod_location: body.p_new_pod_location ?? null,
      p_new_location_type: body.p_new_location_type,
      p_new_building_id: body.p_new_building_id ?? null,
      p_new_source_of_supply: body.p_new_source_of_supply ?? null,
      p_new_venue_group: body.p_new_venue_group ?? "INDEPENDENT",
    });

    if (error) {
      console.error("repurpose_machine RPC error:", error);
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    return NextResponse.json(data);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Internal error";
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
