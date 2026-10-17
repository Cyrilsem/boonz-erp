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

### Item 3.1 machine_eras: DONE (02:15 Dubai)

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

### Item 3.2 fact tables: DONE (02:45 Dubai)

Migration `20261017211607_prd142a_2_strategy_facts.sql`: `fact_machine_daily`, `fact_shelf_daily`, `fact_product_machine_daily`, `fact_product_weekly` (RLS on, admin-only select, anon revoked), helpers `strategy_shelf_code`, `strategy_size_class`, and `build_strategy_facts(p_from)` (SECURITY DEFINER, service_role only). Formulas registered in docs/architecture/METRICS_REGISTRY.md (section "PRD-142a").

The first run failed on an ambiguous column in the hour-profile CTE and then ran over 60 s because `v_shelf_capacity` (55 ms per call) was evaluated once per shelf-day group. Both fixed in place on prod (function body patched with CREATE OR REPLACE); the committed migration file is the fixed body, which is what prod runs.

Evidence:

- Rebuild: `build_strategy_facts(NULL)` = 5.06 s. Window 2025-08-18 to 2026-10-17. Rows: fact_machine_daily 10,468; fact_shelf_daily 31,172; fact_product_machine_daily 28,214; fact_product_weekly 3,750.
- Sep 2026 reconciliation: facts AED 79,872.74 net ex-VAT vs sales_history AED 79,872.74 on the same basis (0.0000%), 9,672 units both. Gross incl. VAT AED 83,866.38.
- Boonz Sep: COGS coverage 95.2% of units, gross margin 36.1%, card share 95.2% of baskets (on Adyen-covered days).

Defaults chosen: window = LEAST(p_from, Monday 60 weeks back) so fact_product_weekly always has 60 full weeks (spec default p_from of 400 days is under 60 weeks); facts end yesterday (Dubai), today's partial day excluded. fact_shelf_daily and fact_product_machine_daily are sparse (sale days only); dead shelves are measured against the current shelf configuration. population column added to fact_machine_daily and net_rev_exvat / machine_weeks to fact_product_weekly (additive). Machines with no shelf layout name match default to STANDARD_16; VOXDFC-1001 (renamed VOXMM-1001) keeps VOX_PREMIUM_13.

### Item 3.3 machine_features: DONE (03:20 Dubai)

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
