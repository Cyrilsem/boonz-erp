// Signed-cookie helpers for caching the user's role in middleware.
//
// Why: middleware was doing a Supabase Auth roundtrip + a Postgres SELECT on
// every protected request. Under load (refill engine running) the DB pool
// starved and middleware blew past Vercel's 25s ceiling, throwing
// MIDDLEWARE_INVOCATION_TIMEOUT.
//
// What: after the first DB-read fallback, middleware writes a signed
// `boonz_role` cookie bound to the user's id. Subsequent requests verify the
// HMAC and skip the DB read entirely.
//
// Trust model: cookie payload = `<user_id>.<role>`. Signed with HMAC-SHA256
// using ROLE_COOKIE_SECRET (server-only env var). Tampering is detected at
// verify time; the cookie is also bound to the Supabase user_id from
// getUser(), so a stolen cookie can't be reused under a different account.
//
// TTL: 15 minutes. A role change (promote/demote) takes effect within 15
// minutes without forcing every session to re-login. For instant invalidation
// the user logs out (clears Supabase session cookie too).

export const ROLE_COOKIE_NAME = "boonz_role";
export const ROLE_COOKIE_MAX_AGE_S = 15 * 60; // 15 minutes

let cachedKey: Promise<CryptoKey> | null = null;

function getKey(): Promise<CryptoKey> {
  if (cachedKey) return cachedKey;
  const secret = process.env.ROLE_COOKIE_SECRET;
  if (!secret || secret.length < 32) {
    throw new Error(
      "ROLE_COOKIE_SECRET env var missing or too short (need ≥32 chars)",
    );
  }
  cachedKey = crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
  return cachedKey;
}

function b64urlEncode(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlDecode(s: string): ArrayBuffer {
  let padded = s.replace(/-/g, "+").replace(/_/g, "/");
  while (padded.length % 4) padded += "=";
  const bin = atob(padded);
  const buf = new ArrayBuffer(bin.length);
  const view = new Uint8Array(buf);
  for (let i = 0; i < bin.length; i++) view[i] = bin.charCodeAt(i);
  return buf;
}

/**
 * Sign a role cookie payload. Returns `<user_id>.<role>.<base64url_hmac>`.
 * Throws if ROLE_COOKIE_SECRET is not configured.
 */
export async function signRoleCookie(
  userId: string,
  role: string,
): Promise<string> {
  const payload = `${userId}.${role}`;
  const key = await getKey();
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(payload),
  );
  return `${payload}.${b64urlEncode(sig)}`;
}

/**
 * Verify a role cookie against the expected Supabase user_id.
 * Returns the role on success, null on failure (tampered, expired format,
 * different user, or missing secret).
 */
export async function verifyRoleCookie(
  cookie: string,
  expectedUserId: string,
): Promise<string | null> {
  const parts = cookie.split(".");
  if (parts.length !== 3) return null;
  const [userId, role, sig] = parts;
  if (userId !== expectedUserId) return null;
  if (!role || !sig) return null;

  try {
    const key = await getKey();
    const ok = await crypto.subtle.verify(
      "HMAC",
      key,
      b64urlDecode(sig),
      new TextEncoder().encode(`${userId}.${role}`),
    );
    return ok ? role : null;
  } catch {
    return null;
  }
}
