# Changelog

One line per migration, oldest first. Started per PRD-124 #13 / ONE-LOOP Phase 7 item 9.

## 2026-09-12

- `20260912000100_prd121_p0_1a_refill_plan_gate_waivers_table.sql` -- `refill_plan_gate_waivers` table, PRD-121 P0.1a.
- `20260912000200_prd121_p0_1b_approve_refill_plan_validates.sql` -- `approve_refill_plan` calls `validate_refill_plan` and honors `p_waive`, PRD-121 P0.1b.
- `20260912000300_prd121_p0_drop_dead_repair_orphan_overload.sql` -- dropped a dead overload of `repair_orphan_internal_transfer`.
- `20260912000400_prd121_p0_3_find_unstarted_dispatch_conflict.sql` -- PRD-121 P0.3 conflict check.
- `20260912000500_prd121_p0_4_edit_dispatch_product_resolve_expiry.sql` -- PRD-121 P0.4 expiry resolution on product edit.
- `20260912000600_prd121_p1_1a_validate_refill_plan_source_param.sql` -- `validate_refill_plan` gains `p_source` ('dispatch'/'plan_output').
- `20260912000700_prd121_p1_1b_write_refill_plan_early_warning.sql` -- early warning in `write_refill_plan`.
- `20260912000800_prd121_p1_2_wire_bind_dispatch_fefo.sql` -- wired `bind_dispatch_fefo` into the push path.

## 2026-09-13

- `20260913000100_prd121_p0_2_insert_driver_remove_line_m2m_pairs.sql` -- M2M pairing in `insert_driver_remove_line`.
- `20260913000200_prd121_phase2_p1_3_substitution_shortfall.sql` -- substitution shortfall handling.
- `20260913000300_prd121_phase2_p1_5_mandatory_return_reason.sql` -- mandatory return reason, PRD-121 P1.5.
- `20260913000400_prd121_phase2_cleanup1_bad_product_name_conventions.sql` -- product name convention cleanup.
- `20260913000500_prd121_phase2_p1_4_approve_mid_pack_warning.sql` -- mid-pack warning on approve, PRD-121 P1.4.
- `20260913000600_prd121_phase2_cleanup3_alert_dedup.sql` -- alert dedup cleanup.
- `20260913010100_prd122_ga_batch_id_vocabulary_guard.sql` -- PRD-122 GA batch_id vocabulary guard.
- `20260913010200_prd122_gb_is_test_column_and_guard_ddl.sql` -- `is_test` column + guard DDL.
- `20260913010300_prd122_gb_is_test_backfill_data.sql` -- `is_test` backfill.
- `20260913010400_prd122_gc_expiry_sanity_guard.sql` -- expiry sanity guard.
- `20260913010500_prd122_gd_receipt_unmapped_alert.sql` -- unmapped receipt alert.
- `20260913010600_prd122_ge_dispose_warehouse_return.sql` -- warehouse return disposal.
- `20260913010700_prd122_gf_sweep_warehouse_hygiene.sql` -- warehouse hygiene sweep.
- `20260913020100_prd122_cl1_apply_warehouse_audit.sql` -- `apply_warehouse_audit`, PRD-122 CL-1.
- `20260913020200_prd122_cl2_purge_warehouse_ghosts.sql` -- `purge_warehouse_ghosts`, PRD-122 CL-2.
- `20260913020300_prd122_cl3_purge_test_inventory.sql` -- `purge_test_inventory`, PRD-122 CL-3.

## 2026-09-14

- `20260914000100_prd122lgp_t1_v_lane_grain_and_params.sql` -- `v_lane_grain` view + lane-grain params, PRD-122 lane-grain-priority T1.
- `20260914000200_prd122lgp_t2_v_machine_priority_lane_signals.sql` -- `v_machine_priority` lane-grain signals, T2.
- `20260914000300_prd122lgp_t3_t3b_pscore_formula_and_consistency_realign.sql` -- p_score weighted-sum formula, drift-check realignment, T3+T3b.
- `20260914000400_prd122lgp_t4_pick_machines_for_refill_svc_track.sql` -- `pick_machines_for_refill` keys off `svc_track`, T4.
- `20260914000500_prd122lgp_t5_service_model_svc_track.sql` -- `machines.service_model` + real `svc_track` fix, T5.
- `20260914000600_prd122lgp_t6_get_machine_health_expose_lane_signals.sql` -- `get_machine_health` exposes lane-grain signals, T6 backend.

## 2026-09-15 -- ONE LOOP overnight (this session)

- `20260915000100_prd12x_p1_weimi_shelf_truth_push_plan_remove_path.sql` -- `push_plan_to_dispatch` Remove path: shelf is the plan's shelf, never the lot's. PRD-125 D2, Phase 1.
- `20260915000200_prd12x_p1_weimi_shelf_now.sql` -- `weimi_shelf_now(machine_id)`, the new canonical shelf read.
- `20260915000300_prd12x_p1_weimi_shelf_truth_add_dispatch_row.sql` -- same Remove-path fix in `add_dispatch_row`.
- `20260915000400_prd12x_p1_align_pod_lots_to_weimi.sql` -- `align_pod_lots_to_weimi`, nightly cron at 22:00 UTC.
- `20260915000500_prd12x_p2_wh_available_for.sql` -- `wh_available_for(machine_id, boonz_product_id)`, PRD-125 D3, Phase 2.
- `20260915000600_prd12x_p2_callers_and_source_kind.sql` -- `engine_add_pod` / `find_substitutes_for_shelf` switched to `wh_available_for`; `source_kind` mapped at push; two CHECK constraints extended for `'venue'`.
- `20260915000700_prd12x_p2_push_plan_source_kind.sql` -- `push_plan_to_dispatch` sets `source_kind` on every path (PRD-124 #38).
- `20260915000800_prd12x_p3_validate_refill_plan_five_gates.sql` -- `validate_refill_plan` rewritten to G3/G5/G7/G8/G10, none waivable. PRD-125 D1/D6, Phase 3.
- `20260915000900_prd12x_p3_approve_refill_plan_no_waive.sql` -- `approve_refill_plan` no longer honors `p_waive`.
- `20260915001000_prd12x_p4_substitution_rules.sql` -- `substitution_rules` table, seeded. PRD-125 D4, Phase 4.
- `20260915001100_prd12x_p4_find_substitutes_rule_driven.sql` -- `find_substitutes_for_shelf` reads the rules table, rule-first.
- `20260915001200_prd12x_p5_picker_brain_params_and_score.sql` -- `v_machine_priority` gains AED-denominated scoring columns. PRD-126 R1-R4, Phase 5.
- `20260915001300_prd12x_p6_confirm_and_build.sql` -- `confirm_and_build`, `approve_pod_refill_plan` runs stitch+push, cron 13 alerts on no confirm. Replaces PRD-125 D5, Phase 6.
- `20260915001400_prd12x_p7_mark_dispatched.sql` -- `mark_dispatched(dispatch_ids)`. PRD-124 #35, Phase 7.

## 2026-09-15 (continued) -- ONE LOOP 2, daytime continuation

- `20260915002000_prd122_r4_horizon_days_4.sql` -- `pick_urgency_params.horizon_days` 3 -> 4.
- `20260915002100_prd122_r4_vox_day_branch_dead_code_comment.sql` -- documents the unreachable VOX-day branch in `pick_machines_for_refill`, no behaviour change.
- `20260915002200_prd12x_pa1_engine_add_pod_d1_target_and_expired_sub.sql` -- `engine_add_pod` D1 real target (hero/venue fill-to-cap, else cap 10) and expired-on-shelf substitution pass.
- `20260915002300_prd12x_pa1_pod_swaps_reason_expired_on_shelf.sql` -- `pod_swaps_reason_check` extended for `'expired_on_shelf'`.
- `20260915002400_prd12x_pa1_get_pod_refill_draft_flags_and_exceptions.sql` -- `get_pod_refill_draft` gains `g2_flag`/`g4_flag`/`g9_flag`; new `get_pod_refill_draft_exceptions`.
- `20260915002500_prd12x_pa1_confirm_and_build_real_exceptions.sql` -- `confirm_and_build` returns real exceptions instead of a hard-coded `[]`.
- `20260915002600_prd12x_pa1_confirm_and_build_timeout_margin.sql` -- `confirm_and_build` timeout 120s -> 180s, engine perf risk disclosed.
- `20260915002700_prd12x_pa2_stitch_pod_to_boonz_already_stitched.sql` -- `stitch_pod_to_boonz` returns `already_stitched` instead of raising, fixing a real collision with `commit_refill_plan_atomic`.
- `20260915002800_prd12x_pa3_confirm_machines_to_visit_cs_added.sql` -- `confirm_machines_to_visit` confirms `cs_added` rows too (PRD-124 #37).
- `20260915002900_prd12x_pb_v_current_price_filled.sql` -- new price-fallback view, closes the 16.5% price gap that blocked PRD-126 A3/A5-A7.
- `20260915003000_prd12x_pb_v_machine_priority_price_filled.sql` -- `v_machine_priority` reads the filled price view (includes a mid-flight perf fix).
- `20260915003100_prd12x_pc_set_wh_batch_expiry.sql` -- `set_wh_batch_expiry` RPC + audit log + nightly no-expiry alert (PRD-124 #11).
- `20260915003200_prd12x_pe1_reverse_cancel_dispatch_line.sql` -- clears 19 of the 76 junk 2030-dated dispatch rows (PRD-124 #41); 57 packed=true rows correctly refused.
- `20260915003300_prd12x_pd_wm_confirm_line_split.sql` -- `wm_confirm_line_split` RPC, multi-batch/flavour return confirmation with variance recording (PRD-123 P1/P2).
- `20260915003400_prd12x_pe2_migration_window_alert.sql` -- migration-in-window alert cron; surfaced a real gap between committed migration filenames and the database's own `schema_migrations.version` values (D-024).

See `DECISIONS-2026-09-15.md` and `OVERNIGHT-REPORT-2026-09-15.md` for the reasoning behind
each change and what was verified, deferred, or found already fixed.

## 2026-09-15 (continued) -- ONE LOOP 3, Job 1/2/3

- `20260915072013_prd12x_pf_substitution_rules_writers.sql` -- `add_substitution_rule` / `deactivate_substitution_rule` (Job 1 item 8, FE settings table).
- `20260915072500_prd126_r6_get_machine_health_aed_v2.sql` -- `get_machine_health()` gains `p_score_aed`, `car_no`, `top_contributors_aed` (Job 1 item 9 / PRD-126 R6).
- `20260915074500_prd126_r5_pick_machines_for_refill_v12.sql` -- `pick_machines_for_refill` v12: `p_cars`/`p_per_car`, three-phase cluster-fill picker, `car_no` output (PRD-126 R5). Two follow-up fixes applied to the same function under separate `apply_migration` calls: `priority_tier` CHECK constraint (maps `p_tier_aed` P1/P2 to the legacy P1_RESTOCK/P2_MAINTAIN strings) and `machines_to_visit.priority_score` overflow (see next line).
- `20260915081500_prd126_r5_widen_priority_score.sql` -- `machines_to_visit.priority_score` widened `numeric(5,2)` -> `numeric(10,2)` (AED scores exceed the old 999.99 ceiling); `v_pick_decision_cohorts_v3` dropped/recreated verbatim around the ALTER.
- `20260915075948_prd124_hotfix_insert_driver_remove_line_source_warehouse.sql` -- CS hotfix applied live at 11:55 Dubai via the dashboard, pulled into the repo here: `insert_driver_remove_line`'s plain branch now derives `source_warehouse_id` from the parent instead of blindly copying `source_kind`, fixing a `refill_dispatching_source_consistency_chk` violation the Phase 2 `source_kind` backfill had created.
- `20260915080500_prd12x_pg_align_pod_lots_inherit_expiry.sql` -- `align_pod_lots_to_weimi`'s create-lot branch inherits `expiration_date` from the most recent lot (any status) of the same product on the same machine instead of hardcoding NULL (excludes the 2099-12-31 sentinel). Written and dry-run-verified (44/133 create-lanes across the fleet would now inherit a real date); **not yet applied live** -- CS asked for this after 22:00 Dubai, ahead of cron 77's 22:00 UTC live run.
- `20260915082749_prd12x_j4_push_plan_to_dispatch_source_warehouse_id.sql` -- same bug class as the `insert_driver_remove_line` hotfix, found by grepping every `INSERT INTO refill_dispatching`: `push_plan_to_dispatch`'s Remove/M2W and Refill/Add New legs computed `source_kind='wh'` but never wrote `source_warehouse_id`. Fixed by deriving it from the same warehouse variable each branch already uses for `from_warehouse_id`. The other 6 writers touching `source_kind` were checked and are safe (explicit validated param, or hardcoded `'m2m'` with a real machine id). Verified in a rolled-back transaction against real historical data.

See `DECISIONS-2026-09-15.md` and `OVERNIGHT-REPORT-2026-09-15.md` for the reasoning behind
each change and what was verified, deferred, or found already fixed.

## 2026-09-17/18 -- PRD-127, propose_refill_plan

- `20260917115043_prd127_a_refill_directives.sql` -- `refill_directives` table (`directive_type='block'` only), `add_refill_directive`/`retire_refill_directive` resolving a target name against machines/pod_products/boonz_products (raises on 0 or >1 matches), seeds the BLOCK on Oreo Cookie - Regular.
- `20260917221402_prd127_b_propose_refill_plan.sql` -- `refill_swap_params` table (expired-lane priority boost, minimum substitute stock) and `propose_refill_plan(p_plan_date, p_machine_names, p_overrides)`: a read-only, chat-native "what would happen" proposal built from the full WEIMI lane list, reusing `wh_available_for` (D3) and `find_substitutes_for_shelf` (D4), AED-descending global allocation identical in shape to `engine_add_pod`'s own `prior_need` window. Two follow-up fixes to the same function under separate `apply_migration` calls, both catching a real fan-out bug found on the first live test run (duplicate fill/exception lines from joining a WEIMI lane onto `v_lane_grain`/`v_current_price_filled` by `(machine_id, pod_product_id)` alone, when neither view is unique at that grain -- see D-012).
- `20260917222552_prd127_c1_bind_dispatch_fefo_idempotent_bind_tally.sql` -- `_bind_tally`'s `CREATE TEMP TABLE` made idempotent (`to_regclass` guard), fixing the real cause of 135 `push_fefo_bind_failure` alerts on a multi-machine push on 17 Sep.
- `20260917222553_prd127_c2_insert_driver_remove_line_drop_item_added.sql` -- dropped the `item_added` filter from the M2M-parent search; the real writer of `item_added=true` on both legs is `approve_m2m_transfer` (a warehouse-side approval), not "push pairing" as first reported (D-004), and could permanently block a driver's multi-variant split.
- `20260917222554_prd127_c3_engine_add_pod_sum_all_flavours_wh_avail.sql` -- `wh_avail` now sums `wh_available_for` across every Active flavour mapped to a pod product instead of one `LIMIT 1` representative flavour; a single out-of-stock flavour could falsely report `blocked_no_wh` for the whole lane (13 lanes on 09-16). Verified live: several real pod products go from `old=0` to real stock (113, 114, 2236 units).
- `20260917230242_prd127_d_advisors_fixes.sql` -- 3 missing FK indexes (`refill_directives`, `refill_swap_params`); revoked anon `EXECUTE` on `engine_add_pod` and `insert_driver_remove_line` (both changed above, Supabase's default grant, no legitimate unauthenticated use case).

`docs/prd127-acceptance.sql` (A1-A11, all pass) and `docs/prd127-sample-2026-09-18.md` (a real
`propose_refill_plan` run against the day's actual 11-machine confirmed pick list). See
`DECISIONS-2026-09-17.md` for the reasoning behind every judgment call, including the
reconstruction of `PRD-127-propose-refill-plan.md` itself (the spec document did not exist
anywhere in the repo or its git history when this turn started).
