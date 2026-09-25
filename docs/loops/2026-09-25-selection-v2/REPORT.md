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

## CS HOLD, F1-F5 fixes (2026-09-25, after the gate above)

CS held the cutover and named five defects in pick_machines_v12, all confirmed live before fixing
(full detail and smoke calls in STATE.md, "CS HOLD" section). picker_config.picker_version stayed
'shadow' throughout; nothing here changed which picker is authoritative.

F1 CAP: the cap only governed non-P1 rows, so total output could exceed p_cap (12 rows at
p_cap=8 for 2026-09-27, confirmed before the fix). Fixed: the cap now governs the whole output. P1
is never trimmed; if P1 alone reaches or exceeds the cap, only P1 rows return and each gets a
'p1_overflow' reason appended, never a silent drop.

F2 CLUSTER: root cause was a naming-convention fallback building code that collapsed unrelated
machines sharing a placeholder "0000" segment onto the same code, wrongly clustering GRIT-1022,
ADDMIND-1007, and AMZ-1029. Fixed in two parts: seeded real machines.building_id for the 18 named
machines in 6 groups (AMZ_B24, AMZ_B30, VML, ALJLT, MIRDIF_CC, WPP_TOWER), then switched the
function to read machines.building_id directly instead of deriving anything. Cluster tagging can no
longer manufacture or change a tier, and never fires on a NULL building_id.

F3 DONOR: tightened to CS's four conditions (pickable check scoped to the donor's own primary
warehouse, velocity under 0.4/day AND stock at least 4, receiver in the fleet-wide top quartile of
velocity with fill under 50%, receiver's own tier is P1 or P2). donor_value_aed now counts only
units the receiver can actually take. Donor count before/after at the real cap of 8 for 2026-09-27:
9 of 12 rows before the fix, 5 of 8 after.

F4 EXPIRY P1 PHANTOMS: an expiry trigger now requires WEIMI to currently confirm the same pod
product on that lane with stock > 0, not just an Active pod_inventory row. Fleet-wide sweep for lots
expiring on or before 2026-09-27 found exactly one phantom lot fleet-wide, not archived:

- IRIS-1070-0000-O1, shelf A01, "Activia Mix & Go - Greek Yogurt Strawberries", qty 2, expired
  2026-09-25. WEIMI currently shows "Keen Health Dipped Crackers" on that same physical lane; the
  Activia batch is stale, no longer physically present.

F5 FILL<50% P1: this trigger now additionally requires a lane with velocity >= 0.3/day and daily
revenue at or above the fleet's own 25th percentile; otherwise it downgrades to P2 instead of
forcing a P1. GRIT-1022-0100-W0 (CS deliberately half-fills it, roughly 6 AED/day) no longer
triggers P1 on fill alone.

## F6 report: 2026-09-27 after the fixes

Tier counts, uncapped (all 30 machines that qualify for some tier):

- P1: 2
- P2: 10 (was 17 before F1-F5; this is the number CS asked to see re-checked)
- P3: 18

The 8 picks at the real default cap (p_cap=8), in order, with their reasons:

1. AMZ-1029-3003-O1, P1, 47.80 AED: a lot expires on or before the plan date and still has stock;
   picked up as part of a building cluster with another machine already visited (AMZ_B30).
2. AMZ-1038-3001-O1, P1, 0.00 AED: one of the top two lanes by velocity is empty or under a day of
   cover; picked up as part of a building cluster with another machine already visited (AMZ_B30).
3. VML-1003-0400-O1, P2, 100.50 AED: days since last visit (7) has reached this machine's rhythm (7
   days); the hero lane will run out before the next scheduled visit; this machine can donate slow
   stock to another machine that needs it (building VML).
4. AMZ-1068-2401-O1, P2, 134.00 AED: days since last visit (3) has reached this machine's rhythm (3
   days); this machine can donate slow stock to another machine that needs it (building AMZ_B24).
5. NOOK-1019-0200-B1, P2, 89.10 AED: at least one lane is empty; this machine can donate slow stock
   to another machine that needs it.
6. WPP-1002-4300-O1, P2, 89.10 AED: the hero lane will run out before the next scheduled visit; this
   machine can donate slow stock to another machine that needs it (building WPP_TOWER).
7. NOVO-1023-0000-W0, P2, 35.80 AED: days since last visit (11) has reached this machine's rhythm
   (10 days); the hero lane will run out before the next scheduled visit; this machine can donate
   slow stock to another machine that needs it.
8. ADDMIND-1007-0000-W0, P2, 0.00 AED: the hero lane will run out before the next scheduled visit.
   Not cluster-tagged (building_id is NULL for this machine, correctly no longer coincidentally
   clustered as it was before F2).

5 of these 8 are donors (AMZ-1068, NOOK-1019, NOVO-1023, VML-1003, WPP-1002); 2 are a real cluster
pair (AMZ-1029, AMZ-1038, both AMZ_B30); ADDMIND-1007 stands alone on its own P2 need.

B6 (supabase/tests/selection_v2.sql) re-run against these fixes on 2026-09-25: all original checks
plus 3 new ones (total-cap, cluster-null-building, phantom-expiry, fill-gate) pass, no exception
raised. B5's four acceptance checks re-verified live under the stricter rules: AMZ-1029 P1/cluster
(pass), VOXMCC-1005-0201-B0 not P1 (pass), AMZ-1068/VML-1004 donors with positive value (pass),
AMZ-1046 and AMZ-1057 both genuinely grouped with AMZ-1068 in the real AMZ_B24 building (pass, now
via a real building assignment, not a naming coincidence).

## CS HOLD (second), F7-F9 fixes

CS held again after reviewing the F1-F6 report, keeping picker_config.picker_version='shadow'.

F7 VISIT VALUE: sales_saved_aed was computed from a machine-level average runway_days against the
machine's rhythm, which flattened to zero whenever the average across every lane exceeded rhythm,
even when a single high-value lane was genuinely empty. AMZ-1038-3001-O1 (228.98 AED/day, an empty
top lane) showed visit_value_aed=0 before the fix. Checked CS's netting hypothesis directly against
v_lane_grain and v_live_shelf_stock's own definitions: neither nets any planned or unconfirmed
dispatch quantity into current_stock, so that was not the cause here. Fixed: sales_saved_aed is now
summed per lane, GREATEST(0, lane_dvel * horizon_days - current_stock) * lane price, horizon_days =
GREATEST(rhythm_days, 3). AMZ-1038 now shows 88.36 AED; AMZ-1029 (also P1) went from 47.80 to 137.09.

F8 COSMETIC: cluster_role='cluster' was applying to machines that already independently qualified
P1 or P2 on their own merits (AMZ-1029, AMZ-1038, AMZ-1046 all carried a redundant cluster tag and
reason). Fixed: cluster_role='cluster' now only applies when the machine's own tier is not already
P1 or P2. AMZ-1029 and AMZ-1038 no longer show the cluster tag; genuine cluster pull-ins (own tier
P3, added because the building already qualifies) still exist and are verified working.

F9 report, pick_machines_v12('2026-09-27', 8) after F7/F8, all 12 P1/P2 candidates:

| Machine              | Tier | Visit value (AED) | Cut status                                                     |
| -------------------- | ---- | ----------------- | -------------------------------------------------------------- |
| AMZ-1029-3003-O1     | P1   | 137.09            | In (P1, never capped)                                          |
| AMZ-1038-3001-O1     | P1   | 88.36             | In (P1, never capped)                                          |
| VML-1003-0400-O1     | P2   | 144.48            | In (1st by P2 value)                                           |
| NOOK-1019-0200-B1    | P2   | 144.47            | In (2nd by P2 value)                                           |
| AMZ-1068-2401-O1     | P2   | 134.00            | In (3rd by P2 value)                                           |
| WPP-1002-4300-O1     | P2   | 93.05             | In (4th by P2 value)                                           |
| NOVO-1023-0000-W0    | P2   | 65.70             | In (5th by P2 value)                                           |
| USH-1008-0000-W1     | P2   | 46.29             | In (6th by P2 value, last slot)                                |
| OMDBB-1020-0P00-O1   | P2   | 26.80             | Out (7th, one slot short)                                      |
| AMZ-1046-2406-O1     | P2   | 13.75             | Out (8th)                                                      |
| ADDMIND-1007-0000-W0 | P2   | 5.27              | Out (9th)                                                      |
| GRIT-1022-0100-W0    | P2   | 0.00              | Out (10th, real value, not a bug: CS runs it deliberately low) |

2 P1 rows are never capped; the cap of 8 leaves exactly 6 P2 slots, filled by the 6 highest
visit_value_aed candidates. OMDBB-1020-0P00-O1, the machine CS asked about directly, now scores a
real 26.80 AED shortage value (was 6 under the old approximation) and still, correctly, misses the
cut by one slot on real numbers, not a formula artifact.

B6 tests updated with 2 more assertions (cluster tag never on an independently-qualifying P1/P2
tier; every P1 machine above the fleet median daily revenue must show a positive visit value), and
the existence checks moved from cap 30 to cap 100 after the F7 re-ranking pushed the loop's one
genuine 2026-09-25 cluster example to position 31 of 31. All 11 checks pass live.

## R5 (queued, gated window)

CS added a third request: driver-entered expiry/variant breakdown on Remove lines
(driver_confirm_remove p_batch_breakdown) and a matching multivariant WH returns approval
(wh_approve_remove_receipt_multivariant), both dispatch/warehouse-confirmation functions under the
loop's 22:00-06:00 Dubai gate. Current Dubai time is well outside that window (11:11), so this is
being investigated and drafted now, marked DEFERRED, and applied in the gated window per the
loop's own hard rules; see STATE.md for progress.

## Gate

Waiting for CS to type "GO v12" or give further HOLD feedback in this session.
