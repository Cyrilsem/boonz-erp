# Overnight 14 to 15 September — one loop

Paste the block below into Claude Code in `boonz-erp`. It runs PRD-125 (one path, with D5
changed: **no automatic build, CS keeps the pick gate**), PRD-126 (picker brain), the
remaining PRD-124 items, and PRD-123 (return splits), in one session. Nine phases. It
stops for nothing except a conflict it cannot resolve.

Read in this order before starting: `PRD-125-one-path.md`, `PRD-126-picker-brain.md`,
`PRD-124-refill-pipeline-stabilisation.md` section 3, `PRD-123-warehouse-return-splits.md`.

---

/goal

You are working on the Boonz ERP. Supabase project `eizcexopcuoycuosittm`. Repo root is the
`boonz-erp` checkout you are in. Four PRDs are in the repo root: PRD-125, PRD-126, PRD-124,
PRD-123. Read all four before writing anything. CS has approved every decision in them with
one change: **PRD-125 D5 is replaced.** There is no automatic 20:00 build. CS confirms the
picks himself and the build runs on his confirm, fast and reliable. See Phase 6.

**Standing rules for the whole session.** `mcp__supabase__apply_migration` for every DDL,
one file per phase, named `prd12x_p<n>_<what>`. Never raw DDL via `execute_sql`. Impersonate
Cyril operator_admin `82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d` via
`set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true)`
in the SAME `execute_sql` call as any role-gated RPC. `execute_sql` returns only the LAST
statement's output. `product_mapping` joined to `warehouse_inventory` fans out; always
`distinct` on `boonz_product_id`. WEIMI slot codes zero-pad, A1 is A01. WH ids: CENTRAL
`4bebef68-9e36-4a5c-9c2c-142f8dbdae85`, MCC `4fcfb52c-271f-4aa7-a373-3495e3271cd3`, MM
`0aef9ccf-32ad-4545-8413-29bebd931d0b`. Every destructive function takes `p_dry_run boolean
DEFAULT true`.

**The 09-15 plan is live and packed. Nothing in this session may change a row on it.**
Every proof runs inside a transaction you roll back. The 09-15 refill_dispatching row count
is your canary; capture it first and re-check it after every phase.

Baselines, captured first, re-run after every phase, printed in the report:

- `select count(*) from refill_dispatching where dispatch_date='2026-09-15'`
- `validate_refill_plan('2026-09-12', null, 'plan_output')` blocking
- `validate_refill_plan('2026-09-15', null, 'plan_output')` blocking
- `select p_tier, count(*) from v_machine_priority group by 1`
- `select count(*) from v_wm_confirmations`

---

## Phase 1 — WEIMI is the shelf truth (PRD-125 D2)

Exactly as PRD-125 Phase 1 in `PRD-125-goal-command.md`: `weimi_shelf_now`, the five
`pod_inventory` read replacements, `align_pod_lots_to_weimi` wired to the 22:00 cron after
the aisle snapshot. Proof: the 09-15 IFLYMCC A08 and MPMCC-1058 A02 swaps rebuilt in a
rolled-back push land on A08 and A02 with no manual step.

## Phase 2 — Stock at the supplying warehouse (PRD-125 D3, PRD-124 #38)

Exactly as PRD-125 Phase 2: `wh_available_for`, every caller switched, `source_kind` mapped
at push, 09-14 and 09-15 rows backfilled. Proof: ACTIVATE-2005 rebuilt for 09-15 in a
rolled-back transaction with zero `blocked_no_wh`; `validate_refill_plan('2026-09-15', null,
'dispatch')` raises no G8 on a venue row.

## Phase 3 — The gate checks the engine's rules (PRD-125 D1, D6)

Exactly as PRD-125 Phase 3: `validate_refill_plan` becomes G3, G5, G7, G8, G10, all
blocking, none waivable; G1, G2, G4, G6, G9 deleted from the function; G2, G4, G9 become
draft columns; `p_waive` removed from `approve_refill_plan`. `engine_add_pod` target =
`max_stock` at velocity ≥ 3 or venue, else `least(10, max_stock)`, the 3 in
`refill_policy_params`. Proof: new 09-12 and 09-15 blocking counts with every violation
listed and real; AMZ-1038 rebuilt passes clean.

## Phase 4 — Substitution rules as data (PRD-125 D4)

Exactly as PRD-125 Phase 4: `substitution_rules` seeded with CS's rules,
`find_substitutes_for_shelf` reads it, scarce-stock consolidation, `no_rule_matched` flag,
`exceptions` array on `get_pod_refill_draft`. Proof: 09-15 rebuilt rolled-back with Evian
resolving by site, Hunter to 9 canisters, OMDCW A07 to Freakin Roasted, exception list under
ten lines.

## Phase 5 — Picker brain (PRD-126)

Build PRD-126 R1 to R6 in full. New params in `pick_urgency_params`: `horizon_days = 3`,
`p1_threshold_aed = 150`, `p2_threshold_aed = 50`, `hero_velocity_floor = 3`,
`cooldown_days = 1`. `v_machine_priority` computes `s_runout_aed`, `s_gap_aed`,
`expiry_penalty_aed`, `stale_penalty_aed`, `p_score_aed`, and the tier per R4.
`pick_machines_for_refill` v12 with `p_cars`, `p_per_car`, cluster fill per R5, `car_no`
written to `machines_to_visit`. `get_machine_health` exposes `p_score_aed`, the three top
contributors, `car_no`. Leave `service_model` and `svc_track` untouched (R7).

Then run the 30-day backtest in R4/A7 and **tune the two thresholds** so that every hero-lane
stock-out in the window had its machine at P1 the day before, with the smallest P1 count
that achieves it. Report the thresholds you settled on and the backtest table.

Proof: all seven acceptance criteria in PRD-126 section 4, run against the 14 Sep snapshot,
each printed pass or fail.

## Phase 6 — Build on confirm, reliably (replaces PRD-125 D5)

CS keeps the gate. `gate0_require_manual_confirm` stays **true**. Build:

- `confirm_and_build(p_plan_date date, p_machine_names text[] DEFAULT NULL)`: sets the
  picks for the date to exactly the list given (unpick the rest, pick and confirm the
  named ones, `cs_added` where new), then runs `_build_draft_core_v3` for those machines
  only, then returns the draft summary with the exception list. One call, under 60 seconds
  for 14 machines. Callable from the FE button and from chat.
- Cron 13 at 20:00 stays, but only builds when `confirmed_now > 0`, and when it is zero it
  writes one `monitoring_alerts` row "no picks confirmed for <date>" and exits. Retire
  `refill_draft_missing_alert`.
- `approve_pod_refill_plan` runs the stitch and the push inside the same call and returns
  the dispatch row count. The FE approve button calls it. Remove the separate stitch step
  from the FE.
- The 8 s statement timeout on `authenticated` must not be hit by any of these: measure
  each, and if one is over 5 s, move it behind a `SECURITY DEFINER` wrapper with its own
  `SET statement_timeout = '120s'`.

Proof: `confirm_and_build('2026-09-16', array['AMZ-1029-3003-O1','NISSAN-0804-0000-L0'])`
rolled back, returns a draft for exactly those two with an exception list, in under 60 s.

## Phase 7 — The remaining PRD-124 items

In this order, each proven:

1. **#35** `mark_dispatched(p_dispatch_ids uuid[])` mirroring `mark_picked_up`; the
   `DailyDispatchingTab.tsx` dispatched branch calls it then `receive_all_dispatches_for_machine`;
   RPC result surfaced on the row.
2. **#42** `SnapshotTab.tsx` `loadData` reads `get_machine_health_cached` and stamps
   `refreshed_at`; `result.aisle` to `aisles`; `machines_online/total` to `machines_covered`.
3. **Field Save** `[machineId]/page.tsx`: missing return reason scrolls the card into view
   and disables Save with the reason as its label.
4. **#39** `_bind_tally` dropped between batches.
5. **#41** the 76 rows dated 2029 or later: release pins, cancel through the RPC, dry run
   printed first, then commit.
6. **#37** confirm the `'picked'` filter on /refill and include `'cs_added'`; if the cause
   is different, say what it was.
7. **#36** procurement count and list from one query; state which number was true.
8. **Migration window alert** every 5 min, `migration_in_window` when a migration lands
   between 06:00 and 22:00 Dubai. Reconcile `supabase_migrations` against
   `supabase/migrations/` and commit every missing file.
9. **`CHANGELOG.md`** at repo root, one line per migration since 12 September including
   everything this session writes.
10. **Inventory-control banner** rewritten as an instruction.

## Phase 8 — Return splits (PRD-123)

Exactly as `PRD-123-goal-command.md` Phases 1 to 4. `wm_confirm_line_split`, variance
recording, the Split toggle on `WarehouseConfirmationsPanel.tsx`, the eight replays as dry
runs. Note that Simran confirmed those eight lines by hand on 14 Sep with the true splits
written into the reason text; replay them from that text, do not re-confirm them.

## Phase 9 — Docs and skill

1. `docs/REFILL-DOCTRINE.md`: one page. The six decisions from PRD-125 as they now stand
   (D5 replaced by Phase 6), the picker rules from PRD-126, the truth table (WEIMI / lots /
   supplying warehouse), the five gates, the substitution rules. This is the document a new
   session reads first.
2. `docs/REFILL-DAILY-LOOP.md`: the five-step daily routine for CS, Jojo, Anthony, Simran,
   with the button or RPC for each step and nothing else.
3. Update the skill file at `skills/boonz-master-3/SKILL.md` if it exists in the repo to
   match `REFILL-DOCTRINE.md`. If it does not exist in the repo, write the corrected SKILL.md
   to `docs/boonz-master-3-SKILL-v4.md` for CS to save.

---

## Report

One section per phase: what changed, the proof output, the five baselines after it. A final
table of the nineteen PRD-124 items with fixed / superseded / open. If any decision
conflicts with the schema in a way you cannot resolve, stop at that phase, write the
report to that point, and say exactly what the conflict is.
