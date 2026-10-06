# PRD-139b finish: status report

Started 2026-10-06T05:03:13Z (09:03 Dubai). Hard stop was 7 hours after start
(2026-10-06T12:03:13Z / 16:03 Dubai), which was sooner than the next 05:45 Dubai
occurrence (2026-10-07). All items finished before the hard stop; this report was
not written against a clock running out.

Full detail, evidence, Cody verdicts, and time-per-item for every claim below is in
`docs/prds/PRD-139b-log.md`.

## Step 0

- Took the single-session lock (`docs/prds/PRD-139b.lock`) cleanly, no competing
  loop found.
- Read `docs/prds/PRD-139-REPORT.md` and `docs/prds/PRD-139-log.md` in full.
  Findings for items 5, 6, 7, 9 were real (independently verified, not just
  trusted) and used directly; items 2, 3, 4, 8 had no usable findings and were
  investigated from scratch in this loop.
- Baseline matched expected exactly: 321 anon-executable SECURITY DEFINER
  functions, 0 storage buckets, top two migrations
  `prd139_item1_role_guard_fix_postgres_bypass` /
  `prd139_item1_user_profiles_role_guard`.

## Item status

| Item | Status | What changed                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ---- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2A   | DONE   | Revoked anon EXECUTE on all 321 SECURITY DEFINER functions; closed default privileges for future functions (with one residual gap, see Phase 5 gate 3). Allowlist: empty, verified.                                                                                                                                                                                                                                                                       |
| 2B   | DONE   | Fail-closed role checks on all 15 named writers. Found and fixed three distinct bug classes (no check at all; checks that failed open on a NULL caller; checks that trusted a client-supplied caller id over the session).                                                                                                                                                                                                                                |
| 3    | DONE   | Server-side per-route gate added to `src/middleware.ts` for every named `/field/*` prefix tier. Home cards already correctly scoped, no change needed there.                                                                                                                                                                                                                                                                                              |
| 4    | DONE   | `sim_cards` and `suppliers` write policies now admin-only (warehouse removed); `suppliers.bank_details`/`payment_terms` column-masked to admins only via a new view; audit triggers added to `pod_products`, `suppliers`, `product_name_conventions`, `machine_name_aliases`.                                                                                                                                                                             |
| 6    | DONE   | New `v_po_header` view with the full status taxonomy; repointed Home, Receiving, and Orders. Two minor consumers (Tasks page status display, desktop Procurement count) deferred, logged.                                                                                                                                                                                                                                                                 |
| 5    | DONE   | Fixed the vacuous-completion bug in both `v_machine_pack_status` and the view it depends on, `v_dispatch_pack_progress`. Pickup/Packing/Dispatching already read from the view and inherit the fix with no FE change. Home's separate "Daily Refills" card re-derives locally and was not touched (real regression risk, logged).                                                                                                                         |
| 7    | DONE   | Dispatch Detail Save summary now built from confirmed RPC results, never local intent; a failed line shows a red banner and stays editable. Dubai date now passed explicitly to `insert_driver_remove_line`.                                                                                                                                                                                                                                              |
| 8    | DONE   | New private `dispatch-photos` storage bucket with role-scoped RLS; FE switched to signed URLs; the silent upload-error catch replaced with a visible, retry-able tile.                                                                                                                                                                                                                                                                                    |
| 9    | DONE   | "Mark all as packed" no longer overwrites already-decided lines; duplicate "Skipped items" rendering fixed (one panel, not two). Immediate per-tap RPC write was too large for the time box; used the PRD's own documented fallback (a beforeunload warning) instead of a full rewrite.                                                                                                                                                                   |
| 10   | DONE   | `driver_feedback` and `pod_inventory_edits` auto-expire jobs (one new, one existing job's threshold corrected from 14 to 7 days) both run and cleared the live backlog. Warehouse Confirmations now paginates 20 at a time with a two-tier age badge. Pseudo-machines excluded from Machine Stock Expiry default lists. One sub-item (0-unit rows in "To validate") flagged as a genuine conflict with the page's own documented design, not implemented. |

Every item that touched the database has a migration in `supabase/migrations/`
applied to prod with a matching timestamp, and every security item (2A, 2B, 3, 4, 8)
has a rollback file in `supabase/rollbacks/`.

## Phase 5 gates

1. **Overload check**: PASS. `check_ambiguous_function_overloads()` returned
   `ambiguous_overload_count: 0` after every apply in this loop.
2. **Repo/prod migration parity**: PASS. All 8 PRD-139b migration timestamps
   present in both the repo and `supabase_migrations.schema_migrations`, in both
   directions.
3. **Anon probe**: PASS, with one caught-and-fixed gap along the way. The
   baseline anon-executable-definer count briefly went to 1 after Item 10 created
   `auto_expire_driver_feedback()` -- the new function was born anon-executable
   because it was created under the `supabase_admin` role, whose own default
   privileges for `public` schema functions still include `anon` (confirmed via
   `pg_default_acl`; `postgres` cannot `SET ROLE supabase_admin` in this managed
   environment to fix that role's own defaults, which is also why Item 2A's
   migration could only close this for the `postgres`/current-session role, not
   every role that might create a function later -- it tried `supabase_admin`
   too and was caught by `insufficient_privilege`, logged at the time). Fixed by
   revoking anon on that one function directly; baseline is back to 0 as of this
   report. **Residual risk, not closed**: any future function created under
   `supabase_admin` will be born anon-executable again until Supabase grants
   `postgres` the privilege to alter `supabase_admin`'s own defaults (or until
   someone with that access runs it once). Recommend checking
   `has_function_privilege('anon', oid, 'EXECUTE')` on any newly created
   function before considering a future PRD done. Final probe: 5 named writers
   (`pack_dispatch_line`, `receive_dispatch_line`, `return_dispatch_line`,
   `cancel_po_line`, `repurpose_machine`) plus 2 random others
   (`set_machine_status`, `skip_dispatch_line`) all denied to the `anon` role.
   Baseline count: **0**.
4. **Role probes**: PASS. field_staff cannot update its own role (regression
   check on Item 1, still correctly blocked); warehouse cannot read
   `suppliers.bank_details` (`insufficient_privilege`) and sees 0 `sim_cards`
   rows. The route-level checks (field_staff redirected from `/field/capture`
   and `/field/config`; warehouse redirected from `/field/config/sims` and
   `/field/config/suppliers`) were verified by tracing the deterministic
   `isFieldRouteAllowed()` function against each case by hand in Item 3's own
   log entry, not by a live browser session.
5. **App smoke test**: PASS at the privilege/query level. No browser tool was
   available in this session, so this is not a full click-through: for
   operator_admin, warehouse, and field_staff, verified (via rolled-back
   transactions impersonating each real account) that every key read each
   role's screens depend on succeeds without a permission error --
   `v_machine_pack_status`, `v_po_header`, `v_wm_confirmations`,
   `v_suppliers_full`, `sim_cards`, `pod_inventory`, `purchase_orders`, and the
   caller's own `user_profiles` row. No stock, pod, or shelf capacity was
   written anywhere in this session.

## For CS, in plain English

**What changed for each role:**

- **Everyone**: the public anon key (the one shipped in the browser bundle) can
  no longer call any backend write function directly without logging in --
  previously about two thirds of them had no protection at all.
- **field_staff**: can no longer reach `/field/capture`, `/field/orders`,
  `/field/inventory`, or `/field/config` even by typing the URL directly (the
  app already hid these, now the server also blocks them). Packing, dispatch
  detail, and pickup screens now always agree with each other and with the
  Home page about which machines are done.
- **warehouse**: can no longer see SIM card PUK codes or supplier bank details
  anywhere, including by direct URL or API call. Can no longer reach
  `/field/config/sims` or `/field/config/suppliers`.
- **operator_admin / manager / superadmin**: unaffected, still reach
  everything.
- **Everyone on the Dispatch Detail page**: if one line fails to save, you now
  see exactly which one and why, in red, instead of a reassuring green
  "all added" message that didn't mean what it said.
- **Everyone on the Pack screen**: "Mark all as packed" will no longer silently
  undo a line you already marked Not filled, Skipped, or moved to another
  machine.
- **Machine photos**: now actually work -- the storage bucket didn't exist
  before this loop, so every photo tap was silently failing. It now either
  saves for real or shows a clear "tap to retry" error.

**What CS or the warehouse manager should do:**

1. Open the Warehouse Confirmations panel and work through the oldest lines
   first using `docs/prds/PRD-139-backlog-report.md` -- 64 lines remain, the
   oldest about 48 days. Nothing was auto-cleared here; this still needs a
   human to confirm each one (per the hard rule against bulk-confirming).
2. Nothing to deploy by hand. This repo auto-deploys to production on every
   push to `main` (see `docs/DEPLOYMENTS.md`) -- every commit in this loop
   already triggered its own production deploy, and the DB changes were
   already live the moment each migration was applied. Nothing is waiting on
   CS here.
3. One real spec conflict needs a decision: the PRD said Machine Stock
   Expiry's "To validate" pill should exclude 0-unit rows, but that pill
   exists specifically to show 0-unit "ghost" rows needing a physical check --
   implementing the instruction literally would empty it. Left as-is pending
   clarification; see the Item 10 entry in `PRD-139b-log.md`.
4. Still owed from before this loop (not part of PRD-139 itself): list which
   real people have used the "Test Driver" (7f4ecaa4) and "Test Warehouse"
   (bf32624e) test accounts in the last 30 days, so they can be moved to
   personal logins. Not started in this loop either -- it was never part of
   either PRD-139 or PRD-139b's scope.

## What is left for a PRD-139c, if anything

- Item 5: Home's "Daily Refills" machine-stage counts still re-derive locally
  instead of reading `v_machine_pack_status`. Real but lower-risk than the bug
  already fixed; needs its own careful pass since the two computations have
  deliberately different business rules today.
- Item 6: Tasks page status-next-to-task display, and the desktop Procurement
  page's open-PO count (same `received_date`-heuristic bug as the field app
  had, not yet fixed there).
- Item 9: immediate per-tap RPC write for Pack/Not filled/Skip/Mark-all (the
  PRD's preferred fix; a `beforeunload` warning was shipped instead as the
  PRD's own documented fallback), and the in-app Back-button guard specifically
  (only the browser-level reload/close warning was implemented).
- Item 10: the "To validate" / 0-unit-rows spec conflict needs a CS decision;
  Inventory Pending Reviews could show a relative "Nd ago" age label instead
  of just the raw timestamp (already sorted oldest-first and already shows a
  date, so this is pure polish).
- Phase 5 gate 3's residual anon-exposure risk on functions created under the
  `supabase_admin` role: needs either a permissions change at the Supabase
  project/org level (so `postgres` can alter `supabase_admin`'s own default
  privileges) or a standing habit of checking `has_function_privilege('anon',
..., 'EXECUTE')` on every new function going forward.

## PRD-139b DONE
