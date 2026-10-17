# PRD-142: Strategic Oversight (machine intelligence, machine and shelf strategy, product intelligence)

Status: DRAFT v2 for CS green-light. Written 2026-10-17, revised the same evening with the Portfolio Map handover folded into the product module.
Owner: CS. Builder: Claude Code loop. Cody review on every SECURITY DEFINER function and on the engine hook.
Runs as two loops: PRD-142a (additive: data layer, machine and product intelligence, UI) can run in parallel with PRD-141; PRD-142b (engine hook and retirement) runs only after PRD-141 has released its lock. See section 1.1.

## 0. Why

Every signal in the ERP today is bottom-up and daily: slot_lifecycle, product_lifecycle_global, P1/P2 picker, compute_refill_decision. They answer "what goes into this lane tomorrow". Nothing answers "what is this machine, what is this product, and what posture should the refill engine take because of it". Decisions of that kind are currently made by CS by hand and dictated as rules (Vitamin Well to best sellers, dead-lane stock to selling machines, no new products on VOX). PRD-142 builds the layer that makes those calls visible, proposes them, and feeds the confirmed posture back into the engine through a table it already reads.

Three modules, one page, one fact layer:

1. Machine Intelligence (observe): KPIs, adoption curve, shelf lens, archetype classification.
2. Machine and Shelf Strategy (decide): 2x2 posture per machine, CS confirms, engine obeys.
3. Product Intelligence (observe and decide): the Portfolio Map (velocity x coverage, prime and retention, demand faded vs supply stopped, playbook) rebuilt inside the ERP on the fact layer, plus what works where by archetype and category balance, with a product posture feeding procurement and the swap pool.

## 1. Decisions already taken by CS (17 Oct 2026)

- Revenue basis for all strategic numbers: paid_amount minus refunded_amount, ex-VAT (divide by 1.05 for UAE VAT-inclusive rows). VAT-inclusive stays only in VOX statements.
- Inception = first sale in the current era.
- Classification (archetypes) and strategy (2x2 posture) are two separate layers. Archetypes can be more than four, named by what the machine is. The 2x2 is four postures: Protect and Grow, Fix the Mix, Watch and Adapt (problem is outside the machine), Not Flippable.
- K-means is a diagnostic to discover and validate archetypes, not the primary view. Archetype assignment rules are then locked in a table so labels are stable month to month.
- Partner-sourced machines (venue_group VOX, LVLUP, LEVELUP, or official_name containing ACTIVATE / IFLY / VOX / MPMCC / LVLUP / LEVELUP, the PRD-087 and Portfolio Map rule) are a separate population for benchmarks, archetypes and postures. Never blended with Boonz-sourced.
- Lives in the ERP at /app/strategy with two tabs (Machines, Products). Shelf lens is a drill-down inside Machines. The old tabs it replaces are retired (section 7.1).
- The product module reuses the Portfolio Map definitions (handover claude/HANDOVER-portfolio-map-2026-10-17.md) as implemented and validated on 2026-10-10, instead of the earlier peak-month lifecycle shape.

### 1.1 Two loops, so 142a can run beside 141

- PRD-142a (additive only): Phases 1, 2, 4 and 5. Creates new tables, functions, views, pg_cron jobs and one new route. Touches no function PRD-141 edits (engine_add_pod, engine_swap_pod, pick_machines_for_refill, get_procurement_demand, write_refill_plan, add_dispatch_row, any field or warehouse function, v_live_shelf_stock, v_shelf_sales_identity, planner views). Lock file docs/prds/PRD-142a.lock; it coexists with PRD-141.lock. Every migration version is taken at apply time (now()), never pre-numbered, and the loop runs git pull origin main before every commit so the two loops interleave on main. Nightly jobs are scheduled outside 20:00 to 23:00 Dubai (cron 13 and the draft build) and outside PRD-141's night window writes: fixed at 03:30 Dubai.
- PRD-142b: Phase 3 (strategy tables, writer RPCs, engine hook) and 7.1 retirement. Lock docs/prds/PRD-142b.lock; stops if PRD-141.lock exists. Night window rules apply to the engine edits.
- The split costs nothing functionally: 142a ships a complete read-only strategy page with proposed postures; 142b makes the postures bite.

## 2. Prod baseline (17 Oct 2026, verified)

- 35 machines with include_in_refill = true; 9 partner, 26 Boonz.
- sales_history 2026: 51,424 rows. goods_slot populated on 100% of rows (shelf key is safe). cost_amount is 0 or NULL on 38.8% of rows (profit needs a fallback). 12 rows with machine_id NULL (ignore).
- slot_name and route_name are poisoned since 17 Apr 2026 (loader defect). Never key on them. goods_slot only.
- boonz_products: 158 rows with avg_cost 0 or NULL; 3 rows with no product_category. supplier_products.last_unit_price_aed exists as the better COGS source.
- machines: 16 live machines have no installation_date. repurposed_at and relaunched_at exist. No machine era table exists. PRD-138 VOX era migrations (4 files, 2026-09-28) define eras for VOX machines only and are being committed by PRD-141 Block A.
- Existing objects to reuse, not rebuild: product_lifecycle_global, slot_lifecycle, get_product_performance, get_product_velocity_ledger(p_weeks, p_scope, p_level), get_machine_health, v_shelf_capacity, strategic_intents, strategic_machine_tags (read by engine_swap_pod Pass 1), lifecycle_product_status, refill_settings, product_name_conventions (pod name normalisation used by the Portfolio Map), product_mapping (warehouse stock per pod product, with fan-out on mixed pods).
- Shelf size is physical layout, not capacity: STANDARD_16 pos 01-08 Small, 09-14 Medium, 15-16 Large per cabinet; VOX_PREMIUM_13 (VOXMCC-1012, VOXMCC-1017, VOXMM-1001) A01-06 Large, A07-09 Medium, A10-13 Small. Shelf code from goods_slot: chr(65 + cabinet) || lpad(pos + 1, 2, '0').
- Portfolio Map prototype assets (template boonz_portfolio_map_v2.html, data builder, lifecycle.py with the playbook rules) are in BOONZ BRAIN/portfolio-map/ if CS copied them; otherwise the rules in section 6 are the spec. The weekly series SQL in the handover section 4 is the reference shape for 6.1.

## 3. Data layer (Phase 1, 142a)

### 3.1 machine_eras

Table machine_eras(era_id uuid pk, machine_id uuid, venue_label text, era_start date, era_end date null, source text, created_at). Seeded by migration:

- Boonz machines: one era from COALESCE(relaunched_at::date, repurposed_at, installation_date, first sale date) to now. Where relaunched_at or repurposed_at is set and sales exist before it, a closed prior era is created from first sale to that date with venue_label = previous_location.
- VOX machines: eras copied from the PRD-138 era definitions if they are in a table or view; otherwise the same rule as Boonz.
- A machine's "current era" = the era with era_end IS NULL. All lifetime KPIs default to current era; the UI has an "all eras" toggle.
- Nightly job checks for a new relaunched_at or repurposed_at and closes/opens eras; logs a monitoring row (a log, not an ack gate).

### 3.2 Daily fact tables (materialized, rebuilt nightly by build_strategy_facts(p_from date default current_date - 400))

All keyed on Dubai date (transaction_date AT TIME ZONE 'Asia/Dubai')::date. Sales basis = the Portfolio Map rule: delivery_status IN ('Success','Successful'), rows where refunded_amount >= paid_amount excluded, pod names normalised through product_name_conventions.official_name, machines with is_test or venue_group 'WH' or official_name starting WH excluded.

- fact_machine_daily(machine_id, era_id, d date, units, gross_aed, refunds_aed, net_rev_exvat, cogs_aed, cogs_coverage_pct, gross_profit_aed, txns, baskets, card_txns, cash_txns, hour_profile jsonb (24 buckets of units), active boolean).
  - active = the machine was in an open era on d. Days with zero sales inside an open era count as active with zeros.
  - cogs per row = COALESCE(sales_history.cost_amount when > 0, qty * supplier_products.last_unit_price_aed for the preferred supplier, qty * boonz_products.avg_cost, NULL). cogs_coverage_pct = share of units with a non-NULL cost. Partner-sourced machines: cogs = NULL, gross_profit = net_rev_exvat * boonz_share from refill_settings key 'partner_revenue_share' (jsonb per venue_group; if not set, NULL and the UI shows "share not configured").
  - baskets = count distinct of the internal_txn_sn prefix before the "_".
  - card vs cash from classification_name or delivered_from; if neither is reliable, card = rows with a matching Adyen reference (internal_txn_sn join), cash = the rest. Record which rule was used in the function comment.
- fact_shelf_daily(machine_id, era_id, d, shelf_code, size_class, pod_product_id, units, net_rev_exvat, max_stock). shelf_code from goods_slot; size_class from the layout rule; max_stock from v_shelf_capacity.
- fact_product_machine_daily(pod_product_id, boonz_product_id, machine_id, era_id, d, units, net_rev_exvat, cogs_aed, population).
- fact_product_weekly(pod_product_id, week_start (Monday, Dubai), population, units, machines_selling, fleet_machines_selling): the Portfolio Map weekly series, 60 weeks kept (the handover flagged 48 as too short for seasonality), built from fact_product_machine_daily.

Indexes on (machine_id, d), (pod_product_id, d), (machine_id, shelf_code, d), (pod_product_id, week_start). Rebuild idempotent (delete window, insert). Runtime target under 60 s for 400 days. Register every table and formula in METRICS_REGISTRY.md.

### 3.3 Machine feature snapshot

Table machine_features(machine_id, as_of date, era_id, age_days, rev_day_90, units_day_90, gp_day_90, ticket_90, units_per_basket_90, card_share_90, peak_hour_share_90 (share of units in the top 3 hours), weekend_share_90, weekday_lunch_share_90 (11:00 to 14:59 Mon to Fri), drinks_share_90 (boonz_products.attr_drink), top5_shelf_share_90, dead_shelf_pct_90, cv_monthly_12 (NULL under 4 full months), trend_30_vs_90 (last 30 days daily avg over prior 60 days daily avg, minus 1), ramp_index (machines under 90 days: cumulative rev at age N over the Boonz fleet median cumulative rev at age N), population). Rebuilt nightly after the facts. Keep 400 days.

### 3.4 Product supply snapshot

Table product_supply_daily(pod_product_id, d, wh_units_central, wh_status text (stocked / low / none: none <= 5, low <= 2 weeks of cover, else stocked), deployed_units, open_po_units, weeks_of_cover numeric). wh_units via product_mapping to warehouse_inventory (Central, Active, not quarantined, not expired). Mixed and catch-all pods (pod_products.is_catchall, and the known fan-out list: Chocolate Bar, Soft Drinks Mix, Vitamin Well, Tannourine, Sun Blast) carry wh_status only and wh_units NULL, because mapping fan-out inflates the count (handover section 7). Open PO units are shown, never treated as fuel. weeks_of_cover = wh_units / current 4-week weekly rate (NULL when either side is unknown).

## 4. Module 1: Machine Intelligence (Phase 2, 142a)

### 4.1 RPC get_strategy_machines(p_population text, p_window text default '90d', p_all_eras boolean default false)

One row per machine: identity (official_name, venue_group, location_category, era start, age), KPI block (avg daily, avg monthly full months only, lifetime current era: units, net rev, gross profit, cogs coverage), characteristics (ticket, basket, card share, peak hours, weekend share), shelf block (top5 share, dead pct, concentration label: Balanced if top5 share < 45%, Skewed 45 to 65, Concentrated > 65), archetype, archetype_benchmark (median rev_day_90 and gp_day_90 of the same archetype and population), posture, posture_proposed, diagnosis (5.2), ramp_index for young machines. Windows 30d, 90d, 12m, era.

### 4.2 RPC get_strategy_machine_detail(p_machine_id)

Returns: daily series for the era (units, net rev, GP); T+ adoption series (day index from first sale, rolling 7-day rev and units, cumulative, plus the Boonz fleet median curve at the same day index); monthly table (full months); hour-of-day and weekday profiles; shelf table (per shelf: size, current product, units/slot/day, rev/slot/day, fleet percent rank, quadrant Prime / Volume-cheap / Premium-slow / Dead / Too new, slot age); product table for the machine (per pod product: units, rev, GP, share, velocity here vs the product's fleet median and vs sibling machines in the same venue_group or building: Local hero / On par / Underperformer, the IRIS-1070 analysis generalised); category balance (6.3).

### 4.3 Archetypes

Table machine_archetypes(code pk, label, population, description, rule jsonb, sort_order). Table machine_archetype_assignment(machine_id, as_of, archetype_code, method text ('rule' or 'manual'), confidence numeric, features jsonb).

Step 1 (diagnostic, output committed as docs/prds/PRD-142-kmeans.md): K-means on the Boonz population over the standardized features (rev_day_90, units_day_90, ticket_90, card_share_90, peak_hour_share_90, weekend_share_90, weekday_lunch_share_90, drinks_share_90, top5_shelf_share_90, dead_shelf_pct_90, cv_monthly_12) for k = 3 to 6, silhouette per k, centroids, machine list per cluster. plpython if available, otherwise scripts/strategy/kmeans_diagnostic.py via the service key. Machines under 90 days excluded.

Step 2: seed machine_archetypes with rules written from the centroids. Starting set (the loop adjusts thresholds to the centroids, keeps the names unless the data contradicts them, logs the reasoning):

- RAMPING: age_days < 90 (any population). Benchmark = ramp curve, not peers.
- OFFICE_LUNCH_ENGINE: weekday_lunch_share >= 0.35 and units_day >= population median.
- PREMIUM_OFFICE: weekday_lunch_share >= 0.25 and ticket >= population 70th percentile and units_day < median.
- GYM_GRAB: peak_hour_share >= 0.45 with peaks outside 11 to 15 and drinks_share >= 0.5.
- LOBBY_TRICKLE: peak_hour_share < 0.30 and units_day < population 40th percentile.
- SEASONAL_SWINGER: cv_monthly_12 >= 0.45 (overrides the above when true, base archetype kept in features).
- Partner population: CINEMA_IMPULSE (weekend_share >= 0.4), VENUE_STANDARD (the rest), RAMPING as above.
  Rules evaluate in sort_order, first match wins, manual override from the UI (method = 'manual', kept until CS clears it). Nightly assignment; an archetype change writes strategy_change_log and shows in the UI for 14 days.

## 5. Module 2: Machine and Shelf Strategy (Phase 3, 142b; the proposal job and diagnosis are computed in 142a as read-only columns)

### 5.1 Posture 2x2

Vertical axis, "worth it today": performance_index = gp_day_90 / archetype benchmark gp_day_90 (fallback rev_day_90 when GP is NULL). Strong if >= 0.85. RAMPING: ramp_index >= 0.8 is Strong.
Horizontal axis, "problem inside or outside": mix_gap = 1 - (actual net rev 90d / expected net rev 90d), expected = sum over the machine's current lanes of (that pod product's median rev per slot per day on peer machines of the same archetype, or population when fewer than 3 peers) * days * slots. Inside if mix_gap >= 0.25 or dead_shelf_pct_90 >= 0.35. Outside otherwise.

Postures and params:

- PROTECT_GROW: Strong. fill_depth = full, swap_mode = dead_lanes_only, allow_new_products = true (false for partner), seed_source = true.
- FIX_MIX: Weak and Inside. fill_depth = standard, swap_mode = aggressive (slot_lifecycle DEAD and ROTATE OUT lanes plus any lane under 40% of the peer median), allow_new_products = true, cabinet_reset_flag when dead_shelf_pct >= 0.5.
- WATCH_ADAPT: Weak and Outside. fill_depth = conservative (base stock only), swap_mode = dead_lanes_only, allow_new_products = false, review_by = as_of + 45 days, venue_check_flag = true.
- NOT_FLIPPABLE: Weak and Inside for two consecutive monthly reviews after a FIX_MIX cycle, or Weak and Outside for 90 days with trend still negative. fill_depth = minimum, swap_mode = none, allow_new_products = false, drain_source = true, relocate_flag = true.
  Never auto-escalated to NOT_FLIPPABLE; the model proposes, CS confirms.

### 5.2 Diagnosis text

One SQL-generated sentence per machine from the components, e.g. "GP 62% of Office Lunch Engine benchmark. Mix gap 31%: lanes A03, A07, B12 under 40% of peer median. Dead shelves 38%. Drinks over-shelved (lanes 40%, rev 15%)." or "Rev down 28% vs prior 60 days with mix on par. Baskets per day down 24%. Outside the machine." No free text.

### 5.3 machine_strategy

Table machine_strategy(machine_id pk, archetype_code, posture, posture_proposed, proposed_at, proposed_reason text, confirmed_at, confirmed_by, review_by date, params jsonb, shelf_overrides jsonb (list of {shelf_code, action: lock | reset | swap_now, note}), notes text, updated_at). History in strategy_change_log(log_id, entity text ('machine' | 'product'), entity_id uuid, field, old_value, new_value, changed_by, changed_at, source 'model' | 'cs').
Writer RPC set_machine_strategy(p_machine_id, p_posture, p_params jsonb, p_shelf_overrides jsonb, p_notes) SECURITY DEFINER, operator_admin and superadmin only, REVOKE from public and anon, GRANT to authenticated, audited. The nightly job writes posture_proposed and proposed_reason only; it never touches posture. In 142a the table and the proposal job exist and the UI shows proposals; the writer RPC and the review buttons ship in 142a too (they are additive), so CS can start confirming postures before 142b makes them bite.

### 5.4 Review screen

/app/strategy > Machines > "Review proposals": machines where posture_proposed differs from posture, with diagnosis, both postures side by side and the params diff. Accept, Accept with edits, Reject (logs reason, suppresses the same proposal 30 days). Also archetype changes and machines past review_by.

### 5.5 The engine hook (142b; how this becomes effective)

1. View v_machine_posture_params(machine_id, posture, params, shelf_overrides) = machine_strategy joined to strategy_posture_defaults. Machines without a confirmed posture return PROTECT_GROW defaults for Boonz and VENUE_STANDARD defaults for partner (today's behaviour, no regression).
2. engine_add_pod reads fill_depth. full = current fill-to-capacity; standard = current with PRD-048 base stock; conservative = base stock only; minimum = only lanes at zero, to base stock. One CASE on an existing quantity line.
3. engine_swap_pod Pass 1 reads swap_mode, allow_new_products and shelf_overrides at the point where strategic_machine_tags is read. none = skip the machine; dead_lanes_only = slot_lifecycle signal in (DEAD, ROTATE OUT); aggressive = also lanes under 40% of the peer median (helper v_lane_vs_peer_median); allow_new_products false = candidate pool restricted to products already live on the machine or venue. shelf_overrides swap_now lanes get priority 1, lock lanes are excluded; overrides are materialized as strategic_machine_tags rows (proposed_by_engine = 'prd142_posture') so the existing approve/consume lifecycle applies.
4. Swap guard (from the IRIS-1070 finding): engine_swap_pod never proposes removing a lane whose current product runs at or above that product's fleet median velocity at this machine, whatever the posture; new lines are seeded on DEAD lanes first. Rollback file and a fleet diff like the others.
5. Picker (pick_machines_for_refill v12): one additive multiplier only, NOT_FLIPPABLE 0.5 and WATCH_ADAPT 0.8, from params key picker_multiplier, default 1.0, behind refill_settings key 'prd142_picker_multiplier_enabled' default false.
6. Transfers (drain): nightly, for each NOT_FLIPPABLE machine, on-shelf stock whose product is Local hero or On par on a PROTECT_GROW or FIX_MIX machine with an open lane or a lane under base stock gets a strategic_machine_tags row action_directive = 'TRANSFER' with the destination in reasoning. Recommendation only; the existing M2M flow executes on CS approval.
7. Product posture (6.4) feeds the swap pool: EXIT and DRAIN excluded as Add candidates everywhere; RESOURCE excluded until wh_status is stocked; GROW products get +1 priority on machines of their target archetypes.
8. Learning loop: every posture change and every prd142-tagged swap or transfer is stamped with the machine's rev_day_90 and gp_day_90 at that date; the machine card shows the 30 and 60 day delta against archetype peers over the same window. No automatic tuning in this PRD.

All engine changes: rollback file, refill_settings keys ('prd142_fill_depth_enabled', 'prd142_swap_mode_enabled', 'prd142_swap_guard_enabled', default true but inert until a posture is confirmed, swap guard default true for all), full-fleet before/after draft-plan diff in a rolled-back transaction pasted in the log, night window only.

## 6. Module 3: Product Intelligence (Phase 4, 142a)

This is the Portfolio Map (handover 2026-10-17) rebuilt on the fact layer, with archetypes added. Definitions are the handover's, as validated on the 2026-10-10 snapshot (Activia and YoPRO land in Missed the wave, Coke Mix in Double down); the loop must reproduce those three placements on the current data as a regression check.

### 6.1 RPC get_strategy_products(p_population text default 'boonz', p_position text default 'trails')

Unit = pod product after product_name_conventions normalisation (the Portfolio Map unit), rolled up to boonz_product_id for procurement, drill to machine. Window = last 8 complete Monday weeks (current), computed from fact_product_weekly. Per product:

- velocity = units / machine-weeks with a sale (units per machine per selling week). This is the strategic velocity; the Performance tab's older units / distinct machines / 8 is not comparable and is retired with that tab.
- coverage = average weekly machines selling it / machines with any sale in the population that week.
- prime = the product's best 4-week window by velocity over the 60-week series, requiring >= 16 units and >= 8 machine-weeks (fallback >= 4), velocity <= 40. retention = current velocity / prime velocity. momentum = last 4 weeks vs the 4 before (up > +15%, down < -15%). prime_weeks_ago.
- maturity: New < 3 months, Growing 3 to 6, Established 6 to 12, Mature 12+, from first-ever sale.
- supply (3.4): wh_status, weeks_of_cover, open_po_units, deployed_units.
- quarantine flags: superseded (renamed or split pods: Krambals and Zigi, Pepsi Mix, Healthy Cola - Mix, kept in a small table product_superseded(pod_product_id, successor_pod_product_id, note) that CS extends when pods are renamed) and anomaly (prime velocity > 40 or one week >= 60% of all units with no current sales). Both excluded from the map and listed separately.
- cluster: 8 groups mapped from pod_products.product_category (Water and sparkling, Soft and energy drinks, Health and protein drinks, Bars protein and dates, Chocolate and candy, Biscuits cakes and crackers, Chips and popcorn, Fresh and dips) in table product_clusters(product_category pk, cluster_code). The 3 products with no category go to a 9th "Unclassified" row and are listed for CS to fix.
- net rev, GP, cogs coverage over the 8 weeks; medians for velocity and coverage computed over live products with >= 8 units.
- playbook (6.2), posture (6.4), best and worst archetypes (6.3).
- For p_position = 'prime' the velocity and coverage are the prime-window values; 'trails' returns both so the UI draws prime to now.

### 6.2 Playbook (the product lifecycle read, rules in this order, first match wins)

1. superseded: excluded.
2. anomaly: excluded.
3. INCUBATE: under 3 months.
4. MISSED_THE_WAVE: prime velocity >= today's median and prime >= 20 units and wh_status = none and now below prime (retention < 0.7, or coverage < 60% of prime coverage, or units down) and prime >= 4 weeks ago. Demand was proven; supply stopped.
5. COOLED_OFF: same strong prime, retention < 0.5, still stocked. Demand faded.
6. current < 8 units: EXIT if >= 6 months, else INCUBATE.
7. DOUBLE_DOWN: velocity >= median, coverage < 50%, and (top-quartile velocity or coverage < median).
8. PROTECT: velocity >= median otherwise. Flag fuel_risk when weeks_of_cover < 2.
9. REDUCE_REPLACE: velocity < median, coverage >= median.
10. EXIT: the rest at >= 6 months; INCUBATE if 3 to 6 months.
    Each label carries the numbers that fired it in a reason jsonb. "Used to work" = MISSED_THE_WAVE and COOLED_OFF, split by cause. "Has legs" = DOUBLE_DOWN, and INCUBATE with velocity in the top quartile.

### 6.3 What works where and category balance

- RPC get_strategy_product_archetype_matrix(p_population): product x archetype, cell = velocity per selling machine-week and its ratio to the product's fleet velocity, plus the machine count. This turns DOUBLE_DOWN into "double down where" and gives target_archetypes for the posture. Heatmap in the UI.
- Cluster summary: per cluster, revenue, count by playbook label, and the one-line read the handover produced by hand (e.g. "Soft and energy: 6 of 8 double-downs, under-distributed; the fix is can lanes not SKUs") generated as counts, not prose.
- Category balance per machine: share of lanes by cluster vs share of net rev by cluster over 90 days; gap = rev share minus lane share; <= -0.15 over-shelved, >= +0.15 under-shelved. Feeds the FIX_MIX diagnosis sentence.
- Cannibalisation flag (backlog item 7, cheap): within a cluster, two products on the same machine where one's velocity rose >= 30% in the 4 weeks after the other was added and the cluster total did not; shown on the product detail, no action.

### 6.4 product_strategy

Table product_strategy(pod_product_id pk, boonz_product_id, posture text in (GROW, HOLD, RESOURCE, DRAIN, EXIT), posture_proposed, proposed_reason jsonb, target_archetypes text[], confirmed_at, confirmed_by, notes, updated_at); history in strategy_change_log (entity = product). Proposal mapping from the playbook: DOUBLE_DOWN -> GROW with target_archetypes = the archetypes where its ratio >= 1.2 and coverage is lowest; PROTECT -> HOLD (fuel_risk raises a restock line in the weekly procurement suggestion, backlog item 1); MISSED_THE_WAVE -> RESOURCE (re-source or formally exit; proposal only, reason shows the unserved units per week at prime); COOLED_OFF and REDUCE_REPLACE -> DRAIN; EXIT -> EXIT; INCUBATE -> HOLD with a "new" flag. lifecycle_product_status inactive = EXIT confirmed. Writer RPC set_product_strategy, same security pattern. Consumers (142b): swap pool (5.5 item 7) and get_procurement_demand (EXIT and DRAIN excluded from the weekly PO suggestion; RESOURCE listed in a separate "decide" block with the open PO quantity so the Zigi 546 and Evian 120 type of question is visible; behind refill_settings key 'prd142_procurement_posture_enabled' default true).

### 6.5 PO hygiene lens (backlog item 6, read-only, 142a)

On the Products tab: open PO units against products whose playbook is COOLED_OFF, REDUCE_REPLACE or EXIT, with the weeks of cover the PO would create. List only.

## 7. UI: /app/strategy (Phase 5, 142a)

Route gated to operator_admin and superadmin via the PRD-140 access model (access area 'strategy' if access_areas exists, else the existing role check).

Machines tab:

- Population toggle (Boonz / Partner), window selector (30d, 90d, 12m, era), all-eras toggle.
- KPI strip: machines, net rev per day, GP per day, cogs coverage, machines by posture.
- 2x2 (performance_index on y, mix_gap on x, points sized by rev_day, coloured by archetype, quadrant labels are the four postures, click opens detail). Archetype legend with counts.
- Table: all columns of get_strategy_machines, sortable, filters by archetype and posture, posture badge with "proposed" indicator.
- Review proposals panel (5.4).
- Machine detail drawer: KPI cards (daily / monthly / lifetime), T+ adoption chart with fleet median overlay and rev/units toggle, hour and weekday profiles, shelf grid (cabinet layout coloured by quadrant), product table with here vs fleet vs siblings, category balance bars, posture editor (params, shelf overrides, notes), posture history and outcome deltas.

Products tab (the Portfolio Map, in the ERP):

- Scope toggle (Boonz / Partner / All), Position (Current / At prime / Trails, default Trails), playbook chips (Double down, Protect, Missed the wave, Cooled off, Reduce and replace, Incubate, Exit) that isolate, cluster filter, min units slider, label all, hover and pin tooltips with the 60-week sparkline (backlog item 3).
- 2x2 velocity x coverage with median lines, maturity as a single-hue ordinal ramp, trails from prime to now; alternate x axis AED per facing (velocity x price, backlog item 2).
- KPI strip: products shown, units and net rev in the 8 weeks, counts per playbook label, unserved units per week at prime across MISSED_THE_WAVE (the "proven demand we are not serving" number).
- Per-cluster table and sortable full table with posture badge and proposed indicator.
- Product x archetype heatmap; PO hygiene list (6.5); superseded and anomaly lists.
- Product detail drawer: weekly series since first sale with prime window shaded, best and worst machines, archetype bars, supply block (wh status, weeks of cover, open POs, deployed), cannibalisation note, posture editor.

Charts use the chart library already in src (check what PRD-087 used) and the ERP palette. No new chart dependency.

### 7.1 Retire (142b, after the new page is verified)

- /app/lifecycle tabs HeatmapTab.tsx and DivestTab.tsx (Overview and Deep Dive stay until PRD-143 decides).
- /app/performance Product Performance tab (PRD-087 / PRD-104) and get_product_velocity_ledger if nothing else calls it (grep first; if the VOX dashboard calls it, keep the RPC and remove only the tab). The Portfolio Map artifact and its weekly manual refresh are superseded by the Products tab; note it in the report so CS can stop republishing it.
- Orphaned view v_swap_candidate_ranking (PRD-005) if still unreferenced.
- Redirects from removed routes to /app/strategy with the matching tab. Every removed route, component and RPC listed in the report.

## 8. Acceptance

142a:

- Fact tables rebuild nightly in under 60 s; fact_machine_daily.net_rev_exvat for Sep 2026 reconciles to sales_history for the same month within 0.5% (ex-VAT, net of refunds, Portfolio Map sales basis); both numbers in the report.
- Every live machine has an era, an archetype, a posture_proposed and a diagnosis; machines under 90 days show RAMPING with ramp_index.
- The K-means diagnostic doc exists with silhouette per k and the chosen rules justified.
- get_strategy_products reproduces the handover regression: Activia Mix and Go and YoPRO in MISSED_THE_WAVE, Coca Cola Mix in DOUBLE_DOWN, Nutella Biscuits T3 in INCUBATE (or the loop explains with numbers why the current data moved them).
- The unserved-demand KPI and the PO hygiene list are populated; the 3 uncategorised products are listed.
- CS can confirm a machine posture and a product posture from the UI; both appear in strategy_change_log within one second.
- Three-role smoke test: operator_admin sees /app/strategy with both tabs, review panel and both drawers; warehouse and field_staff do not see it and lose nothing.
- Migration parity both directions, overload check clean, anon-executable definer count still 0, no function PRD-141 edits was touched (list the functions diffed against PRD-141's log).

142b:

- With a FIX_MIX posture confirmed on one test machine, the next draft plan (rolled-back transaction) shows swap candidates on its under-peer lanes and no other machine's plan changes. With WATCH_ADAPT confirmed on one test machine the draft shows base-stock quantities only on that machine. With no posture confirmed the diff is empty.
- The swap guard blocks the removal of an above-median lane in the rolled-back diff (reproduce the IRIS Zigi case on a test machine).
- A product set to EXIT disappears from the swap candidate pool and from get_procurement_demand; a RESOURCE product shows in the decide block with its open PO.
- Retired tabs redirect; no console errors; parity and security gates as above.

## 9. Not in this PRD

Automatic weight tuning or self-learning (PRD-133 to 135 consumes the outcome deltas later). P1 scoring changes beyond the optional multiplier. Pricing. Venue contract economics beyond the partner share setting. Mobile app screens. Fixing the sales_history loader (slot_name, route_name) and the cost_amount gap at source (separate PRD; this PRD works around both).

---

## Claude Code prompt (paste everything below this line)

You are working in the boonz-erp repo (Next.js App Router, Supabase project `eizcexopcuoycuosittm`). Implement PRD-142 Strategic Oversight. First save this spec verbatim as `docs/prds/PRD-142-strategic-oversight.md` and commit it.

Which loop you are: the /goal that invoked you says PRD-142a or PRD-142b. If it says 142a, take the lock `docs/prds/PRD-142a.lock` (it may coexist with PRD-141.lock; stop only if another PRD-142a lock under 8 hours old exists), build Phases 1, 2, 4, 5 and the additive parts of Phase 3 (tables, writer RPCs, proposal job, review UI), and never touch engine_add_pod, engine_swap_pod, pick_machines_for_refill, get_procurement_demand, write_refill_plan, add_dispatch_row, any field or warehouse function, v_live_shelf_stock, v_shelf_sales_identity or any planner view. If it says 142b, take `docs/prds/PRD-142b.lock`, stop at once if PRD-141.lock or PRD-142a.lock exists, and build 5.5, the 6.4 consumers, and 7.1.

Hard rules:

- Every migration is a file in `supabase/migrations/` with the version taken at apply time (never pre-numbered), applied to prod, committed and pushed after every item, with `git pull origin main` before every commit so a parallel loop can interleave. Every SECURITY DEFINER function ends with `REVOKE EXECUTE FROM public, anon; GRANT EXECUTE TO authenticated` (or service_role only for the nightly jobs). Role checks use `auth.uid()` and the stored role. No overloads; overload check after each phase.
- Nightly jobs (pg_cron) at 03:30 Dubai, never between 20:00 and 23:00 Dubai.
- 142b engine edits only between 22:00 and 06:00 Dubai, each with a rollback file in `supabase/rollbacks/`, a full-fleet before/after draft-plan diff in a rolled-back transaction pasted into the log, Cody review, and the refill_settings keys named in 5.5 and 6.4. With no posture confirmed the diff must be empty: prove it.
- Reuse, do not rebuild: product_lifecycle_global, slot_lifecycle, v_shelf_capacity, strategic_machine_tags, product_name_conventions, product_mapping, the PRD-087 partner/boonz rule, the chart library already in src. Never change live pod or warehouse quantities. Never regenerate a live plan. Never key on sales_history.slot_name or route_name; goods_slot is the shelf key.
- Revenue = (paid_amount minus COALESCE(refunded_amount, 0)) / 1.05 on VAT-inclusive rows; document in METRICS_REGISTRY.md which rows are VAT-inclusive (check one day against the Adyen bridge and paste the check). Sales basis = delivery_status Success/Successful, fully refunded rows excluded, pod names normalised through product_name_conventions.
- Product module definitions are section 6 exactly (velocity per selling machine-week, 8-week current window, 4-week prime over 60 weeks, playbook order 1 to 10). Reproduce the handover regression (Activia, YoPRO in Missed the wave; Coke Mix in Double down) or explain the move with numbers.
- No em dashes anywhere. Dubai dates for all date logic. Surgical scope, no refactors, no renames outside 7.1.
- Running log `docs/prds/PRD-142-log.md` and report `docs/prds/PRD-142-REPORT.md` (shared by both loops, each appends under its own heading) updated after every item: DONE / ALREADY DONE (evidence) / ROLLED BACK (reason) / BLOCKED (exact reason). Do not ask CS questions; take the spec defaults and log every default you chose.

Step 0 (30 min): git pull origin main, take your lock, read this spec, the Portfolio Map handover if present in BOONZ BRAIN/portfolio-map/ or docs/, PRD-034 PRD.md, PRD-087 and PRD-104 notes, PRD-138 (era definitions), METRICS_REGISTRY.md. Record the prod baseline in the log: migration head, live machines by population, sales_history 2026 rows and cost_amount coverage, boonz_products with no avg_cost and no category, machines with no installation_date, whether a VOX era table or view exists, the chart library in src, whether access_areas exists, which routes and components serve /app/lifecycle and /app/performance, and (142b) whether PRD-142a-REPORT sections exist. If a baseline differs from section 2, log it and adapt.

142a time boxes: Step 0 30 min; Phase 1 (3.1 to 3.4) 180; Phase 2 (4.1 to 4.3 with the K-means doc) 180; Phase 4 (6.1 to 6.5) 180; Phase 3 additive (5.3 tables, set_machine_strategy, proposal job, 5.2 diagnosis) 60; Phase 5 UI (section 7 both tabs, review panel, drawers) 300; gates 45. Hard stop 16 hours after the lock.
142b time boxes: Step 0 20 min; 5.5 items 1 to 8 and the 6.4 consumers 240 (night window); 7.1 60; gates 45. Hard stop 8 hours after the lock or 06:30 Dubai.

Test evidence required: Phase 1 the Sep 2026 reconciliation and the rebuild timing; one machine with repurposed_at showing two eras; product_supply_daily for Hunter, Dubai Popcorn and Chocolate Bar (the last with wh_units NULL and status only). Phase 2 get_strategy_machines for every live machine with archetype, benchmark, posture_proposed and diagnosis; the K-means doc; one RAMPING machine with ramp_index. Phase 4 the regression placements with their numbers; one product per playbook label; the archetype matrix for the top 10 products; the unserved-demand KPI; the PO hygiene list. Phase 5 screenshots or DOM dumps of both tabs, the review panel and both drawers; the three-role smoke test. 142b: set_machine_strategy on a test machine visible in v_machine_posture_params; the rolled-back draft-plan diffs (FIX_MIX, WATCH_ADAPT, empty); the swap guard blocking an above-median lane; a product set to EXIT absent from the swap pool and from get_procurement_demand; a RESOURCE product in the decide block.

Gates before you stop: overload check clean; repo/prod migration parity both directions; anon-executable definer count still 0; nightly jobs scheduled and run once by hand with timing; (142a) a diff proving none of the PRD-141 functions changed; (142b) retired routes redirect; section 8 acceptance for your loop with PASS or FAIL and evidence. Final CS section in the report, plain English, no em dashes: items table, migrations, commits, what is on screen, the first list of proposed machine postures with the diagnosis sentence and the archetype counts, the product playbook counts and the unserved-demand number, what CS must do (Vercel deploy if not automatic, confirm the first postures, set partner_revenue_share per venue group, fix the 3 uncategorised products, extend product_superseded, and for 142b enable prd142_picker_multiplier_enabled when ready), and what is left. Delete your lock, commit "PRD-142a: release lock" or "PRD-142b: release lock", push. Last line of your section: "## PRD-142a DONE" or "## PRD-142b DONE".
