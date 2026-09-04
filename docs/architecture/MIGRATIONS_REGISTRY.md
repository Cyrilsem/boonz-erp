# Migrations Registry

The Supabase `migrations` table is the system of record. This file is a curated index that maps **architecture-reform migrations** to Constitution articles and Phase A steps, so we can answer "what's been done, what's left" at a glance without reading raw SQL.

Migrations not listed here are pre-reform (operational migrations from before 2026-04-25). They're not in scope for the constitution-compliance rollup but remain in the Supabase history.

## DF3 — driver_tasks auto-close on PO settle (APPLIED 2026-08-19)

| Migration name                              | Article(s)        | Status             | Note                                                                                                                                                                                                                                                              |
| ------------------------------------------- | ----------------- | ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `df3_driver_tasks_autoclose_on_po_settle`   | 1, 4, 5, 7, 8, 12 | ✅ Applied to prod | `cancel_po_line`: after the DF2 notes rebuild, if zero actionable lines remain on the PO, flip the open driver task to `collected` (≥1 line received) or `cancelled`, appending an `[auto-closed by cancel_po_line]` marker. `cancel_po` inherits via delegation. |
| `df3_receive_purchase_order_autoclose_task` | 1, 4, 5, 7, 8, 12 | ✅ Applied to prod | `receive_purchase_order`: same terminal block before RETURN. Fixes the 66-task driver backlog (64 stale). One-time cleanup of 65 stale tasks done via execute_sql the same day. A `pending_receive` addition does not hold the task open (documented choice).     |

**Cody review 2026-08-19:** ✅ Approve (Articles 1, 4, 5, 7, 8, 12, 13, 14). Non-protected entity (`driver_tasks`), existing canonical writers, S-142/S-147 auto-close precedent.

## PRD-113 — in-machine moves are not returns + expired stock never auto-consumed (APPLIED 2026-08-10)

| Migration name                                   | Article(s)         | Status             | Note                                                                                                                                                                                                                                                                                                                                                              |
| ------------------------------------------------ | ------------------ | ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd113_a1_is_internal_move_column`              | 12, 14             | ✅ Applied to prod | `refill_dispatching.is_internal_move boolean NOT NULL DEFAULT false` + the human-override pair `internal_move_cleared_at` / `internal_move_cleared_by` + partial pairing index `idx_rd_internal_move_pair`. Additive; every existing row keeps today's meaning. Column, not table — Article 14 not engaged.                                                       |
| `prd113_a2_internal_move_predicate_and_writer`   | 1, 3, 4, 8, 12, 16 | ✅ Applied to prod | Canonical predicate `is_internal_move_dispatch` (`security_invoker`, registered in `METRICS_REGISTRY.md`), stamp writer `mark_internal_move_legs`, un-stamp writer `clear_internal_move_flag`, `AFTER INSERT` trigger `trg_mark_internal_move_pair`, and both new writers added to the `enforce_canonical_dispatch_write` allowlist.                              |
| `prd113_a3_return_queue_excludes_internal_moves` | 1, 12, 16          | ✅ Applied to prod | `v_pending_wh_remove_confirmations` excludes in-machine moves (cron 12 `monitor_stuck_remove_dispatches` inherits it for free); `wh_approve_remove_receipt`, `wh_approve_remove_receipt_multivariant` and `approve_stuck_remove` each refuse one. Bodies otherwise byte-identical — the genuine return flow is unchanged.                                         |
| `prd113_a4_fifo_never_consumes_expired`          | 5, 7, 11, 12       | ✅ Applied to prod | `auto_decrement_pod_inventory`: batches expired as of the current Dubai date are ineligible for FIFO sales consumption. Overflow attributable to the rule is reported under `prd113_fifo_expired_overflow`. One implementation, one caller chain (`refresh-stage1` → `run_pod_inventory_decrement` → here); no cron caller, so cron parity holds by construction. |

**Cody review 2026-08-10:** ⚠️ Approve with revisions, 7 conditions, all implemented before apply. Conditions 1–3 (Article 4 provenance + role validation on `mark_internal_move_legs`, `app.rpc_name` stamping in the trigger, INVOKER for the read-only predicate), 4–5 (`clear_internal_move_flag` as the canonical un-stamp writer plus the durable `internal_move_cleared_at` override, because the refusal messages had instructed a direct write on a protected table), 6–7 (registry entries — this row and the `METRICS_REGISTRY` / `RPC_REGISTRY` rows).

## Dispatch role vocabulary fix (APPLIED 2026-07-18)

| Migration name                                         | Article(s)  | Status             | Note                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------------------------------------ | ----------- | ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phaseF_dispatch_role_chk_align_field_staff_warehouse` | 1, 2, 7, 12 | ✅ Applied to prod | Widened `refill_dispatching_last_edited_role_chk` + `refill_dispatching_edit_log_edited_by_role_check` to allow `field_staff` + `warehouse` (legacy `driver`/`warehouse_manager` kept). Fixes `swap_shelf_pod`/`add_dispatch_row` INSERTs being rejected for field/warehouse users. Additive, forward-only DROP+ADD. Cody PASS. Verified via field_staff swap on WH1-2002. |

## PRD-055 notes consolidation into Signals (APPLIED 2026-06-23)

| Migration name                                   | Article(s)  | Status             | Note                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------ | ----------- | ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd055_p1_signal_source_and_issues_view`        | 1, 12       | ✅ Applied to prod | `refill_edit_signals.signal_type` CHECK extended +`'note'` (inert: engine_swap_pod reads only `swap_rejected`; md5 90f26896… unchanged). New read-only `v_action_tracker_issues` (security_invoker) = action_tracker minus driver_feedback. `source` free text (no DDL for 'field_note'/'action').                                                                                                                                                                                                 |
| `prd055_p2_fold_notes_into_signals`              | 1, 12       | ✅ Applied to prod | Idempotent, origin-tagged, NO deletes. 6 machine_field_notes -> signals source='field_note'; 50 action_tracker driver_feedback -> signals source='action'; 42 bug/task/decommission kept in Issues view. All 98 accounted; source rows retained. engine byte-identical.                                                                                                                                                                                                                            |
| `prd055_p4_deprecate_machine_field_notes_writes` | 13          | ✅ Applied to prod | No DB/FE writer of machine_field_notes exists -> retire write path via REVOKE INSERT/UPDATE/DELETE from authenticated (SELECT kept). Table NOT dropped; 90-day monitor to 2026-09-21.                                                                                                                                                                                                                                                                                                              |
| `prd055_p5_redirect_driver_writers_to_signals`   | 1, 4, 8, 12 | ✅ Applied to prod | Completes consolidation: `driver_propose_adjustment` + `driver_report_dispatch_outcome` no longer INSERT `action_tracker`; their driver-feedback/re-dispatch note now lands in `refill_edit_signals` (source='action', signal_type='note' -> engine-inert). Other writes (driver_recommendations, driver_feedback, refill_dispatching outcome UPDATE) + validation + app.via_rpc preserved. engine_swap_pod md5 90f26896… unchanged. Rolled-back test: at_delta=0, sig_delta=2, engine md5 pinned. |

(No P3 migration — P3 is FE-only: Field Capture + Tracker tabs removed from `/app/refill`, Tracker -> Issues reading `v_action_tracker_issues`, Signals the single notes channel.)

## PRD-054 returns-queue cleanup (APPLIED 2026-06-23)

| Migration name                       | Article(s) | Status             | Note                                                                                                                                                                                                                                                                                                                                                                                                  |
| ------------------------------------ | ---------- | ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd054_a_returns_queue_exclude_m2m` | 1, 12      | ✅ Applied to prod | View `v_pending_wh_remove_confirmations` recreated +1 predicate `AND COALESCE(rd.is_m2m,false)=false` (else byte-identical). WH returns-approval queue 21->15, m2m 6->0, all 7 PRD-052 legs excluded. Venue_team (VOX) receive guard found ALREADY LIVE in `receive_dispatch_line` (covers wh_approve_remove_receipt[_multivariant] via delegation) — no function change; verified T1-T6 rolled-back. |

## PRD-059 expiry-batch-hygiene (APPLIED 2026-06-24)

| Migration name                         | Article(s)       | Status             | Note                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| -------------------------------------- | ---------------- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd059_ws2_resolve_shelf_backfill`    | 1,3,8,12 + HR6   | ✅ Applied to prod | RESOLVE: `pod_inventory.shelf_id` NULL→live shelf for **61** Active NULL-shelf batches (boonz→pod_product via Active product_mapping, live in v_live_shelf_stock, shelf via slot_lifecycle single current). Pointer-only. Anti-collision guard (`NOT EXISTS` Active row on machine+shelf+product) skips 74 secondary-batch collisions vs `UNIQUE idx_pod_inv_active_shelf` (→WS6 display); 23 ambiguous Mix left NULL. Idempotent (shelf_id IS NULL), cap 120. Dara+Cody ✅. |
| `prd059_ws3_no_mapping_inactive`       | 1,3,5,8,12 + HR6 | ✅ Applied to prod | NO ACTIVE MAPPING: **23** NULL-shelf Active batches (no Active mapping) → status='Inactive'. Status transition only; stock preserved; reversible via audit log. Idempotent, cap 50. Cody ✅.                                                                                                                                                                                                                                                                                 |
| `prd059_ws4_highlight_orphan_writeoff` | 1,3,5,8,12 + HR6 | ✅ Applied to prod | HIGHLIGHT orphans: **110** mapped-but-not-live NULL-shelf Active batches → status='Removed/Expired', removal_reason='orphan_not_on_machine'. Concentrated on WH2-\* staging + `_OLD` decommissioned units. Stock preserved; reversible. Idempotent, cap 160. Cody ✅.                                                                                                                                                                                                        |
| `prd059_ws5_inactive_cleanup`          | 1,3,5,8,12 + HR6 | ✅ Applied to prod | Inactive cleanup: **1,901** Inactive rows with stock>0 (incl. the 23 from WS3, per CS "all inactive removed") → status='Removed/Expired', removal_reason='inactive_cleanup'. current_stock PRESERVED (not zeroed). End state: 0 Inactive-with-stock rows. Idempotent, cap 2300. Cody ✅.                                                                                                                                                                                     |
| `prd059_ws6_drawer_expiry_truth`       | 16,12            | ✅ Applied to prod | Read-only RPCs. `get_machine_slots_with_expiry` +`nearest_expiry_days`/`nearest_expiry_qty` (nearest batch any horizon; Exp Qty never blank) — DROP+CREATE, columns appended (FE-compatible). NEW `get_machine_orphan_expiry(machine)` = NULL-shelf Active batches not on any live slot (umbrella/ambiguous remainder) for drawer orphan section. Both read canonical v_machine_expiry_batches+v_live_shelf_stock (no inline re-derivation). Cody ✅.                        |

T3 invariant: `pod_inventory` total **6,515 rows unchanged** (no DELETE); every WS3/4/5 change a reversible status transition. T5: engine_add_pod/engine_swap_pod unmodified; swaps_enabled=false. FE (refill/page.tsx) tsc+lint+build green; not pushed to main.

## PRD-058 tunable-priority-weights (APPLIED 2026-06-24)

| Migration name                    | Article(s)   | Status             | Note                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| --------------------------------- | ------------ | ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd058_tunable_priority_weights` | 2,3,12,14,16 | ✅ Applied to prod | NEW single-row config table `refill_priority_params` (id PK DEFAULT 1 CHECK id=1; 30 numeric weight/threshold cols + `dead_stock_forces_p1` bool + updated_at/by) feeding canonical `v_machine_priority`. View rewritten to `CROSS JOIN refill_priority_params p`; every weight/tier-gate/dead-stock literal → `p.<col>` (score-internal comparison constants stay literal per PRD; reasons_arr + `::numeric(6,2)` cast unchanged). Dead dial: `dead_stock_forces_p1=false`+`w_expired_now=0` drops expired-only machines from P1. Consumers (get_machine_health, pick_machines_for_refill) untouched. RLS `rpp_prio_select` USING(true) (view CROSS JOINs the row — must stay visible) + `rpp_prio_write` operator_admin/superadmin/manager. Seeded to baked-in literals → behavior-neutral. T1 GOLDEN live md5 `6bb5b9cbd44aa0f10f0519f7f6579dcb` (30 rows) byte-identical; T6 guard PK+CHECK (row_count=1). Pre-apply inline diff 0/30 drift on defaults. Dara ✅ Cody ✅. |

## PRD-070 m2m-approval-routes-to-destination-machine (APPLIED 2026-07-01)

| Migration name                                           | Article(s)      | Status             | Note                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| -------------------------------------------------------- | --------------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `20260701150259_prd070_m2m_approve_to_destination`       | 1,3,4,6,12,14   | ✅ Applied to prod | NEW canonical `approve_m2m_transfer(uuid,uuid)` (atomic+idempotent; both legs receive_dispatch_line -> source pod out, dest pod in same qty+expiry, ZERO WH; stamps wh_approved+m2m_approved; asserts warehouse_stock before==after). Additive `m2m_approved_at` col + partial `idx_rd_m2m_transfer`. Hard guard: `wh_approve_remove_receipt` REJECTS is_m2m. Dry-run WH delta=0, dest pod +11 on transfer 1538f35f.                 |
| `20260701150432_prd070_m2m_guard_multivariant`           | 1,3,6           | ✅ Applied to prod | `wh_approve_remove_receipt_multivariant` REJECTS is_m2m, points to approve_m2m_transfer. Faithful CREATE OR REPLACE, no other logic changed.                                                                                                                                                                                                                                                                                         |
| `20260701160000_prd070_d2_pair_internal_transfer_m2m`    | 1,3,4,6,8,12,14 | ✅ Applied to prod | D-2. NEW idempotent `pair_internal_transfer_m2m(date,uuid)`. push_plan_to_dispatch carries internal_transfer onto legs but never sets is_m2m/transfer_id; this flags is_m2m + shared m2m_transfer_id + m2m_partner_id + source_machine_id on UNAMBIGUOUS 1:1 conserving pairs (ambiguous/mismatch skip+log). Metadata-only, WH delta 0 by construction. Also the backfill. Dry-run 0 pairs live (safe no-op). Engines md5 unchanged. |
| `20260701160500_prd070_d3_pick_list_m2m_dest_visibility` | 12,16           | ✅ Applied to prod | D-3. CREATE OR REPLACE VIEW `v_dispatch_pick_list`, byte-identical columns, WHERE relaxed to surface pending M2M dest legs (is_m2m AND NOT item_added) even when dispatched=true; all other guards preserved. View only, no row mutation. Dry-run 244->244 rows, 0 newly surfaced, protected transfer 1538f35f NOT surfaced.                                                                                                         |

## PRD-071 environment closeout (APPLIED 2026-07-02)

| Migration name                                                         | Article(s)                | Status             | Note                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ---------------------------------------------------------------------- | ------------------------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `20260702151932_prd071_wsb_push_v7_prepaired_m2m_drop_legacy_overload` | 1,3,4,6,8,12 + Am.003/005 | ✅ Applied to prod | push_plan_to_dispatch v6 -> v7: internal_transfer plan lines become PRE-PAIRED atomic M2M writes (dest-driven, shared m2m_transfer_id, FEFO source batch split, monitoring_alerts skip-log, never fails the push) + post-loop pair_internal_transfer_m2m safety net with GUC restore. DROPs the prod-only legacy (text,date) overload that broke ALL PostgREST named calls (42725) - fulfils the Article 13 deprecation flag. Closes the push-body PRD-057 drift (full body now in git). Dry-run: pair_ok, WH delta 0, idempotent x2, engines md5 unchanged. |
| `20260702153225_prd071_wsc3_approve_m2m_normalize_returned_on_approve` | 1,3,4,6,8,12 + Am.003     | ✅ Applied to prod | approve_m2m_transfer v2: explicit counted normalize pass (returned=false on not-yet-received dest legs) before receiving - fixes the convert-path anomaly at the approve choke point; convert untouched. dispatch_date intentionally kept historical (packed-row immutability). Used to approve transfer 1538f35f (7 normalized, 6+7 legs received, WH delta 0).                                                                                                                                                                                             |

## Registry backfill (PRD-071 WS-D sweep, 2026-07-02): sections missing for applied migrations

| Migration name                                                    | Article(s) | Status             | Note                                                                                                                                                                                                            |
| ----------------------------------------------------------------- | ---------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260618120000_prd036_a_v_dispatch_pickable`                     | 16         | ✅ Applied to prod | PRD-036: pickable-stock dispatch view.                                                                                                                                                                          |
| `20260618130000_prd036_b_log_manual_refill_new_purchase`          | 1,3,8      | ✅ Applied to prod | PRD-036: field batch capture writer.                                                                                                                                                                            |
| `20260701100100_prd036_c_bind_dispatch_fefo`                      | 1,4,12     | ✅ Applied to prod | PRD-036: FEFO dispatch bind (shipped with PRD-068, e1b9368).                                                                                                                                                    |
| `20260619140000_prd037_p0_coexistence_rules_brand_owner`          | 2,16       | ✅ Applied to prod | PRD-037 P0: coexistence rules + brand owner data.                                                                                                                                                               |
| `20260619140100_prd037_p1_engine_swap_pod_v12`                    | 1,12,14    | ✅ Applied to prod | PRD-037 P1: engine_swap_pod v12 (line since superseded by v13 PRD-039, v14, v15_slot_profile PRD-042 - v15 verified live 2026-07-02). swaps_enabled false throughout.                                           |
| `20260622010000_prd048_a_base_stock_inputs`                       | 2,16       | ✅ Applied to prod | PRD-048 ADD-brain base-stock inputs.                                                                                                                                                                            |
| `20260622020000_prd048_b_compute_base_stock_decision`             | 16         | ✅ Applied to prod | PRD-048 service-level base-stock sizing decision fn.                                                                                                                                                            |
| `20260622021000_prd048_b2_spoilage_dominates_floor`               | 16         | ✅ Applied to prod | PRD-048 spoilage-dominates floor rule.                                                                                                                                                                          |
| `20260622030000_prd048_c_engine_add_pod_v19_base_stock`           | 1,12,14    | ✅ Applied to prod | PRD-048 engine_add_pod v19 base-stock (behind flag; prod-sync 2111dda).                                                                                                                                         |
| `20260622040000_prd048_d_v_product_shelf_life`                    | 16         | ✅ Applied to prod | PRD-048 canonical product shelf-life view.                                                                                                                                                                      |
| `20260622050000_prd048_e_engine_v19_shelf_life_canonical`         | 1,12       | ✅ Applied to prod | PRD-048 engine v19 reads canonical shelf life.                                                                                                                                                                  |
| `20260622060000_prd048_f_engine_v19_daily_velocity_units`         | 1,12       | ✅ Applied to prod | PRD-048 engine v19 velocity units fix.                                                                                                                                                                          |
| `20260629100000_prd065_a1_edits_qty_guard`                        | 1,3,12     | ✅ Applied to prod | PRD-065 A1: dispatch-edit qty guard.                                                                                                                                                                            |
| `20260629100100_prd065_a1_set_edit_quantity_and_approve`          | 1,3,8      | ✅ Applied to prod | PRD-065 A1: canonical edit-qty + approve writer.                                                                                                                                                                |
| `20260629100200_prd065_a2_create_field_add_edit`                  | 1,3,8      | ✅ Applied to prod | PRD-065 A2: field add/edit writer.                                                                                                                                                                              |
| `20260629100300_prd065_a3_dispatch_remainder_credit`              | 1,4,6      | ✅ Applied to prod | PRD-065 A3: dispatch remainder credit on receive.                                                                                                                                                               |
| `20260629100400_prd065_b1_v_expired_inventory`                    | 16         | ✅ Applied to prod | PRD-065 B1: expired-inventory view.                                                                                                                                                                             |
| `20260629100500_prd065_b4_warehouse_expire_writeoff`              | 1,3,6,8    | ✅ Applied to prod | PRD-065 B4: warehouse expire write-off writer.                                                                                                                                                                  |
| `20260629100600_prd065_b2_sweep_expired_inventory`                | 1,3,12     | ✅ Applied to prod | PRD-065 B2: expired-inventory sweep.                                                                                                                                                                            |
| `20260629100700_prd065_b3_driver_confirm_expired_removal`         | 1,3,8      | ✅ Applied to prod | PRD-065 B3: driver confirm expired removal.                                                                                                                                                                     |
| `20260630101000_prd068_purge_test_rows_2099`                      | 5,12       | ✅ Applied to prod | PRD-068: purge 2099-dated test rows.                                                                                                                                                                            |
| `20260701100000_prd068_durable_conservation_guards`               | 1,4,12     | ✅ Applied to prod | PRD-068: durable conservation guards (trg_conserve_split_qty, trg_reassert_conservation, trg_credit_dispatch_remainder) - verified live 2026-07-02.                                                             |
| `20260626114643_prd062_merge_delete_duplicate_hunter_hot_n_sweet` | 1,3,5,12   | ✅ Applied to prod | PRD-062: merged duplicate boonz_product cca563ee (Hunter Hot N Sweet) into 8bc412d9 (Hunter Ridge - Hot N Sweet) then DELETEd after zero-ref scan; conservation + collision-dedup asserts. Parity file on main. |

FE: `PendingRemoveApprovalsPanel` approve handlers route is_m2m legs to approve_m2m_transfer (defensive; queue still filters is_m2m=false). tsc 0 errors, build ok. NEEDS CS: 2 stale MINDSHARE Remove legs (unpairable), convert dest-leg returned=true+past-date anomaly, push->pair auto-wiring, live 1538f35f approval.

## PRD-052 convert-removes-to-m2m (APPLIED 2026-06-23)

| Migration name                           | Article(s)    | Status             | Note                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ---------------------------------------- | ------------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd052_convert_removes_to_m2m_transfer` | 1,4,6,8,12,14 | ✅ Applied to prod | NEW canonical writer `convert_removes_to_m2m_transfer(uuid[],uuid,uuid,text)` (added to `enforce_canonical_dispatch_write` allowlist). Retro-converts dispatched plain Removes into paired M2M (source is_m2m=true + dest Add New, shared transfer_id, partner-linked, from_warehouse_id NULL, qty=COALESCE(driver_confirmed_qty,quantity); sets source_machine_id + source_kind='m2m' for `m2m_consistency`). ONLY refill_dispatching; no pod/WH writes. Executed on 7 NOVO-1023 VW removes -> MINDSHARE-1009 A16, transfer_id `1538f35f…`, 11u, zero WH credit, 14 audit rows. T1-T8 rolled-back green. Not git-pushed to main. |

## PRD-031 refill-execution-accuracy (IN PROGRESS 2026-06-14)

| Migration name                          | Article(s)    | Status              | Note                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| --------------------------------------- | ------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| WS-1 product_mapping integrity          | (audit only)  | ✅ No-op (verified) | Read-only audit found ZERO (pod,boonz,machine) duplicates; UNIQUE(pod,boonz,machine_id) + global-default partial-unique constraints ALREADY live. "80 Red Bull rows" = 38 distinct per-machine scoped + global, not dupes. PRD premise wrong; no dedup written (would have deleted legit per-machine rows). Leak is purely the two stitch faults (WS-2/WS-2b).                                                                                                                                                                                                                              |
| `prd031_ws2_ws2b_stitch_onshelf_scoped` | 1,4,5,8,12,14 | ✅ Applied to prod  | `stitch_pod_to_boonz` v21→`v22_onshelf_scoped`. WS-2b scoped-authoritative mapping (pull_raw + pm_per_row NOT-EXISTS gate); WS-2 off-shelf redistribution (on_shelf + shelf_has_known_variant; residual predicate auto-renormalizes via PRD-024 window) with ADD_NEW exemption. v21 md5 `52a6d3b1…a01e`, live v22 md5 `5cec9590…cbe5`. Rolled-back battery green. Cody ⚠️→cleared.                                                                                                                                                                                                          |
| `prd031_ws4_refill_accuracy_gate`       | 4,12,16       | ✅ Applied to prod  | New canonical metric `v_refill_accuracy` (security_invoker; intent-driven LEFT JOIN dispatched so zero-dispatch leaks visible) + read-only `get_refill_plan_accuracy(date)` (INVOKER) returning per-line status (ok\|wh_short\|leak\|over) + plan verdict (pass\|flag\|block). Replaces the vacuous stitch deviation block (root-cause D). Rolled-back battery green (leak/wh_short/ok/zero-dispatch all classified, verdict=block on leaks). FE panel in RefillPlanningTab. Cody ⚠️→cleared.                                                                                               |
| `prd031_ws3_engine_cover_capped`        | 1,4,8,12,16   | ✅ Applied to prod  | `engine_add_pod` v16→`v17_cover_capped` (CS Option B). `need_raw = LEAST(GREATEST(cover_units, driver_req), fill_to_cap)`; cover_units = stance-aware velocity cover (`velocity_target`), wind-down/rotate/dead→0, floor 1. Drift fix: cover uses `p_days_cover` (was 10). Engine consumes `velocity_target` not visual-floored `refill_qty` (now advisory). Read-only battery 2026-06-15: 515u→324u (−37%), fast movers unchanged. live v17 md5 `53efb83f…6e68`. Cody ⚠️→cleared.                                                                                                          |
| `prd031_ws6_drop_sold_7d_column`        | 12,16         | ✅ Applied to prod  | Dropped the dead always-0 `refill_plan_output.sold_7d` placeholder (DDL on protected table); `write_refill_plan` no longer writes it. Real 7d-sales display comes from `get_refill_plan_output_enriched` (`v_sales_history_attributed`), unaffected. FE: `RefillPlanReview` type field removed. tsc clean. Cody ✅.                                                                                                                                                                                                                                                                         |
| `prd031_ws5_stitch_wh_reserved`         | 1,4,5,8,12,14 | ✅ Applied to prod  | `stitch_pod_to_boonz` v22→`v23_wh_reserved`. New `wh_reservation` CTE: `[WH_WARNING]` now fires on reserved-remaining (`wh_avail − cumulative prior variant_final` per boonz, machine_name/shelf order), not total — a shared SKU can't read covered for N machines and pack dry. Warn-only; BUG-006 + PRD-030 are the pack-time guard; WS-4 reads it as `wh_short`. **2nd stitch rewrite within 24h** (Hard Rule 10) under CS "continue WS-5". v22 md5 `5cec9590…cbe5`, live v23 md5 `450303cd…d3fa`. Battery (Popit Cola WH=3, 3 machines): VML-1004 flagged reserved 0. Cody ⚠️→cleared. |

## PRD-030 partial-pack / no-dark-stage (IN PROGRESS 2026-06-14)

| Migration name                                            | Article(s)    | Status             | Note                                                                                                                                                                     |
| --------------------------------------------------------- | ------------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `prd030_pack_outcome_enum_and_column`                     | 12, 14        | ✅ Applied to prod | CREATE TYPE pack_outcome_enum(packed/partial/not_filled) + ADD COLUMN refill_dispatching.pack_outcome (nullable). Forward-only column evolution. Cody class (a) ✅.      |
| `prd030_pack_dispatch_line_partial_notfilled`             | 1,4,5,8,12,14 | ✅ Applied to prod | Empty picks => not_filled (no WH debit), partial keeps planned in original_quantity, conserve trigger untouched. Battery green. Cody ✅. v-before md5 `63454d3d...703c`. |
| `prd030_dispatch_pack_confirmation_table` (+`_add_id_pk`) | 2,7,8,12      | ✅ Applied to prod | New dispatch_pack_confirmation table (id PK + UNIQUE(machine_id,dispatch_date)); RLS read-all + DEFINER-only + audit_log_write.                                          |
| `prd030_confirm_machine_packed`                           | 1,4,8,12      | ✅ Applied to prod | Machine-level pack gate; blocked unless all lines resolved; writes only the confirmation table. Battery green. Cody ✅.                                                  |
| `prd030_pack_status_and_notfilled_views`                  | 16            | ✅ Applied to prod | Canonical v_machine_pack_status (readiness) + v_not_filled_lines (unfilled demand, incl. partial remainders).                                                            |
| `prd030_release_stale_exclude_not_filled`                 | 1,4,12        | ✅ Applied to prod | EOD release excludes not_filled lines.                                                                                                                                   |

## PRD-029 dispatch-state-integrity — skipped lines inert (step 1 APPLIED 2026-06-12)

| Migration name                 | Article(s)  | Status             | Note                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------------------------ | ----------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phaseF_dispatch_state_guards` | 1, 4, 12    | ✅ Applied to prod | pack*dispatch_line: unconditional skipped/cancelled/include=false refusal naming flag + skip_reason, before any mutation. return_dispatch_line: same refusal conditional on packed=false AND picked_up=false (flagged-but-packed = recovery path + EOD sweep contract) + system-actor guard (no actor + nothing physical). PRD 2b corrected: eod sweep pass 1 DOES call return_dispatch_line (packed=true only) - unaffected. Battery 1-4 green rolled-back. Rollback defs + md5s captured. Cody ✅. Repo file `20260612135850*\*.sql`. |
| `phaseF_unskip_dispatch_line`  | 1, 4, 5, 12 | ✅ Applied to prod | NEW canonical writer `unskip_dispatch_line(p_dispatch_id, p_actor DEFAULT NULL)`: clears skipped + include=false in one logged write (actor COALESCE(p_actor, auth.uid()) in mutation_reason; skip_reason preserved); REFUSES cancelled lines. Needed because set_dispatch_include cannot clear skipped, which would leave un-skip silently dead under the step-1 guards. Packing FE handleUnskip rewired. Unskip smoke green (rolled-back). Cody ✅. Repo file `20260612141205_phaseF_unskip_dispatch_line.sql`.                       |

## PRD-028 WS4 Option 1 + WS1 view drops (APPLIED 2026-06-12)

| Migration name                                   | Article(s) | Status             | Note                                                                                                                                                                                                       |
| ------------------------------------------------ | ---------- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd028_ws4_payment_default_matched_only_v2`     | 4, 12, 16  | ✅ Applied to prod | get_payment_default_summary v2: matched-only gap/default + explicit unmatched_exposure age-split at 7d (CS Option 1). Signature unchanged. Cody ✅. v1 md5 `10662ff4...5926`.                              |
| `prd028_ws4_payment_default_v2_1_refund_aligned` | 4, 12, 16  | ✅ Applied to prod | v2.1: per-ref default_short floors at 0 and excludes refunds (PRD-023h). Cody's required live comparison caught v2's refund double-count (567.30 -> 141.30, now cent-equal with the commercial waterfall). |
| `prd028_ws1_drop_deprecated_expiry_views`        | 12, 13, 16 | ✅ Applied to prod | DROP v_pod_inventory_expiry_status + v_pod_inventory_health (CS-approved; pg_depend re-check 0 dependents in-session; canonical v_machine_expiry_summary live).                                            |

## PRD-028 — metrics registry / Article 16 (WS1-WS5 APPLIED 2026-06-12; WS4 consumer ribbons CS-gated)

| Migration name                                 | Article(s)                | Status             | Note                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ---------------------------------------------- | ------------------------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `prd028_ws5_active_fleet`                      | 4, 12, 14 (+A16 draft)    | ✅ Applied to prod | WS5 fleet scope. NEW `v_active_fleet` (status NOT IN Inactive/Warehouse; exposes include_in_refill/repurposed_at/service_track for declared consumer filters - repurposed-but-Active rows carry 3,620.75 AED of period sales, so not baked in). `get_payment_default_summary` venue branch consumes it; full jsonb equality pre/post proven. Data smell: 5 Active machines with repurposed_at. Cody ✅. Repo file `20260612072352_prd028_ws5_active_fleet.sql`.                                                                                                                                                                                                                                                                                                                                                                            |
| `prd028_ws3_wh_pickable_dispatch_availability` | 2, 3, 12, 14 (+A16 draft) | ✅ Applied to prod | WS3 pickable+availability. NEW `v_wh_pickable` (canonical pickable predicate, batch grain, security_invoker; 28 quarantined/expired-but-Active leak rows excluded of 167). `v_dispatch_availability` (zero consumers pre-WS3) consumes it + `picked_up=false` commitment condition; before/after IDENTICAL on live data. Packing FE: batch fetch -> view; committed = unpacked+unpicked claims (kills packed-line double-count, the Available:0 class); product-grain Available badge. tsc+build green. Pre-existing FE direct WH writes flagged (Art 3/6), ticketed, not fixed. Cody ✅. Repo file `20260612070658_prd028_ws3_wh_pickable_dispatch_availability.sql`.                                                                                                                                                                     |
| `prd028_ws2_velocity_canonical`                | 4, 12 (+A16 draft)        | ✅ Applied to prod | WS2 velocity unification. NEW `v_machine_velocity` (units_7d/30d, daily_velocity_7d/30d; Success-only; rolling now() windows) = CANONICAL machine velocity. `get_machine_health.daily_velocity` consumes it (values identical; fn gains search_path); `v_machine_health_signals.units_last_7d` consumes it (gains Success filter - no-op today; anchor CURRENT_DATE -> now(), 9 machines shift 1-2 units, documented). AC: 0 mismatches both consumers; no inline machine-level SUM(qty)/7 left. Cody ⚠️->cleared. Repo file `20260612065444_prd028_ws2_velocity_canonical.sql`.                                                                                                                                                                                                                                                           |
| `prd028_ws1_expiry_canonical`                  | 4, 12, 13 (+A16 draft)    | ✅ Applied to prod | WS1 expiry unification. NEW `v_machine_expiry_batches` (batch-resolution rule: latest Active batch per shelf, NULL-shelf legacy per machine+product, no lookback window); `v_machine_expiry_summary` redefined as CANONICAL over it (+appended SKU cols, Dubai operational date); `v_machine_health_signals.expiry_state` consumes summary; `get_machine_expiry_detail` (DEFINER, +search_path) and `get_machine_slots_with_expiry` (INVOKER) realigned onto batches view. `v_pod_inventory_expiry_status`/`v_pod_inventory_health` COMMENT-deprecated (drop pending CS). AC verified: 30 machines, 0 disagreements signals vs get_machine_health; OMDBB-1020 repro fixed (badge 0 -> 2 units); AMZ-1038 phantom 16 Inactive units -> 0. Cody ⚠️->cleared (search_path added). Repo file `20260612063856_prd028_ws1_expiry_canonical.sql`. |

## PRD-027 — refill hardening batch (WS1 APPLIED 2026-06-12; WS5 drafted-held; WS2/3/4 ticketed)

| Migration name                            | Article(s)  | Status                    | Note                                                                                                                                                                                                                                                                            |
| ----------------------------------------- | ----------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phaseF_swap_pod_v10_2_ws1_guards`        | 1, 4, 8, 12 | ✅ Applied to prod        | engine_swap_pod v10.1 -> v10.2: p_min_pearson applied w/ explicit `global_performer_fallback` marker; per-machine cap across passes (overflow dead-tags deferred + carried); `clamp_reason=default_capacity_8` audit marker. Cody ✅. v10.1 md5 `c30f1165...4894`. Smoke green. |
| `_DRAFT_phaseF_stitch_v21_ws5_real_stock` | 1, 4, 8, 12 | 🟡 DRAFT - HELD (CS gate) | stitch v21: emit real current/max stock instead of hardcoded zeros. Second stitch rewrite within 24h of v20 -> needs CS green light + apply-time Cody on the full verbatim body. Underscore prefix keeps db push from applying it.                                              |

## PRD-025 — finalize preserves approved rows (APPLIED 2026-06-12)

| Migration name                      | Article(s)     | Status             | Note                                                                                                                                                                                                                                                                                              |
| ----------------------------------- | -------------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phaseF_finalize_preserve_approved` | 1, 4, 5, 8, 12 | ✅ Applied to prod | `engine_finalize_pod` (2-arg) v13 -> v14: upsert preserves `approved` when qty+action unchanged, else draft. Kills the "Stitch failed: no approved rows" FE Commit race. Rolled-back regression green (133/133 kept; 1 mutated row drafts; subset 24/24 kept). Cody ✅. v13 md5 `ec8ace36...b6d`. |

## PRD-024 — stitch split normalization + 06-13 reset (section 1 APPLIED 2026-06-12; section 2 gated)

| Migration name                      | Article(s)         | Status             | Note                                                                                                                                                                                                                                                                                                                                                                                  |
| ----------------------------------- | ------------------ | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phaseF_stitch_split_pct_normalize` | 1, 4, 5, 8, 12, 14 | ✅ Applied to prod | stitch v19 -> v20 self-normalizing SKU split (reads `pm.split_pct`, divides by windowed total at 4 sites + new `pm_norm` procurement CTE). Kills multi-flavor inflation (VOXMCC A10 10->30). Battery sim green (106 shelf-pods conserve; 0 single-SKU drift; Activia 170 -> 4/3/3). Cody ✅. v19 md5 `16fb196b...4614`. Section 2 (06-13 plan reset runbook) is CS-gated and pending. |

## PRD-022 — Procurement PO experience (IN PROGRESS 2026-06-11)

| Migration name                               | Article(s)  | Status             | Note                                                                                                                                                                                                                                                                                                                                                                                    |
| -------------------------------------------- | ----------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd022_df1_po_number_allocation`            | 1, 4, 12    | ✅ Applied to prod | DF1. Resynced `po_number_seq` (was below max → re-issuing dupes); `idx_po_number`; `BEFORE INSERT` trigger `trg_po_number_one_po_id` (new po_id can't reuse another po_id's po_number; skips same-po_id + D3b appends + historical dups); `create_purchase_order` skip-used loop. Dara + Cody ✅. Verified: collision blocked, same-po_id allowed, seq≥max, 0 leaks.                    |
| `prd022_df2_cancel_regenerates_driver_notes` | 1, 4, 8, 12 | ✅ Applied to prod | DF2. `cancel_po_line` rebuilds `driver_tasks.notes` (pending/acknowledged tasks only) from remaining non-cancelled lines so drivers stop seeing cancelled products. Verbatim re-create + one block; status untouched. Cody ✅. Verified (rolled-back): cancelled product dropped from notes.                                                                                            |
| `prd022_d5_get_open_po_lines`                | 4, 12       | ✅ Applied to prod | D5. Read-only `get_open_po_lines(p_supplier_id uuid DEFAULT NULL)` — open lines (received_date NULL + not cancelled, same as `on_order`) with server-side supplier filter. Powers D1 chips + D3 list. Dara + Cody ✅. Verified: 87 open / 37 Union Coop.                                                                                                                                |
| `prd022_d3b_add_purchase_order_lines`        | 1, 4, 8, 12 | ✅ Applied to prod | D3b. Owner-only `add_purchase_order_lines(text, jsonb)` appends to an OPEN PO (reuses po_number, same blocked/qty validation, regenerates driver notes, audits, refuses closed POs). 2nd/final INSERT writer on purchase_orders (disjoint from create by precondition). Dara (Option B) + Cody ✅. Verified: owner append + blocked-reject + non-owner-reject + closed-refuse, 0 leaks. |
| `prd022_d3b_widen_proc_event_type`           | 12          | ✅ Applied to prod | D3b companion. Widened `procurement_events_event_type_check` to permit 'lines_appended' (DROP+ADD, additive). Caught by D3b verification test.                                                                                                                                                                                                                                          |

## PRD-021 — lift Ritz Cracker decommission (APPLIED 2026-06-10)

| Migration name                              | Article(s)     | Status             | Note                                                                                                                                                                                                                                                                  |
| ------------------------------------------- | -------------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd021_abandon_intent_service_role_bypass` | 1, 4, 5, 8, 12 | ✅ Applied to prod | `abandon_intent` role guard gained the standard service-role bypass (`v_user_id IS NOT NULL AND NOT role-ok`) so service-role can close intents. Verbatim body otherwise. Used to abandon Ritz decommission intent `ba1ef467`; Loacker `9e117317` untouched. Cody ✅. |

## PRD-1 / PRD-3 Procurement Brain v3 (APPLIED 2026-06-10)

| Migration name                               | Article(s)   | Status                         | Note                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| -------------------------------------------- | ------------ | ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phasef_proc_block_decommissioned_po_writes` | 1, 4, 12     | ✅ Applied to prod             | PRD-1 guardrail. Block ordering of decommissioned/never-order products. New helper `boonz_product_block_reason(uuid)` + guard in `create_purchase_order` (all roles) and `edit_purchase_order_line` (all roles except superadmin) + read-only view `v_procurement_blocked_products`. No service-role bypass (safety rail). Both writers rebuilt from **live** bodies (no PRD-002 revert). Cody ✅. Tested: blocked Ritz rejected on create+edit, control orderable, 0 leaked rows.                        |
| `phasef_proc_demand_pod_level_rpc`           | 4, 12        | ✅ Applied to prod             | PRD-3 pod-level demand reader. New read-only `get_procurement_demand_pod(integer, text)` — pod_product rows (sales/velocity/ctx/forecast + `pod_breakdown` jsonb with PRD-1 block_reason) BEFORE mix_weight trickle-down. Reconciles with `get_procurement_demand`. No writes. Cody ✅. Powers PRD-2 "Pod demand" sub-tab.                                                                                                                                                                                |
| `phasef_proc_po_rls_writes_rpc_only`         | 1, 3, 12     | 🟡 STAGED (apply at FE deploy) | PRD-1b. DROPs `warehouse_manage_pos` (ALL) on `purchase_orders` so authenticated is SELECT-only; all writes via DEFINER RPCs + service_role. Closes the FE direct-insert bypass of the PRD-1 guardrail. Both FE call sites rerouted to `create_purchase_order` (typechecks). Cody ✅ with sequencing condition: **FE reroute must deploy to Vercel before apply** (CS chose Hold). Safe: force_rls=false, postgres-owned DEFINER writers bypass RLS.                                                      |
| `phasef_proc_merge_union_coop_dupe`          | 1, 8, 12     | ✅ Applied to prod             | PRD-5 data hygiene. Merged dupe supplier `3cec0b3a` (Inactive) into canonical `31b6355d`. No deletes: 19 PO lines repointed (each audited pre-mutation), 2 supplier_products repointed, 16 overlap retired in place, Coco Water preferred promoted, dupe renamed + kept Inactive. CS row-diff sign-off; Cody ✅. Verified: dupe 0 lines/0 active/0 preferred; canonical +19 lines/+2 products; 0 multi-preferred; 20 audit rows.                                                                          |
| `phasef_proc_shelf_stock_daily_snapshot`     | 2, 4, 11, 12 | ✅ Applied to prod             | PRD-4b. New `shelf_stock_daily` analytics table + DEFINER writer `snapshot_shelf_stock()` (sole write path, idempotent) + pg_cron `shelf_stock_daily_snapshot` 20:30 UTC. RLS authenticated-SELECT/service-ALL. Accrues days-in-stock history for a future availability-adjusted forecast. First run: 301 rows / 20 machines. Cody ✅. **Forecast v4 (4a) was NOT applied** — 5-window replay showed the spec blend is worse than flat-14d; revisit availability-adjusted velocity once snapshots accrue. |

## PRD-020 — 08-09 Jun refills + 05-06 Jun close-out (APPLIED 2026-06-10)

| Migration name                          | Article(s)  | Status             | Note                                                                                                                                                                                                                       |
| --------------------------------------- | ----------- | ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd020_retro_log_dedup_include_expiry` | 1, 4, 8, 12 | ✅ Applied to prod | `log_retroactive_refill_visit` dedup key gained `expiry_date IS NOT DISTINCT FROM v_expiry` so distinct-expiry batches don't false-collapse. Cody ✅. All other data writes used existing canonical RPCs (no further DDL). |

## PRD-REFILL-V2 — engine rebuild (STAGED 2026-06-08, per-item CS apply gate)

Files staged in `supabase/migrations/`; live bodies in `docs/prds/refill-pipeline/_staging/live/`. NOTHING applied to prod. Each engine writer is diff-gated and needs CS green light (Hard Rule 10).

| Item | Migration file                                             | Article(s)         | Status                               | Dry-run proof                                                     |
| ---- | ---------------------------------------------------------- | ------------------ | ------------------------------------ | ----------------------------------------------------------------- |
| 1    | `20260608120000_refillv2_engine_add_pod_v15_fill_to_cap`   | 1, 4, 5, 8, 12, 14 | 🟡 Staged, ready for CS sign-off     | AC1 284/284 sellers >=95% (100% engine fill); AC2 137 dead tagged |
| 3    | `20260608121000_refillv2_resolve_driver_intent_translator` | 4 (INVOKER, read)  | 🟡 Staged                            | A6 6/7 resolved, 1 flagged, none dropped                          |
| 5    | `20260608123000_refillv2_pick_machines_v8_p1_restock`      | 1, 4, 5, 8, 12     | 🟡 Staged, ready for CS sign-off     | A8 same 28 picked, P1 18->12, 0 warehouses                        |
| 2    | engine_swap_pod v9_5 -> v10 (file pending CS forks)        | 1, 4, 5, 8, 12, 14 | ⏳ Design+spec — 2 CS decisions      | —                                                                 |
| 6    | stitch_pod_to_boonz v18 overlay (file pending CS fork)     | 1, 4, 5, 8, 12     | ⏳ Design+spec — overlay semantic    | —                                                                 |
| 4    | expiry rule (emergent in v15 + FEFO)                       | n/a                | ⏳ Note                              | —                                                                 |
| 7    | 8pm cron chain (build_draft_for_confirmed)                 | 1, 4, 8            | ✅ Confirmed correct (no change yet) | chain stops at draft; no auto-stitch                              |

## Phase A — Perimeter

| Step   | Migration name                                          | Article(s)                 | Status             | Applied    | Rollback ready      |
| ------ | ------------------------------------------------------- | -------------------------- | ------------------ | ---------- | ------------------- |
| A.1    | `phaseA_a1_rls_planogram_pia`                           | 2, 7                       | ✅ Applied         | 2026-04-25 | Yes — see CHANGELOG |
| A.2    | `phaseA_a2_deprecate_rename_machine_legacy`             | 13                         | ✅ Applied         | 2026-04-25 | Yes — see CHANGELOG |
| A.3    | `phaseA_a3_audit_log_infra`                             | 7, 8                       | ✅ Applied         | 2026-04-26 | Yes — see CHANGELOG |
| A.4    | `phaseA_a4_install_audit_triggers`                      | 1, 8                       | ⚠️ Applied (10/16) | 2026-04-26 | Yes — see CHANGELOG |
| A.5a   | `phaseA_a5a_patch_upsert_daily_sales_and_split_matview` | 1, 4, 8, 9, 11, 12         | ✅ Applied         | 2026-04-26 | Yes — see CHANGELOG |
| A.5a.1 | `phaseA_a5a_followup_allow_refresh_op`                  | 12 (forward-only widening) | ✅ Applied         | 2026-04-26 | Yes — see CHANGELOG |
| A.5b   | `phaseA_a5b_part{1..4}_of_4_*` (4 migrations)           | 1, 2, 4, 8                 | ✅ Applied         | 2026-04-26 | Yes — see CHANGELOG |
| A.6    | `phaseA_a6_governance_yml_warn_mode`                    | 15                         | ⏳ Pending         | —          | —                   |
| A.7    | `phaseA_a7_commit_constitution_to_repo`                 | 15                         | ✅ This commit     | 2026-04-25 | n/a (file-only)     |

Legend: ⏳ pending, ⏸️ blocked, ✅ applied, ⚠️ applied with caveats, ❌ rolled back.

**A.4 caveat:** Applied to 10 of 16 originally-listed protected entities. The other 6 are deferred to **A.4.b** pending the Article 15 amendment that reconciles Constitution Appendix A with live schema names (`daily_sales/sales_lines → sales_history`, `sales_aggregated → sales_history_aggregated`, `dispatch_plan → refill_dispatch_plan`, `dispatch_lines → refill_dispatching`, `warehouse_inventory_audit_log → inventory_audit_log`; `slots` does not exist and will be removed from the protected list). See CHANGELOG entry for full breakdown.

**A.5b note:** Patches the 24 remaining canonical SECURITY DEFINER writers (22 plpgsql + 2 SQL→plpgsql conversions) to set `app.via_rpc='true'` and `app.rpc_name='<fn>'` via `PERFORM set_config(...)` as the first statements after `BEGIN` (A.5a precedent). Function-level `SET app.via_rpc='true'` was the Cody-recommended shape but was rejected by Supabase (`permission denied to set parameter "app.via_rpc"`) because custom GUCs aren't pre-registered at the role/db level. Audited the 4 nested-DEFINER call sites (`auto_sanity_check→add_sanity_increment`, `receive_all_dispatches_for_machine→receive_dispatch_line`, `return_all_dispatches_for_machine→return_dispatch_line`, `upsert_sales_lines→refresh_sales_aggregated`) and confirmed none write to a protected entity AFTER the inner call returns, so the SET LOCAL leak does not corrupt the audit trail. Also enabled RLS on `refill_dispatch_plan` (Article 2 — closes Amendment 001's RLS gap) with a SELECT-only policy for `authenticated`; service_role bypasses RLS, which is how canonical RPC writes still reach the table. **A.5c follow-up filed**: re-patch all 25 A.5a/A.5b writers to function-level SET once `app.via_rpc` is pre-registered at db level (requires `ALTER DATABASE postgres SET app.via_rpc=''` as superuser).

## Boonz Master — Operational Intelligence Layer (2026-04-30)

| Migration name                | Article(s)        | Status     | Applied    | Notes                                                                                                                                                                                            |
| ----------------------------- | ----------------- | ---------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `boonz_master_foundation`     | 2, 3, 12          | ✅ Applied | 2026-04-30 | New tables: `boonz_context`, `planned_swaps`, `machine_field_notes`. Alter: `product_mapping.mix_weight`. Non-protected entities — no Appendix A addition required.                              |
| `add_approve_refill_plan_rpc` | 1, 3, 4, 5, 8, 12 | ✅ Applied | 2026-04-30 | New canonical writer `approve_refill_plan(date, text[])`. Flips `refill_plan_output.operator_status` pending→approved + writes `refill_dispatching`. Roles: operator_admin, superadmin, manager. |

## Refill App Issues — Phase 1 (2026-05-04)

All migrations strictly additive — no live-flow behavior change today. Behavior changes (trigger binding, FE deploys, conserve_split swap, backfills) deferred to tonight's post-dispatch deploy window.

| Migration name                                     | Article(s)                     | Status                       | Applied    | Notes                                                                                                                                                                                                                                                                 |
| -------------------------------------------------- | ------------------------------ | ---------------------------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `m1_warehouse_inventory_status_proposal_table`     | 1, 2, 3, 6 (revised), 7, 8, 12 | ✅ Applied                   | 2026-05-04 | New table + RLS + audit trigger for the propose-then-confirm pattern. Adds `warehouse_inventory_status_proposal` to Appendix A protected entities (via Amendment 002).                                                                                                |
| `m2_confirm_reject_warehouse_status_proposal_rpcs` | 1, 4, 5, 8                     | ✅ Applied                   | 2026-05-04 | Two new canonical writers: `confirm_warehouse_status_proposal(uuid, text)`, `reject_warehouse_status_proposal(uuid, text)`. Manager-confirmation gate for `warehouse_inventory.status` flips; drift detection marks proposal `superseded` when live row diverges.     |
| `m3_propose_status_change_functions_unbound`       | 1, 4, 6 (revised), 8, 9        | ✅ Applied (function bodies) | 2026-05-04 | Two trigger functions created but **NOT BOUND** to `warehouse_inventory`. Binding migration `m3b` runs post-dispatch tonight. Functions write only to the proposal table; never UPDATE `warehouse_inventory.status`.                                                  |
| `m4_mark_picked_up_rpc`                            | 1, 3, 4, 5, 8                  | ✅ Applied                   | 2026-05-04 | New canonical writer `mark_picked_up(uuid[])` — replaces direct `refill_dispatching` UPDATE from `field/pickup/page.tsx`. RPC dormant until tonight's FE deploy wires it.                                                                                             |
| `m5_diagnostic_views`                              | 9, 12                          | ✅ Applied                   | 2026-05-04 | Three read-only views: `v_pending_status_proposals`, `v_orphan_dispatch_machine_names` (Issue #13: 4 orphan names), `v_machines_without_shelf_config` (2 rows, both benign — `include_in_refill=false`). `security_invoker=true` so RLS on underlying tables applies. |
| `m3b_bind_warehouse_inventory_propose_triggers`    | 6 (revised), 8                 | ⏳ Pending                   | —          | **Tonight, post-dispatch.** Binds `propose_inactivate_on_zero_stock` AFTER UPDATE on `warehouse_inventory` and `propose_reactivate_on_stock_return` AFTER UPDATE/INSERT on `warehouse_inventory`.                                                                     |

## F.0 — Engine redesign (2026-05-11, ongoing)

Phase F is the proper 3-layer rebuild of the refill engine per CS spec (see `REFILL_BRAIN_REDESIGN.md`). Layer A (strategic upstream, pod_product), Layer B (refill engine, pod_product, Stages 1 + 2a/2b/2c), Layer C (boonz stitching). Two CS gates between layers. Each stage is a callable pitstop. Stage 1 lands first as the smallest additive piece — pure read of existing state plus a new pitstop table.

| Migration name | Article(s) | Status | Applied | Notes |
| ------------------------------------------------------- | -------------- | ---------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `phaseF_stage1_machine_picker` | 1, 4, 5, 8, 12 | ✅ Applied | 2026-05-11 | New pitstop table `machines_to_visit` (PK: plan_date, machine_id; status FSM picked/superseded; FK to machines; audit trigger via `audit_log_write('machine_id')`; RLS read-all, no-direct-writes). New canonical writer `pick_machines_for_refill(p_plan_date)` — reads machines, slot_lifecycle, refill_dispatching history, strategic_intents, v_live_shelf_stock. Computes 5 pick reasons (health ≥30% bad slots, stale ≥7d, empty ≥20%, intent ≥1 active, ramping). Priority score 0..100 weighted sum. Sibling expansion via `venue_group`/`building_id` at lower thresholds. Idempotent — re-running supersedes prior pick. DEFINER, role-gated on `operator_admin`, sets `app.via_rpc`. |
| `phaseF_stage1_machine_picker_v3_drop_and_recreate` | 12 | ✅ Applied | 2026-05-11 | Forward-only fix. Initial deploy renamed RETURNS TABLE columns to `out_*` to avoid plpgsql var-conflict; `CREATE OR REPLACE` rejected the signature change, so this drops + recreates. |
| `phaseF_stage1_machine_picker_v4_intent_count_fix` | 12 | ✅ Applied | 2026-05-11 | Forward-only fix. First smoke test showed every machine flagged "intent" because `COUNT(*)` with `LEFT JOIN strategic_intents` was counting the base row even with no match. Switched to `COUNT(si.intent_id)` (and same fix in `slot_health` + `empty_state`). Re-test on 2026-05-12: 24 machines picked across 8 route clusters with correct reasons. **Open nit (#17):** sibling-only picks get pri_score=0 because sibling pass doesn't re-score — defer to Stage 1 v5. |
| `phaseF_stage2_pitstop_tables_v2` | 1, 2, 8, 12 | ✅ Applied | 2026-05-11 | Three new pitstop tables: `pod_refills` (Stage 2a output, PK plan_date+machine_id+shelf_id+pod_product_id), `pod_swaps` (Stage 2b output, uuid PK, pair-linked with optional `pod_product_id_in` NULL for M2W returns, optional `linked_intent_id` FK), `pod_refill_plan` (Stage 2c consolidated final, status FSM draft → approved → stitched | superseded with approved_at/approved_by/stitched_at). All three tables ENABLE RLS read-all (no direct-write policies so DEFINER is the only path) + audit trigger via `audit_log_write`. Plus helper view `v_warehouse_pod_rollup` (SUM warehouse_inventory.warehouse_stock across boonz variants of each pod_product where product_mapping.status='Active' AND wi.status='Active'; surfaces total_stock + active_batches + earliest_active_expiry). Reads only — Layer A E-2 + Layer B Stage 2 consume; Layer C does NOT use this (boonz-level WH read happens in Stage 3 directly). v1 of this migration failed on `wi.current_stock` (column is `warehouse_stock`); v2 corrected. |
| `phaseF_stage2a_engine_add_pod_v3_max_stock_from_weimi` | 1, 4, 8, 9, 12 | ✅ Applied | 2026-05-11 | Stage 2a "More of the Best" canonical writer `engine_add_pod(p_plan_date, p_days_cover=14)`. Reads `machines_to_visit` (Stage 1 output) + `slot_lifecycle` (signal + velocity_30d) + `pod_inventory` aggregated at (machine_id, shelf_id) for current_stock + `v_shelf_max_stock` (new helper view normalizing shelf_code "A01" ↔ slot_name "A1" and pulling max_stock from `v_live_shelf_stock`) + `v_warehouse_pod_rollup`. Signal-aware sizing: **STAR/DOUBLE DOWN** fill-to-max; **KEEP GROWING/KEEP** CEIL(velocity_30d × days_cover); **RAMPING/WATCH** CEIL(velocity_30d × 7) capped at half-max; **WIND DOWN/ROTATE OUT/DEAD** skipped (Stage 2b's territory). All qty capped by (max-current) and WH pod rollup. v1 failed PK collision because v_live_shelf_stock keyed on (machine_id, pod_product_id) fans out when same product is on multiple shelves; v3 switched to pod_inventory aggregated at (machine_id, shelf_id) which is the slot grain. Default fallback `v_default_max=10` when neither shelf_configurations.max_capacity nor v_live_shelf_stock.max_stock has a value. **Smoke test 2026-05-12:** 124 REFILL rows inserted across 24 picked machines in 417ms. DOUBLE DOWN fills empty shelves fully; KEEP/KEEP GROWING uses velocity formula. Idempotent — deletes prior rows for plan_date then re-inserts. |
| `phaseF_stage2c_engine_finalize_pod` | 1, 4, 5, 8, 12 | ✅ Applied | 2026-05-11 | Stage 2c canonical writer `engine_finalize_pod(p_plan_date)`. Reads pod_refills + pod_swaps, writes pod_refill_plan (status='draft'). Applies R4 (swap-touched shelves invalidate refills on same shelf) via swap_shelves CTE anti-join. Emits four action types per source: REFILL (from pod_refills not swap-touched), REMOVE (from pod_swaps qty_out), ADD_NEW (from pod_swaps qty_in where not NULL), M2W (from pod_swaps where pod_product_id_in IS NULL). R7 60% shelf cap surfaced as diagnostic only (no hard block at Stage 2c — fail-safe lives at Stage 3 if needed). Idempotent — supersedes prior drafts for plan_date. Diagnostics return: rows_finalized, refills_in, swaps_in, r4_overruled_refills, r7_machines_over_60pct, duration_ms. **Smoke test 2026-05-12:** 124 draft rows finalized (Stage 2b empty so 0 swaps merged in). |
| `phaseF_gate_rpcs_approve_and_confirm` | 1, 4, 5, 8, 12 | ✅ Applied | 2026-05-11 | Three Gate RPCs. **Gate 1 approve** `approve_pod_refill_plan(p_plan_date, p_machine_names text[] DEFAULT NULL)` — flips draft → approved with approved_at + approved_by; optional machine filter for partial approval. **Gate 1 reject** `reject_pod_refill_rows(p_plan_date, p_machine_names, p_reason)` — flips draft → superseded with rejection_reason captured in reasoning jsonb; reason mandatory. **Gate 2 confirm** `confirm_stitched_plan(p_plan_date)` — flips approved → stitched with stitched_at; called by Stage 3 Stitch after refill_plan_output rows are written. All three DEFINER, role-gated on operator_admin, set app.via_rpc. **End-to-end test:** Stage 1 (24 picked) → Stage 2a (124 refills) → Stage 2c (124 drafts) → Gate 1 partial (1 machine ADDMIND) → Gate 1 fleet (remaining 123) → Gate 2 confirm → 124 stitched. |

### F.0 day 3 (2026-05-18) — Conductor, Gate 0, edit RPCs, picker quality

Gen 3 conductor (`boonz-master-3`) lands as the single natural-language interface; old `boonz-master` archived as `boonz-legacy`. Three migration workstreams + a data-hygiene backfill + cron change. Constitution Amendment 003 filed in parallel formally adding Phase F entities to Appendix A.

| Migration name                                    | Article(s)        | Status     | Applied    | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ------------------------------------------------- | ----------------- | ---------- | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phaseF_edit_rpcs_with_audit`                     | 1, 2, 4, 7, 8, 12 | ✅ Applied | 2026-05-18 | New canonical writers `edit_pod_refill_row(plan_date, machine_id, shelf_id, pod_product_id, action, new_qty, reason, conductor_session)` (qty-only edit, 5-tuple PK addressing, refuses if linked refill_plan_output past pending, appends to `reasoning` jsonb), `stop_pod_refill_row(...)` (thin wrapper, qty→0), `restitch_after_edits(plan_date, dry_run)` (scoped re-stitch — touches only operator_status=pending boonz rows, delegates to `stitch_pod_to_boonz` for the write). Plus read-only INVOKER `find_substitutes_for_shelf(plan_date, machine_id, shelf_id, anchor_pod_product_id, top_n, aggressiveness_pct)` — Pearson top-N with a 0–100 aggressiveness knob (0–33 per-machine; 34–66 + loc_type; 67–100 + category fallback). New table `pod_refill_plan_audit` with ENABLE RLS + `rls_no_update` + `rls_no_delete` + `select_authenticated` (Article 7 append-only). New columns `pod_refill_plan.edited_at, edited_by`. Generic audit trigger already on `pod_refill_plan` so Article 8 covered. **Scope deferred to v2**: changing pod_product_id or action requires DELETE+INSERT because they're part of the 5-tuple PK — `swap_pod_refill_row` TODO. Cody-reviewed with 7 findings, all addressed pre-apply. Versions v2..v6 are forward-only column-name fixes discovered during smoke tests.                                                                                                                                                                   |
| `phaseF_gate_zero_machines_to_visit`              | 1, 4, 8, 12       | ✅ Applied | 2026-05-18 | Gate 0 — CS confirms picked machine list before Stage 2 can run. New columns on `machines_to_visit`: `confirmed_at`, `confirmed_by`, `dropped_at`, `dropped_by`, `dropped_reason`, `manual_pick_reason`. Three canonical writers: `confirm_machines_to_visit(plan_date)` (flips picked → confirmed_at=now()), `unpick_machine_to_visit(plan_date, machine_id, reason)` (status→cs_dropped + dropped_at/by/reason), `pick_machine_manually(plan_date, machine_id, reason)` (INSERT with status=cs_added + confirmed_at=now() auto-confirm). Helper `_assert_gate_zero(plan_date)` raises `Gate 0 not passed: N machine(s) picked but unconfirmed` if any `status='picked' AND confirmed_at IS NULL` rows for the date. Patched `engine_add_pod` and `engine_swap_pod` to `PERFORM public._assert_gate_zero(p_plan_date)` near the top, and widened `WHERE status='picked'` to `WHERE status IN ('picked','cs_added')` so CS-manual additions feed Stage 2. All three writers role-gated on operator_admin/superadmin, set `app.via_rpc` GUC.                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `phaseF_gate_zero_status_constraint_and_backfill` | 5, 12             | ✅ Applied | 2026-05-18 | Caught a latent bug pre-deploy: `machines_to_visit.status` CHECK constraint only allowed `('picked','superseded')`, which would have made `unpick_machine_to_visit`/`pick_machine_manually` fail on first call. Widened to `('picked','cs_added','cs_dropped','completed','superseded')`. Same migration backfills 52 historical `picked` rows (plan_date < today) to `status='completed'`, `confirmed_at=picked_at`, `confirmed_by='system_backfill_2026-05-18'` so the conductor's "what's pending Gate 0" query doesn't dredge stale rows forever. CS-approved Decision 1 inline.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `phaseF_picker_v2_quality_fixes`                  | 4, 12             | ✅ Applied | 2026-05-18 | Four Stage-1 false-positive fixes to `pick_machines_for_refill`: (1) `intent_state` JOIN on `slot_lifecycle.pod_product_id = strategic_intents.scope_pod_product_id` so intents only credit a machine if the affected pod is actually deployed there (was counting fleet-wide intents against every machine — every machine showed `active_intents=3`); (2) clamp `days_since_visit` to `[0, 365]` (was producing `999` and `-26867` from NULL or corrupted future dates); (3) velocity floor — `primary_picks` now requires `units_last_7d >= 5 OR is_ramping OR active_intent_count > 0`, sibling picks require `>= 3`. New `sales_recent` CTE + new `machines_to_visit.units_last_7d` column for transparency; (4) `is_ramping` window 30 days → 14 days so older "ramping" machines age out and AMZ-installed-yesterday machines still count. ON CONFLICT clears `confirmed_at`/`confirmed_by` so any new pick run requires a fresh Gate 0.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `phaseF_picker_v3_visit_attempts_count`           | 4, 12             | ✅ Applied | 2026-05-18 | One predicate change: `last_visit` CTE now reads `MAX(dispatch_date) WHERE picked_up=true OR returned=true` (was picked_up=true only). Reason: the 23:59 Dubai `eod_auto_release_unpicked` cron flips real visits to `returned=true` when the driver app fails to set `picked_up=true`, so EOD-released visits were being mis-flagged as "no visit attempt" → "stale" forever. Smoke test 2026-05-19: MPMCC-1054 dropped `[stale, intent]` 35 → `[intent]` 15 with days_since_visit 36→5; MPMCC-1058 dropped to `[sibling]` 0; IFLYMCC-1024 still correctly flags stale (genuinely no dispatch since 2026-04-13).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `phaseF_backfill_mpmcc_2026-05-14_pragmatic`      | 12 (data-fix)     | ✅ Applied | 2026-05-18 | DO-block backfill for 17 stuck dispatch rows on MPMCC-1054 (10) + MPMCC-1058 (7) from 2026-05-14. Root cause: driver loaded both machines but driver-app sync left `picked_up=false`, then 23:59 Dubai EOD `auto_release_unpicked_eod` ran `return_dispatch_line` on each, bouncing `warehouse_stock` back. Pod_inventory never got credited despite real refill. CS chose **B-pragmatic** path (per Stax follow-up #67 on driver-app sync): pod_inventory aligned to physical reality, WH untouched (overstated for now, WEIMI sweep #68 will reconcile). For the 15 Refill/Add-New rows the DO block clears `returned=false` then calls `receive_dispatch_line(dispatch_id, quantity)` (drains `consumer_stock` where reservation exists, inserts pod_inventory row, no WH mutation because consumer pool already drained by original return). For 1 Pepsi Remove row, manually sets `picked_up=true, returned=false, item_added=true, filled_quantity=13` + marks pod_inventory rows for Pepsi on shelf Inactive — skipped WH credit because EOD bounce already produced correct +13 for a Remove. For 1 orphan Popit Mix row (never packed), set `include=false`. Verified: 16 active rows now `picked_up=true, returned=false, item_added=true, include=true`; pod_inventory shows +42 across MPMCC-1054 (Haribo 2, M&M 2, Maltesers 2, Popit 11, Ritz 10, Sun Blast 9, VOX Lollies 6) and +18 across MPMCC-1058 (Aquafina 6, Krambals 2, Leibniz Zoo 1, Skittles 2, VOX Lollies 7). |

**Cron change.** `phaseF_stage1_prep_8pm_dubai` scheduled `0 16 * * *` UTC = 20:00 Dubai daily (jobid=13) running `pick_machines_for_refill(CURRENT_DATE + 1)`. No autonomous engine runs — Stage 2 / Gate 1 / stitch / push-to-drivers all driven by CS via `boonz-master-3`. CS-decided Option C+. Old engine cron was already absent from pg_cron, nothing disabled.

**Data hygiene.** `UPDATE machines SET include_in_refill=false WHERE official_name='WH1-2002-0000-W0'` — warehouse facility shouldn't be in the refill route.

### F.dispatch_edit (2026-05-19) — Driver / WH manager editing on refill_dispatching

Following the VOX A07 Ice Tea collision and IFLY-1024 Coconut/7up incident, three migrations to (a) fix `receive_dispatch_line` against the active-shelf unique index, (b) extend `refill_dispatching` with editing + source-traceability columns, (c) add 6 canonical edit writers. Dara-designed, Cody-revised (4 revisions: state-machine guards in RPCs, restore_dispatch_row rejected, Amendment 003 expanded, Amendment 005 filed).

| Migration name                                       | Article(s)         | Status     | Applied    | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| ---------------------------------------------------- | ------------------ | ---------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phaseF_receive_dispatch_line_upsert_active_pod_row` | 1, 4, 8, 12        | ✅ Applied | 2026-05-19 | `receive_dispatch_line` Refill/Add New / Add path now archives existing Active pod*inventory row(s) for the same (machine, shelf, boonz_product) via a CTE, sums their `current_stock`, takes MIN expiration_date for FEFO worst-case, then INSERTs the merged row. Fixes the `idx_pod_inv_active_shelf` UNIQUE conflict that blocked drivers refilling shelves with leftover stock. Smoke test on VOX A07 Ice Tea Peach (3 + 10 = 13 units after merge, old row Inactive with `merged_into_dispatch*\*` reason).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `phaseF_dispatch_editing_schema`                     | 1, 2, 7, 8, 12, 15 | ✅ Applied | 2026-05-19 | 11 new columns on `refill_dispatching`: `original_quantity / original_boonz_product_id / original_shelf_id` (nullable; legacy data has NULLs); `edit_count int DEFAULT 0`; `last_edited_by / last_edited_by_role / last_edited_at`; `source_kind text DEFAULT 'unknown'`; `source_warehouse_id / source_machine_id`; `created_by_edit boolean`. Type-conditional `source_consistency` CHECK (NOT VALID so legacy passes). 5 FKs (boonz / shelf / user_profiles / warehouses / machines) with appropriate ON DELETE rules. Backfill: 29,715 rows got `original_quantity = quantity`; 29,388 got real `source_kind`. New protected table `refill_dispatching_edit_log` with append-only RLS + generic audit trigger. 4 partial indexes per table for FE hot paths. Amendment 003 expanded to 11 entities.                                                                                                                                                                                                                                                                                                                                                                                                               |
| `phaseF_dispatch_editing_rpcs`                       | 1, 4, 5, 7, 8, 12  | ✅ Applied | 2026-05-19 | Six new canonical writers: `edit_dispatch_qty`, `edit_dispatch_shelf` (driver-only), `edit_dispatch_product` (driver-only), `add_dispatch_row`, `remove_dispatch_row` (WH-manager-only), `set_dispatch_source`. All SECURITY DEFINER, role check against `user_profiles.role` (not parameter), set `app.via_rpc` / `app.rpc_name` GUCs, validate inputs (FK existence, enum, range), `SELECT FOR UPDATE` on target row, state-machine guards per Cody R1 (item_added=false universally; picked_up=true for driver edits; picked_up=false for remove). M2M source hard-refuses if source machine has no Active pod_inventory > 0 for the product (per Cody open question). `restore_dispatch_row` rejected by Cody R2 — rewriting `item_added=true` history is dangerous; post-receive corrections go through `adjust_pod_inventory` instead.                                                                                                                                                                                                                                                                                                                                                                          |
| `phaseF_picker_v5_sibling_score`                     | 4, 12              | ✅ Applied | 2026-05-19 | Sibling-only picks in `pick_machines_for_refill` were inheriting `priority_score=0` from `with_score` (severity='skip'). v5 computes a soft sibling score in `final_picks` using the half-threshold conditions that pulled the sibling in: empty_shelves_count>0 → 8, fill_pct<70 → 6, days_since_visit>=7 → 5, expired_skus_7d>0 → 6, active_intent_count>0 → 5. Max 30, ranks below 'medium' (25). Closes task #17.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `phaseF_picker_v7_velocity_shelf_reweight`           | 1, 2, 4, 5, 8, 12  | ✅ Applied | 2026-06-02 | Reweight of `pick_machines_for_refill` toward velocity + shelf depletion (CS request). Replaces the fill%/expiry-dominant severity CASE with a two-tier model: **P1_RESTOCK** (any empty shelf = 50pts hard top; selling-machine low runway; <25% shelf on a seller) and **P2_MAINTAIN** (dead slots / ≥14d stale / expiry / intent, small weights). Adds two additive columns on `machines_to_visit`: `service_track` (NOT NULL DEFAULT 'main', CHECK main/vox) + `priority_tier` (nullable, CHECK P1_RESTOCK/P2_MAINTAIN). VOX scored in same pass but `service_track='vox'`, ordered below all main rows (parallel daily-on-the-spot track, FE renders below a dashed separator). New CTE `shelf_u25` aggregates `v_live_shelf_stock` for <25% non-empty shelves. Legacy `severity`/`priority_score` kept populated via tier→band map; `engine_add_pod`/`engine_swap_pod` verified to gate only on `status IN ('picked','cs_added')`. Dara-designed, Cody ⚠️→all 3 revisions cleared. Verified: 2026-06-03 re-pick = 30 machines (22 main + 8 vox), AMZ-1038 promoted old-"high"→#1 P1 (3 empty, 81 u/wk), ~2.3s runtime. New partial index `idx_mtv_plandate_track_tier_score`. Rollback in CHANGELOG 2026-06-02. |

**Amendment 005 filed** (`09_amendment_005_narrow_concern_canonical_writers.md`) — revises Article 1 to allow multiple narrow-concern canonical writers on high-traffic protected entities. Doc-only commit, no SQL. Pending CS ratification.

### F.0 day 3 PM (2026-05-18) — Machine-aware product_mapping JOIN fixes

Discovered during the reconciler design pass: `product_mapping` is correctly modeled as per-machine (38 machines × ~140 products = ~5,500 rows; UNIQUE constraint on `(pod_product_id, boonz_product_id, machine_id)` enforces correctness), but production queries that JOIN pm without scoping on `machine_id` silently fan out by N× where N = per-machine mappings for the SKU (~24× average). Two HIGH-severity fixes shipped; three MEDIUM/LOW queued for tomorrow.

| Migration name                                           | Article(s) | Status     | Applied    | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| -------------------------------------------------------- | ---------- | ---------- | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phaseF_fix_v_warehouse_pod_rollup_machine_aware_dedupe` | 12         | ✅ Applied | 2026-05-18 | View definition rewrite. Subquery `pm_distinct AS (SELECT DISTINCT pod_product_id, boonz_product_id FROM product_mapping WHERE status='Active')` before the join to warehouse_inventory. `total_stock` no longer multiplied by per-machine pm count. Before/after on 10 high-mapping pods: every value dropped exactly 24× (e.g. Soft Drinks Mix 3,216→134; Vitamin Well 1,200→48). Downstream consumers (`engine_add_pod` wh_avail cap, `engine_swap_pod` `wpr.total_stock>0` filter, ops queries) automatically pick up correct numbers. SECURITY INVOKER view, no DEFINER changes — no Cody review needed.                                                                                                                                                                                                                                                                                                                                               |
| `phaseF_stitch_v8_machine_aware_pm_joins`                | 1, 4, 12   | ✅ Applied | 2026-05-18 | Two CTEs inside `stitch_pod_to_boonz` fixed. **`remove_lines`**: switched `JOIN public.product_mapping pm ON pm.boonz_product_id=pil.boonz_product_id AND pm.pod_product_id=a.pod_product_id AND pm.status='Active'` to an `EXISTS` clause with `(pm.machine_id IS NULL OR pm.machine_id = a.machine_id)` — no fan-out, just a filter validating the pod→boonz mapping. **`demand`** (procurement alerts): added `DISTINCT ON (plan_date, machine_id, shelf_id, pod_product_id, pm.boonz_product_id) ORDER BY (pm.machine_id = prp.machine_id) DESC NULLS LAST, pm.is_global_default DESC` so per-machine wins over global when both match. `pull_raw` and `m_raw` were already machine-aware (use the same ROW_NUMBER pattern from Phase F day 2) and left unchanged. Engine version flipped `v7_sequential_redist` → `v8_machine_aware_pm`. Smoke test against the 2026-05-12 approved plan: 265 lines built, 38 deviations, 47 procurement alerts, 1.1s. |

**Tasks queued for tomorrow (not yet applied):**

| Task                                        | Severity         | Target                                                                                                                                  |
| ------------------------------------------- | ---------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| #72 — `engine_swap_pod` qty subqueries      | MEDIUM           | Pass 1 + Pass 2 qty_out/qty_in subqueries do `JOIN v_pod_inventory_latest ⋈ product_mapping` without machine scoping. Inflates the SUM. |
| #73 — `find_substitutes_for_shelf`          | MEDIUM (display) | wh_stock_units column returned to CS/FE is inflated by same fanout.                                                                     |
| #17 — sibling-only picks `priority_score=0` | LOW              | Phase F day 1 nit. Sibling pass doesn't re-score; minor display issue.                                                                  |

**What this changes in production going forward.** `engine_add_pod` will hit `clamp_reason='capped_by_wh'` correctly on tight-stock products (was previously rare because wh_avail was 24× inflated). Cross-fleet allocations stop exceeding real WH. Stitch REMOVE/M2W output drops from N× duplicates to 1× per (shelf, boonz variant). Procurement alerts sharpen and stop double-counting.

### F.refill-engine-fix (2026-05-23) — Decouple WH, performance floor, diagnostics

PRD `docs/prd-refill-engine-fix.md`. Three-phase rebuild after the 23-May session produced 3 committed rows out of 96 generated. Guiding principle: **inventory does not gate refill planning** — WH stock becomes informational, not a quantity cap. Cody-reviewed Phase 1 + Phase 2 (Phase 3 fast-path approved as read-only helper).

| Migration name                             | Article(s)     | Status     | Applied    | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ------------------------------------------ | -------------- | ---------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `refill_engine_p1_decouple_wh_fanout_diag` | 1, 4, 6, 8, 12 | ✅ Applied | 2026-05-23 | Phase 1 (P0). `engine_add_pod` v9 — drops WH-stock cap from `LEAST(...)`; `wh_avail`+`wh_warning` move to informational `reasoning` JSONB. Removes `clamp_reason ∈ {skipped_no_wh, capped_by_wh}`. `stitch_pod_to_boonz` v12 — `pull_lines` uses `variant_final = variant_target` (no WH cap), removes `pull_redistributed`. `remove_lines` applies uniform even-split for ALL `source_origin` values (fixes fan-out where `REMOVE qty=6` with 3 variants produced 3×6=18u). Returns new `diagnostics[]` array with `{machine_name, shelf_code, pod_product_name, action, qty, stitch_result}` per approved row. Stitch invariant for `internal_transfer` REMOVE/M2W preserved. `refill_plan_deviations.deviation_type` literal `wh_shortage` → `mapping_gap`. Smoke test on 2026-05-23: 58 refills (up from 43); 0 rows with old WH-clamp reasons; 14 rows carry `wh_warning=true`. Cody-reviewed.                                                                                                                                                                                          |
| `refill_engine_p2_floor_auth_empty_shelf`  | 1, 4, 5, 8, 12 | ✅ Applied | 2026-05-23 | Phase 2 (P1). `engine_add_pod` v10 adds machine-velocity-derived performance fill floor: tiers (`≥10 units/day → 70%`, `≥3 → 50%`, else `25%`) plus AC-6 absolute safety net (`gap≥2 AND fill_pct≤25%`). New `clamp_reason='performance_floor'`. `raw_qty = GREATEST(velocity_target, floor_target)`. New JSONB keys: `velocity_raw_qty`, `floor_target`, `machine_daily_velocity`, `fill_floor_threshold`. `auto_generate_draft` adopts NULL-safe role gate (matches engine_add_pod pattern: only enforce when `auth.uid() IS NOT NULL`) — service-role passthrough subsumed since cron's `auth.uid()` is NULL. `engine_finalize_pod` v10 — after the INSERT CTE, UPDATEs REMOVE/M2W rows with no paired ADD_NEW on the same `(machine, shelf)` to add `reasoning.warning='empty_shelf_after_removal'`. Returns `empty_shelf_after_removal_flagged` count. Smoke test on 2026-05-23: 74 refills (up from 58); 33 rows triggered performance floor; engine_finalize flagged 2 empty-shelf rows (ALJLT A05 Krambals M2W + OMDBB A01 Tamreem Date Ball M2W — PRD AC-1 example). Cody-reviewed. |
| `refill_engine_p3_wh_avail_in_draft`       | 12, 13         | ✅ Applied | 2026-05-23 | Phase 3 (P2). DROP+CREATE `get_pod_refill_draft` (return type changed, additive `wh_avail integer` column appended; `LANGUAGE sql STABLE` SECURITY INVOKER preserved). `wh_avail` = SUM of `warehouse_inventory.warehouse_stock` across active product_mapping variants where `status='Active' AND quarantined=false`. NULL when no rows match (no data); 0 when rows exist but stock is empty (confirmed empty). FR-009 satisfied transitively by Phase 1 FR-002 — variant distribution defaults to product_mapping even-split; no WH-weighted code to gate. Smoke test on 2026-05-23: 110 REFILL/ADD_NEW rows, 90 with NULL `wh_avail`, 20 with positive `wh_avail`. Read-only helper — no Cody review required.                                                                                                                                                                                                                                                                                                                                                                           |

**E2E regression test (2026-05-23 dry-run after Phase 1+2+3).** `stitch_pod_to_boonz` produced 228 boonz lines from 130 approved pod rows in 634ms (vs the 23-May incident producing 3 of 96). Diagnostics array populated with 130 entries — 2 `no_active_mapping`, ~16 `no_inventory_to_remove`, ~85 `resolved_no_wh_stock_warning`, remaining `resolved`. 22/25 picked machines have ≥1 plan row (3 fully-stocked machines correctly produce zero rows). VML A12 Vitamin Well REMOVE (pod_qty=235 from upstream engine_swap_pod, out of fan-out fix scope) processes correctly as a single diagnostic entry — fan-out math conserved.

**What this changes in production going forward.** Refill plans now generate for every shelf with a gap, regardless of warehouse stock. WH manager sees `wh_warning` flags + `procurement_alerts` rows when supply can't cover demand, but the plan still ships to drivers — the driver can skip if WH is empty. The performance floor catches near-empty shelves on busy machines that velocity-only logic missed (the 23-May Barebells 4/20 case). Empty-shelf-after-removal warnings give CS a heads-up before approving an M2W with no substitute. FE consumers of `clamp_reason` should treat `performance_floor` as a refill-floor signal; consumers of `refill_plan_deviations.deviation_type` should treat `mapping_gap` as the new value (was `wh_shortage`).

## D.M2M — Machine-to-machine transfers (2026-05-18)

Native M2M infrastructure replacing the broken Remove+Add New comment-based hack. Dara-designed (columns on refill_dispatching, not a new table), Cody-reviewed (4 revisions), Stax UX-designed (separate M2M section in packing FE with acknowledgment flow).

| Migration name                       | Article(s)  | Status     | Applied    | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------------------ | ----------- | ---------- | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phaseD_swap_between_machines`       | 1, 4, 8, 12 | ✅ Applied | 2026-05-18 | Three new columns on refill_dispatching (`is_m2m boolean`, `m2m_partner_id uuid FK`, `m2m_transfer_id uuid`). Two partial indexes for M2M lookups. New partial unique index `idx_pod_inv_active_shelf` on pod_inventory (prerequisite: 1,415 stale duplicate Active rows archived). Updated `conserve_split_dispatch_quantity` trigger with M2M early-return guard. Two new canonical writers: `swap_between_machines(uuid, uuid, jsonb, date, text)` — atomic paired Remove+Add New with pod_inventory adjustment, net-zero guaranteed; `acknowledge_m2m_transfer(uuid)` — WH manager confirmation, reuses wh_approved_at/by columns. Both DEFINER, role-gated, set app.via_rpc. GRANTed to authenticated. |
| `phaseD_m2m_deferred_pod_adjustment` | 1, 4, 8     | ✅ Applied | 2026-05-18 | Fix: pod_inventory adjustment deferred to driver confirmation (not plan creation). `swap_between_machines` no longer touches pod_inventory; dispatch lines born `dispatched=false` (was `true`). `receive_dispatch_line` gains M2M early branch: Remove decrements pod `current_stock` (archives at zero), Add New upserts via `ON CONFLICT`. Both paths skip all WH stock operations. Returns early with `is_m2m: true`.                                                                                                                                                                                                                                                                                   |

## E.1 — Lifecycle engine rebuild (2026-05-10, ongoing)

Phase E begins the proper rebuild of the upstream engines per CS's mental model. E-1 tackles the lifecycle scoring engine — the foundation every downstream decision rests on.

| Migration name                 | Article(s)     | Status     | Applied    | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------ | -------------- | ---------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phaseE1_lifecycle_data_fixes` | 1, 4, 5, 8, 12 | ✅ Applied | 2026-05-10 | Adds `machines.relaunched_at` column + canonical writer `set_machine_relaunched_at(uuid, timestamptz, text)`. Inline data fixes: ALJLT-1015-0200-O1 location_type='coworking' (was NULL → silently dropped by lifecycle line 594), IRIS-1010-0000-O0 → Inactive (defunct, last sale 42d ago), NISSAN-0804-0000-L0 relaunched_at=now() via canonical writer (relocating to new INDEPENDENT venue today). Cody-reviewed with 1 revision (NISSAN write routes through RPC, not direct UPDATE). E-1 audit also produced E1_lifecycle_fix_spec.md. Companion edge function patch (evaluate-lifecycle v13: STAR signal + relaunched_at lookup + null-location-type fallback) ships via Stax separately. |

## D.0 — Strategic intent layer (2026-05-06)

The intent layer between strategic engines and tactical executors. Strategic engines (PRODUCT OPT, EXPIRY OPT) write multi-cycle action plans here; ADD and SWAP read the queue and decide which intents to advance each refill cycle. Progress reflects ONLY what was approved + applied (not what was drafted) — `reconcile_intent_progress` (Phase D-0a) is the sole writer of status/progress changes. Operator can also write intents directly.

| Migration name                                          | Article(s)                | Status     | Applied    | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ------------------------------------------------------- | ------------------------- | ---------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phaseD0_strategic_intents`                             | 1, 2, 5, 7, 8, 12, 14, 15 | ✅ Applied | 2026-05-06 | New protected table `strategic_intents`. Six-value status FSM (queued → in_progress → completed/abandoned/expired/blocked). Five CHECK constraints enforce type-conditional integrity (dissolve_batch needs source_wh_inventory_id; routing types disallow it; terminal status requires closure metadata; abandoned requires reason; target date must be future). FORCE RLS, append-only, audit trigger, 6 indexes (incl. partial unique to prevent duplicate active intents). 4 policies, 4 FKs. Three negative tests passed (dissolve_batch w/o source, decommission w/ source, past completion date). First positive test: Leibniz Zoo Cocoa decommission intent for ALJLT-1015 + OMDCW-1021, 7 units target, 21-day window. Adds to Appendix A (Amendment 006). Cody approved without revisions. Phase D-0a (linked_intent_id + reconcile_intent_progress) ships next.                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `phaseD0a_reconcile_and_lifecycle`                      | 1, 4, 5, 8, 11, 12        | ✅ Applied | 2026-05-06 | Wires `daily_plan_drafts.linked_intent_id` (nullable FK, indexed) so drafts can reference the strategic intent they're advancing. Three new DEFINERs: `reconcile_intent_progress` (sole writer of strategic_intents.progress + auto-completion), `abandon_intent` (operator-only closure), `expire_intents` (system-callable, sweeps overdue active intents → expired). Modified `orchestrate_refill_plan` to add reconcile as the 4th stage (ADD → SWAP → FINALIZE → RECONCILE). Phase D-0a uses `daily_plan_drafts.status='finalized'` as proxy for approved+applied until Step 5b writes refill_plan_output. End-to-end smoke test passed: synthetic draft → finalize → reconcile → intent transitions queued → in_progress with applied_units=3 (of target 7), event captured in progress jsonb. Idempotency verified (re-run added 0 events via draft_id dedup). Article 8 audit captured the reconcile UPDATE. Cody approved without revisions.                                                                                                                                                                                                                                                                                                                                                          |
| `phaseD1_decommission_planner`                          | 1, 4, 5, 8, 12            | ✅ Applied | 2026-05-06 | New DEFINER `propose_decommission_plan(boonz_product_id, target_completion_date, max_residual_units, machine_scope, rationale)` — the PRODUCT OPT planner. Computes target_qty from currently-deployed pod_inventory units within the named scope (or fleet-wide), creates one strategic_intent of type 'decommission'. Per-element FK validation on machine_scope via unnest. Validates `max_residual_units < target_qty` so reconcile can't auto-complete prematurely. Idempotent via `uq_si_active_unique` — friendly UX message on duplicate. Refuses no-op intents (zero deployed units in scope). Cody approved without revisions.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `phaseD1_decommission_planner_fix_pod_status`           | 12                        | ✅ Applied | 2026-05-06 | Forward-only patch. Original planner filtered on `pi.removal_reason IS NULL` but missed `pi.status = 'Active'`, so historical Inactive snapshots (pre-2026-05-06 archive era) were double-counted. Sabahoo Chocolate showed inflated target_qty=83; real number is 4 units on USH-1008 only. Fix adds `pi.status = 'Active'` to the filter. Cleanup migration `phaseD1_cleanup_bogus_sabahoo_intent` abandoned the bad intent and re-creating with the fixed planner gave correct target_qty=4.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `phaseD1_cleanup_bogus_sabahoo_intent`                  | 12                        | ✅ Applied | 2026-05-06 | One-off cleanup migration. Manually transitions the bogus Sabahoo decommission intent (target_qty=83) to status='abandoned' with traceable closure reason. Migration runs as table owner so it bypasses FORCE RLS; sets app.via_rpc/app.rpc_name for audit trail. After cleanup, re-running propose_decommission_plan gave correct target_qty=4.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `phaseD2_batch_dissolution_planner`                     | 1, 4, 5, 8, 12            | ✅ Applied | 2026-05-06 | New DEFINER `propose_batch_dissolution_plan(wh_inventory_id, max_residual_units, safety_buffer_days, rationale)` — the EXPIRY OPT planner. Reads warehouse_inventory directly. Refuses Inactive batches (Article 6 status drift), zero-stock, NULL/past expirations. target_completion = expiration - safety_buffer (default 14d), capped at CURRENT_DATE+1. Defensive math: GREATEST(expiry-buffer, today) plus secondary check (target > today) prevents same-day target. Smoke tests: real Vitamin Well Care batch dissolution intent created (5 units in WH_MCC, expires 2026-06-07, target_completion=2026-05-24, days_to_act=14). Dedup test rejected duplicate with friendly message. Cody approved without revisions.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `phaseD3_wire_addswap_to_intents`                       | 1, 4, 5, 8, 12            | ✅ Applied | 2026-05-10 | Wires ENGINE SWAP to read strategic_intents. Two-pass design on `propose_swap_plan`: Pass 1 walks active decommission intents in scope and emits SWAP REMOVE+ADD_NEW pairs with `linked_intent_id` set; Pass 2 retains the autonomous slot-signal logic. Cody-revised during draft: shelf_code resolution via `pod_inventory.shelf_id → shelf_configurations` (no unsafe `'A01'` fallback). New skip counter `skipped_no_shelf`. ENGINE ADD intent integration deferred to D-3c (its WH-source-selection logic doesn't yet pick specific batches; intent-aware routing is premature). First smoke test produced `intent_driven_swaps=0` due to threshold miscalibration (default 30.0 vs observed Pearson floor 10.0) — fixed in D-3a.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `phaseD3a_swap_calibration_and_guardrails`              | 1, 4, 12                  | ✅ Applied | 2026-05-10 | Recalibrates `propose_swap_plan` after observed-data analysis. Default `p_min_substitute_score`: 30.0 → 10.0 (median in-category Pearson top score = 28.18, p25 = 19.01, floor at 10.0; at 30 only 47/166 active products had a substitute, at 10 → 93). Adds **category fallback** when `get_similar_products` returns nothing: same product_category, ranked by aggregated `slot_lifecycle.velocity_30d` desc with deterministic UUID tiebreaker, WH stock ≥4 baked in via EXISTS. Adds **two guardrails on BOTH Pearson and fallback paths**: (1) substitute must not have an Active pod_inventory row on target machine (FSM-verified — Active+stock=0 means slot reserved for refill); (2) substitute must not itself be in an active decommission intent. New return fields: `pearson_substitutes`, `fallback_substitutes`, `min_substitute_score`. Post-apply smoke test: `intent_driven_swaps=3, autonomous_swaps=36, pearson_substitutes=19, fallback_substitutes=20, skipped_no_substitute=133` (down from 224 with old threshold). Cody-reviewed with 4 revisions (velocity source named, deterministic tiebreaker, decommission filter on both paths, FSM-correct on-machine predicate).                                                                                                           |
| `phaseD3e_r5_r7_and_cron`                               | 1, 4, 5, 8, 11, 12        | ✅ Applied | 2026-05-10 | Three additions: R5 cooldowns in propose_swap_plan (14-day no-repeat-removal; 30-day no-re-introduction filter on substitute candidates); R7 60% shelf cap in engine_finalize (fail-safe hard block, overrules worst-score excess); pg_cron at 16:00 UTC daily (=8pm Dubai) running orchestrate_refill_plan(CURRENT_DATE+1). R3/R5 remain warnings per CS. Smoke test for tomorrow's plan: 156 ADD + 42 SWAP (19 M2W + 23 pairs) → 215 finalized → 409 published rows in 2.1s.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `phaseD3d_machine_to_warehouse_return`                  | 1, 4, 5, 8, 12            | ✅ Applied | 2026-05-10 | Wires SWAP to emit MACHINE_TO_WAREHOUSE drafts when no viable substitute exists. Routes to `machine.primary_warehouse_id` with qty=`pod_inventory.current_stock`. Pass 1 carries `linked_intent_id`; Pass 2 doesn't. Reconcile decommission filter extended to credit M2W alongside REMOVE. PUBLISH maps M2W → 'Remove' refill_plan_output row with `[pull to warehouse]` comment. Smoke test: skipped_no_substitute 112→0, 19 M2W drafts published. Cody approved without revisions.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `phaseD3c_wire_add_to_dissolve_batch`                   | 1, 4, 5, 8, 12            | ✅ Applied | 2026-05-10 | Wires ENGINE ADD to read strategic_intents. `propose_add_plan` now tags REFILL drafts with `linked_intent_id` when the boonz_product has an active dissolve_batch intent. `reconcile_intent_progress` upgraded to intent-type-conditional action filter: decommission=REMOVE, dissolve_batch=REFILL. Cursor JOINs strategic_intents instead of post-filter plpgsql. Smoke test: Vitamin Well Care moved queued 0/5 → completed 7/5 (overshoot documented as Step 5c follow-up). All three intents now in completed state. Cody approved without revisions.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `phaseD5b_engine_publish_to_refill_plan`                | 1, 4, 5, 8, 12            | ✅ Applied | 2026-05-10 | Closes the operator-facing gap. New DEFINER `engine_publish_to_refill_plan(plan_date)` reads finalized daily_plan_drafts and hands them to `write_refill_plan` (canonical refill_plan_output writer) with title-cased action mapping (REFILL→Refill, REMOVE→Remove, ADD_NEW→Add New) and resolved machine/product names. Skips MACHINE_TO_WAREHOUSE for now. PUBLISH is a thin adapter — write_refill_plan remains the sole canonical writer (Article 1). Modified `orchestrate_refill_plan` to add PUBLISH as 4th stage: ADD → SWAP → FINALIZE → PUBLISH → RECONCILE. Smoke test: 667 rows published across 21 machines (includes prior-test-run accumulation; production runs 1×/day will be clean). Three intent-driven SWAPs surfaced correctly. Reconcile cutover from "finalized draft" proxy to "applied refill_plan_output" deferred to D-5c. Cody-reviewed with 1 revision (idempotency-warning sentence in COMMENT).                                                                                                                                                                                                                                                                                                                                                                                 |
| `phaseD3b_reconcile_action_filter_and_intent_recompute` | 1, 4, 8, 12               | ✅ Applied | 2026-05-10 | Fixes latent bug in `reconcile_intent_progress` unmasked by D-3a. SWAP pairs link `linked_intent_id` on both REMOVE (qty=1) and ADD_NEW (qty up to 8) drafts; reconcile was summing both, crediting 9 units per pair instead of 1. After D-3a, Leibniz Zoo Cocoa read 12/7 'completed' (truth: 4/7) and Sabahoo Chocolate 9/4 'completed' (truth: 1/4). Fix: cursor adds `AND d.action = 'REMOVE'` so only the decommission side credits applied_units. Inline note flags that future additive intent types (`introduce`, `rotate_in`) will need a CASE-per-intent_type filter. Same migration includes a one-time DO block that recomputes `applied_units` from REMOVE-event qty for any active decommission/dissolve_batch intent currently 'completed', flips status back to 'queued' or 'in_progress' depending on whether REMOVE events exist, clears `closed_at` / `closure_reason`. Idempotent (guarded by `recomputed_applied < acceptable AND status = 'completed'`). Audit captured via distinct `app.rpc_name='phaseD3b_intent_recompute_data_fix'`. Cody-reviewed with 5 revisions (audit GUC, idempotency guard, status-flip rule by recomputed value, closed_at clearing, events array preservation). Post-apply: Leibniz Zoo 4/7 in_progress, Sabahoo 1/4 in_progress, Vitamin Well 0/5 queued. |

## C.1 — ENGINE FINALIZE pipeline foundations (2026-05-06)

Building toward the OVERALL/DAILY split with parallel ENGINE ADD + ENGINE SWAP feeding ENGINE FINALIZE. C.1 is the first atomic step: extend `rotation_proposals` with the `machine_to_warehouse` proposal type so the 2-step swap pattern (machine → WH → machine) has a schema home. Foundational for ENGINE EXPIRY OPT and ENGINE SWAP to emit return-leg proposals as standalone rows.

| Migration name | Article(s) | Status | Applied | Notes |
| ------------------------------------------------- | ------------------------- | ---------- | ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `phaseC1_machine_to_warehouse_type` | 2, 5, 7, 8, 12, 14 | ✅ Applied | 2026-05-06 | Adds `target_warehouse_id` column (nullable), makes `target_machine_id` nullable, extends `proposal_type` CHECK with `machine_to_warehouse`, adds `rp_target_consistency` CHECK enforcing exactly-one-target-type, drops+recreates `uq_rp_active_source_target` partial unique to include target_warehouse_id, adds `idx_rp_source_machine_pending` for m2w lookups. All 21 existing pending wh_to_machine rows pass new constraints. Synthetic m2w INSERT verified. Negative test (m2w with target_machine_id) correctly rejected by rp_target_consistency. Cody-reviewed; revision (Articles satisfied header) applied. |
| `phaseC2_daily_plan_drafts` | 1, 2, 5, 7, 8, 12, 14, 15 | ✅ Applied | 2026-05-06 | New protected table `daily_plan_drafts` — shared draft surface for ENGINE ADD / ENGINE SWAP / ENGINE EXPIRY_OPT_PUSH. FORCE RLS, append-only, audit trigger `tg_audit_daily_plan_drafts`. Status FSM `draft → finalized                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | overruled`. **Schema-level engine orthogonality** via `dpd_engine_action_match`CHECK (ADD only emits REFILL; SWAP only emits REMOVE/ADD_NEW/MACHINE_TO_WAREHOUSE; EXPIRY_OPT_PUSH only emits REFILL/ADD_NEW). Self-FK`paired_draft_id` (ON DELETE RESTRICT, FORCE-RLS-locked anyway) for 2-leg swap pair tracking. 4 policies, 7 indexes (1 PK + 6 secondary), 9 CHECK constraints, 7 FKs, 1 audit trigger. Negative test (ADD+REMOVE) correctly rejected. Positive test passed. Adds to Appendix A — Amendment 005. Cody-reviewed; FK ON DELETE clauses revised SET NULL → RESTRICT for FORCE-RLS-protected references. |
| `phaseC3_product_correlation_v1` | 12 | ✅ Applied | 2026-05-06 | ENGINE PRODUCT CORRELATION v1 — read-only intelligence. New view `v_product_basket_affinity` computes Pearson correlation of per-machine velocity_30d for every (A,B) pair sharing ≥3 machines with non-zero velocity. Score bounded 0-100 with log-saturated shared-machines factor + velocity floor. New INVOKER RPC `get_similar_products(boonz_product_id, top_n, min_score)` returns ranked similar products with source label. Substrate 1 (machine basket affinity) ships; substrate 2 (sales co-purchase) blocked because 100% of WEIMI transactions are single-SKU; substrate 3 (LLM enrichment) deferred to Phase C-3b. Smoke tests: Vitamin Well - Care top similars are the 4 sister variants + G&H Popped Chips trio + M&M Bag (sensible). Rice Cake Dark Chocolate top similars include 6 Krambals variants at correlation 0.953 — actionable insight for ENGINE SWAP. 6,960 pairs in view: 436 strong, 920 moderate, 2,574 weak, 3,030 noise. Cody-approved without revisions. |
| `phaseC4_engine_finalize` | 1, 4, 5, 8, 12 | ✅ Applied | 2026-05-06 | ENGINE FINALIZE — DEFINER function `engine_finalize(plan_date, dry_run)` owns the merge + conflict-resolution layer between draft producers (ADD, SWAP, EXPIRY_OPT_PUSH). Implements Rule R1+R2+R4 (shelf-level SWAP overrules ADD), surfaces R3/R5/R6 as warnings. Updates daily_plan_drafts status: draft → finalized (with finalized_at) | overruled (with overrule_reason). Phase C-4 prototype DOES NOT call write_refill_plan — Step 5 orchestrator does. Smoke tests: dry-run on 1-draft fixture returned correct preview; conflict test (synthetic SWAP REMOVE on same shelf as existing ADD REFILL) correctly overruled the ADD with proper reason and finalized the SWAP. Article 8 audit trail: 2 UPDATE rows in write_audit_log with via_rpc=true, rpc_name='engine_finalize'. Cody-approved without revisions. |
| `phaseC5_orchestrator` + `phaseC5_swap_dedup_fix` | 1, 4, 5, 8, 12 | ✅ Applied | 2026-05-06 | Phase C-5 — three new DEFINER functions completing the parallel-engine pipeline: `propose_add_plan` (ENGINE ADD, INSERT-only), `propose_swap_plan` (ENGINE SWAP, INSERT-only with PRODUCT CORRELATION handshake), `orchestrate_refill_plan` (thin orchestrator: ADD → SWAP → FINALIZE). Cody-revised: SWAP is INSERT-only (no UPDATE on REMOVE row's paired_draft_id — only ADD_NEW points to REMOVE). `phaseC5_swap_dedup_fix` follow-up wraps both legs of a swap pair in one PL/pgSQL subtransaction (BEGIN..EXCEPTION) so unique_violation on either INSERT rolls back the partial pair gracefully. **First production end-to-end run on CURRENT_DATE+2:** 135 ADD drafts (618ms) + 74 SWAP drafts (1254ms) = 209 total drafts → FINALIZE merged in 300ms, finalized 194 + overruled 15 (R1+R2+R4 conflicts), 51 R3 multi-variant warnings + 16 R5 net-flow warnings surfaced. Total 2.2s wall-clock. **The parallel-orthogonal architecture works as specified.** Phase D follow-ons: R3 brand guardrail, R5 14-day cooldown, R7 60% shelf rule, MACHINE_TO_WAREHOUSE return when no substitute, push_expiry_opt_to_drafts (for EXPIRY OPT proposals to flow into draft pipeline), Step 5b write_refill_plan call (enriches drafts and writes the canonical plan rows). |

## B.1 — Optimizer Brain Phase B: Engine 2 write surface (2026-05-05)

`rotation_proposals` table created with FORCE RLS, four block/allow policies, the universal audit trigger, five indexes (one partial-unique for dedup), and five CHECK constraints enforcing the proposal-type/status state machine. Append-only via DEFINERs (RPCs ship in a separate Phase B.2 migration). Article 15 amendment 003 adds `rotation_proposals` to Appendix A protected entities.

| Migration name                          | Article(s)                | Status     | Applied    | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| --------------------------------------- | ------------------------- | ---------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phaseB_rotation_proposals_table`       | 1, 2, 5, 7, 8, 12, 14, 15 | ✅ Applied | 2026-05-05 | New protected table. ENABLE + FORCE RLS. Audit trigger `tg_audit_rotation_proposals` fires on INSERT/UPDATE/DELETE. Five canonical writers planned (propose_rotation_plan, apply_rotation_proposal, reject_rotation_proposal, mark_proposals_expired, supersede helper) — bodies pending Phase B.2 with separate Cody review.                                                                                                                                                                                                                                                                                                                      |
| `phaseB2a_score_machine_for_product`    | 12                        | ✅ Applied | 2026-05-05 | Read-only INVOKER function. 0-100 fit score with breakdown for routing a boonz_product to a target machine. Reads `v_machine_absorption_capacity`. Weights: throughput 35, archetype 20, location 15, capacity 15, urgency 10. Hard cutoffs: `machine_excluded`, `machine_inactive`, `travel_scope_vox_locked` (8 VOX-locked SKUs hardcoded; TODO Phase C: move to `travel_scope_locks` config table). Smoke tests passed: Vitamin Well Upgrade → VOXMCC-1009 = 69.94 (real fit), Aquafina → VML = 0 (hard_block). Cody-reviewed; revisions applied (COALESCE on throughput formula for single-machine edge case, TODO comment on hardcoded list). |
| `phaseB2a_fix_score_function_multi_row` | 12                        | ✅ Applied | 2026-05-06 | Forward-only patch. `v_machine_absorption_capacity` returns multiple rows for one (machine, boonz_product) pair when a boonz SKU is the global default for ≥2 pod_products (multi-variant). LANGUAGE sql function errored with "more than one row returned by a subquery." Patched the `ctx` CTE with `DISTINCT ON (machine_id, boonz_product_id)` ordered by `pod_product_id NULLS LAST` for determinism.                                                                                                                                                                                                                                         |

## B.1 — Lifecycle Reality Anchor (2026-05-07)

| Migration name                         | Article(s)            | Status     | Applied    | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| -------------------------------------- | --------------------- | ---------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `phaseB_b1_2_machine_first_sale_view`  | 2, 9, 12              | ✅ Applied | 2026-05-08 | New view `v_machine_first_sale` (SECURITY INVOKER, GROUP BY machine_id MIN/MAX/COUNT). Used by evaluate-lifecycle to compute MACHINE_RAMPING based on actual deployment age, fixing the B.1.1 false-positive at WAVEMAKER/WPP (mature machines with quiet patch in 62-day window were wrongly flagged ramping). Edge fn v11 reads from this view as the authoritative first-sale source.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `phaseB_b3_lifecycle_scoring_redesign` | 9, 12, 13, 14, 15     | ✅ Applied | 2026-05-08 | Splits the lifecycle scoring engine: `product_lifecycle_global.score` becomes rank-percentile of per_machine_avg_v30 across the product universe (top product = 10, bottom = 0). `slot_lifecycle.score` becomes a ratio-spectrum centered on the product's own per-machine global avg (5.0 = at avg, 10.0 = 2× avg). Both EMA-blended with prior value (α=0.67 → recent ≈ 2× historical). New `getSignalV2` hard-gates DOUBLE DOWN/KEEP GROWING on both score AND trend. Adds 7 observability columns across `product_lifecycle_global` and `slot_lifecycle`, partial unique index on `(global_rank)` and `(pod_product_id, score DESC) WHERE is_current=true`, `score_kind` enum on `lifecycle_score_history`, new view `v_product_lifecycle_global_enriched`. Edge fn v12 deployed; Aquafina ranks #1 (per_machine_avg=13.18), Evian Sparkling ranks #36 (per_machine_avg=0.135) — the per-machine apples-to-apples ranking CS asked for.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `phaseB_b1_lifecycle_reality_anchor`   | 1, 2, 3, 7, 9, 12, 14 | ✅ Applied | 2026-05-07 | Repoints lifecycle off `planogram` (frozen seed) onto `weimi_aisle_snapshots` (refreshed every ~6h). Converts `slot_lifecycle` from a (machine, shelf) snapshot to a (machine, shelf, product) ledger via 3 new columns (`is_current`, `rotated_in_at`, `rotated_out_at`), constraint rotation to `UNIQUE (machine_id, shelf_id, pod_product_id)`, and partial unique index `uq_slot_lifecycle_current_per_slot` enforcing "exactly one current product per live slot." Two `lifecycle_score_history` indexes added for per-slot-per-product history queries. Pre-flight DO-block aborts cleanly if existing data violates the new invariant. Companion edge fn diff (`evaluate-lifecycle/index.ts` v9) reads snapshot + shelf_configurations, normalizes WEIMI's "A1"/"A15" slot codes to padded "A01"/"A15" via TS-side `padShelf` helper, detects rotations by comparing dominant product-per-slot to existing `is_current=true` row and flips the prior to `is_current=false, rotated_out_at=now()`. New DQ flag types `UNRESOLVED_SHELF_ID` and `UNRESOLVED_POD_PRODUCT_NAME` surface unresolvable snapshot rows. FE matrix at `src/app/(app)/app/lifecycle/page.tsx` adds "Show rotated-out products" toggle that overlays prior products as faded points with rotation timestamps. **Known debt:** evaluate-lifecycle remains in violation of Article 9 (business logic + direct writes inline) — pre-existing, deepened by the rotation-detection logic; tracked for follow-up to wrap in `compute_and_apply_lifecycle()` SECURITY DEFINER RPC. **Follow-up filed:** `phaseB_b2_refill_engine_planogram_retirement` (Dara design pending — refill engine still reads `planogram`). |
| `phaseB2b_engine2_rpcs`                | 1, 4, 5, 8, 12        | ✅ Applied | 2026-05-06 | Four DEFINER canonical writers for `rotation_proposals`: `propose_rotation_plan` (INSERT loop, system+operator callable), `apply_rotation_proposal` (pending→applied, operator-only), `reject_rotation_proposal` (pending→rejected, operator-only), `mark_proposals_expired` (pending→expired, system+operator callable). All set `app.via_rpc/app.rpc_name`, validate inputs, role-gate via user_profiles. First real run produced 21 pending proposals (top: Vitamin Well Antioxidant→VOXMCC-1009 fit 82.7), 3 dedup-skips, 0 hard-blocks below threshold, 21s wall-clock. Audit trigger fired correctly (21 rows in `write_audit_log` with via_rpc=true, rpc_name='propose_rotation_plan'). Cody approved without revisions. **Phase B.3 follow-up:** wire pg_cron for `propose_rotation_plan` at 04:00 Dubai and `mark_proposals_expired(3)` at 03:00 — Article 11 review required.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |

## A.5 — Optimizer Brain Phase A foundations (2026-05-05)

Read-only intelligence layer for Engine 2 (Rotation Planner). Adds the lifecycle archetype column on `boonz_products` (HYPE | ALWAYS_ON | SEASONAL | TRIAL | UNCLASSIFIED), bootstraps it via product lifetime + velocity, and exposes two views: `v_warehouse_at_risk` (warehouse stock × expiry × Engine 1 signal context) and `v_machine_absorption_capacity` (per (machine, boonz_product) absorption profile, sourced from `slot_lifecycle` to avoid parallel velocity computation). No write paths in Phase A. Cody-reviewed; revisions applied (anon grant removed, audit attribution added, article header). Engine 2 RPCs ship in Phase B.

| Migration name                                    | Article(s)   | Status     | Applied    | Notes                                                                                                                                                                                                                                                                                                                 |
| ------------------------------------------------- | ------------ | ---------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phaseA_optimizer_foundations`                    | 2, 6, 12, 14 | ✅ Applied | 2026-05-05 | ALTER `boonz_products` ADD `lifecycle_archetype` text NOT NULL DEFAULT 'UNCLASSIFIED' with CHECK enum + partial index. Bootstrap UPDATE: 144 ALWAYS_ON, 4 TRIAL, 131 UNCLASSIFIED. New views `v_warehouse_at_risk` (171 rows) and `v_machine_absorption_capacity` (8,845 rows). GRANT SELECT to `authenticated` only. |
| `phaseA_optimizer_foundations_fix_urgency_bucket` | 12           | ✅ Applied | 2026-05-05 | Forward-only patch. `INTERVAL '7'` (no unit) was being parsed as 7 _seconds_, dumping every row into `safe_90d_plus`. Replaced with integer arithmetic (`CURRENT_DATE + 7`). Post-fix: 1 urgent_0_7d, 8 soon_7_30d, 13 medium_30_60d, 19 long_60_90d, 130 safe_90d_plus.                                              |

## A.4 — Repurposed-machine attribution (2026-05-05)

Versioned-history table + Adyen attribution view + per-machine read-only RPC. Makes /app/performance and partner reports correctly split repurposed machines (e.g. ACTIVATE-2005 vs MPMCC-2005-0000-W0). Cody-reviewed; revisions applied.

| Migration name                                         | Article(s)            | Status     | Applied    | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------------------------------ | --------------------- | ---------- | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phaseA_a4_machine_terminal_history`                   | 1, 2, 4, 7, 8, 12, 14 | ✅ Applied | 2026-05-05 | New versioned-history table `machine_terminal_history` (terminal × machine × daterange, EXCLUDE-overlap constraint, RLS, generic audit trigger), 9 backfilled windows, new SECURITY DEFINER RPC `register_terminal_move`, new view `v_adyen_transactions_attributed` (security_invoker). Adds `machine_terminal_history` to protected entities.                                                                                                                                                                   |
| `phaseA_a4b_attributed_view_dedupe`                    | 12                    | ✅ Applied | 2026-05-05 | Forward-only patch: restrict the view's machines join to `status='Active'` so stale Inactive terminal claims (WH3\_\* leftovers) don't double-match Adyen rows.                                                                                                                                                                                                                                                                                                                                                   |
| `phaseA_a4c_per_machine_performance_rpc`               | 12                    | ✅ Applied | 2026-05-05 | New read-only RPC `get_per_machine_performance(date, date, text, text[])` returns JSON array per attributed-machine. LANGUAGE sql STABLE; SECURITY INVOKER (RLS via underlying views). Single greppable call site for any per-machine dashboard.                                                                                                                                                                                                                                                                  |
| `phaseA_a4d_vox_commercial_report_via_attributed_view` | 1, 12                 | ✅ Applied | 2026-05-05 | Patches `get_vox_commercial_report` to read Adyen via `v_adyen_transactions_attributed`, split SettledBulk vs RefundedBulk, and net refund_returned out of captured. Site attribution unchanged (still via `sh.machine_mapping`).                                                                                                                                                                                                                                                                                 |
| `phaseA_a4e_vox_consumer_report_join_by_machine_id`    | 1, 12                 | ✅ Applied | 2026-05-05 | Patches `get_vox_consumer_report` join from `selected_machines.machine_name = sales_history.machine_mapping` (current name) to `selected_machines.machine_id = sales_history.machine_id` (stable). Without this, sales rows whose `machine_mapping` was the historical name (e.g. `MPMCC-2005-0000-W0` Apr 23-27) were dropped because no current machine row had that `official_name`. The breakdown still uses `machine_mapping` so MPMCC-2005 appears as a separate row. Powers `/refill/consumers`.           |
| `phaseA_a4f_consumer_report_adyen_pending_flag`        | 12                    | ✅ Applied | 2026-05-05 | Adds `pending`/`status` fields per recent_txn and `pending_txns`/`wallet_txns` summary counts. Lets the FE distinguish "Adyen settlement pending" (last 48h, no PSP yet) from "wallet/cash" (older, no PSP — genuinely off-Adyen). Adyen settlement lags 1-3 days; without this flag, today's late-afternoon transactions look like unmatched wallet sales until the next settlement file lands.                                                                                                                  |
| `phaseA_a4g_vox_commercial_filter_by_machine_id`       | 1, 12                 | ✅ Applied | 2026-05-05 | Patches `get_vox_commercial_report` to drop the `machine_mapping LIKE 'VOXMM%'/'VOXMCC%'` filter (which silently excluded ACTIVATE-2005, MPMCC-2005, IFLYMCC-1024, ACTIVATEMCC-1037, MPMCC-1054, MPMCC-1058 from the commercial waterfall) and switch to `machine_id` matching against the venue_group=VOX Active machines bucketed by pod_location. Now `/refill/consumers` Commercial tab and Header bar agree (was 1,087 AED / 39 txns gap = MPMCC-2005-0000-W0 era + 6 other non-VOX-prefix Mirdif machines). |

## PRD-012 — Driver Pod Add Workflow (2026-05-25, in progress)

Driver-side add of a new product to a machine pod via a propose-then-approve flow on `pod_inventory_edits`. P1.A is the schema substrate; P1.B/C/D add the canonical RPCs; Phase 3 hardens with cron auto-expire (A.5), a hard-block trigger on direct INSERT to `pod_inventory` (A.6), and Inventory Control Session integration (C.6).

| Migration name                                        | Article(s)      | Status     | Applied    | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ----------------------------------------------------- | --------------- | ---------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd_012_pod_inventory_edits_add_flow`                | 2, 5, 7, 12, 14 | ✅ Applied | 2026-05-25 | A.1 schema substrate. Adds `requested_expiration_date date`, `correlation_id uuid NOT NULL DEFAULT gen_random_uuid()`, `expired_at timestamptz` to `pod_inventory_edits`. Reuses `destination_shelf_id` for add-flow target. CHECK constraint `pod_inventory_edits_add_new_product_required_fields` in material-implication form. Three indexes: partial UNIQUE on (machine, shelf, product) WHERE pending+add_new_product (D5), composite on (correlation_id, created_at DESC) for 60s dedupe, partial on (created_at) WHERE pending+add_new_product for review-queue sort. **Phase 3 follow-up:** Amendment 008 to add to Appendix A. |
| `prd_012_extend_pod_inventory_edits_check_whitelists` | 5, 12           | ✅ Applied | 2026-05-25 | P1.A hotfix #1 (caught by smoke test). Two pre-existing CHECKs whitelist edit_type and status values; P1.A missed them. Forward-only DROP+ADD adds `add_new_product` to edit_type whitelist (needed by P1.B) and `expired` to status whitelist (needed by P3.A cron). Strict widening, no existing row affected.                                                                                                                                                                                                                                                                                                                        |
| `prd_012_relax_add_flow_check`                        | 12, 14          | ✅ Applied | 2026-05-25 | P1.A hotfix #2 (caught by smoke test). Original add-flow CHECK required `pod_inventory_id IS NULL` for add rows, blocking the approve RPC's pod_inventory_id linkage on UPDATE. Forward-only DROP+ADD with NULL clause removed. PRD §6.A.1 should be clarified by next maintainer.                                                                                                                                                                                                                                                                                                                                                      |
| `prd_012_propose_pod_inventory_add`                   | 1, 3, 4, 5, 8   | ✅ Applied | 2026-05-25 | A.2. SECURITY DEFINER. Validates D2 (shelf conflict), D3 (expiry bounds), qty > 0 and ≤ shelf max_capacity, D5 (idempotency by correlation_id with 60s replay window). INSERTs pending row. Roles: field_staff plus manager set. Returns jsonb (success or idempotent_replay).                                                                                                                                                                                                                                                                                                                                                          |
| `prd_012_approve_pod_inventory_add`                   | 1, 4, 5, 8, 12  | ✅ Applied | 2026-05-25 | A.3. SECURITY DEFINER. Locks edit row, re-validates shelf/expiry at approval time. Sets `app.via_rpc=true` + `app.rpc_name` + `app.mutation_reason`. INSERTs `pod_inventory` row with `batch_id = format('POD_ADD-%s', edit_id)`. UPDATEs edit row to approved with `pod_inventory_id` link. unique_violation defense around `idx_pod_inv_active_shelf`. Manager-only.                                                                                                                                                                                                                                                                  |
| `prd_012_reject_pod_inventory_add`                    | 1, 4, 5, 8      | ✅ Applied | 2026-05-25 | A.4. SECURITY DEFINER. Locks edit row, requires non-empty decision_note (>= 10 chars), UPDATEs status to rejected. Manager-only. Sets all three set_config markers.                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `prd_012_auto_expire_pod_add_proposals`               | 1, 11, 12       | ⏳ Phase 3 | —          | A.5. Function + pg_cron `pod_add_proposals_auto_expire` at 02:00 Dubai daily. Flips pending → expired for rows older than 14 days; sets `expired_at`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `prd_012_hard_block_pod_inventory_insert`             | 1, 3, 12        | ⏳ Phase 3 | —          | A.6. Trigger on `pod_inventory` BEFORE INSERT that refuses unless `app.via_rpc='true'`. G4 caller-audit gate before flipping.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `prd_012_amendment_008_appendix_a`                    | 15              | ⏳ Phase 3 | —          | Constitution amendment elevating `pod_inventory_edits` to Appendix A with FE INSERT exception clause (mirrors Amendment 007 shape for `inventory_control_attempt`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |

## PRD-013 — Pod Inventory Edits Canonical Approval (2026-05-25, shipped)

Supersedes PRD-012's per-edit_type approve/reject pattern with a unified canonical writer that handles all five edit_types (`expired`, `sold`, `partial_sold`, `return_to_warehouse`, `add_new_product`). Closes the 23-row "approved but pod row still Active" bug surface that lived because FE wrote directly to `pod_inventory_edits` without flipping `pod_inventory`. Phase 3 hardens with auto-expire cron; A.4 hard-block trigger formally deferred to a follow-up PRD per G4 CS decision (out-of-scope inline qty/location FE handlers still write direct).

| Migration name                                               | Article(s)         | Status      | Applied    | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ------------------------------------------------------------ | ------------------ | ----------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `prd_013_approve_pod_inventory_edit`                         | 1, 4, 5, 6, 8, 12  | ✅ Applied  | 2026-05-25 | P1.A. SECURITY DEFINER unified writer. 5-edit_type dispatch per PRD §D2. SELECT FOR UPDATE on edit + pod row. For `return_to_warehouse` with no matching WH row, INSERTs with `status='Inactive'` (Article 6 spirit — warehouse manager promotes via existing m2 propose-then-confirm). Raises on `machines.primary_warehouse_id IS NULL` rather than silent WH_CENTRAL fallback. C.6 inventory_control_session attribution (Amendment 009). Sets all three set_config markers. Manager-role gated.          |
| `prd_013_reject_pod_inventory_edit`                          | 1, 4, 5, 8         | ✅ Applied  | 2026-05-25 | P1.B. SECURITY DEFINER. Any edit_type, requires decision_note ≥ 10 chars. No pod or warehouse_inventory writes. Manager-role gated.                                                                                                                                                                                                                                                                                                                                                                          |
| `prd_013_deprecate_prd_012_approve_reject_pod_inventory_add` | 13                 | ✅ Applied  | 2026-05-25 | Article 13 deprecation. PRD-012 `approve_pod_inventory_add` / `reject_pod_inventory_add` patched to thin shims that forward to the PRD-013 unified RPCs and emit `RAISE NOTICE 'DEPRECATED'`. Sunset target: 2026-08-25 (90-day monitor window).                                                                                                                                                                                                                                                             |
| `prd_013_backfill_archive_pod_inventory_row`                 | 1, 4, 8, 12        | ✅ Applied  | 2026-05-25 | P2.C backlog-cleanup helper. SECURITY DEFINER. Gated to superadmin + operator_admin. Min 10-char `p_reason` (Cody F1 — matches reject RPC). FOR UPDATE lock. Sets `current_stock=0`, `estimated_remaining=0`, `status='Inactive'`, `removal_reason=p_reason`. Used once on 2026-05-25 to archive the 9 stuck pod rows (15 units of stock zeroed). Stays available for future ad-hoc backfills.                                                                                                               |
| `prd_013_auto_expire_pod_inventory_edits`                    | 1, 4, 5, 8, 11, 12 | ✅ Applied  | 2026-05-25 | P3.D. SECURITY DEFINER + pg_cron `pod_inventory_edits_auto_expire` at 22:30 UTC daily (02:30 Dubai). Flips `status='pending'` → `'expired'` for rows older than 14 days, across ALL edit_types (not just add_new_product). 30-minute gap after PRD-012 `pod_add_proposals_auto_expire` (22:00 UTC) keeps the two race-free; Article 1 follow-up filed to deprecate the PRD-012 cron in 90 days. Test-fired clean (expired_count=0 today; no eligible rows). `REVOKE ALL FROM public` blocks `authenticated`. |
| `prd_013_amendment_004_pod_inventory_edits_appendix_a`       | 15                 | ⏳ Deferred | —          | Constitution amendment to add `pod_inventory_edits` to Appendix A. Coupled with PRD-012's Amendment 008 (same elevation, same FE-INSERT exception clause for the driver propose path). Both filed jointly in the follow-up PRD that owns the inline-adjust RPC + A.4 trigger.                                                                                                                                                                                                                                |
| `prd_013_hard_block_pod_inventory_update`                    | 1, 3, 12           | ⏳ Deferred | —          | P3.E. Trigger spec retained in source PRD for the follow-up PRD. Today's 134 ongoing inline qty/location/status direct UPDATEs (out of PRD-013 §4 scope) would break if the trigger flipped now; follow-up PRD owns canonical `inline_adjust_pod_inventory` RPC + FE rewire + 7-day clean + trigger flip.                                                                                                                                                                                                    |

---

## Phase G — Stax FE refactor: refill_dispatching direct-writer closure (2026-06-01, partial)

PROGRAM-2026-06-01 closes the FE call sites that write `refill_dispatching` directly, ahead of the planned 2026-06-06 `enforce_canonical_dispatch_write` flip (RAISE WARNING to RAISE EXCEPTION). O1 shipped 3 new canonical writers; 5 of ~11 FE writers refactored. The remaining 6 had no matching RPC and were deferred by CS (see `docs/prds/_programs/PROGRAM-2026-06-01b-stax-fe-refactor-gap-closure.md`). The flip stays parked until those 6 close.

| Migration name                                           | Article(s)     | Status     | Applied    | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| -------------------------------------------------------- | -------------- | ---------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `phaseG_stax_canonical_writers_for_dispatch_fe_refactor` | 1, 3, 4, 8, 12 | ✅ Applied | 2026-05-30 | 3 SECURITY DEFINER writers: `update_dispatch_comment(uuid,text)`, `set_dispatch_include(uuid,boolean)`, `insert_driver_remove_line(uuid,uuid,uuid,uuid,numeric,date,text)`. Role-gated (field_staff + WH + admin tiers), input-validated, set `app.via_rpc`/`app.rpc_name`, audited by `tg_audit_refill_dispatching`. Also extended the `enforce_canonical_dispatch_write` allow-list with the 3 names while KEEPING RAISE WARNING (no flip). Cody-approved (1 revision: `insert_driver_remove_line` sets `filled_quantity=0` + `item_added=false` explicitly). FE: 5 sites refactored across packing/dispatching/trips. |
| `phaseG_health_bypass_block_flip` (D1)                   | 1, 3, 12       | ⏳ Blocked | —          | Flips `enforce_canonical_dispatch_write` to RAISE EXCEPTION. **Must not apply** until the 6 deferred direct writers (PROGRAM-2026-06-01b) close and the pre-flip soak (`bypass_violation_log WHERE rpc_name IS NULL`) returns 0.                                                                                                                                                                                                                                                                                                                                                                                         |

---

## Phase F — Lifecycle inactive-product flag (2026-05-31)

| Migration                                          | Articles           | Status     | Date       | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| -------------------------------------------------- | ------------------ | ---------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phaseF_lifecycle_product_status`                  | 1, 2, 4, 8, 12, 14 | ✅ Applied | 2026-05-31 | New non-protected table `lifecycle_product_status` + canonical writer `set_product_lifecycle_status(uuid,text,text)` (role-gated, validated, GUC-tagged) + universal `audit_log_write('pod_product_id')` trigger + RLS (SELECT all authenticated, writes role-gated). Seeded 14 retired/0-live-unit products as inactive (in-migration INSERT; MCP apply lacks auth.uid(); trigger audited). Cody ⚠️→revisions applied. Powers /app/lifecycle inactive-exclusion across all tabs. Rollback in CHANGELOG 2026-05-31.                                 |
| `phaseF_fix_pod_refill_plan_qty_check_allow_zero`  | 5, 12              | ✅ Applied | 2026-05-31 | Relaxed `pod_refill_plan_qty_check` from `CHECK (qty > 0)` to `CHECK (qty >= 0)`. The soft-stop contract (`stop_pod_refill_row` → `edit_pod_refill_row(qty:=0)`, stitch no-ops qty=0) was rejected by the old constraint, breaking row-removal persist on Commit (MINDSHARE-1009-4500-O1/A02). Aligns table to canonical writer (already validates qty>=0). No rows violated new constraint. Cody ✅ (Articles 2,5,7,12,14). Follow-up: remove (qty=0/draft) vs restore (status=superseded) inconsistency → Stax. Rollback in CHANGELOG 2026-05-31. |
| `phaseF_add_pod_refill_row_canonical_writer`       | 1, 4, 8            | ✅ Applied | 2026-05-31 | New canonical writer `add_pod_refill_row(date,uuid,uuid,uuid,text,integer,text,text)` — the missing manual-add path for `pod_refill_plan`. Validates pod_product_id resolves (kills "missing pod identifiers"), shelf↔machine, action enum, qty≥0, no-clobber, past-pending lock. Inserts draft / source_origin=warehouse; audits edit_type='add'. Role-gated, GUC-tagged. Cody ✅. FE wiring + machine-exclude checkbox → Stax. Rollback in CHANGELOG 2026-05-31.                                                                                  |
| `phaseF_add_pod_refill_row_fix_audit_before_state` | 1, 4, 8            | ✅ Applied | 2026-05-31 | Fix-forward of the above: `pod_refill_plan_audit.before_state` is NOT NULL, so adds write `'{}'::jsonb` instead of NULL. Same-session correction caught in verification before prod use.                                                                                                                                                                                                                                                                                                                                                            |

---

## PRD-016 / 016B — Return/transfer guardrails (2026-05-31)

| Migration                                            | Articles                 | Status                  | Date       | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ---------------------------------------------------- | ------------------------ | ----------------------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phaseF_prd016_quarantine_unverified_return`         | 2, 6, 7, 12, 14          | ✅ Applied              | 2026-05-31 | Migration 1 (DDL, shipped before this session): `dispatch_return_unverified` enum value + generated `quarantined` column distrusts it + drop/recreate of `idx_wh_inv_quarantined`, `v_wh_inventory_provenance`, `mv_wh_inventory_provenance`. Containment substrate.                                                                                                                                                                                                                                                                                                                                                              |
| `phaseF_prd016_unverified_return_provenance`         | 1, 4, 6, 8, 12           | ✅ Applied              | 2026-05-31 | Migration 2 (Guardrail 3 functional). Verbatim `CREATE OR REPLACE return_dispatch_line` + `receive_dispatch_line`; only added the unverified-provenance stamp (+ trusted restore) on each create-new-batch ELSE INSERT. Merge paths stay trusted. Cody ✅ (verbatim-diff + per-fn restore value). Verified dry: no-match→quarantined, match→trusted. Rollback in CHANGELOG.                                                                                                                                                                                                                                                       |
| `phaseF_prd016_guardrail1_m2m_as_remove`             | 1, 8, 12                 | ✅ Applied              | 2026-05-31 | Guardrail 1 (Bug A). BEFORE INSERT trigger `flag_remove_with_transfer_intent()` on `refill_dispatching` → `monitoring_alerts` (warning) when a `Remove` carries `[TRUCK-TRANSFER]` intent but `is_m2m=false`/no partner. WARN posture (Cody), escalate→BLOCK when FE routes to `swap_between_machines`. Verified: intent→1 alert, normal→0. Rollback in CHANGELOG.                                                                                                                                                                                                                                                                |
| `phaseF_prd016_guardrail2_return_variant_correction` | 1, 8, 12                 | ✅ Applied              | 2026-05-31 | Guardrail 2 (Bug B). BEFORE UPDATE trigger `flag_multivariant_return_without_correction()` on `refill_dispatching` (fires on `returned` false→true) → `monitoring_alerts` (warning) when pod_product maps to >1 active boonz variant on the machine AND no `variant_action_log` row exists for the dispatch. NEW trigger (not a 2nd writer rewrite — respects 24h rule). WARN posture. FE → Stax STAX-2026-05-31-01. Verified: multivariant-no-corr→1, with-corr→0, single→0. Rollback in CHANGELOG.                                                                                                                              |
| `refillv2_b1_draft_missing_alert`                    | 4, 8, 11, 12, 14         | ✅ Applied              | 2026-06-01 | Refill v2 Phase 0 / B1. New DEFINER `cron_refill_draft_missing_alert()` + cron `refill_draft_missing_alert` (jobid 23, `15 16 * * *` = 20:15 Dubai). Checks `refill_plan_output` for tomorrow; if empty writes one deduped `monitoring_alerts` (`refill_draft_missing`, critical) with the recomputed reason. Makes the silent "succeeded but no draft" cron outcome loud. Alert-only; no auto-confirm. Cody ✅. Verified live (dry run `status:ok`, 149 rows, 0 inserted). Rollback in CHANGELOG.                                                                                                                                |
| `refillv2_b2_shelf_index_drift_guard`                | 4, 8, 11, 12, 14         | ✅ Applied              | 2026-06-01 | Refill v2 Phase 0 / B2. Read-only view `v_shelf_aisle_index_drift` + DEFINER `cron_shelf_index_drift_alert()` + cron `shelf_aisle_index_drift_alert` (jobid 24, `30 3 * * *`). Audit found the aisle off-by-one already fixed fleet-wide (727/727 slots, 0 drift); this additive guard alerts if the `aisle_code+1==slot_name` invariant ever regresses. Does NOT touch the correct read path. Cody ✅. Verified live (view 0 non-ok, `status:ok`, 0 inserted). Rollback in CHANGELOG.                                                                                                                                            |
| `refillv2_p1_void_refill_plan`                       | 1, 3, 4, 5, 8, 12        | ✅ Applied              | 2026-06-01 | Refill v2 Phase 1 / F1. Adds `voided` to `pod_refill_plan_status_check` (forward drop+re-add) + canonical writer `void_refill_plan(plan_date, reason)`. Archive-only whole-plan void (draft/approved/stitched → `voided`); refuses if `refill_plan_output` past pending. DEFINER, operator_admin/superadmin, reason ≥10. Audited by `tg_audit_pod_refill_plan`. Cody ✅. Verified live (no-op empty date → `voided_rows:0`). Rollback in CHANGELOG.                                                                                                                                                                               |
| `refillv2_p1_reschedule_refill_plan`                 | 1, 3, 4, 5, 8, 12        | ✅ Applied              | 2026-06-01 | Refill v2 Phase 1 / F1. `reschedule_refill_plan(from, to, reason)` moves a whole plan between dates (key-move `UPDATE plan_date` on `machines_to_visit` + live `pod_refill_plan` rows; never DELETE). Refuses if source dispatched or target occupied. DEFINER, operator_admin/superadmin, reason ≥10. Cody ⚠️✅ (machines_to_visit audit gap tracked). Verified live (no-op empty→empty → 0/0). Rollback in CHANGELOG.                                                                                                                                                                                                           |
| `refillv2_p1_swap_pod_refill_row`                    | 1, 4, 5, 8, 12           | ✅ Applied              | 2026-06-01 | Refill v2 Phase 1 / F1. `swap_pod_refill_row(plan_date, machine_id, shelf_id, old_pod, new_pod, action, reason, conductor_session)` in-place product swap on a plan row. Composes canonical writers `edit_pod_refill_row(p_new_qty:=0)` (stop old) + `add_pod_refill_row(carried qty)` (add new); no new raw write path. Tier operator_admin/superadmin/warehouse; reason ≥10; returns `restitch_required:true`. Cody-approved. Verified pg_proc. Rollback: DROP FUNCTION.                                                                                                                                                        |
| `refillv2_p2_swap_dedup_machine_present`             | 1, 4, 8, 12, 14          | ✅ Applied              | 2026-06-01 | Refill v2 Phase 2 / #2 dedup-guard. `engine_swap_pod` → `v9_2_machine_present_dedup` (verbatim repro, diff-gated). New `ON COMMIT DROP` temp `_machine_present_pods` = `slot_lifecycle` is_current ∪ `v_live_shelf_stock` physical(`current_stock>0`); pass-2 `sub_candidates` excludes any substitute already present on the machine (`mpp.pod_product_id IS NULL`) → falls to M2W, never duplicated. Closed goal #1 as misdiagnosis (off-by-one only in unused `aisle_code`; callers use `slot_name`). Ruled OUT `engine_add_pod` dedup (20 legit multi-facings/11 machines). Cody ✅. Verified pg_proc. Rollback in CHANGELOG. |
| `refillv2_p2_stitch_physical_remove_fallback`        | 1, 4, 6, 8, 12, 14       | ✅ Applied              | 2026-06-01 | Refill v2 Phase 2 / #3 REMOVE/M2W dispatch. `stitch_pod_to_boonz` → `v13_physical_remove_fallback` (verbatim repro, diff-gated). New CTE `remove_lines_physical_fallback` emits a driver line (boonz NULL, qty = `v_live_shelf_stock.current_stock`) for REMOVE/M2W rows the mapped+inventory path dropped (VOX/untracked, non-internal_transfer), so every planned REMOVE reaches the driver. Mapped path + internal_transfer invariant + deviations/alerts unchanged. Cody ✅. Verified pg_proc; live dry-run deferred (no approved plan). Rollback in CHANGELOG.                                                               |
| `refillv2_b4_cap_remove_qty_live_stock`              | 1, 4, 6, 8, 12, 14       | ✅ Applied              | 2026-06-01 | Refill v2 Phase 2 / #4 B4. `stitch_pod_to_boonz` → `v14_remove_qty_capped` (verbatim repro, diff-gated 2 lines). `remove_lines.variant_final` capped: non-internal_transfer removes use `LEAST(fanned, pil.current_stock)`; internal_transfer left uncapped so the fan-out invariant holds. Stops over-capacity emissions (Nescafe 96 etc.). Cody ✅. Verified pg_proc. Rollback in CHANGELOG.                                                                                                                                                                                                                                    |
| `refillv2_b6_finalize_subset_aware`                  | 1, 4, 8, 12              | ✅ Applied              | 2026-06-01 | Refill v2 Phase 2 / #6 B6. `engine_finalize_pod` subset-aware via NO-DROP wrapper (Cody/Art.12): 1-arg replaced in place delegates to new 2-arg `(date, uuid[])` gated v13_subset_aware (14 machine gates). 2-arg has no defaults (avoids 1-arg ambiguity). Foundation for #7 reset_and_restitch. Verbatim repro diff-gated. Cody ✅ (revised from DROP). Verified pg_proc 2 overloads. Rollback in CHANGELOG.                                                                                                                                                                                                                    |
| `refillv2_p2_reset_and_restitch`                     | 1, 4, 5, 8, 12           | ✅ Applied              | 2026-06-01 | Refill v2 Phase 2 / #7. `reset_and_restitch(plan_date, machine_ids[], reason)` — one call to re-derive + re-stitch a subset (replaces ~8 raw dispatch edits = "plans editable without raw writes"). Composes archive-only supersede + engine_finalize_pod(date,ids) + approve_pod_refill_plan + stitch. Dispatch guard refuses non-pending subsets; per-machine pending-only write keeps dispatched machines safe. Cody ✅. Verified pg_proc. Rollback in CHANGELOG.                                                                                                                                                              |
| `refillv2_f5_commit_refill_plan`                     | 2, 4, 7, 12, 14          | ✅ Applied              | 2026-06-01 | Refill v2 Phase 2 / #8 F5. NEW append-only table `refill_commit_log` (RLS: operator SELECT, no update/delete, DEFINER-only insert) + DEFINER `commit_refill_plan(plan_date, comment, machine_ids[])` capturing push comment + summary = "push comments captured". Dara table, Cody ✅. Verified RLS 3 policies + pg_proc. TODO: add table to Appendix A. Rollback in CHANGELOG.                                                                                                                                                                                                                                                   |
| `refillv2_f6_swaps_flag`                             | 1, 2, 4, 12, 14          | ✅ Applied              | 2026-06-01 | Refill v2 Phase 2 / #8 F6 = "swaps toggleable". NEW KV table `refill_settings` (mutable config; SELECT for operators, DEFINER-only writes; seeds swaps_enabled=true) + DEFINER `set_swaps_enabled(enabled, machine_id?)` (global or per-machine). `engine_swap_pod` v9_2→v9_3 (verbatim repro, diff-gated): temp `_swaps_disabled_machines` + `NOT EXISTS` gate on both picked CTEs = disabled machine makes no swaps. Dara table, Cody ✅. Verified pg_proc + RLS + seed. TODO: Appendix A. Rollback in CHANGELOG.                                                                                                               |
| `refillv2_p2_learning_loop_capture`                  | 2, 4, 7, 8, 12, 14       | ✅ Applied              | 2026-06-01 | Refill v2 Phase 2 / #10 stage-1 = "edit-signals captured". 2 append-only tables `engine_recommendation_snapshot` (immutable, UNIQUE 5-tuple) + `refill_edit_signals` (typed signals + delta). Write-once DEFINER `snapshot_engine_recommendations`. Capture trigger `tg_capture_refill_edit_signal` on pod_refill_plan (manual-edit RPCs only, diffs vs snapshot). Seeded 10 rows from 2026-06-01 driver_feedback. Dara tables, Cody ✅. Verified RLS + trigger + seed. TODO: Appendix A. Rollback in CHANGELOG.                                                                                                                  |
| `refillv2_p2_learning_loop_feed_swaps`               | 1, 4, 12                 | ✅ Applied              | 2026-06-01 | Refill v2 Phase 2 / #10 stage-2a = "feeding the engine". `engine_swap_pod` v9_3→v9_4_signal_feedback (verbatim repro, diff-gated): temp `_suppressed_swap_subs` (swap_rejected ≥3 in 30d per machine,pod) + `NOT EXISTS` gate in sub_candidates = repeatedly-rejected substitute never re-proposed. Reads refill_edit_signals (read-only). Cody ✅. Verified pg_proc v9_4. Stage-2b (qty-bias, raise-missed-items) deferred. Rollback in CHANGELOG.                                                                                                                                                                               |
| `20260601200000_rd01_create_plan_add_machine`        | 2, 3, 4, 5, 8, 12, 14    | 📝 FILE — pending apply | 2026-06-01 | Refill-Day RD-01. machines_to_visit +add_source (status already allows cs_added); DEFINER `add_machine_to_plan(plan_date,machine_id,confirm)` (cs_added/operator/is_included/confirmed; idempotent; refuses repurposed) + `create_refill_plan(plan_date,machine_ids[])` (atomic loop; NEVER runs engine — confirm gate preserved). Cody ✅ (design).                                                                                                                                                                                                                                                                              |
| `20260601210000_rd05_fefo_pick`                      | 4, 5, 8, 12, 15          | 📝 FILE — pending apply | 2026-06-01 | Refill-Day RD-05. pod*refill_plan +preferred_wh_inventory_id; read-only INVOKER `get_shelf_fefo_options(machine,boonz)` (FEFO, warehouse_stock>0); edit*/add_pod_refill_row extended via NO-DROP wrapper (8-arg→9-arg+pin). Diff-gate: 9-arg body = live + param + pin-expiry guard + 1 assignment. Cody ✅ (design; #6 wrapper precedent).                                                                                                                                                                                                                                                                                       |
| `20260601220000_rd03_driver_self_service`            | 2, 3, 4, 5, 7, 8, 12, 14 | 📝 FILE — pending apply | 2026-06-01 | Refill-Day RD-03. refill_dispatching +driver_outcome(+qty/at/by); NEW `driver_recommendations` (RLS own-SELECT + DEFINER-only write); `driver_report_dispatch_outcome` (auto action_tracker on not_done; idempotent; never mutates qty/action) + `driver_propose_adjustment` (writes rec+driver_feedback+action_tracker). ⚠️ ownership-model caveat: no dispatch_plan/driver-assignment exists → role+active-line guard only; Cody verdict in summary.                                                                                                                                                                            |
| `20260601230000_rd06_per_row_source`                 | 1, 4, 5, 8, 12, 14       | 📝 FILE — pending apply | 2026-06-01 | Refill-Day RD-06 (Phase 2; FIX-1-irrelevant, keys off the plan 5-tuple). pod_refill_plan +source_warehouse_id (FK warehouses) + CHECK (WH-id only for warehouse source, NOT VALID). `set_refill_row_source` = the ONE source writer (retires raw-UPDATE source_origin): warehouse(+WH)/internal_transfer(delegates to mark_internal_transfer)/vox_at_venue; refuses non-draft. Open: E8 orphan-REMOVE sweep on flip-back. Cody ✅.                                                                                                                                                                                                |
| `20260601240000_rd04_shelf_move`                     | 1, 4, 5, 8, 12, 14       | 📝 FILE — pending apply | 2026-06-01 | Refill-Day RD-04 (Phase 2; keys off pod_inventory.shelf_id, FIX-1-irrelevant). NEW `shelf_layout_changes` log; `move_shelf_product` archive-then-seed paired move (empty-B move / occupied-B swap), atomic, same-machine, locked-row guard, respects idx_pod_inv_active_shelf, NO planogram edit, p_confirm diff. Cody ✅.                                                                                                                                                                                                                                                                                                        |
| `20260601250000_rd02_po_in_refill`                   | 1, 4, 6, 8, 12           | 📝 FILE — pending apply | 2026-06-01 | Refill-Day RD-02 (Phase 2; keys off boonz_product_id, FIX-1-irrelevant). purchase_orders +origin/origin_plan_date/origin_boonz_product_id. `request_po_in_refill` delegates to create_purchase_order (paired driver_task) + box-round + VOX block + origin link. `receive_po_in_refill` delegates to receive_purchase_order (warehouse role). ⚠️ CORRECTIONS: add_stock absent→receive_purchase_order; supplier_id uuid; Art.6 proposal-CREATE writer absent→operator-receive refused (flagged).                                                                                                                                  |

---

## Refill reliability batch — applied 2026-06-04 (PRD `docs/prds/PRD_refill_reliability_2026-06-03.md`)

| Migration name | Articles | Status | Date | Note |
| ------------------------------------------------ | ----------------- | --------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------- |
| `phaseF_stitch_gate_confirm_on_write_ok` | 1, 4, 8, 12, 14 | ✅ APPLIED | 2026-06-03 | WS1a. Gate `confirm_stitched_plan` on `write_refill_plan` returning `status='ok'`; else `skipped_write_failed` + leave pod `approved`. Kills silent whole-machine dispatch loss (stranded VML-1003). |
| `refillv2_ws5a_recommendation_intents` | 1, 2, 4, 5, 8, 12 | ✅ APPLIED | 2026-06-04 | WS5a. NEW `recommendation_intents` table (status `proposed→confirmed→applied                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | rejected`), RLS + no-direct-write policies. |
| `refillv2_ws5b_recommendation_rpcs` | 1, 2, 4, 5, 8, 12 | ✅ APPLIED | 2026-06-04 | WS5b. propose/confirm/reject/apply RPCs; `apply_*` renormalizes per-machine `mix_weight` to 1.0, requires `status='confirmed'`. NOTE: engine still reads `split_pct` (follow-up). |
| `refillv2_ws7_pending_enriched_reader` | 4, 8, 12 | ✅ APPLIED | 2026-06-04 | WS7. Read-only `get_refill_plan_output_enriched(plan_date)` joins live shelf stock + 7d sales (replaces stitch 0/0 placeholders). |
| `refillv2_ws2a_skip_dispatch_line` | 2, 4, 8, 12 | ✅ APPLIED | 2026-06-04 | WS2a. `skip_dispatch_line` writer + 4 cols on `refill_dispatching` + allow-list entry. Unfulfillable line no longer hard-blocks submission. |
| `refillv2_ws2b_push_edit_aware` | 1, 4, 8, 12 | ✅ APPLIED | 2026-06-04 | WS2b. `push_plan_to_dispatch` v5 edit-aware: re-push consumes-and-links a manually reworked dispatch row instead of clobbering it (VML A01 fix). |
| `refillv2_ws4a_driver_feedback_demand_view` | 4, 8, 12 | ✅ APPLIED | 2026-06-04 | WS4a. `v_driver_feedback_demand` view: unresolved asks, 14d decay, boonz→pod. |
| `refillv2_ws4b_engine_driver_demand` | 1, 4, 8, 12, 14 | ✅ APPLIED | 2026-06-04 | WS4b. `engine_add_pod` v13: driver demand as GREATEST floor (`clamp_reason='driver_request'`), self-resolves once planned; §1 suppression + gate-zero preserved. |
| `refillv2_ws6_suppress_zero_anywhere` | 1, 4, 8, 12, 14 | ✅ APPLIED | 2026-06-04 | WS6 + WS1b. `stitch_pod_to_boonz` v17: multi-variant REMOVE/M2W resolution (FEFO + even split + physical fallback) + 0-stock-anywhere variant suppression (warehouse-only). Confirm gate merged inline (verified live). |
| `prd018_bugc_resilient_dispatch_bridge` | 1, 4, 5, 8, 12 | ✅ APPLIED | 2026-06-04 | PRD-018 BUG-C. `push_plan_to_dispatch` → v6_resilient_bridge: per-row BEGIN/EXCEPTION so one raising row no longer aborts the whole machine's bridge; internal_transfer skipped (bridges via swap_between_machines); idempotent cover-link; failures→`monitoring_alerts`. `trg_fire_dispatch_on_approval` stops silently swallowing (logs non-ok/exception). Verified in rolled-back tx. Cody ✅. |
| `prd018_bugc_bridge_severity_fix` | 1, 4, 8, 12 | ✅ APPLIED | 2026-06-04 | PRD-018 BUG-C follow-up. `monitoring_alerts.severity` CHECK ∈ (info,warning,critical); the bridge failure/exception alerts used invalid `'error'` (would raise inside the handler). Forward `CREATE OR REPLACE` re-tagging both to `'critical'`. Caught by rolled-back verification before any failure path fired. |
| `prd018_buge_guardrail3_pack_variant` | 1, 8, 12, 14 | ✅ APPLIED | 2026-06-05 | PRD-018 BUG-E. NEW non-blocking BEFORE UPDATE trigger `flag_multivariant_pack_without_variant_confirmation()` on `refill_dispatching` (fires `packed` false→true) → `monitoring_alerts` (`prd018_guardrail3_pack_variant_unconfirmed`, warning) when the pod resolves to >1 boonz variant for the machine AND no `variant_action_log` correction exists. Counts machine-specific OR global-default mappings (closes guardrail 2's global-pod blind spot). Outbound sibling of PRD-016 guardrail 2. Verified in rolled-back tx. Cody ✅. FE (packer variant pick) → Stax. |
| `prd018_buge_guardrail3_message_fix` | 1, 8, 12 | ✅ APPLIED | 2026-06-05 | PRD-018 BUG-E follow-up. Advisory pointed at invented `action_type pack_variant_change`; `variant_action_log` CHECK only allows return_variant_change/return_variant_split/dispatch_substitution/dispatch_extra_variant. Re-pointed at existing `dispatch_substitution`. Message-only; trigger logic unchanged. |
| `prd018_bugd_availability_shared_batch` | 1 (design) | ⛔ HELD | 2026-06-05 | PRD-018 BUG-D. Drafted view-only fix for shared-WH availability →0; **Cody-blocked + withdrawn** — drop of the `reserved_for_machine_id` exclusion in `v_dispatch_availability` would desync the display from `pick_wh_batch_for_machine` (which still excludes held batches). Correct fix needs a reservation-semantics decision on canonical writer `pack_dispatch_line` → **Dara**. Not applied. |
| `prdunify_step1_pod_refill_plan_decision` | 1, 8, 12, 14 | ⏳ DRAFT | 2026-06-05 | PRD-UNIFY Step 1. `ALTER pod_refill_plan ADD COLUMN decision jsonb` + COMMENT. The single blended decision the card reads. Additive, defaulted NULL. Cody ✅. ✅ APPLIED (live; engine v14 + Step-4 reader depend on it). |
| `prdunify_step2_compute_refill_decision` | 1, 4, 12, 14 | ⏳ DRAFT | 2026-06-05 | PRD-UNIFY Step 2. NEW read-only INVOKER STABLE `compute_refill_decision(machine_id,shelf_id,boonz_product_id,days_cover)` — the ONLY source of `target_units` + `final_score` (stance dials, 0.6·v7+0.4·v30, drain stances, final_score algebra). Verified in rolled-back tx vs PRD acceptance (A2/A4/A5). Cody ✅. ✅ APPLIED (live; re-created by unifycal with tuned dials). |
| `prdunify_step3_engine_add_pod_v14_calibrate` | 1, 4, 8, 12, 14 | ✅ APPLIED | 2026-06-07 | PRD-UNIFY Step 3 — APPLIED on CS green light ("apply both"). `engine_add_pod` v13→v14: sizing delegates to `compute_refill_decision(machine,shelf,NULL,10)` (calibrated dials), rides full `decision` in `pod_refills.reasoning`; visual_floor heuristic ×10. PRESERVED from v13: §1 wh_avail clamp, GREATEST(refill,driver_req) floor, strategic-intent skip, capacity clamp, driver_feedback resolve. WIND DOWN/ROTATE/DEAD drain (decision target ≤ current). Verified live `v14_prd_unify_decision`. |
| `prdunify_step3_finalize_pod_decision_propagate` | 1, 8, 12 | ✅ APPLIED | 2026-06-07 | PRD-UNIFY Step 3 follow-up — APPLIED. `engine_finalize_pod(date,uuid[])` carries `pod_refills.reasoning->'decision'` into `pod_refill_plan.decision` (refill_lines reasoning + `decision` column through `unioned`; swap lines NULL; `decision`/`EXCLUDED.decision` in upsert) so committed drafts persist the card's number (A1). Verified live `v13_subset_aware_decision`. |
| `prdunify_step4_get_machine_slots_repoint` | 1, 12, 14 | ✅ APPLIED | 2026-06-07 | PRD-UNIFY Step 4 — APPLIED on CS green light. DROP+CREATE `get_machine_slots_with_expiry` → returns `decision`/`final_score`/`stance`; target+score+badges from the decision; sorts by Final Score; stops calling `compute_strategy` for target/score (deprecated, left in DB). FE `refill/page.tsx` moves in lockstep (`next build` ✅). Cody ✅. APPLIED 2026-06-07; days_cover passes 10 (PRD-UNIFY-CAL); verified live (calls_decision=true, still_calls_strategy=false; AMZ/VOXMCC smoke test 16/16 rows scored). **FE deploy via git push to main still PENDING — DB+FE must land in lockstep.** |
| `rd01_create_plan_add_machine` | 2,4,5,8,12,14 | ✅ APPLIED 2026-06-07 | 2026-06-06 | RD-01. `machines_to_visit` +`add_source`; `add_machine_to_plan` + `create_refill_plan` (operator/superadmin/warehouse + service-role bypass; cs_added/operator/is_included/confirmed; idempotent; health snapshot; NO engine). Status CHECK left untouched (already has cs_added). **`pick_machines_for_refill` ON CONFLICT reclaim NOT applied** — held for a byte-diff vs live before touching the core writer. Verified live (pg_proc). Cody ✅. |
| `rd05_expiry_aware_fefo_pick` | 4,8,12 | ✅ APPLIED 2026-06-07 | 2026-06-06 | RD-05. `pod_refill_plan.preferred_wh_inventory_id` (FK ON DELETE SET NULL) + `get_shelf_fefo_options(machine_id,boonz)` read-only INVOKER (FEFO across source WHs, nearest-expiry default, warehouse*stock>0). `v_effective_expiry` doesn't exist → uses `expiration_date`. \*\*Writer extension (edit*/add_pod_refill_row +pin) HELD\*\* until PRD-UNIFY applied. Verified in rolled-back tx. Cody ✅. NOT applied. |
| `rd03_driver_self_service` | 2,3,4,5,7,8,12,14 | ✅ APPLIED 2026-06-07 | 2026-06-06 | RD-03. `refill_dispatching.driver_outcome*`; new `driver_recommendations` table + RLS (field own SELECT/INSERT, operator+ all, no field UPDATE/DELETE); `driver_report_dispatch_outcome` (ownership via `trip_events` proxy — no dispatch_plan exists; never mutates qty/action; no reverse picked_up; auto action_tracker; idempotent); `driver_propose_adjustment` (recs+driver_feedback+action_tracker). Verified in rolled-back tx. Cody ⚠️→cleared. NOT applied. |
| `refill_fix_autoconfirm_and_build_timeout` | 1,4,5,8,11,12 | ✅ APPLIED | 2026-06-07 | Refill reliability — 3 bugs in `build_draft_for_confirmed`. (1) DEADLOCK: cron picks but never confirms → Gate-0 awaiting_confirmation → no nightly draft ever. Now PERFORMs canonical `confirm_machines_to_visit` at top (auto-confirm for drafts; CS amended keep-human-confirm rule — gates stay at approve+stitch). (2) TIMEOUT: full-fleet build hit 120s default → atomic rollback → zero draft. NOTE 2026-06-08: the function-level `SET statement_timeout` is INEFFECTIVE (Postgres arms the timer at top-level statement start; an in-function SET can't lift it). REAL FIX is in cron job 13's command: `SET statement_timeout='1200000'; SELECT build_draft_for_confirmed(CURRENT_DATE+1)` (separate SET statement, honored). Verified: one-off cron build of 2026-06-09 succeeded in 306s, 180 rows / 30 machines. FE/manual on-demand still capped by role/gateway timeout → needs the same SET prefix or an async path. (3) NO FINALIZE: build ran 2a+2b but not 2c, so pod_refill_plan stayed empty + FE "Load draft" blank. Now chains `engine_finalize_pod(date)`. Cody ✅ (Articles 1/4/5/8/11/12; writes via canonical RPCs only). Verified live (proconfig + body). End state: 8pm cron yields a ready editable full-fleet draft, zero manual steps. |
| `unifycal_compute_refill_decision_dials` | 4 | ✅ APPLIED | 2026-06-06 | PRD-UNIFY-CAL. Re-CREATE read-only INVOKER `compute_refill_decision` with the 3 delta-validated dials: `p_days_cover` DEFAULT 7→10, KEEP floor 0.60→0.70, RAMPING floor 0.50→0.60. Diff = exactly those 3 (verified: old 0.60/0.50 gone; cover_mults, other floors, drain rule, final-score weights unchanged). Delta plan 2026-06-05 (129 rows): total 375→316, KEEP 194→168 (−26), RAMPING 58→42, WIND DOWN/ROTATE/DEAD = 0 — the Tuned profile. Steps 1-2 are LIVE; the engine v14 file (`prdunify_step3…`) updated to pass `days_cover := 10`, still HELD (Hard Rule 10). |

| `prd042_p0_slot_profile_pools` | 1,2,4,12,14,16 | ✅ APPLIED | 2026-06-20 | PRD-042 P0. New `physical_type_lane_family` (14→7 families, RLS read-only), `slot_pool_curation` (RLS read-only, empty/derived-only), `slot_profile_pool` (precomputed cache, 921 rows, RLS read-only) + `rebuild_slot_profile_pool()` writer DEFINER + pg_cron `rebuild_slot_profile_pool_nightly` 15:30 UTC (before job 13 @16:00) + first rebuild. Replay green (SP1/SP6 + coverage 14/14). Cody ✅. swaps_enabled untouched. |
| `prd042_p1_engine_swap_pod_v15_slot_profile` | 1,4,12,16 | ✅ APPLIED | 2026-06-20 | PRD-042 P1. `engine_swap_pod` v14 → v15_slot_profile. Pass-3 candidate universe = precomputed `slot_profile_pool` for the slot's (lane_family, shelf_size) ∩ live `_p3_cand` guardrails; `cand_cap = pool fill_qty`. Replay SP1-SP6 + R1 all pass. swaps_enabled=false (no-op); engine_add_pod byte-identical (md5 244de950…, T12). Surgical DO-block, drift-guarded. Cody ✅. |
| `prd043_p0_days_until_next_vox_day` | 16 | ✅ APPLIED | 2026-06-20 | PRD-043 P0. `days_until_next_vox_day(date)` IMMUTABLE helper, no table access. Days to next Wed/Fri. Cody ✅. |
| `prd043_p1_pick_machines_for_refill_v11` | 1,12,16 | ✅ APPLIED | 2026-06-20 | PRD-043 P1. `pick_machines_for_refill` v10 → v11. VOX venue gate on normal-day `ranked_primary` (Option B runway-only override, tag `vox_emergency_offday`). NOT flag-gated (live pick). Replay V1/V2/V3/V5/V6/R1 + V4-neg pass; VOX-day byte-identical to v10; V4-pos logic-verified not live-reproduced. Surgical DO-block. Cody ✅. |

| `prd044_p0_packing_confirm_state` | 2,12,14 | ✅ APPLIED | 2026-06-21 | PRD-044 P0. `refill_dispatching.not_filled_reason`; `dispatch_pack_confirmation.final` (default true); `v_machine_pack_status` re-exposed with `pack_final` + `pack_state` (open/in_progress/completed). Additive. Cody ✅. |
| `prd044_p1_confirm_two_mode` | 1,4,5,8,12 | ✅ APPLIED | 2026-06-21 | PRD-044 P1. 5-arg `confirm_machine_packed(...,p_final)` two-mode (Save=false→in_progress never blocks; Finish=true→completed blocks on unresolved); 4-arg delegates to Finish (no drop). `pack_dispatch_line` records `not_filled_reason`. T1-T12 replay green. Cody ✅. |
| `prd045_p0_wh_commitment_correctness` | 1,2,4,12,16 | ✅ APPLIED | 2026-06-21 | PRD-045 P0. `v_dispatch_availability`/`v_dispatch_pickable` commitment fix: `reserved_by_earlier` excludes cancelled/skipped/not_filled/packed + earlier-OTHER-machine only (no self-commit); `oversubscribed` flag; available floors at 0. Read-model only; no fn consumes it (engine/stitch untouched). T1-T10 green. Cody ✅. |
| `prd046_stitch_v26_multivariant_spread` | 1,4,8,12 | ✅ APPLIED | 2026-06-21 | PRD-046. `stitch_pod_to_boonz` v25_wh_pickable_unified → v26_multivariant_spread. Distribution CTEs only: drop on-shelf collapse (spread across all WH-available variants) + on_shelf leftover tie-break. AMZ-1029 A07 17 → 6/5/4/1/1 (conservation). ADD/SWAP/FINALIZE byte-identical. Cody ✅. |
| `prd047_p0_swap_dispatch_shelf` | 1,4,8,12 | ✅ APPLIED | 2026-06-21 | PRD-047 P0. `swap_dispatch_shelf(...)` atomic Remove + Add New via canonical `add_dispatch_row` (title-case, WH-sourced, FEFO at pack, edit-log audit). T3/T4 (atomicity) green. FE shelf-grouped page = needs deploy. Cody ✅. |
| `prd047v2_swap_shelf_pod` | 1,4,8,12,16 | ✅ APPLIED | 2026-06-23 | PRD-047 v2. `swap_shelf_pod(date,uuid,uuid,uuid,text)` pod-level whole-shelf swap: Removes every current Refill/Add line on the shelf at current qty, then Adds New the new pod spread across WH-available variants at shelf capacity (`v_shelf_max_stock`) via the new read-only helper `spread_pod_qty(...)` (a faithful replica of the stitch v26 distribution; stitch keeps its inline copy — kept in sync). Composes `add_dispatch_row` (no direct write); pre-validates non-empty spread. T3/T3b(sum==cap, split==stitch)/T4(atomic) green in BEGIN..ROLLBACK. swaps_enabled untouched. FE pod-swap dialog = needs main deploy. Cody ✅. |
| `prd063_p1_pick_urgency_params` | 2,16 | ✅ APPLIED | 2026-06-28 | PRD-063 step 1. NEW config singleton `pick_urgency_params` (id=1 CHECK id=1; RLS SELECT true + write operator_admin/superadmin/manager) holding the shelf-aware urgency knobs (horizon, A/B floors, grade+component weights, expiry/stale norms+overrides, cooldown, p1/p2 thresholds, driver_capacity). Seeded to CS-locked defaults. Mirrors the `refill_priority_params` pattern (config for v_machine_priority, NOT a separate metric). Single-row guard T6 PASS. Cody ⚠️→✅. |
| `prd063_p2_v_shelf_sales_identity` | 16 | ✅ APPLIED | 2026-06-28 | PRD-063 step 2. NEW canonical per-(machine, pod_product_id) shelf-velocity/identity resolver view. Joins `v_live_shelf_stock` (enabled non-broken slots) to `sales_history` 30d/7d velocity (Success-only — same definition as `v_machine_velocity`), resolving sales names via `pod_products`/`product_name_conventions` tiers + a scoped pod alias (Hunter↔Hunter Ridge). Exposes facings/stock/cap/dvel/dos/resolved/has_sales. Identity coverage 100% (≥95 gate). Cody ✅ (registered as canonical product-grain velocity). |
| `prd063_p3_v_machine_priority_urgency_rewrite` | 12,14,16 | ✅ APPLIED | 2026-06-28 | PRD-063 step 3. `v_machine_priority` rewritten IN PLACE (CREATE OR REPLACE, no shadow/_v2) to the shelf-aware urgency model; supersedes the PRD-058 machine-level body. Every prior output column preserved (sourced unchanged from v_machine_health_signals/machines/shelf_u25); p_tier/p_score/reasons_arr recomputed from urgency; appends urgency/soonest_a_dos/grade_a..d_count; CROSS JOIN pick_urgency_params. New main-P1 reproduces the CS-locked list (drops MC-2004/ALJLT-1015-0200/NOVO-1023, adds ADDMIND-1007 hero + GRIT-1022 stale, keeps the 5 expiry machines). T1 reproduces (live, 100ms<800), T3 picker reads view (parity), T4 cards read view, T5 engines don't reference (byte-identical, swaps_enabled false), T7 rollback file restores prior body verbatim (`_ROLLBACK_prd063_*`). Picker/FE untouched. Cody ✅. |
| `release_stale_wh_pins` | 1,4,11,12 | ✅ APPLIED 2026-07-02 (git backfill 2026-07-04) | 2026-07-04 | Wave-2 B0 prod-sync. Hourly sweeper (pg_cron job 34, :50) clearing warehouse_inventory.reserved_for_machine_id pins with no in-transit packed line. Applied via Cowork MCP 07-02; git file backfilled byte-equivalent from the prod registry, filename carries the prod version (20260702150753) so db push skips. |
| `weimi_product_alias_and_phantom_monitor` | 2,12,16 | ✅ APPLIED 2026-07-02 (git backfill 2026-07-04) | 2026-07-04 | Wave-2 B0 prod-sync. weimi_product_alias table + 20 seed pairs + v_pod_phantom_stock monitoring view. Backfilled byte-equivalent (prod version 20260702154429). |
| `wh_provenance_enum_add_missing_values` | 12 | ✅ APPLIED 2026-07-03 (git backfill 2026-07-04) | 2026-07-04 | Wave-2 B0 prod-sync. wh_provenance_reason_enum CHECK now includes dispatch_partial_remainder + expiry_writeoff (credit_dispatch_remainder / warehouse_expire_writeoff inserts were failing). Backfilled byte-equivalent (prod version 20260703152341). B0 also backfilled 5 older unsynced MCP migrations (agenda tracker flag, prd043 label bump, capacity audit x3) - see commit d0b0e26. |
| `prd072_p0_bind_fail_reason_columns` | 1,2,3,12,14 | ✅ APPLIED | 2026-07-04 | PRD-072. refill_dispatching.bind_fail_reason (CHECK no_stock/quarantined/inactive_batch/pinned_elsewhere) + bind_fail_at + partial index idx_rd_bind_fail_open. Written/cleared only by pack_dispatch_line. Dara design (no reserved_qty counter). |
| `prd072_p1_pack_dispatch_line_live_rebind` | 1,3,4,6,8,12,16 | ✅ APPLIED | 2026-07-04 | PRD-072 headline. pack_dispatch_line pre-flight validates every pick (Active, non-quarantined, in-date, pin NULL-or-mine, stock>=qty) with live FEFO re-bind via v_wh_pickable (bind_dispatch_fefo predicate); all-or-nothing; fail-soft status=bind_failed + machine-readable reason on the line; STOPS writing the whole-remainder reserved_for_machine_id pin (stock move = qty-scoped commitment; release_stale_wh_pins stays as legacy sweeper). Fixtures (a)-(e)+(g1,g2) PASSED in an always-rollback prod dry run before apply. Cody ✅. |
| `prd072_p2_confirm_retire_legacy_overload` | 1,4,12,13 | ✅ APPLIED | 2026-07-04 | PRD-072. DROPPED confirm_machine_packed(text,date,uuid,text) 4-arg delegate; 5-arg two-mode re-created WITH argument defaults (p_final DEFAULT true). ROOT CAUSE FIX: 5-arg had zero defaults so the FE named call resolved to NEITHER overload - every driver confirm failed 06-21..07-04 (dispatch_pack_confirmation empty since 06-26). 42725-class, PRD-071 push v7 precedent. Verified live via PostgREST with the FE arg shape. |
| `prd072_p3_provenance_registry_guard` | 12,15 | ✅ APPLIED | 2026-07-04 | PRD-072. check_provenance_reason_registry() (INVOKER, read-only) scans pg_proc for set_config('app.provenance_reason', literal) vs the wh_provenance_reason_enum CHECK; apply-time DO assert fails the migration on drift. First run caught its own regex gap (m2m_return digit) - fixed in-file. |
| `prd073_reweight_pod_splits` | 1,4,7,8,12 | ✅ APPLIED | 2026-07-04 | PRD-073. Canonical writer reweight_pod_splits(machine,pod,weights,reason,p_rebuild,p_dry_run DEFAULT true): rec flavors proportional x0.90, other mapped flavors share 0.10 evenly, 2dp residual on top rec flavor, post-write sum=100 assert, write_audit_log row. p_rebuild gates broken-sum pods + creates recommended-but-unmapped flavors. Accepts Active+Warehouse machines. Apply-time fixes folded into file: Warehouse scope, temp-table DROP-first (multi-call txns), is_global_default is GENERATED. Seeds applied (see CHANGELOG). Cody ✅. |
| `weimi_alias_tier_v_live_shelf_stock` | 12,16 | ✅ APPLIED | 2026-07-04 | Wave-2 B4. v_live_shelf_stock tier-4 'alias' (weimi_product_alias) after direct/case/conventions; rescued exactly the 17 drifted WEIMI slot rows (2 unmatched remain fleet-wide); 'Freakin Healthy Granola Bar' resolves 7/7. Deterministic multi-target pick (Active-mapping first). Column list preserved; downstream engine/health objects inherit via pod_product_id. Cody ✅ (canonical object evolved in place). |
| `prd073b_wsa_adyen_inventory_enum_and_drift_monitor` | 2,12 | ✅ APPLIED | 2026-07-04 | PRD-073 WS-A. CHECK machines_adyen_inventory_in_store_enum (NOT VALID -> VALIDATE; 'true' rejected - the FE boolean-toggle writer that blinded 12 machines is fixed in the same commit) + v_machine_eligibility_drift monitor (Active+Online machines with zero v_shelf_sales_identity rows). Known residue: 3 repurposed-but-Active machines + Pending Setup. Cody ✅. |
| `prd073b_wsb_v_machine_priority_v2_empty_lowfill` | 12,14,16 | ✅ APPLIED | 2026-07-04 | PRD-073 WS-B. v_machine_priority v2 IN PLACE: grade-weighted s_empty/s_lowfill terms in the urgency blend, reasons empty_shelves/low_fill_sellers/hero_shelf_empty, P1 escalation on empty A/B shelf count. 8 new pick_urgency_params columns (empty_wt_a..d, w_empty, w_lowfill, low_fill_pct_floor, p1_empty_ab_min - PRD-058 dial pattern). Appended cols s_empty/s_lowfill/empty_ab_count. T1-T5 dry-proofed then re-verified live (P1 9->10, NOOK via hero_shelf_empty; engines + picker md5 byte-identical). Dara+Cody ✅. |
| `prd074_p1_health_v3_stale_v2_canonical_clocks` | 13,16 | ✅ APPLIED | 2026-07-04 | PRD-074. get_machine_health v3 (DROP+recreate, 4 APPENDED keys: last_plan_date, last_plan_days, urgency_breakdown, reasons_arr; days_since_visit now = v_machine_health_signals executed-dispatch clock; old approved-plan MAX renamed to last_plan_*). get_stale_visit_signals v2: thin SELECT over the signals view, threshold = pick_urgency_params.stale_override_days (private >10 literal removed); output names kept for SignalsTab. Grep-proofed: sole consumer refill/page.tsx. Dry-proofed T1-T4. Cody ✅. |
| `prd074_p2_deprecate_legacy_generator_and_guard` | 12,13,16 | ✅ APPLIED | 2026-07-04 | PRD-074. auto_generate_refill_plan DEPRECATED (Article 13: SECURITY INVOKER + REVOKE ALL; zero callers; DROP eligible 2026-10-04). NEW check_priority_surface_consistency(): per-machine diffs get_machine_health vs canonical views (visit clock, score, tier, track, breakdown sum); 0 rows live at apply. |
| `prd075_wsa_repurpose_grace_eligibility` | 12,16 | ✅ APPLIED | 2026-07-04 | PRD-075 WS-A. v_live_shelf_stock is_eligible_machine gains the repurpose grace window (repurposed_at NULL OR older than pick_urgency_params.repurpose_grace_days, default 30; rollback = set 0). Full-fleet rolled-back diff: ONLY ACTIVATE-2005 / IFLYMCC-1024 / MPMCC-1054 flip f->t. v_machine_eligibility_drift refined to should-be-eligible machines (inventory 'Live%'); 0 rows live. CS ruling: repurposed_at is permanent relocation history, never NULLed. |
| `prd075_wsb_manual_refills_count_as_visits` | 12,16 | ✅ APPLIED | 2026-07-04 | PRD-075 WS-B (the VOX fix). v_machine_health_signals days_since_visit = GREATEST(executed dispatch evidence, latest pod_inventory_audit_log 'manual-refill-%' event). Proven rolled-back: VOXMCC-1005 22d -> 0d on a manual-refill row; guard 0 diffs. get_machine_health inherits via pass-through. |
| `prd075_wsc_expose_urgency_terms` | 12,16 | ✅ APPLIED | 2026-07-04 | PRD-075 WS-C. v_machine_priority +s_runout/s_capacity/s_expiry/s_stale output columns (EXPOSURE ONLY; p_tier+urgency invariance 0 diffs over 30 machines, rolled-back full-fleet proof). **View md5: before `a49cd7d37e1ebf088f36351d54f646ac` -> after `97e69fa0049ee90262a35766e537a880` (expected, recorded per gate).** |
| `prd075_wsc2_health_breakdown_split_guard_v2` | 12,13,16 | ✅ APPLIED | 2026-07-04 | PRD-075 WS-C part 2. get_machine_health urgency_breakdown lumped core chip SPLIT into runout/capacity/expiry/stale (runout carries rounding residual; sum == urgency exactly, 0 mismatches fleet-wide). check_priority_surface_consistency v2 adds chip_runout/chip_capacity/chip_expiry/chip_stale fields (round-normalized text compare); 0 diffs live. Closes the PRD-074 carry-forward. |
| `prd075b_adjust_refills_count_as_visits` | 12,16 | ✅ APPLIED (chat MCP; git backfill 2026-07-05) | 2026-07-05 | PRD-075 follow-up (CS ruling). Logged inventory reconciliations (reference_id 'adjust-%') reset the visit clock, same as 'manual-refill-%'. Backfilled byte-equivalent (md5-verified), prod version 20260704160955. |
| `prd075c_dispatched_or_packed_counts_as_visit` | 12,16 | ✅ APPLIED (chat MCP; git backfill 2026-07-05) | 2026-07-05 | PRD-075 follow-up 2. last_visit dispatch evidence broadened: picked_up OR returned OR dispatched OR packed (was dispatched AND packed). Approved-only plans never count. FINAL live body of v_machine_health_signals. Prod version 20260704161446. |
| `prd075d_eligibility_drift_sales_truth` | 12,16 | ✅ APPLIED (chat MCP; git backfill 2026-07-05) | 2026-07-05 | PRD-075 follow-up 3. v_machine_eligibility_drift = sales-truth test: Active + sold in 7d + zero grading rows = drift, regardless of labels (caught MPMCC-1058 'Pending Setup' with real P1-level urgency and NISSAN-0804 'Switched off' selling 44/wk). Prod version 20260704162039. |

WS3 (inventory reconciliation: VML receive + 2 WH transfers) intentionally NOT applied — pending per-row CS sign-off. A naive `receive_dispatch_line` on the VML lines would inflate inventory: no consumer reservation exists (WH never debited at pack), so receive would create pod stock without debiting WH. Correct path = pack-reserve→receive per line with CS validating physical reality.

---

## How to add a new entry

1. Apply the migration via `mcp__supabase__apply_migration` with a descriptive name (`phaseX_NN_description`).
2. Add a row to the table above (or the appropriate section) with the date, the Constitution article(s) it enforces, and a one-line note in CHANGELOG.md.
3. If the migration deprecates anything, also update the deprecation tracker in `RPC_REGISTRY.md`.

## Migration naming convention

`phase{A|B|C}_{step}_{verb_noun}` — e.g., `phaseA_a3_audit_log_infra`, `phaseB_b2_machines_canonical_rpc_only`.

Forward-only. Never reuse a name. If a migration was bad, write a new one that fixes it (and document the why in CHANGELOG.md).

## 2026-07-16 — PRD-100 (applied via MCP)

- `f1_structured_capture_tables` — creates refill_events + refill_event_lines (Appendix A), RLS, indexes.
- `f2_record_actual_refill` — creates record_actual_refill (canonical atomic refill writer).
  | 20260718071500_prd102_d1_swap_shelf_pod_qty | swap_shelf_pod (5-arg dropped, 6-arg created) | operator-decided swap quantity; wh_limited clamp |
  | 20260718072000_prd102_d2_decline_swap_pair | refill_dispatching_edit_log CHECKs + decline_swap_pair (new) | Don't-swap decline with reason + swap_rejected signal |

---

## 2026-07-12 P0 incident package

| Migration                                                                                                                                                 | Objects                                                  | Nature                                                                                  |
| --------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| p0_fix1_weimi_slot_guard_block                                                                                                                            | refill_policy_params (config UPDATE) + monitoring_alerts | guard warn→block                                                                        |
| p0_fix2_engine_add_pod_scoped_drift_skip                                                                                                                  | engine_add_pod(date,integer)                             | CREATE OR REPLACE, surgical (PRD-CLEAN-09 block only; md5-diff verified)                |
| p0_fix3_write_refill_plan_scoped_delete                                                                                                                   | write_refill_plan(date,jsonb)                            | CREATE OR REPLACE, surgical (4 changes; g8→g8+scoped-delete)                            |
| p0_fix4_drift_monitor_v2                                                                                                                                  | cron_slot_binding_drift_alert()                          | CREATE OR REPLACE full body v2                                                          |
| p0_fix6_add_dispatch_row_is_m2m                                                                                                                           | add_dispatch_row                                         | CREATE OR REPLACE, surgical (is_m2m column+value only)                                  |
| p0_fix7_dup_guard_identity_scope                                                                                                                          | prevent_duplicate_unstarted_dispatch()                   | CREATE OR REPLACE, surgical (2 hunks)                                                   |
| p0_fix8 / p0_fix8b                                                                                                                                        | sweep_inactivate_stale_zero_stock(text) NEW              | new narrow-concern writer (proposal queue + status via sanctioned auto-confirm pattern) |
| Rollbacks: fix1 = UPDATE back to 'warn'; fix2/3/6/7 = originals preserved in session /tmp *_orig.sql and re-derivable from this registry's prior entries. |

## 2026-07-12 engine rebuild wave

| p0_fix9 | product_mapping (data) | Hunter Ridge single-homing |
| p0_fix10 | engine_add_pod | WEIMI-first identity + wh dedupe + drift plans-true-product |
| p0_fix11 | stitch_pod_to_boonz → v30 | variant substitution + markers + unfilled_shortfalls |
| p0_fix12 | engine_swap_pod | scoped drift skip + WEIMI-first identity |
| p0_fix13 | find_substitutes_for_shelf | real deduped scoped stock + volume-aware rank + decommission guard |
| p0_fix14 | refill_settings (data) | swaps_enabled=true |
| p0_fix15 | propose_decommission_plan ×2, propose_rebalance_plan | pod-inventory dedupe |
| p0_fix16 | get_pod_refill_draft, v_refill_planning_compact, v_warehouse_at_risk | UI read-path dedupe |
| p0_fix17 | product_mapping (data) + 2 partial unique indexes | 4,280 noise rows deactivated |
| 20260714010000_prd100_ws1a_hole_params | pick_urgency_params | 9 hole-signal tuner columns (hole_frac, hole_wt_a..d, holes_norm, w_holes, p1/p2_holes_min) |
| 20260714010500_prd100_ws2_v_shelf_holes | v_shelf_holes (new view) | per-slot hole state, canonical (PRD-100) |
| 20260714011000_prd100_ws3_v_machine_priority_holes | v_machine_priority, get_machine_health, check_priority_surface_consistency | s_holes term + hole overrides/tokens (w_holes-gated) + holes chip |
| 20260714011500_prd100_ws1b_weight_reseed (data, applied last) | pick_urgency_params (data) | guarded reseed 0.50/0.15/0.20/0.15 → 0.35/0.10/0.12/0.13 |
| 20260714012000_prd100_fix1_chip_holes_format | check_priority_surface_consistency | chip_holes guard row '0' vs '0.00' format parity |

## 2026-07-12 Suitability Swap Engine

| wave1_shelf_size_backfill | shelf_configurations (+shelf_size col, 2583 backfill) | protected; audit GUCs |
| wave1_product_size_fit | product_size_fit NEW table + RLS + seed (217 rows) | reference; Appendix A |
| wave1_coexistence_krambals_zigi | coexistence_rules +1 (Krambals&Zigi family) | config |
| wave2_rank_slot_suitability_fn | rank_slot_suitability() NEW | read-only INVOKER helper |
| wave2_engine_swap_pod_rewire | engine_swap_pod (Pass 2a → rank_slot_suitability) | CREATE OR REPLACE, minimal |

| `20260718133205_prd103_edit_po_line_expiry_unlock_post_receipt` | 2026-07-18 | `edit_purchase_order_line` CREATE OR REPLACE (forward-only, rebuilt from live) | Received lines: warehouse/operator_admin/manager may correct EXPIRY only (qty/price superadmin-only). Adds `post_receipt_expiry_edit` audit flag. PO record only. Cody Articles 1,4,5,6,8,12. |

## 2026-07-28 VOX SOA reconciliation wave (Cody-reviewed; CS per-row approval on data rows)

| recon_fix1_lvlup_terminal_id | machines (data, 1 row, audit GUCs) | LVLUP-2015 adyen_unique_terminal_id ...993605 (VOX MPMCC-1054's) -> ...993390 (own, validated from store LVLUP_2015_0000_R0) |
| recon_fix1b_stale_terminal_ids | machines (data, 13 rows, audit GUCs) | NULL stale terminal claims on Inactive machines whose terminal has exactly one Active owner; JET-2001/WH2-2001 pair (...499563, both Inactive) deliberately untouched |
| recon_fix2_attributed_view_dedupe | v_adyen_transactions_attributed | LATERAL LIMIT 1 on m_current + history joins: structurally one row per adyen txn (was fanning out when >1 Active machine claimed a terminal: 211 May-Jun VOX baskets doubled, +6,039.83 phantom captured); security_invoker=true preserved; 3 columns appended (refunded_amount_value, refund_date, net_captured_value) |
| recon_fix3_adyen_refund_backfill_mayjun | adyen_transactions (data, 6 rows) | refunded_amount_value = captured (FULL-refund assumption per CS, true-up if Adyen shows partials); net_captured_value self-corrects |
| recon_fix4_pd_summary_refund_net | get_payment_default_summary | refunds = actual refunded_amount_value (was gross captured of refunded baskets); captured_net no longer double-subtracts refunds; semantics tag matched_only_v2_2_refund_amount |
| recon_fix5a_vox_consumer_report_refunds | get_vox_consumer_report | refund = refunded_amount_value (was adjusted=gross); refunded baskets matched via refund-row psp (were shown wallet/unmatched); refunds excluded from default stats; summary +total_refunded/+refunded_txns; recent_txns +'refunded' status/+refunded amount |
| recon_fix5b_vox_commercial_report_refunds | get_vox_commercial_report | refund = refunded_amount_value; captured_amount now GROSS of refunds so net_revenue subtracts refund exactly once (was double-subtracted, net ~611 low over May-Jun); refunded baskets carry 0.50 fixed fee on net-0 capture (matches SOA) |

## PRD-105 Expiry Truth at Shelf Grain (APPLIED 2026-07-28, read-path only)

| Migration name                   | Article(s)         | Status             | Note                                                                                                                                                                                                                                              |
| -------------------------------- | ------------------ | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `expiry_truth_batches_regrain`   | 12, 16             | ✅ Applied to prod | `v_machine_expiry_batches` dedupe re-grained to `(machine, COALESCE(shelf::text,'noshelf'), boonz_product_id)` via ROW_NUMBER; recovers 285-ish dropped siblings (not-null rows 698→975). 0-collision precondition verified. Old md5 `f2f6397d…`. |
| `expiry_truth_index`             | (non-mutating DDL) | ✅ Applied to prod | Partial index `idx_pod_inventory_active_shelf_expiry (machine_id, shelf_id, expiration_date) WHERE status='Active' AND current_stock>0`.                                                                                                          |
| `expiry_truth_slots_shelf_keyed` | 12, 16             | ✅ Applied to prod | `get_machine_slots_with_expiry` re-keyed product-name→shelf_id; name-keyed CTEs removed; `expiry_qty` unconditional; scorer arg = shelf highest-stock boonz (inert). Old md5 `f57322b3…`.                                                         |
| `expiry_truth_orphan_live_aisle` | 12, 16             | ✅ Applied to prod | `get_machine_orphan_expiry` off-aisle branch (`shelf_id IS NULL OR NOT IN live_shelf`); `live_boonz` exclusion kept. Old md5 `e5e19b3c…`.                                                                                                         |

## PRD-106 Machine-level swap recommender (APPLIED 2026-07-29, additive read-only)

| Migration name                       | Article(s) | Status             | Note                                                                                                                                                                                                                                                                                                        |
| ------------------------------------ | ---------- | ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd106_recommend_swaps_for_machine` | 1, 16      | ✅ Applied to prod | New read-only `recommend_swaps_for_machine(date,uuid,int)` (plpgsql STABLE, INVOKER, zero writes). Machine-level distinct-K swap recommender; reads canonical `v_wh_pickable` (WH dedup, no fan-out) + `get_candidate_affinity`. Engine wiring PARKED for the Wave-2 engine-freeze (PRD-094/095 collision). |

## PRD-107 Pack-stage truth (APPLIED 2026-07-29, backend; FE built NOT deployed)

| Migration name                                  | Article(s) | Status             | Note                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ----------------------------------------------- | ---------- | ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd107_pack_outcome_no_pack_needed_enum`       | 12         | ✅ Applied to prod | Adds `no_pack_needed` to pack_outcome enum.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `prd107_pack_outcome_backfill_and_constraint`   | 12, 16     | ✅ Applied to prod | Backfills packed=true/outcome-NULL rows (4,143 fleet-wide, not the 10 the PRD estimated); constraint packed=true ⇒ pack_outcome NOT NULL ships NOT VALID (6 legacy May-2026 M2M rows unfixable without inventing source-machine identity; still blocks all new/updated rows, probe-proven). ⚠️ AUDIT NOTE: the backfill deliberately LOGGED rather than suppressed — ~4,137 `bypass_violation_log` rows dated 2026-07-29 from this migration are BACKFILL ARTIFACTS, not genuine canonical-write bypasses. Do not read them as incidents. |
| `prd107_v_dispatch_pack_progress`               | 16         | ✅ Applied to prod | Single source of truth for pack-close: packable_n (Refill/Add New/Add), resolved_n, driver_action_n, orphaned_swap_legs, ready_to_pack_close. Article-16 collision with registered `v_machine_pack_status` resolved by repointing that view at this one (Cody block #1).                                                                                                                                                                                                                                                                  |
| `prd107_confirm_machine_packed_view_backed`     | 4, 16      | ✅ Applied to prod | confirm_machine_packed reads the view (FE/RPC divergence structurally impossible; 460 machine-dates, 0 parity mismatches). Added to `enforce_canonical_dispatch_write` allowlist (Cody block #2: orphan flags would have logged as bypasses). Orphaned-swap-leg guard included.                                                                                                                                                                                                                                                           |
| `prd107_stamp_no_pack_needed_driver_legs`       | 12         | ✅ Applied to prod | Driver-side legs (Remove/M2W/M2M-source) stamped `no_pack_needed` via UPDATE, not at INSERT: BEFORE-INSERT stamping would fire `conserve_split_dispatch_quantity` and corrupt split Remove quantities (probe: 38→38 conserved). Covers all FIVE packed=true writers with one trigger.                                                                                                                                                                                                                                                     |
| `prd107_auto_resolve_driver_legs_at_pack_close` | 4, 12      | ✅ Applied to prod | Auto-resolve at pack close, NOT board-only fix: `mark_picked_up` only flips packed=true rows and `driver_confirm_remove` raises on unpacked — packer toggle was load-bearing in the Remove state machine.                                                                                                                                                                                                                                                                                                                                 |

Carry-forwards (PRD-107): pgTAP suite (assertions ran as rolled-back SQL probes only) · 6 legacy rows under NOT VALID constraint · FE deploy pending (tsc clean, build green, lint 147 pre-existing) · PRD-106 B6/B7 engine rewire + `p_exclude_in_machine` overload PARKED under PRD-094/095 engine freeze (7-arg overload would create 42725 ambiguity per RPC_REGISTRY.md:372).

## PRD-106b Size-up gating (APPLIED 2026-07-29, engine helper only; PRD-094/095 freeze NOT touched)

| Migration name                        | Article(s)       | Status             | Note                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------------------------- | ---------------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd106b_sizeup_requires_double_down` | 1, 4, 12, 13, 15 | ✅ Applied to prod | `rank_slot_suitability` (read-only INVOKER helper consumed by engine_swap_pod) size-up gate gains `AND is_dd`: a duplicate facing is only recommendable when an existing facing carries slot_lifecycle.signal='DOUBLE DOWN' (CS rule 2026-07-29). Root cause of the 07-29 "duplicate swap" incident: all 3 dups (Barebells MC A15, CCZ MC A06, CCZ HUAWEI A12) were deliberate `suitability_size_up` picks whose existing facings were only KEEP. engine_swap_pod itself NOT edited — PRD-094/095 parking claims stand, no override needed. Probes: target (MC A15: no Barebells/CCZ) + control (HUAWEI A12: normal ranks unchanged) both pass. Cody verdict recorded in-session. |
| `prd106b2_exclude_evian_1l_swapin`    | 1, 12, 15        | ✅ Applied to prod | `universe` CTE excludes pod 990461ff (Evian - 1L) — standing CS guardrail "Evian 1L never a swap-in"; hole surfaced by the PRD-106b probe (ranked #3 on MC A15); parity with recommend_swaps_for_machine which already excluded it. Post-apply probe clean.                                                                                                                                                                                                                                                                                                                                                                                                                       |

## PRD-108 — Volume-Driven Size-Up (2026-07-29)

Replaces the machine-relative `proven_machine_pctile >= 0.80` size-up test in
`rank_slot_suitability` with three absolute volume tests plus a machine-level floor.
Thresholds are the CS sign-off of 2026-07-29 following a read-only 90d calibration pass.

| Migration                                                                   | What                                                                                                                                                                                                                                  |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd108_sizeup_params`                                                      | 4 additive columns on `refill_policy_params`: `sizeup_min_vel_per_day` 1.25, `sizeup_overflow_factor` 1.25, `sizeup_vs_alternative_factor` 1.3, `sizeup_min_machine_units_wk` 30                                                      |
| `prd108_rank_slot_suitability_volume_tests`                                 | DROP+CREATE (return type gains `sizeup_rationale jsonb`). T1 velocity floor, T2 overflow, T3 opportunity-cost vs the rank-1-by-suitability newcomer, machine floor. `is_present` / `NOT is_blended` / `is_dd` (PRD-106b) all retained |
| `prd108_v_sizeup_candidates` + `prd108_v_sizeup_candidates_rank1_benchmark` | Phase 2b weekly DOUBLE DOWN proposal surface (`earns_double_down`, `dd_proposal`). Proposes only; the function remains the gate                                                                                                       |
| `prd108_recommend_swaps_dd_parity`                                          | `recommend_swaps_for_machine` DD exception now also requires floor + T1 + T2 (T3 structural there)                                                                                                                                    |

**Calibration corrections that changed the build** (details in `docs/prds/PRD-108-EXECUTION-LOG.md`):
`machine_vel` falls back to `ppad` (units per SELLING day), overstating calendar velocity 23.6x mean /
90x max. Used for T1 it passed 286 false positives; used for T3's benchmark it inflated the OMDCW
newcomer 0.258 -> 1.462 and failed the star case. A parallel calendar-day `proven_cal` was introduced
for the size-up path only; `proven_raw` is untouched so candidate ranking is unchanged.

**Cody:** approve with revisions — Article 16 blocked inline velocity; T1 repointed at canonical
`v_shelf_sales_identity.dvel`, machine floor at `v_machine_velocity`. Articles 1, 2, 4, 12, 13, 14, 15, 16.
**Not done:** pgTAP suite (acceptance criterion unmet).
`engine_swap_pod` NOT edited - PRD-094/095 freeze intact (`rank_slot_suitability` is not Family-A).

## PRD-109 — Pre-Flight Refill Gate (2026-07-29) — PARTIAL

| Migration                                                | What                                                                                                                                                                                            |
| -------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd109_preflight_refill_plan`                           | `preflight_refill_plan(p_plan_date date)` -> `(verdict, violations, warnings, checked_at, invariant_versions)`. READ-ONLY FOREVER, STABLE, SECURITY INVOKER, no overload. Implements INV-01..12 |
| INV-06 conservation fix (assertion-guarded substitution) | Children matched across both REMOVE and M2W parents; removed 3 false positives                                                                                                                  |

**Cody:** approve, class (c) read-only. Articles 4, 12, 13, 14, 16. Reads canonical objects only
(`v_wh_pickable`, `v_live_shelf_stock`, `v_dispatch_pack_progress`). Zero write statements.

**Verified:** 2026-07-29 replay -> FAIL in **310 ms** (budget 10 s), citing INV-03 on the named
Barebells / Coca Cola Zero duplicate facings and INV-04 on the named MC-2004 A15 orphan.

**NOT DONE:** the stitch gate is NOT wired (`stitch_pod_to_boonz` unchanged, no `p_force`); no pgTAP;
no frozen 07-29 fixture; no FE. See `docs/prds/PRD-109-EXECUTION-LOG.md` for the reasons.
Key finding: every WH aggregation must dedupe by `wh_inventory_id` BEFORE any mapping join, and the
INV-01/02 name family is Active mappings at ANY scope UNION same `product_family_id` - never name
prefix matching (`Hunter` would swallow `Hunter Ridge`).

### PRD-109 continued (2026-07-29)

| Migration                                                                      | What                                                                                                                                                                                              |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd109_stitch_preflight_gate`                                                 | `preflight_override_log` (append-only, Article 7) + stitch DROP 2-arg / CREATE 4-arg with `p_force`, `p_force_reason`. **Applied as blocking - superseded within minutes, see next row**          |
| `prd109_preflight_enforcement_warn_mode`                                       | `refill_policy_params.preflight_enforcement` ('warn'\|'block', DEFAULT 'warn'). Gate honours it. **SHIPS AS 'warn'** - the flip to 'block' is a manual CS decision after ~7 plan dates of burn-in |
| INV-02 tighten + INV-07/INV-11 differentiate (assertion-guarded substitutions) | warnings 89 -> 26/date; INV-11 9 -> 1                                                                                                                                                             |

Cody class (b) reviewed before the gate apply: Articles 1, 2, 4, 6, 7, 8, 12, 13, 16.
`stitch_pod_to_boonz` is NOT in the frozen Family-A set; PRD-094/095 freeze untouched.
`pg_proc` = 1 row for stitch - all 4 DB callers + FE bind to the 4-arg defaults (42725 avoided).

## PRD-110 P1.1 — truth layer: operating models + product sourcing (2026-07-30, relay leg 5)

| Migration                                                        | What it does                                                                                                                                                                                                                                                                                                                                                                                             |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260730150001_prd110_p11_machines_operating_model`             | `machines.operating_model` text NULL + CHECK (fully_managed\|co_managed\|partner_managed) + `v_machine_operating_model_proposed`. SPEC CORRECTION: shipped NULLABLE, not the spec's NOT NULL — the same clause parks the backfill for CS review, and a NOT NULL column with a parked backfill cannot exist. NULL = unclassified, and every operating-model rule is INERT while NULL (no silent default). |
| `20260730150002_prd110_p11_product_sourcing_table`               | `product_sourcing` append-only edge table + RLS (SELECT only, no write policy) + `tg_product_sourcing_append_only` + `tg_product_sourcing_model_guard` + audit trigger. Append-only is enforced by TRIGGER, not RLS: the canonical writer is DEFINER and bypasses RLS, so an RLS-only rule would bind nothing.                                                                                           |
| `20260730150003_prd110_p11_product_sourcing_writers_and_readers` | `v_product_sourcing_current`, `resolve_product_sourcing_v3` (INVOKER), `v_product_sourcing_model_conflicts`, `set_product_sourcing_v3`, `set_machine_operating_model_v3`.                                                                                                                                                                                                                                |
| `20260730150004_prd110_p11_backfill_product_sourcing_v3`         | `backfill_product_sourcing_v3` (idempotent, insert-only) + PARKED `apply_proposed_operating_models_v3`. Backfill executed: **4022 edges**.                                                                                                                                                                                                                                                               |
| `20260730150005_prd110_p11_fixture5_p1_sourcing_assertions`      | Fixture 5 seq 10 re-phased P1 → P2; new seq 11/12/13/14 = the P1-layer acceptance tests.                                                                                                                                                                                                                                                                                                                 |
| `20260730150006_prd110_p11_fixture105_seq10_rephase`             | Fixture 105 seq 10 re-phased P1 → P2 (LAW 8 bisect: it reads `blocked_demand` = engine output).                                                                                                                                                                                                                                                                                                          |

Cody class (a) DDL on protected entity (`machines`, Appendix A) + (a) new table + (b) writer DEFINER ×3 + (c) read-only helper.
Articles checked: 1, 2, 3, 4, 7, 8, 12, 14, 16. `machines.operating_model` is written ONLY by
`set_machine_operating_model_v3` — a raw UPDATE would violate Articles 1 and 3, which is why the
parked activation is an RPC call and not an UPDATE statement.
Article 14: `product_sourcing` holds sourcing DECISIONS and their history, which no view can derive
(product_mapping is only the seed; the point is that CS edits the edges afterwards). Same standing
as `blocked_demand`. No ADR required.

### PRD-110 Phase 1 - P1.2 `shelf_state` canonical view (2026-07-30, relay leg 6)

| Migration                                                   | What it does                                                                                                                                                                                                                                                                    |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260730160001_prd110_p12_v_shelf_state`                   | `v_shelf_state` - the WS-A1 canonical shelf object. 656 rows = one per non-phantom shelf on an Active + `include_in_refill` machine. `security_invoker=true`, anon REVOKEd. Full column-by-column provenance in `docs/architecture/SHELF_STATE_DEFINITION.md`.                  |
| `20260730160002_prd110_p12_shelf_lifecycle_autoprovision`   | `provision_shelf_lifecycle_v3(shelf_id)` (canonical single-shelf lifecycle writer, DEFINER, idempotent) + `tg_provision_shelf_lifecycle()` + `tg_provision_shelf_lifecycle_ins` AFTER INSERT ON `shelf_configurations` WHEN `NOT is_phantom`. Closes the coverage-regrowth gap. |
| `20260730160003_prd110_p12_fixture3_shelf_state_assertions` | Fixture 3 seq 10–18 (`phase_required='P1'`): coverage, no fan-out, fleet-wide G2, WEIMI-identity-only, sourcing totality, explicit NULL placeholders, S-10/S-06 truth layer, guarantee installed, velocity-grain safety.                                                        |

Cody class (a) DDL on protected entity (`shelf_configurations` + `slot_lifecycle`, both Appendix A) + (b) writer DEFINER + (c) read-only view.
Articles checked: 1, 2, 3, 4, 8, 11, 12, 14, 16.
Article 1 - `provision_shelf_lifecycle_v3` is the canonical SINGLE-shelf lifecycle writer;
`seed_missing_slot_lifecycle` remains the canonical BATCH writer. Both apply the identical scope
guard (`status='Active' AND include_in_refill`), so they cannot disagree about who is in scope.
Article 4 - the DEFINER sets `app.via_rpc`/`app.rpc_name`; role validation is skipped ONLY when
`app.via_trigger='true'`, i.e. when the parent `shelf_configurations` INSERT already carried its own
authorization. The trigger clears the GUC immediately after the call so provenance cannot leak to
later statements in the same transaction (PRD-016B lesson).
Article 14 - `v_shelf_state` is a VIEW, not a snapshot table, so the staleness test does not apply.
Article 16 - `days_since_visit` is a PASSTHROUGH of `v_machine_health_signals` (PRD-074 SSOT); it is
not re-derived. `current_stock` comes from `v_live_shelf_stock` via `v_shelf_slot_identity`, expiry
from `v_machine_expiry_batches`, sourcing from `v_product_sourcing_current` - every registered metric
is read from its canonical object.

## PRD-110 P1.4 (WS-J2) — inventory events + composition estimator · 2026-07-30 (relay leg 8)

| Migration                                           | What                                                                                   |
| --------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `prd110_p14_inventory_events_composition_anomalies` | 3 additive tables + 14 indexes + 7 triggers + 3 SELECT-only RLS policies               |
| `prd110_p14_inventory_event_writers_v3`             | 5 canonical `_v3` DEFINER writers + 5 `composition_*` params on `refill_policy_params` |
| `prd110_p14_composition_estimator_v3`               | `estimate_shelf_composition_v3` + `_estimator_rise_disposition_v3`                     |
| `prd110_p14_estimator_conservation_fix`             | fixed 2 real quantity-conservation defects in the estimator (see below)                |

Cody verdict on the DDL: ⚠️ approve with revisions; all three revisions incorporated BEFORE apply
(append-only trigger, audit triggers, shelf/machine consistency guard).

Article 1 - `record_inventory_event_v3` is the ONLY write path to `inventory_events` and the only
thing that moves a `shelf_composition` bucket. `raise_inventory_anomaly_v3` is the only writer of
`inventory_anomalies`. Enforced structurally: all three tables have a SELECT policy and **no**
INSERT/UPDATE/DELETE policy at all.
Article 2/3 - RLS enabled on all three; `authenticated` may only SELECT (role join via
`user_profiles`, `field_staff` included on events + composition for the driver collapse UI, excluded
from anomalies). `anon` REVOKEd on tables and functions.
Article 4 - every writer sets `app.via_rpc`/`app.rpc_name`, validates inputs, and applies the house
role gate: a NULL actor is permitted so cron/estimator can call it, a real caller must hold the role.
Article 7 - `tg_inventory_events_append_only` blocks UPDATE and DELETE at the row level. RLS alone is
insufficient because DEFINER RPCs and `service_role` bypass it. A bad event is corrected by a
compensating `correction` event, never by editing history.
Article 8 - `tg_audit_inventory_events` / `_shelf_composition` / `_inventory_anomalies` →
`audit_log_write(<pk>)`, the same pattern as `blocked_demand` and `product_sourcing`. NOTE:
`audit_log_write` logs unconditionally, so estimator-derived decrements double into `write_audit_log`;
exempting a self-auditing ledger would need an Article 15 amendment and was NOT assumed.
Article 12 - purely additive, `IF NOT EXISTS` throughout, no existing object altered or dropped.
Article 14 - **no ADR required.** None of the three materializes a query result: `inventory_events` is
an event log, `inventory_anomalies` an exception queue, and `shelf_composition` holds a value that
depends on event ORDER and confidence-decay history, which no SELECT can derive. Same reasoning that
exempted `blocked_demand`. (The `pod_refill_plan_shadow` ADR is a separate, still-binding obligation.)

**THE GRAIN DECISION — do not "simplify" this.** `shelf_composition` is keyed
`UNIQUE NULLS NOT DISTINCT (shelf_id, boonz_product_id, expiry_bucket)`. `expiry_bucket` is part of
IDENTITY because the EXPIRY IRON RULE requires an expired bucket to coexist with a sellable bucket of
the same product on the same shelf; collapse the key and the rule becomes unrepresentable.
`NULLS NOT DISTINCT` (PG 17.6) stops the unknown-expiry bucket from splintering into unbounded
NULL-keyed duplicates. `expiry_bucket IS NULL` means UNKNOWN and is treated as SELLABLE — the
fail-safe direction, since treating unknown as expired would freeze it from decrements forever and
inflate `est_qty` without bound.

**Two real conservation defects fixed in `prd110_p14_estimator_conservation_fix`:**
(1) the cold-start seed used `FLOOR()` of each `split_pct` share and dropped the remainder, seeding 11
units against a WEIMI count of 14 — a silent quantity loss. Replaced with a largest-remainder spread,
plus a conservation assertion that raises an anomaly when a pod's mapping genuinely cannot conserve
the count. (2) the drop allocator awarded remainder units without checking bucket headroom, so
`LEAST(est_qty, base+1)` could discard a unit; now only buckets with headroom win one and the residual
is computed from units actually taken.

## PRD-110 P1.4 acceptance fixtures + the two missing spec objects (2026-07-30, relay leg 9)

Three migrations, registry 33 → 36. Cody verdict: ⚠️ approve with revisions (Article 16 registry
entries + a residue assertion on every fixture); both revisions incorporated before apply.

| Version          | Name                                              | What                                                                  |
| ---------------- | ------------------------------------------------- | --------------------------------------------------------------------- |
| `20260730135658` | `prd110_p14_audit_prompt_and_expiry_action_views` | `v_shelf_audit_prompts` + `v_expiry_action_queue`, both INVOKER views |
| `20260730140130` | `prd110_fixtures_19_20`                           | fixtures 19 (venue fill) + 20 (expired never assumed sold)            |
| `20260730140354` | `prd110_fixtures_21_22`                           | fixtures 21 (driver confirm collapse) + 22 (multi-SKU decay)          |

**Why the two views exist.** BUILD SPEC P1.4 carries two clauses that leg 8 shipped params for but no
object: "flagged shelves only (top uncertainty x value-at-risk, max 3/visit)" and "expiry
auto-write-off lines require confidence >= 0.7, else a verify task". Without a DB object those rules
would have been implemented in the FE — recreating the exact defect P1.2 removed when it deleted the
FE's independent shelf scorer (G1 "one truth"). Both are views, so Article 14 does not apply: nothing
is materialized and nothing can go stale.

### ⚠️ The load-bearing pattern a future editor must not "simplify"

Fixtures 19-22 mutate **live** shelves and machines through the canonical `_v3` writers, then
**deliberately roll the mutations back** inside a plpgsql subtransaction:

```
BEGIN
  ... canonical writer calls, then build a jsonb of observations ...
  RAISE EXCEPTION 'GP20:%', payload::text;     -- rolls the subtransaction back
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM LIKE 'GP20:%' THEN payload := substring(SQLERRM from 'GP20:(.*)$')::jsonb; ELSE RAISE; END IF;
END;
INSERT INTO golden.scratch ...   -- outside the rolled-back block, so it survives
```

The observations travel out **through the exception message** because a `golden.scratch` INSERT placed
inside the block is rolled back with everything else (this was tried first and lost the payload).

**Why it must stay:** `inventory_events` is append-only and trigger-enforced, so a fixture that wrote
for real would deposit permanently undeletable test rows in a production ledger on every nightly
`run_all()`, and would not be repeatable (its own prior events change the next run's starting belief —
the estimator is idempotent per `(shelf, WEIMI snapshot)`). Deleting or renaming the `RAISE` sentinel
silently converts these fixtures into a production writer.

**Enforcement, per Cody:** every fixture carries residue assertions (seq 95-97, plus seq 98 on fixture
19 for `machines.operating_model`) that fail if the rollback ever stops holding. The rollback is
asserted, not assumed.

**Second reason the pattern is required:** it is what lets the fixtures use **belief** rather than
synthetic sensor data. Setting `shelf_composition` above the live WEIMI count makes the estimator see a
genuine drop, so fixtures 20 and 22 need no fabricated WEIMI snapshot and no synthetic machine.

**Evidence at apply:** fixture 19 15/15 · 20 20/20 · 21 13/13 · 22 19/19 = **67 pass / 0 fail**, run
**three consecutive times with identical results** (stress-suite S7 satisfied for the P1 set).
`run_all('P0')` = **47/0**, byte-identical to leg 8 — zero regression. Residue after every run:
`inventory_events` 0 · `shelf_composition` 0 · `inventory_anomalies` 0 · classified machines 0.

---

## PRD-110 P1.3 (relay leg 10) — the availability contract that retires the sentinel pattern

`prd110_p13_availability_contract` — three additive objects. No consumer rewired, no engine touched,
no row deleted. Cody classified (c) read-only, verdict ⚠️ approve with revisions; both revisions were
incorporated **before** apply.

- `_is_sentinel_wh_row_v3(text, date)` IMMUTABLE — THE single definition of a VOX fake-stock sentinel:
  `batch_id LIKE 'VOXSOURCE-%' AND expiration_date = '2099-12-31'`.
  ⚠️ **The conjunction is load-bearing, not defensive style.** 9 REAL PO-batch rows (202 units at
  WH_CENTRAL) carry `wh_location = 'VOX_SOURCED'`. A retirement keyed on `wh_location` would destroy
  real stock. Verified live: predicate selects exactly 40 rows and rejects all 9.
- `v_shelf_availability_v3` (`security_invoker`) — availability per pod-bound shelf.
  `available_units IS NULL` ⇒ unconstrained (venue/partner-supplied). Otherwise real Boonz WH stock
  with sentinels excluded. Also exposes `wh_units_sentinel`, `sentinel_backed`,
  `would_block_on_retirement` so the parked D-09 decision is a live view and can never go stale
  (Article 14).
- `resolve_shelf_availability_v3(uuid)` — per-shelf point lookup, a wrapper over the view so
  availability has exactly ONE definition for the engine (set) and stitch/pack (per line).

**Cody revision 1 (Article 16, the one that mattered):** the draft re-derived the WH-pickable
predicate inline. `v_wh_pickable` is the REGISTERED canonical object for that metric, and
`engine_add_pod` v19's inline copy is explicitly **grandfathered debt** — not a licence for new
objects. The view now consumes `v_wh_pickable`, exactly as `v_product_shelf_life` does.
Known divergence, stated rather than hidden: `v_wh_pickable` expires on the **Dubai** date and
requires `warehouse_stock > 0`; v19 inline uses `CURRENT_DATE` with no stock floor. Only a batch
expiring exactly today can differ; zero-stock rows add zero to a SUM.

**Cody revision 2 (Article 16):** disjointness from `v_wh_pickable` / `v_dispatch_availability` /
`v_dispatch_pickable` recorded in `METRICS_REGISTRY.md` with the reason, so a later "consolidation"
cannot silently drop the sourcing dimension.

**Evidence at apply:** 544 rows (463 boonz_wh · 75 venue · 6 mixed) · 75 unconstrained rows carry
`available_units IS NULL` · 61 shelves are sentinel-backed, of which 53 are venue (safe by
definition) · **`would_block_on_retirement` = 0 fleet-wide** · the 8 constrained sentinel-backed
shelves hold **≥195** real units against capacities of 14-25.

---

## PRD-110 P1.3 (relay leg 11) — golden fixture 24, and the retirement path measured rather than assumed

Two additive migrations. **`golden` schema only** — no `public` object created, altered or dropped,
no row deleted, no flag flipped, no cron touched, no engine body modified.

| version          | name                                      | content                          |
| ---------------- | ----------------------------------------- | -------------------------------- |
| `20260730144123` | `prd110_p13_golden_fixture_24_row`        | 1 row into `golden.fixtures`     |
| `20260730144214` | `prd110_p13_golden_fixture_24_assertions` | 34 rows into `golden.assertions` |

⚠️ **Version-ordering note for future legs:** these two carry real wall-clock versions
(`2026073014:41/14:42`), while legs 5-9 hand-assigned synthetic higher ones (`20260730150004`,
`20260730160003`). So `ORDER BY version` no longer equals apply order for PRD-110. Do **not** rewrite
the old versions to "fix" this — Article 12 is forward-only and the mismatch is cosmetic. Locate
migrations by name.

### TWO SPEC CORRECTIONS — the retirement writer is neither of the two previously named

Leg 10 corrected BUILD SPEC P1.3's `DELETE` to "inactivation via `inactivate_warehouse_row`". **That
correction was itself wrong**, and the fixture found it by probing the writer instead of trusting the
parked script:

1. `inactivate_warehouse_row` **refuses any row with `warehouse_stock > 0`** — and all 40 sentinels
   hold stock (686-999). Measured error: _"refusing to inactivate row with stock > 0
   (warehouse_stock=999, consumer_stock=0). Drain stock via apply_inventory_correction first."_
2. After draining to 0 via `apply_inventory_correction`, the AFTER-UPDATE trigger
   **`tg_propose_inactivate_on_zero_stock` writes an auto-confirmed proposal row and flips the row to
   `Inactive` itself**. A follow-up `inactivate_warehouse_row` call then fails _"row already in status
   Inactive"_.

**Canonical retirement is therefore ONE call per row**, and the status flip is the trigger's:

```sql
SELECT public.apply_inventory_correction(wh_inventory_id, NULL, NULL, NULL, 0,
         'PRD-110 P1.3 sentinel retirement: venue sourcing now makes this shelf unconstrained',
         '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid)
FROM public.warehouse_inventory
WHERE public._is_sentinel_wh_row_v3(batch_id, expiration_date) AND status = 'Active';
```

`v_wh_pickable` requires `warehouse_stock > 0` **and** `status='Active'`, so the drain alone already
removes a sentinel from availability; the trigger's flip is hygiene on top. Verified live: after the
drain a sentinel is absent from `v_wh_pickable` **and** already `Inactive`.

### Cody — Article 6 finding, PRE-EXISTING, recorded not resolved

Article 6 reads _"warehouse_inventory.status is set only by the warehouse manager via the canonical
RPC. No trigger, function, cron, n8n sync, or app flow may write it."_ Two live facts sit against it:

- `tg_propose_inactivate_on_zero_stock` **is a trigger that UPDATEs `warehouse_inventory.status`
  directly** — the only one on the table — and the retirement path depends on it.
- Article 6's stated enforcement hook is `app.rpc_name = 'set_warehouse_status'`, and
  **`set_warehouse_status` does not exist.** The live canonical writers are
  `inactivate_warehouse_row` / `reactivate_warehouse_row` / `confirm_warehouse_status_proposal`
  / `reject_warehouse_status_proposal`. `trg_detect_silent_warehouse_write` only _logs_, and only
  Pattern A (silent Inactive/0 → Active/N reactivation).

Grandfathered as RC-14 Tier 2a debt. It is **not** introduced by this migration and it is not a block
on a fixture that merely observes it. Flagged for CS because the parked D-09 activation now performs
its status change through a trigger rather than a manager RPC.

**Cody verdict:** ⚠️ approve with revisions — both incorporated before apply. (1) assert the
protected-entity `DELETE` never returns `SUCCEEDED` (seq 28) so it fails loudly if the FK is ever
relaxed, not merely if the error text changes; (2) record the Article 6 tension in
`golden.fixtures.notes` where the next leg reads it.

### Fixture 24 shape (34 assertions, all green first run)

Reuses the leg-9 pattern exactly: mutate live rows through canonical writers inside a plpgsql
subtransaction, `RAISE EXCEPTION 'GP24:%'` with a jsonb payload, catch, extract via
`substring(SQLERRM from 'GP24:(.*)$')`, INSERT to `golden.scratch` **outside** the block.

- **seq 1-5 preconditions.** 40 sentinel rows, all Active, all 40 in `v_wh_pickable`, 61
  sentinel-backed shelves. seq 1 doubles as a **D-04 tripwire**: if the population moves off 40,
  someone re-topped or minted and the fixture must be re-baselined.
- **seq 6-9 the headline.** SOA `BNZ/MAFE/2026-06/001` = **101,181.71** before AND after all 40 are
  retired; delta exactly 0; the registry row is re-read each run so the fixture cannot drift with it.
- **seq 10-12 the structural proof — stronger than the behavioural one, because it holds for every
  month, not just 2026-06.** `get_vox_consumer_report` does not contain the string
  `warehouse_inventory`; **25** revenue-shaped objects scanned; **0** read the table. seq 11 exists
  so a regex that silently matches nothing cannot be mistaken for evidence.
- **seq 13-18 the retirement happened.** 40 drained · 0 units left · 40 now `Inactive` · 0 pickable ·
  **+40 auto-confirmed status proposals** (the flip is provenanced, not silent).
- **seq 19-23 the load-bearing invariant.** The per-shelf `available_units` fingerprint is
  **byte-identical** (`5e2dbd4a07fc864aa72dc6ce27c5b8fb`) with all 40 sentinels retired, because
  `v_shelf_availability_v3` computes it with `FILTER (WHERE NOT is_sentinel)`. 544 rows unchanged ·
  `would_block_on_retirement` 0 **after** the act, not merely predicted 0 before it · venue shelves
  keep `available_units IS NULL` · sentinel-backing 61 → 0.
- **seq 24-28 both spec corrections proven live**, each captured as a real `SQLERRM`, not asserted
  from a count: the `DELETE` aborts on `inventory_audit_log_wh_inventory_id_fkey` (255 rows); the
  stocked-row refusal; the already-Inactive refusal; and the fail-loud guard.
- **seq 90 / 95-99 residue.** S-08 tripwire plus: 40 rows `Active` again · unit total restored exactly
  · `inventory_audit_log` unchanged · proposals unchanged · availability fingerprint back to baseline.

**Evidence at apply:** fixture 24 **34 pass / 0 fail on the first run**. `run_all('P1')` =
19:15 · 20:20 · 21:13 · 22:19 · 24:34 = **101 pass / 0 fail**, run **three consecutive times with
identical per-fixture results** (S7 satisfied for the P1 set). `run_all('P0')` = **47/0**,
byte-identical to legs 8-10 — zero regression. Live state re-verified independently after the runs:
sentinels **40 Active / 39,463 units**, proposals back to **1118** (1158 inside the block),
`inventory_audit_log` **15,227**, `inventory_events`/`shelf_composition`/`inventory_anomalies`
**0/0/0**, availability fingerprint unchanged, and **zero** `monitoring_alerts` raised.

---

## PRD-110 Phase 2 scaffold (relay leg 12, registered retroactively by leg 14 — S-19)

⚠️ **These two migrations were applied by relay leg 12, which then ended without logging them or
writing a RESUME POINTER.** Leg 13 found the objects live and undocumented and raised S-19; leg 14
dumped them from `pg_catalog`, verified every promise in `ADR-shadow-plan-tables.md` §7, and wrote
this entry. **Nothing was re-applied** — this is paperwork catching up to a correct apply.

| Version          | Name                                   | What it did                                                                                                                                                              |
| ---------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `20260730145843` | `prd110_p2_0_pod_refill_plan_shadow`   | `pod_refill_plan_shadow` — the LAW-4 shadow plan ledger `engine_add_pod_v3` writes instead of `pod_refill_plan`. 14 cols, 3 indexes, 10 constraints, RLS on, 3 policies. |
| `20260730145907` | `prd110_p2_0_v_shadow_vs_live_plan_v3` | `v_shadow_vs_live_plan_v3` — the Article-16 canonical v3-vs-v19 diff, `security_invoker=true`.                                                                           |

⚠️ **Version is NOT apply order here** (the standing PRD-110 caveat): `20260730145843` sorts _before_
the P1.1 (`2026073015xxxx`) and P1.2 (`2026073016xxxx`) migrations but was applied _after_ both.
Locate PRD-110 migrations **by name**, never by version ordering.

### ADR §7 verification (leg 14, from `pg_catalog` — every promise measured, none assumed)

| ADR §7 promise                       | Verdict | Measured evidence                                                                                                                                                                                                                                                                                      |
| ------------------------------------ | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Art 1 — single writer                | ✅      | `authenticated` holds `SELECT, REFERENCES, TRIGGER` only — **no INSERT grant** — and there is **no INSERT policy**, so RLS denies by default. Only `service_role` / a DEFINER writer can insert.                                                                                                       |
| Art 2/3 — RLS on, `anon` REVOKEd     | ✅      | `relrowsecurity = true`. `has_table_privilege('anon', …, 'SELECT')` = **false** on both table and view. `anon` appears in neither grant list.                                                                                                                                                          |
| Art 2/3 — reads limited to roles     | ✅      | Policy `pod_refill_plan_shadow_select` (cmd `r`, role `authenticated`) requires `up.role IN (warehouse, operator_admin, superadmin, manager)` via `(SELECT auth.uid())` — correct RLS idiom, not bare `auth.uid()`.                                                                                    |
| Art 2/3 — `security_invoker` on view | ✅      | `reloptions = {security_invoker=true}`.                                                                                                                                                                                                                                                                |
| Art 8 — append-only                  | ✅      | Policies `pod_refill_plan_shadow_no_update` (cmd `w`) and `…_no_delete` (cmd `d`), both `USING (false)`, both role PUBLIC. `run_id` + `produced_at` are the audit trail.                                                                                                                               |
| Art 12 — forward-only                | ✅      | Two new objects. Nothing dropped, downgraded, or re-signatured. `pod_refill_plan` untouched.                                                                                                                                                                                                           |
| Art 14 — ADR signoff                 | ✅      | `docs/architecture/ADR-shadow-plan-tables.md`, ACCEPTED, and **linked from the table's `COMMENT`** — obligation §8.4 discharged at apply time.                                                                                                                                                         |
| ADR §2 — column-compatible with live | ✅      | The 11 shared columns are exactly `pod_refill_plan`'s engine-output subset, **identical types**, and the `action` CHECK is byte-identical (`REFILL / REMOVE / ADD_NEW / M2W` — UPPERCASE in both). PK = the live PK **plus `run_id`**, so re-runs are additive-and-distinguishable, never destructive. |

**Deliberately unmirrored** (11 live-only columns): `status`, `approved_at/by`, `stitched_at`,
`created_at`, `updated_at`, `edited_at/by`, `linked_refill_pk`, `linked_swap_id`, `linked_intent_id`.
All lifecycle/approval fields the engine never produces. The diff view reads `live_status` from the
live table rather than storing it — coherent with the ADR.

### Two obligations that remain OPEN and are NOT closed by this entry

1. **ADR §7 Article 4** — "writer validates `plan_date`, refuses a date with non-pending live rows
   (LAW 12)". That is a property of `engine_add_pod_v3`, which **does not exist yet**
   (`pg_proc` count = 0). It must be built into the writer, not retrofitted.
2. **ADR §8.3** — "a golden assertion that `pod_refill_plan` row count is unchanged across any v3
   shadow run", carried on **every** Phase-2 fixture the way the S-08 tripwire (seq 90) rides on
   every engine-calling fixture. Owed by the fixtures, tracked as the **seq 91** tripwire.

`RPC_REGISTRY.md` gets the `engine_add_pod_v3` entry when the engine lands; there is no RPC to
register today.

### Known shape note for Phase 3

The shadow table carries **no** `linked_refill_pk` / `linked_swap_id`. If the P3.1 stitch ladder needs
a shadow line table (`pod_refills_shadow`, ADR §2), that pair must be **designed in**, not assumed
inherited.

## PRD-110 P2.1 in-stock velocity (relay leg 17, registered by leg 18)

⚠️ **Registered one leg late.** Leg 17 applied both migrations and then lost the database to a
runaway read-only SELECT (see below) before it could write this entry. It deliberately left the
registry blank rather than write it from memory (standing rule: registries are written from a live
`pg_catalog` read). Leg 18 wrote it after the DB recovered. **Nothing was re-applied.**

| Version          | Name                                     | What it did                                                                                                                                                                                                                                                               |
| ---------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260730170001` | `prd110_p21_v_weimi_shelf_history_v3`    | `v_weimi_shelf_history_v3` — historical WEIMI shelf state resolved to pod identity; a strict generalisation of `v_live_shelf_stock` over all snapshots. `security_invoker=true`. Measured live (leg 18): **79,094 rows, 44 machines**, 2026-03-31 → 2026-07-30 14:00:39Z. |
| `20260730170002` | `prd110_p21_v_shelf_instock_velocity_v3` | `v_shelf_instock_velocity_v3` — in-stock velocity at (machine_id, pod_product_id). `security_invoker=true`. ⚠️ **APPLIED BUT NEVER VERIFIED, AND TOO SLOW TO QUERY AS WRITTEN** (S-22).                                                                                   |

⚠️ **Version drift, corrected by leg 18.** These two were applied via the MCP, which assigns its own
apply-time version: they landed as `20260730160930` / `20260730161226` while the files on disk are
named `…170001` / `…170002`. Left alone, `supabase db push` would have seen both files as unapplied
and re-applied them. Leg 18 realigned the two `schema_migrations` rows to match the filenames (the
repo's recorded pattern for MCP version drift). Every earlier PRD-110 migration was already aligned.

**Resolver coverage over full history** (leg 18, live): direct 73,886 · conventions 2,455 ·
case_insensitive 1,108 · alias 591 · **unmatched 1,054** (1.33%). The four-tier resolver is lifted
verbatim from `v_live_shelf_stock`; a hand-rolled three-rung version diverged on 17.1% of keys
(leg-16 F5), so it must never be re-implemented.

**Equivalence invariant (Cody's Article 16 condition) — PROVEN EXACT at apply.** Restricting the
history view to the latest snapshot per device and applying the live view's own final
`DISTINCT ON (machine_id, cabinet, layer, slot_name)` reproduces `v_live_shelf_stock` row-for-row:
807 = 807, zero diffs on `pod_product_id`, `current_stock`, `match_method`, `is_eligible_machine`.
⚠️ A naive comparison that does **not** reproduce that final collapse shows a phantom 241-row gap —
do not "fix" it.

### ⛔ The P2.1 velocity view is UNVERIFIED and caused a production incident

Querying `v_shelf_instock_velocity_v3` with ~10 independent aggregates in one statement saturated
production for **~35 minutes** (2026-07-30 16:13→16:48 UTC): `execute_sql` connection timeouts,
PostgREST HTTP 522, platform status `ACTIVE_HEALTHY` throughout. The statement was a **read-only
SELECT** holding only ACCESS SHARE — no write blocking, no lock escalation, no corruption or
data-loss path, nothing half-applied. It self-terminated; the DB recovered on its own and leg 18
confirmed `pg_stat_activity` clean. **`cron 13` ran normally at 16:00 UTC in 29.7s — the nightly
advisory was never affected (LAW 12 intact), and no live plan table was touched.**

**Root cause** (leg 18, from the on-disk artifacts): the velocity view references the history view
**four times** — twice for `max(snapshot_at)` in `w`, plus `hist`, plus `snaps` — and each
evaluation re-runs a triple-LATERAL JSONB flatten of 79k rows plus four LATERAL resolver lookups per
row. Worse, `w` derives the window bounds _from the view itself_, so the 30-day predicate cannot
push down. Fix drafted (4 evaluations → 1) in `docs/prds/PRD-110-P21-PERF-FIX-PROPOSAL.md` —
**deliberately not a migration file** until its pre-flight assertions pass.

**Binding rule for anyone touching this view:** one cheap aggregate per statement, scoped to one
machine first, and always `SET statement_timeout` — a client timeout does **not** cancel the server
query. That is precisely how prod stayed saturated for 35 minutes.

### ✅ Perf fix APPLIED (leg 18) — `20260730170009_prd110_p21_velocity_v3_perf_single_flatten`

| Version          | Name                                         | What it did                                                                                                                                                    |
| ---------------- | -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260730170009` | `prd110_p21_velocity_v3_perf_single_flatten` | `CREATE OR REPLACE VIEW v_shelf_instock_velocity_v3` — 4 history-view evaluations → 1. Only `w` and `snaps` change; `hist` still reads the canonical resolver. |

Forward-only (Article 12): this **replaces the view body**, it does not edit `20260730170002`.
The view is now queryable fleet-wide in a single statement (687 series / 41 machines).

**Equivalence proven BEFORE apply, three independent assertions:**

| Assertion                 | Result                                                                                                                                                                          |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A1** anchor equality    | base(+`machines` join) max = raw base max = view max, all three `2026-07-30 14:00:39.507348+00`                                                                                 |
| **A2** snaps set-equality | base **1208 = 1208** view over the 30d window; `EXCEPT` both directions **0 / 0**                                                                                               |
| **A3** output equality    | **687 = 687** rows, only_old 0, only_new 0, **zero diffs** on `stock_hours`, `elapsed_hours`, `velocity_instock`, `velocity_status`, all five `n_case_*`, `t_start`, `t_anchor` |

Verified again **after** apply against the `_test` shadow (0 diffs), then the shadow was **DROPPED**.
`security_invoker=true` re-verified from `reloptions`; column list unchanged (18 cols — and
`CREATE OR REPLACE VIEW` errors outright if it changed, so that condition is self-proving).

⚠️ **This makes the view FAST and proves it did not change MEANING. It does not prove the meaning is
right** — the P2.1 oracle comparison is still outstanding, and the object stays 🔴 not-yet-canonical
in `METRICS_REGISTRY.md`. Perf work never promotes a metric.

⚠️ **Version drift did NOT recur here:** applied as `20260730170009` and the on-disk file is named
`20260730170009_…`. Checked deliberately, because leg 17's two migrations drifted (see above).

---

## PRD-110 P2.1 shelf-grain velocity split + fixture 19 re-phase (2026-07-30, relay leg 21)

Four migrations. `prd110%` count **44 -> 48**. All four were applied through the MCP `apply_migration`
channel, which stamps its own version and **writes no file** (the S-24 bug class), so each file was
written by hand afterwards and then **PROVEN identical** to `schema_migrations.statements` by
comparing md5 of the comment-stripped, whitespace-normalised text. **All four MATCH.** S-24 therefore
did **not** grow this leg - it stays at its original 12.

| version          | name                                               | what                                                                                                                                           |
| ---------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260730181405` | `prd110_p21_velocity_shelf_split_v3`               | NEW view `v_shelf_instock_velocity_split_v3` - shelf-grain in-stock velocity. Superseded twice below; file kept so the repo reproduces the DB. |
| `20260730181608` | `…_exact_conservation`                             | forward fix: stop rounding the two conserved velocity columns (rounding broke conservation by up to n×5e-7). **Not sufficient alone.**         |
| `20260730181902` | `…_residual_absorber`                              | forward fix: deterministic residual absorber for the ±1e-20 numeric-division residue. **FINAL body.** Conservation is now EXACT.               |
| `20260730182813` | `prd110_golden_fixture19_rephase_post_d07_premise` | fixture 19 seq 1 + seq 4 re-phased (NOT deleted) - their premise was "D-07 parked", and leg 20 applied D-07.                                   |

**Cody reviewed the view before apply** (Articles 2, 3, 12, 14, 16): a plain view, not a snapshot
table, so Article 14's staleness test does not bite and no ADR is needed; `security_invoker = true`
matching every sibling v3 view; grant to `authenticated` + `service_role` and **deliberately not
`anon`**, matching `v_shelf_state` rather than the two velocity/history views that do grant anon
(standing revoke-anon carry-forward). Verdict was ⚠️ approve-with-revisions on one point - Article 16
requires the new metric to be **registered** - which is why `METRICS_REGISTRY.md` gained its row in
the same atomic unit.

⚠️ **`CREATE OR REPLACE VIEW` may only APPEND columns.** The absorber migration first failed with
`42P16 cannot change name of view column "velocity_instock_pod" to "is_residual_absorber"` because the
new column sat mid-list. It is now appended last. Same rule that bit PRD-063.

⚠️ **Version drift did NOT recur, but it was CAUGHT rather than avoided:** the first file was
hand-named `20260730182000_…` before the apply, and the MCP stamped `20260730181405`. The file was
renamed to match. **Write the file after the apply, or rename it - never assume your chosen timestamp
is the one that lands.**

**Regression gates, both re-run after the work:** `golden.run_all('P0')` = 4 fixtures / **47 / 0**;
`golden.run_all('P1')` = 5 fixtures / **101 / 0** (after the fixture-19 re-phase; it was 13/2 on first
run this leg - see the EXECUTION-LOG bisect, it was a stale premise from leg 20's D-07 apply, not a
regression, and **P1 had not been run since leg 14**).

## PRD-110 relay leg 22 — 2026-07-30 (5 migrations, golden harness only)

All five touch the `golden` schema only. No protected entity, no `SECURITY DEFINER` in `public`,
no RLS, no cron, no engine body, no live plan table. Cody reviewed each before apply.
All five files were written **after** the apply (RISK 63) and proven identical to
`supabase_migrations.schema_migrations.statements` by md5 over the comment-stripped,
whitespace-normalised text — **5 of 5 MATCH**, so S-24 stays at 12.

| version          | name                                                             | what                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ---------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `20260730184635` | `prd110_golden_fixture19_events_in_txn_delta_not_absolute`       | Fixture 19 computed `events_in_txn` as an **absolute** `count(*)` of `inventory_events`, which read 0 only while D-08 was parked. CS-approved cron 44's first live run (18:40 UTC, 31 rows) turned it red on a true statement about the fixture and a false one about the table. Now an in-envelope delta, per fixture 21's house pattern. `expect` stays 0; strictly stronger.                                                                  |
| `20260730185730` | `prd110_p21_golden_fixture2_velocity_invariant_contract`         | **Fixture 2 built** — 41 assertions over `v_shelf_instock_velocity_v3` (I1–I9) and `v_shelf_instock_velocity_split_v3` (V1–V7, V2/V3 **exact**), plus the exact ratio identity `velocity_instock/velocity_raw = 720/stock_hours`, the anchor recorded, and a cross-object anchor-agreement check. Spec premise restated per S-20/S-04; original text preserved in `fixtures.notes`.                                                              |
| `20260730185938` | `prd110_golden_runner_phase_passthrough_and_vacuous_green_guard` | `run_all(p_phase)` filtered fixtures by phase but never passed it to `run_fixture`, so `run_all('P2')` returned **0 pass / 0 fail / passed=true**. Adds the pass-through and **Guard 3** (a run that evaluated nothing is not a pass). Advances `golden.config.current_phase` P1 → P2.                                                                                                                                                           |
| `20260730190011` | `prd110_golden_run_all_phase_gate_never_reduces_coverage`        | Forward fix to the above, caught before it was trusted: the first pass-through would have gated fixture 3 at `P0` and skipped its 9 P1 assertions (14 evaluated → 5). The gate is now the max of `p_phase`, `config.current_phase` and the fixture's own phase — **monotone: no argument to `run_all` can reduce coverage**.                                                                                                                     |
| `20260730190326` | `prd110_golden_acceptance_gate_expected_red_vs_regression`       | Adds `golden.assertions.acceptance_gate_sql` and `golden.runs.n_expected_red`. Distinguishes a **regression tripwire** (failure is a failure) from an **acceptance criterion** whose subject is not built yet (failure is `expected_red`). Evidence-based, not a phase label, so it self-retires: the 3 assertions waiting on `engine_add_pod_v3` become binding automatically the instant that function exists. A broken gate **fails closed**. |

**Why the acceptance gate exists.** Waking the 4 long-dormant P2 assertions turned `run_all('P0')`
red for a legitimate reason — they are acceptance criteria for an engine that has not been written.
LAW 8 halts phase work on any golden failure, so without this the loop's own halt-signal would have
been permanently jammed, and the human response to a permanently-red suite is to stop reading it.

## PRD-110 relay leg 23 — 2026-07-30 (1 migration, golden harness only)

`golden` schema only. No protected entity, no `SECURITY DEFINER` in `public`, no RLS, no cron,
no engine body, no live plan table, no flag. Cody reviewed before apply and returned
**⚠️ Approve with revisions**; all three revisions were applied before the migration ran.

| version          | name                                                    | what                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ---------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260730193530` | `prd110_p21_golden_fixture14_sensor_lie_clamp_contract` | **Fixture 14 built** — 26 assertions on the real 41-shelf / 16-machine `WEIMI count > capacity` population (no synthetic data). Estimator half green (clamp = capacity exactly, anomaly row per shelf, provenance, fleet-wide universality); plan half asserts "no negative / absurd qty" unconditionally on v19; three `engine_add_pod_v3` acceptance criteria are `acceptance_gate_sql`-gated and read **expected_red 5** today. |

**Cody's three revisions, all applied before apply:**

1. **A tripwire gap, found by enumerating the engine's write targets rather than assuming them.**
   `engine_add_pod` writes **four** tables (`pod_refills`, `pod_swaps`, `driver_feedback`,
   `monitoring_alerts`). The fixture covered three; `pod_swaps` was uncovered. Added as **seq 94**.
2. `golden.fixtures.notes` now records that seq 91/92/93/94 are **idleness** assertions (RISK 65) on
   tables cron 13 writes at 16:00 UTC — a red there is a **collision, not a regression**. seq 91's
   total-count form is ADR §8.3 verbatim and is kept rather than narrowed.
3. `monitoring_alerts` is **deliberately** untripwired (alerting sink, not state), and seq 8's
   `v_shelf_state` join makes it a violation detector rather than a fleet-completeness claim. Both
   stated in `notes` so neither reads as an oversight later.

**Constitutional class: (f) non-protected — measured, not assumed.** Appendix A was read directly:
`machines_to_visit`, `pod_refills`, `pod_swaps`, `driver_feedback` and `monitoring_alerts` appear in
the Constitution **zero times**. The scenario writes one non-protected table directly
(`machines_to_visit`) and reaches everything else by **calling** `engine_add_pod`, so Article 1 holds
by construction. Precedent: fixtures 3, 5 and 105 already invoke this engine on synthetic dates.

📌 **`plan_date` is derived, not declared — a landmine for the next fixture author.**
`golden.render` computes `{{plan_date}}` as `DATE '2030-01-01' + fixture_id` and **ignores the
`fixtures.plan_date` column entirely**. Fixture 14 therefore uses **2030-01-15**, matching fixtures 3
(01-04) and 10 (01-11). The leg-22 pointer proposed `2030-02-14`; that would have left the column and
the actual writes pointing at different dates. Fixture 2's `2030-02-02` is harmless only because
fixture 2 never uses the macro. `fixtures_plan_date_key UNIQUE (plan_date)` is what makes the
`+ fixture_id` convention collision-proof by construction.

📌 **File-parity recipe needs a trim step.** The file is proven identical to
`schema_migrations.statements` by md5 over the comment-stripped, whitespace-normalised text — but
**only after `btrim`/`.strip()`**. The MCP strips the trailing newline, so the raw lengths differ by
exactly 1 byte and the untrimmed md5 mismatches on a file that is in fact correct. Leg 22's recipe
omitted this. **1 of 1 MATCH**; S-24 stays at **12**.

---

## PRD-110 relay leg 24 — 2026-07-30 · P2.0b shadow at the engine-advisory grain (4 migrations)

**Why this leg exists at all.** The pointer's next task was `engine_add_pod_v3`. Reading the seven
gated acceptance assertions column by column _before_ writing any engine SQL showed the Phase-2
acceptance contract was **unsatisfiable by the existing shadow scaffold**: every gated assertion reads
`public.pod_refills` (`current_stock`, `max_stock`, `qty`, `clamp_reason`) or `public.blocked_demand`,
and `pod_refill_plan_shadow` — which mirrors `pod_refill_plan`, the plan/approval grain — carries none
of those columns. Creating the engine first would have produced a function that could prove nothing.

| Version          | Name                                                       | What it does                                                                                                                                                           |
| ---------------- | ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260730201143` | `prd110_p20b_pod_refills_shadow`                           | The table. Shadow triple + mirrored `pod_refills` grain + `velocity_instock` + `availability_basis`. 7 CHECKs, 3 FKs (NO ACTION), 2 indexes, RLS, append-only trigger. |
| `20260730201306` | `prd110_p20b_v_blocked_demand_shadow_v3`                   | The view. `_blocked_demand_gaps_v3`'s shape over the shadow, keyed by `run_id`, `security_invoker = true`.                                                             |
| `20260730201338` | `prd110_p20b_shadow_view_least_privilege`                  | Default privileges had left `authenticated = arwdDxtm` on the new view. REVOKE ALL + GRANT SELECT.                                                                     |
| `20260730201511` | `prd110_p20b_seq91_tripwire_extended_to_three_live_tables` | ADR §8.3 tripwire extended from `pod_refill_plan` alone to three live tables. Fixture 2 seq 92/93, fixture 14 seq 97.                                                  |

**Cody verdict: ⚠️ Approve with revisions — four, all applied before apply.**

1. **`ON DELETE RESTRICT` → NO ACTION** on all three FKs, mirroring `pod_refills` exactly. The
   principle: _a shadow must never constrain production more tightly than the live twin it shadows._
2. **A `BEFORE UPDATE OR DELETE` trigger**, because `CREATE POLICY … FOR UPDATE USING (false)` binds
   `authenticated` only and is bypassed by the SECURITY DEFINER writer and `service_role`. ADR §5
   guarantee (1) is load-bearing for the Article 14 signoff, so it needed enforcement that binds the
   writer. ⚠️ The precedent table `pod_refill_plan_shadow` still lacks this — **RISK 74**.
3. **`availability_basis = 'unknown'` must be paired with a `clamp_reason`** — otherwise the value is
   a silent-failure escape hatch and LAW 5 leaks through the one column added to close a LAW-5 gap.
4. **Extend the seq-91 tripwire to three live tables** before `engine_add_pod_v3` exists.

**📌 The best thing in this migration, and the pattern to repeat: LAW 5 as a CHECK constraint.**
`CHECK (qty > 0 OR clamp_reason IS NOT NULL)` makes a silent zero _unrepresentable_ rather than
merely detectable. It was safe to impose only because it was measured first — across all **3,841**
live `pod_refills` rows, **834** have `qty = 0` and **zero** have a NULL `clamp_reason`, so the
constraint is empirically true over the entire history of the table it mirrors and is not a novel
restriction. Two siblings do the same for availability. Where a law can be made unrepresentable,
prefer that to asserting it in a fixture.

**⚠️ `velocity_30d` is deliberately NOT mirrored** (S-13: the column is units-per-day despite its
name, and v19 reads it three mutually incompatible ways). The shadow carries `velocity_instock`,
daily by construction. ⚠️ **That column records what the engine used and is NOT a metric object** —
`v_shelf_instock_velocity_v3` stays 🔴 not-yet-canonical, gated on **D-10**. A later leg must not read
`pod_refills_shadow.velocity_instock` as the canonical velocity and route around that gate.

**Article 8, stated rather than silent:** the generic `audit_log_write` trigger is **not** attached.
`pod_refills`, `pod_refill_plan` and `blocked_demand` all carry it; this table does not, because it is
a non-protected diagnostic object taking ~544 INSERTs per nightly run, and `run_id` + `engine_tag` +
`produced_at` already answer "who wrote what, when". ADR §7 row 8's "if attached" hedge is now
resolved explicitly on both shadow tables.

**Proof, behavioural not structural.** 10 of 10 assertions inside a single rollback envelope: valid
INSERT accepted · UPDATE refused · DELETE refused · silent `qty=0` refused · `qty=0` **with** a
`clamp_reason` accepted · `boonz_wh` with NULL availability refused · `venue` with NULL availability
accepted (unconstrained is legal and must stay legal) · `unknown` without a reason refused · same
natural key under a **new** `run_id` accepted (re-runs additive, ADR §2) · duplicate within one
`run_id` refused. Residue after rollback: **0 rows**.

**Suites after:** 11 fixtures · **216 pass / 0 fail / 6 expected-red / 0 vacuous / 1 arrived-early**
(213 → 216, the three new tripwires; assertions 219 → 222). All three suites run per S-27.

**File parity: 4 of 4 MATCH** by md5 with `.strip()`/`btrim` on both sides (RISK 71). S-24 stays at
**12** — no new file-less migrations.

---

## PRD-110 relay leg 25 — golden harness: the estimator no-op premise guard

### `20260730204005_prd110_p14_golden_estimator_noop_premise_guard`

**Class (f) — golden schema only.** No production object, no protected entity, no SECURITY DEFINER,
no RLS, no cron, no engine body. Cody-reviewed as class (f) with two revisions, both applied before
apply.

**What it closes.** `estimate_shelf_composition_v3` is idempotent per WEIMI snapshot per shelf —
`prosrc` line 59-60 takes an `already_processed_skipped -> CONTINUE` branch keyed on
`source_ref = 'estimator:<snapshot_at>'`. Fixtures **20** and **22** are the only two of the eleven
that call the estimator, and both call it on a **live** shelf. Once any caller (i.e. cron 44) has
consumed the current snapshot for that shelf, the fixture's own call writes nothing and every
assertion downstream of it measures a no-op.

**Measured, not inferred** (rollback envelope, leg 25): first call `events_written=7 /
already_processed_skipped=0`; second call `events_written=0 / already_processed_skipped=1`.

**Why it is not cosmetic.** Fixture 20 is the **LAW 7 (EXPIRY IRON RULE)** proof and its assertions
are shaped _"the expired bucket was NOT touched"_ / _"0 unallocatable residuals"_. A no-op makes
those pass **vacuously** — the S-29 class, in the one fixture that proves LAW 7. Fixture 22's
post-flip damage was measured in situ at **7 fail / 13 pass** (seqs 1, 2, 3, 4, 5, 6 and the new 89),
not the single assertion S-28 recorded.

**What it does.** Adds `estimator_noop_skipped` to each fixture's observation payload and a run-time
premise assertion **seq 89** (`eq 0`) to both. It does **not** fix the no-op; it converts a silent
vacuous green into an honest red that **names its own cause**, so a bisecting leg reads "the cron got
here first" instead of hunting the estimator.

**Cody revision 1 — the guard earned its keep on the first apply.** The end-state `DO` block
(`scenario_sql LIKE '%estimator_noop_skipped%'` on both rows = 2) rather than "did the replace fire".
Apply attempt 1 **failed** on it (`reached 1 of 2`): fixture 20's `'a_events_written'` key sits at
line 52, not adjacent to its `jsonb_build_object(` at line 47, so the two-line anchor never matched.
The whole migration rolled back with **nothing half-applied** and no `schema_migrations` row. Without
this guard the migration would have "succeeded" while shipping an assertion that reads a key which
never exists. It also makes the migration safely re-runnable.

**Cody revision 2 — verified before apply, not assumed.** `golden.compare` contains
`IF p_actual IS NULL OR p_expect IS NULL THEN RETURN false;`, so an absent key **fails**. Had it
returned true, the guard-of-the-guard would itself have been vacuous.

**Suites after:** 11 fixtures · **218 pass / 0 fail / 6 expected-red / 0 vacuous / 0 skipped /
1 arrived-early**. P0 48/0 · P1 **101 → 103**/0 · P2 67/0. Assertions **222 → 224**. All three run
per S-27.

**File parity: 1 of 1 MATCH** — `md5 = e6c819c371cae54f5f1938d8c72a058a`, 5642 bytes on both sides
with `.strip()`/`btrim` (RISK 71). S-24 stays at **12**.

⚠️ **Consequence for D-08.** The fleet-wide cron-44 expansion now has a named, loud prerequisite:
it will turn fixtures 20 and 22 honestly red. The durable fix — a re-derive path so a caller that has
deliberately perturbed belief can re-run against a consumed snapshot — is owed **before** that flip.
See PARKING-LOT S-28.

---

## PRD-110 relay leg 26 — 2026-07-30 (2 migrations)

### `20260730211918_prd110_p14_estimator_force_rederive_s28`

**Class:** modified SECURITY DEFINER on a live cron path. **Cody:** ⚠️ approve with revisions —
Articles 1, 4, 8, 11, 12, 13, 16. All three revisions applied before apply.

Adds `p_force_rederive boolean DEFAULT false` to `estimate_shelf_composition_v3`, skipping ONLY the
already-processed `CONTINUE`. This is S-28's owed half: without it, cron 44's fleet-wide expansion
(D-08, pre-approved, ~2026-08-02) makes fixtures 20 and 22 no-ops — fixture 22 honestly red, and
fixture 20 **vacuously green on the EXPIRY IRON RULE (LAW 7) proof**.

**The overload landmine, handled.** Both original parameters carry defaults, so a surviving 2-arg
candidate beside a 3-arg-all-defaults one makes EVERY call ambiguous (42725) — including cron 44's
live `(shelf_id, false)`. The 2-arg version is DROPPED in the same transaction and the migration
**executes cron 44's exact positional shape afterwards** to prove the call site still resolves
(Cody revision 2, Article 13) rather than reasoning that it must.

**How the body was derived.** Four exact substitutions over the LIVE `prosrc`, each asserted to match
**exactly once**, then a **reverse substitution asserted to reproduce the original body byte-for-byte
before any DDL runs**. That is the R25-U1 lesson generalised: it proves not just that the four edits
landed but that nothing else moved.

**Cody revision 1 (Article 12).** The first draft was forward-only but **not idempotent** — a re-run
found no 2-arg function and raised. Section 0a now returns a no-op when the 3-arg is present and the
2-arg is gone.

**Containment.** Force is **REFUSED fleet-wide** (`p_shelf_id IS NULL` raises), and the migration
proves the guard binds by calling it and requiring the exception.

### `20260730212013_prd110_p14_estimator_revoke_anon_default_priv_regression`

⚠️ **Fixes a privilege regression the previous migration introduced, found by verifying the ACL
instead of trusting the apply.** The dropped 2-arg function carried
`postgres=X | authenticated=X | service_role=X`. The recreated 3-arg one came back as
`postgres=X | anon=X | authenticated=X | service_role=X`.

`REVOKE ALL … FROM PUBLIC` was run and did nothing about it: **PUBLIC is not `anon`.** Supabase's
`ALTER DEFAULT PRIVILEGES … GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role`
re-attached the grant to the newly created object. This is **RISK 73's mirror image** — there,
"REVOKE `anon` alone is not least privilege" on a view; here, "REVOKE PUBLIC alone is not least
privilege" on a function.

**Why it mattered.** The estimator's role check is `IF v_actor IS NOT NULL AND NOT EXISTS(…)`. For an
anonymous caller `auth.uid()` is NULL, so the check is **skipped entirely**, and `p_dry_run` is only a
default — `estimate_shelf_composition_v3(<shelf>, false)` would have written real `inventory_events`.

**⚠️ STANDING RULE, new: any DROP+CREATE of a function in this project silently re-grants
anon/authenticated/service_role from default privileges. Restate the intended ACL explicitly and then
ASSERT it.** This migration asserts it.

**Verification (all measured, none inferred).** ACL restored to the exact pre-S-28 set · exactly
**1** overload · SECURITY DEFINER + `search_path` preserved · cron 44 command unchanged and resolving ·
behavioural force proof inside a rollback envelope: consume → `skipped=1` → perturb → still
`skipped=1` → **force → `skipped=0, forced_rederive=1, events=1, drops=1`** · residue **0**
(events/composition/anomalies 31/31/10 before and after).

**Suites after:** 11 fixtures · **218 pass / 0 fail / 6 expected-red / 0 vacuous / 1 arrived-early**,
224 elements, all three run per S-27. Unchanged from STEP R — this unit was designed to move nothing.

**File parity: 2 of 2 MATCH** — `a7a21695cfd896e0b6e305e4f208c133` (11952 bytes) and
`c1377f7cd349c08830adb00540b7ced0` (2579 bytes), `.strip()`/`btrim` both sides (RISK 71).
S-24 stays at **12**. `prd110%` **59 → 61**.

---

## PRD-110 relay leg 27 — `golden.arrange_shelf`, the precondition primitive (2026-07-30)

Four migrations. **Written retroactively at leg 28** — leg 27 closed without a registry section
and its own RESUME POINTER flagged the omission as owed.

| version          | name                                                       | what it does                                                                                                                                                                                                                                                            |
| ---------------- | ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260730214710` | `prd110_golden_arrange_shelf_d08_fleetwide_immunity`       | Creates `golden.arrange_shelf(uuid, boolean)`: resets DERIVED `shelf_composition` for one shelf and re-dates the machine's newest WEIMI row, so a fixture owns its own preconditions instead of borrowing the estimator's.                                              |
| `20260730214752` | `prd110_golden_fixtures_202122_own_their_preconditions`    | Wires that call into fixtures 20/21/22 — **inside their inner `BEGIN … RAISE 'GPnn:' … EXCEPTION` block**, which is the real rollback envelope (RISK 80).                                                                                                               |
| `20260730215314` | `prd110_golden_arrange_shelf_release_by_update_not_insert` | Fix-forward: the snapshot release INSERTed a replay row, but `weimi_device_status` carries `unique_device_status UNIQUE (weimi_device_id, snapshot_date)` — one row per device per DAY — so it raised `duplicate key` on every call. Re-dates the existing row instead. |
| `20260730215644` | `prd110_golden_arrange_shelf_status_id_is_uuid_not_bigint` | Fix-forward: `weimi_device_status.status_id` is `uuid`, not `bigint`.                                                                                                                                                                                                   |

**Why it exists (S-28).** Simulating D-08's fleet-wide expansion (`estimate_shelf_composition_v3(NULL,false)`
then `run_all('P1')`) reddened **17 assertions across three fixtures** — 20, **21** and 22. Root cause
was **pre-existing seeded belief**, not snapshot consumption, so leg 26's `p_force_rederive` path
could not have reached it, and fixture 21 never calls the estimator at all. `arrange_shelf` took the
exposure **17 → 1**, and **not one assertion was edited** — the proof that the fixtures were always
asserting the right thing and merely borrowing preconditions they did not own.

📌 **Two files in `supabase/migrations/` are deliberately UNAPPLIED and must not be assumed landed.**
`20260730203000_prd110_golden_arrange_shelf_d08_fleetwide_immunity.sql` (leg 24, S-31 — its analysis
was right and its code could never have run) and
`20260730212000_prd110_p20c_golden_p2_acceptance_reexpressed_on_shadow.sql` (S-30 — owner is the
`engine_add_pod_v3` unit). Both verified absent from `schema_migrations` again at leg 28.

---

## PRD-110 relay leg 28 — S-34: fixtures 3 and 5 own their shelf state (2026-07-30)

| version          | name                                                        | what it does                                                                                                        |
| ---------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `20260730224235` | `prd110_s34_golden_pin_machine_stock`                       | `golden.weimi_pin_backup` + `golden.pin_machine_stock(uuid,int)` + `golden.restore_machine_stock(uuid)`.            |
| `20260730224812` | `prd110_s34_fixtures_3_and_5_own_their_preconditions`       | Fixtures 3 and 5 pin their machines empty, plan, restore; seq 5 and seq 12 re-expressed; seq 94/95 tripwires added. |
| `20260730225152` | `prd110_s34_fixture14_seq33_subcapacity_silent_drop_mirror` | Moves S-05's sub-capacity detector to fixture 14 seq 33, which runs unpinned.                                       |

**Why (R27-D6 / S-34).** Five P0 assertions went red at leg-27 close with **no engine change**: the
production WEIMI ingest at ~22:00:40 UTC moved live fleet stock, and fixtures 3 and 5 assert on that
stock through a live `engine_add_pod` call. `218 pass / 0 fail` was never a stable baseline — it was
a baseline measured before 22:00, and legs 7–26 all happened to run earlier in the day.

**Article 14** — `golden.weimi_pin_backup` does not materialise a query result for performance; it
holds a pre-image no view can derive (the source value is being overwritten). Cody: no ADR required.

**SAFETY MODEL, and it is the whole design.** `golden.run_all` is **one transaction** (plpgsql cannot
commit; proven by every fixture's `pod_refills` rows sharing one `created_at`). Pin and restore are
therefore in the same transaction as the engine call, so under MVCC **no other session can ever
observe the pinned value** — this is what makes the cron-44 estimator race structurally impossible
rather than merely unlikely. Any exception rolls the pin back via `run_fixture`'s savepoint.

**Cody review — 4 revisions demanded, all applied.** R1 `machine_id` is the PK (a `status_id` PK let
two rows exist per machine and turned `restore`'s lookup into a bare 21000). R2 the read-back
self-proof was gated on `p_curr_stock = 0`, so a non-zero pin returned success without proving
anything — now unconditional and per shelf. R3 `restore` asserts the post-restore total against the
pre-pin total **the pin recorded through the same view** (re-summing raw JSONB counts aisles that map
to no shelf, so a correct restore would have failed). R4 assert the full ACL after apply (RISK 77).

**Behavioural proof, 12 assertions in a rollback envelope:** guard REFUSES outside a golden run ·
negative stock REFUSED · restore-without-pin REFUSED · 16 aisles pinned, **204 → 0 → 204** ·
per-shelf fingerprint **byte-identical** after restore · `snapshot_at` **untouched** · backup 1 → 0 ·
residue 0. ACL measured `{postgres=X, service_role=X}` — no `anon`, no `authenticated`.

**Two assertions re-expressed (S-04 house pattern, original text preserved in `golden.fixtures.notes`):**

- **fixture 3 seq 5**, `>= 9 lines` → _a line for EVERY shelf carrying a live WEIMI slot, 0 uncovered_.
  Pinned empty the engine emits **16 lines for 16 shelves**, and all 10 qty-0 lines carry a
  `clamp_reason`. Stronger than the number it replaced and anchor-independent.
- **fixture 3 seq 12**, instantaneous fleet-wide `G2 = 0` → _no shelf is PERMANENTLY blind_. See
  **S-35**: cron 7 `evaluate-lifecycle-4h` (22:15 UTC) archives rotated shelves without provisioning
  a replacement and cron 42 closes the gap at 15:30 UTC, so an instantaneous fleet-wide 0 is not a
  property of a correct system. The assertion now proves every offender is claimed by the canonical
  seeder (dry run measured **pure** and **97 ms**, hoisted into a `MATERIALIZED` CTE).

**⚠️ Assertion power was moved, not lost — and this is the part a future leg must not undo.** The
empty pin made fixture 3 **seq 1** pass, because at stock 0 every shelf is sub-capacity AND every one
gets a line. True, non-vacuous, but no longer discriminating for S-05, whose silent drop only fires at
_partial_ stock. Hence seq 33 on fixture 14 (unpinned, same machine, same `engine_add_pod_v3` gate),
reading **3** today — A05 Krambals 5/6, A08 Skittles Bag 8/10, A11 Be-kind Bar 18/20.

**Suites after: 11 fixtures · 229 assertions · 223 pass / 0 genuine fail / 6 expected-red /
0 scenario errors / 0 vacuous.** Residue 0 across `weimi_device_status` (4405 rows, newest unchanged),
`golden.weimi_pin_backup` (0), both shadow tables (0), sentinels (40), and 0 live plan rows written
on any `plan_date < 2030`.

**File parity: 3 of 3 MATCH** — `3700ddc2e11fc796b5d11f9524ea35b1` (11428) ·
`16dc06c54cfe398e4ec887bd42c9fcae` (12919) · `c7fb68bfc4ce13263434258236fbbf5d` (3210),
`.strip()`/`btrim(… , E' \t\n')` both sides (RISK 71 + RISK 79). S-24 stays at **12**.
`prd110%` **65 → 68**.

## 2026-07-30 · PRD-110 relay leg 31 · the first v3 engine, applied as ONE atomic unit with the acceptance re-expression

Two migrations, deliberately inseparable, because the eight gated Phase-2 acceptance criteria arm
the instant `public.engine_add_pod_v3` appears in `pg_proc`:

| version          | name                                                     | what                                                                                                                                                                                                                       |
| ---------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260730234725` | `prd110_p20c_golden_p2_acceptance_reexpressed_on_shadow` | re-expresses the EIGHT gated P2 criteria onto `pod_refills_shadow` / `v_blocked_demand_shadow_v3`; adds `golden.v3_run_id`, `golden.run_engine_v3_if_built`, fixture 3 seq 7, and seq 86/87/88 on all four engine fixtures |
| `20260730234831` | `prd110_p20_engine_add_pod_v3_truth_layer`               | `public.engine_add_pod_v3(p_plan_date date, p_days_cover integer)` — SECURITY DEFINER, truth-layer candidate set, writes ONLY `public.pod_refills_shadow`                                                                  |

## PRD-110 S-37 (2026-07-31, relay leg 33) — the split view's pod key made canonical

| version          | name                                               | what                                                                                                                                                                                                                                                                                     |
| ---------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260731005200` | `prd110_s37_golden_fixture2_split_alias_asymmetry` | **FIXTURE FIRST (LAW 1).** Fixture 2 +5 assertions (seq 60–64) riding the SINGLE existing read of the split view — zero extra evaluations (S-26). 60/61 gated → the only two expected-reds; 62/63/64 ungated tripwires.                                                                  |
| `20260731010500` | `prd110_s37_fixture2_restore_leg24_before_keys`    | **Repair of a defect the previous migration introduced.** Rebuilding `scenario_sql` from the migration FILE that created it silently reverted leg 24's `'pr'`/`'bd'` tripwire keys, reding seq 92/93. LAW 13 in miniature. Ships the reusable referenced-key-vs-written-key guard query. |
| `20260731012000` | `prd110_s37_velocity_split_v3_canonical_pod_key`   | **THE FIX.** `v_shelf_instock_velocity_split_v3` canonicalises the Hunter→Hunter Ridge pod alias in `shelves` AND `slot_stock`, and **recomputes `n` over the merged group**. Also ships golden seq 65 (Article 16 anti-drift) and drops the `_test` shadow.                             |

⛔ **The trap, and why leg 32's "proven" dry-run was necessary but not sufficient.** Leg 32 dry-ran a
canonicalisation and reported conservation exact (max |Σw − 1| = 0.000000000, 0 pods violating), which
reads like proof. It is not: the view carries a **residual absorber** (`w_raw + (1 − w_sum)` on rank 1),
so Σw is forced to exactly 1 _whatever the partition key is_. **Conservation is laundered, not proven.**
Measured this leg: all 26 family shelves carry `pod_shelf_count = 1` (v_shelf_state partitions it by the
RAW key), so merging two n=1 shelves without recomputing `n` sends both down `single_shelf` (w_raw = 1.0
each) and the absorber "repairs" the pair to **w = 0.0 and w = 1.0** — a LAW 5 silent zero behind a green
check. Fix outcome proves the trap was real: the family now reports `instock_weighted = 14` (the 7 dual
machines × 2); a join-only fix would have left those same 14 rows as `single_shelf`.

📌 **The transferable lesson: a conservation identity enforced by a residual absorber can never falsify
the key it is computed over.** When an invariant is true by construction, it is not evidence. Assert the
grain (`n` = group size) and the branch (`single_shelf` ⇒ w = 1), not just the sum.

**The first file had been sitting unapplied since leg 26 and had aged against a live baseline.**
Reading it in full against live state found **five** defects (leg 28 knew of one), any single one of
which breaks the apply or reds a blameless engine:

1. End-state guard 7h hardcoded `233 = 224 + 9`. Live had been **229** since leg 28. The file would
   have **rolled itself back**.
2. It predates fixture 14 **seq 33** (leg 28's S-05 sub-capacity mirror) — the EIGHTH criterion, left
   pointing at `public.pod_refills`, which v3 never writes.
3. It predates leg 28's **S-34 pin** and appended the v3 call AFTER the pin envelope on fixtures 3
   and 5, so v19 would plan a pinned machine and v3 a restored one. Every shadow-vs-live diff would
   be noise — LAW 4's whole purpose defeated.
4. ⭐ **S-30's own prescribed fix for (3) was itself wrong.** It anchored on
   `'PERFORM golden.restore_machine_stock(v_m);'`. Fixture 3 has that string; **fixture 5 does not** —
   it restores three machines in a `FOR` loop. That `replace()` would have silently no-op'd on
   fixture 5 and guard 7b would have rolled the migration back. The v19 call is the anchor instead
   (measured present exactly once in both). New guard **7b2** proves the v3 call precedes the restore.
5. **S-36**: fixture 105 seq 10 filtered on the MACHINE's `venue_group='VOX'` as a proxy for
   "venue-sourced". P1.1 retired that proxy. Three `boonz_wh` shelves on its own VOX-group machines
   legitimately block (`MPMCC-1054 A12` Haribo 7/8, `A13` Leibniz 3/16, `MPMCC-1058 A05` Krambals
   5/6, all `available_units = 0`), so a LAW-5-compliant engine would have read **3** against `eq 0`.
   Re-scoped to `v_shelf_availability_v3.sourcing <> 'boonz_wh'`. **The blocked rows are correct
   output and were NOT suppressed** — the engine emitted exactly those three and 105 seq 10 reads 0.

**A sixth item came out of the Cody pass, an addition rather than a correction.**
ADR-shadow-plan-tables **§8 obligation 3** requires the "`pod_refill_plan` row count unchanged across
any v3 shadow run" tripwire on _every_ Phase-2 fixture. It rode on fixture 14 only (seq 91, keyed off
fixture 14's own scratch, which fixtures 3/5/105 do not have). **seq 86** now carries it on all four,
off the helper's own captured count. Coverage therefore moved **+13, not +9**.

**Suites after: 11 fixtures · 242 assertions · 242 pass / 0 fail / 0 expected-red / 0 scenario
errors**, run twice with identical results. **All six pre-existing expected-reds closed**
(`5:10, 14:30, 14:31, 14:32, 14:33, 105:10`) — the engine turned every one of them green on the
first run, with no bisect.

**Engine evidence, per fixture (`lines / scope`, so coverage is exact by construction):**
fixture 3 **16/16**, 145 units, 1 blocked · fixture 5 **64/64**, 466 units, 2 blocked ·
fixture 14 **16/16**, 29 units, **5 over-capacity** (matches seq 30's 5) · fixture 105 **48/48**,
68 units, **3 blocked_no_wh** = exactly S-36's three. Slowest run **867 ms**.

**Residue 0.** `public.pod_refills` unchanged at **3875** (pre-2030 **3734**) — seq 87 proves it per
fixture · `pod_refill_plan_shadow` **0** · `golden.weimi_pin_backup` **0** · sentinels **40** ·
`inventory_events` / `shelf_composition` **31 / 31** · `v_blocked_demand_open` **20** · no flag
flipped, no cron changed, no protected entity written, v19 `engine_add_pod` byte-untouched.
`prd110%` **68 → 70**.

📌 **The transferable lesson, and it cost leg 29 a whole leg to find the first half of it: an
unapplied migration file is a claim about a database that has moved on.** Re-read it in full against
live state before applying, and never trust its constants — including the constants in the correction
notes written _about_ it.

---

## PRD-110 P2.1 — leg 34 (2026-07-31): the engine sizes on in-stock velocity, and both velocity objects go canonical

Two migrations, one atomic unit, applied in this order. **LAW 1 was the ordering constraint, not a
preference:** the fixture went in first, its failing baseline was recorded, and only then did the
engine change.

| version          | name                                                       | what                                                                                                                         |
| ---------------- | ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `20260731012239` | `prd110_p21_golden_fixture14_velocity_provenance_contract` | Fixture 14 gains **seq 40-48** (the velocity-provenance + sizing-unit contract) and `AMZ-1046-2406-O1` joins its picked set. |
| `20260731012755` | `prd110_p21_engine_add_pod_v3_velocity_instock`            | `engine_add_pod_v3` sizes on `velocity_instock_shelf` and records where every rate came from.                                |

### The failing baseline, captured before the engine moved

seq 40 = **32** · 41 = **32** · 42 = **32** · 43 = **32** · 46 = **32** · 47 = **32** · 48 = **false**
— 7 expected-red, 0 hard fail. seq 44 = **0** and seq 45 = **0**, both **VACUOUSLY green**: their
populations (`instock_split` lines, `weimi_raw_fallback` lines) were empty because no line carried a
`velocity_source` at all. **seq 48 exists precisely to catch that**, and it was red. This is leg 33's
lesson applied prospectively rather than retroactively — _assert the branch, not just the sum._

### Why fixture 14 was widened instead of a fixture 27 being written

`v_shelf_instock_velocity_split_v3` costs ~20 s per evaluation and **machine-scoping does not reduce
it** — measured this leg: one machine **19.77 s**, fleet-wide **19.8 s**, because the object's inner
`vel` CTE is `MATERIALIZED` and no predicate pushes down. (The pod-grain object _does_ push down:
3.49 s for one machine vs 15.4 s fleet-wide. The two behave differently; do not reason about one from
the other.) A new fixture would have added a second full evaluation to every suite run. Fixture 14
already invokes the v3 engine, so the whole contract rides on that run and adds exactly **one** read.

Adding `AMZ-1046-2406-O1` alongside `MPMCC-1058-0000-R0` is what makes the assertions non-vacuous:
MPMCC-1058 is 16/16 `velocity_status='ok'` (the `instock_split` branch), AMZ-1046 is 16/16
`out_of_canonical_scope` with a NULL shelf velocity but a non-null `v_shelf_state.velocity_raw` (the
`weimi_raw_fallback` branch, D-13). **Both branches, one run, no extra velocity evaluation.** Every
pre-existing fixture-14 assertion is either scoped to `machine_name = 'MPMCC-1058-0000-R0'` or is
run/absolute-scoped, which was verified before the edit and confirmed after: all **31** stayed green.

### The residual branch is D-10's answer, not a new decision

`instock_split` → `weimi_raw_fallback` → `none_no_signal`, recorded per line as `velocity_source`
with the number in `velocity_effective_daily`. Never a silent 0, never an invented number (LAW 5 +
LAW 6). The engine additionally **RAISEs** if any line fails to name a recognised source — the
coverage guard's logic applied to provenance rather than to row count.

**S-13 dies here.** `velocity_instock` is a daily rate by construction; there is no `/30` and no
`*30` anywhere in the function, and **seq 46** (`cover_units = ceil(velocity_effective_daily ×
days_cover)`) is the assertion that stops v3 ever acquiring v19's three-way self-disagreement.

### Cody: ⚠️ Approve with revisions — and the revision was Article 16

Art 4 ✅ (via_rpc/rpc_name, input + role validation, three RAISE guards) · Art 12 ✅ (CREATE OR
REPLACE, identical signature, additive keys only — which is also what preserves the ACL, RISK 77) ·
Art 14 ✅ (no new table) · Art 2/3/6 ✅ · Art 16 ✅ on substance (reads the canonical object, derives
nothing inline). **Art 16 ⚠️ required revision:** `METRICS_REGISTRY.md` still read _"do not consume
yet"_ for the object this migration consumes. A migration that contradicts the registry is the exact
drift Article 16 exists to stop, so **both velocity rows were promoted 🔴 → 🟢 in the same unit**,
naming the consumer and dating the `pod_refills_shadow.velocity_instock` semantic change.
📌 Art 8 is **not engaged** — `pod_refills_shadow` is outside the Appendix A protected list, so the
universal-audit trigger does not fire; `tg_pod_refills_shadow_append_only` carries the guarantee. Do
not cite Article 8 as satisfied for this table.

### Result

**11 fixtures · 257 assertions · 257 pass / 0 fail / 0 expected-red / 0 arrived-early / 0 scenario
errors**, all three phases. Engine on fixture 14: **32 lines / 32 scope**, `velocity_instock_lines`
**16**, `velocity_fallback_lines` **16**, `velocity_none_lines` **0**, 37 units, 19.0 s (the one
velocity read). `pod_refills` pre-2030 **3734** unchanged · `pod_refill_plan_shadow` **0** ·
`engine_add_pod_v3` still **1 overload, anon absent** · `prd110%` **73 → 75**.

⚠️ **The suite got ~80 s slower and that is the S-26 tax landing, not a regression.** Four fixtures
invoke the engine (3, 5, 14, 105) and each now pays one ~19 s velocity read: fixture 3 8.7 → 27.3 s,
5 26.9 → 58.6 s, 14 11.0 → 53.9 s (also carrying the scenario's own read), 105 19.8 → 39.6 s. **STEP 7
S1 is unaffected** — a full-fleet shadow run is ONE engine invocation, so it pays the ~19 s once.

📌 **The transferable lesson: predicate pushdown is a property of the specific object, not of the
family.** Two views over the same data, one of which scopes 4× cheaper per machine and one of which
does not, because one has a `MATERIALIZED` CTE in its body. Measure the object you are about to
consume; never infer its cost from its sibling.

---

## PRD-110 leg 36 (2026-07-31) - S-41 / S-42: the estimator stops compounding what it already did

| version          | name                                                       | what                                                                                                                                                                                                                                                           |
| ---------------- | ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260731021540` | `prd110_s41_golden_fixture27_estimator_firing_idempotency` | FIXTURE FIRST. Adds golden fixture 27 (P1, plan_date 2030-01-26) + 13 assertions. Behaviour-neutral. Recorded failing baseline: **seq 6 = false, seq 8 = 1, seq 9 = 2**.                                                                                       |
| `20260731021929` | `prd110_s41_s42_estimator_firing_idempotency`              | THE FIX. `shelf_composition.last_age_decay_at` (additive, nullable); `estimate_shelf_composition_v3` age decay re-anchored + at-most-once-per-day + new `shelves_age_decayed` counter; `raise_inventory_anomaly_v3` idempotent per observation. Cody-reviewed. |
| `20260731022114` | `prd110_s41_fixture27_seq7_residue_immune_restatement`     | seq 7 restated onto a fixture-controlled synthetic snapshot (the original measured cron-44 timing, not the fix) + adds seq 11/12 mechanism assertions.                                                                                                         |
| `20260731022206` | `prd110_s41_fixture27_seq9_restore_pair_total_semantics`   | Restores seq 9's pair-total expression after the seq-7 probe split silently changed what it measured. One expression; no expectation re-fitted.                                                                                                                |

**Root cause, one, two symptoms.** The estimator's idempotency marker is an `inventory_events` row.
A flat shelf writes no event, so nothing marks the WEIMI snapshot processed and the loop body re-runs
on all 24 daily firings (RISK 76, now measured). Symptom 1: `count_above_capacity` anomalies re-raised
per firing - 20 rows for one snapshot across 5 shelves, byte-identical payloads, so an anomaly COUNT
measured cron frequency rather than reality. Symptom 2 (the serious one): the loop tail subtracted
`rate x total_days_since_a_fixed_anchor` on **every** firing - cumulative in time and wrong even at a
once-per-day cadence - which was due to start at **2026-07-31 18:40:00Z** and would have driven every
composition row on the burn-in machine to `confidence = 0` in ~15 firings, silently disabling both
the expiry auto-write-off gate (>= 0.70) and the driver-prompt gate (>= 0.50).

⚠️ **The fix does NOT change skip semantics** - flat shelves still re-run. It removes the two accruing
side effects. Fixture 27 seq 3 pins that distinction by asserting the second call still does not skip.

⚠️ **No history deleted.** The 35 anomaly rows (15 duplicates) are retained as the evidence for S-41;
that is why the dedupe is a function guard and not a unique index.

⚠️ **Expect ONE legitimate decay on the first post-fix firing** - `last_age_decay_at` ships NULL, so
the anchor falls back to `min(created_at)` and settles the genuinely accrued days once, then stamps.
That single drop is correct; do not "fix" it.

**Verification:** fixture 27 15/15 green; all three suites re-run **12 fixtures / 272 pass / 0 fail /
0 expected-red / 0 scenario errors / 0 vacuous**, with 272 pass == 272 assertions on the books.
`pod_refills` pre-2030 unchanged at 3734. All four files md5-verified byte-identical to
`schema_migrations.statements` (RISK 71 btrim/.strip on both sides), so **S-24 does not grow**.

---

## PRD-110 P2.2a — base-stock policy resolver (leg 38, 2026-07-31)

| Version          | Name                                                      | What                                                                                   |
| ---------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `20260731031428` | `prd110_p22a_base_stock_policy_params`                    | 6 additive INERT columns + 2 CHECKs on `refill_policy_params` (not a protected entity) |
| `20260731031738` | `prd110_p22a_golden_fixture28_base_stock_policy_resolver` | Golden fixture 28, 17 assertions — applied BEFORE its subject (LAW 1)                  |
| `20260731031834` | `prd110_p22a_v_machine_base_stock_policy_v3`              | The resolver view, `security_invoker = true`, anon+authenticated REVOKEd then SELECT   |

**Cody:** ⚠️ Approve with revisions — Articles 2, 3, 12, 14, 16. Article 14 ✅ (a view, not a
snapshot table). Article 16 forced the load-bearing revision: the cadence must use the **canonical
visit vocabulary**, not a dispatch-only re-derivation (13 of 30 machines diverge, always
overstating, up to 1.60x). Article 2/3 forced `security_invoker = true`. All three applied.

**Recorded LAW-1 baseline** (fixture 28 run after migration 2/3, before 3/3): **0 pass / 17 fail /
0 scenario errors**, `view_exists = 'false'`. The `to_regclass` + dynamic-`EXECUTE` guard produced a
clean red rather than an S-33 `scenario_error` — which is the whole point of writing it that way.

**Verification:** fixture 28 **17/17** green after 3/3; all three suites re-run **13 fixtures /
289 pass / 0 fail / 0 expected-red / 0 scenario errors / 0 skipped / 0 vacuous** (289 pass == 289
assertions on the books). `pod_refills` pre-2030 unchanged at **3734**. Fixture 28's `scenario_sql`
md5-verified byte-identical to disk (`0d30463f448559833d1d4e822fa426ed`, 7776 bytes).

⚠️ **`base_stock_default_interval_days` shipped at 5.5, not the 7 the leg-37 pointer proposed.**
7 is the median-of-medians of a **dispatch-only** derivation (6.75); on the canonical vocabulary the
measured fleet median-of-medians is **5.50**. The parameter is only ever read by the one tier-3
machine, but the number is measured, not guessed.

---

## PRD-110 P2.2b (sigma / dispersion) - applied by leg 39, FILED BY LEG 40

⛔ **These four were applied to the DB by leg 39 and never written to disk or logged.** Leg 39 died
after its provisional RESUME POINTER without a FINAL block. Leg 40 reconciled them at STEP R: each
file below was reconstructed from `supabase_migrations.schema_migrations.statements` and
**md5-verified byte-identical** before being recorded here. Nothing was re-applied; the DB was
already correct. The gap was files + log, never the database.

| #   | version          | name                                                  | md5 of `statements`                |
| --- | ---------------- | ----------------------------------------------------- | ---------------------------------- |
| 1   | `20260731034644` | `prd110_p22b_sigma_dispersion_params`                 | `b7b73bcb9337a3b2432285bcc4bd25ca` |
| 2   | `20260731034918` | `prd110_p22b_golden_fixture29_demand_dispersion`      | `c72a90f926e6016752554b654b736679` |
| 3   | `20260731035112` | `prd110_p22b_v_pod_demand_dispersion_v3`              | `5026cd28bda950efe7f4f5d98980dbc8` |
| 4   | `20260731035223` | `prd110_p22b_s46_fixture28_scope_check_parenthesised` | `9f6fc67056ef8cf7d4dc8e5b67a1ed34` |

**1/4 params.** Four `base_stock_sigma_*` columns on `refill_policy_params`, CHECK-constrained,
INERT on apply. Defaults measured, not invented: lookback **60d**, min_days **14**, phi_floor **0**
(deliberately inert, raising it to 1.0 is the Poisson floor parked as **D-15**), prior_precedence
`pod_then_fleet`.

**2/4 fixture 29, LAW 1 FIXTURE FIRST.** Applied BEFORE the view. **Recorded LAW-1 baseline:
0 pass / 18 fail**, `view_exists='false'`, via the same `to_regclass` + dynamic-`EXECUTE` guard as
fixture 28 (a clean red, not an S-33 scenario error). `baseline_status='failing_expected'`.

**3/4 the view.** `v_pod_demand_dispersion_v3` plus, additively, `v_pod_product_canonical_v3` (the
first named owner of the Hunter pod-alias map, closing the no-owner half of **S-38**). Both REVOKEd
from `anon`. Fixture 29 went **18/18** green immediately after.

**4/4 S-46, a live hole found while writing fixture 29.** Fixture 28 seq 3's "symmetric EXCEPT"
scope check was **not symmetric**: `UNION` and `EXCEPT` have equal precedence and are
left-associative in Postgres, so `(A EXCEPT B UNION ALL C EXCEPT D)` parses as
`((A EXCEPT B) UNION ALL C) EXCEPT D`. A DROPPED machine was caught; an INVENTED one reported 0.
Proven not argued: `act=(1,2,99), exp=(1,2)` gives 0 unparenthesised, 1 parenthesised. Fixed in
place under L33-3 (targeted `replace` on the live `scenario_sql` with pre- and post-guards, never a
rebuild from the creating migration). Fixture 28 was the only fixture carrying the shape.

⚠️ **Leg 40 verification caveat.** All four are md5-verified against the DB, and fixture 29 was
green in leg 39's own run. Leg 40 did **not** re-run the suites after filing, because the suite is
independently RED on fixtures 3 and 14 for a cause unrelated to P2.2b (see the leg-40 EXECUTION-LOG
entry, S-47). P2.2c must not start until that is closed (LAW 8).

---

## PRD-110 leg 41 · S-47 CLOSED (suite back to green) + S-48 discovered

Three migrations, all **harness-only** (schema `golden`). No engine body, no protected entity, no RLS,
no live plan table written. Cody reviewed all three before apply (Articles 1, 2, 3, 4, 6, 7, 8, 12,
13, 14, 16 checked; verdict ⚠️ approve-with-revisions, one revision applied - see below).

| version          | name                                                      | applied md5                        | file byte-identical?              |
| ---------------- | --------------------------------------------------------- | ---------------------------------- | --------------------------------- |
| `20260731044622` | `prd110_s47_fixture3_premise_gate_law5_floor`             | `9614c63391b2eb57fb66d03662dd3de6` | ❌ S-49 (comments only)           |
| `20260731044650` | `prd110_s47_s48_fixture14_txn_attribution_tripwires`      | `c899caba57921eb660ac5f996006085b` | ❌ S-49 (comments + COMMENT text) |
| `20260731044927` | `prd110_s47_fixture14_seq91_92_expect_matches_count_form` | `fa5eed0e11464faf18c017dd4650339f` | ✅ verified                       |

**044622 - fixture 3.** `seq 4` (v3 shadow P2.5 floor) and `seq 7` (v19 regression guard) keep their
STRICT `qty > 0` form but gain an `acceptance_gate_sql` premise:
`v_shelf_availability_v3.available_units > 0` for `MPMCC-1058-0000-R0` A07. An unstocked warehouse
now reports as `n_expected_red` instead of a false `n_fail`, and the P2.5 floor test is NOT retired.
Three new assertions: **seq 8** (v3 shadow) and **seq 9** (v19) carry LAW 5 unconditionally - the
pinned-empty shelf always receives exactly ONE line, either `qty>0` or `qty=0` with a non-empty
`clamp_reason`; **seq 19** requires that reason to NAME the warehouse block (`ILIKE '%wh%'`), gated on
the inverse premise so it binds only when the warehouse is genuinely empty. Fixture 3: 22 → 25
assertions.
📌 Article 16 honoured: the gates read the canonical `v_shelf_availability_v3`, never re-deriving
warehouse availability from `warehouse_inventory` or through `product_mapping`.

**044650 - fixture 14 + `golden.written_by_this_txn(xid)`.** New read-only helper, `LANGUAGE sql`,
**VOLATILE** (Cody's one revision: it wraps `pg_xact_status`, which is `provolatile='v'`; a STABLE
wrapper around a VOLATILE callee is a planner footgun and VOLATILE costs nothing on a seq scan),
**SECURITY INVOKER** (safe: `pg_xact_status` has `proacl = NULL`, i.e. EXECUTE to PUBLIC).
`seq 91 / 92 / 93` re-expressed from global count deltas onto transaction attribution; new **seq 100**
is an anti-vacuity self-test. Fixture 14: 40 → 41 assertions.

**044927 - follow-up.** 044650 changed `seq 91/92` `check_sql` from a boolean to a COUNT but left
`expect_op/expect` at `eq/'true'`, so both compared `'0'` against `'true'` and failed. Forward-only
correction to `eq/'0'` (Article 12). Caught by the suite on the first run after apply.

**Suite after all three: 14 fixtures · 309 pass · 0 fail · 2 expected_red · 0 vacuous.**
⚠️ The 2 expected_red are fixture 3 seq 4 and seq 7 while WH_CENTRAL is out of McVities Digestive
Nibbles. **That is the fix working, not a regression.** Green is `n_fail = 0`.

## PRD-110 leg 42 — D-14 applied via a v3-scoped carrier (2026-07-31)

⚠️ **These four are applied and verified in the DB but are NOT yet on disk** (S-49). The DB is
authoritative; regenerate verbatim from `supabase_migrations.schema_migrations.statements`.

| version          | name                                                          | what                                                                                                                                                                                                                                      | applied md5                        |
| ---------------- | ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| `20260731051447` | `prd110_d14_msp_v3_carrier_columns`                           | `machine_service_policy` gains nullable `trip_interval_days_v3`, `z_v3`, `v3_source` + 3 CHECKs (one biconditional: an override may not exist without naming its decision)                                                                | `f8192bc2c022ff8d189fbd55c33948f5` |
| `20260731051529` | `prd110_d14_base_stock_policy_v3_reads_v3_carrier`            | `v_machine_base_stock_policy_v3` resolves `z = COALESCE(z_v3, z_default, z_mid)` and sizes the policy tier on `COALESCE(trip_interval_days_v3, trip_interval_days)`; new `z_source` value `machine_service_policy_v3`; 3 columns appended | `8f5a2504372ec88f08d79e3a1402c682` |
| `20260731051651` | `prd110_d14_fixture28_v3_carrier_and_v19_neutrality_tripwire` | golden fixture 28 mirrors the carrier ladder; seq 15 re-phased `param_default` → `policy_seed`; new seq 18/19/20/21                                                                                                                       | `2ad847c73b86abdd1f568f5df5889665` |
| `20260731051747` | `prd110_d14b_d14c_apply_cs_decision_to_v3_carrier`            | the CS-authorized D-14b (z by machine_class) + D-14c (AMZ-1046 row) writes, to the carrier only                                                                                                                                           | `6cb2705d6ce49f979db8b4ae07d18e62` |

⛔ **Why the carrier exists.** `machine_service_policy.z_default` and `.trip_interval_days` are read
by the **LIVE v19 `engine_add_pod`** (lines 163-164 and 167), `rank_slot_suitability` and
`v_sizeup_candidates`. With `refill_sizing_mode='base_stock'`, writing D-14 into those columns would
have moved tonight's production plan on ~157 of 544 pod-bound shelves — LAW 12. Migration D proves
neutrality against a per-machine pre-image of v19's own expressions. **Fixture 28 seq 20/21 are the
standing tripwire; they go red on purpose if anyone propagates into the base columns (see D-16).**

---

## PRD-110 P2.2c — base-stock sizing wired into the engine (2026-07-31, relay leg 44)

| version          | name                                               | what it does                                                                                                                                                                                                                                                                                                                                                                                     | md5 (file == applied)              |
| ---------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------- |
| `20260731061145` | `prd110_p22c_fixture14_base_stock_sizing_contract` | FIXTURE FIRST (LAW 1). Fixture 14 seq 46 RE-PHRASED to the base-stock identity (never deleted); new seq 50/51 (LAW-5 horizon/sigma provenance), 52 (terms equal the view exactly), 53 (anti-vacuity: z differs from the stale base column), 54 (shelf share cannot exceed pod sigma), 55 (safety term actually binds), 56 (S-43 degeneracy tripwire), 57 (`p_days_cover` re-roled, not orphaned) | `7bb21f38fe6b02110930f2b579ab94f4` |
| `20260731061440` | `prd110_p22c_engine_add_pod_v3_base_stock`         | `engine_add_pod_v3` sizes on `ceil(mu*H + z*sigma*sqrt(H))`. Joins `v_machine_base_stock_policy_v3` + `v_pod_demand_dispersion_v3` as MATERIALIZED CTEs (S-26 contract). Adds two LAW-5 RAISE guards and S-43 saturation telemetry to the return value.                                                                                                                                          | `bd2c9dd9f693b9213623713552441ef2` |

⭐ **FIXTURE FIRST was performed, not merely claimed.** Migration A was applied ALONE and fixture 14
run against it: **43 pass / 6 fail**, and the six were exactly seq 46, 50, 51, 52, 55, 57 — every one
an assertion that can only pass once the engine changes. Migration B then took the fixture to
**49/49**. A green-on-first-run fixture would have proved nothing (the S-48 vacuity lesson); this
sequence proves the new contract genuinely binds.

⛔ **`p_days_cover` was RE-ROLED, deliberately, not orphaned.** The signature is unchanged (no
`pronargdefaults` trap), the arg stays required and validated, it still echoes verbatim into
`pod_refills_shadow.days_cover` so shadow-vs-v19 diffing stays comparable, and it is now the
**tier-3 horizon fallback** when a machine has no policy row. Live that tier is empty (all 31
machines resolve a policy row) — it is defensive, and seq 50 would catch its silent disappearance.

**Full suite after apply: 14 of 14 fixtures green, 328 pass / 0 fail / 2 expected_red over 330
assertions** (322 -> 330, +8). Fixture 14 went 41 -> 49.

---

## 2026-07-31 · PRD-110 P2.3 (relay leg 46) · `20260731070920_prd110_p23_engine_expiry_ceiling`

**S-24 now 37.** One migration, applied and filed to disk in the same unit (20,113 bytes, md5
`751e6b783e3260770bbd0b2e28a35a52`, byte-identical to `schema_migrations.statements` on the first
attempt via the S-49 Management-API method).

`engine_add_pod_v3` gains BUILD SPEC P2.3's expiry ceiling. Full contract in RPC_REGISTRY
(amendment 2026-07-31 P2.3). Method: **13 exact named substitutions over the live
`pg_get_functiondef` text**, each asserted to match EXACTLY ONCE, plus a **reverse substitution
asserted to reproduce the original byte-for-byte BEFORE any DDL runs** — so the only differences
that could ship are the enumerated ones. The 449-line body was never retyped.

⭐ **FIXTURE FIRST was performed, not claimed.** Fixture 8 was built and baselined RED by leg 45
(**14 pass / 0 fail / 5 expected_red**) before any engine change existed. This migration took it to
**19 / 19 with zero expected_red** — seq 28/29 (the non-vacuity guards) went green, which is what
makes seq 24/25/27 real evidence rather than vacuous zeros (**S-52 closes by itself here**).

⛔ **Post-DDL guards are part of the migration, not a follow-up probe** (Cody rev 3): exactly ONE
`engine_add_pod_v3`, **oid still 235798**, `proacl` still `{postgres=X, authenticated=X,
service_role=X}` with `anon` absent, and the replaced body actually contains the ceiling. 📌
`CREATE OR REPLACE` **preserves** privileges — the R26-D2 ACL loss was a DROP+CREATE.

**Full suite after apply: 15 of 15 fixtures green, 347 pass / 0 fail / 2 expected_red over 349
assertions.** Delta vs the leg-45 baseline (342 / 0 / 7) is exactly fixture 8's five expected_red
turning into passes; every other fixture is unchanged line for line. The 2 remaining expected_red
are fixture 3's known WH-out-of-stock pair (S-29 house pattern, not a regression).

⛔ **RISK 94 applies to every number quoted about this migration.** At fixture 8's synthetic
**2030-01-09** the ceiling is 0 on essentially every WH-constrained line (nothing in stock is
sellable in 2030) — that is the deliberate maximum-stress case, **not** a fleet signal. Measured at
the live plan date the ceiling binds on **10 of 544 shelves (1.84%), removing 10 of 1254 units
(0.8%)** — a safety rail, which is the correct shape.

**v19 `engine_add_pod` is byte-untouched** (md5 `630ae01f2ee8f468c079645abd0a7275`, re-verified
after apply). Tonight's live plan is unaffected.

## 2026-07-31 · PRD-110 S-53 (relay leg 47) · venue-sourcing correction reaches the truth layer

Two migrations, one atomic unit:

- `20260731075835_prd110_s53_fixture30_venue_sourcing_mirror_contract` — golden fixture 30 (20
  assertions, phase P1). INSERT-only into `golden.fixtures` / `golden.assertions`; no DDL, no
  protected entity touched.
- `20260731075954_prd110_s53_fixture30_guard_constants_corrected` — forward-only correction of two
  guard constants (Article 12: the applied migration above is NOT edited).

**What was wrong.** The ⭐ CS decision of 2026-07-31 ("Pepsi Black, Ice Tea Peach and Red Bull are
VENUE-sourced on ALL VOX machines") was applied to `product_mapping`, but its loop obligation —
supersede the matching `product_sourcing` edges — was never executed. Because `product_sourcing`
feeds `v_shelf_state.sourcing` → `v_shelf_availability_v3` → the `basis` P2.3 gates the expiry
ceiling on, **30 edges were both sized against Boonz WH stock AND capped by a Boonz WH expiry, for
stock the venue supplies.** LAW 2 arriving late.

**Scope, re-measured live — the parking lot's numbers did NOT survive.** It claimed 28 rows and
"Pepsi - Black has NO edge, needs one MINTED". Live: the gap is **30 triples** — Pepsi - Black
(8), Red Bull - Regular (11), Red Bull - Diet (11) — and Pepsi - Black **has** 8 `boonz_wh` edges
to supersede. **Zero mints.** `Ice Tea - Peach` (6) was already correct.

⭐ **The scope query had to be rebuilt mid-review (Cody, Article 16).** The first version joined
`product_mapping` on `machine_id`, silently dropping global-default rows — which is exactly the
"most specific wins" inference METRICS_REGISTRY names as the single most expensive bug PRD-110
exists to delete (S-10 / S-06). The ratified rule is **a `venue_team` mapping at ANY scope wins on
a `co_managed` machine**, and fixture 30 now encodes that. The banned form measures the SAME 30
today, which is precisely what made it dangerous.

⛔ **Two standing guards against over-correction, both green:** the **77** VOX-supplied `venue`
edges (Fade Fit 44, Aquafina 11, VOX Popcorn 12, Lollies 6, Cotton Candy 4) stay `venue` — each
carries a global `venue_team` row plus a machine-scoped `boonz` row, so they are correct under
ANY-scope and would flip under most-specific-wins; and the **20** Coca-Cola / Mountain Dew edges on
the genuinely mixed `Soft Drinks Mix` pod stay `boonz_wh`, keeping those 3 pods `mixed` and
therefore still `is_constrained`. 📌 Both constants were initially set from differently-scoped
queries (75 / 12) and were corrected to the measured truth by the second migration — neither gap
was a data defect.

**Applied via the canonical writer**, 30 calls to `set_product_sourcing_v3` under operator_admin
impersonation: **30 changed, 0 no-ops**. Conservation exact — `product_sourcing` 4022 → 4052 rows,
Active **still 4022**, Superseded **0 → 30**, venue 116 → **146**, boonz_wh 3811 → **3781**,
partner 95 unchanged, `origin='manual'` **30**. Every change is a supersede pair: N Active
`venue`/manual/attributed against N Superseded `boonz_wh` carrying `valid_to`. **Zero rows deleted,
zero `UPDATE`s of `source`.**

**Effect:** 9 shelves flip `is_constrained` true → false with `available_units` NULL (Red Bull 4,
Pepsi Black 5); the 4 `Soft Drinks Mix` shelves stay constrained at 325 units. Active `boonz_wh`
edges for these products on **fully_managed** machines are untouched (Pepsi Black 19, Red Bull
22+22) — the CS decision was scoped to VOX machines only.

**Suite after apply: 16 of 16 fixtures green, 367 pass / 0 fail / 2 expected_red over 369
assertions** — exactly the leg-46 baseline (347/0/2 over 349) plus fixture 30's 20. Fixture 5 was
flagged in the pointer as likely to move; it **held at 17/0**.

**v19 `engine_add_pod` is byte-untouched** (md5 `630ae01f2ee8f468c079645abd0a7275`, re-verified
after apply) and reads none of `product_sourcing` / `v_shelf_state` / `v_shelf_availability_v3` —
verified before applying, so tonight's 16:00Z live cycle cannot be affected (LAW 12). `v3` md5 and
oid 235798 unchanged. No RPC added or modified, so RPC_REGISTRY needs no amendment.

⚠️ **Live interaction to watch:** `estimate_shelf_composition_v3` reads sourcing to disposition a
count rise. **MPMCC-1058-0000-R0 A02 (Red Bull) is in the flipping set and is cron 44's D-08
burn-in scope** — a count rise there now yields an auto `venue_fill` event instead of an anomaly
row. That is the intended P1.4 behaviour (fixture 19), **not** burn-in drift. Anomalies held at 40
across the change.

---

## PRD-110 P2.4 — demand multipliers (relay leg 48, 2026-07-31)

| version          | name                                                     | what                                                                                                                                                                                                                                                                                                                                   |
| ---------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260731083812` | `prd110_p24_golden_fixture31_demand_multiplier_baseline` | Golden fixture 31 (35 assertions, P2). LAW 1: applied and run **RED at 0/35** before any P2.4 object existed.                                                                                                                                                                                                                          |
| `20260731084025` | `prd110_p24_demand_calendar_and_resolver`                | `demand_calendar` table + 3 CHECKs + partial unique index (`NULLS NOT DISTINCT`) + RLS + `tg_demand_calendar_append_only` + `tg_audit_demand_calendar`; `refill_policy_params.demand_factor_clamp_min/max`; `resolve_demand_multiplier_v3` (INVOKER), `set_demand_factor_v3` (DEFINER writer), `load_dow_profile_v3` (DEFINER loader). |
| `20260731084125` | `prd110_p24_demand_calendar_shape_check_null_safe`       | Forward-only correction of `chk_demand_calendar_shape` (Article 12 — the applied migration was NOT edited) + fixture 31 extended from 3 to 5 malformed-shape probes.                                                                                                                                                                   |

⭐ **The transferable bug, and it is a general one: a CHECK constraint PASSES when it evaluates to
NULL.** The first `chk_demand_calendar_shape` guarded the macro_kpi branch with
`iso_week BETWEEN 1 AND 53`. With a NULL `iso_week` that test is NULL, the branch is NULL, the whole
disjunction is NULL, and **the malformed row was accepted**. The `dow` branch had the identical
hole. Fixture 31 seq 6 caught it on the first green run (`shape_rej` 2, expected 3). Every range
test inside a multi-branch shape CHECK must be guarded by an explicit `IS NOT NULL`.
📌 It would have failed _silently_: such a row is inert in the resolver (its temporal predicate can
never match), so the symptom is "CS authored a factor and nothing happened" — the exact class LAW 5
forbids.

⛔ **Resolution rule, and it is deliberately the OPPOSITE of `product_sourcing`'s.** Within a
source, the **most specific scope wins** (machine > class > fleet); across sources the factors
**multiply**; the product is then clamped to `[demand_factor_clamp_min, demand_factor_clamp_max]`.
Do **not** import S-53's ANY-SCOPE rule here — that rule answers "who supplies this product", this
one answers "which authored factor applies", and conflating them would double-count.

**Ships with an EMPTY calendar on purpose.** Zero active rows ⇒ the resolver returns exactly `1.0`
for every machine ⇒ v3 quantities do not move until CS authors a factor. Fixture 31 seq 5 pins
`active_rows = 0` and is the assertion that deliberately flips on the first authored row.
`load_dow_profile_v3` is **not** invoked by the migration.

---

## PRD-110 P2.4 — engine wiring (relay leg 49, 2026-07-31)

| version     | name                                                     | what                                                                                                                                                                                                                              |
| ----------- | -------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260731…` | `prd110_p24_golden_fixture7_event_uplift_baseline`       | Golden fixture 7 (24 assertions, P2), plan_date **2030-01-08**. LAW 1: applied and run **RED at 15 pass / 9 fail, zero scenario errors, zero residue** before the engine was touched.                                             |
| `20260731…` | `prd110_p24_engine_add_pod_v3_demand_multiplier`         | `engine_add_pod_v3` gains CTE `dmf` (one `resolve_demand_multiplier_v3` call per **picked machine**), `vel_base` (unscaled) beside `vel_eff = vel_base × factor`, and five `reasoning` provenance keys. oid **235798** preserved. |
| `20260731…` | `prd110_p24_reasoning_second_jsonb_object_100_arg_limit` | Forward-only correction (Article 12): the five P2.4 keys move into a **second** `jsonb_build_object` merged with `\|\|`.                                                                                                          |

⭐ **The transferable bug, and it is fully general: `jsonb_build_object` is capped at 100 arguments
= 50 key/value pairs.** The engine's `reasoning` object was already at **49 pairs (98 args)** — one
pair from the ceiling. P2.4's five keys took it to 54 pairs / 108 args and **every engine run died**
with `54023: cannot pass more than 100 arguments to a function`.
⚠️ **Standing rule: before adding a key to `reasoning`, COUNT THE PAIRS.** At 50 the base object is
FULL — append a new `|| jsonb_build_object(...)` group instead.

📌 **It surfaced as a VACUOUS GREEN, and that is the more important lesson.** With the engine dead
both fixture-7 run maps were empty, so every `count(*) FROM jsonb_each` mismatch assertion returned
0 and **passed**. Ten assertions went green on a completely broken engine. What caught it in 30
seconds was fixture 7 **seq 3/4**, the non-vacuity guards ("the baseline run produced lines at all"
/ "at least one line carries a non-zero velocity"). Third time the S-48 / S-52 vacuity discipline
has paid for itself.

⛔ **RECORDED, deliberately NOT acted on (LAW 13).** `sigma_daily_shelf` is derived in `polled` from
`velocity_instock_shelf`/`_pod`, **not** from `vel_eff`. So the multiplier scales the MEAN term but
leaves the SAFETY term unscaled — an uplifted machine carries a proportionally smaller buffer.
BUILD SPEC P2.4 specifies only `effective_velocity = velocity_instock × Πfactors`; scaling sigma too
would be creative interpretation. Parked for CS as **D-18**.

**Still inert on live data.** `demand_calendar` remains empty, so the resolver returns `1.0` for all
31 machines and v3 quantities are byte-unchanged. v19 `engine_add_pod` md5
`630ae01f2ee8f468c079645abd0a7275` **re-verified byte-identical after apply** (LAW 12).

---

## PRD-110 relay leg 50 · 2026-07-31 · P2.6 preflight invariants BLOCKING AT COMMIT

Three migrations. BUILD SPEC P2.6 (WS-B2): "Preflight invariants -> blocking at commit incl. the
corrected INV-06". INV-06 v2 had already shipped under P0.6(d); what was missing was the GATE.
`commit_refill_plan` performed **zero** invariant checking, so a plan carrying a known conservation
leak could be committed with nothing refusing it and nothing recording that it had been let through.

| version        | name                                                       | what                                                                                                                                                                                                                       |
| -------------- | ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 20260731094138 | `prd110_p26_golden_fixture33_preflight_at_commit_baseline` | LAW 1. Golden fixture 33 (35 assertions, P2, plan_date 2030-02-03) + the `golden.probe_commit_under_mode` harness helper. Ran **RED 16 pass / 16 fail with ZERO errors** before the gate existed.                          |
| 20260731094519 | `prd110_p26_preflight_gate_at_commit`                      | The gate. `preflight_override_log.source`, `refill_commit_log.{preflight_verdict, preflight_violation_count, preflight_override_id}`, the new `preflight_override_v3(date,text)` RPC, and the `commit_refill_plan` wiring. |
| 20260731094558 | `prd110_p26_golden_fixture33_consumption_via_commit_log`   | The Cody-required fixture correction, recorded rather than applied silently.                                                                                                                                               |

**Ships INERT.** `refill_policy_params.preflight_enforcement` is `'warn'` and stays `'warn'`. Under
warn the only behavioural change is that the commit response gains a `preflight` block. The flip to
`'block'` remains a parked CS decision and now arms **both** gates (stitch and commit) with one flag.

### ⛔ Cody's material finding — the first design would have silently defeated Article 7

The override was originally to be consumed by stamping `preflight_override_log.consumed_at`. That
table carries `pol_no_update` and `pol_no_delete`. A `postgres`-owned `SECURITY DEFINER` **bypasses
RLS**, so the UPDATE would have succeeded — which makes it worse, not better: the policy would have
been defeated invisibly, by a function that looked compliant.

Consumption is therefore recorded by an **INSERT on the consuming side**:
`refill_commit_log.preflight_override_id` references the grant that let the commit through, and a
partial UNIQUE index makes a grant physically unspendable twice. Both logs stay append-only, and the
audit chain reads forwards (which commit spent which grant) instead of as a mutable flag.
⭐ **Standing rule: when an append-only log needs "consumed" state, put the state on the consumer.**

### ⛔ The `pronargdefaults` landmine caught the first apply

`CREATE OR REPLACE public.commit_refill_plan(date,text,uuid[])` failed with
`42P13: cannot remove parameter defaults from existing function`. The live signature is
`p_machine_ids uuid[] DEFAULT NULL::uuid[]`, and the replacement had dropped the default — the same
class as the 13-day driver-confirm outage. Postgres refused, and **a failed `apply_migration` leaves
nothing behind**: no column, no version row, verified after the failure. ⭐ **Check `pronargdefaults`
before ANY `CREATE OR REPLACE`.** An overload carrying extra defaulted params was rejected as a
design for the same reason: it would make the 3-arg call ambiguous. The grant-then-commit split
avoids the overload entirely and is better audit besides.

### Evidence

Fixture 33 **16/16 RED → 35/35 GREEN**, zero errors in both runs. Full suite re-run all three
phases: **P0 66 pass / 0 fail / 2 expected_red** and **P1 144 / 1 / 0** (the single fail is S-55,
which pre-dates this leg) — both byte-identical to the leg-49 baseline.

LAW 12 cleared: v19 `engine_add_pod` md5(prosrc) `630ae01f2ee8f468c079645abd0a7275` unchanged;
`engine_add_pod_v3` `a79bbe1f8fef8415e14f324e32f8b83b` oid 235798 unchanged; `stitch_pod_to_boonz`
and `preflight_refill_plan` both byte-untouched; `commit_refill_plan` oid **144821 preserved**, one
overload, `pronargdefaults` still 1. Zero live `refill_commit_log` rows touched, crons 13 and 44
unchanged, enforcement still `warn`.

---

## PRD-110 P2 / D-12 — the nightly shadow diff (2026-07-31, relay leg 51)

| Version          | Object                                                                                    | Class   |
| ---------------- | ----------------------------------------------------------------------------------------- | ------- |
| `20260731101049` | `golden.probe_scalar(text)` + golden fixture **34** (45 assertions)                       | harness |
| `20260731101421` | `v_engine_diff_v3` · `v_engine_diff_v3_by_machine` · `v_engine_diff_v3_summary` (3 views) | (a) DDL |
| `20260731102752` | `v_shelf_instock_velocity_v3` — `velocity_status` NULL `stock_hours` guard                | (a) DDL |

### What it closes

BUILD SPEC P2 tail: "nightly diff vs v19 (units, lines, blocked, per-machine)". The **diff half**
is now built and proven. WMAPE tracking and the nightly runner remain (see the leg-51 pointer).

### ⛔ The defect this leg found at STEP R — a diff object that could never return a row

`public.v_shadow_vs_live_plan_v3` (leg 12) reads `pod_refill_plan_shadow` FULL JOIN
`pod_refill_plan`. But `pod_refill_plan_shadow` holds **0 rows** and
`position('pod_refill_plan_shadow' in prosrc) = 0` on `engine_add_pod_v3` — the v3 engine's **only**
INSERT target is `pod_refills_shadow` (ADR §9 addendum: the sibling shadow table landed at P2, not
P3.1, precisely because the Phase-2 acceptance grain is `pod_refills`, not `pod_refill_plan`).

So the object nominated to carry the Phase-2 shadow gate was **structurally vacuous**: it would have
reported "0 differences" forever, and 0 differences reads as PARITY. This is the S-48 / S-52 failure
class sitting in the one place where it would have been believed. It was found by probing the
object's row count rather than its definition.

⭐ **STANDING RULE: a comparison object must be able to say "I compared nothing" out loud.**
`v_engine_diff_v3_summary.is_vacuous` is TRUE whenever either engine contributed zero lines. Any
reader must branch on it before quoting a delta. A count of differences is meaningless without the
count of things compared.

The plan-grain view is **kept** (Article 12, forward-only) and is correct for the grain it names —
it comes alive at Phase-5 cutover. It gains a `COMMENT ON VIEW` that opens with the warning, and
fixture 34 seq 60/61 pin its emptiness as by-design so it can never again be misread.

### ⭐ `golden.probe_scalar(text)` — how a fixture gets to precede its object

LAW 1 says the fixture lands first. But a plain `check_sql` naming a not-yet-created relation fails
at **parse** time, which surfaces as a run ERROR and takes the whole fixture down — so the RED is
unreadable. Legs 47-50 worked around this by choosing fixtures whose objects all already existed
("the RED had to come from BEHAVIOUR"). `probe_scalar` wraps the probe in `EXECUTE` and degrades a
missing relation to a comparable `MISSING: …` sentinel, so the assertion **FAILS cleanly**.

⛔ Assertions built on it must use `eq` / `ne` / `contains`. `golden.compare` RAISES on
`gt`/`gte`/`lt`/`lte` when an operand is non-numeric, so a sentinel under `gt` would produce the
very error the helper exists to prevent.

### Evidence

Fixture 34 **17 pass / 28 fail / 0 errors RED → 45 / 0 / 0 GREEN**. Every one of the 28 failures was
a `MISSING: relation … does not exist` sentinel — zero errors in the RED run.

The fixture recomputes the entire diff **independently from the base tables** into `golden.scratch`
key `truth` and requires the views to reproduce every number; no assertion compares the diff object
against itself. Measured on plan_date 2030-02-04 over two machines: v3 **32 lines / 24 units**, v19
**15 lines / 26 units**, **30 of the joined rows disagree** (seq 9 — an identity view would pass
nothing), duplicate join keys **0 / 0** on both sides, plan-grain view **0 rows** on the same date.

### `20260731102752` — the P2.1 defect this leg's regression run surfaced

Golden **fixture 2 seq 8** ("I7: status ok implies a non-NULL velocity") went **0 → 2** between
09:51Z and 10:15Z. Bisected and reproduced on the base view with no fixture involved, so it is
**not** a regression from the D-12 work (which adds only views over `pod_refills` /
`pod_refills_shadow` / `blocked_demand`).

```sql
velocity_status = CASE WHEN si.machine_id IS NULL         THEN 'out_of_canonical_scope'
                       WHEN a.stock_hours < w.floor_hours THEN 'below_floor'
                       ELSE 'ok' END
```

`stock_hours` is NULL when the series was **never observed in stock** in the window. `NULL < 48.0`
is NULL, not TRUE, so the `below_floor` branch does not fire and control falls through to the
optimistic `'ok'` — while `velocity_instock`, guarded by `stock_hours >= floor_hours`, is correctly
NULL. Status says healthy; there is no velocity behind it.

⭐ **THE GENERAL LESSON: the value guard and the status guard were written against the same column
with opposite NULL behaviour.** `>=` fails SAFE on NULL (no value emitted); `<` fails OPEN on NULL
(falls to the else branch). Wherever a status column classifies what a value column computes, the
two predicates must agree on NULL **explicitly**.

Fixed to `stock_hours IS NULL OR stock_hours < floor_hours`. `below_floor` rather than a new status:
NULL is zero observed in-stock hours, which genuinely is below the floor, and a fourth value would
red fixture 2's `status_other` assertion (domain must stay exactly three).

**Blast radius measured before applying, not assumed:** `engine_add_pod_v3` reads `velocity_status`
from `v_shelf_instock_velocity_split_v3` — the SHELF-grain sibling, which has **0 violations across
all 544 rows** because it anchors on `max(weimi_device_status.snapshot_at)` instead of `now()`. That
sibling was deliberately **not** touched. v19 does not reference `velocity_status` at all, and no
other view in `public` does. ⇒ **zero engine impact, live or shadow**; 2 rows changed label.

📌 **Why it surfaced now:** this view's window is `now() - 30 days` and slides continuously. The last
usable observation fell out between the two runs. The fixture did not go flaky — it went TRUE.

**Evidence:** violations **2 → 0**; status domain unchanged `{ok, below_floor, out_of_canonical_scope}`;
`security_invoker=true` preserved; fixture 2 back to **49/49**; both engine md5(prosrc) unchanged.
Applied by anchored substitution that RAISES if the anchor moved, is already guarded, or the view
has lost `security_invoker` — never a blind patch.

---

## 20260731105057 · 20260731105146 · 20260731105330 · 20260731105439 — golden fixture 36, WMAPE vacuity baseline (P2, D-12)

`prd110_p2_golden_fixture36_wmape_vacuity_baseline` (16,152 chars) plus three corrective migrations
(`…fix_expect_placeholders` 3,806 · `…fix_quote_escaping_depth` 3,618 · `…harden_seq21_seq28_v2`
2,085). Applied by the leg-52 attempt that died before filing anything; adopted and recorded at leg
52 proper — see the EXECUTION-LOG entry for **RISK 104**.

**Fixture 36 — "WMAPE tracking is honest about missing actuals"**, plan_date **2030-02-06**,
**31 assertions**. Written and run **RED first** per LAW 1: 12/19 at 10:51:57Z, re-cut to a
**clean 11 pass / 20 fail with zero errors** at 10:54:52Z before any WMAPE object existed
(`golden.probe_scalar`, leg 51's helper, is what makes a fixture-before-object RED clean rather
than a parse error).

Assertion shape, which is the reusable part: **seq 2-9 are non-vacuity guards** — the engines really
ran, both produced series, the real anchor date carries non-zero actuals, and **seq 9 requires v19
NOT to be a perfect forecaster**, without which an identity implementation would pass everything
after it. **seq 13-17 recompute the snapshot independently from the base tables** and require it to
be reproduced; no assertion compares the object against itself. **seq 20-22** pin the grain,
**seq 23-29** pin vacuity honesty (NULL, not 0.0), **seq 30** idempotence, **seq 31** `anon` privilege.

## 20260731105912 — `engine_forecast_error_v3` + `refresh_engine_forecast_error_v3(date)` (P2, D-12)

The WMAPE **measurement snapshot**. Table PK **`(plan_date, engine_tag, machine_id, pod_product_id)`**;
columns carry `horizon_days`, `horizon_end`, `n_shelves`, `dc_variants`, `forecast_units`,
`actual_units`, `abs_error`, `signed_error`, `actuals_settled`, `velocity_basis`, `run_id`,
`measured_at`. Writer is SECURITY DEFINER, scoped to one `plan_date`, DELETE+INSERT so re-measuring
is idempotent (fixture 36 seq 30). `anon` holds no privilege (seq 31).

⛔ **This is the one place PRD-110 materializes rather than views, and it needed an ADR amendment to
do it** — see `ADR-shadow-plan-tables.md` **§10**, which supersedes §2's _"WMAPE telemetry likewise
[a view]"_ on two independent grounds: a measured **13.5 s floor** on the actuals scan alone
(`v_sales_history_resolved` resolves `pod_product_id` by correlated name lookup, so no index removes
it — RISK 88 territory on every read), and **measurement provenance** — a live view silently rewrites
a WMAPE that CS has already reviewed when sales are restated. The gate is a claim about a point in
time, so it is recorded with `measured_at`, not re-derived.

📌 **Grain is machine × pod, NOT shelf**, because actuals only resolve at that grain and **139 real
(plan_date, machine, pod) groups span more than one shelf** — a shelf grain would double-count their
sales. The PK makes that unrepresentable.

## 20260731110004 — `v_engine_wmape_v3` + `v_engine_wmape_v3_gate` (P2, D-12)

Reader views over the snapshot (`security_invoker=true`, `anon` REVOKEd), so ADR §2's
do-not-materialize-twice intent still governs everything derivable cheaply.

**`v_engine_wmape_v3`** — per (plan_date, engine_tag): `n_series`, `n_series_settled`, sums,
`wmape`, `bias_ratio`, `is_vacuous`, `vacuous_reason`.
**`v_engine_wmape_v3_gate`** — v19 vs v3 side by side with `wmape_delta` and `v3_meets_gate`.

⭐ **Both implement the RISK 102 idiom and it earned its keep immediately.** On the real elapsed date
**2026-06-26** the gate returns `v3_meets_gate = NULL`, `is_vacuous = true`,
`vacuous_reason = 'no_v3_measurement'` — v3 has only ever run on synthetic 2030 dates, so there is
nothing to compare and the object says so instead of implying parity. On 2030-02-06 both engines
report `horizon_not_elapsed` with **WMAPE NULL, not 0.0**.

**First real accuracy measurement in the programme:** 2026-06-26, v19, 141 settled series —
forecast **4106.9** vs actual **2935.0**, **WMAPE 0.7878**, **bias +0.3993** (over-forecasts ~40%).
⛔ One date is not a fleet verdict; it is the gate's denominator awaiting a fortnight of shadow.

---

## PRD-110 P2.7 — nightly shadow runner (leg 53, 2026-07-31)

| version          | name                                                | what                                           |
| ---------------- | --------------------------------------------------- | ---------------------------------------------- |
| `20260731114442` | `prd110_p27_golden_fixture37_nightly_shadow_runner` | Golden fixture 37 + 27 assertions (RED first)  |
| `20260731115020` | `prd110_p27_nightly_shadow_runner_v3`               | Log table + runner RPC + health view + cron 45 |

Closes the last gap before the Phase-2 checkpoint: v3 had **never run on a real plan_date**, so
`v_engine_wmape_v3_gate` read `no_v3_measurement` permanently. Objects: `shadow_runner_log_v3`
(RLS, append-only-on-update via policy **and** trigger, `audit_log_write('id')`, SELECT-only for
`authenticated`), `run_nightly_shadow_v3(date,integer,integer,text)`, `v_shadow_runner_health_v3`,
and cron **45** `prd110_p27_nightly_shadow_runner_v3` at **`22 21 * * *`**.

⭐ **The schedule is a verified derivation, not a guess.** 21:22 UTC = 01:22 Dubai, where
`resolve_refill_plan_date()` returns Dubai _today_ — provably the same plan_date cron 13 targets at
16:00 UTC (20:00 Dubai ⇒ tomorrow). It also lands ~5 h after the pick, giving CS time to clear
Gate 0, and after crons 2/31/5 so fleet and shelf state have settled. Minute 22 collides with no
active cron (hourly jobs sit at :00, :15, :40, :50 and \*/5). Fixture 37 seq 22/23 pin both.

⛔ **LAW 12 untouched:** every DML target in the engine's body is `pod_refills_shadow`; fixture 37
seq 25 witnesses `pod_refills` byte-unchanged across the whole run.

⚠️ **CORRECTION (leg 54): the "SELECT-only for `authenticated`" claim above was NOT true when it was
written.** The migration issued `GRANT SELECT`, but a GRANT is **additive** — Supabase's default
privileges had already granted ALL on the new public table, so `authenticated` in fact held
INSERT/UPDATE/DELETE/TRUNCATE. Only the REVOKE in `20260731121100` made the sentence true. See
S-57 below.

### PRD-110 leg 54 · P2.7 hardening — fixture-37 idempotence + S-57 closed

| version          | name                                              | what                                                 |
| ---------------- | ------------------------------------------------- | ---------------------------------------------------- |
| `20260731120906` | `prd110_p27_fixture37_idempotence_and_grant_pins` | seq 13 → delta; +seq 28/29/30 grant pins (RED first) |
| `20260731121100` | `prd110_p27_revoke_loose_grants_s57`              | REVOKE non-SELECT from `authenticated` on both       |

**Both defects were found by the committed `run_all('P2')`,** which leg 53 left running and could
not read before it closed. Leg 53 saw fixture 37 green on its **virgin** run (27/27); the atomic
run_all disagreed at **26/27**.

⭐ **seq 13 was non-idempotent by construction.** It counted rows in the append-only, durable
`shadow_runner_log_v3`, so the count drifted 1 → 2 → 3 across reruns. Proven rather than inferred:
all nine `(note,step,status)` groups sat at exactly **n=2** after exactly two runs. ⛔ **This would
also have failed STRESS S7** (`run_all()` ×3 → identical results).

⛔ **The obvious fix — let the fixture DELETE its own rows — was REFUSED on Cody review.** The table
carries `tg_srl_v3_no_update` plus an audit trigger and is an Article 7 append-only log, and a
fixture that deleted from it would contradict its **own seq 19**, which exists to prove the absence
probe left the log intact. ✅ Re-expressed instead as a **delta measured across the gate0 call**:
mutates nothing, idempotent by construction, and **strictly stronger** than the original — it proves
_this_ run wrote exactly one row, where an absolute count could be satisfied by another writer's.
⛔ Not weakened to `gte 1`; a double-write is the regression it exists to catch.

⛔ **S-57 was wider than recorded and is now CLOSED.** Grants were loose on **both**
`engine_forecast_error_v3` and `shadow_runner_log_v3` (the table leg 53 recorded as already
following the stricter standard). Seq 26/27 missed it because they check **`anon` only** — fixture
36 seq 31's exact blind spot, repeated. ✅ Safe to revoke, verified live not assumed: the only
writers are `refresh_engine_forecast_error_v3` and `run_nightly_shadow_v3`, both **SECURITY DEFINER
owned by `postgres`**, so every legitimate write is unaffected. SELECT is deliberately retained and
seq 30 pins that the REVOKE did not go too far.

---

## PRD-110 P3.1a — category-first substitute selection (leg 55, 2026-07-31)

| version          | name                                                      | what                                                               |
| ---------------- | --------------------------------------------------------- | ------------------------------------------------------------------ |
| `20260731125118` | `prd110_p31a_golden_fixture39_category_first_substitutes` | fixture 39 (37 assertions) + `golden.config.current_phase` P2 → P3 |
| `20260731125150` | `prd110_p31a_find_substitutes_for_shelf_v3`               | new versioned selector; v1 untouched                               |

**The incident, reproduced before it was fixed.** BUILD-SPEC line 89 (CS, 2026-07-31): raw Pearson
basket correlation finds COMPLEMENTS, not SUBSTITUTES. Live RED on machine `4b235d37` / anchor
**Fade Fit** (Protein & Health Bars): v1 rank 1 = **Pepsi Regular**, while SIX in-category protein
bars sat in stock, unassorted. After v3: ranks **1-6 are all Protein & Health Bars** and Pepsi
Regular falls to rank 8.

⭐ **The object CS's correction names is not the object to fix.** `v_pod_substitutes` — the pure
Pearson view — has **zero consumers in `pg_proc`**. It is dead code; fixing it would have changed
nothing. The live path is `find_substitutes_for_shelf`, consumed by `engine_swap_pod` and
`compute_nowh_proposals`.

⛔ **Rule (2) was ALREADY live.** The BUILD SPEC calls the in-machine duplicate an open bug, but v1's
`present` CTE (slot_lifecycle ∪ live stock > 0) already excludes. It was NOT re-fixed — only pinned.

⭐ **Article 16 was the one substantive review finding.** The first draft inherited v1's inline
re-derivation of two _registered_ metrics. Both now read canonical objects: **WH pickable stock** →
`v_wh_pickable`, **candidate basket affinity** → `get_candidate_affinity()`. ⛔ Proven behaviour
neutral BEFORE the swap, not assumed: 122 pods with stock > 0 under both the inline and the
canonical read, **identical sets and identical quantities** on both anchor machines; the only two
differing rows sum to exactly 0 inline and are dropped by `wh_stock > 0` either way. One deliberate
semantic delta: `get_candidate_affinity` COALESCEs an unknown correlation to **0** where v1 left it
NULL — immaterial to ranking (Pearson is only the third tiebreak) but `pearson_score` now reads 0.
📌 `global_v30` (fleet-wide AVG of `slot_lifecycle.velocity_30d`) is **not** a registered metric and
stays inline; register it if it is ever promoted.

⭐ **The trap that would have sunk the fixture.** The CS incident machine `9db7a821` (Hunter Ridge)
has **ZERO** in-category candidates — all four Chips & Crisps pods holding WH stock are already on
the machine, so rule (2) removes every one. The correct v3 answer there is **still cross-category,
but flagged**. A fixture demanding an in-category winner _there_ would be unsatisfiable by
construction — a second S-55. So the fixture carries **two anchors**: `4b235d37` proves the category
path (350 such (machine, anchor) pairs exist across **37** machines), `9db7a821` proves the FLAG
path. Seq 6 pins the 0 explicitly so the trap stays visible to the next reader.

⚠️ **S-59 (open).** The taxonomy is fragmented — `Chips` (1 pod) beside `Chips & Crisps` (13),
`Chocolate Bar` (2) beside `Chocolates` (9), 3 pods NULL. v3 matches on **exact equality** and will
under-reach. That is deliberate: a merge mapping is a CS taxonomy decision, not one to invent
(LAW 10). The under-reach is never silent — it surfaces as `requires_cs_review`.

✅ **D-20 CORRECTED.** Leg 54 recorded "margin is not available at pod grain". That is **false** —
`pod_products.purchasing_cost` exists and is populated for **102 / 163** pods (88 have both cost and
RSP). `unit_margin` is now RETURNED, but deliberately **not** a ranking term: at 54% coverage a
margin weight would systematically demote the 46% with no cost on file. Weighting it is the parked ask.

✅ **S-57 applied FORWARD.** v1 is executable by `anon` today (Supabase default privileges). v3 ships
tight from birth — explicit REVOKE from `PUBLIC` **and** `anon`, GRANT to `authenticated` +
`service_role`, with fixture seq 33/34 pinning **both** directions. A GRANT is additive; only a
REVOKE narrows.

**Evidence.** Fixture 39 RED **22 pass / 15 fail** with the function absent, then **37 / 37** green,
then **37 / 37 three more consecutive times** at ~300 ms (S7 pre-cleared — S-58's lesson that one
green run is not idempotence). Eligibility parity: v1 and v3 return the **same 39 candidates**;
v3 re-ranks, it does not re-filter (seq 28). v1 `md5(prosrc)` **`8486ff04…`** pinned by seq 30.

## PRD-110 P3.1b — supply ladder (relay leg 56, 2026-07-31)

| version          | name                                         | what                                                                                                                                                                                   |
| ---------------- | -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260731133705` | `prd110_p31b_golden_fixture40_supply_ladder` | Golden fixture 40 (38 assertions, plan_date 2030-02-10). Applied and run RED before the function existed, per LAW 1.                                                                   |
| `20260731134008` | `prd110_p31b_fixture40_scratch_jsonb_fix`    | Corrective: `golden.scratch.value` is **jsonb**, not text. Scenario now stores one jsonb object per key (fixture 39's house idiom).                                                    |
| `20260731134351` | `prd110_p31b_resolve_supply_ladder_v3`       | `resolve_supply_ladder_v3` — BUILD-SPEC line 88 ladder. READ-ONLY (STABLE, SECURITY INVOKER). Cody-reviewed; no consumer wired (D-22).                                                 |
| `20260731140159` | `prd110_p32_golden_fixture41_m2m_sku_legs`   | Golden fixture 41 (46 assertions, plan_date 2030-02-11). Applied and run RED before the function existed, per LAW 1. Two mirror anchors off ONE source shelf.                          |
| `20260731140547` | `prd110_p32_fixture41_provolatile_cast_fix`  | Corrective: `pg_proc.provolatile` is type `"char"`, so bare `\|\|` is ambiguous. Cast added. Found BY the RED baseline (seq 46 errored rather than evaluating).                        |
| `20260731140551` | `prd110_p32_resolve_m2m_sku_legs_v3`         | `resolve_m2m_sku_legs_v3` — BUILD-SPEC line 90, M2M at SKU level. READ-ONLY (STABLE, SECURITY INVOKER). Cody-reviewed. Live writers left byte-untouched and md5-pinned by the fixture. |

All three are additive. **0 protected-entity writes, 0 rows deleted, 0 flags flipped, 0 crons changed.**
v19 `engine_add_pod`, `commit_refill_plan`, v1 `find_substitutes_for_shelf` and P3.1a
`find_substitutes_for_shelf_v3` all byte-untouched (pinned by fixture 40 seq 33/34).

## PRD-110 P3.5 — value-at-risk picker (relay leg 58, 2026-07-31)

| version          | name                                           | what                                                                                                                                                                                                                                                                                                               |
| ---------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `20260731143009` | `prd110_p35_var_capacity_params`               | Seven `var_*` day-capacity columns + `chk_var_capacity_params_sane` + column comments on `refill_policy_params`. Applied BEFORE the fixture because the fixture's own independent recomputation reads `var_default_gap_days`.                                                                                      |
| `20260731143037` | `prd110_p35_golden_fixture42_var_picker`       | Golden fixture 42 (51 assertions, plan_date 2030-02-12). Applied and run RED before the function existed, per LAW 1.                                                                                                                                                                                               |
| `20260731143218` | `prd110_p35_fixture42_vacuous_assertion_fix`   | Corrective: **11 assertions passed VACUOUSLY** in the RED (S-70). Violation-counting assertions return 0 over an empty input, so seq 27 — "THE SPINE" — passed against a function that did not exist. Each body wrapped in a NO_PICKER_OUTPUT guard.                                                               |
| `20260731143736` | `prd110_p35_rank_machines_by_value_at_risk_v3` | `rank_machines_by_value_at_risk_v3` — BUILD-SPEC line 93. READ-ONLY (LANGUAGE sql, STABLE, SECURITY INVOKER).                                                                                                                                                                                                      |
| `20260731144037` | `prd110_p35_fixture42_blind_machine_sensor`    | Two assertions added after the first GREEN exposed S-71: five AMZ machines score 0.00 AED because 60% of their shelves are unmeasurable, not because they are safe. Pins the coverage counters beside every zero.                                                                                                  |
| `20260731145040` | `prd110_p35_var_picker_dsv_canonical_source`   | **Cody revision (Article 16):** `days_since_visit` re-pointed from `v_machine_priority` (a consumer's pass-through copy) to `v_machine_health_signals`, the object METRICS_REGISTRY line 49 registers as its owner. 0 numeric change (31 machines, 0 disagreements) — a provenance fix. +2 assertions (seq 54/55). |

All six are additive. **0 protected-entity writes, 0 rows deleted, 0 flags flipped, 0 crons changed.**
v19 `engine_add_pod`, `commit_refill_plan`, `engine_add_pod_v3`, the P3.1a/P3.1b/P3.2 selectors and
BOTH live Gate-0 objects (`pick_machines_for_refill` `d9f508d1…`, `confirm_machines_to_visit`
`a3344191…`) all byte-untouched — pinned live by fixture 42 seq 49/50.

⚠️ **`refill_policy_params` gained a CHECK, so a bad config is now a constraint violation rather
than a picker that silently selects nothing.** `var_travel_minutes_inter_cluster >= intra` is part
of it: an inverted travel model would make the greedy walk prefer to leave the cluster.

## PRD-110 P3.3 — rotation heartbeat (relay leg 59, 2026-07-31)

| version          | name                                                    | what                                                                        |
| ---------------- | ------------------------------------------------------- | --------------------------------------------------------------------------- |
| `20260731151435` | `prd110_p33_rotation_proposals_v3`                      | advisory proposal queue + RLS + 3 conservation CHECKs + idempotency UNIQUE  |
| `20260731151725` | `prd110_p33_rotation_params`                            | 5 `rot_*` policy params + `chk_rot_params_sane`                             |
| `20260731152203` | `prd110_p33_golden_fixture43_rotation_heartbeat`        | fixture 43 row (RED baseline)                                               |
| `20260731152206` | `prd110_p33_golden_fixture43_assertions`                | 50 assertions, S-70-wrapped at authoring time                               |
| `20260731152558` | `prd110_p33_fixture43_expiry_date_basis_fix`            | ⛔ S-75 expiry horizon re-based to `CURRENT_DATE` + sensor-for-the-sensor   |
| `20260731152701` | `prd110_p33_fixture43_seq42_real_idempotency`           | seq 42 was a duplicate of seq 41; re-expressed against the table            |
| `20260731152842` | `prd110_p33_propose_rotations_v3`                       | the heartbeat writer                                                        |
| `20260731153432` | `prd110_p33_propose_rotations_v3_on_conflict_ambiguity` | ⛔ S-76 `ON CONFLICT` column list ambiguous vs OUT params → name constraint |

⛔ **`public.rotation_proposals` DOES NOT EXIST and must stay that way.** P3.3 was built once
before and retired: its 22 rows live in `graveyard.rotation_proposals`, and three SECURITY
DEFINER functions (`propose_rotation_plan`, `apply_rotation_proposal`, `reject_rotation_proposal`)
still reference the dead `public.` path, still hold **`anon` EXECUTE**, and throw on every call.
They fail closed today only because the table is absent — creating a table at that name would
silently reanimate three anon-reachable definer writers. Fixture 43 seq 50 is the sentinel. **S-74.**

⚠️ **The new table is written by exactly one object** (`propose_rotations_v3`); it has a SELECT
policy for `authenticated` and no INSERT/UPDATE/DELETE policy at all, so the CS gate cannot be
flipped from a client. No approve/reject RPC exists yet — when one is written it OWNS the
transition graph, because a CHECK constraint cannot see the old row.

### PRD-110 leg 61 — D-26 (CS-answered) implemented

| version          | name                                             | note                                                                        |
| ---------------- | ------------------------------------------------ | --------------------------------------------------------------------------- |
| `20260731160701` | `prd110_p33_rot_keep_floor_param_d26`            | `rot_keep_floor` int NOT NULL DEFAULT **2**, `CHECK >= 0` (0 = strip)       |
| `20260731160935` | `prd110_p33_fixture43_keep_floor_d26_red`        | LAW 1: fixture adopts the floor FIRST → 6 real fails. +seq 54/55            |
| `20260731161258` | `prd110_p33_propose_rotations_v3_keep_floor_d26` | `LEAST(GREATEST(stock - floor, 0), headroom)` — Cody rev 2 is load-bearing  |
| `20260731161300` | `prd110_p33_fixture43_rot_param_addition_proof`  | ⛔ S-79 absolute `count(*)=5` over a growing family → required-set / 0-viol |

⛔ **S-78 — fixture 43 occupies seq 1..53 CONTIGUOUSLY.** The new assertions were first written at
seq 46/47, both TAKEN. An `ON CONFLICT (fixture_id, seq) DO UPDATE` would have **silently
overwritten two live assertions and still reported a clean apply**. Assertion INSERTs must be
BARE so a seq collision ERRORS. Landed at 54/55; fixture 43 is now **55 assertions**.

### PRD-110 leg 62 — D-24 + D-25 (CS-answered) implemented, S-81 closed, S-79 swept

| version          | name                                           | note                                                                                           |
| ---------------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `20260731163542` | `prd110_p35_d24_cadence_breach_params`         | `var_cadence_floor_multiple` **2.0** + `var_cadence_hard_max_days` **14**, NEW check (no DROP) |
| `20260731163545` | `prd110_p35_d24_d25_money_first_picker`        | D-24 money-first sort + D-25 staleness tiebreak. md5 `8c4dc618…` → `3a6c5914…`                 |
| `20260731163549` | `prd110_p35_s81_revoke_var_picker_anon_public` | S-81: `REVOKE EXECUTE … FROM anon, PUBLIC` on the VAR picker                                   |
| `20260731163924` | `prd110_p35_fixture42_d24_d25_s81_rebaseline`  | fixture 42 55 → **67** assertions; seq 21/40 re-expressed, 20/22/23/31–35 re-described         |

⛔ **THE ARTICLE-12 MOVE WORTH COPYING.** D-24 needed a new output (`breached` vs `target-due`) on
a function with a `RETURNS TABLE` signature. Adding an OUT column forces `DROP` + `CREATE`, which
Article 12 forbids. Instead the EXISTING `cadence_floor_due` column was **redefined** to mean
BREACHED — which is what its name always said — and the displaced soft state moved into the
`reasoning` blob as `reasoning.cadence.target_due`. Signature byte-identical, `pronargdefaults`
held at 1, so this stayed a true `CREATE OR REPLACE`.

⛔ **A SEMANTIC REDEFINITION IS INVISIBLE TO POSTGRES — the blast radius must be probed and
RECORDED, not assumed.** Before applying: **0 FE call sites · 0 `pg_proc` callers · 0 `pg_views` ·
0 `cron.job`** — sole reader was golden fixture 42. That evidence is now written into the
RPC_REGISTRY entry, because the next reader cannot re-derive "it was safe at the time" from a diff.

⭐ **S-79 SWEEP DONE (the 📌 item the leg-61 pointer flagged for before STEP 7).** Every enabled
assertion of the shape `count(*) = <literal>` over a `LIKE 'prefix\_%'` family was audited across
all 27 fixtures. **Fixture 42's `var_*` exposure was the last live instance** and is now covered by
seq 58 (REQUIRED-SET) + seq 59 (0-VIOLATIONS). Fixture 43 seq 3 and fixture 39 seq 31 count against
**named arrays**, not prefixes, so they do not grow with the roadmap. Nothing else matched.

## PRD-110 relay leg 63 — P3.1c opens: the ladder's first consumer finds the ladder broken

| version          | name                                          | what                                                                                                     |
| ---------------- | --------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `20260731170130` | `prd110_p31c_s85_ladder_rung1_record_fix`     | S-85: `resolve_supply_ladder_v3` crashed on every rung-1-satisfiable call; md5 `ec8dffa2…` → `920b32d0…` |
| `20260731170528` | `prd110_p31c_s85_s86_fixture40_rung1_anchors` | fixture 40 38 → **56** assertions; anchors C (rung-1 full) + D (rung-1 partial)                          |

⛔ **A 38/38 GREEN FIXTURE GUARDED A FUNCTION THAT THREW ON ITS HAPPIEST PATH.** For its whole
P3.1b life `resolve_supply_ladder_v3` raised `55000 record "v_sub" is not assigned yet` on **every
call whose demand was satisfiable from the primary warehouse**. The rung-2 _log_ entry dereferences
`v_sub` unconditionally; the `SELECT INTO` that assigns it runs only when rung 1 has already
**failed**. Fixture 40 could not see it because anchors A and B are **both deliberately starved** —
A is the sentinel trap, B is the contention case — so between them the suite proved rungs 2-6 and
never once executed terminal rung 1.

⭐ **THE HABIT THIS EARNS, BINDING BEYOND THIS FUNCTION.** The bug surfaced the moment the object
was exercised **the way its real consumer would** — 6 live shadow-plan lines rather than 2
hand-picked anchors — and it surfaced in the first 10 seconds of doing so. **An advisory object
with zero consumers has never had its happy path executed.** PRD-110 currently holds two more in
exactly that state: `resolve_m2m_sku_legs_v3` and `rank_machines_by_value_at_risk_v3` (advisory,
no consumer). ⛔ Before wiring ANY of them, run them across a real population first, not across
their fixture's anchors.

⛔ **AND THE GENERAL FORM: A FIXTURE BUILT FROM AN INCIDENT INHERITS THE INCIDENT'S BLIND SPOT.**
Fixture 40's anchors came from the 07-30 blocked-demand incident, so both are starved _by
construction_ — the fixture was a faithful record of a failure mode and, for that exact reason, a
systematically incomplete test of the function. When a fixture's anchors all come from one
incident, **add an anchor from the ordinary case on purpose.**

📌 **PL/pgSQL mechanism, so it is not re-learned:** an unassigned `record` has an INDETERMINATE
tuple structure, and a `CASE` guard does **not** protect a field reference inside it — the
structure must be resolved to build the expression, whichever branch runs. Eight NULL-initialised
scalars remove the failure mode _by construction_. Signature, `STABLE`, `SECURITY INVOKER`,
`search_path` and `pronargdefaults` (1) all byte-identical: a true Article-12 `CREATE OR REPLACE`.

📌 **S-86, discovered in the same pass:** the ladder does **not** cascade after a partial fill. The
terminal rung is the first _satisfiable_ rung at any quantity, so a 1-of-2 fill stops at rung 1 with
rung 2 reading `attempted: false`. The stranded unit is a **LAW 5 obligation on the consumer**.
Fixture 40 seq 55 states that as a contract so `stitch_v3` cannot be built without honouring it.

---

## PRD-110 P3.1c — `stitch_v3` skeleton, its shadow ledger, and the S-88 grant sweep (leg 64)

| version          | name                                             | what                                                           |
| ---------------- | ------------------------------------------------ | -------------------------------------------------------------- |
| `20260731173118` | `prd110_p31c_refill_plan_output_shadow`          | new SKU-grain shadow ledger, append-only by TRIGGER            |
| `20260731173122` | `prd110_p31c_stitch_v3_skeleton`                 | `stitch_v3(date, uuid)` — md5 `10ae3658…`, `pronargdefaults` 1 |
| `20260731173609` | `prd110_p31c_shadow_ledger_revoke_authenticated` | strips the default-privilege grants fixture 44 seq 25 caught   |
| `20260731173710` | `prd110_p31c_golden_fixture_44_stitch_v3`        | fixture 44, **30 assertions**                                  |
| `20260731173815` | `prd110_p31c_s88_revoke_truncate_sweep`          | S-88 swept across the seven sibling PRD-110 tables             |

⛔ **S-88 — `REVOKE ALL … FROM PUBLIC` DOES NOT UNDO SUPABASE'S DEFAULT PRIVILEGES, AND TRUNCATE
BYPASSES BOTH RLS AND ROW-LEVEL TRIGGERS.** `ALTER DEFAULT PRIVILEGES` grants the `authenticated`
**role** every privilege on each new `public` table at CREATE time. Revoking from `PUBLIC` does not
touch a role grant, and `GRANT` only adds — so a migration that enables RLS, writes policies, and
grants `SELECT, REFERENCES, TRIGGER` still ships with `authenticated` holding INSERT/UPDATE/DELETE/
**TRUNCATE**. RLS `USING (false)` and a `FOR EACH ROW` append-only trigger both stop UPDATE and
DELETE; **neither stops TRUNCATE**, which is not a row operation. The "immutable ledger" was
erasable by any logged-in user.

⭐ **How it was caught, and why the sweep matters more than the fix.** Golden fixture 44 seq 25 was
written as a routine Article-1 check against the table _this leg created_ — and failed on the first
run. The sweep then found the identical hole on **seven** PRD-110 siblings: `inventory_events`
(append-only event log, Article 7), `product_sourcing` (append-only versioning), `blocked_demand`
(the LAW 5 ledger), `machines_to_visit` (the Gate-0 table, 1,240 rows), `shelf_composition`,
`inventory_anomalies`, `demand_calendar`. Per the S-79 habit the sweep was **closed, not sampled**.

📌 **The sweep revokes TRUNCATE ONLY.** INSERT/UPDATE/DELETE are left exactly as found: RLS already
gates them, and revoking could break a legitimate FE path. Probed before applying — **0 functions
and 0 cron jobs** issue TRUNCATE against any of the eight tables, so nothing legitimate lost a
capability. ⛔ **Binding on every future `CREATE TABLE`: `REVOKE ALL … FROM authenticated` FIRST,
then grant back the narrow set.** Enabling RLS is not sufficient.

---

## PRD-110 P3.1c / S-89 — the rung-4 m2m branch made executable (2026-07-31, relay leg 65)

| Version          | Name                                             | What                                                                                                                                                        |
| ---------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260731180311` | `prd110_p31c_s89_list_m2m_donors_v3`             | NEW read-only fn: names rung-4 donors at shelf grain (ladder only counted them).                                                                            |
| `20260731180315` | `prd110_p31c_s89_resolve_m2m_donor_legs_v3`      | NEW rung-4 seam v1.                                                                                                                                         |
| `20260731180809` | `prd110_p31c_s92_donor_legs_v3_resolvable_donor` | Seam **v2**: walk donors until one has a knowable SKU mix. Forward-only replacement of v1 (Article 12 — a new migration, never an edit of the applied one). |
| `20260731180815` | `prd110_p31c_s91_stitch_v3_rung4_executable`     | `stitch_v3` rung-4 branch rewired to the seam. Fixes S-91 D1–D4.                                                                                            |
| `20260731181118` | `prd110_p31c_golden_fixture_45_rung4_m2m`        | Golden fixture 45 (18 assertions).                                                                                                                          |

⛔ **`stitch_v3`'s body was SPLICED from the live definition**, replacing only the block between the
rung-3 and rung-5 markers, so every other byte (role gate, source-run pick, rungs 1–3, the LAW 5
blocked row, the conservation assert, the return shape) is provably unchanged. `pronargdefaults=1`
preserved — `p_source_run_id` keeps `DEFAULT NULL::uuid` (RISK 101 / the Wave-2 confirm outage).
md5 `10ae3658…` → `6e0ea323…`. ⛔ `resolve_supply_ladder_v3` deliberately **left byte-untouched** at
`920b32d0…`: its `donor_machines` count is a diagnostic with other readers, and re-tightening its
rung-4 velocity is its own reviewed unit, not a drive-by.

### ⛔ How the never-executed branch was actually proven (S-85's lesson, applied)

A clean `CREATE` and a green happy-path dry-run prove nothing about a branch they do not enter
(S-90). Rung 4 cannot be reached from live data, so the end-to-end proof ran inside a
`BEGIN … ROLLBACK` envelope that neutralised **rung 2 only** (a transaction-scoped stub of
`find_substitutes_for_shelf_v3`; rungs 1 and 3 already fail naturally for pod `b1827ff7`, which has
zero pickable stock at every warehouse). **First execution in the branch's life:** 4 units in → one
`Refill` leg of **2** units, `source_origin='internal_transfer'`, `from_machine_id` = donor
`9acce2bf`, `boonz_product_id` bound, `lines_source='shelf_composition_via_callee'` — plus an honest
`m2m_donor_capped` Blocked row for the 2 units the donor could not cover. Conservation held.
⛔ **Rollback verified byte-exact:** `find_substitutes_for_shelf_v3` back at `ca7c52f9…`, and
`refill_plan_output_shadow`/`pod_refills_shadow` carry **0** rows from the envelope.

---

## PRD-110 P3.1d — FEFO SKU binding (2026-07-31, relay leg 66)

| Version          | Name                                   | What it does                                                                                                                                           |
| ---------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `20260731183908` | `prd110_p31d_resolve_fefo_sku_legs_v3` | NEW read-only seam (INVOKER, STABLE) + Cody's grant revision (`REVOKE … FROM PUBLIC, anon`; `GRANT … TO authenticated, service_role`).                 |
| `20260731183912` | `prd110_p31d_stitch_v3_fefo_binding`   | `stitch_v3` rung-1/2/3 emit block rewired to bind SKUs. **Spliced** from the live `pg_get_functiondef`; `pronargdefaults=1` preserved by construction. |
| `20260731183914` | `prd110_p31d_golden_fixture_46`        | Golden fixture 46 + 27 assertions (plan_date 2030-02-16).                                                                                              |

### The incident this closes

Every `stitch_v3` warehouse-rung row shipped with `boonz_product_id NULL` and
`reasoning.sku_binding='deferred_to_p31d'`. The plan named a **pod** but never a **product** and
never a **batch** — so no picker could be told which flavour to pull, and no batch could be
reserved. Only the rung-4 m2m legs (leg 65) bound a SKU at all.

### ⛔ The horizon split — the thing that will trip the next reader (S-94)

`resolve_supply_ladder_v3` counts supply through `v_wh_pickable`, whose expiry test is against
**today** (Dubai). `wh_fefo_for_line` filters `expiration_date >= p_plan_date`. On production dates
(plan_date = tomorrow) the two differ by a day and the difference is _correct_ — you should not
dispatch stock that expires before the plan date. **On a synthetic 2030 fixture date they diverge
totally:** the newest real non-sentinel batch in the warehouse expires **2027-12-29**, so the ladder
happily rules units placeable while FEFO can bind **none of them**.

⭐ This is why fixture 46 calls the seam **twice** — once on today's horizon (proving it binds) and
once on 2030 (proving LAW 7 refuses, by name). A fixture that only ran on its own 2030 date would
have proved nothing but the refusal, and a green suite would have hidden the fact that binding had
never been exercised at all. ⛔ **Do not "fix" the divergence by relaxing the plan_date filter** —
it is LAW 7, and it is the reason expired stock cannot exit by assumption.

### How it was proven (S-91's lesson applied)

- **Regression, on the existing 2030 source run:** 13 lines in → **13 rows out, unchanged**,
  conservation held, **zero** `deferred_to_p31d` markers, all 13 rows carrying the named reason
  `no_pickable_batch_in_scope`. Nothing binds on that horizon, so the row shape is byte-comparable
  to the pre-P3.1d behaviour — the regression case and the feature case are the same code path.
- **The binding itself, in a `BEGIN … ROLLBACK` envelope** on a synthetic shadow source line dated
  today (shadow tables only; LAW 12 untouched): **1 anonymous line of 12 units → 3 SKU-bound
  `Refill` legs** in strict FEFO order — 1 unit from the `2026-12-04` batch, 10 from `2027-01-09`
  (spanning two batches of that SKU), 1 from `2027-01-30` — each carrying its own
  `preferred_wh_inventory_id`. It drained a **single-unit** oldest batch before moving on, which is
  the whole point of FEFO and is exactly what a per-SKU-only binder would never do.
- **The per-SKU ceiling was verified by decomposition, not assumed:** the seam bound 34 of a
  nominal 82 units, and the six per-SKU ceilings (`real stock − committed_elsewhere`, sentinels
  excluded) sum to **exactly 34**. ⚠️ The "82" came from an ad-hoc probe that summed
  `warehouse_inventory` **through a `product_mapping` join** — the documented fan-out anti-pattern,
  reproduced live in the course of this leg. The real figure is 46 gross / 34 net. The seam avoids
  it by deduping variants first, exactly as the ladder does.

---

## PRD-110 P3.1e — the blocked_demand promotion (2026-07-31, relay leg 67)

| Version          | Name                                              | What it does                                                                                                                                                                       |
| ---------------- | ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260731190752` | `prd110_p31e_blocked_demand_stitch_gap_sources`   | THREE new read-only helpers (INVOKER): `_blocked_demand_reason_map_v3`, `_blocked_demand_gaps_stitch_v3`, `_blocked_demand_gaps_for_source_v3`. All REVOKEd from `PUBLIC, anon`.   |
| `20260731190759` | `prd110_p31e_record_blocked_demand_stitch_source` | `record_blocked_demand_v3` learns `source='stitch'`. **Spliced** from the live definition; 2 args / 1 default / SECURITY DEFINER preserved by construction. + Cody's ACL revision. |
| `20260731191217` | `prd110_p31e_golden_fixture_47`                   | Golden fixture 47 + **50** assertions (plan_date 2030-02-17).                                                                                                                      |
| `20260731192336` | `prd110_p31e_stitch_marker_truthful`              | `stitch_v3` Blocked-row marker corrected: it promised a writer that now exists. One jsonb value; no control flow touched.                                                          |

### The incident this closes

BUILD SPEC P0.5 names **three** writers of the ledger — `engine_add_pod`, `stitch`, and the
FEFO-bind step. Only `engine_add` existed (cron 43, nightly). Every unit `stitch_v3` stranded since
P3.1c carried the marker `blocked_demand_promotion = 'source=stitch writer lands with the live
cutover (P3.1e)'` and **reached no human**: the plan knew the demand was unmet, and procurement was
never told. Stitch and the FEFO-bind step are one source, not two, because after P3.1d the binding
happens inside `stitch_v3` and its unbound rows land in the same shadow output.

### ⭐ The design decision this unit exists to make — the reason map

`blocked_demand.reason` is a four-value CHECK constraint; `stitch_v3` computes far richer named
reasons (`m2m_donor_capped`, `spot_buy_candidate`, `no_pickable_batch_in_scope`, …). The mapping is
therefore **lossy by design**, and it is organised by the action a human must take, not by what went
wrong: `blocked_no_wh` → BUY it · `partial_wh_limited` → BUY the balance · `routing_gap` → MOVE it ·
`substitution_exhausted` → DECIDE. The loss is compensated — the original named reason is always
carried into `reasoning->'components'`, so no diagnosis ever depends on the enum alone.

⛔ It lives in its own named function precisely so it is testable without a pipeline run. On this
fleet the ladder stops at rung 1 or 2, so an end-to-end fixture can only ever exercise **2 of the 17**
named reasons; the other fifteen — every m2m and every FEFO reason — are asserted directly.

### ⛔ Two row kinds, one ledger row

`uq_blocked_demand_open` keys on `(plan_date, machine_id, shelf_id, pod_product_id, source)`, so a
shelf gets exactly one open row per source. That forces a merge of two different failures:
**`unplaced`** (an explicit `Blocked` row — the ladder placed nothing) and **`unbound`** (a row that
DOES ship at qty > 0, but which no batch could name a SKU for). Both are demand no nameable warehouse
batch can serve, which is exactly what the ledger is for, so `qty_blocked` is their SUM — and
`reasoning.qty_unplaced` / `qty_unbound` / `components[]` split it back out so the two are never
confused. ⚠️ `v_blocked_demand_open` does not project those keys, so a consumer reading only
`qty_blocked` sees one conflated number; the breakdown is reachable through the view's `reasoning`.

⛔ Keyed on **`anchor_pod_product_id`**, not `pod_product_id`. A rung-2 substitution emits its rows
against the SUBSTITUTE pod while the `Blocked` row carries the ANCHOR; keying on the emitted pod
would split one shelf's demand into two ledger rows that each look like a separate problem.

### How it was proven

- ⛔ **The live path was diffed, not inspected.** Cron 43 (`prd110_p05_blocked_demand_2015_dubai`,
  `15 16 * * *`, ACTIVE) calls this function nightly with the default source. `record_blocked_demand_v3`
  was called on **three** real gap-bearing dates before and after, in rolled-back transactions:
  `2026-07-30` (20 gaps / 107 units), `2030-01-06` (14 / 119), `2030-04-16` (16 / 49) — **all three
  results byte-identical**, and the two gap sets `EXCEPT`-ed both ways returned empty.
- Fixture 47 green **50/50**, `vacuous: false`. Conservation asserted: ledger units = stitch's
  unplaced + unbound exactly.
- Full P3 suite re-run and **persisted**: 39 `37/0` · 40 `56/0` · 41 `46/0` · 42 `67/0` (101.7 s) ·
  43 `55/0` (103.1 s) · 44 `30/0` · 45 `18/0` · 46 `27/0` · 47 `50/0` — **386 assertions, 0 fail**.
- The two P0 fixtures that exercise this writer re-run green: **105** (`P0.5 ledger 1:1`) `15/0`
  and **5** `17/0`. ⚠️ Both take ~55–60 s despite being P0 — the documented P0 budget understates them.
- ⛔ P2 fixtures 2/14/34 were **not** re-run, and that is safe by inspection rather than by hope:
  their `blocked_demand` assertion is an ADR-8.3 tripwire comparing a **global** count against a
  `before` snapshot taken _inside their own run_, so it is self-relative and cannot see this leg's rows.

### ⛔ Why the promotion is NOT wired into stitch_v3

`RPC_REGISTRY` records that `stitch_v3` _"writes exactly one table, which has no operational consumer
(LAW 4)"_. `blocked_demand` **has** one — procurement reads `v_blocked_demand_open`. Auto-promotion
would make a shadow engine write into a live consumer's path, and would also double-count against the
`engine_add` row for the same shelf (different `source` ⇒ a second open row). Parked as **D-29**.

## PRD-110 P3.4 — facing rightsizing (relay leg 68, 2026-07-31)

| Version          | Name                                 | What                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ---------------- | ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260731194715` | `prd110_p34_facing_params`           | 8 additive `fac_*` policy columns on `refill_policy_params` + `chk_fac_params_sane`. Every threshold is a POLICY choice, not a measurement; CS retunes with one UPDATE. The CHECK encodes coherence, not taste: `shrink_ratio < 1.0` and `expand_ratio > 1.0` (shrinking an above-median lane or expanding a below-median one is incoherent), `starvation_ratio >= 1.0` (the in-stock rate is ≥ the calendar rate by construction), `min_facings_to_shrink >= 2` (so a shrink can never take a family to zero lanes). |
| `20260731194721` | `prd110_p34_v_facing_performance_v3` | The revenue/facing/day report. See METRICS_REGISTRY for the full Article-16 reasoning. Read-only, `security_invoker`, REVOKEd from `anon`. **No consumer at apply.** 525 rows / 0 facing-count disagreements / 60 multi-facing families.                                                                                                                                                                                                                                                                              |

⛔ **STAGED, NOT APPLIED (leg 68):** the queue half of P3.4 — `facing_proposals_v3` (advisory table) and
`propose_facing_changes_v3` (SECURITY DEFINER writer) — is written, Cody-reviewed and perf-corrected at
**`docs/prds/staged-p34/`**, deliberately OUTSIDE `supabase/migrations/` so no migration tool or
owed-set counter mistakes an unapplied draft for owed work. ⛔ Per LAW 1 the proposer must NOT be
applied before golden fixture 48 exists.

## PRD-110 P3.4 — the queue half, applied (relay leg 69, 2026-07-31)

Leg 68's staged drafts are now LIVE and fixture-proven. ⛔ `docs/prds/staged-p34/` has been
**retired**, after proving both files byte-identical to their filed migrations — a staged directory
that outlives its apply is a landmine that invites a second application.

| Version          | Name                                           | What                                                                                                                                                                                                                                                                             |
| ---------------- | ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260731201548` | `prd110_p34_facing_proposals_v3_table`         | The advisory queue. Unchanged from the Cody-reviewed draft. RLS on, SELECT-only for `authenticated`, no write policy — the SECURITY DEFINER proposer is the only writer. Evidence columns are frozen AT PROPOSAL TIME by design (Article 14: a decision record, not a snapshot). |
| `20260731202119` | `prd110_p34_golden_fixture_48`                 | Fixture 48 + 52 assertions, applied BEFORE the proposer (LAW 1). RED baseline observed and recorded: **25 pass / 27 fail**, no aborts.                                                                                                                                           |
| `20260731202527` | `prd110_p34_propose_facing_changes_v3`         | The proposer. ⛔ **Not byte-identical to the leg-68 draft** — see the defect below. md5 `ad626601`.                                                                                                                                                                              |
| `20260731202632` | `prd110_p34_fixture48_seq44_acl_convention`    | Seq 44 re-expressed against the ratified fleet ACL convention.                                                                                                                                                                                                                   |
| `20260731203115` | `prd110_p34_fixture48_runtime_split_fixture49` | Fixture 48 trimmed to 3 view reads; dry-run/limit contract split into fixture **49**; seq 44 `expect` corrected.                                                                                                                                                                 |

### ⛔ The defect the dry-run caught, which reading the file could not

The staged proposer built its scratch tables with `CREATE TEMP TABLE _fac_perf ON COMMIT DROP`.
**`ON COMMIT DROP` drops at COMMIT, not at RETURN.** A second call inside the SAME transaction
therefore fails outright with `relation "_fac_perf" already exists` — and calling it twice in one
transaction is exactly what the idempotency contract (STEP 7 S4: re-run every engine 3x on one date)
and fixture 48 (three calls) both do. The fix is two `DROP TABLE IF EXISTS pg_temp.…` lines: the
scratch tables are rebuilt PER CALL. ⭐ This is why LAW 13 says dry-run the **BEHAVIOUR**, not the
DDL: the DDL-only dry run passed in 2 s.

### Evidence

- Fixture 48 **49/49 green**, fixture 49 **8/8 green**.
- Full P3 suite re-run and persisted: 39 `37/0` · 40 `56/0` · 41 `46/0` · 42 `67/0` (106 s) ·
  43 `55/0` (104 s) · 44 `30/0` · 45 `18/0` · 46 `27/0` · 47 `50/0` · 48 `49/0` (121 s) · 49 `8/0`
  (34 s) — **443 assertions, 0 fail**.
- Live batch at plan_date 2030-02-18: **23 proposals, 11 shrink / 12 expand, all `pending`**, matching
  an independently re-derived oracle **as a set**, not merely in count.
- LAW 5 accounting on that run: 525 families considered; 71 out-of-universe, 56 partner_managed,
  21 no price basis, 76 no in-stock rate, 71 thin peer group. Nothing silently dropped.
- 0 protected-entity writes: `machines_to_visit` 1240 and `v_blocked_demand_open` 20, both unmoved.

---

## PRD-110 P3.6 — EDITS AS EVENTS (leg 70, 2026-07-31)

| Version          | Name                                           | What                                                                                               |
| ---------------- | ---------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `20260731205322` | `prd110_p36_golden_fixture_50`                 | Fixture 50 + 46 assertions: the edits-as-events contract.                                          |
| `20260731205406` | `prd110_p36_fixture50_vacuous_green_hardening` | Three assertions that passed BEFORE their engine existed.                                          |
| `20260731210416` | `prd110_p36_plan_edits_events`                 | `plan_edits_v3` + `v_plan_edits_active_v3` + `record_plan_edit_v3` + `compose_plan_with_edits_v3`. |

BUILD-SPEC line 94. The overlay rule, stated once: **hard** = the human's number wins permanently for
that plan_date and no engine re-run can move it; **soft** = the human's number wins only while the
engine still believes what it believed WHEN THE EDIT WAS MADE, and if the base has moved since, the
newer information wins and the edit **yields** — counted and named, never silent. Neither lock may
DROP an edit: `applied + yielded = considered` is asserted inside the composer and RAISEs if violated.

### ⛔ S-105 (NEW) — A PARTIAL UNIQUE INDEX MAKES "INSERT THEN SUPERSEDE" IMPOSSIBLE

`ux_plan_edits_v3_active` permits one active row per `(plan_date, shelf_id, pod_product_id)`. The
writer's first form inserted the successor and _then_ retired the predecessor — so for the duration of
one statement, two rows were active, and every re-edit of a key died on
`duplicate key value violates unique constraint "ux_plan_edits_v3_active"`. The order is load-bearing:
**retire first, insert second**, which means `superseded_by` must point at a row that does not exist
yet. Hence the self-FK is `DEFERRABLE INITIALLY DEFERRED` — that clause is doing real work, and
removing it re-breaks the writer.

### ⛔ S-106 (NEW) — `golden.runs.detail` IS A jsonb **ARRAY**, so `detail->>'scenario_error'` IS ALWAYS NULL

`run_fixture` catches a scenario exception and appends `{'scenario_error': SQLERRM}` as an **element**
of the `'[]'::jsonb` array. Reading it as a top-level key returns NULL, which reads exactly like "the
scenario ran fine". It cost this leg four probes to distinguish "the DDL is invisible" from "the
scenario threw". ⭐ Always:
`SELECT e->>'scenario_error' FROM golden.runs r, jsonb_array_elements(r.detail) t(e) WHERE e ? 'scenario_error'`.

### ⛔ S-107 (NEW) — A THROWN SCENARIO LEAVES THE **PREVIOUS RUN'S** SCRATCH IN PLACE

The scenario opens with `DELETE FROM golden.scratch WHERE fixture_id = …`, so when it throws, its
savepoint rolls back and the **committed scratch from the previous run survives**. Assertions then
read _stale but plausible_ values — here, `'absent'` sentinels left by the RED baseline — and the
fixture looks like "the engine was never built" rather than "the scenario crashed". ⛔ On a suspicious
all-absent read, check the scenario_error array FIRST (S-106), and `DELETE` scratch in the probe.

### ⭐ S-108 (NEW) — THE TRUNCATE GAP THIS ADR HAS CARRIED SINCE P2.0 IS NOW CLOSED, ONCE

`ADR-shadow-plan-tables.md` note 2 records that TRUNCATE bypasses both RLS and every `FOR EACH ROW`
trigger, leaving "write-once, never updated" untrue for the shadow family. `plan_edits_v3` is the
first table in the family to carry a **statement-level** `BEFORE TRUNCATE` trigger, so its append-only
claim is complete rather than aspirational. ⛔ The sibling tables still do not have one.

### Evidence

- Fixture 50 **46/46 green**, committed. RED baseline before the engine was **2/46**, and the only two
  greens were the live-state tripwires that must stay green — a genuinely non-vacuous RED.
- The RED baseline initially read 5/46; **three assertions were passing because nothing existed**
  (seq 20 compared two NULLs, seq 23/33 asked whether a shelf was absent from an absent row-set).
  They now return a `no_compose` sentinel and can only go green on real composed output.
- **Every pre-existing engine object byte-unchanged** (md5 of `prosrc`): `stitch_v3` `a8753091` ·
  `engine_add_pod_v3` `a79bbe1f` · `resolve_supply_ladder_v3` `920b32d0` ·
  `record_blocked_demand_v3` `f950b17f` · `propose_facing_changes_v3` `ad626601`.
- 0 protected-entity writes, 0 rows deleted, 0 flags flipped, 0 crons changed.
  `machines_to_visit` **1240** and `v_blocked_demand_open` **20**, both provably unmoved.

---

## PRD-110 P3.7 — one pipeline (leg 71, 2026-07-31)

| version          | name                                           | what                                                                                                                |
| ---------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `20260731212608` | `prd110_p37_golden_fixture_51`                 | fixture 51, plan_date 2030-02-21. LAW 1: landed RED before the engine.                                              |
| `20260731212724` | `prd110_p37_fixture51_vacuous_green_hardening` | seq 26/28 gated on a pipeline having planned a run.                                                                 |
| `20260731212818` | `prd110_p37_fixture51_ne_sentinel_fix`         | ⛔ seq 42 used `ne` against a sentinel and went green with no engine at all.                                        |
| `20260731213324` | `prd110_p37_fixture51_seq36_correction`        | assertion was wrong, engine was right (found by the behaviour dry run).                                             |
| `20260731213328` | `prd110_p37_pipeline_runs_table`               | `pipeline_runs_v3` + append-only trigger + BEFORE TRUNCATE + standing-approval unique index + `v_pipeline_runs_v3`. |
| `20260731213331` | `prd110_p37_run_pipeline_and_approve`          | `run_pipeline_v3`, `approve_pipeline_run_v3`.                                                                       |

### The defect P3.7 closes, and how it was measured

Leg 70's pointer flagged the `compose → stitch` coupling as implicit and recorded it as "probably the
desired pipeline". ⛔ **It was worse than implicit — it was nondeterministic.** `stitch_v3` with a
NULL source resolves its input `ORDER BY produced_at DESC, run_id DESC`, and
`pod_refills_shadow.produced_at` DEFAULTs to `now()` — the **transaction** timestamp. A base run and
the run composed from it inside one transaction therefore **tie**, and the tie-break falls to uuid
ordering of `run_id`. Whether the human's overlay reached the stitched plan was a coin flip.

Fixture 51 forces the flip to its wrong face: the base run is minted with a `run_id` of the form
`ffffffff-ffff-4fff-bfff-…`, which sorts above every random v4 uuid. Measured in the fixture, with a
composed run present on the date, the implicit pick returns `engine_add_pod_v3` and
`implicit_equals_planned` is **false** — i.e. the pre-P3.7 path would have discarded every edit,
silently. `run_pipeline_v3` passes every run id explicitly and re-asserts afterwards that
`stitch.source_run_id` is the run it planned.

### Evidence

- Fixture 51 **53/53 green**. RED baseline **3/53**, and the only three greens are the live-state
  tripwires (LAW 4/11) that must stay green at every moment of the build.
- ⛔ The first RED read 5/53 and **two of those were weakly vacuous**; a third (seq 42) was vacuous
  in the opposite direction — **a sentinel defeats `eq` but FEEDS `ne`**. Rule earned: an assertion
  may use `ne`/`not_null` only when the sentinel itself would fail it.
- ⭐ The DDL dry run and the **behaviour** dry run (`BEGIN; migrations; run_fixture; RAISE with the
numbers; ROLLBACK;`) were run separately. The behaviour run is what found the seq-36 defect.
- **Every pre-existing engine object byte-unchanged** (md5 of `prosrc`): `stitch_v3` `a8753091` ·
  `engine_add_pod_v3` `a79bbe1f` · `resolve_supply_ladder_v3` `920b32d0` ·
  `record_blocked_demand_v3` `f950b17f` · `propose_facing_changes_v3` `ad626601` ·
  `record_plan_edit_v3` `b77f9e9a` · `compose_plan_with_edits_v3` `32d2a805` ·
  `tg_plan_edits_v3_append_only` `fb0520bc`.
- 0 protected-entity writes, 0 rows deleted, 0 flags flipped, **0 crons changed**.
  `machines_to_visit` **1240** and `v_blocked_demand_open` **20**, both provably unmoved.

## PRD-110 S-112 / S-113 — a deliberate skip is not an error (2026-07-31, relay leg 72)

| #   | version          | name                                      | what                                                                                                                                                                                                           |
| --- | ---------------- | ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `20260731215241` | `prd110_s112_s113_golden_fixture_53`      | Golden fixture 53 (plan_date **2030-02-23, itself a Saturday**) + 22 assertions. RED baseline **13/22**.                                                                                                       |
| 2   | `20260731220053` | `prd110_s112_runner_truthful_skip`        | `is_refill_planning_day_v3(date)` (new, read-only, INVOKER) · `shadow_runner_log_v3.status` CHECK widened `+skipped_calendar +no_picks` · `run_nightly_shadow_v3` reclassifies (md5 `969b1042` → `c0ddc8b5`).  |
| 3   | `20260731220057` | `prd110_s113_health_judges_scheduled_run` | `v_shadow_runner_health_v3` judged on the SCHEDULED run (9 incumbent cols kept in order, 6 appended) · cron 45 **command only** tagged `p_note => 'cron'` · fixture 37 seq 17/18 re-pointed to `log_is_alive`. |

**Fixture 53 22/22 green** (from 13/22). Fixture 37 re-run for regression after the re-point.

### ⛔ THE POINTER'S PROPOSED FIX WAS REFUTED BY MEASUREMENT — AND NOT APPLIED

Leg 71 handed over `cron.alter_job(45, schedule => '45 16 * * *')` as a "verified candidate",
on the premise that job 45 "asks for a plan date Stage 1 has not prepared, every single night,
forever". Probed live before acting (LAW 13), that premise is **false**:

- `resolve_refill_plan_date()` flips at **18:00 Dubai**, not at midnight.
- cron 13 @ `16:00Z` = 20:00 Dubai → resolves **D+1**. cron 45 @ `21:22Z` = 01:22 Dubai → resolves
  **that same D+1**. Both returned `2026-08-01` on 07-31. ⭐ **The two crons already agree.**
- The real reason 2026-08-01 had no picks: **it is a Saturday**, and PRD-035 WS-E makes Saturday a
  delivery day. `build_draft_for_confirmed_v3('2026-08-01')` returns `status='skipped_saturday'`
  and writes nothing, deliberately. Every Saturday in the window — 07-11, 07-18, 07-25, 08-01 —
  has exactly **0** picked/cs_added machines.
- ⛔ Applying the proposed reschedule would have been **actively harmful**: 16:45Z is 45 min after
  Stage 1, i.e. **before** the overnight human `cs_added`/`cs_dropped` edits. Pick timestamps show
  Stage 1 seeding at 20:00 Dubai and humans editing until ~06:00. The current 01:22 Dubai slot
  captures them; 20:45 Dubai would not.

⭐ **The schedule was correct all along. The defect was the WORD in the log**, and that is what
this unit fixed. `22 21 * * *` stands, and migration 3 RAISEs if it ever moved during apply.

### 📌 Article 16 debt opened deliberately (D-35)

`_build_draft_core_v3` still carries `EXTRACT(DOW)=6` inline. Named in `METRICS_REGISTRY.md` as the
known illegal copy to retire; collapsing it means editing the live Stage 1 engine, which LAW 12
puts outside this unit.

- 0 protected-entity writes, 0 rows deleted, 0 flags flipped. **0 cron SCHEDULES changed** (one
  cron _command_ changed, asserted schedule-identical). `machines_to_visit` **1240** and
  `v_blocked_demand_open` **20**, both provably unmoved.

## PRD-110 leg 73 (2026-07-31) — P3.6 `swap_v3`

| version          | name                                            | what                                                                                                                                                         |
| ---------------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `20260731222111` | `prd110_p36_golden_fixture_54_swap_v3`          | Golden fixture 54 (plan_date 2030-02-24), RED baseline 9/30 for the one-verb swap.                                                                           |
| `20260731222503` | `prd110_p36_swap_v3_one_verb`                   | NEW SECURITY DEFINER `swap_v3` — two hard-locked legs via `record_plan_edit_v3` (Article 1: not a second writer). Cody ⚠️ approve-with-revisions; see D-36.  |
| `20260731222506` | `prd110_p36_fixture54_cross_machine_correction` | Fixture 54 correction: the cross-machine case re-anchored after the duplicate guard proved case 4e was itself wrong. Adds seq 6 and seq 35. Fixture → 32/32. |

⚠️ Apply-time version drift on all three; each filed to disk at its REGISTERED version, owed set NONE.

## PRD-110 leg 74 (2026-07-31) — S-116 fixture 50 re-runnability

| version          | name                                   | what                                                                                                                                                                                                                                                                                                                                     |
| ---------------- | -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260731223857` | `prd110_p37_s116_fixture50_rerunnable` | Golden fixture 50 made re-runnable: a run-scoped baseline is captured BEFORE the first edit, so seq 17/42 measure what THIS run appended. `expect` stays `eq 2` / `eq 5` — nothing weakened to `gte`. Adds seq 47/48/49. Fixture 49/49 on three consecutive separate-transaction runs. Cody ✅ fast-path (class f, golden harness only). |

⚠️ Apply-time version drift; filed to disk at its REGISTERED version, owed set NONE.
⛔ The pointer's proposed remedy (DELETE the fixture's own `plan_edits_v3` rows in arrange) was
proven IMPOSSIBLE, not merely undesirable: `plan_edits_v3` carries `tg_plan_edits_v3_append_only`
plus `tg_plan_edits_v3_no_truncate`, and section (7) of that very scenario ASSERTS the DELETE is
REFUSED. ⭐ **S-108 is therefore CONFIRMED, not falsified** — the guard is the CAUSE of the
non-re-runnability. Seq 48 now pins the guard so the point cannot be lost again.

## PRD-110 leg 75 (2026-08-01) - PHASE 3 GATE, golden fixture 6

| version          | name                                              | what                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ---------------- | ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260731230055` | `prd110_p3gate_golden_fixture_6_stranded_reroute` | Golden fixture 6 "Stranded stock reroute" (Pepsi Black), 51 assertions, **51/51 on two separate-transaction runs**, ~5.6 s. Proves the rung-3 `alt_wh` scope of `resolve_fefo_sku_legs_v3` positively for the first time (binds a real WH_CENTRAL batch, 6/6 units, 0 unbound, 0 primary-WH, 0 sentinel) and RECORDS **S-118**: rung 2 is an absorbing state, so the stranded units are seen and never spent. **No engine touched** - both engine md5 pinned by seq 50/51. Cody fast-path (class f, golden harness only; zero DDL, zero protected entity). |

⚠️ Apply-time version drift; filed to disk at its REGISTERED version `20260731230055`, owed set NONE.
⛔ This fixture is **green at baseline on purpose** (`baseline_status='passing'`) and that is not a
LAW 1 shortcut: it drives no engine change. It proves machinery that already existed but had never
been exercised positively, and it RECORDS an open incident rather than closing one. Seq 22/25/26 are
the open-incident record. The LAW 1 driver for changing the rung order is a FUTURE fixture behind D-37.

## PRD-110 leg 76 (2026-08-01) - PHASE 3 GATE, golden fixture 12 + the guardrail registry

| version          | name                                         | what                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ---------------- | -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260731231836` | `prd110_p31a_fixture_12_guardrail_products`  | Golden fixture 12 "Guardrail products never swap in", 26 assertions. Landed FIRST and RED at **19 pass / 7 fail** (reds 10, 11, 14, 20, 21, 22, 23) per LAW 1. Golden harness only, zero DDL, zero protected entity. Cody fast-path (class f).                                                                                                                                                                                                             |
| `20260731232246` | `prd110_p31a_assortment_guardrails_registry` | NEW additive table `public.assortment_guardrails` (RLS on, select-open, writes gated to operator_admin/superadmin, mirrors `rpp_write`), seeded BY NAME with one row (Evian - 1L). Plus `find_substitutes_for_shelf_v3` CREATE OR REPLACE via a **named substitution on `pg_get_functiondef`** adding one `NOT EXISTS` against the registry. md5 `ca7c52f9` -> `6aa6885e`. Cody ⚠️ approve-with-revisions (Articles 2/12/14/16); the revision was applied. |
| `20260731232443` | `prd110_p31a_restate_fixture40_selector_pin` | Fixture 40 seq 34 md5 pin RESTATED (not deleted, not weakened): `ca7c52f9...` -> `6aa6885e...`, `check_sql` and `eq` operator untouched, description now carries the provenance of the move. Guarded: aborts unless the live md5 and the old baseline are both exactly what the file was written for.                                                                                                                                                      |

⚠️ Apply-time version drift on all three; each filed to disk at its REGISTERED version, owed set NONE.

⛔ **THE RED WAS A DISAGREEMENT BETWEEN TWO ENGINES, NOT A THEORY.** On three real
(machine, shelf, anchor) triples - MC-2004-0100-O1, NISSAN-0804-0000-L0, VOXMCC-1005-0201-B0 - at
the same date, `find_substitutes_for_shelf_v3` returned Evian - 1L at **RANK 1** as
`in_category_performer` while `rank_slot_suitability` returned it **ZERO** times (0 of 13 / 7 / 35).
The PRD-106b2 guardrail existed only as a literal uuid inside one engine. Fleet-wide the selector
offered it as rank 1 on **8 distinct live machines**.

⭐ **Cody's revision, applied before apply:** `replace()` substitutes EVERY occurrence, and the
migration only asserted the anchor appeared _at least_ once. Two anchors would have shipped two
guardrail clauses and a malformed body while the post-condition grep still passed. The `$fix$` block
now demands the anchor appear **exactly once**.

⛔ **SCOPE, stated so a later leg does not over-correct:** the guardrail blocks INTRODUCTION only.
The 6 shelves that legitimately carry Evian - 1L are untouched, because the substitute candidate set
already excludes anything present on the machine. Fixture 12 seq 8 pins this.

⭐ **Regression sweep after the engine change, every fixture that consumes the substitute path,
run INDIVIDUALLY:** 39 **37/37** · 40 **56/56** · 44 **30/30** · 45 **18/18** · 6 **51/51** ·
47 **50/50** · 51 **53/53** · 12 **26/26**. Fixture 39's ELIGIBILITY PARITY assertion (seq 28) was
pre-analysed as the risk and survived: Evian is not in that machine's universe (probed v1=0, v3=0
before touching anything).

---

## `20260731234420` prd110_p38_fixture_11_mid_plan_machine_drop_red · `20260731234438` prd110_p38_freed_allocation_reoffer

**PRD-110 leg 77 · Phase 3 gate · fixture 11 "Mid-plan machine drop" (AMZ drop 07-30, the VW 6u case).**

⭐ **LAW 1 honoured with recorded evidence.** `20260731234420` installed fixture 11 (39 assertions)
and it was RUN AND RECORDED RED in `golden.runs` - **22 pass / 17 fail**, note
`leg 77 LAW-1 BASELINE: fixture 11 recorded RED before any fix exists` - **before a line of the fix
was applied**. `20260731234438` then closed it: **39/39 green**.

⛔ **THE DEFECT, found by probing rather than by reading.** `compose_plan_with_edits_v3` handles a
`drop` by setting the effective qty to 0 and simply **not inserting the line**. The warehouse units
that line had already claimed stop being claimed with **no record anywhere that they came back**.
There was no re-allocation verb in the database at all - `propose_*` covered facings, rotations,
decommission, rebalance, dissolution and pod-inventory adds, and **nothing covered freed allocation**.
On 2026-07-30 two AMZ machines were dropped post-draft while VML-1004 A05 sat `blocked_no_wh` on the
very product AMZ-1029 A06 had just released.

⭐ **Purely ADDITIVE (LAW 3): no existing engine was touched.** All 15 engine md5s re-probed
byte-identical after apply, so **no `golden.assertions` md5 pin moved and S-122 never fired**.

**What shipped:** `reallocation_proposals_v3` (new CS-gated queue, RLS on, SELECT-only to
`authenticated`, no anon grant - byte-for-byte the `rotation_proposals_v3` / `facing_proposals_v3`
convention) + `propose_reallocations_v3(date,uuid,uuid,boolean)`.

⛔ **Article 14 does NOT bite:** the table holds proposal STATE (`status`, `reviewed_by`,
`review_note`) that no view can derive. Same class as the two sibling proposal queues. No ADR needed,
and none was written.

⭐ **Cody: ⚠️ approve-with-revisions. All three revisions were real and were applied BEFORE apply:**

1. `ON COMMIT DROP` is not `ON RETURN DROP` (S-101). A call that raised after creating the temp
   tables would leave them for the rest of the transaction and the **next call in that same
   transaction would die on "relation already exists"** - and the fixture calls the verb twice
   (dry then live). Now dropped on the way IN, not only on the way out.
2. `ON CONFLICT DO NOTHING` paired with a blind `v_written + 1` **reports writes it never made** on a
   re-run. Now counts `GET DIAGNOSTICS ROW_COUNT`.
3. ⛔ **The important one.** The accounting guard compared `(matched + unclaimed)` against the freed
   LINE count - but a **PAIR count is not a SOURCE count**. One source split across two claimants
   scored 2 and could mask a source represented nowhere, which is precisely the LAW-5 failure the
   function exists to prevent. Now counts DISTINCT `(source_shelf, pod)` actually represented.

⛔ **The boundary that keeps this from becoming a rebalancer, asserted at fixture 11 seq 24:** being
merely under-full is NOT a claim. Only an explicit `blocked_no_wh` / `partial_wh_limited` clamp is.
The control shelf AMZ-1046 A09 carries a freed product, is not clamped, and is never offered it.

⭐ **Regression, each fixture in its own transaction:** 50 **49/49** · 51 **53/53** (the compose and
pipeline neighbours). `machines_to_visit` **1240** and `v_blocked_demand_open` **20** provably
unmoved; `refill_plan_output` on the 2030 fixture date **0** (LAW 4/12). 0 protected-entity writes,
0 rows deleted, 0 flags flipped, 0 cron schedules changed.

---

## `20260801002517_prd110_p3_golden_fixture_1_0730_replay.sql` (leg 78)

**GOLDEN FIXTURE 1 - the 07-30 nine-edit full replay. The last Phase 3 gate item.**
Purely additive to the `golden` schema: one `golden.fixtures` row + **59 assertions**. No public
DDL, no function, no RLS, no protected-entity write. **All fifteen engine md5s byte-unchanged.**

The fixture is deliberately in **two halves**, because the incident and the mechanism are two
different claims and conflating them would prove neither:

- **Half A - the incident itself, READ ONLY** over live `refill_plan_output` on 2026-07-30:
  71 lines, ⭐ **64 dispatched (the gate number)**, 7 machines, **0 silent qty-0**, every line
  operator-approved, the **K&Z REMOVE on 1013 A04 present AND dispatched (resolved)**, the A04
  ADD_NEW 8 Tamreem units, and the three CS numbers reproduced to the unit (1054 Nutella **3**,
  VW A05 **6**, Zigi **7**). ⭐ **The coconut stop is asserted as an ABSENCE** (S-114): zero
  coconut lines survived anywhere in the session.
- **Half B - the mechanism** on synthetic **2030-01-02**: a supplied base run over 6 machines,
  **9 edits through `record_plan_edit_v3`**, `run_pipeline_v3` -> compose -> stitch ->
  `approve_pipeline_run_v3`, then a **second pipeline run over a MOVED engine base**.

⛔ **The v3 shadow vocabulary has NO `Remove` action** (`refill_plan_output_shadow.action` is
Refill / Add New / Blocked). The live A04 REMOVE is asserted as historical truth in half A; its v3
analogue in half B is a `drop` edit. **The two are asserted separately and are NOT conflated.**

⭐ **The assertion that earns the fixture its keep is seq 63:** the re-run proves the hard edits
held (9 and 7) **while the UNLOCKED control line correctly FOLLOWED the engine 7 -> 9**. An engine
frozen wholesale would be exactly as wrong as one that trampled the human, and only the control
catches that.

⭐ **FALSIFICATION PROBE, run before the fixture was trusted.** A fixture that passes on its first
landing is worthless until it is shown it can fail. Mutating one edit qty (7 -> 8) produced exactly
**5 targeted reds** - the composed value, the stitched value, the survived-re-run value, and both
unit totals. The 59/59 is non-vacuous.

**Cody: ⚠️ approve-with-revisions, both applied before apply.** (1) seq 83 originally pinned live
`machines_to_visit` to the literal **1240**, coupling a P3 gate fixture to ambient fleet state - the
day CS onboards a machine it would go red for a reason unrelated to the incident. Now a **start-vs-end
invariance** tripwire with a baseline captured in half A. (2) An **Article 16 note** recorded in the
fixture's `notes`: half A counts dispatched-vs-planned inline, adjacent to `v_refill_accuracy`. That
is deliberate and is NOT an illegal copy - ⛔ **a test oracle that read the canonical object would be
asserting that object against itself. Do not "fix" it by rewiring it to `v_refill_accuracy`.**

**Evidence:** fixture 1 **59/59 live** (4.6 s). Regression: **12 26/26 · 50 49/49 · 51 53/53**.
Tripwires: the incident date still holds its **71 rows** (read, never written), `refill_plan_output`
on 2030-01-02 **0**, `machines_to_visit` **1240**, `v_blocked_demand_open` **20** - all unmoved.

---

## `20260801003401_prd110_s117_fixture_11_rerunnable_scope_fix.sql` (leg 78)

**S-117 CLEARED FOR FIXTURE 11 - and leg 77's hypothesis falsified by test.**

Leg 77 hoped `ux_realloc_v3_pair` would make a second run of fixture 11 idempotent, flagging it
UNTESTED. Re-running it as a routine regression check returned **31/39**. ⭐ **The index cannot
dedup, for the OPPOSITE reason to the one guessed: the `composed_run_id` is FRESH on every run, so
the pair never collides and every run APPENDS a complete second set of proposals.** Two identical
4-row batches were observed (23:44Z leg 77, 00:26Z leg 78) with the exact doubling signature -
seq 18 got 2 want 1, seq 22 got 6 want 3, seq 35 got 4 want 0.

⛔ **PROVEN not to be a fixture 1 regression BEFORE the fix was written:** fixture 1's `scenario_sql`
references neither `reallocation_proposals_v3` nor 2030-01-12, and the two batches are timestamped
either side of this leg's start.

⭐ **The fix is a SCOPE TIGHTENING IN THE SCENARIO, not an assertion edit.** Both reads asked
"what is on this plan_date"; they now ask "what did THIS run produce", via the `composed_run_id`
the scenario already held. **All 39 assertion rows are byte-identical** - no expect value weakened,
no op loosened, nothing deleted (S-103 / S-122 discipline). The assertions became MORE precise.
⛔ A `replace()` that matches nothing is a **silent no-op**, so the migration ends in a guard DO
block that RAISEs unless both substitutions landed.

**Evidence:** **39/39 on three consecutive runs, each in its OWN transaction** (S-117: re-runnability
cannot be tested inside one). The queue still legitimately appends (20 rows / 5 batches) - it is an
append-only proposal ledger; what changed is that the fixture now measures its own run.

---

## PRD-110 P4.1 + P4.2 (2026-08-01, relay leg 79) - the feedback loop's three tables

| Version          | Name                                         | What                                                                                            |
| ---------------- | -------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `20260801005744` | `prd110_p4_1_feedback_ledger_pins`           | `feedback_ledger_v3`, `feedback_proposals_v3`, `planning_pins_v3` + `v_planning_pins_active_v3` |
| `20260801010210` | `prd110_p4_golden_fixture_55_pin_invariants` | Golden fixture 55, 26 assertions - the proof (LAW 1)                                            |
| `20260801010307` | `prd110_p4_advance_golden_phase_p4`          | `golden.config.current_phase` P3 → P4 after the P3 gate was declared                            |

**Design:** `docs/prds/PRD-110-P4-DARA-feedback-pins-design.md` (Dara, 6-section proposal).
**Review:** Cody ⚠️ approve-with-revisions. **All five revisions were applied before apply**, and two
of them were substantive rather than stylistic:

1. ⛔ **`array_length()` → `cardinality()`.** The provenance invariant ("a proposal with no evidence
   is not a proposal") was **inert as designed**: `array_length('{}',1)` returns **NULL**, and a
   CHECK constraint that evaluates to NULL **PASSES**. Both `chk_fpr_v3_evidence` and
   `chk_pin_v3_provenance` were affected. ⭐ **Proven, not argued** - the falsification run below
   restores the original form and the evidence-free rows are ACCEPTED.
2. ⛔ **The uniqueness index would have tombstoned its own slot.** `ux_pin_v3_active_one_per_kind` is
   partial on `revoked_at IS NULL`, but an **expired** pin is not revoked, so a lapsed `until`-mode
   pin would occupy its slot forever and could never be renewed. The predicate cannot be widened:
   index predicates must be IMMUTABLE and `now()` is not. Resolved by materialising expiry as a
   revocation with a **system actor** (`revoke_reason='expired_system'`, `revoked_by IS NULL`), which
   `chk_pin_v3_revoke` admits as its own branch. Fixture 55 seq 9 walks retire-then-re-mint.
3. View given `security_invoker = true` (ADR §7) so it cannot become an RLS bypass.
4. `anon`/`PUBLIC`/`authenticated` **REVOKED** on all four objects including the view, then
   `GRANT SELECT` - ⛔ **in that order, because a GRANT is additive and cannot narrow** (ADR §11.2).
   The migration **reads the privilege state back naming `authenticated`**, not `anon` (§11.3:
   fixtures 36/37 once passed vacuously by checking the role that correctly held nothing).
5. `'superseded'` exempted from the reviewer check - supersede is a system action with no human.

⭐ **Article 14: NO ADR, and that is the considered answer, not an omission.** These hold state no
view can derive (an append-only ledger, a review queue, standing constraints) - the same class as
`rotation_proposals_v3` / `facing_proposals_v3` / `reallocation_proposals_v3`, none of which required
one. The corrected Article 14 test is **silent staleness**, not table count (PRD-110 S-03). Dara's own
handoff checklist asked for an ADR; that was the OLD misreading and was overruled at review.

**Evidence:** fixture 55 **26/26 live, twice, each in its own transaction** (53 ms, 32 ms).
⭐ **Falsified before it was trusted:** reverting `cardinality()` to `array_length()` produced
**exactly 2 targeted reds - seq 1 and seq 2, both `got=ACCEPTED`** - which simultaneously proves the
fixture bites and that Cody's finding was a live defect, not a style note.
⭐ **S-117 designed in, not discovered:** every row the fixture writes carries a **deterministic
uuid**, so its cleanup is exact and a re-run is a no-op. Row counts held at 5 pins / 2 feedback /
1 proposal across both runs. **0 protected-entity writes; RPC_REGISTRY unchanged by design (no RPC
was added - the writers land with P4.1's verbs).**

---

## `20260801011835_prd110_p41_golden_fixture_56_verb_contract` + `20260801012431_prd110_p41_feedback_verbs` — PRD-110 P4.1, the writers (2026-08-01 leg 80)

Leg 79 landed `feedback_ledger_v3` / `feedback_proposals_v3` / `planning_pins_v3` with `authenticated`
holding SELECT only and **no writers**, so the tables were inert — only `postgres`/`service_role`
could put a row in them. These two migrations are that unit's other half: the fixture, then the three
`SECURITY DEFINER` verbs it proves. See `RPC_REGISTRY.md` for each verb.

⭐ **LAW 1 observed literally, and the red is the point.** The fixture landed **first** and ran
**4 pass / 37 fail** against functions that did not exist. It then ran **40/40** with the verbs in
place, and **40/40 again on a second run in its own transaction** (59 ms, 58 ms). A fixture that is
green before its subject is built is proving nothing; this one could not have been.

⭐ **FALSIFIED ON ITS SUBTLEST CLAIM, not just on the easy ones.** Removing the two `set_config`
lines that restore `app.rpc_name` after the driver wrap produced **exactly one red — seq 24,
`got=driver_propose_adjustment`.** One targeted red is what separates a real proof from a green run.

⭐ **S-117 built in, not discovered.** The verbs mint their own uuids, so rows are reclaimed by
**marker** (`FX56%` in `note` / `trigger_reason`) rather than by id. Row counts held exactly across
both runs: ledger **9** (2 from fixture 55 + 7), proposals **5** (1 + 4), pins **7** (5 + 2).

⛔ **AND THE DRIVER PROBE IS ROLLED BACK ON PURPOSE.** The wrap writes into
`driver_recommendations`, `driver_feedback` and `refill_edit_signals` — tables this fixture has no
business deleting from. So it runs in a subtransaction that ends in a deliberate `RAISE`, capturing
what it observed in plpgsql variables (which survive the rollback) and writing them to
`golden.scratch` afterwards. **Rerunnability without a single delete outside our own three tables.**

**Cody: ⚠️ approve with revisions.** Articles 1, 3, 4, 5, 6, 12, 13 clean.
Article 1 verified **live** by a `prosrc` sweep — no other function in `public` writes any of the
three tables. The revision was Article 16: the approve verb reads the base table rather than the
canonical view, which is **correct and must stay** — carve-out now recorded in `METRICS_REGISTRY.md`.

⚠️ **Article 8, fleet-level gap logged (S-127):** none of the three tables carries the generic
write-audit trigger. **Not a regression** — `rotation_proposals_v3`, `facing_proposals_v3` and
`reallocation_proposals_v3` do not carry it either. The verbs stamp `app.via_rpc` + `app.rpc_name`
correctly, so the trigger would work the day it is installed. Parked, not fixed here.

**0 protected-entity writes · 0 rows deleted outside the three v3 tables · 0 flags flipped · 0 cron
schedules changed · 0 engine functions touched (all sixteen md5s byte-unchanged).**

## `20260801022432_prd110_p42_engine_pin_consumption` (PRD-110 P4.2, relay leg 82)

`CREATE OR REPLACE engine_add_pod_v3` — the P4.2 consumer. Pins become constraints the engine obeys.
Full behavioural detail in `RPC_REGISTRY.md` (Amendment 2026-08-01). md5 `a79bbe1f` → `e9f3caff`.

Built by deterministic substitution over `pg_get_functiondef()` rather than by transcribing 592
lines: four anchors, each asserted to match **exactly once**, plus a generated-source check that the
result reads the canonical view and matches no `(FROM|JOIN)\s+(public\.)?planning_pins_v3`. The
migration ends in a guard `DO` block that REFUSES to record itself as applied unless all six markers
are present in the live `prosrc`.

**Cody: ✅ approve.** Articles 1, 2, 3, 4, 6, 12, 14, 16 clean. **Article 1 verified LIVE** — a
`prosrc` sweep for writers of `pod_refills_shadow` returns exactly `engine_add_pod_v3` and
`compose_plan_with_edits_v3`, both pre-existing; this unit adds no writer. Article 16 clean: the
engine reads the canonical `v_planning_pins_active_v3`, which is the correct side of leg 80's
carve-out (a _guard_ reads the base table to match its index predicate; a _consumer_ reads the view).
⚠️ Article 7/8: `pod_refills_shadow` carries `tg_pod_refills_shadow_append_only`, not the generic
audit trigger — same family as S-127, not a regression.

**0 protected-entity writes · 0 flags flipped · 0 cron schedules changed · 0 rows deleted ·
`stitch_v3` and the other fifteen engine md5s byte-unchanged.**

## `20260801024319_prd110_s128_fixture56_never_stock_guard_proof` (PRD-110 S-128, relay leg 83)

**The proof, shipped BEFORE the thing it proves (LAW 1).** Extends fixture 56 — the P4.1
verb-contract fixture whose subject is "every gate refuses by its own named rule" — with the gate
S-128 calls for. Touches nothing outside the `golden` schema.

⛔ **The 15.7k-character scenario is edited by SUBSTITUTION over the live definition, never
re-transcribed.** Three anchors, each asserting its own occurrence count (2 / 1 / 1), plus
post-conditions on the generated source; a missed match ABORTS rather than silently no-op'ing.

Changes: probe (j)'s scratch key `neg_contra` → `neg_ns_parked` (it has always been the `never_stock`
approval probe; only the rule that refuses it changed) · new probe (l), the **legal exit**, run in a
rolled-back subtransaction so `pr3` stays `pending` for seq 36 · seq 35 re-stated (**S-103**:
description + `check_sql` + `expect` together) · seqs 41–45 added, all carrying `phase_required='P4'`
**explicitly** (the column defaults to `'P0'`).

⭐ **New probe key deliberately does NOT start with `neg`**, because seq 39 counts `key LIKE 'neg%'`
and expects exactly 11. A twelfth refusal probe would have reddened an anti-vacuity assertion that
has nothing to do with this change.

**RED baseline recorded in `golden.runs`: 42 pass / 3 fail (seqs 35, 41, 44)** against the verb as it
stood — i.e. the three assertions that describe a guard which did not yet exist. Seqs 42/43/45 green
from the start by design (a standing tripwire, a regression guard, an anti-vacuity count).

## `20260801024503_prd110_s128b_never_stock_approval_guard` (PRD-110 S-128 option (b), relay leg 83)

`CREATE OR REPLACE approve_feedback_proposal_v3` — refuses `pin_kind='never_stock'` until the P4.2
ceiling branch ships. md5 `e4bf1bb3` → **`0be4d718`**. Full behavioural detail and the **removal
contract** in `RPC_REGISTRY.md` (Amendment 2026-08-01, S-128).

Generated by substitution over `pg_get_functiondef()` with a **single-overload assertion** (editing an
arbitrary overload while the live one goes untouched is a silent no-op), two pre-conditions (not
already applied; the contradiction guard present, so this is the definition the edit targets), an
exactly-once anchor match, and three post-checks on the generated source **before** `EXECUTE` —
including that the guard precedes the contradiction guard and that it follows the reject branch.
⛔ `pg_get_functiondef()` returns **no trailing semicolon**.

⭐ **BOTH PLACEMENT DECISIONS WERE FALSIFIED, NOT ARGUED.** Guard hoisted below the contradiction
guard → exactly 3 reds (35/41/44). Guard hoisted above the reject branch → exactly 1 red (43). Each
falsification reddened precisely the assertion written for it, and nothing else.

**Cody: ✅ approve, no revisions.** Articles 1, 2, 3, 4, 6, 7, 8, 12, 13, 14, 16 checked.
**Article 1 verified LIVE** — a `prosrc` sweep returns `approve_feedback_proposal_v3` as the sole
INSERT path into `planning_pins_v3` (`propose_pin_from_feedback_v3` only reads it for the uniqueness
slot, per leg 80's carve-out), so the guard is a **complete** chokepoint; fleet-wide `never_stock`
count 0 confirms it is also non-retroactive. Article 4 clean and the placement is what preserves it:
`app.via_rpc`/`app.rpc_name`, the role gate, the decision-domain check, the note check and the
`FOR UPDATE` lock all precede the guard. Article 16 not engaged — the guard reads `pr.pin_kind` off
the already-locked proposal row and touches neither the base table nor the view.
⚠️ Article 7/8: `planning_pins_v3` still lacks the generic audit trigger (**S-127** family, not
widened here — a refusal writes nothing).

⚠️ **Logged as S-131: the contradiction guard is now a DEAD BRANCH in both directions. Do not delete
it** — it is suspended, not dead, and returns to load-bearing when the ceiling branch ships.

**Fixture 56 GREEN 45/45 · regression 55 26/26, 16 31/31, 17 25/25 all re-run live · 0
protected-entity writes · 0 flags flipped · 0 cron schedules changed · 0 rows deleted ·
`engine_add_pod_v3` `e9f3caff` and `stitch_v3` `a8753091` byte-unchanged · `feedback_ledger_v3` 9 /
`feedback_proposals_v3` 5 / `planning_pins_v3` 7 all UNMOVED.**

## `20260801025345_prd110_s129_fixture8_mislabel_full_to_cap_exemption` (PRD-110 S-129, relay leg 83)

Golden-harness only. Adds `AND fill_to_cap > 0` to fixture 8's `mislabelled_full` tripwire (one
anchor, asserted to match exactly once, with a double-apply refusal) and re-states seq 27's
description. **Fixture 8: 17/2 → 18/1.**

The tripwire counted `clamp_reason='skipped_full' AND ceil_u < cover_units` as a mislabel. ⛔ When
`fill_to_cap = 0` the shelf is **genuinely full**: `need_raw` and `need_raw_no_expiry` are both 0, the
expiry branch correctly never fires, and `skipped_full` is the _more_ accurate of the two labels —
no clamp class is being hidden from procurement because nothing was clamped.

⭐ **Verified live against run `bb049152` (32 lines) BEFORE the migration was written**, not taken
from the parking lot on trust: the tripwire fired on exactly **one** row (`cap=0 ceil=0 need=0
cover=1 floor=0`) and the exemption takes it to **0**. Exactly sufficient, no wider than needed.

⛔ **S-129 IS NOT CLOSED — fixture 8 remains RED at 18/1.** seq 29 (`floor_protected = 0`) is a
**TRUE** red and is now the sole one, which is the point: the real signal no longer sits next to a
false positive. See **S-132** — the same probe revealed the CORE assertion is passing vacuously.

**0 protected-entity writes · 0 flags flipped · 0 cron schedules changed · 0 rows deleted · all
sixteen engine md5s byte-unchanged (`e9f3caff` / `a8753091`).**

---

## PRD-110 P4.3a (2026-08-01, relay leg 85) — the WS-H2 edit-history miner + fixture 57

Eight migrations. **0 protected-entity writes · 0 flags flipped · 0 cron schedules changed · all
sixteen engine md5s byte-unchanged (`e9f3caff` / `a8753091`) · `mine_edit_history_v3` = `a9db274c`.**

| version          | name                                                     | what                                                     |
| ---------------- | -------------------------------------------------------- | -------------------------------------------------------- |
| `20260801031252` | `prd110_p43_edit_history_miner`                          | the miner RPC                                            |
| `20260801031319` | `prd110_p43_edit_history_miner_acl`                      | REVOKE EXECUTE FROM anon (S-104 fleet convention)        |
| `20260801031945` | `prd110_p43_fixture_57_edit_history_miner`               | fixture 57, 39 assertions                                |
| `20260801032109` | `prd110_p43_fixture_57_superseded_by_fk_fix`             | `superseded_by` is a FK to an EDIT, not a user           |
| `20260801032219` | `prd110_p43_fixture_57_reclaim_by_marker`                | reclaim by marker, not by shared machine anchor          |
| `20260801032303` | `prd110_p43_fixture_57_seq21_run_independent`            | seq 21 was counting runs, not proving anything           |
| `20260801032412` | `prd110_p43_fixture_57_strand_cleanup_and_anchor_follow` | remove 3+3 stranded rows; reclaim follows an anchor move |
| `20260801032515` | `prd110_p43_fixture_57_temp_table_rerun_guard`           | S-101 inside the fixture's own scenario                  |

**Calibration is the headline, and it was measured before a line was written.** The charter's own
figures — 4 weeks of history, 3 occurrences — yield **ZERO** proposals on live data (machines are
visited roughly weekly, so 28 days offers at most ~4 plan dates per machine). At **90 days / 2
occasions** the miner produces **9**, clearing the charter's "≥5 sensible proposals" bar. Those are
the shipped defaults, and the 28/3 result is pinned in fixture 57's sibling probe so the choice stays
auditable rather than folkloric.

**⛔ THE INCIDENT, RECORDED IN FULL.** Fixture 57's first committed run reclaimed by MACHINE
(`DELETE ... WHERE machine_id = mA`). Its anchor collided with the machine fixtures 55/56 anchor on,
and it deleted their rows: ledger 9 → 4, proposals 5 → 3, **pins 7 → 0** — the three counters the
resume pointer flags as "UNMOVED and they MUST stay so". Re-running fixtures 55 (26/26) and 56
(45/45) restored every row, because both are reclaim-and-recreate by marker and therefore
self-healing. Final counters: **ledger 12, proposals 8, pins 7** — baseline plus fixture 57's
intended, stable +3/+3 footprint, verified across four consecutive runs. ⭐ **The rule this cost:
a fixture reclaims by ITS OWN MARKER, never by a shared anchor. A machine is shared state.**

**Cody:** ⚠️ approve-with-revisions. Article 16 caught the `already_pinned` guard reading the base
table `planning_pins_v3` and re-deriving `revoked_at IS NULL AND (expires_at IS NULL OR expires_at >
now())` inline — verbatim the registered metric _"is a planning pin currently in force?"_. The leg-80
carve-out is an allow-list of exactly two verbs, both asking the different _"which row occupies the
uniqueness slot?"_ question. Revised to read `v_planning_pins_active_v3` before apply; fixture 57
seq 36 is the standing guard that it never regresses.

---

## PRD-110 P4.3b — pick-learning (WS-H4) schema half (relay leg 86, 2026-08-01)

| version          | name                                     | what                                                                                                                                                                        |
| ---------------- | ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260801034400` | `prd110_p43b_pick_learning_schema`       | `picker_feature_param_map_v3` (feature→dial semantics) + `picker_weight_proposals_v3` (advisory queue) + RLS/ACL + 11 seed rows + 7 `pl_*` params on `refill_policy_params` |
| `20260801034408` | `prd110_p43b_v_pick_decision_cohorts_v3` | the Article 16 registered metric classifying WHY CS's selection differs from the cron pick                                                                                  |

⭐ **CALIBRATED BEFORE A LINE WAS WRITTEN, and the calibration changed the design twice.**
1218 live picker rows / 70 plan_dates / 241 CS drops / **2** live CS adds (the other 24 `operator`
rows sit on 2030 fixture dates — the "adds" signal the charter assumes is essentially absent live).

⛔ **FINDING — THE PICKER'S OWN COMPOSITE IS A COIN FLIP.** Across the 24 learnable days, 1653
same-day (kept, dropped) pairs: `priority_score` concordance with CS = **50.0%** (the view
independently computes 50.03%). Per-feature: `empty_shelves_count` **68.6** · `empty_shelf_pct`
**67.3** · `active_intent_count` **38.2** · `fill_pct` **40.4** · `expired_skus_now` 56.0 ·
`days_since_visit` 51.0 · `runway_days` 49.0 · `units_last_7d` 49.5 · `dead_slot_pct` 47.7 ·
`hero_slot_count` all-ties.

⛔ **THE TWO POLARITY TRAPS, both caught by live probe, both now structural in the schema.**
Weights multiply normalised `s_*` terms in `v_machine_priority` (`score = w_empty*s_empty + …`),
NOT raw features.

1. **SIGN.** Concordance BELOW 50 means CS keeps machines with LOW values — which for a dial that
   already rewards low values is evidence to **RAISE**, not lower. Encoded as `param_rewards` in a
   TABLE so a one-row `UPDATE` can falsify it; an inline `CASE` could not be mutated that way.
2. **MONOTONICITY — the trap that killed the intuitive mapping.** Measured `corr(s_term, feature)`:
   `s_empty`/`empty_shelves_count` **+1.000** · `s_empty`/`empty_shelf_pct` **+1.000** ·
   `s_expiry`/`expired_skus_now` **+1.000** · `s_stale`/`days_since_visit` **+0.943** — all ACTIVE.
   But **`corr(s_lowfill, fill_pct) = −0.042`**: the obvious `fill_pct → w_lowfill` mapping is
   WRONG, that dial does not control fill at all. `fill_pct`'s nearest dial is `w_capacity`
   (−0.458) and even that fails the 0.70 bar. Also REFUSED: `runway_days` (−0.160),
   `dead_slot_pct` (+0.038). **4 of 11 features survive; 7 are named refusals as table rows.**

⭐ **EXPECTED LIVE YIELD RECORDED IN ADVANCE** so the miner's first run is checked against a
prediction and not against itself: **EXACTLY ONE proposal — raise `w_empty` 0.900 → 0.945 (+5.05%)**,
lead feature `empty_shelves_count`, 1318 pairs, 24 days. ⛔ Do NOT benchmark this miner against the
edit miner's "≥5 proposals" bar: there are only seven dials and one honest proposal is the answer.

**Cody: ⚠️ approve-with-revisions — and one revision was a live crash path.**
`CHECK (proposed_weight <> current_weight)` is a correct invariant AND an abort path: `delta` scales
from the band edge, so a candidate landing exactly ON the band computes `proposed = current` and
**aborts the whole mining run**. Rounding widens it — `w_expiry` at 0.120 needs ~0.42% before
`numeric(6,3)` moves at all. The CHECK stays; the miner must gate `|conc−50| > band` **strictly** and
SKIP any candidate whose rounded weight equals current. Also added `pwp_pairs_coherent`
(`concordant + discordant <= pairs`) at Cody's instruction.

⛔ **Cody REFUSED to certify the parking claim as structural, and was right.** `pick_urgency_params`
carries `authenticated=arwdDxtm` and the miner will be `SECURITY DEFINER` owned by `postgres`, so it
bypasses RLS: nothing in this schema PREVENTS a write. The design gives a function whose body
contains no such write — true by construction, not by structure. **Fixture 58 must therefore carry
two mandatory assertions** (see S-138).

**Article 14: NO ADR**, matching `rotation_proposals_v3` / `facing_proposals_v3` /
`reallocation_proposals_v3` — a review queue and a semantics lookup hold state no view can derive,
and the corrected test is silent staleness, not table count (S-03).

**Verified at apply:** map 11 rows / 4 active · proposals 0 · `pl_*` = 90/100/8/8.00/20.00/5/0.700 ·
ACL on BOTH table and view `{postgres,service_role,authenticated=r}` — no `anon`, byte-identical to
the sibling convention · view reproduces the calibration exactly (24/188/241 · 7/53/48 · 39/0/688) ·
`pick_urgency_params.updated_at` unchanged at `2026-07-13 17:36:38` — **parking intact**.

**0 protected-entity writes · 0 flags flipped · 0 cron schedules changed · 0 engine functions
touched · `machines_to_visit` READ-ONLY throughout.**

## PRD-110 P4.3b (leg 87, 2026-08-01) — the pick-learning miner, and what `pairs` counts

Four migrations, applied in the LAW-1 order (fixture, then subject, twice over).

| version          | name                                               | what                                               |
| ---------------- | -------------------------------------------------- | -------------------------------------------------- |
| `20260801040232` | `prd110_p43b_golden_fixture_58_pick_learning`      | fixture 58 + 39 assertions, all gated on the miner |
| `20260801040645` | `prd110_p43b_mine_pick_history_v3`                 | the miner                                          |
| `20260801041110` | `prd110_p43b_fixture_58_v2_evaluable_pairs`        | fixture 58 v2 — K5, ties and NULLs; +3 assertions  |
| `20260801041202` | `prd110_p43b_mine_pick_history_v3_evaluable_pairs` | `pairs` = evaluable, gate on discriminating        |

⛔ **THE FINDING OF THE LEG — `pairs` MEANT TWO DIFFERENT THINGS, AND THE FIXTURE COULD NOT TELL.**
Leg 86 recorded the expected live yield as _"1318 pairs, 68.6%"_. Leg 87 reproduced 68.57% exactly
and got **474**. Both numbers are real, measured over the same 24 learnable days and the same 1653
ordered (kept, dropped) pairs:

- **1318** = pairs where `empty_shelves_count` is non-null on BOTH sides — **evaluable**
- **474** = pairs that are not ties (concordant 325 + discordant 149) — **discriminating**
- **844** = ties, which is **64% of the evidence base**

⭐ **The constraint settled it, not the prose.** Cody wrote `pwp_pairs_coherent` as
`concordant + discordant <= pairs`. A `<=` is only meaningful if `pairs` carries the ties; had the
discriminating count been intended it would have been `=`. The stored column is now the evaluable
count and the **gate binds on the discriminating count** — 150 pairs of which 149 are ties is one
observation, not 150 — with both reported side by side so a reviewer can see how thin a signal is.

⛔ **AND THE FIRST FIXTURE PASSED UNDER EITHER DEFINITION.** Its population had no ties and no NULLs,
so evaluable = discriminating = 120 and every assertion held whichever meaning the miner used. That
is S-132's failure mode exactly: an assertion that reads strict and discriminates nothing. v2 adds a
fifth kept machine, K5, that **ties** with D2 on two features and is **NULL** on the other two, so
the counts now differ in BOTH directions (150 vs 140, and 120 vs 150) and no single definition
satisfies the fixture by accident.

**Live verification against leg 86's prediction, on every axis:** exactly ONE proposal · raise
`w_empty` **0.900 → 0.945** (+5.0333%) · lead `empty_shelves_count` · **68.57%** · **1318 pairs**
(844 ties, 474 discriminating) · **24 days**.

⭐ **Polarity is falsifiable and was falsified.** Flipping one `picker_feature_param_map_v3.param_rewards`
row to `low` inside a rolled-back transaction reddens fixture 58 on seq 9 (`raise` → `lower`) and
seq 15 (`0.900 -> 0.958` → `0.900 -> 0.842`). That is why polarity lives in a table.

⭐ **The dry run paid for itself again.** `v_gates || 'below_min_pairs'` resolves the untyped literal
to `text[]`, so Postgres parsed it as an array literal and threw `malformed array literal` — inside
the narrow-window call, which aborted the whole scenario. Caught pre-apply; fixed with `::text`.

**Cody: ⚠️ approve-with-revisions on both.** (1) Article 8 — the fixture fires
`tg_audit_machines_to_visit` 160×/run and every row would have landed with `rpc_name = NULL`; it now
stamps `app.rpc_name = 'golden.fixture_58'` (`via_rpc` stays false, because that is the truth).
(2) S-127 is now a LIVE gap, not a theoretical one — `picker_weight_proposals_v3` starts receiving
real writes today and still carries no write-audit trigger. Still fix all eight in ONE unit.

**Verified at apply:** fixture 58 **42/42 green twice committed** (549 ms / 348 ms) · red baselines
captured BOTH times (miner absent → 1 scenario fail, 33 expected-red, 0 true reds; then v2 vs the old
semantics → exactly the 4 predicted true reds 11/40/41/42) · ACL `{postgres,authenticated,service_role}`,
**no `anon`** · `pick_urgency_params.updated_at` unchanged at `2026-07-13 17:36:38.481583+00` —
**parking intact** · `engine_add_pod_v3` `e9f3caff` and `stitch_v3` `a8753091` byte-unchanged.

**0 protected-entity writes · 0 flags flipped · 0 cron schedules changed · 0 engine functions
touched.**

---

## PRD-110 P4.3c — G12 acceptance-rate telemetry (2026-08-01, relay leg 88)

| version          | name                                   | what                                                                               |
| ---------------- | -------------------------------------- | ---------------------------------------------------------------------------------- |
| `20260801042730` | `prd110_p43c_g12_acceptance_telemetry` | 3 params on `refill_policy_params` + `g12_verdict_v3` + `v_proposal_acceptance_v3` |
| `20260801042805` | `prd110_p43c_acl_fix_view_select_only` | S-140 ACL correction on the view (forward-only, Article 12)                        |
| `20260801043420` | `prd110_p43c_golden_fixture_59_g12`    | golden fixture 59 + 50 assertions                                                  |

Dara design → Cody review → apply. Read-only object; **no protected entity is written**.
Articles 2 / 4 / 7 / 8 / 12 / 14 / 16. Full metric definition in METRICS_REGISTRY; helper contract in
RPC_REGISTRY.

⛔ **S-140 (NEW) — THE SUPABASE DEFAULT-PRIVILEGES TRAP IS WIDER THAN LEG 87 RECORDED.** Leg 87
learned the FUNCTION half (`anon` gets EXECUTE explicitly, so `REVOKE ALL … FROM PUBLIC` does not
remove it). The trap also applies to **VIEWS** and to **`authenticated`**: `v_proposal_acceptance_v3`
landed with `authenticated=arwdDxtm` despite the migration containing both `REVOKE ALL … FROM PUBLIC`
and `GRANT SELECT … TO authenticated`, because the default grant is made **explicitly, per role** —
so revoking from `PUBLIC` removes nothing and the `GRANT SELECT` adds nothing already held.
⭐ **The only fix that works is `REVOKE ALL … FROM <role>` then `GRANT SELECT`**, and the only way to
know you need it is to **read `relacl` back** — exactly as leg 87 established for `proacl`. Caught at
verify, corrected forward, and now pinned every run by fixture 59 seq 49, which asserts the full ACL
string rather than merely "no anon".

⚠️ **Cody's recorded condition, not a defect:** with `g12_min_decided = 5` and zero decided proposals
fleet-wide, **all five families report `insufficient_evidence` on day one.** That is correct. It is
also how a gate becomes decorative, so it is written into the PARKING-LOT rather than left for a
future leg to misread a green-looking board as evidence the miners are accepted.

**Verified at apply:** fixture 59 **50/50 green twice committed** (40 ms / 40 ms) · `scenario_error`
NULL and `vacuous:false` on both runs (S-135 reconciled) · **zero pre-epoch residue after both runs**
(`feedback_proposals_v3` back to 8 rows, `picker_weight_proposals_v3` back to 2) · fixture 58 re-run
**42/42**, unharmed · view ACL byte-identical to `v_planning_pins_active_v3` · `g12_verdict_v3` ACL
`{postgres,authenticated,service_role}`, **no `anon`**, one overload · `pick_urgency_params.updated_at`
unchanged at `2026-07-13 17:36:38.481583+00` — **S-138 parking intact** · `engine_add_pod_v3`
`e9f3caff` and `stitch_v3` `a8753091` byte-unchanged.

**0 protected-entity writes · 0 flags flipped · 0 cron schedules changed · 0 engine functions
touched.**

## PRD-110 P4.3d (2026-08-01, relay leg 89) - the weekly miner schedule and its run log

| version          | migration                       | what                                                                                                     |
| ---------------- | ------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `20260801045328` | `prd110_p43d_miner_runs_log`    | `miner_runs_v3` append-only table + 3 dials on `refill_policy_params` + append-only/no-truncate triggers |
| `20260801045333` | `prd110_p43d_run_weekly_miners` | `run_weekly_miners_v3` (SECURITY DEFINER) + `miner_refusal_tally_v3` (IMMUTABLE, INVOKER)                |
| `20260801045440` | `prd110_p43d_weekly_miner_cron` | cron job **46** `prd110_p43d_weekly_miners_0530_dubai`, `30 1 * * 1` (Monday 05:30 Dubai)                |
| `20260801050037` | `prd110_p43d_golden_fixture_60` | golden fixture 60 + 54 assertions                                                                        |

⛔ **THE TRAP THIS UNIT WALKED INTO AND OUT OF (S-141).** The handover said a cron command could be a
bare `SELECT public.mine_*_v3();` because both miners take full defaults. That is true about arity
and dangerous about behaviour: **both miners default `p_dry_run => false`**, so the bare command
would have MINTED LIVE on its first fire - reddening fixture 58 through the global
`ux_pwp_one_pending_per_param` slot and putting real CS-facing proposals in a queue nobody had
decided to fill. The shipped command passes no override either, but it calls a **wrapper** whose
dials default to dry.

⛔ **AND THE COLLISION RUNS BOTH WAYS (S-142) - this is the finding of the leg.** The recorded risk
was "a live cron would break fixture 58". Probed live, the reverse is already true: fixture 58's two
committed `pending` rows (window `2030-03-05..14`, on `w_empty` and `w_stale`) **currently occupy the
GLOBAL one-pending-row-per-dial slot**, so the live pick miner returns `refused: pending_exists` and
`proposals_would_create = 0`. The handover's "the miner would mint ONE proposal, `w_empty`
0.900 -> 0.945" **is no longer what happens**: it would mint nothing, refused by test data. That
refusal is indistinguishable from a real one at a glance, which is why `miner_runs_v3.warnings`
carries `synthetic_pending_blocks_live_minting` on exactly the run it explains.

**Cody's review, three required revisions, all applied before apply:** (Article 4) `GRANT EXECUTE …
TO authenticated` on a DEFINER that accepts `p_pick_dry_run => false` let **any** authenticated user
mint live proposals around the parked dials - the grant is now `service_role` only **and** a role
check refuses the override path, so widening the grant later cannot reopen it; (Article 4) the
runner stamped no provenance - `app.via_rpc`/`app.rpc_name` are now set **immediately before the log
INSERT**, because both miners overwrite `app.rpc_name` with their own name mid-run and a stamp at the
top would have attributed the log row to the miner, and both are restored after so the GUC does not
leak; (Article 8) `miner_runs_v3` is the **ninth** table in the S-127 write-audit-trigger gap, left
for that one unit, which the stamp makes work the day it lands.

**Article 14 ✅** - permitted, and not by the corrected-wording loophole: nothing in the database
records what a miner **would** have minted, so this materialises no query a view could compute. No
ADR owed; `ADR-shadow-plan-tables.md` is byte-unchanged.

**Verified at apply:** fixture 60 **54/54 green TWICE COMMITTED** · `scenario_error` NULL and
`vacuous:false` both runs (S-135 reconciled) · **fixtures 57 (39/39), 58 (42/42) and 59 (50/50) all
re-run green and unharmed** · `miner_runs_v3` holds 4 rows, **all `invoked_by='fixture'`** ·
`picker_weight_proposals_v3` **2**, `feedback_proposals_v3` **8**, `planning_pins_v3` **7**,
`feedback_ledger_v3` **12** - **every one unchanged, zero proposals minted** · table `relacl` exactly
`{postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres,authenticated=r/postgres}` and runner
`proacl` exactly `{postgres=X/postgres,service_role=X/postgres}` (**no `anon`, no `authenticated`**) ·
`mine_edit_history_v3` `a9db274c` and `mine_pick_history_v3` `8d8d915c` **byte-unchanged - the whole
justification for a wrapper** · `engine_add_pod_v3` `e9f3caff` and `stitch_v3` `a8753091` unchanged ·
`pick_urgency_params.updated_at` still `2026-07-13 17:36:38.481583+00` - **S-138 parking intact**.

**0 protected-entity writes · 0 flags flipped · 0 EXISTING cron schedules changed (one job ADDED) ·
0 engine functions touched.**

---

## PRD-110 relay leg 91 - 2026-08-03 - CS decision D-30 + P4.4 spot buy (4 migrations)

| version          | name                                         | what                                                                                 |
| ---------------- | -------------------------------------------- | ------------------------------------------------------------------------------------ |
| `20260803170420` | `prd110_d30_revoke_anon_blocked_demand_gaps` | CS **D-30 "REVOKE NOW"**: `anon` EXECUTE off `_blocked_demand_gaps_v3`               |
| `20260803170737` | `prd110_p44_spot_buy_dials`                  | `spot_buy_price_cap_aed` (15) + `spot_buy_cap_enforcement` (`'warn'`), 81 -> 83 cols |
| `20260803171126` | `prd110_p44_create_spot_purchase_v3`         | the atomic spot-buy RPC (SEC DEF, warehouse+, composes 3 incumbent writers)          |
| `20260803171411` | `prd110_p44_procurement_event_types`         | **additive** CHECK extension: 11 incumbent event types + 2 spot types                |

**D-30 evidence:** `proacl` read BACK per S-140 and asserted whole -
`{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}`. The migration also asserts
the three legitimate grants SURVIVE, because a revoke that silently stripped `service_role` would
break the nightly runner with no error.

**P4.4 evidence:** `create_spot_purchase_v3` `79305485`, one overload, SECURITY DEFINER,
`search_path=public, pg_temp` pinned, `proacl`
`{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}` (no `anon`). Smoke-probed
live in **dry-run**: minted `PO-2026-SPOT3D7C1954` (po_number 9257), received 8 units into **WH_MCC
and not CENTRAL**, auto-closed **1** driver task, `committed=false`. **Residue re-probed after: 0
spot POs, 0 spot events, 0 `-SPOT-B%` batches, 0 task edits, `blocked_demand` still 52 all-open.**

⛔ **`20260803171411` DROPs and re-ADDs `procurement_events_event_type_check`.** It is additive in
effect and it refuses to run unless all **11** incumbent values are present in the live CHECK first,
then re-asserts all 13 and proves the rebuilt CHECK still REFUSES an invalid value. Reusing
`goods_received`/`task_collected` was rejected: it would make a spot buy indistinguishable from a
planned receive in the event stream, which is the signal P4.5's scoreboard needs.

**0 flags flipped · 0 cron schedules changed · 0 engine functions touched** -
`engine_add_pod_v3` `e9f3caff` · `stitch_v3` `a8753091` · `mine_pick_history_v3` `8d8d915c` ·
`mine_edit_history_v3` `a9db274c` · `run_weekly_miners_v3` `9fe5d730` all byte-unchanged.

---

## PRD-110 relay leg 92 - 2026-08-03 - golden fixture 18 closes the P4.4 debt (1 migration)

| version          | name                           | what                                                                |
| ---------------- | ------------------------------ | ------------------------------------------------------------------- |
| `20260803173909` | `prd110_p44_golden_fixture_18` | golden fixture 18 + **80 assertions** for `create_spot_purchase_v3` |

**Result: 80/80 GREEN on two consecutive committed runs** (149 ms, 210 ms), `n_fail=0`,
`n_expected_red=0`, no `scenario_error`, not vacuous. Golden moves **49 -> 50 fixtures** and
**1655 -> 1735 assertions**. This closes the ⏸️ debt leg 91 declared: P4.4 was BUILT and
smoke-proven but UNFIXTURED, and therefore unproven under LAW 1.

⭐ **THE FIXTURE EXERCISES THE REAL WRITE PATH (`p_dry_run=false`) AND STILL LEAVES ZERO ROWS.**
The scenario runs plant + 12 refusal probes + a dry run + the committed write inside ONE plpgsql
subtransaction and ends it with `RAISE EXCEPTION 'FX18_ROLLBACK'`. Rows vanish; plpgsql VARIABLES
survive, so everything the assertions read is captured into `s_*` variables BEFORE the unwind and
written to `golden.scratch` after it. This is the same mechanism the RPC uses for its own dry run.

⛔ **A DELETE-BASED RECLAIM IS NOT MERELY WORSE HERE, IT IS IMPOSSIBLE.** `warehouse_inventory` is
referenced by `inventory_audit_log`, so DELETEing the received batch requires erasing append-only
audit rows (Article 7). The first draft hit exactly this FK. Rolling back never writes them.
⚠️ The one thing a rollback cannot undo is `nextval('po_number_seq')` - sequences are
non-transactional, so each run burns one `po_number`. Same accepted class as fixture 60's permanent
`miner_runs_v3` rows, and recorded rather than discovered later.

⛔ **THE CALLER IS A `warehouse` USER AND THAT IS A SAFETY PROPERTY, NOT A DETAIL.** Per S-145
`add_purchase_order_lines` is owner-only, so a warehouse caller can never take the attach path and
`po_path` is deterministically `'minted'`. An `operator_admin` caller would attach to whatever open
walk-in PO happens to exist for that supplier TODAY and then stamp `received_date` on it - on a day
when procurement has an open Carrefour PO, the fixture would receive a **real production purchase
order**. Leg 91's dry run returned `minted` only because no such PO existed that minute.

**Residue verified independently after three total runs** (one smoke + two committed): 0 FX18
`warehouse_inventory` rows, 0 `refill_dispatching` rows on the 2030 date, 0 FX18 `blocked_demand`
rows, 0 `PO-%-SPOT%` purchase orders, 0 spot `procurement_events`, `inventory_events` still **48**.
⭐ `blocked_demand` is still **52 rows, ALL 52 open** - the fixture creates the table's first-ever
resolutions and then unwinds them, so Cody's G12 condition remains untested by construction and
nobody can read a burn-down out of fixture traffic.

**0 flags flipped · 0 cron schedules changed · 0 engine functions touched · 0 RPC bodies edited** -
`engine_add_pod_v3` `e9f3caff` · `stitch_v3` `a8753091` · `mine_pick_history_v3` `8d8d915c` ·
`mine_edit_history_v3` `a9db274c` · `run_weekly_miners_v3` `9fe5d730` ·
`create_spot_purchase_v3` `79305485` all byte-unchanged under `md5(prosrc)`.

---

## PRD-110 relay leg 93 - 2026-08-03 - CS decision D-23 EXECUTED, fixture-only (1 migration)

| version          | name                                           | what                                                         |
| ---------------- | ---------------------------------------------- | ------------------------------------------------------------ |
| `20260803175617` | `prd110_p32_fixture41_d23_zero_headroom_clamp` | fixture 41 anchor C + **17 assertions** (seq 47-63), no code |

**Result: 63/63 GREEN on two consecutive committed runs** (1812 ms, 1763 ms), `n_fail=0`,
`n_expected_red=0`, no `scenario_error`, not vacuous. Golden stays **50 fixtures**, assertions move
**1735 -> 1752**. ⛔ **NO function was created or altered** - `resolve_m2m_sku_legs_v3` is
byte-unchanged, which is the whole point: CS answered D-23 "KEEP THE CLAMP", and keeping behaviour
is only a decision if something pins it.

⭐ **WHAT WAS ACTUALLY MISSING, MEASURED BEFORE ANYTHING WAS WRITTEN.** Fixture 41's anchor A has
headroom 9 (clamp never fires) and anchor B headroom 1 (partial clamp). **Nothing in the suite
reached headroom = 0** - the case where the clamp is most consequential, because it is the one in
which the resolver must transfer NOTHING. Separately, `dest_capacity_clamp` appeared as a literal
string in **zero of the 46 assertions**: it was pinned only INDIRECTLY (`totals.clamped_units` is a
SUM FILTERed on that exact reason, so a rename reddens seq 36), while seq 38 merely counts DISTINCT
return reasons and would survive renaming both.

⭐ **ANCHOR C - THE OVER-FULL DESTINATION.** `golden.pin_machine_stock(MPMCC-1058, 99)` puts every
aisle at 99 units, so A05 (`max_stock` 6) reads `current_stock` 99 through `v_shelf_state` - the
resolver's own view. Raw headroom is **negative** and `GREATEST(...,0)` floors it to 0, so this
exercises the OVER-full case, not merely the exactly-full one. Result, verified by a rolled-back
smoke probe BEFORE a single assertion was written (S-149): `status=ok · input=14 · transfer=0 ·
return=14 · clamped=8 · conserved=true · dest.headroom=0 · transfer legs in the array = 0 · reasons
= {dest_capacity_clamp, not_assortable_at_destination}`.

⛔ **S-155 (NEW) - WHY PINNING A LIVE WEIMI OBSERVATION IS SAFE HERE, AND WHY AN INNER EXCEPTION
HANDLER WOULD MAKE IT UNSAFE.** `golden.run_fixture` executes `scenario_sql` inside a plpgsql
`BEGIN ... EXCEPTION WHEN OTHERS` block. That is a SUBTRANSACTION: if any statement between the pin
and the restore raises, the whole scenario - pin included - rolls back and never commits. So the
fixture-3 idiom (pin -> work -> restore, ONE `DO` block, **NO** inner handler) is exactly right, and
adding a handler would be strictly worse: it would let execution continue past a failed restore and
leave a live observation modified. Confirmed empirically - the smoke probe ended in `RAISE` and left
0 rows in `golden.weimi_pin_backup`, 0 unfinished `golden.runs`, and A05 back at `current_stock` 5.

⭐ **THE THREE ANCHORS JOINTLY DEFEAT VACUITY, which is why no counterfactual probe was needed.**
Headroom 9 -> (transfer 6, clamped 0) · headroom 1 -> (transfer 1, clamped 7) · headroom 0 ->
(transfer 0, clamped 8). Removing the `LEAST(..., headroom)` term would make **all three** read
transfer = eligible-units and clamped = 0, so it cannot pass any of them. Monotonicity across
anchors is the discriminator, and it is asserted rather than argued.

⛔ **LAW 5 AT THE BOUNDARY (seq 54).** With zero headroom the resolver emits **zero transfer legs**
rather than a transfer leg carrying qty 0. A 0-unit transfer leg is precisely the silent-qty-0 class
LAW 5 exists to forbid, so this is asserted as a correctness property, not noted as an observation.

**Cody review - ⚠️ approve with revisions, all three applied before apply:**

- **R1 (Article 12)** the `scenario_sql` append was unguarded. Forward-only does not imply
  re-application-safe: a second append would run pin/restore twice and the second
  `restore_machine_stock` would raise "no pin backup". Now guarded by
  `AND position('legs_C' in scenario_sql) = 0`.
- **R2** seq 61/62 originally pinned the live levels `5` and `1`. Those move on any sale or refill,
  and a residue proof that reddens for non-residue reasons trains the operator to ignore the one
  assertion whose job is catching a modified live observation. Now captured `pre_pin` and asserted
  **post-restore = pre-pin**, so it is drift-immune.
- **R3** seq 49 pinned `-93`, which encodes `max_stock` 6 - ordinary configuration. Now `lt 0`,
  which still proves the over-full case the `GREATEST(...,0)` floor exists for.

**Residue re-verified independently after three total runs** (one smoke + two committed), by direct
query rather than the scenario's own bookkeeping: `golden.weimi_pin_backup` **0** rows, unfinished
`golden.runs` **0**, A05 `current_stock` **5** / headroom **1**, A06 headroom **9** - all identical
to the pre-leg readings.

**0 flags flipped · 0 cron schedules changed · 0 engine functions touched · 0 RPC bodies edited** -
`engine_add_pod_v3` `e9f3caff` · `stitch_v3` `a8753091` · `mine_pick_history_v3` `8d8d915c` ·
`mine_edit_history_v3` `a9db274c` · `run_weekly_miners_v3` `9fe5d730` ·
`create_spot_purchase_v3` `79305485` all byte-unchanged under `md5(prosrc)`.

## PRD-110 relay leg 94 - 2026-08-03 - CS decision D-36 EXECUTED, fixture + engine (2 migrations)

| version          | name                                           | what                                                                       |
| ---------------- | ---------------------------------------------- | -------------------------------------------------------------------------- |
| `20260803181333` | `prd110_p36_fixture54_d36_provenance_reassert` | fixture 54 step (6) + 9 assertions (seq 60-68). RED on the old body.       |
| `20260803181622` | `prd110_p36_swap_v3_d36_reassert_rpc_name`     | `swap_v3` body substitution: re-assert after each inner call. 41/41 green. |

**CS answered D-36 → RE-ASSERT `app.rpc_name` after each inner call in `swap_v3`; no signature
change.** Applied fixture-first per LAW 1: the fixture went red on seq 62/65/66 against the old
body, and green on the new one.

**⛔ D-36's PARKED PREMISE WAS FALSE AND IS CORRECTED IN THE MIGRATION HEADER.** The note claimed
`write_audit_log` "records two ordinary edits and no swap". It records **nothing**: `plan_edits_v3`
carries no `audit_log_write` trigger at all (only `tg_plan_edits_v3_append_only` /
`_no_truncate`), and `write_audit_log` holds **zero** rows for `swap_v3`, `record_plan_edit_v3` or
`plan_edits_v3`. The real defect is narrower and worse - `set_config(..., true)` is
**transaction-scoped**, so `swap_v3` returned leaving `record_plan_edit_v3` behind and the next
write to any of the **42** audited tables in that transaction was stamped with the inner writer.
Measured live before a line was written: after a successful swap,
`current_setting('app.rpc_name')` = `record_plan_edit_v3`.

**⭐ `swap_v3` was the LONE outlier, not a new convention.** Every other v3 writer that calls an
inner `rpc_name`-setter already re-asserts - `create_spot_purchase_v3` (3), `mine_edit_history_v3`
(3), `run_weekly_miners_v3` (2), `submit_feedback_v3` (2) - and fixtures 56/57/58 already pin the
property for three of them.

**Anchors (S-157 spread):** successful two-leg swap → `record_plan_edit_v3` (RED → `swap_v3`) ·
refused swap → caller's own value survives, because the caught raise rolls the subtransaction back
(GREEN before **and** after - this is what proves seq 62 measures the inner calls, not the probe).

**CODY: ⚠️ APPROVE WITH REVISIONS on both, both defects real and applied BEFORE apply.**

- **R1 (fixture)** seq 65/66 had a vacuity hole that opened exactly on the D-35 bypass class: with
  **zero** inner calls the body splits into one element, so seq 65 finds the _opening_ assert in
  the tail and seq 66 evaluates `n-1 >= 0` - **both green precisely when the canonical writer had
  been bypassed**. Closed by seq 68 pinning `inner_calls` at `gte 2`.
- **R1 (engine)** the verify block omitted `pronargdefaults`. `swap_v3` has two defaulted args, so
  every 5-arg caller depends on them surviving the replace - the exact omission behind the 13-day
  driver-confirm outage in the Wave-2 closeout. Now asserted `= 2`.

**Verified after apply:** `swap_v3` md5(prosrc) `733e653a` → `ffff8485` · `pronargdefaults` **2** ·
`SECURITY DEFINER` intact · `search_path=public, pg_temp` intact · ACL byte-identical
(`{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}`, no `anon`, no `PUBLIC`) ·
**one** overload · identity arguments unchanged. Fixture 54 **41/41 green on two consecutive
committed runs**.

**⭐ HERMETICITY PROVEN, NOT ASSUMED.** `golden.run_all()` runs every fixture in ONE transaction and
a subtransaction that COMMITS does not roll `set_config` back, so step 6 restores the ambient value
on exit. Fixture **60 seq 54 reads the ambient `app.rpc_name` without setting it first**, so an
unrestored sentinel would have reddened fixture 60 for a reason unrelated to fixture 60. Tested by
running 54 then 60 in one shared transaction: `f54_fail=0`, `f60_fail=0`, and the value between
them was `compose_plan_with_edits_v3` - what fixture 60 would have seen anyway, not the sentinel.

**Blast radius closed:** no other DB function calls `swap_v3` and `grep -rn swap_v3 src/` returns
nothing, so fixture 54 (scenario + seq 11/12/35) is the complete consumer set.

**0 flags flipped · 0 cron schedules changed · 0 other engine functions touched** -
`engine_add_pod_v3` `e9f3caff` · `stitch_v3` `a8753091` · `mine_pick_history_v3` `8d8d915c` ·
`mine_edit_history_v3` `a9db274c` · `run_weekly_miners_v3` `9fe5d730` ·
`create_spot_purchase_v3` `79305485` · `resolve_m2m_sku_legs_v3` `3eb6f3af` all byte-unchanged
under `md5(prosrc)`.

---

## `20260803183514_prd110_p03_fixture61_d35_one_calendar` (2026-08-03, relay leg 95)

**CS DECISION D-35, fixture leg.** Golden fixture **61**, 13 assertions. Applied BEFORE the engine
edit and confirmed **RED on seq 4 and 5** against the then-live body - that red is the deliverable
(LAW 1), not a defect. Golden **50 -> 51 fixtures**, assertions **1761 -> 1774**.

**What it proves.** Not "the helper exists" - that the two copies of the PRD-035 WS-E calendar
AGREE, measured across **seven consecutive days**: for each day it calls Stage 1 and compares
"did it take the Saturday exit?" against `is_refill_planning_day_v3()`. Seq 7 requires zero
disagreements; seq 8/9/10 require **exactly one** skip, on the Saturday, with the helper
independently rejecting exactly one day whose DOW is 6.

⭐ **The spread is what makes the agreement mean anything (S-157).** A helper stuck at TRUE and a
Stage 1 that never skips agree perfectly on all seven days. Without seq 8/9/10, seq 7 is theatre.

⛔ **NEW LANDMINE - S-164: A 2030 DATE IS NOT AUTOMATICALLY SAFE TO CALL STAGE 1 ON.**
`_build_draft_core_v3` returns early on a Saturday, on a live plan, and on zero included machines,
but on a date carrying **confirmed + included** `machines_to_visit` rows it proceeds into
`engine_add_pod` / `engine_swap_pod` / `engine_finalize_pod`, under its own pinned
`statement_timeout` of **20 minutes**. `2030-03-05..2030-03-14` carry **eight** `machines_to_visit`
rows each (fixture 58's cast), so "any synthetic 2030 date" would have fired the real engines inside
the golden harness. The fixture verifies its window is virgin FIRST and refuses to call Stage 1 at
all otherwise; seq 3 turns that refusal into a red instead of a runaway. Window `2030-06-03..09` was
probed virgin before the file existed. ⭐ **Generalise: LAW 12 says use synthetic 2030 dates; it does
NOT say a 2030 date is empty. Probe the window, every time.**

**CODY ⚠️ APPROVE WITH REVISIONS - R2 applied before apply.** The residue and virginity checks
covered `machines_to_visit` / `pod_refill_plan` / `refill_dispatching` but omitted
**`refill_plan_output`** - the one protected table LAW 12 names by name, and the one fixture 53
seq 22 already tripwires. Added to both. Seq 11 now proves all four tables untouched.

⭐ **Anti-vacuity is seq 13.** If the window were not virgin the loop would not run, leaving
`disagreements = 0` and greening seq 7 vacuously. Seq 13 pins `days_probed = 7`, and seq 6 pins that
the Saturday exit still EXISTS at all - deleting the branch outright would otherwise satisfy seq 5.

---

## `20260803183540_prd110_p03_stage1_d35_collapse_saturday_to_helper` (2026-08-03, relay leg 95)

**CS DECISION D-35 EXECUTED AND CLOSED.** Body substitution over `pg_get_functiondef()`, one IF
condition: `EXTRACT(DOW FROM p_plan_date) = 6` becomes
`NOT public.is_refill_planning_day_v3(p_plan_date)`. Fixture 61 goes **13/13 green, twice**.
Article 16's "known illegal copy to retire" (METRICS_REGISTRY, the refill-planning-calendar row) is
retired; Stage 1 and `run_nightly_shadow_v3` now share one calendar object.

⛔ **WHY THIS WAS NOT A ONE-LINE SWAP.** The helper is `p IS NOT NULL AND EXTRACT(DOW FROM p) <> 6` -
a **strictly larger guard set** than the inline rule. On a NULL date the inline rule declines the
branch (NULL condition) while `NOT helper(NULL)` TAKES it, converting a raise into a silent
`skipped_saturday`. It is safe at this site, and only at this site, because
`IF p_plan_date IS NULL THEN RAISE` executes three lines earlier. The migration asserts that ordering
**positionally on the live body** and REFUSES rather than assuming it. ⭐ **Generalise: collapsing an
inline rule onto a named helper is only semantics-preserving if the helper's guard set is not larger
than the site's - or if the extra guards are already discharged upstream. Check, don't assume.**

**CODY ⚠️ APPROVE WITH REVISIONS - R3 applied before apply.** `position()` returns 0 for "not found",
so the original ordering check would have reported "the NULL guard moved" when the truth was "the
branch is gone" - a correct refusal with a wrong diagnosis. Each landmark is now proven to EXIST
before any position is compared, and `v_def IS NULL` is refused outright.

⭐ **Anchor counted as an exact substring, deliberately NOT as a regex.** The anchor is 130+
characters of prose and punctuation; hand-escaping it for `regexp_matches` is its own defect surface.
`(length(def) - length(replace(def, anchor, ''))) / length(anchor)` counts literal occurrences with
nothing to escape, and must equal exactly 1 before the replace runs.

**VERIFIED AFTER APPLY, BY DIRECT QUERY.** `_build_draft_core_v3` `md5(prosrc)`
**f69dd070 -> fef941d5** · `pronargdefaults` **0** · `SECURITY DEFINER` intact · identity arguments
unchanged · **one** overload · both pinned GUCs intact (`search_path=public`,
`statement_timeout=1200000`) · ACL byte-identical per S-140
(`{postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}`) ·
`helper_calls`=1 · inline DOW occurrences=**0** · `skipped_saturday` branch intact.
**Re-applying the migration is a proven no-op** (idempotency guard returns early; md5 unchanged).

**Blast radius closed.** Callers are `build_confirmed_now_v3` and `build_draft_for_confirmed_v3`
(the latter is cron 13); a body edit reaches neither signature. `grep -rn` over `src/` returns
nothing for either name. **Golden fixture 53 re-run after the collapse: 22/22 green** - seq 8 still
reads `skipped_saturday`, which is the LAW 12 proof that production behaviour did not change.

⚠️ **RAISED, NOT FIXED (LAW 10) - see PARKING-LOT D-41.** `_build_draft_core_v3` holds `anon=X` and
its role guard short-circuits on a NULL `auth.uid()`. Pre-existing, untouched here, and the ACL is
asserted byte-identical precisely so this unit provably did not touch it.

**0 flags flipped · 0 cron schedules changed · 0 other engine functions touched** -
`engine_add_pod_v3` `e9f3caff` · `stitch_v3` `a8753091` · `swap_v3` `ffff8485` ·
`mine_pick_history_v3` `8d8d915c` · `mine_edit_history_v3` `a9db274c` ·
`run_weekly_miners_v3` `9fe5d730` · `create_spot_purchase_v3` `79305485` ·
`resolve_m2m_sku_legs_v3` `3eb6f3af` all byte-unchanged under `md5(prosrc)`.

---

## PRD-110 P4.2 / CS DECISION D-38 (2026-08-03, relay leg 96) — EDIT WINS, LOUDLY

| version          | name                                        | what                                                                     |
| ---------------- | ------------------------------------------- | ------------------------------------------------------------------------ |
| `20260803185605` | `prd110_p42_fixture62_d38_edit_wins_loudly` | golden fixture 62, 18 assertions · **RED 7/11** on the pre-change bodies |
| `20260803190232` | `prd110_p42_d38_edit_wins_loudly`           | five-part implementation (columns · intent vocab · trigger · both verbs) |
| `20260803190324` | `prd110_p42_d38_fix_uuid_aggregate`         | `min(uuid)` does not exist — caught at runtime by fixture 62 seq 2       |

CS answered D-38 → **edit wins, loudly**. Below-pin edits still APPLY; the override is now stamped on
the edit line and lands in `feedback_ledger_v3` as `pin_contradiction` evidence for G12.

**Five parts, ONE migration, deliberately** (the S-128 removal-contract lesson): `plan_edits_v3` gains
`pin_floor_at_edit` / `pin_contradiction` / `pin_feedback_id`; `feedback_ledger_v3`'s intent CHECK
gains a ninth value by S-148 additive rebuild; `tg_plan_edits_v3_append_only` learns to protect the
three new columns; `submit_feedback_v3` accepts the ninth intent; `record_plan_edit_v3` detects,
stamps and emits. Split across units, fixture 62 would redden on the fix itself.

⛔ **THE FLOOR IS READ FROM THE ENGINE, NEVER RECOMPUTED.** `engine_add_pod_v3` already writes
`pin_floor_units` onto EVERY shadow line (0 explicitly when unpinned) and `record_plan_edit_v3`
already resolves that exact base row for `base_qty_at_edit`. The edit path therefore ASKS the engine
what floor it applied. Re-deriving it from `v_planning_pins_active_v3` would put a second copy of the
pin ladder in a second function — the Article 16 sin D-35 retired one migration earlier, with S-165's
guard-set trap attached.

⛔ **THE FLOOR IS THE TEST, NOT `pin_binds`.** `pin_binds` means "the pin decided `need_raw`". A floor
of 6 on a line the ladder independently took to 9 does not bind, yet an edit down to 3 is still an
override of live CS policy. Gating on `pin_binds` would silently miss that entire class.

⛔ **AND THE EDIT MUST HAVE LOWERED IT.** The rule is `floor > 0 AND effective < floor AND effective <
base`. The third clause is load-bearing: without it a line the ENGINE left short (WH-limited) is
blamed on the next human who touches it, and an `add` raising a short line TOWARD its floor is
recorded as an override of the very pin it is moving toward.

### CODY: ⚠️ APPROVE WITH REVISIONS — three, all applied BEFORE apply

- **⛔ CODY R1 — `pin_contradiction` is NULLABLE.** A `NOT NULL DEFAULT false` would backfill all
  pre-D-38 rows to "false", asserting _evaluated, no contradiction_ about edits never checked against
  a pin. That is the silent-zero LAW 5 forbids and exactly what fixture 62 seq 10 exists to prevent.
  ⭐ **Confirmed live after apply: 182 of 196 rows read NULL** — under the original design all 182
  would now be lying.
- **⛔ CODY R2 — the FK is `ON DELETE RESTRICT`, not `SET NULL`.** `SET NULL` is an UPDATE against an
  append-only table: the trigger raises and the delete fails anyway, so `SET NULL` declares behaviour
  that cannot happen. `RESTRICT` states the true intent and matches every other FK on the ledger.
- **⛔ CODY R3 — METRICS_REGISTRY records the provenance read** so a later leg does not "converge"
  the edit path onto the pins view and silently reintroduce the duplication.

### ⛔ S-166 (NEW) — AN ABSOLUTE COUNT OF A PRODUCTION TABLE IS A DECAYING TRIPWIRE

Fixture **50 seq 46** and **51 seq 51** ("LAW 11: the Gate-0 queue is untouched at 1240") are **RED**,
and **not because of this unit** — nothing here writes `machines_to_visit`. The table is at **1330**:
cron 13 adds production rows nightly (2026-08-02/03/04 present) and other fixtures' 2030 casts
accumulate. Both were green on 2026-08-01 and have been **silently rotting since**; this leg is simply
the first to run them again. ⭐ **The intent is a DELTA ("the fixture did not touch it"), expressed as
an ABSOLUTE.** ⛔ **Do NOT bump 1240 → 1330** — that re-arms the same decay and reads as green while
meaning nothing. The fix is to capture the count before and after the scenario body and assert
equality, exactly as fixture 62 seq 16/18 do. ⚠️ Same class as the defect caught in fixture 62's own
draft and corrected before apply.

### VERIFIED AFTER APPLY, BY DIRECT QUERY

`record_plan_edit_v3` `md5(prosrc)` `b77f9e9a` → **`7c510cd1`** · `submit_feedback_v3` `00318176` →
**`26ffe548`** · both SECURITY DEFINER, one overload each, identity arguments unchanged, whole ACL
byte-identical (S-140), `search_path=public, pg_temp` intact · ⛔ **`pronargdefaults` asserted at its
REAL value per verb — `record_plan_edit_v3` 0 and `submit_feedback_v3` 2.** The draft asserted a
convenient uniform 0 and would have failed; S-163 caught it (13-day driver-confirm outage precedent).
**Blast radius re-run GREEN: fixtures 55 (26/26) · 56 (45/45) · 57 (39/39) · 54 (41/41) · 16 (31/31) ·
17 (25/25).** Fixture 62 **18/18 on two consecutive runs**. Golden **51 → 52 fixtures**, assertions
**1774 → 1792**.

**0 flags flipped · 0 cron schedules changed · 0 engine functions touched** — `engine_add_pod_v3`
`e9f3caff` · `stitch_v3` `a8753091` · `swap_v3` `ffff8485` · `mine_pick_history_v3` `8d8d915c` ·
`mine_edit_history_v3` `a9db274c` · `run_weekly_miners_v3` `9fe5d730` · `create_spot_purchase_v3`
`79305485` · `resolve_m2m_sku_legs_v3` `3eb6f3af` · `run_nightly_shadow_v3` `c0ddc8b5` ·
`_build_draft_core_v3` `fef941d5` all byte-unchanged under `md5(prosrc)`.

---

## PRD-110 S-166 (2026-08-03, relay leg 97) - the Gate-0 queue tripwire becomes a DELTA (2 migrations)

| version          | name                                                         | what                                                    |
| ---------------- | ------------------------------------------------------------ | ------------------------------------------------------- |
| `20260803192110` | `prd110_p3_s166_gate0_queue_delta_not_constant`              | 3 scenario bodies + 3 assertions rewritten              |
| `20260803192227` | `prd110_p3_s166_gate0_queue_delta_not_constant_reapply_noop` | SAME body, applied twice on purpose = idempotency proof |

**Defect.** Fixtures 11/50/51 asserted "the Gate-0 queue is untouched" as an ABSOLUTE count
(`machines_to_visit = 1240`). `public.machines_to_visit` grows nightly via cron 13, and the table now
stands at **1330**. The assertions were green on 2026-08-01 and red on 2026-08-03 with **nothing
changed but production**.

**⛔ The third red was invisible.** Leg 96 reported two (50 seq 46, 51 seq 51). Fixture 11 seq 38
carries the identical shape but last ran on 08-01, so its `golden.scratch` row still held the stale
1240 and the fixture read GREEN. Running it at this leg's baseline turned it red immediately
(`actual 1330`). **A stale fixture is not a passing fixture** - the blast radius of a decaying
tripwire is every fixture carrying the shape, not just the ones that happen to have re-run.

**Fix.** Each body captures the count BEFORE the scenario runs (`golden.scratch` key
`tripwires_before`, inserted immediately after the body's own `DELETE FROM golden.scratch`); the
existing tripwire section already captured it AFTER; the assertion subtracts and expects `0`. This is
the shape fixture 1 seq 83 already used in this repo. ⛔ **Bumping 1240 -> 1330 was refused** - it
re-arms the identical decay and yields an assertion that is green and meaningless.

**⛔ Why the fixture-11-seq-39 shape was NOT copied.** Seq 39 asserts the `pod_refills` tripwire
against a live `count(*)` re-taken at assertion time. That is drift-immune but WEAK: both readings
are taken AFTER the body, so a body that wrote rows would be included in both and the delta would
still be 0. Only a BEFORE-vs-AFTER pair can catch what LAW 4 actually cares about.

**CODY: ⚠️ APPROVE WITH REVISIONS - one, applied before apply.** R1: the draft was two `DO` blocks,
i.e. two statements. A failure in the second would have left bodies carrying a before-capture that no
assertion reads - a half-applied migration. Collapsed into ONE `DO` block so atomicity does not depend
on the runner's transaction semantics. (Class (f), non-protected: the `golden` schema is test
infrastructure. Article 16 checked and does not bind - `machines_to_visit` is the base table of
`v_pick_decision_cohorts_v3`, but a raw `count(*)` used as a write-tripwire is not a re-derivation of
the cohort metric.)

**Non-vacuity PROVEN, not assumed** (perturbation inside a `DO` block that raises to roll itself back):
a board that moves by 7 makes the assertion return **`7`**, and a before-capture that never ran makes
it return **`absent`**. Both are red. The `COALESCE(...,'absent')` is what stops a missing capture
passing as NULL.

**Verified after apply.** Fixtures **11 (39/0) · 50 (49/0) · 51 (53/0)**, green on two consecutive
full runs; RED baseline `1330 vs 1240` captured on all three first. `golden.fixtures` **52** and
`golden.assertions` **1792** both UNCHANGED (3 rewritten, 0 added). Zero `expect='1240'` survivors.
**0 flags flipped · 0 cron schedules changed · 0 engine functions touched.**

**⚠️ METHOD NOTE.** Proving idempotency by RE-APPLYING as a migration mints a second
`schema_migrations` row and therefore a disk-filing debt; it was filed at `20260803192227` to keep the
owed set empty. Later legs should prove idempotency by re-running the body through
`/tmp/prd110_sql.sh`, which mints no row.

## Leg 98 (2026-08-03) — D-19 pre-flip proof. 2 migrations, 0 flags flipped.

| version          | name                                             | what                                                                                                                                                 |
| ---------------- | ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260803193834` | `prd110_leg98_d19_stitch_gate_probes`            | `golden.probe_stitch_under_mode` + `golden.probe_atomic_commit_under_mode`. Golden-schema only; no engine, no production row, no flag.               |
| `20260803194336` | `prd110_leg98_fixture63_stitch_gate_d19_preflip` | Golden fixture **63** (`2030-03-05`, phase `P2`) + **33 assertions**. Pins the preflight gate at the two enforcement sites fixture 33 never touches. |

**Result: fixture 63 GREEN 33/33 on three consecutive runs.** Fixture 33 re-run after it: **35/35**,
uncontaminated. Live `preflight_enforcement` still `warn` — verified after every run.
Golden: **52 → 53 fixtures**, **1792 → 1825 assertions**.

⛔ **D-19 WAS NOT EXECUTED, and the fixture is the reason.** See `S-172` in the PARKING-LOT: the flip
arms a guard whose escape hatch is unreachable from the only commit path the FE calls, and whose
refusal reaches the operator as `PRD-019 E2` instead of `INV-06`. The precondition the leg-97 pointer
demanded — _prove the override exists and works before flipping_ — is now **proven for
`commit_refill_plan` (fixture 33, re-run green this leg) and DISPROVEN for the path CS actually uses.**

⭐ **Fixture 63's safety design, reusable:** parents are seeded `status='stitched'`, never `'approved'`,
so `stitch_pod_to_boonz` always halts at its own `no approved rows` guard, which sits **after** the
preflight gate. "Reached `no approved rows`" is therefore a safe, deterministic marker for _the gate
let this through_, and no call in the fixture can ever run a real stitch.
⚠️ Consequence to remember: the `p_force` path's `preflight_override_log` INSERT is rolled back by that
same halt, so `override_log_delta` is **0 on every probe by construction** — the audited-write shape is
asserted on the column default instead (seq 43), never on a delta that cannot move.

---

## leg 99 (2026-08-03) — D-41 EXECUTED: the legacy Stage-1 grant sweep

| version          | name                                              | what                                                                         |
| ---------------- | ------------------------------------------------- | ---------------------------------------------------------------------------- |
| `20260803195429` | `prd110_leg99_fixture64_d41_stage1_grant_sweep`   | golden fixture 64 (23 assertions), landed FIRST and RED on 12 of them        |
| `20260803195618` | `prd110_leg99_d41_stage1_grant_sweep`             | the sweep: REVOKE EXECUTE FROM `anon` **and** `PUBLIC` on all five           |
| `20260803195820` | `prd110_leg99_fixture64_seq9_public_detector_fix` | seq 9's PUBLIC detector rewritten to `aclexplode(grantee=0)` + seq 24 canary |

**What D-41 was.** Five legacy Stage-1 `SECURITY DEFINER` functions were executable by `anon`:
`_build_draft_core_v3`, `build_draft_for_confirmed_v3` (cron 13's entry point), `build_confirmed_now_v3`,
`pick_machines_for_refill` and `confirm_machines_to_visit`. The last two **write**. Their role gate reads
`IF auth.uid() IS NOT NULL AND NOT EXISTS (... operator_admin ...) THEN error`, so for `anon`
(`auth.uid()` = NULL) the condition short-circuits false and the guard is **skipped entirely** — it
protects an authenticated non-admin and waves through an unauthenticated caller.

CS closed D-41 in a Cowork session: _"REVOKE ALL FIVE NOW … Grant-layer fix only — live function bodies
stay byte-untouched (LAW 12); the guard-pattern hardening itself ships with v3."_

⛔ **THE PARKED PREMISE WAS INCOMPLETE, and this is the second consecutive leg where that was true.**
D-41 was raised naming only `anon`. Measured live at execution, **four of the five also carried a PUBLIC
grant** (`=X/postgres`). `anon` is a member of `PUBLIC`, so `REVOKE … FROM anon` alone would have left
`has_function_privilege('anon', oid, 'EXECUTE')` **TRUE** — CS's own stated acceptance test would have
failed while the migration reported success. Revoking `PUBLIC` is required **by** the answer, not scope
drift beyond it. Cody approved on exactly that reading.

⚠️ **ARTICLE 4 IS NOT CURED AND MUST NOT BE RECORDED AS CURED.** The sweep removes _reachability_, not
the _guard inversion_. CS assigned the hardening to v3. Fixture 64 seq 18–22 pin all five bodies by
`md5(prosrc)` so the scope split cannot be crossed silently in either direction.

⭐ **S-140 honoured:** `proacl` read BACK and asserted as the **whole string** — in-migration (a `DO`
block that RAISEs on any deviation, including over-reach that would strip `authenticated` or
`service_role`) and again in fixture 64 seq 11–15. All five now read exactly
`{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}`, the same convention fixture 18
seq 2 and fixture 60 seq 4 already pin for the v3 tier.

⭐ **Why the revoke could not strand the nightly (LAW 12):** crons **13** and **14** are the only automated
callers and both run as `username='postgres'`, the function owner — verified live, and pinned as fixture
64 seq 23. `grep -rn` over `src/` returns zero call sites for all five (one comment mention in
`SnapshotTab.tsx:645`), re-derived this leg per S-158 rather than trusted from the parking lot.

---

## leg 100 (2026-08-03) — S-172 step 1: the pre-flight refusal becomes legible on the FE's only commit path

| version          | name                                         | what                                                                        |
| ---------------- | -------------------------------------------- | --------------------------------------------------------------------------- |
| `20260803203229` | `prd110_s172_step1_atomic_preflight_legible` | `commit_refill_plan_atomic` gains a `preflight_failed` branch               |
| `20260803203403` | `prd110_s172_step1_fixture63_rebaseline`     | fixture 63 seq 52/53/54/55 re-pointed, seq 57/58/59 added (33 → 36 asserts) |

**What changed.** `stitch_pod_to_boonz` returns a rich `{status:'preflight_failed', violation_count,
violations[], warnings, invariant_versions, message}` payload when the plan FAILs under
`preflight_enforcement='block'`. That payload has **no `write_result` key**, so
`commit_refill_plan_atomic`'s generic guard reported only
`stitch write_result=null — rolling back (PRD-019 E2).` and discarded the invariant id, the offending
machine/shelf and the `fix_path`. The teeth were real (the commit rolls back, fixture 63 seq 50/51);
the recovery was not. A new branch, placed **before** the generic guard, RAISEs the payload instead.

Operator-visible message now (captured live from fixture 63, not composed by hand):

> `commit_refill_plan_atomic: PRE-FLIGHT REFUSED this commit (PRD-109 gate, preflight_enforcement=block). 1 invariant violation(s): INV-06. Nothing was written; the entire commit is rolled back. First violation [INV-06] machine=GRIT-1022-0100-W0 shelf=A07: expected children sum = parent qty 8, found children sum 7. FIX: Re-run the stitch for this machine; if it persists, inspect stitch_leakage for this plan_date. Full detail: SELECT * FROM public.preflight_refill_plan('2030-03-05'). NOTE: an audited single-use override (p_force plus a reason of at least 10 characters) exists on public.stitch_pod_to_boonz but is NOT reachable from this commit path yet (PRD-110 S-172 step 2); fix the violation above and re-commit.`

⭐ **Zero risk under the live flag, and that is provable rather than asserted.**
`preflight_enforcement` is still `'warn'`, and under `warn` `stitch_pod_to_boonz` never returns
`preflight_failed`, so the branch is **unreachable** until D-19 flips. `md5(prosrc)` moved
`56f14180 → 4237fbcc`; signature and `pronargdefaults` are unchanged (`0`), so no overload was minted.

⛔ **D-19 IS STILL NOT FLIPPED, DELIBERATELY.** Step 1 makes the refusal legible. **Step 2** — a
`p_force`/`p_force_reason` passthrough plus the FE affordance (Stax + a deploy) — is the real cost of
D-19, and only after it may `preflight_enforcement` go to `'block'`. Flipping now would arm a guard
and remove its escape hatch in one statement.

⭐ **The four tripwires did their job.** Fixture 63 seq 52/53/54/55 pinned the swallowed-refusal
behaviour **on purpose**; they went red exactly when step 1 landed. Seq 54 was additionally rebuilt
from a `prosrc` substring count to a **signature** test (`pg_get_function_identity_arguments NOT LIKE
'%p_force%' AND pronargdefaults = 0`) — the new message names `p_force` in prose, which would have
made the old detector report "step 2 shipped" when it had not. **S-173 generalises: a detector that
cannot distinguish is the defect, whether it reads permanently red or vacuously green.**

Fixture 63: **36/36 green on three consecutive runs**, and a fourth run moved
`refill_plan_output` (8160), `preflight_override_log` (11) and the fixture's own rows by **zero** —
idempotent.

---

## PRD-110 leg 101 (2026-08-03) — P4.5 scoreboard: five migrations, one of them written by a red fixture

| Version          | Name                                            | What it did                                                                                                                                                                                                                                                                                                                                                                             |
| ---------------- | ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260803205310` | `prd110_p45_scoreboard_daily_v3`                | `scoreboard_daily_v3` table + `compute_scoreboard_day_v3(date)` (DEFINER writer) + `v_scoreboard_daily_v3` (wide dashboard read) + `v_scoreboard_health_v3` (streak gate) + cron **47** `prd110_p45_scoreboard_daily_0245_dubai` (`45 22 * * *` UTC).                                                                                                                                   |
| `20260803205342` | `prd110_p45_scoreboard_grant_tighten`           | S-140 read-back fix: `authenticated` still held Supabase's default `arwdDxtm` on the new table. `REVOKE ALL` + `GRANT SELECT`.                                                                                                                                                                                                                                                          |
| `20260803205554` | `prd110_p45_scoreboard_composition_reachable`   | Reachability fix: `composition_confidence_avg` was gated on `= today Dubai` while cron 47 computes Dubai-**yesterday**. Window widened to `[today-1, today]`.                                                                                                                                                                                                                           |
| `20260803205921` | `prd110_p45_golden_fixture_65`                  | Golden fixture 65, 28 assertions.                                                                                                                                                                                                                                                                                                                                                       |
| `20260803205957` | `prd110_p45_scoreboard_engine_tag_null_safe`    | **Written because fixture 65 seq 10 went red on its first run.** See below.                                                                                                                                                                                                                                                                                                             |
| `20260803211714` | `prd110_p44b_spot_fill_v3`                      | **P4.4b Migration A.** `spot_fill_v3` — units bought at a shop and placed straight on a shelf, never through a warehouse (`pending` = physically on shelf, financially unreceived). 3 CHECKs, 2 FKs, 3 indexes, RLS + `authenticated` SELECT policy. ACL read back and asserted whole (S-178). Direct-to-machine per design D-E.                                                        |
| `20260803213141` | `prd110_p44b_post_facto_fill_phase1`            | **P4.4b Migration B.** `_resolve_open_walkin_po_v3` (PO-resolution rule lifted per D-F) + `receive_dispatch_line_sourced_v3` (the driver-facing `n from WH + m spot` split) + **one allowlist entry** in `enforce_canonical_dispatch_write`. ⛔ `receive_dispatch_line` NOT touched — phase 1 calls it with **n only**, so its line-112 overfill guard is never asked about spot units. |
| `20260803213638` | `prd110_p44b_procurement_event_type_post_facto` | `procurement_events.event_type` CHECK widened to admit `post_facto_fill_recorded`. **Found by the leg's own rolled-back happy-path probe, not by review.** ⛔ Reusing `spot_purchase_created` was rejected: it would make a post-facto shelf fill indistinguishable from a P4.4 warehouse spot buy.                                                                                     |

⛔ **THE THREE-VALUED-LOGIC TRAP, and it survived a Cody review.** `ck_scoreboard_engine_tag` shipped as

```sql
(metric_key = 'wmape' AND engine_tag IN ('v3','v19'))
OR (metric_key <> 'wmape' AND engine_tag IS NULL)
```

For an untagged `wmape` row that is `(TRUE AND NULL) OR FALSE` = **NULL**, and **a CHECK constraint
accepts a NULL result**. The one shape the constraint existed to forbid was the one shape it let
through. Rewritten as a `CASE` so the result is always TRUE or FALSE.

⭐ **The lesson is not "remember SQL trinary logic" — it is that the constraint READ correctly to two
reviewers and only a fixture that actually tried the forbidden insert found it.** Any CHECK whose
expression can evaluate to NULL is a CHECK that is off for exactly the rows you care about. Write the
adversarial INSERT, do not read the predicate.

⭐ Also caught by read-back rather than by review: Supabase's `ALTER DEFAULT PRIVILEGES` grants every
new `public` table to `anon` **and** `authenticated` at CREATE time. The migration's explicit
`REVOKE ... FROM anon` worked; `GRANT SELECT TO authenticated` did **not** reduce the default
`arwdDxtm` it already held. Only RLS stood between `authenticated` and INSERT/UPDATE/DELETE.
**On any new table: revoke, then grant, then read `relacl` back and assert the whole string.**

---

## leg 104 (2026-08-04) — D-42 executed: the commit/stitch tier grant sweep

| version          | name                                             | what                                                                     |
| ---------------- | ------------------------------------------------ | ------------------------------------------------------------------------ |
| `20260803215158` | `prd110_leg104_fixture66_d42_commit_stitch_tier` | golden fixture **66** (25 assertions) + `golden._acl_canary_public_66()` |
| `20260803215225` | `prd110_leg104_d42_commit_stitch_grant_sweep`    | `REVOKE EXECUTE … FROM anon, PUBLIC` on the five commit/stitch functions |

**LAW 1 held, and the baseline is the evidence.** Fixture 66 landed FIRST and ran **12 RED / 13 GREEN**
— red on exactly seq 4–15 (the grant assertions), green on every non-vacuity check, every body md5 pin
and the detector self-test. The sweep then turned it **25/25 GREEN**. Fixture 64 re-run **24/24**, so
the D-41 tier was not disturbed. Golden **55 → 56 fixtures, 1880 → 1905 assertions**.

⭐ **THE PRE-SWEEP RED IS WORTH MORE THAN THE POST-SWEEP GREEN.** Seq 9 read **4** before the sweep:
four of the five carried a PUBLIC grant that an `anon`-only revoke would have left in place. A fixture
written after the fix would have recorded 0 and proved nothing about what was actually there.

⛔ **CODY REQUIRED ONE REVISION AND IT WAS A REAL ONE.** The fixture's cron assertion was first written
fleet-wide (`zero active crons with username <> 'postgres'`), which goes red the day anyone adds a
legitimate non-postgres cron **anywhere**, for a reason unrelated to D-42. Split into seq 23
(tier-scoped: zero active crons whose command references any of the five — **diagnosable**) and seq 25
(fleet-wide, explicitly labelled as the one that can go red for an unrelated cause). **A tripwire that
fires on unrelated changes trains legs to dismiss it.**

⭐ **IN-MIGRATION VERIFY WENT BEYOND D-41's.** The sweep's `DO` block asserts the whole `proacl` string,
CS's literal acceptance test, `authenticated`/`service_role` survival **and** all five body `md5(prosrc)`
values, so the migration aborts if it is not the grant-layer-only change it claims to be. The scope
split is enforced by the migration itself, not only by the fixture that follows it.

## 20260803221105_prd110_p44b_receive_spot_fill_po_v3 (leg 105, 2026-08-04)

PRD-110 P4.4b **Migration C** — `public.receive_spot_fill_po_v3(text, jsonb, uuid, boolean)`, phase 2
of post-facto fill capture, plus a widening of `procurement_events_event_type_check` to admit
`'post_facto_fill_received'`. Built per `PRD-110-P4.4b-DARA-post-facto-fill-design.md` §4/§6/§8
(binding). One overload, SECURITY DEFINER, `search_path=public, pg_temp`, ACL read back as exactly
`{postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}` (S-140/S-178), role gate
`warehouse+` mirroring the incumbent `receive_purchase_order`.

⭐ **D-E PROVEN BY EXECUTION, NOT BY READING.** The function's complete DML inventory, extracted from
`prosrc` with full-line comments stripped, is exactly three statements: `UPDATE public.purchase_orders`,
`UPDATE public.spot_fill_v3`, `INSERT INTO public.procurement_events`. **Zero `warehouse_inventory`
DML.** ⛔ A naive `prosrc ~* 'warehouse_inventory'` returns TRUE and looks like a violation — the two
surviving mentions are string literals inside the returned JSON payload that document why no batch
exists. **Check the statements, not the substring.**

⭐ **THE EXPIRY PROPAGATION IS A RE-BUCKET, NOT AN ADD** — the single highest-risk defect in the unit
(§6: a phase-2 double-add). Phase 1 books the units into the **NULL** expiry bucket; phase 2 emits two
`record_inventory_event_v3` `'correction'` events (−qty from NULL, +qty into the receipt bucket) whose
deltas sum to zero, so shelf composition **totals are unchanged**. ⛔ `'correction'` is the only kind
whose `inventory_events_sign_by_kind` CHECK admits both directions (verified live: it falls through to
`ELSE true`). `shelf_composition_identity` is `NULLS NOT DISTINCT`, so the NULL bucket is a real
addressable bucket, not a hole.

⛔ **CODY REQUIRED TWO REVISIONS AND THE FIRST WAS A LIVE-DATA DEFECT, NOT A STYLE NOTE.** The PO-line
match originally filtered on `received_date IS NULL` alone. `cancel_po_line` sets
`purchase_outcome = 'not_purchased'` and **never stamps `received_date`** — measured this leg,
**13 production rows are in exactly that state right now**. A spot receipt could therefore have landed
on a **cancelled** line and flipped it back to `'received'`, resurrecting a line an operator
deliberately killed. Fixed by adding `AND COALESCE(purchase_outcome,'') <> 'not_purchased'` to both the
candidate count and the pick — the same predicate `_resolve_open_walkin_po_v3` already uses.
⭐ **This was found by querying the data, not by reading `cancel_po_line`'s source.** Second revision:
`total_price_aed` in the payload is now read back via `RETURNING` instead of recomputed, because the
price actually written may be the line's pre-existing one.

⚠️ **ARTICLE 8 GAP RECORDED, NOT INTRODUCED.** `purchase_orders` carries **no** `audit_log_write`
trigger (probed: zero), so the universal audit does not cover it — true of all **7** incumbent DEFINER
writers, of which this is now the 8th. The compensating control is `procurement_events` (RLS enabled),
which this migration writes. ⛔ Closing that gap touches 7 existing writers → PARKING-LOT (S-185), not
this unit.

⭐ **GUARDS PROVEN LIVE IN A ROLLED-BACK `DO` BLOCK**, not asserted: role gate refuses `role none`;
empty `p_lines`, blank `p_po_id` and unknown `po_id` each raise; a real `po_id` with an unknown
`spot_fill_id` reaches **inside the loop body** and raises there (so the loop and its Article 4 GUC
re-assert both execute). ⭐ On exit `current_setting('app.rpc_name')` read back **empty** — the S-160
capture/restore works, measured rather than argued. Zero residue: the probe raised to roll back.

⛔ **UNMOVED BY THIS MIGRATION:** `receive_dispatch_line` **28195f57** (the line-112 overfill guard,
byte-for-byte), all three gate md5s, `enforce_canonical_dispatch_write` **f87607a7**, every engine md5,
every flag, every cron. `purchase_orders` **1044**, `warehouse_inventory_status_proposal` **1148**,
`shelf_composition` **31**, `inventory_events` **50**, `spot_fill_v3` **0** — all unchanged, because
this migration created a function and widened a CHECK and wrote **no rows**.

---

## `20260803223550_prd110_p44b_golden_fixture_26` — PRD-110 P4.4b Migration D · golden fixture 26

**Applied** 2026-08-04 (leg 106) · server-assigned version · `prd110%` **269 → 270**, disk **270 → 271**
(the +1 remains S-31's retained `20260730203000`).

**What it adds.** One row in `golden.fixtures` (id **26**, `phase_required='P4'`, `plan_date` **2030-08-04**)
and **89** rows in `golden.assertions`. ⭐ **No function, table, trigger, flag, cron or engine was touched.**
`golden` **56 → 57** fixtures, **1905 → 1994** assertions.

**Why it exists (LAW 1 clause 2).** Migrations A/B/C shipped `spot_fill_v3`,
`receive_dispatch_line_sourced_v3` and `receive_spot_fill_po_v3`. This is the only thing that can close
the 2026-07-30 01:21 incident, and it is what closes it.

**⛔ THE CONTROL IS THE POINT.** seq 15-18 call the OLD path `receive_dispatch_line(d, 9)` on the same
shape and require it to STILL RAISE the overfill error, leave the line unreceived, and move no stock.
A fixture that only proves the new path works cannot tell you the guard survived. seq 14 pins
`receive_dispatch_line` at md5 **28195f57** so Cody's condition 1 goes red the moment anyone edits the
incumbent instead of composing it.

**What it proves, in one line each.** Split integrity (filled 9 = 1 WH + 8 spot, neither derived from
the other) · the 8 spot units reach `shelf_composition` immediately in the **NULL expiry bucket** via a
`spot_buy_receive` event · the PO line is raised and stays **UNRECEIVED** (Cody's recorded condition
made visible) · pod-level fallback vs enumerated breakdown · phase 2 is a **RE-BUCKET, not an add**, and
running it twice changes composition **not at all** (seq 51-52 — the difference between the feature and
a stock-inflation bug) · **zero `warehouse_inventory` rows** created by phase 2, asserted independently
of the RPC's own claim (seq 47-48, D-E) · 11 refusals each proven to FIRE · Article 4 GUC restore ·
**11 residue assertions**, three of them read LIVE at assertion time.

**Mechanism.** One plpgsql subtransaction ended by `RAISE EXCEPTION 'FX26_ROLLBACK'`; rows vanish,
plpgsql variables survive, assertions read `golden.scratch` written after the unwind. ⚠️ Burns **three**
`po_number_seq` values per run (sequences are non-transactional) because a **field_staff** caller always
MINTS — S-145, and that is precisely the property that stops this fixture attaching to and then
receiving a REAL open Carrefour PO.

**Cody: ⚠️ approve with revisions, both taken.** Articles 1, 3, 4, 6, 7, 8, 12, 14, 16 + LAW 12 / S-124.
(1) The scenario plants a `warehouse_inventory` batch — new this leg — and the residue payload carried
`'wh'` with **no assertion reading it**; phantom WH stock is pickable by the live FEFO binder within
minutes. Added seq 87 + a live independent read at seq 88. (2) `enforce_canonical_dispatch_write` LOGS
rather than blocks, so a plant that ever loses `app.via_trigger` accumulates `bypass_violation_log`
rows silently — baseline captured, delta asserted at seq 89.

**Article 6 ✅ narrowly:** the plant INSERTs a new batch with `status='Active'`; it never UPDATEs
`status` on an existing row, and it never commits.

**Verified.** Run **twice, committed** (S-136): **89/89 green both runs, zero errors, zero failing seqs.**
Live residue after both runs: `refill_dispatching` on 2030-08-04 **0**, `wh_location='FX26'` **0**,
`spot_fill_v3` note `FX26%` **0**.

⛔ **UNMOVED:** `receive_dispatch_line` **28195f57** · `receive_dispatch_line_sourced_v3` **91902266** ·
`receive_spot_fill_po_v3` **dd7f63ea** · `enforce_canonical_dispatch_write` **f87607a7** · every engine
md5 · all four flags · all seven crons · `spot_fill_v3` **0** · `purchase_orders` **1044** ·
`inventory_events` **50** · `shelf_composition` **31** · `procurement_events` **722** ·
`refill_plan_output` **8256** · `blocked_demand` **48** · `machines_to_visit` **1334** ·
`driver_tasks` **160**. **This migration wrote no row to any protected table.**

**Four landmines it discovered** (full detail in PARKING-LOT): **S-187** goal-command fixture ids ≠
`golden.fixtures` ids (4→41, 13→40, 25→50; 15 and 23 have no dedicated fixture) · **S-188**
`prevent_duplicate_unstarted_dispatch` forces one shelf per leg · **S-189** `quarantined` is GENERATED
from `provenance_reason`, so a plant without one is invisible to FEFO and fails with the same message as
having no stock · **S-190** `wh_fefo_for_line` judges shelf life against the LINE's date, so on a 2030
fixture date all real stock is expired and a fixture needing a WH debit must plant its own batch.

---

## `20260803231648_prd110_p4_golden_fixture_9` + `20260803231750_prd110_p4_golden_fixture_9_assert4_searchpath_truth` (2026-08-04, PRD-110 leg 108)

**Golden fixture 9 - the repack that froze a machine (NOOK-1019-0200-B1, 2026-07-20).** One
`golden.fixtures` row + **73** `golden.assertions`. No function, no RLS, no schema change, no protected
row committed. Golden **57 / 1994 -> 58 / 2067**. Closes the last item before the **P4 gate**.

**What the fixture pins.** The incident is **three** defects, not one, and all three are asserted:
**S-191** `repack_machine` admits `warehouse`, `push_plan_to_dispatch` does not, and repack calls push -
so the packing role starts a repack it cannot finish, with no savepoint: 2 rows returned, 1 plan row
reset, 0 fresh rows, then `push_failed` (seq 16-28). **S-192** `return_dispatch_line` stamps
`dispatched=true`, so the first repack's own returns permanently block every retry (seq 31-34).
**S-193, the worst:** as `operator_admin`, with every permission, repack returns `status='ok'` and
creates **zero** fresh rows; the returned row still holds the (machine, shelf, product, action, date)
key, so push moves 0 lines and re-stamps `dispatched=true` (seq 6-15). **S-196, the recovery:**
`log_manual_refill` asked for 10 units the warehouse lacks returns `ok`, writes all 10 to the pod,
decrements 0 and flags a shortfall - the property that saved NOOK by hand (seq 44-55).

⛔ **The fixture asserts the system AS IT STANDS, defects included.** D-43 (may `warehouse` repack at
all?) is open CS policy and nothing waits on it. **When the fix lands, seq 1-2 and 16-28 go red, and
updating them IS the proof it landed.** Do not loosen them.

**Cody: ⚠️ approve with revisions, taken.** Articles 1, 2, 3, 4, 6, 7, 8, 12, 13, 14, 16.
**Article 6 ✅ on evidence, not precedent:** probed live, the Article-6 enforcement trigger
`trg_detect_silent_warehouse_write` is **UPDATE-only**, and the fixture never UPDATEs `status` on any
row; `status` is also nullable with **no default** and `v_wh_pickable` requires `'Active'`, so omitting
the column was not an available alternative. **Article 3 ✅:** the plant carries `app.via_trigger` and
**clears it the moment the plant ends** (unlike the leg-107 draft), so the canonical-writer guard is
armed for every RPC leg rather than masked - seq 56 exists to prove exactly that.
**Required revision, taken:** S-197 recorded in the PARKING-LOT rather than fixed inline (LAW 10).

**S-197, found by running it.** A **no-op** `unskip_dispatch_line` leaves `app.via_rpc='true'` +
`app.rpc_name='unskip_dispatch_line'` set, and that name is on `enforce_canonical_dispatch_write`'s
allowlist - so the identical raw `UPDATE` that was logged as a bypass one statement earlier is
invisible one statement later (seq 56/57/58, proven by attempt with a control per S-177). Bounded to
one transaction (`is_local = true`). Same class for provenance at seq 62.

**Second migration = Article 12 in action.** Seq 4 went **RED on first run**: written by analogy with
fixture 26 seq 6/7 it expected `'search_path=public, pg_temp'`, but `repack_machine` pins
`search_path=public` with **no `pg_temp`**. Corrected by a **forward migration**, never an edit in
place. Fleet measurement behind it (**S-198**): of **332** public DEFINER functions, **105** pin
`pg_temp`, **196** pin `public` only, **22** pin nothing. Pre-PRD-110 and fleet-scale, so recorded and
not churned.

**Verified.** `golden.run_fixture(9, ..., 'P4')` **73/73 green, three consecutive runs.** Live residue
after all three: `refill_dispatching` on both 2030 dates **0** · `refill_plan_output` **0** ·
`wh_location='FX09'` **0** · `pod_inventory` for the machine **0** · `pod_inventory_audit_log`
`manual-refill-...-2030%` **0** · `bypass_violation_log` delta **0** (and the fixture deliberately
mints one control row, so that zero also proves the control rolled back). ⭐ **Burns no sequence** - no
PO is minted - so a run is completely inert.

**P4 gate re-run green this leg:** 9 (73) · 16 (31) · 17 (25) · 18 (80) · 20 (21) · 26 (89).

⛔ **UNMOVED:** `repack_machine` **d719d3c1** · `log_manual_refill` **c1f05b38** ·
`unskip_dispatch_line` **a1aabb24** · `push_plan_to_dispatch` **21371529** · `commit_refill_plan`
**ed4a3df6** · `stitch_pod_to_boonz` **806340b2** · `commit_refill_plan_atomic` **4237fbcc** · every
engine md5 · all four flags · all seven crons.

---

## 20260803233512_prd110_step7_stress_recorder (leg 109, 2026-08-04)

**STEP 7 opens.** First migration of the stress suite: one durable home for all seven suites'
verdicts. Creates `golden.stress_runs` + `golden.record_stress(...)`.

**Why a table and not a view (Article 14).** S3 and S5 are driven by genuinely parallel external
connections and S1/S2/S4/S6 record a measured wall-clock; **no view can derive either**. This is the
append-only-ledger shape Article 14 permits, not the snapshot shape it bans. No ADR required. ⛔ It
must never be used to cache something a view _could_ compute.

**Posture — matched, not invented.** The `golden` schema is `{postgres=UC/postgres}`: `anon` and
`authenticated` hold **no USAGE**, which is why `golden._acl_canary_public_64/66` exist. New table is
RLS ON, **zero policies, zero grants**, identical to the seven sibling tables.

**Cody-required revision, applied before apply (S-140):** a new function receives `EXECUTE` to
`PUBLIC` by default, so reachability rested on the schema-USAGE gate _alone_. Explicit
`REVOKE ALL ... FROM PUBLIC` added. Verified after apply: `proacl = {postgres=X/postgres}`, the
tightest sibling ACL. Function is **SECURITY INVOKER** (a DEFINER would have built a privilege bridge
into the harness for no gain) with `search_path = golden, public, pg_temp` - `pg_temp` **LAST**, per
S-198.

**Duration cannot be faked:** `record_stress` measures `p_started_at -> clock_timestamp()`
server-side rather than accepting a caller-supplied runtime.

**Verified:** `max(version)` **20260803231750 -> 20260803233512** · `prd110%` **272 -> 273** ·
table exists, `relrowsecurity=true`, **0 policies**, `relacl` NULL, 2 indexes, **exactly 1 overload**
of `record_stress` (⛔ the `repurpose_machine` foot-gun: any later leg changing these 9 args must
check `pg_proc` first, since `CREATE OR REPLACE` with a new signature silently overloads).

### `20260804000121_prd110_leg110_golden_fixture14_assert6_conservation` (PRD-110 leg 110)

Forward fix (**Article 12**) to `golden.assertions` (14, 6) — description + `check_sql`. No DDL, no
DEFINER, no RLS, no protected-entity write; `golden.*` is not in Appendix A.

The old predicate `composition total = capacity` on every over-capacity ("sensor lie") shelf
conflated _"the clamp fired at seed"_ with _"nothing has been consumed since"_. Shelf **A10** went
red on 2026-08-01 for a `derived_decrement` of **-3** that was entirely correct — its seed was
`+12`, exactly capacity, so the clamp had worked. Restated in **conservation form**: seed event =
capacity **AND** composition total = sum of all that shelf's `inventory_events`. Strictly stronger
than what it replaced. ⛔ Deliberately **not** weakened to `tot <= mx` — that is seq 8, fleet-wide,
and the two must not collapse.

**Cody required revision applied:** wrapped in a `DO` block with `GET DIAGNOSTICS`, raising unless
exactly **one** row is updated — Article 12's _idempotent_ half, against the S-193 class where a
statement reports success while changing nothing.

**Verified:** `max(version)` **20260803233512 -> 20260804000121** · `prd110%` **273 -> 274** ·
fixture 14 re-runs **49 / 0**.

---

## `20260804001959_prd110_leg111_golden_fixture24_selfsupply_s50_precondition`

**PRD-110 leg 111 · UNIT A · S-200 class (A), first of four.** Fixture 24's S-50 phantom-consumer
drain leg had gone **vacuous**: seq 29 borrowed its precondition from live fleet state, and the
fleet cleaned itself. All 40 sentinel `warehouse_inventory` rows are Active with
`warehouse_stock > 0` and `consumer_stock = 0`, so seq 29 (`gt 0`) went red on **2026-07-31** while
seq 30/32/33 stayed green for the worst possible reason — **0 = 0**.

**Remedy: self-supply the precondition** inside the fixture's own rollback probe (fixture 31's
proven idiom), planting the exact production shape S-50 found — phantom `consumer_stock` on a
stocked, Active sentinel. seq 29 and seq 32 re-pointed at the probe-measured count; **seq 35 NEW**
pins that the plant seeded exactly the 3 rows it asked for, separating "the drain is broken" from
"the scenario never got set up". ⛔ Nothing relaxed to `gte 0` — that is the S-48/S-52/S-55 vacuity
mode, already burned four times.

**Cody ⚠️ Approve with revisions.** Article 6 ✅ — the plant writes `consumer_stock`, never
`status`; both status-flipping triggers were checked rather than assumed and neither `WHEN` clause
can fire (`tg_propose_inactivate_on_zero_stock` needs BOTH stocks at 0; `tg_propose_reactivate`
needs `OLD.status='Inactive'`). Article 3 ✅ not engaged — `golden.run_fixture` is
`prosecdef=false` owned by `postgres`, so the harness is not writing as `authenticated`.
Article 1 ✅ not engaged — a rolled-back probe is not UI/edge/n8n/cron and persists no state.
**Required revision applied:** an explicit ⛔ comment forbidding a future reader from setting
`app.via_rpc` here — per **S-197** that would leave the canonical-writer gate open for the rest of
the transaction, masking the very drain and retirement calls the fixture exists to prove.

⚠️ **Raised, not churned (LAW 10):** `authenticated` holds `INSERT, UPDATE, DELETE, TRUNCATE` on
`public.warehouse_inventory` — Article 3's REVOKE enforcement clause is unsatisfied on a protected
entity. Pre-existing, distinct from D-41/D-42 (those were function EXECUTE grants). See **S-202**.

**Verified:** `max(version)` **20260804000121 -> 20260804001959** · `prd110%` **274 -> 275** ·
fixture 24 **42 / 0** — and green **earned, not vacuous**: `planted=3 · probe_rows=3 · drained=3 ·
units=21 · consumer_after=0 · audit_rows=3 · stranded=0 · retired=40`. Residue nil: live sentinel
`consumer_stock` back to **0**, 40 still Active, `wisp` unchanged at 1148, and **zero**
`bug001_silent_reactivation` alerts (the 9 alerts in the window are ambient crons stamped before
the migration).

⭐ **Runner fact confirmed by the first attempt's failure:** the migration body is applied in ONE
transaction. A PK collision on the seq-35 INSERT (34 was already taken) rolled the whole body back —
`prd110%` stayed 274 and `scenario_sql` was untouched. Fail-loud worked exactly as Cody specified.

---

## `20260804002428_prd110_leg111_golden_fixture40_ab_contrast_network_wide` + `20260804002451_..._crossref_fix`

**PRD-110 leg 111 · UNIT B · S-200 fixture 40 seq 8 — and a CORRECTION TO S-200's OWN CLASSIFICATION.**

S-200 filed 40/8 as class (A) ("ambient non-vacuity gone vacuous", remedy = rollback probe).
Measured live, **that classification is wrong and the probe would have been the wrong tool**:

| anchor           | real_primary | real_other | sentinel |
| ---------------- | ------------ | ---------- | -------- |
| A (Fade Fit)     | 0            | **0**      | 7992     |
| B (Vitamin Well) | 0            | **88**     | 0        |

B's real stock did **not** evaporate — it **moved out of the machine's primary warehouse**.
seq 8 was pinned to ONE warehouse, so a routine inter-warehouse transfer turned it red while the
fact it exists to prove stayed true throughout. This is class **(B)** (re-express the relationship),
not class (A). A plant would have seeded supply that already exists, proving nothing.

**Fix:** seq 8 restated network-wide (`B_real_primary + B_real_other >= 1`) using scratch keys that
already existed — no `scenario_sql` change. **seq 57 NEW** pins the other half of the contrast
(`A_real_primary + A_real_other = 0`), which was only ever half-covered by seq 7; without it seq 8
could go vacuous in the opposite direction. ⛔ Threshold stays `>= 1` — only the SCOPE widens.
⛔ The **description** was corrected too, not just the SQL: with 88 units at an alternate WH,
"blocked by contention" is no longer true, and carrying a stale narrative under a passing assertion
is exactly how the "fully green" claim survived ~25 legs.

**Cody ✅ Approve** (class (f), `golden.*` not in Appendix A). Article 12 ✅ forward-only +
`GET DIAGNOSTICS` on the UPDATE. Ruled a **strengthening**: discriminating power is preserved
because seq 57 proves anchor A still FAILS the same test at 0.

**Verified:** fixture 40 **57 / 0**, non-vacuous — `A_network = 0` (sentinel 7992) ·
`B_network = 88` (sentinel 0). Both assertions bite.

⛔ **`_crossref_fix` (20260804002451):** seq 8's description shipped saying "Paired with seq 43"
when the assertion landed at seq 57. Corrected forward rather than left as a harmless typo — a
wrong cross-reference is the same stale-narrative defect S-200 is about.

⚠️ **SEQ-PICKING LESSON, paid for TWICE this leg (fixture 24 and fixture 40):** both failed applies
came from reading a **FILTERED** assertion list and inferring the gap. Fixture 24 is 1..34 + 90 +
94..99; fixture 40 is 1..56 contiguous. ⭐ **Always take `max(seq)+1` from an UNFILTERED query.**
The bare INSERT (no `ON CONFLICT`) caught it both times, and the single-transaction migration body
rolled everything back — fail-loud working exactly as Cody specified.

---

## `20260804004215_prd110_leg112_f2_seq27_floor_selfsupply_probe`

PRD-110 leg 112 · S-200 red set · **fixture 2 seq 27 CLOSED** (class (A), re-derived live).

**The cause, measured rather than inherited.** `v_shelf_instock_velocity_v3` emits only `ok` (525)
and `out_of_canonical_scope` (143). `below_floor` = **0**. The branch is NOT dead code: it needs
`si.machine_id IS NOT NULL` AND `stock_hours < 48`. There ARE **19** real sub-floor series live —
but every one is `out_of_canonical_scope`, so its `velocity_instock` is NULL for a **second** reason
(`units_30d IS NULL`). Minimum in-scope `stock_hours` is **71.9996**, just above the floor.

⛔ **THIS IS WHY THE CLASS-(B) REMEDY WAS REJECTED HERE.** Restating seq 27 fleet-wide ("no sub-floor
series receives a velocity") is satisfied on all 19 **without the floor ever being the operative
denier** — a green-at-zero in disguise, i.e. the S-48/S-52/S-55 vacuity mode. S-200 filed 2/27 as
class (A) and live measurement **confirms** it. ⭐ Independent corroboration from
`METRICS_REGISTRY` line 46: the recorded leg-20 distribution was **ok 517 · below_floor 8 ·
out_of_canonical_scope 162**. The branch was genuinely populated then. It decayed.

**Remedy — fixture 31 / fixture 24 rollback-probe idiom.** Plant one chronically-empty shelf
(`A99`, `currStock 0`) into the **last two** `weimi_device_status` snapshots of the eligible machine
`USH-1008-0000-W1`, measure into variables, `RAISE EXCEPTION '22023'`, swallow. The **latest**
snapshot is what puts the series into `v_live_shelf_stock` → `v_shelf_sales_identity` (canonical
scope); the **second-latest** supplies the interval whose `t_i` carries stock 0, driving
`stock_hours` to **0** via case A rather than NULL. Product `Al Ain Water 1.5L` — unique name,
direct tier-1 match, not on that machine, zero sales there in-window.

**Cody ⚠️ Approve with revisions.** Appendix A ✅ not engaged (`weimi_device_status` is not
protected). Article 3 ✅ — `golden.run_fixture` is `prosecdef=false` owned by `postgres`.
Article 6 ✅ untouched. Article 8 ✅ — `app.via_rpc` deliberately unset (S-197). Article 16 ✅ — the
probe **reads** the canonical velocity object and re-implements the floor nowhere.
⛔ **Required revision applied:** `METRICS_REGISTRY` line 46 states verbatim that _"fixtures must
record the anchor they ran against"_ — this view's `t_anchor` is deliberately moving, so a future
red would be unattributable. `t_anchor` + `floor_hours` added to the payload.
⚠️ Recorded: `weimi_device_status` is the n8n sync target; the probe holds row locks on 2 rows.
Keep the plant at two rows, never widen.

**Verified — fixture 2 `54 / 0`, and the green is EARNED, not vacuous:**
`planted=2 · floor_before=0 · floor_after=1 · floor_delta=1 · status=below_floor ·
stock_hours 0.0000 < floor_hours 48.0 · vi_is_null=true · sh_under_floor=true ·
t_anchor 2026-08-03 22:00:40`. Residue nil: `below_floor` back to 0, machine back to 16 slots,
zero `A99` rows, `inventory_events` 50 and `shelf_composition` 31 unchanged.
`weimi_device_status` carries **no triggers** (verified), so nothing can escape the rollback.

## `20260804004705_prd110_leg112_f2_seq64_alias_family_conservation`

PRD-110 leg 112 · S-200 red set · **fixture 2 seq 64 CLOSED** (class (B), re-derived live).

Measured live: `split_family` **24** · `shelfstate_family` **24** · `split_raw_key` **0** ·
`split_total` **544**. The pin was `eq 26`, the fleet on the day the S-37 fix landed
(`METRICS_REGISTRY` line 229: _"family 26, 24 recover velocity, the 2 that stay NULL are
AMZ-1046 (D-13)"_). ⭐ **The split view and `v_shelf_state` AGREE at 24 and `split_total` is still
exactly 544 — nothing in the build moved.** Two alias shelves left the eligible fleet. Class (B)
confirmed; the photograph aged while the fact stayed true.

**Remedy (fixture 40's idiom):** seq 64 → non-vacuity `gt 0` (the same POSITIVE form seq 27-31 use —
⛔ NOT a relaxation to `gte 0`), plus **seq 102 NEW**, the conservation half seq 64 never covered:
the split view carries exactly the alias-family shelves `v_shelf_state` carries. That is what
actually catches an S-37 regression, and both sides move together under fleet turnover.
⛔ **The pair must move together — seq 102 alone is satisfiable on 0 = 0.**

⚠️ **PERF drove the shape (S-26 / RISK 88):** `v_shelf_instock_velocity_split_v3` costs ~20 s per
evaluation and machine-scoping does not reduce it. The migration therefore **extends the existing
single read** of `s` via `replace()` rather than adding a second read; `v_shelf_state` (~113 ms) is
free to pull in. ⛔ A `replace()` that misses is **silent**, so the body carries a fail-loud
`DO` guard asserting the needle landed — the body is one transaction, so raising costs nothing.

**Cody ✅ Approve** (class (f)). Article 16 ✅ — both new counters read canonical objects.
**Verified:** fixture 2 **54 / 0**, earned: `family 24 · family_state 24 · delta 0 · raw_key 0 ·
v1_rows 544`.

## `20260804010212_prd110_leg113_f59_seq25_26_realloc_rederive`

**PRD-110 leg 113 · S-200 red set · fixture 59 seq 25 + 26 (class (B), re-derived live).**
`golden.*` only — 2 assertion bodies restated, 3 added. No DDL, no DEFINER, no RLS, no cron, no
protected entity, no engine md5 moved.

**Why they were red:** seq 25 `reallocation.fixture_unmatched` pinned `eq 18` -> actual **33**;
seq 26 `fixture_undecided` pinned `eq 6` -> actual **11**. ⭐ Fixture 59 plants **nothing** into
`reallocation_proposals_v3`; that family is ambient, and it is **append-only, grown by FIXTURE 11**
(P3.8 freed-unit re-offer, which does not reclaim). Measured: 44 rows · 11 distinct `base_run_id` ·
33 `unclaimed` + 11 `proposed` == 11 runs x (3 + 1). **18/6 was the photograph at 6 runs.**
⛔ Bumping 18 -> 33 would re-arm the same trap for run 12 (**S-204**).

**Fix:** re-express the RELATIONSHIP the prose always claimed. seq 25/26 now equate the AFTER
scratch snapshot against a live re-derivation off `reallocation_proposals_v3` (`status='unclaimed'`
/ `status IN ('pending','proposed')`, scoped `>= g12_fixture_epoch`). New **seq 51/52** are `gt 0`
non-vacuity partners; new **seq 53** states disjointness outright
(`undecided + unmatched <= fixture_rows AND undecided < fixture_rows`).

⛔ **Nothing relaxed to `gte 0`** (the S-48/S-52/S-55 mode). Negative control: remapping
`unclaimed -> undecided` now fails **four** assertions where the old pair caught one.

⚠️ Deliberately **not idempotent** — the bare `INSERT` on 51/52/53 raises on re-apply, and the
fail-loud `DO` guard aborts before it. The body is one transaction, so a raise costs nothing.
⚠️ **Apply-time version drift:** MCP recorded `20260804010212`; the disk file was renamed from
`20260804012000` to match, so DB and disk agree.

**Cody ✅ Approve** (fast-path class (f)). Article 12 ✅ forward-only (harness data). Article 16 ✅ —
`v_proposal_acceptance_v3` remains the canonical object. **Verified: fixture 59 `53 / 0`**, earned
(`25=true · 26=true · 51=33 · 52=11 · 53=true`).

## `20260804010644_prd110_leg113_f55_seq25_26_declared_date_sweep`

**PRD-110 leg 113 · S-200 red set · fixture 55 seq 25 + 26 (class (D)).** `golden.*` only — 2
assertion bodies restated, 4 added. The bodies READ `refill_plan_output` / `pod_refill_plan`
(Appendix A) but the migration writes nothing outside `golden.*`.

**Why they were red:** rpo 2030+ pinned `eq 21` -> actual **26**; prp pinned `eq 9` -> actual **11**.
⭐ The overshoot is **exactly fixture 63's own legitimate plants**, and all three 2030 dates
(2030-01-11 fx10, 2030-02-03 fx33, 2030-03-05 fx63) are **declared** `golden.fixtures.plan_date`
values. No residue at all. ⛔ Bumping 21 -> 26 re-arms the same trap for fixture 67.

**Fix:** restate the S-124 fleet sweep as **ownership** rather than cardinality — count 2030+ rows
whose `plan_date` matches no `golden.fixtures` row, expect **0**. New **seq 27/28** are `gt 0`
non-vacuity partners; **seq 29** pins the LAW-12 carve-out (2099+ set = exactly 9 rows, all on
machine `a6c02486-5d95-42ca-9adc-bc755c3019d3`) so the exclusion cannot become a hiding place;
**seq 30** proves the prp carve-out term is inert (zero 2099+ prp rows).

⛔ **LAW 12** — the nine pre-PRD-110 `2099-12-*` rows are left untouched and carved out explicitly by
machine AND date. ⚠️ S-200 listed only 2 of their 8 comment prefixes; all 8 are recorded in the
migration header. No `golden.fixtures` row declares any 2099 date (verified: 0).

⚠️ Deliberately **not idempotent** (bare `INSERT` + fail-loud `DO` guard). ⚠️ Apply-time version
drift: MCP recorded `20260804010644`; disk file renamed from `20260804011500` to match.

**Cody ✅ Approve** (fast-path class (f)). **Verified: fixture 55 `30 / 0`**, earned
(`25=0 · 26=0 · 27=26 · 28=11 · 29=true · 30=0`).

## `20260804013427_prd110_leg114_f8_seq26_29_selfsupply_empty_shelf`

PRD-110 leg 114 (written) / leg 115 (verified + applied). **Fixture 8 seq 26/29 - the last member
of the S-200 red set.** ⚠️ **Written by an aborted leg 114 that died before applying it**; leg 115
found the file on disk with no matching row, re-derived every premise live, and adopted it (S-206).

`golden.*` only: fixture 8's `scenario_sql` gains a **plant/restore pair** around the engine call,
its `eng` payload gains the `floorful` witness, and assertions **32-35** are added. The plant sets
ONE integer (`currStock` 3 -> 0) on ONE aisle (WEIMI `showName` **A7** = `shelf_code` **A07**, zero-pad
law) of ONE `weimi_device_status` snapshot row, then restores the banked `door_statuses` **wholesale**
and pins byte-equality.

⛔ **Why WEIMI and not `warehouse_inventory`:** S-203 prescribed a near-expiry WH plant; **S-205
proved it a NO-OP** - fixture 8's `plan_date` is 2030-01-09 and every real batch expires 2026-2027,
so `expiry_days` is already 0 on all 32 lines and the ceiling already 0 on all 20 WH lines. The
missing ingredient was `floor_units > 0`, which needs an **EMPTY SHELF**. ⭐ **That correction is
what kept the unit clear of a protected entity entirely.**

⭐ **S-208:** residue is impossible via any error path - `golden.run_fixture` runs the scenario in a
plpgsql subtransaction (`EXCEPTION WHEN OTHERS`), verified from `pg_proc`, not assumed.

⚠️ Deliberately **not idempotent** (bare `INSERT` + fail-loud `DO` guard; a re-apply raises on the
`$fx8plant$` count and rolls back the single-transaction body). ⚠️ Apply-time version drift: MCP
recorded `20260804013427`; disk file renamed from `20260804020500` to match.

**Cody ✅ Approve** (Articles 1, 2, 3, 6, 7, 8, 10, 12, 14, 16; `weimi_device_status` is **not** in
Appendix A, verified against the constitution's own list). **Verified: fixture 8 `23 / 0`**, earned
(`26=0 · 28=20 · 29=1 · 32=1 · 33=0 · 34=true · 35=1`), residue disproven off live WEIMI.

## `20260804013910_prd110_leg115_f48_excluded_leak_use_snapshot_s201`

PRD-110 leg 115. **S-201: fixture 48 timed out (57014) and therefore READ AS GREEN while its 49
assertions never evaluated.** `golden.*` only - the two `excluded_leak` joins now read the fixture's
own step-(2) `f48_perf` snapshot instead of re-reading the live 23.6 s `v_facing_performance_v3`.

⭐ **Not a loosening:** `f48_perf` is `SELECT *` from that same view, materialised in the same
transaction. ⭐ **Measured 119.8 s -> 71.1 s (-48.7 s)** from `golden.runs`; **fixture 48 = 49 / 49**.

⛔ **S-209 (parked):** the residual cost is NOT in the harness - `propose_facing_changes_v3` line 39
re-materialises the same 23.6 s view on **every call** and fixture 48 calls it twice. That needs its
own Dara/Cody unit and bears on **S1**.

⛔ **The fix has a second half that is not a migration:** at 71.1 s fixture 48 still exceeds the ~57 s
default `statement_timeout`, so **a runner that does not raise it will keep scoring a silent green**.
`/tmp/prd110_s7.sh` does NOT set it; `/tmp/prd110_sweep.sh` does.

Fail-loud `DO` guard: exactly 1 surviving live-view mention, step-(2) snapshot intact, 2 rewritten
joins, creation ordered before use. **Cody ✅ Approve** (fast-path class (f)).

## `20260804020719_prd110_leg117_stress_s6_blocked_demand_volume` (leg 117)

PRD-110 STEP 7 / **S6 — blocked_demand volume**. Adds `golden.stress_s6_v1(p_n, p_record, p_note)`,
INVOKER, `search_path = golden, public, pg_temp`, `REVOKE ALL ... FROM PUBLIC`. `golden.*` only —
**no fixture and no assertion added** (S1–S6 stay out of `golden.fixtures` on purpose, or S7 would
measure itself).

Plants `p_n` (default 500) distinct open `blocked_demand` rows inside a plpgsql subtransaction that
**always ends in RAISE**, so it is rolled back on the success path and on every error path alike;
plpgsql _variables_ survive the rollback while rows do not, which is the whole mechanism. Asserts 16
properties of `v_blocked_demand_open` and RAISES if a single planted row survives.

⛔ **Why not the reserved 2030-11-06 date:** `v_blocked_demand_open` carries
`AND bd.plan_date < '2030-01-01'` — it deliberately excludes the synthetic band, so a 2030 plant
yields **zero** view rows and passes **vacuously**. The guard is not relaxed; the probe moves to real
dates instead. ⛔ **Offsets (`CURRENT_DATE - off`), never absolute dates** — an absolute date would
make the assertion true only on the day it was written (S-200 / S-213).

⛔ Load-bearing constraint the design did not have: `uq_blocked_demand_open` UNIQUE
`(plan_date, machine_id, shelf_id, pod_product_id, source) WHERE resolved_at IS NULL`. The plant
draws 500 distinct triples from 1369 available and anti-joins live open rows on that exact key, so
it can never contend with production on any date.

**Measured (dry-proof and shipped run identical):** inserted 500 · view_planted 500 · view_planted_d
500 (no fan-out) · view_total 520 = 500 + 20 pre-existing · buckets fresh 80 / watch 97 / aging 171 /
critical 152 (sum 500) · bucket_mismatch 0 · age_days_mismatch 0 · edges 2→fresh 3→watch 6→watch
7→aging 13→aging 14→critical · leak_2030 0 · **bd 44 → 44, residue 0**. `stress_run_id` 55c12f45,
**16 pass / 0 fail**.

**Cody ✅ Approve** (Articles 1, 2, 3, 4, 8, 12, 14, 16). `blocked_demand` is **not** in Appendix A —
verified against `01_constitution.html` itself (0 occurrences; absent from the Core-entities list),
so the direct INSERT engages neither Article 1 nor Article 3. `tg_audit_blocked_demand`'s 500
`write_audit_log` rows roll back with the probe. Article 16: the inline `age_bucket` re-derivation is
the _independent_ check of the canonical object and is deliberate — reading the view's own bucket to
verify the view's bucket would be tautological.

⚠️ Apply-time version drift, **sixth consecutive leg**: file `…021500`, DB recorded `…020719`; disk
renamed to the DB version.

---

### `20260804024500_prd110_leg118_f42_seq60_selfsupply_cadence_precondition` (PRD-110 leg 118)

**What:** fixture 42 self-supplies the `|breached| < capacity` precondition that seq 60 — the CS
D-24 acceptance test — silently presupposed, plus the D-44 live sensor. `golden.*` scenario edit +
9 new assertions (68–76). **Closes the sole Law-8 blocker; golden 58 / 2094.**

**Mechanism:** the scenario banks `var_cadence_floor_multiple` / `var_cadence_hard_max_days`, plants
values DERIVED from the fleet (`GREATEST(dsv/gap of M_CAD, live)` and `GREATEST(max(dsv)+1, live)` —
both clamps make it a **tightening only**), runs the read-only picker, then restores byte-identical
and verifies twice (seq 75 asks the restore block, seq 76 asks the table). Placement is the whole
design: `'pop'` is snapshotted BEFORE the plant (so seq 56/57 still pin the live 2.0/14 defaults and
`'pop'` doubles as the D-44 live sensor), while `'breach'` and the picker both run AFTER it (so seq
62 stays a real cross-check). `pg_advisory_xact_lock(1100042)` serialises the borrow.

**Evidence:** fixture 42 **76/76, 0 fail, 105 s**, `scenario_error` null. seq 60 true · 34 true ·
35 true · 62 = 0 · 56/57 true · 39 = 24 · 63 = 18. New sensors: 68 = 1 · 69 true · 70 true · 71 = 1 ·
**72 = 11 (`breached_live`)** · **73 = 5 (`eff_cap_model`)** · 74 true · 75 true · 76 true.
Params verified back at 2.0 / 14; all 17 gate md5s unchanged; `machines_to_visit` unmoved (seq 48).

**Cody ✅ Approve** (Articles 1, 2, 3, 4, 6, 7, 8, 12, 14, 16). `refill_policy_params` is **not** in
Appendix A (RLS on, 2 policies, **0 triggers**), and the only reader of those two columns anywhere in
the database is `rank_machines_by_value_at_risk_v3` itself — STABLE, SECURITY INVOKER, writes nothing
(seq 51). Direct precedent: `golden.probe_stitch_under_mode` (leg 98) already forces and restores a
different column of the same table. Article 16 ✅ — the visit clock is read from
`v_machine_health_signals`, the canonical object at METRICS_REGISTRY line 49. Cody raised **S-217**
(`authenticated` holds INSERT/UPDATE/DELETE on `refill_policy_params`) and parked it, out of scope.

⛔ **seq 60 was NOT loosened** — a guard in the migration refuses to apply if its `check_sql`,
`expect_op` or `expect` ever moves.

### `20260804025000_prd110_leg118b_f42_restore_orphan_insert_header_fix` (PRD-110 leg 118b)

**What:** forward-only correction (Article 12) of leg 118. Its restore needle matched only the
`SELECT ... 'mtv_after' ...` line while the payload re-emitted the whole statement including the
`INSERT INTO golden.scratch (fixture_id, key, value)` header, leaving the original header dangling
in front of the injected `DO` block → `syntax error at or near "DO"`. Removes the orphan and adds
the SYNTAX invariant the leg-118 shape guard could not express: every scratch INSERT header must be
followed by `SELECT` or `VALUES` (implemented by splitting on the literal header — **not** a regex;
the header contains parentheses and hand-escaping them is how the guard failed on its first apply).

⭐ **No apply-time version drift this leg — the first in seven.** Both migrations were applied
through the `prd110_sql.sh` shim, which **S-215 proves is transactional**, with the
`schema_migrations` row inserted explicitly afterwards; the disk filenames therefore match the DB
versions exactly by construction rather than by post-hoc rename.

## `20260804030000_prd110_leg119_stress_s1_full_fleet_shadow` (leg 119)

PRD-110 STEP 7 / **S1 — full-fleet shadow run**. Adds `golden.stress_s1_v1(p_plan_date, p_days_cover,
p_record, p_note)`, INVOKER, `search_path = golden, public, pg_temp`, `REVOKE ALL ... FROM PUBLIC` —
the same posture as leg 117's `stress_s6_v1`. `golden.*` only: **no fixture and no assertion added**
(S1–S6 stay out of `golden.fixtures` or S7 would measure itself).

Plants the whole `include_in_refill AND status='Active'` fleet onto the reserved synthetic date
2030-11-01, fires `run_nightly_shadow_v3(pd, 7, 0, note)` with `p_settle_limit => 0` (S-199), and
measures only the `run_id` generation the run itself minted. **16 assertions**, all green.

⛔ **NOTHING IS CLEANED ON ENTRY, AND THAT IS DELIBERATE.** `pod_refills_shadow` carries
`tg_pod_refills_shadow_append_only` (ADR §5.1) and `shadow_runner_log_v3` carries `tg_srl_v3_no_update`,
so a clean-on-entry S1 would refuse on its own second run and could never be re-run. S1 uses the
**bank-and-diff** idiom instead: bank the `run_id` set and the `shadow_runner_log_v3` id watermark
before the run, measure the delta after.

⭐ **Cody ⚠️ Approve-with-revisions, and the revisions were the substance of the leg.** The staged
draft raw-`DELETE`+`INSERT`ed `machines_to_visit`. That table is absent from `01_constitution.html`
(0 occurrences) but `RPC_REGISTRY.md` designates it protected in three entries, names a canonical
writer set, and carries a **standing Cody condition** (RPC_REGISTRY:1214) that the first consumer
turning a ranking into a `machines_to_visit` row is a new class-(b) review. This is that consumer.
The plant was rewritten onto `pick_machine_manually(plan_date, machine_id, reason)` — DEFINER,
service-role bypass on NULL `auth.uid()`, sets `app.via_rpc` + `app.rpc_name` (Articles 4 and 8),
upserts on `(plan_date, machine_id)`. **S1 now issues no raw SQL against any plan table**, and
because the RPC upserts, the clean-on-entry DELETE was removed outright.

⛔ **A SPEC CORRECTION THE STAGED DRAFT GOT BACKWARDS.** Its comment claimed `engine_add_pod_v3`
"reads neither `confirmed_at` nor `is_included`". Measured live: the engine **does**
`PERFORM public._assert_gate_zero(p_plan_date)`, which raises `check_violation` on any row with
`status='picked' AND confirmed_at IS NULL`. A `'picked'` plant that forgot the confirm would be
refused as `blocked_gate0`. `pick_machine_manually` writes `status='cs_added'` + `confirmed_at`, so
the gate-zero predicate cannot match at all — LAW 11 honoured by the real manual path, not simulated.
Assertion 16 pins it (`gate0_no_unconfirmed_picks = 0`).

**Measured, `stress_run_id` `ded9fb1e`, 16 pass / 0 fail:** runtime **36 717 ms** against a 600 000 ms
budget (**6 %**) · zero `status='error'` steps · summary/engine/measure all `ok` · fleet 31 = planted
31 = machines_covered 31 · shelf scope 656 · **544 shadow lines**, exactly **1** new `run_id` · 161
units · `no_unexplained_qty0` **0** · `no_null_keys_in_output` **0** · ADR §8 obligation-3 tripwire
`pod_refills` 3955→3955, `pod_refill_plan` 6572→6572, `refill_plan_output` 8256→8256 (**re-verified by
an independent read after the run**, leg-118's verify-twice idiom) · live `2026-08-04` untouched at 96.

⭐ **NO APPLY-TIME VERSION DRIFT — the second consecutive leg.** Applied with `/tmp/prd110_sql.sh`
(S-215, transactional) and the `schema_migrations` row inserted explicitly, so the filename matches
the DB by construction. `prd110%` 286 → **287**.

---

## `20260804040000_prd110_leg120_stress_s4_pipeline_chaos` (leg 120)

PRD-110 STEP 7 / **S4 — pipeline chaos**. Adds `golden.stress_s4_v1(p_plan_date, p_days_cover,
p_runs, p_promote_blocked, p_record, p_note)` and its helper
`golden._s4_input_fingerprint(p_plan_date)`, both INVOKER, `search_path = golden, public, pg_temp`,
`REVOKE ALL ... FROM PUBLIC` — the posture of `stress_s1_v1` and `stress_s6_v1`. `golden.*` only:
**no fixture and no assertion added**, and no RPC or metric, so `RPC_REGISTRY` and
`METRICS_REGISTRY` are untouched.

Plants the whole `include_in_refill AND status='Active'` fleet onto the reserved synthetic date
2030-11-04 through `pick_machine_manually`, then fires **`run_pipeline_v3` three times** in one
transaction. **33 assertions**, all green.

⛔ **THE LEG-109 DRAFT (`docs/prds/PRD-110-S4-scenario-DRAFT.sql`) WAS NOT SHIPPED — IT CANNOT RUN.**
S-221 named five fatal flaws and leg 120 re-measured every one. The load-bearing correction is the
target: the draft fires `run_nightly_shadow_v3` (engine + measure + settle), which exercises **one**
engine and never touches the stitch ladder. "Every engine" is **`run_pipeline_v3`**, measured to
chain **four** objects — `engine_add_pod_v3` → `compose_plan_with_edits_v3` → `stitch_v3` →
`record_blocked_demand_v3`. The other four: a clean-on-entry `DELETE` that the append-only triggers
refuse with 42501 (bank-and-diff instead); `min(created_at)` on a table with no `created_at`; a raw
`INSERT` into `machines_to_visit` (Cody's leg-119 ruling); and being written as a golden fixture,
which would make S7 measure itself.

⛔ **"IDEMPOTENT" MEANS CONTENT EQUALITY PER `run_id`, NEVER ROW-COUNT STABILITY (S-199).** Each
engine mints `gen_random_uuid()` per call with no DELETE and no ON CONFLICT, so three runs
legitimately produce three generations — 6 new `run_id`s in `pod_refills_shadow` (3 engine + 3
compose) and 3 in `refill_plan_output_shadow`. S4 asserts three md5 content fingerprints are
identical across generations; an S4 asserting "row count unchanged" would go red against correct
behaviour.

⛔ **A SUBSET PLANT IS VACUOUS ON THIS DATE, AND THE DRY RUN PROVED IT.** With the three lowest
machine_ids the engine wrote 64 lines but `units_planned = 0`, so compose dropped all 64,
`run_pipeline_v3` returned `composed_empty`, and **stitch never ran**. The engine's ~34 s is fixed
view-materialisation cost regardless of fleet size, so a subset saves nothing. Assertion 17 pins
`machines_covered = fleet` so a future shrink cannot pass unnoticed.

⭐ **Cody ⚠️ Approve-with-revisions; both revisions changed the shipped file.**
**(1)** The blocked-demand tripwire took a **global** `count(*)`, which PARKING-LOT:5757 rules out by
name and which **cron 43** (`prd110_p05_blocked_demand_2015_dubai`, `15 16 * * *` UTC) can move for
reasons unrelated to S4 — rescoped to `(plan_date, source)`, with the global pair kept as a metric.
**(2)** The header claimed the runs "read ONE snapshot". **They do not:** PostgreSQL defaults to READ
COMMITTED, so every statement takes a fresh snapshot and one transaction is **not** one snapshot. A
function cannot raise its own isolation level, so the claim was corrected and backed by an
**input-drift sentinel** (assertion 33): `_s4_input_fingerprint` hashes `shelf_composition` in full
(cron 44 rewrites it hourly at :40) and row-count-pins the rest of the input surface, taken after
the plant and again after the last run. A red 33 means the generations are _allowed_ to differ.
⭐ The sentinel earned itself immediately — its first dry run went red because the baseline was
captured **before** the plant, so the suite's own 31 `machines_to_visit` rows read as drift.

📌 **Article 16 nit, recorded not blocked:** the fleet predicate is inlined rather than read from
`v_active_fleet`. `v_active_fleet` is deliberately broader (`status NOT IN (Inactive, Warehouse)`)
than the engine's own scope (`Active AND include_in_refill`, per `v_shelf_state`); mirroring the
engine is what keeps assertion 17 from comparing two populations. Same posture as the approved S1.

⭐ **`p_promote_blocked => true` IS NOT AN EXECUTION OF D-29.** D-29 parks _auto_-promotion; its own
text (PARKING-LOT:5735) reads "the call is available and safe to run by hand on any date; nothing
schedules it." The argument is passed explicitly on a synthetic date — no default, cron or flag
changed. It is what makes S4 honest: `record_blocked_demand_v3` is the one object in the chain whose
idempotence rests on a UNIQUE index rather than on minting a fresh `run_id`, so it is the only place
"no dup lines" can actually fail.

**Measured, `stress_run_id` `931193ba`, 33 pass / 0 fail / 0 skip:** total **126 094 ms** against a
600 000 ms budget (**21 %**), per-run 3 × ~42 s · every run `status='ok'` · engine 544 lines ×3
identical · compose 46 ×3 identical · stitch 47 rows ×3 identical · units placed 160 ×3 · fleet 31 =
planted 31 = covered 31 · zero duplicate keys in either engine or stitch output · zero unexplained
qty-0 · `gate0_no_unconfirmed_picks` 0 · inputs stable (33 green).
**blocked_demand idempotence, the headline:** run 1 inserted **46** rows, runs 2 and 3 inserted
**0** — open row count constant at 46 across all three, content fingerprint identical, zero stale
closes. Re-running **re-stamps, it never duplicates**. (Runs 2-3 legitimately _update_: `reasoning`
carries the promoting stitch `run_id`, a new uuid each generation.)
**ADR §8 obligation-3 tripwire, re-verified by an independent read after the run:** `pod_refills`
3955→3955, `pod_refill_plan` 6572→6572, `refill_plan_output` 8256→8256, live `2026-08-04` untouched
at 96.

⚠️ **`blocked_demand` MOVES 44 → 90 AND THAT IS NOT A REGRESSION.** All 46 new rows sit on
2030-11-04. `v_blocked_demand_open` filters `plan_date < '2030-01-01'`, so the procurement worklist
is **provably** untouched — re-read at 20 before and after. Per PARKING-LOT:5757 a global `count(*)`
on this table is not a regression signal; scope by `plan_date` and `source`.

⛔ **THE HTTP RESPONSE WAS A CLOUDFLARE 524 AND THE RUN PASSED ANYWAY (S-212).** Transport cut at
~125 s; the transaction had already committed server-side. The verdict was read back from
`golden.stress_runs`, never from the response body. Any future S4 run must budget >2 min and use the
fire-and-read-back pattern.

⭐ **NO APPLY-TIME VERSION DRIFT — the third consecutive leg.** Applied with `/tmp/prd110_sql.sh`
(S-215, transactional) and the `schema_migrations` row inserted explicitly. `prd110%` 287 → **288**.

---

## 20260804050000_prd110_leg121_stress_s2_estimator_soak

**PRD-110 STEP 7 / S2 — estimator soak, 10 000 synthetic WEIMI deltas.** Adds
`golden.stress_s2_v1(p_rounds integer, p_record boolean, p_note text, p_allow_cron_window boolean)`,
INVOKER, `search_path = golden, public, pg_temp`, `EXECUTE` revoked from PUBLIC. One cold-start
fleet derivation plus `p_rounds` (default 18) role-driven storm rounds over synthetic
`weimi_device_status` snapshots, **25 assertions**. Cody ⚠️ Approve-with-revisions; both revisions
changed the shipped file (see below).

**Result:** `stress_run_id` `0e792c88`, **25 pass / 0 fail**, **27 611 ms** (4.6 % of the
600 000 ms budget), **10 336 deltas processed**, 19 rounds. Storm content all fired:
`count_above_capacity` 683 · `count_rise_unexplained` 689 · `negative_delta_unallocatable` 56 ·
`derived_decrement` 8 026 · `venue_fill` 61 · `correction` 3 062 · `driver_confirm` 424.
EXPIRY IRON RULE: `dd_on_expired` **0** against **22** independent witnesses.
`residue` 0 · negative `est_qty` 0 · confidence out-of-bounds 0 · confidence regressions 0.

**Rollback-restored probe — nothing persists.** `inventory_events` 50 → 50 ·
`shelf_composition` 31 → 31 · `inventory_anomalies` 147 → 147 · `weimi_device_status` 4569 → 4569
(max `snapshot_at` still 2026-08-03T22:00:40) · `product_sourcing` 4052 → 4052, all re-read
independently after the run. **Consumes no plan_date: 2030-11-02 is released, not used.**

**Cody's two revisions.** (1) `weimi_device_status` is not an Appendix A protected entity, so the
direct snapshot append is not an Article 1 violation — but the canonical ingest writer
`upsert_device_status` exists and bypassing it silently becomes precedent, so the header now names
it and states the two measured reasons it cannot drive the soak (`snap_date := CURRENT_DATE`
hardcoded; a `total_curr_stock >= existing * 0.1` guard that rejects every drop-to-zero round).
(2) The Article 6 tripwire took a bare `count(*)` on `warehouse_inventory` — a count cannot see an
UPDATE, which is the only shape an Article 6 `status` violation could take; A24 is now a content
fingerprint over the status / provenance histogram plus `warehouse_stock` and `consumer_stock` sums,
and `pod_inventory` likewise gets status plus `current_stock`.

Articles checked: 1, 2, 4, 6, 7, 8, 12, 14, 16. No new table, no RLS change, no metric re-derived
inline. Append-only is respected rather than bypassed: the probe only INSERTs, and the undo is a
transaction rollback rather than a DELETE, so `tg_inventory_events_append_only` is never fired.

## 20260804051000_prd110_leg121_s2_fail_branch_text_cast

**S-227 fix, forward-only (Article 12).** `v_fails := v_fails || 'A02 ...'` with `v_fails text[]`
is ambiguous — the untyped literal resolves as an ARRAY literal, so Postgres raises
`22P02 malformed array literal` and the suite ABORTS instead of reporting its failures. Re-ships
`golden.stress_s2_v1` with an explicit `::text` on all 25 failure appends; `20260804050000` is
left exactly as applied. Proven by the run that found it: at `p_rounds => 2`, S2 reported
`24 pass / 1 fail ["A02 fewer than 10000 deltas processed"]` instead of crashing.

⚠️ **The same shape is in `golden.stress_s6_v1` (leg 117) and `golden.stress_s4_v1` (leg 120)** and
has never executed in either — both finished with zero failures, so the branch is dead code. A red
S4 or S6 would crash rather than report. **Parked as its own unit** (PARKING-LOT S-227): both are
banked green and carry md5s on the roll, so re-shipping them is a deliberate act with its own Cody
pass, not a drive-by.

⭐ **No apply-time version drift — the fourth consecutive leg.** Both applied with
`/tmp/prd110_sql.sh` (S-215, transactional) and the `schema_migrations` rows inserted explicitly.
`prd110%` 288 → **290**.

---

## `20260804060000_prd110_leg122_stress_s3_concurrent_edits.sql` — PRD-110 STEP 7 S3 (leg 122)

Three `golden.*` harness objects, no table, no RLS change, no protected entity touched:
`_s3_edit_plan_v1` (STABLE, pure read — deterministic target selection),
`stress_s3_setup_v1` (LAW-12 guards, `:36-:48` cron-44 refusal, fleet plant through
`pick_machine_manually`, one `run_pipeline_v3` base run, returns the target list + the LAW 4 bank),
`stress_s3_verify_v1` (re-runs `run_pipeline_v3` FIRST, then judges). Driven externally by the
checked-in `scripts/prd110_s3_concurrent_edits.py`.

⛔ **S3 is the first suite that CANNOT be a single SQL function.** Twenty edits issued from one
session are twenty SEQUENTIAL statements. `golden.stress_runs.driver = 'external'` exists for this.

⛔ **The order is the property.** Every ledger and overlay count is taken AFTER the pipeline
re-runs, because P3.6 promises survival _across_ a re-run and a count taken before it cannot
observe a violation. "20 rows exist" is a vacuous pass.

**Cody, two revisions, both applied before the migration landed:** (1) the TRUNCATE probe now
pre-checks `pg_trigger` and does not take an ACCESS EXCLUSIVE lock to learn what `pg_trigger`
answers free — and the file now records that a subtransaction rollback does NOT release that lock,
so the probe must stay last; (2) `p_bank` is mandatory and its absence RAISEs, because the LAW 4
tripwire and the drift sentinel were `skipped` when the bank was NULL — a tripwire that can be
switched off by omission is not a tripwire.

## `20260804061000_prd110_leg122_s3_wave2_contention_witness.sql` — S3 wave-2 witness (leg 122)

**Fix-forward (Article 12).** `20260804060000` stays exactly as applied; this re-ships
`golden.stress_s3_verify_v1` on the same signature, adding three metrics and assertions 34/35.
Existing seq 1–33 keep their numbers and meanings.

⛔ **THE FIRST RUN WAS GREEN AND ITS CONTENTION CLAIM WAS UNWITNESSED.** `20260804060000`'s header
predicted, under a heading reading "MEASURED, NOT ASSUMED", that five concurrent same-key edits
would leave one winner and four loud 23505 refusals. The run returned **5 ok / 0 refused**
(`f4b33fe3`) — and the suite had no way to tell "`record_plan_edit_v3` serialised five racing
writers correctly" from "the five calls never actually raced", because peak in-flight overlap was
measured for wave 1 only.

⭐ **The cause, and the fix.** `record_plan_edit_v3` spends milliseconds inside its
FOR-UPDATE/INSERT critical section while a call takes ~2.7 s end to end, nearly all transport. Five
requests can be in flight together and still take the row lock seconds apart. The driver now
BARRIER-ALIGNS wave 2 — every contender sleeps server-side to one shared instant and only then
enters the RPC — and reports the SERVER clock at entry. **Measured on the re-run (`e08cfe09`): entry
spread 1 ms across 5 contenders, and one call was duly refused with 23505.** The prediction was
right; the unaligned wave simply never tested it.

⭐ **No apply-time version drift — the fifth consecutive leg.** Both applied with
`/tmp/prd110_sql.sh` (S-215, transactional) and the `schema_migrations` rows inserted explicitly.
`prd110%` 290 → **292**.

---

## `20260804070000_prd110_s5_spot_buy_race_suite.sql` — PRD-110 STEP 7 S5 (shipped leg 124, run + recorded leg 125)

Adds `golden._s5_leg_log` (+ index) and four `golden` SECURITY DEFINER functions —
`stress_s5_setup_v1`, `stress_s5_pack_leg_v1`, `stress_s5_bind_leg_v1`, `stress_s5_verify_v1` — all
`REVOKE`d to `postgres=X/postgres`. Nothing outside `golden` is created, altered or dropped and no
live writer is modified (LAW 4). Article 14 clear: the leg log materialises nothing, it is the only
channel by which a contender running in its own connection and transaction returns a payload to the
verifier.

⛔ **THIS MIGRATION WAS APPLIED BY AN UNLOGGED LEG AND ADOPTED FORWARD.** Leg 124 wrote the file,
applied it, inserted the `schema_migrations` row, ran `stress_s5_setup_v1` — and died before the
waves. Leg 125 found the gap at pickup (`prd110%` 292 → **293**, disk 293 → 294, `git status` 295 → 297) and adopted it: owed set proven empty by md5 equality of both sorted name lists
(**80790cb95b90a998178415d707d97563**, 293 names each), all 12 doc hashes unmoved, all 26 roll md5s
byte-identical. A forward gap is work to verify and record, never corruption to undo.

⭐ **S5 IS GREEN, 29/29, and neither wave is vacuous.** Wave 1 (pack vs pack, common barrier) proves
`pack_dispatch_line` clean POSITIVELY: exactly one leg packed, exactly one refused with `Already
packed` (P0001), batch Z debited exactly once (5 → 1 warehouse, 0 → 4 consumer, sum conserved).
Wave 2 (offset barrier, bind enters +2 s) reproduces **S-237 on the production path**: the bind
contender blocked **3056 ms** on the pack contender's row lock — that wait IS the witness they
raced (S-234) — then re-bound an already-`packed=true` line, reporting `bound=1`.

⛔ **THE PRODUCTION CONSEQUENCE IS NOW MATERIALISED IN REAL DATA, NOT ARGUED.** Dispatch line
`a2020a40` carries `from_wh_inventory_id = d2c19a2a` (batch Y) while the five units it holds were
debited from `0aa9e796` (batch X). `return_dispatch_line` and `credit_dispatch_remainder` credit
`from_wh_inventory_id`, so a return on that line would destroy stock on X and mint it on Y, with
Y's expiry. Assertions 23/24/25 PIN this as sensors per the D-46 routing (CS decision still open):
green today, **expected to red the day `bind_dispatch_fefo` gets its two predicates back**, and
updating them from Y to X is the proof the parked binder fix landed.

⛔ **TWO GUARDS WERE READ LIVE AND NEITHER INTERCEPTS THE RE-BIND — this is stronger than leg 123
had.** `enforce_packed_dispatch_immutability` guards `boonz_product_id`, `pod_product_id`,
`machine_id`, `shelf_id` and `dispatch_date` on a packed row; `from_wh_inventory_id` is not in the
set. `trg_enforce_pack_via_rpc` carries `WHEN (new.packed = true AND old.packed IS DISTINCT FROM
true)`, so it fires only on the false→true transition and is blind to a writer that mutates a
packed line's binding. Measured, not inferred: `refill_pack_bypass_log` stayed flat at 20 and
`bypass_violation_log` flat at 18725 across the whole run.

⛔ **S-238 — THE `reserved_for_machine_id` FENCE IS NOT DURABLE, AND IT RELEASED MID-LEG.**
`release_stale_wh_pins` (cron **34**, `50 * * * *`) nulls any pin with no packed-but-not-picked-up
line for that machine+product. The leg-124 plant's lines were unpacked, so the pins were released
at **05:50 UTC**, 15 minutes after planting — caught only because the pickup probe at 05:49 and the
handle rebuild at 05:53 disagreed. Twelve units of synthetic stock sat live-pickable in WH_CENTRAL
in between, and product P had no other pickable batch, so a real plan needing it would have picked
synthetic stock. Re-fenced under the harness-plant exemption (one column, three known rows,
`status` untouched — Article 6 clear) before the waves ran. ⭐ **The run made the fence permanent:**
both lines are now `packed=true, picked_up=false`, which satisfies the cron's own guard —
re-probed after the run, `pins_would_release_now` = **0**.

⭐ **No apply-time version drift.** Applied with `/tmp/prd110_sql.sh` (S-215, transactional) and the
`schema_migrations` row inserted explicitly. `prd110%` 292 → **293**. `golden.stress_runs` 8 → **9**;
six of seven suites green (S1, S2, S3, S4, S5, S6), S7 outstanding.

## 20260804073000_prd110_leg127_f28_seq15_19_observed_convergence

**PRD-110 leg 127.** Re-phases golden fixture 28 seq 15 and seq 19 after the in-scope fleet fully
converged on the `observed` base-stock interval tier.

**Why.** S7 round 0 (58/58 fixtures, 2094/2094 assertions, zero skipped) returned exactly two
failures, both in fixture 28. Bisected live: AMZ-1046-2406-O1 took real driver dispatches on
2026-07-25 / 07-31 / 08-04, giving gaps {6,4}, so `n_gaps = 2 >= base_stock_min_gaps = 2` and the
machine moved `policy_seed` -> `observed` under precedence `observed_first`. It was the last live
member of the policy_seed tier, so `tiers_exercised` fell 2 -> 1.

⛔ **Production drift, not harness contamination** - the fixture's cadence CTE is bounded
`dispatch_date <= CURRENT_DATE`, which structurally excludes every synthetic 2030-dated stress plant.

**What changed.** `golden.fixtures` (fixture 28 `scenario_sql`, three named substitutions adding the
`view_tier2_present` structural probe) and `golden.assertions` (seq 15 expect -> `observed`; seq 19
re-pointed to `view_tier2_present`, `gte 2` -> `eq 1`). Follows the D-14c precedent that introduced
seq 18 for the param_default tier: prove an emptied tier from `pg_get_viewdef`, not from live visit
history (S-204).

⛔ **No assertion added or deleted** - fixture 28 stays 21, global population stays 2094, fixtures
stay 58. The non-vacuity spine (seq 2 / 16 / 17 / 18) is guarded unchanged. `v_machine_base_stock_policy_v3`
viewdef md5 **62c096f1** before and after: no engine object touched.

**Cody:** ✅ Approve, class (f) non-protected. Articles 1, 2, 3, 7, 12, 14, 16 checked.

**Evidence.** Dry-run probe ran the fixture inside an aborted transaction: 21 pass / 0 fail / 21
evaluated. Post-apply live re-run: **21/21, zero reds**. ⭐ No apply-time version drift; applied with
`/tmp/prd110_sql.sh` (S-215) and the `schema_migrations` row inserted explicitly. `prd110%` 293 -> **294**.

---

## 20260805235500 · `prd110_d45_compose_add_additive` (PRD-110 leg 133, D-45 EXECUTE)

⚠️ **REGISTRY GAP FLAGGED, NOT SILENTLY PAPERED OVER:** leg 132's six migrations
(`20260805231203`, `231420`, `231824`, `232010`, `232501`, `232851`) are **applied and registered in
`schema_migrations` but absent from this document**. This file's last narrative entry is leg 127's
`20260804073000`. The two entries below are leg 133's own; the leg-132 six remain owed.

**What changed.** `compose_plan_with_edits_v3` — one `CASE` in loop (a): plan-edit kind `add` now
composes to **`base_qty + edit_qty`** instead of `edit_qty`. `set_qty` stays absolute, `drop` stays 0.
Applied by named substitution on `pg_get_functiondef` output, diff-verified to a single hunk.
⛔ Loop (b) (edits with no base line) deliberately unchanged — base is 0 there, so it was already
additive. ⛔ `record_plan_edit_v3` deliberately untouched per the CS ruling.

**Why.** The two halves of the edit path disagreed: the writer read `add` additively for its
pin-contradiction guard while the composer applied it as absolute, so "add 3" on a base of 12
composed to **3** — a silent 9-unit reduction of a line the human meant to raise. Measured exposure
at S3 leg 122: **5 of 5** applied `add` edits carried a non-zero base.

**Cody:** ✅ Approve. Articles 1, 2, 3, 4, 6, 8, 12, 14, 16 checked. No protected entity written —
the function's only write target is `pod_refills_shadow` (shadow table, LAW 4). `SECURITY DEFINER`
and `SET search_path TO 'public','pg_temp'` restated verbatim; ACL preserved by `CREATE OR REPLACE`.

**Evidence.** `prosrc` md5 **32d2a805 → 0f8dcfb6**. Owed-set recomputed both sides.

---

## 20260805235600 · `prd110_d45_s3_sensors_flip_to_additive` (PRD-110 leg 133, D-45 proof leg 2)

**What changed.** `golden.stress_s3_verify_v1` — assertions **18** and **20** re-based from the
absolute expectation to the additive one, reading the base from the composer's own base run
(`v_base`), **not** from `base_qty_at_edit`. Both renamed per S-103
(`…_at_D45_additive_qty`, `add_composes_as_additive_D45_property`), neither loosened. New seq **36**
`D45_additive_assertion_is_load_bearing` promotes the already-computed `v_add_diverge` diagnostic to
an anti-vacuity assertion (≥1 applied add on a non-zero base).

**Why a SECOND migration rather than one.** The red is the proof. S3 ran against the fixed composer
with the OLD sensors and failed exactly as the CS ruling predicted — banked
`golden.stress_runs` **`2ecddab8`**, `passed=false`, 33/2. These sensors live in a `golden.stress_*`
function, **not** in `golden.assertions`, so `golden.run_all()` was never left red between the two.

**Cody:** ✅ Approve. Articles 7, 12, 14, 16. Harness-only object; `prosecdef=false` (INVOKER)
correctly preserved — this function was never DEFINER; `search_path` `'golden','public','pg_temp'`
restated verbatim. The append-only `plan_edits_v3` refusal probes (Article 7) untouched.

**Evidence.** `prosrc` md5 → **f09fc2ff**. S3 re-run **`ec76abd0`**, `passed=true`, **36/0**, with
seq 36 reading **5** (assertion is load-bearing, not vacuous). Fixtures 1/11/50/51/54/57 green
(59/39/49/53/41/39, 0 skipped). `prd110%` 300 → **302**.

---

## 20260806003000 / 20260806003100 / 20260806003200 — PRD-110 leg 134: D-43 EXECUTED (both halves) + S-193 CLOSED

**CS ruling (2026-08-04).** _"D-43 CLOSED: warehouse SELF-SERVES repacks. Add `warehouse` to
`push_plan_to_dispatch`'s role list (option a). The pre-flight fix (repack_machine must check push
authorisation BEFORE returning a single row) remains mandatory and independent."_

**Why S-193 rides in the same migration.** Leg 133 raised S-248 and parked D-43 on it. Today the
packing role hits S-191: repack half-completes and RAISES `push_failed` — **loud**. Half 1 alone
authorises that role for push, so it stops erroring and lands on **S-193** instead: `status='ok'`,
**zero** fresh dispatch rows, plan re-stamped `dispatched=true`. Shipping half 1 by itself would
hand the exact role that reported the 2026-07-20 incident a **silent freeze in place of a loud
error**. The parking lot has demanded the S-193 fix since leg 107; it is the precondition that makes
D-43 safe, and both defects live in the same function.

**S-193's mechanism, one line.** push's RC-01 §5(5b) multi-wave idempotency probe excluded
`skipped`/`cancelled`/`is_m2m` rows but **not `returned` ones**, so a row repack had just RETURNED
still matched and the plan line was "preserved" against a dead row. The partial unique index and
`prevent_duplicate_unstarted_dispatch` **both already excluded `returned=true`** — this predicate
was the only place that did not, which is why the fresh INSERT succeeds the moment it agrees.

**Blast radius, measured live rather than argued.** Only three functions ever set
`refill_plan_output.dispatched=false`: `push_plan_to_dispatch`, `repack_machine`,
`reset_approved_undispatched`. The third also flips `operator_status` to `pending`, which push does
not select. **The `returned` predicate change therefore reaches the repack path and nothing else** —
no cron, no EOD sweep, no driver return.

**Objects.** NEW `public.push_dispatch_authorized_roles()` (IMMUTABLE sql, `search_path ''`,
`ARRAY['operator_admin','superadmin','manager','warehouse']`) — the ONLY place the push-authorisation
role set is written down. `push_plan_to_dispatch` **21371529 → 6372fe60** (v10 → `v11_rc01_single_writer_d43_s193`;
4 named substitutions / 6 changed lines). `repack_machine` **d719d3c1 → 2e8330fe** (1 inserted
pre-flight block, immediately above the `return_dispatch_line` loop — its first destructive act, and
there is no savepoint).

**Cody:** ⚠️ Approve with revisions → applied. Articles 1, 2, 3, 4, 5, 6, 8, 12, 13, 14, 16. The
revision: `GRANT EXECUTE … TO authenticated` **dropped** (Article 3, least privilege) — both callers
are DEFINER owned by `postgres`, so the EXECUTE check resolves as the definer; the grant would only
publish the privileged-role list to every logged-in user. `service_role` only.

**S-248 answered structurally, not by inspection.** Once `warehouse` joins push's set, repack's gate
and push's set are **identical**, so half 2's pre-flight is a branch **no role can reach**. It ships
anyway as the anti-divergence guard, and fixture 9 seq **78** asserts the relation as DATA
(`repack_roles ⊆ push_roles`, expect `0|4` — the second number is anti-vacuity, because a regexp that
stops matching yields zero rows and would pass a bare `0`). seq **79** asserts the pre-flight
PRECEDES the first destructive act; ordering is the whole defect.

**Evidence — a three-run chain in `golden.runs`, all re-readable, none to be deleted:**
`58a80197-4796-4d26-9d8f-7970c7bd18b0` **73/0 green** (old functions) →
`78ebb82f-1750-4da8-a612-66f09028d356` **63/10 RED** (fixed functions, old sensors: seq 2, 9, 10, 11,
16, 17, 18, 22, 27, 28) → `f0d4c08b-2116-4f4e-9774-4adfbccf6bd7` **80/0 green** (re-based).
Fixture 9 population **73 → 80**; no assertion loosened, every re-based expect still exact equality.

**⚠️ S-192 IS NOT CLOSED and is still pinned** (fixture 9 seq 31-34): a repack's own returns stamp
`dispatched=true`, so the second repack on a (machine, date) is still refused forever.

## `20260807171000_prd110_s274_fixture54_owns_its_assortment_premises`

PRD-110 leg 146. **S-274 — fixture 54 was red at 33/41 and the first failure was its own premise
sensor.** seq 2 ("the incoming pod is NOT already assorted on the machine") read **1**: HUAWEI-2003
A03 had been re-podded to **Al Ain Zero**, which is the fixture's incoming pod, so `swap_v3` refused
correctly and six downstream assertions read `absent`. ⭐ **Not an engine regression** — `swap_v3`
`md5(prosrc)` is **ffff8485** before and after, unmoved since leg 126.

**The defect is that the fixture READ its premises off live assortment instead of OWNING them** (the
S-34 class). Closed with the leg-114/115 self-supply idiom, **not** by loosening seq 2 (it keeps
`eq 0` verbatim) and **not** by re-pointing the anchors at whatever pod is free today.

**Objects.** NEW `golden.plant_shelf_identity(uuid, uuid, integer)` — the identity sibling of
`golden.plant_shelf_stock` (leg 136). Identity in this system is WEIMI `goodsName` resolved through
the four tiers of `v_live_shelf_stock`, so planting an identity is the **same class of write on the
same row** as planting a stock level. `p_pod_product_id` NULL vacates with a sentinel proven to match
no tier ('unmatched' is a real live state — six aisles carry it). Takes custody of the machine
pre-image in `golden.weimi_pin_backup` so the existing `golden.restore_machine_stock` puts it back.
NEW `golden.evict_pod_from_machine(uuid, uuid)` — vacates every shelf carrying a pod, which is what
turns "pod X is not on this machine" into a **construction**. Fixture 54 gains step (0b) (five plants:
A04 = outgoing, A05 = duplicate, A07 = cross-swap incumbent, evict incoming, evict cross, donor
NOVO-1023 A13 = cross pod @ 6) and step (7) (restore both machines). Assertions **41 → 44**.

⛔ **The planter keys on the row the VIEWS read, not on `official_name`.** NOVO-1023 carries snapshots
under three historical `device_name`s; `v_shelf_slot_identity` resolves newest-per-`device_name` then
newest-overall, and keying on the machine's current name alone would sometimes edit a row no view
reads. `golden.plant_shelf_stock` still has that shape — recorded, not fixed here (LAW 10).

⭐ **Residue is impossible by construction and was also measured.** `golden.run_fixture` runs the
scenario in a plpgsql subtransaction, so any error between plant and restore rolls the plants back;
the step-(7) restore is deliberately **not** wrapped, because a failed restore should roll the whole
scenario back rather than be swallowed. Measured after the run: `pre_state` = `post_state` =
`f9d2d73c301789067cba0179e14182e0` across both machines, `golden.weimi_pin_backup` **0**, zero
`GOLDEN-VACANT-%` rows in `v_live_shelf_stock`, A03 back to Al Ain Zero, donor A13 back to 7 units.

**Cody:** ⚠️ Approve with revisions → applied. Articles 1, 2, 3, 4, 6, 7, 8, 12, 14, 16.
`weimi_device_status` is **not** in Appendix A (settled precedent: `pin_machine_stock` leg 28, the
leg-114/115 fixture-8 plant/restore, `plant_shelf_stock` leg 136). **R1:** seq 8 (custody released)
must read `golden.weimi_pin_backup` **live and whole-table**, never `golden.scratch` — a scenario that
RAISEs rolls back its own scratch DELETE (S-266), so a scratch-derived residue sensor goes green off
the previous run's snapshot exactly when a leak is most likely, and a two-machine filter would miss a
third plant whose restore was forgotten. **R2:** custody is keyed by `machine_id` and
`restore_machine_stock` DELETEs the row, so the anchor and donor MUST stay distinct — recorded as a
comment on step (7). Both functions are SECURITY **INVOKER** with `search_path = ''` and explicitly
`REVOKE`d from `PUBLIC, anon, authenticated` (S-268 shape). Article 16 ✅ the residue fingerprint reads
`v_shelf_state`, the canonical object, rather than re-parsing the `door_statuses` JSONB.

⚠️ Recorded: `weimi_device_status` is the n8n sync target and the plant holds a row lock on up to two
snapshot rows for the fixture's duration — do not start fixture 54 inside cron 44's window (UTC :40).

**Verified: fixture 54 `43 / 1`** — every premise, every swap and all of D-36 green; the lone survivor
was seq 54, closed by `20260807171500`.

## `20260807171500_prd110_s277_fixture54_seq54_restated_to_the_invariant`

PRD-110 leg 146. **S-277 — an absolute count over an APPEND-ONLY ledger can never state a relative
property.** With the S-274 plants in place fixture 54 read 43/44, the survivor being seq 54
("RE-RUN PRESERVATION: a second compose applies the same swap, dropping nothing", expect **4**,
actual **5**).

⭐ **THE FIFTH EDIT IS NOT THIS RUN'S, AND IT IS THE SAME INCIDENT.** `plan_edits_v3` history for
(2030-02-24, A07) shows every run from 2026-07-31 22:25Z to 2026-08-06 22:09Z dropping **SF Pancake**,
and the run at 2026-08-07 16:15:59Z dropping **Keen Health Dipped Crackers** instead. HUAWEI-2003 A07
was re-podded in the **same ~18-hour window** that re-podded A03. **One re-podding event, two
casualties** — and the first masked the second, because with the same-machine swap refused the cross
swap was the only swap left and nobody counted its legs.

⛔ **The orphan cannot be retired, by constitutional design.** `record_plan_edit_v3` supersedes on
(plan_date, shelf_id, pod_product_id) and no future run will ever emit an edit on the SF Pancake key
again — A07's incumbent is now OWNED by the S-274 plant. `plan_edits_v3` carries
`tg_plan_edits_v3_append_only` on DELETE, UPDATE and TRUNCATE (verified from `pg_trigger`). The row
stays active forever, inert: `effective_qty` 0, note "drop on a shelf the base did not plan".

**So `expect 4` was never the invariant — it was a census of the ledger that happened to agree with
it.** Restated per S-103 / S-272 (the row is UPDATEd in place with a landing guard, never deleted;
`expect_op`/`expect` move with the SHAPE of `check_sql`). **One assertion becomes three, each stricter
than the one it replaces:** seq **54** now compares c2's applied **edit_id SET** to c1's — the old
form could not tell "applied the same four" from "applied four different ones"; seq **56** requires
all four of the fixture's OWN legs in c2.applied, matched by (shelf_id, pod_product_id, kind), which
the absolute count never checked; seq **57** requires every non-fixture applied edit to be **inert**
(`effective_qty` 0), so a genuinely live extra edit goes red while the unretirable historical no-op is
tolerated **explicitly** rather than absorbed into a number. Assertions **44 → 46**.

**Cody:** ✅ Approve (fast-path, class f — `golden.assertions` only). Articles 12, 16.

**Verified: fixture 54 `46 / 0`, `passed` true, zero `scenario_error`, 5020 ms** — adjudicated from
`golden.runs`, never from the returned set (S-260/S-266). Actuals: `2=0 · 7=yes · 8=0 · 9=restored ·
20=ok · 21=2 · 54=preserved · 56=4 · 57=inert · 60=ok · 61=2 · 62=swap_v3 · 63=true`.
⭐ `swap_v3` **ffff8485 unmoved** — the fix landed in the fixture, which is where S-274 says it belongs.

---

## `20260808180000_prd110_dr10_fixture73_red_baseline` + `20260808181000_prd110_dr10_proposals_family_audit_triggers` (leg 156) — DR-10, Article 8 across the `*_proposals_v3` family

**The defect, measured.** A decision on a proposal minted no `write_audit_log` row on ANY table in
the family. Not a theoretical gap: `write_audit_log` held **0** rows for all five tables, and the RED
baseline fired before the fix (`f8664987`, **12 / 9**) recorded `no_trigger=5`, `wrong_fn=5`,
`wrong_shape=5` with five real decisions producing zero audit rows.

**⛔ THE PARKING LOT SAID FOUR. THE CATALOGUE SAYS FIVE (S-299).** DR-10's note enumerated `facing`,
`feedback`, `rotation`, `picker_weight`. Re-deriving the site list BY SHAPE (S-280) — a `public` table
carrying all four of `proposal_id` / `status` / `reviewed_by` / `reviewed_at` — returns
`reallocation_proposals_v3` as well, **92 live rows, also zero triggers**. A migration that pasted the
note's four names would have left the family one table divergent, which is precisely the rot DR-10 was
raised to prevent, committed by the fix for it. The predicate does NOT pull in
`warehouse_inventory_status_proposal` (which already has `tg_audit_wisp`).

**The install loops the shape predicate at apply time** rather than naming tables, then re-derives all
three counters and RAISEs unless `no_trigger = wrong_fn = wrong_shape = 0` — a partial install cannot
commit. Idempotent: a table already correctly wired is skipped, not churned. Per S-298 the only hard
guard refuses an **empty** family, never an unexpected count — a hardcoded "must equal 5" would refuse
the correct migration the day a sixth proposal table lands.

**⭐ `audit_log_write('proposal_id')`, never `audit_log_write()`.** The helper COALESCEs a missing
`TG_ARGV[0]` to `'id'` — a column NONE of these five has — so the argument-less form would not error.
It would log `row_pk = '?'` on every decision forever while every existence check still passed.
`dispatch_pack_confirmation` carries exactly that argument-less form live today; it was not copied.
Fixture 73 seq 9 makes the argument mandatory rather than conventional.

**Fixture 73 (21 assertions, id 73, plan_date 2030-06-20)** decides a REAL pending proposal on each of
the five inside a PL/pgSQL subtransaction rolled back by a sentinel RAISE, counting the audit row
INSIDE the block. PL/pgSQL variables survive a subtransaction rollback; rows do not — an `INSERT` into
the results temp table placed before the RAISE would be discarded by the very rollback it measures,
and the fixture would report "no candidate" on both sides of the fix. It plants nothing: planting into
these five means satisfying `fp_v3_direction_math`, `chk_fpr_v3_value`, `rp_v3_qty_le_headroom`,
`realloc_v3_unclaimed_is_empty`, `pwp_pairs_coherent` and eleven FKs, then deleting synthetic rows from
tables CS reviews by hand.

⛔ Two live traps found by the S-149 dry run, not by reading: `picker_weight_proposals_v3` has **no
pending row at all** (1 applied, 2 superseded), so its predicate accepts `superseded` and excludes
`applied` (`pwp_applied_shape` would raise 23514); and `reallocation_proposals_v3` uses `status =
'proposed'` because `realloc_v3_unclaimed_is_empty` ties `'unclaimed'` to `target_shelf_id IS NULL`.
Seq 6 is the standing sensor that keeps a 23514 from being misread as an Article 8 gap.

**Cody:** ✅ Approve. Articles 1, 2, 3, 7, 8, 12, 14, 16. Sink verified append-only
(`wal_no_update` / `wal_no_delete` both `USING (false)`) BEFORE adding five write sources to it; all
five family tables already `relrowsecurity = true`. Named but not blocking: the `ILIKE` shape patterns
treat `_` as a single-char wildcard and are sound only because `tgfoid = 'public.audit_log_write'::regproc`
pins function identity exactly — do not reuse that pattern without the `regproc` pin.

**Verified: fixture 73 `21 / 0`, `passed` true, zero `scenario_error`, 30773 ms** (`8cd19e87`),
adjudicated from `golden.runs`. Independent post-run probe: all five status populations unchanged
(`facing:20 | feedback:12 | picker:2 | realloc:23 | rotation:25`), zero stray review notes, family
`write_audit_log` count still 0 — the exercise leaves nothing behind.
⛔ **Triggers are not retroactive.** The 83 existing proposal rows have no audit history and never
will; Article 8 coverage for this family begins here.

## PRD-003 (2026-08-11) - PO document totals, VAT, and the additions mirror

All five are additive and forward-only (Article 12). Repo filenames match the applied
`supabase_migrations.schema_migrations.version` exactly.

| version          | name                                                | what it does                                                                                                                                                                             |
| ---------------- | --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260811201329` | `prd003_po_document_totals_vat`                     | `purchase_order_totals` + RLS + S-308 revoke; `purchase_orders.source_addition_id` + partial UNIQUE; `v_po_document_totals`; **`v_daily_flow_reconciliation` double-count patch (C-3)**. |
| `20260811201443` | `prd003_po_totals_rpcs_and_addition_mirror`         | `set_po_document_totals`, `get_po_document_totals`, `get_input_vat_report`, `_mirror_po_addition_line_v1`; anon + PUBLIC revokes.                                                        |
| `20260811201550` | `prd003_wire_addition_mirror_into_receive_paths`    | `receive_purchase_order` and `receive_purchase_order_addition` rebuilt from live bodies with one added statement each.                                                                   |
| `20260811201626` | `prd003_revoke_write_verbs_on_totals_view`          | S-308 follow-through on the VIEW - the post-image showed `authenticated=arwdDxtm` on it.                                                                                                 |
| `20260811202600` | `prd003_procurement_events_admit_totals_and_mirror` | widens the `event_type` CHECK by three values.                                                                                                                                           |

⚠️ **S-308 APPLIES TO VIEWS, NOT JUST TABLES, AND THAT COST AN EXTRA MIGRATION.** The default
privilege hands `authenticated` the full verb set on **every relation** created in `public`. After
`20260811201329` the ACL read was
`v_po_document_totals: {postgres=arwdDxtm/postgres,authenticated=arwdDxtm/postgres,service_role=arwdDxtm/postgres}`.
`GRANT SELECT` does not take the other verbs away and `REVOKE ... FROM anon` does not touch what
`authenticated` holds. The view is non-updatable so a write would have failed anyway - but
"it would fail anyway" is luck, not posture. Post-image after `20260811201626`:
`purchase_order_totals: authenticated=rm/postgres` (SELECT + MAINTAIN only), INSERT/UPDATE/DELETE all
`has_table_privilege = false`.

⛔ **THE PRE-MERGE DRY-RUN IS WHAT CAUGHT THE CHECK-CONSTRAINT BREAK.** T1 was run as a DO block that
performs every write, measures every assertion, then `RAISE`s so the whole transaction unwinds and
production is left untouched (the PRD-016B pattern). The first run failed with `23514` on
`procurement_events_event_type_check`. Without that rehearsal the failure would have landed on the
first real receive after deploy. Verified afterwards: `purchase_order_totals` row count **0** - the
rehearsal left nothing behind.

## 2026-08-14 — PRD-115 mid-pack plan edit safety

Four migrations, forward-only.

| version          | name                                   | notes                                                                                                                                                                                                                                                                                       |
| ---------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260814090000` | `prd115_remove_dispatch_row_tombstone` | §2.1. `remove_dispatch_row` gains a `refill_plan_output` tombstone (`operator_status='rejected'` + `removed_at_dispatch_by` appended to `operator_comment`, `WHERE dispatch_id = p_dispatch_id`), same transaction as the `include=false` write. Every prior guard byte-identical.          |
| `20260814090500` | `prd115_push_plan_tombstone_guard`     | §2.2. `push_plan_to_dispatch` v11 → **v12_prd115_tombstone_guard** via anchored splice. **Base md5 `5f858899eecef1e75e6ae6d00fcc1c8b` → post md5 `487f33107819ce8335251e235ac7405e`** (24,251 → 25,295 b). Base-md5 gate + three anchor-uniqueness gates + idempotent re-run short-circuit. |
| `20260814091000` | `prd115_pack_status_needs_reconfirm`   | §2.3. `v_machine_pack_status.pack_state` gains `needs_reconfirm`; two additive trailing columns `needs_reconfirm`, `unresolved_n`. Grants and `reloptions` verified identical pre/post.                                                                                                     |
| `20260814093000` | `prd115_golden_fixture_115`            | Acceptance 5. Fixture 115 (29 assertions) on synthetic date `2030-04-26`. Zero residue.                                                                                                                                                                                                     |

⛔ **The splice pattern, and why it is not cleverness.** `push_plan_to_dispatch` is 24 kB of
conservation stop-ship, RC-01 §5(5a)/§5(5b) idempotency, M2M pairing and FIFO batch walking.
PRD-115 §3 requires the duplicate-unstarted, packed-row and conservation guards to stay
BYTE-IDENTICAL, and the only way to be certain of that is to never retype them. This follows
`20260709015534_drift_kill_p1_wire_push_and_stitch.sql`, which established the pattern on this
exact function. Byte-identity was then PROVEN rather than asserted: reversing exactly the three
insertions from the live v12 body reproduces the v11 md5.

⛔ **Record the post-image md5.** The next splice needs `487f33107819ce8335251e235ac7405e` as its
base, and will refuse to run without it.

## 2026-08-14 — PRD-022 groundwork: total-first pricing + the advisory flagger

Four migrations, forward-only. **These were applied through the Supabase MCP and have no `.sql`
file in `supabase/migrations/`** — they are recorded here because the registry is the only place
they exist in git. Reconstruct from `pg_get_functiondef` if a file is ever needed.

| version          | name                                         | notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| ---------------- | -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20260814104803` | `po_unit_price_guard`                        | First cut of the price guard.                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `20260814104915` | `po_unit_price_guard_fix_record_fields`      | Field-reference fix on the above.                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `20260814111855` | `po_price_total_first_flag_only`             | `total_price_aed` + `price_flag jsonb` on `po_additions` and `purchase_orders`; trigger fn `procurement_price_sync_and_flag` on both (BEFORE INSERT OR UPDATE) doing total↔unit sync and stamping `LOOKS_LIKE_LINE_TOTAL` / `PRICE_HIGH` / `PRICE_LOW`; helpers `peer_unit_price_v1`, `classify_procurement_price_v1`, `price_looks_like_line_total_v1`; RPCs `create_po_addition_v2`, `correct_procurement_unit_price_v1`; view `v_po_price_flags`. Backfill stamped 14 rows with `backfilled:true`. |
| `20260814112002` | `procurement_events_allow_price_flag_raised` | `event_type` CHECK += `'price_flag_raised'`.                                                                                                                                                                                                                                                                                                                                                                                                                                                          |

⛔ **Advisory forever.** The flagger never raises and never blocks. A flag is a jsonb column plus a
`procurement_events` row; the warehouse write always completes.

## 2026-08-15 — PRD-022: pricing_status, the review verdict, and total-first receive

Four migrations, forward-only. Cody ⚠️ approve with revisions — 4 required changes and 1 statement
deleted, all applied before DDL. Articles 1, 2, 3 + S-308, 4, 5, 7, 8, 12, 13, 15.

Source of truth for all four: `supabase/migrations/20260815092204_po_pricing_status_v1.sql` (the
annotated single-file form). Applied as four parts because a `CREATE OR REPLACE VIEW` failure would
otherwise have rolled back two 8 kB function bodies with it.

| version applied as                       | notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `po_pricing_status_v1`                   | `pricing_status text NOT NULL DEFAULT 'priced'` + CHECK `in ('priced','free_goods','unpriced')` on both tables (constant default → no rewrite). `procurement_events` CHECK += `'price_flag_reviewed'`. `procurement_price_sync_and_flag` extended with the three-block `pricing_status` section. **Column-level UPDATE lockdown on `po_additions`** (Cody): `REVOKE UPDATE FROM authenticated` then re-grant on the 14 pre-existing columns only, so `pricing_status` and `price_flag` are unreachable from the browser. |
| `po_pricing_status_v1_rpcs`              | `create_po_addition_v2` **dropped at 7 args and recreated at 8** with `p_pricing_status` (see `deprecated.md` — `CREATE OR REPLACE` cannot add a parameter, and an overload would have left the no-total path live). New `review_price_flag_v1(text,uuid,text,text)`. Anon `EXECUTE` revoked on `create_po_addition_v2`, `correct_procurement_unit_price_v1` and `receive_purchase_order_addition`.                                                                                                                      |
| `po_pricing_status_v1_view_and_backfill` | `v_po_price_flags` gains `pricing_status` **appended last** (mid-list insertion raises 42P16). Idempotent backfill: 3 `po_additions` + 18 `purchase_orders` received rows carrying no money → `unpriced` + `UNPRICED_RECEIPT` with `backfilled:true`. One summary `write_audit_log` row, not 21.                                                                                                                                                                                                                         |
| `po_pricing_status_v1_receive_path`      | `_mirror_po_addition_line_v1` carries `pricing_status` onto the mirrored line. `receive_purchase_order` line payload accepts `total_price_aed` + `pricing_status`; unit still accepted and counted as `legacy_unit_entry` / `legacy_unit_lines` in the `goods_received` payload.                                                                                                                                                                                                                                         |

⛔ **Trigger block ordering is load-bearing.** free_goods short-circuit → unpriced→priced reset →
the unpriced stamp, all **before** the existing `if not v_changed` early return, because a receive
transition is a status change and moves neither price nor qty. The stamp keys on
`v_recv OR v_prev_code = 'UNPRICED_RECEIPT'` rather than on `pricing_status` alone — that is
precisely what stops a flag cleared by `review_price_flag_v1` resurrecting on the next unrelated
edit. Proven in a rolled-back transaction across six transitions.

⛔ **`purchase_orders` qty edits still never rescale prices.** The `purchase_orders` branch has no
qty-derivation clause and this migration did not add one. Verified live: qty 10 → 50 left
`total_price_aed` at 25.00 and `price_per_unit_aed` at 2.5000.

⛔ **The Vitamin Well - Care row (`219fc9b2`) was NOT marked `free_goods`,** which is a deliberate
departure from the PRD text. Its total is 9.25, and `create_po_addition_v2` in the same migration
refuses to create such a row (`FREE_GOODS_WITH_PRICE`). Cody blocked it: a backfill must not seed a
state the canonical writer can neither reproduce nor repair. It stays `priced`, which is true.
`review_price_flag_v1(verdict='confirmed_correct')` is the instrument if it is ever flagged.

**Held, not applied:** `supabase/migrations/_HELD_prd022_po_additions_rpc_only.sql` — drops the
`field_staff_insert` and `warehouse_update` policies on `po_additions`. Gated on a one-week clean
soak; the four preconditions and their queries are in the file header. Earliest apply 2026-08-22.

**Fifth migration, post-advisor:** `po_pricing_status_v1_trigger_fn_revoke` — the security advisor
flagged `procurement_price_sync_and_flag()` as `anon`-executable via `/rest/v1/rpc/`. Inherited from
`po_price_total_first_flag_only`, not introduced here, but the body is replaced by this PRD so it is
in the blast radius. Revoked from `public`/`anon`/`authenticated`; trigger execution unaffected
(the trigger fires as table owner) and proven by a full receive afterwards.

⛔ **Left alone deliberately:** the advisor's `security_definer_view` ERROR on `v_po_price_flags`.
**All 82 views in `public`** lack `security_invoker`, so this is a systemic pre-existing posture, not
a PRD-022 regression. Flipping one view in isolation would start applying RLS for its callers and
change behaviour. Recorded for a dedicated unit; `CREATE OR REPLACE VIEW` preserved whatever the
2026-08-14 migration set.

---

## 2026-08-19 — `machine_location_categories_lookup`

**What:** New lookup `machine_location_categories` + `machines.location_category` (nullable, FK) +
`idx_machines_location_category` + one-time backfill from `pod_location`
(Legacy/Lebanon/Office/Central/DIP/China). Seeded: in_market, office, dip, china, lebanon, legacy,
other. RLS on the lookup: `mlc_read` (SELECT, authenticated), `mlc_admin_write` (ALL,
operator_admin/superadmin/manager via user_profiles).

**Why:** machine section grouping in /app/pods and /field/config/machines was hardcoded FE buckets;
adding a market (Lebanon) required a deploy. Sections are now data. `wins_over_active=true`
(lebanon, legacy) keeps those machines out of In Market even when status=Active.

**Cody:** ⚠️ approved with revisions (Articles 2, 3, 12, 14) — Article 3 note: the edit-form write of
`location_category` rides the existing `admins_manage_machines` direct-update surface (Batch 5 /
RC-04 debt); fold into the future canonical `update_machine` RPC.

**Rollback:** `ALTER TABLE machines DROP COLUMN location_category; DROP TABLE
machine_location_categories;` (forward-only preferred — write a new migration).
| `prd016d_receive_po_addition_into_machine` | 1,4,8,12 | ✅ Applied | 2026-08-21 | NEW DEFINER composing receive_purchase_order_addition + record_actual_refill so a shop→machine field purchase can be received without inventing warehouse stock. Unblocks the pending-addition banner. FE modal replaces window.prompt. Cody ✅. |
| `prd113b_internal_move_pod_level_pairing` | 12,16 | ✅ Applied | 2026-08-21 | is_internal_move_dispatch gains a pod-product-level fallback (gated on the destination Add New being m2m-self with no from_warehouse_id) so multi-flavour in-machine moves stop surfacing as warehouse returns. 14 legs reclassified, 0 phantom WH rows, 5 stamped. Cody ✅. |
| `prd118_i_commitment_batch_grain_and_breakdown` | 12,16 | ✅ Applied | 2026-08-31 | `v_dispatch_open_wh_commitment` (PRD-110 D-28 canonical open-WH-claim object) gains additive columns `from_wh_inventory_id` + `driver_confirmed_breakdown` so the packing screen can net commitment at BATCH grain instead of product grain. Predicate/shape unchanged — exposure only. Fixed a 3-machine Sunbites packing deadlock (batches reading "no stock" while a sibling batch of the same product carried the committed units). Backend applied live 2026-08-31 (prod schema_migrations 20260831041646 + 20260831041717, reconstructed here as one file — incremental diff between the two not preserved outside prod); FE `fix(prd-118): item I` shipped same day. Cody ✅ (Article 16 — additive, no competing object). |
| `prd119_p1_disposition_events` | 1,2,4,7 | ✅ Applied | 2026-09-02 | New append-only ledger `disposition_events`, replaces the returns Google Sheet. RLS + explicit `authenticated` REVOKE (S-308) — no permissive INSERT policy, writable only by DEFINER RPCs. Cody ✅. |
| `prd119_p1_48h_dispatch_guard` | 1,4 | ✅ Applied | 2026-09-02 | `approve_refill_plan` gains an absolute (no-override) 48h floor beneath the existing 7-day override-able check; `pick_wh_batch_for_machine`/`repin_dispatch_batch`/`get_shelf_fefo_options` never surface a batch ≤48h from expiry. `bind_dispatch_fefo`/`pack_dispatch_line` deliberately untouched (live packing writers that day). Cody ✅. |
| `prd119_p1_m2m_b1_add_dispatch_row_source_check` | 4,16 | ✅ Applied | 2026-09-02 | `add_dispatch_row` no longer mistags a same-machine move as `is_m2m=true`. Live-state check before writing found B2/B3 already shipped under a separate PRD-117 effort with a superior pairing-aware classifier; only B1 remained. Cody ✅. |
| `prd119_p1_v_wm_confirmations` | 2,16 | ✅ Applied | 2026-09-02 | New view — the single Warehouse Confirmations queue, surfaces a picked-up Remove line not yet WH-approved. Fixed in testing: qty=0 leakage, `2099-12-31` sentinel misread as a real expiry driving a bogus redeploy proposal. Cody ✅. |
| `prd119_p1_wm_confirm_line` | 1,4,6,7,8 | ✅ Applied | 2026-09-02 | New DEFINER — the only write to `warehouse_inventory`/`disposition_events` for a `v_wm_confirmations` line (restocked/redeploy_pending/waste), composes `warehouse_expire_writeoff` for the waste path. Cody ✅. |
| `prd119_p2_pod_inventory_expiry_grain` | 2,12,16 | ✅ Applied | 2026-09-02 | Closes PRD-118 item J (deferred there): widens `idx_pod_inv_active_shelf` to one Active row per machine+shelf+product+expiry. Full reader audit in the same migration fixed `v_pod_inventory_latest`, `v_machine_expiry_batches` (the exact defect PRD-114 named), `approve_pod_inventory_edit`'s add_stock branch, `record_variant_correction`'s new-variant lookup, `v_pod_inventory_shelf_mismatch`'s multi_active_rows verdict. Cody ✅. |
| `prd119_p2_pod_sales_decrement_kill_switch` | 1,4 | ✅ Applied | 2026-09-02 | New `refill_qa.feature_flag` row `pod_sales_decrement_enabled` (default off). `auto_decrement_pod_inventory` matched a sale to `pod_inventory` by product name across the whole machine, no shelf predicate — 28% of resolvable events drained the wrong lane. Cody ✅. |
| `prd119_p2_resync_date_rows_only` | 1,4,7 | ✅ Applied | 2026-09-02 | `resync_pod_inventory_from_weimi` restricted to DATE?-row-only corrections; a dated lot is the human-touch-only ledger (D0) and must never be silently rewritten by the drift engine. Blocked drift now surfaces via `prd119_resync_dated_lot_blocked` alert instead. Cody ✅. |
| `prd119_p3_apply_expiry_check` | 1,4,6,7,8 | ✅ Applied | 2026-09-02 | New canonical driver-tap writer (`removed \| not_there \| date_read`), composes `correct_expiry_v1` (role gate widened to `field_staff`, scoped `p_scope='pod'`). Cody ✅. |
| `prd119_p3_wm_queue_driver_tap_union` | 2,16 | ✅ Applied | 2026-09-02 | `v_wm_confirmations` generalized to a second source: open driver-tap `removed_at_machine` disposition events, chained via `superseded_by_event` on confirm instead of stamping a nonexistent dispatch row. Cody ✅. |
| `prd119_p3_get_expiry_sanity_checks_rescope` | 4,16 | ✅ Applied | 2026-09-02 | Window 7d→3d; NULL-expiry (DATE?) rows now included as `severity='date_unverified'` (previously excluded entirely). Cody ✅. |
| `prd119_p3_apply_expiry_check_payload_enrich` | 8,12 | ✅ Applied | 2026-09-04 | Additive: `apply_expiry_check`'s `day_close_events` payload gains `product_name`/`severity`/`qty` for the `not_there`/`date_read` branches, so the Day Close log is self-describing rather than joining live against a row that may already be archived by view time. Cody ✅. |
| `prd119_p4_migration_sheet_load` | 1,7,12 | ✅ Applied | 2026-09-04 | One-time backfill of the returns Google Sheet (113 rows/365 units at load time) into `disposition_events` (`source='migration_sheet'`). 99 rows loaded (97 waste, 2 removed_at_machine); 14 flagged for CS, not guessed. Idempotency guarded. Cody ✅. |
| `prd119_p4_disposition_reporting_and_redeploy` | 1,4,6,7,16 | ✅ Applied | 2026-09-04 | `v_disposition_ledger`, `v_redeploy_outcomes`, `v_waste_by_sku_90d` (canonical read objects) + `confirm_disposition_redeploy` — closes the `redeploy_pending → redeployed` transition `wm_confirm_line` could open but never close, same DEFINER-owner append-only chain pattern. Cody ✅. |
| `prd119_p4_wm_alert_queue` | 1,4,11,16 | ✅ Applied | 2026-09-04 | `v_wm_alert_queue` (dedupes 1,010 raw `bug010_wh_approval_stuck` rows to 228 actionable lines, 337 `prd016_guardrail2_return_variant_uncorrected` stay 1:1) + `acknowledge_wm_alert` (sole writer of `monitoring_alerts.acknowledged`, acks by dedup key not raw alert_id). Adds the missing `check_expiry_unvalidated_nightly` cron job (PRD-118 K2 had never actually been scheduled). Cody ✅. |
| `prd119_p4_propose_wh_redeploy` | 1,4,6,7 | ✅ Applied | 2026-09-04 | New DEFINER — opens a redeploy proposal directly off an aging `warehouse_inventory` batch for admin triage, composes with `confirm_disposition_redeploy`. Caught in testing: first fixture carried the `2099-12-31` sentinel, silently computed a nonsense `waste_by` — added an explicit guard before applying. Cody ✅. |
