# PRD-140: Access control, one source of truth + Settings > Users

You are working in the boonz-erp repo (Next.js app router, Supabase project `eizcexopcuoycuosittm`). Today (06 Oct 2026) three things broke access: PRD-139b item 3 added a middleware route table that disagreed with page-level role lists (warehouse bounced off /field/config/sims, fixed in 96756a4); PRD-139c's watchdog revoked PUBLIC execute on definer functions and `authenticated` lost 14 of them; and the new Sign out controls were <Link>s that Next prefetched, signing every user out within 30 seconds of login (fixed in ccad97f, /logout now ignores prefetch). Root problem: access is defined in four places that must agree by hand: 28 frontend files with role arrays (10 distinct), the sidebar `hiddenByRole` map, the middleware `FIELD_ROUTE_RULES`, and 78 RLS policies plus 271 functions reading `user_profiles.role`. There is no Users page; CS creates users in the Supabase dashboard.

Goal: define access once (database), have every layer read it, give CS Settings > Users. `role` stays the coarse tier the database trusts; RLS is untouched in this PRD.

### Step 0. Lock, baseline, hotfix check (15 min)

- `git pull origin main`. If `docs/prds/PRD-140.lock` exists on main and is less than 8 hours old, STOP: print "another PRD-140 loop holds the lock" and end. Otherwise write the lock (ISO timestamp, hostname, pid), commit "PRD-140: take lock", push. If the push is rejected because someone pushed the lock first, STOP.
- Confirm on main: `src/app/logout/route.ts` returns 204 on `next-router-prefetch`, `purpose: prefetch`, `sec-purpose`, `x-middleware-prefetch` and `rsc` headers; the three Sign out controls (two Profile cards in `src/app/(field)/field/page.tsx`, one in `src/app/(app)/sidebar-nav.tsx`) are `<a>` not `<Link>`; middleware has `/field/config/product-naming` as the only admins-only config prefix. If any is missing, fix it first (it is a 5 minute item) and log ALREADY DONE or DONE.
- Record the prod baseline in `docs/prds/PRD-140-log.md`:
  - per-role resolved access today, derived by reading `hiddenByRole`, `FIELD_ROUTE_RULES` and every `*_ROLES` array (`grep -rn "_ROLES = \[" src`). Write it as a table: role x area key (use the key list in item 1). This table is the Phase 1 acceptance target: after item 1 the resolver must return exactly this.
  - `select role, count(*) from user_profiles group by 1;` (expected operator_admin 2, field_staff 3, warehouse 3).
  - definer functions in public with no `authenticated` execute: expected 14 (`_mirror_po_addition_line_v1, _resolve_open_walkin_po_v3, audit_log_write, close_anon_definer_functions, procurement_price_sync_and_flag, refresh_fleet_data, run_delivery_verification_alerts, run_machine_health_integrity_check, run_weekly_miners_v3, tg_mark_internal_move_pair, trigger_lifecycle_eval` plus invoker functions `auto_generate_refill_plan, prd114_golden_gate_tick, rename_machine_in_place_legacy`). None are called from src. Log the list.
  - `select version, name from supabase_migrations.schema_migrations order by version desc limit 5;`
- `git log --since="6 hours ago" --oneline origin/main`: if PRD-139c is still pushing commits, note it and re-pull before each item.

### Order and time boxes

1 (60 min), 2 (60), 3 (75), 4 (35), 5 (50), 6 (40), 7 (35), 8 (30), gates (40).

### Item 1. Access catalog + resolver (Phase 1, no behaviour change)

Migration `prd140_1_access_catalog`:

- Tables:
  - `access_areas(key text pk, surface text not null check (surface in ('app','field')), label text not null, route_prefix text, sidebar_label text, sort int not null default 0)`.
  - `role_area_defaults(role text, area_key text references access_areas(key) on delete cascade, primary key (role, area_key))`.
  - `user_area_overrides(user_id uuid references auth.users(id) on delete cascade, area_key text references access_areas(key) on delete cascade, effect text check (effect in ('allow','deny')), granted_by uuid, granted_at timestamptz default now(), note text, primary key (user_id, area_key))`.
  - `access_audit_log(id bigserial pk, at timestamptz default now(), actor_id uuid, target_user_id uuid, action text, before jsonb, after jsonb)`.
  - `access_internal_functions(proname text pk, note text)` seeded with the 14 names from Step 0.
  - RLS on all five: SELECT for authenticated on `access_areas` and `role_area_defaults`; `user_area_overrides` SELECT own rows or holders of `app.settings.users`; writes only via the functions below; `access_audit_log` SELECT for `app.settings.users` holders.
- Seed `access_areas` with exactly these keys (surface, label, route_prefix, sidebar_label where the label must match the NavItem label in sidebar-nav.tsx byte for byte):
  app: app.dashboard (/app, "Dashboard"), app.refill (/refill, "Refill & Dispatch"), app.driver_requests (/admin/driver-requests, "Driver Requests"), app.pods (/app/pods, "Pods"), app.inventory (/app/inventory, "Inventory"), app.products (/app/products, "Products"), app.suppliers (/app/suppliers, "Suppliers"), app.procurement (/app/procurement, "Procurement"), app.price_review (/app/procurement/price-review, "Price Review"), app.lifecycle (/app/lifecycle, "Lifecycle"), app.performance (/app/performance, "Performance"), app.financials (/app/financials, "Financials"), app.consumers (/refill/consumers, "Consumers"), app.sales_pipeline (/app/sales-pipeline, "Sales Pipeline"), app.sims (/app/sims, "SIM Cards"), app.inventory_sessions (/admin/inventory-sessions, "Inventory Sessions"), app.wh_quarantine (/admin/wh-quarantine, "WH Quarantine"), app.expiry_waste (/admin/expiry-waste, "Expiry & Waste"), app.drift (/refill/drift, "Drift Monitor"), app.tracker (/app/tracker, "Tracker"), app.settings (/app/settings, "Settings"), app.settings.users (/app/settings/users, null).
  field: field.home (/field), field.profile, field.tasks, field.pod_inventory, field.pickup, field.dispatching, field.dispatching.pick (/field/dispatching/pick), field.trips, field.packing, field.shelf_view, field.not_filled, field.capture, field.orders, field.receiving, field.inventory, field.expiry, field.config (/field/config), field.config.sims, field.config.suppliers, field.config.product_naming, field.config.machines, field.config.boonz_products, field.config.pod_products, field.config.product_mapping. route_prefix is the obvious /field/... path; sidebar_label null.
  Check the sidebar for any NavItem not covered and add it; log additions.
- Seed `role_area_defaults` so the resolver reproduces the Step 0 table exactly for superadmin, operator_admin, manager, warehouse, field_staff, finance. app.tracker is NOT a default for anyone; the existing `tracker_boonz_access` flag and OWNER_EMAIL logic stay as they are (add them as an allow override at resolve time, see below). app.settings.users default: superadmin, operator_admin.
- Functions (all SECURITY DEFINER, search_path = public, explicit grants):
  - `resolve_user_access(p_user_id uuid) returns table(area_key text, surface text, route_prefix text, sidebar_label text)`: role defaults UNION allow overrides MINUS deny overrides; plus app.tracker when `user_profiles.tracker_boonz_access` or the email equals the owner email constant in `src/lib/auth/owner.ts` (copy the value, log it). A caller may resolve only their own id unless they hold app.settings.users; otherwise raise.
  - `has_area(p_user_id uuid, p_key text) returns boolean`.
  - View `v_my_access` as `select * from resolve_user_access(auth.uid())`.
  - `set_user_area_override(p_user_id uuid, p_key text, p_effect text)` and `clear_user_area_override(p_user_id uuid, p_key text)`: caller must hold app.settings.users; write audit row.
- Verification in the migration comments and in the log: for each role, `select array_agg(area_key order by area_key) from resolve_user_access(<a user of that role>)` equals the Step 0 table. For roles with no user (manager, superadmin, finance) create nothing; verify by reading role_area_defaults directly.
- Rollback file `supabase/rollbacks/prd140_1_rollback.sql` (drop the five tables, three functions, view).
  Accept: resolver output per role equals the Step 0 table; no page behaviour changed.

### Item 2. Edge function admin-users

`supabase/functions/admin-users/index.ts`, one function, `action` in the body: `list`, `create`, `set_role`, `set_name`, `set_password`, `send_reset`, `ban`, `unban`, `revoke_sessions`, `set_override`, `clear_override`.

- Verify the caller's JWT with the anon client, then check `has_area(caller, 'app.settings.users')` with the service client; 403 otherwise.
- `list`: auth.users joined to user_profiles: id, email, full_name, role, last_sign_in_at, banned_until, created_at, open sessions count (`auth.sessions`), surfaces from `resolve_user_access`.
- `create`: `auth.admin.createUser({ email, password, email_confirm: true })`, then insert user_profiles (id, full_name, role, onboarding_complete false). If the profile insert fails, delete the just-created auth user and return the error (this is the ONLY permitted auth user deletion, within the same request, for a user that never existed before it).
- `set_role`: update user_profiles.role. Guard rails: cannot change your own role; cannot set or unset superadmin unless caller is superadmin; role must be one of superadmin, operator_admin, manager, warehouse, field_staff, finance.
- `set_password`: `auth.admin.updateUserById(id, { password })`. `send_reset`: `auth.admin.generateLink({ type: 'recovery' })` then send via the project's existing email path (if none is configured, return the link to the caller and log that CS must send it; do not block the item).
- `ban` / `unban`: `auth.admin.updateUserById(id, { ban_duration: '876000h' | 'none' })`. Cannot ban yourself or a superadmin unless caller is superadmin.
- `revoke_sessions`: `auth.admin.signOut(id, 'global')`.
- `set_override` / `clear_override`: call the SQL functions from item 1.
- Every action writes `access_audit_log`. Deploy with `supabase functions deploy admin-users`. Log the deployed version.
  Accept: curl as CS's session creates a throwaway user `prd140-test@boonz.test` (field_staff), lists it, bans it, unbans it, revokes sessions; a field_staff session gets 403 on `list`. Leave the test user banned (do not delete).

### Item 3. Settings > Users page

- `src/app/(app)/app/settings/users/page.tsx` (client component, uses the edge function through a small `src/lib/admin-users.ts` client with the user's access token).
- List: name, email, role, surfaces chips (App / Field / Tracker), last sign-in (Dubai time, relative), status (Active / Disabled / Never logged in), open sessions. Search box. Sort by name.
- Create dialog: full name, email, role select, temporary password (generate 12 chars, show once with copy, allow override), auto-confirm always on. On success the new user appears in the list.
- Edit drawer: name, role select, actions (Send password reset, Set temporary password, Sign out everywhere, Disable / Enable), and the Area matrix: every `access_areas` row grouped by surface, three-state per row (Default / Allow / Deny) with the effective result shown live (Default resolves to the role default, grey when excluded, green when included). Saving writes overrides one by one and refreshes.
- Audit tab: last 200 `access_audit_log` rows.
- Guard rails mirrored in the UI (disabled controls with a tooltip): self, superadmin targets.
- `src/app/(app)/app/settings/page.tsx`: replace the placeholder with a Settings hub listing "Users" (and nothing else for now).
- Sidebar: "Settings" already exists; add no new item. The Users page is gated by the item 4 hook (`app.settings.users`); until item 4 lands, gate it with a direct `v_my_access` read in the page.
  Accept: CS opens /app/settings/users, sees 8 users (2 admins, 3 warehouse, 3 field_staff), creates nothing new, bans nothing. Warehouse session opening the URL is redirected.

### Item 4. Access provider + hook

- `src/lib/auth/access.ts`: `getUserAccess(supabaseServerClient, userId)` (server) and `AccessProvider` + `useAccess()` + `useRequireArea(key, redirectTo?)` (client). The provider fetches `v_my_access` once on mount, caches in context, exposes `has(key)`, `areas`, `loading`. `useRequireArea` redirects to the surface root (`/app` or `/field`) when loaded and missing; renders nothing meanwhile.
- Mount `AccessProvider` in `src/app/(app)/layout.tsx` and `src/app/(field)/layout.tsx`. Do not change any page yet.
  Accept: typecheck and lint clean; no behaviour change.

### Item 5. Middleware reads the resolver (Phase 2, smoke test immediately)

- Cookie `boonz_access` = `<user_id>.<role>.<comma separated area keys>`, 15 min, signed with the existing helper in `src/lib/auth/role-cookie.ts` (add a second cookie name constant; keep `ROLE_COOKIE_NAME` exported). On miss: one RPC `resolve_user_access` with the PROFILE_TIMEOUT_MS bound, rewrite the cookie. Keep the `role` in the cookie so the existing role branches can be deleted safely.
- Route check replaces `FIELD_ROUTE_RULES` and the role branches for /app, /field, /admin, /refill: longest `route_prefix` match among the user's areas wins. If the path is under a surface root and the user has no area on that surface, redirect to the other surface root they do have (or /login). Unmatched path under a surface where the user has at least one area: for /field deny and redirect to /field; for /app, /admin, /refill allow if the user has `app.dashboard` (today's /app pages are not all in the catalog; log which ones you saw and add them to the catalog if clearly a page). Keep `vox_admin` and `tracker_boonz` branches byte for byte.
- `/logout` clears `boonz_role` and `boonz_access`.
- Rollback: `git revert` of this commit is the rollback; keep the old code path in the same file behind a `const USE_RESOLVER = true` flag for this loop only, so a rollback is a one-line flip. Item 7 removes the flag.
- Smoke test now, as operator_admin, warehouse and field_staff: login lands on the right surface; Home loads; warehouse opens /field/packing, /field/config/sims, /field/config/suppliers and is bounced from /field/config/product-naming and /app/financials; field_staff opens /field/pickup and is bounced from /field/packing; operator_admin opens /app/settings/users and /field/config/product-naming.
  Accept: the smoke test passes; the edge logs show zero 401s on /rest/v1 for logged-in users during the test window.

### Item 6. Sidebar, field homes, login redirect

- `sidebar-nav.tsx`: render an item iff its `label` is in the resolved `sidebar_label` set. Delete `hiddenByRole`. The Tracker ownerOnly logic is replaced by `app.tracker` in the resolved set (the resolver adds it per item 1).
- Field homes: WarehouseHome, OperatorAdminHome, DriverHome keep their layout; each card that links to a `/field/...` page is rendered iff the matching `field.*` key is in the resolved set. Keep the component choice by role.
- Login form: after sign-in, read `v_my_access` once; redirect to `/app` if any app.* area, else `/field` if any field.* area, else `/tracker` if tracker_boonz, else `/login?error=no_access`. Keep vox_admin first.
- Smoke test as in item 5 plus: warehouse sidebar hides Financials, Settings, SIM Cards; manager (no live user: verify via role_area_defaults) would hide Settings and Lifecycle.
  Accept: smoke test passes; no card links a role to a page it cannot open.

### Item 7. Delete the hard-coded arrays

- Replace every `*_ROLES` page guard under `src/app/(field)/field/**` and any under `src/app/(app)/**` with `useRequireArea('<key>')`; delete the arrays and the `profile.role` reads they used (keep reads that drive UI text).
- Remove the `USE_RESOLVER` flag and the old middleware path.
- `scripts/check-no-role-arrays.sh`: greps `src/` for `\["(operator_admin|superadmin|manager|warehouse|field_staff|finance)"` style arrays outside `src/lib/auth/` and `src/middleware.ts`; exits 1 on a hit. Wire it into the `lint` npm script.
  Accept: the script passes; `grep -rn "_ROLES = \[" src` returns only `src/lib/auth/` (if anything); smoke test from item 5 passes again.

### Item 8. Function privilege drift + watchdog fix

- `check_function_privileges()` returns rows for: (a) definer functions in public executable by anon; (b) functions referenced by any `.rpc("name"` in src that lack an `authenticated` execute grant. Wire (b) by generating `scripts/rpc-names.txt` from grep at drift time and passing it in.
- Change `close_anon_definer_functions()`: after revoking from PUBLIC and anon, `GRANT EXECUTE ... TO authenticated` unless the name is in `access_internal_functions`. Re-run it once; confirm the 14 are unchanged and nothing else lost authenticated.
- Add the check to the existing drift script and to `docs/drift` output.
  Accept: check returns 0 rows for (a) and (b).

### Phase 9. Gates (run before you stop, even if items are BLOCKED)

1. Per-role resolved sets after item 7 equal the Step 0 table except for the documented additions (app.settings.users for admins; app.tracker via flag).
2. Parity: repo migrations match prod `schema_migrations` both directions.
3. Function check: 0 definer functions executable by anon; every `.rpc(` name in src has an authenticated grant.
4. Edge logs for the last hour of the loop: zero `/rest/v1` or `/auth/v1` 401s from authenticated-user agents on boonz-erp.vercel.app, zero GET /logout from prefetch headers that returned anything but 204.
5. App smoke test as operator_admin, warehouse, field_staff (nothing written to live stock): login, Home, Packing list, Pickup, Dispatching, Orders, Receiving, Inventory, Config hub, SIM Cards (warehouse yes, product naming no), /app sidebar, Settings > Users (admins only).
6. Overload check: no public function has two signatures that make a named-arg call ambiguous.
7. Final section of the report, for CS, plain English, no em dashes: table of items with status, migrations, commits; what changed on screen for each role (should be nothing except Settings > Users); how to create a user, change a role, grant Jojo packing as an override, disable Test Driver and Test Warehouse (do NOT do that in this loop; CS does it after the team confirms everyone is on personal logins); what is left for a PRD-141 (RLS migration to has_area).
8. Delete `docs/prds/PRD-140.lock`, commit "PRD-140: release lock", push. Last line of the report: "## PRD-140 DONE".
