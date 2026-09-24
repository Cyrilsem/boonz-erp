# BOONZ-MASTER-3-DELTA: changes from loop/selection-v2-2026-09-25

Exact changes the boonz-master-3 skill's knowledge needs to pick up from this loop.

## New picker: pick_machines_v12 and the picker_config switch

- New function pick_machines_v12(p_plan_date date, p_cap int default 8) returns machine_id,
  official_name, tier (P1/P2/P3), visit_value_aed, reasons text[], building_id (text, derived from
  the official_name naming convention, not machines.building_id which is unpopulated fleet-wide),
  cluster_role (donor/cluster/null), donor_for jsonb.
- New table picker_config(key, value, updated_at, updated_by). Single row key='picker_version',
  values 'v11' | 'shadow' | 'v12'. Currently 'shadow'.
- New table machines_to_visit_shadow: holds whichever picker is NOT authoritative for a plan_date,
  tagged by picker_version. Read via v_picker_shadow_diff(plan_date) for a side-by-side comparison.
- _build_draft_core_v3 (called by build_draft_for_confirmed and the 6am pre-pick) now reads
  picker_config.picker_version before repicking: 'v11' behaves exactly as before; 'shadow' keeps
  v11 authoritative and additionally runs v12 into the shadow table; 'v12' makes v12 authoritative
  (its picks land in machines_to_visit, P1/P2 mapped to the existing priority_tier vocabulary
  P1_RESTOCK/P2_MAINTAIN, P3 has no v11 equivalent and lands as NULL there) and archives v11's own
  run into the shadow table instead.
- pick_rhythm_params(tier_label, rhythm_days): top=3, mid=7, slow=10 days, used by v12's P2 rhythm
  rule (NTILE(3) over daily_revenue_aed computed live each call, not a stored per-machine tercile).

## Cutover

No cutover has happened. picker_config.picker_version is still 'shadow'. Do not flip it to 'v12'
without an explicit CS "GO v12" and the pre-cutover checklist in the loop task (dry check on the
next plan_date, mutation_reason logged, at least 30 minutes before the 20:00 Dubai draft cron).

## Known open item on v12 before cutover

With today's real fleet (32 eligible machines), 17 independently qualify P2 under the literal
rules, filling the cap of 8 before any cluster/donor pick is reached. The donor/cluster logic
itself is verified correct on real data (AMZ-1068-2401-O1 and VML-1004-0500-O1 both correctly
computed as donors with positive value once the cap allows it). Whether the cap should be larger,
or P2's boolean gate should become a ranked signal instead of an admit/reject gate, needs a CS
decision before cutover; do not silently change either without one.

## G3 (validate_refill_plan)

The EMPTY-lane-with-no-line check now also treats a lane already covered by an approved
refill_plan_output line, or by anything in refill_dispatching, as covered. Previously it only saw
pending plan_output rows for the p_source branch being checked, which produced false blocks
(AMZ-1029-3003-O1 A10 was the evidence). G5/G7/G8/G10 unchanged.

## G4 (M2M lot binding)

push_plan_to_dispatch's M2M source-leg lot lookup and add_m2m_transfer's lot lookup now filter to
the boonz_product_id actually being transferred. Previously both picked whichever Active lot on
the source shelf expired soonest regardless of product, which could bind a completely different
flavour's lot onto a transfer (ADDMIND-1007 A16 evidence). Falls back to NULL, never another
flavour's lot. The equivalent plain (non-M2M) Remove/Machine To Warehouse leg lookup still has the
same unfiltered shape; it is out of this fix's scope and unchanged.

## G6 (engine_finalize_pod)

Auto-suppressed orphan M2W/REMOVE rows (no replacement shelf) are now written with qty = 0, not
left at their original nonzero quantity next to a status flag. Prior quantity preserved in
reasoning.auto_suppressed_prior_qty for audit.

## M2M no longer auto picked_up

push_plan_to_dispatch no longer sets picked_up=true on an M2M source (Remove) leg at push time.
New RPC cancel_m2m_transfer(p_transfer_id, p_reason, p_convert_source_to_return, p_dry_run)
cancels an unstarted transfer (refuses if the driver has already touched either leg), optionally
converting the source leg to a plain warehouse Remove. Destination-leg lookup is by
m2m_partner_id, not by action label (a destination leg can legitimately be 'Refill' or 'Add New').

## Knowledge tables (PRD-134, seed only, nothing reads these yet)

product_lane_fit, sku_intents, cannibal_pairs. See docs/loops/2026-09-25-selection-v2/STATE.md for
the exact seeded rows and ids. RLS: authenticated read, operator_admin/superadmin write via RLS
policy (authenticated keeps its default write grant here, unlike the picker tables above which
revoke it entirely).

## Data fix

weimi_product_alias gained one explicit row (Red bull 355ML -> the existing generic Red Bull pod
product). No new pod product was created; the existing generic identity was already correct and
already shared by three real SKU variants on that shelf's history.
