# PRD-139c FINAL: status report

Started 2026-10-06T08:06:57Z. Single session, lock taken cleanly on `main`
after confirming no competing PRD-139 loop was running (`git log
--since="3 hours ago"`). Full detail, evidence, and Cody verdicts for every
item are in `docs/prds/PRD-139c-log.md`.

## Item status

| Item | Status | What changed                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ---- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | DONE   | `ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin` confirmed still permission-denied for `postgres` in this managed project, matching the PRD-139b finding exactly. Built the documented fallback: `close_anon_definer_functions()`, a `SECURITY DEFINER` watchdog (owner postgres, no execute for anon/authenticated) that revokes anon EXECUTE on every public `prosecdef` function anon can reach and logs one `monitoring_alerts` row per function closed, scheduled every 15 minutes via pg_cron. Extended the existing nightly drift check `check_ambiguous_function_overloads()` to also report and alert on `anon_executable_definer_count`. |
| 2    | DONE   | Grepped `src/` and `supabase/functions/` for all 7 named tables; found zero live reads of any of them, including `weimi_product_alias`, so all 7 are revoked rather than RLS-gated. Found `authenticated` held full read-write-delete-truncate on all 7 (worse than the anon-SELECT-only description) and closed both in one `REVOKE ALL FROM anon, authenticated`. No tables dropped.                                                                                                                                                                                                                                                               |
| 3    | DONE   | Home's "Daily Refills" (packed/picked up/dispatched) and the admin "Ready to collect" / "To dispatch" cards no longer re-derive stage completion locally. Both the warehouse/admin and driver branches of `src/app/(field)/field/page.tsx` now read `v_machine_pack_status` directly for today, the same object Packing, Pickup, and Dispatching already read from.                                                                                                                                                                                                                                                                                  |
| 4    | DONE   | The pack detail screen's in-app Back link can now cancel navigation when there are unsaved pack decisions, showing "You have N unsaved packs. Leave anyway?" via a new optional `onBackAttempt` prop on the shared `FieldHeader` component (no-op everywhere else).                                                                                                                                                                                                                                                                                                                                                                                  |
| 5    | DONE   | Machine Stock Expiry's "To validate" pill (which is entirely 0-unit ghost rows by definition) now hides its rows by default, with a "Show 0-unit rows" toggle to reveal them. The pill's own badge count is unaffected by the toggle; a dedicated empty-state message explains the hidden rows instead of the misleading generic "all clear" text.                                                                                                                                                                                                                                                                                                   |

Items 1 and 2 (the only items touching the database) each have a migration
in `supabase/migrations/` applied to prod with a matching timestamp, a
rollback file in `supabase/rollbacks/`, and an inline Cody review performed
before applying. Items 3, 4, and 5 are pure FE changes with no DB migration,
no Cody review, and no rollback file, per the spec's own Cody+rollback
requirement naming only items 1 and 2.

## Accept criteria

1. **Anon definer count stays 0 after a test function + one cron cycle,
   then cleanup.** PASS. Created a throwaway `SECURITY DEFINER` function
   (`prd139c_test_anon_definer`), confirmed anon could execute it, ran
   `close_anon_definer_functions()` directly as one watchdog cycle,
   confirmed anon access was revoked and the count returned to 0, confirmed
   a `monitoring_alerts` row was logged for the closed function, then
   dropped the test function. Re-verified at the end of the loop: anon
   definer count is 0, the watchdog cron job is active (job id 87, every 15
   minutes).
2. **Anon SELECT denied on all 7 tables.** PASS. Re-verified at the end of
   the loop: `has_table_privilege('anon', ..., 'SELECT')` is false on all 7.
3. **Home counts equal Pickup/Dispatching counts for today.** PASS. Both
   Home branches and the Pickup/Dispatching pages now read the same
   `v_machine_pack_status` booleans (`is_pack_complete`, `is_pickup_complete`,
   `is_dispatch_complete`) for the same `dispatch_date`, so they move
   together by construction. Cross-checked live: 8 machines with
   `total_included > 0` today, matching a plain distinct-machine count over
   `refill_dispatching` with `include=true` and `cancelled=false`.
4. **Smoke test as operator_admin, warehouse, field_staff (Home, Packing,
   pack screen Back, Dispatching, Expiry, Config) passes.** PASS at the
   privilege/query level, the same methodology PRD-139b used (no browser
   session with valid credentials was available in this session to drive a
   live click-through). For each of the three real test accounts, verified
   via rolled-back transactions that every key read each role's screens
   depend on succeeds without a permission error: `v_machine_pack_status`,
   `v_dispatch_pack_progress`, `warehouse_inventory`, `v_po_header`,
   `purchase_orders`, `pod_inventory`, `pod_inventory_edits`, `po_additions`,
   `boonz_products`, `pod_products`, `suppliers`, `product_mapping`,
   `machines`, `sim_cards`, `refill_dispatching`, `driver_tasks`. warehouse
   correctly sees 0 `sim_cards` rows (unchanged from PRD-139b, not a
   regression introduced here). The pack screen's in-app Back guard (Item 4)
   is pure client-side logic with no DB read; verified by code trace plus
   `npx tsc --noEmit` and `npx eslint` on the modified file, both clean.

## For CS, in plain English

- **Everyone**: a background job now runs every 15 minutes and automatically
  locks down any new backend function that gets accidentally exposed to
  anonymous users, closing the gap left over from PRD-139b. The nightly
  overload check now also watches this.
- **Everyone**: six old backup tables and one unused product-alias table can
  no longer be read or written by anyone except the database owner. None
  were deleted.
- **Warehouse and admin roles on Home**: "Daily Refills," "Ready to
  collect," and "To dispatch" now always agree with Packing, Pickup, and
  Dispatching, because they read the exact same object.
- **Drivers on the Pack screen**: tapping the in-app Back link with unsaved
  pack decisions now asks "You have N unsaved packs. Leave anyway?" before
  leaving, the same way closing the tab already did.
- **Everyone on Machine Stock Expiry**: the "To validate" list (0-unit ghost
  rows needing a physical check) is now hidden by default with a "Show
  0-unit rows" toggle to reveal it, instead of always being shown. The pill
  count itself is still always visible.

**What CS should do:**

1. Nothing to deploy by hand. This repo auto-deploys to production on every
   push to `main` (see `docs/DEPLOYMENTS.md`); every commit in this loop
   already triggered its own production deploy, and the DB changes were
   already live the moment each migration was applied.
2. No open decisions or spec conflicts from this loop. Item 5's conflict
   from PRD-139b is resolved per your own instruction in this spec (toggle,
   not exclusion).
3. Still owed from before PRD-139/139b/139c (out of scope for all three):
   list which real people have used the "Test Driver" (7f4ecaa4) and "Test
   Warehouse" (bf32624e) test accounts in the last 30 days, so they can be
   moved to personal logins.

## PRD-139c DONE
