# PRD-133-135: Selection Strategist v2 + Learning Tables

Status: DRAFT, recreated 2026-09-25 from the loop/selection-v2-2026-09-25 task brief. Not found
in the repo or the BOONZ BRAIN folder prior to this loop; authored here from the brief's own
Phase B and Phase C text so B1 onward has a PRD to point at, per this loop's own STATE.md note.

## Background

Evidence day: plan_date 2026-09-25, 8 machines, 102 dispatch rows, 246 units, LIVE and dispatched.
Of the 102 lines, 50 came from the current picker/engine (v11, pick_machines_for_refill) and 52
were hand-built by CS as manual strategy on top. That split is the working definition of the
problem PRD-133 through PRD-135 exist to close: the current picker leaves roughly half of a day's
real decisions to manual judgment. PRD-133 is the new picker engine (v12). PRD-134 is the
knowledge layer that feeds it product-specific and SKU-specific intent (no logic yet, seeded
data only, this loop). PRD-135 is the shadow/cutover mechanism (picker_config) that lets v12 run
alongside v11 without replacing it until proven.

## PRD-133: pick_machines_v12

### Switch (picker_config)

Table `picker_config(key text primary key, value text, updated_at timestamptz, updated_by uuid)`.
Seed row: `picker_version = 'shadow'`.

Semantics:

- `v11`: current picker only, unchanged behavior.
- `shadow`: v11 decides which machines are actually picked; v12 also runs on the same plan_date
  and writes its own picks to `machines_to_visit_shadow` for comparison, never affecting the real
  plan.
- `v12`: v12 decides; v11 still runs, writing its output to the shadow table instead, so the two
  can keep being compared after cutover.

The switch is read at the single entry point used by `build_draft_for_confirmed` and the 6am
pre-pick job. No other call site branches on picker_version.

### pick_machines_v12(p_plan_date date, p_cap int default 8)

Returns `table(machine_id uuid, official_name text, tier text, visit_value_aed numeric,
reasons text[], building_id uuid, cluster_role text, donor_for jsonb)`.

Inputs:

- Latest WEIMI snapshot per machine (`weimi_aisle_snapshots`, latest `snapshot_at`, the feed
  refreshes every 4 hours).
- Lane velocity from `v_lane_grain`.
- `pod_inventory` for expiry only, never for stock level (WEIMI is the stock source of truth).
- Warehouse pickability from `v_wh_pickable`.
- The effective `product_mapping` set: machine-scoped Active rows override global defaults for
  the same pod product; never a raw join that fans out across every mapping row.
- Net same-day deliveries: any dispatch row with `driver_confirmed_at` after the machine's latest
  snapshot adds its quantity to that lane's stock, so a machine already refilled today isn't
  double-counted as still empty.

Tiers:

**P1 (always picked, bypasses cooldown):**

- Expired stock physically on the shelf.
- A lot expiring on or before `p_plan_date` with WEIMI stock still greater than zero.
- The machine's own top-2 lanes by velocity: either empty, or under 1 day of cover.
- Two or more lanes empty.
- Overall fill under 50%.

**P2:**

- `days_since_visit >= rhythm`, where rhythm comes from `pick_rhythm_params`: top revenue tercile
  (trailing 3-day revenue) gets a 3-day rhythm, mid tercile 7 days, slow tercile 10 days.
- The top lane will run out before the next scheduled visit.
- Any lane is empty (even if the product has zero warehouse stock; the refill engine, not the
  picker, decides swaps).

**P3:** ride-along candidate, picked only if cap allows after P1/P2/cluster/donor.

**Skip:** visited within the last day with no P1 trigger.

**Venue-supplied (VOX) machines**, all lanes venue_team: P1 only on expiry or an empty hero lane;
"hero lane running out" alone is never enough for P1. The existing v11 Wed/Fri VOX visit gate is
unchanged.

**Ordering inside a tier**, by `visit_value_aed`:
`visit_value_aed = sales_saved + expiry_avoided + donor_value`

- `sales_saved`: lost sales avoided between now and the next scheduled visit.
- `expiry_avoided`: value of stock that would otherwise expire unsold.
- `donor_value`: units of a warehouse-out-of-stock SKU a donor machine can release, multiplied by
  the receiving machine's price for that SKU.
  Not a single AED figure compared across tiers; tier always wins, value only orders within a tier.

**Cluster**: once any machine with a `building_id` is picked, every other machine in that same
building becomes a P3 candidate with `cluster_role = 'cluster'`, and is actually picked if it has
any P2/P3 need or donor value and the cap still allows it.

**Donor**: a machine holding a SKU with warehouse pickable stock of zero, on a lane with velocity
under 0.4 units/day, is a donor for any other machine with a top-quartile lane of the same pod
product below 50% fill. `cluster_role = 'donor'`, `donor_for` lists the receiving machine(s).

Cap: 8 total picks. Fill order: P1, then P2, then clusters/donors, then P3.

`reasons[]` are plain English, no em dashes, one entry per trigger that fired.

### v_picker_shadow_diff(plan_date)

Side-by-side view: v11's actual picks vs v12's picks for the same plan_date, each with tier and
reasons, for manual comparison during shadow mode.

### backtest_priority(p_from date, p_to date)

Replays each day from `p_from` to `p_to` using that day's own WEIMI snapshot (not today's), for
both pickers. Metrics per picker, stored in `picker_backtest_results`:

- Critical lane-days unserved: a lane at velocity >= 1/day sitting at zero stock or under 1 day of
  cover, not visited the next day.
- Low-need visits: a visit where no lane was under 4 days of cover.
- Expired units left on shelf for more than 1 day.
- Slow machines never visited in 10 or more days.
- VOX false P1 count: VOX machines picked as P1 for a reason other than expiry or an empty hero
  lane.

### Acceptance (2026-09-25 replay, snapshot as of 2026-09-24 22:00 Dubai)

- v12 must pick AMZ-1029-3003-O1 as P1 (Activia expiring 2026-09-25).
- v12 must NOT pick VOXMCC-1005-0201-B0 as P1.
- v12 must surface AMZ-1068-2401-O1 and VML-1004-0500-O1 as donors (Vitamin Well / Red Bull /
  Krambals).
- v12 must pull AMZ-1046-2406-O1 in via the building-24 cluster once AMZ-1068 is picked.

### Tests

`supabase/tests/selection_v2.sql`: one assertion group per rule above (each P1 trigger, each P2
trigger, the VOX gate, the cap, the cluster rule, the donor rule, the cooldown bypass on P1). All
must pass before any cutover.

## PRD-134: Knowledge tables (seed only, this loop; no scoring logic yet)

- `product_lane_fit(pod_product_id, machine_id, shelf_code, ...)`: which physical lanes a product
  is allowed to occupy. Seed: Dubai Popcorn fits A15 and A16 only.
- `sku_intents(boonz_product_id, machine_id, intent, threshold, note, ...)`: operator-declared
  intent per SKU per machine. Seed: Red Bull 355ML on AMZ-1029-3003-O1 deplete at threshold 4;
  Zigi temp_out fleet-wide, ETA 2026-10-02; Smart Gourmet Hummus temp_out fleet-wide; Krambals
  keep; Vitamin Well push to top machines.
- `cannibal_pairs(product_a, product_b, note, ...)`: products that cannibalize each other's sales
  when co-located. Seed: Nutella Biscuits T3 vs Nutella Biscuits T12.

RLS on all three: `operator_admin` write, any `authenticated` role read.

No scoring or picker logic reads these yet in this loop; they exist so PRD-134's later scoring
work has real seeded data to build against.

## PRD-135: Engine safety flags (this loop: evidence only, default OFF)

`refill_policy_params.slow_lane_fill_cap_pct` (default NULL, meaning off). When set,
`engine_add_pod` caps the fill target for any lane with velocity below
`hero_velocity_floor / 3` at that percentage of `max_stock`, instead of filling to max. This loop
only backtests what a 60% cap would have changed on the 2026-09-25 evidence day and records the
numbers in the loop's REPORT.md; the flag is never enabled.

## Non-goals for this loop

- No cutover to v12 without CS explicitly typing "GO v12".
- No scoring logic against the PRD-134 knowledge tables yet, seed data only.
- No enabling of `slow_lane_fill_cap_pct`.
- No changes to `pick_machines_for_refill` (v11) itself beyond the picker_config switch at its
  single call site.
