# PRD-140 running log

Start: 2026-10-06T14:17:10Z. Lock taken cleanly on main (commit b2f7e42,
rebased after one benign push race onto a333f76). No competing PRD-140
loop found. PRD-139c's own loop had already finished and released its
lock before this one started (commit 3cf66f9), and a /logout
prefetch-prevention fix (6ae570d) landed on main between PRD-139c's close
and this loop's start. Both are observed, not touched.

## Step 0

### Hotfix checks

- `src/app/logout/route.ts`: ALREADY DONE. Returns 204 on
  `next-router-prefetch`, `purpose: prefetch`, `sec-purpose` (includes
  prefetch), `x-middleware-prefetch`, and `rsc` headers, before ever
  calling `supabase.auth.signOut()`.
- Sign out controls: ALREADY DONE. All three are plain `<a href="/logout">`,
  not `<Link>`: `src/app/(app)/sidebar-nav.tsx:285`, and
  `src/app/(field)/field/page.tsx:536` and `:1007` (the two Profile cards,
  WarehouseHome and OperatorAdminHome).
- Middleware admins-only config prefix: ALREADY DONE. `FIELD_ROUTE_RULES`
  in `src/middleware.ts` has exactly one admins-only config rule,
  `/field/config/product-naming` (FIELD_ADMIN_ROLES). `/field/config`
  itself (catching sims, suppliers, machines, boonz-products,
  product-mapping) is FIELD_WAREHOUSE_ROLES.

No fixes needed in Step 0.

### Discovered discrepancy (logged, not changed in Phase 1)

`src/app/(app)/sidebar-nav.tsx`'s `hiddenByRole` map has a `warehouse` key
(hiding Financials, Consumers, Performance, Lifecycle, SIM Cards, Sales
Pipeline, Settings, Inventory Sessions, Drift Monitor, Price Review),
implying warehouse is meant to see a partial `/app` sidebar. But
`src/middleware.ts`'s "Field-only roles" branch blocks `warehouse`
(alongside `field_staff`) from `/app`, `/portal`, and `/chat` entirely,
redirecting to `/field`. Warehouse cannot reach `/app` at all today; the
`hiddenByRole.warehouse` entries are unreachable dead configuration, not
a real permission. Per the hard rule "Phase 1 must change NOTHING," the
baseline table below treats warehouse as having zero `app.*` areas,
matching the actually-enforced behaviour (middleware), not the vestigial
sidebar map. Warehouse has 3 live users this morning; this is the one
place where guessing wrong would cost a real person a real screen, so the
stricter, currently-enforced reading wins.

### Baseline resolved access table (today, before any PRD-140 change)

Derived from `src/middleware.ts` (surface gate + `FIELD_ROUTE_RULES`,
which the file's own comment says is "the actual enforcement" for
`/field`; page-level `*_ROLES` arrays are UX only) and
`src/app/(app)/sidebar-nav.tsx`'s `hiddenByRole` (the only real signal for
`/app` sub-area intent, since middleware does not restrict operator_admin
/ manager / superadmin / finance within `/app` at all today).

Roles with a live user today: operator_admin, warehouse, field_staff.
manager, superadmin, finance have no live user; their rows are verified
by reading the source, not by a smoke test.

`app.*` areas (TRUE = resolved access today):

| area key               | superadmin                                                                                           | operator_admin | manager | warehouse | field_staff | finance |
| ---------------------- | ---------------------------------------------------------------------------------------------------- | -------------- | ------- | --------- | ----------- | ------- |
| app.dashboard          | T                                                                                                    | T              | T       | F         | F           | T       |
| app.refill             | T                                                                                                    | T              | T       | F         | F           | F       |
| app.driver_requests    | T                                                                                                    | T              | T       | F         | F           | F       |
| app.pods               | T                                                                                                    | T              | T       | F         | F           | F       |
| app.inventory          | T                                                                                                    | T              | T       | F         | F           | T       |
| app.products           | T                                                                                                    | T              | T       | F         | F           | T       |
| app.suppliers          | T                                                                                                    | T              | T       | F         | F           | T       |
| app.procurement        | T                                                                                                    | T              | T       | F         | F           | T       |
| app.price_review       | T                                                                                                    | T              | T       | F         | F           | F       |
| app.lifecycle          | T                                                                                                    | T              | F       | F         | F           | F       |
| app.performance        | T                                                                                                    | T              | T       | F         | F           | T       |
| app.financials         | T                                                                                                    | T              | T       | F         | F           | T       |
| app.consumers          | T                                                                                                    | T              | T       | F         | F           | F       |
| app.sales_pipeline     | T                                                                                                    | T              | T       | F         | F           | F       |
| app.sims               | T                                                                                                    | T              | T       | F         | F           | T       |
| app.inventory_sessions | T                                                                                                    | T              | T       | F         | F           | F       |
| app.wh_quarantine      | T                                                                                                    | T              | T       | F         | F           | F       |
| app.expiry_waste       | T                                                                                                    | T              | T       | F         | F           | F       |
| app.drift              | T                                                                                                    | T              | T       | F         | F           | F       |
| app.tracker            | not a role default for anyone; granted via `tracker_boonz_access` flag or owner email, same as today |
| app.settings           | T                                                                                                    | T              | F       | F         | F           | T       |
| app.settings.users     | T                                                                                                    | T              | F       | F         | F           | F       |

`field.*` areas (TRUE = resolved access today), from `FIELD_ROUTE_RULES`
(`FIELD_ALL_ROLES` = field_staff + warehouse + admins;
`FIELD_WAREHOUSE_ROLES` = warehouse + admins; `FIELD_ADMIN_ROLES` =
operator_admin/manager/superadmin only). finance has zero `/field`
access at middleware level (redirected to `/app`).

| area key                     | superadmin | operator_admin | manager | warehouse | field_staff | finance |
| ---------------------------- | ---------- | -------------- | ------- | --------- | ----------- | ------- |
| field.home                   | T          | T              | T       | T         | T           | F       |
| field.profile                | T          | T              | T       | T         | T           | F       |
| field.tasks                  | T          | T              | T       | T         | T           | F       |
| field.pod_inventory          | T          | T              | T       | T         | T           | F       |
| field.pickup                 | T          | T              | T       | T         | T           | F       |
| field.dispatching            | T          | T              | T       | T         | T           | F       |
| field.dispatching.pick       | T          | T              | T       | T         | F           | F       |
| field.trips                  | T          | T              | T       | T         | T           | F       |
| field.packing                | T          | T              | T       | T         | F           | F       |
| field.shelf_view             | T          | T              | T       | T         | F           | F       |
| field.not_filled             | T          | T              | T       | T         | F           | F       |
| field.capture                | T          | T              | T       | T         | F           | F       |
| field.orders                 | T          | T              | T       | T         | F           | F       |
| field.receiving              | T          | T              | T       | T         | F           | F       |
| field.inventory              | T          | T              | T       | T         | F           | F       |
| field.expiry                 | T          | T              | T       | T         | F           | F       |
| field.config                 | T          | T              | T       | T         | F           | F       |
| field.config.sims            | T          | T              | T       | T         | F           | F       |
| field.config.suppliers       | T          | T              | T       | T         | F           | F       |
| field.config.product_naming  | T          | T              | T       | F         | F           | F       |
| field.config.machines        | T          | T              | T       | T         | F           | F       |
| field.config.boonz_products  | T          | T              | T       | T         | F           | F       |
| field.config.pod_products    | T          | T              | T       | T         | F           | F       |
| field.config.product_mapping | T          | T              | T       | T         | F           | F       |

This table is the Phase 1 acceptance target (Item 1's resolver output must
equal it exactly) and the Phase 9 Gate 1 target (after item 7, same table
plus the two documented additions: app.settings.users already matches
above, so no addition needed there; app.tracker stays flag-driven).

### Live counts

`select role, count(*) from user_profiles group by 1`: field_staff 3,
operator_admin 2, warehouse 3. Matches the spec's expected baseline
exactly.

### Definer functions with no authenticated execute

Query: functions in `public` where
`has_function_privilege('authenticated', oid, 'EXECUTE')` is false.
Result: exactly the 14 named in the spec, confirmed by name:
`_mirror_po_addition_line_v1`, `_resolve_open_walkin_po_v3`,
`audit_log_write`, `auto_generate_refill_plan`,
`close_anon_definer_functions`, `prd114_golden_gate_tick`,
`procurement_price_sync_and_flag`, `refresh_fleet_data`,
`rename_machine_in_place_legacy`, `run_delivery_verification_alerts`,
`run_machine_health_integrity_check`, `run_weekly_miners_v3`,
`tg_mark_internal_move_pair`, `trigger_lifecycle_eval`. None are called
from `src` (grepped for each name against `.rpc(` and plain calls; zero
hits).

### Recent migrations

```
20261006090058  prd139c_2_revoke_dead_tables
20261006081718  prd139c_1_close_anon_definer_watchdog
20261006064323  prd139b_10_backlog_auto_expire
20261006063117  prd139b_8_dispatch_photos_bucket
20261006062029  prd139b_5_v_machine_pack_status
```

### Competing loop check

`git log --since="6 hours ago" --oneline origin/main` shows PRD-139c's own
loop completed and released its lock (commit 3cf66f9) before this loop's
lock commit (b2f7e42). One more commit landed after PRD-139c's release:
`6ae570d fix(auth): stop /logout firing on Link prefetch` (a different
session, same fix already covered by the Step 0 hotfix check above,
confirmed present). No PRD-139c lock or loop is currently active. Will
re-pull before each item per the hard rule.

## Item log

### Item 1: access catalog + resolver - BLOCKED (hard stop)

Fully designed and self-reviewed (Cody voice, Articles 2/3/12 plus this
loop's own stricter PUBLIC/anon revoke rule, all satisfied) before the
hard stop was reached:

- Five tables (access_areas, role_area_defaults, user_area_overrides,
  access_audit_log, access_internal_functions), RLS enabled on all five,
  SELECT-only policies, writes routed exclusively through four SECURITY
  DEFINER functions.
- access_areas seeded with the 22 app.* keys (sidebar_label copied byte for
  byte from sidebar-nav.tsx) and 24 field.* keys (route_prefix matching the
  real directory structure under src/app/(field)/field, confirmed by
  listing it, not assumed) named in the spec. No NavItem or field directory
  was found uncovered, so no additions were needed.
- role_area_defaults seeded to reproduce the Step 0 baseline table exactly,
  including the deliberate warehouse app.* = none choice over the sidebar's
  vestigial hiddenByRole.warehouse entry (logged above under Step 0).
- resolve_user_access(), has_area(), set_user_area_override(),
  clear_user_area_override(), and view v_my_access, each ending with
  REVOKE ALL ... FROM PUBLIC, anon; GRANT EXECUTE ... TO authenticated,
  service_role, per this loop's own hard rule.
- Rollback file drafted (drop the five tables, four functions, the view).

One `apply_migration` call was attempted and returned a transient tool
error ("Invalid or expired requestState"). Confirmed via direct query
that nothing was applied (`information_schema.tables` has no
`access_areas` row) - prod is untouched, zero live risk. Before retrying,
checked wall-clock time and found this session's real elapsed time had
reached 2026-10-07T05:57:51Z against a 2026-10-06T14:17:10Z start - past
both this loop's hard-stop thresholds (7 hours, and the 05:45 Dubai
cutoff, which the 7-hour cap reaches first from an 18:17 Dubai start).
Stopping here rather than applying a first migration after the hard stop
has already passed, per the loop's own rule to finish or roll back the
item in flight and write the report rather than continue.

The unapplied DRAFT migration and rollback files were deleted from the
working tree (never committed; this repo's own convention is that a
DRAFT_ file is renamed to its real timestamp only after a real apply, not
committed as a draft). The full SQL is preserved in this log's design
summary above and in the conversation transcript for the next PRD-140
session to reuse directly rather than redesign from scratch.

### Items 2 to 8 - BLOCKED (hard stop, not started)

The hard stop was reached during Item 1, before any of these began.
Nothing in the repo or in prod was touched for items 2 through 8.
