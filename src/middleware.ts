import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import {
  ROLE_COOKIE_MAX_AGE_S,
  ROLE_COOKIE_NAME,
  signRoleCookie,
  verifyRoleCookie,
} from "@/lib/auth/role-cookie";

// Hard caps to prevent MIDDLEWARE_INVOCATION_TIMEOUT (Vercel kills at 25s).
// Supabase Auth API or DB pool starvation can stall these calls indefinitely.
// On timeout we redirect to /login instead of letting Vercel hammer the request.
const AUTH_TIMEOUT_MS = 5000;
const PROFILE_TIMEOUT_MS = 3000;

// PRD-139b Item 3: server-side per-route gate for /field. The client-side checks in
// each page (e.g. field/config/page.tsx's CONFIG_ROLES) are UX only, not security —
// this is the actual enforcement. Most-specific prefix wins; an exact match on "/field"
// itself is allowed for every field-accessible role; anything under /field that matches
// none of the rules below falls back to admins-only.
const FIELD_ADMIN_ROLES = ["operator_admin", "manager", "superadmin"];
const FIELD_WAREHOUSE_ROLES = ["warehouse", ...FIELD_ADMIN_ROLES];
const FIELD_ALL_ROLES = ["field_staff", ...FIELD_WAREHOUSE_ROLES];

const FIELD_ROUTE_RULES: { prefix: string; roles: readonly string[] }[] = [
  // Admins-only (checked first: most specific prefixes under /field/config).
  // Mirrors the page-level role lists: product-naming is the only config page
  // that excludes warehouse. sims + suppliers allow warehouse on the page and
  // were wrongly admins-only here (warehouse tapping SIM Cards bounced home).
  { prefix: "/field/config/product-naming", roles: FIELD_ADMIN_ROLES },
  // warehouse + admins
  { prefix: "/field/packing", roles: FIELD_WAREHOUSE_ROLES },
  { prefix: "/field/shelf-view", roles: FIELD_WAREHOUSE_ROLES },
  { prefix: "/field/dispatching/pick", roles: FIELD_WAREHOUSE_ROLES },
  { prefix: "/field/not-filled", roles: FIELD_WAREHOUSE_ROLES },
  { prefix: "/field/capture", roles: FIELD_WAREHOUSE_ROLES },
  { prefix: "/field/orders", roles: FIELD_WAREHOUSE_ROLES },
  { prefix: "/field/receiving", roles: FIELD_WAREHOUSE_ROLES },
  { prefix: "/field/inventory", roles: FIELD_WAREHOUSE_ROLES },
  { prefix: "/field/expiry", roles: FIELD_WAREHOUSE_ROLES },
  // catches /field/config and every other config sub-route (boonz-products,
  // pod-products, product-mapping, product-naming, machines) not already matched above
  { prefix: "/field/config", roles: FIELD_WAREHOUSE_ROLES },
  // field_staff + warehouse + admins
  { prefix: "/field/pickup", roles: FIELD_ALL_ROLES },
  { prefix: "/field/dispatching", roles: FIELD_ALL_ROLES },
  { prefix: "/field/trips", roles: FIELD_ALL_ROLES },
  // all roles
  { prefix: "/field/profile", roles: FIELD_ALL_ROLES },
  { prefix: "/field/tasks", roles: FIELD_ALL_ROLES },
  { prefix: "/field/pod-inventory", roles: FIELD_ALL_ROLES },
];

function isFieldRouteAllowed(path: string, role: string): boolean {
  if (path === "/field") return true;
  for (const rule of FIELD_ROUTE_RULES) {
    if (path.startsWith(rule.prefix)) return rule.roles.includes(role);
  }
  // Unknown /field route: admins only.
  return FIELD_ADMIN_ROLES.includes(role);
}

function withTimeout<T>(
  p: PromiseLike<T>,
  ms: number,
  label: string,
): Promise<T> {
  return Promise.race([
    Promise.resolve(p),
    new Promise<T>((_, reject) =>
      setTimeout(() => reject(new Error(`middleware_timeout:${label}`)), ms),
    ),
  ]);
}

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  // Skip auth entirely for static files and Next.js internals.
  // These were triggering 30+ /user calls per page load.
  if (
    pathname.startsWith("/_next/") ||
    pathname.startsWith("/api/") ||
    pathname.includes(".") ||
    pathname === "/robots.txt" ||
    pathname === "/sitemap.xml"
  ) {
    return NextResponse.next();
  }

  let supabaseResponse = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) =>
            request.cookies.set(name, value),
          );
          supabaseResponse = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options),
          );
        },
      },
    },
  );

  const path = request.nextUrl.pathname;

  // ── Public pass-through (cheap check FIRST, before any network call) ─────────
  const isPublic =
    path.startsWith("/login") ||
    path === "/logout" ||
    path.startsWith("/reset-password") ||
    path.startsWith("/auth") ||
    path.startsWith("/_next") ||
    path.startsWith("/api") ||
    path === "/favicon.ico" ||
    /\.(svg|png|jpg|jpeg|gif|webp|ico|css|js)$/.test(path);

  if (isPublic) return supabaseResponse;

  // Always use getUser() — validates JWT server-side (not getSession() which reads cookie only)
  // Bounded by AUTH_TIMEOUT_MS so we never hit Vercel's 25s middleware ceiling.
  let user: Awaited<ReturnType<typeof supabase.auth.getUser>>["data"]["user"] =
    null;
  let authError: unknown = null;
  try {
    const result = await withTimeout(
      supabase.auth.getUser(),
      AUTH_TIMEOUT_MS,
      "getUser",
    );
    user = result.data.user;
    authError = result.error;
  } catch {
    // Supabase Auth stalled. Fail to login rather than let Vercel kill the request.
    const loginUrl = new URL("/login", request.url);
    loginUrl.searchParams.set("redirectTo", path);
    loginUrl.searchParams.set("error", "auth_timeout");
    return NextResponse.redirect(loginUrl);
  }

  // ── No session → login ───────────────────────────────────────────────────────
  if (authError || !user) {
    const loginUrl = new URL("/login", request.url);
    loginUrl.searchParams.set("redirectTo", path);
    return NextResponse.redirect(loginUrl);
  }

  // ── vox_admin: role lives in app_metadata, no user_profiles row needed ───────
  if (user.app_metadata?.role === "vox_admin") {
    const allowed =
      path === "/consumers_vox" ||
      path.startsWith("/consumers_vox/") ||
      path.startsWith("/api/vox/") ||
      path.startsWith("/login");
    if (!allowed) {
      return NextResponse.redirect(new URL("/consumers_vox", request.url));
    }
    return supabaseResponse;
  }

  // ── Fast path: signed role cookie ────────────────────────────────────────────
  // Avoids a Postgres roundtrip on every protected request. Cookie is bound to
  // the Supabase user_id, so a stale cookie from another user fails verify
  // and we fall through to the slow path (which then rewrites the cookie).
  let role: string | null = null;
  let roleFromCookie = false;
  const roleCookieRaw = request.cookies.get(ROLE_COOKIE_NAME)?.value;
  if (roleCookieRaw) {
    try {
      role = await verifyRoleCookie(roleCookieRaw, user.id);
      roleFromCookie = role !== null;
    } catch {
      role = null;
    }
  }

  // ── Slow path: fetch role from user_profiles + rewrite the cookie ────────────
  // Bounded by PROFILE_TIMEOUT_MS. If the DB stalls (pool starvation, slow RLS),
  // fail to login rather than block the page load.
  if (!role) {
    try {
      const { data: profile } = await withTimeout(
        supabase
          .from("user_profiles")
          .select("role")
          .eq("id", user.id)
          .single(),
        PROFILE_TIMEOUT_MS,
        "user_profiles",
      );
      role = profile?.role ?? null;
    } catch {
      const loginUrl = new URL("/login", request.url);
      loginUrl.searchParams.set("redirectTo", path);
      loginUrl.searchParams.set("error", "profile_timeout");
      return NextResponse.redirect(loginUrl);
    }

    if (!role) {
      // Profile missing or RLS blocked read — force re-login instead of
      // silently falling through as field_staff
      const loginUrl = new URL("/login", request.url);
      loginUrl.searchParams.set("redirectTo", path);
      loginUrl.searchParams.set("error", "session_invalid");
      return NextResponse.redirect(loginUrl);
    }

    // Refresh the signed cookie on the outbound response.
    try {
      const signed = await signRoleCookie(user.id, role);
      supabaseResponse.cookies.set(ROLE_COOKIE_NAME, signed, {
        httpOnly: true,
        secure: process.env.NODE_ENV === "production",
        sameSite: "lax",
        path: "/",
        maxAge: ROLE_COOKIE_MAX_AGE_S,
      });
    } catch {
      // ROLE_COOKIE_SECRET not configured — proceed without caching. The fix
      // still works, it just doesn't get the perf benefit until the env var
      // is set. Don't break the request over it.
    }
  }
  // (roleFromCookie is reserved for future logging; kept to make the path
  // taken visible to grep.)
  void roleFromCookie;

  const onApp = path.startsWith("/app");
  const onField = path.startsWith("/field");
  const onPortal = path.startsWith("/portal");
  const onChat = path.startsWith("/chat");

  // ── Field-only roles (warehouse, field_staff) ────────────────────────────────
  // Allow: /field/*
  // Block: /app, /portal, /chat → redirect to /field
  if (role === "field_staff" || role === "warehouse") {
    if (onApp || onPortal || onChat) {
      return NextResponse.redirect(new URL("/field", request.url));
    }
    if (onField && !isFieldRouteAllowed(path, role)) {
      return NextResponse.redirect(new URL("/field", request.url));
    }
    return supabaseResponse;
  }

  // ── Ops roles (operator_admin, manager, superadmin) ──────────────────────────
  // Allow: /field/*, /app/*, /chat/* — full ops visibility across both surfaces
  // Block: /portal → redirect to /app
  if (
    role === "operator_admin" ||
    role === "manager" ||
    role === "superadmin"
  ) {
    if (onPortal) {
      return NextResponse.redirect(new URL("/app", request.url));
    }
    return supabaseResponse; // explicit pass-through — /field/packing etc reach the page
  }

  // ── Finance ──────────────────────────────────────────────────────────────────
  // Allow: /app/*, /chat/*
  // Block: /field, /portal → redirect to /app
  if (role === "finance") {
    if (onField || onPortal) {
      return NextResponse.redirect(new URL("/app", request.url));
    }
    return supabaseResponse;
  }

  // ── Client (portal-only) ─────────────────────────────────────────────────────
  // Allow: /portal/*
  // Block: everything else → redirect to /portal
  if (role === "client") {
    if (onApp || onField || onChat) {
      return NextResponse.redirect(new URL("/portal", request.url));
    }
    return supabaseResponse;
  }

  // ── Boonz tracker partner (tracker_boonz) ────────────────────────────────────
  // Allow: /tracker only. Everything else → redirect to /tracker.
  if (role === "tracker_boonz") {
    if (path === "/tracker" || path.startsWith("/tracker/")) {
      return supabaseResponse;
    }
    return NextResponse.redirect(new URL("/tracker", request.url));
  }

  // ── Unknown role — pass through, page-level guards handle it ─────────────────
  return supabaseResponse;
}

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico|css|js|woff|woff2|ttf|map)$).*)",
  ],
};
