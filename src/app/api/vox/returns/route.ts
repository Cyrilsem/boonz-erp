// app/api/vox/returns/route.ts
// PRD-040 Track C / C1: thin pass-through to get_vox_returns (read-only VOX returns ledger).
// Same pattern as /api/vox/commercial: server-side service_role client, no business logic here.
// The RPC scopes to venue_group='VOX' and resolves staff names; this route only shapes params.
import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

export const maxDuration = 30;

export async function GET(req: NextRequest) {
  try {
    const { searchParams } = new URL(req.url);
    const dateTo =
      searchParams.get("date_to") || new Date().toISOString().slice(0, 10);
    const dateFrom =
      searchParams.get("date_from") ||
      new Date(Date.now() - 30 * 864e5).toISOString().slice(0, 10);
    const machineId = searchParams.get("machine_id");

    const supabase = createClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.SUPABASE_SERVICE_ROLE_KEY!,
    );

    const { data, error } = await supabase.rpc("get_vox_returns", {
      p_date_from: dateFrom,
      p_date_to: dateTo,
      p_machine_id: machineId || null,
    });

    if (error) {
      console.error("get_vox_returns RPC error:", error);
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    return NextResponse.json(data ?? [], {
      headers: {
        "Cache-Control": "public, s-maxage=30, stale-while-revalidate=60",
      },
    });
  } catch (err) {
    return NextResponse.json(
      {
        error: "Internal error",
        details: err instanceof Error ? err.message : String(err),
      },
      { status: 500 },
    );
  }
}
