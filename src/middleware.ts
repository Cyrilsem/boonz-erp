import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

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

  // Always use getUser() — validates JWT server-side (not getSession() which reads cookie only)
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  const path = request.nextUrl.pathname;

  // ── Public pass-through ──────────────────────────────────────────────────────
  const isPublic =
    path.startsWith("/login") ||
    path.startsWith("/reset-password") ||
    path.startsWith("/auth") ||
    path.startsWith("/_next") ||
    path.startsWith("/api") ||
    path === "/favicon.ico" ||
    /\.(svg|png|jpg|jpeg|gif|webp|ico|css|js)$/.test(path);

  if (isPublic) return supabaseResponse;

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

  // ── Fetch role from user_profiles for all other users ────────────────────────
  const { data: profile } = await supabase
    .from("user_profiles")
    .select("role")
    .eq("id", user.id)
    .single();

  const role = profile?.role ?? null;

  if (!role) {
    // Profile missing or RLS blocked read — force re-login instead of
    // silently falling through as field_staff
    const loginUrl = new URL("/login", request.url);
    loginUrl.searchParams.set("redirectTo", path);
    loginUrl.searchParams.set("error", "session_invalid");
    return NextResponse.redirect(loginUrl);
  }

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

  // ── Unknown role — pass through, page-level guards handle it ─────────────────
  return supabaseResponse;
}

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico|css|js|woff|woff2|ttf|map)$).*)",
  ],
};
