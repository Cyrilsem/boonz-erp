# PRD-124 — Refill pipeline stabilisation

**Owner:** CS
**Written:** Monday 14 September 2026, late
**Status:** ready to build
**Supersedes:** the open items in the 14 Sep fix list and to-do #35 to #45. Folds in the
unfinished PRD-116 items (#7, #8, #9) that never landed.

---

## 1. Why this exists

Three days of refills produced **nineteen distinct defects**. Each one was found by a person
at the moment it hurt: the driver at a machine, Simran at the warehouse screen, you at the
pack list. None was found by the system.

They are not nineteen random bugs. They are four things:

**A. Two definitions of the truth.** WEIMI says what is on a shelf. `pod_inventory` says
what lot is on a shelf. They disagree, and different writers trust different ones. The
engine plans on WEIMI. The push places Remove legs on `pod_inventory`. The gate reads WEIMI.
The driver sees the push. So a Remove for a lane the driver can see ends up labelled with a
lane the driver cannot see.

**B. Two definitions of available stock.** The engine and the gate check WH_CENTRAL. Half
the fleet is topped from WH_MCC. So every VOX line is born dead and has to be resurrected by
hand, every night, and the dispatch-side gate then reports it as short.

**C. Two refill philosophies in one pipeline.** Engine v15: "sellers fill to capacity."
Gate G1 (PRD-121): "never fill to capacity." Every engine plan trips 70 to 80 blocking
violations on the gate that was built to protect it, and the only way through is a waiver.
A gate that is always waived is not a gate.

**D. Screens that do not do what their label says.** Mark All Dispatched cannot mark
anything dispatched. Refresh cannot refresh the cards. Confirm cannot confirm a split
return. Each looks alive and does nothing.

And underneath all four: **migrations land without a contract.** Six migrations arrived on
14 September between 13:49 and 15:36 Dubai, mid-refill, and changed what the picker
considers eligible and how P1 is scored. They were coherent. Nobody planning that day's
refill knew they had happened.

---

## 2. Goals

1. **One truth per question.** WEIMI for what is on a shelf. `pod_inventory` for expiry only.
   `warehouse_inventory` by name across the warehouse that actually supplies the machine.
2. **The engine and the gate agree.** A plan the engine builds passes the gate without a
   waiver, or the gate is wrong and gets changed.
3. **Every button does what it says**, and every failure surfaces where the person is
   looking.
4. **No schema or engine change reaches production between 06:00 and 22:00 Dubai** without
   a line in a changelog the planner reads.

### Non-goals

- Rewriting the engine. v15 stays. Its clamps and its capacity rule get inputs it can trust.
- Redesigning the field app.
- PRD-123 (return splits). It ships on its own track; this PRD references it.

---

## 3. The defects, all of them

Severity: **S1** blocks a refill or corrupts stock · **S2** costs the team time every cycle ·
**S3** cosmetic or slow-burn.

### Truth and stock (A, B)

| #   | Sev | Defect                                                     | Root cause                                                                                                                                                           | Fix                                                                                                                                                                                                     |
| --- | --- | ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 44  | S1  | Remove legs land on the wrong shelf                        | `push_plan_to_dispatch` and `add_dispatch_row` set `shelf_id = COALESCE(lot_shelf, requested_shelf)`. The `pod_inventory` lot wins over the shelf the plan asked for | Resolve Remove shelf from the latest WEIMI slot that carries the pod product. Use the lot only for expiry. If WEIMI and the lot disagree, keep the WEIMI shelf and flag `lot_shelf_mismatch` on the row |
| 45b | S1  | Engine zeroes every venue line as `blocked_no_wh`          | `engine_add_pod` checks WH_CENTRAL only. Aquafina is 0 there and 515 at WH_MCC                                                                                       | Engine availability = the machine's supplying warehouse. `venue_team` products resolve against WH_MCC / WH_MM. Same for `find_substitutes_for_shelf`                                                    |
| 38  | S1  | Every pushed row has `source_kind = 'unknown'`             | `push_plan_to_dispatch` never maps `source_origin` to `source_kind`                                                                                                  | Map at push: `warehouse` to `wh`, `vox_at_venue` to `venue`, `internal_transfer` to `m2m`. Backfill the 09-14 and 09-15 rows                                                                            |
| G8d | S1  | Dispatch-side gate reports venue lines as short in CENTRAL | Consequence of #38: `is_venue` is derived from `source_kind` and it is always `unknown`                                                                              | Falls out of #38. Add a regression test: a `vox_at_venue` row must never raise G8                                                                                                                       |
| —   | S2  | `pod_inventory` drifts and nothing says so                 | No drift monitor. `resync_pod_inventory_from_weimi` exists but a dry run on MPMCC-1058 would write off 21 and add 140 unattributed                                   | Nightly drift report per machine: lanes where WEIMI pod and `pod_inventory` pod disagree. Surface on the Snapshot card. Do **not** auto-resync                                                          |
| —   | S2  | Dubai Popcorn ghost 5 planned three times in two days      | ERP 5, shelf 0. The count baseline exists but the ghost row is still Active                                                                                          | Run `apply_warehouse_audit` from Monday's count. Until then, quarantine the 5                                                                                                                           |
| 7   | S2  | Conservation guard on superseded M2W (PRD-116)             | Unfinished                                                                                                                                                           | Land it                                                                                                                                                                                                 |

### Engine vs gate (C)

| #   | Sev | Defect                                              | Root cause                                                                                        | Fix                                                                                                                                                             |
| --- | --- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| G1  | S1  | 74 blocking G1 on a plan the engine built           | Engine fills sellers to capacity; G1 blocks landing at capacity                                   | Pick one. Recommendation: G1 becomes **warning** on lanes where `daily_velocity >= 3`, stays **blocking** below. Venue lines exempt from G1 as they are from G8 |
| 45a | S2  | Zombies in P1 next to 39-a-day machines             | `p1_holes_min = 2`, `p1_empty_ab_min = 1`, `stale_override_days = 14` fire with no velocity gate  | The three hard triggers promote to P1 only when `daily_velocity >= 3` or the machine is not labelled Zombie / Kill Candidate. Otherwise P2                      |
| G5  | S2  | G5 accepts a global mapping                         | Fixed on 13 Sep to stop false positives, at the cost of the machine-specific check PRD-121 wanted | Two-level: blocking when neither machine nor global mapping exists; warning when only global exists                                                             |
| —   | S2  | 8pm engine builds nothing                           | `gate0_require_manual_confirm = true` and nobody confirms picks by 20:00                          | Cron 13 sends the pick list to CS at 19:00 with a one-tap confirm, and if nothing comes back by 20:00 it builds anyway and marks the draft `unconfirmed_picks`  |
| 39  | S3  | `_bind_tally already exists`, 108 warnings per push | Temp table not dropped between batches                                                            | `DROP TABLE IF EXISTS` or `ON COMMIT DROP`                                                                                                                      |
| 9   | S3  | Edit clamp uses lane cap, not product cap (PRD-116) | Unfinished                                                                                        | Land it. Read `slot_capacity_max` first                                                                                                                         |

### Screens (D)

| #   | Sev | Defect                                                | Root cause                                                                                                             | Fix                                                                                                                                                                                                |
| --- | --- | ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 35  | S1  | Mark All Dispatched does nothing                      | Calls `receive_all_dispatches_for_machine`, whose loop is `WHERE dispatched = true`. No `mark_dispatched` RPC exists   | New `mark_dispatched(p_dispatch_ids uuid[])` mirroring `mark_picked_up`. Button calls it, then receive. Or drop the `dispatched = true` filter, since `receive_dispatch_line` sets the flag itself |
| 42  | S1  | Refresh completes, cards never update                 | `loadData()` calls live `get_machine_health()` (34 s) as `authenticated` (8 s timeout). Cancelled every time, silently | `loadData` reads `get_machine_health_cached`. Fix `result.aisle` to `aisles` and `machines_online/total` to `machines_covered`                                                                     |
| 40  | S1  | Return confirmation cannot split by expiry or flavour | `wm_confirm_line` is single-shot and stamps `wh_approved_at` on first call                                             | **PRD-123**, already written, `/goal` ready                                                                                                                                                        |
| —   | S2  | Field Save silently blocked                           | `handleSave` returns early on a missing return reason; the notice renders above the fold                               | Scroll the notice into view and disable Save with the reason as its label                                                                                                                          |
| 37  | S2  | /refill hides packing that /field shows               | Likely `machines_to_visit.status = 'picked'` filter hides `cs_added`                                                   | One query to confirm, then include `cs_added`                                                                                                                                                      |
| 36  | S2  | Procurement header 21, list 3                         | Not investigated. Count and list use different filters, or fan-out                                                     | Investigate, then make one query feed both                                                                                                                                                         |
| 41  | S2  | 76 junk 2030 dispatch rows bury the approval queue    | PRD-122 R3.4 never executed                                                                                            | Release pins, cancel via RPC                                                                                                                                                                       |
| —   | S3  | Inventory-control lock reads as an error              | Banner says "edits are locked" before the button that unlocks them                                                     | Rewrite the banner as an instruction                                                                                                                                                               |
| 8   | S3  | Driver multi-variant split inheritance (PRD-116)      | Unfinished                                                                                                             | Land it                                                                                                                                                                                            |

### Process

| #   | Sev | Defect                                                      | Fix                                                                                                                                                                                                             |
| --- | --- | ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| —   | S1  | Migrations land mid-day with no notice                      | `CHANGELOG.md` at repo root, one line per migration with date, what changed, who asked. Deploy window 22:00 to 06:00 Dubai unless CS says otherwise. A cron that alerts if a migration lands outside the window |
| 10  | S2  | Migration files not all committed                           | Reconcile `supabase_migrations.schema_migrations` against `supabase/migrations/` and commit the gap                                                                                                             |
| —   | S2  | Every empty lane needs the `add_dispatch_row` route by hand | `write_refill_plan` accepts an Add New on an empty lane when the pod product carries an Active mapping for that machine. The slot guard checks identity, not emptiness                                          |

---

## 4. Acceptance criteria

| #   | Criterion                                                                                                                                                          |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| A1  | The 09-15 plan replayed end to end lands every Remove on the WEIMI shelf with zero manual moves                                                                    |
| A2  | The 09-15 plan replayed produces zero `blocked_no_wh` on VOX venue lines                                                                                           |
| A3  | Every row pushed carries a `source_kind` other than `unknown`, and `validate_refill_plan(..., 'dispatch')` raises no G8 on a venue line                            |
| A4  | An engine plan for AMZ-1038 passes the gate with zero blocking and zero waivers                                                                                    |
| A5  | GRIT at 1.7/day with two empty rows is P2, AMZ-1038 at 39/day is P1                                                                                                |
| A6  | Mark All Dispatched on a machine at P n/n, U n/n, D 0/n takes it to D n/n                                                                                          |
| A7  | Refresh on the Snapshot page updates a card within 5 s of "Refresh complete"                                                                                       |
| A8  | Cron 13 builds a draft on a night where nobody confirmed picks, and marks it                                                                                       |
| A9  | `push_plan_to_dispatch` runs three times in one session with zero `_bind_tally` warnings                                                                           |
| A10 | A migration applied at 14:00 Dubai raises an alert within 5 minutes                                                                                                |
| A11 | `validate_refill_plan('2026-09-12')` still returns 53 blocking after every gate change **except** the G1 and G5 changes, whose new counts are stated in the report |

---

## 5. Order

Two Claude Code sessions, not one. The first is database only and can run tonight. The
second is frontend and needs a deploy.

**Session 1, database:** #44, #45b, #38 + G8d, G1, #45a, G5, cron 13, #39, #41, drift
report, quarantine the ghost 5, migration alert, reconcile migration files.

**Session 2, frontend:** #35, #42, field Save notice, #37, #36, inventory banner.

PRD-123 runs on its own.

## 6. Claude Code prompt

`PRD-124-goal-command.md`, session 1 and session 2 as two pasteable blocks.
