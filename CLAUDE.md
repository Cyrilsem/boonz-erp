# Boonz ERP — Claude Code Instructions
## Stories P1-S1 through P1-S4

You are building the Boonz ERP platform. Read every section of this file before
writing a single line of code. Do not skip ahead. Do not make assumptions that
contradict anything written here.

---

## What you are building

A Next.js 14 monorepo for a UAE smart vending operator. The app has 4 surfaces
in a single codebase:
- `/app/*`    — management ERP (internal team)
- `/field/*`  — field staff PWA (drivers + warehouse)
- `/portal/*` — client portal (read-only for vending location clients)
- `/chat/*`   — agentic GUI (Claude-powered command interface)

This session covers P1-S1 through P1-S4 only:
- P1-S1: Scaffold the Next.js app and folder structure
- P1-S2: Install Supabase packages and create lib/supabase helpers
- P1-S3: ✅ ALREADY DONE — user_profiles table exists in Supabase with RLS
- P1-S4: Auth middleware — session refresh + role-based surface routing

---

## Immutable decisions — do not reverse these

1. **Single Next.js codebase, 4 route groups** — not separate apps
2. **RLS enforced at DB level, not just UI** — every permission gate is a
   Supabase RLS policy. Middleware routing is cosmetic only.
3. **SUPABASE_SERVICE_ROLE_KEY** — never import this in any client component
   or any file under `src/app/` directly. Only via server.ts or Edge Functions.
4. **TypeScript strict mode** — no `any`, no ts-ignore
5. **No OAuth / social login in Phase 1** — email + password only

---

## Supabase project

- Project ID: `eizcexopcuoycuosittm`
- URL: `https://eizcexopcuoycuosittm.supabase.co`
- Region: ap-south-1 (Mumbai)
- DB status: 21 tables exist and are populated — do not run any CREATE TABLE
  migrations in this session. user_profiles already exists.

### user_profiles table (already live — do not recreate)

```
id               uuid  PK → auth.users.id
role             text  CHECK IN ('superadmin','operator_admin','manager',
                                  'finance','field_staff','warehouse','client')
operator_id      uuid  nullable
client_id        uuid  nullable
full_name        text  nullable
telegram_user_id text  nullable
created_at       timestamptz
updated_at       timestamptz
```

RLS is ON. Two policies exist:
- `users_own_profile` — SELECT where auth.uid() = id
- `admins_manage_profiles` — ALL where caller role IN ('superadmin','operator_admin')

Auto-trigger exists: every new auth.users row auto-creates a user_profiles row
with default role = 'field_staff'.

---

## Environment variables — READ FROM EXISTING .env FILE

**The `.env` file already exists in this project directory. Do not create it,
do not overwrite it, do not prompt for values.**

Your job regarding environment variables:
1. Verify `.env` exists at the project root: `ls -la .env`
2. Verify it contains these keys (use `grep` to check key names only — do not
   print or log values):
   - `NEXT_PUBLIC_SUPABASE_URL`
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY`
   - `SUPABASE_SERVICE_ROLE_KEY`
3. If any key is missing, list which ones are absent and stop — do not proceed
   until the operator adds them
4. Ensure `.env` is in `.gitignore` — add it if not already present

**Next.js loads `.env` automatically** — no extra configuration needed.

**Required `.gitignore` entries** (add if missing, never remove existing ones):
```
.env
.env.local
.env*.local
```

---

## P1-S1: Scaffold Next.js app

### Step 1 — Scaffold (skip if package.json already exists)

If `package.json` already exists in the current directory, skip this command
and go straight to Step 2.

If no `package.json`:
```bash
npx create-next-app@latest . \
  --typescript \
  --tailwind \
  --eslint \
  --app \
  --src-dir \
  --import-alias "@/*" \
  --no-turbopack
```

The `.` scaffolds into the current directory, not a subdirectory.

### Step 2 — Create route group folders

Inside `src/app/`, create these folders and files:

```
src/app/
├── (app)/
│   ├── layout.tsx
│   └── page.tsx
├── (field)/
│   ├── layout.tsx
│   └── page.tsx
├── (portal)/
│   ├── layout.tsx
│   └── page.tsx
├── (chat)/
│   ├── layout.tsx
│   └── page.tsx
└── (auth)/
    └── login/
        └── page.tsx
```

**Each `layout.tsx`:**
```tsx
export default function Layout({ children }: { children: React.ReactNode }) {
  return <>{children}</>
}
```

**Each `page.tsx`** (use the surface name as label):
```tsx
export default function Page() {
  return <div>Boonz — [App / Field / Portal / Chat / Login] placeholder</div>
}
```

### Step 3 — Create repo folder structure

Create these with `.gitkeep` files so they commit to git:
```
docs/
engines/refill/
engines/sales/
engines/procurement/
engines/finance/
agent/tools/
n8n/flows/
supabase/migrations/
```

Create `agent/system_prompt.md`:
```markdown
# Boonz Agent System Prompt

You are the Boonz operations agent. You help the operator run the company.

<!-- Full prompt defined in Phase 4 (P4-S1). Placeholder only. -->
```

### P1-S1 acceptance criteria

- [ ] `npx next build` completes with 0 errors
- [ ] All 4 route groups exist under `src/app/`
- [ ] `supabase/migrations/` exists
- [ ] `.env` present and listed in `.gitignore`

---

## P1-S2: Supabase client helpers

### Install packages

```bash
npm install @supabase/supabase-js @supabase/ssr
npm install -D @types/node
```

### Create `src/lib/supabase/client.ts`

Used in Client Components (`'use client'`) only.

```ts
import { createBrowserClient } from '@supabase/ssr'

export function createClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  )
}
```

### Create `src/lib/supabase/server.ts`

Used in Server Components, Route Handlers, and Server Actions only.

```ts
import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'

export async function createClient() {
  const cookieStore = await cookies()

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll()
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options)
            )
          } catch {
            // Intentional: called from Server Component read-only context
          }
        },
      },
    }
  )
}
```

### P1-S2 acceptance criteria

- [ ] `@/lib/supabase/client` resolves in a `'use client'` component — 0 TS errors
- [ ] `@/lib/supabase/server` resolves in a server component — 0 TS errors
- [ ] `SUPABASE_SERVICE_ROLE_KEY` not referenced in either file
- [ ] `npx next build` still 0 errors

---

## P1-S3: ALREADY DONE — skip entirely

Do not run any SQL. Do not create any migration. Do not touch the database.

---

## P1-S4: Auth middleware

Create `src/middleware.ts` at the project root (same level as `package.json`,
**not** inside `src/app/`).

```ts
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
```

### P1-S4 acceptance criteria

- [ ] `/app` without session → redirects to `/login?redirectTo=/app`
- [ ] `/field` without session → redirects to `/login`
- [ ] `field_staff` visiting `/app` → redirected to `/field`
- [ ] `warehouse` visiting `/app` → redirected to `/field`
- [ ] `client` visiting `/app` → redirected to `/portal`
- [ ] `manager` visiting `/field` → redirected to `/app`
- [ ] `operator_admin` visiting `/app` → passes through (no redirect)
- [ ] `npx next build` — 0 errors
- [ ] `npx tsc --noEmit` — 0 errors

---

## Final verification

```bash
npx next build
npx tsc --noEmit
```

Both must exit code 0. This session is complete when both pass.

---

## Stop here

Do not start P1-S5 (login page), P1-S6 (sidebar), P1-S7 (field nav),
or P1-S8 (CI/CD). Those are separate sessions.

---

## Files created in this session

```
src/middleware.ts
src/app/(app)/layout.tsx
src/app/(app)/page.tsx
src/app/(field)/layout.tsx
src/app/(field)/page.tsx
src/app/(portal)/layout.tsx
src/app/(portal)/page.tsx
src/app/(chat)/layout.tsx
src/app/(chat)/page.tsx
src/app/(auth)/login/page.tsx
src/lib/supabase/client.ts
src/lib/supabase/server.ts
agent/system_prompt.md
agent/tools/.gitkeep
docs/.gitkeep
engines/refill/.gitkeep
engines/sales/.gitkeep
engines/procurement/.gitkeep
engines/finance/.gitkeep
n8n/flows/.gitkeep
supabase/migrations/.gitkeep
```

Not touched:
```
.env   ← pre-existing, read-only
```
