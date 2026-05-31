# PRD-015 Execution Log

Migration files only; nothing applied to prod (per-phase sign-off cadence).

## Phase A — machine include/exclude toggle

| AC                                  | Status                                                                 | Artifact                                                                                                                       |
| ----------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| AC#10 data model (`is_included`)    | ✅ file written                                                        | `supabase/migrations/20260531090000_phaseF_mtv_is_included.sql`                                                                |
| AC#10 picker ON CONFLICT reset      | ✅ file written (verbatim+1 line, diff-gate before apply)              | `supabase/migrations/20260531090200_phaseF_picker_reset_is_included.sql`                                                       |
| AC#11 toggle RPCs                   | ✅ file written                                                        | `supabase/migrations/20260531090100_phaseF_machine_inclusion_rpcs.sql` (`set_machine_inclusion`, `bulk_set_machine_inclusion`) |
| AC#13 FE (RefillPlanningTab)        | ✅ built; npx next build green; 0 new lint errors                      | `src/app/(app)/refill/RefillPlanningTab.tsx` (+331/-167)                                                                       |
| AC#12 engine/commit honor inclusion | ⏳ Phase B (`build_draft_for_confirmed`) + engine `is_included` filter |

**Cody verdict (Phase A backend):** ✅ Approve. Articles 1,3,4,8,12,14. Resolved: (1) toggle RPC role tier set to **operator_admin/superadmin/warehouse** per CS (manager dropped — no such users; warehouse manager curates the list); confirm_machines_to_visit + build_draft_for_confirmed stay operator_admin/superadmin. (2) migration 3 must be diffed against live `pg_get_functiondef` before apply.

**New scope (CS):** Phase C gets **C3** — add `warehouse` to the role check of `edit_pod_refill_row`, `stop_pod_refill_row`, `restitch_after_edits` (keep operator_admin/superadmin; tier-only widening, locked-row guards intact). `find_substitutes_for_shelf` already allows warehouse. Cody review.

**Apply order (after sign-off):** 090000 (column) → 090100 (RPCs) → 090200 (picker patch).

**Open question for CS:** toggle RPC role tier (include `manager`?).

## Phase B — decouple pick from engine — files written, Cody ✅

| AC                              | Status                                                                                                                                                                                                                                                                                                                                                | Artifact                                                                                                                                                                     |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| AC#1 build_draft_for_confirmed  | ✅ file                                                                                                                                                                                                                                                                                                                                               | `20260531091000_phaseG_build_draft_for_confirmed.sql` (gate0→awaiting_confirmation; no_included_machines guard; engine add+swap; no re-pick; role operator_admin/superadmin) |
| AC#2 cron 13 repoint            | ✅ file                                                                                                                                                                                                                                                                                                                                               | `20260531091100_phaseG_cron13_repoint_build_draft.sql` (cron.alter_job → build_draft_for_confirmed; auto_generate_draft documented manual-only)                              |
| AC#3 human confirm gate         | ✅ via FE (AC#13 commit) + build_draft gate0; cron never auto-confirms                                                                                                                                                                                                                                                                                |
| AC#12 engine honors is_included | ⚠️ DEFERRED to refill-brain — engine_add_pod (3 mtv refs) + engine_swap_pod (5 mtv refs) need `AND COALESCE(is_included,true)=true` on machine-selection reads. 30KB blind reproduction unsafe. build_draft enforces route-level no_included_machines; FE blocks committing excluded. Partial-exclude still plans excluded machines until this lands. |

**Cody verdict (Phase B):** ✅ Approve (Articles 1,4,8,11,12). AC#12 engine gap tracked. Add build_draft_for_confirmed to RPC_REGISTRY.
**Apply order:** 091000 → 091100.

## Phase B — decouple pick from engine — (superseded by row above)

## Phase C — launch gate + alert + C3 — files written, Cody ✅

| AC                         | Status  | Artifact                                                                                                                                                             |
| -------------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| AC#8 launch gate           | ✅ file | `20260531092100_phaseG_c1_launch_gate.sql` — `assert_product_launch_ready(uuid,text[])` read-only INVOKER; caller-enforced (no over-broad trigger)                   |
| AC#9 unmatched-WEIMI alert | ✅ file | `20260531092200_phaseG_c2_unmatched_weimi_alert.sql` — `cron_unmatched_weimi_alert()` → monitoring_alerts, daily 03:15 UTC                                           |
| C3 warehouse tier          | ✅ file | `20260531092000_phaseG_c3_warehouse_tier_pod_refill_edits.sql` — edit_pod_refill_row + restitch_after_edits +warehouse (verbatim+role); stop_pod_refill_row inherits |

**Cody verdict (Phase C):** ✅ Approve (Articles 1,3,4,7,8,11,12,14). Notes: C1 gate is caller-enforced (launch tooling must call it; trigger deliberately omitted to avoid blocking non-launch swaps); C3 verbatim-diff vs live before apply. Register new fns in RPC_REGISTRY.
**Apply order:** 092000 (C3) → 092100 (C1) → 092200 (C2).

## Phase C — launch gate + alert — (superseded by row above)

## Phase D — pod_inventory reconciliation (gated, DIFFS ONLY) — files written, Cody ✅

| AC                    | Status                                                                                                       | Artifact                                                                                                                                                                                          |
| --------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| AC#4 mismatch view    | ✅ file, tested read-only                                                                                    | `20260531093000_phaseG_d1_pod_shelf_mismatch_view.sql` (verdicts: 58 product_mismatch / 279 multi_active / 295 no_pod_row / 29 weimi_unmatched / 93 ok)                                           |
| AC#5 reconcile RPC    | ✅ file                                                                                                      | `20260531093100_phaseG_d2_reconcile_pod_inventory_shelf.sql` (confirm=false diff / confirm=true archive+seed; archive-only; reason>=10; lock+NULL-product guards; role operator_admin/superadmin) |
| AC#6 one-active index | ✅ file (gated)                                                                                              | `20260531093200_phaseG_d4_one_active_pod_per_shelf.sql` (pre-check raises until multi-active cleared; apply LAST)                                                                                 |
| AC#7 Plaay reconcile  | ◐ DIFFS ONLY emitted (20 shelves, read-only) — NO mutation; awaiting per-shelf CS sign-off then confirm=true |

**D3 Plaay-scoped diff (read-only, 20 shelves):** ADDMIND-1007 A04(4)/A07(5); HUAWEI-2003 B14(3, pod=Truffles vs WEIMI=Protein Balls 2P); MC-2004 A07(2)/B11(no_pod_row); MINDSHARE-1009 A06(no_pod_row); NOOK-1019 A06(2)/A08(3); NOVO-1023 A04(9!)/A07(6); OMDBB-1020 A05(3)/A07(4); OMDCW-1021 A07(Krambals→Plaay Tablets product_mismatch)/A08(5); USH-1008 A06(3); VML-1003 A06(4, Tamreem→Plaay)/A08(5); WH1-2002 B05/B06/B07(no_pod_row). Each reconciled individually with diff shown, on CS sign-off.

**Cody verdict (Phase D):** ✅ Approve (Articles 1,3,4,5,6,7,8,12,14). reconcile stays operator_admin/superadmin (NOT warehouse — destructive archive class). pod_inventory audit trigger confirmed. Register view + reconcile in RPC_REGISTRY.
**Apply order:** 093000 (view) → 093100 (reconcile) → [per-shelf confirm=true after sign-off] → 093200 (index LAST).

## Phase D — pod_inventory reconciliation (gated) — (superseded by row above)
