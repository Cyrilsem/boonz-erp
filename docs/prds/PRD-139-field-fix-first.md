You are working in the boonz-erp repo (Next.js app router, Supabase project `eizcexopcuoycuosittm`). Run PRD-139 tonight as one loop. First save this whole prompt as `docs/prds/PRD-139-field-fix-first.md` and commit it.

### Ground rules

- Pull main first. Before each item, check main and prod: if PRD-137 or anything since already fixed it, record "already done" with evidence and skip it.
- Every DB change is a migration file in the repo AND applied to prod; keep prod/repo parity (run the existing drift/parity check at the end).
- Every SECURITY DEFINER, grant, RLS and middleware change gets a Cody review pass before apply.
- Surgical scope. No refactors, no renames, no UI redesign beyond what each item says. No em dashes in any user-facing text.
- Dubai dates (Asia/Dubai) for any date logic.
- Write a running log to `docs/prds/PRD-139-log.md`: per item, what changed, migration names, commit hashes, test evidence.
- Order: Phase 1 security (items 1, 2, 3, 4), Phase 2 truth (6, 5), Phase 3 silent failures (7, 8, 9), Phase 4 backlogs (10), Phase 5 gates.

### Item 1. Role self-promotion

Facts: `public.user_profiles` has policy `own_profile_update` (id = auth.uid()) and `authenticated` holds UPDATE on column `role`. No guard trigger.
Do:

- Find every client write to `user_profiles` in `src/` (language, onboarding/tour flags, name, etc.). Replace table-level UPDATE for `authenticated` with column-level UPDATE on exactly those columns. `role` and `id` excluded.
- Add a BEFORE UPDATE trigger `trg_user_profiles_role_guard`: if `NEW.role IS DISTINCT FROM OLD.role` and the caller is not service_role and not operator_admin/superadmin (checked via a SECURITY DEFINER helper `is_admin(auth.uid())`), raise `role change not allowed`.
- Same guard for INSERT: authenticated users cannot insert a profile with a role other than the default the app expects (check how profiles are created; if by trigger or service role, revoke INSERT from authenticated).
  Accept: as a test field_staff session, `update user_profiles set role='superadmin' where id=auth.uid()` fails; updating `preferred_language` still works; admin role change via the existing admin path still works. Log the current 6 users and roles for CS.

### Item 2. Writers callable with the public key

Facts: 320 of 414 public SECURITY DEFINER functions are executable by anon.
Do:

- Prove the allowlist: grep `src/` and `supabase/functions/` for `.rpc(` calls reachable without a session (login, auth callback, public pages, `/portal` pre-login, any route the middleware treats as public) and any server code using the anon key. Check Supabase API logs for the last 7 days for RPC calls made with role anon if available. Write the allowlist (expected empty) to the log.
- Migration: for every function in schema public with `prosecdef = true`: `REVOKE EXECUTE ... FROM anon, PUBLIC; GRANT EXECUTE ... TO authenticated, service_role;` except the allowlist. Also `ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, PUBLIC;` so new functions are closed by default. Generate the statement list from `pg_proc` in the migration (DO block), and save a rollback SQL file next to it (re-grant to anon for the exact list revoked).
- Fail-closed role checks on these writers (add or fix; never trust a role or user id passed from the client): `pack_dispatch_line`, `repack_machine`, `skip_dispatch_line`, `confirm_machine_packed`, `edit_dispatch_qty`, `mark_picked_up` (warehouse, operator_admin, manager, superadmin); `receive_dispatch_line`, `return_dispatch_line`, `driver_confirm_remove`, `record_actual_refill` (field_staff plus the above); `wm_confirm_line`, `cancel_po_line` (warehouse plus admins); `set_product_mapping_splits`, `set_machine_status`, `repurpose_machine` (operator_admin, manager, superadmin; keep current warehouse behaviour where it already works for mapping, check the FE). A NULL `auth.uid()` or a user with no profile row must raise. Where a function takes `p_caller_id`, `p_edit_role` or similar, ignore the parameter value and use `auth.uid()` and the stored role; keep the parameter in the signature so the FE does not break, and remove `p_edit_role: 'warehouse_manager'` from the pack screen calls.
- Do not create overloads. Run the overload check after.
  Accept: with the anon key and no session, `select pack_dispatch_line(...)` / RPC call returns permission denied for every function in the named list; logged-in smoke test (Phase 5) passes for every role.

### Item 3. Per-route gate in /field

Facts: `src/middleware.ts` only checks the `/field` prefix; `/field/config` has a client-only check (`field/config/page.tsx:11`).
Do: add a server-side route map in middleware (most specific prefix wins, unknown /field route = operator_admin, manager, superadmin only, others redirect to `/field`):

- All roles: `/field`, `/field/profile`, `/field/tasks`, `/field/pod-inventory`.
- field_staff + warehouse + admins: `/field/pickup`, `/field/dispatching` (incl. `[machineId]`), `/field/trips`.
- warehouse + admins: `/field/packing`, `/field/shelf-view`, `/field/dispatching/pick`, `/field/not-filled`, `/field/capture`, `/field/orders`, `/field/receiving`, `/field/inventory`, `/field/expiry`, `/field/config`, `/field/config/boonz-products`, `/field/config/pod-products`, `/field/config/product-mapping`, `/field/config/product-naming`, `/field/config/machines`.
- admins only (operator_admin, manager, superadmin): `/field/config/sims`, `/field/config/suppliers`.
  Keep the client checks; they are UX, not security. Home cards should not link a role to a page it cannot open (hide the card).
  Accept: field_staff gets redirected from `/field/capture`, `/field/orders/new`, `/field/inventory`, `/field/config`; warehouse gets redirected from `/field/config/sims` and `/field/config/suppliers`; operator_admin reaches everything.

### Item 4. Sensitive master data and audit

Do:

- RLS: `sim_cards` ALL and SELECT for operator_admin, manager, superadmin only (warehouse loses access, matching desktop which hides SIMs from warehouse). Check that no warehouse flow reads `sim_cards`; if one does, give it a SECURITY DEFINER read that excludes PUK and contact number columns.
- `suppliers`: keep warehouse SELECT on non-sensitive columns only (name, code, status, contact person, phone, email, address, products supplied); bank details and payment terms readable by admins only (column grants or a view; choose the smaller change and log it). Warehouse write on suppliers removed.
- Add `audit_log_write` triggers (same pattern as `boonz_products`, `machines`, `product_mapping`, `sim_cards`) to `pod_products`, `suppliers`, `product_name_conventions`, `machine_name_aliases`.
  Accept: warehouse session cannot select PUK columns or bank details; an edit to a pod product price writes an audit row.

### Item 5. One machine status everywhere

Facts: `v_machine_pack_status` (machine_id, dispatch_date, total_included, resolved, physical, not_filled, picked_up_physical, dispatched_physical, is_pack_complete, is_pickup_complete, is_dispatch_complete, pack_state, ...) is mostly right. Seen live: Packing said JET "Already dispatched", Dispatching "To dispatch 10/45", Trips "In progress"; HUAWEI "Completed, 6 lines" on Dispatching, "In progress, 8 lines" on Trips, listed on Pickup, while Home said "0 ready to collect".
Do:

- Fix the view: rows with `total_included = 0` are excluded (or flagged `no_plan`) so they never read as complete; `pack_state` = 'completed' when every included line is resolved (NOOK case). Keep the column list stable.
- Repoint these to the view (no local recomputation of done/ready): Home cards (Daily refills, Ready to collect, To dispatch), Packing list status chip, pack screen banner, Pickup list, Dispatching list and progress bar, Trips list chips.
- Definitions: Ready to collect = is_pack_complete AND NOT is_pickup_complete AND physical > 0. Pickup list shows only those. To dispatch = is_pickup_complete AND NOT is_dispatch_complete AND physical > 0. Pack screen banner when some lines are dispatched: "Dispatch in progress (10 of 45 dispatched), repack disabled for dispatched lines"; only say "Already dispatched" when is_dispatch_complete.
- Line counts shown next to a machine use `physical` (or `total_included` labelled as planned), the same number on every page.
  Accept: for today's date, Home, Packing, Pickup, Dispatching and Trips agree for every machine; HUAWEI not on Pickup; JET shows 10 of 45 everywhere.

### Item 6. POs: one header status

Facts: 31 POs have an unreceived line; 29 of them only have `not_purchased` lines left; 2 are truly open. Home "Open orders", the Receiving list and Tasks use "any line with received_date null".
Do:

- Create `v_po_header` (po_id, po_number, supplier_id, purchase_date, lines, ordered_qty, received_qty, open_lines, cancelled_lines, received_lines, status) with: Cancelled = all lines not_purchased; Pending = open_lines > 0 and received_lines = 0; Partial = open_lines > 0 and received_lines > 0; Closed short = open_lines = 0 and received_lines > 0 and cancelled_lines > 0; Received = open_lines = 0 and cancelled_lines = 0. Open line = `purchase_outcome IS NULL AND received_date IS NULL`.
- Repoint: Home "Open orders" (count Pending + Partial), Home "Received today" (count distinct POs received today, not lines), `/field/receiving` list (Pending + Partial only, sorted by purchase_date desc), `/field/orders` Pending and All tabs (status pill from the view), Tasks "Collected" vs PO state (show the view status next to the task), and any desktop Procurement count that uses the same rule (search for it; log what you changed).
- Make sure `cancel_po_line` leaves a state the view reads as Cancelled (no extra column needed if `not_purchased` is the cancel outcome; verify).
  Accept: Home shows 2 open orders; Receiving lists 2 POs; Orders All shows UC1003B as Closed short; no cancelled PO appears in Receiving.

### Item 7. Dispatch Detail Save

Facts: `src/app/(field)/field/dispatching/[machineId]/page.tsx` save loop continues past per-line RPC errors and then shows the green summary built from local intent (around :819-825); `addedCount` counts intent.
Do: collect a result per line (ok / error message). Summary counts only confirmed writes. If any line failed: red banner listing each failed line (product, shelf, error), keep those lines editable, keep Save enabled for retry; never show the green "all added" state. Also pass the Dubai date explicitly to `insert_driver_remove_line` (it defaults to UTC CURRENT_DATE).
Accept: forcing one RPC to fail in a dev test shows the red banner with that line and a correct count; successful lines are not re-sent on retry.

### Item 8. Machine photos

Facts: no storage buckets exist; `dispatch_photos` has 0 rows; upload errors are swallowed (`catch {}` around :481-483 of the dispatch page).
Do: migration creating private bucket `dispatch-photos` with storage policies: authenticated INSERT and SELECT for field_staff, warehouse and admin roles, path `<machine_id>/<dubai_date>/<before|after>-<uuid>.jpg`; no anon access; no public URLs (use signed URLs where the page shows the photo). Replace the silent catch with a visible error on the tile ("Photo not saved, tap to retry"). Do not create `machine-issues` (its page is to be removed in a later PRD).
Accept: a test upload creates an object and a `dispatch_photos` row; the tile shows the image via a signed URL; with storage blocked the tile shows the error.

### Item 9. Pack screen

Facts: `src/app/(field)/field/packing/[machineId]/page.tsx` "Mark all as packed" (around :1579-1602) overwrites lines already Not filled, M2M legs and no-stock lines; Packed, Confirm removed, Confirm move and pick quantities are browser-only until Save or Finish.
Do:

- Mark all as packed only touches lines with no decided outcome and with picks available; it never changes Not filled, Skipped, M2M transferred or no-stock lines.
- Write each pack outcome when tapped (call `pack_dispatch_line` per line, same as Not filled and Skip already do), show the RPC error on the card if it fails. If a full immediate-write change is too big tonight, add instead a `beforeunload` and in-app Back guard ("You have N unsaved packs") and log that the immediate write is deferred.
- Remove the client-sent `p_edit_role` (see item 2).
- The 7 duplicate "Skipped items" rows seen on JET (Hunter Canister 40G A09 x4, Plaay Truffle A16 x3): find why the list repeats (likely one row per batch or per dispatch row) and show one row per line.
  Accept: on a test machine, mark one line Not filled, press Mark all as packed, Finish: that line stays Not filled with no warehouse debit; leaving mid-pack either keeps the packs (immediate write) or warns.

### Item 10. Backlogs

Facts: 127 warehouse confirmations (oldest about 47 days), 11 pending pod edits (oldest 23 Sep), 8 unresolved `driver_feedback` rows from 20 May to 3 Jun still shown on Capture, 31 "To validate" rows on Machine Stock Expiry that are all 0 units.
Do (no stock writes):

- `driver_feedback` older than 30 days and unresolved: set resolved with note `auto-expired PRD-139`, so the Capture box clears. Add a nightly job doing the same.
- `pod_inventory_edits` pending older than 7 days: set status `expired` (status already exists), nightly job. Show the age on each card in Inventory Pending Reviews, oldest first.
- Warehouse Confirmations: sort oldest first, show an age badge (amber over 48 h, red over 7 days), and paginate (render the first 20 with "show more") so the batch list below is reachable.
- Machine Stock Expiry: "To validate" excludes 0-unit rows; exclude pseudo-machines `WH1-*`, `WH2-*` and `*_OLD` from default lists.
- Write `docs/prds/PRD-139-backlog-report.md`: the 127 confirmations grouped by age bucket and source (machine, reason), so CS and the warehouse can clear them by hand.
  Accept: Capture shows 0 unlogged corrections; Pending Reviews shows only rows under 7 days; confirmations list loads with 20 cards and age badges.

### Phase 5. Gates (all must pass before you stop)

1. Overload check: no function in public has two signatures that make a named-arg call ambiguous.
2. Parity: repo migrations match prod.
3. Anon probe: with the anon key and no session, call 5 of the named writers and 2 random other SECURITY DEFINER writers: all denied.
4. Role probes: field_staff cannot update its role, cannot open `/field/capture`; warehouse cannot open `/field/config/sims` or read PUKs.
5. App smoke test before 06:00 Dubai, as each role (use the real accounts' flows on a test machine or a dry run that writes nothing to live stock): login, Home loads with correct counts, Packing list, pack screen (pack, Not filled, Mark all), Pickup, Dispatch Detail (add, return, photo), Orders, Receiving list, Inventory, Config hub. Any failure: fix or roll back that item using its rollback file, and log it.
6. Final message to CS in the log: per item done / skipped / rolled back, migrations, commits, and anything CS must do (e.g. Vercel deploy if not automatic).
