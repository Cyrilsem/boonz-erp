/**
 * admin-users: Supabase Edge Function
 *
 * PRD-140 Item 2. One function, every Settings > Users action, gated on the
 * caller holding the app.settings.users area (via has_area, the resolver
 * built in PRD-140 Item 1). Service role key never leaves this function.
 *
 * Auth: requires a valid Supabase JWT. The caller's own access is checked
 * with has_area before any action runs; anyone without app.settings.users
 * gets 403, including a read-only `list`.
 *
 * POST /functions/v1/admin-users
 * Body: { action: string, ...payload }
 *
 * actions: list, create, set_role, set_name, set_password, send_reset,
 * ban, unban, revoke_sessions, set_override, clear_override.
 */

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Matches the 6 roles seeded in role_area_defaults (PRD-140 Item 1). The DB's
// own user_profiles_role_check also allows "client" and "tracker_boonz", but
// those are separate concepts with no row in role_area_defaults -- this admin
// UI intentionally does not offer setting a user to either via this action.
const SETTABLE_ROLES = [
  "superadmin",
  "operator_admin",
  "manager",
  "warehouse",
  "field_staff",
  "finance",
] as const;
type SettableRole = (typeof SETTABLE_ROLES)[number];

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return json({ error: "Unauthorized" }, 401);
  }

  // anonClient: forwards the caller's own JWT. Used for auth.getUser() and
  // for the two actions (set_override, clear_override) whose SQL functions
  // need auth.uid() to resolve to the real caller, both for their own
  // authorization check and for access_audit_log.actor_id attribution.
  const anonClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );

  const {
    data: { user: caller },
    error: authError,
  } = await anonClient.auth.getUser();
  if (authError || !caller) {
    return json({ error: "Unauthorized" }, 401);
  }

  // serviceClient: service_role, for every auth.admin.* call and for the
  // actions above that cannot run as the ordinary authenticated role.
  const serviceClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: callerHasAccess, error: accessErr } = await serviceClient.rpc(
    "has_area",
    { p_user_id: caller.id, p_key: "app.settings.users" },
  );
  if (accessErr || !callerHasAccess) {
    return json({ error: "Forbidden" }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }
  const action = body.action as string | undefined;

  try {
    switch (action) {
      case "list":
        return json(await actionList(serviceClient), 200);
      case "create":
        return json(await actionCreate(serviceClient, caller.id, body), 200);
      case "set_role":
        return json(await actionSetRole(serviceClient, caller.id, body), 200);
      case "set_name":
        return json(await actionSetName(serviceClient, caller.id, body), 200);
      case "set_password":
        return json(
          await actionSetPassword(serviceClient, caller.id, body),
          200,
        );
      case "send_reset":
        return json(await actionSendReset(serviceClient, caller.id, body), 200);
      case "ban":
        return json(
          await actionBanUnban(serviceClient, caller.id, body, true),
          200,
        );
      case "unban":
        return json(
          await actionBanUnban(serviceClient, caller.id, body, false),
          200,
        );
      case "revoke_sessions":
        return json(
          await actionRevokeSessions(serviceClient, caller.id, body),
          200,
        );
      case "set_override":
        return json(await actionSetOverride(anonClient, body), 200);
      case "clear_override":
        return json(await actionClearOverride(anonClient, body), 200);
      default:
        return json({ error: `Unknown action: ${action}` }, 400);
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[admin-users] action=${action} error:`, message);
    return json({ error: message }, 400);
  }
});

// deno-lint-ignore no-explicit-any
type SBClient = any;

// ── Helpers ──────────────────────────────────────────────────────────────────

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

async function writeAudit(
  serviceClient: SBClient,
  actorId: string,
  targetUserId: string | null,
  action: string,
  before: unknown,
  after: unknown,
) {
  const { error } = await serviceClient.from("access_audit_log").insert({
    actor_id: actorId,
    target_user_id: targetUserId,
    action,
    before: before ?? null,
    after: after ?? null,
  });
  if (error) {
    // Never block the actual action over an audit-log write failure; log and move on.
    console.error("[admin-users] audit write failed:", error.message);
  }
}

// ── Actions ──────────────────────────────────────────────────────────────────

async function actionList(serviceClient: SBClient) {
  const { data: listResult, error: listErr } =
    await serviceClient.auth.admin.listUsers({ perPage: 200 });
  if (listErr) throw new Error(`listUsers failed: ${listErr.message}`);
  const authUsers = listResult.users;

  const { data: profiles, error: profErr } = await serviceClient
    .from("user_profiles")
    .select("id, full_name, role");
  if (profErr) throw new Error(`user_profiles read failed: ${profErr.message}`);
  const profileById = new Map(
    (profiles ?? []).map((p: { id: string }) => [p.id, p]),
  );

  const { data: sessionCounts, error: sessErr } = await serviceClient.rpc(
    "admin_user_session_counts",
  );
  if (sessErr) throw new Error(`session counts failed: ${sessErr.message}`);
  const sessionsById = new Map(
    (sessionCounts ?? []).map(
      (s: { user_id: string; open_sessions: number }) => [
        s.user_id,
        s.open_sessions,
      ],
    ),
  );

  const rows = [];
  for (const u of authUsers) {
    const profile = profileById.get(u.id) as
      { id: string; full_name: string | null; role: string } | undefined;
    if (!profile) continue; // auth user with no profile row: not a app/field user, skip

    const { data: access } = await serviceClient.rpc("resolve_user_access", {
      p_user_id: u.id,
    });
    const areaKeys: string[] = (access ?? []).map(
      (a: { area_key: string }) => a.area_key,
    );
    const surfaces = {
      app: areaKeys.some((k) => k.startsWith("app.") && k !== "app.tracker"),
      field: areaKeys.some((k) => k.startsWith("field.")),
      tracker: areaKeys.includes("app.tracker"),
    };

    rows.push({
      id: u.id,
      email: u.email,
      full_name: profile.full_name,
      role: profile.role,
      last_sign_in_at: u.last_sign_in_at ?? null,
      banned_until: u.banned_until ?? null,
      created_at: u.created_at,
      open_sessions: sessionsById.get(u.id) ?? 0,
      surfaces,
    });
  }

  return { users: rows };
}

async function actionCreate(
  serviceClient: SBClient,
  actorId: string,
  body: Record<string, unknown>,
) {
  const email = String(body.email ?? "").trim();
  const fullName = String(body.full_name ?? "").trim();
  const role = body.role as string;
  const password = String(body.password ?? "");

  if (!email) throw new Error("email is required");
  if (!fullName) throw new Error("full_name is required");
  if (!SETTABLE_ROLES.includes(role as SettableRole)) {
    throw new Error(`role must be one of: ${SETTABLE_ROLES.join(", ")}`);
  }
  if (password.length < 8) {
    throw new Error("password must be at least 8 characters");
  }

  const { data: created, error: createErr } =
    await serviceClient.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });
  if (createErr) throw new Error(`createUser failed: ${createErr.message}`);
  const newUserId = created.user.id;

  const { error: profileErr } = await serviceClient
    .from("user_profiles")
    .insert({
      id: newUserId,
      full_name: fullName,
      role,
      onboarding_complete: false,
    });
  if (profileErr) {
    // The ONLY permitted auth user deletion in this function: undoing a user
    // that never existed before this same request, because its profile
    // insert failed and an auth user with no profile is not a usable account.
    await serviceClient.auth.admin.deleteUser(newUserId);
    throw new Error(
      `profile insert failed, user rolled back: ${profileErr.message}`,
    );
  }

  await writeAudit(serviceClient, actorId, newUserId, "create", null, {
    email,
    full_name: fullName,
    role,
  });

  return { id: newUserId, email, full_name: fullName, role };
}

async function actionSetRole(
  serviceClient: SBClient,
  actorId: string,
  body: Record<string, unknown>,
) {
  const targetId = String(body.user_id ?? "");
  const newRole = body.role as string;
  if (!targetId) throw new Error("user_id is required");
  if (targetId === actorId) throw new Error("cannot change your own role");
  if (!SETTABLE_ROLES.includes(newRole as SettableRole)) {
    throw new Error(`role must be one of: ${SETTABLE_ROLES.join(", ")}`);
  }

  const { data: callerProfile, error: callerErr } = await serviceClient
    .from("user_profiles")
    .select("role")
    .eq("id", actorId)
    .single();
  if (callerErr)
    throw new Error(`could not read caller role: ${callerErr.message}`);

  const { data: targetProfile, error: targetErr } = await serviceClient
    .from("user_profiles")
    .select("role")
    .eq("id", targetId)
    .single();
  if (targetErr) throw new Error(`target user not found: ${targetErr.message}`);

  const callerIsSuperadmin = callerProfile.role === "superadmin";
  if (
    (newRole === "superadmin" || targetProfile.role === "superadmin") &&
    !callerIsSuperadmin
  ) {
    throw new Error("only a superadmin can set or unset the superadmin role");
  }

  const { error: updateErr } = await serviceClient
    .from("user_profiles")
    .update({ role: newRole })
    .eq("id", targetId);
  if (updateErr) throw new Error(`role update failed: ${updateErr.message}`);

  await writeAudit(
    serviceClient,
    actorId,
    targetId,
    "set_role",
    { role: targetProfile.role },
    { role: newRole },
  );

  return { id: targetId, role: newRole };
}

async function actionSetName(
  serviceClient: SBClient,
  actorId: string,
  body: Record<string, unknown>,
) {
  const targetId = String(body.user_id ?? "");
  const fullName = String(body.full_name ?? "").trim();
  if (!targetId) throw new Error("user_id is required");
  if (!fullName) throw new Error("full_name is required");

  const { data: before } = await serviceClient
    .from("user_profiles")
    .select("full_name")
    .eq("id", targetId)
    .single();

  const { error: updateErr } = await serviceClient
    .from("user_profiles")
    .update({ full_name: fullName })
    .eq("id", targetId);
  if (updateErr) throw new Error(`name update failed: ${updateErr.message}`);

  await writeAudit(
    serviceClient,
    actorId,
    targetId,
    "set_name",
    before ?? null,
    { full_name: fullName },
  );

  return { id: targetId, full_name: fullName };
}

async function actionSetPassword(
  serviceClient: SBClient,
  actorId: string,
  body: Record<string, unknown>,
) {
  const targetId = String(body.user_id ?? "");
  const password = String(body.password ?? "");
  if (!targetId) throw new Error("user_id is required");
  if (password.length < 8) {
    throw new Error("password must be at least 8 characters");
  }

  const { error: updateErr } = await serviceClient.auth.admin.updateUserById(
    targetId,
    { password },
  );
  if (updateErr) throw new Error(`set_password failed: ${updateErr.message}`);

  // Never log the password itself.
  await writeAudit(serviceClient, actorId, targetId, "set_password", null, {
    changed: true,
  });

  return { id: targetId, status: "password_set" };
}

async function actionSendReset(
  serviceClient: SBClient,
  actorId: string,
  body: Record<string, unknown>,
) {
  const targetId = String(body.user_id ?? "");
  if (!targetId) throw new Error("user_id is required");

  const { data: target, error: getErr } =
    await serviceClient.auth.admin.getUserById(targetId);
  if (getErr || !target?.user?.email) {
    throw new Error(
      `could not resolve target email: ${getErr?.message ?? "no email on file"}`,
    );
  }

  const { data: linkData, error: linkErr } =
    await serviceClient.auth.admin.generateLink({
      type: "recovery",
      email: target.user.email,
    });
  if (linkErr) throw new Error(`generateLink failed: ${linkErr.message}`);

  // No project email-sending path exists yet (grepped supabase/functions and
  // src/lib for resend/sendgrid/smtp: nothing found). Per this item's own
  // spec: return the link to the caller and log that CS must send it,
  // rather than blocking the item on building an email integration.
  console.log(
    `[admin-users] send_reset: no email path configured, returning recovery link to caller for manual send to ${target.user.email}`,
  );

  await writeAudit(serviceClient, actorId, targetId, "send_reset", null, {
    email: target.user.email,
    note: "no email path configured, link returned to caller for manual send",
  });

  return {
    id: targetId,
    email: target.user.email,
    recovery_link: linkData.properties.action_link,
    note: "No email path is configured in this project. Send this link to the user yourself.",
  };
}

async function actionBanUnban(
  serviceClient: SBClient,
  actorId: string,
  body: Record<string, unknown>,
  ban: boolean,
) {
  const targetId = String(body.user_id ?? "");
  if (!targetId) throw new Error("user_id is required");
  if (ban && targetId === actorId) throw new Error("cannot ban yourself");

  if (ban) {
    const { data: callerProfile } = await serviceClient
      .from("user_profiles")
      .select("role")
      .eq("id", actorId)
      .single();
    const { data: targetProfile } = await serviceClient
      .from("user_profiles")
      .select("role")
      .eq("id", targetId)
      .single();
    if (
      targetProfile?.role === "superadmin" &&
      callerProfile?.role !== "superadmin"
    ) {
      throw new Error("only a superadmin can ban a superadmin");
    }
  }

  const { error: updateErr } = await serviceClient.auth.admin.updateUserById(
    targetId,
    { ban_duration: ban ? "876000h" : "none" },
  );
  if (updateErr) {
    throw new Error(`${ban ? "ban" : "unban"} failed: ${updateErr.message}`);
  }

  await writeAudit(
    serviceClient,
    actorId,
    targetId,
    ban ? "ban" : "unban",
    null,
    { banned: ban },
  );

  return { id: targetId, banned: ban };
}

async function actionRevokeSessions(
  serviceClient: SBClient,
  actorId: string,
  body: Record<string, unknown>,
) {
  const targetId = String(body.user_id ?? "");
  if (!targetId) throw new Error("user_id is required");

  const { error } = await serviceClient.auth.admin.signOut(targetId, "global");
  if (error) throw new Error(`revoke_sessions failed: ${error.message}`);

  await writeAudit(serviceClient, actorId, targetId, "revoke_sessions", null, {
    revoked: true,
  });

  return { id: targetId, status: "sessions_revoked" };
}

// set_override / clear_override intentionally use anonClient (the caller's
// own forwarded JWT), not serviceClient: the SQL functions key their own
// authorization check and access_audit_log.actor_id off auth.uid(), which
// only resolves to the real caller when their JWT is forwarded. Calling
// these via the service client would record actor_id as NULL.

async function actionSetOverride(
  anonClient: SBClient,
  body: Record<string, unknown>,
) {
  const targetId = String(body.user_id ?? "");
  const key = String(body.area_key ?? "");
  const effect = String(body.effect ?? "");
  if (!targetId || !key) throw new Error("user_id and area_key are required");
  if (effect !== "allow" && effect !== "deny") {
    throw new Error("effect must be allow or deny");
  }

  const { error } = await anonClient.rpc("set_user_area_override", {
    p_user_id: targetId,
    p_key: key,
    p_effect: effect,
  });
  if (error) throw new Error(`set_override failed: ${error.message}`);

  return { id: targetId, area_key: key, effect };
}

async function actionClearOverride(
  anonClient: SBClient,
  body: Record<string, unknown>,
) {
  const targetId = String(body.user_id ?? "");
  const key = String(body.area_key ?? "");
  if (!targetId || !key) throw new Error("user_id and area_key are required");

  const { error } = await anonClient.rpc("clear_user_area_override", {
    p_user_id: targetId,
    p_key: key,
  });
  if (error) throw new Error(`clear_override failed: ${error.message}`);

  return { id: targetId, area_key: key, cleared: true };
}
