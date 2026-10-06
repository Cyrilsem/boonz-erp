import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { ROLE_COOKIE_NAME } from "@/lib/auth/role-cookie";

// GET /logout — one URL that signs any user out of any surface (field,
// warehouse, admin, VOX) and lands them on a fresh /login.
//
// Why a route and not only client-side signOut(): the warehouse and admin
// homes had no sign-out control, and client-side signOut() leaves the signed
// `boonz_role` middleware cookie behind. Clearing it here means a user who
// switches account (shared test login → personal login) gets the new role on
// the very next request instead of inheriting the old one for up to 15 min.
export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  try {
    const supabase = await createClient();
    await supabase.auth.signOut();
  } catch {
    // Session already gone or Auth unreachable — still clear cookies + redirect.
  }

  const res = NextResponse.redirect(new URL("/login", request.url), 303);
  res.cookies.set(ROLE_COOKIE_NAME, "", { path: "/", maxAge: 0 });
  // Belt and braces: drop any Supabase auth cookies on the response too.
  for (const c of request.cookies.getAll()) {
    if (c.name.startsWith("sb-")) {
      res.cookies.set(c.name, "", { path: "/", maxAge: 0 });
    }
  }
  return res;
}
