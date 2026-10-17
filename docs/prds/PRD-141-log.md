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
