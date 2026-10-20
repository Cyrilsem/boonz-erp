# PRD-142 report

Shared by PRD-142a and PRD-142b; each loop appends under its own heading. Evidence for every line is in `docs/prds/PRD-142-log.md`.

## PRD-142a (additive: data layer, machine and product intelligence, UI)

Lock taken 2026-10-17 23:48 Dubai, released 2026-10-18 11:20 Dubai (hard stop was 15:48). The session stalled with no activity from 01:30 to 09:45 Dubai; the scheduled 03:30 nightly ran on its own in that gap.

### Items

| Item                                                                     | Status    | Evidence                                                                                                                                                  |
| ------------------------------------------------------------------------ | --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Step 0 baseline                                                          | DONE      | Matches spec section 2 except sales_history rows (51,649) and cost gap (39.0%); machines.is_test does not exist; VOX eras live in a function, not a table |
| 3.1 machine_eras                                                         | DONE      | 49 eras on 42 machines; 6 machines with two eras (SAP-2002: WH1 era to 2026-10-09, SAP era from 2026-10-10)                                               |
| 3.2 fact tables                                                          | DONE      | Rebuild 5.1 s (nightly at 03:30: 33 s under load); Sep 2026 net ex-VAT AED 79,872.74 in facts and in sales_history (0.0000%), 9,672 units both            |
| 3.3 machine_features + ramp curve                                        | DONE      | 42 machines; ramp_index for the 7 RAMPING machines (IRIS-1070 day 53: 0.70)                                                                               |
| 3.4 product_supply_daily                                                 | DONE      | Hunter WH 0 none; Dubai Popcorn 16 low (0.93 weeks); Chocolate Bar fan-out, units NULL, status low                                                        |
| 4.3 archetypes + K-means doc                                             | DONE      | docs/prds/PRD-142-kmeans.md; Boonz k=4 silhouette 0.230, partner k=3 0.186; 9 locked rules                                                                |
| 4.1 get_strategy_machines                                                | DONE      | 26 Boonz, 16 partner, 42 all, tested as operator_admin                                                                                                    |
| 4.2 get_strategy_machine_detail                                          | DONE      | IRIS-1070 drill-down reproduces the handover read (Zigi Local hero, Red Bull and Al Ain Zero lanes dead)                                                  |
| 5.1 to 5.3 additive (postures, diagnosis, machine_strategy, writer RPCs) | DONE      | 42 proposals: PROTECT_GROW 24, FIX_MIX 10, WATCH_ADAPT 8                                                                                                  |
| 6.1, 6.2 product playbook                                                | DONE      | Regression PASS (Activia and YoPRO Missed the wave, Coca Cola Mix Double down, Nutella Biscuits T3 Incubate, Zigi Cooled off)                             |
| 6.3 archetype matrix, cluster summary, category balance                  | DONE      | 208 matrix cells; cluster reads; category balance in the diagnosis and the machine drawer                                                                 |
| 6.3 cannibalisation flag                                                 | NOT BUILT | Time-boxed out (backlog item 7, "no action" display only)                                                                                                 |
| 6.4 product_strategy + set_product_strategy                              | DONE      | GROW proposals with target archetypes (e.g. Loacker, Coca Cola Zero to OFFICE_LUNCH_ENGINE)                                                               |
| 6.5 PO hygiene                                                           | DONE      | Smart Gourmet Hummus 108 on order (15.4 weeks of cover), Keen Health Dipped Crackers 108 (4.9 weeks)                                                      |
| Nightly job                                                              | DONE      | pg_cron `prd142_strategy_nightly_0330_dubai` (30 23 * * * UTC); full chain run by hand 13.5 s                                                             |
| Phase 5 UI /app/strategy                                                 | DONE      | Live on production (deploy of aa918ab); both tabs, review panel and both drawers checked in the browser                                                   |

### Acceptance (section 8, 142a)

| Check                                                                                                                    | Result                                             | Evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Facts rebuild nightly under 60 s; Sep 2026 reconciles within 0.5%                                                        | PASS                                               | 5.1 s by hand, 33 s in the 03:30 run; AED 79,872.74 both sides (0.0000%)                                                                                                                                                                                                                                                                                                                                                                                                      |
| Every live machine has an era, archetype, posture_proposed and diagnosis; machines under 90 days RAMPING with ramp_index | PASS                                               | 42 of 42 (35 include_in_refill plus 7 partner machines still selling); 7 RAMPING with ramp_index                                                                                                                                                                                                                                                                                                                                                                              |
| K-means doc with silhouette per k and justified rules                                                                    | PASS                                               | docs/prds/PRD-142-kmeans.md                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Products regression                                                                                                      | PASS                                               | See the log table (numbers per product)                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Unserved-demand KPI and PO hygiene populated; 3 uncategorised listed                                                     | PASS                                               | 164.5 units/week; 2 PO hygiene lines; Eviron Health Drink, Pocari Sweat, Tannourine Water                                                                                                                                                                                                                                                                                                                                                                                     |
| CS can confirm a machine and a product posture from the UI; both in strategy_change_log within 1 s                       | PASS (writers proven in a rolled-back transaction) | set_machine_strategy and set_product_strategy as operator_admin wrote both log rows in the same transaction (well under 1 s), then ROLLBACK. I did not click Accept in the live UI so no posture is recorded on CS's behalf; the buttons call these same RPCs                                                                                                                                                                                                                 |
| Three-role smoke test                                                                                                    | PASS                                               | operator_admin: page, both tabs, review panel, machine drawer (IRIS-1070) and product drawer (Coca Cola Mix) render on production. warehouse and field_staff: middleware blocks /app; the RPCs refuse them (`get_strategy_machines: operator_admin or superadmin only`, `set_machine_strategy: operator_admin or superadmin only`); sidebar entry hidden for finance, manager, warehouse. Nothing existing was changed for them                                               |
| Migration parity both directions                                                                                         | PASS (PRD-142a scope)                              | 14 prd142a files = 14 prd142a schema_migrations rows; two rows inserted by hand (created_by prd142a-session-manual-insert) because apply_migration failed with "Invalid or expired requestState"                                                                                                                                                                                                                                                                              |
| Overload check                                                                                                           | PASS                                               | No PRD-142a function is overloaded (the only overload in public is `engine_finalize_pod`, not touched)                                                                                                                                                                                                                                                                                                                                                                        |
| anon-executable SECURITY DEFINER count                                                                                   | PASS                                               | 0                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| No PRD-141 function touched                                                                                              | PASS                                               | No prd142a file defines engine_add_pod, engine_swap_pod, pick_machines_for_refill, get_procurement_demand, write_refill_plan, add_dispatch_row, v_live_shelf_stock or v_shelf_sales_identity. md5 of their bodies on prod at 11:10 Dubai: add_dispatch_row e714f2d7, engine_add_pod 57f5860e, engine_swap_pod 0264d0ec, get_procurement_demand 2285bfc3, pick_machines_for_refill 84e9cfee, write_refill_plan 9b06c82e (changes to them, if any, come from PRD-141's own log) |

### Migrations (all applied to prod, all in supabase/migrations/)

20261017211208_prd142a_1_machine_eras, 20261017211607_prd142a_2_strategy_facts, 20261017212319_prd142a_3_machine_features, 20261017212841_prd142a_4_product_supply_daily, 20261017213013_prd142a_5_strategy_nightly_job, 20261018055406_prd142a_6_machine_archetypes (manual row), 20261018055728_prd142a_7_machine_strategy_tables, 20261018060009_prd142a_8_posture_proposals, 20261018060312_prd142a_9_get_strategy_machines, 20261018060350_prd142a_10_get_strategy_machine_detail, 20261018063648_prd142a_12_get_strategy_products, 20261018063818_prd142a_13_product_matrix_detail_writer, 20261018063838_prd142a_14_strategy_nightly_full, 20261018063916_prd142a_11_product_playbook (manual row). The md5 of every function body in these files equals `md5(prosrc)` on prod.

### Commits on main

c09e4d1, 6745c38, cbd767c, 19b8fac, 5ae49cd, 3ecae1c, c41f349, 736bc9a, 1da1609, aa918ab, plus this report and the lock release.

### For CS (plain English)

**What is on screen.** A new "Strategy" item under Commercial in the ERP sidebar (only you and other operator admins see it). The Machines tab shows every live machine as a dot on a map: up means it earns more than similar machines, right means its own shelves are the problem. Each machine has a type (archetype), a proposed posture and a one-line diagnosis. A review list lets you accept, edit or reject each proposal. Clicking a machine opens its full picture: how it grew since day one against the fleet, busy hours and days, every shelf coloured by how well it sells, every product compared with the fleet and with sister machines, and which categories take too much space. The Products tab is the Portfolio Map rebuilt inside the ERP and refreshed every night: the same map, chips, trails and tables, plus "what works where" by machine type, PO checks and the lists of products to fix.

**Machine types found (42 machines).** Office lunch engine 8, Premium office 3, Lobby trickle 4, Steady office 1, Gym grab 1, Seasonal swinger 5, Ramping 7 (under 90 days), Cinema impulse 10, Venue standard 3 (the LVLUP machines). Three of the starting rules were adjusted because the data contradicted them; the reasons are in docs/prds/PRD-142-kmeans.md.

**First proposed postures (none confirmed yet).**

Fix the mix (problem is inside the machine):

- ALJLT-1015-0100: GP 26% of Lobby trickle benchmark. Mix gap 75%: lanes A04, A07, A01 under 40% of peer median. Dead shelves 88%.
- GRIT-1022: GP 23% of Gym grab benchmark. Mix gap 60%: lanes A04, A14, A16 under 40% of peer median. Dead shelves 56%.
- HUAWEI-2003: GP 56% of Office lunch engine benchmark. Mix gap 40%: lanes A13, B14, A12 under 40% of peer median.
- IRIS-1070: Ramping, day 53: cumulative revenue 70% of the fleet median at the same age. Mix gap 25%: lanes A03, A15, A01 under 40% of peer median.
- JET-1016: GP 66% of Seasonal swinger benchmark. Mix gap 27%: lanes A13, A14, A07 under 40% of peer median. Dead shelves 44%.
- MINDSHARE-1009: GP 63% of Seasonal swinger benchmark. Mix gap 34%: lanes A08, A04, A12. Dead shelves 38%.
- NOVO-1023: GP 24% of Premium office benchmark. Mix gap 28%: lanes A04, A14, A07. Dead shelves 56%. Biscuits, cakes and crackers over-shelved (lanes 25%, rev 9%).
- WAVEMAKER-1006: GP 42% of Lobby trickle benchmark. Mix gap 63%: lanes A06, A03, A01. Dead shelves 50%. Soft and energy drinks over-shelved (lanes 25%, rev 7%).
- IFLYMCC-1024 (partner): Rev 34% of Cinema impulse benchmark. Mix gap 54%: lanes A15, A16, A05.
- MPMCC-1058 (partner): Rev 52% of Cinema impulse benchmark. Mix gap 26%: lanes A15, A16, A14.

Watch and adapt (problem is outside the machine):

- ADDMIND-1007: GP 63% of Office lunch engine benchmark. Mix on par. Rev up 10%, baskets up 25%.
- AMZ-1057: GP 64% of Office lunch engine benchmark. Mix on par. Rev up 90%, baskets up 93%.
- VML-1003: GP 69% of Office lunch engine benchmark. Mix on par. Rev up 10%.
- WPP-1002: GP 59% of Seasonal swinger benchmark. Mix on par. Rev up 166%, baskets up 132%.
- LVLUP-1018, LVLUP-1048 (partner): 79% and 52% of Venue standard benchmark, both growing.
- MPMCC-1054, VOXMM-1013 (partner): 76% of Cinema impulse benchmark, revenue down 15%, baskets down 11% and 18%.

Protect and grow (24): AMZ-1029, AMZ-1038, AMZ-1068, MC-2004, USH-1008, OMDBB-1020, OMDCW-1021, NISSAN-0804, NOOK-1019, ALJLT-1015-0200, VML-1004, AMZ-1046, BEBEACH-1069, SAP-2002, and partner ACTIVATEMCC-1037, ACTIVATEMCC-2005, ACTIVATEMOE-2007, LVLUP-2015, VOXDFC-1001, VOXDFC-2006, VOXMCC-1005, VOXMCC-1011, VOXMCC-1012, VOXMCC-1017.

Worth a look before confirming: four "Watch and adapt" machines (AMZ-1057, WPP-1002, LVLUP-1018, LVLUP-1048) are growing fast; they are below benchmark because they are still climbing, so Protect and grow may be the better call. VOX machines show chocolate and candy taking about half the lanes for about a third of the revenue.

**Products (Boonz sourcing, last 8 weeks).** 65 products, 10,089 units, AED 69,872 ex-VAT. Double down 10, Protect 8, Missed the wave 21, Cooled off 3, Reduce and replace 3, Incubate 10, Exit 10 (plus 3 superseded and 1 anomaly set aside). Proven demand you are not serving: about **165 units a week** across the Missed the wave products. Hunter has moved from Protect to Missed the wave since the 10 October snapshot because the warehouse ran out.

**What you need to do.**

1. Vercel deploys automatically from main; the page is already live at /app/strategy.
2. Confirm the first machine postures in the review list (or reject with a reason; a rejected proposal stays quiet for 30 days). Nothing changes in refills yet: PRD-142b is what makes postures act on the refill engine.
3. Set `partner_revenue_share` in refill_settings (one number per venue group, e.g. {"VOX": 0.3}) so partner machines get a gross profit; until then they are compared on revenue.
4. Fix the 3 uncategorised products: Eviron Health Drink, Pocari Sweat, Tannourine Water.
5. Check `product_superseded`: Pepsi Mix's successor was guessed as Pepsi Black; add any other renamed pods.
6. Check Al Ain Zero in boonz_products: `attr_drink` is false (it was true early this morning).
7. The Portfolio Map artifact and its weekly manual refresh can stop once you are happy with the Products tab (PRD-142b retires the old tabs).
8. For 142b, later: enable `prd142_picker_multiplier_enabled` when ready.

**What is left.** The cannibalisation flag (6.3, display only) was not built. Outcome deltas after posture changes (5.5 item 8) belong to 142b. NOT_FLIPPABLE is never proposed automatically yet (it needs two monthly reviews of history); you can set it by hand. PRD-142b: engine hook, product posture in procurement and the swap pool, and retiring the old Lifecycle and Performance tabs.

## PRD-142a DONE

## PRD-142b

Lock taken 2026-10-19 17:39 Dubai. Hard stop 2026-10-20 05:39 Dubai. The session stalled on a database call from about 23:40 Dubai on 19 Oct and only resumed at 03:14 Dubai on 21 Oct, so the engine hook was not applied. Evidence for every line is in docs/prds/PRD-142-log.md under "PRD-142b log".

### Items

| Item | Status | Evidence |
| --- | --- | --- |
| A1 chart clipping | DONE | New SVG map with one clipPath on the plot; production DOM probe: 0 points and 0 trail ends outside the plot in every scope and position, also after hovers (before: 3 marks outside on Partner, one a 532 px trail) |
| A2 axis domain per scope | DONE | Domains from the drawn points (prime included on Trails), log y kept; Partner Trails y 1.16 to 70.9 with Aquafina (52.55) and its trail inside; medians follow the population |
| A3 tooltip | DONE | Card inside the chart on three hovers, flips above near the bottom; 0 SVG mutations on hover; no page height change. Flip-left branch not exercised on the 2560 px screen |
| A4 product review panel | DONE | Panel on Products (65 open proposals on Boonz); reject_product_strategy_proposal with 30 day suppression, tested in a rolled-back run (Ice Tea) |
| A5 navigation | DONE | Strategy > Machines and Strategy > Products in the sidebar; ?tab=products opens Products |
| A6 cannibalisation flag | DONE | Product drawer card; Dubai Popcorn shows 3 flags |
| A7 proposals only in refill | DONE | 35 machines proposed, 7 outside refill untouched and badged "not in refill" |
| A8 phantom shelves | DONE | Drawer grid and shelf KPIs use cabinet_count; AMZ-1029 16 lanes (was 40); shelf KPIs were already right (AMZ-1029 dead 0.000 before and after, ADDMIND-1007 0.063 and 0.063); cleanup list docs/prds/PRD-142-phantom-shelves.md. No browser screenshot (hard stop) |
| A9 new products visible | DONE | Huel INCUBATE, New, 5 units, supply block filled; shown under the slider with a "new, under threshold" marker. No browser screenshot (hard stop) |
| 5.5 item 1 v_machine_posture_params and flags | DONE | Applied, inert |
| 5.5 items 2, 3, 4, 5, 7 (fill_depth, swap_mode, shelf overrides, swap guard, picker multiplier, product posture in the pool) | BLOCKED (hard stop) | Written and parked, anchors verified, not applied; no fleet diff ran |
| 5.5 item 6 TRANSFER recommendations | BLOCKED (hard stop) | Not written; design in the log |
| 5.5 item 8 outcome deltas | BLOCKED (hard stop) | Not written |
| 6.4 get_procurement_demand posture | BLOCKED (hard stop) | Not written; design in the log |
| 7.1 Lifecycle Heatmap and Divest tabs | DONE | Removed, redirect to Strategy Products |
| 7.1 Performance > Product Performance tab | DONE | Removed, redirect; component and get_product_velocity_ledger kept because /app/products > Performance still uses them |
| 7.1 v_swap_candidate_ranking | BLOCKED | Unreferenced, but the database tool refused the DROP; SQL parked with rollback |
| 7.1 Portfolio Map artifact | Superseded | The Products tab replaces it; the weekly manual refresh can stop |

### Acceptance (section 8, 142b, with the 19 Oct change)

| Check | Result | Evidence |
| --- | --- | --- |
| (a) flags false: rolled-back fleet diff empty | FAIL (not run) | Hook not applied; diff tool not installed before the hard stop |
| (b) flags true: changes only on non-PROTECT_GROW machines | FAIL (not run) | Same |
| (c) swap guard blocks an above-median removal | FAIL (not run) | Guard written, not applied |
| (d) EXIT product absent from swap pool and procurement | FAIL (not run) | Pool filter written, not applied; procurement change not written |
| (e) RESOURCE product in the decide block | FAIL (not run) | Not written |
| Retired tabs redirect; no console errors | PASS (code), browser check not run | Redirect code in lifecycle and performance pages; /app/strategy had no console errors in production after Block A |
| Parity and security gates | PASS | 7 prd142b migrations on prod and in the repo; overloads only engine_finalize_pod (pre-existing); anon-executable definers 0 |

### Migrations (applied to prod and committed)

20261019134423_prd142b_a7_posture_proposals_refill_scope, 20261019134554_prd142b_a4_product_proposal_review, 20261019134723_prd142b_a6_cannibalisation_flag, 20261019191204_prd142b_a8_phantom_shelves, 20261019191350_prd142b_a9_new_products_in_scope, 20261019191926_prd142b_b1_posture_params, 20261019192430_prd142b_b0_engine_diff_runs.

Parked, not applied: supabase/migrations/parked/prd142b_b2_b4_engine_hook.sql, prd142b_b0b_fleet_diff_tool.sql, prd142b_c_retire_v_swap_candidate_ranking.sql.

Rollback files: supabase/rollbacks/prd142b_a4_rollback.sql, prd142b_a6_rollback.sql, prd142b_a7_rollback.sql, prd142b_a8_rollback.sql, prd142b_a9_rollback.sql, prd142b_b0_rollback.sql, prd142b_b1_rollback.sql, prd142b_b2_b4_rollback.sql, prd142b_c_v_swap_candidate_ranking_rollback.sql.

### Commits on main

7731db3 (lock), be70e76, d4cf1cd, d4d643c, 2fb0bf1, 736e73e, de31a9d, 278532b, c9c64a3, plus this closeout and the lock release. Vercel deployed automatically up to 736e73e and de31a9d (checked); later code commits (278532b, c9c64a3) deploy the same way from main.

### For CS (plain English)

**What changed on the Strategy page.** The Products map no longer draws lines outside its frame, and its scale now fits whatever you are looking at, so Partner products such as Aquafina (about 52 a week) sit inside the chart with their trail. The hover card stays inside the chart and no longer makes the page jump. There is a "Review product proposals" list on the Products tab with Accept, Accept with edits and Reject (a rejected proposal stays quiet for 30 days). The sidebar has Strategy > Machines and Strategy > Products. The product drawer shows likely cannibalisation (for example Sunbites taking from Dubai Popcorn on AMZ-1057). Machines outside refill show "not in refill" and no longer get new proposals. The machine drawer only shows cabinets that exist (AMZ-1029 shows 16 lanes, not 40). New products under 3 months, such as Huel, always show on the map and in the table, marked "new, under threshold" when they sell less than the slider.

**Old tabs retired.** Lifecycle Heatmap and Divest Plan, and Performance > Product Performance, are gone; old links land on Strategy > Products. The same Product Performance view still exists under Products > Performance and can be retired in PRD-143. You can stop republishing the Portfolio Map artifact.

**Engine.** Nothing in the refill engine reads postures yet. The five switches exist in refill_settings: prd142_fill_depth_enabled false, prd142_swap_mode_enabled false, prd142_swap_guard_enabled true, prd142_picker_multiplier_enabled false, prd142_procurement_posture_enabled true. Today none of them changes anything, because the engine code that reads them is written but not installed.

**What you need to do.**

1. Nothing to deploy by hand; Vercel builds from main.
2. Schedule the engine hook for a night window in a new loop (PRD-142c or inside PRD-143): Cody review of supabase/migrations/parked/prd142b_b2_b4_engine_hook.sql, install the diff tool, run the two full-fleet diffs, apply, then flip prd142_fill_depth_enabled and prd142_swap_mode_enabled when you are happy, and prd142_picker_multiplier_enabled later.
3. Drop the old view v_swap_candidate_ranking yourself in the SQL editor (one line, file in supabase/migrations/parked), or let the next loop do it.
4. Review the first product proposals in the new panel.
5. Approve the phantom-shelves cleanup (152 rows on the four AMZ machines, AMZ-1046 and BEBEACH-1069) for a later night.

**Left for PRD-143 (or a PRD-142c).** Engine hook items 2 to 8 and the procurement posture block; TRANSFER recommendations (needs 'TRANSFER' allowed on strategic_machine_tags); outcome deltas on the machine card; the phantom-shelves cleanup; retiring Products > Performance and get_product_velocity_ledger; the three-role smoke test and A8/A9 screenshots that the hard stop cut.

## PRD-142b DONE
