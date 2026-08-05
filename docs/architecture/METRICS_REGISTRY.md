# Metrics Registry — single source of truth for every business parameter

**Status:** RATIFIED as Constitution Article 16 (2026-06-12, PRD-028 WS6; `01_constitution.html#a16`) · **Owner:** CS · **Created:** 2026-06-11

> NOTE 2026-06-12: this file (untracked) disappeared from disk during the PRD-028 WS1 session and was
> restored from the session's read buffer, with the WS1 row updated to LIVE. Content otherwise verbatim.

## The rule (Article 16 draft)

> For every business metric (a number an operator, partner, or engine acts on), there is exactly ONE
> canonical definition object in the database — a view or read-only function. Every consumer (FE page,
> RPC, engine, cron, advisory, skill, export) reads that object. No view, function, or component may
> re-derive a registered metric inline. Changing a metric definition = changing the canonical object,
> nothing else. Cody blocks any PR or migration that computes a registered metric outside its canonical
> object.

Why: in June 2026 alone, three production incidents traced to the same disease — multiple surfaces
computing their own version of one number (machine priority: 3 definitions; payment default: 3
formulas, none correct; expiry: card badge and tier logic disagreed on the same screen). Each unification
killed a bug class permanently.

## Registry

| Metric                                                     | Canonical object                                                                                                                                                                                                      | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | Known illegal copies to retire                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Machine priority tier + score (P1/P2/P3)                   | `v_machine_priority` (param-driven via single-row `refill_priority_params`, PRD-058)                                                                                                                                  | ✅ LIVE (stock-led v2, 2026-06-11; tunable via `refill_priority_params` since PRD-058 2026-06-24)                                                                                                                                                                                                                                                                                                                                                                              | ~~picker inline~~ retired (v9.2 reads view) · ~~get_machine_health inline~~ retired (2026-06-11) · FE `refillUrgency()` in `refill/page.tsx` line ~625 — still used for in-tier sort only; retire or rename to make non-authoritative · **PRD-058 (2026-06-24, `prd058_tunable_priority_weights`):** all P1/P2 tier gates + p_score weights + the dead-stock dial moved into single-row config `refill_priority_params` (CROSS JOINed into the view); CS retunes via one-row UPDATE, no migration. Seeded to the prior baked-in literals → byte-identical (T1 golden md5 `6bb5b9cbd44aa0f10f0519f7f6579dcb`). The config row is NOT a separate metric object — it is parameters for THIS canonical object. Score-internal comparison constants without a named param stay literal in the view body (documented, intentional). · **PRD-063 (2026-06-28, `prd063_p3_v_machine_priority_urgency_rewrite`): body REWRITTEN IN PLACE to the shelf-aware urgency model (supersedes the PRD-058 machine-level body). Knobs now in new singleton `pick_urgency_params` (CROSS JOINed); reads new canonical `v_shelf_sales_identity` (see its own row) for per-shelf velocity. Same object, same consumers (picker/cards). Every prior column preserved + appended urgency/soonest_a_dos/grade_a..d_count. The PRD-058 T1 golden md5 `6bb5b9c…` no longer applies (intentional behaviour change: tier now reflects whether a SELLING shelf runs out before the refill, not cosmetic fill/dead %). Rollback file `_ROLLBACK_prd063_*` restores the prior body verbatim.** · **PRD-073 (2026-07-04, `prd073b_wsb_v_machine_priority_v2_empty_lowfill`): v2 adds grade-weighted empty/low-fill terms (s_empty, s_lowfill) to the urgency blend + P1 escalation on empty A/B shelves (hero_shelf_empty). New knobs in `pick_urgency_params`: empty_wt_a/b/c/d, w_empty, w_lowfill, low_fill_pct_floor, p1_empty_ab_min. Appended output cols s_empty/s_lowfill/empty_ab_count. Same canonical object, same consumers.** · **PRD-075 (2026-07-04, `prd075_wsc_expose_urgency_terms`): +s_runout/s_capacity/s_expiry/s_stale output columns (exposure only, invariance proven; md5 a49cd7d3 -> 97e69fa0).** · **PRD-100 (APPLIED 2026-07-14): +s_holes (per-slot hole signal from new canonical `v_shelf_holes`) at w_holes, P1/P2 hole overrides + tokens empty_hero_row/empty_rows_2plus/hole_row, all gated on w_holes>0 (w_holes=0 = byte-identical golden); appended cols s_holes/holes_total/holes_a..d; chip surface (get_machine_health + consistency guard) gains the holes chip.** |
| Payment default / captured / gap (reconciliation)          | `get_payment_default_summary(from,to,venue_group,machine_ids)`                                                                                                                                                        | ✅ LIVE v2.1 `matched_only_v2_1_refund_aligned` (CS chose Option 1 + age-split, 2026-06-12; migrations `prd028_ws4_payment_default_matched_only_v2` + `..._v2_1_refund_aligned`). Gap/default over MATCHED refs, refunds are not default (PRD-023h-aligned, per-ref floor); `unmatched_exposure` explicit + age-split at 7d (recent=lag, aged=true default). Verified cent-equal with the commercial waterfall (141.30 == 141.30, VOX 06-01..11; exposure 2,209.85 all recent) | ~~/app/performance ribbon + dark bar client calc~~ wired (one pdSummary call; refunds+cash own fields) · consumer ribbon full-scope wiring to the summary ticketed to Stax (action_tracker 09a15262); pod-subset stays on the (cent-equal) waterfall until a pod_location scope param is designed                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Machine pack/pickup/dispatch readiness                     | `v_machine_pack_status` (per machine, dispatch_date)                                                                                                                                                                  | ✅ LIVE (PRD-030, 2026-06-14)                                                                                                                                                                                                                                                                                                                                                                                                                                                  | Replaces the 3 ad-hoc FE count predicates (packing-list packed_count===sku_count, pickup packed_count===total, dispatching picked_up_count===total). `is_pack_complete` = all included lines resolved (packed/partial/not_filled/skipped); pickup/dispatch over PHYSICAL (packed) subset so not_filled never blocks. FE migration to read this = PRD-030 step 4.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| Unfilled refill demand (not-filled + partial remainder)    | `v_not_filled_lines` (per machine+SKU+date, shortfall>0)                                                                                                                                                              | ✅ LIVE (PRD-030, 2026-06-14)                                                                                                                                                                                                                                                                                                                                                                                                                                                  | Fleet not-filled feed for procurement / PRD-031. `kind` = full_not_filled \| partial_remainder; shortfall = planned (original_quantity) - filled.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Plan date (today vs tomorrow)                              | `resolve_refill_plan_date()`                                                                                                                                                                                          | ✅ LIVE                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | any `CURRENT_DATE`/`CURRENT_DATE+1` used as a plan date (UTC bug). Audit FE + remaining RPCs                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Live shelf stock                                           | `v_live_shelf_stock`                                                                                                                                                                                                  | ✅ LIVE (house rule since 2026-05-19)                                                                                                                                                                                                                                                                                                                                                                                                                                          | any pod_inventory-based stock count                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| Machine expiry counts (expired now / 7d / 30d / earliest)  | `v_machine_expiry_summary` (aggregates `v_machine_expiry_batches`, the batch-resolution rule view)                                                                                                                    | ✅ LIVE (PRD-028 WS1, 2026-06-12, `prd028_ws1_expiry_canonical`); **inputs cleaned PRD-059 (2026-06-24)**                                                                                                                                                                                                                                                                                                                                                                      | ~~signals expired*skus*\*~~ rewired (consume summary) · ~~detail/slots RPC drift~~ realigned on batches view · ~~`v_pod_inventory_expiry_status` / `v_pod_inventory_health`~~ DROPPED 2026-06-12 (CS approved; pg_depend re-check 0 dependents; `prd028_ws1_drop_deprecated_expiry_views`) · **PRD-059 (2026-06-24): canonical object UNCHANGED; cleaned the `pod_inventory` rows it reads so card == drawer — 61 NULL-shelf Active relinked to their live shelf, 23 unmapped→Inactive, 110 off-machine orphans + 1,901 Inactive-with-stock→Removed/Expired (status transitions, stock preserved, reversible via write_audit_log; 0 rows deleted). Drawer reconciliation via read-only `get_machine_slots_with_expiry` (now exposes nearest_expiry_qty) + new `get_machine_orphan_expiry` (NULL-shelf batches off any live slot); both read this canonical object, no inline re-derivation. Fleet-wide only 1 residual orphan (2u).** · **PRD-105 (2026-07-28, `expiry_truth_*`): batch-resolution rule `v_machine_expiry_batches` RE-GRAINED — dedupe partition `(machine, shelf)` → `(machine, COALESCE(shelf::text,'noshelf'), boonz_product_id)` (a newer snapshot on one product was evicting a sibling product on the same shelf BEFORE the MIN; RC-3). 0-collision precondition verified; recovers dropped siblings (not-null rows 698→975, +1127u). Canonical `v_machine_expiry_summary` unchanged in shape, now fed correct rows. `get_machine_slots_with_expiry` re-keyed product-name→shelf_id (removes the machine-blind lowest-UUID `product_boonz` quasi-inline identity; RC-1/RC-6), `expiry_qty` unconditional. `get_machine_orphan_expiry` extended to off-aisle ghosts (RC-4). All still read this canonical object, no inline re-derivation. Reconciliation drawer==summary 31/31; blind-spot wrong-MIN 63→0; `s_expiry` byte-identical (no picker perturbation). Read-path only, zero writes. Open item: orphan `live_boonz` exclusion still suppresses off-aisle ghosts that are live elsewhere (RC-4 residual tail).**                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Machine velocity (7d/30d, daily)                           | `v_machine_velocity` (units_7d/30d, daily_velocity_7d/30d; Success-only, rolling windows)                                                                                                                             | ✅ LIVE (PRD-028 WS2, 2026-06-12, `prd028_ws2_velocity_canonical`)                                                                                                                                                                                                                                                                                                                                                                                                             | ~~get_machine_health inline daily_velocity~~ rewired · ~~signals units_last_7d inline~~ rewired · slot_lifecycle stored velocities (slot grain: keep) · FE Stock Snapshot displays get_machine_health (no recompute)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| WH pickable stock                                          | `v_wh_pickable` (batch grain; Active, NOT quarantined, in-date Dubai or NULL, stock>0; security_invoker)                                                                                                              | ✅ LIVE (PRD-028 WS3, 2026-06-12, `prd028_ws3_wh_pickable_dispatch_availability`)                                                                                                                                                                                                                                                                                                                                                                                              | ~~packing FE batch fetch inline predicate~~ rewired to view (28 quarantined/expired-but-Active leak rows excluded) · ad-hoc queries · `get_product_performance.wh_available` consumes it (2026-06-16)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Dispatch committed / available                             | `v_dispatch_availability` (consumes v_wh_pickable; commitments = unpacked+unpicked warehouse-origin claims, same dispatch_date)                                                                                       | ✅ LIVE (PRD-028 WS3, 2026-06-12)                                                                                                                                                                                                                                                                                                                                                                                                                                              | ~~packing FE committed=packed double-count~~ fixed (commitment = unpacked+unpicked claims; packed lines are already debited from WH) · FE per-batch pick caps still client-side (Stax follow-up: consume view per line)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Dispatch pickable + stranded (packing truth)               | `v_dispatch_pickable` (consumes v_dispatch_availability for serving pickable + reservation-aware available_qty; adds stranded_units/stranded_warehouses = same product pickable in NON-serving WHs; security_invoker) | ✅ LIVE (PRD-036 Phase A, 2026-06-18, `prd036_a_v_dispatch_pickable`)                                                                                                                                                                                                                                                                                                                                                                                                          | Packing FE `field/packing/[machineId]/page.tsx` consumes it for the stranded-stock note (a serving-WH 0 is explained, not distrusted). FE still client-re-derives the batch pick pool from v_wh_pickable (pre-existing Art-16 debt, ticketed). New signal; this view is its canonical object.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Dead slot %                                                | `v_machine_priority.dead_slot_pct` (inherits signals)                                                                                                                                                                 | ⚠️ verify                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | `get_machine_health.dead_stock_count` uses a different formula (blended-score HAVING) than signals' dead_slot_pct — reconcile                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Refill quantity decision                                   | `engine_add_pod` v18 within-machine relative-score bands (consumes `compute_refill_decision.final_score` for RANK + raw velocity blend for cover)                                                                     | 🟡 REDEFINED — file ready, awaiting CS apply (PRD-035 WS-A, `prd035_b_engine_relative_score_band`, 2026-06-18). Prior LIVE: v17 cover-capped (`prd031_ws3_engine_cover_capped`, 2026-06-14)                                                                                                                                                                                                                                                                                    | **PRD-035 WS-A redefinition (CS decision A1, 2026-06-18):** qty is STANCE-FREE. Engine ranks shelves by `final_score` WITHIN each machine (`ntile(3)`); ADD = ROUND(raw velocity blend `0.6·v7+0.4·v30` × `days_cover` × band_fraction), capacity-capped. Bands: top third 1.00 · mid 0.60 · bottom 0.30 · bottom+empty → floor 1 facing · 0 local sales (v7=0 AND v30=0) → 0. `compute_refill_decision.velocity_target`/`cover_mult`/`floor_pct`/`stance_mult`/`refill_qty`/`target_units` are now ADVISORY/display-only (NOT consumed for plan qty); `final_score` retains stance but only as the RANK signal. Behaviour note: WIND DOWN shelves that still sell now get a rank-based fill (were stance-zeroed). Follow-up: retire/rename the advisory `refill_qty`/`velocity_target` to remove latent drift. **PRD-048 (2026-06-22, `prd048_c_engine_add_pod_v19_base_stock`): v19 applied behind flag `refill_policy_params.refill_sizing_mode` (default `legacy` = byte-identical to v18; `base_stock` = service-level order-up-to via pure `compute_base_stock_decision`). The redefinition lives INSIDE the canonical object (Art 16 ✅). **ENABLED 2026-06-22 (`refill_sizing_mode='base_stock'`, GLOBAL; nightly draft human-committed via FE Gate 1+2).** ~~Art-16 TODO: inline shelf-life read~~ **RESOLVED (`prd048_e_engine_v19_shelf_life_canonical`): base_stock `shelf_life_days` now reads the canonical `v_product_shelf_life` (see its own row below); no inline `warehouse_inventory` derivation remains.** Units fix `prd048_f`: `velocity_7d/30d` are DAILY rates; engine passes `v7*7,v30*30` to the window-total helper. `wh_avail` inline predicate is grandfathered v18 debt (unchanged). Legacy gate-clean re-proven after every change (v18-verify head-to-head, byte-identical).**                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| Product shelf-life for sizing                              | `v_product_shelf_life` (FEFO remaining shelf-life days per (warehouse, boonz_product); consumes `v_wh_pickable`; security_invoker)                                                                                    | ✅ LIVE (PRD-048, 2026-06-22, `prd048_d_v_product_shelf_life`)                                                                                                                                                                                                                                                                                                                                                                                                                 | Sole source for `engine_add_pod` base_stock spoilage cap (`S ≤ mu·shelf_life·0.8`). Consumes the canonical `v_wh_pickable` (does NOT re-derive the pickable predicate). No other consumer yet; any future shelf-life-for-sizing read must use this object. **PRD-110 P2.3 (2026-07-31, `prd110_p23_engine_expiry_ceiling`): second consumer added — `engine_add_pod_v3` (shadow) reads this object for its expiry ceiling `min(S, capacity, days_to_expiry × sell_rate × safety)`.** Two derivations are ASSIGNED TO THE ENGINE by this row and must NOT be re-published as a competing view: (i) **plan-time re-anchoring** — the engine reads `earliest_expiry` and computes `GREATEST(earliest_expiry − p_plan_date, 0)`, NOT the published `remaining_shelf_life_days`, which is CURRENT_DATE-anchored and answers a different question for any future `plan_date`; (ii) **pod-grain collapse** — `MIN(earliest_expiry)` across the pod's Active `product_mapping` members and across the machine's `[primary, secondary]` warehouses, since this object is published at `(warehouse, boonz_product)` grain. The pod→WH predicate is copied verbatim from `v_shelf_availability_v3` so v3 has exactly ONE pod→WH resolution. Same precedent as the P2.2c shelf-grain sigma assignment.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Refill execution accuracy (intent vs dispatched per shelf) | `v_refill_accuracy` (grain plan_date,machine,shelf,pod,action; intent-driven so zero-dispatch leaks are visible) read via `get_refill_plan_accuracy(plan_date)`                                                       | ✅ LIVE (PRD-031 WS-4, 2026-06-14, `prd031_ws4_refill_accuracy_gate`)                                                                                                                                                                                                                                                                                                                                                                                                          | Replaces the structurally-vacuous stitch deviation block (`refill_plan_deviations` mapping_gap never fires: variant_target≡variant_final). `status` = ok\|wh_short\|leak\|over; verdict pass\|flag\|block. Sole consumers: `get_refill_plan_accuracy` + RefillPlanningTab WS-4 panel. No client re-derivation of intent/dispatched/gap.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Machine scope "active fleet"                               | `v_active_fleet` (status NOT IN Inactive/Warehouse; exposes include_in_refill, repurposed_at, service_track for declared consumer filters)                                                                            | ✅ LIVE (PRD-028 WS5, 2026-06-12, `prd028_ws5_active_fleet`)                                                                                                                                                                                                                                                                                                                                                                                                                   | ~~get_payment_default_summary inline scope~~ rewired (value-identical, jsonb-equality proven) · get_vox_commercial_report pods scope + signals base = follow-up consumers (wire on next change) · data smell: 5 Active machines carry repurposed_at                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |

| Candidate basket affinity (Pearson co-purchase) | `get_candidate_affinity(p_machine_id uuid, p_cand_pod_product_id uuid)` (read-only DEFINER; per-machine `correlation_pod_per_machine` then `correlation_pod_per_loc_type` fallback, averaged over the machine's velocity>0 basket, COALESCE 0) | ✅ LIVE (PRD-039 P0, 2026-06-20, `prd039_p0_get_candidate_affinity`) | `find_substitutes_for_shelf.basket_corr` computes the IDENTICAL score inline (dual definition) — converge it onto this helper in ONE behaviour-diffed pass (PRD-040 B1 plan; not yet executed). `engine_swap_pod` v13 Pass-3 carries a set-based mirror of this math (documented equivalent for performance; reconcile at convergence). No new inline copies permitted. |
| Shelf velocity + product identity (per machine,product) | `v_shelf_sales_identity` (grain (machine_id, canonical pod_product_id) over enabled non-broken slots; facings/stock/cap + units_30d/7d, dvel=units30d/30, dos=stock/dvel, resolved/has_sales) | ✅ LIVE (PRD-063, 2026-06-28, `prd063_p2_v_shelf_sales_identity`) | Sole source of per-(machine,product) shelf velocity for `v_machine_priority` urgency. Sales resolve from `sales_history.pod_product_name` (text) via the SAME `pod_products`/`product_name_conventions` name tiers `v_live_shelf_stock` uses, folded through a scoped pod-identity alias (Hunter↔Hunter Ridge; pods are mixes so boonz_product_id is NOT a usable identity key). Success-only + 30d window = identical sales definition to the machine-grain `v_machine_velocity`. Any future per-product velocity read must use this object, not re-aggregate `sales_history`. Identity coverage 100% at apply (≥95 gate). |
| Historical shelf state (per machine,snapshot,slot) | `v_weimi_shelf_history_v3` (grain (machine_id, snapshot_at, cabinet_index, layer_label, slot_name); pod identity via the canonical four-tier resolver; `security_invoker=true`) | ✅ LIVE (PRD-110 P2.1, 2026-07-30, `prd110_p21_v_weimi_shelf_history_v3`) | **Registered as an Article 16 condition of Cody's approval.** Serves _historical_ shelf state — unregistered before now, and structurally underivable from `v_live_shelf_stock`, which is a `DISTINCT ON latest` view. It does NOT compete with the "Live shelf stock" row above: restricted to the latest snapshot per device and put through the live view's own final `DISTINCT ON`, it reproduces `v_live_shelf_stock` **exactly** (807=807; zero diffs on pod_product_id / current_stock / match_method / is_eligible_machine). That equivalence assertion is the anti-drift guard and must be kept. Source is `weimi_device_status`, NOT `weimi_aisle_snapshots` (the two disagree on 294 stock keys/30d — S-21 — and only device_status is on the engine's read path). Two deliberate improvements over the live view: keyed on `machine_id` (device_name is not 1:1 with machine_id — 11 machine_ids span >1 device_name, so the live key can silently drop a machine) and a deterministic tiebreak on the conventions tier. Live coverage: 79,094 rows / 44 machines, 1.33% unmatched. Any future historical-shelf-stock read must use this object. |
| In-stock velocity (per machine,product) | `v_shelf_instock_velocity_v3` (units per IN-STOCK day; stock_hours via the A/B/C/D case model with the case-X unobservable guard; 48h floor) | 🟢 **CANONICAL from 2026-07-31 leg 34** (PRD-110 P2.1, applied 2026-07-30 as `prd110_p21_v_shelf_instock_velocity_v3`). Consumed **transitively** — `engine_add_pod_v3` reads the shelf-grain `v_shelf_instock_velocity_split_v3`, which reads this. The two rows are promoted together and must move together. | Intended to stop a shelf that sold out early from reading as low demand. **Article 16 shaped this object:** the velocity NUMERATOR is read from the canonical `v_shelf_sales_identity.units_30d` and is never re-aggregated from `sales_history`; raw `sales_history` is used ONLY for intra-interval depletion timestamps (cases C/D, ~2% of cells), which are not a registered metric. Series outside the canonical object's scope get `velocity_status='out_of_canonical_scope'` and a **NULL** velocity — never a silent 0 (LAW 5). ⚠️ Never verified against the P2.1 oracle, and **too slow to query as written** — it caused a 35-minute production saturation on 2026-07-30 (S-22). **Perf FIXED 2026-07-30 leg 18** (`prd110_p21_velocity_v3_perf_single_flatten`, `20260730170009`): 4 history-view evaluations → 1; now queryable fleet-wide in one statement (687 series / 41 machines). Behaviour-identical — A1 anchor equality, A2 snaps 1208=1208 (EXCEPT 0/0), A3 output 687=687 with zero diffs on every column. **Still 🔴 not-yet-canonical: fast and meaning-preserving is not the same as correct.** Promote to LIVE only after the P2.1 oracle comparison (`PRD-110-P21-ORACLE.json`) — perf work never promotes a metric. Probe one cheap aggregate at a time, scoped to one machine, always with `SET statement_timeout`. **→ ORACLE COMPARISON DONE 2026-07-30 leg 19 (S-23): the A/B/C/D MECHANISM IS VERIFIED.** 648 series joined; window-normalised in-stock fraction agrees within **1 percentage point on 82.9%**, 5pp on 97.1%, 10pp on 98.3%. Every residual is attributed, not waved away: `elapsed_hours` deltas are **quantised at 1.35h + k×24h**, where the 1.35h is the two source tables' differing newest-snapshot time and each 24h step is one day on which `weimi_device_status` resolved a pod that the oracle's aisle-table resolver did not (S-21); the numerator differs on only 54/493 series and **always in the same direction** (view ≥ oracle, +3…+12 units), exactly as a window ending 3.4h later predicts. `velocity_instock` agrees within 10% on 86.4%. **Status stays 🔴 pending TWO open items, both recorded, neither a mechanism defect:** (1) the object is **not reproducible across days** — `t_anchor = max(weimi_device_status.snapshot_at)`, and the cadence is daily-at-22:00-UTC with ±2h jitter plus occasional off-cadence arrivals (one landed mid-verification at 17:23:07 UTC, adding a 19.37h final interval to all 41 machines and shifting the case mix). Any fixture asserting exact numbers off this view WILL flake. **→ RESOLVED 2026-07-30 leg 20: ASSERT THE MECHANISM; the anchor STAYS MOVING.** A moving anchor is _correct_ for production - it is what makes the engine read current velocity - so pinning it in the view would freeze the engine's view of the fleet, a worse defect than a flaky fixture. ⚠️ **And pinning it could never have delivered reproducibility anyway (RISK 56, found by this resolution): the two halves of `velocity_instock` are on DIFFERENT CLOCKS.** The denominator `stock_hours` spans `[t_anchor - 30d, t_anchor]` (WEIMI snapshot time) while the numerator `v_shelf_sales_identity.units_30d` filters `transaction_date >= now() - '30 days'` (wall-clock), so the numerator slides continuously while the denominator is frozen until the next snapshot lands - **the metric drifts even when no new data arrives.** Magnitude today is near zero (anchor lag 0.474h -> 0 units misaligned either side; `units_window` agrees with `units_30d_canonical` on 521 of 525 series, max delta 6) but it scales with ingest lag: at 24h lag ~1/30 of the window misaligns, ~296 units/day against 8,874 per 30d. Fix belongs with D-10 (use the view's own `units_window`), not in a fixture task. **THE CONTRACT fixtures 2 and 14 assert - 9 anchor-independent invariants, all verified live on all 687 series, 0 violations:** I1 `stock_hours <= elapsed_hours` · I2 both hours non-negative · I3 `stock_censoring` in [0,1] · I4 **`velocity_instock >= velocity_raw`** whenever both non-NULL (true by construction since `stock_hours/24 <= 30`; the strongest of the nine - it catches an inverted ratio or a unit error that eyeballing numbers never would) · I5 `out_of_canonical_scope` => BOTH velocities NULL (LAW 5) · I6 `below_floor` => `stock_hours < floor_hours` and velocity NULL · I7 `ok` => velocity NOT NULL · I8 no negative case counts · I9 an all-X series has NULL `elapsed_hours`. Distribution: **ok 517 · below_floor 8 · out_of_canonical_scope 162**. 📌 The view **exposes `t_start`, `t_anchor` and `floor_hours` as columns** (non-NULL on all 687 rows) - fixtures must **record the anchor they ran against**, so a later investigation can separate "the anchor moved" from "the engine changed" without guessing. (2) the `out_of_canonical_scope` population (below). **GATE NOW NARROWED TO D-10 ALONE:** the mechanism is verified (S-23) and the invariants are verified (leg 20); what remains is a _consumer_ decision - what `engine_add_pod_v3` does with 162 NULL velocities - not a defect in the metric. Flip to 🟢 canonical as soon as D-10 is answered. |
| Per-slot hole state (present-tense emptiness) | `v_shelf_holes` (grain = physical slot; is_hole = stock 0 OR fill ratio <= pick_urgency_params.hole_frac; grade/hole_wt from pooled `v_shelf_sales_identity` velocity) | ✅ LIVE (PRD-100, 2026-07-14) | Deliberately NOT a runout metric: pooled DOS (v_shelf_sales_identity) answers "when do we run out"; this answers "is there a hole on the wall right now". Sole consumer: `v_machine_priority` s_holes. Any future emptiness read must use this object. |
| Machine grading eligibility (drift) | `v_machine_eligibility_drift` | ✅ LIVE (PRD-073 WS-A, 2026-07-04) | New monitor: Active + Online-today machines contributing ZERO rows to `v_shelf_sales_identity` (any cause - bad adyen_inventory_in_store value, repurposed_at set, no shelves). Should be empty; every row here is a machine the urgency model cannot see. Known residue 2026-07-04: 3 repurposed-but-Active + Pending Setup machines. |
| Days since visit (THE visit clock) | `v_machine_health_signals.days_since_visit` | ✅ CANONICAL (PRD-074, 2026-07-04) | Definition (PRD-075 final, prd075c): refill_dispatching evidence (picked_up OR returned OR **dispatched OR packed**) OR pod_inventory_audit_log refs **'manual-refill-%' OR 'adjust-%'** - GREATEST of the two clocks. Approved-only plans NEVER count. Consumers: v_machine_priority (stale terms), get_machine_health v3 (pass-through), get_stale_visit_signals v2 (threshold = pick_urgency_params.stale_override_days). ~~get_machine_health visit_data MAX(approved plan_date)~~ retired - that notion is now `last_plan_date` (informational, NEVER a visit). ~~get_stale_visit_signals private approved-plan def + >10 literal~~ retired. |
| Last plan date (informational) | `get_machine_health.last_plan_date` (MAX approved refill_plan_output.plan_date) | ✅ NAMED (PRD-074) | Approved-plan recency. Labeled separately on FE cards ("last plan Nd"); must never be presented as a visit. |
| Urgency breakdown (chip surface) | `get_machine_health.urgency_breakdown` (jsonb [{label, pts}], pts sum == v_machine_priority.urgency) | ✅ LIVE (PRD-074) | Built server-side from v_machine_priority.urgency/s_empty/s_lowfill x pick_urgency_params weights; ~~lumped core chip~~ SPLIT 2026-07-04 (PRD-075): six real terms, runout carries the rounding residual, sum == urgency exactly. ~~refill/page.tsx 8 hardcoded chip formulas~~ DELETED 2026-07-04. FE renders verbatim, zero client math. Guard: check_priority_surface_consistency() (urgency_breakdown_sum field). |
| Product performance + factor-adjusted expected demand | `get_product_performance(p_bucket, p_as_of)` (per-product trailing 3mo + MTD throughput, expected month-end demand, units/revenue/avg over 3mo+MTD; sourcing buckets boonz/vox/all) | ✅ LIVE (2026-06-16, `get_product_performance_rpc`) | Net-new; this fn IS the canonical object. Source `v_sales_transactions` (Successful), bucketing AT TIME ZONE Asia/Dubai. Sole consumer = `/app/products` Performance tab. Back-test Boonz Mar–May 2026 = 5,594 units / AED 59,618. Future surfaces must read this fn, not re-derive product throughput/expected. |

## Enforcement

1. **Cody checklist addition (class b/c reviews):** "Does this object compute a registered metric inline?
   If yes → block, point to canonical object." Add to cody SKILL.md review playbook.
2. **CI lint (Phase B):** grep migrations + src for signature patterns (`expiration_date <`, `daily_velocity`,
   `captured_amount_value` aggregations, `CURRENT_DATE + 1`) outside canonical objects → fail with pointer here.
3. **This file is the registry.** Adding a metric = adding a row here + the canonical object in the same PR.

## Execution order (each step: Dara design → Cody review → migrate → verify consumers)

1. ~~**P0 expiry**~~ ✅ DONE 2026-06-12 (`prd028_ws1_expiry_canonical`): `v_machine_expiry_summary` canonical
   over new `v_machine_expiry_batches`; signals rewired; detail/slots RPCs realigned; AC green (30 machines,
   0 disagreements; OMDBB-1020 fixed).
2. ~~**P1 velocity**~~ ✅ DONE 2026-06-12 (`prd028_ws2_velocity_canonical`): `v_machine_velocity` canonical;
   `get_machine_health` (values identical) + `v_machine_health_signals` consume it; AC green (0 mismatches,
   no inline machine-level SUM(qty)/7 left).
3. ~~**P1 WH pickable + dispatch availability**~~ ✅ DONE 2026-06-12 (`prd028_ws3_wh_pickable_dispatch_availability`):
   `v_wh_pickable` created (28 leak rows excluded); `v_dispatch_availability` consumes it + picked_up
   condition; packing FE badges rewired (pickable fetch, unpacked-claims commitments, product-grain
   Available). FE build green.
4. **P1 FE banner wiring** — get_payment_default_summary into the 3 reconciliation banners (prompt already drafted).
5. ~~**P2 active-fleet scope view**~~ ✅ DONE 2026-06-12 (`prd028_ws5_active_fleet`): `v_active_fleet` live,
   `get_payment_default_summary` consumes (jsonb-equality zero value change); remaining consumers wire on
   their next change.
6. **Ratify Article 16** into 01_constitution.html, update Cody SKILL.md.

## PRD-110 P1.1 (2026-07-30) — product sourcing per machine

| Metric                             | Canonical object                                                                 | Notes                                                                                                                                                                                                                                       |
| ---------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Sourcing of a product on a machine | `resolve_product_sourcing_v3(machine, pod, sku?)` / `v_product_sourcing_current` | No consumer may infer sourcing from `product_mapping.source_of_supply` directly, and none may infer it from `venue_group` or from the presence of a `VOXSOURCE-*` sentinel row. Those are the two inference paths PRD-110 exists to delete. |
| Machine operating model            | `machines.operating_model` (proposal: `v_machine_operating_model_proposed`)      | NULL = unclassified; rules are INERT while NULL. Never derive the model from `venue_group` at read time.                                                                                                                                    |

⚠️ The single most expensive inference bug this replaces: reading sourcing from the MOST SPECIFIC
`product_mapping` row. Fade Fit and Aquafina each carry a global-default row marked `venue_team` and
a machine-scoped row marked `boonz` on every VOX machine. "Most specific wins" therefore resolves
both to Boonz-sourced on exactly the co-managed machines where the venue supplies them — which is
S-10 and the Aquafina half of S-06. The correct rule is: on a `co_managed` machine, a `venue_team`
mapping at ANY scope wins.

## PRD-110 P1.2 (2026-07-30) - shelf state

| Metric                                                            | Canonical object                    | Notes                                                                                                                                                                                                                                |
| ----------------------------------------------------------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Shelf state (identity, stock, capacity, sourcing, signal, expiry) | `v_shelf_state`                     | G1 "one truth". One row per non-phantom shelf on an Active + `include_in_refill` machine. Full column provenance: `SHELF_STATE_DEFINITION.md`. Consumers migrate at P2 (engines), P2.6 (preflight), Stax ticket (FE scorer deleted). |
| Shelf-grain physical verification recency                         | `v_shelf_state.days_since_verified` | Shelf-grain sibling of the visit clock, NOT a replacement: the machine-grain clock stays `v_machine_health_signals.days_since_visit`, which `v_shelf_state` PASSES THROUGH unchanged. P1.4 refines it with `driver_confirm` events.  |

⚠️ `v_shelf_state` **re-derives nothing**. Stock = `v_live_shelf_stock` (via `v_shelf_slot_identity`),
expiry = `v_machine_expiry_batches`, sourcing = `v_product_sourcing_current` / `resolve_product_sourcing_v3`,
visit clock = `v_machine_health_signals`. If a future edit inlines any of these, Article 16 is broken.

⚠️ `velocity_raw` is (machine, pod) grain REPLICATED across that pod's shelves - 11 shelves of one pod
each read the pod's full 19.17/day. Never SUM it; divide by `pod_shelf_count` or wait for P2.1's
`velocity_instock`.

## PRD-110 S-12 backfill (2026-07-30) - plan conservation vs refill accuracy

Registry omission closed, not a new object: `preflight_refill_plan` shipped with PRD-109 on
2026-07-29 and appeared in **no** registry. Full description in `RPC_REGISTRY.md` (Read-only helpers).

| Metric                                              | Canonical object                                                               | Notes                                                                                                                                                                                                                                                                                                                                                                                                                |
| --------------------------------------------------- | ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Plan conservation (`REMOVE` / `M2W` parents closed) | `preflight_refill_plan(plan_date)` **INV-06** (`set_version v2` predicate)     | A REMOVE parent is satisfied when a matching `Remove` line exists in `refill_plan_output` (join plan/machine/shelf/pod + action). The stitch commit gate; enforcement level in `refill_policy_params.preflight_enforcement`. **Second consumer 2026-07-31 (PRD-110 leg 50, P2.6): `commit_refill_plan` reads the same object before its INSERT — one flag arms both gates. Nothing re-derives an invariant inline.** |
| Refill execution accuracy (`REFILL` / `ADD_NEW`)    | `v_refill_accuracy` read via `get_refill_plan_accuracy(plan_date)` (row above) | Unchanged. Intent-vs-dispatched per shelf.                                                                                                                                                                                                                                                                                                                                                                           |

⚠️ These two are **deliberately disjoint by action**: INV-06 owns `REMOVE`/`M2W`, `v_refill_accuracy`
owns `REFILL`/`ADD_NEW`. Article 16 asks for one canonical object per metric, which invites a future
leg to "consolidate" them - doing so silently drops one action domain from coverage. They are two
metrics, not two implementations of one.

## PRD-110 P1.4 (2026-07-30, leg 9) - composition belief vs batch records

Two new read-only views (`prd110_p14_audit_prompt_and_expiry_action_views`). Both sit next to
already-registered objects, and Article 16's "one canonical object per metric" invites a future leg to
merge them. Merging either pair silently deletes a domain, so the disjointness is registered here with
its reason - the same pattern as INV-06 vs `v_refill_accuracy` above.

| Metric                                                   | Canonical object        | Notes                                                                                                                                                                                                              |
| -------------------------------------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Driver audit prompt selection (which shelves to verify)  | `v_shelf_audit_prompts` | BUILD SPEC P1.4 "flagged shelves only, top uncertainty x value-at-risk, max 3/visit". Flagged = confidence < `composition_confidence_prompt_threshold`; rank per machine; cap `composition_max_prompts_per_visit`. |
| Believed-expired units on a shelf + the auto-action gate | `v_expiry_action_queue` | `action = auto_write_off` when confidence >= `composition_confidence_min_autoaction` (0.7), else `verify_task`. Proposing is not doing: the EXPIRY IRON RULE still requires a human `write_off` event.             |

⚠️ **`v_expiry_action_queue` is DISJOINT from `v_machine_expiry_summary` / `v_machine_expiry_batches`.**
The registered expiry metric reads `pod_inventory` - physical **batch records**. This view reads
`shelf_composition` - the estimator's per-SKU **belief**. Different questions, and the DATA-SOURCE LAW
forces them apart (`pod_inventory` = expiry history ONLY, never current state). Note a shelf now has
two expiry surfaces: `v_shelf_state.oldest_expiry_est` answers "what does the batch record say", this
view answers "what do we believe is on the shelf right now, and are we sure enough to act". Do not
merge them.

⚠️ **`v_shelf_audit_prompts` is DISJOINT from `v_machine_priority`.** That object ranks MACHINES for
refill urgency; this one ranks SHELVES for physical verification. Different grain, different purpose,
different consumer (the Stax driver-collapse UI). Folding the audit ranking into the priority view
would lose the verification domain entirely.

⚠️ The prompt-selection rule lives in the DB **on purpose**. P1.2 deleted the FE's independent shelf
scorer to satisfy G1 "one truth"; re-implementing "which 3 shelves do I ask the driver about" in the FE
would recreate exactly that defect one layer up.

---

## PRD-110 P1.3 — plan-time shelf availability (`v_shelf_availability_v3`)

| Metric                       | Canonical object          | Status                                                   | Replaces / disjoint from                                                                         |
| ---------------------------- | ------------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Plan-time shelf availability | `v_shelf_availability_v3` | ✅ LIVE (2026-07-30, `prd110_p13_availability_contract`) | the VOXSOURCE sentinel pattern; disjoint from the three dispatch-side availability objects below |

**The contract.** `available_units IS NULL` means **unconstrained** — the venue or partner supplies
that shelf and Boonz WH stock is irrelevant to whether it can be planned. Otherwise it is real Boonz
WH stock with sentinel rows excluded. This is the object that makes the 40 fake `999` rows
unnecessary: it returns the same answer whether or not they exist.

⚠️ **It consumes `v_wh_pickable` and does NOT re-derive the pickable predicate** (Article 16).
`engine_add_pod` v19 keeps its own inline copy — that is **grandfathered** debt recorded against the
"Refill quantity decision" row, and it does not extend to new objects. P2.1 closes it when
`engine_add_pod_v3` reads this view.

⚠️ **DELIBERATELY DISJOINT — do not consolidate.** Four availability objects exist and each answers a
different question:

| Object                    | Grain     | Question                                              |
| ------------------------- | --------- | ----------------------------------------------------- |
| `v_wh_pickable`           | batch     | what can be picked at all (no machine, no sourcing)   |
| `v_dispatch_availability` | batch     | what is uncommitted on a dispatch date (PACKING)      |
| `v_dispatch_pickable`     | batch     | packing truth incl. stock stranded in non-serving WHs |
| `v_shelf_availability_v3` | **shelf** | can this shelf be PLANNED, given who supplies it      |

A venue-sourced shelf is _unconstrained_ here and simply **absent** from the dispatch views, because
nothing is picked for it. Folding this into the dispatch family would lose the sourcing dimension,
which is the entire point of WS-A2. Folding it into `v_shelf_state` would put commitment-blind
warehouse math into the shelf-truth view.

⚠️ **`would_block_on_retirement` is a live column, not a snapshot** (Article 14). The parked sentinel
retirement (D-09) is a decision about production data; a materialised impact report would go stale
between review and apply. It reads 0 fleet-wide today.

---

## PRD-110 Phase 2 (2026-07-30, leg 14) — v3 proposed plan (shadow) and the v3-vs-v19 diff

Registered per `ADR-shadow-plan-tables.md` §7 (Article 16 row) and §8.1. Closes the Article-16 half of
**S-19**.

| Metric / concept              | Canonical object           | Rule                                                                                                                  |
| ----------------------------- | -------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| **v3 proposed plan (shadow)** | `pod_refill_plan_shadow`   | What `engine_add_pod_v3` proposed, at `produced_at`, under `run_id`. Write-once per run, never UPDATEd.               |
| **Approved plan (live, v19)** | `pod_refill_plan`          | Unchanged, unaffected, and the ONLY thing dispatch/stitch/preflight/FE/advisory read.                                 |
| **v3 vs v19 plan divergence** | `v_shadow_vs_live_plan_v3` | `diff_kind ∈ {match, qty_diff, v3_only, v19_only}` at the plan grain. Do not re-derive this comparison anywhere else. |

⚠️ **`pod_refill_plan_shadow` and `pod_refill_plan` are EXPLICITLY DISJOINT — never union them.**
They have the same grain and near-identical columns, which makes them look consolidatable. They are
not. `pod_refill_plan` is a **protected entity** that drives real dispatch; the shadow table is a
**proposal ledger with no operational consumer**. A `UNION ALL` between them, or an `is_shadow` flag
folding one into the other, is exactly the design ADR §4 rejected: it would put non-plan rows inside a
protected entity that five consumers read without a `WHERE` predicate, and one missed predicate
dispatches a driver against a shadow plan.

⚠️ **Reading the shadow table requires naming a run.** Every row carries `run_id`, `engine_tag` and
`produced_at`; re-runs are additive. There is no "current shadow plan" without a run selector — that
is the ADR §5.3 staleness guarantee, not an inconvenience. `v_shadow_vs_live_plan_v3` picks
`DISTINCT ON (plan_date) … ORDER BY produced_at DESC`, i.e. the **latest run for each plan_date**,
and exposes `run_id` so the reader always knows which one it got.

⚠️ **The diff is restricted to plan_dates where a shadow run exists.** An absent shadow therefore
reads as _no data_, never as _total divergence_ — a distinction that matters the moment WMAPE is
computed over a window in which the shadow engine did not run every night.

**Retention (ADR §5.4):** shadow rows older than 90 days are droppable without loss; the scoreboard
aggregates are the durable artifact. Purge is manual and logged — never a cron that could race a diff
mid-read.

## PRD-110 P2.1 (2026-07-30, relay leg 21) - shelf-grain in-stock velocity

| Metric                                                            | Canonical object                    | Status                                                                                                                                                                    | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ----------------------------------------------------------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| In-stock velocity **per shelf** (units/in-stock day, shelf grain) | `v_shelf_instock_velocity_split_v3` | 🟢 **CANONICAL from 2026-07-31 leg 34.** Sole consumer: `engine_add_pod_v3` (`20260731012755`), which reads it ONCE per run and copies `velocity_instock_shelf` verbatim. | **PROMOTED 2026-07-31 leg 34.** Both gates are now discharged: D-10 was ANSWERED on evidence at leg 32, and the object's own join defect was fixed at leg 33 (S-37). The promotion is deliberately made in the same atomic unit as the first consumer, not before — Cody's Art 16 revision on `20260731012755`. **The consumer contract is fixture-enforced (fixture 14 seq 40-48, all green at promotion):** a plan line reads `velocity_source='instock_split'` **iff** this object publishes a non-null `velocity_instock_shelf` for that shelf (seq 42, 0 mismatches in either direction); the number is copied **exactly**, never rescaled or re-derived (seq 44); and `cover_units = ceil(velocity x days_cover)` with **no /30 and no \*30** anywhere (seq 46 — this is what kills S-13). ⭐ **SUPERSEDED 2026-07-31 leg 44 (P2.2c, `20260731061440`): the sizing identity is now `cover_units = ceil(velocity_effective_daily x horizon_days + z x sigma_daily_shelf x sqrt(horizon_days))`.** The S-13 intent is UNCHANGED and seq 46 still enforces it — every rate in the identity is a calendar-DAY rate, so any /30 or \*30 still reds it. What changed is only the horizon: `days_cover` (a caller argument) gave way to `horizon_days` (the per-machine measured cadence + lead from `v_machine_base_stock_policy_v3`). `days_cover` was **re-roled, not orphaned** — still required, still validated, still echoed verbatim into `pod_refills_shadow.days_cover` so shadow-vs-v19 diffing stays comparable, and it remains the **tier-3 horizon fallback** for any machine with no policy row (0 such machines live; the tier is defensive). Fixture 14 seq 50-57 pin the new contract. ⚠️ **`pod_refills_shadow.velocity_instock` CHANGED MEANING on 2026-07-31.** Before leg 34 it was an always-NULL passthrough of `v_shelf_state.velocity_instock`; from `20260731012755` it carries this object's shelf-grain rate and is non-null on **exactly** the `instock_split` lines (seq 47). Rows written before that migration are NOT comparable — scope by `run_id` and check `reasoning->>'engine_calibration' = 'v3_p21_velocity_instock'`. ⚠️ **PERF IS A CONSUMER CONSTRAINT, not a footnote (S-26 / RISK 88):** ~20 s per evaluation, and **machine-scoping does not reduce it** (measured leg 34: one machine 19.77 s vs fleet-wide 19.8 s — the inner `vel` CTE is MATERIALIZED so no predicate pushes down). Any consumer must read it **once per run and join**. This is also why `v_shelf_state.velocity_instock` is still NULL and fixture 3 seq 15 still asserts so: `v_shelf_state` costs 113 ms and is read four times per engine run plus once per FE machine-page load, so folding this object into it would multiply ~20 s across every consumer. Populating that column needs the S-26(b) materialised-history escalation first — parked as **S-39**. | Re-grains `v_shelf_instock_velocity_v3` (machine, pod) onto the shelves that hold the pod. Velocity comes from the pod-grain object, the shelf universe and the `shelf_id` <-> WEIMI `slot_name` join come from `v_shelf_state` (which owns them via `v_shelf_slot_identity`), stock history from `v_weimi_shelf_history_v3`. Applied `20260730181405` + `…181608` + `…181902`. **⚠️ CORRECTED 2026-07-31 leg 33 (S-37): this row used to claim the object "re-derives nothing". That is no longer true, and it was the bug.** The object had NO pod-alias canonicalisation while both `v_shelf_sales_identity` and `v_shelf_instock_velocity_v3` do, so it joined a RAW pod key against a CANONICAL one and 16 Hunter shelves silently carried a NULL velocity. `20260731012000` canonicalises the alias in `shelves` **and** `slot_stock` and **recomputes `pod_shelf_count` over the merged group** (the join-only fix double-counts on the 7 machines carrying both shelves; see MIGRATIONS_REGISTRY S-37 for why conservation cannot detect it). **The object therefore now carries a THIRD inline copy of a pod-identity rule `v_shelf_sales_identity` owns — recorded Article 16 debt, not a design.** There is no canonical alias object to read; convergence onto one is parked as **S-38**. Drift is blocked mechanically by golden fixture 2 **seq 65**, which fails the instant the three definitions stop agreeing on the pair. Post-fix: 544 rows, family 26, 24 recover velocity, the 2 that stay NULL are AMZ-1046 (D-13). |

**This object closes the `velocity_raw` warning two sections above** (_"⚠️ `velocity_raw` is (machine, pod)
grain REPLICATED across that pod's shelves … Never SUM it; divide by `pod_shelf_count` or wait for
P2.1's `velocity_instock`"_). It is that object - and it **supersedes the `1/n` advice with a measured
weight**, because `1/n` is wrong by up to 2x in the tail (leg-16 F7, reproduced independently on the
`weimi_device_status` path at leg 21: same 4 worst pairs, weights within ±0.003).

**The split.** `w_instock = shelf_instock_hours / SUM(shelf_instock_hours) OVER (machine, pod)`.
`split_method` names the branch so no case is silent: `single_shelf` (n=1, w=1) · `instock_weighted`
(the normal case) · `zero_instock` (the pod had hours, this shelf had none -> w=0, **named, not
hidden**) · `equal_fallback` (the pod had no in-stock hours anywhere -> w=1/n).
Live at apply: **441 single_shelf · 102 instock_weighted · 1 zero_instock · 0 equal_fallback**.

**Conservation is EXACT, not toleranced** - and that took two forward migrations to get right:
rounding the output to 6dp broke it by up to n×5e-7, and un-rounding still left ±1e-20 because
numeric division truncates at 20dp on repeating decimals (7 × 0.142857… ≠ 1). One deterministic shelf
per pod (`is_residual_absorber` - most in-stock hours, ties by `shelf_id`) absorbs the residue.
⚠️ **A future edit must not reintroduce rounding on `velocity_instock_shelf` / `velocity_raw_shelf`.**
A conservation law with a fudge factor is where a real defect hides; a tolerance loose enough to pass
(1e-9) is loose enough to conceal a genuine 1e-9 error.

**Verified live on all 544 pod-bound shelves at apply, 0 violations:** V1 one row per shelf, no
fan-out (544 = 544) · V2 `SUM(w_instock) = 1` exactly · V3 `SUM(velocity_instock_shelf) =
velocity_instock_pod` exactly · V3b same for `velocity_raw_shelf` · V4 `w_instock` in [0,1] ·
V5 `shelf_instock_hours <= pod_instock_hours` · V6 pod-NULL <=> shelf-NULL (LAW 5: an absent signal,
never a silent 0) · V7 exactly one absorber per (machine, pod).

⚠️ **D-10 IS MUCH SMALLER AT SHELF GRAIN THAN THE POD-GRAIN NUMBER SUGGESTS, and it decomposes into
two nameable data problems rather than one modelling question.** Pod grain says 162 of 687 series
(23.6%, 37 machines) are `out_of_canonical_scope`. But the engine plans **shelves**, and most of those
series are historical pod bindings no longer on any shelf. Measured on the live 544:
**39 shelves (7.2%) carry a NULL velocity, and they decompose with no residual:**

| cause                                | shelves | shape                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------------ | ------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `out_of_canonical_scope`             |  **15** | **all on ONE machine, `AMZ-1046-2406-O1`** - every pod on it, so this is a machine-level absence from `v_shelf_sales_identity`, not a per-product gap                                                                                                                                                                                                                                             |
| no row in the pod-grain view at all  |  **16** | **all the SAME pod, `Hunter`**, one shelf on each of 16 different machines - `Hunter` never resolves in `v_weimi_shelf_history_v3`, so it produces no series. This is the **Hunter / Hunter Ridge** identity landmine (leg-16 F5; PRD-109 "name family = Active mapping ANY scope UNION `product_family_id`, **never** name-prefix") showing up as missing velocity. `Hunter Ridge` DOES resolve. |
| `below_floor` (48h guard, by design) |   **8** | the designed thin-series guard, not a defect                                                                                                                                                                                                                                                                                                                                                      |
|                                      |  **39** | = the exact NULL count, nothing unattributed                                                                                                                                                                                                                                                                                                                                                      |

So the D-10 ask should be answered against **7.2% of live shelves, concentrated in one machine and
one pod**, not "a quarter of the fleet". Two of the three buckets look fixable at the data layer
rather than by an engine branch.

**Anchor.** Inherits the moving `t_anchor` of the pod-grain view (RISK 53 resolved leg 20: assert the
mechanism, do not pin) and re-exposes `t_start` / `t_anchor` so fixtures record what they ran against.
RISK 56 (numerator and denominator on different clocks) is inherited unchanged.

⚠️ **PERFORMANCE - a correction to S-22's "perf half closed".** Reading this view fleet-wide costs
**~19s**, of which **~15.4s is the pod-grain view** and only ~3.1s is the split machinery.
`v_shelf_instock_velocity_v3` was benchmarked at leg 18 with `count(*)`, which lets the planner elide
the `dep` CTE (the correlated case-C depletion subquery) **and** the `v_shelf_sales_identity` join -
so the recorded 3.4s never exercised the expensive path. Measured properly at leg 21:
`count(*)` **3.4s** vs `count(velocity_instock)` **15.4s** on the same object.
`v_shelf_sales_identity` itself is only **85ms**, so the cost is `dep`, not the numerator.
**Do not benchmark either velocity object with `count(*)`.** Carried as **S-26**.

---

## PRD-110 P2.0b — shadow objects at the engine-advisory grain (relay leg 24, 2026-07-30)

Article 16 requires one canonical object per registered metric. Two objects are registered here, and
one **anti-registration** is recorded because it is the more likely future mistake.

| Metric                                 | Canonical object                    | Disjoint from                                                                        |
| -------------------------------------- | ----------------------------------- | ------------------------------------------------------------------------------------ |
| v3 proposed refill quantities (shadow) | `public.pod_refills_shadow`         | `public.pod_refills` — the **live** engine's advisory output. Disjoint by engine.    |
| v3 blocked demand (shadow)             | `public.v_blocked_demand_shadow_v3` | `public.blocked_demand` — the **live** ledger written by `record_blocked_demand_v3`. |

Both are disjoint from their live twins **by source, not by shape**: the shadow objects are written
only by `engine_add_pod_v3`, the live ones only by the v19 chain. That is deliberate — the Phase-2
gate (WMAPE(v3) ≤ WMAPE(v19)) is a comparison, and a comparison needs two objects, not one merged
one. Do not consolidate them. Consolidation would delete the gate.

### ⚠️ ANTI-REGISTRATION — `pod_refills_shadow.velocity_instock` is NOT a metric object

The column records **what the engine used at run time**. It is provenance, not a metric. That is
still true, and it is still the reason this anti-registration exists — but **the gate language below
was rewritten on 2026-07-31 (leg 34) because both of its premises expired.**

⚠️ **CORRECTED leg 34.** This entry used to read "`v_shelf_instock_velocity_v3` remains 🔴
not-yet-canonical, and the sole gate on promoting it is D-10 (39 of 544 shelves … 16 on the `Hunter`
pod that never resolves in WEIMI history …)". **Both halves are now wrong.** D-10 was ANSWERED on
evidence at leg 32 — and its `Hunter` cohort was never a data absence at all but the S-37 join
defect, fixed at leg 33. Both velocity objects were promoted to 🟢 at leg 34, in the same unit as
their first consumer.

**The anti-registration itself STANDS, unchanged in substance.** Read the **view**, never this
column, when you want the metric. The column is scoped to one `run_id` and one engine version, and
its meaning changed on 2026-07-31 (always-NULL passthrough → shelf-grain rate on exactly the
`instock_split` lines). A fleet-wide read of it is a read across incomparable runs. Also recorded as
a `COMMENT ON COLUMN` in the database, so the warning survives without this file.

📌 **What replaced D-10 as the thing to understand here:** a shelf with no in-stock velocity is not
starved and is not silently zeroed. `engine_add_pod_v3` falls back to `v_shelf_state.velocity_raw`
and records `velocity_source='weimi_raw_fallback'` (LAW 5 + LAW 6). Live at leg 34, that cohort is
`AMZ-1046-2406-O1` — 16 of 16 shelves, a **data** problem (stale Adyen metadata on a selling
machine, **D-13**), not a modelling one — plus whatever sits under the designed 48h cold-start floor
on the day. Never read a `weimi_raw_fallback` line's velocity as an in-stock rate.

📌 **`velocity_30d` is deliberately absent from the shadow** (S-13). Anything needing v19's velocity
for a diagnostic diff joins `public.pod_refills`, which still carries it. The shadow does not
propagate a column whose name and units disagree.

---

## Article 16 · "v3 proposed ADD plan (shadow)" — canonical object registered at PRD-110 leg 31

ADR-shadow-plan-tables **§7 row 16** and **§8 obligation 1** require this row in the same atomic unit
as the engine that fills the table. Registered here on apply of `20260730234831`.

| metric                        | canonical object                        | grain       | written by                                                      | NOT to be confused with                                                                                           |
| ----------------------------- | --------------------------------------- | ----------- | --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| v3 proposed ADD plan (shadow) | **`public.pod_refills_shadow`**         | shelf × run | `public.engine_add_pod_v3` **only**                             | `public.pod_refills` = the **live v19 advisory plan**. Same grain, different engine, different truth status.      |
| v3 blocked demand (shadow)    | **`public.v_blocked_demand_shadow_v3`** | shelf × run | derived (view) from `pod_refills_shadow.reasoning->>'need_raw'` | `public.blocked_demand` / `v_blocked_demand_open` = the **live** ledger v19 writes via `record_blocked_demand_v3` |

**Scope every read by `run_id`.** `pod_refills_shadow` is append-only (`tg_pod_refills_shadow_append_only`
refuses UPDATE and DELETE), so the table accumulates one immutable block per run and
"latest row at this plan_date" is **not** a valid substitute for a run scope. Eight runs and 288 rows
existed within an hour of the engine landing, purely from two passes of the golden suite.

⚠️ **`availability_basis` is the SOURCING EDGE, not a free-text note** —
CHECK `IN ('boonz_wh','venue','partner','mixed','unknown')`, and `'boonz_wh'` additionally requires
`wh_available_pod IS NOT NULL`. It is the column that makes S-06 answerable at the row level: a
`venue` line with `qty = 0` and a `boonz_wh` line with `qty = 0` mean completely different things,
and only this column distinguishes them.

⚠️ **`mixed` is CONSTRAINED, and that is a live trap for any future assertion.** Of the 544 pod-bound
shelves, `venue` (75) is the only unconstrained class; `boonz_wh` and `mixed` both draw on real WH
stock. S-36's re-scoped fixture 105 seq 10 counts blocks where `sourcing <> 'boonz_wh'`, which
**includes `mixed`** — it reads 0 today only because both mixed shelves in that fixture's scope carry
`available_units = 362`. A mixed shelf that legitimately runs dry would red a correct engine, which is
S-36's own defect class recurring. Carried as **RISK 86**; the one-line fix if it ever fires is
`sourcing = 'venue'`.

📌 **`velocity_instock` in this table is written through verbatim and is still NULL.** It is NOT a
velocity source. See the D-10 entry above — reading it here is exactly the bypass that entry exists
to prevent.

## PRD-110 P2.2a — machine visit cadence + base-stock horizon (`v_machine_base_stock_policy_v3`)

| Metric                                     | Canonical object                 | Status                                                             | Replaces / disjoint from                                                                 |
| ------------------------------------------ | -------------------------------- | ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| Machine visit CADENCE + base-stock horizon | `v_machine_base_stock_policy_v3` | ✅ LIVE (2026-07-31, `prd110_p22a_v_machine_base_stock_policy_v3`) | New metric. Disjoint from "Days since visit" (a RECENCY) — see the vocabulary rule below |

**Why this is a new metric and not a re-derivation.** The registered visit clock
`v_machine_health_signals.days_since_visit` yields a **recency**, and a recency cannot produce
inter-visit **gaps**. Cadence therefore needs its own canonical object. What it may **not** do is
invent a second definition of "a visit".

⛔ **THE VOCABULARY RULE (Article 16, binding on every future consumer).** A visit is
`GREATEST(dispatch evidence, manual-refill evidence)`, exactly as the visit clock defines it:

- dispatch: `refill_dispatching`, `cancelled = false` **AND `skipped = false`** AND
  (`picked_up` OR `returned` OR `dispatched` OR `packed`);
- manual: `pod_inventory_audit_log.reference_id LIKE 'manual-refill-%' OR 'adjust-%'`, joined on
  **`pal.machine_id` DIRECTLY** — never through `pod_inventory` (fan-out, DO-NOT list).

Measured 2026-07-31: a **dispatch-only** derivation disagrees on **13 of 30** machines and
**always overstates** the gap (up to **1.60x**; VOXMCC-1011 reads 8 days instead of 5). An
overstated interval inflates the horizon, `fill_to_cap` absorbs it, and the engine degenerates to
always-max-fill **with no error, no qty-0 and no anomalous `clamp_reason`** — S-43's failure mode,
reintroduced quietly. Golden fixture 28 seq 17 is the standing regression guard on this.

**Three tiers, and the third is mandatory.** `interval_source` NAMES the tier that fired:
`observed` (>= `base_stock_min_gaps` measured gaps) -> `policy_seed` -> `param_default`.
`AMZ-1046-2406-O1` (16 pod-bound shelves) has **neither** a `machine_service_policy` row **nor** a
measurable cadence; two tiers starve it silently (LAW 5). `machine_service_policy` is **read-only**
here — CS-owned data (D-14).

---

## `v_pod_demand_dispersion_v3` - canonical dispersion (sigma) input to base stock

**Registered by leg 40** (object applied by leg 39, migration `20260731035112`).

**Grain:** one row per in-scope **canonical** (machine, pod) pair. Scope comes from
`v_shelf_state`, NOT from the sales table, so pairs with zero sales in the window are still
covered (52 measured 2026-07-31). 469 pairs across 31 machines.

**What it publishes:** the scale-free dispersion ratio `phi = sigma_obs / sqrt(mu_obs)`, never a
sigma. Consumers apply it to the canonical mu:

- `sigma_daily_pod   = phi * sqrt(velocity_instock_pod)`
- `sigma_daily_shelf = sigma_daily_pod * (velocity_instock_shelf / velocity_instock_pod)`

⛔ **WHY A RATIO AND NOT A SIGMA (this is S-13 in a new costume, do not "simplify" it).** A sigma
computed over _days with sales_ drops zero-demand days and counts stockout days as zero, while the
canonical mu (`velocity_instock`) is already in-stock-corrected. Publishing that sigma next to that
mu mixes two bases. `phi` is immune because numerator and denominator shift together.

**Named ladder, never NULL (LAW 5 / LAW 6).** `phi_source` is always one of `own` (>=
`base_stock_sigma_min_days` of history) -> `pod_prior` (pooled median phi for the canonical pod) ->
`fleet_prior` (fleet median) -> `floor_no_history` (degenerate backstop, which NAMES itself rather
than passing as a real estimate). Measured 2026-07-31: own **163** / pod_prior **198** /
fleet_prior **108**, a partition. The prior tiers are the **majority** path, exactly as S-44 said.

⚠️ **There is deliberately NO shelf-grain sigma object.** The view reads sales history only and
joins **neither** velocity object (RISK 88: an unbounded read of either can take the pooler down).
The shelf split belongs to `engine_add_pod_v3` at P2.2c, which already evaluates
`v_shelf_instock_velocity_split_v3` once. Do not go looking for a shelf-grain sigma view, and do not
add one.

⛔ **RISK 91 is baked in.** `delivery_status` is `'Successful'`, never `'Success'`, and it is the
only value across all 38,386 rows. The bare literal returns **zero rows silently**, which would make
sigma 0 fleet-wide and strip every shelf of safety stock with no error. The view accepts both
literals; **fixture 29 seq 14/15 is the tripwire** (correct filter non-vacuous, bare `'Success'`
still matching zero).

**Params (on `refill_policy_params`, CS-flippable without a migration):**
`base_stock_sigma_lookback_days` 60 · `base_stock_sigma_min_days` 14 ·
`base_stock_sigma_phi_floor` **0 (inert; 1.0 = Poisson floor, parked as D-15)** ·
`base_stock_sigma_prior_precedence` `pod_then_fleet` | `fleet_only`.

**Guard:** golden fixture 29, **18 assertions**, green since 2026-07-31 03:51Z.

## `v_pod_product_canonical_v3` - the pod-alias owner

**Registered by leg 40** (same migration). Canonical owner of the pod-product alias map
(Hunter -> Hunter Ridge). Join ANY raw `pod_product_id` through this to get the key the canonical
velocity objects use.

**Why it exists:** the map had **three inline copies and no owner** (S-38), which is precisely how
S-37 happened (a raw key joined against a canonical one). This object is **additive** - the existing
inline copies are untouched, and **fixture 29 seq 16/17** is the standing guard that they have not
diverged (exactly one non-identity row, and it is the Hunter pair).

### Amendment 2026-07-31 (PRD-110 leg 42) — `v_machine_base_stock_policy_v3` honours the D-14 carrier

The canonical object is unchanged in identity and remains the single source for machine visit cadence

- base-stock horizon. Its resolution now reads the v3 carrier first:

* `z = COALESCE(machine_service_policy.z_v3, .z_default, refill_policy_params.z_mid)`;
  `z_source` vocabulary widens to `machine_service_policy_v3 | machine_service_policy | param_z_mid`.
* the `policy_seed` tier sizes on `COALESCE(trip_interval_days_v3, trip_interval_days)`.
* `policy_trip_interval_days` **keeps its original meaning** — a passthrough of the RAW v19 seed. The
  override is exposed separately in the appended `policy_trip_interval_days_v3`, `z_v3`, `v3_source`.

⛔ **Consumers must read `z` and `horizon_days` from this view, never from `machine_service_policy`
directly.** The base columns belong to the live v19 engine and are deliberately left at their stale
2026-06-21 seed values (LAW 12). This applies to P2.2c engine wiring.

---

## PRD-110 P2.2c (2026-07-31, relay leg 44) — the base-stock sizing identity is WIRED

`engine_add_pod_v3` (`20260731061440`) now sizes on the BUILD SPEC P2.2 target rather than on a
caller-supplied cover window:

```
cover_units = ceil( mu * H  +  z * sigma_daily_shelf * sqrt(H) )
```

**Where every term comes from — all four are canonical reads, nothing is re-derived inline:**

| term                 | canonical source                                                  |
| -------------------- | ----------------------------------------------------------------- |
| `mu`                 | `v_shelf_instock_velocity_split_v3.velocity_instock_shelf` (P2.1) |
| `H` (`horizon_days`) | `v_machine_base_stock_policy_v3.horizon_days`                     |
| `z`                  | `v_machine_base_stock_policy_v3.z`                                |
| `phi`                | `v_pod_demand_dispersion_v3.phi`                                  |

⭐ **`sigma_daily_shelf` is derived IN THE ENGINE, and that is the registry's own instruction, not
an Article 16 lapse.** This file already states (see `v_pod_demand_dispersion_v3` above) that there
is deliberately NO shelf-grain sigma object and that "the shelf split belongs to `engine_add_pod_v3`
at P2.2c, which already evaluates `v_shelf_instock_velocity_split_v3` once". The engine implements
exactly the two published formulas, unmodified:

- `sigma_daily_pod   = phi * sqrt(velocity_instock_pod)`
- `sigma_daily_shelf = sigma_daily_pod * (velocity_instock_shelf / velocity_instock_pod)`

**Do not create a shelf-grain sigma view to "clean this up".** It would re-derive a metric two
canonical objects already own, and RISK 88 makes any object that joins a velocity object a pooler
hazard.

⛔ **`z` and `horizon_days` are read from the VIEW, never from `machine_service_policy`.** The base
columns are v19's and are deliberately stale (D-14 / D-16). This is not left to good intentions:
**fixture 14 seq 53** asserts that at least one line carries a `z` DIFFERING from that machine's
`z_default` — measured **16 lines** at apply. Reading the wrong column would collapse that to 0 and
red the fixture. seq 52 separately asserts the stamped `z`/`horizon_days` equal the view's, exactly.

**LAW 5 is enforced by the engine about its own output.** Every line names `horizon_source`
(`base_stock_policy_v3` | `days_cover_arg_fallback`) and `sigma_source`
(`phi_x_sqrt_velocity_instock_pod_split_by_shelf_share` | `no_dispersion_row` | `no_instock_split`),
and the function RAISES if any line carries an unrecognised value — a quantity may never move on an
unnamed horizon or an unnamed sigma. Fixture 14 seq 50/51 mirror both guards.

📌 **S-43's failure mode is now VISIBLE rather than inferable.** S-43 warned that an over-long
horizon makes `need_raw` saturate at `fill_to_cap` on every shelf, so v3 degenerates into "always max
fill" with no error, no qty-0 and no anomalous `clamp_reason`. The engine's return value now carries
`fill_to_cap_lines` and `fill_to_cap_share`, and **fixture 14 seq 56** reds if EVERY line clamps to
`fill_to_cap`. Measured fleet-wide at apply (read-only dry run over all 544 pod-bound shelves):
saturation **163 -> 206 of 450** shelves with capacity (36% -> 46%), planned units **1044 -> 1253**
(+20%), **0** machines lacking a policy row, 309 shelves up / 44 down / 191 unchanged. Well short of
degeneracy — S-43's fear is measured, not assumed.

---

## Demand multiplier / DOW seasonality profile (PRD-110 P2.4, leg 48)

| Metric                                                | Canonical object                                                                  | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ----------------------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Demand multiplier applied to a machine on a plan date | **`resolve_demand_multiplier_v3(machine_id, plan_date)`**                         | ✅ LIVE 2026-07-31 (empty calendar ⇒ 1.0). **First consumer wired 2026-07-31 leg 49: `engine_add_pod_v3` reads it once per picked machine and multiplies `vel_eff` by `factor`.** Consumer contract fixture-enforced (fixture 7, 24 assertions green): the factor scales `velocity_effective_daily` and `mu_term` on every line, the clamp reaches quantities, and an unfactored line records `1.0` with an empty source list. ⛔ No consumer may re-implement the resolution rule inline. |
| Fleet day-of-week seasonality profile                 | **`demand_calendar` rows where `source='dow'`**, written by `load_dow_profile_v3` | ✅ LIVE (loader built, not yet run)                                                                                                                                                                                                                                                                                                                                                                                                                                                        |

**Article 16:** no consumer may re-derive a demand factor inline. The engine reads the resolver;
nothing else multiplies velocity by a hand-rolled seasonality term. The loader itself reads
`v_sales_history_resolved` (canonical) rather than re-deriving sales from `sales_lines`.

⛔ **Do not confuse this with sourcing resolution.** `product_sourcing` resolves under the
**ANY-SCOPE** rule (S-53); `demand_calendar` resolves **most-specific-within-source**. Different
questions, deliberately opposite answers.

---

## v3-vs-v19 shadow diff (PRD-110 P2 / D-12, leg 51)

| Metric                                            | Canonical object                          | Status                                                                                                                                            |
| ------------------------------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| v3 vs v19 disagreement, line grain                | **`v_engine_diff_v3`**                    | ✅ LIVE 2026-07-31. One row per (plan_date, machine, shelf, pod_product) on either side; `diff_kind` ∈ match / qty_diff / v3_only / **v19_only**. |
| v3 vs v19 disagreement, per machine               | **`v_engine_diff_v3_by_machine`**         | ✅ LIVE 2026-07-31. Lines, units and **blocked** per machine — the per-machine dimension BUILD SPEC P2 names.                                     |
| The nightly shadow report (one row per plan_date) | **`v_engine_diff_v3_summary`**            | ✅ LIVE 2026-07-31. What the Phase-2 gate reads.                                                                                                  |
| Whether a shadow comparison happened at all       | **`v_engine_diff_v3_summary.is_vacuous`** | ✅ LIVE 2026-07-31.                                                                                                                               |

**Article 16:** no consumer may re-derive the diff. All three objects are views over
`pod_refills_shadow` (latest run per plan_date) and `pod_refills`; the rollups aggregate the line
grain rather than re-querying the base tables, and fixture 34 seq 37 / 43 pin that they do.

⛔ **`v_shadow_vs_live_plan_v3` is NOT this metric.** It reads the PLAN grain
(`pod_refill_plan_shadow`), which `engine_add_pod_v3` never writes, so it returns 0 rows on every
date until Phase-5 cutover. **Its zero is not parity.** Explicitly disjoint from the three objects
above; fixture 34 seq 60/61 pin the distinction.

⛔ **`is_vacuous` must be read before any delta is quoted.** A diff with an empty side reports zero
differences, which is indistinguishable from agreement unless the object says so. This is the
generalised form of the S-48 / S-52 non-vacuity discipline, moved out of the fixtures and into the
metric itself.

📌 **`v19_only` is the load-bearing bucket.** It counts lines v3 **drops** — the PRD-109 Extra Gum
class, where the fault is an ABSENCE. Any comparison that only walks the rows v3 produced is blind
to exactly the failure the shadow period exists to catch.

---

## `engine_forecast_error_v3` / `v_engine_wmape_v3` / `v_engine_wmape_v3_gate` — Phase-2 forecast accuracy (D-12)

**Canonical answer to: "is v3 forecasting better than v19?"** Nothing else may compute WMAPE.

| object                     | kind             | grain                                                 |
| -------------------------- | ---------------- | ----------------------------------------------------- |
| `engine_forecast_error_v3` | SNAPSHOT (table) | `(plan_date, engine_tag, machine_id, pod_product_id)` |
| `v_engine_wmape_v3`        | view             | `(plan_date, engine_tag)`                             |
| `v_engine_wmape_v3_gate`   | view             | `plan_date` — v19 vs v3 side by side                  |

Written per plan_date by `refresh_engine_forecast_error_v3(p_plan_date date)` (idempotent
DELETE+INSERT). Proven by **golden fixture 36** (31 assertions). Snapshot rather than view by
**ADR §10** — measured 13.5 s floor on the actuals scan, plus measurement provenance.

⛔ **EVERY READER MUST BRANCH ON `is_vacuous` BEFORE READING `wmape`.** This is not advisory. A
WMAPE of NULL means _nothing was measurable_, and the named `vacuous_reason` says which:

- `horizon_not_elapsed` — the forecast window has not finished; `actuals_settled = false`.
- `no_v3_measurement` — v19 has a score, v3 has never run on this date. **The gate returns
  `v3_meets_gate = NULL` here, never `true`.**

⭐ A score and an absence must never render the same. `wmape` is NULL, not 0.0, when there is nothing
to score — a 0.0 would read as a _perfect_ forecast, which is the exact opposite of the truth.
Same family as RISK 102 (`v_engine_diff_v3_summary.is_vacuous`): **a measurement object must be able
to say "I measured nothing" out loud.**

📌 `n_shelves > 1` on a snapshot row is normal and intended — the grain is machine × pod because
actuals resolve no finer, and 139 real groups span several shelves. Reading this table at shelf
grain double-counts sales; the PK prevents storing it that way.

**Baseline as at 2026-07-31:** the only real elapsed date measured is **2026-06-26** — v19,
141 settled series, WMAPE **0.7878**, bias **+0.3993**. ⛔ Not a fleet figure; one date, pending the
nightly shadow runner.

---

## `v_shadow_runner_health_v3` — canonical health of the nightly shadow runner (P2.7)

Columns: `log_rows`, `last_run_at`, `last_ok_at`, `gate0_nights` (14 d), `v3_measured_real_dates`,
`hours_since_last_run`, `is_healthy`, `is_measuring`, `verdict`. `security_invoker=true`, `anon`
holds nothing.

⭐ **It fires on ABSENCE, because that is how this component fails.** A dead schedule writes no bad
row — it writes _nothing at all_, so a detector that inspects rows sees a clean table and reports
health. `is_healthy` is therefore anchored on `log_rows > 0 AND last_run_at >= now() - 30 h`, and is
explicitly **FALSE, never NULL**, on an empty log (RISK 103). Same lesson as PRD-109's INV-10: the
absence _is_ the signal. Fixture 37 seq 17-19 prove it with the forced-rollback probe idiom.

⭐ **`is_healthy` and `is_measuring` are deliberately two columns.** A long `blocked_gate0` streak is
a runner that is alive and running nightly while producing **zero** measurements — sterile, not
broken. Collapsing them into one boolean would either cry wolf about a healthy schedule or hide a
fortnight of lost telemetry. Read `verdict` for which case you are in.

## Machine value at risk (PRD-110 P3.5, 2026-07-31, leg 58)

| Metric                                                  | Canonical object                          | Status                                                                                                     |
| ------------------------------------------------------- | ----------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Expected revenue lost if a machine is not visited today | **`rank_machines_by_value_at_risk_v3()`** | ✅ LIVE 2026-07-31, ADVISORY. Read-only (STABLE / SECURITY INVOKER). No consumer wired — CS still selects. |

⛔ **DISJOINT FROM `v_machine_priority.urgency` — and the distinction is the whole point of P3.5.**
They overlap in PURPOSE (both rank machines for a visit) and not at all in DEFINITION:

|         | `v_machine_priority.urgency`                                  | `rank_machines_by_value_at_risk_v3`     |
| ------- | ------------------------------------------------------------- | --------------------------------------- |
| unit    | dimensionless score                                           | **AED**                                 |
| terms   | empty · low-fill · runout · capacity · expiry · stale · holes | expected lost revenue, and nothing else |
| revenue | **none, at any point**                                        | the only term                           |
| status  | canonical since PRD-063/074, drives Gate 0 today              | advisory, drives nothing yet            |

⭐ Two machines one day from a stockout score identically under `urgency` whether the shelf about
to empty earns 40 AED a day or 0.40. That gap is what this metric fills. ⛔ Neither object may
absorb the other's terms: an `urgency` that grew a revenue term, or a VAR that grew a hole term,
would recreate the two-competing-priorities problem PRD-074 closed. If they are ever to be
combined, the combination is a THIRD registered object reading both — not an edit to either.

⭐ **This object RE-DERIVES NOTHING.** mu ← `v_shelf_instock_velocity_split_v3` · demand factor ←
`resolve_demand_multiplier_v3` · cadence ← `v_machine_base_stock_policy_v3` · visit clock ←
`v_machine_health_signals.days_since_visit` (line 49) · stock/capacity ← `v_shelf_state` ·
machine scope + `r_cluster` ← `v_machine_priority`.

📌 **Provenance correction worth reading, because it is the failure mode Article 16 exists for.**
As first applied (`20260731143736`) it read `days_since_visit` from `v_machine_priority` — which
is listed on line 49 as a _consumer_ of the visit clock, not its owner. The numbers were identical
(31 machines, **0 disagreements**), so nothing was wrong and nothing would have gone wrong for a
long time. ⛔ That is exactly the danger: a copy that agrees is indistinguishable from the original
right up until the day it does not, and by then nobody remembers which of the three copies the
picker read. Corrected at `20260731145040` and pinned by fixture 42 seq 54, with seq 55 forcing
every output row to NAME the object it read in `reasoning.visit_clock_source`.

⚠️ **A zero here means one of two very different things, so read the coverage counters with it.**
`value_at_risk_aed = 0` is either "nothing at risk" or "cannot see" — five AMZ machines score 0.00
with 24 of 40 shelves carrying no velocity and no price. The object reports the distinction
(`no_velocity_shelves`, `no_price_basis_shelves`, `at_risk_but_unpriceable`) but does NOT
compensate for it in the ranking, so blind machines sink to the bottom as though they were safe.
Fixture 42 seq 52 keeps that sensor honest. Closing the gap is CS decision **D-25** (S-71).

## `rotation_fit_score` — canonical object: `public.propose_rotations_v3` (PRD-110 P3.3, leg 59)

**Definition.** Dimensionless. How much faster a pod product moves at a candidate destination
shelf than at the source shelf it is stranded on:
`target_velocity / GREATEST(source_velocity, rot_slow_velocity_per_day/10)`.
Companion measure `projected_days_to_sell = proposed_qty / target_velocity` — days for the moved
units to clear **at the destination**.

**Disjoint from every existing metric, declared under Article 16.** It is not
`v_machine_priority.urgency` (dimensionless shelf-state composite, machine grain, no velocity
ratio), and it is not `rank_machines_by_value_at_risk_v3.value_at_risk_aed` (AED, machine grain,
a money term). `rotation_fit_score` is a **ratio at shelf-pair grain**. The three are not
comparable and must never be summed, averaged together, or substituted for one another.

**Provenance, pinned by fixture 43 seq 36.** Velocity is read from
`v_shelf_instock_velocity_split_v3`, the canonical owner, and every emitted row NAMES that object
in `scoring_breakdown.velocity_source`.
⛔ **NEVER read velocity from `v_shelf_state.velocity_instock`** — it is still literally
`NULL::numeric -- P2.1` on all 656 shelves even though P2.1 is closed, and the view comment
("NULL until P2.1") now reads as a promise that was kept elsewhere. A consumer that trusted it
would silently disqualify the entire fleet and return an empty set that looked like a verdict of
"no rotations needed". **S-73.**

⚠️ **The thresholds are POLICY, not measurement.** All five `rot_*` params are judgment calls
about what "too slow" and "worth a van leg" mean; every emitted row repeats this in
`scoring_breakdown.threshold_basis`, and fixture 43 seq 38 fails if it stops doing so.

⚠️ **The expiry horizon is measured from `CURRENT_DATE`, never from `p_plan_date`** — S-75. Judged
from a synthetic 2030 plan_date the guard does not error, it stops binding: it admitted 52 of 802
candidate pairs (exactly those whose expiry was _unknown_) and blocked nothing real. From the real
world it admits 765 and blocks 37 that genuinely cannot clear before expiring. Fixture 43 seq 19
is a sensor **for** that sensor and fails if the blocked set ever empties.

## PRD-110 P3.1c (2026-07-31, relay leg 65) — a PINNED Article 16 mirror, and why it is tolerated

`list_m2m_donors_v3` reads velocity as `COALESCE(v_shelf_state.velocity_instock, velocity_raw, 0)`
and applies the overstock rule `current_stock > GREATEST(velocity*7, 5)`. That is **not** the
registered canonical in-stock-velocity object (`v_shelf_instock_velocity_split_v3`, row above), and
per **S-73** `v_shelf_state.velocity_instock` is NULL on all 656 shelves — so in practice this runs
on `velocity_raw`, which this registry already flags as **(machine, pod) grain replicated across
that pod's shelves**.

⛔ **This is pre-existing debt inside `resolve_supply_ladder_v3` rung 4, not a new definition.** The
new function replicates the predicate **byte-for-byte and deliberately**, because parity with the
ladder is the entire point: the ladder counts donors, the function names them, and if the two rules
diverge the engine would block against donors it cannot draw from.

**Cody permitted the mirror on one binding condition: it must be PINNED.** Golden fixture 45
assertions 4 and 5 assert that `list_m2m_donors_v3` and the ladder's own rung-4 log agree on both
the donor **machine count** and the **total excess**. Any future edit to either rule turns the
fixture red instead of letting the two drift apart silently.

⏸️ **D-27 (OPEN, CS/Cody):** converge rung 4's velocity onto the canonical in-stock object. Doing it
changes which machines qualify as donors on a live engine path, so it is its own reviewed unit with
its own before/after diff — ⛔ never a drive-by inside an unrelated migration. Until then the mirror
stands, pinned.

## PRD-110 P3.4 (2026-07-31, relay leg 68) - revenue per facing per day

| Metric                                                                 | Canonical object          | Status                                                                                                                                                                     | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ---------------------------------------------------------------------- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Revenue per facing per day (per machine, per canonical product family) | `v_facing_performance_v3` | 🟢 **CANONICAL from 2026-07-31 leg 68** (`prd110_p34_v_facing_performance_v3`, `20260731194721`). No consumer yet: the P3.4 proposer that reads it is staged, not applied. | Grain = `(machine_id, canonical pod_product_id)`, 525 rows at apply. **Article 16 shaped this object twice over.** (1) Identity, `facings`, `stock`, `cap` and the CALENDAR velocity (`dvel`) are read from **`v_shelf_sales_identity`**, the canonical alias owner, NOT recomputed — the registry's own instruction on that row ("any future per-product velocity read must use this object"). ⛔ The obvious alternative — grouping `v_shelf_instock_velocity_split_v3` by its emitted `pod_product_id` — is WRONG: that view canonicalises the Hunter/Hunter Ridge alias internally (S-37) but emits the RAW pod key per shelf while `pod_shelf_count`/`velocity_*_pod` are FAMILY-level, so one 2-lane family becomes two rows that each claim `facings=2` and the full family velocity. Measured live before the object was written. (2) Only the IN-STOCK rate comes from `v_shelf_instock_velocity_split_v3` (🟢 canonical). ⛔ **TWO velocities are published and neither is "the" velocity:** `rev_per_facing_day_realized` (calendar rate — what the lane earned) and `rev_per_facing_day_potential` (in-stock rate — what it earns while stocked). The in-stock rate is the **same class of quantity as PRD-108's ppad trap**: measured across 456 live families it is ≥ the calendar rate on every one (min 1.006, mean 1.121x, **max 14.003x**, 20 families >50% over). `starvation_ratio` is their quotient and is the only admissible evidence for ADDING a facing. ⚠️ **Article 16 DEBT, recorded deliberately (D-31):** the three-tier price cascade (realized machine-pod → realized fleet-pod → `recommended_selling_price`) is a SECOND inline copy of the one `rank_machines_by_value_at_risk_v3` owns. Copied verbatim so the two cannot disagree about unit value (S-94); convergence is the open ask. ⚠️ **PERF IS A CONSUMER CONSTRAINT:** inherits ~20 s from the split view and machine-scoping does NOT reduce it (S-26 / RISK 88) — read ONCE into a temp table and join. A consumer that evaluated it seven times stalled the database for ~3 minutes (S-98). Coverage stated, not implied: 454/525 in the refill universe, 428 priced-and-measured, 71 with no in-stock coverage (LEFT JOINed and flagged, never dropped — S-71), 0 `facing_count_disagreement`. |

## PRD-110 S-112 (2026-07-31, relay leg 72) - the refill planning calendar

| Metric                                 | Canonical object                  | Status                                                                                                                                                                                                                        | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| -------------------------------------- | --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Is a given date a refill PLANNING day? | `is_refill_planning_day_v3(date)` | 🟢 **CANONICAL from 2026-07-31 leg 72** (`prd110_s112_runner_truthful_skip`, `20260731220053`), **AND CANONICAL BY ADOPTION from 2026-08-03 leg 95** (`prd110_p03_stage1_d35_collapse_saturday_to_helper`, `20260803183540`). | Read-only, `IMMUTABLE`, SECURITY INVOKER (Cody class (c): DEFINER was not justified, so the safer default stands). Encodes PRD-035 WS-E: **Saturday (DOW 6) is a delivery day and is never planned.** ⛔ **This is NOT `resolve_refill_plan_date()`** and must never be confused with it — that object answers _which_ date to plan (it flips at 18:00 Dubai), this one answers _whether_ a date is plannable at all. ✅ **THE ARTICLE 16 DEBT IS PAID (D-35 executed, leg 95).** `_build_draft_core_v3` carried the same rule inline as a bare `EXTRACT(DOW FROM p_plan_date) = 6`; CS answered COLLAPSE and leg 95 substituted it for `NOT public.is_refill_planning_day_v3(p_plan_date)`. Verified by direct query: `helper_calls`=1, `EXTRACT(DOW FROM p_plan_date)` occurrences=**0**, `skipped_saturday` branch intact, `md5(prosrc)` `f69dd070`→`fef941d5`, and signature / `pronargdefaults`=0 / `prosecdef` / both pinned GUCs / the whole ACL string all byte-identical. **Consumers are now `run_nightly_shadow_v3` and `_build_draft_core_v3` (Stage 1, behind cron 13); both ask the name and neither re-derives the number.** ⛔ **The collapse is semantics-preserving ONLY because of what sits above it:** the helper's guard set is strictly LARGER (`p IS NOT NULL AND …`), so on a NULL date the inline rule declines the branch while `NOT helper(NULL)` takes it. It is safe at this site, and only at this site, because `IF p_plan_date IS NULL THEN RAISE` executes three lines earlier — the migration asserts that ordering positionally and REFUSES rather than assuming it. ⭐ Pinned by golden fixture **61** (13 assertions), which compares Stage 1's Saturday exit against the helper across **seven consecutive days** and requires exactly one skip, on the Saturday, with zero disagreements — agreement alone is fakeable by a helper stuck at TRUE, so the spread is what makes seq 7 mean something. Golden fixture **53** seq 4/5/8 (unchanged, re-run 22/22 green after the collapse) remains the consumer-side pin that Stage 1 really answers `skipped_saturday`. ⭐ **Why the rule needed a name at all:** cron 45's first-ever fire (2026-07-31 21:22Z) was logged `status='error'` because Saturday 2026-08-01 had no picked machines. Distinguishing "we never plan Saturdays" from "nobody picked" and from "the engine broke" is impossible without the calendar, and copying `EXTRACT(DOW)=6` into the runner would have made a second source of truth for a business rule. Pinned by golden fixture **53** seq 4/5/8, which asserts the fixture date really is a Saturday, the day before it really is a Friday, and Stage 1 really answers `skipped_saturday`. |

## PRD-110 P4.2 (2026-08-01, relay leg 79) - the active planning pin

| Metric                                                                    | Canonical object            | Status                                                                                                                                              | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------------------------------------------- | --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Is a planning pin currently in force? (machine × shelf? × product × kind) | `v_planning_pins_active_v3` | 🟡 **CANONICAL from 2026-08-01 leg 79** (`prd110_p4_1_feedback_ledger_pins`, `20260801005744`) — canonical by declaration, **not yet by adoption**. | `security_invoker = true`. **"Active" has exactly one definition and it lives here: `revoked_at IS NULL` AND (`expires_at IS NULL` OR `expires_at > now()`).** ⛔ **Engines and L0 read this view; never `planning_pins_v3` directly** — the base table deliberately retains revoked and expired rows forever, because revocation is a SUPERSEDE and the fixture-16 provenance chain depends on that history surviving. A consumer that read the base table would honour dead pins. ⭐ **The two-part definition is also why the schema needed a system-expiry actor:** `ux_pin_v3_active_one_per_kind` is a partial index and **cannot test the expiry half** (index predicates must be IMMUTABLE; `now()` is not), so expiry has to be materialised into `revoked_at` before the uniqueness slot frees. The view is the only place the full rule is stated. ⚠️ **No consumer yet** — the P4.1 verbs and the L0 constraint read land in a later unit; fixture 55 seq 10–16 pins the view's behaviour (active shown, revoked hidden, expired hidden, `days_remaining` NULL for perpetual) so a future consumer cannot quietly redefine it. |

---

### ⛔ Article 16 CARVE-OUT (2026-08-01 leg 80) — `planning_pins_v3` has TWO legitimate readings, and only one of them is the metric

`v_planning_pins_active_v3` remains the canonical answer to **"is a planning pin currently in
force?"** — `revoked_at IS NULL` **AND** (`expires_at IS NULL` OR `expires_at > now()`). Engines and
L0 read the view. That is unchanged.

⛔ **But `approve_feedback_proposal_v3` reads the BASE TABLE, on purpose, and that is not a
violation.** It is not asking whether a pin is in force. It is asking **which row occupies the
uniqueness slot**, and the slot is defined by the partial indexes `ux_pin_v3_active_one_per_kind` and
`ux_pin_v3_stock_policy_exclusive`, whose predicate is **`revoked_at IS NULL` alone**. Index
predicates must be IMMUTABLE and `now()` is not, so — as this registry's own entry for the view
already notes — the index **cannot** test the expiry half.

**The failure mode if someone "corrects" this to read the view:** an expired-but-unrevoked
`never_stock` pin is invisible in the view and still holds the slot. The contradiction guard would
pass, the INSERT would reach the index, and CS would get a bare `23505` instead of the sentence
naming the conflicting pin.

⭐ **The general rule this is an instance of: a guard must be expressed over the same predicate as the
constraint it is protecting.** A guard that is merely _related_ to the constraint is a guard that
disagrees with it at exactly the inputs nobody tested. Two questions that sound alike —
"in force?" and "occupies the slot?" — are different questions, and Article 16 governs the first only.

**Consumers of the base table are therefore an allow-list, not a free-for-all:**
`approve_feedback_proposal_v3` (slot check) and `propose_pin_from_feedback_v3` (contradiction flag).
Any other reader wanting "in force" must use the view.

---

### `v_pick_decision_cohorts_v3` — WHY CS's final selection differs from the cron pick (2026-08-01 leg 86, PRD-110 P4.3b)

**Canonical object:** `public.v_pick_decision_cohorts_v3`. **Base tables:** `machines_to_visit` ONLY.
**Grain:** one row per `plan_date`. **Consumers:** `mine_pick_history_v3` (P4.3b), the G12
acceptance-rate telemetry, the P4.5 scoreboard, and — when built — the charter's Gate 0
"CS would likely add/drop" hint.

**The metric:** `cohort ∈ no_drops | day_cancelled | cluster_scope | mixed_capacity`, and the
derived `is_learnable` = `mixed_capacity` only.

⛔ **Why this is a registered metric and not a CTE inside the miner.** 241 live CS drops, and their
reasons are overwhelmingly ROUTE OR DAY SCOPE rather than per-machine judgment: _"cancel entire
5-Jun plan"_ ×25, _"CS route scope: focus on 6-machine route"_ ×22, _"CS shortlist"_ ×21,
_"AMZ-only route today"_, _"VOX track dropped for 29 Jul"_. **A learner that treats every drop as
"the picker over-ranked this machine" learns to down-weight VOX machines because VOX days are
episodic.** Only days where CS kept a top-K spread across MORE THAN ONE route cluster carry
information about machine RANK. Live at registration: `mixed_capacity` 24 days / 188 drops / 241
kept · `cluster_scope` 7 days / 53 drops · `no_drops` 39 days · `day_cancelled` 0 days.

### ⛔ Article 16 CARVE-OUT (leg 86) — the miner reads the base table for FEATURES, and that is not a violation

`mine_pick_history_v3` MUST source its `is_learnable` plan_date set from the view and MUST NOT
re-derive the cohort predicate. It ALSO reads `machines_to_visit` directly for the pairwise
**feature values** (`empty_shelves_count`, `fill_pct`, …) of the kept-vs-dropped comparisons.
**That is a different question from the cohort classification** and is permitted, scoped to
plan_dates the view has already classified.

⭐ This is the leg-80 carve-out's mirror image, recorded BEFORE the function exists rather than
after a reviewer flags it: _"which days were CS genuinely choosing between?"_ is the registered
metric; _"what were this machine's feature values that day?"_ is a base-table read that no view
owns. Stating it in advance is the cheap half of the lesson leg 85 paid for.

**Base-table allow-list for the cohort question:** empty. Every consumer reads the view.

⭐ **The headline diagnostic lives here too, and it is a FINDING, not a proposal.**
`score_concordance_pct` fleet-wide across the learnable days = **50.03%** over 1653 pairs. The
picker's own composite `priority_score` is a **coin flip** against CS's keep/drop decision. It is
NULL — never 50-by-default — when every pair ties, because unmeasurable is not neutral.

## PRD-110 P4.3 (2026-08-01, relay leg 88) - proposal acceptance rate (G12)

| Metric                                                          | Canonical object           | Status                                                                                                                         |
| --------------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Share of a proposal family's DECIDED proposals that CS accepted | `v_proposal_acceptance_v3` | 🟡 **CANONICAL from 2026-08-01 leg 88** (`prd110_p43c_g12_acceptance_telemetry`, `20260801042730`) - canonical by declaration. |

`security_invoker = true`, `authenticated=r`. Verdict logic lives in the `IMMUTABLE`
`g12_verdict_v3(accepted, decided, min_decided, bar)` helper so every branch is testable without
planting a row; the view calls the same helper it is tested through, so the two cannot drift.
Article 16 conflict check was RUN, not assumed: `~* 'accept(ance)?_(rate|pct)'` over every `pg_proc`
body and view definition returned **zero** hits, so no inline copy is being blessed.

⛔ **THE DEFINITION, because "acceptance rate" could mean four different things.** Denominator is
**decided = accepted + rejected** only.

| status                  | bucket     | in denominator? | why                                                           |
| ----------------------- | ---------- | --------------- | ------------------------------------------------------------- |
| `approved`, `applied`   | accepted   | yes             | `applied` is approved-and-acted, not a fourth state           |
| `rejected`              | rejected   | yes             | the only negative CS judgement                                |
| `pending`, `proposed`   | undecided  | no              | CS has not ruled yet                                          |
| `unclaimed`             | unmatched  | no              | a reallocation offer that found no target was never put to CS |
| `superseded`, `expired` | withdrawn  | no              | left the queue WITHOUT a judgement                            |
| anything else           | `unmapped` | no              | published, never silently dropped                             |

⭐ **`withdrawn` is the load-bearing distinction.** Counting a superseded proposal as a rejection
punishes the miner for CS's latency; counting it as an acceptance overstates. It is a third thing.

⛔ **ZERO EVIDENCE IS NOT A FAILING GRADE.** `decided = 0` yields `live_acceptance_pct = NULL` and
`live_verdict = 'insufficient_evidence'`, never `0.00` / `'fail'`. G12's bar is "≥60% or the miner is
noise"; rendering an unreviewed queue as 0% would retire a working miner on no evidence. A fourth
verdict, `incoherent`, reports impossible inputs (`accepted > decided`) rather than raising - S-137,
a correct invariant that throws inside a view is a crash path for every consumer.

⭐ **LIVE AND FIXTURE POPULATIONS ARE PUBLISHED SIDE BY SIDE AND NEVER COLLAPSED (S-139).** Rows
dated `>= g12_fixture_epoch` (2030-01-01) are the harness's synthetic universe. This is not
decoration: **at apply, all 82 proposal rows fleet-wide were fixture residue**, and a naive view
would have headlined _"feedback pins: 75% acceptance"_ over four fixture rows. That 75.00 is real -
it is pinned by fixture 59 seq 8 - and it sits in `fixture_acceptance_pct` where it belongs, while
`live_verdict` correctly reads `insufficient_evidence`.
⚠️ **HORIZON:** `g12_fixture_epoch` is a real date only ~4 years out. Revisit well before 2030 or
live proposals begin classifying as fixture rows.

⭐ **Always exactly five rows.** `fam` is a `VALUES` list LEFT JOINed to the data, so an empty queue
renders as zero-proposals-ever instead of vanishing - an absence that looks like a non-existence is
the INV-10 / S-132 failure mode. `in_g12_scope` is true only for the two miner-fed queues
(`feedback_pins`, `picker_weights`); `rotation` / `facing` / `reallocation` are P3 proposers and are
reported, not graded, because an acceptance rate over a mixed population is a number about nothing.
`bucket_sum_ok` is the object's own miscount detector.

**Consumers:** none yet. Pinned by golden fixture **59 (50/50)**.

## PRD-110 P4.3d (2026-08-01, relay leg 89) - Article 16 check run, NO new metric registered

`miner_runs_v3` and `run_weekly_miners_v3` add **no** registered business metric, and the conflict
check against this file was run and came back empty. Recorded here so a later leg does not re-open
the question: a miner run is an **event**, not a measurement, and registering an append-only log as a
"canonical metric object" would blur what Article 16 protects.

⭐ **It is still the single source for one question** - _"what did the weekly miners find?"_ - and any
future board, digest or Remy pack must read `miner_runs_v3` rather than re-invoke a miner to find
out. Re-invoking would answer a **different** question (today's data, not the scheduled run's), and
in live mode it would also mint.

⛔ **Read boards with `WHERE invoked_by = 'cron'`.** Golden fixture 60 leaves 2 permanent rows per
run stamped `invoked_by = 'fixture'` - it cannot clean up after itself, because refusing DELETE is
the property it exists to prove.

---

## PRD-110 P4.2 / D-38 (2026-08-03, relay leg 96) — the pin floor ON AN EDIT LINE is a PROVENANCE read (Cody R3)

⛔ **This row exists to stop a future leg from "converging" `record_plan_edit_v3` onto
`v_planning_pins_active_v3`.** The pins view is and remains the canonical answer to _"is a pin
currently in force?"_ — engines and L0 read it and nothing else. But `record_plan_edit_v3` asks a
**different question**: _"what floor did the engine apply to the line this human was reacting to?"_

That number is **not** re-derivable from the pins view without re-implementing the ladder, because
`protect_depth` resolves as `GREATEST(value − stock_clamped, 0)` against engine-internal clamped
stock, `min_facing` as `value`, `always_stock` as `1`, MAXed across pins and joined pod↔boonz through
Active `product_mapping`. `engine_add_pod_v3` already publishes the result on **every** shadow line as
`reasoning->>'pin_floor_units'` (0 explicitly when unpinned, LAW 5), and `record_plan_edit_v3` already
resolves that exact base row to compute `base_qty_at_edit`.

⭐ **So the edit path READS the engine's recorded output. That is the Article 16-compliant choice, not
an exception to it** — the alternative is a second copy of the pin ladder in a second function, which
is precisely the duplication D-35 retired one migration earlier and the guard-set divergence S-165
warns about. **Consumer contract, pinned by golden fixture 62 seq 7 and seq 10:** the flagged line
carries the floor the engine recorded (6), and an unpinned line records **0, never NULL**.
⚠️ `pin_floor_at_edit` is NULL only when there was no engine line to contradict at all — never
conflate that with 0, and never with `pin_contradiction IS NULL` (which means "row predates D-38").

---

## PRD-110 P4.5 scoreboard — nine registered metrics (leg 101)

| Metric                       | Canonical object                                   | Grain / definition                                                                                   | Upstream canonical object it consumes        |
| ---------------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| On-shelf availability (A)    | `v_scoreboard_daily_v3.osa_a_shelves`              | **Slot**-grain: share of A-aisle slots with `current_stock > 0`, latest snapshot per slot per day    | `v_weimi_shelf_history_v3`                   |
| Stockout rate                | `v_scoreboard_daily_v3.stockout_rate`              | **Machine**-grain incidence: share of observed machines with ≥1 empty A slot                         | `v_weimi_shelf_history_v3`                   |
| Waste %                      | `v_scoreboard_daily_v3.waste_pct`                  | write-off units ÷ all units that left the shelf that day                                             | `inventory_events`                           |
| WMAPE (per engine)           | `v_scoreboard_daily_v3.wmape_v3` / `.wmape_v19`    | pass-through, including the source view's own vacuity                                                | `v_engine_wmape_v3`                          |
| Plan adherence               | `v_scoreboard_daily_v3.plan_adherence`             | dispatched units ÷ intended units for that `plan_date`                                               | `v_refill_accuracy`                          |
| Revenue per machine per day  | `v_scoreboard_daily_v3.revenue_per_machine_day`    | net revenue ÷ refill-eligible active machines (AED)                                                  | `sales_history_aggregated`, `v_active_fleet` |
| Blocked aging                | `v_scoreboard_daily_v3.blocked_aging_days`         | mean age of rows OPEN **as at** that date (`resolved_at IS NULL OR resolved_at > date`)              | `blocked_demand`                             |
| Expired-sold incidents       | `v_scoreboard_daily_v3.expired_sold_incidents`     | count of `kind='expired_sold_incident'` events that day; a **count**, so 0 is real and never vacuous | `inventory_events`                           |
| Composition confidence (avg) | `v_scoreboard_daily_v3.composition_confidence_avg` | mean estimator confidence, **as at compute time**                                                    | `shelf_composition`                          |

⛔ **`osa_a_shelves` and `stockout_rate` are deliberately measured over DIFFERENT populations.** Had
both been slot-grain, the second would be `1 − ` the first and the pair would carry one metric's worth
of information while presenting as two. Fixture 65 seq 25 pins the denominators as unequal so a later
"simplification" cannot quietly collapse them.

⚠️ **`composition_confidence_avg` is as-at-compute-time, not as-at-`metric_date`.** `shelf_composition`
keeps no history, so the value is only honest for the day just ended and the day in progress; for
anything older the writer **refuses** (`vacuous_reason = 'composition_is_present_tense_only'`) rather
than back-stamping today's confidence onto last week. Giving this metric real history means giving
`shelf_composition` history, which is its own unit.

⭐ **THE VACUITY DISCIPLINE IS PART OF THE CONTRACT, not an implementation detail.** Every row is
EITHER a real value (`is_vacuous = false`, `metric_value NOT NULL`) OR an explicit, reasoned refusal
(`is_vacuous = true`, `metric_value NULL`, `vacuous_reason NOT NULL`), enforced by
`ck_scoreboard_vacuity`. **A consumer that treats a NULL metric as 0 is reading the scoreboard wrong.**
Every row also records `source_object`, so an auditor can confirm no metric was re-derived locally
(Article 16) without reading the function body.
