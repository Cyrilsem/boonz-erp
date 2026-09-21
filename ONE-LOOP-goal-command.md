# ONE LOOP: all PRDs, no stops, proven end to end

Open Claude Code in `boonz-erp`, paste everything below the line. Nothing else is needed.

---

/goal

You are working on the Boonz ERP. Supabase project `eizcexopcuoycuosittm`. Repo root is the `boonz-erp` checkout you are in. Six files sit in the repo root: `PRD-125-one-path.md`, `PRD-125-goal-command.md`, `PRD-126-picker-brain.md`, `PRD-124-refill-pipeline-stabilisation.md`, `PRD-124-goal-command.md`, `PRD-123-warehouse-return-splits.md`, `PRD-123-goal-command.md`, plus `docs/REFILL-DAILY-LOOP.md`. Read all of them in full before writing a single line. Then build every requirement in them, in the phase order below, in this one session, until every requirement is proven and the final checklist has no open line.

## Rule zero: you do not stop

This session runs unattended overnight. CS is asleep. Therefore:

- Never ask a question. Never wait for confirmation. Never pause between phases.
- The PRD goal-command files contain lines like "STOP HERE. Wait for CS." Those lines are void for this session. Read past them.
- When two documents disagree, PRD-125 wins over PRD-124, PRD-126 wins over PRD-124, and this prompt wins over all of them. PRD-125 D5 is replaced by Phase 6 below: CS keeps the manual pick gate, there is no automatic build.
- When a decision conflicts with the schema in a way the PRDs do not settle, choose the option that keeps the doctrine (WEIMI is the shelf truth, pod_inventory is expiry only, stock is read at the supplying warehouse, sellers fill to capacity, five gates, CS confirms picks). Write the choice and the reason to `DECISIONS-2026-09-15.md` in the repo root, and continue.
- If a phase breaks the canary (below), roll that phase's migration back, fix it, re-run it, re-prove it. Do not skip the phase. Do not move on with a broken canary.
- If a proof fails, the phase is not done. Fix and re-prove. A phase is done only when its proof prints pass.
- Your session ends when Phase 12's checklist has zero open lines and the report is written. Not before.

## Standing rules for the whole session

- `mcp__supabase__apply_migration` for every DDL and every function change. One migration file per phase, named `prd12x_p<n>_<what>`. Never raw DDL through `execute_sql`. Every migration is also written into `supabase/migrations/` with the same name and committed.
- Impersonate Cyril operator_admin `82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d` via `set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true)` in the SAME `execute_sql` call as any role-gated RPC. `execute_sql` returns only the LAST statement's output; a failing statement aborts the batch; temp tables do not survive across calls.
- `product_mapping` joined to `warehouse_inventory` fans out; always `distinct` on `boonz_product_id`.
- WEIMI slot codes zero-pad, A1 is A01. `machines.official_name` is the name. `refill_dispatching` has `shelf_id`, join `shelf_configurations`.
- WH ids: CENTRAL `4bebef68-9e36-4a5c-9c2c-142f8dbdae85`, MCC `4fcfb52c-271f-4aa7-a373-3495e3271cd3`, MM `0aef9ccf-32ad-4545-8413-29bebd931d0b`.
- Every destructive or writing function you create takes `p_dry_run boolean DEFAULT true`.
- The `authenticated` role runs with `statement_timeout = 8s`. Every function the FE calls must return under 5 s on production data, or sit behind a `SECURITY DEFINER` wrapper with its own `SET statement_timeout = '120s'`. Measure each one and print the timing.
- Every proof runs inside a transaction you roll back, or against a date that has no live rows (2026-09-16 or later).
- Keep the packed-row guard, the conservation trigger, the canonical-writer allowlist and the slot guard. You are removing G1, G2, G4, G6, G9 from `validate_refill_plan` and the waiver argument from `approve_refill_plan`. You are not removing any other guard.
- No em dashes in any file, comment, alert text or commit message.

## The canary and the baselines

**The 2026-09-15 plan is live and packed. Not one row of it may change.** Capture first, re-run after every phase, print in the report:

```sql
select count(*) as rows_0915, count(*) filter (where packed) as packed_0915,
       md5(string_agg(id::text || quantity::text || shelf_id::text || coalesce(include,true)::text, ',' order by id)) as fingerprint_0915
from refill_dispatching where dispatch_date = '2026-09-15';
```

The fingerprint must be identical after every phase. If it changes, Rule zero applies: roll back, fix, re-prove.

Also capture: `validate_refill_plan('2026-09-12', null, 'plan_output')` blocking count; `validate_refill_plan('2026-09-15', null, 'plan_output')` blocking count; `select p_tier, count(*) from v_machine_priority group by 1`; `select count(*) from v_wm_confirmations`; `select count(*) from pod_refill_plan where plan_date='2026-09-15'`.

---

## Phase 1. WEIMI is the shelf truth (PRD-125 D2)

Build exactly what `PRD-125-goal-command.md` Phase 1 specifies: `weimi_shelf_now(p_machine_id)`, the five `pod_inventory` read replacements (`push_plan_to_dispatch` Remove path, `add_dispatch_row` Remove path, the internal-move detection, `v_live_shelf_stock`, `return_dispatch_line` and `receive_dispatch_line`), the `[NO LOT ON SHELF]` zeroing branch deleted, `align_pod_lots_to_weimi(p_machine_id, p_dry_run)` wired into the 22:00 UTC cron after the aisle snapshot, one machine at a time, with a `monitoring_alerts` row when it moves or retires more than 5 lots.

Proof: in a rolled-back transaction, rebuild the 09-15 IFLYMCC A08 and MPMCC-1058 A02 swaps through the real push. Every Remove lands on A08 and A02 with the WEIMI quantity, no split legs, no manual step. Run `align_pod_lots_to_weimi` dry on every machine with `include_in_refill=true` and print the table. Print pass or fail.

## Phase 2. Stock at the supplying warehouse (PRD-125 D3, PRD-124 #38)

Build `wh_available_for(p_machine_id, p_boonz_product_id)` returning `(warehouse_id, free_stock, fefo_expiry)` exactly as PRD-125 Phase 2. Switch every availability read to it: `engine_add_pod` v15, `find_substitutes_for_shelf` v2, `validate_refill_plan` G8 and G9, `bind_dispatch_fefo`, `push_plan_to_dispatch`. Map `source_origin` to `source_kind` at push (`warehouse` to `wh`, `vox_at_venue` to `venue`, `internal_transfer` to `m2m`); if `venue` is not an allowed `source_kind` value, add it through a migration. Backfill `source_kind` on 09-14 and 09-15 rows (this is a metadata column; it does not change quantity, shelf or include, so the fingerprint above is unaffected; if your fingerprint query includes it, say so and exclude it).

Proof: rebuild ACTIVATE-2005 for 09-15 in a rolled-back transaction: zero `blocked_no_wh` on venue lines, every venue line tagged venue. `validate_refill_plan('2026-09-15', null, 'dispatch')` raises no G8 on a venue row. Print pass or fail.

## Phase 3. The gate checks the engine's rules (PRD-125 D1, D6)

Rewrite `validate_refill_plan` to G3, G5, G7, G8, G10, all blocking, exactly as PRD-125 Phase 3. Delete G1, G2, G4, G6, G9 from the function. G2, G4, G9 become boolean columns on `get_pod_refill_draft`. Remove `p_waive` from `approve_refill_plan` and every writer of `refill_plan_gate_waivers`; keep the table. Encode D1 in `engine_add_pod`: target `max_stock` when the lane's 30-day daily velocity is at or above `refill_policy_params.hero_velocity_floor` (new row, value 3) or the product is `venue_team`; otherwise `least(10, max_stock)`. Apply `slot_capacity_max` overrides everywhere `max_stock` is read.

Proof: re-validate 09-12 and 09-15 with `'plan_output'`; print the new blocking counts and list every violation with the lane and the reason; each must be a real problem, not a doctrine disagreement. Rolled-back rebuild of AMZ-1038 passes with zero blocking. Print pass or fail.

## Phase 4. Substitution rules as data (PRD-125 D4)

Table `substitution_rules` exactly as PRD-125 Phase 4, seeded with CS's rules as written in PRD-125 D4 (Evian, Hunter, the snack chain, scarce stock, expired on shelf). `find_substitutes_for_shelf` reads it in priority order, checks `wh_available_for`, checks `weimi_shelf_now` for "never a product already on another lane of this machine", returns the first match or nothing. No match: the lane stays at its level and `reasoning` gets `no_rule_matched`. Scarce-stock rule: under 12 free fleet-wide, one lane only, the highest-velocity one. `get_pod_refill_draft` gains an `exceptions` array (every `no_rule_matched`, every gate failure, every lane where WEIMI and lots disagree after alignment). A small FE table under `/refill` settings to list, add, deactivate rules.

Proof: rolled-back rebuild of 09-15 with the rules seeded: Evian lanes resolve by site, Hunter lanes resolve to 9 canisters with capacity 12, OMDCW A07 resolves to Freakin Roasted, the exception list is under ten lines and every line on it is real. Print pass or fail.

## Phase 5. Picker brain (PRD-126)

Build R1 to R6 in full. New params in `pick_urgency_params`: `horizon_days = 3`, `p1_threshold_aed = 150`, `p2_threshold_aed = 50`, `hero_velocity_floor = 3`, `cooldown_days = 1`. `v_machine_priority` computes `s_runout_aed`, `s_gap_aed`, `expiry_penalty_aed`, `stale_penalty_aed`, `p_score_aed` and the tier per R4, with the Zombie and cooldown rules. `pick_machines_for_refill` v12 with `p_cars`, `p_per_car`, cluster fill per R5, `car_no` on `machines_to_visit`. `get_machine_health` exposes `p_score_aed`, the three top contributors, `car_no`. Machine Health card and sort per R6. Leave `service_model` and `svc_track` untouched (R7).

Then run the 30-day backtest (A7): for every day in the window, for every hero lane (velocity at or above 3) that hit zero on a WEIMI snapshot, was the machine P1 under the new rule the day before, and was it P1 under the old rule. Tune `p1_threshold_aed` and `p2_threshold_aed` to the values that catch every hero stock-out with the smallest P1 count. Write the chosen values into `pick_urgency_params` and print the backtest table.

Proof: A1 to A7 from PRD-126 section 4 against the 14 Sep snapshot, each printed pass or fail. All seven must pass. If A5 (two-car cluster split) needs `venue_group` or `building_id` values that are missing on some machines, fill them from the machine name prefix and the site, write what you filled to `DECISIONS-2026-09-15.md`, and continue.

## Phase 6. Build on confirm, reliably (replaces PRD-125 D5)

CS keeps the gate. `refill_policy_params.gate0_require_manual_confirm` stays true. Build:

- `confirm_and_build(p_plan_date date, p_machine_names text[] DEFAULT NULL, p_cars int DEFAULT 2)`: sets the picks for the date to exactly the list given (unpick the rest, pick and confirm the named ones, `cs_added` where new, `car_no` per Phase 5 cluster fill), then runs the draft build for those machines only, then returns the draft summary with the `exceptions` array. Under 60 s for 14 machines; behind a SECURITY DEFINER wrapper if needed. Callable from the FE and from chat.
- A `Confirm and Build` button on the `/refill` pick list that calls it, with the car split shown per machine.
- Cron 13 at 20:00 Dubai stays, builds only when `confirmed_now > 0`; when zero it writes one `monitoring_alerts` row "no picks confirmed for <date>" and exits. Retire `refill_draft_missing_alert`.
- `approve_pod_refill_plan(p_plan_date, p_machine_names)` runs the stitch and the push inside the same call and returns the dispatch row count. The FE approve button calls it; the separate stitch step is removed from the FE.
- Measure `confirm_and_build`, `approve_pod_refill_plan`, `get_pod_refill_draft`, `get_machine_health_cached`, `validate_refill_plan` on production data. Print the timings. Anything over 5 s goes behind a wrapper.

Proof: `confirm_and_build('2026-09-16', array['AMZ-1029-3003-O1','NISSAN-0804-0000-L0'])` inside a rolled-back transaction returns a draft for exactly those two with an exception list in under 60 s. Print pass or fail.

## Phase 7. The remaining PRD-124 items

Each one proven before the next:

1. `mark_dispatched(p_dispatch_ids uuid[])` mirroring `mark_picked_up` (sets `dispatched=true`, refuses rows not picked up, returns the count). `DailyDispatchingTab.tsx` dispatched branch calls it then `receive_all_dispatches_for_machine`; the RPC result is shown on the row, an error is shown as text, never swallowed.
2. `SnapshotTab.tsx` `loadData` reads `get_machine_health_cached` and stamps `refreshed_at`; the refresh button result reads `aisles` (not `aisle`) and `machines_covered` (not `machines_online/total`). No page may call a function that takes longer than 5 s.
3. Field app `[machineId]/page.tsx`: when a return line has no reason, Save is disabled with the label "Pick a reason on <shelf>" and the card scrolls into view. Nothing silent.
4. `_bind_tally` dropped between batches in `bind_dispatch_fefo`.
5. The rows dated 2029 or later in `refill_dispatching`: release pins, cancel through the RPC, dry run printed first, then commit.
6. The `/refill` pick list filter includes `'cs_added'` alongside `'picked'`; if the packing rows not showing on `/refill` had a different cause, fix that and say what it was.
7. Procurement count and list come from one query; state which number was true.
8. Migration window alert: a pg_cron job every 5 min writes `monitoring_alerts` `migration_in_window` when a row lands in `supabase_migrations.schema_migrations` between 06:00 and 22:00 Dubai. Reconcile that table against `supabase/migrations/` and commit every missing file.
9. `CHANGELOG.md` at repo root, one line per migration since 12 September including everything this session writes.
10. `StartInventorySessionBar.tsx` banner rewritten as an instruction: "Press Start Inventory Control to confirm returns."

## Phase 8. Return splits (PRD-123)

Exactly as `PRD-123-goal-command.md` Phases 1 to 4: `wm_confirm_line_split(p_line_id, p_splits jsonb, p_reason, p_caller, p_dry_run)` with entries `{qty, expiry, outcome, boonz_product_id, target_machine_id, disposal_code}`, the sum of qty must equal the line or the variance is recorded, `wh_approved_at` stamped once, the Split toggle on `WarehouseConfirmationsPanel.tsx` reusing the variant and expiry rows already in `PendingRemoveApprovalsPanel.tsx`. The eight 14 Sep lines that Simran confirmed by hand with the split in the reason text: replay each as a dry run from that text and print the result; do not re-confirm them.

Proof: dry-run split of one real pending line with two expiries, dry-run split of one with two flavours, both print the resulting rows; a split whose qty sum is wrong records the variance and says so. Print pass or fail.

## Phase 9. Docs and skill

1. `docs/REFILL-DOCTRINE.md`, one page: the six decisions as they now stand (D5 replaced by Phase 6), the picker rules and the final thresholds, the truth table (WEIMI, lots, supplying warehouse), the five gates, the substitution rules and where they live. This is the file a new session reads first.
2. `docs/REFILL-DAILY-LOOP.md` is already in the repo; update it only if a button name or RPC name changed in this session.
3. `docs/boonz-master-3-SKILL-v4.md`: the skill text matching the doctrine, including every RPC signature you created or changed tonight with its exact argument list.
4. Regenerate TypeScript types (`mcp__supabase__generate_typescript_types`) into the path the repo uses.

## Phase 10. One full day, end to end, rolled back

In one transaction against 2026-09-16 (no live rows), as Cyril:

1. `confirm_and_build('2026-09-16', array['AMZ-1029-3003-O1','AMZ-1038-3003-O1','ACTIVATEMCC-2005-0000-L0'], 2)` returns a draft with car numbers and an exception list.
2. `approve_pod_refill_plan('2026-09-16', those three)` returns a dispatch row count above zero.
3. `validate_refill_plan('2026-09-16', null, 'dispatch')` returns zero blocking.
4. Every Remove row's `shelf_id` matches `weimi_shelf_now` for that machine and product. Every fill row on a warehouse source has `from_wh_inventory_id` set. Every venue row has `source_kind = 'venue'` and no pin. No lane on any of the three machines is at zero on WEIMI without a line or an exception entry.
5. `mark_picked_up` on all rows, `mark_dispatched` on all rows, `receive_dispatch_line` on one fill row, `driver_confirm_remove` on one Remove row, `return_dispatch_line` on one fill row with a reason, then `wm_confirm_line_split` dry run on the returned row.
6. Roll back. Confirm the canary fingerprint. Print every step's output and pass or fail.

This phase must pass in full. If any step fails, fix the function and re-run the whole phase from step 1.

## Phase 11. Frontend build and deploy

1. `npm run typecheck` (or `tsc --noEmit`), `npm run lint`, `npm run build` all pass with zero errors. Fix whatever fails, do not suppress.
2. Every screen touched tonight compiles: `/refill`, `/dispatching`, the field `[machineId]` page, the inventory panels, Machine Health.
3. Commit per phase with a message starting `prd12x pN:`, then push to the branch that deploys to production. Wait for the Vercel deployment to reach ready; if it fails, read the log, fix, push again. Print the deployment URL and status.
4. Run `mcp__supabase__get_advisors` for security and performance; fix every finding on an object you created or changed tonight (missing `search_path`, missing grants, RLS on new tables).

## Phase 12. The checklist, then the report

Re-read PRD-125, PRD-126, PRD-124 section 3, and PRD-123 line by line. Write `IMPLEMENTATION-CHECKLIST-2026-09-15.md` with one line per requirement in those documents, each marked done with the phase and the proof line that covers it, or superseded with the reason. Any line that is neither done nor superseded is open; go back and build it, then update the checklist. Repeat until there are zero open lines.

Then write `OVERNIGHT-REPORT-2026-09-15.md` in the repo root: one section per phase (what changed, the proof output, the canary and the baselines after it), the final backtest table and thresholds, the timing table for every FE-facing function, the PRD-124 nineteen-item table (fixed, superseded, open), the contents of `DECISIONS-2026-09-15.md`, and a five-line note for CS to read at 06:00: what he presses tonight at 19:00, what changed on the pack screen, what changed on the field app, what Simran sees on confirmations, and anything he must decide. Commit it. Write one `monitoring_alerts` row, severity info, source `overnight_2026_09_15`, payload the five-line note.

Only then is the session finished.
