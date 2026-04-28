// app/api/machines/repurpose/route.ts
// CC-15: Proxy to the Supabase Edge Function repurpose-machine.
// Kept for backwards-compat with any ERP-side callers that still hit this route.
// The field PWA now calls the edge function directly via supabase.functions.invoke().
import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

export async function POST(req: NextRequest) {
  try {
    const body = await req.json();

    // Forward the caller's auth token so the edge function can verify it
    const authHeader = req.headers.get("authorization") ?? "";

    const supabase = createClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
      { global: { headers: { Authorization: authHeader } } },
    );

    const { data, error } = await supabase.functions.invoke(
      "repurpose-machine",
      {
        body: {
          p_old_machine_id: body.p_old_machine_id,
          p_new_official_name: body.p_new_official_name,
          p_new_pod_location: body.p_new_pod_location ?? null,
          p_new_location_type: body.p_new_location_type,
          p_new_building_id: body.p_new_building_id ?? null,
          p_new_source_of_supply: body.p_new_source_of_supply ?? null,
          p_new_venue_group: body.p_new_venue_group ?? "INDEPENDENT",
        },
      },
    );

    if (error) {
      console.error("repurpose-machine edge function error:", error);
      let msg = error.message ?? "Unknown error";
      try {
        msg = JSON.parse(msg).error ?? msg;
      } catch {
        /* not JSON */
      }
      return NextResponse.json({ error: msg }, { status: 500 });
    }

    return NextResponse.json(data);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Internal error";
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
