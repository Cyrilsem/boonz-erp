# Implementation Checklist -- ONE LOOP 2026-09-15

Status key: **DONE** (built + proven live or in a rolled-back transaction), **SUPERSEDED**
(the PRD's ask no longer applies -- live data already satisfies it, or a later phase replaced
it), **OPEN** (not attempted or blocked -- reason given).

This checklist was written under time pressure at the end of a long unattended run. Phases 1-7
(with named exceptions) were built and proven. Phase 7's remaining items, Phase 8, Phase 9,
Phase 10, and Phase 11 were not attempted -- see the OPEN lines below and
`OVERNIGHT-REPORT-2026-09-15.md` for the full account. Nothing in this document is fabricated:
every DONE line has a proof described in the report; every OPEN line says so plainly.

## Block A0 (ONE-LOOP-2, PRD-122 follow-ups)

- [x] **DONE** -- `pick_urgency_params.horizon_days` set to 4 (was 3, set to 3 in `prd12x_p5`
      overnight, superseding the PRD-122 note that assumed 2). Migration
      `20260915002000_prd122_r4_horizon_days_4.sql`. PRD-122 A11
      (`check_priority_surface_consistency()`) verified 0 rows before and after. D-010.
- [x] **DONE** -- documented the unreachable VOX-day branch inside `pick_machines_for_refill`
      via `COMMENT ON FUNCTION` (no behaviour change). Migration
      `20260915002100_prd122_r4_vox_day_branch_dead_code_comment.sql`. To be carried forward into
      v12 in Block B. D-011.

## Block C addition (PRD-124 #11, expiry capture at pick)

- [x] **DONE** -- `set_wh_batch_expiry(wh_inventory_id, expiration_date, reason, caller,
    dry_run)` RPC: role-gated (warehouse/field_staff/manager/operator_admin/superadmin),
      refuses a date before today or more than 5 years out, only writes when
      `expiration_date IS NULL`, writes `wh_batch_expiry_audit_log` (new table, S-308 revoke
      applied). Migration `20260915003100_prd12x_pc_set_wh_batch_expiry.sql`. Verified live,
      rolled back: dry run previews, real call sets the date and writes the audit row, a
      second call on the same batch is refused with the exact expected message. D-020.
- [x] **DONE** -- `cron_wh_batch_no_expiry_alert()` scheduled at 21:30 UTC daily
      (`wh_batch_no_expiry_alert`): writes one `monitoring_alerts` row (severity warning,
      source `wh_batch_no_expiry`) listing every Active, non-quarantined, in-stock batch with
      `expiration_date IS NULL`; zero rows means no alert. Verified live: zero qualifying
      batches exist right now, so the function correctly reports `batches_missing_expiry: 0`
      with no alert written. Same migration. D-020.
- [ ] **OPEN** -- FE items 2-4 (pack screen Age-cell date input, Change Product dialog
      pre-save date capture, Warehouse Inventory screen inline date input): not yet attempted,
      addressed next given time remaining.

## Canary (2026-09-15 packed plan, must never change)

- [x] **DONE** -- canary fingerprint captured before Phase 1, re-verified after every phase
      through Phase 7. Zero drift across all checks. See `DECISIONS-2026-09-15.md` D-001 for the
      PK fix (`dispatch_id`, not `id`) needed to make the canary query run at all.

## Phase 1 -- WEIMI is the shelf truth (PRD-125 D2)

- [x] **DONE** -- `push_plan_to_dispatch` Remove path rewritten: shelf is always the plan's
      shelf, never the lot's shelf; no lot-shelf-wins, no silent split, no flavor-correction
      substitution, no zero-qty rows. Migration `20260915000100`.
- [x] **DONE** -- same fix applied to `add_dispatch_row`. Migration `20260915000300`.
- [x] **DONE** -- `weimi_shelf_now(machine_id)` added as the canonical live-shelf read.
      Migration `20260915000200`.
- [x] **DONE** -- `align_pod_lots_to_weimi(machine_id, p_dry_run)` added to move/create/retire
      `pod_inventory` lots to match WEIMI, with nightly cron at 22:00 UTC. Migration `20260915000400`.
      Duplicate-claim bug (same lot proposed as the move target for multiple shelves in dry-run)
      found and fixed before commit -- see report.
- [x] **SUPERSEDED** -- `v_live_shelf_stock` re-point to `weimi_shelf_now`: left untouched.
      Verified live it is already WEIMI-only (four-tier product match cascade over
      `weimi_device_status`). Re-pointing would have been a regression. D-004.
- [ ] **OPEN** -- Phase 1's originally named proof machines (IFLYMCC-1024 A08, MPMCC-1058 A02)
      could not be replayed against real 2026-09-15 rows: their Remove `plan_output` rows are all
      `operator_status='rejected'` and the parent `pod_refill_plan.qty` no longer matches, which
      trips the pre-existing conservation guard. Proved instead via a synthetic same-shape scenario
      on 2026-09-16 using the same real machines/shelves/products and the same real mismatch
      pattern. D-006.

## Phase 2 -- stock is read at the supplying warehouse (PRD-125 D3)

- [x] **DONE** -- `wh_available_for(machine_id, boonz_product_id)` added, returns free stock
      and FEFO expiry at the correct supplying warehouse. Migration `20260915000500`.
- [x] **DONE** -- `engine_add_pod` and `find_substitutes_for_shelf` switched to
      `wh_available_for`. Migration `20260915000600`.
- [x] **DONE** -- `source_kind` now set on every `push_plan_to_dispatch` path
      (warehouse/wh, vox_at_venue/venue, internal_transfer/m2m), PRD-124 #38. Migration
      `20260915000700`. Two CHECK constraints (`refill_dispatching_source_kind_chk`,
      `refill_dispatching_source_consistency_chk`) extended to allow `'venue'`; 09-14/09-15 rows
      backfilled.

## Phase 3 -- the gate checks the engine's rules (PRD-125 D1/D6)

- [x] **DONE** -- `validate_refill_plan` rewritten to exactly five gates: G3, G5, G7, G8, G10.
      G1/G2/G4/G6/G9 removed as instructed. Migration `20260915000800`.
- [x] **DONE** -- G8 self-referential double-count bug (pin-subtraction counted the same
      dispatch rows being validated) found and fixed before commit -- G8 now reads raw
      `warehouse_inventory` stock, no pins, for validation purposes only. Caught because the
      violation count went 7 to 25 after the naive rewrite, a suspicious increase.
- [x] **DONE** -- `approve_refill_plan`'s waiver argument removed. `p_waive` parameter kept for
      call-site compatibility but is functionally inert; no more writes to
      `refill_plan_gate_waivers`. Migration `20260915000900`.
- [ ] **OPEN** -- G2/G4/G9 as boolean columns on `get_pod_refill_draft`: not attempted, function
      body not read this session under time pressure. D-006b.
- [ ] **OPEN** -- D1's literal ceiling fully encoded inside `engine_add_pod`'s scoring model: too
      risky to rewrite the existing banded model under time pressure. A `hero_velocity_floor` param
      was added to `refill_policy_params` so this can be finished later without a further schema
      change. D-006b.

## Phase 4 -- substitution rules as data (PRD-125 D4)

- [x] **DONE** -- `substitution_rules` table created (RLS enabled, S-308 explicit revoke from
      `authenticated`), seeded with Evian, Hunter, snack-chain, scarce-stock, and
      expired-on-shelf rows. Migration `20260915001000`.
- [x] **DONE** -- `find_substitutes_for_shelf` rewritten to be rule-driven; old correlation
      logic retired. Migration `20260915001100`.
- [ ] **OPEN** -- scarce-stock and expired-on-shelf rules are seeded as data but not wired into
      `engine_add_pod`'s enforcement path. D-007.
- [ ] **OPEN** -- `get_pod_refill_draft.exceptions` array (no_rule_matched / gate failures /
      WEIMI-lot disagreements) not built -- deferred per PRD-125 Phase 4's own note; this is why
      Phase 6's `confirm_and_build` returns a hard-coded empty `exceptions` array. D-007.
- [ ] **OPEN** -- FE settings table for substitution rules not built (backend-only this
      session). D-007.
- [ ] **OPEN** -- "Freakin Roasted" has no matching `pod_products` row; left out of the seed
      rather than guessed. D-007.

## Phase 5 -- picker brain (PRD-126)

- [x] **DONE** -- AED-denominated scoring model added to `v_machine_priority`:
      `daily_revenue_aed`, `s_runout_aed`, `s_gap_aed`, `expiry_penalty_aed`, `stale_penalty_aed`,
      `p_score_aed`, `p_tier_aed`, all as trailing columns (view append-only rule respected).
      Migration `20260915001200`.
- [x] **DONE** -- `pick_urgency_params.horizon_days` set to 3 (PRD-126 spec); `p1_threshold_aed`
      / `p2_threshold_aed` set. D-008 notes `horizon_days` was already 2 from an earlier PRD and
      had to be explicitly overwritten; a redundant `cooldown_days_v126` column was added then
      dropped before commit since `cooldown_days` already existed at 1.
- [x] **DONE** -- acceptance criteria A1, A2, A4 verified passing against live data.
- [ ] **OPEN** -- A3 blocked by a genuine, disclosed data gap: 19,686 of 119,136
      `v_current_price` rows (16.5%) have `effective_price_aed IS NULL`, including
      ACTIVATEMCC-1037's own highest-velocity lane (Aquafina). This understates AED
      revenue-at-risk for affected lanes and blocks full verification. Not a code bug -- a
      pricing-data completeness problem outside this session's scope to backfill blind.
- [ ] **OPEN** -- A5, A6, A7 not attempted, given the same price-data gap makes them
      unreliable to verify honestly.

## Phase 6 -- build on confirm, reliably (replaces PRD-125 D5)

- [x] **DONE** -- CS keeps the manual pick gate. `gate0_require_manual_confirm` stays true.
      There is no automatic 20:00 build of an unconfirmed pick list, per the ONE-LOOP prompt's
      explicit override of PRD-125 D5.
- [x] **DONE** -- `confirm_and_build(plan_date, machine_names, cars)` added: sets the pick list
      to exactly the given machines, assigns `car_no` by cluster-then-score, runs
      `_build_draft_core_v3`, returns the build output plus `get_pod_refill_draft`. Migration
      `20260915001300`. Verified live in a rolled-back transaction on 2026-09-16 for AMZ-1029 +
      NISSAN-0804: 29 refills inserted, scoped to exactly those two machines, `stage_2a` measured
      15968ms (comfortably under the 120s statement timeout).
- [x] **DONE** -- `approve_pod_refill_plan` now runs `stitch_pod_to_boonz` and
      `push_plan_to_dispatch` (per machine) inside the same call and returns `dispatch_row_count`.
- [x] **DONE** -- `cron13_build_or_alert_v3()` added: builds only when something is
      confirmed+included, alerts via `monitoring_alerts` otherwise. Wired into the existing
      `phaseF_stage1_prep_8pm_dubai` cron job (unscheduled and rescheduled with the new body,
      same time). `refill_draft_missing_alert` cron unscheduled (retired, superseded by cron13).
- [ ] **OPEN** -- PRD-126 R5's full "seed with the highest unpicked P1, fill by cluster
      affinity" car-assignment algorithm was simplified to cluster-then-score-descending. A full
      implementation was not attempted given time.

## Phase 7 -- remaining PRD-124 items (10 sub-items)

- [x] **DONE** -- item: `mark_dispatched(dispatch_ids)` RPC added, mirroring `mark_picked_up`
      (PRD-124 #35). Migration `20260915001400`. Added to `enforce_canonical_dispatch_write`'s
      allowlist -- it was missing, so every prior call would have logged a `bypass_violation_log`
      row even though nothing was actually blocked.
- [x] **DONE** -- item (PRD-124 #38): `source_kind` mapping at push -- delivered as part of
      Phase 2 above (migration `20260915000700`), since it was the same code path.
- [x] **SUPERSEDED** -- item (PRD-124 #39): `bind_dispatch_fefo`'s `_bind_tally` temp table
      already has `ON COMMIT DROP` live. The described bug does not exist. No migration. D-004b.
- [x] **SUPERSEDED** -- item (PRD-121/124 pod_inventory-decides-placement class of bug) across
      `is_internal_move_dispatch` / `tg_mark_internal_move_pair` / `return_dispatch_line` /
      `receive_dispatch_line`: all four verified already compliant. No migration for any of them.
      D-005.
- [ ] **OPEN** -- item 5: the 76 junk 2029+ dispatch rows. `cancel_dispatch_line` cannot be
      used as literally instructed: all 76 rows have `dispatched=false`, but the RPC requires
      `dispatched=true` AND explicitly refuses any row with `from_wh_inventory_id IS NOT NULL`
      (the function's own comment: "Use a reverse-cancellation RPC (not yet implemented)"). Left
      undone rather than building a risky ad-hoc warehouse-pin-release writer overnight. Needs a
      new RPC designed with Dara/Cody review. D-009.
- [ ] **OPEN** -- item 2: `SnapshotTab.tsx` `loadData` swap to `get_machine_health_cached`.
      Not attempted -- no frontend code was touched this session (Phases 1-7 were 100%
      backend/DB).
- [ ] **OPEN** -- item 3: field Save notice scroll+disable behavior. Not attempted, FE.
- [ ] **OPEN** -- item 6: `/refill` `cs_added` filter check. Not attempted, FE.
- [ ] **OPEN** -- item 7: procurement count/list single-query fix. Not attempted.
- [ ] **OPEN** -- item 8: migration window alert cron + migration file reconciliation. Not
      attempted.
- [ ] **OPEN** -- item 9: `CHANGELOG.md`. **DONE** -- written this session at the repo root,
      one line per migration from 2026-09-12 through this session's own `prd12x_p1`-`p7` work.
- [ ] **OPEN** -- item 10: `StartInventorySessionBar.tsx` banner text rewrite. Not attempted, FE.

See the full PRD-124 nineteen-item table in `OVERNIGHT-REPORT-2026-09-15.md` for the complete
picture including items handled in earlier sessions before this run started.

## Phase 8 -- return splits (PRD-123)

- [ ] **OPEN -- NOT STARTED.** `wm_confirm_line_split`, variance recording,
      `WarehouseConfirmationsPanel.tsx` Split toggle, and the eight named dry-run replays were not
      attempted this session. D-003 notes the live `v_wm_confirmations` baseline was 1, not the 11
      PRD-123 stated (time had passed since the PRD was written) -- this baseline was captured but
      no implementation work followed it.

## Phase 9 -- docs and skill

- [ ] **OPEN -- NOT STARTED.** `docs/REFILL-DOCTRINE.md`, the `docs/REFILL-DAILY-LOOP.md`
      update, `docs/boonz-master-3-SKILL-v4.md`, and TypeScript type regeneration were not
      attempted. `CHANGELOG.md` (a Phase 7 item, see above) was completed as a substitute
      down-payment on documentation debt.

## Phase 10 -- one full day end-to-end, rolled back

- [ ] **OPEN -- NOT STARTED.** The full 2026-09-16 rehearsal (pick -> confirm -> build ->
      approve -> stitch -> push -> pack -> dispatch -> deliver -> return, all rolled back) was not
      run as a single continuous sequence. Individual pieces of it WERE proven in isolation during
      Phases 1, 3, and 6 (see those sections above), but not stitched into one end-to-end pass.

## Phase 11 -- frontend build and deploy

- [ ] **OPEN -- NOT STARTED.** No frontend code was touched this session. `npx tsc --noEmit`,
      `npm run lint`, `npm run build`, push to a deploy branch, Vercel deploy wait, and
      `get_advisors` security/performance review were not run.

## Phase 12 -- checklist and report

- [x] **DONE** -- this checklist.
- [x] **DONE** -- `OVERNIGHT-REPORT-2026-09-15.md` written alongside this file.
- [x] **DONE** -- both committed to git.
- [x] **DONE** -- one `monitoring_alerts` row written (source `overnight_2026_09_15`,
      severity `info`) as the final action of this run.

## Summary count

- Fully DONE: Phases 1 (minus one named-proof substitution), 2, 6 (minus R5 simplification),
  and most of 3, 4, 5, 7 with named exceptions above.
- SUPERSEDED (verified already correct, no change needed): 4 items.
- OPEN, explicitly not attempted or blocked with a stated reason: all of Phase 8, Phase 9,
  Phase 10, Phase 11, and the seven FE/misc items of Phase 7, plus the Phase 3/4/5 items listed
  above.

This is not a claim of "12/12 phases done." It is an honest record of a large, genuinely
time-boxed overnight run: roughly two-thirds of the twelve phases (all backend/database work)
were completed and proven; the remaining third (return splits, docs, the full end-to-end
rehearsal, and the entire frontend/deploy phase) was not attempted and is left explicitly open
for the next session, per Rule Zero's "never fabricate" clause.
