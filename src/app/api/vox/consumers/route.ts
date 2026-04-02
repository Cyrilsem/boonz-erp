import { createClient } from "@supabase/supabase-js";
import { NextRequest, NextResponse } from "next/server";

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url);
  const podsParam = searchParams.get("pods") ?? "";
  const consolidated = searchParams.get("consolidated") === "true";

  const pods = podsParam.length
    ? podsParam
        .split(",")
        .map((p) => p.trim())
        .filter(Boolean)
    : ["Mercato", "Mirdif"];

  const supabase = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
  );

  const { data, error } = await supabase.rpc("get_vox_consumer_report", {
    p_pods: pods,
    p_consolidated: consolidated,
  });

  if (error) {
    console.error("[vox/consumers]", error.message);
    return NextResponse.json({ error: error.message }, { status: 500 });
  }

  return NextResponse.json(data ?? {});
}
