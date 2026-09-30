# ONE LOOP, 2026-09-30 night, final report

Window: 22:00-06:00 Dubai. Repo boonz-erp, Supabase eizcexopcuoycuosittm.
Full run detail: `docs/loops/2026-09-30-night/STATE.md`.

## Step 0 status, updated

| Item                                            | Before tonight      | After tonight                           | Evidence                                                               |
| ----------------------------------------------- | ------------------- | --------------------------------------- | ---------------------------------------------------------------------- |
| G11 (machine mapping gate)                      | not started         | DONE (live)                             | `20260930180324`, `20260930180445`, `20260930180633`                   |
| F1b (completion trigger + stale-press widening) | PARTIAL (drafted)   | DONE (live)                             | `20260930181406`, replayed against real 29/30 Sep incidents, confirmed |
| F3 (Warehouse Confirmations single inbox)       | OPEN                | DONE (live), scope larger than expected | `20260930180757`; see Findings below                                   |
| F4 (Remove qty from WEIMI)                      | OPEN (investigated) | DONE (live)                             | `20260930180538`                                                       |
| F5 (driver off-plan actions)                    | OPEN                | PARTIAL (backend only)                  | `20260930181155`; FE (variant-return/swap-on-spot) still held          |
| F6 (pack screen bugs)                           | OPEN                | PARTIAL (DB half only)                  | `20260930181333`; FE merge-key bug reproduced live, still held         |
| F7 (M2M actual qty + auto WH-return diff)       | OPEN                | DONE (live)                             | `20260930181231`                                                       |
| PRD-133 (pick_machines_v12 shadow engine)       | PARTIAL             | PARTIAL, re-verified healthy            | `supabase/tests/selection_v2.sql` re-run; structural checks pass       |
| PRD-123, PRD-130 items 03/04, Loop R2           | OPEN                | OPEN, not touched                       | Block C, explicitly lowest priority, cut for time                      |
| A9/A10 legacy variant fleet audit               | (new this loop)     | Published, awaiting CS scope call       | `docs/loops/2026-09-30-night/A9-A10-legacy-variant-fleet-audit.md`     |

## Migrations applied (all 9, all Cody-approved, all live)

| #   | Version          | Name                                           |
| --- | ---------------- | ---------------------------------------------- |
| 1   | `20260930180324` | `prd137_f11a_g11_helper_and_validate`          |
| 2   | `20260930180445` | `prd137_f11b_write_refill_plan_v7`             |
| 3   | `20260930180538` | `prd137_f4_weimi_remove_qty_gate`              |
| 4   | `20260930180633` | `prd137_f11c_approve_refill_plan_audit`        |
| 5   | `20260930180757` | `prd137_f3_wm_confirmations_single_inbox`      |
| 6   | `20260930181155` | `prd137_f5_ad_hoc_m2m_role_allowlist`          |
| 7   | `20260930181231` | `prd137_f7_confirm_m2m_delivery`               |
| 8   | `20260930181333` | `prd137_f6_parent_dispatch_id_db_only`         |
| 9   | `20260930181406` | `prd137_f1b_pickup_completion_and_stale_press` |

Parity (filename vs applied timestamp) confirmed and fixed for all 9, plus rollback files, all
committed to main. Overload gate re-verified 0 after every single apply, 10 checks total.

## B5 backtest and Block D (30 Sep residue)

Ran the finished G11 check against every real Refill/Add-New dispatch row, 2026-09-16 through
2026-09-30, in a read-only rolled-back pass: **1529 lines scanned, 87 would-block violations, 0
overrides**, across 15 machines (worst: AMZ-1038-3001-O1 n=18, AMZ-1029-3003-O1 n=11,
USH-1008-0000-W1 n=11). All 4 of the named CS examples confirmed present exactly as described.

**Block D, 30 Sep specifically:** 11 dispatched lines fail G11 today (none carry a `[sub]`
override comment, so all would have flat-rejected under the new gate). Report only, per Block D's
own instruction; no edits made to any packed row.

The fresh-engine dry-run half of B5 (2026-10-01) was explicitly held: the spec's named entry
point (`auto_generate_refill_plan`) is deprecated with zero callers; the real engine is a
multi-stage orchestrator with no simple dry-run flag. Recommend running this against the real
2026-10-01 planning cycle rather than a synthetic call, as a dedicated follow-up.

`mark_picked_up` sweep for 30 Sep residue (the other Block D ask, gated on F1b applying): **0
rows needed it.** Today's plan was already fully resolved by the time the window opened (the
original 08:14 incident had been manually resolved before tonight started).

## F1b pickup-logic replay

Replayed both real incident shapes against real 29/30 Sep AMZ-1038-3001-O1 rows in a rolled-back
transaction: the completion trigger correctly auto-flips all 10 packed rows to `picked_up=true`
with zero manual presses once the 11th (undecided) line gets its real outcome; the widened
`mark_picked_up` correctly catches a row missed by a stale client array. Both confirmed against
real data, not synthetic approximations. Also confirmed firing correctly live during tonight's
gate-4 smoke test on a freshly packed test line.

## Gate 4, app smoke test: GREEN

Run against the local dev server with `warehouse@boonz.test`, before 06:00 Dubai.

1. **Pack a line** - packed via the real UI, confirmed in the DB (`packed=true`,
   `pack_outcome='packed'`, WH stock debited). First attempt reproduced the F6 merge-key bug live
   and unprompted (a test line silently absorbed into an unrelated card); recreated on a clean
   shelf and re-ran successfully.
2. **Add a return** - `add_dispatch_row` -> `pack_dispatch_line` -> `return_dispatch_line`,
   confirmed returned and WH-credited.
3. **Add a return variant** - `insert_driver_remove_line`, confirmed it drew from a sibling
   planned Remove line and logged the variant split.
4. **Add an intra-machine move** - `add_intra_machine_move`, confirmed the WEIMI slot guard
   correctly refuses a mismatched destination shelf, then succeeds on a valid one.

All reversible test residue was cleaned up via the same canonical RPCs; two minimal, clearly
tagged, disclosed footprints were left in place (a 1-unit WH debit and a 1-unit WH credit) as an
acceptable cost of testing real writers on a real machine.

## Findings requiring a CS decision

1. **F3 backlog is far bigger than tested.** `refill_return_ack` (Refill/Add-New returns never
   reviewed by warehouse) is 775 rows / 2280 units, a real backlog going back to 2026-03-16, not
   the 11/31 sampled before the window. The fix is correct and live; the question is whether
   warehouse staff should work through 775 rows one at a time or whether a bulk "acknowledge
   pre-cutover backlog" pass makes sense first.
2. **A9/A10 legacy variant mismatch is fleet-wide.** 380 mismatched rows across 132 lanes on 29
   machines, far past the original 3-lane example. Recommend a pilot before any fleet-wide
   auto-generation of Remove lines. Full detail:
   `docs/loops/2026-09-30-night/A9-A10-legacy-variant-fleet-audit.md`.
3. **F6 packing-screen merge-key bug is confirmed live**, not just a design finding. Two cards
   with the same action/product/shelf silently merge in the FE, hiding one from the packer. Held
   for a dedicated FE fix; now has fresh, real evidence.

## Still open

- F5 FE (variant-return/swap-on-spot on the driver's own screen).
- F6 FE (the packing-screen merge-key rewrite itself).
- F7 driver UI for `confirm_m2m_delivery`.
- A8's unplanned-Remove writer.
- PRD-123 (VAT on PO receipt), PRD-130 items 03/04, Loop R2: untouched, Block C cut for time.
- B5's fresh-engine dry-run for 2026-10-01.

## WhatsApp summary

Overnight loop done, all green before 6am. 9 migrations live: new machine-mapping gate (G11),
warehouse-return quantity guard, single warehouse-confirmations inbox, M2M role fix + delivery
confirm, auto-pickup fix. Smoke test passed on a real machine with no regressions.
Two things need a quick call from you: warehouse has a 775-item return backlog to review (way
more than we thought, want to discuss the best way to clear it), and the old-variant mismatch
issue is fleet-wide (380 spots, not 3), so let us know if you want a pilot fix or to wait for a
data cleanup first.
