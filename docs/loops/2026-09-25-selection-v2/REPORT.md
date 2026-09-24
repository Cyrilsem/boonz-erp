# Loop report: Selection v2 + refill engine P0 fixes

Branch loop/selection-v2-2026-09-25. Applied 00:48 to 03:10 Dubai, 2026-09-25. Full detail and
smoke calls in STATE.md; this is the summary.

## Applied (all live)

A1 M2M lock, cancel_m2m_transfer RPC. A2 real repair of transfer 91240fab. A3 G3 coverage fix in
validate_refill_plan. A4 M2M lot binding must match flavour, push_plan_to_dispatch and
add_m2m_transfer. A5 engine_finalize_pod zeroes qty on auto-suppressed M2W rows. A6 explicit WEIMI
alias for Red bull 355ML, no new pod product created (root cause was a fuzzy-match-only shelf, not
a missing mapping). B1 picker_config switch, seeded shadow. B2 pick_machines_v12 engine, switch
wired into _build_draft_core_v3. B3 v_picker_shadow_diff(plan_date). B4 picker_backtest_results
table (structure only, see Deferred). B6 supabase/tests/selection_v2.sql, all green against live
data. C1 refill_policy_params.slow_lane_fill_cap_pct column, off (see Deferred). C2 seeded
product_lane_fit, sku_intents, cannibal_pairs per PRD-134.

## Deferred to a later pass, not silently dropped

- B4/B5 full 24-day historical replay: pick_machines_v12 and pick_machines_for_refill both read
  only the latest WEIMI snapshot (v_machine_priority, v_lane_grain), with no as-of-date capability
  to replay a past day. A real backtest needs a parallel snapshot-at-date input path, a separate
  build. B5's four checks are answered against real live data instead (below), a close proxy since
  this session started shortly after the named 22:00 Dubai 24 Sep snapshot.
- C1 engine wiring: engine_add_pod is roughly 25KB of already-battle-tested sizing logic. Adding
  the capping branch safely needs reading and understanding the whole function first; the flag
  must stay off regardless, so this was cut rather than rushed. Backtest evidence below is real.

## A2 outcome

Transfer 91240fab-0c1e-4b96-853a-0b887e5a2c62 (VML-1004-0500-O1 A03, Red Bull, qty 7) cancelled via
cancel_m2m_transfer and converted to a plain warehouse Remove, new dispatch_id
61310768-b5ef-4d70-bff3-143a2ebc7301. Verified: source and destination legs both quantity 0,
skipped, excluded; new Remove row quantity 7, routed to VML-1004's own primary warehouse.

## Direct writes and mutation_reason

1. cancel_m2m_transfer (A2): "cancel_m2m_transfer 91240fab-0c1e-4b96-853a-0b887e5a2c62 by=system:
   CS 24 Sep: Red Bull 7 back to WH, AMZ-1029 355ML lane being depleted", plus add_dispatch_row's
   own "cancel_m2m_transfer ... converted to warehouse return: ..." on the new Remove row.
2. weimi_product_alias insert (A6): "loopv2 A6: add weimi_product_alias Red bull 355ML -> pod
   product Red Bull (a602c923...), direct reference-table insert, no canonical writer RPC exists
   for this table."
   All other changes this loop were schema/table migrations or seed data, self-documented by their
   migration file and commit message, not RPC-mediated writes against live operational rows.

## B5 acceptance (against real live data, 2026-09-25/27, proxy for the 22:00 24 Sep snapshot)

1. AMZ-1029-3003-O1 must be P1 (Activia expiry): PASS. Also proves the cooldown bypass works,
   since this machine has days_since_visit = 0 today and is still P1.
2. VOXMCC-1005-0201-B0 must not be P1: PASS, never P1 under v12 (tier null or P2 depending on day).
3. AMZ-1068-2401-O1 and VML-1004-0500-O1 must surface as donors: PASS, both real, positive
   visit_value_aed (452.45 and 298.70 AED) once the cap allows more than 8 rows through. FAIL at
   the real default cap of 8: today's fleet has 17 of 32 eligible machines independently
   qualifying P2 under the literal PRD-133 rules, filling the cap before these donors are reached.
   This is a real, verified finding (donor logic confirmed correct), not a bug in the donor
   computation; whether P2's boolean gate should become a softer ranking signal, or the cap should
   be larger, is a product call for CS. See STATE.md B2 section 5.
4. AMZ-1046-2406-O1 pulled in via the building 24 cluster once AMZ-1068 is picked: PARTIAL.
   AMZ-1046 independently qualifies P2 on its own need before any cluster logic is needed; the
   cluster mechanism itself is verified working generically (at least one genuine cluster pull-in
   confirmed in every test run, see B6), just not exercised by this specific pair on live data
   today.

## B6 tests

supabase/tests/selection_v2.sql, run live: P1 cooldown bypass, VOX gate, cap exempts P1, cap never
exceeded, both named donors correctly tagged with positive value, at least one genuine cluster
pull-in, no em dashes in engine reasons. All passed.

## v12 vs v11, next real planning day (2026-09-27, since 2026-09-26 is Saturday, no plan)

v11 (rolled back, not written): 8 machines, led by AMZ-1029-3003-O1 (367.08), AMZ-1038-3001-O1
(341.70), VOXMCC-1005-0201-B0 (135.81, reasons hero_runout/seller_below_horizon).
v12 (read-only): 4 P1 (AMZ-1029, ADDMIND-1007, IRIS-1070, GRIT-1022-0100-W0) plus 8 P2, all 8 P2
tagged donor or cluster. VOXMCC-1005-0201-B0 does not appear at all under v12 for this date
(v11 picks it, v12 does not), the clearest behavioural difference between the two right now.
AMZ-1029 P1 in both. Full reasons per machine in STATE.md and via
v_picker_shadow_diff('2026-09-27').

## Gate

Waiting for CS to type "GO v12" or "HOLD" in this session.
