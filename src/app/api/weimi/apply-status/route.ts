/**
 * GET /api/weimi/apply-status?optAisleId=...&optAisleId=...
 *
 * Polls the WEIMI "Query Vending Machine Slot Modification Status" endpoint
 * (/ext/aisle/update/state) for one or more optAisleId(s) returned by
 * /api/weimi/apply-capacity. Per WEIMI's recommendation: poll every 2s,
 * up to 30 times.
 *
 * Auth: Authorization: Bearer <WEIMI_PROXY_TOKEN>
 *
 * Returns:
 *   {
 *     "results": [
 *       { optAisleId, operation_status, weimi_code, weimi_msg, http_status, raw, status_label },
 *       ...
 *     ]
 *   }
 *
 * operation_status meaning:
 *   0 = Created, 1 = Notified device, 2 = Completed, 3 = Failed
 */
import { NextRequest, NextResponse } from "next/server";
import { callWeimi, verifyProxyToken } from "@/lib/weimi";

interface WeimiStatusResponse {
  code?: number;
  msg?: string;
  data?: { optAisleId?: string; operationStatus?: number };
  optAisleId?: string;
  operationStatus?: number;
}

const STATUS_LABEL: Record<number, string> = {
  0: "Created",
  1: "Notified device",
  2: "Completed",
  3: "Failed",
};

export const maxDuration = 60;

export async function GET(req: NextRequest) {
  if (!verifyProxyToken(req.headers.get("authorization"))) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  // Accept either a single optAisleId or a comma-separated list via ?ids=
  const url = new URL(req.url);
  const ids: string[] = [];
  const idsParam = url.searchParams.get("ids");
  if (idsParam) {
    ids.push(
      ...idsParam
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean),
    );
  }
  url.searchParams.getAll("optAisleId").forEach((v) => {
    if (v) ids.push(v);
  });

  if (ids.length === 0) {
    return NextResponse.json(
      { error: "optAisleId required (single or ?ids=a,b,c)" },
      { status: 400 },
    );
  }

  const results: Array<Record<string, unknown>> = [];

  for (const optAisleId of ids) {
    try {
      // WEIMI's GET endpoint reads optAisleId from the query string. Sign with
      // the same paramJson semantics as POST — the existing n8n flow signs an
      // empty paramsObj on GET endpoints, so we match.
      const r = await callWeimi(
        "GET",
        "/ext/aisle/update/state",
        { optAisleId },
        { optAisleId },
      );
      const w = (r.body ?? {}) as WeimiStatusResponse;
      const opStatus = w.data?.operationStatus ?? w.operationStatus ?? null;
      results.push({
        optAisleId,
        operation_status: opStatus,
        status_label:
          opStatus !== null && opStatus !== undefined
            ? (STATUS_LABEL[opStatus] ?? "Unknown")
            : null,
        weimi_code: w.code,
        weimi_msg: w.msg,
        http_status: r.http_status,
        raw: r.raw.slice(0, 500),
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      results.push({ optAisleId, status_label: "error", error: msg });
    }
  }

  return NextResponse.json({ results });
}
