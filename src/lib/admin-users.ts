// PRD-140 Item 3: thin typed client for the admin-users edge function.
// supabase.functions.invoke() forwards the current session's access token
// automatically; this file only shapes the request/response per action so
// the Settings > Users page doesn't repeat the same error-unwrap logic
// seven times.

import { createClient } from "@/lib/supabase/client";

export type SettableRole =
  | "superadmin"
  | "operator_admin"
  | "manager"
  | "warehouse"
  | "field_staff"
  | "finance";

export interface AdminUserSurfaces {
  app: boolean;
  field: boolean;
  tracker: boolean;
}

export interface AdminUserRow {
  id: string;
  email: string | null;
  full_name: string | null;
  role: SettableRole;
  last_sign_in_at: string | null;
  banned_until: string | null;
  created_at: string;
  open_sessions: number;
  surfaces: AdminUserSurfaces;
}

export class AdminUsersError extends Error {}

async function call<T>(
  action: string,
  payload: Record<string, unknown> = {},
): Promise<T> {
  const supabase = createClient();
  const { data, error } = await supabase.functions.invoke("admin-users", {
    body: { action, ...payload },
  });
  if (error) {
    // supabase-js surfaces a non-2xx response as `error`, with the function's
    // own JSON body sometimes reachable on error.context; fall back to the
    // raw message if that isn't present.
    let message = error.message ?? "Request failed";
    const ctx = (error as { context?: { body?: unknown } }).context;
    if (ctx?.body) {
      try {
        const parsed =
          typeof ctx.body === "string" ? JSON.parse(ctx.body) : ctx.body;
        if (parsed?.error) message = parsed.error;
      } catch {
        /* not JSON, keep the raw message */
      }
    }
    throw new AdminUsersError(message);
  }
  return data as T;
}

export const adminUsers = {
  list: () => call<{ users: AdminUserRow[] }>("list"),

  create: (input: {
    email: string;
    full_name: string;
    role: SettableRole;
    password: string;
  }) => call<{ id: string }>("create", input),

  setRole: (userId: string, role: SettableRole) =>
    call<{ id: string; role: string }>("set_role", {
      user_id: userId,
      role,
    }),

  setName: (userId: string, fullName: string) =>
    call<{ id: string; full_name: string }>("set_name", {
      user_id: userId,
      full_name: fullName,
    }),

  setPassword: (userId: string, password: string) =>
    call<{ id: string; status: string }>("set_password", {
      user_id: userId,
      password,
    }),

  sendReset: (userId: string) =>
    call<{ id: string; email: string; recovery_link: string; note: string }>(
      "send_reset",
      { user_id: userId },
    ),

  ban: (userId: string) =>
    call<{ id: string; banned: boolean }>("ban", { user_id: userId }),

  unban: (userId: string) =>
    call<{ id: string; banned: boolean }>("unban", { user_id: userId }),

  revokeSessions: (userId: string) =>
    call<{ id: string; status: string }>("revoke_sessions", {
      user_id: userId,
    }),

  setOverride: (userId: string, areaKey: string, effect: "allow" | "deny") =>
    call<{ id: string; area_key: string; effect: string }>("set_override", {
      user_id: userId,
      area_key: areaKey,
      effect,
    }),

  clearOverride: (userId: string, areaKey: string) =>
    call<{ id: string; area_key: string; cleared: boolean }>("clear_override", {
      user_id: userId,
      area_key: areaKey,
    }),
};

// A 12-character temporary password: upper, lower, digit, guaranteed one of
// each, the rest random from a pool that excludes visually ambiguous
// characters (0/O, 1/l/I).
const PASSWORD_POOL = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789";

export function generateTempPassword(): string {
  const pick = (pool: string) => pool[Math.floor(Math.random() * pool.length)];
  const required = [
    pick("ABCDEFGHJKMNPQRSTUVWXYZ"),
    pick("abcdefghjkmnpqrstuvwxyz"),
    pick("23456789"),
  ];
  const rest = Array.from({ length: 9 }, () => pick(PASSWORD_POOL));
  const chars = [...required, ...rest];
  // Shuffle so the required characters aren't always in the first 3 slots.
  for (let i = chars.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [chars[i], chars[j]] = [chars[j], chars[i]];
  }
  return chars.join("");
}
