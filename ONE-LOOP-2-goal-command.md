# ONE LOOP 2: finish what the overnight run left open

Paste everything below the line into Claude Code in `boonz-erp`, on branch `overnight-2026-09-15-prd123-126`.

---

/goal

You are continuing the overnight run on the Boonz ERP, Supabase project `eizcexopcuoycuosittm`, branch `overnight-2026-09-15-prd123-126`. Read first, in this order: `IMPLEMENTATION-CHECKLIST-2026-09-15.md`, `DECISIONS-2026-09-15.md`, `OVERNIGHT-REPORT-2026-09-15.md`, then `ONE-LOOP-goal-command.md` for the standing rules and the canary, then the four PRDs it names. Every line marked OPEN in the checklist is your job. The session ends when the checklist has zero OPEN lines, the app is deployed, and the report is rewritten. Not before.

## What went wrong last time, and the rules that fix it

The last session stopped after 1 h 48 min with 27 open lines. It cited "remaining time" nine times. There was no time limit. There is none now. You have the whole day; CS presses Confirm and Build at 19:00 Dubai and everything must be live by 18:00 Dubai.

The last session also refused to touch `engine_add_pod` and `get_pod_refill_draft` because it had not read them. Read them now, in full, before anything else, and then change them. "I have not read it" is a reason to read, never a reason to skip.

The last session found four real problems and stopped at each one. The decisions are made below. Apply them, do not re-litigate them.

The checklist has exactly two allowed states: DONE with a proof, or SUPERSEDED because the requirement was already true on live data, with the query that proves it. OPEN is not a state you may leave a line in. "Not attempted", "given time", "FE not in scope", "needs Dara and Cody" are not allowed phrases in the final checklist.

Never ask. Never wait. On any conflict the PRDs do not settle, choose the doctrine-consistent option, log it in `DECISIONS-2026-09-15.md`, continue.

## Daytime rule

It is daytime in Dubai. The team is packing, driving and confirming returns against the 09-15 plan. Therefore, until 22:00 Dubai you may not alter these functions: `receive_dispatch_line`, `receive_all_dispatches_for_machine`, `driver_confirm_remove`, `return_dispatch_line`, `wm_confirm_line`, `mark_picked_up`, `skip_dispatch_line`, `cancel_dispatch_line`, `protect_packed_dispatch_row`, or anything the field app or the warehouse panels call today. New functions beside them are fine. Everything on the engine, picker, draft, validate, approve, push and confirm path is fine, nothing runs there until 19:00. The 09-15 canary fingerprint from the last run (using `dispatch_id`) must be unchanged at the end of every phase.

## The four decisions

**Price gap (blocks PRD-126 A3, A5, A6, A7).** 16.5 % of `v_current_price` rows have a NULL `effective_price_aed`. Build `v_current_price_filled`: for each machine and pod product, price = `effective_price_aed` when not null; else the realised unit price on that machine over the last 30 days from `v_sales_history_resolved` (amount over qty) when at least 3 units sold; else the fleet median `effective_price_aed` for that pod product; else the fleet median realised price; else 0 with `price_source = 'unpriced'`. Column `price_source` on every row. `v_machine_priority` and the backtest read the filled view. Write `docs/unpriced-lanes-2026-09-15.md` listing every lane still at `unpriced` with velocity at or above 1, sorted by velocity, for CS to fix in WEIMI. Then run A3, A5, A6, A7 and the backtest for real, tune the thresholds, write them to `pick_urgency_params`.

**Freakin Roasted.** Search `pod_products`, `product_name_conventions`, `weimi_product_alias` and `boonz_products` with `ilike '%freakin%'`. If the pod is "Freakin Healthy" with roasted flavours as boonz products, seed the D4 rule at that pod with the boonz ids. If there is no pod at all, create the `pod_products` row, the `product_name_conventions` row and the `product_mapping` rows mirroring the nearest sibling (omit `is_global_default`, it is generated), then seed. Log which case it was.

**The 76 rows dated 2029 or later.** `cancel_dispatch_line` cannot clear them (needs `dispatched=true`, refuses pinned rows). Build `reverse_cancel_dispatch_line(p_dispatch_id uuid, p_reason text, p_caller uuid, p_dry_run boolean DEFAULT true)`: allowed only when `packed=false AND dispatched=false`; clears `from_wh_inventory_id` and the breakdown (no warehouse stock moves, the stock never left), sets `cancelled=true`, `include=false`, writes the reason to the comment and an audit row, refuses any row not matching the guard. Add it to `enforce_canonical_dispatch_write`. Run it dry on all 76, print the table, then commit on all 76. Prove: zero rows dated 2029 or later remain, CENTRAL free stock for the 25 previously pinned products went up by exactly the released quantities.

**D1 inside `engine_add_pod`.** Keep the banded scoring for ordering. Replace only the quantity target: after the band computes its figure, `target := case when lane_velocity_30d >= hero_velocity_floor or source_of_supply contains 'venue_team' then max_stock_with_override else least(10, max_stock_with_override) end`, still clamped by `wh_available_for`. Nothing else in the function changes. Prove on a rolled-back rebuild of AMZ-1038 and ACTIVATE-2005 for 09-16: every seller lane at max, every venue lane at max, every slow lane at 10 or max.

## Accepted as superseded from the last run

Phase 1 proof on IFLYMCC A08 and MPMCC-1058 A02 via the 09-16 synthetic scenario (D-006). `v_live_shelf_stock`, `is_internal_move_dispatch`, `return_dispatch_line`, `receive_dispatch_line` already compliant (D-004, D-005). `_bind_tally` already `ON COMMIT DROP` (D-004b). `validate_refill_plan(..., 'plan_output')` vacuous on 09-12 and 09-15 (D-002). Mark those five lines SUPERSEDED with the decision id and move on.

## Order of work

**Block A, the 19:00 path (do this first, it is what CS presses tonight).**

1. Read `engine_add_pod` and `get_pod_refill_draft` in full. Apply D1 as above. Add G2, G4, G9 as boolean columns and the `exceptions` array (`no_rule_matched`, every gate failure, every WEIMI-vs-lot disagreement after alignment) to `get_pod_refill_draft`. Wire the scarce-stock rule (under 12 free fleet-wide, one lane only, the highest velocity) and the expired-on-shelf rule (Remove plus substitute on the same lane) into the engine allocation loop.
2. FE `RefillPlanningTab.tsx`: a Confirm and Build button that calls `confirm_and_build(date, names, cars)` with the car split shown per machine; the Commit button calls `approve_pod_refill_plan(date, names)` only, which now stitches and pushes, and the separate `stitch_pod_to_boonz` call is removed from the FE. Make `stitch_pod_to_boonz` return `already_stitched` instead of raising when it finds nothing pending, so nothing old breaks. The draft view shows the `exceptions` array on top and the G2, G4, G9 flags per row.
3. `/refill` pick list includes `'cs_added'` alongside `'picked'`. If the packing rows not showing on `/refill` had a different cause, fix it and say what it was.
4. Timings for `confirm_and_build`, `approve_pod_refill_plan`, `get_pod_refill_draft`, `validate_refill_plan`, `get_machine_health_cached` on production data. Anything over 5 s goes behind a `SECURITY DEFINER` wrapper with `SET statement_timeout = '120s'`.

**Block B, the picker.** Price fill as above, then PRD-126 R5 (`pick_machines_for_refill` v12 with `p_cars`, `p_per_car`, cluster fill, `car_no`), R6 (`get_machine_health` exposes `p_score_aed`, three top contributors, `car_no`; Machine Health card and sort), the backtest, the thresholds. A1 to A7 all printed pass.

**Block C, the team's screens.** `DailyDispatchingTab.tsx` Mark All Dispatched calls `mark_dispatched` then `receive_all_dispatches_for_machine`, result shown on the row, error shown as text. `SnapshotTab.tsx` `loadData` reads `get_machine_health_cached`, stamps `refreshed_at`, reads `aisles` and `machines_covered`. Field `[machineId]/page.tsx`: Save disabled with "Pick a reason on <shelf>" and the card scrolled into view when a return line has no reason. `StartInventorySessionBar.tsx` banner: "Press Start Inventory Control to confirm returns." Procurement count and list from one query, say which number was true. Substitution rules table under `/refill` settings: list, add, deactivate.

**Block D, PRD-123 in full.** `wm_confirm_line_split(p_line_id, p_splits jsonb, p_reason, p_caller, p_dry_run)`, variance recording, `wh_approved_at` stamped once, the Split toggle on `WarehouseConfirmationsPanel.tsx` reusing the variant and expiry rows from `PendingRemoveApprovalsPanel.tsx`. This is a new function beside `wm_confirm_line`, so it is allowed during the day. Dry-run replay of whichever of the eight 14 Sep lines are still open; print; do not re-confirm.

**Block E, hygiene.** The 76 junk rows as above. Migration window alert: pg_cron every 5 min writing `monitoring_alerts` `migration_in_window` when a row lands in `supabase_migrations.schema_migrations` between 06:00 and 22:00 Dubai, and today's own migrations are the first ones it should catch, which is correct and expected. Reconcile `supabase_migrations.schema_migrations` against `supabase/migrations/` and commit every missing file. `CHANGELOG.md` extended with everything this session writes.

**Block F, docs.** `docs/REFILL-DOCTRINE.md` (six decisions as they stand, D5 replaced by confirm-and-build, picker rules with the final thresholds, truth table, five gates, where the substitution rules live). `docs/boonz-master-3-SKILL-v4.md` with every RPC signature created or changed on 14 and 15 Sep with its exact argument list. `docs/REFILL-DAILY-LOOP.md` updated only if a button or RPC name changed. Regenerate TypeScript types into the path the repo uses.

**Block G, the rehearsal.** The Phase 10 full day for 2026-09-16 exactly as `ONE-LOOP-goal-command.md` states it, in one transaction, rolled back, canary checked after. Every step printed pass. If any step fails, fix the function and re-run the whole block from step 1.

**Block H, build and deploy.** `tsc --noEmit`, lint, `npm run build`, zero errors, no suppressions. Commit per block with messages starting `prd12x <block>:`. Push the branch, open a PR to the production branch, merge it, wait for the Vercel deployment to reach ready, print the URL and status. Run `mcp__supabase__get_advisors` for security and performance and fix every finding on an object created or changed on 14 or 15 Sep.

**Block I, the checklist and the report.** Rewrite `IMPLEMENTATION-CHECKLIST-2026-09-15.md` from scratch against the four PRDs line by line: DONE with proof or SUPERSEDED with query. Zero OPEN. If a line would be OPEN, go back and do it. Rewrite `OVERNIGHT-REPORT-2026-09-15.md`: one section per block, proof output, canary after each, the backtest table and thresholds, the timing table, the nineteen PRD-124 items each fixed or superseded, the decisions log, and the five-line note for CS: what he presses at 19:00, what changed on the pack screen, on the field app, on confirmations, and anything he must decide. Commit. Write one `monitoring_alerts` row, severity info, source `overnight_2026_09_15_part2`, payload the five-line note.

Only then is the session finished.
