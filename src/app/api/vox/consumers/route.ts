// app/api/vox/consumers/route.ts
import { createClient } from "@supabase/supabase-js";
import { NextRequest, NextResponse } from "next/server";

export async function GET(request: NextRequest) {
  try {
    const supabase = createClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.SUPABASE_SERVICE_ROLE_KEY!,
    );
    const { searchParams } = new URL(request.url);
    const podsParam = searchParams.get("pods") || "Mercato,Mirdif";
    const consolidated = searchParams.get("consolidated") !== "false";
    const dateFrom = searchParams.get("date_from") || "2026-02-06";
    const dateTo =
      searchParams.get("date_to") || new Date().toISOString().split("T")[0];
    const pods = podsParam.split(",").filter(Boolean);

    const { data, error } = await supabase.rpc("get_vox_consumer_report", {
      p_pods: pods,
      p_consolidated: consolidated,
      p_date_from: dateFrom,
      p_date_to: dateTo,
    });

    if (error) {
      console.error("Supabase RPC error:", error);
      return NextResponse.json(
        { error: "Failed to fetch", details: error.message },
        { status: 500 },
      );
    }

    return NextResponse.json(data, {
      headers: {
        "Cache-Control": "public, s-maxage=300, stale-while-revalidate=600",
      },
    });
  } catch (err: any) {
    return NextResponse.json(
      { error: "Internal error", details: err.message },
      { status: 500 },
    );
  }
}
