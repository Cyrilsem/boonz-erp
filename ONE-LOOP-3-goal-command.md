# ONE LOOP 3: the frontend, the picker, the rehearsal, the deploy

Paste everything below the line into Claude Code in `boonz-erp`, branch `overnight-2026-09-15-prd123-126`.

---

/goal

You are finishing the Boonz ERP overnight run on branch `overnight-2026-09-15-prd123-126`, Supabase project `eizcexopcuoycuosittm`. Read `IMPLEMENTATION-CHECKLIST-2026-09-15.md`, `DECISIONS-2026-09-15.md`, `OVERNIGHT-REPORT-2026-09-15.md`, then `ONE-LOOP-2-goal-command.md` for the standing rules, the canary and the four decisions. Two sessions have now left the same four things open. This session does only those four and finishes them.

## The permission you kept asking for

You left every frontend surface open because they are "live, driver-facing screens this session couldn't verify visually". CS is the owner of the app and he is telling you now: **you are authorized to change every screen in this repo, deploy it, and put it in front of the drivers and the warehouse today.** Verification for a frontend change is defined as: `tsc --noEmit` clean, lint clean, `npm run build` clean, and a rendered check of each changed component. For the rendered check, start the dev server, use Playwright with the Chromium already installed (`/opt/pw-browsers/chromium`, do not run `playwright install`), log in with the credentials in `.env.local` or the test account the repo's existing e2e setup uses, take a screenshot of each changed screen at phone width and desktop width, and save them under `docs/screens-2026-09-15/`. If no login route is reachable from Playwright, render the component in isolation with the repo's test runner and snapshot it. Either counts. "Could not verify visually" is not a sentence this session may write.

Nothing else from the last two runs is re-litigated. Do not re-read the PRDs beyond what the checklist points to. Do not re-prove backend blocks already marked DONE.

## Four jobs, in this order

**Job 1. The frontend, every open line.**

1. `RefillPlanningTab.tsx`: a Confirm and Build button on the pick list calling `confirm_and_build(p_plan_date, p_machine_names, p_cars)`, car split shown per machine from `car_no`. The draft view shows the `exceptions` array on top and the G2, G4, G9 flags per row. The Commit button keeps calling `commit_refill_plan_atomic` (the path you found is the real one); make sure that path and `approve_pod_refill_plan` cannot both push the same rows, and say in one line how.
2. `DailyDispatchingTab.tsx`: Mark All Dispatched calls `mark_dispatched` then `receive_all_dispatches_for_machine`; the RPC result is shown on the row, an error is shown as text.
3. `SnapshotTab.tsx`: `loadData` reads `get_machine_health_cached`, stamps `refreshed_at`; the refresh result reads `aisles` and `machines_covered`.
4. Field `[machineId]/page.tsx`: a return line with no reason disables Save with the label "Pick a reason on <shelf>" and scrolls the card into view.
5. Pack card, Change product dialog, Warehouse Inventory: the expiry-capture inputs calling `set_wh_batch_expiry` exactly as PRD-124 item 11 in `ONE-LOOP-2-goal-command.md` and the follow-up message in the checklist describe.
6. `WarehouseConfirmationsPanel.tsx`: the Split toggle calling `wm_confirm_line_split`, reusing the variant and expiry rows from `PendingRemoveApprovalsPanel.tsx`.
7. `StartInventorySessionBar.tsx` banner: "Press Start Inventory Control to confirm returns."
8. Substitution rules table under `/refill` settings: list, add, deactivate, backed by `substitution_rules`.
9. Machine Health card: `p_score_aed`, the three top contributors, `car_no`, sort by `p_score_aed`.
10. Procurement count and list from one query.

**Job 2. The picker.** PRD-126 R5 (`pick_machines_for_refill` v12 with `p_cars`, `p_per_car`, cluster fill, `car_no` on `machines_to_visit`), R6 (`get_machine_health` exposes `p_score_aed`, contributors, `car_no`), the 30-day backtest against `v_current_price_filled`, thresholds tuned and written to `pick_urgency_params`. A1 to A7 printed pass. The PRD-122 dead-branch comment block carried into v12.

**Job 3. The rehearsal.** Phase 10 of `ONE-LOOP-goal-command.md` for 2026-09-16, one transaction, rolled back, every step printed pass, canary checked after. Also run `align_pod_lots_to_weimi` dry on every `include_in_refill` machine and print the summary, since cron 77 runs it live at 22:00 UTC tonight.

**Job 4. Build, deploy, ledger.** `tsc --noEmit`, lint, `npm run build` clean. Reconcile the migration ledger: for every file in `supabase/migrations/` whose version is missing from `supabase_migrations.schema_migrations`, insert the ledger row with that version and name (the schema is already applied, the ledger is the only thing wrong), and for every ledger version with no file, write the file from the live function body; print the reconciled list. Push the branch, open a PR to the production branch, merge, wait for the Vercel deployment to reach ready, print the URL and status. Run `mcp__supabase__get_advisors` and fix findings on objects changed on 14 or 15 Sep. Rewrite the checklist with zero OPEN lines and the report with a section per job, commit, and write one `monitoring_alerts` row, source `overnight_2026_09_15_part3`, with the five-line note for CS.

Only then is the session finished.
