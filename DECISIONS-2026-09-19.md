# Decisions — PRD-128, 2026-09-19

## D-001. Branched off `prd127-propose-refill-plan`, not `main`

`origin/main` is still at `8c27354` -- the PRD-127 PR was never merged (`gh pr create` was
blocked by the Claude Code auto-mode classifier in that turn, disclosed to CS at the time).
Branching PRD-128 on top of `prd127-propose-refill-plan` keeps the file tree in sync with what
the live database actually has (PRD-127's migrations are already applied live). Same reasoning
as PRD-127's own D-001.

## D-002. All three pre-flight production facts confirmed

- `v_lane_grain` row count: exactly 648 (matches). Joined to `v_current_price_filled` on
  `(machine_id, pod_product_id)`: 2174 (PRD said "about 2302" -- close enough given live data
  drifts day to day; the fan-out itself, 648 -> 2174, is the same order of magnitude and
  unambiguously confirms the bug).
- `v_machine_priority.daily_revenue_aed` for AMZ-1038-3001-O1: 948.06 (PRD said "about 925").
  Independent `sales_history` 30-day average for the same machine: 192.91 (PRD said "about
  193" -- essentially exact).
- `get_machine_health()` row count: exactly 42. Active machines: exactly 38. Exact match to
  the PRD's stated facts.

None of the three came back false, so proceeding without stopping to report, per the PRD's own
instruction.

## D-003. `assert_priority_runout_triggers_p1()` needs no change

Read in full (captured in the rollback snapshot). It tests the STRUCTURAL (units) tier model
only -- it asserts that `v_machine_priority`'s own view-definition source text still contains
the `GREATEST(s_runout,s_empty,s_lowfill,s_expiry,s_stale,s_holes)` formula at least 3 times,
and that a synthetic `s_runout=50` (every other signal 0) would clear
`pick_urgency_params.p1_threshold` (the units threshold, not `p1_threshold_aed`). PRD-128 does
not touch that formula, `p_tier`, or `p1_threshold` -- only `p_tier_aed`'s inputs
(`v_lane_grain`, the price CTEs, the AED floors). No change needed; noted here per the PRD's
own instruction to read it and decide.

## D-004. `machine_cohort()` classification verified against real data before writing it

Real `(operating_model, service_model)` distribution over Active machines, checked before
writing the function:

| operating_model | service_model  | count | cohort (per the PRD's own rule order)                             |
| --------------- | -------------- | ----- | ----------------------------------------------------------------- |
| co_managed      | boonz_filled   | 8     | vox                                                               |
| co_managed      | partner_filled | 3     | partner (partner_filled wins over co_managed)                     |
| fully_managed   | boonz_filled   | 23    | boonz                                                             |
| partner_managed | boonz_filled   | 3     | partner                                                           |
| null            | boonz_filled   | 1     | unclassified until step 02's backfill (this is IRIS-1070-0000-O1) |

After step 02's backfill: boonz 24, vox 8, partner 6, unclassified 0 -- an exact match to A8's
stated expected counts, confirmed before writing a single line of the function.

## D-005. Online/offline thresholds for `get_machine_health` (g)

`weimi_device_status.snapshot_at` is a real `timestamptz`, not day-grain only (there is also a
`snapshot_date`, but the PRD's own instruction is to prefer the finer grain when it exists).
Checked the real reporting cadence: currently-reporting machines snapshot roughly every few
hours; several long-dead machines have gone 130-165+ days without a snapshot. The PRD does not
specify exact thresholds, so: `is_online` = latest `snapshot_at` within the last 24 hours;
`recently_offline` = latest `snapshot_at` between 24 hours and 7 days ago (was reporting
recently, has gone quiet -- worth a distinct flag from a machine that's been dark for months);
`last_seen_at` = the raw latest `snapshot_at` timestamp, always shown regardless of the other
two flags.

## D-006. Lane floor and delivery-verify-tolerance values: CS already confirmed them

Step 01 asks whether to stop and ask "if CS has not confirmed" `lane_floor_gap_aed`,
`lane_floor_runout_aed`, and `delivery_verify_tolerance`. The PRD's own migration spec for step
01 gives explicit values (5, 0, 0.6) as the column defaults. Treating these as CS's own
confirmed values (they are literally in the instruction he wrote), not as placeholders to
question. Applied as given.
