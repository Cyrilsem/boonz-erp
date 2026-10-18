# PRD-142 running log

Shared by PRD-142a and PRD-142b; each loop appends under its own heading.

## PRD-142a

### Step 0: baseline (2026-10-18 01:10 Dubai)

Worktree note: the boonz-erp-142a worktree was created in a sandbox, so its `.git` file points at a `/sessions/...` path that does not exist on this Mac. Git is driven with `GIT_DIR` and `GIT_WORK_TREE` set explicitly (nothing in the sibling checkout rewritten). Two stale empty lock files from the worktree creation at 01:01 (`worktrees/boonz-erp-142a/HEAD.lock`, `refs/heads/loop/prd-142a.lock`) were removed; no git process was running.

| Item                               | Spec section 2           | Prod 2026-10-18                                                                      | Note                                                                                        |
| ---------------------------------- | ------------------------ | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| Migration head                     | n/a                      | 20261017210334 (prd138_wsb_era_aware_eligibility)                                    |                                                                                             |
| Live machines (include_in_refill)  | 35 (9 partner, 26 Boonz) | 35 (9 partner, 26 Boonz)                                                             | same                                                                                        |
| sales_history 2026 rows            | 51,424                   | 51,649                                                                               | grew with new sales                                                                         |
| cost_amount 0 or NULL              | 38.8%                    | 39.0%                                                                                |                                                                                             |
| boonz_products avg_cost 0/NULL     | 158                      | 158                                                                                  |                                                                                             |
| boonz_products no category         | 3                        | 3                                                                                    |                                                                                             |
| Live machines no installation_date | 16                       | 16                                                                                   |                                                                                             |
| VOX era table or view              | none expected            | none; PRD-138 shipped a function `vox_machine_eras(uuid)` (repurposed_at split only) | Default: function, not table/view, so spec 3.1 says use the Boonz rule for VOX too. Logged. |
| plpython3u                         | n/a                      | not installed                                                                        | K-means runs in scripts/strategy/kmeans_diagnostic.py                                       |
| Chart library in src               | n/a                      | recharts ^3.8.1 (used by /app/lifecycle and /app/performance)                        | no new dependency                                                                           |
| access_areas                       | n/a                      | exists (PRD-140); FE has `useRequireArea` in src/lib/auth/access.tsx                 | new area `app.strategy` will be seeded for operator_admin and superadmin                    |
| /app/lifecycle                     | n/a                      | page.tsx, HeatmapTab.tsx, DivestTab.tsx                                              | 142b retires two tabs                                                                       |
| /app/performance                   | n/a                      | page.tsx                                                                             | 142b                                                                                        |
| anon-executable SECURITY DEFINER   | 0                        | 0                                                                                    |                                                                                             |
| machines.is_test                   | spec mentions it         | column does not exist                                                                | Default: exclusion is venue_group 'WH' or official_name starting WH only.                   |

Other findings that shape Phase 1:

- `sales_history` has no pod_product_id. Unit = `COALESCE(product_name_conventions.official_name, pod_product_name)` matched to `pod_products.pod_product_name`: 99.4% of 2026 success rows match (314 rows, 9 names unmatched; they stay in machine facts, not in product facts).
- `sales_history.boonz_product_id` is NULL on almost every row, so COGS fallback goes through `product_mapping` (machine-specific Active rows, else the global default), weighted by split_pct.
- goods_slot formats: `C-Ann` (cabinet, zero-based position, 97.6% of rows) and `itemN` (basket line items on multi-item vends, 2.4%). shelf_code is NULL for `itemN`.
- classification_name and delivered_from are empty on every recent row, so card vs cash cannot come from them. Adyen check (2026-09-30, last full Adyen day; Adyen feed stops 2026-10-01): Adyen transaction count equals sales baskets on every Boonz machine with a terminal (AMZ-1029 40 = 40, AMZ-1038 41 = 41, OMDBB 20 = 20, USH-1008 10 = 10). Rule chosen: card_txns = least(baskets, Adyen count for the machine-day) on days the Adyen feed covers, NULL otherwise; cash = baskets minus card.
- VAT: Adyen `value_aed` holds the pre-auth amount (1 AED Boonz, 20 AED VOX), not the captured basket, so it cannot reconcile revenue amounts. paid_amount is the consumer shelf price, and UAE consumer prices are VAT-inclusive, so every row is treated as VAT-inclusive (net_rev_exvat = (paid_amount - COALESCE(refunded_amount,0)) / 1.05). Logged as a default in METRICS_REGISTRY.md.
- Fully refunded rows in 2026: 0. 135 rows have paid_amount 0 (kept as units, zero revenue). Default: "fully refunded" = refunded_amount > 0 and refunded_amount >= paid_amount.
- Open PO = purchase_orders with received_date NULL and purchase_outcome NULL (44 lines). `not_purchased` lines are excluded.
- Central warehouse = WH_CENTRAL (warehouse_id 4bebef68-...).
- Partner machines that sell but have include_in_refill false: 4 VOX, 3 LVLUP. They get eras and facts; the strategy page lists include_in_refill machines plus any machine with a sale in the last 30 days.
- pg_cron: 03:30 Dubai = `30 23 * * *` UTC. Two existing jobs at that minute (bug006_007_nightly_check, prd129r machine health); both are checks, no conflict with PRD-141 writes.

### Item 3.1 machine_eras: DONE (01:12 Dubai)

Migration `20261017211208_prd142a_1_machine_eras.sql`: table `machine_eras` (one open era per machine, unique partial index), helpers `strategy_population(venue_group, official_name)` (the PRD-087 partner rule, one place) and `strategy_is_excluded_machine` (WH), and `sync_machine_eras()` (SECURITY DEFINER, service_role only) which seeds and then maintains eras nightly, writing a pre-acknowledged `monitoring_alerts` row (source `prd142_machine_eras`, a log not an ack gate) whenever it rolls or closes an era.

Seed result: 49 eras on 42 machines. 32 single eras (`seed`), 10 open eras from a relaunch/repurpose boundary, 6 closed prior eras, 1 archived machine. Live machines without an open era: 0.

Evidence, machines with two eras:

| Machine                  | Prior era (venue_label, dates)               | Current era start          |
| ------------------------ | -------------------------------------------- | -------------------------- |
| SAP-2002-0000-R1         | WH1-2002-0000-W0, 2026-01-14 to 2026-10-09   | 2026-10-10 (relaunched_at) |
| ACTIVATEMOE-2007-0000-B0 | LLFP-2007-0000-R0, 2026-02-13 to 2026-09-29  | 2026-09-30                 |
| ACTIVATEMCC-2005-0000-W0 | MPMCC-2005-0000-W0, 2026-04-23 to 2026-04-27 | 2026-04-28 (repurposed_at) |
| NISSAN-0804-0000-L0      | Warehouse, 2026-01-01 to 2026-05-10          | 2026-05-11                 |
| VOXDFC-1001-0100-V0      | VOXMM-1001-0100-V0, 2025-05-26 to 2026-09-27 | 2026-09-28                 |
| VOXDFC-2006-0200-B0      | LLFP-2006-0000-C0, 2026-02-14 to 2026-09-27  | 2026-09-28                 |

Defaults chosen: relaunched_at is converted to a Dubai date before use (NISSAN relaunched 2026-05-10 20:36 UTC = 05-11 Dubai). Machines with no boundary start at LEAST(installation_date, first sale) so no sale falls outside an era (NOOK installed 11-29, first sale 11-28). "Live" = include_in_refill or a sale in the last 30 days.

### Item 3.2 fact tables: DONE (01:20 Dubai)

Migration `20261017211607_prd142a_2_strategy_facts.sql`: `fact_machine_daily`, `fact_shelf_daily`, `fact_product_machine_daily`, `fact_product_weekly` (RLS on, admin-only select, anon revoked), helpers `strategy_shelf_code`, `strategy_size_class`, and `build_strategy_facts(p_from)` (SECURITY DEFINER, service_role only). Formulas registered in docs/architecture/METRICS_REGISTRY.md (section "PRD-142a").

The first run failed on an ambiguous column in the hour-profile CTE and then ran over 60 s because `v_shelf_capacity` (55 ms per call) was evaluated once per shelf-day group. Both fixed in place on prod (function body patched with CREATE OR REPLACE); the committed migration file is the fixed body, which is what prod runs.

Evidence:

- Rebuild: `build_strategy_facts(NULL)` = 5.06 s. Window 2025-08-18 to 2026-10-17. Rows: fact_machine_daily 10,468; fact_shelf_daily 31,172; fact_product_machine_daily 28,214; fact_product_weekly 3,750.
- Sep 2026 reconciliation: facts AED 79,872.74 net ex-VAT vs sales_history AED 79,872.74 on the same basis (0.0000%), 9,672 units both. Gross incl. VAT AED 83,866.38.
- Boonz Sep: COGS coverage 95.2% of units, gross margin 36.1%, card share 95.2% of baskets (on Adyen-covered days).

Defaults chosen: window = LEAST(p_from, Monday 60 weeks back) so fact_product_weekly always has 60 full weeks (spec default p_from of 400 days is under 60 weeks); facts end yesterday (Dubai), today's partial day excluded. fact_shelf_daily and fact_product_machine_daily are sparse (sale days only); dead shelves are measured against the current shelf configuration. population column added to fact_machine_daily and net_rev_exvat / machine_weeks to fact_product_weekly (additive). Machines with no shelf layout name match default to STANDARD_16; VOXDFC-1001 (renamed VOXMM-1001) keeps VOX_PREMIUM_13.

### Item 3.3 machine_features: DONE (01:25 Dubai)

Migration `20261017212319_prd142a_3_machine_features.sql`: `machine_features` (one row per machine with an open era per as_of, 400 days kept), `strategy_ramp_curve` (median cumulative net rev and units by day index from inception, per population, eras whose inception is inside the fact window, days 1 to 365), and `build_machine_features(p_as_of)` (SECURITY DEFINER, service_role only). Extra columns beyond the spec (additive): inception, active_days_90, peak_hours_90, shelves_configured.

Result: 42 machines (35 include_in_refill plus 7 partner machines still selling), 726 ramp-curve rows, 0.28 s.

Fixes made while validating (applied in place on prod; files carry the final bodies; md5 of every function body in the repo equals `md5(prosrc)` on prod for all 7 functions so far):

- card_share_90 was 0 everywhere: integer division. Fixed with a numeric cast.
- Adyen feed's last day (2026-10-01) is a partial ingest and produced fake cash baskets (AMZ-1029 11 card / 13 cash). The last feed day is no longer treated as covered.
- Machines the Adyen feed never attributes (IRIS-1070, AMZ-1046, BEBEACH) showed card share 0%; they now show NULL.
- AMZ machines carry 24 configured shelves (cabinets B to E) with no product and no stock, which read as 60% dead. A shelf now counts only if it holds a current product (v_shelf_capacity.current_product) or sold in the window. AMZ dead % went 0.600 to 0.000.
- Dead threshold set at under 1 unit per 14 active days, so IRIS-1070 reads 31% dead (handover counted 8 of 16 lanes at 0 to 4 units over 6.5 weeks on a slightly different window).

Defaults: weekend = Saturday and Sunday. Lunch = Mon to Fri 11:00 to 14:59 Dubai. drinks = boonz_products.attr_drink of the pod's largest-split mapped product (VOX premium machines have no mapping, drinks_share NULL). cv_monthly_12 uses only full calendar months inside the era. Ramp index compares within the same population.

Evidence, RAMPING machines (age < 90 days) with ramp_index: SAP-2002 (age 8) 3.22, BEBEACH-1069 (11) 1.65, IRIS-1070 (53) 0.70, AMZ-1046 (83) 1.00; partner ACTIVATEMOE-2007 (13) 5.00, VOXDFC-2006 (20) 1.67, VOXDFC-1001 (19) 0.92.

### Item 3.4 product_supply_daily: DONE (01:29 Dubai)

Migration `20261017212841_prd142a_4_product_supply_daily.sql`: `product_supply_daily` and `build_product_supply(p_d)` (SECURITY DEFINER, service_role only). 169 pods per day, 0.09 s.

Rules: wh_units_central = WH_CENTRAL, Active, not quarantined, not expired, through any Active product_mapping row. Fan-out pods (is_catchall: Chocolate Bar, Snack Bar, Soft Drinks Mix; plus Vitamin Well, Tannourine Water, Sun Blast Juice from the handover list) carry wh_status only. wh_status: none <= 5 units, low <= 2 weeks of cover, else stocked. weekly_rate = Boonz-population units over the last 4 complete Monday weeks / 4 (WH_CENTRAL fuels Boonz machines). Open POs = received_date NULL and purchase_outcome NULL; never counted as fuel.

Fix while validating: deployed_units first came from pod_inventory and was inflated (Barebells 881) because pod_inventory keeps historical snapshot rows. It now reads `v_shelf_capacity.current_stock` (live shelf truth) with the shelf product name normalised through product_name_conventions: 7,466 of 7,490 shelf units (99.7%) attribute to a pod. Patched in place; file md5 = prod md5.

Evidence (2026-10-18):

| Pod                     | wh_units_central | wh_status | deployed | open PO | weekly rate | weeks of cover |
| ----------------------- | ---------------- | --------- | -------- | ------- | ----------- | -------------- |
| Hunter                  | 0                | none      | 52       | 0       | 13.25       | 0.00           |
| Dubai Popcorn           | 16               | low       | 36       | 24      | 17.25       | 0.93           |
| Chocolate Bar (fan-out) | NULL             | low       | 723      | 0       | 184.50      | NULL           |
| Barebells               | 5                | none      | 300      | 300     | 76.50       | 0.07           |

### Nightly job: DONE (01:30 Dubai)

Migration `20261017213013_prd142a_5_strategy_nightly_job.sql`: `run_strategy_nightly()` runs sync_machine_eras, build_strategy_facts, build_machine_features, build_product_supply, each isolated in its own exception block, and logs the run to monitoring_alerts (source `prd142_strategy_nightly`, pre-acknowledged info, or an unacknowledged warning if a step fails). pg_cron job 88 `prd142_strategy_nightly_0330_dubai` at `30 23 * * *` UTC = 03:30 Dubai. Run by hand: 6.25 s total (eras 0 changes, facts 5.79 s, features 0.29 s, supply 0.09 s).

Phase 1 complete.

### Session stall (logged 09:50 Dubai)

The session stalled between 01:30 and 09:45 Dubai (no tool activity). The earlier "DONE (hh:mm)" stamps above were corrected to the real commit times. The 03:30 cron fired on its own while the session was stalled: `prd142_strategy_nightly_0330_dubai` succeeded at 03:30:00 Dubai in 33.4 s. On resume the Supabase MCP `apply_migration` returned "Invalid or expired requestState" for large payloads (the error PRD-140 and PRD-141 hit); small `execute_sql` calls kept working. Fallback used for item 4.3: the migration was applied in four `execute_sql` chunks and the schema_migrations row was inserted by hand (`created_by = 'prd142a-session-manual-insert'`), the same pattern PRD-141 used for PRD-140 item 1. Hard stop stays 15:48 Dubai; remaining items are prioritised: RPCs, proposals, product playbook, UI, gates.

### Item 4.3 archetypes and K-means: DONE (09:58 Dubai)

Migration `20261018055406_prd142a_6_machine_archetypes.sql` (applied via execute_sql chunks, see above): `machine_archetypes` (9 locked rules), `machine_archetype_assignment` (nightly, 400 days), `machine_archetype_override` (CS manual, kept until cleared), `strategy_change_log`, `strategy_rule_match()` (a small JSON rule evaluator) and `assign_machine_archetypes()` (SECURITY DEFINER, service_role only). First-ever assignment is not logged as a change; later changes write strategy_change_log.

K-means doc: `docs/prds/PRD-142-kmeans.md` (Boonz k=4 silhouette 0.230, partner k=3 0.186) with the rule-by-rule reasoning. Script: `scripts/strategy/kmeans_diagnostic.py`.

Spec rules changed by the data (each logged in the doc): SEASONAL_SWINGER CV threshold 0.45 to 0.60; LOBBY_TRICKLE peak-share condition dropped; CINEMA_IMPULSE weekend >= 0.40 replaced by weekend >= 0.30 and ticket >= 15; new fallbacks OFFICE_STANDARD (Boonz) alongside VENUE_STANDARD (partner).

Data flag for CS: `boonz_products.attr_drink` is false for Al Ain Zero (it was true at 01:20). drinks_share now also counts drinks pod categories (build_machine_features patched; file md5 = prod md5).

Counts (42 machines): OFFICE_LUNCH_ENGINE 8, PREMIUM_OFFICE 3, LOBBY_TRICKLE 4, OFFICE_STANDARD 1, GYM_GRAB 1, SEASONAL_SWINGER 5, RAMPING 7 (4 Boonz, 3 partner), CINEMA_IMPULSE 10, VENUE_STANDARD 3.

### Phase 3 additive (5.1 to 5.3): DONE (10:15 Dubai)

Migrations (apply_migration worked again for these sizes): `20261018055728_prd142a_7_machine_strategy_tables.sql` (`strategy_posture_defaults` with the 5.1 params per posture and population, `machine_strategy`, `product_clusters` with all 32 current categories mapped to the 8 Portfolio Map clusters plus UNCLASSIFIED, `strategy_cluster()`), and `20261018060009_prd142a_8_posture_proposals.sql` (`propose_machine_postures()` service_role only; `set_machine_strategy(machine, posture, params, shelf_overrides, notes)` and `reject_machine_strategy_proposal(machine, reason)`, both SECURITY DEFINER, `is_admin(auth.uid())` checked, REVOKE public/anon, GRANT authenticated, every call writes strategy_change_log). md5 of every function body = prod.

Rules as specified in 5.1 with these defaults: benchmark = median gp_day_90 (rev_day_90 when GP is NULL, i.e. partner until the share is set) of the same archetype and population excluding the machine itself, population median under 3 peers; lanes = v_shelf_capacity current products; peer lane rate = median net rev per lane per active day over peers carrying the pod. NOT_FLIPPABLE is never auto-proposed in 142a (needs two monthly review cycles); CS can set it. A rejected proposal is suppressed for 30 days (rejected_posture, rejected_until). The diagnosis sentence is SQL-generated and includes the category-balance clause (6.3) when a cluster is over-shelved by 15 points or more.

First proposals (as_of 2026-10-17, 42 machines): PROTECT_GROW 24, FIX_MIX 10, WATCH_ADAPT 8. Examples:

- HUAWEI-2003 (Office lunch engine) FIX_MIX: "GP 56% of Office lunch engine benchmark. Mix gap 40%: lanes A13, B14, A12 under 40% of peer median."
- NOVO-1023 (Premium office) FIX_MIX: "GP 24% of Premium office benchmark. Mix gap 28%: lanes A04, A14, A07 under 40% of peer median. Dead shelves 56%. Biscuits, cakes and crackers over-shelved (lanes 25%, rev 9%)."
- IRIS-1070 (Ramping, day 53) FIX_MIX: "Ramping, day 53: cumulative revenue 70% of the boonz fleet median at the same age. Mix gap 25%: lanes A03, A15, A01 under 40% of peer median."
- MPMCC-1054 (Cinema impulse) WATCH_ADAPT: "Rev 76% of Cinema impulse benchmark. Mix on par (gap 15%). Rev down 15% vs prior 60 days. Baskets per day down 11%. Outside the machine."

### Items 4.1 and 4.2 machine RPCs: DONE (10:40 Dubai)

Migrations `20261018060312_prd142a_9_get_strategy_machines.sql` and `20261018060350_prd142a_10_get_strategy_machine_detail.sql`. Both SECURITY DEFINER, `is_admin(auth.uid())` gate, REVOKE public/anon, GRANT authenticated, read-only, return jsonb. Two bugs fixed in place while testing (jsonb_build_object over 100 arguments; a GROUP BY on a cast and a window function inside an aggregate); md5 of both bodies = prod.

- `get_strategy_machines(population, window 30d|90d|12m|era, all_eras)`: one object per machine with identity, window KPIs (units, net rev, GP, per day, cogs coverage), full-month averages, lifetime (current era, or all eras), characteristics, shelf block with concentration label (Balanced < 45%, Skewed 45 to 65, Concentrated > 65), archetype and any archetype change in the last 14 days, archetype benchmark (median rev_day_90 and gp_day_90 of the archetype and population; the list benchmark includes the machine itself, the proposal job excludes it), posture, proposal, diagnosis, performance_index, mix_gap, ramp_index. Tested as operator_admin: boonz 90d 26 machines, partner era 16, all 12m all-eras 42.
- `get_strategy_machine_detail(machine)`: daily era series, T+ adoption (rolling 7-day rev and units, cumulative, fleet median cumulative at the same day index), monthly table with full-month flag, hour and weekday profiles, shelf table (size class, product, units and rev per slot per day, fleet percent ranks, quadrant Prime / Volume-cheap / Premium-slow / Weak / Dead / Too new / Empty, slot age), product table (velocity here vs fleet median vs siblings in the same venue_group or building: Local hero >= 1.25x fleet median, Underperformer <= 0.75x, else On par; "Too few machines" under 3), category balance, eras, strategy history and posture defaults.

Evidence, IRIS-1070 drill-down (reproduces the handover section 6 read): Zigi Local hero 3.50/wk here vs fleet 2.45 (the winner that was swapped out), Perrier Local hero 2.43 vs 1.86, Pepsi Black Underperformer 1.67 vs siblings 8.29, Loacker 1.25 vs siblings 7.31; lanes A03 Red Bull and A15 Al Ain Zero Dead, A01 Keen Health and A08 Plaay Dead, A10 Barebells Dead. Adoption day 41: cumulative AED 793 vs fleet median AED 1,388.

### Phase 4 (6.1 to 6.5) product intelligence: DONE (11:45 Dubai)

Migrations: `20261018063916_prd142a_11_product_playbook.sql` (applied through several execute_sql calls, schema_migrations row inserted by hand, `created_by = 'prd142a-session-manual-insert'`; the build had to be split into small functions `strategy_playbook_prepare`, `strategy_playbook_clear`, `strategy_playbook_insert`, `propose_product_strategy` and the orchestrator `build_product_playbook` because the MCP rejected the larger payloads), `20261018063648_prd142a_12_get_strategy_products.sql`, `20261018063818_prd142a_13_product_matrix_detail_writer.sql`, `20261018063838_prd142a_14_strategy_nightly_full.sql`. The version of _11 sorts after _12 to _14 because its row was registered last; replay order is still safe (plpgsql bodies resolve tables at call time). md5 of all 10 function bodies = prod. One fix while running: `anomaly` evaluated to NULL when no 4-week window had 16 units (COALESCE to false).

Tables: `product_superseded` (seeded with Krambals & Zigi, Pepsi Mix, Healthy Cola - Mix; successors filled where a pod exists, Pepsi Mix successor is a guess for CS), `product_playbook` (per population boonz, partner, all; 60-week series arrays for sparklines; reason jsonb with the numbers that fired the label), `product_strategy` (proposals for the Boonz population). RPCs (is_admin gate, authenticated only): `get_strategy_products(population, position)` (products, KPI strip, medians, cluster summary with a counts read, PO hygiene list, quarantined list, uncategorised list), `get_strategy_product_archetype_matrix(population)`, `get_strategy_product_detail(pod, population)`, writer `set_product_strategy(pod, posture, target_archetypes, notes)` (logs to strategy_change_log).

Defaults chosen and logged: products in scope have >= 30 units over the 60-week series (the handover filter); "now below prime" for MISSED_THE_WAVE = retention < 0.7, coverage < 60% of prime coverage, or current units per week below prime units per week; COOLED_OFF also requires the prime to be >= 4 weeks ago; proposals only for the Boonz population; GROW target archetypes = up to 2 archetypes where the product's velocity ratio >= 1.2, lowest archetype coverage first. Cannibalisation flag (6.3 last bullet, backlog item 7): NOT BUILT in 142a, time-boxed out.

Regression vs the handover (2026-10-10 snapshot), Boonz, as_of 2026-10-18: PASS.

| Product             | Handover                                     | Now             | Numbers now                                                                    |
| ------------------- | -------------------------------------------- | --------------- | ------------------------------------------------------------------------------ |
| Activia Mix & Go    | Missed the wave (4.5 @32% to 2.7 @11%, WH 2) | MISSED_THE_WAVE | prime 4.50 @32.3%, now 2.50 @9.5%, retention 0.56, WH none, prime 11 weeks ago |
| YoPRO               | Missed the wave (3.2 @15% to 2.1 @6%)        | MISSED_THE_WAVE | prime 3.15 @15.1%, now 2.13 @4.2%, WH none                                     |
| Coca Cola Mix       | Double down (15.6 @22%)                      | DOUBLE_DOWN     | 16.95 @21.9%, WH stocked                                                       |
| Nutella Biscuits T3 | Incubate (23/wk on 3 machines)               | INCUBATE        | 18.6/wk, 0.9 months live                                                       |
| Zigi                | Cooled off (7.7 to 3.8)                      | COOLED_OFF      | prime 7.70, now 3.79, retention 0.49, stocked                                  |

Moved since the snapshot (explained by the data): Hunter Protect to MISSED_THE_WAVE (WH_CENTRAL now 0 vs 11 in the handover, prime 4.29 @47% to 2.55 @34%). Evian Exit stays EXIT.

Boonz counts: DOUBLE_DOWN 10, PROTECT 8, MISSED_THE_WAVE 21, COOLED_OFF 3, REDUCE_REPLACE 3, EXIT 10, INCUBATE 10, SUPERSEDED 3, ANOMALY 1 (Tannourine Water). Medians: velocity 2.55/wk (handover 2.4), coverage 17.6% (handover 19%), top quartile 4.39. KPI: 65 products shown, 10,089 units, AED 69,872 net ex-VAT in 8 weeks; unserved proven demand 164.5 units/week across MISSED_THE_WAVE (handover about 150). Cluster read, Soft and energy drinks: 7 double down, 3 missed the wave, 3 to drain or exit of 13 (handover: 6 of 8 double-downs are drinks).

PO hygiene list: Smart Gourmet Hummus (COOLED_OFF) 108 open, 15.4 weeks of cover from the PO; Keen Health Dipped Crackers (REDUCE_REPLACE) 108 open, 4.9 weeks. (The handover's Zigi 546 and Evian 120 POs are no longer open.) Uncategorised pods: Eviron Health Drink, Pocari Sweat, Tannourine Water.

Nightly: `run_strategy_nightly()` now runs eras, facts, features, supply, archetypes, machine proposals, product playbook and proposals; run by hand 13.5 s. Access: `access_areas` key `app.strategy` (route /app/strategy, sidebar "Strategy") granted to operator_admin and superadmin through role_area_defaults.

### Phase 5 UI /app/strategy: BUILT (12:40 Dubai), verification below

Files: `src/app/(app)/app/strategy/page.tsx` (tabs, `useRequireArea("app.strategy")`), `MachinesTab.tsx`, `MachineDrawer.tsx`, `ProductsTab.tsx`, `ProductDrawer.tsx`, `shared.tsx`; sidebar entry "Strategy" under Commercial in `src/app/(app)/sidebar-nav.tsx`, hidden for finance, manager and warehouse (middleware already blocks warehouse and field_staff from /app). recharts only (no new dependency); ERP palette variables. Supabase client created inside useEffect (kept in a ref for handlers).

- Machines tab: population toggle, window 30d/90d/12m/era, all-eras toggle; KPI strip (machines, net rev per day, GP per day, COGS coverage, machines by posture); posture 2x2 (performance index on y, mix gap on x, points sized by rev per day, coloured by archetype, reference lines at 85% and 25%, click opens the drawer); archetype legend with counts and the 14-day archetype-change notice; review-proposals panel (Accept, Accept with edits via the drawer, Reject with a required reason, plus machines past review_by); sortable table with archetype and posture filters and a dashed "proposed" badge.
- Machine drawer: diagnosis, KPI cards (daily, full-month average, lifetime era), T+ adoption chart with fleet median and a revenue/units toggle, hour and weekday profiles, shelf grid by cabinet coloured by quadrant, product table here vs fleet vs siblings, category balance bars, posture editor (posture, params from strategy_posture_defaults, shelf overrides lock/reset/swap now, notes) calling set_machine_strategy, history and eras.
- Products tab: scope Boonz/Partner/All, position Current/At prime/Trails, X axis coverage or AED per facing, playbook chips with counts, cluster filter, min units slider, label all, tooltip with the 60-week sparkline; velocity (log) x coverage map with median lines, maturity single-hue ramp fill and playbook outline, prime-to-now trails; KPI strip incl. "proven demand not served"; cluster table; sortable full table with posture badge; product x archetype heatmap (top 25 by revenue); PO hygiene, quarantined and uncategorised lists.
- Product drawer: now vs prime KPI cards, the numbers that fired the label, weekly series with the prime window shaded, best and worst machines, archetype bars, supply block, posture editor calling set_product_strategy, history.

Gates so far: `npx tsc --noEmit` clean; eslint on the new files clean (fixed three react-hooks/set-state-in-effect errors by deriving loading and drawer state from a load key); `npm run build` passes, `/app/strategy` listed as a dynamic route. `npm ci` was run in this worktree (it had no node_modules); lockfile unchanged, no package added.
