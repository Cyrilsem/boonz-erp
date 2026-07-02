/**
 * POST /api/weimi/apply-capacity
 *
 * Proxies the WEIMI "Modify Aisle Capacity" endpoint
 * (/ext/aisle/capacity/update). Accepts a flat list of updates, groups by
 * deviceCode, and submits one WEIMI call per device.
 *
 * Auth: Authorization: Bearer <WEIMI_PROXY_TOKEN>
 *
 * Body:
 *   {
 *     "updates": [
 *       { "deviceCode": "...", "aisleCode": "0-A00", "capacity": 20,
 *         // optional metadata, echoed back in the response for logging:
 *         "machine_name": "ADDMIND-1007-0000-W0", "slot_name": "A1",
 *         "pod_product_name": "Ice Tea" },
 *       ...
 *     ],
 *     "dry_run": false   // when true, returns what would be sent without calling WEIMI
 *   }
 *
 * Returns:
 *   {
 *     "summary": { total_updates, total_devices, submitted, errors, dry_run },
 *     "results": [
 *       { deviceCode, machine_name, aisle_count, aisles, http_status,
 *         weimi_code, weimi_msg, opt_aisle_id, operation_status, status, ... },
 *       ...
 *     ]
 *   }
 *
 * After submitting, poll GET /api/weimi/apply-status?optAisleId=... per device
 * to confirm each operation reached operationStatus = 2 (Completed).
 */
import { NextRequest, NextResponse } from "next/server";
import { callWeimi, verifyProxyToken } from "@/lib/weimi";

interface UpdateItem {
  deviceCode: string;
  aisleCode: string;
  capacity: number;
  // Echo-only metadata
  machine_name?: string;
  slot_name?: string;
  pod_product_name?: string;
  action_type?: string;
  current_capacity?: number;
}

interface ApplyPayload {
  updates: UpdateItem[];
  dry_run?: boolean;
}

interface WeimiCapacityResponse {
  code?: number;
  msg?: string;
  data?: { optAisleId?: string; operationStatus?: number };
  optAisleId?: string;
  operationStatus?: number;
}

export const maxDuration = 60; // seconds; needs Pro plan for >10s

export async function POST(req: NextRequest) {
  // Auth
  if (!verifyProxyToken(req.headers.get("authorization"))) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  let body: ApplyPayload;
  try {
    body = (await req.json()) as ApplyPayload;
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }

  if (!Array.isArray(body?.updates) || body.updates.length === 0) {
    return NextResponse.json(
      { error: "updates array required" },
      { status: 400 },
    );
  }

  // Validate + group by deviceCode
  const grouped = new Map<string, UpdateItem[]>();
  for (const u of body.updates) {
    if (
      !u ||
      typeof u.deviceCode !== "string" ||
      !u.deviceCode ||
      typeof u.aisleCode !== "string" ||
      !u.aisleCode ||
      !Number.isInteger(u.capacity) ||
      u.capacity < 0
    ) {
      return NextResponse.json(
        { error: "invalid update entry", detail: u },
        { status: 400 },
      );
    }
    if (!grouped.has(u.deviceCode)) grouped.set(u.deviceCode, []);
    grouped.get(u.deviceCode)!.push(u);
  }

  const results: Array<Record<string, unknown>> = [];

  for (const [deviceCode, items] of grouped) {
    const paramsObj = {
      deviceCode,
      aisleList: items.map((i) => ({
        aisleCode: i.aisleCode,
        capacity: i.capacity,
      })),
    };

    if (body.dry_run) {
      results.push({
        deviceCode,
        machine_name: items[0]?.machine_name,
        aisle_count: items.length,
        aisles: items.map((i) => ({
          aisleCode: i.aisleCode,
          capacity: i.capacity,
          slot_name: i.slot_name,
          pod_product_name: i.pod_product_name,
          current_capacity: i.current_capacity,
        })),
        status: "dry_run",
        paramJson: JSON.stringify(paramsObj),
      });
      continue;
    }

    try {
      const r = await callWeimi(
        "POST",
        "/ext/aisle/capacity/update",
        paramsObj,
      );
      const w = (r.body ?? {}) as WeimiCapacityResponse;
      const opt = w.data?.optAisleId ?? w.optAisleId ?? null;
      const opStatus = w.data?.operationStatus ?? w.operationStatus ?? null;
      results.push({
        deviceCode,
        machine_name: items[0]?.machine_name,
        aisle_count: items.length,
        aisles: items.map((i) => ({
          aisleCode: i.aisleCode,
          capacity: i.capacity,
          slot_name: i.slot_name,
          pod_product_name: i.pod_product_name,
          current_capacity: i.current_capacity,
        })),
        http_status: r.http_status,
        weimi_code: w.code,
        weimi_msg: w.msg,
        opt_aisle_id: opt,
        operation_status: opStatus,
        status:
          r.ok && (w.code === 200 || w.code === undefined)
            ? "submitted"
            : "error",
        raw: r.raw.slice(0, 500),
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      results.push({
        deviceCode,
        machine_name: items[0]?.machine_name,
        aisle_count: items.length,
        status: "error",
        error: msg,
      });
    }
  }

  const submitted = results.filter((r) => r.status === "submitted").length;
  const errors = results.filter((r) => r.status === "error").length;

  return NextResponse.json({
    summary: {
      total_updates: body.updates.length,
      total_devices: grouped.size,
      submitted,
      errors,
      dry_run: !!body.dry_run,
    },
    results,
  });
}
