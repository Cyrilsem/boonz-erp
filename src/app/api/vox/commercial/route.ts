// app/api/vox/commercial/route.ts
import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

export const revalidate = 300;

export async function GET(req: NextRequest) {
  try {
    const { searchParams } = new URL(req.url);
    const podsParam = searchParams.get("pods") || "Mercato,Mirdif";
    const pods = podsParam
      .split(",")
      .map((p) => p.trim())
      .filter(Boolean);
    const dateFrom = searchParams.get("date_from") || "2026-02-06";
    const dateTo =
      searchParams.get("date_to") || new Date().toISOString().slice(0, 10);

    const supabase = createClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.SUPABASE_SERVICE_ROLE_KEY!,
    );

    const { data, error } = await supabase.rpc("get_vox_commercial_report", {
      p_pods: pods,
      p_date_from: dateFrom,
      p_date_to: dateTo,
    });

    if (error) {
      console.error("Supabase RPC error:", error);
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    return NextResponse.json(data, {
      headers: {
        "Cache-Control": "public, s-maxage=300, stale-while-revalidate=60",
      },
    });
  } catch (err: any) {
    return NextResponse.json(
      { error: "Internal error", details: err.message },
      { status: 500 },
    );
  }
}
