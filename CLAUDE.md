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

## Migration filename format — must match existing pattern

Every migration file in `supabase/migrations/` MUST use the timestamp prefix format `YYYYMMDDHHMMSS_snake_case_name.sql`. Other formats (six-digit integers, semantic versioning, anything else) will be silently ignored by `supabase db push` and the migration will not be applied.

To check the current convention before adding new migrations:
```bash
ls supabase/migrations/ | tail -5
```

Always pattern-match the most recent existing files. Round 2.5 hit this exact bug: filenames like `20260409107500_*.sql` used an invalid time component (minute 75 doesn't exist), so migrations were committed but not applied by the runner. They had to be re-applied directly via the Supabase MCP and the files renamed retroactively.

## Function naming gotcha — repurpose_machine vs rename_machine_in_place_legacy

There are two functions for changing a machine's identity:

- **`repurpose_machine(p_old_machine_id, ...)`** — CANONICAL. Atomic split: archives the old row (sets repurposed_at), creates a fresh machine_id with the new identity, archives slot_lifecycle. Use this for any new identity transition.
- **`rename_machine_in_place_legacy(p_machine_id, ...)`** — DEPRECATED. Older rename-in-place pattern: updates the existing row, preserves the same machine_id, creates an alias in machine_name_aliases. Used by older field PWA flows. Do NOT call this from new code.

Do not create another function named `repurpose_machine` with a different signature — PostgreSQL will allow the overload but it creates a serious foot-gun. Always check `pg_proc` before adding any function:

```sql
SELECT proname, pg_get_function_identity_arguments(oid) FROM pg_proc WHERE proname = '<name>';
```

## On /compact

Preserve: modified files list, test status, pending tasks, any SQL migrations written.
