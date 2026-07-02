/**
 * WEIMI third-center API client helpers.
 * Auth pattern mirrors the existing n8n flow:
 *   SIGN = sha1(`secretKey=${secret},nonce=${nonce},timestamp=${timestamp},appId=${appId},paramJson=${paramJson}`)
 */
import { createHash, randomBytes } from "crypto";

export const WEIMI_BASE_URL =
  process.env.WEIMI_BASE_URL ??
  "https://micron.weimi24.com/v8/third-center-web";

export function weimiCredsFromEnv(): { appId: string; secretKey: string } {
  const appId = process.env.WEIMI_APP_ID ?? "";
  const secretKey = process.env.WEIMI_SECRET_KEY ?? "";
  return { appId, secretKey };
}

export function makeNonce(): string {
  // 13–32 char alphanumeric per WEIMI spec
  return randomBytes(12).toString("hex");
}

export function signRequest(
  secretKey: string,
  nonce: string,
  timestamp: string,
  appId: string,
  paramJson: string,
): string {
  const raw = `secretKey=${secretKey},nonce=${nonce},timestamp=${timestamp},appId=${appId},paramJson=${paramJson}`;
  return createHash("sha1").update(raw).digest("hex");
}

export function weimiHeaders(
  appId: string,
  sign: string,
  timestamp: string,
  nonce: string,
): HeadersInit {
  return {
    "Client-Type": "EXTERNAL",
    SIGN: sign,
    TIMESTAMP: timestamp,
    NONCE: nonce,
    APP_ID: appId,
    "Content-Type": "application/json",
  };
}

/**
 * Call any WEIMI ext endpoint with the right auth headers.
 * For GET, paramJson is the query-string equivalent serialised the same way
 * as the n8n flow does (empty object {} when no params).
 */
export async function callWeimi(
  method: "POST" | "GET",
  pathFromBase: string,
  paramsObj: Record<string, unknown>,
  query?: Record<string, string>,
): Promise<{
  ok: boolean;
  http_status: number;
  body: unknown;
  raw: string;
  paramJson: string;
}> {
  const { appId, secretKey } = weimiCredsFromEnv();
  if (!appId || !secretKey) {
    throw new Error(
      "WEIMI_APP_ID or WEIMI_SECRET_KEY env var missing on the Vercel deployment",
    );
  }

  const paramJson = JSON.stringify(paramsObj);
  const nonce = makeNonce();
  const timestamp = Date.now().toString();
  const sign = signRequest(secretKey, nonce, timestamp, appId, paramJson);

  let url = `${WEIMI_BASE_URL}${pathFromBase}`;
  if (query && Object.keys(query).length > 0) {
    const qs = new URLSearchParams(query).toString();
    url += (url.includes("?") ? "&" : "?") + qs;
  }

  const init: RequestInit = {
    method,
    headers: weimiHeaders(appId, sign, timestamp, nonce),
  };
  if (method === "POST") {
    init.body = paramJson;
  }

  const resp = await fetch(url, init);
  const raw = await resp.text();
  let body: unknown = null;
  try {
    body = JSON.parse(raw);
  } catch {
    // keep as null; raw still returned
  }

  return { ok: resp.ok, http_status: resp.status, body, raw, paramJson };
}

/** Bearer-token auth helper for routes that proxy WEIMI on behalf of n8n. */
export function verifyProxyToken(authHeader: string | null): boolean {
  const expected = process.env.WEIMI_PROXY_TOKEN;
  if (!expected) return false;
  if (!authHeader || !authHeader.startsWith("Bearer ")) return false;
  return authHeader.slice(7) === expected;
}
