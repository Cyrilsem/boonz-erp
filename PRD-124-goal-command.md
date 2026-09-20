# PRD-124 — Claude Code prompts

Two sessions. Run Session 1 first, in `boonz-erp`. Session 2 after it lands.

---

## SESSION 1 — database

/goal

You are working on the Boonz ERP. Supabase project `eizcexopcuoycuosittm`. Repo root is the
`boonz-erp` checkout you are in. Read `PRD-124-refill-pipeline-stabilisation.md` in full
before you touch anything; section 3 is the defect list and section 4 is what "done" means.

Rules for the whole session: `mcp__supabase__apply_migration` for every DDL, one migration
file per item, named `prd124_<item>_<what>`. Never raw DDL through `execute_sql`. Every
destructive function takes `p_dry_run boolean DEFAULT true`. Impersonate Cyril
operator_admin `82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d` via
`set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true)`
in the SAME `execute_sql` call as any role-gated RPC. `execute_sql` returns only the LAST
statement's output. Never `select` from `product_mapping` joined to `warehouse_inventory`
without `distinct` on `boonz_product_id`; it fans out. WEIMI slot codes zero-pad, A1 is A01.

Baselines to capture before anything changes, and re-run after every item:

- `validate_refill_plan('2026-09-12', null, 'plan_output')` blocking count (53 today)
- `select count(*) from refill_dispatching where dispatch_date='2026-09-15'` (228 today)
- `select p_tier, count(*) from v_machine_priority group by 1` (14 P1, 1 P2, 17 P3 today)

Work in this order.

**1. Remove legs on the WEIMI shelf (#44).** In `push_plan_to_dispatch` and
`add_dispatch_row`, the Remove path sets `shelf_id = COALESCE(v_batch.lot_shelf_id, v_shelf_id)`.
Invert it: the shelf is the one the plan named (which came from WEIMI), the lot supplies
expiry and `pod_lot_id` only. When the lot's shelf differs from the plan's shelf, keep the
plan's shelf and append `[lot_shelf_mismatch: lot on <code>]` to `comment`. Prove it by
replaying the 09-15 IFLYMCC A08 and MPMCC-1058 A02 swaps inside a rolled-back transaction:
every Remove must land on A08 and A02.

**2. Engine sees the supplying warehouse (#45b).** `engine_add_pod` v15 and
`find_substitutes_for_shelf` v2 compute availability against WH_CENTRAL
`4bebef68-9e36-4a5c-9c2c-142f8dbdae85` only. Change availability to: for a pod product whose
Active mapping on this machine carries `source_of_supply = 'venue_team'`, sum stock at
WH_MCC `4fcfb52c-271f-4aa7-a373-3495e3271cd3` and WH_MM `0aef9ccf-32ad-4545-8413-29bebd931d0b`;
otherwise WH_CENTRAL. Prove by rebuilding the 09-15 draft for ACTIVATE-2005 in a rolled-back
transaction: zero `blocked_no_wh` on Aquafina.

**3. `source_kind` at push (#38, G8d).** `push_plan_to_dispatch` maps
`refill_plan_output.source_origin` to `refill_dispatching.source_kind`: `warehouse` to
`wh`, `vox_at_venue` to `venue`, `internal_transfer` to `m2m`. Backfill every 09-14 and
09-15 row that still reads `unknown` from its rpo parent. Then confirm
`validate_refill_plan('2026-09-15', null, 'dispatch')` raises no G8 on any `venue` row.

**4. G1 agrees with the engine.** In `validate_refill_plan`, G1 stays `blocking` when the
lane's `daily_velocity < 3` (read `v_machine_velocity` or the lane grain), becomes
`warning` at or above, and is skipped entirely for `is_venue` rows, the same exemption G8
already has. State the new 09-12 and 09-15 counts in the report.

**5. P1 velocity gate (#45a).** In `v_machine_priority`, the three hard triggers
(`holes_total >= p1_holes_min`, `empty_ab_count >= p1_empty_ab_min`,
`days_since_visit > stale_override_days`) promote to P1 only when the machine's
`daily_velocity >= 3`. Below that they promote to P2. Prove: GRIT-1022 is P2, AMZ-1038 is
P1, and the total P1 count drops from 14 with the list of who moved.

**6. G5 two-level.** Blocking when no Active mapping exists at all for that
`boonz_product_id`; warning when only a global row exists and no machine-specific one.
Report the 09-12 count under the new rule.

**7. Cron 13 builds anyway.** At 19:00 Dubai, `cron_refill_pick_notice()` writes a
`monitoring_alerts` row listing the picked machines for `resolve_refill_plan_date()`. At
20:00, `build_draft_for_confirmed_v3` runs with the manual gate; if `confirmed_now = 0` it
runs `_build_draft_core_v3(date, false, true)` anyway and tags every draft row's reasoning
with `unconfirmed_picks: true`. The FE draft header must be able to read that flag.

**8. `_bind_tally` (#39).** In `push_plan_to_dispatch_v16`, `DROP TABLE IF EXISTS _bind_tally`
before create, or create it `ON COMMIT DROP`. Prove by pushing the same machine twice in one
session with zero warnings.

**9. Junk 2030 rows (#41).** For every `refill_dispatching` row with `dispatch_date >= 2029-01-01`:
release any `from_wh_inventory_id` pin (the two live ones first, name them), then cancel
through the canonical route. Dry run first, print the 76 rows, then commit. The pending
WH-approval queue must show only 2026 rows afterwards.

**10. Drift report.** New view `v_pod_weimi_drift`: one row per machine and shelf where the
latest WEIMI pod product differs from the `pod_inventory` Active lot's pod product, with
both names and both stocks. New RPC `get_pod_drift_summary()` returning per-machine counts,
added to `app_cache` on the same 2-minute cron as `machine_health`. Do **not** call
`resync_pod_inventory_from_weimi` anywhere.

**11. Ghost stock.** Quarantine the Dubai Popcorn rows in WH_CENTRAL (Butter 2, Salted 3)
with reason `ghost per CS 14 Sep, physically zero`. Do not delete. They resolve at
`apply_warehouse_audit`.

**12. Migration window alert.** A pg_cron job every 5 minutes: if a row exists in
`supabase_migrations.schema_migrations` with `version` newer than the last checked and the
current Dubai time is between 06:00 and 22:00, raise a `monitoring_alerts` row of type
`migration_in_window` with the migration name. Then reconcile `supabase_migrations` against
`supabase/migrations/` on disk and commit every missing file with its original content
(pull it from `pg_get_functiondef` / `pg_get_viewdef` where the file is lost).

**13. `CHANGELOG.md`** at repo root. One line per migration applied since 12 September,
oldest first: date, time Dubai, name, one sentence, who asked. Include today's six
`prd122lgp` migrations and every one this session writes.

Report: one page. Per item, what changed, the proof, the three baseline numbers after it.
Flag anything weaker than specified rather than reporting it done.

---

## SESSION 2 — frontend

/goal

You are working on the Boonz ERP frontend in `boonz-erp`. Read
`PRD-124-refill-pipeline-stabilisation.md` section 3, table "Screens". Session 1 has
landed; `mark_dispatched` may or may not exist, check `pg_proc` first.

Surgical changes only. Do not refactor. Every change gets a Playwright check where one is
feasible, using the pre-installed Chromium.

**1. Mark All Dispatched (#35).** `src/app/(app)/refill/DailyDispatchingTab.tsx`,
`handleBulkUpdate`, branch `field === "dispatched"`. If `public.mark_dispatched(uuid[])`
exists, call it with every included, packed, picked-up line for the machine, then call
`receive_all_dispatches_for_machine` as today. If it does not exist, create it as a
migration mirroring `mark_picked_up` (flips `dispatched = true` only on rows with
`picked_up = true`, returns the ids it refused). Surface the RPC result on the row, not in
`console.error`. Prove on a machine at P n/n, U n/n, D 0/n.

**2. Refresh updates the cards (#42).** `src/app/(app)/refill/SnapshotTab.tsx`, `loadData`.
Replace the live `get_machine_health` call with `get_machine_health_cached` and stamp
`healthAsOf` from its `refreshed_at`. Fix the result-shape drift in the refresh panel:
`result.aisle` is `result.aisles`; `result.machines_online / machines_total` is
`result.machines_covered`. Prove: after Refresh, a card changes within 5 seconds, and the
"Machines" tile shows a number.

**3. Field Save notice.** `src/app/(field)/field/dispatching/[machineId]/page.tsx`. When
`missingReturnReason.length > 0`, scroll the first offending card into view and set the
Save button label to "Pick a return reason on N line(s)" with the button disabled. Never
return silently.

**4. /refill vs /field (#37).** Find the query behind the packing view on /refill and the
one behind /field. If /refill filters `machines_to_visit.status = 'picked'`, include
`'cs_added'`. If the cause is different, say what it was.

**5. Procurement 21 vs 3 (#36).** Find the count and the list. Make the list's query feed
the count. State which number was true.

**6. Inventory-control banner.** `src/components/inventory/StartInventorySessionBar.tsx`.
Rewrite the copy as an instruction: "Press Start Inventory Control to edit quantities.
Every change is logged." Keep the button.

Report: per item, what changed, the proof, and anything weaker than specified.
