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

## D-007. Incident: step 04 applied ~7 minutes before the 22:00 Dubai window

While dry-testing `prd128_04_lane_grain_left_join` in what was meant to be a rolled-back
transaction, the closing statement was typed as `COMMIT` instead of `ROLLBACK`. The view went
live at approximately 21:53 Dubai on 2026-09-19, ahead of the 22:00-05:00 window the PRD sets
for steps 4-9.

Checked the actual exposure before deciding what to do: `v_lane_grain` has exactly one
dependent object, `v_machine_priority` (confirmed via `pg_depend`), and no cron job in
`cron.job` runs between 21:53 and 22:00 Dubai that touches refill ranking (the nearest is
`pick_machines_morning_6am_dubai` at 06:00 Dubai). So the early apply changed no live plan and
raced no job. Disclosed to CS immediately in-session rather than silently proceeding.

Decision: left step 04 in place (it can't be meaningfully "un-committed" -- re-running it a
second time after 22:00 would just be a no-op CREATE OR REPLACE) and continued applying steps
05 onward strictly after the clock actually reached 22:00 Dubai, verified each time via
`now() at time zone 'Asia/Dubai'` before applying.

## D-008. Fourth schema gotcha found: shelf_code and slot_code pad differently

Not one of the three gotchas the PRD listed. `shelf_configurations.shelf_code` is zero-padded
to 2 digits across the whole fleet ("A01".."A16"). `weimi_aisle_snapshots.slot_code` is
unpadded ("A1".."A9", then "A10".."A16" -- confirmed via a length/value spot check; no
zero-padded 3-char slot_code exists anywhere). A direct string-equality join between them only
matches the double-digit shelves and silently drops every single-digit one. First cut of
`v_delivery_verification` showed ~60 percent `not_landed` past the WEIMI coverage start date
because of exactly this -- most rows never found a matching snapshot at all (both
`weimi_prev`/`weimi_next` NULL), and NULL collapsed to a false 0-movement reading. Fixed by
normalizing both sides with `regexp_replace(code, '^([A-Za-z]+)0*(\d+)$', '\1\2')` before
joining, verified against `A01`/`A1`/`A10`/`A010`/`B01`/`B1`/`B15`/`C09`. After the fix, the 559
remaining both-NULL rows are the expected ones: 502 predate WEIMI's own coverage start
(2026-04-28), leaving 57 genuine gaps out of 4851 dates within the covered window.

## D-009. A14: 14 not_landed lanes on 2026-09-18, not the PRD's stated 7

Live count for 2026-09-18 after the padding fix: 42 landed, 14 not_landed, 12 partial. The
PRD's own text names "7 specific not_landed lanes" for this date. Checked the actual 14 rows
(pasted in the final report) -- they are genuine: several show weimi stock net DECREASING over
the day despite units being added, because same-day sales outpaced the delivery. The verdict
formula is applied exactly as the PRD specifies it (`weimi_move <= 0` -> `not_landed`,
regardless of why the net is non-positive) -- this is not a bug in the join or the formula, and
not something to unilaterally reinterpret (a same-day-sales adjustment would be a formula
change the PRD didn't ask for). Treating the 7-vs-14 gap the same way as D-002's revenue-figure
drift: the PRD's illustrative number was accurate against a past snapshot of live data, current
live data has moved on. Reporting the real counts rather than forcing a match.

## D-010. get_machine_health() performance regression: found, partially fixed, residual documented

Once v_delivery_verification landed, get_machine_health() went from sub-second to 47.7s
(measured via EXPLAIN ANALYZE). Root causes found and fixed, in the order discovered:

1. shelf_configurations.shelf_code / weimi_aisle_snapshots.slot_code pad differently (D-008) --
   already covered above, but it was also the FIRST performance red flag (a ~60 percent
   not_landed rate on a view that should mostly show landed deliveries).
2. weimi_prev/weimi_next used DISTINCT ON over a pre-joined range set instead of a per-row
   LATERAL "ORDER BY snapshot_at DESC LIMIT 1" -- the range predicate (snapshot_date) sat in
   the middle of the natural index order, forcing a Bitmap Heap Scan + external sort per row
   (714ms for one half of the lookup at 5353 rows). Rewritten as LATERAL with a snapshot_at
   bound and a matching (machine_id, normalized_slot, snapshot_at DESC) index -- 714ms -> 125ms
   for the same lookup.
3. v_machine_health_signals.last_visit used LEFT JOIN v_delivery_verification + GROUP BY, which
   computes the view for every machine in dispatch history before filtering to the ~32 active
   ones (3.6s for the view alone). Rewritten as a per-machine correlated scalar subquery,
   wrapped MATERIALIZED -- 3.6s -> 321ms for the same view.
4. v_machine_priority references v_machine_health_signals three separate times internally
   (pre-existing structure, not introduced by this PRD -- harmless before because the old
   last_visit was cheap). Once last_visit got expensive, this pattern multiplied it badly:
   EXPLAIN ANALYZE showed one of v_delivery_verification's LATERAL scans running 166,976 times
   against an expected 5,353 (~31x). Fixed with one shared `vmhs AS MATERIALIZED` CTE inside
   v_machine_priority, all three references pointed at it -- v_machine_priority alone: 18.6s ->
   under 15s, worst node's loop count: 166,976 -> 7,873.
5. get_machine_health() itself independently references v_machine_priority,
   v_machine_health_signals, and v_delivery_verification multiple times in its own body (mp,
   hs, last_delivery, last_delivery_detail). Wrapped each as its own MATERIALIZED CTE
   (mp_data/hs_data/dv_data) at the top of the function.

**Residual, undocumented-until-now issue**: after all five fixes, get_machine_health() as a
whole still measures roughly 30-45s (down from 47.7s, but far from the sub-second baseline it
had before this PRD). The most likely remaining cost is with_velocity's dead_stock_count/
local_hero_count correlated subqueries -- pre-existing, unchanged in shape by PRD-128 (step 06
changed WHAT they filter by, not the correlated-subquery-per-machine-times-two pattern itself)
-- each of which reads v_sales_history_resolved, a heavy fuzzy product-name-matching view (its
own EXPLAIN plan shows CTEs estimated at tens of millions of rows). This was very likely already
somewhat slow before PRD-128 but not the dominant cost when last_visit was still cheap.

This is flagged as a known issue rather than fully solved: further optimization would mean
restructuring v_sales_history_resolved or building a materialized snapshot of
last-landed-delivery-date refreshed by a cron job, both of which are proper follow-up work (with
Dara's input) rather than something to improvise under this PRD's read-surface, minimal-footprint
mandate. Correctness was verified unaffected by every fix in this list -- cohort counts (D-004),
A2 revenue tolerance, and guard results all matched before and after.
