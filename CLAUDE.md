# Boonz Smart Vending ERP

Next.js 15.x App Router / Vercel / Supabase (eizcexopcuoycuosittm, ap-south-1)
Live: boonz-erp.vercel.app

## Verify

npm run build # production build
npx tsc --noEmit # typecheck — run after EVERY change
npm run lint # lint check

## Rules — MUST FOLLOW

- .limit(10000) on ANY Supabase query returning >100 rows
- RLS: always (SELECT auth.uid()), never bare auth.uid()
- NEVER put RLS policies on user_profiles that query other tables
- user_profiles RLS: only own_profile_select and own_profile_update, both id = (SELECT auth.uid())
- createClient() inside useEffect only
- FIFO: expiration_date ASC NULLS LAST, walk all batches
- Direct Supabase client inserts over Edge Functions for simple writes
- Ignore middleware.ts deprecation warning

## MUST NOT

- Refactor beyond the scope of the current task
- Touch user_profiles RLS unless explicitly asked
- Remove .limit() from any existing query
- Modify auth/redirect flow without approval
- Create Edge Functions for simple DB writes
- Add packages without asking first

## Test Users

operator_admin: cyrilsem@gmail.com
field_staff: driver@boonz.test / Test1234!
warehouse: warehouse@boonz.test / Test1234!

## Commits

Conventional: feat: / fix: / chore:
One logical change per commit.
never commit .env in github

## On /compact

Preserve: modified files list, test status, pending tasks, any SQL migrations written.
