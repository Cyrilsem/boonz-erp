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

CS typed "GO v12" on 2026-09-25 after F1-F9 HOLD fixes (see STATE.md/REPORT.md for the fix detail
and the two rounds of HOLD feedback). picker_config.picker_version is now 'v12', set 2026-09-25
12:26 Dubai, more than 30 minutes before the 20:00 Dubai draft cron. v12 is authoritative from
tonight's draft for plan_date 2026-09-27 onward. Rollback: set picker_version back to 'v11' with a
mutation_reason naming the regression.

The F1-F9 fixes changed pick_machines_v12's real behaviour from what B2 first shipped: the cap now
governs the whole output including P1 (not just non-P1 rows); clustering reads real
machines.building_id (seeded for named building groups) instead of a naming-convention guess and
never applies to a machine that already independently qualifies P1/P2; donor criteria are tightened
to a primary-warehouse pickable check, a stock floor, fleet-wide top-quartile receiver velocity, and
a real receiver tier; expiry P1 requires WEIMI to confirm the same product on the lane with stock;
fill<50% P1 requires real velocity and above-median revenue, else downgrades to P2; and
visit_value_aed's sales_saved component is a real per-lane shortage sum, not a machine-level
runway approximation.

## Open item queued after cutover (not blocking)

F10 (CS, next pass): visit_value_aed's sales_saved component uses each machine's own rhythm_days as
its horizon, so a slow machine (10-day rhythm) sums shortage over a longer window than a fast
machine (3-day rhythm), which can inflate its ranking relative to faster machines with a shorter
horizon. CS asked for a single common horizon, min(rhythm_days, 5), applied to every machine, with
a before/after ranking report for 2026-09-27. Not started; queued for the next work pass.

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
