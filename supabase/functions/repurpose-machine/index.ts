/**
 * repurpose-machine — Supabase Edge Function
 *
 * Atomically repurposes a vending machine to a new identity:
 *   1. Archives the old machine row (repurposed_at, include_in_refill = false)
 *   2. Archives slot_lifecycle rows for the old machine
 *   3. Creates a fresh machine_id with the new identity
 *   4. Wires old WEIMI name → old UUID in machine_name_aliases   ← KEY FIX
 *   5. Wires new WEIMI name → new UUID in machine_name_aliases   ← KEY FIX
 *
 * All five steps run inside a single Postgres transaction via repurpose_machine().
 * Steps 4–5 prevent the ETL misattribution bug that caused ALHQ/JET, LLFP/MPMCC,
 * and IRIS/ACTIVATEMCC sales to be attributed to the wrong machine.
 *
 * Auth: requires a valid Supabase JWT (any authenticated user).
 * Execution: uses service_role to call the SECURITY DEFINER SQL function.
 *
 * POST /functions/v1/repurpose-machine
 * Body: {
 *   p_old_machine_id:       string  (uuid)
 *   p_new_official_name:    string
 *   p_new_pod_location:     string  (= new WEIMI route name; falls back to official_name)
 *   p_new_location_type:    string  ("office"|"coworking"|"retail"|...)
 *   p_new_building_id?:     string
 *   p_new_source_of_supply?: string
 *   p_new_venue_group?:     string  (default "INDEPENDENT")
 * }
 *
 * Response 200: { old_machine_id, new_machine_id, slots_archived, aliases_wired, result }
 * Response 400: { error: string }  — validation failure
 * Response 401: { error: "Unauthorized" }
 * Response 500: { error: string }  — database error
 */

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const VALID_VENUE_GROUPS = ["ADDMIND", "VOX", "VML", "WPP", "OHMYDESK", "INDEPENDENT"];

Deno.serve(async (req: Request) => {
  // ── CORS preflight ──────────────────────────────────────────────────────────
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  // ── Auth: verify caller has a valid Supabase session ───────────────────────
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return json({ error: "Unauthorized" }, 401);
  }

  const anonClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } }
  );

  const { data: { user }, error: authError } = await anonClient.auth.getUser();
  if (authError || !user) {
    return json({ error: "Unauthorized" }, 401);
  }

  // ── Parse + validate request body ──────────────────────────────────────────
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const {
    p_old_machine_id,
    p_new_official_name,
    p_new_pod_location,
    p_new_location_type,
    p_new_building_id      = null,
    p_new_source_of_supply = null,
    p_new_venue_group      = "INDEPENDENT",
  } = body as {
    p_old_machine_id:        string;
    p_new_official_name:     string;
    p_new_pod_location:      string;
    p_new_location_type:     string;
    p_new_building_id?:      string | null;
    p_new_source_of_supply?: string | null;
    p_new_venue_group?:      string;
  };

  // Required field checks
  if (!p_old_machine_id || typeof p_old_machine_id !== "string") {
    return json({ error: "p_old_machine_id is required" }, 400);
  }
  if (!p_new_official_name?.trim()) {
    return json({ error: "p_new_official_name is required" }, 400);
  }
  if (!p_new_location_type?.trim()) {
    return json({ error: "p_new_location_type is required" }, 400);
  }
  if (!VALID_VENUE_GROUPS.includes(String(p_new_venue_group))) {
    return json({
      error: `Invalid venue_group "${p_new_venue_group}". Must be one of: ${VALID_VENUE_GROUPS.join(", ")}`,
    }, 400);
  }

  // ── Execute via service_role (bypasses RLS, calls SECURITY DEFINER fn) ──────
  const serviceClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  const { data, error: rpcError } = await serviceClient.rpc("repurpose_machine", {
    p_old_machine_id,
    p_new_official_name:    p_new_official_name.trim(),
    p_new_pod_location:     (p_new_pod_location ?? "").trim() || null,
    p_new_location_type:    p_new_location_type.trim(),
    p_new_building_id:      p_new_building_id      ?? null,
    p_new_source_of_supply: p_new_source_of_supply ?? null,
    p_new_venue_group:      String(p_new_venue_group),
  });

  if (rpcError) {
    console.error("[repurpose-machine] RPC error:", rpcError);

    // Surface user-friendly messages for known validation exceptions
    const msg: string = rpcError.message ?? "";
    if (msg.includes("does not exist or is already repurposed")) {
      return json({ error: msg }, 400);
    }
    if (msg.includes("already exists")) {
      return json({ error: msg }, 400);
    }
    if (msg.includes("Invalid venue_group")) {
      return json({ error: msg }, 400);
    }

    return json({ error: "Database error: " + msg }, 500);
  }

  // data is an array of one row from RETURNS TABLE
  const row = Array.isArray(data) ? data[0] : data;

  console.log(
    `[repurpose-machine] ✓ user=${user.id} ` +
    `old=${row.old_machine_id} → new=${row.new_machine_id} ` +
    `slots_archived=${row.slots_archived} aliases_wired=${row.aliases_wired}`
  );

  return json(row, 200);
});

// ── Helper ──────────────────────────────────────────────────────────────────

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}
