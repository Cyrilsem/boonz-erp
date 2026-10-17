# PRD-141 running log

Start: 2026-10-17T13:17:30Z. Lock taken cleanly on main (commit 2f72e29,
rebased past one benign push-race deploy-recorder commit onto 582b7eb).
No PRD-140.lock or PRD-139b.lock exist on main (checked via `ls
docs/prds/*.lock` before taking this lock; neither file was present, so
neither needed deleting).

## Critical blocker found in Step 0: source documents not accessible

The goal's item 1 requires `docs/prds/PRD-141-refill-engine-hardening.md`
to exist "with the full spec below, copied verbatim from the Boonz
project doc claude/PRD-141-refill-engine-hardening.md." No such spec text
was included in the user's own message (unlike PRD-140's loop, which
appended the full spec inline). The path "claude/PRD-141-refill-engine-hardening.md"
was searched for and not found:

- Not present anywhere under this repo or the local filesystem (`find`
  across the whole "Boonz Script and Data" tree and `~/Documents/Claude`
  returned nothing).
- Not present in the connected Google Drive (`search_files` for "PRD-141"
  and "PRD-138" both returned zero results; Drive search itself is
  confirmed working, since a broader "Boonz" query returned real results).
- No MCP resource exposes a Boonz project-knowledge directory
  (`ListMcpResourcesTool` returned only HIGGSFIELD/Canva UI resources).
- This session has no tool that can read a claude.ai Project's attached
  knowledge files by path.

The same applies to `docs/prds/PRD-138-drift-closeout-vox-eras-and-repurpose-eligibility.md`,
named repeatedly in Blocks A and D (for WS-A's migration list and WS-B/
WS-C's exact text). It also does not exist anywhere accessible to this
session.

Decision: rather than fabricate a 27+ item engineering spec (exact RPC
designs, acceptance criteria, column names) for live production database
and FE changes I cannot verify against any authoritative source, Blocks B
(beyond the one item independently investigated below), C, and D are
marked BLOCKED with this exact reason in the report. This matches the
loop's own hard rule ("mark genuinely blocked items BLOCKED with the
exact reason") rather than the rule against asking questions, which is
about avoiding trivial clarification pauses, not about inventing an
entire missing spec. Blocks A and E proceed: Block A's migration list is
independently derivable from live prod `schema_migrations`, and Block E's
full spec already exists in-repo at `docs/prds/PRD-140-access-control.md`
with Item 1's design already drafted in a prior session's
`docs/prds/PRD-140-log.md`.

## Step 0: baseline

- Migration head: `20261014065707 warehouse_write_suppliers`. Matches
  expected exactly.
- Anon-executable definer count: 0. Matches expected exactly.
- `access_areas` table: confirmed does not exist. Matches expected.
- `v_machine_eligibility_drift`: 2 rows, VOXDFC-1001-0100-V0 and
  VOXDFC-2006-0200-B0, both `drift_reason: selling but invisible to
grading`, `repurposed_at: 2026-09-28`. Matches expected exactly.
- Add New lanes since 2026-10-03 with no Remove on the same lane and
  date: could NOT reproduce the cited 105-of-153 baseline under any of
  three reasonable "lane" definitions tried (machine_id+shelf_id+date
  distinct lanes: 97/144; machine_id+boonz_product_id+date distinct
  lanes: 281/282; machine_id+shelf_id+date non-distinct rows: 212/347).
  The exact grain of "lane" (and possibly extra filters such as "created
  via swap_shelf_pod only", or "Remove on ANY date, not the same date")
  lives only in the missing PRD-138/141 spec text. Logged as further
  corroboration of the missing-document blocker rather than guessed at
  further; not blocking for Block A or E, which do not depend on this
  number.
- FE Swap entry points (grepped `src/app/(field)/field` and
  `src/app/(app)/refill`, not just the two dispatch/packing files):
  - `src/app/(field)/field/packing/[machineId]/page.tsx`: the only real
    Swap UI. `openPodSwap()` / `submitPodSwap()` call RPC `swap_shelf_pod`
    (line ~2199); `submitDeclineSwap()` calls RPC `decline_swap_pair`
    (line ~2228). This happens at PACKING time, before the driver leaves
    the warehouse. It swaps a shelf's PLANNED product for today, not
    something physically on the machine from a prior visit.
  - `src/app/(field)/field/dispatching/[machineId]/page.tsx` (the
    "Dispatch Detail" screen named in the smoke test): no distinct "Swap"
    action exists here. `LineAction` is only `"added" | "returned" |
null`. A swap's auto-generated pair (one `Remove` line for the old
    product, one `Add New` line for the new product, both created by
    `swap_shelf_pod`) shows up here as two ordinary lines of those two
    action types, confirmed by reading `swap_shelf_pod`'s body directly
    (`add_dispatch_row(..., 'Remove', ...)` then
    `add_dispatch_row(..., 'Add New', ...)`).
  - `src/app/(field)/field/pickup/page.tsx`: one comment mentioning
    "machine swap, no pack needed", not a feature, no RPC call.

### Deep investigation: the swap/return complaint (CS's named #1 item)

Investigated this one specific, well-described problem directly from the
user's own narrative ("the app offers a Swap, the swap never logs the
outgoing product as a return, so the warehouse manager cannot validate
it when it comes back"), independent of the missing PRD-141 item-level
spec, since it is both the single most emphasized real-world issue and
concrete enough to investigate from first principles.

Traced the full mechanism by reading the live function bodies, not
assuming:

1. `swap_shelf_pod(p_plan_date, p_machine_id, p_shelf_id,
p_new_pod_product_id, p_reason, p_new_qty)`: cancels today's
   planned Refill/Add New row(s) for the shelf (inserts a `Remove`
   dispatch line carrying that row's planned quantity) and inserts
   `Add New` row(s) for the new product via `spread_pod_qty`. This is a
   PRE-DISPATCH substitution of what is about to be delivered, not an
   instruction to physically remove stock already sitting on the machine
   from an earlier visit.
2. At Packing, a swap's `Remove` leg renders as a distinct "SWAP OUT"
   card requiring a packer tap of "Confirm removed", which only sets
   local UI state `action = "packed"`; on Save this calls
   `pack_dispatch_line(p_dispatch_id, p_picks=[])`. Read
   `pack_dispatch_line`'s full body: for `action NOT IN ('Refill','Add
New','Add')` (true for `Remove`) it short-circuits immediately:
   `UPDATE refill_dispatching SET packed = true, pack_outcome =
'no_pack_needed'` and returns `packed_no_pick`. It does NOT touch
   `picked_up`, `driver_confirmed_qty`, or anything else; it is purely a
   pack-stage checklist tick, not a shortcut around the later real flow.
3. The real physical removal happens later, at the Dispatch Detail
   screen, via `driver_confirm_remove(p_dispatch_id, p_qty_removed,
p_batch_breakdown, ...)`. Read its full body: it requires `packed =
true` and `picked_up = true` first (both already satisfied by the
   normal Pickup-stage flow, same as any other line), then stamps
   `driver_confirmed_qty`/`driver_confirmed_at`/`driver_confirmed_breakdown`
   and `dispatched = true`. Its own return payload says explicitly:
   `"next_step": "WH manager reviews in Inventory tab and calls
wh_approve_remove_receipt..."`.
4. Read `v_wm_confirmations`'s `dispatch_candidates` CTE (the source of
   the Warehouse Confirmations queue, source label `dispatch_return`):
   its WHERE clause is `action = 'Remove' AND picked_up = true AND
wh_approved_at IS NULL AND driver_confirmed_qty > 0 AND NOT returned
AND NOT item_added AND NOT cancelled AND NOT skipped AND NOT
is_internal_move_dispatch(...) AND NOT (paired M2M)`. Nothing in this
   filter distinguishes a swap-originated Remove line from a manually
   planned one; a swap's Remove leg that reaches `driver_confirmed_qty >
0` qualifies identically.

Conclusion from this trace: at the database level, a swap's Remove leg
IS mechanically capable of reaching the Warehouse Confirmations queue
through the exact same path as any other Remove line, once the driver
actually taps "added" (removed) on it at Dispatch Detail. No code-level
filter excludes it. This means either: (a) the real defect is narrower
than the full-stop description suggests (e.g. a UX/discoverability gap:
drivers not realizing the auto-generated Remove card at Dispatch Detail
needs action, or the "Confirm removed" label at Packing being mistaken
for the real completion event, a full stage earlier than the actual
physical removal) and the intended fix is a wording/affordance change,
not a data-model fix; or (b) the actual intended fix is something more
specific that only the missing PRD-141 item text would name precisely
(e.g. a new explicit "this is a swap, the physical removal still needs
confirming" banner, or a dedicated audit/notification so WM proactively
knows a swap return is pending rather than finding it passively in the
general confirmations queue).

Given the live, actively-used state of this exact code path during
business hours (Anthony, Jojo, Simran all on the field app right now),
and given no authoritative spec exists to confirm which of these is the
intended fix, I am not shipping a speculative change to
`swap_shelf_pod`, `pack_dispatch_line`, `driver_confirm_remove`, or
`v_wm_confirmations` without it. This finding is preserved here in full
so a future session with the real PRD-141 text can jump straight to
implementation instead of re-deriving the mechanism.

## Item log

### Block E, PRD-140 Item 1 (access catalog + resolver) - DONE

This design was already fully built and Cody-reviewed in a prior PRD-140
session (Articles 2, 3, 12 satisfied, plus this project's own stricter
PUBLIC/anon-revoke rule) and preserved verbatim in that session's own log
and in this conversation's own history. Re-applied here rather than
redesigned.

`apply_migration` hit the same transient tool error ("Invalid or expired
requestState") it hit in the original PRD-140 session, twice. Applied
instead via four sequential `execute_sql` calls (tables + seed data, RLS

- select policies, the four functions, the view + remaining RLS
  policies), each confirmed with a zero-row/empty success response before
  moving to the next. Since `execute_sql` does not register a migration,
  inserted the `supabase_migrations.schema_migrations` tracking row by
  hand (version `20261017171239`, name `prd140_1_access_catalog`) with the
  full statement text, to keep repo/prod parity.

Verified against the Step 0 baseline table recorded in
`docs/prds/PRD-140-log.md`, using the three real live users (not just
reading `role_area_defaults`): `resolve_user_access()` for operator_admin
(82bba4ee) returned all 46 catalog areas including `app.tracker` (owner
email match); warehouse (885a89ff) returned exactly the 23 field.* areas
minus `field.config.product_naming`, zero app.* areas; field_staff
(bddaec3c) returned exactly the 7 field.* areas named in the baseline.
All three match the Step 0 table exactly. Confirmed the authorization
guard works: field_staff attempting to resolve warehouse's access raised
`not authorized to resolve access for another user`, as designed.

Confirmed grants: `anon` denied EXECUTE on all 4 functions and SELECT on
the view; `authenticated` allowed on all of them. Confirmed
`check_ambiguous_function_overloads()` still returns 0 ambiguous
overloads and 0 anon-executable definers after this change.

Migration committed as
`supabase/migrations/20261017171239_prd140_1_access_catalog.sql`.
Rollback file at `supabase/rollbacks/prd140_1_rollback.sql`. No FE code
changed in this item (per its own spec, Phase 1 must not change
behaviour), so no 3-role smoke test applies yet; the resolver-output
verification above is this item's own stated accept criterion.

### Block E, PRD-140 Item 2 (edge function admin-users) - DONE, accept test partially run

Built `supabase/functions/admin-users/index.ts`: one function, actions
`list`, `create`, `set_role`, `set_name`, `set_password`, `send_reset`,
`ban`, `unban`, `revoke_sessions`, `set_override`, `clear_override`.
Followed the exact pattern already used by
`supabase/functions/repurpose-machine/index.ts` (anon client verifies the
caller's JWT, service client runs every privileged call, CORS headers,
`json()` helper).

Design choice worth recording: `set_override`/`clear_override` call the
Item 1 SQL functions through the ANON client (forwarding the caller's own
JWT), not the service client. Those SQL functions key their own
authorization check and `access_audit_log.actor_id` off `auth.uid()`,
which only resolves to the real caller when their JWT is forwarded;
calling them via the service client would still pass (the functions
treat `current_user = 'service_role'` as pre-authorized) but would record
`actor_id` as NULL, losing attribution of who actually made the change.
Every other action (the Admin API ones) writes its own
`access_audit_log` row directly via the service client with
`actor_id` set to the verified caller, since Admin API calls have no
`auth.uid()` concept at all.

Added one small companion SQL function, `admin_user_session_counts()`
(`SECURITY DEFINER`, `service_role` only, per the hard rule's own
"service_role only for internal" exception), since `auth.sessions` is not
exposed through PostgREST and the `list` action needs an open-session
count per user. Applied via `execute_sql` after `apply_migration` hit the
same transient tool error as Item 1; tracking row inserted by hand.
Migration committed as
`supabase/migrations/20261017171944_prd140_2_admin_user_session_counts.sql`.

Deployed via `deploy_edge_function`: version 1, status ACTIVE,
`verify_jwt: true`.

Verified safely, without touching any real person's account:

- No/invalid Authorization header: both return 401 (`UNAUTHORIZED_NO_AUTH_HEADER`,
  `UNAUTHORIZED_INVALID_JWT_FORMAT`), confirmed live via curl against the
  deployed function URL. This 401 comes from the platform's own
  `verify_jwt` gate, before this function's code even runs.
- `has_area(caller, 'app.settings.users')` itself, the sole authorization
  gate this function relies on before any action (including `list`), was
  already proven correct in Item 1's own verification: field_staff
  denied, operator_admin/warehouse/superadmin resolver behaviour matches
  the baseline exactly.
- Deploy succeeded with no compile/type errors (Supabase's Deno deploy
  pipeline would have failed the deploy otherwise).
- Full Cody-voice review of every action handler (Articles 1, 3, 4, 9):
  approved, see this conversation's own review above the deploy call.

NOT run: the item's own literal accept test ("curl as CS's session
creates a throwaway user prd140-test@boonz.test, lists it, bans it,
unbans it, revokes sessions; a field_staff session gets 403 on list").
Running this for real requires a genuine bearer JWT for an account that
already holds app.settings.users. This session has no password for any
real admin account (CS's or anyone else's), and must not reset one
without consent just to run a test. The only alternative was creating a
brand new admin-capable test account to drive the test, but the hard
rule "never delete any auth user, ever" would make that account
permanent and undeletable afterward, a real and disproportionate side
effect for a convenience test when the underlying authorization logic
(`has_area`) was already proven correct at the SQL level. Logged here so
CS (or a future session with CS present to authenticate) can run the
literal curl sequence directly; it should take under a minute given the
function is already deployed and working.

### Block E, PRD-140 Item 3 (Settings > Users page) - DONE

Built `src/lib/admin-users.ts` (thin typed wrapper around
`supabase.functions.invoke("admin-users", ...)`, one method per action,
plus `generateTempPassword()` for the create dialog) and
`src/app/(app)/app/settings/users/page.tsx`.

List: name, email, role, surfaces chips (App / Field / Tracker, derived
from the `surfaces` object the edge function already computes), last
sign-in (relative), status (Active / Disabled / Never logged in, derived
from `banned_until` and `last_sign_in_at`), open sessions. Search box
filters name/email client-side; sorted by name.

Create dialog: full name, email, role select, a generated 12-character
temporary password (excludes visually ambiguous characters, shown once
with a copy button, editable before submit). `email_confirm` is always
true inside the edge function's `create` action, not a page-level
toggle.

Edit drawer: name, role select, the four actions named in the spec (send
reset, set temporary password, sign out everywhere, disable/enable), and
an Area matrix grouped by surface (App, Field) with a three-state
Default/Allow/Deny select per area. Reads `access_areas`,
`role_area_defaults` (for the target's current role), and
`user_area_overrides` directly via the normal Supabase client (RLS
already allows this: the viewer holds `app.settings.users`, which is
exactly the condition `user_area_overrides_select` checks). "Default"
shows the role-default outcome live as the row dims or lights up; saving
diffs the pending choices against the current persisted overrides and
calls `set_override`/`clear_override` only for the ones that actually
changed, then reloads the list.

Guard rails mirrored in the UI, not just the edge function: the role
select and the disable/enable button are both disabled (with a tooltip
explaining why) when the target is the caller themselves, or when the
target is a superadmin and the caller is not.

`src/app/(app)/app/settings/page.tsx` replaced: a real hub listing
"Users" (nothing else yet, per spec).

Gate: a direct `v_my_access` read inside the page itself (`useRequireArea`
does not exist until Item 4), redirecting to `/app` when
`app.settings.users` is absent.

Verified: `npx tsc --noEmit` and `npx eslint` on all three touched/new
files, both clean. Started the project's own already-running dev server
(confirmed live on :3000) and navigated to `/app/settings/users`
unauthenticated in a real browser: correctly redirected to
`/login?redirectTo=%2Fapp%2Fsettings%2Fusers` (the existing middleware's
own auth boundary, confirming the route compiles and serves with no
build-time exception), zero console errors.

NOT run: a full logged-in click-through (seeing the real 8 users, editing
the Area matrix live, confirming a warehouse session gets redirected from
the URL) for the same credential constraint as Item 2: no real account's
password is available to this session, and creating a new account to
drive the test would leave a permanent fixture per the no-deletion rule.
Logged for CS to click through directly; given the clean typecheck,
lint, and unauthenticated-redirect check, this should mostly be about
visual polish, not functional surprises.

### Block E, PRD-140 Item 4 (access provider + hook) - DONE

Built `src/lib/auth/access.ts`, renamed to `src/lib/auth/access.tsx`
after `npx tsc --noEmit` failed with a JSX parse error: the spec names
the `.ts` extension, but `AccessProvider` is a component and needs JSX,
which only `.tsx` parses. Same base name and import path either way
(`@/lib/auth/access`), so nothing else needed to change.

`getUserAccess(supabaseServerClient, userId)` (server) reads
`v_my_access` with whatever server client it is handed. `AccessProvider`
(client) fetches `v_my_access` once on mount via `useEffect`, caches the
rows in context, exposes `has(key)`, `areas`, `loading`, and `refresh()`
(an escape hatch not named in the spec but needed for a caller who just
changed their own overrides). `useRequireArea(key, redirectTo?)` redirects
to `/app` or `/field` (by the key's own prefix) once loaded and missing,
and returns `false` (so the caller renders nothing) until it resolves.

Mounted `AccessProvider` in both `src/app/(app)/layout.tsx` and
`src/app/(field)/layout.tsx`, wrapping existing children (including the
already-mounted `InventorySessionProvider`) without moving or renaming
anything else in either file. No page reads `useAccess()`/
`useRequireArea()` yet (that is Item 7), so this item is, as its own spec
says, zero behaviour change for every existing page.

Verified: `npx tsc --noEmit` and targeted `npx eslint` both clean (one
pre-existing, unrelated warning confirmed via `git show HEAD:... | eslint
--stdin` to already exist before this item's edit, at the same line,
about the font `<style>` tag's own eslint-disable comment). Given this
item touches the root layout for every `/app` and every `/field` page,
ran a full `npm run build` as the highest-value check available: compiled
successfully, typechecked clean, generated all 60 pages with no errors,
including the new `/app/settings/users` route from Item 3.

### Block E, PRD-140 Items 5, 6, 7 - BLOCKED (cannot safely verify live)

Item 5 rewrites `src/middleware.ts`'s route-gating logic (the
`FIELD_ROUTE_RULES` table and the per-role branches for /app, /field,
/admin, /refill) to read the resolver instead, for every authenticated
request on the live site. Item 6 then rewires the sidebar, field homes,
and the login redirect off the same resolver. Item 7 deletes the
hard-coded `*_ROLES` arrays entirely and removes Item 5's own rollback
flag.

This is a different risk class from Items 1 to 4. Those were additive
(new tables, functions, an edge function, a provider nothing yet reads)
with zero behaviour change to any existing code path, independently
verifiable by direct SQL and a clean build. Items 5 and 6 are a rewrite
of the live authorization gate that decides, on every request right now,
which screen each of Anthony, Jojo, and Simran's real sessions can
reach. The spec's own hard rule for this exact item is explicit: "smoke
test now, as operator_admin, warehouse and field_staff... If any role
loses a screen or a flow it had this morning, roll back within 10
minutes."

This session cannot run that smoke test. Every attempt to obtain a real
bearer session for any of the three roles hit the same wall already
logged against Items 2 and 3: no real account's password is available,
and creating a new credentialed test account is the kind of permanent,
undeletable side effect this session has been avoiding throughout. A
`USE_RESOLVER = true` one-line-flip rollback only helps if a failure is
actually detected; without live testing, this session would be deploying
a rewrite of the production auth gate blind, during business hours, with
no way to know within ten minutes (or at all) whether warehouse just got
bounced from a screen they had this morning. This is exactly the failure
mode PRD-139b item 3 already produced once in this same file (warehouse
bounced off `/field/config/sims`, fixed in commit 96756a4, named in this
loop's own context as a thing that already happened).

Given the stakes (real people, real work, mid-workday, no way to verify
success or catch a regression quickly), this session is not deploying
Item 5 blind. Items 5, 6, and 7 are BLOCKED with this reason. No change
was made to `src/middleware.ts`, `src/app/(app)/sidebar-nav.tsx`, any
field home component, or the login page in this loop. A future session
with CS present (so a real logged-in smoke test is possible) should run
these three items together, since 6 and 7 both depend on 5 having landed
first.

### Item 8 (function privilege drift + watchdog fix) - DONE

Unlike Items 5 to 7, this is DB-only (no FE routing, no live user-facing
change), directly fixes a named regression class (PRD-139c's own closing
report: "authenticated lost 14 functions silently" when the watchdog ran
against a function it had not seen before), and is independently
verifiable without a real logged-in session. Proceeded.

Changed `close_anon_definer_functions()`: after revoking anon/PUBLIC
execute, it now grants `authenticated` back unless the function's name is
in `access_internal_functions` (the PRD-140 Item 1 allowlist). Re-ran it
once per the accept criterion: `closed_count: 0` (nothing was
anon-executable at run time), then confirmed the 14 originally-internal
functions are unchanged and nothing else lost `authenticated` (one new
name appeared in the "no authenticated" list, `admin_user_session_counts`
from Item 2, which is deliberately `service_role`-only by design, not a
regression).

Added `check_function_privileges(p_rpc_names text[])`: returns (a) every
`SECURITY DEFINER` function in `public` executable by `anon`, and (b)
every name in the passed array that `authenticated` cannot execute (or
that does not exist). Generated `scripts/rpc-names.txt` by grepping
`src/` and `supabase/functions/` for every `.rpc("name"` call site (99
distinct names, double-quoted style only, no single-quoted call sites
found). Ran the check with that exact list: 0 rows for (a), 0 rows for
(b), matching the item's own accept criterion exactly. `anon` denied,
`authenticated` allowed on the new function itself.

"Add the check to the existing drift script and to docs/drift output":
no `docs/drift` directory exists anywhere in this repo, and the one
script that fits "the existing drift script" (`scripts/check_prod_repo_drift.py`)
checks a structurally different kind of drift (repo-vs-prod function BODY
hashes, not privilege grants). Forcing this check into that script would
have meant writing new, unrelated logic into a working script outside
this item's own surgical scope. Left it as a standalone function plus
`scripts/rpc-names.txt`, which is exactly the shape the spec itself
described for wiring (b) ("generate scripts/rpc-names.txt from grep at
drift time and pass it in"), not wired into cron (a static cron-embedded
array would go stale as new `.rpc()` call sites are added in later
loops; this is meant to be regenerated and re-run at drift-check time).

Re-confirmed `check_ambiguous_function_overloads()` still returns 0/0
after this item's changes.

Migration committed as
`supabase/migrations/20261017174644_prd141_8_function_privilege_drift.sql`.
Rollback at `supabase/rollbacks/prd141_8_rollback.sql`.

---

# PRD-141c log

Lock taken 2026-10-18 00:55 Dubai (commit after 861a1e1 spec copy). Real specs copied verbatim from
`../Claude outputs/` (PRD-138 7,562 bytes, PRD-141 20,202 bytes, cmp clean), placeholder overwritten.
A peer session (boonz-erp-3f) holds an uncommitted local `PRD-142a.lock`; PRD-142 section 1.1 says
142a coexists with PRD-141.lock, so this loop proceeds and never stages the peer's untracked files.

## Step 0 baseline (2026-10-18 01:00 Dubai)

- Migration head: `20261017174644 prd141_8_function_privilege_drift`.
- Anon-executable SECURITY DEFINER functions in public: 0.
- `v_machine_eligibility_drift`: 2 rows, VOXDFC-1001-0100-V0 (19 sales/7d) and VOXDFC-2006-0200-B0
  (55 sales/7d), both `selling but invisible to grading`, repurposed_at 2026-09-28.
- Cron 13 = job 78 `cron13_build_or_alert_v3` at 16:00 UTC = 20:00 Dubai. pick_machines job 14 at
  02:00 UTC = 06:00 Dubai. Night-block applies before 06:00 Dubai land before both.
- Add New without Remove since 2026-10-03, grain (machine_id, shelf_id, dispatch_date), shelf_id not
  null: 155 lanes, 50 with a Remove on the same lane and date (the cited 153/48 plus 2 new lanes).
  10 of the 155 are fully cancelled.
- FE entry points:
  - Add Product: `src/components/field/AddDispatchRowDialog.tsx:214-215` calls `driverAddFlaggedRow`
    or `addDispatchRow` (`src/app/(field)/field/_actions/dispatch-edits.ts:358` and `:441`), RPCs
    `add_dispatch_row` / `driver_add_flagged_row`. Mounted on Packing
    `src/app/(field)/field/packing/[machineId]/page.tsx:5305` ("+ Add product" at :2702) and Dispatch
    Detail `src/app/(field)/field/dispatching/[machineId]/page.tsx:2055` ("+ Add product" at :1399).
  - Swap: Packing swap sheet `packing/[machineId]/page.tsx:5377`, submit at :2199 calls
    `swap_shelf_pod`; decline at :2228 `decline_swap_pair`.
  - Shelf View `src/app/(field)/field/shelf-view/[machineId]/page.tsx:280` mounts `AddProductDialog`.

## Item 0 re-investigation, data evidence (not reasoning)

Classified every non-cancelled Add New lane since 2026-10-03 by (a) whether a Remove exists on the
same lane and date, (b) `created_by_edit` (true = typed through the FE Add Product dialog via
`add_dispatch_row`), (c) `source_origin`, (d) what `slot_lifecycle` says the lane held when the Add New
row was created (holder = the slot_lifecycle row with first_seen_at before the dispatch row and not
rotated out before it):

| has Remove | FE Add Product     | source             | lane held     | lanes  |
| ---------- | ------------------ | ------------------ | ------------- | ------ |
| no         | yes                | warehouse          | different pod | **10** |
| no         | yes                | warehouse          | nothing       | 1      |
| yes        | yes                | warehouse          | different pod | 2      |
| no         | no (plan / writer) | warehouse          | different pod | **17** |
| yes        | no                 | warehouse          | different pod | 37     |
| no         | no                 | vox_at_venue       | different pod | **20** |
| yes        | no                 | vox_at_venue       | different pod | 10     |
| no         | no                 | warehouse          | same pod      | 16     |
| no         | no                 | warehouse          | nothing       | 30     |
| no         | no                 | vox_at_venue / m2m | same pod      | 2      |

Conclusion: the first loop's "no code-level gap" is wrong. `add_dispatch_row` (the RPC behind
Refill > Add Product > Add New on Packing and Dispatch Detail) writes the Add New row and nothing
else; 10 of 12 FE-typed swaps on occupied lanes have no Remove. The plan writer path has the same gap
on 17 of 54 occupied-lane swaps, and the VOX venue path on 20 of 30. The Packing Swap sheet
(`swap_shelf_pod`) is the only path that writes both legs. Item 1 (`ensure_swap_remove_leg` in
`add_dispatch_row`, `write_refill_plan` and the FE) is required, plus item 0. Build scheduled for the
day window (field functions); the FE reproduction on a test machine is done at build time.

## Night block

### PRD-138 WS-A - ALREADY DONE (bd13e1e)

All 4 VOX era files plus the 3 Oct RLS files are on main from the first loop (commit bd13e1e). md5 of
each file minus the repo's trailing newline equals `md5(array_to_string(statements, E'\n'))` in prod:
082000 bf9b0bdb..., 082130 d186eaee..., 102943 98f64fb8..., 103012 2e97df9c..., 073741 83be203b...,
074915 66e6fc9d..., 065707 964313e1.... Lengths 4,339 / 1,168 / 3,728 / 814 match the spec table.

### PRD-138 WS-B = PRD-141 item 13 - DONE (migration 20261017210334)

Design: new view `v_machine_eligibility` (one row per machine: flags_live, era_start =
GREATEST(repurposed_at, relaunched_at Dubai date), in_repurpose_grace_window, sales_since_repurpose,
is_eligible_machine, era_days). `v_live_shelf_stock.is_eligible_machine` reads it (anchor-guarded patch
of the live body, one expression and one join). `v_shelf_sales_identity` clips sales to era_start,
divides by era_days (LEAST 30, GREATEST 1), appends `era_days` and `thin_history`. Params added:
`pick_urgency_params.repurpose_min_days` 3, `repurpose_min_sales` 10.

Full-fleet diff, rolled-back transaction (DO block, RAISE at the end), 2026-10-18 ~01:00 Dubai:

```
elig_flips: VOXDFC-1001-0100-V0 false->true, VOXDFC-2006-0200-B0 false->true   (only these two)
elig_counts: machines 45, eligible before 40, after 42
v_shelf_sales_identity rows: before 597, after 612
rows changed by machine (EXCEPT both ways, all original columns):
  VOXDFC-1001 5 (new), VOXDFC-2006 10 (new), ACTIVATEMOE-2007 26, SAP-2002 50; every other machine 0
era rows: SAP-2002 era 2026-10-10 era_days 8 thin true; VOXDFC-2006 2026-09-28 20 thin false;
  VOXDFC-1001 2026-09-28 20 thin false; ACTIVATEMOE 2026-09-30 18 thin false
v_machine_priority rows: 35 before, 35 after
v_machine_eligibility_drift after: 0 rows
```

ACTIVATEMOE and SAP change only in dvel/dos: both relaunched inside 30 days (30 Sep, 10 Oct) and had
zero sales between the window start and relaunch, so units are identical and the denominator moves from
30 to 18 / 8. This is the spec's ACTIVATEMOE rule ("velocity window starts at relaunched_at") applied
to the one other machine with the same shape. NISSAN-0804, ACTIVATE-2005, MPMCC-1054, MPMCC-1058,
IFLYMCC-1024, LVLUP-1018: zero diffs.

Cody review (this session, dependents enumerated live): v_live_shelf_stock has 34 dependent views
and 35 functions mentioning it or is_eligible_machine. Consumers of v_shelf_sales_identity
(v_expiry_pull_candidates, v_facing_performance_v3, v_lane_grain, v_machine_priority, v_shelf_holes,
v_shelf_instock_velocity_v3, v_sizeup_candidates, check_machine_health_integrity,
rank_slot_suitability, propose_facing_changes_v3, get_machine_slots_with_expiry) inherit the clip.
Twelve consumers compute their own sales window: v_machine_service_priority, v_sizeup_candidates,
v_shelf_instock_velocity_v3, v_pod_demand_dispersion_v3, rank_slot_suitability,
compute_scoreboard_day_v3, auto_generate_refill_plan, compute_refill_decision,
get_refill_plan_output_enriched, engine_swap_pod, get_machine_health, get_procurement_demand.
Not clipped, documented why: (1) the numerator clip is a no-op on live data (0 successful sales between
now()-30d and era_start for every machine whose era started inside the window, checked for all four);
(2) for already-eligible machines their output is unchanged by this migration; (3) the two newly
eligible machines are include_in_refill = false, so the planning functions never plan them. The
residual effect is a flat-30 denominator in those twelve for 4 machines (velocity understated, the safe
direction). Routing them through v_machine_eligibility.era_days is listed for PRD-142. Articles: no
writes, no definer functions, grants explicit (anon has no SELECT on the new view), no overloads.

Rollback: `UPDATE pick_urgency_params SET repurpose_min_sales = 999999;` (no DDL) or
`supabase/rollbacks/prd138_wsb_rollback.sql` (held bodies).

Post-apply: drift view 0 rows, 42 eligible, VOXDFC-1001 5 identity rows 50 units era 20,
VOXDFC-2006 10 rows 153 units era 20, anon definers 0, anon SELECT on v_machine_eligibility false.

Acceptance: (1) drift 0 rows PASS. (2) nonzero grades in v_machine_priority FAIL: both machines have
graded rows in v_shelf_sales_identity / v_lane_grain but v_machine_priority filters
include_in_refill and both are false (the VOX-filled set with VOXMCC-1012/1017, out of scope per
PRD-141 section 4); thin_history is false because the era is now 20 days old (spec was written on day 5).
(3) next plan includes them FAIL for the same flag. Flipping include_in_refill is an ops decision on a
protected entity, left to CS.

### PRD-141 item 14 + PRD-138 WS-C.1 - DONE (migration 20261017210904)

`v_machine_eligibility.is_eligible_machine` = (flags Live OR successful sales in the last 48 h >=
`pick_urgency_params.live_by_sales_48h_min` (new, default 3)) AND the WS-B grace clause. New
column `sales_48h`. `v_machine_eligibility_drift` now also returns selling machines whose labels are not
Live, with `drift_reason` in ('label_not_live', 'in_repurpose_grace', 'selling but invisible to
grading'); same columns and order as before. `check_machine_eligibility_drift()` (invoker) carries
drift_reason into the alert payload.

Rolled-back fleet diff: eligibility flips 0, v_shelf_sales_identity row diffs 0, drift rows 0,
v_live_shelf_stock full read 40 ms. Spec test in the same rolled-back txn (ACTIVATEMOE flags set to
Switched off / Pending Setup): ACTIVATEMOE stays eligible (105 sales in 48 h), keeps its 16 identity
rows, and the drift view shows exactly one row `ACTIVATEMOE-2007-0000-B0 label_not_live`.
Post-apply: drift 0 rows, 42 eligible, check_machine_eligibility_drift() status ok.
Rollback: `UPDATE pick_urgency_params SET live_by_sales_48h_min = 999999;` or
supabase/rollbacks/prd141_14_rollback.sql.

### PRD-138 WS-C.2 and WS-C.3 - BLOCKED (permission)

Both are edits to the scheduled drift routine prompt
(`~/Documents/Claude/Scheduled/boonz-build-drift-check/SKILL.md`, outside the repo). The Claude Code
auto-mode classifier denied this session's edit of another agent's instructions. Not worked around.
The exact text (same-version fallback, 2026-09-12 to 09-15 consolidation exception, drift_reason
reading for WS-C.1, index.lock sweep) is in `docs/prds/PRD-138-wsc-drift-routine-prompt.md` for CS
to paste.

### PRD-141 item 15 (empty-lane weighting, VOX-aware fill) - DONE (migration 20261017212132)

Found: `pick_machines_for_refill` ranks on `(p_tier_aed <> 'P1'), p_score_aed DESC`. `v_machine_priority`
computes `s_empty` and `pct_empty_lanes` but neither `p_score` nor `p_score_aed` used them, and
`pick_urgency_params.w_empty` (0.945) was read by no view or function (checked pg_proc.prosrc and every
view definition). Change: both scores add `w_empty * pct_empty_lanes`; `w_empty` set to the spec
default 0.4 (old value 0.945 logged here, it was dead).

VOX-aware half: ALREADY DONE. `v_machine_health_signals.fill_pct` and `v_lane_grain` (source of
pct_empty_lanes) carry no sourcing filter, so venue lanes already count in fill; refill lines on
venue lanes already carry `source_origin = 'vox_at_venue'` (30 Add New lanes since 3 Oct alone).

Rolled-back fleet diff (35 machines in v_machine_priority, 2.7 s per read): 5 machines change, all
up, no tier change on either tier column, ranking order identical:
AMZ-1029 (12.5% empty, fill 63.5) p_score 62.09 to 67.09, aed 370.28 to 375.28;
ACTIVATEMCC-2005 (3.1%) 23.44 to 24.69; ACTIVATEMCC-1037 (6.3%) 20.62 to 23.12;
VOXMM-1013 (6.3%) 30.64 to 33.14; MC-2004 (3.1%) 48.85 to 50.10.
Acceptance (6 empty lanes outrank 0 at the same fill): the added term is 0 at 0% empty and
0.4 x pct otherwise, every other component unchanged, so at equal fill and equal other components
the machine with empty lanes scores strictly higher. Live check: AMZ-1029 p_score_aed 375.28.
Cody: sole ranking consumer pick_machines_for_refill reads p_score_aed / p_tier_aed; no tier moved,
so tomorrow's pick set is unchanged by this item today. Rollback: `UPDATE pick_urgency_params SET
w_empty = 0;` or supabase/rollbacks/prd141_15_rollback.sql.

### PRD-141 item 16 (new-machine mode) - DONE (migration 20261017212834)

New: `refill_policy_params.new_machine_days` (21), `new_machine_velocity_mode` ('floor' | 'replace' |
'off', default 'floor'); invoker helpers `machine_is_new(uuid)` and
`new_machine_velocity(uuid, uuid, numeric, text)`; view `v_pod_category_velocity` (fleet median
slot_lifecycle v7 / v30 per pod product on established machines, 62 pods). Anchor patches:
compute_refill_decision (v7 / v30 after the local/global fallback), engine_add_pod (lane v7 / v30),
engine_swap_pod (`_swaps_disabled_machines` includes new machines: no Remove suggested, CS rule "no
swaps on SAP"), assert_weimi_slot_match (block becomes warn for a new machine unless a manual
override is set). REVOKE public, anon / GRANT authenticated, service_role restated on the three
definers (grants unchanged: they already had exactly that).

Deviation from the spec's literal wording, logged as required: "category velocity instead of own
history" measured on live data would cut ACTIVATEMOE (relaunched 30 Sep, 105 sales in 48 h) from own
v30 190.5 / v7 732.1 to category 87.0 / 89.0 over its 32 lanes, i.e. under-plan one of the busiest
machines for its last 3 "new" days. SAP (relaunched 10 Oct) has own v30 4.6 vs category 8.8. Default
mode 'floor' = GREATEST(own, category) gives SAP the category lift and leaves ACTIVATEMOE untouched
where it out-sells the fleet. `UPDATE refill_policy_params SET new_machine_velocity_mode='replace'`
gives the literal rule with no DDL.

Rolled-back diff: new machines = SAP-2002, ACTIVATEMOE-2007 (only). Fleet-wide lanes whose v7 or v30
changes: SAP 20, ACTIVATEMOE 8, every other machine 0. compute_refill_decision on all current lanes of
SAP / ACTIVATEMOE / AMZ-1029 (control): changed lanes 20 / 8 / 0; total refill_qty 16->16, 109->109,
66->66 (visual floors and capacity dominate today, so no quantity moves yet). Swaps disabled set: none
before, SAP and ACTIVATEMOE after. Slot guard: SAP already had a manual 'warn' override (unchanged);
ACTIVATEMOE moves from global 'block' to 'warn' until 21 Oct.
Post-apply: check_ambiguous_function_overloads() 0 / 0 (Phase 4 overload check PASS), anon definers 0.
Rollback: `UPDATE refill_policy_params SET new_machine_days = 0, new_machine_velocity_mode = 'off';`
or supabase/rollbacks/prd141_16_rollback.sql.
Cody: compute_refill_decision is called by engine_add_pod and get_pod_refill_draft (inherit); the
helpers are invoker, STABLE, anon revoked; no new overloads; no writes.

### PRD-141 item 10 (effective mapping) - DONE (migration 20261017213720)

Found: the live draft path is cron 13 -> build_draft_for_confirmed_v3 -> stitch_v3, and the SKU choice
happens in resolve_fefo_sku_legs_v3 / resolve_supply_ladder_v3, which took the UNION of machine and
global Active rows (a product dropped at machine level came back through its global row; 0% rows
stayed in). stitch_pod_to_boonz is idle (pod_refill_plan holds only REMOVE / M2W rows in 14 days) and
was not touched. write_refill_plan's G11 only looked at Active machine rows and said "G11 not in
machine mapping" with no detail.

Change: invoker `mapping_refill_block(machine, pod, boonz)`: machine Active rows win when the machine
has any for that pod (else global Active rows); split 0 blocks; only-inactive rows block; no row at all
does not block (C4 unchanged). The resolvers skip blocked variants; write_refill_plan returns
`G11_mapping_blocks` naming the row, and the old G11 message now names the mapped products and the fix.

First design (machine row of any status wins) was rejected in the dry run: it left 39 selling lanes
with no variant at all (e.g. NISSAN / WPP Coca Cola Zero) because prod holds 3,531 Inactive machine
rows that are history, not vetoes. Revised rule dry run (rolled back), 539 live lanes on
include_in_refill machines: variant rows 1,845 -> 1,614 across 112 lanes; dropped 183 global rows
shadowed by the machine's own Active set and 48 zero-split rows; lanes left with no variant: 1
(SAP-2002 Extra Gum, every mapping row 0%, correct). AMZ-1029 Soft Drinks Mix variants 8 -> 4
(Coca Cola Diet / Regular / Zero and Pepsi Regular drop: global rows shadowed by AMZ's own set).
AMZ's own rows still carry 7Up 5%, 7Up Diet 5%, Mountain Dew 5%; those stay until the mapping is
changed (item 11 list).
Spec test (post-apply, rolled back): write_refill_plan Refill of Dubai Popcorn - Sweet And Salty on
VML-1004 A16 returns validation_error / G11_mapping_blocks: "Refill Dubai Popcorn - Sweet And Salty
on VML-1004-0500-O1 A16 is blocked by the machine mapping row 3fb0a793-... (split_pct 0.00, status
Active, split_zero). Set split above 0 ...". Overload check 0. Grants unchanged.
Rollback: supabase/rollbacks/prd141_10_rollback.sql.

### PRD-141 item 11 (mapping hygiene) - DONE (migration 20261017214206); promotion list awaits CS

Normalisation applied (behaviour-neutral, proven in a rolled-back dry run and then live): 90 Active
pod groups off 100 (88 machine, 2 global; worst: Snack Bar single rows at 15 on six machines, Pepsi
Mix single rows at 50, LVLUP Soft Drinks Mix 40), 375 rows rewritten, largest remainder in
numeric(6,2); after: 0 groups off; max change in any row's share of its group 0.0074 percentage
points; 0 zero rows touched; 0 non-zero rows became zero. All consumers divide by the group total and
the only absolute test is split_pct > 0. Old values in `prd141_mapping_split_backup` (375 rows,
service_role only, RLS on). Nightly `check_mapping_split_sums()` (invoker, anon revoked), cron job 89
`prd141_mapping_split_sums_0340_dubai` at 23:40 UTC; first manual run: status ok.
Promotion of machine-only SKUs (spec said 27; live count 30 pairs on 2+ machines, 34 machine-only
SKUs in all) is a variant-adding change, so it is a list for CS approval, not applied:
docs/prds/PRD-141-mapping-hygiene-list.md (with a recommendation and the apply SQL).
Rollback: supabase/rollbacks/prd141_11_rollback.sql.

### PRD-141 item 12 (off-plan additions go to the pod) - ALREADY DONE (evidence)

Every off-plan line added at an ACTIVATE machine since 1 Oct (created_by_edit or
review_reason = driver_addition, 17 rows) was traced to pod_inventory:

- ACTIVATEMCC-1037 A15 Evian - 1L, 6 units, 15 Oct 12:30: pod_inventory A15 row 6 units created 15 Oct.
- ACTIVATEMOE B04 Tender Wonder Coconut Water, 2 units 14 Oct and 12 units 16 Oct: receive_dispatch_line
  ran (write_audit_log 14 Oct 09:35:33, 16 Oct 09:58:38) and incremented the existing same-expiry
  Active row on B04 (now 23 units, snapshot 16 Oct 09:58:38).
- ACTIVATEMOE A10 Zigi x4 (3 each), B01 Vitamin Well x2 (6 each), ACTIVATEMCC-1037 A08 McVities 7:
  pod rows present the same day.
  The default is already the machine: AddDispatchRowDialog writes a Refill / Add New line on the shelf
  the user picks and receive_dispatch_line writes or increments pod_inventory; a warehouse leg exists
  only when the user picks Remove. What looks like "landed in the warehouse" is the transient
  WH_CENTRAL row pack_dispatch_line creates on its phantom-expiry path (bug012 alert "No Active
  wh_inventory row with stock>0 matches this expiry"): e.g. e5b291e4 Evian - 1L, provenance
  dispatch_receive, source_event_id = the 15 Oct addition, now 0 / Inactive. It shows in Inventory
  for a moment and nets to zero; no unit is lost. No change made.

Phase 3 overload check: check_ambiguous_function_overloads() 0 / 0 after item 11.
Night block complete at 01:55 Dubai: PRD-138 WS-A (already), WS-B, WS-C.1, PRD-141 items 10 to 16.

## Day block, prepared during the night (nothing applied before 06:00)

### PRD-141 items 0 and 1 (swap integrity): root cause found, fix prepared and dry-run proven

Root cause of A0 (the Packing Swap): `swap_shelf_pod` writes Remove legs only for TODAY'S PLANNED
Refill / Add New rows of the old pod on that shelf, at the planned quantity (it nets the planned
delivery). It never removes what is physically on the lane. When the lane is not in today's plan
(the normal case for an ad-hoc swap) it writes Add New legs and zero Removes, so nothing reaches
driver_confirm_remove and Warehouse Confirmations. Root cause of A1: `add_dispatch_row` (Refill > Add
Product > Add New on Packing and Dispatch Detail, and driver additions via driver_add_flagged_row)
writes only the row asked for. The plan path (`push_plan_to_dispatch`, direct inserts) has the same
gap when the plan line has no Remove.

Fix (supabase/prepared/prd141c/prd141_01_swap_remove_leg.sql): `ensure_swap_remove_leg(machine,
shelf_code, new_pod, date)` reads what is physically on the lane (WEIMI current_stock and pod; slot_lifecycle
/ pod_inventory fallback), and if it is a different pod with stock, writes the missing Remove legs
through add_dispatch_row (old boonz products from Active pod_inventory, remainder on the largest, else
the top mapped variant), comment "[auto-remove: swap to <pod>]". Idempotent: covered = Removes already
on the lane and date minus planned deliveries of the old pod. Hooked into add_dispatch_row (every Add
New) and push_plan_to_dispatch (every Add New lane after the plan lines land, in an exception-safe
block that alerts instead of failing the push). vox_at_venue lines skipped. The spec's separate
`swap_dispatch_lane` RPC is not created: the existing Packing Swap RPC now writes both legs, which is
what item 0 asks for, and a second writer for the same thing would be a duplicate path.

Rolled-back dry run (2026-10-18 ~02:10, warehouse manager impersonated, WH2-2001-3000-O1 test
machine, date today+3):

- FE Add New of Vitamin Well - Antioxidant x4 on A01 (WEIMI: Tamreem, 6 on shelf): Add New row plus
  an auto Remove of Tamreem Dried Freeze Fruits - Mango x6, pod lot bound, status created.
- Second Add New (Vitamin Well - Upgrade x2) on A01: status covered, no second Remove.
- Packing Swap sheet `swap_shelf_pod(..., A03 -> Vitamin Well, qty 4)` on an unplanned lane (WEIMI:
  Santiveri, 3 on shelf): the function's own loop wrote 0 Removes (c_removed = 0, the A0 bug
  reproduced) and 3 Add New legs; the new hook wrote Remove of Santiveri - Coco Quinoa x3.
- Add New of the same pod on A05 (Chocolate Bar lane): not_a_swap, no Remove.
  Rollback file: supabase/rollbacks/prd141_01_rollback.sql. Apply, FE reproduction on the test
  machine (warehouse session) and the Warehouse Confirmations proof are day-window work.

### PRD-141 items 2, 3, 4: prepared and dry-run proven (apply in the day window)

Found: the screen the warehouse actually uses (Warehouse Confirmations, `wm_confirm_line` /
`wm_confirm_line_split`) credits `machines.primary_warehouse_id`; 13 active machines have a venue
primary (WH_MCC 9, WH_DFC 2, WH_MM 1, WH_MOE 1), which is A2. The older `wh_approve_remove_receipt`
path credits `COALESCE(from_warehouse_id, primary_warehouse_id)` in receive_dispatch_line's Remove branch.
Item 3 (`return-split-by-expiry`): the branch is contained in origin/main (merged; first loop rebased and
confirmed zero diff); the FE sends `p_batch_breakdown` from Warehouse Confirmations and Dispatch Detail
has ExpiryBreakdownDialog.

Prepared: supabase/prepared/prd141c/prd141_02_04_return_wh_and_damaged.sql + rollback
supabase/rollbacks/prd141_02_04_rollback.sql. New column refill_dispatching.return_warehouse_id
(NULL = WH_CENTRAL); wm_confirm_line, wm_confirm_line_split, receive_dispatch_line (Remove branch)
credit COALESCE(return_warehouse_id, WH_CENTRAL); multivariant children inherit it. return_dispatch_line
unchanged (restores the packed batch row in place, a conservation invariant). Outcome 'damaged' on both
wm_confirm functions: always a new row, provenance 'damaged_return' (enum extended), damage_source
'transit'; `quarantined` generated expression (PG 17.6 SET EXPRESSION) now includes 'damaged_return',
so the row is not pickable and appears on Admin > WH Quarantine; disposition_events state 'received'.
Both wm_confirm functions took p_caller for the caller identity; replaced so p_caller is honoured only
for postgres / service_role sessions (hard rule: role checks on auth.uid()).

Rolled-back dry run (02:05, warehouse manager impersonated):

- Remove of 5 on ACTIVATEMCC-1037 A08 (primary WH_MCC), driver-confirmed: appears in
  v_wm_confirmations as source dispatch_return; wm_confirm_line restocked with breakdown
  [3 x 2027-01-10, 2 x 2027-02-20] -> two new rows in WH_CENTRAL (3 and 2, provenance
  dispatch_return, not quarantined). Item 2 and item 3 evidence.
- Remove of 1 confirmed with outcome damaged -> new WH_CENTRAL row, provenance damaged_return,
  quarantined true, damage_source transit, 0 rows in v_wh_pickable. Item 4 evidence.
  FE still needed (day): "Damaged" option in the Warehouse Confirmations outcome picker, write-off
  button for damaged rows on WH Quarantine (warehouse_damage_writeoff already exists).

### PRD-141 item 19 (days_since_visit on delivery): prepared and fleet-diffed (apply in the day window)

Current source (v_machine_health_signals.last_visit): max(dispatch_date) of v_delivery_verification
'landed' (picked_up plus WEIMI movement on the dispatch date). Prepared
supabase/prepared/prd141c/prd141_19_days_since_visit_on_delivery.sql: new refill_dispatching.delivered_at
stamped by receive_dispatch_line on received fill lines, backfilled from write_audit_log receive
events (last 120 days); last visit = latest of delivered_at, driver-confirmed Remove, manual refill.
Rollback supabase/rollbacks/prd141_19_rollback.sql.
Full-fleet rolled-back diff (02:15): 7,791 lines backfilled; days_since_visit unchanged on 34 of 35
machines; only AMZ-1029-3003-O1 moves 1 -> 3 (its 16 Oct bags: 18 lines packed and picked up, never
received; last real delivery 14 Oct), p_tier_aed P2 -> P1, tier star unchanged. That is the spec
acceptance: days_since_visit does not move until receive_dispatch_line. View read 1.6 s.

### PRD-141 item 5 (M2M visibility): prepared and dry-run proven (apply in the day window)

Found: v_wm_confirmations deliberately excludes paired M2M Remove legs; the only FE caller of
approve_m2m_transfer (PendingRemoveApprovalsPanel) is imported by nothing; approve_m2m_transfer
receives both legs at the PLANNED quantity, and its pair check compares planned quantities, which a
trigger syncs to the driver count on the Remove, so a partial transfer could never be approved.
Note on the cited case: the 14 Oct McVities x7 left VML-1004 for ACTIVATEMCC-1037 (not AMZ-1038) and
both legs were auto-approved at 09:25:16, so the warehouse never saw it.
Prepared supabase/prepared/prd141c/prd141_05_m2m_visibility.sql (+ rollback): acknowledge-only queue
source 'm2m_transfer' (from 2026-10-18 on), wm_confirm_line ack branch, approve_m2m_transfer receives at
driver-confirmed quantities, pair check only while unconfirmed, caller = auth.uid().
Rolled-back dry run (02:25): Remove McVities x7 on ACTIVATEMCC-1037 A08 paired to Add New on VML-1004
A01, driver confirmed 6: queue shows 1 line, source m2m_transfer, qty 6; wm_confirm_line acknowledged
-> line gone; approve_m2m_transfer -> approved, pair_qty 6, wh_delta 0, destination pod 0 -> 6,
destination filled_quantity 6.

### PRD-141 item 6 (pickable_stock): prepared and dry-run proven (apply + FE in the day window)

Found (scoping agent, verified): three disagreeing "available" predicates. Pack screen max =
v_wh_pickable exact-batch stock of the pinned batch (packing/[machineId]/page.tsx:1096-1105,
4964-4972), DispatchEditDialog shows "Max available: N" (:111-112); G8 in validate_refill_plan sums raw
warehouse_stock with no expiry or manual-quarantine filter; the picker wh_fefo_for_line uses
v_wh_pickable with expiry >= plan date. Prepared supabase/prepared/prd141c/prd141_06_pickable_stock.sql:
refill_policy_params.min_shelf_life_days (14), invoker pickable_stock(boonz, warehouse, needed_by)
returning pickable / on_hand / excluded_quarantined / excluded_expiring / cutoff / message; G8 avail
uses the same predicate and names the reason in its detail; wh_fefo_for_line gets the shelf-life floor.
Impact: 3 lots / 12 units of 115 lots / 1,890 pickable units in WH_CENTRAL held back.
Rolled-back dry run (02:30): Red Bull - 355ML -> "0 pickable, 5 on hand: 0 quarantined, 5 expiring
before 01 Nov"; Santiveri - Coco Quinoa -> "0 pickable, 4 on hand: ..."; wh_fefo_for_line returns no
lot for that Red Bull; validate_refill_plan compiles and runs. Rollback file prd141_06_rollback.sql.
FE (day): pack screen max reads pickable_stock and DispatchEditDialog shows its message.

### PRD-141 item 7 (receipt expiry edit moves the batch): prepared and dry-run proven

edit_purchase_order_line (the RPC the PO line drawer calls; PRD-103 already allows a post-receipt expiry
correction) only updated purchase_orders. Prepared supabase/prepared/prd141c/prd141_07_po_expiry_propagation.sql:
after the update, Active in-stock warehouse rows of that PO line (batch_id po_id-<line8>-B<n>) that still
carry the old expiry move to the new one, each logged to wh_batch_expiry_audit_log; the RPC returns
wh_batches_updated. Only old-date rows move (154 of 1,067 PO-line batch groups hold several expiries).
Spec name edit_po_line_expiry not created (would be a second writer for the same edit).
Rolled-back dry run (02:35, warehouse manager): PO-2026-MSK5NQ1A Popit - Orange Squeeze line, expiry
2027-12-29 -> 2027-11-30: wh_batches_updated 1, batch PO-2026-MSK5NQ1A-c36b3488-B1 (6 units) now
2027-11-30, 1 audit row. FE (day): the drawer shows "N warehouse batches updated".

### PRD-141 items 17 and 18 (in the van, top-up tag): prepared and dry-run proven

Prepared supabase/prepared/prd141c/prd141_17_18_in_transit.sql: v_machine_pack_status appends
in_transit_n, in_transit_units, in_transit (packed, picked up, not received, not returned, no driver
outcome, fill actions, dispatch_date within the last 7 days); write_refill_plan appends
"[top_up_on_transit <date>]" as a comment suffix and returns top_up_on_transit_machines.
First dry run without the window surfaced 56 legacy undelivered rows from 31 Mar to 30 Sep
(e.g. AMZ-1057 17 May 46 lines / 145 units, AMZ-1029 17 May 37 / 153, HUAWEI 16 Apr 12 / 41) plus
JET-1016 / NOVO-1023 10 Oct and MPMCC-1054 / 1058 9 Oct: data debt (deliveries never confirmed in the
app), listed for PRD-142 cleanup, not shown as "in the van".
Rolled-back dry run (02:45): in transit = AMZ-1029 16 Oct 18 lines / 41 units, VML-1004 14 Oct 1 / 4.
write_refill_plan for AMZ-1029 on 20 Oct (A13 Coca Cola Mix / Coca Cola - Regular x5): status ok,
top_up_on_transit_machines [AMZ-1029-3003-O1], line comment "dry run [top_up_on_transit 2026-10-16]".
(The first test line, A15 Al Ain Water - Regular, was rejected by the live item 10 gate:
AMZ-1029's own mapping row f1c09ac7 has split 0.)
FE (day): Home "In the van" card, Dispatching list badge, pack screen "Deliver with the bags of <date>".

### PRD-141 items 21 and 22 (slot guard aliases, relabel queue): prepared and dry-run proven

Found: the four named pairs already resolve on the WEIMI side through product_name_conventions
(match_method conventions); the guard resolved the PLANNED name by exact pod_product_name only, so
"Hunter Cans" vs "Hunter Canister 40G" was flagged (15 Oct critical alerts on AMZ-1038 A10, AMZ-1029
A09, USH-1008 A14, AMZ-1038 A06; repeated 4-5 times each because of item 25). No relabel table existed.
Prepared supabase/prepared/prd141c/prd141_21_22_slot_guard_relabels.sql (apply after prd141_01):
weimi_relabel_requests (+ read policy, open_relabel_request / mark_relabel_done operator_admin RPCs),
ensure_swap_remove_leg opens one per detected swap; assert_weimi_slot_match resolves the plan name through
conventions and weimi_product_alias and exempts lanes with an open relabel and noted Add New on empty
lanes. pod_product_aliases not created (would duplicate product_name_conventions).
Rolled-back dry run (02:50): pending plan line "Hunter Cans" on AMZ-1038 A10 (WEIMI Hunter Canister
40G): guard check mode before = 1 warned, after = 0 warned. Add New on WH2-2001 A01 opened relabel
"A01 Tamreem Dried Freeze Fruits -> Vitamin Well (swap)"; mark_relabel_done as operator_admin -> done.
FE (day): Config > Machines "Relabels" tab with the open list and a Done button.

### PRD-141 item 23 (WEIMI drift report): report prepared; weekly auto-commit BLOCKED (permission)

Prepared supabase/prepared/prd141c/prd141_23_weimi_drift_report.sql: v_pod_weimi_lane_drift (lanes where
WEIMI and Active pod_inventory differ by more than 2 units, refill machines, snapshot under 48 h) and
check_pod_weimi_drift() nightly at 03:50 Dubai (one alert row). Rolled-back read (02:55): 533 lanes on
35 machines; worst AMZ-1038 16 lanes / 1,851 units, AMZ-1029 16 / 1,389, AMZ-1068 16 / 756,
ACTIVATEMCC-2005 27 / 657, MC-2004 30 / 639. VML-1004 (the F3 example) has 11 drifting lanes, e.g.
A02 Soft Drinks Mix WEIMI 5 vs pod_inventory 40. pod_inventory is mostly ABOVE WEIMI.
Weekly auto-commit (spec: resync_pod_inventory_from_weimi weekly for machines with no open dispatch):
BLOCKED (permission). The Claude Code auto-mode classifier refused to let this session create an
unattended job that rewrites live pod quantities. Not worked around. Design for CS, ready to paste: a
service_role-only function looping the drift machines that have no open dispatch line in the last 7
days, calling resync_pod_inventory_from_weimi(machine, false) inside a per-machine exception block,
cron '20 0 * * 0' (Sunday 04:20 Dubai), switch refill_policy_params.weekly_resync_enabled. Given the
size of the drift (hundreds of units per AMZ machine) and the align_pod_lots_to_weimi job failing on
unique-index collisions (99 failures in 3 days, scoping agent), a supervised first run is the safer path.
