You are working in the boonz-erp repo (Next.js app router, Supabase project `eizcexopcuoycuosittm`). This finishes PRD-139. Last night's loop shipped item 1 only and left findings for items 5, 6, 7 and 9 in `docs/prds/PRD-139-REPORT.md` and `docs/prds/PRD-139-log.md`. Items 2, 3, 4 and 8 have no usable findings.

### Step 0. Single-session lock and baseline (5 min)

- `git pull origin main`. If `docs/prds/PRD-139b.lock` exists on main and its timestamp is less than 8 hours old, STOP: print "another PRD-139b loop holds the lock" and end. Otherwise write the lock (ISO timestamp, hostname, process id), commit "PRD-139b: take lock", push. If the push is rejected because someone else pushed the lock first, STOP.
- Also run `git log --since="3 hours ago" --oneline origin/main`. If any commit mentions PRD-139 and is not yours, write it in the log and re-read the report before starting.
- Read `docs/prds/PRD-139-REPORT.md` and `docs/prds/PRD-139-log.md` in full. For items 5, 6, 7 and 9, copy each finding (file, line, cause) into `docs/prds/PRD-139b-log.md` and re-check it against current main (lines may have moved). Use those findings; do not re-investigate from zero unless the file changed.
- Record the prod baseline in the log with SQL:
  - anon-executable SECURITY DEFINER functions in public (expected 321 on 6 Oct): `select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef and has_function_privilege('anon', p.oid, 'EXECUTE');`
  - storage buckets (expected 0): `select count(*) from storage.buckets;`
  - `select version, name from supabase_migrations.schema_migrations order by version desc limit 5;` (expected top two: 20261006043408 prd139_item1_role_guard_fix_postgres_bypass, 20261006043159 prd139_item1_user_profiles_role_guard).
  - If any baseline differs, something else changed prod: log it and adapt, do not undo it.

### Order and time boxes

2A (45 min), 2B (60), 3 (30), 4 (35), 6 (30), 5 (60), 7 (25), 8 (35), 9 (45), 10 (35), Phase 5 gates (40). Security first because it is the real exposure; truth and UX after.

### Ground rules

- Before each item, check main and prod: if it is already fixed, record ALREADY DONE with evidence and skip it.
- Every DB change is a migration file in the repo AND applied to prod; keep repo/prod parity.
- Surgical scope. No refactors, no renames, no UI redesign beyond what each item says.
- Dubai dates (Asia/Dubai) for any date logic.
- Running log: `docs/prds/PRD-139b-log.md` (per item: what changed, migration names, commit hashes, test evidence, time used).

### Item 2A. Close anon execute on SECURITY DEFINER functions (the big one)

Facts (6 Oct): 321 public SECURITY DEFINER functions are executable by anon, most of them writers. Anyone with the public key (it ships in the browser bundle) can call them without logging in.
Do:

- Prove the allowlist (cap 15 min): grep `src/` and `supabase/functions/` for `.rpc(` calls reachable without a session (login, auth callback, public pages, `/portal` pre-login, any route the middleware treats as public) and any server code using the anon key. Check Supabase API logs for the last 7 days for RPC calls with role anon if available. Write the allowlist (expected empty) to the log.
- Snapshot first: save the exact list of anon-executable definer functions (schema, name, identity args) to `supabase/rollbacks/prd139b_2a_anon_list.txt`.
- Migration `prd139b_2a_revoke_anon_definer`: a DO block over `pg_proc` where `prosecdef` and schema public, except the allowlist: `REVOKE EXECUTE ON FUNCTION ... FROM anon, PUBLIC; GRANT EXECUTE ON FUNCTION ... TO authenticated, service_role;`. Then `ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, PUBLIC;` (run it for every role that creates functions here, at least postgres and supabase_admin if permitted; log any that error).
- Rollback file `supabase/rollbacks/prd139b_2a_rollback.sql`: re-grant to anon for the exact snapshot list.
- Smoke test immediately as operator_admin, warehouse and field_staff: Home loads, Packing list, one pack screen opens, Dispatching list, Orders list. If something breaks, find the function(s) it calls, re-grant only those to anon (log why) or better, fix the caller to use the session client.
  Accept: the baseline count query returns 0 (or the allowlist size); anon probe on 5 named writers returns permission denied; all three roles still load the screens above.

### Item 2B. Fail-closed role checks on the named writers

Do (only after 2A is applied and smoke-tested):

- Add or fix role checks (never trust a role or user id passed from the client) on: `pack_dispatch_line`, `repack_machine`, `skip_dispatch_line`, `confirm_machine_packed`, `edit_dispatch_qty`, `mark_picked_up` (warehouse, operator_admin, manager, superadmin); `receive_dispatch_line`, `return_dispatch_line`, `driver_confirm_remove`, `record_actual_refill` (field_staff plus the above); `wm_confirm_line`, `cancel_po_line` (warehouse plus admins); `set_product_mapping_splits`, `set_machine_status`, `repurpose_machine` (operator_admin, manager, superadmin; keep warehouse where the FE already uses it for mapping, check the FE first and log the decision).
- A NULL `auth.uid()` or a user with no profile row must raise. Where a function takes `p_caller_id`, `p_edit_role` or similar, ignore the value and use `auth.uid()` plus the stored role; keep the parameter in the signature so the FE does not break. Remove `p_edit_role: 'warehouse_manager'` from the pack screen calls.
- Use `CREATE OR REPLACE` with the identical signature. Never create an overload. Run the overload check after.
- For `receive_dispatch_line` and `return_dispatch_line`: insert the role check at the top only; the double-credit guard shipped on 5 Oct stays exactly as is (diff the body before and after and paste the diff in the log).
- Rollback file: the previous bodies of all 15 functions (from `pg_get_functiondef` before the change).
  Accept: a field_staff session calling `pack_dispatch_line` is denied; a warehouse session can pack; a field_staff session can receive a line; overload check clean.

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

Start from the item's findings in PRD-139-REPORT.md / PRD-139-log.md (re-checked in Step 0).
Facts: `v_machine_pack_status` (machine_id, dispatch_date, total_included, resolved, physical, not_filled, picked_up_physical, dispatched_physical, is_pack_complete, is_pickup_complete, is_dispatch_complete, pack_state, ...) is mostly right. Seen live: Packing said JET "Already dispatched", Dispatching "To dispatch 10/45", Trips "In progress"; HUAWEI "Completed, 6 lines" on Dispatching, "In progress, 8 lines" on Trips, listed on Pickup, while Home said "0 ready to collect".
Do:

- Fix the view: rows with `total_included = 0` are excluded (or flagged `no_plan`) so they never read as complete; `pack_state` = 'completed' when every included line is resolved (NOOK case). Keep the column list stable.
- Repoint these to the view (no local recomputation of done/ready): Home cards (Daily refills, Ready to collect, To dispatch), Packing list status chip, pack screen banner, Pickup list, Dispatching list and progress bar, Trips list chips.
- Definitions: Ready to collect = is_pack_complete AND NOT is_pickup_complete AND physical > 0. Pickup list shows only those. To dispatch = is_pickup_complete AND NOT is_dispatch_complete AND physical > 0. Pack screen banner when some lines are dispatched: "Dispatch in progress (10 of 45 dispatched), repack disabled for dispatched lines"; only say "Already dispatched" when is_dispatch_complete.
- Line counts shown next to a machine use `physical` (or `total_included` labelled as planned), the same number on every page.
  Accept: for today's date, Home, Packing, Pickup, Dispatching and Trips agree for every machine; HUAWEI not on Pickup; JET shows 10 of 45 everywhere.

### Item 6. POs: one header status

Start from the item's findings in PRD-139-REPORT.md / PRD-139-log.md (re-checked in Step 0).
Facts: 31 POs have an unreceived line; 29 of them only have `not_purchased` lines left; 2 are truly open. Home "Open orders", the Receiving list and Tasks use "any line with received_date null".
Do:

- Create `v_po_header` (po_id, po_number, supplier_id, purchase_date, lines, ordered_qty, received_qty, open_lines, cancelled_lines, received_lines, status) with: Cancelled = all lines not_purchased; Pending = open_lines > 0 and received_lines = 0; Partial = open_lines > 0 and received_lines > 0; Closed short = open_lines = 0 and received_lines > 0 and cancelled_lines > 0; Received = open_lines = 0 and cancelled_lines = 0. Open line = `purchase_outcome IS NULL AND received_date IS NULL`.
- Repoint: Home "Open orders" (count Pending + Partial), Home "Received today" (count distinct POs received today, not lines), `/field/receiving` list (Pending + Partial only, sorted by purchase_date desc), `/field/orders` Pending and All tabs (status pill from the view), Tasks "Collected" vs PO state (show the view status next to the task), and any desktop Procurement count that uses the same rule (search for it; log what you changed).
- Make sure `cancel_po_line` leaves a state the view reads as Cancelled (no extra column needed if `not_purchased` is the cancel outcome; verify).
  Accept: Home shows 2 open orders; Receiving lists 2 POs; Orders All shows UC1003B as Closed short; no cancelled PO appears in Receiving.

### Item 7. Dispatch Detail Save

Start from the item's findings in PRD-139-REPORT.md / PRD-139-log.md (re-checked in Step 0).
Facts: `src/app/(field)/field/dispatching/[machineId]/page.tsx` save loop continues past per-line RPC errors and then shows the green summary built from local intent (around :819-825); `addedCount` counts intent.
Do: collect a result per line (ok / error message). Summary counts only confirmed writes. If any line failed: red banner listing each failed line (product, shelf, error), keep those lines editable, keep Save enabled for retry; never show the green "all added" state. Also pass the Dubai date explicitly to `insert_driver_remove_line` (it defaults to UTC CURRENT_DATE).
Accept: forcing one RPC to fail in a dev test shows the red banner with that line and a correct count; successful lines are not re-sent on retry.

### Item 8. Machine photos

Facts: no storage buckets exist; `dispatch_photos` has 0 rows; upload errors are swallowed (`catch {}` around :481-483 of the dispatch page).
Do: migration creating private bucket `dispatch-photos` with storage policies: authenticated INSERT and SELECT for field_staff, warehouse and admin roles, path `<machine_id>/<dubai_date>/<before|after>-<uuid>.jpg`; no anon access; no public URLs (use signed URLs where the page shows the photo). Replace the silent catch with a visible error on the tile ("Photo not saved, tap to retry"). Do not create `machine-issues` (its page is to be removed in a later PRD).
Accept: a test upload creates an object and a `dispatch_photos` row; the tile shows the image via a signed URL; with storage blocked the tile shows the error.

### Item 9. Pack screen

Start from the item's findings in PRD-139-REPORT.md / PRD-139-log.md (re-checked in Step 0).
Facts: `src/app/(field)/field/packing/[machineId]/page.tsx` "Mark all as packed" (around :1579-1602) overwrites lines already Not filled, M2M legs and no-stock lines; Packed, Confirm removed, Confirm move and pick quantities are browser-only until Save or Finish.
Do:

- Mark all as packed only touches lines with no decided outcome and with picks available; it never changes Not filled, Skipped, M2M transferred or no-stock lines.
- Write each pack outcome when tapped (call `pack_dispatch_line` per line, same as Not filled and Skip already do), show the RPC error on the card if it fails. If a full immediate-write change is too big tonight, add instead a `beforeunload` and in-app Back guard ("You have N unsaved packs") and log that the immediate write is deferred.
- Remove the client-sent `p_edit_role` (see item 2B; skip if 2B already did it).
- The 7 duplicate "Skipped items" rows seen on JET (Hunter Canister 40G A09 x4, Plaay Truffle A16 x3): find why the list repeats (likely one row per batch or per dispatch row) and show one row per line.
  Accept: on a test machine, mark one line Not filled, press Mark all as packed, Finish: that line stays Not filled with no warehouse debit; leaving mid-pack either keeps the packs (immediate write) or warns.

### Item 10. Backlogs

Facts: 127 warehouse confirmations (oldest about 47 days), 11 pending pod edits (oldest 23 Sep), 8 unresolved `driver_feedback` rows from 20 May to 3 Jun still shown on Capture, 31 "To validate" rows on Machine Stock Expiry that are all 0 units.
Do (no stock writes):

- `driver_feedback` older than 30 days and unresolved: set resolved with note `auto-expired PRD-139`, so the Capture box clears. Add a nightly job doing the same.
- `pod_inventory_edits` pending older than 7 days: set status `expired` (status already exists), nightly job. Show the age on each card in Inventory Pending Reviews, oldest first.
- Warehouse Confirmations: sort oldest first, show an age badge (amber over 48 h, red over 7 days), and paginate (render the first 20 with "show more") so the batch list below is reachable.
- Machine Stock Expiry: "To validate" excludes 0-unit rows; exclude pseudo-machines `WH1-*`, `WH2-*` and `*_OLD` from default lists.
- Write `docs/prds/PRD-139-backlog-report.md` (refresh the counts from prod first; they were taken on 5 Oct): the 127 confirmations grouped by age bucket and source (machine, reason), so CS and the warehouse can clear them by hand.
  Accept: Capture shows 0 unlogged corrections; Pending Reviews shows only rows under 7 days; confirmations list loads with 20 cards and age badges.

### Phase 5. Gates (run before you stop, even if items are BLOCKED)

1. Overload check: no function in public has two signatures that make a named-arg call ambiguous.
2. Parity: repo migrations match prod `schema_migrations` (both directions).
3. Anon probe: with the anon key and no session, call 5 of the named writers and 2 random other SECURITY DEFINER writers: all denied. Re-run the baseline count query: report the number.
4. Role probes: field_staff cannot update its role (item 1 regression check), cannot open `/field/capture` or `/field/config`; warehouse cannot open `/field/config/sims` or read PUK columns or supplier bank details.
5. App smoke test as operator_admin, warehouse and field_staff (a test machine or a dry run that writes nothing to live stock): login, Home counts, Packing list, pack screen (pack, Not filled, Mark all), Pickup, Dispatch Detail (add, return, photo), Orders, Receiving list, Inventory, Config hub. Any failure: fix or roll back that item with its rollback file, and log it.
6. Final section of the report, written for CS (plain English, no em dashes): a table of items with status, migrations, commits; what changed on screen for each role; anything CS must do (Vercel deploy, manual clearing of the confirmations backlog using the backlog report); and what is left for a PRD-139c, if anything.
7. Delete `docs/prds/PRD-139b.lock`, commit "PRD-139b: release lock", push. Last line of the report: "## PRD-139b DONE".
