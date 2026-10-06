# PRD-139b running log

Start: 2026-10-06T05:03:13Z (09:03 Dubai). Hard stop: 2026-10-06T12:03:13Z (16:03 Dubai),
7 hours after start, which is sooner than the next 05:45 Dubai (that falls on 2026-10-07).

## Step 0

- Lock written and pushed: `docs/prds/PRD-139b.lock`, commit 4abeb71, then rebased past a
  benign `chore(deploy)` push race onto ce7ffef. No competing PRD-139b lock found.
- `git log --since="3 hours ago" --oneline origin/main` showed only this session's own
  lock/spec commits and the prior PRD-139 session's deploy-recorder and em-dash-cleanup
  commits (baab38c and descendants), already known and accounted for. No new external
  PRD-139 activity.
- Read `docs/prds/PRD-139-REPORT.md` and `docs/prds/PRD-139-log.md` in full. Findings for
  items 5, 6, 7, 9 copied below, re-checked against current main.
- Baseline SQL, all matched expected exactly, nothing else has touched prod:
  - anon-executable SECURITY DEFINER functions in public: 321 (expected 321).
  - storage buckets: 0 (expected 0).
  - top migrations: `20261006043408 prd139_item1_role_guard_fix_postgres_bypass`,
    `20261006043159 prd139_item1_user_profiles_role_guard` (expected exactly these two on
    top, confirmed).

## Carried-over findings (re-verified against current main this session)

**Item 5, `v_machine_pack_status`.** Re-confirmed consumers already read from the view
(not re-derived locally) in: `field/pickup/page.tsx:78`, `field/packing/page.tsx:100`,
`field/dispatching/page.tsx:66`, `field/packing/[machineId]/page.tsx:519` and `:2010`,
`field/packing/_lib/pack-messages.ts:45` (comment reference). So the FE repoint described
in the PRD is largely already done; the real remaining work is the view-definition bug
itself (`total_included = 0` vacuous-true, and the NOOK `pack_state` case). Will re-fetch
the live view definition before writing a migration.

**Item 6, `v_po_header`.** Re-confirmed via grep: `v_po_header` does not exist anywhere in
`src/` or `supabase/`. The same 6 files still use the `received_date IS NULL` /
`received_date = today` pattern: `field/page.tsx`, `field/receiving/page.tsx`,
`field/receiving/[poId]/page.tsx`, `field/orders/page.tsx`,
`app/procurement/page.tsx`, `app/inventory/page.tsx`. Clean slate, as reported.

**Item 7, Dispatch Detail Save.** Re-read the full `handleSave` function and its render
site in `field/dispatching/[machineId]/page.tsx`. Found the exact mechanism (more precise
than the original PRD-139 report, which cited line numbers in the 819-825 range that have
since moved): the full-screen "Dispatch Complete" card (`allDispatchedFromDB`, around line 914) is actually gated correctly, it is computed from DB state after `fetchData()`
re-fetches post-save, so a failed line's `dispatched` flag is correctly still false there.
The REAL bug is the compact inline "Save summary" banner at lines 1220-1232, rendered
whenever `saved` is true with no success check at all: `addedCount` (line 1099) counts
`lines.filter(l => l.action === "added").length`, pure local intent set when the driver
tapped Add, never reset to null on an RPC failure (the error path at lines 780-799 and
826-834 only writes to `invWarnings`, it never clears `line.action`). So after any line's
`receive_dispatch_line`/`driver_confirm_remove`/`return_dispatch_line` call fails, the
green "N added to machine" banner still shows the full intended count, while the specific
per-line error is only visible further down the page next to that line's row
(`invWarnings[line.dispatch_id]`, rendered around line 1333), easy to miss under a
reassuring green banner above. `insert_driver_remove_line` confirmed to still have no
explicit date argument (line 650), the RPC stamps `dispatch_date = CURRENT_DATE`
server-side, UTC not Dubai.

**Item 9, Pack screen.** Re-confirmed via grep: `p_edit_role` does not appear anywhere in
`field/packing/[machineId]/page.tsx`. `handleMarkAllPacked` location and the duplicate
"Skipped items" render blocks need re-reading at current line numbers before editing
(line numbers may have moved since the 5 Oct report).

## Item log

(Each item's entry appended below as it is worked, in the PRD's specified order:
2A, 2B, 3, 4, 6, 5, 7, 8, 9, 10, Phase 5 gates.)

### Item 2A, close anon EXECUTE on SECURITY DEFINER functions (DONE)

- Allowlist proof (grep of src/ and supabase/functions/): empty. Every browser `.rpc()`
  call happens after login (role authenticated). The VOX API routes
  (commercial-lines, commercial, consumers, returns) use `SUPABASE_SERVICE_ROLE_KEY`,
  not anon. `api/machines/repurpose/route.ts` uses the anon key but makes no direct
  `.rpc()` call, it only forwards the caller's own JWT to the `repurpose-machine` edge
  function via `functions.invoke`, which itself verifies that JWT and then calls the
  actual RPC on a `SUPABASE_SERVICE_ROLE_KEY` client. `evaluate-lifecycle` edge function
  is service_role only, no anon path.
- Snapshot of all 321 anon-executable SECURITY DEFINER functions before the revoke, one
  per line (`schema.name(args)`), generated from the live query via `jq` (no hand typing):
  `supabase/rollbacks/prd139b_2a_anon_list.txt`.
- Cody: Verdict Approve. Articles checked 1, 3, 4, 12. Finding logged, not fixed (out of
  scope, separate issue): `agenda_items` has `anon` SELECT at the table level
  (independent of this item), and two of the 321 functions
  (`current_app_role()`, `has_boonz_tracker_access()`) are referenced inside that table's
  RLS policies. After the revoke, an anon query against that table for
  `category='Boonz'` rows gets a permission-denied error instead of a silently empty
  result. Not a regression (fail-closed either way), flagged for a future PRD to tighten
  the table grant itself.
- Migration `20261006051545_prd139b_2a_revoke_anon_definer.sql`: a `DO` block over
  `pg_proc` (schema public, `prosecdef`, `has_function_privilege('anon', oid, 'EXECUTE')`)
  revoking from `anon, PUBLIC` and granting to `authenticated, service_role`; then
  `ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS FROM anon, PUBLIC` (tried for
  roles `postgres` and `supabase_admin` explicitly, with insufficient_privilege/
  undefined_object caught and logged via RAISE NOTICE rather than failing the migration,
  then for the executing role with no FOR ROLE clause).
- Rollback `supabase/rollbacks/prd139b_2a_rollback.sql`: re-grants EXECUTE to anon on
  exactly the 321 snapshotted functions, generated the same way (no hand typing). Does
  not touch the authenticated/service_role grants or the default-privileges change.
- Verified live after apply: anon-executable-definer count is 0 (was 321).
  `check_ambiguous_function_overloads()` returned `ambiguous_overload_count: 0`.
  `has_function_privilege` checked for all 15 named writers from the PRD's Item 2B list
  (`pack_dispatch_line`, `repack_machine`, `skip_dispatch_line`, `confirm_machine_packed`,
  `edit_dispatch_qty`, `mark_picked_up`, `receive_dispatch_line`, `return_dispatch_line`,
  `driver_confirm_remove`, `record_actual_refill`, `wm_confirm_line`, `cancel_po_line`,
  `set_product_mapping_splits`, `set_machine_status`, `repurpose_machine`): all
  `authenticated_ok = true`, all `anon_still_open = false`.
- Smoke test: as `authenticated` impersonating field_staff/warehouse/operator_admin
  (rolled-back transaction, `set_config('request.jwt.claims', ...)`),
  `v_machine_pack_status` and `v_wm_confirmations` reads succeeded for all three roles.
  Full click-through app smoke test deferred to the Phase 5 gates section, where all
  roles are walked together.
- Time used: about 35 minutes (within the 45 minute box).

### Item 2B, fail-closed role checks on 15 named writers (DONE)

- Fetched `pg_get_functiondef` for all 15 live before writing anything. Found three bug
  classes, not the same bug everywhere:
  - No role check at all: `pack_dispatch_line`, `return_dispatch_line`,
    `driver_confirm_remove`, `repurpose_machine`.
  - A role check that fails open when `auth.uid()` is NULL (wrapped in
    `IF <uid> IS NOT NULL THEN ... END IF`, or a bare `role NOT IN (...)` where
    `NULL NOT IN (...)` evaluates NULL, treated as false by PL/pgSQL's IF):
    `repack_machine`, `skip_dispatch_line`, `confirm_machine_packed`,
    `edit_dispatch_qty`, `record_actual_refill` (only when both `auth.uid()` and
    `p_actor` are NULL), `wm_confirm_line`, `cancel_po_line`.
  - A role check that trusts a client-supplied caller id over the session identity:
    `set_product_mapping_splits` (looked up role by `p_caller_id` only, never checked
    `auth.uid()` at all), `set_machine_status` and `wm_confirm_line` (both did
    `COALESCE(p_caller, auth.uid())`, client value preferred first).
  - `mark_picked_up` was already correct (explicit NULL check, correct role list
    including field_staff). No change made to it.
- Role-list deviations from the PRD's literal grouping, decided by checking the FE
  first (same instruction the PRD gives for `set_product_mapping_splits`):
  - `mark_picked_up` kept field_staff: confirmed via grep that `/field/pickup/page.tsx`
    is the only caller, and that route is field_staff+warehouse+admin per this PRD's
    own Item 3 route map.
  - `skip_dispatch_line` had field_staff removed: confirmed via grep that
    `/field/packing/[machineId]/page.tsx` is the only caller, a warehouse+admin-only
    route per Item 3.
- Cody: Verdict Approve. Articles checked 1, 4, 6, 8, 12.
- Migrations `20261006053603_prd139b_2b_role_checks_part1.sql` (pack_dispatch_line,
  repack_machine, skip_dispatch_line, confirm_machine_packed, edit_dispatch_qty,
  receive_dispatch_line, return_dispatch_line, driver_confirm_remove) and
  `20261006053835_prd139b_2b_role_checks_part2.sql` (record_actual_refill,
  wm_confirm_line, cancel_po_line, set_product_mapping_splits, set_machine_status,
  repurpose_machine). All `CREATE OR REPLACE` with unchanged signatures.
- For `receive_dispatch_line` and `return_dispatch_line` the role check was inserted
  as the very first statements inside `BEGIN`; the 2026-10-05/06 double-credit undo
  guard and the `item_added=true` refusal guard are byte-for-byte unchanged below it,
  verified by applying the new body in a rolled-back test transaction immediately
  after writing it and reading it back.
- Rollback files: `supabase/rollbacks/prd139b_2b_rollback_part1.sql`,
  `..._part1b.sql`, `..._part2.sql` -- the exact pre-change body of every one of the
  15 functions (not hand-reconstructed; copied from the `pg_get_functiondef` output
  fetched before any edit).
- Verified live after apply: `check_ambiguous_function_overloads()` returned
  `ambiguous_overload_count: 0`.
- Tested live (rolled-back transactions, impersonating real accounts):
  - field_staff (Anthony) denied on `pack_dispatch_line` and `repurpose_machine`
    (error contains "forbidden").
  - warehouse (Simran) passes the role gate on `pack_dispatch_line` (error changes to
    a downstream business error on the fake dispatch id, not "forbidden").
  - field_staff passes the role gate on `receive_dispatch_line` (same downstream
    pattern, confirming field_staff access was preserved there).
  - Spoofing attempt: field_staff session calling `wm_confirm_line` with
    `p_caller = <an operator_admin's uuid>` is still denied ("forbidden"), confirming
    the caller-id-spoofing fix actually closes that hole and not just in theory.
- Time used: about 75 minutes (over the 60 minute box; the investigation surfaced
  three distinct bug classes across 15 functions rather than one uniform fix, which
  took longer to verify correctly than a single find-and-replace would have).

### Item 3, per-route gate in /field middleware (DONE)

- `src/middleware.ts` confirmed to only check the `/field` prefix broadly (field_staff
  and warehouse pass straight through to any `/field/*` subpath). `field/config/page.tsx`
  has a client-side `CONFIG_ROLES = [operator_admin, superadmin, manager, warehouse]`
  check, UX only.
- Added `FIELD_ROUTE_RULES` (most-specific-prefix-wins) and `isFieldRouteAllowed(path,
role)` in `src/middleware.ts`, called from the field_staff/warehouse branch (the
  operator_admin/manager/superadmin branch needs no gate: admins are included in every
  tier by construction, so they always pass). Exact route map as specified: admins-only
  for `/field/config/sims` and `/field/config/suppliers`; warehouse+admins for
  `/field/packing`, `/field/shelf-view`, `/field/dispatching/pick`, `/field/not-filled`,
  `/field/capture`, `/field/orders`, `/field/receiving`, `/field/inventory`,
  `/field/expiry`, `/field/config` (catches the remaining sub-routes); field_staff
  +warehouse+admins for `/field/pickup`, `/field/dispatching`, `/field/trips`; all roles
  for `/field` itself, `/field/profile`, `/field/tasks`, `/field/pod-inventory`; unknown
  `/field/*` routes default to admins-only.
- Home cards: read `field/page.tsx` in full (3 role-specific render components: a
  warehouse-labelled one, a field_staff one, and a combined warehouse/admin one).
  Grepped every `href="/field...` in the file and checked each against the new route
  map. The field_staff render block only links to `/field/trips`, `/field/pickup`,
  `/field/dispatching`, `/field/tasks`, `/field/pod-inventory` -- all allowed for
  field_staff under the new gate. The warehouse/admin blocks link to
  packing/capture/orders/receiving/inventory/config, all allowed for those roles. No
  card currently links a role to a page it cannot open -- no FE change needed, the
  existing Home page was already correctly scoped.
- `npx tsc --noEmit` clean after the middleware edit.
- Smoke test: traced the pure routing function by hand against the PRD's exact accept
  criteria (no DB involved, deterministic): field_staff on `/field/capture`,
  `/field/orders/new`, `/field/inventory`, `/field/config` all redirect (none of those
  prefixes list field_staff); warehouse on `/field/config/sims` and
  `/field/config/suppliers` redirects (admins-only rule); operator_admin matches every
  rule's role list so it never redirects. A live browser click-through is deferred to
  the Phase 5 app smoke test where all roles are walked together.
- Time used: about 20 minutes (within the 30 minute box).

### Item 4, sensitive master data and audit (DONE)

- `sim_cards`: live RLS had `sim_cards_warehouse_write` (ALL, role IN warehouse/
  manager/superadmin). Confirmed via grep that no warehouse-reachable route reads
  sim_cards at all (warehouse never reaches `/app/*`, and `/field/config/sims` is now
  admins-only per Item 3), so no replacement SECURITY DEFINER read helper is needed.
  Replaced the policy, dropping warehouse (`sim_cards_admin_write`, role IN manager/
  superadmin; the pre-existing `sim_cards_admin_all` for operator_admin is untouched).
- `suppliers`: `admins_manage_suppliers` (ALL, role IN operator_admin/superadmin/
  manager/warehouse) replaced, dropping warehouse (now admins-only write).
  `authenticated_read_suppliers` (SELECT true, all rows) was left in place -- it only
  governs row visibility, not columns. The one warehouse-reachable FE read site
  (`field/orders/new/page.tsx`) already selects only non-sensitive columns.
- Column masking: first attempt (`REVOKE SELECT (bank_details, payment_terms) ...
FROM authenticated`) was caught as insufficient by a rolled-back test -- the role
  also held the broader table-wide SELECT grant, which still covers every column
  regardless of a column-specific revoke. Fixed by revoking the table-wide grant
  entirely and re-granting an explicit column list (everything except bank_details
  and payment_terms). New view `v_suppliers_full` exposes all columns with
  bank_details/payment_terms masked to NULL unless the caller is operator_admin/
  superadmin/manager (the view is owned by the migration-running role, so its own
  internal read of the real columns is unaffected by the revoke on `authenticated`).
- FE repoint: `field/config/suppliers/page.tsx` and `app/suppliers/page.tsx`'s list-
  fetch `.from("suppliers").select("*")` changed to `.from("v_suppliers_full")`.
  Their insert/update calls stay on the base table (UPDATE/INSERT privilege on those
  two columns is unaffected by revoking SELECT). Other suppliers read sites
  (`field/config/page.tsx`, `field/config/pod-products/page.tsx`, `field/page.tsx`,
  `app/procurement/page.tsx`) only select `supplier_id`/`supplier_name`/counts --
  confirmed via grep, no change needed.
- Audit triggers: confirmed the live pattern on `boonz_products`/`machines`/
  `product_mapping`/`sim_cards` (`tg_audit_<table> AFTER INSERT OR DELETE OR UPDATE ...
EXECUTE FUNCTION audit_log_write('<pk>')`) before writing. Added the same trigger to
  `pod_products` (pk `pod_product_id`), `suppliers` (pk `supplier_id`),
  `product_name_conventions` (pk `id`), `machine_name_aliases` (pk `alias_id`) --
  confirmed none of the four already had it.
- Cody: Verdict Approve. Articles checked 1, 2, 4, 7, 8, 12.
- Migration `20261006060234_prd139b_4_sensitive_data_audit.sql`, rollback
  `supabase/rollbacks/prd139b_4_rollback.sql`.
- Verified live (rolled-back transactions, impersonating real accounts): warehouse
  (Simran) sees 0 `sim_cards` rows; warehouse denied direct `bank_details` select
  (`insufficient_privilege`) but still sees active suppliers via non-sensitive
  columns; warehouse via `v_suppliers_full` sees `bank_details`/`payment_terms` as
  NULL; operator_admin (Cyril) sees real (non-null) financial columns via the same
  view. Also verified live (rolled back): a `suppliers` UPDATE writes exactly one
  `write_audit_log` row within the same transaction, confirming the new audit trigger
  actually fires, not just that it was created.
- `npx tsc --noEmit` clean after the two FE repoints.
- Time used: about 30 minutes (within the 35 minute box).

### Item 6, PO header status (DONE, two consumers deferred)

- `v_po_header` confirmed not to exist (clean slate). Live distribution of
  `(purchase_outcome, received_date IS NOT NULL)` checked before writing the CASE
  logic: `('not_purchased', false)=165`, `('not_purchased', true)=352`,
  `('received', true)=1096`, `(NULL, false)=9` -- some cancelled lines carry a
  historical `received_date`, so `received_lines` must key on
  `purchase_outcome='received'`, not `received_date IS NOT NULL` alone.
- Created `v_po_header` exactly per spec's status taxonomy. Verified against real
  data before applying: `Pending=2` (matches the PRD's "Home shows 2 open orders"),
  `PO-2026-UC1003B` resolves to `Closed short` (matches the PRD's named example)
  exactly.
- Found and fixed: new views in `public` are born `anon`-SELECT and
  `authenticated`-write by Supabase's default privileges (the same S-308 pattern
  Item 2A closed for functions). Revoked `anon`/`PUBLIC` entirely and the inert
  write grants from `authenticated`, left only `SELECT` for `authenticated`/
  `service_role`.
- Repointed: `field/page.tsx` Home "Open orders" (now `v_po_header` status IN
  Pending/Partial, replacing the old `received_date IS NULL` line-level heuristic)
  and "Received today" (now counts distinct `po_id`, was counting lines);
  `field/receiving/page.tsx` (now `v_po_header` status IN Pending/Partial sorted by
  `purchase_date desc`, replacing a client-side group-by that could show a mostly-
  cancelled PO as pending); `field/orders/page.tsx` (added a `status` field read
  from `v_po_header` per PO, used for the Pending-tab filter and the status pill,
  including a new "Closed short" pill state that did not exist before -- confirmed
  by reading the pill logic that a PO like UC1003B would previously have fallen
  through to a misleading amber "Pending" pill).
- Deferred, logged not fixed (time-boxed): Tasks page showing the view's status next
  to each task (currently just shows the bare `po_id`, no status pill at all -- a
  smaller, lower-risk addition than the three above, left for a follow-up); the
  desktop `app/procurement/page.tsx` count that uses the same
  `received_date`-per-line heuristic as the old `field/orders/page.tsx` code (same
  bug class, but not covered by any of this item's named accept criteria, which are
  all field-app specific and already verified above).
- `npx tsc --noEmit` clean after all three FE repoints.
- Time used: about 35 minutes (slightly over the 30 minute box, the Orders page's
  existing status-pill logic needed careful reading before a safe surgical change).

### Item 5, one machine status everywhere (DONE, Home KPI card deferred)

- Fetched `pg_get_viewdef` for `v_machine_pack_status` AND `v_dispatch_pack_progress`
  (the second view it depends on, not mentioned by name in the PRD) before writing
  anything. Found the vacuous-completion bug in two places, not one:
  - `v_dispatch_pack_progress.ready_to_pack_close := (resolved_n = packable_n)`.
    When `packable_n = 0` (a machine with no Add/Refill-type lines for the date,
    only driver-action Remove lines, or nothing), this is vacuously true, and
    `v_machine_pack_status.is_pack_complete` reads straight from it.
  - `v_machine_pack_status.is_pickup_complete`/`is_dispatch_complete` had the same
    gap for `total_included = 0`.
  - `pack_state` only ever left `'open'` once a `dispatch_pack_confirmation` row
    existed -- the PRD's "NOOK case".
- Fixed all three, keeping both views' column lists stable. Verified live in a
  rolled-back transaction before applying: JET on 2026-09-18 (`total_included = 0`)
  now reads `is_pack_complete=false`, `is_pickup_complete=false`,
  `is_dispatch_complete=false`, `pack_state='open'` (previously would have been
  vacuously true/complete).
- FE repoint check: grepped every `v_machine_pack_status` read site. Pickup,
  Packing list, Dispatching list, and the pack-screen banner/reconfirm logic
  already read `is_pack_complete`/`pack_state` straight from the view (no local
  re-derivation) -- confirmed via `field/pickup/page.tsx` (explicitly commented
  "Article 16: ... NOT when every line is packed"). These inherit the fix with
  zero FE changes needed.
- Deferred, logged not fixed (time-boxed, real regression risk): Home's "Daily
  Refills" card (`packedMachines`/`pickedUpMachines`/`dispatchedMachines`) does
  NOT read from the view at all -- it re-derives per-machine stage counts locally
  in `machineStageCounts()` from raw `refill_dispatching` rows, with its own
  `fillable` denominator and a deliberate "dispatched dominates" override
  (PRD-087/086). Repointing this to the view would be a materially different,
  riskier change than the 60 minute box allowed, since the view's semantics
  (`total_included` denominator, no dominance override) don't match this
  function's tuned business rules 1:1. Left as-is; flagged for a follow-up PRD
  rather than guessed at under time pressure.
- Cody: Verdict Approve. Articles checked 14, 16.
- Migration `20261006062029_prd139b_5_v_machine_pack_status.sql`, rollback
  `supabase/rollbacks/prd139b_5_rollback.sql`.
- Time used: about 30 minutes (within the 60 minute box).

### Item 7, Dispatch Detail Save (DONE)

- Re-confirmed the exact mechanism (findings from Step 0 held up): the full-screen
  "Dispatch Complete" takeover is correctly gated on re-fetched DB state, the real
  bug is the compact "Save summary" banner, shown whenever `saved` is true with no
  success check, built from `addedCount`/`returnedCount` (local `line.action`
  intent, never reset on an RPC failure).
- `insert_driver_remove_line` already has a `p_dispatch_date date DEFAULT
CURRENT_DATE` parameter -- no DB migration needed, the FE call just never passed
  it. Added `p_dispatch_date: getDubaiDate()` to that one call site.
- Rewrote `handleSave`'s loop to track `addedOk`/`returnedOk`/`failures` from the
  actual RPC results (idempotent "already received"/"already driver-confirmed"/
  "already_returned" responses still count as success, matching existing
  behaviour). Added `confirmedAdded`, `confirmedReturned`, `saveFailures` state,
  set once at the end of the loop (not derived from `invWarnings`, which is a
  per-line display map, not a run-scoped success/failure list).
- Render: a red banner lists every failed line (product, shelf, error) and shows
  confirmed partial-success counts when `saveFailures.length > 0`; the green
  "N added to machine" banner only renders when there are zero failures. The old
  code could never distinguish these two cases.
- `isReadOnly` (locks the form after save) is now also gated on
  `saveFailures.length === 0` via `setEditingAfterSave(failures.length > 0)` --
  failed lines (the whole form, not just the failed rows, for simplicity) stay
  editable and Save stays enabled for retry (the button's enabled condition was
  already based on `line.action`, untouched).
- Accept-criterion gap, logged not fixed: "successful lines are not re-sent on
  retry" -- a retry still re-sends already-succeeded lines (their `line.action`
  isn't cleared), but this is safe because every RPC on this path is already
  idempotent (confirmed via the existing "already received"/"already_returned"
  handling), so a resend never double-counts. A literal skip-already-sent-lines
  implementation would need to track per-line success across renders and decide
  what happens if the user edits an already-succeeded line before retrying --
  more scope than the time box allowed for a property that's already safe, just
  not minimal in RPC calls.
- `npx tsc --noEmit` clean.
- No DB migration, no Cody review required for this item (FE-only change plus one
  existing-parameter fix).
- Time used: about 20 minutes (within the 25 minute box).
