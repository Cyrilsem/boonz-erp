import { createServerClient } from '@supabase/ssr'
import { NextResponse, type NextRequest } from 'next/server'

export async function middleware(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request })

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll()
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) =>
            request.cookies.set(name, value)
          )
          supabaseResponse = NextResponse.next({ request })
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options)
          )
        },
      },
    }
  )

  // Always use getUser() — not getSession(). getUser() validates the JWT
  // server-side. getSession() reads from cookie without validation.
  const {
    data: { user },
  } = await supabase.auth.getUser()

  const path = request.nextUrl.pathname

  // Pass-through: public routes, Next.js internals, static files
  const isPublic =
    path.startsWith('/login') ||
    path.startsWith('/reset-password') ||
    path.startsWith('/auth') ||
    path.startsWith('/_next') ||
    path.startsWith('/api') ||
    path === '/favicon.ico' ||
    /\.(svg|png|jpg|jpeg|gif|webp|ico|css|js)$/.test(path)

  if (isPublic) {
    return supabaseResponse
  }

  // No session → redirect to login, preserve intended destination
  if (!user) {
    const loginUrl = new URL('/login', request.url)
    loginUrl.searchParams.set('redirectTo', path)
    return NextResponse.redirect(loginUrl)
  }

  // Fetch role from user_profiles
  const { data: profile } = await supabase
    .from('user_profiles')
    .select('role')
    .eq('id', user.id)
    .single()

  const role = profile?.role ?? 'field_staff'

  const appRoles    = ['superadmin', 'operator_admin', 'manager', 'finance']
  const fieldRoles  = ['field_staff', 'warehouse']
  const portalRoles = ['client']

  const onApp    = path.startsWith('/app')
  const onField  = path.startsWith('/field')
  const onPortal = path.startsWith('/portal')
  const onChat   = path.startsWith('/chat')

  // Chat: app roles only
  if (onChat && !appRoles.includes(role)) {
    return NextResponse.redirect(new URL('/login', request.url))
  }

  // Wrong surface → redirect to correct one
  if (fieldRoles.includes(role) && (onApp || onPortal || onChat)) {
    return NextResponse.redirect(new URL('/field', request.url))
  }
  if (portalRoles.includes(role) && (onApp || onField || onChat)) {
    return NextResponse.redirect(new URL('/portal', request.url))
  }
  if (appRoles.includes(role) && (onField || onPortal)) {
    return NextResponse.redirect(new URL('/app', request.url))
  }

  return supabaseResponse
}

export const config = {
  matcher: [
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)',
  ],
}
