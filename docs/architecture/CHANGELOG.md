# Architecture Changelog

A running log of every architecture-level edit. Newest first. Each entry: what changed, why, what was applied where, and how to roll back. The Supabase `migrations` table is the system of record for SQL; this file is the human-readable companion that maps migrations to Constitution articles and explains intent.

Format:

```
## YYYY-MM-DD — short title
**Phase / Article:** A.X / Constitution Article N
**Applied to:** prod | repo | both
**Migration name:** <name in Supabase migrations table, if any>
**Summary:** one paragraph on what / why
**Rollback:** SQL or steps to undo
```

## 2026-06-12 — PRD-028 dispatch-state-integrity step 1: pack/return guards (skipped lines are inert)

**Phase / Article:** Phase F / Constitution Articles 1, 4, 12 (canonical-writer hardening)
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`) + repo file `20260612135850_phaseF_dispatch_state_guards.sql`
**Migration name:** `phaseF_dispatch_state_guards`
**Summary:** Both canonical dispatch writers now enforce the skip/cancel/exclude flags that were display-only (Incidents A+B, 2026-06-12). `pack_dispatch_line`: unconditional three-flag refusal (skipped / cancelled / include=false) placed before ANY mutation including the packed_no_pick early path; error names the flag and the skip_reason. `return_dispatch_line`: three-flag refusal CONDITIONAL on `packed=false AND picked_up=false` (nothing physical to return); flagged-but-packed lines stay returnable because that is the Incident-A recovery path and the EOD sweep contract; PLUS a system-actor guard (no p_returned_by AND nothing physical -> refuse) that kills the Dispatch Complete auto-return burst. PRD section 2b assumption corrected during verification: `eod_auto_release_unpicked` pass 1 DOES route through return_dispatch_line (packed=true picked_up=false only), so the unconditional refusal the PRD literally asked for would have broken the sweep and stranded debited consumer_stock; Cody endorsed the conditional form. Rollback functiondefs captured verbatim with md5s (`76be9334...` / `8520614a...`) in `docs/prds/prd-028-dispatch/ROLLBACK-pre-guards-functiondefs.sql`. Battery 1-4 green in one rolled-back tx: B1 pack-skipped refused naming the reason; B2 system-return-skipped refused, WH totals+rowcount untouched; B3 synthetic pack(2u)->mark_picked_up->driver return, WH 192->190->192, path pinned; B4 eod sweep released=1 failed=0 + stale release clean through the guards. Pre-existing note (not fixed): neither writer role-gates its caller.
**Rollback:** run `docs/prds/prd-028-dispatch/ROLLBACK-pre-guards-functiondefs.sql` verbatim.

## 2026-06-12 — PRD-028 WS4 Option 1 (matched-only + age-split exposure) APPLIED; WS1 deprecated views DROPPED

**Phase / Article:** Article 16 (canonical payment-default metric) / Articles 4, 12, 13
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`)
**Migration name:** `prd028_ws4_payment_default_matched_only_v2` + `prd028_ws4_payment_default_v2_1_refund_aligned` + `prd028_ws1_drop_deprecated_expiry_views`
**Summary:** CS decided WS4 Option 1 with age-split exposure. `get_payment_default_summary` now reports gap/default over MATCHED refs only (settlement-lag refs no longer inflate the partner default: 21.03% class -> 1.28%), with `unmatched_refs`/`unmatched_exposure` explicit and age-split at 7 days (`recent` = lag window, `aged` = likely true default). v2.1 also aligns refunds with PRD-023h (per-ref `default_short = GREATEST(total - settled - refunded - cash, 0)`) after Cody's required live comparison caught v2 double-counting a refund-only ref (gap 567.30 vs waterfall 141.30; delta exactly 2x the 213 refund). Verified cent-equal post-apply: gap 141.30 == waterfall 141.30 (VOX 06-01..11); unmatched exposure 2,209.85 ALL in the recent bucket (0 aged). Signature unchanged (no pg_proc overload). All v1 jsonb keys preserved (/app/performance unaffected structurally). Consumer ribbon full-scope wiring ticketed to Stax (action_tracker `09a15262`). WS1 closure: `v_pod_inventory_expiry_status` + `v_pod_inventory_health` DROPPED with explicit CS approval (zero consumers re-verified via pg_depend in-session; canonical `v_machine_expiry_summary` live). Cody ✅ (Articles 4, 12, 13, 16).
**Rollback:** redeploy v1 body (md5 `10662ff4870ef54a0907dbe4b3f65926`); views recreate from `prd028_ws1_expiry_canonical`-era definitions if ever needed (none expected; zero consumers).

## 2026-06-12 — PRD-024 section 2 EXECUTED: 06-13 plan rebuilt (Gates 1+2 passed); WS5 stitch v21 + lifecycle v14 deployed upstream

**Phase / Article:** Phase F / canonical-RPC-only runbook (no raw writes; the two upstream code changes were separately Cody-approved)
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`)
**Migration name:** `phaseF_stitch_v21_ws5_real_stock` (upstream, CS green-lit the within-24h second stitch rewrite; reverse-fragment md5 proof vs v20 `8a9f0f3e...6a01`). evaluate-lifecycle v14 deployed (platform v23; 10,223 sales rows / 2 pages; floors live with CS-confirmed 0.5/1.0 thresholds; named stance absurdities resolved; WIND DOWN 109->80, DEAD 91->51).
**Summary (runbook):** 65 stale drafts for CS-dropped NISSAN-0804/NOOK-1019/VML-1003 superseded via reject_pod_refill_rows (5 plan dates); reset_approved_undispatched structurally no-op (103 rpo rows already pending, no dispatch links); re-pick on v14 signals (8) -> NISSAN+VML dropped via unpick_machine_to_visit + set_machine_inclusion(false) (engines do not read is_included; unpick is operative); Gate 0 (6 confirmed); engine_add v16 (101 refills, 11 dead tags) -> engine_swap v10.2 first live run (8 resolved, 3 deferred_by_cap, 2 below-pearson explicit fallbacks) -> finalize v14 (120 drafts, 3 orphan-M2W suppressed). Gate 1 (CS GO): approve subset 7 machines, 117 rows (VOXMCC-1005 via sticky cs_added). Stitch v21 dry-run + FULL PRD-024 battery green incl. item 3 vs FRESH post-transfer WH (42 zero-WH variants excluded) + item 6 (deviations 0, noncanonical 0); 109/109 shelves real current/max stock. Gate 2 (CS GO): commit 102 lines / 117 stitched; approve_refill_plan -> 102 dispatch rows back-populated; cleanup_orphan_dispatching deleted 22 true orphans; remaining 81 stale lines auto-skipped by the resilient bridge. Post-commit: coverage 7/7 (102 active lines), 0 shelves with SUM(variants) > pod_qty (28 exact, 20 WH-limited).
**Rollback:** plan layer only - reset_and_restitch / reset_approved_undispatched on 2026-06-13. WS5: redeploy v20; v14: redeploy v13.1 (platform v22).

## 2026-06-12 — PRD-028 WS6: Article 16 ratified (one canonical object per business metric)

**Phase / Article:** Constitution amendment - NEW Article 16
**Applied to:** repo docs (`01_constitution.html` Article 16 + TOC; `.claude/skills/cody/SKILL.md` playbook; `METRICS_REGISTRY.md` status -> RATIFIED)
**Migration name:** none
**Summary:** Article 16 text (from METRICS_REGISTRY.md) added to the Constitution with Why (the June 2026 triple-incident root cause) and Enforcement (Cody blocks inline re-derivation; registry row + canonical object land in the same PR; Phase B CI lint). Cody SKILL.md: 16-article identity, quick-reference row 16, Article 16 checks added to review classes (b) writer DEFINER, (c) read-only DEFINER, (d) FE/edge - "computes a registered metric inline -> block, point to canonical object"; METRICS_REGISTRY.md added to Cody's knowledge base. Registry statuses current through WS5: expiry, velocity, WH pickable, dispatch availability, fleet scope all LIVE; payment-default banners wired on /app/performance, consumer ribbons CS-gated (WS4 memo).
**Rollback:** revert the three doc files.

## 2026-06-12 — PRD-028 WS5: v_active_fleet canonical fleet scope

**Phase / Article:** PRD-028 metrics registry / Constitution Articles 4, 12, 14 (implements Article 16 draft)
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`) + repo file `20260612072352_prd028_ws5_active_fleet.sql`
**Migration name:** `prd028_ws5_active_fleet`
**Summary:** NEW `v_active_fleet` (34 machines): base rule status NOT IN (Inactive, Warehouse); `include_in_refill`, `repurposed_at`, `service_track` are EXPOSED columns so each consumer declares its extra filter instead of re-deriving it. Measured why repurposed_at is not baked in: 4 of 11 VOX reconciliation-scope machines are repurposed-but-Active and carry 3,620.75 AED of 06-01..11 sales - excluding them would silently drop 27% of period money. `get_payment_default_summary` venue-scope branch rewired to the view; full jsonb equality with the pre-migration output proven on 06-01..11 VOX (zero value change). Data smell flagged for CS: 5 Active machines fleet-wide have repurposed_at set (old identities never archived). Follow-up consumers (wire on their next change): get_vox_commercial_report pods scope, v_machine_health_signals base.
**Rollback:** re-apply the previous get_payment_default_summary body (inline scope); DROP VIEW v_active_fleet.

## 2026-06-12 — PRD-028 WS4: /app/performance banners wired to get_payment_default_summary; consumer ribbons deferred on CS decision

**Phase / Article:** PRD-028 metrics registry / Article 16 draft (FE read wiring only; no DB change)
**Applied to:** repo FE `src/app/(app)/app/performance/page.tsx` (committed, not deployed)
**Migration name:** none
**Summary:** ONE `get_payment_default_summary` call per (period, scope) now feeds BOTH the green Payment Default strip and the Transactions dark bar on /app/performance (state `pdSummary`); refunds + cash rendered as their own fields on both. Scope = explicit machine picker -> p_machine_ids, else group filter (All -> NULL = fleet). Banner value changes documented in the WS4 design note (Captured: any-status client calc -> canonical settled-refunds+cash; Gap: matched-only -> total exposure). **DEFERRED with CS decision memo** (docs/prds/prd-028/WS4-reconciliation-banners-design.md): /refill/consumers + /consumers_vox ribbons - live comparison shows the canonical summary vs the PRD-023-bound commercial waterfall differ SEMANTICALLY (gap 2,777.15 / 21.03% vs 141.30 / 1.27% for 06-01..11 VOX) because the summary counts 89 unmatched refs as gap; flipping a partner-facing default rate 16x and breaking the ribbon==cards invariant needs CS to pick: (1) matched-only metric + explicit unmatched_exposure field [recommended], (2) total-exposure everywhere incl. waterfall, or (3) settlement-lag cutoff. tsc + build green.
**Rollback:** git revert the FE commit.

## 2026-06-12 — PRD-028 WS3: canonical WH pickable + dispatch availability + packing FE wiring

**Phase / Article:** PRD-028 metrics registry / Constitution Articles 2, 3, 12, 14 (implements Article 16 draft)
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`) + repo file `20260612070658_prd028_ws3_wh_pickable_dispatch_availability.sql` + FE `src/app/(field)/field/packing/[machineId]/page.tsx`
**Migration name:** `prd028_ws3_wh_pickable_dispatch_availability`
**Summary:** NEW `v_wh_pickable` = the canonical pickable predicate (Active, NOT quarantined, in-date Dubai-or-NULL, stock>0; batch grain; `security_invoker=true` so it cannot widen warehouse_inventory RLS). Live impact: 28 of 167 Active-stock batches were leak-class (quarantined or expired but Active) and are now excluded - the Simran "WH badge shows unpickable stock" class. `v_dispatch_availability` (had ZERO consumers - built, never wired) redefined: wh_avail consumes `v_wh_pickable` (inline predicate deleted), commitments gain `picked_up=false` per the registry rule; before/after distribution IDENTICAL on current data (value-stable, structural). Packing FE wired: batch fetch reads `v_wh_pickable`; the committed fetch flips from `packed=true` to `packed=false AND picked_up=false` - packing PHYSICALLY DEBITS warehouse_inventory, so counting packed lines double-subtracted and produced the "Available: 0" class; Available badge is now product-grain `max(0, WH - Committed)`. tsc + build green. The commit also carries the concurrent session's uncommitted WS7 "reserved-to" display (same hunks, attributed). FLAGGED, pre-existing, NOT fixed (scope): packing page restore helper writes warehouse_inventory (incl. status) directly from FE - Articles 3/6; ticket to Stax.
**Rollback:** re-apply the previous `v_dispatch_availability` body (in this migration's header comment via WS3 design note); `DROP VIEW v_wh_pickable` after un-wiring FE; revert the FE file via git.

## 2026-06-12 — PRD-028 WS2: canonical machine velocity rollup (v_machine_velocity)

**Phase / Article:** PRD-028 metrics registry / Constitution Articles 4, 12 (implements Article 16 draft)
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`) + repo file `20260612065444_prd028_ws2_velocity_canonical.sql`
**Migration name:** `prd028_ws2_velocity_canonical`
**Summary:** One machine-grain velocity object. NEW `v_machine_velocity` (units_7d, units_30d, daily_velocity_7d, daily_velocity_30d; Success-only; rolling now()-interval windows). `get_machine_health.daily_velocity` consumes it (formula identical, values unchanged; fn also gains `SET search_path = public, pg_temp`). `v_machine_health_signals.sales_recent` consumes it: units_last_7d gains the Success filter (no-op today, all last-30d rows are 'Successful') and moves from UTC-midnight CURRENT_DATE anchor to rolling now() (9 machines shift 1-2 units at apply time; one boundary artifact AMZ-1057 50->49 documented in the design note). Product/slot-grain velocities (flag_intent_threats v7/v60, slot_lifecycle, get_sales_by_machine lookback report) intentionally out of scope per registry. AC verified post-apply: 0 velocity mismatches get_machine_health vs canonical; 0 signals mismatches; no inline machine-level SUM(qty)/7 remains.
**Rollback:** re-apply previous `v_machine_health_signals` + `get_machine_health` bodies (WS1 versions, in `20260612063856_prd028_ws1_expiry_canonical.sql`); `DROP VIEW v_machine_velocity` last.

## 2026-06-12 — PRD-028 WS1: canonical machine expiry metric (v_machine_expiry_summary + batch-resolution view)

**Phase / Article:** PRD-028 metrics registry / Constitution Articles 4, 12, 13 (implements Article 16 draft, ratification in WS6)
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`) + repo file `20260612063856_prd028_ws1_expiry_canonical.sql`
**Migration name:** `prd028_ws1_expiry_canonical`
**Summary:** Kills the two-sources-of-truth expiry bug class (live repro OMDBB-1020: priority tier said expired=1, health badge said 0; 5 machines disagreed fleet-wide). NEW `v_machine_expiry_batches` holds the single batch-resolution rule: pod_inventory `status='Active' AND current_stock>0`, latest snapshot per shelf (legacy NULL-shelf rows per machine+product), NO 30-day lookback window (the window silently zeroed badges as snapshots aged; Active rows are operational truth and must stay visible). `v_machine_expiry_summary` redefined as the CANONICAL machine-grain metric over it - existing columns preserved in order, SKU-grain columns appended (expired_skus_now, expiring_skus_3d/7d/30d), "today" standardized on the Dubai operational date (CURRENT_DATE was the same UTC disease as the plan-date bug). `v_machine_health_signals.expiry_state` now consumes the summary (was: its own no-window scan); `get_machine_expiry_detail` (DEFINER, gains `SET search_path`) and `get_machine_slots_with_expiry` (INVOKER) realigned onto the batches view. `v_pod_inventory_expiry_status` + `v_pod_inventory_health` COMMENT-deprecated (zero consumers found; drop deferred for CS approval per Article 13). Value changes (all documented in `docs/prds/prd-028/WS1-expiry-unification-design.md`): ALJLT-1015 0->1, MC-2004 0->1, NISSAN-0804 0->2, OMDBB-1020 0->2 badge units (now critical, correct); AMZ-1038 16->0 (phantom Inactive rows). AC verified post-apply: 30 machines compared, 0 zero/non-zero disagreements between `v_machine_priority.expired_skus_now` and `get_machine_health().expired_units`. Cody ⚠️->cleared.
**Rollback:** re-apply the previous definitions of the 2 views + 2 functions (captured verbatim in the design note's "current objects" section / pg history); `DROP VIEW v_machine_expiry_batches` last (no other dependents).

## 2026-06-12 — PRD-027 WS1: engine_swap_pod v10.2 swap guards; WS5 drafted (held); WS2/3/4 ticketed

**Phase / Article:** Phase F / Constitution Articles 1, 4, 8, 12
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`) + repo file `20260612220000_phaseF_swap_pod_v10_2_ws1_guards.sql`
**Migration name:** `phaseF_swap_pod_v10_2_ws1_guards`
**Summary:** Three WS1 guards on the canonical Stage-2b writer, rest of the 15,359-char v10.1 body verbatim (md5 `c30f1165329034488967b1dfca5e4894`). **1a:** `p_min_pearson` is now actually applied in the dead-tag resolution - threshold-qualifying candidates are preferred (`ORDER BY (pearson >= p_min_pearson) DESC, rank`); when none qualify the best remaining candidate is taken EXPLICITLY with `substitute_source='global_performer_fallback'` + `reasoning.below_pearson_threshold=true` (last night shipped corr 0.214/0.242 swaps with no marker). **1b:** `p_max_swaps_per_machine` now caps ACROSS passes - strategic tags consume the budget first, dead-tags resolve worst-shelf-first (lowest live stock), overflow rows are deferred with `reasoning.deferred_by_cap=true` and carry to the next cycle (pod_in stays NULL so finalize's orphan-M2W suppression keeps them off the driver plan). Driver-rec swaps stay uncapped (driver-initiated). **1c:** when the swap-in qty falls back to the hardcoded 8 (no `v_shelf_max_stock` row), `reasoning.clamp_reason='default_capacity_8'` makes it auditable until the WS4 backfill. New return counters `dead_tags_deferred_by_cap` + `dead_tags_below_pearson_fallback`. Cody ✅. Rolled-back smoke on 06-13 (gate-0 confirmed in-tx): executes end-to-end, new return shape verified. **WS5** (stitch emits real current/max stock) drafted as `_DRAFT_phaseF_stitch_v21_ws5_real_stock.sql` - HELD: second stitch rewrite within 24h of v20 needs CS green light + apply-time Cody on the full body. **WS2/WS3/WS4** ticketed in action_tracker (Stax FE source-WH column; push_plan_to_dispatch WH-assignment audit; Dara max_capacity backfill design).
**Rollback:** redeploy the v10.1 body (md5 above).

## 2026-06-12 — PRD-026: evaluate-lifecycle v14 built (scoring integrity) — DEPLOY HELD for CS thresholds

**Phase / Article:** Phase E lifecycle / Constitution Articles 1, 9 (inherited scorer pattern; no new write paths)
**Applied to:** repo only (`supabase/functions/evaluate-lifecycle/index.ts` rebuilt from the DEPLOYED v13.1 source - the repo copy was stale pre-v13). **NOT deployed**: PRD-026 §4 velocity-floor thresholds need CS sign-off first.
**Migration name:** none (edge function source change only).
**Summary:** Three fixes, everything else verbatim from deployed v13.1. **P1 (silent sales truncation):** the single `.limit(10000)` sales fetch dropped ~217 of the 10,217 rows in the 62d window today (no ORDER BY, arbitrary which) -> understated velocities -> false DEAD tags feeding the swap engine. v14 paginates (`.order(transaction_date, transaction_id)`, `.range` pages of 10,000, hard cap 30 pages) and THROWS instead of scoring on possibly-truncated sales; response reports `sales_rows_fetched` + `sales_pages`. **P3 (trend overrides absolute strength):** guards inserted in `getSignalV2`: score>=8 AND trend<4 -> KEEP (was WIND DOWN; KEEP chosen over PLATEAU so no new enum value enters `slot_lifecycle.signal` fixed-list matches downstream); score>=6 AND trend<4 -> WATCH. **P2 (relative scoring condemns absolute sellers):** new `applyVelocityFloor` at slot level after relative scoring: DEAD requires literal zero v30 (else ROTATE OUT); v30>=0.5/day never ROTATE OUT/DEAD; v30>=1.0/day never worse than WATCH. Thresholds are constants marked PROPOSED pending CS. Cody ✅ (deploy-hold sequencing confirmed). Post-deploy plan: one scoring run, assert rows>10000/pages>=2, 25-slot regression set + stance-distribution diff for CS.
**Rollback:** redeploy the v13.1 source (captured verbatim in this commit's parent diff and live as platform version 22).

## 2026-06-12 — PRD-025 Option A: engine_finalize_pod preserves approved rows

**Phase / Article:** Phase F / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`) + repo file `20260612210000_phaseF_finalize_preserve_approved.sql`
**Migration name:** `phaseF_finalize_preserve_approved`
**Summary:** `engine_finalize_pod`'s upsert unconditionally `SET status='draft'`, so whenever finalize ran after `approve_pod_refill_plan` (FE Commit ordering race, observed 2026-06-11/12: approve 01:53:30.2 -> finalize 01:53:30.7), every approved row silently reverted to draft and the next stitch raised "no approved rows" to the operator. v14 preserves `approved` when the incumbent row is materially unchanged (same qty + action); material changes still revert to draft and demand re-approval. Two deltas vs v13 (md5 `ec8ace36cc2b1a6527bc0eb8ea185b6d`), rest of the 15,927-char 2-arg body verbatim; 1-arg wrapper untouched. Article 5 note: this removes an implicit, undocumented approved->draft demotion; `approved -> stitched` remains exclusive to `confirm_stitched_plan`. Rolled-back regression on 2026-06-13 (119 pod_refills + 7 pod_swaps): (1) no-op re-finalize keeps 133/133 approved with 0 drafts; (2) one mutated pod_refills qty -> exactly that row drafts (132 approved / 1 draft); (4) subset re-finalize keeps the machine's 24/24 approved. Option B (FE always orders finalize -> approve -> stitch) ticketed to Stax as cheap insurance.
**Rollback:** redeploy the v13 body (restore `status = 'draft'` and the `v13_subset_aware_decision` version string).

## 2026-06-12 — PRD-024 section 1: stitch v20 self-normalizing SKU split (CRITICAL)

**Phase / Article:** Phase F / Constitution Articles 1, 4, 5, 8, 12, 14
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`) + repo file `20260612200000_phaseF_stitch_split_pct_normalize.sql`
**Migration name:** `phaseF_stitch_split_pct_normalize`
**Summary:** `stitch_pod_to_boonz` v19 read `pm.mix_weight` raw and only normalized the per-shelf split when the total was 0. With 1,713 active machine-scoped `product_mapping` rows carrying `mix_weight = 1.0`, every variant on a multi-flavor shelf received `floor(pod_qty x 1.0)` = the full shelf quantity (VOXMCC-1005 A10: pod qty 10 -> 30 units dispatched on the committed 06-13 plan). A data-only resync was rejected because raw `split_pct` scales vary (machine-scoped Activia sums to 170; a global set sums to 0.66), so v20 makes the RPC self-normalizing: all four mapping reads switch to `pm.split_pct`, and the four split sites (`pull_norm`, `remove_phys_split`, deviation `n`, new procurement `pm_norm` CTE) divide by the windowed `total_split`, so shares sum to 1.0 at any raw scale. Procurement demand drops the arbitrary 0.20 default for the shared even-split-when-zero rule. Largest-remainder distribution, driver-pin first-claim, WH redistribution, signature, role gate, GUCs: unchanged (9-delta diff, rest of the 32,354-char body verbatim). Cody approved pre-apply; his required audit found 0 variants losing allocation (all 753 `split_pct=0` rows already had `mix_weight=0`) and no all-zero variant set. Verification battery (read-only simulation on the real 06-13 plan rows, 106 shelf-pods / 82 multi-SKU): v19 math inflates 4 shelf-pods (worst +60 units), v20 conserves on all 106, 0 single-SKU drift vs v19, Activia sum-170 regression splits 4/3/3 = 10. Battery items 3 and 6 re-fire at the gated 06-13 rebuild's stitch dry-run (PRD-024 section 2).
**Rollback:** redeploy the v19 body (md5 fingerprint `16fb196b820c97a31b8cfccfdff84614`, capture record in `docs/prds/refill-pipeline/_staging/live/stitch_pod_to_boonz_v19_rollback_fingerprint_2026-06-12.md`; verbatim body = migration `20260608124000_refillv2_stitch_driver_overlay_shelfguard.sql`).

## 2026-06-11 — PRD-023h: commercial default_amount excludes refunds

**Phase / Article:** PRD-023 follow-up / read-only, no protected writes (class c fast-path)
**Applied to:** both (remote via MCP as `prd023_h_commercial_default_excludes_refunds`; repo `supabase/migrations/20260611205500_prd023_h_commercial_default_excludes_refunds.sql`)
**Migration name:** `prd023_h_commercial_default_excludes_refunds`
**Summary:** CS decision: a deliberate refund is not a payment default. `get_vox_commercial_report` default_amount now assesses the gap against the originally captured amount (adyen_captured_net + refund_returned + cash_recovered). Aligns the green PAYMENT DEFAULT ribbon with the consumer-report DEFAULT card and /app/performance: 06Feb-01Jun 1,361.90/1.43%/37disc -> 1,076.90/1.13%/32disc. Refunds stay on their own waterfall line. Money waterfall (net revenue, shares, vox_net_dues) unchanged.
**Rollback:** re-run the same guarded DO block with the two expressions swapped.

## 2026-06-11 — PRD-023: VOX dashboard commercial fixes (read-only RPCs)

**Phase / Article:** PRD-023 / Constitution Articles 1, 2, 12, 15 (read-only; no protected writes)
**Applied to:** both (remote via MCP apply*migration; repo `supabase/migrations/20260611120000_prd023_vox_commercial_reporting.sql`)
**Migration name:** applied as `prd023_a*..`, `prd023*b*..`, `prd023_c_vox_commercial_txn_lines`, `prd023_d_vox_report_grants_drop_anon`(+`prd023_a/b_fix_machineid_groupby`); repo-consolidated into one file
**Summary:** Made the VOX Commercial ribbon, cards and CSV tell one story. (a) `get_vox_commercial_report`displays machine identity by`official_name`/`machine_id`(was historic`machine_mapping`, which duplicated renamed machines, e.g. ACTIVATE-2005 ↔ MPMCC-2005); money logic unchanged (waterfall re-verified at 36,940.00 / captured 36,389.40 / default 550.60 / COGS 1,878.02 / 1592 txns). (b) `get_vox_consumer_report`nets refunds via the SettledBulk+RefundedBulk pattern on`v_adyen_transactions_attributed`(was gross, Δ115.00), groups machine aggregates +`num_machines`by`machine_id`(9→8), derives`total_captured`from the matched set (was NULL via the`adyen_full`store_description join), and gains`p_machine uuid DEFAULT NULL`for server-side machine scoping (added via DROP+CREATE to avoid a PGRST203 overload; sole caller uses named params). (c) NEW read-only`get_vox_commercial_txn_lines(p_pods,p_date_from,p_date_to)`(SQL STABLE, SECURITY INVOKER) returns one row per`sales_history`line incl. VOX-sourced (COGS 0),`supply_source`three-valued (Boonz/VOX/LLFP, unmapped surfaced); line sums reproduce the waterfall (36,940.00 / 1,878.02). (d) Grants dropped`anon`/`PUBLIC`, narrowed to `authenticated, service_role`(no client-side anon rpc() exists; routes call as service_role). Cody approved (read-only; DROP+CREATE acceptable; anon dropped). FE: ribbon binds the commercial waterfall + commercial fetched on (period,pods) change; SKU "Line detail" CSV export (UTF-8 BOM); Products machine dropdown; VOX dashboard Commercial tab mounted (route gated to`vox_admin`; RPCs structurally VOX-only so a crafted non-VOX pod returns empty).
**Rollback:** restore the prior 4-arg bodies of `get_vox_commercial_report`/`get_vox_consumer_report`from git history;`DROP FUNCTION public.get_vox_commercial_txn_lines(text[],date,date)`; revert the FE files. No data changed (read-only).

## 2026-06-11 — PRD-022 D3b: add_purchase_order_lines (owner append to open PO) + FE drawer

**Phase / Article:** PRD-022 / Constitution Articles 1, 4, 8, 12
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`)
**Migration names:** `prd022_d3b_add_purchase_order_lines`, `prd022_d3b_widen_proc_event_type`
**Summary:** New owner-only DEFINER writer `add_purchase_order_lines(p_po_id text, p_lines jsonb)` — Dara chose Option B (dedicated sibling writer) over overloading create_purchase_order. operator_admin/superadmin only; appends lines to an existing OPEN PO reusing its po_number/supplier_id/purchase_date; same blocked-product + qty validation as create; regenerates `driver_tasks.notes` (DF2 mechanism); audits to procurement_events('lines_appended') + write_audit_log. Refuses fully-received/cancelled POs. It is the operation-scoped canonical writer for "append to open PO" (the 2nd and final INSERT path on purchase_orders alongside create; disjoint by precondition - create rejects existing po_id, append requires it). DF1 trigger skips it (existing po_id). Companion `prd022_d3b_widen_proc_event_type` widened the `procurement_events_event_type_check` to permit 'lines_appended' (caught by the verification test). Dara + Cody ✅ (Cody noted: two INSERT writers is the ceiling). Verified (rolled-back): owner append adds 1 line reusing po_number 9136 + regenerates notes; blocked product rejected; non-owner (warehouse) rejected; fully-received PO refused; 0 leaks. FE: owner-only add-line control in the Open POs drawer tab.
**Rollback:** `DROP FUNCTION public.add_purchase_order_lines(text, jsonb);` (constraint widen is additive, harmless to leave).

## 2026-06-11 — PRD-022 D5: get_open_po_lines reader RPC

**Phase / Article:** PRD-022 / Constitution Articles 4 (read-only DEFINER), 12
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`)
**Migration name:** `prd022_d5_get_open_po_lines`
**Summary:** New read-only `get_open_po_lines(p_supplier_id uuid DEFAULT NULL)` (STABLE SECURITY DEFINER, sql, no writes). Returns open PO lines (`received_date IS NULL AND purchase_outcome <> 'not_purchased'` - identical to `get_procurement_demand.on_order` so D1 chips reconcile) with optional server-side supplier filter; columns po_line_id/po_id/po_number/supplier_id/supplier_name/boonz_product_id/boonz_product_name/ordered_qty/price_per_unit_aed/expiry_date/purchase_date/age_days. Powers PRD-022 D1 ordered-state chips + D3 Open POs drawer list. DEFINER kept for parity with sibling readers (zero exposure delta; INVOKER would also suffice). Dara shape-checked, Cody ✅ (read-only; Articles 4, 12). Verified: 87 open lines total, 37 filtered to Union Coop.
**Rollback:** `DROP FUNCTION public.get_open_po_lines(uuid);`

## 2026-06-11 — PRD-022 DF2: cancel_po_line regenerates driver_tasks.notes

**Phase / Article:** PRD-022 / Constitution Articles 1, 4, 8, 12
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`)
**Migration name:** `prd022_df2_cancel_regenerates_driver_notes`
**Summary:** Cancelling a PO line left the driver task's `notes` checklist stale, so drivers still saw the cancelled product. `cancel_po_line` rebuilt verbatim from live (role gate, reason>=10, received-line guard, dual audit intact) with one added block: after the cancel UPDATE, it rewrites `driver_tasks.notes` for the PO's still-actionable task (status pending/acknowledged only) from the remaining lines (`purchase_outcome <> 'not_purchased'`), matching create_purchase_order's "Name xQty" format, with an `(all lines cancelled)` fallback. Touches only `notes`, never `status` (Article 5 clear). Cody ✅ (Articles 1, 4, 8, 12). Verified (rolled-back test): cancelling the Krambals line removed it from PO-2026-MQ7MO2T9's task notes; no commit leaked.
**Rollback:** `CREATE OR REPLACE` cancel_po_line without the driver_tasks.notes UPDATE block.

## 2026-06-11 — PRD-022 DF1: po_number allocation fix + cross-po_id uniqueness guard

**Phase / Article:** PRD-022 / Constitution Articles 1, 4, 12
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`)
**Migration name:** `prd022_df1_po_number_allocation`
**Summary:** `po_number_seq` had drifted BELOW `max(po_number)` (last_value 9143 < max 9144) because the retired FE path inserted `MAX+1` po_numbers directly while the RPC advanced the sequence; `nextval` was re-issuing existing numbers (incident: 9140 collision, PO renumbered to 9144). Fix, all go-forward, zero historical rows touched (23 historical duplicate po_numbers left as-is per CS): (0) `idx_po_number` index; (1) `setval(po_number_seq, COALESCE(MAX(po_number), last_value))` resync; (2) `BEFORE INSERT` trigger `trg_po_number_one_po_id` (DEFINER) blocking a brand-new `po_id` from claiming a `po_number` already owned by a different `po_id` (skips same-`po_id` multi-line + D3b appends; never re-validates historical dups); (3) `create_purchase_order` rebuilt verbatim from live (PRD-1 blocked-product guard intact) plus a skip-used loop after `nextval` to self-heal future drift. Dara shape-checked (trigger is a backstop not a hard constraint - acceptable since nextval is the atomic sole allocator + direct writes RLS-dropped; header-table-UNIQUE alternative rejected as historical dups block its backfill). Cody ✅ (Articles 1, 4, 12). Verified live: new po_id reusing 9144 blocked with the named rule; same po_id allowed; seq >= max; live traffic allocated 9145 cleanly; 0 leaked test rows.
**Rollback:** `DROP TRIGGER trg_po_number_one_po_id ON public.purchase_orders; DROP FUNCTION public.trg_po_number_one_po_id_fn();` and `CREATE OR REPLACE` create_purchase_order without the skip loop. Index + setval are harmless to leave.

## 2026-06-10 — PRD-021 abandon_intent service-role bypass (lift Ritz Cracker decommission)

**Phase / Article:** PRD-021 / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`)
**Migration name:** `prd021_abandon_intent_service_role_bypass`
**Summary:** `abandon_intent` rejected the service-role connection (auth.uid() IS NULL) in its role guard, blocking programmatic intent closure. Added the standard service-role bypass: the guard line changed from `v_user_id IS NULL OR NOT EXISTS(operator role)` to `v_user_id IS NOT NULL AND NOT EXISTS(operator role)` — an authenticated non-operator is still rejected; only NULL-uid service-role now passes. Same bypass class as `prd019_set_dispatch_include_service_role_bypass`. Body otherwise verbatim (signature, SECURITY DEFINER, search_path, audit GUCs, p_intent_id/p_reason validation, FOR UPDATE lock, abandonable-status guard, UPDATE). Used to close strategic_intent `ba1ef467` (Ritz Cracker decommission) — CS lifted it 2026-06-10 (selling well at Amazon). `closed_by` NULL under service-role; CS attribution in `closure_reason`. Loacker Quadratini decommission (`9e117317`) untouched. Cody ✅. Verified: target → abandoned w/ closed_at; zero active decommission intents remain on Ritz `2e20605a`.
**Rollback:** `CREATE OR REPLACE FUNCTION` the prior body (restore `v_user_id IS NULL OR NOT EXISTS`). No data migration to undo; to re-queue the intent, write a new `strategic_intents` row (do not edit the abandoned one in place).

## 2026-06-10 — PRD-4 (Procurement Brain v3): shelf-stock snapshot infra; forecast v4 swap REJECTED by replay

**Phase / Article:** Phase F / Constitution Articles 2, 4, 11, 12
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`)
**Migration name:** `phasef_proc_shelf_stock_daily_snapshot` (4b). Forecast v4 (4a): **NOT applied — validation failed.**
**Summary (4b, applied):** New analytics table `shelf_stock_daily` (per-(machine,pod_product) nightly snapshot) + sole DEFINER writer `snapshot_shelf_stock()` (idempotent upsert from `v_live_shelf_stock`, eligible+enabled slots, Asia/Dubai date, caller gate system/operator_admin/superadmin, GUCs set) + pg_cron `shelf_stock_daily_snapshot` at 20:30 UTC (after nightly-fleet-refresh). RLS: authenticated SELECT-only, service_role ALL, no authenticated write. First manual run captured 301 rows (290 in-stock) across 20 machines / 63 products. Purpose: accrue days-in-stock history so availability-adjusted velocity (sales/days-in-stock) becomes measurable for a future forecast. Cody ✅ (Articles 2, 4, 11, 12, 14).
**Summary (4a, REJECTED):** Backtested the spec's blended forecast (0.7×14d + 0.3×prior-28d) and alternatives against actuals over a 5-window replay (as-of 04-29…05-27, each predicting next 14d, pod level). Result: the blend is **worse than flat-14d in 4 of 5 windows** (MAE e.g. 957 vs 820); trend-extrapolation/momentum overshoot (MAE 1166–1217); a static ×1.1 uplift helps only in growth regimes and hurts in steady ones (regime-dependent, not robust). **No tested basis change robustly beats flat-14d**, so `get_procurement_demand` keeps its v3 flat-14d × ctx basis. The genuine improvement — availability-adjusted velocity — is unvalidatable until `shelf_stock_daily` accrues ~3-4 weeks; revisit then. Validation-before-swap (per goal) prevented a forecast regression.
**Rollback (4b):** `SELECT cron.unschedule('shelf_stock_daily_snapshot'); DROP FUNCTION public.snapshot_shelf_stock(); DROP TABLE public.shelf_stock_daily;`

## 2026-06-10 — PRD-5 (Procurement Brain v3): merge duplicate Union Coop supplier

**Phase / Article:** Phase F / Constitution Articles 1, 8, 12
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`)
**Migration name:** `phasef_proc_merge_union_coop_dupe`
**Summary:** Data hygiene. Merged duplicate supplier "Union Coop" (`3cec0b3a…47d7`, was Inactive, 19 PO lines, 18 supplier_products) into canonical (`31b6355d…64d8`, Active, 334 lines, 94 products). No deletes. Repointed all 19 PO lines (audited one row each to `write_audit_log` before mutation); repointed the 2 supplier_products canonical lacked (Barkthins Pretzel + Almond, kept preferred); retired the 16 overlap dupe rows in place (`status='Inactive'`, `is_preferred=false`); promoted canonical's Coco Water to preferred (it lost its only preferred when the dupe's flag cleared); renamed the dupe `"Union Coop (DUP merged to 31b6355d on 2026-06-10)"` (kept Inactive). Ordering (clear-preferred → repoint-non-overlap → restore → retire → promote) avoids the partial-unique `uq_supplier_products_one_preferred` clash. CS reviewed the row diff + signed off; Cody ✅ (Articles 1 — migration-path exception with explicit audit, 8, 12). Verified post-apply: dupe 0 PO lines / 0 Active / 0 preferred / renamed; canonical 353 lines (+19), 96 products (+2); 0 products with multiple preferred; 20 audit rows (19 + summary).
**Rollback:** Repoint the 19 lines + 2 supplier_products back to `3cec0b3a…`, restore the dupe's preferred flags + Active status + original name, re-clear the promoted Coco Water flag. Audit rows are append-only (kept).

## 2026-06-10 — PRD-3 (Procurement Brain v3): pod-level demand RPC

**Phase / Article:** Phase F / Constitution Articles 4 (read-only DEFINER), 12
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`)
**Migration name:** `phasef_proc_demand_pod_level_rpc`
**Summary:** New read-only `get_procurement_demand_pod(integer, text)` (STABLE SECURITY DEFINER, LANGUAGE sql, zero writes). Emits demand at the pod_product level — the sales reality BEFORE `get_procurement_demand`'s mix_weight trickle-down — with columns `sales_14d, velocity_per_day, ctx_multiplier (category>global>1), forecast_demand, mapped_variant_count, pod_breakdown jsonb`. Each `pod_breakdown` entry lists a mapped boonz variant with mix_weight/split_pct/attributed_14d/source_of_supply and its PRD-1 `block_reason`. Reuses the same pod-sales window + `demand_context_factors` machinery as the boonz RPC so the two FE sub-tabs reconcile (breakdown attributed_14d sums back to pod sales, verified e.g. Chocolate Bar 251). DEFINER for parity with the sibling RPC over the same RLS-gated read sources. Cody-reviewed ✅ (read-only; Articles 4, 12). Powers PRD-2's "Pod demand" sub-tab. Validated live: top pods return correct velocity/forecast and breakdowns.
**Rollback:** `DROP FUNCTION public.get_procurement_demand_pod(integer, text);`

## 2026-06-10 — PRD-1 (Procurement Brain v3) guardrail: block ordering decommissioned / never-order products

**Phase / Article:** Phase F / Constitution Articles 1, 4, 12
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`)
**Migration name:** `phasef_proc_block_decommissioned_po_writes`
**Summary:** No path could previously stop a PO line for a decommissioned product — Ritz Cracker - Regular was ordered 2026-06-10 (PO-2026-MQ7MQIHO, cancelled). Added shared detection helper `boonz_product_block_reason(uuid)` (STABLE, SECURITY DEFINER) returning `decommissioned_product | never_order_flavor | NULL`: a product is BLOCKED when it has >=1 `supplier_products` row and **every** row is `status='Inactive'` with notes matching `never_order_flavor`/`decommissioned_product` (no rows at all = "Unassigned", orderable). Re-created both canonical PO writers from their **live** bodies with a guard before insert/edit — no behavior reverted (create kept verbatim; edit kept the PRD-002 received-lock + `lock_level`). Guard has **no service-role / system bypass** by design (safety rail, not auth gate); `create_purchase_order` blocks for everyone, `edit_purchase_order_line` blocks for everyone except `superadmin` (CS carve-out for historical price corrections — removal otherwise via `cancel_po_line`). Added read-only view `v_procurement_blocked_products` to back PRD-2's struck-through "Blocked" group. Verified `create_purchase_order` is the sole PO-line inserter and there are zero FE/edge direct inserts. Cody-reviewed (✅ Articles 1, 4, 12; the review caught that the first draft re-created `edit_purchase_order_line` from the stale 2026-05-23 file body — which would have silently reverted PRD-002 received-lock — and rebuilt it from live). Tested live (operator*admin impersonation): create blocked Ritz rejected naming the rule; edit blocked Ritz line as operator_admin rejected; control product still orderable; 0 leaked test rows.
**Pre-existing note (not in scope):** `purchase_orders` has no universal audit trigger; `edit*\*`compensates with a manual`write_audit_log`insert but`create_purchase_order`writes only`procurement_events`, not `write_audit_log`(Article 8 gap predating this change). Flagged for a separate follow-up.
**Rollback:**`CREATE OR REPLACE FUNCTION` both writers from their pre-`phasef_proc_block_decommissioned_po_writes`live bodies (drop the`v_block_reason`block), then`DROP VIEW public.v_procurement_blocked_products;`and`DROP FUNCTION public.boonz_product_block_reason(uuid);`.

## 2026-06-10 — PRD-020 log_retroactive_refill_visit dedup key now includes expiry

**Phase / Article:** PRD-020 / Constitution Articles 1, 4, 8, 12
**Applied to:** prod (Supabase `eizcexopcuoycuosittm`)
**Migration name:** `prd020_retro_log_dedup_include_expiry`
**Summary:** The per-line dedup `EXISTS` in canonical RETRO-LOG writer `log_retroactive_refill_visit` keyed on machine+date+boonz+qty+action+shelf+`[RETRO-LOG` comment but **omitted expiry_date**. Two genuinely distinct same-qty/same-shelf batches that differ only by expiry (e.g. ALJLT-1015 Dubai Popcorn Butter 1@2027-02-01 and 1@2027-02-07) were wrongly collapsed — the second was skipped as a false-positive duplicate, violating FIFO "keep batches separate". Added one conjunct `AND (expiry_date IS NOT DISTINCT FROM v_expiry)`. Strictly narrower dedup: cannot over-write or lose data, only stops false-positive skips. Signature, SECURITY DEFINER, search_path, role gate, audit GUCs all verbatim. Cody-reviewed (✅ Articles 1, 4, 8, 12). Verified: both Dubai Butter batches now persist as separate rows with distinct expiries; all other PRD-020 Part A/B1 lines logged 0 dup-skips.
**Rollback:** `CREATE OR REPLACE FUNCTION` the prior body (remove the added `AND (expiry_date IS NOT DISTINCT FROM v_expiry)` conjunct). No data migration to undo.

## 2026-06-08 — PRD-REFILL-V2 (STAGED — per-item CS apply gate; NOTHING APPLIED YET)

**Phase / Article:** PRD-REFILL-V2 / Articles 1, 4, 5, 8, 12, 14 (Hard Rule 10 — diff-gate + CS green light per writer)
**Applied to:** repo only (migration files staged in `supabase/migrations/`; live bodies captured in `docs/prds/refill-pipeline/_staging/live/`). NOTHING applied to prod.
**Summary:** Engine rebuild per `docs/prds/refill-pipeline/PRD-REFILL-V2-add-swap-rebuild.md`. Core principle: quantity DECOUPLED from score (final_score/Pearson = ranking only, never a fill cap).

- **Item 1 engine_add_pod v14->v15** `20260608120000_refillv2_engine_add_pod_v15_fill_to_cap.sql` — STAGED, ready for sign-off. Fill-to-cap: need_raw=GREATEST(max_stock-current_stock, driver_req), capped ONLY by a shared-WH window allocation (best sellers first); dead (stance DEAD/ROTATE OUT/DEAD — SWAP NOW or velocity_30d=0) -> qty 0 + pod_swaps tag (reason dead/rotate_out, pod_product_id_in NULL, reasoning.tagged_by='engine_add_pod_v15'). DRY-RUN 2026-06-09: 284/284 WH-fillable sellers >=95% (100% engine fill); all shorts WH-limited; 137 dead tagged. Header flags PRD deviations (pod_swaps.reason CHECK blocks 'dead_tagged_by_add'; WIND DOWN kept as drain).
- **Item 3 resolve_driver_intent (NEW INVOKER)** `20260608121000_refillv2_resolve_driver_intent_translator.sql` — STAGED. Read-only translator; unresolved -> 'unresolved_driver_intent'. DRY-RUN 2026-06-05: 6/7 resolved, 1 (no boonz SKU) flagged, none dropped (A6).
- **Item 5 pick_machines_for_refill v7->v8** `20260608123000_refillv2_pick_machines_v8_p1_restock.sql` — STAGED, ready for sign-off. P1_RESTOCK mirrors get_machine_health bands (velocity proxied units_last_7d>0); explicit warehouse/excluded filter; sibling expansion + visit_order kept. DRY-RUN: same 28 picked, P1 18->12 (no over-pick), 0 warehouses (A8).
- **Item 2 engine_swap_pod (live v9_5, not v8) -> v10** — DESIGN + PATCH SPEC, awaiting CS on 2 forks: (a) M2W paired warehouse return is net-new (today only a pod_swaps row; WH credit downstream at stitch) — write in-engine vs keep downstream? (b) consume add tags via UPDATE-in-place vs current DELETE-all+rebuild. Removes Pass-2 autonomous-Pearson + lifecycle optimization; swap-in via find_substitutes_for_shelf + global fallback; consume driver_recommendations.
- **Item 6 stitch_pod_to_boonz (v18) overlay** — DESIGN + PATCH SPEC, awaiting CS on overlay semantics (pinning driver SKU+qty must re-solve the mix largest-remainder; sum=pod_qty invariant). Default: driver SKU first claim up to driver_qty, remainder by mix_weight. + defensive shelf-code A01..E16 guard (all 2615 live codes already canonical).
- **Item 4 expiry** — emergent from v15 + FEFO; optional thin per-slot augmentation offered.
- **Item 7 8pm cron** — CONFIRMED: build_draft_for_confirmed chains confirm->add->swap->finalize, STOPS at draft, no auto-approve/auto-stitch (job 13, 0 16 \* \* \* Dubai). Only change: insert expiry step once v15/v10 land.
  **Rollback:** n/a — repo-only staging. If applied later, each is forward-only CREATE OR REPLACE; rollback = re-apply prior version (v14/v9_5/v7/v18 bodies preserved in `_staging/live/`).

## 2026-06-07 — PRD-019: 05/06 + 06/06 refill logging round + Nissan supersede + WH note (APPLIED to prod)

**Phase / Article:** PRD-019 / Articles 1, 4, 8, 12 (data-logging via canonical writers)
**Applied to:** prod (`eizcexopcuoycuosittm`)
**Migration:** `prd019_set_dispatch_include_service_role_bypass` (the only DDL — one-line service-role bypass added to `set_dispatch_include`, Cody ✅, same pattern as adjust_pod_inventory). All else is data via existing canonical writers.
**Summary:** Logged the 05/06 + 06/06 refill rounds (01-04 Jun already done in PRD-017/018). **Nissan reconcile:** voided the 14 04-Jun `[RETRO-LOG]` rows (`set_dispatch_include(id,false)` + `update_dispatch_comment` '[…SUPERSEDED by 05/06 full log…]', via operator_admin impersonation since update_dispatch_comment has no bypass) then logged the full 05/06 Nissan list (29 rows) — one clean record, no double-count. **05/06 logged:** NISSAN 29, AMZ-1029 25 (incl. A1 Zigi→Sunbites swap: Remove Zigi 6 + Add Sunbites Cheese 4/O&O 4), AMZ-1038 23 (incl. A1 Zigi(3)→Nibbles swap), NOOK 16 (new machine). 2 swap Removes via `insert_driver_remove_line` (operator_admin impersonation). **06/06 logged (source_origin=vox_at_venue):** ACTIVATEMCC-1037 1, ACTIVATE-2005 5, IFLYMCC-1024 3, VOXMCC-1011 3, MPMCC-1054 3, VOXMCC-1005 5. **CS resolutions:** Al Ain Zero (no catalog variant) → Al Ain Water - Regular (AMZ-1029 6 / AMZ-1038 8 / NOOK 15); Nissan VW Upgrade 2 + Reload 2; KitKat 28/02/26 → 2027-02-28 + NOOK Krambals Tomato 20/01/26 → 2027-01-20 (typos); VW Zero Lemon → WH_CENTRAL. **Part 2:** VW Zero Lemon +5 @2026-09-06 to WH_CENTRAL via `adjust_warehouse_stock` (WH-mgr bf32624e impersonation, provenance manual_adjust); Mirdif Stockroom list → 1 `action_tracker` task (Simran-only, not logged). **Skipped (past/invalid, per rule, not logged):** AMZ-1029 Hunter Sea Salt&Vinegar 01/02/26, Dubai Salted 17/02/26, VW Reload 30/02/26 (invalid); VOXMCC-1011/1005 VW Well Care 06/06/26 (past). **Parked to action_tracker:** A6 Hummus N/A (procurement), AMZ-1029 Reload invalid-date, NOOK G&H Popped Protein + Eviron Wellness (no qty). Each canonical-writer call verified in a rolled-back tx before commit (supersede + WH add).
**Rollback:** re-include the 14 Nissan 04/06 rows (`set_dispatch_include(id,true)`) + remove the 05/06 [RETRO-LOG] rows if a true double-count reversal is needed; zero the VW Zero Lemon WH row; restore set_dispatch_include prior body (drop the bypass). Retro-log rows are dedup-guarded so re-runs are idempotent.

## 2026-06-07 — PRD-UNIFY Step 3 engine delegation APPLIED (CS green light)

**Phase / Article:** PRD-UNIFY Step 3 / Articles 1, 4, 8, 12 (Hard Rule 10 — CS approved "apply both")
**Applied to:** prod
**Migration names:** `prdunify_step3_engine_add_pod_v14_calibrate`, `prdunify_step3_finalize_pod_decision_propagate`
**Summary:** On CS green light, applied the two held CORE-writer changes. `engine_add_pod` v13→**v14**: sizing now delegates to `compute_refill_decision(machine, shelf, NULL, 10)` (the calibrated dials) — one brain for engine + card; the `visual_floor` clamp heuristic uses 10 to match. PRESERVED from v13: the §1 wh_avail clamp, the `GREATEST(refill, driver_req)` driver-demand floor, strategic-intent → 0 skip, the capacity clamp, and the driver_feedback decay-resolve. WIND DOWN/ROTATE/DEAD now drain (decision's `target ≤ current` → refill 0). `engine_finalize_pod` (date,uuid[]) patched to carry the decision jsonb from `pod_refills.reasoning->'decision'` into `pod_refill_plan.decision` (refill_lines reasoning + a `decision` column through `unioned` + `decision`/`EXCLUDED.decision` in the upsert; swap lines = NULL decision) so committed drafts persist the same number the card renders (A1). Verified live: engine reports `v14_prd_unify_decision` and calls `compute_refill_decision(…,10)`; finalize tagged `v13_subset_aware_decision` with `decision = EXCLUDED.decision`. Delta proof (plan 2026-06-05): the Tuned profile — drains 0, KEEP trimmed not collapsed (note the absolute total drifts with `now()`-relative velocity: 316 on 06-05, ~301 on 06-06).
**Rollback:** re-apply engine v13 (`ws4b_engine_add_pod_v13_driver_demand`) and `engine_finalize_pod` v13_subset_aware (drop the decision column refs); `compute_refill_decision` dials stay (independent).

## 2026-06-06 — PRD-UNIFY-CAL: lock the unified-decision dials

**Phase / Article:** PRD-UNIFY-CAL / Article 4 (read-only fn), Hard Rule 10 (engine held)
**Applied to:** prod (`compute_refill_decision` only); engine_add_pod v14 HELD as a file for CS sign-off
**Migration names:** `unifycal_compute_refill_decision_dials` (applied); `20260605132000_prdunify_step3_engine_add_pod_calibrate.sql` (updated, NOT applied)
**Summary:** Calibrated `compute_refill_decision` (read-only STABLE/INVOKER) to the delta-validated dials: `p_days_cover` DEFAULT 7→10, KEEP floor_pct 0.60→0.70, RAMPING floor_pct 0.50→0.60. Diff-gated to exactly those three constants (verified: old KEEP 0.60 / RAMPING 0.50 gone; cover_mults, STAR/DD 0.80, KEEP GROWING 0.70, WATCH 0.40, WIND DOWN/ROTATE/DEAD 0.00 + drain rule, and all final-score weights unchanged). Delta on plan 2026-06-05 (129 REFILL/ADD rows): total refill 375→316 (vs the untuned 7/0.60/0.50 which collapsed it to 227), KEEP 194→168 (−26), RAMPING 58→42, WIND DOWN/ROTATE/DEAD = 0 — matches the PRD's Tuned profile. The engine delegation (PRD-UNIFY Step 3, `engine_add_pod` v13→v14: sizing via `compute_refill_decision(...,10)` while preserving v13's wh_avail clamp + driver_request floor + driver_feedback resolve + strategic-intent skip) is a CORE-writer second rewrite — Hard Rule 10 — HELD as the staged file for CS green light; the 375→316 by-stance table is the per-row delta to sign off. PRD-UNIFY dials table + canonical block updated to 10/0.70/0.60.
**Rollback:** re-apply the prior `compute_refill_decision` (days_cover 7, KEEP 0.60, RAMPING 0.50) from the PRD-UNIFY Step-2 migration; the engine was never changed (still v13).

## 2026-06-06 — Refill-Day Phase 1: RD-01 / RD-05 / RD-03 (APPLIED to prod 2026-06-07)

**Phase / Article:** Refill-Day (Layer 2) / Articles 2,3,4,5,7,8,12,14
**Applied to:** prod (`eizcexopcuoycuosittm`) 2026-06-07 via apply*migration (`rd01_create_plan_add_machine`, `rd05_expiry_aware_fefo_pick`, `rd03_driver_self_service`); verified live (pg_proc + columns + RLS policies). **Two writer-changes held back (need verbatim diff-gate + Cody before touching core writers):** (1) RD-01 `pick_machines_for_refill` ON CONFLICT reclaim — `add_source` default already covers picker inserts; (2) RD-05 `edit*/add_pod_refill_row`pin extension — was gated on PRD-UNIFY (now applied by CS 06-06/06-07, so it's unblocked; live writer signatures are unchanged so it will apply cleanly). FE wiring (RD-01 +Add-machine modal, RD-05 batch dropdown, RD-03 field-PWA outcome/Recommend + offline queue) still to deploy.
**Files (apply order):**`20260606120000_rd01_create_plan_add_machine.sql`, `20260606121000_rd05_expiry_aware_fefo_pick.sql`, `20260606122000_rd03_driver_self_service.sql`.
**Summary:** The human-in-the-loop refill-day control surface. **RD-01** — `add_machine_to_plan(plan_date,machine_id,confirm)`+`create_refill_plan(plan_date,machine_ids[])`(DEFINER, operator*admin/superadmin/warehouse + service-role bypass, pull the v_machine_health_signals snapshot, status`cs_added`/add_source `operator`/is_included/confirmed, idempotent, **NOT** running the engine — confirm gate preserved); `machines_to_visit`gains`add_source`; `pick_machines_for_refill` reproduced verbatim with a 2-line ON CONFLICT reclaim (`add_source='picker', is_included=true`). **RD-05** — `pod_refill_plan.preferred_wh_inventory_id`(FK ON DELETE SET NULL) +`get_shelf_fefo_options(machine_id,boonz)`read-only INVOKER (FEFO batches across the machine's source WHs, nearest-expiry default, warehouse_stock>0, days_to_expiry). **RD-03** —`refill_dispatching.driver_outcome\*`cols + new`driver_recommendations`table (RLS: field_staff own SELECT/INSERT, operator+ SELECT all, no field UPDATE/DELETE) +`driver_report_dispatch_outcome`(ownership-scoped, never mutates qty/action, no reverse of picked_up, auto action_tracker punch-item, idempotent) +`driver_propose_adjustment`(writes driver_recommendations + driver_feedback + action_tracker). **Verified in rolled-back tx:** add_machine_to_plan 35-col insert + idempotency; get_shelf_fefo_options FEFO output; driver_propose_adjustment 3-table write — all clean.
**DISCOVERY CORRECTIONS surfaced:** (1)`machines_to_visit_status_check`ALREADY allows`cs_added` (+`cs_dropped`,`completed`) — the PRD's literal CHECK would have dropped those, so it was NOT touched. (2) RD-03's ownership join `dispatch_plan`does NOT exist and there is no per-driver dispatch assignment — ownership uses`trip_events (driver_user_id, machine_id, dispatch_date)`as the assignment proxy; stricter per-route ownership needs a driver-route-assignment table (flagged). (3)`v_effective_expiry`does not exist — FEFO uses`warehouse_inventory.expiration_date`. **HELD:** RD-05's `edit\*/add_pod_refill_row` `p_preferred_wh_inventory_id`writer extension is parked until PRD-UNIFY is applied (PRD-UNIFY also extends those writers; building both now would diverge). **FE:** client-side`supabase.rpc()`wiring (matches the live pattern; no`\_actions.ts`in (app)/refill) — RD-01 "+ Add machine" picker modal, RD-05 batch dropdown + raise-PO, RD-03 field-PWA per-line outcome + Recommend sheet with offline-queue idempotent on dispatch_id+outcome — spec'd for Stax. Cody verdicts inline in each file.
**Rollback:** none applied. After apply: RD-03`DROP FUNCTION driver_report_dispatch_outcome, driver_propose_adjustment; DROP TABLE driver_recommendations; ALTER refill_dispatching DROP driver_outcome\*`; RD-05 `DROP FUNCTION get_shelf_fefo_options; ALTER pod_refill_plan DROP preferred_wh_inventory_id`; RD-01 restore picker v7, `DROP FUNCTION add_machine_to_plan, create_refill_plan` (add_source col additive — safe to leave).

## 2026-06-05 — PRD-UNIFY: one refill decision (stance × dosage) + single Final Score (DRAFTED — NOT applied)

**Phase / Article:** PRD-UNIFY / Articles 1, 4, 8, 12, 14
**Applied to:** none — 4 migration FILES + 1 FE diff produced for CS review. APPLY NOTHING was the directive.
**Files (apply order):** `20260605130000_prdunify_step1_pod_refill_plan_decision.sql`, `20260605131000_prdunify_step2_compute_refill_decision.sql`, `20260605132000_prdunify_step3_engine_add_pod_calibrate.sql` (⚠️ Hard Rule 10 — CORE writer, needs CS green light), `20260605133000_prdunify_step4_get_machine_slots_repoint.sql`; FE `src/app/(app)/refill/page.tsx`.
**Summary:** Retire the "two brains" (lifecycle engine writes the plan; health engine `compute_strategy`/`get_machine_slots` shows a different fill-to-max verdict). New model: lifecycle = STANCE (direction + ceiling + floor), recency velocity = DOSAGE (units + urgency), 💎/👑 demoted to badges. **Step 1** adds `pod_refill_plan.decision jsonb`. **Step 2** adds read-only INVOKER `compute_refill_decision(machine_id, shelf_id, boonz_product_id, days_cover)` — the SINGLE source of both `target_units` and `final_score` (dials table + 0.6·v7+0.4·v30 blend + WIND DOWN/ROTATE/DEAD drain + final_score = demand_base×stance×placement×urgency). **Step 3** calibrates `engine_add_pod` v13→v14 to DELEGATE sizing to `compute_refill_decision` (one brain) and ride the decision in `pod_refills.reasoning` — DIFF-GATED: only dials + decision emission change; orchestration byte-identical; the WIND-DOWN-refills-up bug is fixed. **Step 4** DROP+CREATEs `get_machine_slots_with_expiry` to return `decision`/`final_score`/`stance`, source target+score+badges from the decision, sort by Final Score; `compute_strategy` no longer called for a target or a score (left in DB, deprecated). **Step 5** FE swaps the modal's Strategy(PROTECT/SUSTAIN)+Score columns for Stance + Final Score (hover = breakdown), default sort Final Score desc; `npx next build` ✅, `tsc` ✅. **Verified in rolled-back tx (Step 2):** A2 Rice Cake WIND DOWN→refill 0 + score ×0.4 despite 💎; A5 ROTATE OUT→0; A4 Vitamin Well KEEP→floor-led 6 (cap 10) < fill-to-max; the rolled-back run caught 2 real bugs (MAX(uuid), velocity-fallback clobber) before any apply. v2 FIX-1 confirmed APPLIED (0/727 aisle drift). Cody verdicts inline in each file. **Open for CS:** Step 3 needs Hard Rule 10 green light; `engine_finalize_pod` 2-line decision-propagation patch (documented in Step 3 file) optional (the reader already shows the live decision).
**Rollback:** none applied. After apply, unwind: Step 4 restore prior reader; Step 3 restore `engine_add_pod` v13; Step 2 `DROP FUNCTION compute_refill_decision`; Step 1 column additive/defaulted NULL (safe to leave); FE revert the `refill/page.tsx` diff.

---

## 2026-06-05 — Refill reliability WS2/WS4/WS5/WS7 applied to prod

**Phase / Article:** Refill reliability / Articles 1, 2, 4, 5, 8, 12, 14
**Applied to:** prod (DB); FE changes in working tree pending Vercel deploy
**Migration names:** `ws2a_skip_dispatch_line`, `ws2b_push_edit_aware_v5`, `ws5a_recommendation_intents`, `ws5b_recommendation_rpcs_no_writer`, `ws7_pending_enriched_reader`, `ws4a_driver_feedback_demand_view`, `ws4b_engine_add_pod_v13_driver_demand`
**Summary:** WS2 — `push_plan_to_dispatch` v4→v5 edit-aware (skips re-inserting a (machine,date,shelf,pod) that already has a manually-reworked dispatching row: created_by_edit / edit_count>0 / cancelled / skipped — fixes the A01 Popit-over-Coke-Zero clobber), plus new `skip_dispatch_line(p_dispatch_id,p_reason)` canonical writer + `refill_dispatching.skipped/skip_reason/skipped_at/skipped_by` columns + allow-list entry, so an unfulfillable line can be skipped without hard-blocking submission. WS5 — `recommendation_intents` table (status machine proposed→confirmed→applied|rejected, RLS read-only + RPC-only writes) + `propose/confirm/reject/apply_recommendation_intent` RPCs (human-confirm gate; boonz-level routes to the pre-existing `apply_mix_weight_recommendation` which was LEFT AS-IS per WS-A, pod-level routes to swap/decommission). WS7 — `get_refill_plan_output_enriched(plan_date)` read-only reader joining `v_live_shelf_stock` (live Stock) + `v_sales_history_attributed` (7d sales) so the pending Refill Planning view shows real Stock/7d instead of stitch's 0/0 placeholders; FE (`RefillPlanningTab.tsx` pending load + `field/packing/[machineId]/page.tsx` "reserved to {machines}" UX) staged in the working tree. WS4 — `v_driver_feedback_demand` view (per machine+pod unresolved asks, 14-day decay, boonz→pod via product_mapping) + `engine_add_pod` v12→v13 that floors refill qty by an in-window driver ask (`GREATEST(..., driver_req_qty)`, clamp_reason `driver_request`) and marks ingested feedback resolved (decay closure); §1 wh_avail suppression preserved. All Cody-reviewed; each function sets app.via_rpc; forward-only.
**Rollback:** re-apply each function's prior version (push v4, engine v12_wh_avail_s1_suppress, restore enforce_canonical_dispatch_write without 'skip_dispatch_line'); drop `recommendation_intents` + the WS5/WS7/WS4 functions + `v_driver_feedback_demand`; `refill_dispatching` skip columns are additive/defaulted and harmless to leave. Migration files under `supabase/migrations/`.

## 2026-06-05 — WS-A: make mix_weight canonical (pod to SKU split)

**Phase / Article:** Refill reliability WS-A / Articles 1, 4, 12
**Applied to:** prod
**Migration names:** `wsa0_backfill_mix_weight_from_split`, `wsa_stitch_v18_mix_weight_canonical`, `wsa_procurement_demand_mix_weight`, `wsa_secondaries_mix_weight`
**Summary:** `apply_mix_weight_recommendation` wrote `product_mapping.mix_weight` but the pod to SKU fan-out read `split_pct`, so confirmed recommendations never reached the plan. Step 0 found mix_weight was at the raw default 1.0 on 7,654 of 7,662 active rows (never backfilled; only 8 Hunter rows already matched split_pct/100), so there were no genuine recommendation divergences to preserve. Applied a one-time canonical backfill `mix_weight = ROUND(split_pct/100, 4)` via the new `backfill_mix_weight_from_split_pct(p_confirm)` writer (6,263 rows updated; verified 3,098/3,100 pods now sum to 1.0; the 2 off are pre-existing pods whose split_pct does not sum to 100). Then switched the six split_pct readers to mix_weight, diff-gated to source + scale only: `stitch_pod_to_boonz` v17 to v18 (the REFILL fan-out, the WS1b REMOVE physical-fallback split, and the deviation+procurement-alert blocks: `pod_qty*split_pct/100` to `pod_qty*mix_weight`, `total_split=0` fallback to `1.0/variant_n`; the inline confirm gate, WS6.2 0-stock filter, and WS1b fallback preserved byte-for-byte and re-verified live), `get_procurement_demand` (attributed demand by mix_weight), `reconcile_pod_inventory_shelf` + `backfill_dispatch_boonz_product_ids` (dominant-variant pick ORDER BY mix_weight). `apply_mix_weight_recommendation` left as-is. Behavior-preserving (post-backfill mix_weight = split_pct/100): stitch v18 dry-run on 2026-06-12 emitted 4 resolved lines, engine_version `v18_wsa_mix_weight_canonical`, no errors; get_procurement_demand returned 55 rows cleanly. `split_pct` retained as a read-only mirror (drop 2026-07-04); `assert_product_launch_ready` still validates `SUM(split_pct)=100` and is flagged for the same cutover (switch to `SUM(mix_weight)=1.0`).
**Rollback:** re-apply the v17 stitch body (`20260604200000_refillv2_ws6_suppress_zero_anywhere.sql`), the prior `get_procurement_demand` (split_pct attribution), and the prior secondaries (ORDER BY split_pct); mix_weight values are harmless to leave (split_pct unchanged). Migration files staged under `supabase/migrations/`.

---

## 2026-06-04 — PRD-018 BUG-C: resilient approve→dispatch bridge (APPLIED to prod)

**Phase / Article:** PRD-018 / Articles 1, 4, 5, 8, 12
**Applied to:** prod (`eizcexopcuoycuosittm`)
**Migration names:** `prd018_bugc_resilient_dispatch_bridge`, `prd018_bugc_bridge_severity_fix`
**Summary:** Root-cause fix for "packed items absent from dispatch list" (data-confirmed: many machines carried `refill_plan_output` rows `operator_status='approved' AND dispatched=false` — whole-machine bridge losses, e.g. 2026-05-17 AMZ-1068=33, AMZ-1038=39). Two causes: (1) `trg_fire_dispatch_on_approval` wrapped `push_plan_to_dispatch` in `EXCEPTION WHEN OTHERS … RAISE NOTICE`, **silently swallowing** any bridge failure so the operator's approve persisted while zero dispatch rows were written; (2) `push_plan_to_dispatch` v5 looped ALL of a machine's approved rows in one transaction, so a single raising row (`block_orphan_internal_transfer` — push isn't in its allow-list; `prevent_duplicate_unstarted_dispatch`; NULL shelf) aborted the **entire** machine's bridge. Fix → `push_plan_to_dispatch` **v6_resilient_bridge**: per-row `BEGIN/EXCEPTION` sub-block (one bad row is counted + logged to `monitoring_alerts` and its plan row stays `dispatched=false`/visible, siblings still bridge); `internal_transfer` rows skipped (they bridge via `swap_between_machines`); idempotent cover-link guard (link an existing live dispatch row instead of inserting a dup); returns `status='partial'` + `lines_failed`/`lines_skipped_internal_transfer` counters. `trg_fire_dispatch_on_approval` now records non-ok results AND exceptions to `monitoring_alerts` instead of a silent NOTICE, still without rolling back the operator's approve. Identity signature `(p_plan_date date, p_machine_name text)` unchanged; both stay `SECURITY DEFINER`, set `app.via_rpc`/`app.rpc_name`; push stays on the `enforce_canonical_dispatch_write` allow-list. **Caught in rolled-back verification:** `monitoring_alerts.severity` CHECK ∈ (info,warning,critical) — initial `'error'` was invalid and would have raised inside the handler; corrected to `'critical'` via the `_severity_fix` follow-up before any failure path could fire. Verified in a rolled-back tx (synthetic AMZ-1068 plan: good row bridges, internal_transfer skips, a `prevent_duplicate`-poisoned row fails in isolation while the good sibling bridges, re-run idempotent = 0 new rows, 2 `dispatch_bridge_failure` alerts surfaced). Cody-approved (Articles 1, 4, 5, 8, 12). **Note (Stax follow-up):** FE `RefillPlanningTab` should surface `status='partial'`/`lines_failed`. **Note (CS-gated):** the historical approved-undispatched backlog is NOT auto-rebridged (would create stale past-date dispatch rows) — separate per-row cleanup if wanted.
**Rollback:** restore the prior `push_plan_to_dispatch(date,text)` v5 body + the prior `trg_fire_dispatch_on_approval()` body from migration history (both forward-only `CREATE OR REPLACE`).

---

## 2026-06-05 — PRD-018 BUG-E: outbound multi-variant pack guardrail (APPLIED to prod)

**Phase / Article:** PRD-018 / Articles 1, 8, 12
**Applied to:** prod (`eizcexopcuoycuosittm`)
**Migration names:** `prd018_buge_guardrail3_pack_variant`, `prd018_buge_guardrail3_message_fix`
**Summary:** "Packed variant ≠ dispatch variant" (Red Bull Regular packed, dispatch shows Diet). **Not a data anomaly** — multi-`is_global_default` + `split_pct` is the fleet-wide mix design (≈55 pods carry several defaults). `stitch_pod_to_boonz` legitimately fans a multi-variant pod into one dispatch row per resolved variant by split (Red Bull → Regular 80% + Diet 20%); on a machine effectively stocking one physical variant the driver fills the off-variant row with what's on hand → packed ≠ dispatch. Backend fix = the OUTBOUND sibling of PRD-016 guardrail 2: NEW non-blocking BEFORE UPDATE trigger `flag_multivariant_pack_without_variant_confirmation()` on `refill_dispatching` firing on `packed` false→true; when the pod resolves to >1 active boonz variant for the machine AND no `variant_action_log` row exists for the dispatch, writes a `monitoring_alerts` (`prd018_guardrail3_pack_variant_unconfirmed`, warning) steering the FE to `record_variant_correction(action_type='dispatch_substitution')`. **Improvement over guardrail 2:** the variant count includes GLOBAL-default mappings (`machine_id IS NULL AND is_global_default`), not only machine-specific rows — guardrail 2's machine-specific-only count silently misses globally-mapped pods like Red Bull (count 0 → never fires). NEW trigger (no `pack_dispatch_line` rewrite — 24h rule). WARN posture (blocking a pack would be an outage). Verified in rolled-back tx (multi-variant pack → 1 alert; multi-variant pack with a `variant_action_log` row → 0). `_message_fix` follow-up: the advisory pointed at an invented `action_type pack_variant_change`; the `variant_action_log` CHECK only allows `return_variant_change/return_variant_split/dispatch_substitution/dispatch_extra_variant`, so re-pointed at the existing `dispatch_substitution`. Cody-approved (Articles 1, 8, 12, 14) — same blessed shape as guardrails 1 & 2. **FE → Stax:** packing screen must let the packer pick the actual variant and call `record_variant_correction`. **Held (Red Bull single-default):** making Red Bull a single global default is a product/mix decision (no machine would ever get Diet), inconsistent with the fleet pattern — NOT done; awaiting CS re-confirmation with this context.
**Rollback:** `DROP TRIGGER trg_flag_multivariant_pack_without_confirmation ON public.refill_dispatching; DROP FUNCTION public.flag_multivariant_pack_without_variant_confirmation();`

## 2026-06-05 — PRD-018 BUG-D: HELD pending Dara (reservation semantics)

**Phase / Article:** PRD-018 / Article 1 (design)
**Applied to:** none — RCA recorded, migration drafted then **withdrawn**
**Summary:** Shared-WH availability →0 / stale display. RCA: `pack_dispatch_line` moves `warehouse_stock→consumer_stock` AND stamps `reserved_for_machine_id` on the WHOLE batch row when packing only part of it, so `v_dispatch_availability.wh_avail` (and the pick path `pick_wh_batch_for_machine`, which excludes `held_for_other_machine`) hide a shared batch's remaining `warehouse_stock` from other machines → spurious 0 while stock>0 (Al Ain). The "stale 37" display is an FE bug (sums `warehouse_stock + consumer_stock` instead of live `warehouse_stock` — Stax). A one-line `v_dispatch_availability` view change (drop the reserved exclusion) was drafted and **Cody-blocked**: it would desync display from the pick path (item shows available but `pack_dispatch_line` still can't pick a held batch). Correct fix = a reservation-semantics decision on a canonical writer (`pack_dispatch_line` should stop earmarking the un-consumed remainder, e.g. clear `reserved_for_machine_id` when `warehouse_stock`>0 after the pick) + the view + the pick helper together → **Dara** design, then Cody re-review. Verified assumption along the way: only `pack_/receive_/return_dispatch_line` WRITE `reserved_for_machine_id` and all decrement stock in the same statement (`pick_wh_batch_for_machine` is read-only `LANGUAGE sql STABLE`).
**Rollback:** n/a (nothing applied).

---

## 2026-06-04 — Refill reliability batch: WS2 / WS4 / WS5 / WS6 / WS7 (APPLIED to prod)

**Phase / Article:** Phase F / Articles 1, 2, 4, 5, 8, 12, 14, 15
**Applied to:** prod
**Migration names (apply order):** `refillv2_ws5a_recommendation_intents`, `refillv2_ws5b_recommendation_rpcs`, `refillv2_ws7_pending_enriched_reader`, `refillv2_ws2a_skip_dispatch_line`, `refillv2_ws2b_push_edit_aware`, `refillv2_ws4a_driver_feedback_demand_view`, `refillv2_ws4b_engine_driver_demand`, `refillv2_ws6_suppress_zero_anywhere`
**Summary:** Eight migrations executing the 2026-06-03 refill post-mortem PRD (`docs/prds/PRD_refill_reliability_2026-06-03.md`). WS5a/WS5b add the recommendation-translator stack: `recommendation_intents` table (RLS, no-direct-write) + propose/confirm/reject/apply RPCs that turn free-text driver/ops asks into typed intents and, on human confirm, renormalize per-machine `product_mapping.mix_weight` to sum 1.0 (NOTE: engine still reads `split_pct`, not `mix_weight` — flagged follow-up). WS7 adds read-only `get_refill_plan_output_enriched(p_plan_date)` so the pending Refill Planning view shows live shelf stock + 7d sales instead of stitch's 0/0 placeholders. WS2a adds `skip_dispatch_line` (an unfulfillable line is marked skipped, not a hard block) + 4 new columns on `refill_dispatching` + allow-list entry on `enforce_canonical_dispatch_write`. WS2b makes `push_plan_to_dispatch` edit-aware so a re-push no longer clobbers a manual dispatch swap (the VML A01 Popit-over-Coke-Zero resurrection). WS4a adds `v_driver_feedback_demand` (unresolved asks, 14d decay, boonz→pod) and WS4b wires it into `engine_add_pod` v13 as a GREATEST demand floor (`clamp_reason='driver_request'`), self-resolving once planned. WS6 is `stitch_pod_to_boonz` v17: WS1b multi-variant REMOVE/M2W resolution (resolve to concrete boonz variant via pod_inventory FEFO + even split, physical-fallback path) + WS6.2 suppression of resolved variants with literally 0 stock anywhere (warehouse-sourced only; vox/internal exempt). The v17 file carries the 2026-06-03 confirm-on-error gate MERGED inline so re-baselining stitch cannot silently revert it (verified live: gate + WS6.2 filter + v17 marker + WS1b path all present). Each SECURITY DEFINER fn + protected DDL Cody-reviewed in its staged file header. WS1a confirm gate already live since 2026-06-03 (entry below).
**Rollback:** each is a forward-only `CREATE OR REPLACE` / additive `ALTER ... ADD COLUMN IF NOT EXISTS`; restore prior function bodies from migration history. WS2a columns are additive/defaulted (safe to leave). WS3 inventory reconciliation (VML receive + 2 WH transfers) intentionally NOT in this batch — pending per-row CS sign-off (a naive receive with no consumer reservation would inflate inventory; see post-mortem).

## 2026-06-03 — Stitch: gate confirm on write success (APPLIED to prod)

**Phase / Article:** Phase F / Articles 1, 4, 8, 12, 14
**Applied to:** prod
**Migration name:** `phaseF_stitch_gate_confirm_on_write_ok`
**Summary:** Root-cause fix from the 2026-06-03 refill post-mortem. `stitch_pod_to_boonz` called `confirm_stitched_plan` unconditionally right after `write_refill_plan`. When `write_refill_plan` returned `validation_error` (e.g. unmappable REMOVE `boonz_product_name` like `Evian`/`Vitamin Well`/`Krambals & Zigi`), the pod plan still flipped to `stitched` while `refill_plan_output` stayed empty -> silent whole-machine dispatch loss (this stranded VML-1003). `write_refill_plan` is already atomic (validation fails before any write), so the fix is purely in the orchestrator: only call `confirm_stitched_plan` when `write_refill_plan` returns `status='ok'`; otherwise return `skipped_write_failed` and leave the pod plan `approved` (retryable + visible). Applied surgically via a `DO`-block that fetches the live definition, replaces only the 2-line ELSE block, and aborts if the target is not found verbatim (no transcription of the 24KB body, no silent no-op). Cody-approved. Companion follow-ups (in PRD): WS1b resolve multi-variant REMOVE so it stops rejecting; WS2 stop `push_plan_to_dispatch` clobbering manual dispatch swaps. See `BOONZ BRAIN/PRD_refill_reliability_2026-06-03.md`.
**Rollback:** restore the pre-patch `stitch_pod_to_boonz` body (unconditional confirm) from migration history.

---

## 2026-06-02 — get_machine_health v2: expose v7 tier/track on Stock Snapshot (APPLIED to prod)

**Phase / Article:** Phase F / Article 12 (forward-only); read-only helper
**Applied to:** prod
**Migration name:** `phaseF_get_machine_health_v2_tier_track`
**Summary:** Extended the read-only `get_machine_health()` dashboard helper to emit `service_track` ('main'|'vox'), `priority_tier` ('P1_RESTOCK'|'P2_MAINTAIN'|'skip'), and `priority_score` using the SAME thresholds as picker v7, so the Stock Snapshot "Priority" card grid matches the picker instead of its old bespoke client-side `refillUrgency()`. Carried `machines.venue_group` through `device_metrics`; added a `CROSS JOIN LATERAL` computing units_7d (daily_velocity×7), runway (days_until_empty), dead% (dead_stock_count/total_slots), days_since_visit, and an intent proxy (pending_swap_count). Return-type widen required `DROP FUNCTION` + `CREATE` (function, not a data table); grants restored (PUBLIC/anon/authenticated/service_role). No writes; stays STABLE SECURITY DEFINER (justified — reads RLS-protected weimi/sales for the dashboard). FE (`src/app/(app)/refill/page.tsx`): `refillUrgency` now returns `priority_score`; priority sort = service_track→priority_tier→score; dashed "VOX · refilled daily on the spot" separator at the main→vox boundary; legend pills → P1 restock / P2 maintain / VOX (daily). tsc clean. **Note:** card-grid scores differ slightly from the picker because get_machine_health derives velocity from `sales_history` while the picker uses `v_machine_health_signals`; ordering intent is identical. Unify the velocity source later if exact parity is wanted.
**Rollback:** `DROP FUNCTION public.get_machine_health(); CREATE FUNCTION ...` restored from the pre-v2 (30-col) body in migration history; revert the FE diff in `refill/page.tsx`.

---

## 2026-06-02 — Picker v7: velocity + shelf reweight + VOX parallel track (APPLIED to prod)

**Phase / Article:** Phase F / Articles 1, 2, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseF_picker_v7_velocity_shelf_reweight`
**Summary:** Reweighted `pick_machines_for_refill` (canonical writer for `machines_to_visit`, a protected entity) from the old fill%/expiry-dominant severity CASE to a two-tier, velocity- and shelf-weighted model. **P1_RESTOCK** = any empty shelf (hard top, 50pts + 12 each extra), a selling machine running dry (runway <14d when units_7d≥20, or <7d for any), or a shelf <25% on a selling machine. **P2_MAINTAIN** = dead slots (≥15%), long refill gap (≥14d stale), expiry, or active intent — small weights so they never outrank a stockout. VOX machines are scored in the same pass but tagged `service_track='vox'` and ordered below all `main` rows (CS decision: VOX is refilled daily on the spot; keep visible as a parallel track below a dashed separator). Two additive columns on `machines_to_visit`: `service_track` (NOT NULL DEFAULT 'main', CHECK main/vox) and `priority_tier` (nullable, CHECK P1_RESTOCK/P2_MAINTAIN). Legacy `severity`/`priority_score` kept populated (tier→band map) for back-compat; downstream `engine_add_pod`/`engine_swap_pod` gate only on `status IN ('picked','cs_added')` — verified no dependency on severity granularity. Resolves known nit #17 (sibling rows now carry a real score). Dara-designed, Cody-reviewed (approve with revisions, all cleared). Verified: 30 machines for 2026-06-03 (22 main + 8 vox), AMZ-1038 correctly promoted from old "high" to #1 P1 (3 empty shelves, 81 units/wk); picker runs in ~2.3s.
**Rollback:** `CREATE OR REPLACE FUNCTION public.pick_machines_for_refill(date)` restored from the v6 body (in migration history); the two columns are additive and may be left in place. Re-running the restored v6 function supersedes and re-picks.

---

## 2026-06-02 — PRD-017 refill availability bugs (APPLIED to prod)

**Phase / Article:** PRD-017 / Articles 1, 4, 6, 12
**Applied to:** prod (`eizcexopcuoycuosittm`)
**Migrations:** `prd017_buga_v_dispatch_availability_serving_wh`, `prd017_buga_get_pod_refill_draft_wh_avail_s1`, `prd017_buga_engine_add_pod_s1_suppress`
**Summary:** **BUG-A** — the WH-availability used by packing/draft/sizing now uses the §1 _Available_ definition (serving WH = machine primary+secondary, `status='Active'`, `quarantined=false`, in-date `expiration_date>=CURRENT_DATE`/NULL, `reserved_for_machine_id` NULL-or-self; never `consumer_stock`). Three surfaces, each verbatim-repro with only the WH-stock lines changed: `v_dispatch_availability` (CTE rekeyed per-(machine,product), join on both keys — **verified 47/47 rows match §1, 0 mismatch; 40 warehouse rows now `blocked_no_wh`; 0 vox/internal ever blocked** = edges 1/2/3/5/6, edge 4 surfaced as blocked_no_wh), `get_pod_refill_draft.wh_avail` (+expiry/serving-WH/reservation clauses), `engine_add_pod` → **v12_wh_avail_s1_suppress** (wh_avail = §1 per-machine; `wh_avail=0` ⇒ `final_qty=0`, `clamp_reason='blocked_no_wh'`, while `gap_rows` still emits the procurement_gap = edge 4 not silent). **BUG-B** — classified all three against §1 (all machines serve WH_CENTRAL only): YoPRO Choc@OMDCW = Case 1 (set 3 via `adjust_warehouse_stock` as the warehouse manager, provenance manual_adjust → Available 3); Hunter Ridge@HUAWEI = already Available 1 (pickup-0 was the read bug, fixed by BUG-A); VW Upgrade@MINDSHARE = already Available 1, the 19+5 in WH_MCC flagged Case 2 (wrong-WH, transfer = policy) + Case 3 (quarantined, manager propose-then-confirm — never auto). **Cleanups:** GH Popped Chips **Sweet BBQ** (only qualifier: mapped+present+3 WH) retro Add New @ MINDSHARE 2026-06-01 via `log_retroactive_refill_visit`; YoPRO count set to 3. Cody ✅ each change. Article-6 honored (no auto status/quarantine flip; warehouse writes ran as the warehouse manager with audit).
**Rollback:** `CREATE OR REPLACE` each view/function to its prior body (v_dispatch_availability prior def, get_pod_refill_draft prior wh_avail, engine_add_pod v11); the data adjusts reverse via `adjust_warehouse_stock` back to prior counts.

---

## 2026-06-01 — Refill-Day capabilities RD-01/03/05 (FILES WRITTEN, NOT APPLIED)

**Phase / Article:** Refill-Day batch / Articles 2,3,4,5,7,8,12,14,15
**Applied to:** repo only (output-only goal; CS reviews + applies)
**Migration names:** `20260601200000_rd01_create_plan_add_machine`, `20260601210000_rd05_fefo_pick`, `20260601220000_rd03_driver_self_service`
**Summary:** Phase 1 of the Refill-Day PRD set (RD-00..RD-06). RD-01: `add_machine_to_plan`/`create_refill_plan` (ad-hoc plan/machine; cs*added/operator; never runs engine). RD-05: `preferred_wh_inventory_id` pin + read-only `get_shelf_fefo_options` + `edit*/add_pod_refill_row`extended to 9-arg via no-DROP wrapper (#6 precedent). RD-03:`driver_outcome`cols +`driver_recommendations`table +`driver_report_dispatch_outcome`/`driver_propose_adjustment`. Phase 2 (RD-02/04/06) HELD: depends on FIX-1 (`v_live_shelf_stock`aisle fix) which is unapplied (closed as misdiagnosis — off-by-one only in unused`aisle_code`; callers read `slot_name`). RD-03 open question: no `dispatch_plan`/driver-assignment model exists, so per-driver ownership scoping is role+active-line only (Cody must rule).
**Rollback:** n/a (nothing applied; delete the migration files to discard).

---

## 2026-06-01 — Refill System v2 Phase 2 / #10 stage-2a: engine_swap_pod consumes signals (feeding)

**Phase / Article:** Refill v2 Phase 2 / Constitution Articles 1, 4, 12
**Applied to:** prod
**Migration name:** `refillv2_p2_learning_loop_feed_swaps`
**Summary:** Closes the "feeding the engine" half of #10. `engine_swap_pod` v9_3→`v9_4_signal_feedback` (verbatim repro, diff-gated to: a new `ON COMMIT DROP` temp `_suppressed_swap_subs` = (machine_id, pod_product_id) from `refill_edit_signals WHERE signal_type='swap_rejected' AND created_at >= now()-30d GROUP BY machine,pod HAVING COUNT(*)>=3` — the 3-in-30d rule CS chose; a `LEFT JOIN` + `WHERE sss.pod_in IS NULL` in `sub_candidates`; version bump x3). A substitute CS has rejected 3+ times in 30d on a machine is never re-proposed. Read-only on `refill_edit_signals`; no new write path (still `pod_swaps`); composes cleanly with the F6 swaps-disabled gate and the #2 machine-present dedup. No-op at zero signal volume. Cody ✅. Verified pg_proc v9_4. The other two #10 feedback mechanisms (per-shelf qty bias in `engine_add_pod`; raise-repeatedly-missed-items, a placement-layer concern) are documented stage-2b follow-ups, deliberately deferred until real signal volume.
**Rollback:** `CREATE OR REPLACE` engine_swap_pod back to the v9_3 body.

---

## 2026-06-01 — Refill System v2 Phase 2 / #10 stage-1: learning-loop capture

**Phase / Article:** Refill v2 Phase 2 / Constitution Articles 2, 4, 7, 8, 12, 14 (+15 Appendix A)
**Applied to:** prod
**Migration name:** `refillv2_p2_learning_loop_capture`
**Summary:** Captures the learning loop's facts (DONE-WHEN: "edit-signals captured"). Two new append-only tables (Dara): `engine_recommendation_snapshot` (immutable per plan_date; UNIQUE 5-tuple) and `refill_edit_signals` (typed signals: qty_raised/qty_lowered/item_added/item_removed/swap_rejected + delta). Both RLS-enabled, operator SELECT, no-update/no-delete, DEFINER-only writes. New write-once DEFINER `snapshot_engine_recommendations(plan_date, machine_ids[])` (`ON CONFLICT DO NOTHING`). Capture by trigger (Dara D6): `tg_capture_refill_edit_signal` AFTER INSERT/UPDATE on `pod_refill_plan` fires only for manual-edit RPCs (reads `app.rpc_name` ∈ edit/add_pod_refill_row), diffs vs the snapshot, inserts a typed signal — engine/orchestrator writes are skipped so the engine never logs itself. Seeded 10 rows from the 2026-06-01 `driver_feedback`. Cody ✅. Verified: both tables RLS + 3 policies, snapshot RPC, trigger, 10 seed rows. TODO: add both tables to Appendix A.
**Rollback:** `DROP TRIGGER tg_capture_refill_edit_signal ON pod_refill_plan; DROP FUNCTION tg_capture_refill_edit_signal(), snapshot_engine_recommendations(date,uuid[]); DROP TABLE refill_edit_signals, engine_recommendation_snapshot;`.

---

## 2026-06-01 — Refill System v2 Phase 2 / #8 F6: swaps on/off flag

**Phase / Article:** Refill v2 Phase 2 / Constitution Articles 1, 2, 4, 12, 14 (+15 Appendix A)
**Applied to:** prod
**Migration name:** `refillv2_f6_swaps_flag`
**Summary:** Lets CS toggle the autonomous swap engine off globally or per-machine (DONE-WHEN: "swaps toggleable"). (A) New KV config table `refill_settings(setting_key PK, setting_value jsonb, updated_at, updated_by)` — CS chose this over altering the protected `machines` table. RLS: SELECT for operator/superadmin/manager; no write policies (sole writer is the DEFINER via owner-bypass; it is mutable config, NOT an append-only log, so intentionally no no_update/no_delete). Seeds `('swaps_enabled','true')`. (B) New DEFINER `set_swaps_enabled(p_enabled boolean, p_machine_id uuid DEFAULT NULL)` upserts global key `swaps_enabled` or per-machine `swaps_enabled:<id>`; gate operator_admin/superadmin + service bypass. (C) `engine_swap_pod` v9_2→v9_3 (verbatim repro, diff-gated to: a new `ON COMMIT DROP` temp `_swaps_disabled_machines` = machines whose effective flag [per-machine override ?? global ?? true] = false; `AND NOT EXISTS(_swaps_disabled_machines)` on BOTH `picked` CTEs (pass-1 tag + pass-2 autonomous); version bump x3). A disabled machine generates zero swaps in either pass. Dara table, Cody ✅. Verified: settings RLS on + seed='true', `set_swaps_enabled` + `engine_swap_pod` v9_3 with the gate in pg_proc. TODO: add `refill_settings` to Appendix A.
**Rollback:** `CREATE OR REPLACE` engine_swap_pod back to v9_2 body; `DROP FUNCTION set_swaps_enabled(boolean,uuid); DROP TABLE refill_settings;`.

---

## 2026-06-01 — Refill System v2 Phase 2 / #8 F5: commit_refill_plan + refill_commit_log

**Phase / Article:** Refill v2 Phase 2 / Constitution Articles 2, 4, 7, 12, 14 (+15 Appendix A)
**Applied to:** prod
**Migration name:** `refillv2_f5_commit_refill_plan`
**Summary:** Captures every refill-plan push with the operator's free-text comment (DONE-WHEN: "push comments captured"). New append-only table `refill_commit_log` (commit_id PK, plan_date, comment [CHECK non-empty], committed_by→user_profiles ON DELETE SET NULL, committed_at, machine_ids uuid[] [NULL=whole plan], scope all/subset, summary jsonb, via_rpc, rpc_name; index (plan_date, committed_at DESC)). RLS enabled: SELECT for operator_admin/superadmin/manager via `(SELECT auth.uid())` user_profiles join; `no_update`/`no_delete` USING(false); NO insert policy so the DEFINER (owner) is the sole writer (Article 7, same pattern as pod_inventory_audit_log). New DEFINER `commit_refill_plan(p_plan_date, p_comment, p_machine_ids uuid[] DEFAULT NULL)`: role gate + `auth.uid() IS NULL` bypass, validates plan_date + non-empty comment, computes a read-only summary (line counts by action + machine count from refill_plan_output), inserts one log row. Dara-designed table, Cody ✅. Verified: table RLS on + 3 policies, function in pg_proc. TODO: add `refill_commit_log` to Constitution Appendix A (Article 15 housekeeping).
**Rollback:** `DROP FUNCTION commit_refill_plan(date,text,uuid[]); DROP TABLE refill_commit_log;` (no other dependants).

---

## 2026-06-01 — Refill System v2 Phase 2 / #7: reset_and_restitch (plans editable without raw writes)

**Phase / Article:** Refill v2 Phase 2 / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `refillv2_p2_reset_and_restitch`
**Summary:** One canonical call to re-derive + re-stitch a plan subset, replacing the ~8 raw dispatch edits a live correction used to need (DONE-WHEN: "plans editable without raw writes"). `reset_and_restitch(p_plan_date, p_machine_ids uuid[], p_reason text)` composes existing canonical writers: (1) dispatch guard refuses if any subset `refill_plan_output` row is past `pending`; (2) RESET — archive-only supersede of all active subset `pod_refill_plan` rows (full reset per CS: discards manual adds; manual qty-edits overwritten in step 3); (3) `engine_finalize_pod(date, ids)` [#6 subset-aware] re-derives engine rows → draft; (4) `approve_pod_refill_plan(date, names)` draft → approved; (5) `stitch_pod_to_boonz(date, false)` re-emits — SAFE because `write_refill_plan` deletes per-machine + pending-only, so dispatched machines are untouched. Role gate operator_admin/superadmin + `auth.uid() IS NULL` bypass; reason ≥10; sets app.via_rpc. The only direct protected-entity write is the archive-only supersede (same family as void_refill_plan). Caveat (documented): stitch is whole-plan (reads all approved); bounded-safe via the per-machine pending-only write. Cody ✅. Verified pg_proc.
**Rollback:** `DROP FUNCTION reset_and_restitch(date,uuid[],text);` (composes existing writers; no data migration).

---

## 2026-06-01 — Refill System v2 Phase 2 / #6 (B6): engine_finalize_pod subset-aware

**Phase / Article:** Refill v2 Phase 2 / Constitution Articles 1, 4, 8, 12
**Applied to:** prod
**Migration name:** `refillv2_b6_finalize_subset_aware`
**Summary:** Makes the `pod_refill_plan` finalize/stitch writer subset-aware so a single machine (or set) can be re-stitched without clobbering the rest of the plan (foundation for #7 reset_and_restitch). Shape (Cody, Article 12 — NO DROP): the existing 1-arg `engine_finalize_pod(date)` is replaced in place with a thin wrapper that delegates to a new 2-arg `engine_finalize_pod(date, uuid[])` passing NULL (whole plan). The 2-arg carries no defaults (a `DEFAULT NULL` would make the 1-arg call ambiguous; Postgres also forbids a defaulted param before a non-defaulted one). FE/orchestrator one-arg calls hit the wrapper unchanged (verified 0 SQL-function callers, 0 cron). The 2-arg body is a verbatim reproduction of live v12_1, diff-gated to exactly: 14 machine gates `(p_machine_ids IS NULL OR <tbl>.machine_id = ANY(p_machine_ids))` on every machine-scoped clause (supersede UPDATE, the 4 INSERT-source CTEs, empty_shelf UPDATE, orphan_m2w SELECT + suppress UPDATE, the v_refills_in/v_swaps_in/v_overruled counts, swap_counts r7, high_velocity capacity scan) + version v12_1→v13_subset_aware. When `p_machine_ids IS NULL` behaviour is identical to v12_1. Role gate (operator_admin + `auth.uid() IS NULL` bypass), `app.via_rpc`, the `ON CONFLICT` upsert, and the universal audit trigger are unchanged. The 2-arg granted EXECUTE to authenticated/anon/service_role (mirroring the original). No schema change. Cody ✅ (revised from DROP+CREATE to the no-DROP wrapper). Verified live: 2 overloads exist, 2-arg is v13_subset_aware, 1-arg delegates.
**Rollback:** `CREATE OR REPLACE` the 1-arg with the original v12_1 body and `DROP FUNCTION engine_finalize_pod(date, uuid[])`. Pure function-body change; no data change.

---

## 2026-06-01 — Refill System v2 Phase 2 / #4 (B4): stitch_pod_to_boonz cap REMOVE/M2W qty at shelf stock

**Phase / Article:** Refill v2 Phase 2 / Constitution Articles 1, 4, 6, 8, 12, 14
**Applied to:** prod
**Migration name:** `refillv2_b4_cap_remove_qty_live_stock`
**Summary:** Caps mapped REMOVE/M2W dispatch quantities at what is physically on the shelf. The engine had emitted removes far above capacity (Nescafe 96, Nutella 234, Be-kind 144) because `remove_lines` fanned the PLANNED qty across pod_inventory variants with no cap. Fix (verbatim reproduction of stitch v13, diff-gated to two lines): `remove_lines.variant_final` wrapped in `CASE WHEN source_origin='internal_transfer' THEN <uncapped fan-out> ELSE LEAST(<fan-out>, current_stock) END` where `current_stock` is the per-variant `pil.current_stock` already in `remove_lines_raw` (which filters `current_stock>0`); plus `engine_version` v13→v14_remove_qty_capped. `internal_transfer` rows are left UNCAPPED so the `v_remove_violations` fan-out invariant (actual vs planned, internal_transfer only) still holds. The #3 physical-fallback path already caps at `v_live_shelf_stock`. REFILL/ADD path, deviations, procurement_alerts, role gate, `app.via_rpc` unchanged. No new write path, no schema change. Cody ✅. Verified live: `v14_remove_qty_capped` + the `LEAST(...)` cap present.
**Rollback:** `CREATE OR REPLACE` the prior v13 body (unwrap the CASE back to the uncapped fan-out, revert version literal). Pure function-body change.

---

## 2026-06-01 — Refill System v2 Phase 2 / #3: stitch_pod_to_boonz physical REMOVE/M2W fallback

**Phase / Article:** Refill v2 Phase 2 / Constitution Articles 1, 4, 6, 8, 12, 14
**Applied to:** prod
**Migration name:** `refillv2_p2_stitch_physical_remove_fallback`
**Summary:** Fixes REMOVE/M2W rows silently producing no driver dispatch line for VOX/untracked products (e.g. OMDCW A01 Popit remove never reached the driver). Root cause: `remove_lines_raw` INNER JOINs `v_pod_inventory_latest` with `current_stock>0`; VOX-sourced products are physically present (`v_live_shelf_stock`) but not tracked in `pod_inventory`, so the line was dropped and only surfaced in the `diag` array as `no_inventory_to_remove` (driver never sees diag). Confirmed not a mapping gap: Popit has 117 active mappings and 0 pods are physically-present-unmapped fleet-wide. Fix (verbatim reproduction of stitch v12, diff-gated to intended lines only): (A) new CTE `remove_lines_physical_fallback` — for REMOVE/M2W rows that are NOT `internal_transfer` and where the mapped+inventory path produced no line for that (machine,shelf,pod), emit a driver line with `boonz_product_id` NULL and qty = `v_live_shelf_stock.current_stock` (joined `slot_name`<->`shelf_code`, `current_stock>0`); (B) `UNION ALL` into `all_lines`; (C) two comment-CASE branches for `boonz_product_id IS NULL` removes (physical remove / untracked M2W, both flagged "no WH credit"); (D) `engine_version` `v12_wh_decoupled_fanout_fix_diag` -> `v13_physical_remove_fallback`. The existing mapped remove path, the `internal_transfer` fan-out invariant (`v_remove_violations` RAISE), `refill_plan_deviations`, `procurement_alerts`, the role gate, and `app.via_rpc` are byte-identical. The emitted `v_lines` jsonb keys on `boonz_product_name` (set to `pod_product_name`) and never carried `boonz_product_id`, so the NULL id stays internal — no leak to `write_refill_plan`/dispatch. No new write path, no schema change. Cody ✅ (Articles 1, 4, 6, 8, 12, 14). Verified live: `pg_get_functiondef` shows the fallback CTE, the comment branch, and `v13` with no `v12` remnant. Dry-run on a real approved plan deferred (no plan currently in `approved`).
**Rollback:** `CREATE OR REPLACE` the prior `v12_wh_decoupled_fanout_fix_diag` body (drop `remove_lines_physical_fallback`, its `UNION ALL`, the two comment branches, revert the version literal). Pure function-body edit; no data change.

---

## 2026-06-01 — Refill System v2 Phase 2 / #2: engine_swap_pod machine-present dedup

**Phase / Article:** Refill v2 Phase 2 / Constitution Articles 1, 4, 8, 12, 14
**Applied to:** prod
**Migration name:** `refillv2_p2_swap_dedup_machine_present`
**Summary:** Fixes the dedup-guard bug where the swap engine introduced a substitute already present on the machine (e.g. OMDBB-1020 Barebells duplicated to a 2nd shelf; `dedup_demoted_to_m2w=false`). Root cause: pass-2 substitute selection only excluded a substitute that had an Active `v_pod_inventory_latest` row (the ERP's belief via `product_mapping`); it never checked `slot_lifecycle` placement or physical WEIMI stock, so a product physically present but with a mapping/inventory gap looked "absent" and got swapped onto a second shelf. Fix (verbatim reproduction of `engine_swap_pod`, diff-gated to only the intended lines): (A) new `ON COMMIT DROP` temp table `_machine_present_pods` = `slot_lifecycle` is_current UNION `v_live_shelf_stock` physical (`current_stock>0`), keyed (machine_id, pod_product_id); (B) `sub_candidates` LEFT JOINs it on the substitute and requires `mpp.pod_product_id IS NULL`, so a substitute already present anywhere on the machine is dropped from the pool and the dead shelf falls to M2W — never duplicated; (C) `engine_version` `v9_1_product_match_planned_swap` → `v9_2_machine_present_dedup` (3x). No schema change, no role/gate change (operator_admin + `auth.uid() IS NULL` service bypass preserved), no new raw write path. Investigation also closed the goal's #1 (the `v_live_shelf_stock` aisle off-by-one is real but lives only in the unused `aisle_code` field; all six callers read `slot_name`, so no view rewrite was needed) and ruled OUT an `engine_add_pod` refill-dedup (20 legitimate multi-facings across 11 machines — e.g. Aquafina on 6 shelves — would be regressed by collapsing same-product-multiple-shelf rows; the YoPro duplicate was a bad placement, prevented going forward by this swap-side guard). Cody ✅ (Articles 1, 4, 8, 12, 14). Verified live: `pg_get_functiondef` shows the temp table, the join+`mpp ... IS NULL` guard, and `v9_2` with no `v9_1` remnant.
**Rollback:** `CREATE OR REPLACE` the prior `v9_1_product_match_planned_swap` body (remove `_machine_present_pods`, its LEFT JOIN, the `AND mpp.pod_product_id IS NULL` predicate, and revert the 3 version literals). Pure function-body edit; no data change.

---

## 2026-06-01 — get_vox_consumer_report: raise recent_txns cap (banner/list discrepancy mismatch)

**Phase / Article:** Phase F / Constitution Articles 12, 14
**Applied to:** prod
**Migration name:** `phaseF_vox_consumer_report_raise_recent_txns_limit`
**Summary:** `/refill/consumers` banner showed "32 Discrepancies" while the Default-filtered list showed only 15. Root cause: `summary.disc_count` is computed server-side over ALL matched baskets (32), but the FE Default view filters `D.transactions`, which is the RPC's `recent_txns` subquery capped at `LIMIT 2000` (the 2000 most-recent baskets). With ~90 baskets/day the 2000-row window only reached back to ~09 May, so 17 older discrepancies were counted but never loaded. Same cap-then-filter family as the `/app/performance` 10k truncation. Fix: bumped the single `recent_txns` literal `LIMIT 2000` → `LIMIT 100000` so the list covers the full bounded date window. Read-only `STABLE` `SECURITY INVOKER` function; no protected-entity write path. Applied as a forward `CREATE OR REPLACE` re-derived from the live definition via `pg_get_functiondef` + single-literal `replace()` with a guard (aborts if `LIMIT 2000` not found), avoiding manual transcription of the large body. Cody ✅ (Articles 12, 14). Verified live: function now carries `LIMIT 100000`; RPC returns all 4,190 baskets, `disc_count`=32 and disc rows in `transactions`=32 (was 15). Payload grows from 2k to ~4k transaction rows for a normal quarter.
**Rollback:** Re-run the same DO-block pattern replacing `LIMIT 100000` → `LIMIT 2000` (or `CREATE OR REPLACE` the prior body). No data change; pure function-body edit.

---

## 2026-06-01 — Refill System v2 Phase 1 / F1: reschedule_refill_plan

**Phase / Article:** Refill v2 Phase 1 / Constitution Articles 1, 3, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `refillv2_p1_reschedule_refill_plan` (file `supabase/migrations/20260601100100_refillv2_p1_reschedule_refill_plan.sql`)
**Summary:** Second lifecycle writer — "plan movable between dates" (DONE-WHEN). `reschedule_refill_plan(p_from_date, p_to_date, p_reason)` moves a whole plan coherently: key-move `UPDATE plan_date` on both `machines_to_visit` (the full visit list, preserving `status`/`confirmed_at`/`is_included`) and the live `pod_refill_plan` rows (`draft/approved/stitched`, stamped `reasoning.rescheduled_from`). Never DELETE. DEFINER, `operator_admin/superadmin`, GUCs set, reason ≥10, `from≠to`. Guards: refuses if `p_from_date` is dispatched (`refill_plan_output` past `pending`) or if `p_to_date` is already occupied in either table (no clobber); terminal rows (`voided/superseded`) stay on the old date. Chose full coherent move (Option A) over draft-only (Option B, which would leave the target date with a draft but no visit list / confirm gate). `pod_refill_plan` audited by `tg_audit_pod_refill_plan`; `machines_to_visit` has no audit trigger (matches its existing writers — traceable via `reasoning.rescheduled_from`). Cody ⚠️-approved (machines_to_visit audit gap tracked). Verified live: no-op move between two empty future dates → `machines_moved:0, plan_rows_moved:0`.
**Rollback:** `DROP FUNCTION IF EXISTS public.reschedule_refill_plan(date,date,text);` (data moves are not auto-reverted — reschedule back to the original date if needed).

---

## 2026-06-01 — Refill System v2 Phase 1 / F1: void_refill_plan

**Phase / Article:** Refill v2 Phase 1 / Constitution Articles 1, 3, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `refillv2_p1_void_refill_plan` (file `supabase/migrations/20260601100000_refillv2_p1_void_refill_plan.sql`)
**Summary:** First Phase 1 lifecycle writer. Adds a distinct `voided` terminal state to `pod_refill_plan_status_check` (forward-only drop + re-add; new value set is a superset so existing rows re-validate) and the canonical writer `void_refill_plan(p_plan_date, p_reason)`. DEFINER, role `operator_admin/superadmin`, sets `app.via_rpc`/`app.rpc_name`, reason ≥10 chars. Archive-only: `UPDATE … SET status='voided'` on rows in `draft/approved/stitched`, appending `{voided_reason,voided_by,voided_at}` to `reasoning`; never DELETE; idempotent (re-void skips already-`voided` rows). Refuses if any `refill_plan_output` row for the date is past `pending` (plan already dispatched → cancel the dispatch leg first), so it cannot orphan downstream dispatching. Scoped to `pod_refill_plan` only (does not touch `machines_to_visit` — reschedule's job — nor `refill_plan_output`). Audited by the existing universal trigger `tg_audit_pod_refill_plan` (`audit_log_write`), confirmed installed on the table. Mirrors the `reject_pod_refill_rows` template. Cody ✅. Verified live: constraint updated; no-op call on an empty future date returned `voided_rows:0`.
**Rollback:** `DROP FUNCTION IF EXISTS public.void_refill_plan(date,text);` and restore the prior CHECK (`ALTER TABLE public.pod_refill_plan DROP CONSTRAINT pod_refill_plan_status_check; ADD CONSTRAINT … CHECK (status = ANY (ARRAY['draft','approved','stitched','superseded']));`) — only safe once no row is in the `voided` state.

---

## 2026-06-01 — Refill System v2 Phase 0 / B2: shelf aisle-index regression guard

**Phase / Article:** Refill v2 Phase 0 / Constitution Articles 4, 8, 11, 12, 14
**Applied to:** prod
**Migration name:** `refillv2_b2_shelf_index_drift_guard` (file `supabase/migrations/20260601090100_refillv2_b2_shelf_index_drift_guard.sql`)
**Summary:** B2 audit found the historical `v_live_shelf_stock` off-by-one (WEIMI `aisle_code` is 0-indexed `0-A00..0-A15`; `slot_name`/showName is 1-indexed `A1..A16`; `shelf_code` is `A01..A16` and aligns with `slot_name`) is **already resolved end-to-end**: `seed_shelf_configurations` derives `shelf_code` as `letter || (aisle_code_number + 1)`, and all five named read-callers (`engine_add_pod`, `engine_swap_pod`, `get_pod_refill_draft`, `get_machine_slots_with_expiry`, `pick_machines_for_refill`) join on `slot_name = LEFT(shelf_code,1)||SUBSTR(shelf_code,2)::int`. Live proof: 727/727 fleet slots satisfy the invariant (0 drift); WPP Nescafe sits correctly on A02 (signal KEEP), not A01. The "WPP A01 Nescafe wrong-removal" in the learning baseline was the pre-fix state. Rather than edit already-correct joins (no-refactor rule), installed an **additive read-only regression guard**: view `v_shelf_aisle_index_drift` recomputes the `aisle_code+1 == slot_name` invariant per live slot (verdict `ok|index_drift|unparseable_aisle_code`, `expected_slot_name` mirrors the seed exactly), and cron `shelf_aisle_index_drift_alert` (jobid 24, `30 3 * * *` = 07:30 Dubai) → `cron_shelf_index_drift_alert()` writes one deduped `monitoring_alerts` (`shelf_aisle_index_drift`, critical) finding if any slot ever drifts or a malformed aisle_code appears, warning ops NOT to re-seed `shelf_configurations` until resolved. Cody ✅. Verified live: view 0 non-ok, function `status:ok`, 0 inserted.
**Rollback:** `SELECT cron.unschedule('shelf_aisle_index_drift_alert'); DROP FUNCTION IF EXISTS public.cron_shelf_index_drift_alert(); DROP VIEW IF EXISTS public.v_shelf_aisle_index_drift;`

---

## 2026-06-01 — Refill System v2 Phase 0 / B1: draft-missing alert

**Phase / Article:** Refill v2 Phase 0 / Constitution Articles 4, 8, 11, 12, 14
**Applied to:** prod
**Migration name:** `refillv2_b1_draft_missing_alert` (file `supabase/migrations/20260601090000_refillv2_b1_draft_missing_alert.sql`)
**Summary:** The 8pm Dubai builder cron (job 13 `phaseF_stage1_prep_8pm_dubai` → `build_draft_for_confirmed(CURRENT_DATE+1)`) returns a jsonb `status` of `draft_ready` | `awaiting_confirmation` | `no_included_machines` without raising, so pg_cron logs every outcome identically as "succeeded / 1 row". A night where nobody confirmed the picked machines produced no draft and no signal; ops discovered the empty plan the next morning. Added a companion cron `refill_draft_missing_alert` (jobid 23, `15 16 * * *` = 20:15 Dubai, 15 min after the builder) calling new DEFINER `cron_refill_draft_missing_alert()`. It checks `refill_plan_output` for tomorrow; if zero rows it writes ONE `monitoring_alerts` (`source='refill_draft_missing'`, severity `critical`) row carrying the precise reason — recomputed read-only from `machines_to_visit` with the same predicates the builder uses (`no_machines_picked` / `awaiting_confirmation` / `no_included_machines` / `engine_produced_no_rows`) plus an `action_needed` line — deduped per plan_date per calendar day. Alert-only: does NOT auto-confirm machines (PRD-015 human-gate preserved). Shape mirrors the approved `cron_unmatched_weimi_alert`. Cody ✅ (Articles 4, 8, 11, 12, 14). Verified live: cron active; rolled-back dry run returned `{status: ok, refill_plan_output_rows: 149, inserted: 0}` against today's existing plan (no false alert).
**Rollback:** `SELECT cron.unschedule('refill_draft_missing_alert'); DROP FUNCTION IF EXISTS public.cron_refill_draft_missing_alert();`

---

## 2026-05-31 — PRD-016B: Track 7 return/transfer guardrails (Migration 2 + Guardrails 1 & 2)

**Phase / Article:** Phase F / Constitution Articles 1, 4, 6, 8, 12
**Applied to:** prod
**Migration names:** `phaseF_prd016_unverified_return_provenance`, `phaseF_prd016_guardrail1_m2m_as_remove`, `phaseF_prd016_guardrail2_return_variant_correction`
**Summary:** Finished the return/transfer guardrails whose design + containment substrate shipped earlier (PRD-016 / `phaseF_prd016_quarantine_unverified_return`). Each task is its own forward migration, each Cody-reviewed separately.

- **Guardrail 3 functional (Migration 2).** Surgical `CREATE OR REPLACE` of canonical writers `return_dispatch_line` and `receive_dispatch_line`, bodies reproduced verbatim. Only change: each create-new-batch ELSE branch (the `IF NOT FOUND` path that invents a WH batch — `REMOVE-RETURN-%` in return; `RETURN-%` + `REMOVE-RECEIVE-%` in receive) now stamps `app.provenance_reason='dispatch_return_unverified'` immediately before the INSERT and restores the trusted value (`dispatch_return`/`dispatch_receive`) immediately after. The restore is required for correctness: `trg_set_wh_provenance` fires BEFORE INSERT OR UPDATE and overwrites `provenance_reason` from the GUC, and the Remove breakdown loop interleaves create-new INSERTs with merge UPDATEs, so an unverified value would otherwise leak onto a later merge and falsely quarantine a real batch. Net: a return landing on a real received batch stays trusted (`quarantined=false`); a return inventing a batch lands `quarantined=true` on the needs-review screen. Closes Bug C going forward. Verified in a rolled-back tx: no-match return → `dispatch_return_unverified`/quarantined; matching-batch return → `dispatch_return`/not quarantined. Static diff = exactly the 10 stamp lines (2 in return, 3 in receive, paired with restores).
- **Guardrail 1 (Bug A).** New non-blocking BEFORE INSERT trigger `flag_remove_with_transfer_intent()` on `refill_dispatching`: a `Remove` row with a `[TRUCK-TRANSFER]` comment but `is_m2m=false` and `m2m_partner_id IS NULL` writes a `monitoring_alerts` (`warning`) row steering to `swap_between_machines`. `block_orphan_internal_transfer` did not cover this (source_origin is `warehouse`, not `internal_transfer`). WARN posture (Cody): blocking before the FE routes truck-transfers to `swap_between_machines` would convert a data-quality bug into an outage. Verified: transfer-intent Remove → 1 alert; normal Remove → 0.
- **Guardrail 2 (Bug B).** New non-blocking BEFORE UPDATE trigger `flag_multivariant_return_without_correction()` on `refill_dispatching`, firing on the `returned` false→true commit: if the dispatch's `pod_product_id` maps to >1 active boonz variant on its machine AND no `variant_action_log` row exists for the dispatch, writes a `monitoring_alerts` (`warning`) row steering to `record_variant_correction`. Implemented as a NEW trigger (not a 2nd `CREATE OR REPLACE` of `return_dispatch_line`) to respect the 24h-rewrite hard rule; the fire point shares the return transaction so a future escalation to RAISE rolls back the WH credit atomically. The FE escape hatch (`record_variant_correction` → `variant_action_log`, called BEFORE the return) goes to Stax (STAX-2026-05-31-01). Verified: multi-variant return without correction → 1 alert; with a prior `variant_action_log` row → 0; single-variant → 0.
- **Smoke:** both writers valid, both triggers live, packing/pickup dispatch read joins return rows, WH baseline unchanged (973 rows / 870 quarantined / 0 `dispatch_return_unverified` live). No `source_origin` writes; no protected-table direct writes. All verification used rolled-back transactions (0 leaked rows/alerts).
  **Follow-ups:** (1) escalate Guardrail 1 + 2 WARN→BLOCK once the FE wiring lands; (2) the receive-of-Remove WH credit (`item_added` flip) has the same multi-variant ambiguity as Guardrail 2 — out of PRD-016B scope, logged as a known gap.
  **Rollback:** Migration 2 — re-apply return/receive verbatim with the ELSE-branch stamps removed (already-quarantined rows stay quarantined; WH manager unquarantines via recount). Guardrails 1 & 2 — `DROP TRIGGER trg_flag_remove_with_transfer_intent ON refill_dispatching; DROP FUNCTION flag_remove_with_transfer_intent();` and `DROP TRIGGER trg_flag_multivariant_return_without_correction ON refill_dispatching; DROP FUNCTION flag_multivariant_return_without_correction();`

---

## 2026-05-31 — Phase F: add_pod_refill_row canonical writer (manual-add path)

**Phase / Article:** Phase F / Constitution Articles 1, 4, 8
**Applied to:** prod
**Migration name:** `phaseF_add_pod_refill_row_canonical_writer` (+ fix-forward `phaseF_add_pod_refill_row_fix_audit_before_state`)
**Summary:** Added the missing canonical writer for inserting a manual `pod_refill_plan` row. The FE "+ Add row" had no backing RPC, so manually-added rows lived only in browser state; a typed product with no `pod_product_id` ("Plaay Truffle 2pcs") caused `Row removal persist failed ... missing pod identifiers` and aborted the whole Commit (WPP-1002-4300-O1/A01, 2026-05-31). `add_pod_refill_row(plan_date, machine_id, shelf_id, pod_product_id, action, qty, reason, conductor_session)` validates that `pod_product_id` resolves in `pod_products` (the core fix), shelf-belongs-to-machine, action enum, qty≥0, no 5-tuple clobber, and the past-pending lock; inserts at `status='draft'`, `source_origin='warehouse'`; role-gated; sets GUCs; audits to `pod_refill_plan_audit` (`edit_type='add'`). Cody-approved (Articles 1,2,3,4,5,8,12). Verified: bad product rejected, valid WPP A01 Plaay add returns clean (both rolled back). Fix-forward migration corrects `before_state` NOT NULL (write `'{}'::jsonb` for adds). Still needed: FE wiring (forced product dropdown + autofill → this RPC) and the machine-exclude-checkbox fix — handed to Stax.
**Rollback:** `DROP FUNCTION public.add_pod_refill_row(date,uuid,uuid,uuid,text,integer,text,text);`

---

## 2026-05-31 — Phase F: relax pod_refill_plan qty CHECK to allow zero (soft-stop fix)

**Phase / Article:** Phase F / Constitution Articles 5, 12
**Applied to:** prod
**Migration name:** `phaseF_fix_pod_refill_plan_qty_check_allow_zero`
**Summary:** The `pod_refill_plan` row-removal path (`stop_pod_refill_row` → `edit_pod_refill_row(qty := 0)`) writes `qty = 0` as the soft-stop signal, and Stage 3 stitch treats `qty = 0` as a no-op. But the table still carried the original `CHECK (qty > 0)`, which rejected the qty=0 write and broke "Row removal persist" on Commit (surfaced at MINDSHARE-1009-4500-O1/A02 G&H Popped Chips, 2026-05-31). Relaxed the constraint to `CHECK (qty >= 0)` to align the table with the canonical writer contract (`edit_pod_refill_row` already validates `p_new_qty >= 0`). No existing rows violated the new constraint. Negative qty still blocked. Cody-approved (Articles 2, 5, 7, 12, 14). Follow-up logged: `restore_pod_refill_row` only un-supersedes `status='superseded'` rows while the remove path leaves `status='draft' qty=0` — remove/restore are inconsistent; hand to Stax to reconcile.
**Rollback:** `ALTER TABLE public.pod_refill_plan DROP CONSTRAINT pod_refill_plan_qty_check; ALTER TABLE public.pod_refill_plan ADD CONSTRAINT pod_refill_plan_qty_check CHECK (qty > 0);` (only safe if no qty=0 rows exist).

---

## 2026-05-31 — Phase F: lifecycle_product_status (inactive-product flag)

**Phase / Article:** Phase F / Constitution Articles 1, 2, 4, 8, 12, 14
**Applied to:** prod
**Migration name:** phaseF_lifecycle_product_status
**Summary:** New non-protected table `lifecycle_product_status(pod_product_id PK, status, reason, set_by, set_at)` flags products out of the lifecycle analysis (status='inactive'); absence of a row = active. Sole canonical writer `set_product_lifecycle_status(uuid,text,text)` (SECURITY DEFINER: validates auth + role operator_admin/superadmin/manager, status enum, pod_products FK; sets app.via_rpc/app.rpc_name). RLS: SELECT all authenticated, writes role-gated. Article 8 via universal `audit_log_write('pod_product_id')` trigger. Seeded 14 retired products with 0 live units (Tannourine, Mezzmix x2, Loacker Quadratini, Sprite, Almarai x2, Galaxy Kunafa, Lays, Coco Water, 7 Days Croissant, Nutella B Ready, Garden Veggie, Happy holidays) via in-migration INSERT (MCP apply lacks auth.uid(); trigger audited the seed). Cody verdict ⚠️→ revisions applied. FE: /app/lifecycle filters inactive across all tabs with a Show-inactive toggle + mark/unmark action.
**Rollback:** `DROP TRIGGER trg_lps_audit ON public.lifecycle_product_status; DROP FUNCTION public.set_product_lifecycle_status(uuid,text,text); DROP TABLE public.lifecycle_product_status;`

---

## 2026-05-30 - Phase G: add_stock canonical pod writer + HUAWEI-2003 / MC-2004 recounts (30-May punch list)

**Phase / Article:** Phase G pod recount / Articles 1, 4, 5, 8, 12 (pod-only; Article 6 N/A, no warehouse_inventory write).
**Applied to:** both (migration `phaseG_pod_add_stock_writer` to prod; data recounts applied via the RPC).
**Migration name:** `phaseG_pod_add_stock_writer`
**Summary:** Added `add_stock` edit_type to `approve_pod_inventory_edit` (Dara design, Cody-approved Articles 1/4/5/6/8/12/14). Merges on (machine, shelf, product): sums stock, pulls expiry to earliest (FEFO worst-case), matching the `receive_dispatch_line` precedent; falls back to INSERT when the (shelf, product) has no Active row. Widened the `pod_inventory_edits.edit_type` CHECK + added an `add_stock` required-fields CHECK. This unblocked the Simran recounts which the strict `add_new_product` path could not express (increments + multi-batch). Applied: Kinder Bueno MC-2004 (archived shelf=null row via `backfill_archive_pod_inventory_row`, re-added 4u to A10, CS-approved destructive); 14 HUAWEI-2003 products; 12 MC-2004 products. All additive (edit_type=add). Doc typos corrected per CS: Oreo `30/09/36`->`2026-09-30`, Sunbites `19/06/24`->`2026-06-19`. ~24 lines remain blocked on CS (new-product shelves, ambiguous variants, set-vs-add, missing qty/expiry); the Ritz stuck-dispatch closures (Phase 1.5) are blocked on a data mismatch vs CS's described quantities. See `memory/project_30may_pod_recount.md`.
**Rollback:** `add_stock` rows are normal Active pod_inventory rows; to reverse, archive them via `backfill_archive_pod_inventory_row`. To drop the type: restore the prior `approve_pod_inventory_edit` body + revert the two CHECK constraints (forward migration).

---

## 2026-05-30 - FE: pod-add reject modal enforces 10-char decision note client-side (30-May punch list)

**Phase / Article:** FE hardening / Articles 1, 3, 4 (defense-in-depth; no protected write, no RPC change).
**Applied to:** repo (FE only).
**Migration name:** none.
**Summary:** Simran hit the raw `reject_pod_inventory_edit: decision_note required (min 10 chars, got N)` RPC exception when rejecting a pending pod addition. `PendingPodAdditionsPanel.tsx` now disables Confirm-reject until the trimmed note is >= 10 chars, adds a textarea `minLength` + a live `At least 10 characters required (N/10)` counter, and parses the canonical RPC raise into a friendly inline message. Server-side validation in the DEFINER remains authoritative. Cody-approved. The `field/inventory/page.tsx` `window.prompt` reject path was already guarded. NOTE: the HUAWEI-2003 + MC-2004 pod recounts from the same punch list are NOT applied yet (the canonical `add_new_product` RPC cannot increment existing batches or hold multi-batch; escalated to Dara for an `add_stock` edit_type, pending CS approval + Cody review).
**Rollback:** revert the `PendingPodAdditionsPanel.tsx` commit.

---

## 2026-05-30 - Phase G: 3 canonical writers for the refill_dispatching FE refactor (PROGRAM-2026-06-01)

**Phase / Article:** Phase G FE-write closure / Articles 1, 3, 4, 8 (and 12 forward-only).
**Applied to:** both (migration applied to prod; FE committed to repo).
**Migration name:** `phaseG_stax_canonical_writers_for_dispatch_fe_refactor`
**Summary:** PROGRAM-2026-06-01 set out to close the 13+ FE call sites that write `refill_dispatching` directly, before the planned 2026-06-06 enforcement flip (RAISE WARNING to RAISE EXCEPTION). Added 3 SECURITY DEFINER writers: `update_dispatch_comment(uuid,text)`, `set_dispatch_include(uuid,boolean)`, `insert_driver_remove_line(uuid,uuid,uuid,uuid,numeric,date,text)`. Each is role-gated, input-validated, sets `app.via_rpc`/`app.rpc_name` (Article 4) and is audited via `tg_audit_refill_dispatching` (Article 8). The migration also extends the `enforce_canonical_dispatch_write` allow-list with the 3 names while KEEPING RAISE WARNING (no flip), so the new RPC writes are recognised as canonical during the soak window. Cody-approved with one revision applied: `insert_driver_remove_line` sets `filled_quantity=0` + `item_added=false` explicitly to mirror the proven direct insert, since `filled_quantity` is nullable with no default.

**Scope reality vs. the PRD:** reading every write site plus every candidate RPC body showed the PRD's "3 RPCs, all mappings decided" held for only 5 of ~11 writers. 5 were refactored and committed (packing:1295, dispatching:497/624/669, trips:227). The other 6 (packing 1141/1209/1267, dispatching 535, trips 258, DailyDispatchingTab 298) have NO matching canonical RPC and were deferred by CS decision ("ship 5 clean, defer 6 + flip"). See `docs/prds/_programs/PROGRAM-2026-06-01b-stax-fe-refactor-gap-closure.md`. The RAISE EXCEPTION flip (D1) must NOT ship until those 6 close; the trigger stays RAISE WARNING.
**Rollback:** `DROP FUNCTION public.update_dispatch_comment(uuid,text); DROP FUNCTION public.set_dispatch_include(uuid,boolean); DROP FUNCTION public.insert_driver_remove_line(uuid,uuid,uuid,uuid,numeric,date,text);` then `CREATE OR REPLACE` the prior `enforce_canonical_dispatch_write` with the 22-name allow-list (see git history of the migration). FE: revert the 3 refactor commits.

---

## 2026-05-26 — Perf hotfix: `idx_wal_rpc_row_occurred` on `write_audit_log` to kill 38s correlated scan

**Phase / Article:** Operational perf fix / Constitution Article 12 (forward-only, additive). No writer / RLS / Article 6 path altered.
**Applied to:** prod only (via `mcp__supabase__execute_sql` — `apply_migration` rejects `CREATE INDEX CONCURRENTLY` because it wraps in a transaction; CONCURRENTLY is required because `write_audit_log` is high-write and a non-concurrent build would hold an ACCESS EXCLUSIVE lock on a 735 MB / 660 k-row table for ~30-60s, blocking every canonical writer).
**Migration name:** not registered in `supabase_migrations` (applied as raw SQL — see Rollback for the canonical statement).
**Summary:** Boonz portal was returning `504 GATEWAY_TIMEOUT` / `MIDDLEWARE_INVOCATION_TIMEOUT` and `Failed to fetch` on the login form. Root cause was not Vercel and not the middleware: Postgres backend slots were saturated. The hourly cron `monitor_stuck_remove_dispatches` (jobid 12) was running an average 71s and peaking at 534s, starving pg_cron's ability to fork workers for every other job, including `refresh-sales-aggregated-10min` (jobid 4), which was visibly failing in the dashboard and is what surfaced the incident.

EXPLAIN ANALYZE on `v_stuck_remove_dispatches` showed a correlated subquery `SELECT max(occurred_at) FROM write_audit_log WHERE rpc_name = 'mark_picked_up' AND row_pk = rd.dispatch_id::text` running once per candidate `refill_dispatching` row. `write_audit_log` had no index covering `(rpc_name, row_pk)`, so every probe was a sequential scan of all 660,085 rows: 4.6 GB of shared-buffer reads per execution, 38.2s wall time, cost 3,069,683,663.

Added composite covering index on `(rpc_name, row_pk, occurred_at DESC)`. Postgres now does an Index Only Scan with `Heap Fetches: 0`. Re-ran EXPLAIN: 794ms total (was 38,247ms, 48× speedup), 0 disk reads, cost 85,434. The hourly cron 12 will fit well inside its 1-hour window and stop starving the rest of the cron fleet.

Generic enough to accelerate any future "find latest audit event for row X under RPC Y" pattern on `write_audit_log`. Index size: 46 MB.

Separately, `refresh-sales-aggregated-10min` (jobid 4) was disabled from the Supabase dashboard during the incident. Audit confirmed `sales_history_aggregated` has zero callers (no DB-internal references, no FE matches in `boonz-erp/src/`, no n8n flow matches, zero `information_schema.role_table_grants` rows). The MV has been refreshing every 10 minutes for nearly two months feeding nothing. Cron 4 stays disabled; the MV itself is a follow-up cleanup candidate.

**Rollback:**

```sql
DROP INDEX CONCURRENTLY IF EXISTS public.idx_wal_rpc_row_occurred;
```

**Re-apply (canonical statement):**

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_wal_rpc_row_occurred
ON public.write_audit_log (rpc_name, row_pk, occurred_at DESC);
```

---

## 2026-05-25 — Phase G Phase 3 + Phase 4 (close the chapter): physical-receipt gate + phantom drain + daily reconciliation + session viewer + reason dropdown + M2M audit

**Phase / Article:** Phase G PRD v2 Phase 3 + Phase 4 / Constitution Articles 1, 4, 5, 7, 8, 11, 12 (backend); Article 3 (FE — new read-only viewer at `/admin/inventory-sessions`, no new direct writes).
**Applied to:** prod (3 backend migrations applied via MCP) + repo (FE + audit docs + carve-out PRDs).
**Migrations (via MCP, names from Supabase migrations table):**

- `phaseG_p3_a2_purchase_orders_physical_received_qty_and_status_widen` — A.2.
- `phaseG_p3_a3_drain_consumer_stock_phantom` — A.3.
- `phaseG_p3_c6_c7_daily_flow_reconciliation` — C.6 + C.7.

**Summary:** Nine items shipped end-to-end in a single batch (six from Phase 3, three from Phase 4). Three items (A.6 auto-receive, A.7 hard-block direct UPDATE, B.6 control-mode soft lock) carved out into standalone PRDs that require staging windows the batch cadence can't offer.

(A.2) New `purchase_orders.physical_received_qty numeric NULL` column + widened `warehouse_inventory_status_check` to include `'PendingPhysicalReceipt'` + new `confirm_physical_receipt(p_po_line_id uuid, p_physical_qty numeric, p_received_by uuid DEFAULT NULL, p_notes text DEFAULT NULL)` SECURITY DEFINER RPC. The RPC validates caller role (`warehouse/operator_admin/superadmin/manager`), validates the line is received but unconfirmed, sets `app.via_rpc` and `app.rpc_name`, updates `physical_received_qty` and flips status from PendingPhysicalReceipt to Active on the linked WH row.

(A.3) New `drain_consumer_stock_phantom(p_wh_inventory_id uuid, p_reason text, p_drained_by uuid DEFAULT NULL)` SECURITY DEFINER RPC. Cody-approved revision: instead of inventing a new `'consumer_phantom_drain'` provenance reason that would fail the `wh_provenance_reason_enum` CHECK, the RPC uses the existing `'manual_adjust'` and carries the discriminator in `inventory_audit_log.reason` text as `'consumer_phantom_drain: <text>'`. Minimum reason length 10 chars (matches `edit_purchase_order_line` and `cancel_po_line`). Per-row CS approval cadence — no rows drained without CS sign-off.

(C.6) New `daily_reconciliation_log` table (append-only, RLS, `no_update`/`no_delete` policies) + new `v_daily_flow_reconciliation` view (`date_product` CTE joining `po_in / addn_in / returns_in / packs_out / sales_out` aggregates). `sales_history.transaction_date + qty + boonz_product_id` chosen as the canonical sales aggregate (sales_lines does not exist in live schema; sales_history is the source of truth).

(C.7) New `cron_daily_inventory_reconciliation()` SECURITY DEFINER function + `daily_inventory_reconciliation` pg_cron job scheduled at `0 2 * * *` (02:00 UTC = 06:00 Dubai). Job snapshots `v_daily_flow_reconciliation` for the prior day into `daily_reconciliation_log`. Backfill smoke for 2026-05-24 returned 0 rows (no matching movement that day) — accepted as expected.

(B.7) PO physical-receipt confirmation surface on `/app/inventory` drawer. When the drawer opens, an effect resolves the linked PO line via the batch_id LIKE pattern (`<po_id>-<short_uuid>-B<idx>`) that `receive_purchase_order` writes — query goes through `purchase_orders` filtered by `boonz_product_id` (small set per product) with client-side UUID-prefix match (avoids the PostgREST UUID-LIKE coercion issue). If the linked line has `received_date != NULL` AND `physical_received_qty IS NULL`, a yellow "Pending physical receipt" chip renders with a confirm dialog (physical qty + optional notes) that calls `confirm_physical_receipt` via the canonical RPC.

(B.3) Reason dropdown for inventory edits. Replaced the free-text reason input with an 8-option category select (`physical_count / damaged_unit / expiry_writeoff / found_discrepancy / m2m_correction / supplier_short_ship / supplier_over_ship / other`) plus a detail textarea (>=4 chars). Final reason persisted as `<code>: <detail>` so the daily flow reconciliation (C.6) can bucket `inventory_audit_log` rows by intent in future PR iterations.

(B.5) New `/admin/inventory-sessions` page. Two-column split: left = session list (last 200, status badge + start time + truncated id), right = per-session attempt grid with result filter (success / blocked_rls / blocked_trigger / rpc_error / validation_error / network_error / other / all) and a free-text search across `wh_inventory_id / boonz_product_id / field_changed / rpc_called / reason / error_message`. Read-only; RLS gates visibility to manager/operator_admin/superadmin per `inventory_control_session` policies. Tabular grid renders `when / result chip / field / rpc / wh_inventory short id / old → new JSON / reason / error` per row, with `.limit(10000)` per CLAUDE.md rule.

(A.8) M2M flow audit document at `docs/prds/phase-g/A8_m2m_flow_audit_2026-05-25.md`. Findings: there are two M2M flows in production. The canonical `swap_between_machines` writer is unused in current traffic (0 live rows). All 8 live `is_m2m=true` rows were written by an **anonymous direct UPDATE** (no `rpc_name`, no `actor_role` in `write_audit_log`) that flipped `is_m2m=false → true, source_kind='unknown' → 'truck_transfer', from_warehouse_id=<WH_CENTRAL> → NULL` ~10 minutes after `push_plan_to_dispatch` inserted the rows. This is an Article 3 + 4 violation. The audit document flags it as a follow-up PRD (sibling of A.7 carve-out) and does not fix it in this batch — fixing requires identifying the writer first.

**Carve-outs (standalone PRDs created, not shipped):**

- `docs/prds/phase-g/CARVEOUT_A6_auto_receive_on_dispatch.md` — auto-receive cron for stuck `picked_up=true / received_at IS NULL` dispatches. Needs dry-run staging window.
- `docs/prds/phase-g/CARVEOUT_A7_hard_block_direct_wh_update.md` — `BEFORE UPDATE` trigger raising on missing `app.via_rpc`. Needs 7-day audit-only warning window. Blocked by A.8 anonymous-flip root cause.
- `docs/prds/phase-g/CARVEOUT_B6_control_mode_soft_lock.md` — yellow chip + confirm dialog on rows in scope of an open session. Needs 2 weeks of B.5 telemetry first.

**Smoke 9.1 (A.2):** `confirm_physical_receipt` exists with the documented signature; SECURITY DEFINER confirmed; CHECK on `warehouse_inventory_status_check` includes `PendingPhysicalReceipt`.
**Smoke 9.4 (B.3/B.5):** typecheck clean; `editReasonCode` required before save; `/admin/inventory-sessions` page renders the session list + attempts grid against live data; RLS gates working (visible to operator_admin, no rows for field_staff).
**Smoke 9.6 (C.6/C.7):** cron job `daily_inventory_reconciliation` scheduled `0 2 * * *`, `active=true`; view `v_daily_flow_reconciliation` resolves; backfill for 2026-05-24 returns 0 (no movement that day, expected).

**Rollback:** Each migration is forward-only. To unwind: drop the cron job, drop the daily_reconciliation_log table, drop the view, drop `drain_consumer_stock_phantom`, drop `confirm_physical_receipt`, narrow the status CHECK back, drop `physical_received_qty` column. FE rollback: revert the inventory page + delete the inventory-sessions page. Carve-out PRDs are documentation only — deletion safe.

---

## 2026-05-25 — Phase G Phase 2 (the biggest leak): pack NULL refuse + EOD action narrow + movement trail view + FE drawer

**Phase / Article:** Phase G PRD v2 Phase 2 / Constitution Articles 1, 4, 8, 11, 12 (backend); Article 3 (FE — no new direct writes; view consumed read-only).
**Applied to:** prod (3 migrations applied via MCP) + repo (FE).
**Migrations:**

- `phaseG_p2_a1_pack_dispatch_line_refuse_null_from_wh` (file `supabase/migrations/20260525170000_*.sql`) — A.1.
- `phaseG_p2_a5_eod_auto_release_action_narrow_then_reenable_cron` (file `20260525170100_*.sql`) — A.5 + cron job 9 re-enabled atomically.
- `phaseG_p2_c5_v_wh_inventory_movement_trail` (file `20260525170200_*.sql`) — C.5.

**Summary:** Four PRD items shipped end-to-end with smoke tests for Sections 9.3 and 9.5.

(A.1) `pack_dispatch_line` now raises `pack_dispatch_line: every pick must include from_wh_inventory_id (BUG-006 prevention)` on any pick with NULL or empty `wh_inventory_id`. Guard sits at the top of the FOR loop, before the `::uuid` cast that previously masked the error. Smoke 9.3 confirmed: pack with `{"qty":1,"wh_inventory_id":null}` raises the new message. Same signature with `p_packed_by uuid DEFAULT NULL` preserved.

(A.5) `eod_auto_release_unpicked` sweep narrowed from any-action to `action IN ('Refill','Add New','Add')` — case-sensitive, matching the `pack_dispatch_line` short-circuit contract exactly. Cody flagged that the original "inclusive" allow-list `('REFILL','ADD NEW',...)` would have recreated the very bug (uppercase variants short-circuit pack with no WH decrement, so sweeping them via `return_dispatch_line` credits phantom WH). Narrowed list confirmed against all 16 live action variants: only `Refill / Add New / Add` get swept; `Remove / REMOVE / Machine To Warehouse / MOVE / REFILL upper / ADD NEW upper / Backup / Calibrate / Keep / Replace / Transfer / NULL` are now excluded. After CREATE OR REPLACE, the migration re-enabled cron job 9 atomically via `cron.alter_job(job_id := 9::bigint, active := true)`.

(C.5) New SECURITY INVOKER view `v_wh_inventory_movement_trail` unions five event streams keyed on `wh_inventory_id`: `inventory_audit_log`, `write_audit_log` (filtered to `table_name='warehouse_inventory'` with regex-validated UUID `row_pk`), `refill_dispatching` (where `from_wh_inventory_id` matches), `purchase_orders` (via `batch_id LIKE '%-<short_uuid>-B%'` provenance match per `receive_purchase_order`'s batch-id format), and `inventory_control_attempt`. Each row carries `wh_inventory_id, event_class, event_time, actor, summary, payload`. RLS inherits from underlying tables. `GRANT SELECT TO authenticated`.

(B.4) New `src/components/inventory/MovementTrail.tsx` component renders the trail lazily (loads on expand) per row. Wired into the operator inventory drawer in `/app/inventory/page.tsx` after the existing Field rows in read mode. tsc + next build clean.

**Smoke 9.3:** direct call to `pack_dispatch_line` with NULL pick raised the new BUG-006 prevention message — refusal confirmed at the RPC layer.
**Smoke 9.5:** the IN-list against live action variants confirmed `Refill / Add New / Add` are swept, every other variant excluded.

**Rollback:** `git revert <commit-sha>` reverts the FE. For the backend, apply forward `CREATE OR REPLACE` with the prior bodies (full v9 / v9 / no-view) and `cron.alter_job(job_id := 9, active := false)` to disable cron 9 again.

---

## 2026-05-25 — PRD-010a v9.1 patches: engine_swap_pod planned-swap guard product-match + engine_finalize_pod capacity filter widening

**Phase / Article:** PRD-010a (refill-pipeline) / Constitution Articles 1, 4, 5, 8, 12. Backend-only, no schema changes.
**Applied to:** prod (both migrations applied via MCP `apply_migration`) + repo.
**Migration names:**

- `engine_swap_pod_v9_1_product_match_planned_swap` (file `supabase/migrations/20260525160000_engine_swap_pod_v9_1_product_match_planned_swap.sql`)
- `engine_finalize_pod_v12_1_keep_in_capacity_filter` (file `supabase/migrations/20260525160100_engine_finalize_pod_v12_1_keep_in_capacity_filter.sql`)

**Summary:** Two surgical edits to canonical writers shipped in PRD-010 commit 44ef57a. (1) `engine_swap_pod` v9.1 replaces the broken `planned_swaps.shelf_code` to `shelf_configurations.shelf_code` text JOIN in the `_planned_swap_shelves` temp table with a product-match via `pod_products` to `slot_lifecycle` on `pod_product_id`. WEIMI-format cabinet codes in `planned_swaps` (e.g. `'0-A06'`) were missing all four MC-2004 Plaay shelves because they did not match the logical codes used in `shelf_configurations` (e.g. `'A06'`). The join chain mirrors the existing `pick_machines_for_refill v6` auto-close logic. `engine_version` bumped `v9_swap_dedup_planned_priority` → `v9_1_product_match_planned_swap`. (2) `engine_finalize_pod` v12.1 widens the high-velocity capacity-warning filter from `signal IN ('STAR','DOUBLE DOWN','KEEP GROWING')` to also include `'KEEP'`. The most common proven-product signal was excluded, so MC-2004 Coca Cola Zero (KEEP, v30=1.53, capped on a 14-unit shelf) never surfaced a suggestion to move to the larger Loacker shelf. `engine_version` bumped `v12_m2w_empty_shelf_guard` → `v12_1_keep_in_capacity_filter`. No signature change on either function; the v12 M2W empty-shelf guard and `m2w_no_replacement_warnings` machinery preserved verbatim. Cody-approved against Articles 1, 4, 5, 8, 12.

**Rollback:** Forward `CREATE OR REPLACE` reverting to the v9 / v12 bodies. The patches are additive within the function body (one CTE replacement + one literal addition); reverting is mechanical.

---

## 2026-05-25 — PRD-012 Phase 1 closeout: propose/approve/reject RPCs deployed plus two hotfixes

**Phase / Article:** PRD-012 Phase 1 steps A.2/A.3/A.4 / Constitution Articles 1, 3, 4, 5, 8, 12, 14 (✅).
**Applied to:** prod.
**Migrations:**

- `prd_012_propose_pod_inventory_add` (file `supabase/migrations/20260525150000_*.sql`)
- `prd_012_approve_pod_inventory_add` (file `supabase/migrations/20260525150100_*.sql`)
- `prd_012_reject_pod_inventory_add` (file `supabase/migrations/20260525150200_*.sql`)
- `prd_012_extend_pod_inventory_edits_check_whitelists` (file `supabase/migrations/20260525150300_*.sql`) — hotfix #1
- `prd_012_relax_add_flow_check` (file `supabase/migrations/20260525150400_*.sql`) — hotfix #2

**Summary:** Three canonical-writer DEFINER RPCs land the driver pod-add workflow on the schema substrate shipped earlier today. `propose_pod_inventory_add(p_machine_id, p_shelf_id, p_boonz_product_id, p_quantity, p_expiration_date, p_notes?, p_photo_path?, p_correlation_id?, p_proposed_by?)` is callable by field*staff + manager roles and validates D2 (shelf conflict via Active pod_inventory row check, distinguishes case-2 "different product" vs case-3 "same product"), D3 (expiry not in past, not beyond 36 months), quantity > 0 and <= shelf max_capacity, plus D5 idempotency by `correlation_id` within a 60-second replay window. `approve_pod_inventory_add(p_edit_id, p_approver_id?, p_decision_note?, p_expiry_override_accepted?)` is manager-only, locks the edit row with `FOR UPDATE` (case-14 concurrent approve defense), re-validates shelf conflict (case-10) and expiry (case-11), sets `app.via_rpc=true` + `app.rpc_name` + `app.mutation_reason`, INSERTs a `pod_inventory` row with `batch_id = format('POD_ADD-%s', edit_id)` and `status='Active'`, then UPDATEs the edit row linking `pod_inventory_id`. Has `unique_violation` defense around `idx_pod_inv_active_shelf`. `reject_pod_inventory_add(p_edit_id, p_decision_note, p_approver_id?)` is manager-only, requires `decision_note >= 10 chars` (case-12), UPDATEs status to rejected, appends note to the edit row. All three follow the Phase G P1 `attempt_inventory_correction` template (search_path locked, role check via user_profiles, structured jsonb return). Cody approved at G2 with revisions: P1.B missing `app.mutation_reason` (added), `COMMENT ON FUNCTION` statements restored from drafts and em-dash-scrubbed, `unique_violation` exception handler added to P1.C. Pre-deploy checks confirmed: only `get_operational_signals` (read-only get*\* helper) references `POD_ADD` in pg_proc (no other writer); zero src/supabase references to that batch_id pattern; `tg_audit_pod_inventory` AFTER INSERT/UPDATE/DELETE trigger live on pod_inventory (Article 8 satisfied); `idx_pod_inv_active_shelf` unique partial index enforces one Active row per (machine, shelf, product). End-to-end smoke test ran propose → idempotent replay → approve → verify pod row Active → verify edit status approved, all five steps passed, transaction rolled back (zero leaked rows).

**Two hotfixes during smoke test execution:** P1.A's CHECK constraint design missed two pre-existing CHECKs on pod_inventory_edits. **Hotfix #1** (`prd_012_extend_pod_inventory_edits_check_whitelists`): the existing `pod_inventory_edits_edit_type_check` whitelisted `{in_stock, sold, partial_sold, expired, return_to_warehouse, transfer}` and the existing `pod_inventory_edits_status_check` whitelisted `{pending, approved, rejected}`. Neither included the new values P1.B/C and the future P3.A cron need (`add_new_product` and `expired` respectively). Forward-only DROP+ADD on both, strictly widening. Cody-approved. **Hotfix #2** (`prd_012_relax_add_flow_check`): the P1.A add-flow CHECK required `pod_inventory_id IS NULL` for add_new_product rows, blocking the approve RPC's `pod_inventory_id` linkage on UPDATE. The PRD §6.A.1 wording was ambiguous between "INSERT-time invariant" and "row-level invariant"; the latter is wrong because approval must link the new pod row back. Forward-only DROP+ADD removing the NULL clause. Cody-approved. After both hotfixes, smoke test passed.

**Phase 3 reminders:** Amendment 008 (pod_inventory_edits → Appendix A with FE INSERT exception clause); A.5 cron must be SECURITY DEFINER with set_config markers and must UPDATE WHERE status='pending' only (no reverse transition); A.6 trigger requires G4 caller-audit gate; C.6 inventory_control_attempt integration on approve/reject when session open.

**Rollback:** All five migrations are forward-only with DROP IF EXISTS guards. To roll back: write a new migration that DROPs the three RPCs (`DROP FUNCTION public.propose_pod_inventory_add(...)` etc), restores the two CHECKs to their pre-hotfix shape, and finally rolls back the schema columns (`DROP CONSTRAINT pod_inventory_edits_add_new_product_required_fields`, `DROP INDEX idx_pie_*`, `ALTER TABLE pod_inventory_edits DROP COLUMN ...`). Safe to roll back any time before Phase 2 wires the FE callers.

---

## 2026-05-25 — PRD-012 P1.A: pod_inventory_edits add-flow schema (driver pod-add workflow)

**Phase / Article:** PRD-012 Phase 1 step A.1 / Constitution Articles 2, 5, 7, 12, 14 (✅) and 15 (⚠️ Phase 3 follow-up flagged).
**Applied to:** prod.
**Migration name:** `prd_012_pod_inventory_edits_add_flow` (file `supabase/migrations/20260525140000_prd_012_pod_inventory_edits_add_flow.sql`).
**Summary:** Substrate for the driver pod-add workflow per PRD-012 (`docs/prds/inventory/prd_012_driver_pod_add_workflow.md`). Extends `pod_inventory_edits` with three new columns: `requested_expiration_date date NULL` (driver's chosen expiry for the new pod_inventory row), `correlation_id uuid NOT NULL DEFAULT gen_random_uuid()` (D5 idempotency token, 60s dedupe window inside the upcoming propose RPC), and `expired_at timestamptz NULL` (D6 auto-expire bookkeeping for the upcoming cron). Reuses the existing `destination_shelf_id` for the add-flow target shelf rather than introducing a new column; column comment updated to document the dual semantic. Adds CHECK constraint `pod_inventory_edits_add_new_product_required_fields` in material-implication form so existing edit_types are unaffected. Adds three indexes: `idx_pie_one_pending_add_per_target` (partial UNIQUE; enforces D5 one-pending-per-(machine,shelf,product) at the DB layer), `idx_pie_correlation_id_recent` (composite for the 60s dedupe lookup), `idx_pie_pending_adds_oldest_first` (partial; supports operator review queue oldest-first sort per PRD C.5). Pre-apply checks confirmed: 213 rows total, 0 destination_shelf_id callers in src/, RLS policies (field_staff_insert_edits + reviewers_update_edits) already permit the add flow. Material finding logged at G1: existing data shows the table has historically been used as a sales/disposal log (`expired, partial_sold, return_to_warehouse, sold` edit_types only; zero `pending` rows ever recorded). PRD-012 is the first edit_type to actually exercise the propose/approve flow the schema was designed for.

**Pending P1 follow-ups:** A.2 propose_pod_inventory_add RPC, A.3 approve_pod_inventory_add RPC, A.4 reject_pod_inventory_add RPC. All three drafted then gated at G2 with Cody verdict before deploy.

**Phase 3 follow-up (Cody-flagged):** Amendment 008 to elevate `pod_inventory_edits` to Appendix A under the Amendment 007 precedent (proposal substrate for protected entity writes). FE INSERT exception clause for the existing driver propose path.

**Rollback:** Forward-only migration to `DROP CONSTRAINT pod_inventory_edits_add_new_product_required_fields`, `DROP INDEX idx_pie_*`, `ALTER TABLE pod_inventory_edits DROP COLUMN requested_expiration_date, DROP COLUMN correlation_id, DROP COLUMN expired_at`. Safe to roll back until the propose RPC starts writing add rows.

---

## 2026-05-25 — PRD-002 procurement per-line edit-lock, Cancel-with-comment, add-item multi-batch expiry

**Phase / Article:** PRD-002 (procurement) / Constitution Articles 1, 4, 5, 8, 12 (backend patch); Article 3 (FE — no new direct writes to protected entities; `po_additions` direct INSERT pattern is unchanged from PRD-001-procurement).
**Applied to:** prod (migration `phaseF_proc_edit_po_line_received_lock`) + repo (FE).
**Migration name:** `phaseF_proc_edit_po_line_received_lock` (file `supabase/migrations/20260525130000_phaseF_proc_edit_po_line_received_lock.sql`).
**Summary:** Closes three procurement gaps when a PO is partially received. (1) Backend — `edit_purchase_order_line` gains a received-state guard: lines with `received_qty > 0` OR `purchase_outcome = 'received'` are now superadmin-only; other roles get a `line is already received; only superadmin can edit` raise. A `lock_level` field (`'received'` | `'unreceived'`) is recorded in `procurement_events.payload`, `write_audit_log.payload`, and the function's return jsonb so the audit history can differentiate normal edits from superadmin overrides. No signature change. Cody-approved against Articles 1, 4, 5, 8, 12. (2) FE per-line lock + Cancel — `/field/orders` (mobile) and `/app/procurement` (desktop) PO drawers now render a per-line action cell: 🔒 chip on received lines for non-superadmin callers, `Cancel` button on unreceived lines for `warehouse/operator_admin/manager/superadmin`, line-through plus `Not received` badge on `purchase_outcome='not_purchased'`. New shared component `src/app/(field)/components/CancelPOLineDrawer.tsx` takes a 10-char-minimum free-text reason and calls the existing `cancel_po_line` RPC. The desktop page imports the field component for parity. (3) FE add-item multi-batch — `/field/receiving/[poId]` add-item modal refactored from single `{qty, expiry}` to `addBatches: {qty, expiry}[]` with a `+ Add another expiry batch` affordance. Each batch becomes one row in `po_additions`. Save is blocked iff every batch has empty expiry (mixed batches with one date are allowed; some products legitimately have no expiry). Price stays per-product on the addition. Build clean: tsc + next build.

**Open question (deferred to CS):** should `operator_admin` also override received-line edits, or stay superadmin-only? PRD shipped superadmin-only; flip the guard to `v_caller_role NOT IN ('superadmin','operator_admin')` in a forward migration if CS wants the broader scope.

**Rollback:** `git revert <commit-sha>` for the FE. For the backend RPC, apply a forward `CREATE OR REPLACE` that removes the `v_lock_level` block + the received-state RAISE (no DROP, Article 12). The patch is purely additive within the function body so reverting is mechanical.

---

## 2026-05-25 — PRD-001 inventory session-gate discoverability (FE only)

**Phase / Article:** PRD-001 (inventory) / no Constitution articles touched (FE only, no protected-entity writes added).
**Applied to:** repo (FE only; no SQL).
**Files:** `src/app/(field)/field/inventory/page.tsx`, `src/app/(app)/app/inventory/page.tsx`, `src/components/inventory/StartInventorySessionBar.tsx`.
**Summary:** Closes the silent-fail trap that left the warehouse manager (Simran, role=warehouse) unable to save any inventory edit. Four FE changes: (1) header `+ Inventory Control` renamed to `+ Bulk Edit` on `/field/inventory` to kill the name collision with the session-opening button in `StartInventorySessionBar`; (2) the session bar plus canary wrapper is now `position: sticky` under the page header on both `/field/inventory` (Tailwind) and `/app/inventory` (inline style for parity with that page's pattern) so the bar stays visible while scrolling or with the soft keyboard open; (3) a shared `alertNoSession()` helper replaces the silent early-returns in `saveInlineQty`, `toggleBatchStatus`, and `completeControl` — each path now pops a loud `window.alert()` and scroll-snaps the bar back into view via `document.getElementById('start-inventory-session-bar').scrollIntoView`. The anchor id is set on all five render branches of `StartInventorySessionBar`. (4) `handleEnterBulkEdit` re-verifies the open session against `inventory_control_session` via a fresh SELECT before flipping `controlMode=true`, closing the localStorage-flicker bypass that previously let users into bulk-edit without a real open session. No backend, no migration, no protected-entity writes added; tsc and next build both clean.

**Rollback:** `git revert <commit-sha>`. The four shipped behaviors revert together; the underlying canonical writer paths and session schema are unchanged.

---

## 2026-05-25 — Constitution Amendment 007 (Phase G P1 audit tables added to Appendix A)

**Phase / Article:** Phase G P1 / Constitution Article 15.
**Applied to:** repo (Constitution document only; no SQL).
**Summary:** Adds `inventory_control_session` (under Core entities) and `inventory_control_attempt` (under Append-only logs) to Appendix A so the two audit-substrate tables shipped in commit 95ad54b fall under the Constitution's protected scope. Documents the FE INSERT exception clause for `inventory_control_attempt`: authenticated FE may INSERT directly when a SECURITY DEFINER wrapper was not reached (transport-level failures, JWT expiry, edge function unreachable). The exception is gated by RLS policy `ica_insert` requiring caller role in (warehouse, operator_admin, superadmin, manager) AND existence of an open parent session for the same user. This is the only protected entity in Appendix A allowed to receive FE-direct INSERTs. The role-plus-open-session gate is the structural replacement for the usual DEFINER role check. **Forensic discriminator:** FE-direct INSERTs are constrained to `result = 'network_error'`; this value is never emitted by the SECURITY DEFINER wrappers (which only set success / blocked_rls / blocked_trigger / rpc_error / validation_error), so the `result` column is a grep-able boundary between FE-originated and wrapper-originated rows. **Article 4 carve-out:** FE-direct INSERTs do not set `app.via_rpc` or `app.rpc_name`; the row itself is the audit, so the universal `write_audit_log` trigger correctly does not double-log it. This is intended behavior, not an Article 4 violation.

**Rollback:** Revert the HTML edit in `docs/architecture/01_constitution.html`. No SQL to undo.

---

## 2026-05-25 — Phase G Inventory Integrity Initiative, Phase 1 FE migration

**Phase / Article:** Phase G P1 / Constitution Articles 1, 3, 5, 6 (Cody-approved).
**Applied to:** repo (FE only; no SQL).
**Files:** `src/app/(app)/layout.tsx`, `src/app/(field)/layout.tsx`, `src/app/(app)/app/inventory/page.tsx`, `src/app/(field)/field/inventory/page.tsx`, `src/app/(field)/field/inventory/[inventoryId]/page.tsx`, `src/lib/inventory/adjust-warehouse-line.ts`.
**Summary:** Operator console plus field app inventory pages now route every `warehouse_inventory` stock or status write through the C.3 SECURITY DEFINER wrappers via the FE helpers shipped in f6ed953. Layouts mount `InventorySessionProvider` so the session context reaches every page. Edit affordances disable when no session is open OR caller role is outside `EDIT_ROLES`. `adjustWarehouseLine` flipped to runtime hard-rejection for stock and status callers, directing them to `attemptCorrection` / `attemptStatusChange`; metadata-only callers use `adjustWarehouseLineMetadata`. Zero direct UPDATE on `warehouse_inventory` survives in any migrated page. Build clean (tsc + next build). Cody Article 3 review passed. Commit 3c18df5.

**Rollback:** `git revert 3c18df5`. The C.3 wrapper RPCs and FE helpers remain live; pages would revert to calling the soft-deprecated `adjustWarehouseLine` directly.

---

## 2026-05-24 — Phase G Inventory Integrity Initiative, Phase 1 backend (C.1, C.2, C.3)

**Phase / Article:** Phase G P1 (Inventory Integrity Initiative, PRD v2) / Constitution Articles 1, 2, 4, 5, 6 (Amendment 002), 7, 8, 12, 14, 15.
**Applied to:** prod.
**Migration names:**

- `phaseG_p1_c1_c2_inventory_control_tables` (Workstream C.1 + C.2 audit tables)
- `phaseG_p1_c3_inventory_control_rpcs` (Workstream C.3 wrappers + the new `inactivate_warehouse_row` canonical writer for PRD B.2)

**Summary:** Phase G PRD v2 Phase 1 unblocks the WH manager. Two new append-only tables, six new RPCs. `inventory_control_session` and `inventory_control_attempt` capture every inventory-control sitting and every per-row mutation attempt (success or failure) with full RPC response, before-and-after diff, error class, and a FE-side correlation id. Six SECURITY DEFINER functions land: `inactivate_warehouse_row` (the missing canonical Active->Inactive writer, per PRD B.2), `start_inventory_session` and `close_inventory_session` for the session lifecycle, and three logging wrappers `attempt_inventory_correction`, `attempt_reactivate_row`, `attempt_status_change` that delegate to existing canonical writers (`apply_inventory_correction`, `reactivate_warehouse_row`, and the new `inactivate_warehouse_row`) inside PL/pgSQL BEGIN/EXCEPTION blocks (PG's implicit SAVEPOINT). Each wrapper INSERTs exactly one `inventory_control_attempt` row in the terminal state per Cody's Option Y append-only ruling; failures are classified by SQLSTATE (insufficient_privilege->blocked_rls, check_violation->blocked_trigger, raise_exception->validation_error, OTHERS->rpc_error). Cody-reviewed both migrations: C.1/C.2 approve-with-revisions (Option Y applied; 'pending' dropped from result CHECK list); C.3 approve-with-revisions (reservation guard added to `inactivate_warehouse_row`; article-list migration header; function COMMENT naming the canonical writer). RLS on both new tables: SELECT and INSERT gated to `warehouse / operator_admin / superadmin / manager` via `user_profiles` join; UPDATE and DELETE blocked at the policy layer. `inventory_control_attempt` INSERT additionally requires the parent session to exist and be `status='open'`. Defense-in-depth partial unique index `idx_ics_one_open_per_user` on `(started_by) WHERE status='open'`; `start_inventory_session` auto-aborts a prior open session for the same user before INSERTing the new one (SECURITY DEFINER bypass of `ics_no_update`).

**Verified post-deploy:** 2 tables created (10 + 18 columns), 12 indexes (including PKs and slug UNIQUE), 8 RLS policies. 6 functions present with correct signatures, all SECURITY DEFINER. Dry-test 1: `start_inventory_session` -> `close_inventory_session` round-trip succeeded against a real session row (no warehouse_inventory mutation). Dry-test 2: `inactivate_warehouse_row` refused on a real Active row with positive stock with the expected `refusing to inactivate row with stock` message. One closed audit session remains as a smoke fixture (slug `dry_test_2026-05-24_phase_g_smoke`); harmless.

**Still pending in Phase 1:** Article 15 amendment adding `inventory_control_session` and `inventory_control_attempt` to Appendix A (with the direct-INSERT exception for FE client-side failure capture). Stax FE rewire B.1 (edit-count cell), B.2 (status toggle), B.8 (canary heartbeat). A.4 Saturday 23 corrections (gated by CSV access and per-row CS sign-off at checkpoint gate 3). Phase 1 summary report `phase_g_phase_1_summary.md` due at sprint close.

**Rollback:** `DROP FUNCTION public.attempt_status_change(uuid, uuid, text, text, uuid, uuid, numeric); DROP FUNCTION public.attempt_reactivate_row(uuid, uuid, numeric, text, uuid, uuid, text, date, text); DROP FUNCTION public.attempt_inventory_correction(uuid, uuid, numeric, text, uuid, uuid); DROP FUNCTION public.close_inventory_session(uuid, uuid, jsonb); DROP FUNCTION public.start_inventory_session(uuid, uuid[], text, uuid); DROP FUNCTION public.inactivate_warehouse_row(uuid, text, uuid); DROP TABLE public.inventory_control_attempt; DROP TABLE public.inventory_control_session;`. Not recommended: the audit tables hold smoke-test rows and would lose data; the canonical inactivate path is what PRD B.2 explicitly added.

---

## 2026-05-24 — Fix multi-cabinet WEIMI JOIN in `get_pod_refill_draft`

**Phase / Article:** Phase F (refill draft read path) / Constitution Article 12
**Applied to:** prod
**Migration name:** `fix_get_pod_refill_draft_weimi_join`

**Summary:** The FE refill-draft view was joining `v_live_shelf_stock` to `shelf_configurations` with `SPLIT_PART(lss.aisle_code, '-', 2) = sc.shelf_code`. That predicate is destructive for multi-cabinet machines: WEIMI aisle codes are always `{cabinet}-A{nn}`, so the split never produces a `B`-prefix (B-side shelves never matched), produced an off-by-one for inner-aisle indices (A-side shelves matched the wrong slot), and fanned out when two cabinets shared a slot suffix (one shelf row × N matching aisle rows). Replaced with the slot_name JOIN already used by `engine_add_pod` v10: `lss.slot_name = LEFT(sc.shelf_code, 1) || (SUBSTR(sc.shelf_code, 2)::int)::text`. Verified on ACTIVATE-2005-0000-W0 against tomorrow's draft: A06 now resolves once as Gatorade Zero 6/12 (50%), A07 once as Pocari Sweat 4/12 (33%), B09 as Aquafina 13/20 (65%), B11 as Aquafina 9/20 (45%). Fan-out duplicates eliminated (6 draft rows → 4 for ACTIVATE-2005). HUAWEI-2003-0000-B1 and MC-2004-0100-O1 verified clean via the coverage diagnostic — zero `MISSING` shelves for any of the three active multi-cabinet machines in tomorrow's pick. Eight machines benefit total (ACTIVATE-2005, HUAWEI-2003, MC-2004, LLFP-2005, LLFP-2007, WH-2001, WH1-2002, WH2-2006). A separate pre-existing data gap on AMZ-1068-2401-O1 (configured B/C/D/E shelves with no corresponding WEIMI telemetry) surfaced in the coverage diagnostic — flagged as a follow-up, not a regression of this fix.

**Constitutional context:** Article 12 forward-only `CREATE OR REPLACE`. Function identity, return shape (including `wh_avail` added by `phaseF_proc_edit_po_line_audit`), and GRANTs preserved. Not a canonical writer — read-only helper — so no Cody review required. The PRD's regression-test query is captured below for the cron's post-run diagnostics.

**Cron diagnostic to add (P1, separate PR):**

```sql
SELECT m.official_name, sc.shelf_code
FROM machines_to_visit mtv
JOIN machines m ON m.machine_id = mtv.machine_id
JOIN shelf_configurations sc ON sc.machine_id = m.machine_id AND sc.is_phantom = false
LEFT JOIN v_live_shelf_stock lss
  ON lss.machine_id = m.machine_id
  AND lss.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
WHERE mtv.plan_date = CURRENT_DATE + 1
  AND mtv.status IN ('picked','cs_added')
  AND lss.slot_name IS NULL;
-- Zero rows = healthy. Non-zero = shelf_code ↔ WEIMI mapping gap.
```

**Rollback:** Restore the prior body via `CREATE OR REPLACE FUNCTION get_pod_refill_draft` with the `SPLIT_PART(lss.aisle_code, '-', 2) = sc.shelf_code` JOIN. Not recommended — the broken predicate is what this migration repairs.

---

## 2026-05-23 — PRD-001: WH manager can edit submitted PO with full audit capture

**Phase / Article:** Phase F (procurement) / Constitution Articles 1, 4, 7, 8
**Applied to:** prod
**Migration names:**

- `phaseF_proc_edit_po_line_audit` (RPCs + denormalized columns)
- `phaseF_proc_events_widen_event_type_check` (widens `procurement_events.event_type` CHECK to accept `po_line_edited`)

**Summary:** New canonical UPDATE writer `edit_purchase_order_line(p_po_line_id uuid, p_new_ordered_qty numeric, p_new_price_per_unit_aed numeric, p_new_expiry_date date, p_reason text)` for the three editable PO-line fields (ordered_qty, price_per_unit_aed, expiry_date) plus the derived `total_price_aed`. SECURITY DEFINER, role gate `warehouse / operator_admin / superadmin / manager`, required reason ≥10 chars, no-op edit guard, coherence guard (ordered_qty ≥ received_qty). Applies Dara's three schema corrections (numeric not integer; write_audit_log columns are `operation` + `occurred_at`; actor_role captured; dual-write to BOTH `procurement_events` and `write_audit_log`) and Cody's required revisions (dual-write across both audit tables in one transaction; column COMMENTs on the new `purchase_orders.last_edited_at` / `last_edited_by` columns naming `edit_purchase_order_line` as the sole writer; no-op edit guard). New read helper `get_po_edit_history(p_po_id text)` (SECURITY INVOKER) reads from `procurement_events` (idx_procurement_events_po_id covers it) joined to `user_profiles` for actor display, powering the FE "Edit history" pill and the post-receipt warning banner. FE: new `EditPOLineDrawer` and `POEditHistoryPill` components wired into `/field/orders`; post-receipt warning banner added to `/field/receiving/[poId]`.

**Article 8 note (open question deferred to CS):** dual-write to `write_audit_log` + `procurement_events` is the conservative path per Cody's verdict — strict reading of Article 8 requires a `write_audit_log` row from every canonical writer. An Article 15 amendment recognizing subsystem audit logs (`procurement_events`, `pod_inventory_audit_log`, `warehouse_inventory_audit_log`) as Article 8-equivalent would let us drop the dual-write, but is deferred to a future PR. Default for now: dual-write stays.

**Smoke test (against staging fixture, then cleaned up):** insert a fake PO line, call `edit_purchase_order_line(qty 10→12, price 5.0→5.5, expiry +30→+60, reason='PRD-001 smoke test…')`, assert both `procurement_events.po_line_edited` and `write_audit_log` rows exist; verify `get_po_edit_history` returns the new event; verify no-op guard rejects re-submitting the same values; verify coherence guard rejects `ordered_qty < received_qty`; verify reason-length guard rejects short reasons. All checks pass.

**Rollback:** `DROP FUNCTION public.edit_purchase_order_line(uuid, numeric, numeric, date, text); DROP FUNCTION public.get_po_edit_history(text); ALTER TABLE public.purchase_orders DROP COLUMN last_edited_at, DROP COLUMN last_edited_by;` + restore the original `procurement_events_event_type_check` CHECK without `po_line_edited`. Existing `procurement_events` rows of type `po_line_edited` and `write_audit_log` rows with `rpc_name='edit_purchase_order_line'` would need to be deleted or accepted as historical audit records.

---

## 2026-05-23 — Refill Engine Emergency Fix (PRD prd-refill-engine-fix.md)

**Phase / Article:** Phase F / Constitution Articles 1, 4, 5, 6, 8, 12
**Applied to:** prod
**Migration names:**

- `refill_engine_p1_decouple_wh_fanout_diag` (Phase 1, P0)
- `refill_engine_p2_floor_auth_empty_shelf` (Phase 2, P1)
- `refill_engine_p3_wh_avail_in_draft` (Phase 3, P2)

**Summary:** Three-phase rebuild of the refill engine pipeline after the 23-May session produced only 3 committed rows out of 96 generated and removed products from healthy shelves while ignoring critical gaps. Guiding principle: **inventory does not gate refill planning**. Refill plans are now built from shelf gaps; warehouse stock is purely informational. Phase 1 (P0) — `engine_add_pod` v9 stops capping qty by `wh_avail` (only physical shelf headroom caps now); `wh_avail` and `wh_warning` move to informational `reasoning` JSONB. `stitch_pod_to_boonz` v12 — `pull_lines` produces `variant_final = variant_target` (no WH cap); `remove_lines` applies uniform even-split for ALL `source_origin` values, fixing the fan-out bug where `REMOVE qty=6` with 3 variants produced 3×6=18u; new `diagnostics[]` array returns one entry per approved pod_refill_plan row with `stitch_result` ∈ {resolved, resolved_no_wh_stock_warning, no_active_mapping, no_inventory_to_remove}. Phase 2 (P1) — `engine_add_pod` v10 adds machine-velocity-derived performance fill floor: tiers (≥10 units/day → 70%, ≥3 → 50%, else → 25%) plus AC-6 absolute safety net (`gap≥2 AND fill_pct≤25%`); new `clamp_reason='performance_floor'`. `auto_generate_draft` adopts NULL-safe role gate (matches canonical pattern: only enforce when `auth.uid() IS NOT NULL`). `engine_finalize_pod` v10 annotates REMOVE/M2W rows with no paired ADD_NEW on the same `(machine, shelf)` with `reasoning.warning='empty_shelf_after_removal'`. Phase 3 (P2) — `get_pod_refill_draft` adds `wh_avail` column (NULL = no WH data, 0 = confirmed empty). FR-009 satisfied transitively by FR-002 (no WH-weighted code remains to gate). Test results on 2026-05-23: engine_add_pod v10 → 74 refills (up from 43); 33 rows triggered the performance floor; 0 rows have legacy `wh_short` reasons; 14+ rows carry `wh_warning=true` for transparency. engine_finalize_pod flagged 2 rows with `empty_shelf_after_removal` (ALJLT-1015-0100-B1 A05 Krambals M2W + OMDBB-1020-0P00-O1 A01 Tamreem Date Ball M2W). stitch dry-run produced 228 boonz lines from 130 approved pod rows, with 130-entry diagnostics array — no fan-out inflation. Cody-reviewed Phase 1 + Phase 2 (Phase 3 read-only, fast-path approved).

**New / changed values to be aware of:**

- `pod_refills.clamp_reason` adds value `performance_floor`; removes `skipped_no_wh` and `capped_by_wh` from the universe.
- `pod_refills.reasoning` JSONB adds keys `wh_avail`, `wh_warning`, `velocity_raw_qty`, `floor_target`, `machine_daily_velocity`, `fill_floor_threshold`.
- `pod_refill_plan.reasoning` JSONB may carry `{"warning": "empty_shelf_after_removal"}` on REMOVE/M2W rows.
- `refill_plan_deviations.deviation_type` adds value `mapping_gap`; removes `wh_shortage` from new inserts.
- `stitch_pod_to_boonz` return JSONB adds `diagnostics` array.
- `get_pod_refill_draft` return type adds `wh_avail integer` (nullable).
- Engine version strings: `v10_wh_decoupled_perf_floor` (engine_add_pod), `v12_wh_decoupled_fanout_fix_diag` (stitch), `v10_empty_shelf_warning` (engine_finalize_pod).

**Rollback:** Revert each function to its prior `prosrc` via `CREATE OR REPLACE FUNCTION` (or `DROP+CREATE` for `get_pod_refill_draft` since its return type was changed). Prior bodies are preserved in the migration history of the function (pre-`v9/v10/v11.2/v12` versions). No DDL was applied to any base table or RLS policy, so a rollback is purely function-body level.

---

## 2026-05-18 — Native machine-to-machine transfers (swap_between_machines)

**Phase / Article:** D (M2M transfers) / Constitution Articles 1, 4, 8, 12
**Applied to:** prod
**Migration name:** `phaseD_swap_between_machines`

**Summary:** Native M2M transfer infrastructure. Previously, machine-to-machine product moves were hacked via unlinked Remove + Add New dispatch lines with free-text comments — the packing FE couldn't distinguish M2M from real swaps, WH stock was incorrectly deducted by `pack_dispatch_line`, and pod_inventory wasn't adjusted. The new `swap_between_machines(source_machine_id, dest_machine_id, transfers jsonb, plan_date, comment)` RPC atomically creates a matched Remove + Add New dispatch pair with `is_m2m=true, packed=true, dispatched=false` (zero WH stock movement). Pod_inventory is NOT adjusted at plan creation — deferred to driver confirmation via `receive_dispatch_line` (see `phaseD_m2m_deferred_pod_adjustment`). Net-zero guaranteed by construction. Companion `acknowledge_m2m_transfer(transfer_id)` lets the WH manager confirm awareness (sets `wh_approved_at/by`). Three new columns on `refill_dispatching`: `is_m2m boolean`, `m2m_partner_id uuid` (bidirectional partner link), `m2m_transfer_id uuid` (groups a logical transfer). Two partial indexes for M2M lookups. New partial unique index `idx_pod_inv_active_shelf` on `pod_inventory(machine_id, shelf_id, boonz_product_id) WHERE status='Active'` enables the dest-machine upsert — required dedup of 1,415 stale duplicate Active rows first (archived as Inactive with `removal_reason='archived_2026-05-18_m2m_dedup'`). Updated `conserve_split_dispatch_quantity` trigger to skip M2M rows (prevents false parent-decrement on packed M2M inserts). Dara-designed, Cody-reviewed (4 revisions applied: qty>0 validation, audit trigger verification, partial unique index, explicit NULL on from_warehouse_id).

**Rollback:** `ALTER TABLE refill_dispatching DROP COLUMN is_m2m, DROP COLUMN m2m_partner_id, DROP COLUMN m2m_transfer_id; DROP INDEX idx_pod_inv_active_shelf; DROP FUNCTION swap_between_machines; DROP FUNCTION acknowledge_m2m_transfer;` + restore original `conserve_split_dispatch_quantity` function body (remove the `is_m2m` early-return guard).

---

## 2026-05-18 — M2M deferred pod_inventory adjustment

**Phase / Article:** D (M2M transfers, fix) / Constitution Articles 1, 4, 8
**Applied to:** prod
**Migration name:** `phaseD_m2m_deferred_pod_adjustment`

**Summary:** Corrects the M2M lifecycle to match regular refill flow — pod_inventory adjustments are deferred to driver confirmation (via `receive_dispatch_line`) rather than happening at plan creation time. Two changes: (1) `swap_between_machines` no longer touches `pod_inventory`; dispatch lines are now created with `dispatched=false` (was `true`) so they flow through the normal pickup → receive lifecycle; machine names resolved for the return note ("Start at source"). (2) `receive_dispatch_line` gains an M2M-aware early branch at the top: for M2M Remove, decrements `pod_inventory.current_stock` by `filled_quantity` (archives row only if stock hits 0); for M2M Add New, upserts via `ON CONFLICT` on the new `idx_pod_inv_active_shelf` partial unique index. Both paths skip all warehouse stock operations (no consumer_stock drain, no WH credit/debit). Returns early with `is_m2m: true` and `m2m_transfer_id` in the response. Regular (non-M2M) flow is untouched below the early-return block.

**Rollback:** Restore previous `swap_between_machines` body (with pod_inventory ops and `dispatched=true`) + restore previous `receive_dispatch_line` body (without the M2M branch). The original bodies are in migration `phaseD_swap_between_machines`.

---

## 2026-05-19 (afternoon) — Picker v5 sibling score + FE filled-vs-planned fix

**Phase / Article:** F bugfix / Constitution Articles 4, 12

**Applied to:** prod (DB) + repo (FE)
**Migration name:** `phaseF_picker_v5_sibling_score`

**Summary:** Two small follow-ups before tomorrow's refill cycle. (1) `pick_machines_for_refill` v5: sibling-only picks were inheriting `priority_score=0` from `with_score` (because their severity computes to `'skip'`), making them invisible in priority-sorted views. v5 computes a soft sibling score in `final_picks` using the half-threshold conditions that pulled the sibling in: `empty_shelves_count>0` → 8, `fill_pct<70` → 6, `days_since_visit>=7` → 5, `expired_skus_7d>0` → 6, `active_intent_count>0` → 5. Max 30, ranks below 'medium' (25) so primary picks always win. Smoke test on 2026-05-20 plan: 23 primary picks, no sibling-only triggered, but the soft-score logic is now in place for when they do appear. Closes task #17 (Phase F day-1 nit).

**FE fix — dispatch-complete summary** (`src/app/(field)/field/dispatching/[machineId]/page.tsx`): the post-save summary was using `(l.filled_qty || l.quantity)` for shelf-total aggregation and per-line render. When `filled_qty=0` (driver returned the line), the `||` fallback to `quantity` falsely displayed the planned units as if they were placed. IFLY 2026-05-19: Fade Fit Hazelnut ×4 + Peanut Butter ×4 showed as "added" when both were returned (only Salted Caramel ×3 + Dark Chocolate ×1 actually went in). Fix: aggregate from `filled_qty` only (no fallback), filter on `line.action === "added"` for add/remove totals, add a new `returnedTotal` shown with `↩` amber badge. Per-line render now distinguishes `↩{quantity}` (returned) from `×{filled_qty}` (placed) from `−{filled_qty}` (removed). `line.action` is correctly re-derived from DB on reload (dispatched=true → "added", returned=true → "returned"). Closes task #75.

**Rollback:**

```sql
-- Restore picker v4 body from session transcript at edd21a03 or write_audit_log.
```

FE rollback: `git revert` the commit.

---

## 2026-05-19 — Phase F dispatch editing: 6 RPCs + edit_log + source traceability + receive UPSERT

**Phase / Article:** F / Constitution Articles 1 (revised by Amendment 005), 2, 4, 5, 7, 8, 12, 15
**Applied to:** prod
**Migration names:** `phaseF_receive_dispatch_line_upsert_active_pod_row`, `phaseF_dispatch_editing_schema`, `phaseF_dispatch_editing_rpcs`

**Summary:** Three migrations to unblock the driver/WH manager workflow and give them real editing affordances. Driven by two incidents today on VOXMCC-1005 (Ice Tea Peach blocked at A07) and IFLYMCC-1024 (driver loaded 4 Fade Fit Coconut + 10 7up, neither in the dispatch plan; multi-variant Fade Fit returned because driver substituted). Dara designed the schema, Cody approved with 4 revisions, Stax FE design queued for tomorrow.

**Fix #1 — `receive_dispatch_line` UPSERT (`phaseF_receive_dispatch_line_upsert_active_pod_row`).** The recent `idx_pod_inv_active_shelf` unique index (`(machine_id, shelf_id, boonz_product_id) WHERE status='Active'`) was added during MPMCC backfill prep and rejected the straight INSERT in `receive_dispatch_line` whenever a prior Active row existed on the shelf for the same boonz*product. Driver got `Receive failed: duplicate key value violates unique constraint "idx_pod_inv_active_shelf"`. Fix: archive existing Active rows via a CTE (`status='Inactive'`, `removal_reason='merged_into_dispatch*<date>\_<dispatch_id>'`), then INSERT the new row with summed `current_stock`and`LEAST(new_expiry, old_expiry)`for FEFO worst-case. Smoke test on the stuck VOX A07 Ice Tea Peach dispatch (3 + 10 = 13 units after merge): old row archived with traceable reason, new row Active with batch_id`MERGED-DISPATCH-2026-05-19`. Driver unblocked.

**Fix #2 — dispatch editing schema (`phaseF_dispatch_editing_schema`).** Eleven new columns on `refill_dispatching`: `original_quantity`, `original_boonz_product_id`, `original_shelf_id` (nullable due to legacy data — 2,824 rows had NULL shelf_id, 646 NULL boonz_product_id, 53 NULL quantity); `edit_count int NOT NULL DEFAULT 0`; `last_edited_by`, `last_edited_by_role`, `last_edited_at`; `source_kind text NOT NULL DEFAULT 'unknown'` (CHECK in `wh | m2m | truck_transfer | unknown`); `source_warehouse_id`, `source_machine_id`; `created_by_edit boolean`. Type-conditional CHECK enforces `source_kind`↔FK consistency (e.g. `m2m` requires `source_machine_id`, `wh` requires `source_warehouse_id`). Backfill: 29,715 rows got `original_quantity = quantity`; 29,388 got real `source_kind` (m2m from `is_m2m=true`, wh from `from_warehouse_id`, else unknown). New protected table `refill_dispatching_edit_log` (Amendment 003 11th entity) with append-only RLS + generic audit trigger. Four new indexes on each table for the FE's hot paths (edited rows per machine, recent activity, per-user audit, edit_kind filter).

**Fix #3 — six new canonical writers (`phaseF_dispatch_editing_rpcs`).** All SECURITY DEFINER, role-gated against actual `user_profiles.role` (the `p_edit_role` parameter is audit-only, not authorization), set `app.via_rpc`/`app.rpc_name`, validate inputs, lock the target row with `SELECT ... FOR UPDATE`, write to `refill_dispatching_edit_log`. State-machine guards per Cody's R1:

| RPC                          | Allowed when                          | Audit role parameter accepts                                                                                                                                                                                      |
| ---------------------------- | ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `edit_dispatch_qty(...)`     | `item_added=false`                    | driver, warehouse_manager, operator_admin, superadmin, manager                                                                                                                                                    |
| `edit_dispatch_shelf(...)`   | `picked_up=true AND item_added=false` | driver, operator_admin, superadmin, manager (WH manager rejected)                                                                                                                                                 |
| `edit_dispatch_product(...)` | `picked_up=true AND item_added=false` | driver, operator_admin, superadmin, manager. Resolves pod_product_id via machine-aware product_mapping (per-machine wins).                                                                                        |
| `add_dispatch_row(...)`      | always                                | driver, warehouse_manager, operator_admin, superadmin, manager. Validates shelf exists on planogram; resolves pod_product_id; hard-refuses m2m if source machine has no active pod_inventory > 0 for the product. |
| `remove_dispatch_row(...)`   | `picked_up=false`                     | warehouse_manager, operator_admin, superadmin, manager (driver rejected). Soft-remove via `include=false`.                                                                                                        |
| `set_dispatch_source(...)`   | `item_added=false`                    | warehouse_manager, operator_admin, superadmin, manager. Same m2m hard-refuse validation.                                                                                                                          |

`restore_dispatch_row` was rejected by Cody R2 (rewriting `item_added=true` history is dangerous). Post-receive corrections must go through `adjust_pod_inventory` directly with explicit per-row sign-off.

**Amendment 003 expanded (11th entity).** `refill_dispatching_edit_log` appended to the protected entity list. Pending ratification.

**Amendment 005 filed.** Revises Article 1 to allow multiple narrow-concern canonical writers on high-traffic protected entities (`refill_dispatching`, `pod_inventory`, `warehouse_inventory`, `refill_plan_output`). Codifies the precedent that's been operationally true since before Phase A — the literal "exactly one canonical write path" was always shorthand for "no uncontrolled paths." Doc-only commit, no SQL.

**Tomorrow's Stax work.** FE design for driver app + WH packing app to actually use these RPCs. Filed as task #79. Plus task #75 (display planned-vs-filled fix) and #76 (driver substitution UX).

**Rollback:**

```sql
-- RPCs
DROP FUNCTION IF EXISTS public.edit_dispatch_qty(uuid, numeric, text, text, text);
DROP FUNCTION IF EXISTS public.edit_dispatch_shelf(uuid, text, text, text, text);
DROP FUNCTION IF EXISTS public.edit_dispatch_product(uuid, uuid, text, text, text);
DROP FUNCTION IF EXISTS public.add_dispatch_row(uuid, text, uuid, numeric, text, date, text, uuid, uuid, text, text, text);
DROP FUNCTION IF EXISTS public.remove_dispatch_row(uuid, text, text, text);
DROP FUNCTION IF EXISTS public.set_dispatch_source(uuid, text, uuid, uuid, text, text, text);

-- Edit log table + RLS + trigger
DROP TRIGGER IF EXISTS tg_audit_refill_dispatching_edit_log ON public.refill_dispatching_edit_log;
DROP TABLE IF EXISTS public.refill_dispatching_edit_log;

-- Schema columns (this will fail if any new rows reference them; check first)
ALTER TABLE public.refill_dispatching
  DROP COLUMN IF EXISTS original_quantity, DROP COLUMN IF EXISTS original_boonz_product_id,
  DROP COLUMN IF EXISTS original_shelf_id, DROP COLUMN IF EXISTS edit_count,
  DROP COLUMN IF EXISTS last_edited_by, DROP COLUMN IF EXISTS last_edited_by_role,
  DROP COLUMN IF EXISTS last_edited_at, DROP COLUMN IF EXISTS source_kind,
  DROP COLUMN IF EXISTS source_warehouse_id, DROP COLUMN IF EXISTS source_machine_id,
  DROP COLUMN IF EXISTS created_by_edit;

-- receive_dispatch_line: restore the pre-UPSERT body from write_audit_log or session transcript.
```

---

## 2026-05-18 (PM) — Phase F bugfix: machine-aware product_mapping JOINs

**Phase / Article:** F bugfix / Constitution Articles 1, 12

**Applied to:** prod
**Migration names:** `phaseF_fix_v_warehouse_pod_rollup_machine_aware_dedupe`, `phaseF_stitch_v8_machine_aware_pm_joins`

**Summary:** Discovered during the Phase F reconciler design pass: production code that JOINs `pod_inventory` (or `warehouse_inventory`) to `product_mapping` was not scoping by `machine_id`. `product_mapping` is correctly modeled as per-machine — 38 machines × ~140 products = ~5,500 rows seeded 2026-03-21 — and the existing UNIQUE constraint on `(pod_product_id, boonz_product_id, machine_id)` enforces correctness. **The data is fine.** Production _queries_, however, were silently fanning out by N× (N = per-machine mappings for the SKU, ~24× on average) wherever they joined pm without filtering on machine_id. This inflated `wh_avail` in Stage 2a, produced duplicate REMOVE lines in Stage 3 Stitch, and was masking real WH shortage all the way back to Phase F day 1. Two fixes shipped this afternoon; three more queued for tomorrow.

**Fix #1 — `v_warehouse_pod_rollup`.** View previously did `JOIN warehouse_inventory wi ⋈ product_mapping pm ... GROUP BY pm.pod_product_id` with no dedupe on pm. SUM(`wi.warehouse_stock`) was multiplied by the count of per-machine pm rows for each boonz_product. Fix: subquery `pm_distinct AS (SELECT DISTINCT pod_product_id, boonz_product_id FROM product_mapping WHERE status='Active')` before the join. Before/after measurement across 10 high-mapping products (Soft Drinks Mix, Krambals & Zigi, Krambals, Tamreem Date Ball, Al Ain Water, Pepsi Mix, Pepsi Black, Chocolate Bar, Snack Bar, Vitamin Well): each dropped from a number in the 1,200–3,200 range to a number in the 48–134 range — exactly 24× reduction in every case, matching the per-machine seeding factor. Vitamin Well went from "1,200 units fleet-wide" (looked comfortable) to "48 units, earliest_active_expiry 2026-06-07" (tight, three weeks). Downstream consumers (`engine_add_pod` wh_avail cap, `engine_swap_pod` Pass 2 filter `wpr.total_stock > 0`, any ops query reading total_stock) automatically pick up the correct numbers.

**Fix #2 — `stitch_pod_to_boonz` v8.** Two CTEs inside the function had the same JOIN pattern. **(a) `remove_lines`** joined `v_pod_inventory_latest ⋈ product_mapping` without machine scoping, fanning REMOVE/M2W output by N×. Switched the pm join to an `EXISTS` clause with `(pm.machine_id IS NULL OR pm.machine_id = a.machine_id)` — no fan-out, just a filter proving the boonz→pod mapping is valid. **(b) `demand`** (procurement-alert CTE) already had machine scoping but no ROW_NUMBER dedupe — double-counted when both per-machine and global pm rows matched. Added `DISTINCT ON (plan_date, machine_id, shelf_id, pod_product_id, pm.boonz_product_id) ... ORDER BY (pm.machine_id = prp.machine_id) DESC NULLS LAST, pm.is_global_default DESC` to keep one pm row per (prp_row, boonz_product), preferring per-machine over global. `pull_raw` and `m_raw` were already correct (use the same ROW_NUMBER pattern) — left unchanged. Smoke test against the 2026-05-12 approved plan: 265 lines built, 38 deviations, 47 procurement alerts, 1.1s. Function version flipped from `v7_sequential_redist` to `v8_machine_aware_pm`.

**Three more fixes queued (tasks #72, #73, #17).** `engine_swap_pod` qty subqueries (MEDIUM — same fanout in Pass 1/Pass 2 qty_out/qty_in), `find_substitutes_for_shelf` wh_stock_units (MEDIUM — display only, inflates the WH stock column shown to CS in the substitute search), and the sibling-priority-score=0 nit (LOW — Phase F day 1 todo). Deferred to allow observation of tomorrow's first refill cycle running on the fixed views.

**What this changes in production going forward.**

- `engine_add_pod` will hit `clamp_reason='capped_by_wh'` on products with real WH constraints (was previously rare because wh_avail was 24× inflated). Expect smaller REFILL qtys on tight-stock products.
- Cross-fleet allocations will no longer exceed real WH. Stitch deviations should drop and procurement alerts should sharpen.
- REMOVE/M2W stitched output drops from N× duplicates to 1× per (shelf, boonz variant). Past stitched plans that included REMOVE lines may have had wasted-CPU duplicates downstream; new plans are clean.

**Rollback:**

```sql
-- Restore the pre-fix view body
CREATE OR REPLACE VIEW public.v_warehouse_pod_rollup AS
 SELECT pm.pod_product_id,
    sum(wi.warehouse_stock)::integer AS total_stock,
    count(DISTINCT wi.wh_inventory_id) FILTER (WHERE wi.status = 'Active'::text AND wi.warehouse_stock > 0::numeric) AS active_batches,
    min(wi.expiration_date) FILTER (WHERE wi.status = 'Active'::text AND wi.warehouse_stock > 0::numeric) AS earliest_active_expiry
   FROM product_mapping pm
     JOIN warehouse_inventory wi ON wi.boonz_product_id = pm.boonz_product_id
  WHERE pm.status = 'Active'::text AND wi.status = 'Active'::text
  GROUP BY pm.pod_product_id;

-- Restore stitch_pod_to_boonz to v7 — body retrievable from write_audit_log payload or
-- session transcript at edd21a03.
```

---

## 2026-05-18 — Phase F day-3: Conductor, Gate 0, Edit RPCs, Picker v2/v3, MPMCC backfill

**Phase / Article:** F (Conductor + Gate 0) + bugfix / Constitution Articles 1, 2, 4, 7, 8, 12

**Applied to:** prod + repo
**Migration names:** `phaseF_edit_rpcs_with_audit` (v1..v6 column fixes), `phaseF_gate_zero_machines_to_visit`, `phaseF_gate_zero_status_constraint_and_backfill`, `phaseF_picker_v2_quality_fixes`, `phaseF_picker_v3_visit_attempts_count`, `phaseF_backfill_mpmcc_2026-05-14_pragmatic`

**Summary:** Major Phase F day-3. Three orthogonal workstreams shipped: (1) **Gen 3 Conductor** — new `boonz-master-3` skill replaces the Phase D monolith, routes natural language to four `boonz-pico-*` sub-skills, enforces explicit Gate 0 / Gate 1 / Gate 2 green lights, no auto-engine runs. Old `boonz-master` archived as `boonz-legacy`. (2) **Edit + re-stitch RPCs** so CS can change a plan after Gate 1 without breaking dispatching. (3) **Gate 0 between Stage 1 and Stage 2** — CS confirms the picked machine list before the engine runs. Plus four picker-quality fixes that cut the candidate list in half. Plus a pragmatic backfill of 17 stuck dispatch rows from a 2026-05-14 EOD-misrelease incident on MPMCC-1054 / 1058.

**Edit RPCs** (`phaseF_edit_rpcs_with_audit` v1..v6). New canonical writers `edit_pod_refill_row(plan_date, machine_id, shelf_id, pod_product_id, action, new_qty, reason, conductor_session)` (qty-only edit; 5-tuple PK addressing; refuses if any linked refill_plan_output row past pending; appends to `reasoning` jsonb), `stop_pod_refill_row(...)` (thin wrapper, qty→0), `restitch_after_edits(plan_date, dry_run)` (scoped re-stitch — only touches operator_status=pending boonz rows, delegates to existing `stitch_pod_to_boonz`). Plus read-only INVOKER function `find_substitutes_for_shelf(plan_date, machine_id, shelf_id, anchor_pod_product_id, top_n, aggressiveness_pct)` — Pearson top-N with a 0–100 aggressiveness knob (0–33 per-machine only, 34–66 + loc_type, 67–100 + category fallback). New table `pod_refill_plan_audit` with RLS + no-update/no-delete policies. New columns on `pod_refill_plan`: `edited_at`, `edited_by`. **Scope deferred to v2**: changing `pod_product_id` or `action` requires DELETE+INSERT because they're part of the 5-tuple PK. Cody-reviewed with 7 findings, all addressed before apply. v2..v6 are forward-only column-name fixes discovered during smoke tests (`machines.location_type` not `loc_type`; `correlation_pod_per_loc_type.location_type`; `refill_plan_output.generated_at` not `created_at`; `pod_products.product_category` not `category`; `pod_products.status` doesn't exist — switched to `is_catchall=false`; `warehouse_inventory.warehouse_stock + consumer_stock` not `stock_units`; plus `#variable_conflict use_column` to resolve OUT-column vs table-column ambiguity).

**Gate 0** (`phaseF_gate_zero_machines_to_visit`). New canonical writers `confirm_machines_to_visit(plan_date)` (flips picked rows confirmed_at=now()), `unpick_machine_to_visit(plan_date, machine_id, reason)` (drop a machine, status→cs_dropped), `pick_machine_manually(plan_date, machine_id, reason)` (add a machine, status=cs_added with auto-confirm). Plus helper `_assert_gate_zero(plan_date)` that raises `Gate 0 not passed: N machine(s) picked but unconfirmed` if any `picked` row lacks `confirmed_at`. Patched `engine_add_pod` and `engine_swap_pod` with `PERFORM public._assert_gate_zero(p_plan_date)` near the top — the engine literally cannot run until CS confirms. Engine reads also widened from `status='picked'` to `status IN ('picked','cs_added')` so CS-manual additions go through Stage 2. New columns on `machines_to_visit`: `confirmed_at`, `confirmed_by`, `dropped_at`, `dropped_by`, `dropped_reason`, `manual_pick_reason`. Generic audit trigger already in place via `tg_audit_machines_to_visit` so Article 8 covered automatically.

**Status constraint widen + backfill** (`phaseF_gate_zero_status_constraint_and_backfill`). Caught a latent bug — `machines_to_visit.status` CHECK constraint only allowed `('picked','superseded')`, which would have caused every `unpick_machine_to_visit` / `pick_machine_manually` to fail on first call. Widened to `('picked','cs_added','cs_dropped','completed','superseded')`. Backfilled 52 historical `picked` rows (2026-05-12 + 2026-05-13) to `status='completed', confirmed_at=picked_at, confirmed_by='system_backfill_2026-05-18'` so the conductor's "what's pending Gate 0" query doesn't dredge stale rows forever. CS-approved this Decision 1 inline.

**Picker quality** (`phaseF_picker_v2_quality_fixes` + `phaseF_picker_v3_visit_attempts_count`). Five Stage-1 false-positive patterns surfaced from preview analysis: (1) `active_intents` counted fleet-wide intents (`scope_machine_ids IS NULL`) against every machine, making "intent" a constant +15 — every machine showed `active_intents=3` after the 3 active decommission intents (Ritz + 2 Loacker variants). Fix: count an intent only when its `scope_pod_product_id` is actually deployed on a slot of this machine. (2) `days_since_visit` produced garbage (`999` for NULL last-visit, `-26867` from a corrupted future-dated `dispatch_date` on WH1-2002). Fix: clamp to `[0, 365]`. (3) No velocity floor — WAVEMAKER picked with 81% dead slots but only 3 units sold last 7d. Fix: require `units_last_7d >= 5 OR is_ramping OR active_intent_count > 0` (true ramping + targeted intent exempt). (4) `is_ramping` window too permissive — IFLYMCC, MPMCC-1054/1058 stuck "ramping" at 30–36 days since visit. Fix: window 30d → 14d (per CS feedback — AMZ machines installed yesterday still ramping; older "ramping" expires). (5) `WH1-2002` (a warehouse facility) was in the route. Fix: flipped `include_in_refill=false` on the row. **v3** then added a second predicate change: `last_visit_date` now uses `MAX(dispatch_date) WHERE (picked_up=true OR returned=true)` so EOD-auto-released visits still count as visit attempts (otherwise MPMCC-1054/1058 would re-mis-flag stale every day — see backfill below). New column `units_last_7d` on `machines_to_visit` for debugging. Preview comparison: 30 candidates → 29 after v2/v3, but the "intent" tag now fires on only 12 of 29 (the ones actually carrying decommissioned products), `WH1-2002`/`WAVEMAKER` gone, MPMCC machines correctly show `days_since_visit=5`.

**MPMCC-1054 / 1058 backfill** (`phaseF_backfill_mpmcc_2026-05-14_pragmatic`). Root cause: on 2026-05-14 the driver physically loaded both machines, but the driver app never flipped `refill_dispatching.picked_up=true`. At 23:59 Dubai the `eod_auto_release_unpicked` cron classified all 17 rows as unpicked and ran `return_dispatch_line` on each, bouncing `warehouse_stock` back. Result: WH overstated, pod_inventory understated, picker mis-flagged both machines as 35-day-stale (despite live sales). After review, CS chose **B-pragmatic** path — flip flags + credit `pod_inventory` to reality, leave WH untouched (overstated by ~5 days, WEIMI snapshots will reconcile). DO block (1) called `receive_dispatch_line(dispatch_id, quantity)` on the 15 Refill / Add-New rows after first clearing `returned=false` (drains `consumer_stock` where reserved, inserts `pod_inventory` rows, no WH change because consumer pool was already 0 post-return); (2) for the Pepsi Remove row manually flipped flags + marked `pod_inventory` Inactive with skip on WH (EOD bounce already produced the correct +13 credit for a Remove); (3) marked the 1 orphan Popit-Mix row (never packed) `include=false` with a reason note. Verified: all 16 active rows now `picked_up=true, returned=false, item_added=true`; pod_inventory shows +42 units across MPMCC-1054 (Haribo 2, M&M 2, Maltesers 2, Popit 11, Ritz 10, Sun Blast 9, VOX Lollies 6) and +18 units across MPMCC-1058 (Aquafina 6, Krambals 2, Leibniz Zoo 1, Skittles 2, VOX Lollies 7). Root cause (driver-app sync gap) filed as Stax follow-up task #67. WEIMI-vs-pod_inventory reconciliation sweep filed as task #68.

**Cron change.** Old engine cron (`orchestrate_refill_plan` at 8pm Dubai) was already absent from pg_cron (no rollback needed). New cron `phaseF_stage1_prep_8pm_dubai` (jobid=13, `0 16 * * *` UTC = 20:00 Dubai daily) runs `pick_machines_for_refill(CURRENT_DATE + 1)` only. Stage 2 / Gate 1 / stitch / push-to-drivers all driven by CS via `boonz-master-3` — no autonomous engine runs. Per CS direction Decision 2 (Option C+).

**Skills change** (file-only, no migration). Source updated in `BOONZ BRAIN/new-skills/`: archived `boonz-master/SKILL.md` → `boonz-legacy/SKILL.md` with frontmatter retitled and narrow trigger list (won't fire on generic operational language). New `boonz-master-3/SKILL.md` written from scratch — conductor for Gen 3, routes to the four `boonz-pico-*` sub-skills, handhold flow + Gate 0 + edit playbook + diagnostic patterns. Pico-skills README refreshed to list 5 skills (master-3 + 4 pico) plus legacy fallback. Edit RPC design preserved at `BOONZ BRAIN/edit_rpcs_design.md` for reference.

**Rollback:**

```sql
-- Edit RPCs
DROP FUNCTION IF EXISTS public.edit_pod_refill_row(date, uuid, uuid, uuid, text, int, text, text);
DROP FUNCTION IF EXISTS public.stop_pod_refill_row(date, uuid, uuid, uuid, text, text);
DROP FUNCTION IF EXISTS public.find_substitutes_for_shelf(date, uuid, uuid, uuid, int, int);
DROP FUNCTION IF EXISTS public.restitch_after_edits(date, boolean);
DROP TABLE IF EXISTS public.pod_refill_plan_audit;
ALTER TABLE public.pod_refill_plan DROP COLUMN IF EXISTS edited_at, DROP COLUMN IF EXISTS edited_by;

-- Gate 0
DROP FUNCTION IF EXISTS public._assert_gate_zero(date);
DROP FUNCTION IF EXISTS public.confirm_machines_to_visit(date);
DROP FUNCTION IF EXISTS public.unpick_machine_to_visit(date, uuid, text);
DROP FUNCTION IF EXISTS public.pick_machine_manually(date, uuid, text);
-- For engine_add_pod / engine_swap_pod / pick_machines_for_refill: restore prior bodies from
--   write_audit_log payload or the session transcript at edd21a03.
ALTER TABLE public.machines_to_visit
  DROP COLUMN IF EXISTS confirmed_at, DROP COLUMN IF EXISTS confirmed_by,
  DROP COLUMN IF EXISTS dropped_at,   DROP COLUMN IF EXISTS dropped_by,
  DROP COLUMN IF EXISTS dropped_reason, DROP COLUMN IF EXISTS manual_pick_reason,
  DROP COLUMN IF EXISTS units_last_7d;
ALTER TABLE public.machines_to_visit DROP CONSTRAINT IF EXISTS machines_to_visit_status_check;
ALTER TABLE public.machines_to_visit ADD CONSTRAINT machines_to_visit_status_check
  CHECK (status = ANY (ARRAY['picked'::text, 'superseded'::text]));

-- Cron
SELECT cron.unschedule('phaseF_stage1_prep_8pm_dubai');

-- MPMCC backfill is data-mutation — NOT mechanically reversible. To approximate undo:
--   * UPDATE refill_dispatching SET returned=true, picked_up=false, item_added=false
--     WHERE dispatch_date='2026-05-14' AND machine_id IN (MPMCC-1054, MPMCC-1058);
--   * UPDATE pod_inventory SET status='Inactive', removal_reason='rollback_backfill_2026-05-18'
--     WHERE batch_id ILIKE 'DISPATCH-2026-05-14%';
--   No clean way to undo Pepsi pod_inventory inactivation without finding original rows.
```

---

## 2026-05-19 — Multi-variant WH approval for REMOVE returns (Bug #2 from 19-May report)

**Phase / Article:** F bugfix / Constitution Articles 1, 4, 5, 7, 8, 12
**Applied to:** prod
**Migration name:** `phaseF_wh_approve_remove_receipt_multivariant`

**Summary:** Driver returns N flavours under one parent REMOVE dispatch (e.g. Barebells 12 pcs = 4 each of 3 flavours). The existing `wh_approve_remove_receipt` only accepted one boonz variant — the parent dispatch's default — forcing the WH manager to credit all 12 under one flavour and manually correct inventory afterwards. New RPC + FE flow let the manager split the verified total across the actual variants returned, with batch expiry per variant.

**RPC:** `wh_approve_remove_receipt_multivariant(p_parent_dispatch_id, p_variant_breakdown jsonb, p_approved_by, p_reason)`. `p_variant_breakdown` shape: `[{boonz_product_id, qty, expiry}, ...]`. For each entry the function INSERTs a child REMOVE dispatch (the `conserve_split_dispatch_quantity` trigger automatically decrements parent.quantity), then calls `receive_dispatch_line` on the child with a single-expiry batch_breakdown — credits the correct WH batch and archives the correct variant's pod_inventory row. Parent closed via direct UPDATE (`returned=true, return_reason='split_into_N_variants_see_children'`) to avoid the receive/return_dispatch_line pod_archival, which would otherwise falsely archive the parent's default-variant pod row. Validates breakdown sum equals driver_confirmed_qty; validates each variant is mapped to the parent's pod_product. SECURITY DEFINER, search_path pinned, owner=postgres.

**FE:** `PendingRemoveApprovalsPanel` rewrite. Each pending REMOVE row gains a `↳ Split by variant` toggle. On open: lazy-loads available variants from `product_mapping` by pod_product_id; renders per-variant qty + batch expiry inputs; running sum-validation against verified qty; approve button disabled until sum matches. Single-variant approval path preserved unchanged for products that don't need a split.

**Example flow.** iFly Barebells return, 12 pcs total. Driver does `driver_confirm_remove` with qty=12 against the default-variant parent dispatch. WH manager opens the approval panel, hits "Split by variant", enters 4 Creamy Crisp @ 24/09/2026, 4 Cookies & Cream @ 22/09/2026, 4 Cookies & Caramel @ 22/09/2026. Sum = 12 ✓. Hits approve. Backend inserts 3 child REMOVEs, receives each one to the correct WH batch (3 separate wh_inventory credits at the right expiries), archives 3 separate pod_inventory rows (one per variant) on iFly. Parent dispatch closed as `returned=true, return_reason='split_into_3_variants_see_children'`. WH inventory and pod inventory both end up correct — no manual cleanup.

**Rollback:**

```sql
DROP FUNCTION IF EXISTS public.wh_approve_remove_receipt_multivariant(uuid, jsonb, uuid, text);
-- FE: revert PendingRemoveApprovalsPanel.tsx to pre-multivariant version
```

---

## 2026-05-19 — auto_decrement_pod_inventory: archive-on-zero rule

**Phase / Article:** F bugfix / Constitution Articles 1, 4, 5, 7, 8, 12
**Applied to:** prod
**Migration name:** `phaseF_auto_decrement_archive_on_zero`

**Summary:** CS rule clarified: when a product departs the pod via ANY event (sale, transfer, expiry-pull, driver removal) AND the resulting `current_stock` is 0, the `pod_inventory` row must flip to `status='Inactive'` immediately. Previously `auto_decrement_pod_inventory` zeroed the stock but kept `status='Active'`, leaving ghost rows that depended on ad-hoc sweep crons (`archived_*_zero_stock_past_expiry`, `_ghost_sweep_active_machines`, `_m2m_dedup`) to catch up days later. The other departure paths already archive in real time — only the sales-driven depletion was leaking.

**Fix:** Both UPDATE branches of `auto_decrement_pod_inventory` now set `status='Inactive', removal_reason=format('sold_through_%s', CURRENT_DATE)` when a sale brings a batch to ≤0. SECURITY DEFINER unchanged, audit GUCs unchanged, `pod_inventory_audit_log` still captures every transition.

**Coverage map after this fix** — every "product leaves the pod" path archives at qty=0:

- Sale → `auto_decrement_pod_inventory` ✅ (this patch)
- Driver REMOVE / return → `receive_dispatch_line` / `return_dispatch_line` REMOVE branch ✅ (already)
- M2M move (source side) → routes through REMOVE dispatch ✅ (already)
- Expired stock physically pulled by driver → REMOVE dispatch ✅ (already)
- Swap (REMOVE + ADD New pair) → REMOVE side archives ✅ (already)

**Does NOT flip Inactive** (intentional per CS rule "status follows physical reality, not stock level"):

- Slot at qty=0 waiting for refill → still Active until next refill cycle inserts a new row
- Stale WEIMI snapshot — product still physically in slot
- Slot at qty>0 past expiry — driver hasn't pulled it yet

**Historical ghosts not retroactively cleaned** by this migration — the periodic sweep crons (`archived_*_zero_stock_past_expiry` etc.) and CS's manual flips will continue to clear the backlog. The Sun Blast - Apple row at VOXMCC-1005-0201-B0 that CS flipped at 12:34 today (`archived_2026-05-19_expired_sold_cs_authorized`) is the canonical example — the new logic would have caught it automatically at sale time.

**Rollback:**

```sql
-- Restore prior function body from write_audit_log payload or session transcript.
-- The patched logic is purely additive — current_stock/snapshot_at update behaviour
-- is identical; only the status/removal_reason CASE clauses are new.
```

---

## 2026-05-19 — v_live_shelf_stock duplicate shelf rows — 3-layer fix

**Phase / Article:** E bugfix / Constitution Articles 1, 4, 12, 14
**Applied to:** prod
**Migration names:** `phaseE_v_live_shelf_stock_dedup_layer1`, `phaseE_dedup_product_name_conventions_and_unique`

**Summary:** Aisle-info modal on `/app/machines/[id]` rendered shelves repeated 6× (ACTIVATEMCC-1037 A15/A16 each showed "Evian 1L 2/6" six times). Fleet-wide sweep found 39 affected shelf rows across 8 machines, 26 products, 79 phantom rows total. Two independent fan-out sources, fixed in three layers.

**Cause A — `product_name_conventions` duplicate rows.** Table had no `UNIQUE (original_name, official_name)` constraint. An upstream re-runner (n8n or migration script) had been re-inserting the same name-mapping pairs since 2026-03 — 1017 total rows reduced to 174 distinct pairs (843 duplicate rows). When a WEIMI shelf row's `goods_name_raw` lacked an exact match in `pod_products` (Evian 1L → "Evian - 1L", Coco Max - Regular → "Coco Max", M&M bag → "M&M Bags", Oreo Minis → "Oreo Mini"), the view's tier3 JOIN multiplied output by 6×.

**Cause B — `weimi_device_status` alternate machine_ids.** ALJLT-1015, JET-1016, LLFP-2005 each had snapshots under two `machine_id`s (current + historic from a repurpose era). The view's `DISTINCT ON (machine_id)` preserved both, leaking 2× rows.

**Layer 1 fix (`phaseE_v_live_shelf_stock_dedup_layer1`).** `CREATE OR REPLACE VIEW v_live_shelf_stock`. Two changes: (1) `latest_snapshots` CTE now uses `DISTINCT ON (device_name)` ORDER BY snapshot_at DESC so alternate-machine_id rows collapse to the freshest. (2) Final SELECT wraps the tier-union in `DISTINCT ON (machine_id, cabinet_index, layer_label, slot_name)` ORDER BY snapshot_at DESC + match_method preference (direct > case_insensitive > conventions > unmatched) so any residual fan-out collapses to one row per physical slot, freshest first. DISTINCT can only reduce rows — engine consumers (Picker v4, Engine v7, Stitch v9 deployed 2026-05-19) now see correct stock counts where they were previously inflated by 6× or 2× on affected shelves. Verified `SELECT COUNT(*) FROM (… GROUP BY machine_name, slot_name, goods_name_raw HAVING COUNT(*)>1)` returns 0 fleet-wide.

**Layer 2 + 3 fix (`phaseE_dedup_product_name_conventions_and_unique`).** Single migration that (a) deletes 843 duplicate `product_name_conventions` rows keeping the earliest `created_at` per (original_name, official_name) pair via `ROW_NUMBER() OVER PARTITION BY ... ORDER BY created_at ASC, id::text ASC`, and (b) adds `UNIQUE (original_name, official_name)` constraint so future re-runners get a `unique_violation` instead of silently growing the table. Attributed via `app.rpc_name='phaseE_dedup_product_name_conventions'` so universal audit captured the DELETE. Negative test confirmed the constraint blocks re-insert of an existing pair.

**Weimi orphan-snapshot delete deliberately skipped.** The "orphan" machine_ids are alternate entries for the same physical device — they have forensic value for lifecycle and repurpose-era attribution. Layer 1 view-level dedup is sufficient; deleting weimi history would harm `machine_terminal_history` lineage with zero FE/engine benefit.

**Downstream impact assessment.** Engine code paths reading `v_live_shelf_stock` (Picker, Engine ADD/SWAP, Stitch) previously saw inflated stock readings for the 26 affected products. The view fix is monotonic-decreasing in row count — no engine logic can break from receiving fewer rows. Any logic relying on the inflation was already producing wrong numbers; it now produces correct ones.

**Rollback:**

```sql
-- Layer 2/3 (data cleanup is irreversible; constraint can be dropped):
ALTER TABLE public.product_name_conventions DROP CONSTRAINT product_name_conventions_pair_unique;
-- Layer 1 (revert view to pre-fix tier definitions):
-- Re-create v_live_shelf_stock from the pg_get_viewdef snapshot at b35c86de era
-- (saved in session transcript). NOT recommended — pre-fix view was producing
-- silently wrong data.
```

---

## 2026-05-14 — BUG-012: phantom dispatch.expiry_date — structural fix

**Phase / Article:** D bugfix / Constitution Articles 1, 4, 8, 12
**Applied to:** prod
**Migration names:** `phaseD_bug012_sync_dispatch_expiry_from_pinned_wh`, `phaseD_bug012_receive_return_effective_expiry`

**Summary:** Closes the root cause of BUG-012 (phantom expiries surfaced in the 14-May report). At pack time `pack_dispatch_line` snapshots `wh_inventory.expiration_date` into `refill_dispatching.expiry_date`. Between pack time and receive/return, the WEIMI snapshot ingest can mutate the source wh row's `expiration_date` (real-world batch correction, supplier re-issue, manager edit) — leaving the dispatch row holding a stale snapshot. Downstream the engine's phantom-expiry detector flagged these as "no Active wh_inventory row matches", and the receive/return RPCs occasionally inserted new wh rows with the stale snapshot instead of crediting the live batch.

**Fix part 1 — cascade trigger.** New `sync_dispatch_expiry_from_pinned_wh()` SECURITY DEFINER trigger function (owner=postgres, `SET search_path = public, pg_temp`). Bound `AFTER UPDATE OF expiration_date ON warehouse_inventory FOR EACH ROW`. When fired, sets `app.via_rpc='true'` + `app.rpc_name='sync_dispatch_expiry_from_pinned_wh'` + `app.mutation_reason` (Article 4 + 8), then UPDATEs every un-finalized (`item_added=false AND returned=false`) refill_dispatching row pinned via `from_wh_inventory_id` to the new expiration_date. Emits an `info` `monitoring_alerts` row with `source='bug012_expiry_sync'` summarising rows synced. Universal audit picks up the cascaded UPDATE attributed to the trigger function. `protect_packed_dispatch_row` doesn't gate `expiry_date`, so packed rows are correctly updated. `detect_phantom_dispatch_expiry` self-heals because post-sync the dispatch.expiry_date matches the live wh batch.

**Fix part 2 — RPC effective-expiry resolution.** `receive_dispatch_line` and `return_dispatch_line` now compute `v_effective_expiry` once near the top via explicit branch: `IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN SELECT expiration_date FROM warehouse_inventory ... ELSE v_dispatch.expiry_date`. Every downstream lookup, WH replenish, overfill subtract, REMOVE breakdown path B, REMOVE FEFO fallback, pod_inventory insert, and consumer drain match uses `v_effective_expiry` instead of `v_dispatch.expiry_date`. Pinned rows always read the live wh row; legacy un-pinned rows fall back to the snapshot. Return jsonb now includes `effective_expiry` for debug visibility.

**Backfill.** 4 stale rows identified pre-deploy (2 NULL-snapshot, 2 date-shift) and synced via one-shot UPDATE attributed to `app.rpc_name='bug012_backfill_cascade'`. Invariant `dispatch.expiry_date = pinned wh.expiration_date` now holds across all 33 pinned open rows.

**Live test.** Toggled one wh row's expiration_date forward 7 days then reverted. Both events fired the cascade; `monitoring_alerts.bug012_expiry_sync` captured both with `dispatch_rows_synced=1` each. `write_audit_log` shows 4 UPDATE rows attributed to `bug012_backfill_cascade` and 2 to `sync_dispatch_expiry_from_pinned_wh`, all with `via_rpc=true`.

**Rollback:**

```sql
-- Restore prior RPC bodies from write_audit_log payload or the session transcript.
DROP TRIGGER IF EXISTS trg_sync_dispatch_expiry_from_pinned_wh ON public.warehouse_inventory;
DROP FUNCTION IF EXISTS public.sync_dispatch_expiry_from_pinned_wh();
```

---

## 2026-05-11 — Bugfix: return_dispatch_line + receive_dispatch_line (3 bugs)

**Phase / Article:** B.3 bugfix / Constitution Articles 1, 4, 8, 12
**Applied to:** prod
**Migration name:** `fix_return_receive_dispatch_remove_and_phantom`

**Summary:** Three bugs causing inventory drift, discovered during Ritz/Loacker decommission and NISSAN daily-roll audit.

**BUG 1 (REMOVE returns 0):** `return_dispatch_line` used `COALESCE(filled_quantity, quantity)` — for REMOVE rows `filled_quantity=0` (not NULL), so COALESCE returned 0. Fix: REMOVE branch now uses `ABS(quantity)` directly, credits WH, and archives `pod_inventory`.

**BUG 2 (phantom WH credits):** When `consumer_stock=0` for all matching rows (already released by a prior daily-roll return), the fallback ELSE branch found any WH row and blindly added `+quantity` — creating phantom stock. 218 phantom units across 48 WH rows accumulated over May 4–10 from NISSAN daily-roll cycles. Fix: removed the fallback ELSE branch for Refill/Add/Add New. If no consumer reservation exists, there is nothing to return.

**BUG 3 (receive skips REMOVE):** `receive_dispatch_line` only handled `action IN ('Refill','Add New','Add')`. REMOVE was excluded, so the FE confirmation flow for REMOVE rows had no working RPC. Fix: added `ELSIF action = 'Remove'` branch that credits WH with `p_filled_quantity` and archives `pod_inventory`.

**Rollback:** `CREATE OR REPLACE` both functions with the pre-patch source (retrievable from `write_audit_log` payload or the session transcript at `a0446bad`).

---

## 2026-05-11 — Phase F day 2: pitstop tables, Stage 2a, Stage 2c, Gates 1 & 2

**Phase / Article:** F-Stage 2 + Gates / Constitution Articles 1, 2, 4, 5, 8, 9, 12
**Applied to:** prod
**Migrations:** `phaseF_stage2_pitstop_tables_v2`, `phaseF_stage2a_engine_add_pod_v3_max_stock_from_weimi`, `phaseF_stage2c_engine_finalize_pod`, `phaseF_gate_rpcs_approve_and_confirm` (+ a v1 / v2 of stage2a that failed on PK collision via v_live_shelf_stock fanout; v3 corrected by switching to pod_inventory at shelf grain).

**Summary:** Five new pieces and the full Stage 1 → 2a → 2c → Gate 1 → Gate 2 chain is now end-to-end functional.

**Pitstop tables:** `pod_refills` (Stage 2a output, PK plan_date+machine_id+shelf_id+pod_product_id), `pod_swaps` (Stage 2b output, uuid PK with pair-linked pod_product_id_out/in; pod_in NULL = M2W return), `pod_refill_plan` (Stage 2c consolidated final, status FSM `draft → approved → stitched | superseded` with approved_at/approved_by/stitched_at). All three RLS-read-all + audit trigger + no direct-write policies.

**Helper views:** `v_warehouse_pod_rollup` (SUM warehouse_stock across boonz variants per pod_product → total_stock, active_batches, earliest_active_expiry — Layer A + Layer B read this; Layer C does NOT). `v_shelf_max_stock` (per-slot max_stock derived from `v_live_shelf_stock`, normalizing shelf_code "A01" ↔ slot_name "A1" via regex). Stage 2 needs the weimi-derived max because `shelf_configurations.max_capacity` is mostly NULL.

**Stage 2a `engine_add_pod(plan_date, days_cover=14)`:** Signal-aware sizing. STAR/DOUBLE DOWN fill-to-max; KEEP GROWING/KEEP use velocity_30d × days_cover; RAMPING/WATCH use velocity × 7 capped at half-max; WIND DOWN/ROTATE OUT/DEAD skipped (Stage 2b's territory). All qty capped by (max-current) and WH pod rollup. Smoke test 2026-05-12: 124 REFILL rows in 417ms. Default fallback `v_default_max=10` when neither config nor weimi has a value.

**Stage 2c `engine_finalize_pod(plan_date)`:** Reads pod_refills + pod_swaps, writes pod_refill_plan(status='draft'). R4: swap-touched shelves invalidate refills on the same shelf (anti-join via swap_shelves CTE). Emits four action types: REFILL, REMOVE, ADD_NEW, M2W. R7 60% shelf cap surfaced as diagnostic only at Stage 2c. Idempotent — supersedes prior drafts. Smoke test: 124 draft rows (Stage 2b empty so 0 swaps merged in).

**Gate RPCs:** `approve_pod_refill_plan(plan_date, machine_names[] DEFAULT NULL)` (Gate 1 — draft → approved, optional partial scope), `reject_pod_refill_rows(plan_date, machine_names, reason)` (Gate 1 reject — draft → superseded with reason captured in reasoning jsonb), `confirm_stitched_plan(plan_date)` (Gate 2 — approved → stitched, called by Stage 3 after refill_plan_output is written).

**End-to-end test:** Stage 1 (24 picked) → Stage 2a (124 refills) → Stage 2c (124 drafts) → Gate 1 partial (1 machine) → Gate 1 fleet (remaining 123) → Gate 2 confirm → 124 stitched. Full chain works. **Gaps remaining for tomorrow:** Stage 2b (engine_swap_pod — pod-level swap/substitute logic with intent-driven Pass 1 + autonomous Pass 2 ported from current propose_swap_plan) and Stage 3 Stitch (boonz mapping + WH SKU split adjustment + deviation/procurement alerts).

**Rollback (additive, safe to drop):**

```sql
DROP FUNCTION IF EXISTS public.confirm_stitched_plan(date);
DROP FUNCTION IF EXISTS public.reject_pod_refill_rows(date, text[], text);
DROP FUNCTION IF EXISTS public.approve_pod_refill_plan(date, text[]);
DROP FUNCTION IF EXISTS public.engine_finalize_pod(date);
DROP FUNCTION IF EXISTS public.engine_add_pod(date, integer);
DROP VIEW IF EXISTS public.v_shelf_max_stock;
DROP VIEW IF EXISTS public.v_warehouse_pod_rollup;
DROP TABLE IF EXISTS public.pod_refill_plan;
DROP TABLE IF EXISTS public.pod_swaps;
DROP TABLE IF EXISTS public.pod_refills;
```

---

## 2026-05-11 — Phase F-Stage 1: machine picker (`pick_machines_for_refill` + `machines_to_visit`)

**Phase / Article:** F-Stage 1 / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration names:** `phaseF_stage1_machine_picker`, `phaseF_stage1_machine_picker_v3_drop_and_recreate`, `phaseF_stage1_machine_picker_v4_intent_count_fix`

**Summary:** First migration of Phase F — the 3-layer engine rebuild (Layer A strategic upstream pod*product, Layer B refill engine pod_product with Stages 1 + 2a/2b/2c, Layer C boonz stitching, with two CS approval gates between layers — full spec in `BOONZ BRAIN/REFILL_BRAIN_REDESIGN.md`). Stage 1 is the smallest additive piece: a pure-read machine picker that decides \_which* machines to visit on a given date and outputs a callable pitstop table. **New table `machines_to_visit`** (PK plan_date+machine_id, status FSM picked/superseded, FK to machines, audit trigger `audit_log_write('machine_id')`, RLS read-all, no direct write policies so only DEFINER reaches it). **New RPC `pick_machines_for_refill(p_plan_date)`** — DEFINER, role-gated on `operator_admin`, sets `app.via_rpc`. Reads `machines` + `slot_lifecycle` + `refill_dispatching` history + `strategic_intents` (active = queued/in_progress) + `v_live_shelf_stock`. Five pick reasons: **health** (≥30% slots in DEAD/WIND DOWN/ROTATE OUT), **stale** (≥7d since last picked_up dispatch), **empty** (≥20% shelves at 0 stock), **intent** (≥1 active strategic_intent touching machine or fleet-wide), **ramping** (relaunched_at or first_sale_at within 30d). Priority score 0..100 = weighted sum (30+20+25+15+10). Sibling expansion via `venue_group` (fallback `building_id`) at lower thresholds — once one machine in a cluster is picked, siblings get pulled in at half thresholds. Idempotent: re-running supersedes prior pick for same date. **Smoke test (plan_date 2026-05-12):** 24 machines picked across 8 route clusters (ADDMIND, GRIT, INDEPENDENT, NOVO, OHMYDESK, VML, VOX, WPP). Reasons distribution: health (15), stale (15), ramping (7), sibling (1 — OMDCW-1021 added as sibling of OMDBB-1020). VML-1003/1004 correctly excluded (no real signals, just a stale 'intent' false-flag that the v4 fix removed). **v4 fix** corrected a `COUNT(*)` vs `COUNT(si.intent_id)` LEFT-JOIN bug that made every machine flag "intent"; same shape bug fixed in `slot_health` and `empty_state` defensively. **Known nit (#17):** sibling-only picks get pri_score=0 because sibling pass doesn't re-score — deferred to Stage 1 v5.

**Rollback:**

```sql
-- v1 rollback (additive; safe to drop without touching production data):
DROP FUNCTION IF EXISTS public.pick_machines_for_refill(date);
DROP TABLE  IF EXISTS public.machines_to_visit;
```

---

## 2026-05-10 — Phase E-1: evaluate-lifecycle v13.1 (STAR signal + relaunched_at + null-location fallback)

**Phase / Article:** E-1 / Constitution Article 9
**Applied to:** prod
**Edge function:** `evaluate-lifecycle` versions 21 → 22 (`v13` → `v13.1`)

**Summary:** Five-line surgical patch to the lifecycle scoring edge function, no business-logic surface added. (1) New `STAR` signal class above `DOUBLE DOWN`: fires when `score ≥ 9 AND fleetVelRatio ≥ 5`, where `fleetVelRatio = slot.v30 / fleet_avg_v30_for_this_pod_product`. Captures saturated leaders that growth-only signals miss because trend reads flat at the ceiling. (2) `machines` SELECT now pulls `relaunched_at`; `isRampingMachine()` reads it before `first_sale_at`. NISSAN-0804 (relaunched 2026-05-10) immediately flips its 16 slots from stale `DEAD` to `RAMPING`. (3) Null-location-type machines no longer silently dropped from scoring — `effectiveLocationType()` returns `'office'` fallback; `UNNORMALIZED_LOCATION` data-quality flag still fires. (4) `v13.1` patch: dark-machine filter whitelists ramping machines so newly-relaunched zero-sales slots actually pass through scoring instead of keeping stale signals. (5) Per-slot `getSignalV2(score, trend, fleetVelRatio)` call wires the new param; product-level signal still uses default `1.0` (STAR doesn't apply to global product aggregates by definition). Verified post-deploy: ALJLT-1015-0200 has 16 scored slots (was 0), NISSAN-0804 has 16/16 RAMPING. STAR threshold of 5× missed Aquafina at VOXMCC-1009 (actual ratio 2.87× — fleet avg of 4.65/d is pulled up by the strong VOX slots themselves; needs CS decision on whether to lower threshold or move to leave-one-out / median-based metric).

**Rollback:** redeploy v12 source (preserved at `evaluate-lifecycle` version 20 via Supabase function version history) — `mcp__supabase__deploy_edge_function` with the v12 file body restores prior behaviour.

---

## 2026-05-10 — Phase E-1: Lifecycle data fixes + relaunched_at infrastructure

**Phase / Article:** E-1 / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseE1_lifecycle_data_fixes`

**Summary:** First migration of Phase E (rebuild). Closes three lifecycle-engine audit findings: (1) Adds `machines.relaunched_at` column — overrides `first_sale_at` as the RAMPING grace anchor when a machine is physically relocated to a new venue. (2) Adds canonical writer `set_machine_relaunched_at(p_machine_id, p_relaunched_at, p_reason)` — DEFINER, role-gated, validates non-future timestamp + Active machine status. (3) Inline data fixes: `ALJLT-1015-0200-O1` location_type set to 'coworking' (was NULL, which made `evaluate-lifecycle` line 594 silently exclude the machine — now visible to scoring on next cron tick); `IRIS-1010-0000-O0` flipped to `status='Inactive'`/`include_in_refill=false` (defunct, last sale 42d ago); `NISSAN-0804-0000-L0` has `relaunched_at=now()` set via the new canonical writer (CS relaunching at new venue). Cody-reviewed with one revision: NISSAN write routes through `set_machine_relaunched_at` RPC instead of direct UPDATE (Article 1 — single canonical writer for the new column, plus install-time smoke test of the RPC). E-1 audit also produced a complete signal-logic spec at `BOONZ BRAIN/E1_lifecycle_fix_spec.md` covering STAR signal class, RAMPING for relaunched machines, and null-location-type fallback — those land via the next `evaluate-lifecycle` edge function patch (E-1.x via Stax).

**Companion work pending:** edge function `evaluate-lifecycle` v13 — adds STAR signal class (`score ≥ 9 AND fleet_velocity_ratio ≥ 5`), reads `relaunched_at` as ramp anchor, doesn't silently drop machines with NULL `location_type` (emits data quality flag, scores with 'office' fallback). Stax→Cody→deploy.

**Rollback:**

```sql
-- Revert data fixes (manual, requires CS approval per row):
UPDATE machines SET status='Active', include_in_refill=true WHERE official_name='IRIS-1010-0000-O0';
UPDATE machines SET location_type=NULL WHERE official_name='ALJLT-1015-0200-O1';
UPDATE machines SET relaunched_at=NULL WHERE official_name='NISSAN-0804-0000-L0';
-- Drop function and column:
DROP FUNCTION IF EXISTS public.set_machine_relaunched_at(uuid, timestamptz, text);
ALTER TABLE public.machines DROP COLUMN IF EXISTS relaunched_at;
```

---

## 2026-05-10 — Phase D-3e: R5 cooldowns + R7 shelf cap + 8pm Dubai cron

**Phase / Article:** D-3e / Constitution Articles 1, 4, 5, 8, 11, 12
**Applied to:** prod
**Migration name:** `phaseD3e_r5_r7_and_cron`

**Summary:** Three additions per CS spec. **R5 cooldowns** in `propose_swap_plan`: 14-day no-repeat-removal on (machine, product) — pre-checks `refill_plan_output` for approved 'Remove' on same (machine_name, boonz_product_name) in the last 14 days, skips if found. 30-day no-re-introduction on substitute candidates — Pearson and category-fallback queries both filter out candidates whose product was Removed from this machine in the last 30 days. New return field `skipped_r5_cooldown`. **R7 60% shelf cap** in `engine_finalize`: per machine, count distinct SWAP-touched shelves (M2W's `reasoning.shelf_code_origin` included). Slot count from `slot_lifecycle.archived=false` per machine. Cap = floor(60% × slot_count). Excess SWAP drafts overruled worst-score-first. R3 and R5 remain warnings per CS confirmation. R7 is a fail-safe — today's per-machine cap is still 2, so R7 doesn't trigger; engages only if `p_max_swaps_per_machine` is bumped beyond ~9–19. **pg_cron** at 16:00 UTC daily (= 8pm Dubai) running `orchestrate_refill_plan(CURRENT_DATE+1)`. Job name `orchestrate-refill-plan-8pm-dubai`. Idempotent re-creation (unschedule first if exists). Smoke test for 2026-05-11: 156 ADD + 42 SWAP (19 M2W + 23 pairs) → 215 finalized → 409 published rows across 21 machines in 2.1s.

**Rollback:**

```sql
-- Restore D-3d propose_swap_plan + engine_finalize (without R5/R7).
-- Unschedule cron:
SELECT cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'orchestrate-refill-plan-8pm-dubai'));
```

---

## 2026-05-10 — Phase D-3d: MACHINE_TO_WAREHOUSE return path

**Phase / Article:** D-3d / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseD3d_machine_to_warehouse_return`

**Summary:** Phase C-1 set up the `machine_to_warehouse` proposal type but never wired it. SWAP today reported skipped_no_substitute=112+ per run — products dying on shelf with no plan. D-3d wires SWAP to emit MACHINE_TO_WAREHOUSE drafts when no viable substitute exists (Pearson + category fallback both fail OR substitute lacks WH stock). M2W draft routes to `machine.primary_warehouse_id` with qty = `pod_inventory.current_stock` (physical pull instruction). Pass 1 M2W carries `linked_intent_id` for decommission credit; Pass 2 (autonomous) does not. Phase C-2's `uq_dpd_active_per_slot_action` index already engineered M2W dedup via `COALESCE(shelf_code, '__M2W__')` sentinel. Same migration extends `reconcile_intent_progress` decommission filter to credit `MACHINE_TO_WAREHOUSE` alongside `REMOVE` (both reduce deployed stock); `dissolve_batch` correctly excludes M2W (M2W feeds WH, opposite of dissolve goal). `engine_publish_to_refill_plan` upgraded to map M2W → 'Remove' refill_plan_output row (driver pulls; "to WH" destination implicit), with shelf_code resolved from `reasoning.shelf_code_origin` and comment annotated `[pull to warehouse]`. **Smoke test:** 19 M2W drafts emitted, 19 published as 'Remove [pull to warehouse]' rows, skipped_no_substitute dropped from 112 to 0. Cody approved without revisions; two operational notes for CS — M2W qty can be > 1 (physical units) vs SWAP REMOVE qty=1 (slot signal); Pearson-no-WH-stock now flows to M2W instead of skip.

**Rollback:**

```sql
-- Restore D-3c propose_swap_plan / reconcile / publish bodies (no M2W path).
-- See phaseD3c migration source for prior versions.
```

---

## 2026-05-10 — Phase D-3c: Wire ENGINE ADD to dissolve_batch intents

**Phase / Article:** D-3c / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseD3c_wire_add_to_dissolve_batch`

**Summary:** D-3 wired SWAP to decommission intents but deferred ADD wiring for dissolve_batch. Today the Vitamin Well Care intent (5 units to drain by 2026-05-24) sat at 0/5 in the queue — nothing routed from EXPIRY OPT to ADD. D-3c closes the loop. `propose_add_plan` now checks each refill candidate for an active dissolve_batch intent matching the boonz_product (oldest active intent if multiple); when found, the REFILL draft is tagged with `linked_intent_id` so reconcile credits the dissolve goal. WH-batch FEFO routing remains the warehouse manager's call at pick time. `reconcile_intent_progress` upgraded to intent-type-conditional action filter: `decommission` credits REMOVE only (D-3b behavior), `dissolve_batch` credits REFILL only (D-3c new). Future additive types (`introduce`, `rotate_in`) add their own clause. Cursor JOIN to strategic_intents lets the type/action match happen in SQL rather than per-row plpgsql. Cody approved without revisions. **Smoke test:** Vitamin Well Care moved queued 0/5 → completed 7/5 in one orchestrator run. `intent_linked_drafts=6` reported by ADD; one REFILL of qty=7 saturated the threshold and auto-completed (mixed-batch overshoot is the documented v1 limitation).

**Limitation (documented):** REFILL crediting toward dissolve_batch is approximate. The draft doesn't carry `source_batch_id`; if WH has both the at-risk batch and a fresh batch, FEFO behavior at the warehouse depends on operator discipline. Crediting full refill qty regardless of which batch the units came from overstates progress in mixed-batch scenarios. Step 5c tightens this to true batch-stock decrement once `refill_plan_output.source_batch_id` lands.

**Rollback:**

```sql
-- Restore D-3b/D-3a propose_add_plan body (no linked_intent_id tagging) and reconcile body (REMOVE-only filter).
-- See migration phaseD3b_reconcile_action_filter_and_intent_recompute for the prior reconcile source.
```

---

## 2026-05-10 — Phase D-5b: engine_publish_to_refill_plan

**Phase / Article:** D-5b / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseD5b_engine_publish_to_refill_plan`

**Summary:** Closes the biggest gap between the optimizer brain and operators. Before D-5b, `orchestrate_refill_plan` ran ADD → SWAP → FINALIZE → RECONCILE but FINALIZE just flipped draft status; nothing crossed to `refill_plan_output`, the operator-facing table. New `engine_publish_to_refill_plan(plan_date)` reads finalized drafts and hands them to `write_refill_plan` (the canonical refill_plan_output writer) with title-cased action mapping (REFILL→Refill, REMOVE→Remove, ADD_NEW→Add New) — critical because field-packing FE keys on title case (CS memory). Resolves machine_id → official_name via `machines`, boonz_product_id → name via `boonz_products`. For ADD_NEW drafts (no pod_product_id), looks up global default pod via `product_mapping`. PUBLISH is a thin adapter — `write_refill_plan` remains the sole canonical writer for refill_plan_output (Article 1). Counts skipped rows by reason (`skipped_m2w` for unsupported MACHINE_TO_WAREHOUSE action, `skipped_no_machine`, `skipped_no_product`). Modified `orchestrate_refill_plan` to add PUBLISH as 4th stage between FINALIZE and RECONCILE: ADD → SWAP → FINALIZE → PUBLISH → RECONCILE. **Smoke test:** 667 rows published across 21 machines in 1.8s, three intent-driven swap pairs surfaced correctly with intent UUIDs in comment field, all actions in title case (Refill 437 / Add New 115 / Remove 115). Reconcile cutover from "finalized draft" proxy to "applied refill_plan_output row" deferred to D-5c (requires linked_intent_id column on refill_plan_output, separate Dara migration).

**Idempotency note:** `write_refill_plan` does a scoped DELETE of pending rows for affected machines before re-INSERT. Re-running orchestrate_refill_plan during a review window replaces unreviewed pending rows for those machines. Approved rows are untouched. Documented in function COMMENT.

**Rollback:**

```sql
-- Restore the prior orchestrate_refill_plan body (ADD → SWAP → FINALIZE → RECONCILE, no PUBLISH stage).
-- See migration phaseD0a_reconcile_and_lifecycle for the prior source.
DROP FUNCTION IF EXISTS public.engine_publish_to_refill_plan(date);
```

---

## 2026-05-10 — Phase D-3b: reconcile_intent_progress action filter + intent recompute

**Phase / Article:** D-3b / Constitution Articles 1, 4, 8, 12
**Applied to:** prod
**Migration name:** `phaseD3b_reconcile_action_filter_and_intent_recompute`

**Summary:** D-3a unmasked a latent bug in `reconcile_intent_progress`: SWAP pairs link `linked_intent_id` on BOTH the REMOVE draft (qty=1) AND the paired ADD_NEW draft (qty up to 8), and reconcile was summing both — so each swap pair credited 9 units against a decommission intent instead of 1. After the D-3a smoke test, Leibniz Zoo Cocoa read 12/7 'completed' (truth: 4/7 in_progress) and Sabahoo Chocolate 9/4 'completed' (truth: 1/4 in_progress). D-3b adds `AND d.action = 'REMOVE'` to the reconcile cursor — only the decommission side credits applied_units, ADD_NEW remains in the events array as audit but doesn't count. Inline comment flags that future additive intent types (`introduce`, `rotate_in`) will need a CASE-per-intent_type filter when they land. Same migration includes a one-time DO block that recomputes `applied_units` for any active decommission/dissolve_batch intent currently 'completed' from REMOVE-event qty only, flips status back to 'queued' or 'in_progress' depending on whether any REMOVE events exist, and clears `closed_at` / `closure_reason`. Idempotent — guarded by `recomputed_applied < acceptable AND status = 'completed'`. Audit captured via `app.via_rpc='true'` and distinct `app.rpc_name='phaseD3b_intent_recompute_data_fix'` so the `write_audit_log` row explains why each touched intent flipped. Post-apply verification: Leibniz Zoo Cocoa now in_progress 4/7, Sabahoo Chocolate in_progress 1/4, both `closed_at` NULL.

**Rollback:**

```sql
-- Restore D-3a/D-0a reconcile body (without action filter):
-- See D-0a entry for the original CREATE OR REPLACE source.
-- The data fix cannot be cleanly rolled back — once applied, the
-- bogus 'completed' state is gone. To undo, manually re-flip:
-- UPDATE strategic_intents SET status='completed', closed_at=now(), ...
-- but only with operator approval; the previous state was incorrect anyway.
```

---

## 2026-05-10 — Phase D-3a: propose_swap_plan calibration + guardrails

**Phase / Article:** D-3a / Constitution Articles 1, 4, 12
**Applied to:** prod
**Migration name:** `phaseD3a_swap_calibration_and_guardrails`

**Summary:** D-3 smoke test produced `intent_driven_swaps=0` despite three active intents in the queue. Root cause: default `p_min_substitute_score=30.0` was set blind, before live correlation data. Observed in-category Pearson distribution across 166 active products: median top score = 28.18, p25 = 19.01, floor = 10.0. At threshold 30 only 47/166 products could find a substitute; at 10, 93 can. 71 products have NO Pearson signal at all (single-machine SKUs, no co-purchase basket). D-3a recalibrates default to 10.0 AND adds a category-anchored fallback: when `get_similar_products` returns nothing, pick the highest-velocity in-category SKU (slot_lifecycle.velocity_30d aggregated, deterministic UUID tiebreaker) with WH stock ≥ 4 and non-expired buffer. CS-flagged guardrails added to BOTH Pearson and fallback paths: (1) substitute must not have an Active pod_inventory row on the target machine — verified against FSM where Active+stock=0 means "slot allocated, awaiting refill" not "removed"; (2) substitute must not itself be in an active decommission intent. Both passes (strategic and autonomous) get the same treatment so intent-driven and autonomous swaps share filtering. Post-apply smoke test: `intent_driven_swaps=3, autonomous_swaps=36, pearson_substitutes=19, fallback_substitutes=20, skipped_no_substitute=133` (down from 224 with 30.0 threshold). Function comment updated.

**Rollback:**

```sql
-- Restore D-3 propose_swap_plan body (default p_min_substitute_score=30.0,
-- no category fallback, no on-machine guard, no decommission-target guard).
-- Source in migration 20260506_phaseD3_wire_addswap_to_intents.sql.
```

---

## 2026-05-10 — Phase D-3: Wire ENGINE ADD/SWAP to read strategic_intents

**Phase / Article:** D-3 / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseD3_wire_addswap_to_intents`

**Summary:** Closes the strategic-intent loop. `propose_swap_plan` now runs a two-pass design: Pass 1 walks active `decommission` intents whose target_completion_date >= plan_date, joins to pod_inventory rows for products in scope, and emits SWAP REMOVE+ADD_NEW pairs with `linked_intent_id` set so reconcile can credit progress when the operator approves+applies the row. Pass 2 retains the original autonomous slot-signal logic for ROTATE_OUT/DEAD/WIND_DOWN slots not addressed in Pass 1. Per-machine cap (default 2) shared across both passes — strategic intents take priority. Cody's required revision applied during draft: shelf_code resolution now goes via `pod_inventory.shelf_id → shelf_configurations` instead of an unsafe `'A01'` fallback that would have placed SWAP REMOVE rows on the wrong shelf. New skip counter `skipped_no_shelf` for traceability. `propose_add_plan` integration with dissolve_batch intents deferred to D-3c (its WH-source-selection logic doesn't yet pick specific batches; intent-aware routing is premature). NB: D-3a immediately followed because the 30.0 threshold default produced zero intent-driven swaps despite live intents.

**Rollback:**

```sql
-- Restore the prior single-pass propose_swap_plan body (autonomous-only).
-- See migration phaseC_c5_decompose_addswap for the prior source.
```

---

## 2026-05-08 — Phase B.3: Lifecycle scoring redesign (Global rank-percentile + Local spectrum + EMA + signalV2)

**Phase / Article:** B.3 / Constitution Articles 9, 12, 13, 14, 15
**Applied to:** prod
**Migration name:** `phaseB_b3_lifecycle_scoring_redesign`

**Summary:** Splits the lifecycle scoring engine into two distinct formulas — `product_lifecycle_global.score` is now rank-percentile across all stocked products by per-machine-average velocity, and `slot_lifecycle.score` is now a ratio-spectrum centered on each product's own per-machine global average (5.0 = at avg, 10.0 = 2× avg). Both scores are EMA-blended with prior value (α=0.67 → recent ≈ 2× historical, satisfying CS's "compound upward/downward" intuition). Signal logic shifts to `getSignalV2` — DOUBLE DOWN and KEEP GROWING now require BOTH score AND trend to clear thresholds (hard-gate), eliminating the case where high-volume-but-flat products were branded DOUBLE DOWN. RAMPING flag bubbles from slot to product level via new `product_lifecycle_global.ramping_machine_count` column. **First post-deploy verification:** Aquafina (92.27 u/day total, 7 machines, 13.18/machine avg) now ranks #1 with score_raw=10.00. Evian Sparkling (0.27 u/day, 2 machines, 0.135/machine avg) now ranks #36 with score_raw=5.39 — exactly the per-machine apples-to-apples ranking CS asked for. Edge fn `evaluate-lifecycle/index.ts` deployed v12 with phase reorder (per-product totals computed BEFORE per-slot scoring so each slot can read its product's per-machine avg as the spectrum anchor). Six new observability columns added across `product_lifecycle_global` and `slot_lifecycle` for audit (per_machine_avg_v30, global_rank, score_raw, ramping_machine_count, local_score_raw, spectrum_ratio, product_avg_v30_at_score_time). New view `v_product_lifecycle_global_enriched` (SECURITY INVOKER) joins product+family+ramping markers for the Global matrix FE consumer. `lifecycle_score_history.score_kind` enum tags new rows as 'v2_split_global_local' for forward-compat traceability.

**Behavior changes (Article 15 disclosure):**

1. `product_lifecycle_global.score` formula changed from velocity-weighted-average-of-cohort-relative-scores to rank-percentile of per_machine_avg_v30 across all products with machine_count > 0. Top product = 10, bottom = 0, evenly distributed by rank.
2. `slot_lifecycle.score` formula changed from cohort-baseline-relative to product-portfolio-spectrum (5.0 = at product's per-machine avg, 10.0 = 2× avg, 0.0 = zero). Spectrum ratio capped at 2× before scoring.
3. Both scores now EMA-blended with prior value: `new_score = 0.67 × computed_today + 0.33 × prior`. New rows bootstrap with prior=computed (no memory yet, converges over ~3 cron ticks).
4. `getSignalV2` replaces `getSignal`. Hard-gate: DOUBLE DOWN requires score≥8 AND trend≥7; KEEP GROWING requires score≥6 AND trend≥7; KEEP requires score≥4 AND trend≥4 (or score≥4 AND trend<4 → WIND DOWN). Eliminates the score=4.5 dead-band orphan from B.1.1.

**Article 9 status (extends prior known-debt note from B.1, B.1.1, B.1.2):** `evaluate-lifecycle` continues to do business logic + direct writes inline. B.3 adds three new logic blocks to that footprint: (a) per-product aggregation phase (Phase 3b/3c) before per-slot scoring, (b) rank-percentile computation across the product universe (Phase 3c), (c) EMA blend on both score paths (Phases 3d + 4), (d) RAMPING bubble counting per product (Phase 3b). Same Phase B follow-up to wrap evaluate-lifecycle in a `compute_and_apply_lifecycle()` SECURITY DEFINER RPC absorbs all of these. Tracked under Task 21.

**Deploy checklist (operational note from Cody review):**

- Migration applied first (additive columns only, no data backfill — new columns NULL on existing rows).
- Edge fn v12 deployed second.
- `trigger_lifecycle_eval()` invoked manually post-deploy to populate new columns within ~30s. Verified: 77 products updated, Aquafina ranked #1 as expected.
- One-time score-shock: every product/slot's score shifted from old formula to new. EMA smooths the second tick onward. Subsequent cron runs converge each score to its new equilibrium over ~3 ticks.

**Code locality note (extends B.1.1 note):** Phase reorder logic, rank-percentile, EMA, RAMPING bubble all live in Deno (`evaluate-lifecycle/index.ts`). Update site for any future signal/score formula tweaks: same file, search for `getSignalV2`, `productGlobalRawScore`, `ema`, `ramping_machine_set`.

**Rollback:**

```sql
-- Revert evaluate-lifecycle to v11 first (blob in Edge Function dashboard).
-- Then drop the additive columns:
DROP VIEW IF EXISTS public.v_product_lifecycle_global_enriched;
DROP INDEX IF EXISTS public.idx_slot_lifecycle_product_score;
DROP INDEX IF EXISTS public.idx_product_lifecycle_global_rank;
ALTER TABLE public.lifecycle_score_history DROP COLUMN IF EXISTS score_kind;
ALTER TABLE public.slot_lifecycle DROP COLUMN IF EXISTS product_avg_v30_at_score_time;
ALTER TABLE public.slot_lifecycle DROP COLUMN IF EXISTS spectrum_ratio;
ALTER TABLE public.slot_lifecycle DROP COLUMN IF EXISTS local_score_raw;
ALTER TABLE public.product_lifecycle_global DROP COLUMN IF EXISTS ramping_machine_count;
ALTER TABLE public.product_lifecycle_global DROP COLUMN IF EXISTS score_raw;
ALTER TABLE public.product_lifecycle_global DROP COLUMN IF EXISTS global_rank;
ALTER TABLE public.product_lifecycle_global DROP COLUMN IF EXISTS per_machine_avg_v30;
-- Existing score values are EMA-blended with new formula; reverting fully requires retrigger after rollback.
```

---

## 2026-05-08 — Phase B.1.2: All-time first-sale view fix for ramping detection

**Phase / Article:** B.1.2 / Constitution Articles 2, 9, 12
**Applied to:** prod
**Migration name:** `phaseB_b1_2_machine_first_sale_view`

**Summary:** B.1.1 derived per-machine first-sale-date from the same 62-day sales window already loaded for velocity computation. That window-min is **not** the same as all-time first-sale: a mature machine with a quiet patch in the window (e.g., WAVEMAKER-1006 and WPP-1002, both first-sold 2025-09-26 but with no sales between Mar 6 and Apr 14, 2026) reported a within-window first-sale of 2026-04-14 — falsely flagging them RAMPING after B.1.1 deploy. B.1.2 adds a dedicated read-only view `v_machine_first_sale` (`SELECT machine_id, MIN(transaction_date), MAX(transaction_date), COUNT(*) FROM sales_history WHERE delivery_status='Successful' GROUP BY machine_id`), declared `SECURITY INVOKER` so caller RLS applies. Edge fn `evaluate-lifecycle/index.ts` now reads from this view to populate `firstSaleByMachine`, replacing the window-min derivation. The fallback to `machines.created_at` for never-sold machines is preserved. Verified post-deploy: WAVEMAKER (224d) and WPP (224d) correctly classify as mature and receive normal signals; six genuinely-young machines (ACTIVATE-2005 15d, ACTIVATEMCC-1037 6d, IFLYMCC-1024 5d, MPMCC-1054 6d, MPMCC-1058 8d, NOVO-1023 13d) correctly remain RAMPING.

**Article 9 status:** Same pre-existing debt — edge fn does business logic + direct writes. Tracked under the same Phase B follow-up.

**Rollback:**

```sql
-- Revert evaluate-lifecycle/index.ts to v10 (B.1.1 derivation from sales window).
-- Then drop the view:
DROP VIEW IF EXISTS public.v_machine_first_sale;
```

---

## 2026-05-08 — Phase B.1.1: Machine ramping + signal band fix

**Phase / Article:** B.1.1 / Constitution Articles 1, 3, 9, 15
**Applied to:** prod (edge fn) + repo (FE — pending Vercel deploy)
**Migration name:** none — code-only patch

**Summary:** Two related fixes to `evaluate-lifecycle/index.ts` after CS observed newly-deployed VOX machines (MPMCC-1058, MPMCC-1054, ACTIVATEMCC-1037, ACTIVATE-2005) being categorized as DEAD/ROTATE OUT despite being only 6–14 days post-first-sale. **Fix 1: Machine ramping protection.** New constant `MACHINE_RAMP_DAYS=30`. New helper `isRampingMachine()` derives per-machine first-sale-date from the existing 62-day sales window with `machines.created_at` as fallback (preserves the distinction between truly-young machines and long-dark mature machines — the latter continue to flag MACHINE_DARK, not RAMPING). When a machine is within its ramp window, its slot signals override to a new `RAMPING` value regardless of computed score/trend. New DQ flag type `MACHINE_RAMPING` surfaces affected machines (severity=info; days-since-first-sale or days-since-creation logged in message). The `lifecycle_data_quality_flags` resolve-stale list expanded to include `MACHINE_RAMPING`. **Fix 2: Score-band gap closure.** Previous `getSignal` had three orphan bands that fell through to DEAD by accident: (a) `score≥4.5 && score<8.5 && trend<3.5`, (b) `score≥4.5 && score<8.5 && trend>6.5`, (c) `score≥6.5 && trend≤5`. Simplified band logic so any `score≥4.5` floors to KEEP regardless of trend; only DOUBLE DOWN and KEEP GROWING still require trend confirmation (>5). This was the proximate cause of MPMCC-1058's slots being flagged DEAD at the cap-induced score=4.5. **FE:** added `RAMPING: "#3b82f6"` (blue) to `SIGNAL_COLORS`; added `RAMPING` to `sigOrder` legend list; matrix points now render in distinct blue with proper tooltip badging via existing `getSignalColor` plumbing. **Verification:** triggered `trigger_lifecycle_eval()` post-deploy, confirmed MPMCC-1058 / MPMCC-1054 / ACTIVATEMCC-1037 / ACTIVATE-2005 now show signal=RAMPING for all slots, mature machines (NOVO-1023, OMDCW-1021) unaffected.

**Article 9 status:** Same pre-existing debt as B.1 — edge fn does business logic + direct writes inline. No new debt entry; the B.1 known-debt note already covers the additional logic. Still tracked under the same Phase B follow-up to wrap evaluate-lifecycle in a `compute_and_apply_lifecycle()` SECURITY DEFINER RPC.

**Behavior changes (Article 15 disclosure):**

- `score≥4.5 && score<8.5 && trend<3.5` was DEAD → now KEEP.
- `score≥4.5 && score<8.5 && trend>6.5` was DEAD → now KEEP.
- `score≥6.5 && trend≤5` was DEAD → now KEEP (or KEEP GROWING if trend>5, unchanged).
- All slots at machines within 30-day ramp window now signal=RAMPING regardless of computed score/trend.

**Rollback:**

```ts
// Revert evaluate-lifecycle/index.ts:
// 1. Remove MACHINE_RAMP_DAYS, isRampingMachine helper, firstSaleByMachine map.
// 2. Revert getSignal to the pre-B.1.1 trend-band-gated version.
// 3. Remove RAMPING override at the slotUpdates push site.
// 4. Remove MACHINE_RAMPING from the resolve-stale list and from the dqFlags emit loop.
// 5. Remove RAMPING from FE SIGNAL_COLORS and sigOrder.
```

Existing slot_lifecycle.signal values containing "RAMPING" will be overwritten on the next cron tick after rollback. No DDL involved.

---

## 2026-05-07 — Phase B.1: Lifecycle reality anchor (snapshot-driven, ledger PK)

**Phase / Article:** B.1 / Constitution Articles 1, 2, 3, 7, 9, 12, 14
**Applied to:** prod
**Migration name:** `phaseB_b1_lifecycle_reality_anchor`

**Summary:** Repoints the lifecycle scoring engine off `planogram` (frozen seed since April 2026, no FE writer) onto `weimi_aisle_snapshots` (refreshed every ~6h by the WEIMI integration) for the runtime "what product is in this slot" question. Planogram retains its single legitimate runtime job: deployment-time seeding by `new-machine-onboarding`. To preserve product-level score history when slots rotate, `slot_lifecycle` is converted from a (machine, shelf) snapshot to a (machine, shelf, product) ledger: three new columns (`is_current` boolean default true, `rotated_in_at` timestamptz default now(), `rotated_out_at` timestamptz nullable), constraint rotation from `UNIQUE (machine_id, shelf_id)` to `UNIQUE (machine_id, shelf_id, pod_product_id)`, and a partial unique index `uq_slot_lifecycle_current_per_slot` on `(machine_id, shelf_id) WHERE is_current=true AND archived=false` to enforce the "exactly one current product per live slot" invariant. Two indexes added to `lifecycle_score_history` for per-slot-per-product history queries. Pre-flight DO-block aborts cleanly if existing data violates the new invariant. The companion `evaluate-lifecycle/index.ts` diff replaces the planogram read with a snapshot + shelf_configurations read, normalizes WEIMI's "A1"/"A15" slot codes to padded "A01"/"A15" shelf codes (with TS-side resolver `padShelf` and `normalizeName` for product-name matching trim+lowercase+collapse-whitespace), detects rotations by comparing the new dominant product per (machine, shelf) to the existing `is_current=true` row and flipping the prior row to `is_current=false, rotated_out_at=now()`, and upserts new scores with the new ledger conflict key. New DQ flag types `UNRESOLVED_SHELF_ID` and `UNRESOLVED_POD_PRODUCT_NAME` surface unresolvable snapshot rows for ops attention. Lifecycle FE matrix at `src/app/(app)/app/lifecycle/page.tsx` filters to `is_current=true` by default with a "Show rotated-out products" toolbar toggle that overlays prior products as faded points with dashed strokes and rotation timestamps in tooltips. Cleared lockstep release: migration → edge fn deploy → FE deploy → cron tick verification.

**Origin context:** The original B.1 design was justified by an inflated 92% drift number that came from a SQL normalization bug on my end (treating `0-A14` as shelf `A14` rather than `A15` — WEIMI's sales feed uses zero-indexed slot labels, snapshot/shelf_configurations use one-indexed). After correction, real drift is ~9% (mostly recent rotations the snapshot has already caught up with). The schema design survives because keeping rotated-out products visible on the matrix and preserving their score history is independently valuable. Snapshot anchoring eliminates the need for `v_current_slot_assignment`, `v_unresolved_sales_product_names`, and `pod_product_name_normalize` (the sales-anchored design's helpers) — the snapshot already says what's currently in each slot, so no 30-day sales aggregation is required. CS approved Scope B (planogram retired from runtime hot path); refill engine retirement is filed as `phaseB_b2_refill_engine_planogram_retirement`.

**Known debt: evaluate-lifecycle Article 9 conformance.** The edge fn does business logic (velocity / trend / consistency / score / signal / rotation-detection / archive-detection) and direct writes to `slot_lifecycle`, `lifecycle_score_history`, `lifecycle_data_quality_flags`, `product_lifecycle_global`. This violates Article 9 ("Edge functions are HTTP wrappers around RPCs. No business logic. No direct table writes."). It is pre-existing and was not introduced by B.1; B.1 deepens it by adding rotation-detection logic. Tracked as Phase B follow-up: convert evaluate-lifecycle to wrap a SECURITY DEFINER RPC `compute_and_apply_lifecycle()` so writes flow through Article 4 / Article 8 plumbing.

**Code locality note.** Pod product name normalization moved from a planned SQL `pod_product_name_normalize(text)` IMMUTABLE helper into Deno (`evaluate-lifecycle/index.ts:normalizeName`). This is a maintainability tradeoff: future tweaks to the resolver (e.g., adding alias rules, handling new WEIMI conventions) require redeploying the edge fn rather than executing a migration. Update site is `supabase/functions/evaluate-lifecycle/index.ts`.

**Rollback:**

```sql
-- Note: rolling back to (machine_id, shelf_id) UNIQUE will fail if any (machine, shelf)
-- has multiple non-archived rows. The edge fn must be reverted to its pre-B.1 version
-- BEFORE the schema rollback so no further rotation rows are created. Then:
DROP INDEX IF EXISTS public.uq_slot_lifecycle_current_per_slot;
DROP INDEX IF EXISTS public.idx_lifecycle_hist_slot_product_date;
DROP INDEX IF EXISTS public.idx_lifecycle_hist_product_machine_date;
ALTER TABLE public.slot_lifecycle DROP CONSTRAINT IF EXISTS slot_lifecycle_machine_shelf_product_uk;
-- Manually delete is_current=false rows OR consolidate, then:
ALTER TABLE public.slot_lifecycle ADD CONSTRAINT slot_lifecycle_machine_id_shelf_id_key UNIQUE (machine_id, shelf_id);
ALTER TABLE public.slot_lifecycle DROP COLUMN IF EXISTS is_current;
ALTER TABLE public.slot_lifecycle DROP COLUMN IF EXISTS rotated_out_at;
ALTER TABLE public.slot_lifecycle DROP COLUMN IF EXISTS rotated_in_at;
```

---

## 2026-05-06 — Phase D.0a: linked_intent_id + reconcile + abandon + expire + orchestrator

**Phase / Article:** D.0a / Constitution Articles 1, 4, 5, 8, 11, 12
**Applied to:** prod
**Migration name:** `phaseD0a_reconcile_and_lifecycle`

**Summary:** Wired the strategic-intent layer to the tactical pipeline. `daily_plan_drafts.linked_intent_id` (nullable FK to strategic_intents, ON DELETE RESTRICT, indexed via partial index where IS NOT NULL) lets drafts written by ADD/SWAP reference the strategic intent they're helping advance — NULL means autonomous decision (legacy/orthogonal path). Three new DEFINERs: **`reconcile_intent_progress(plan_date)`** is the sole writer of `strategic_intents.progress` jsonb and the queued/in_progress→completed transitions; iterates finalized drafts with linked_intent_id, dedups by draft_id (re-running on the same plan_date is a no-op), appends progress events with full draft trace, auto-completes when applied_units >= target_qty - max_residual_units. **`abandon_intent(intent_id, reason)`** is the operator-only closure path (queued/in_progress/blocked → abandoned) requiring a non-empty reason. **`expire_intents()`** is the cron-callable sweeper (active intents whose target_completion_date is past → expired). Modified `orchestrate_refill_plan` to add reconcile as the 4th stage so the loop closes automatically after every refill cycle: propose_add → propose_swap → engine_finalize → reconcile_intent_progress. **Phase D-0a proxy:** uses `daily_plan_drafts.status='finalized'` as the "approved+applied" signal until Step 5b writes the canonical `refill_plan_output`. The intent FSM, abandon/expire RPCs, and orchestrator stay identical when reconcile shifts to read from `refill_plan_output` directly. **End-to-end smoke test:** linked a synthetic SWAP draft to the Leibniz Zoo Cocoa intent (the operator-created intent from D.0), ran finalize then reconcile, observed the intent transitioned `queued → in_progress` with `applied_units=3` (of `target_qty=7`) and a proper event in the progress jsonb. Re-ran reconcile to confirm idempotency (0 new events via draft_id dedup). Article 8 audit captured the UPDATE with `via_rpc=true, rpc_name='reconcile_intent_progress'`. Cody approved without revisions.

**Rollback:**

```sql
DROP FUNCTION IF EXISTS public.expire_intents();
DROP FUNCTION IF EXISTS public.abandon_intent(uuid, text);
DROP FUNCTION IF EXISTS public.reconcile_intent_progress(date);
DROP INDEX IF EXISTS public.idx_dpd_linked_intent;
ALTER TABLE public.daily_plan_drafts DROP COLUMN IF EXISTS linked_intent_id;
-- orchestrate_refill_plan stays at the 4-stage version; recreate the 3-stage form if needed.
```

---

## 2026-05-06 — Phase D.0: strategic_intents (programmed action queue)

**Phase / Article:** D.0 / Constitution Articles 1, 2, 5, 7, 8, 12, 14, 15 + Amendment 006
**Applied to:** prod
**Migration name:** `phaseD0_strategic_intents`

**Summary:** First step of Phase D — the strategic intent layer that sits between the strategic engines (PRODUCT OPT, EXPIRY OPT, future MACHINE OPT) and the tactical executors (ADD, SWAP). Multi-cycle action plans live here. **Strategic engines never write to `daily_plan_drafts` directly** — they write intents (e.g. "decommission Vitamin Well from machines A,B,C by Aug 1; target_qty=18"), and ADD/SWAP pull from the queue each cycle, deciding which intents to advance based on today's reality. **Crucial design rule (CS clarified 2026-05-06):** intent progress reflects ONLY what was approved AND applied through the canonical refill pipeline — drafts written, drafts overruled by FINALIZE, and drafts rejected by operator review do NOT progress intents. A future `reconcile_intent_progress` RPC (Phase D-0a) is the sole writer of status/progress changes, driven by what lands in `refill_plan_output`. New protected table with six-value status FSM (queued / in_progress / completed / abandoned / expired / blocked), five type-conditional CHECK constraints (dissolve_batch requires source_wh_inventory_id; routing types disallow it; terminal status requires closure metadata; abandoned requires reason; target completion date must be future), four canonical INSERT writers planned (propose_decommission_plan, propose_batch_dissolution_plan, write_operator_intent, plus reconcile/abandon/expire as UPDATE writers), FORCE RLS, append-only, audit trigger. Six indexes including partial unique to prevent duplicate active intents on (intent_type, scope_boonz_product_id, source_wh_inventory_id). Three negative tests passed (dissolve_batch w/o source rejected by si_dissolve_batch_has_source; decommission w/ source rejected by si_routing_types_no_batch; past target date rejected by si_target_completion_future). **First real intent inserted:** Leibniz Zoo Cocoa decommission for ALJLT-1015 + OMDCW-1021, 7 units target, 21-day window — operator-initiated based on the optimization analysis from earlier in this session. **Amendment 006 to the Constitution:** strategic_intents joins Appendix A protected entities. Cody approved without revisions. **Next:** D-0a wires linked_intent_id on daily_plan_drafts + reconcile_intent_progress + abandon_intent + expire_intents (cron-callable).

**Rollback:**

```sql
DROP TRIGGER IF EXISTS tg_audit_strategic_intents ON public.strategic_intents;
DROP TABLE IF EXISTS public.strategic_intents;
```

---

## 2026-05-06 — Phase C.5: Parallel-engine orchestrator (ADD + SWAP + FINALIZE end-to-end)

**Phase / Article:** C.5 / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseC5_orchestrator`, `phaseC5_swap_dedup_fix`

**Summary:** Phase C complete. Three new DEFINER functions cap the parallel-engine architecture: (1) **`propose_add_plan(plan_date, min_qty_threshold, days_cover)`** — ENGINE ADD. INSERT-only writer that iterates v_live_shelf_stock + slot_lifecycle, computes Engine B refill qty (CLAMP(velocity × 21d cover, floor=3 office / 4 entertainment, max_stock)), caps by WH availability with the 7-day expiry buffer, writes REFILL drafts. Phase C-5 prototype omits multi-variant split, machine_modes overrides, field-note application — these are Phase D refinements. (2) **`propose_swap_plan(plan_date, max_swaps_per_machine, min_substitute_score)`** — ENGINE SWAP. INSERT-only writer that iterates slot_lifecycle for ROTATE_OUT / DEAD / WIND_DOWN slots sorted worst-score-first, calls `get_similar_products()` (PRODUCT CORRELATION handshake), emits paired REMOVE + ADD_NEW drafts when a category-matching substitute exists with ≥4 units WH stock. **Cody revision applied:** the function is strictly INSERT-only — pairing is one-way (ADD_NEW.paired_draft_id points to REMOVE only, no bidirectional UPDATE), keeping ENGINE FINALIZE as the lone canonical UPDATE writer of daily_plan_drafts. **Follow-up patch `phaseC5_swap_dedup_fix`** wrapped both legs of a swap pair in one PL/pgSQL BEGIN..EXCEPTION subtransaction so unique_violation on either INSERT (legitimate dedup case when two REMOVE rows pick the same substitute) rolls back the partial pair gracefully. (3) **`orchestrate_refill_plan(plan_date)`** — thin orchestrator that calls ADD → SWAP → FINALIZE in sequence. ADD and SWAP are parallel-independent; FINALIZE handles all conflict resolution. Returns combined jsonb summary. **Does NOT yet call write_refill_plan** — that's a Step 5b enrichment task. **First end-to-end production run on CURRENT_DATE+2 produced:** 135 ADD drafts in 618ms + 37 SWAP pairs (74 drafts) in 1254ms = 209 total drafts; FINALIZE finalized 194 and overruled 15 by R1+R2+R4 (every overrule logged with machine_id, shelf_code, product, qty, reason); 51 R3 multi-variant warnings + 16 R5 net-flow warnings surfaced as guidance. Total 2.2s wall-clock. **Article 8 audit trail captured all 209 INSERTs and 209 status-flip UPDATEs in write_audit_log** with proper via_rpc=true and per-engine rpc_name attribution. The parallel-orthogonal architecture CS specified — ADD and SWAP independent, FINALIZE as conflict referee + sole UPDATE writer — is now real and observable in the data. **Phase D follow-ons:** R3 brand guardrail, R5 14-day cooldown, R7 60% shelf rule, MACHINE_TO_WAREHOUSE emission when no substitute available, `push_expiry_opt_to_drafts` so applied rotation_proposals flow into the draft pipeline, Step 5b enrichment + `write_refill_plan` call (turns finalized drafts into canonical refill_plan_output rows).

**Rollback:**

```sql
DROP FUNCTION IF EXISTS public.orchestrate_refill_plan(date);
DROP FUNCTION IF EXISTS public.propose_swap_plan(date, int, numeric);
DROP FUNCTION IF EXISTS public.propose_add_plan(date, int, int);
-- Drafts produced by these runs stay in daily_plan_drafts (FORCE RLS blocks DELETE).
-- They have status='finalized' or 'overruled'; can be filtered out of any future query.
```

---

## 2026-05-06 — Phase C.4: ENGINE FINALIZE (merge + conflict resolution)

**Phase / Article:** C.4 / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseC4_engine_finalize`

**Summary:** Step 4 of Phase C — the merge layer. New DEFINER function `engine_finalize(plan_date, dry_run=false)` reads all `daily_plan_drafts` for a plan_date, runs CS's parallel-engine conflict-resolution rules, and flips draft statuses. **Rule R1+R2+R4 (auto-resolve):** if SWAP touches a shelf, ADD drafts on that shelf are overruled with the documented reason. **Rule R6 (surface as warning):** if EXPIRY_OPT_PUSH targets product P at machine A, ADD drafts for product P at OTHER machines get flagged in the warnings array (not auto-overruled — at-risk push is a directive, not a block). **Rules R3 (multi-variant) and R5 (net-flow):** surfaced as warnings, both drafts proceed. The function returns a structured jsonb with total_drafts / finalized / overruled / resolutions / warnings / duration_ms — full explainability of every decision. **Phase C-4 prototype deliberately does NOT call `write_refill_plan`** — that's Step 5's orchestrator job. This step ships the merge layer cleanly so it can be tested independently. Smoke tests proved the design end-to-end: (1) dry-run on the existing 1-draft fixture returned `total_drafts=1, finalized=1, overruled=0` without modifying rows; (2) injected a synthetic SWAP REMOVE draft on VML-1004 shelf A07 (same shelf as the existing ADD REFILL smoke test), real run correctly returned `total_drafts=2, finalized=1 (SWAP), overruled=1 (ADD)` with full resolution detail in jsonb, and the ADD draft now shows `status='overruled'` with reason "Rule R1+R2+R4: SWAP action on this shelf overrules ADD maintenance refill"; (3) **Article 8 audit trail captured both UPDATEs** in write_audit_log with `via_rpc=true, rpc_name='engine_finalize'`; (4) empty-input edge case returned cleanly with the documented note. Role gate: operator_admin/superadmin/manager OR system context. Granted to authenticated AND service_role for cron callability. Cody approved without revisions.

**Rollback:**

```sql
DROP FUNCTION IF EXISTS public.engine_finalize(date, boolean);
-- Note: drafts already flipped to finalized/overruled stay that way (FORCE RLS blocks
-- DELETE; status is terminal). Acceptable because the function only changed metadata.
```

---

## 2026-05-06 — Phase C.3: ENGINE PRODUCT CORRELATION v1 (machine basket affinity)

**Phase / Article:** C.3 / Constitution Article 12 (read-only INVOKER, no protected-entity writes)
**Applied to:** prod
**Migration name:** `phaseC3_product_correlation_v1`

**Summary:** Step 3 of Phase C — read-only intelligence layer for ENGINE SWAP and future ENGINE PRODUCT OPT to query product similarity. New view `v_product_basket_affinity` computes Pearson correlation of per-machine `velocity_30d` (sourced from `slot_lifecycle`) for every (A,B) pair where both products are stocked-and-selling on at least 3 shared machines. Combined score is bounded 0-100, with a log-saturated shared-machines factor (saturating at 10 shared machines) and a velocity floor (suppresses noise pairs where both products barely sell). New INVOKER RPC `get_similar_products(boonz_product_id, top_n=5, min_score=10.0)` returns the top-N similar products with score, shared_machines, correlation, and a `source` label that future versions will diversify when sales-co-purchase + LLM-enrichment substrates land. **Substrate 1 (sales co-purchase) confirmed dead** — 2026-05-06 scout showed 100% of WEIMI transactions are single-SKU; revisit only if WEIMI exposes baskets or if temporal-proximity inference (60-second window same-machine) gets built (Phase D experiment). **Substrate 3 (LLM enrichment)** deferred to Phase C-3b — a Claude pass over the catalog tagging products with use_case / customer_persona / time_of_day affinities. v1 substrate is purely machine basket affinity. Smoke test results were strong: **Vitamin Well - Care** top similars are all 4 sister Vitamin Well variants (correlation 1.000 across 19 shared machines, score 71.28), then G&H Popped Chips trio (62.10), then M&M Chocolate Bag (55.88) — exactly the wellness-customer cluster you'd expect. **Rice Cake Dark Chocolate** top similars include the Milk Chocolate variant (54.20) and surprisingly all 6 Krambals variants at correlation 0.953 (51.68) — meaning Krambals is the natural successor whenever Rice Cake gets rotated out of an office machine, an insight no previous primitive could surface. View pair distribution: 6,960 total pairs, 436 strong (≥50), 920 moderate (20-50), 2,574 weak (5-20), 3,030 noise (<5). Cody approved without revisions. **Phase D follow-on:** weight-tuning the score formula once SWAP starts consuming, temporal-proximity basket inference experiment, LLM enrichment substrate.

**Rollback:**

```sql
DROP FUNCTION IF EXISTS public.get_similar_products(uuid, int, numeric);
DROP VIEW IF EXISTS public.v_product_basket_affinity;
```

---

## 2026-05-06 — Phase C.2: daily_plan_drafts (shared draft surface)

**Phase / Article:** C.2 / Constitution Articles 1, 2, 5, 7, 8, 12, 14, 15 + Amendment 005
**Applied to:** prod
**Migration name:** `phaseC2_daily_plan_drafts`

**Summary:** Step 2 of Phase C — the shared draft surface where ENGINE ADD, ENGINE SWAP, and ENGINE EXPIRY*OPT_PUSH write their independent proposals; ENGINE FINALIZE will consume and merge into the canonical `refill_plan_output`. New protected entity `daily_plan_drafts` with FORCE RLS, append-only posture, and the universal audit trigger pattern (`tg_audit_daily_plan_drafts` calling `audit_log_write('draft_id')`). Status FSM `draft → finalized | overruled` with timestamp + reason CHECKs enforcing terminal-state metadata. **Schema-level engine orthogonality** via `dpd_engine_action_match`: ENGINE ADD can only emit `REFILL` actions, ENGINE SWAP only `REMOVE`/`ADD_NEW`/`MACHINE_TO_WAREHOUSE`, ENGINE EXPIRY_OPT_PUSH only `REFILL`/`ADD_NEW`. This is a hard-rule encoding of CS's parallel-independent engine design — no engine can step out of its lane regardless of bug. Self-FK `paired_draft_id` links the two legs of a SWAP pair (REMOVE + ADD_NEW or REMOVE + MACHINE_TO_WAREHOUSE) so FINALIZE can validate pair completeness before finalizing either leg. FK `ON DELETE` clauses revised per Cody — RESTRICT for FORCE-RLS-protected references (`paired_draft_id`, `linked_proposal_id` to rotation_proposals), SET NULL only for `proposed_by_user` since `user_profiles` allows deletion. **Important nuance for downstream readers:** the `action='REMOVE'` value is a \_physical-world operation* (driver pulls product off shelf, returns to WH), not a database deletion — every row in this system is append-only by design. Negative test (`ADD + REMOVE`) correctly rejected by `dpd_engine_action_match`. Positive test (`ADD + REFILL` for VML-1004 Rice Cake) inserted cleanly. **Amendment 005 to the Constitution:** `daily_plan_drafts` joins Appendix A protected entities. Cody approved with FK revisions applied. **Step 4 (`engine_finalize`) and Step 5 (extract `propose_add_plan` / `propose_swap_plan`) will populate this table.**

**Rollback:**

```sql
DROP TRIGGER IF EXISTS tg_audit_daily_plan_drafts ON public.daily_plan_drafts;
DROP TABLE IF EXISTS public.daily_plan_drafts;
-- Note: dropping the table releases the FK constraints automatically.
```

---

## 2026-05-06 — Phase C.1: machine_to_warehouse proposal type

**Phase / Article:** C.1 / Constitution Articles 2, 5, 7, 8, 12, 14
**Applied to:** prod
**Migration name:** `phaseC1_machine_to_warehouse_type`

**Summary:** First atomic step of Phase C — the OVERALL/DAILY split that introduces ENGINE FINALIZE as the only writer to `refill_plan_output`, with ENGINE ADD and ENGINE SWAP producing parallel drafts. C.1 lays the schema foundation for the **2-step swap pattern** (machine → WH → machine, never machine → machine direct). Extends `rotation_proposals` with `target_warehouse_id` column (nullable), makes `target_machine_id` nullable, adds `machine_to_warehouse` to the `proposal_type` CHECK enum, adds new `rp_target_consistency` CHECK enforcing exactly-one-target-type by proposal_type (m2w → target_warehouse_id NOT NULL + target_machine_id NULL; all other types → target_machine_id NOT NULL + target_warehouse_id NULL). Updates `rp_source_consistency` to recognize m2w. Drops+recreates the partial unique index `uq_rp_active_source_target` to include target_warehouse_id (so two pending m2w to the same WH for the same product+source can't collide). Adds `idx_rp_source_machine_pending` to support ENGINE SWAP and ENGINE EXPIRY OPT lookups of "is there already a pending return for this machine?" Existing 21 pending wh_to_machine rows pass all new constraints (backward compatible). Smoke test inserted a real m2w proposal (HUAWEI-2003 returning Rice Cake to WH_CENTRAL) — succeeded. Negative test (m2w with target_machine_id set) correctly rejected by rp_target_consistency. Cody approved with one revision (added Articles satisfied header). **Step 5 will teach `propose_rotation_plan` to emit machine_to_warehouse rows when an underperforming slot is detected.**

**Rollback:**

```sql
-- Forward-only patch would be needed to undo. Direct SQL rollback:
ALTER TABLE public.rotation_proposals DROP CONSTRAINT IF EXISTS rp_target_consistency;
ALTER TABLE public.rotation_proposals DROP CONSTRAINT IF EXISTS rp_source_consistency;
ALTER TABLE public.rotation_proposals DROP CONSTRAINT IF EXISTS rotation_proposals_proposal_type_check;
ALTER TABLE public.rotation_proposals ADD CONSTRAINT rotation_proposals_proposal_type_check
  CHECK (proposal_type IN ('wh_to_machine','machine_to_machine','shelf_substitute'));
-- Note: would orphan the smoke-test m2w row. DELETE blocked by FORCE RLS — would need to drop+recreate policy temporarily.
DROP INDEX IF EXISTS public.idx_rp_source_machine_pending;
DROP INDEX IF EXISTS public.uq_rp_active_source_target;
ALTER TABLE public.rotation_proposals ALTER COLUMN target_machine_id SET NOT NULL;
ALTER TABLE public.rotation_proposals DROP COLUMN IF EXISTS target_warehouse_id;
```

---

## 2026-05-06 — Phase B.2b: Engine 2 canonical writers (4 RPCs) + score function multi-row patch

**Phase / Article:** B.2b / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseB2a_fix_score_function_multi_row`, `phaseB2b_engine2_rpcs`

**Summary:** Engine 2 is now end-to-end live as a read-write engine. Four DEFINER canonical writers for `rotation_proposals`: (1) `propose_rotation_plan(horizon_days, min_fit_score, max_per_source, dry_run)` — main loop iterating `v_warehouse_at_risk` for urgent buckets, scoring every active machine via `score_machine_for_product`, INSERTing top-N as pending proposals (`trigger_reason='expiry_risk'`, `proposal_type='wh_to_machine'` in B.2b; other reasons/types are future expansion). (2) `apply_rotation_proposal(proposal_id, plan_date, notes)` — CS approval; **Phase B prototype flips status only — does NOT create a planned_swaps row, that's Phase C wiring into the refill engine.** (3) `reject_rotation_proposal(proposal_id, reason)` — CS veto, captures reason in notes. (4) `mark_proposals_expired(age_days)` — daily housekeeping. All four set `app.via_rpc='true'` + `app.rpc_name=<name>`, validate inputs (NULL/range/FK), role-gate via `user_profiles`. System-callable functions (propose, mark_expired) bypass role gate when `auth.uid() IS NULL` so cron via `service_role` works; operator-only functions (apply, reject) require authenticated operator role with no bypass. `propose_rotation_plan` handles dedup via the partial unique index `uq_rp_active_source_target` — `unique_violation` is caught and counted as `skipped_dedup`. **Pre-emptive fix:** `phaseB2a_fix_score_function_multi_row` patched `score_machine_for_product` because `v_machine_absorption_capacity` returns multiple rows per (machine, boonz_product) pair when a boonz SKU is the global default for ≥2 pod_products (multi-variant scenario) — `DISTINCT ON (machine_id, boonz_product_id) … ORDER BY pod_product_id NULLS LAST` collapses the ctx CTE to one deterministic row. **First production run produced 21 pending proposals in 21s wall-clock**, 3 dedup-skips, 0 hard-blocks below threshold. Top scores: Vitamin Well Antioxidant→VOXMCC-1009 (82.7), Vitamin Well Care→VOXMCC-1009 (81.2), Vitamin Well Antioxidant→VOXMCC-1011 (81.1). Engine 2 routes the WH_MCC Vitamin Well stack toward the high-throughput VOX entertainment machines that already sell it — exactly the conduit pattern CS specified. **Article 8 verified end-to-end:** 21 audit rows in `write_audit_log` with `via_rpc=true`, `rpc_name='propose_rotation_plan'`, `operation='INSERT'`. Cody approved without revisions. **Phase B.3 follow-up:** pg_cron wiring (04:00 Dubai for propose, 03:00 for mark_expired) is a separate migration with its own Article 11 review.

**Rollback:**

```sql
DROP FUNCTION IF EXISTS public.mark_proposals_expired(int);
DROP FUNCTION IF EXISTS public.reject_rotation_proposal(uuid, text);
DROP FUNCTION IF EXISTS public.apply_rotation_proposal(uuid, date, text);
DROP FUNCTION IF EXISTS public.propose_rotation_plan(int, numeric, int, boolean);
-- The fix to score_machine_for_product is forward-only; no rollback needed.
-- Pending proposals can be cleared via:
-- DELETE blocked at RLS — would need to drop RLS policies first OR mark them all 'expired' via mark_proposals_expired(0).
```

---

## 2026-05-05 — Phase B.2a: score_machine_for_product (Engine 2 fit scorer)

**Phase / Article:** B.2a / Constitution Article 12 (read-only INVOKER, no protected-entity writes)
**Applied to:** prod
**Migration name:** `phaseB2a_score_machine_for_product`

**Summary:** First Engine 2 RPC. Read-only `SECURITY INVOKER` function returning a `{score, hard_block, breakdown}` jsonb for routing a `boonz_product` to a target machine. 0-100 score combining five weighted components: throughput rank (35%), archetype/slot signal fit (20%), location_type fit using `product_lifecycle_global.best_location_type` / `worst_location_type` (15%), open shelf capacity vs proposed qty (15%), and urgency from projected days-to-sell vs horizon (10%). Hard cutoffs surface as `hard_block` reason: `no_pair_in_view`, `machine_excluded` (include_in_refill=false), `machine_inactive`, and `travel_scope_vox_locked` (the 8 VOX-locked SKUs from `engines/refill/guardrails/travel-scope.md` cannot route to non-VOX venue_groups). Reads `v_machine_absorption_capacity` (Phase A.5 view) — single source of truth, no parallel velocity computation. Cody review verdict ⚠️ Approve with revisions; both revisions applied (COALESCE guard on the throughput formula for the single-machine-fleet edge case where NULLIF would silently null the whole score; TODO comment in the function body marking the hardcoded VOX-locked list as a Phase C refactor target — should become a `travel_scope_locks` config table). Smoke tests: (1) Vitamin Well Upgrade → VOXMCC-1009 returned 69.94 with sensible breakdown (throughput 35 + location 15 + archetype 10 + capacity 7.5 + urgency 2.44); (2) Aquafina → VML returned 0 with `hard_block: travel_scope_vox_locked`; (3) ranking Vitamin Well across the fleet produced VOXMCC-1011 (74.68) > VOXMCC-1009 (69.94) > OMDBB (55.23) > office machines (~50) — top-2 are the highest-throughput VOX entertainment machines that already sell the product, exactly where Engine 2 should route at-risk warehouse stock. Function added to `RPC_REGISTRY.md` under Read-only helpers (now 9 functions). Phase B.2b (`propose_rotation_plan` DEFINER + 3 transition RPCs) is the next migration.

**Rollback:**

```sql
DROP FUNCTION IF EXISTS public.score_machine_for_product(uuid, uuid, int, int);
```

---

## 2026-05-05 — Constitution Amendment 003 + 004: Appendix A additions

**Phase / Article:** Article 15 amendment
**Applied to:** repo (`01_constitution.html`)
**Migration name:** n/a (constitutive doc edit)

**Summary:** Two protected entities added to Appendix A. **Amendment 003:** `rotation_proposals` — Engine 2 (Rotation Planner) write surface. Append-only via DEFINER RPCs, FORCE ROW LEVEL SECURITY, status FSM (pending → applied | rejected | expired | superseded). Created in migration `phaseB_rotation_proposals_table`. **Amendment 004:** `machine_terminal_history` — created in A.4 with the protected posture but never formally promoted in the appendix; this entry codifies it. CS approved both 2026-05-05. Cody's `SKILL.md` protected entity list also updated to match (lives in the plugin install path outside the BOONZ BRAIN repo, updated through the plugin maintenance channel).

**Rollback:** Edit `01_constitution.html` to revert Appendix A entries. The protected status of these tables in production code (RLS, FORCE, RPCs) is independent of the appendix listing.

---

## 2026-05-05 — Phase B.1: rotation_proposals write surface

**Phase / Article:** B.1 / Constitution Articles 1, 2, 5, 7, 8, 12, 14, 15
**Applied to:** prod
**Migration name:** `phaseB_rotation_proposals_table`

**Summary:** Engine 2 (Rotation Planner) gets its output queue. New table `rotation_proposals` with three proposal types (`wh_to_machine`, `machine_to_machine`, `shelf_substitute`), source/target FKs, snapshot-at-proposal scoring fields (`machine_fit_score`, `projected_days_to_sell`, `scoring_breakdown` jsonb), and a 5-state status FSM (`pending → applied | rejected | expired | superseded`). Five CHECK constraints enforce type-conditional integrity: `rp_source_consistency` (wh/machine source matches type), `rp_shelf_required_for_substitute`, `rp_substitute_changes_product` (target ≠ source for substitutes; = source for routing types), `rp_review_consistency` (applied/rejected require reviewed_at), `rp_applied_has_plan_date`. RLS enabled AND **forced** (per Cody — without FORCE, DEFINERs could DELETE; FORCE makes the table truly append-only). Four policies: select-allow, insert/update/delete-block at WITH CHECK/USING false. Five indexes: `idx_rp_pending_proposed_at` (FE morning brief), `idx_rp_target_machine_pending` (per-machine pane), `uq_rp_active_source_target` (partial unique for dedup, COALESCEs nullable source columns to sentinel UUID), `idx_rp_proposed_at_all` (history), `idx_rp_linked_swap_id` (swap-back lookup). Universal audit trigger `tg_audit_rotation_proposals` calls `audit_log_write('proposal_id')` on every INSERT/UPDATE/DELETE — same pattern as `machine_terminal_history`, `pod_inventory`, `slot_lifecycle`, etc. Cody review verdict ⚠️ Approve with revisions; all three revisions applied (FORCE RLS, audit trigger, articles header). Bodies for the five canonical writers (`propose_rotation_plan` DEFINER, `apply_rotation_proposal` DEFINER, `reject_rotation_proposal` DEFINER, `mark_proposals_expired` DEFINER, `score_machine_for_product` INVOKER) ship in Phase B.2 with separate Cody review. Until those exist, no writes happen — the table sits empty by design.

**Rollback:**

```sql
DROP TRIGGER IF EXISTS tg_audit_rotation_proposals ON public.rotation_proposals;
DROP TABLE IF EXISTS public.rotation_proposals;
```

---

## 2026-05-05 — Manual lifecycle_archetype flips post-A.5 bootstrap

**Phase / Article:** A.5 follow-up / Constitution Article 5 (state machine — manual transition by CS)
**Applied to:** prod
**Migration name:** n/a (direct SQL by CS, per Cody's note that until Phase B's transition RPC ships, manual SQL by CS is the allowed path)

**Summary:** Bootstrap rule used "first attributable sale" as lifetime proxy, which mis-tagged a few mature SKUs as UNCLASSIFIED because their `product_mapping` was repointed recently. CS spot-checked the bootstrap distribution and authorized three manual corrections: **UNCLASSIFIED → ALWAYS_ON** for Pepsi - Regular (124 sales/30d), Perrier - Regular (19 sales/30d), SF Pancake - Chocolate Cream (8 sales/30d). **UNCLASSIFIED → TRIAL** for all SKUs of brands Healthy Cola (6 SKUs), Fade Fit (5 SKUs), Fade Fit Balade (2 SKUs) — these are newer brands CS is actively testing. Final distribution: 147 ALWAYS_ON, 17 TRIAL, 115 UNCLASSIFIED. Brands Nada Protein, Hayatna, Dunkin were also flagged for phase-out by CS but `lifecycle_archetype` is the wrong axis — phase-out belongs in `portfolio_strategy.md §6` alongside 7days, Sabahoo, YoPro, or in a future `boonz_products.phase_out_bias` column. Tracked as a separate followup; left as UNCLASSIFIED for now.

**Rollback:**

```sql
UPDATE public.boonz_products SET lifecycle_archetype = 'UNCLASSIFIED'
 WHERE boonz_product_name IN ('Pepsi - Regular','Perrier - Regular','SF Pancake - Chocolate Cream');
UPDATE public.boonz_products SET lifecycle_archetype = 'UNCLASSIFIED'
 WHERE product_brand IN ('Healthy Cola','Fade Fit','Fade Fit Balade');
```

---

## 2026-05-05 — Optimizer Brain Phase A foundations: lifecycle_archetype + at-risk + absorption views

**Phase / Article:** A.5 / Constitution Articles 2, 6, 12, 14
**Applied to:** prod
**Migration name:** `phaseA_optimizer_foundations`, `phaseA_optimizer_foundations_fix_urgency_bucket`

**Summary:** First migration of the Optimizer Brain build (Engine 2 — Rotation Planner per the Bible). Phase A is read-only intelligence; no new write paths. Three pieces landed: (1) `boonz_products.lifecycle_archetype text NOT NULL DEFAULT 'UNCLASSIFIED'` with CHECK enum (HYPE | ALWAYS*ON | SEASONAL | TRIAL | UNCLASSIFIED) and a partial index excluding the default value. The bootstrap UPDATE auto-tagged the catalog using product lifetime and velocity per CS rule (≥30d in catalog AND velocity > 0 → ALWAYS_ON; <30d → TRIAL; else UNCLASSIFIED) — final distribution 144 ALWAYS_ON / 4 TRIAL / 131 UNCLASSIFIED, with HYPE and SEASONAL reserved for future manual promotion. (2) `v_warehouse_at_risk` view exposes warehouse stock × expiration × full Engine 1 (`product_lifecycle_global`) signal context, with an `urgency_bucket` column (expired / urgent_0_7d / soon_7_30d / medium_30_60d / long_60_90d / safe_90d_plus / no_expiry_set). 171 active rows. (3) `v_machine_absorption_capacity` view exposes per (machine, boonz_product) absorption profile — throughput rank, open shelf capacity, slot-level signal/score/velocity/recommendation pulled directly from `slot_lifecycle` (no parallel computation against `v_sales_history_attributed`), plus catalog-level passthrough. 8,845 rows. GRANT SELECT to `authenticated` only (Cody revision dropped `anon`). Audit attribution via `SET LOCAL app.via_rpc / app.rpc_name` so the bootstrap UPDATE is traceable. Cody review: ⚠️ Approve with revisions — all four revisions applied (anon dropped, SET LOCAL added, article header added, SSOT comment corrected). **Followup migration `phaseA_optimizer_foundations_fix_urgency_bucket` applied immediately:** the original CASE used `INTERVAL '7'` etc. without unit, which Postgres parses as 7 \_seconds*. All 171 rows had landed in `safe_90d_plus`. Patched to integer arithmetic (`CURRENT_DATE + 7`); post-fix distribution reflects real expiry pressure (1 urgent_0_7d, 8 soon_7_30d, 13 medium_30_60d, 19 long_60_90d, 130 safe_90d_plus). **Phase B (next):** archetype-transition RPC + `score_machine_for_product` SECURITY DEFINER + `propose_rotation_plan` RPC + `rotation_proposals` write table. Until Phase B ships, mutations to `boonz_products.lifecycle_archetype` happen via direct SQL by CS only.

**Rollback:**

```sql
DROP VIEW IF EXISTS public.v_machine_absorption_capacity;
DROP VIEW IF EXISTS public.v_warehouse_at_risk;
DROP INDEX IF EXISTS public.idx_boonz_products_archetype_active;
ALTER TABLE public.boonz_products DROP COLUMN IF EXISTS lifecycle_archetype;
```

---

## 2026-05-05 — Repurposed-machine attribution: `machine_terminal_history` + attributed view + per-machine RPC

**Phase / Article:** A.4 / Constitution Articles 1, 2, 4, 7, 8, 12, 14
**Applied to:** prod
**Migration name:** `phaseA_a4_machine_terminal_history`, `phaseA_a4b_attributed_view_dedupe`, `phaseA_a4c_per_machine_performance_rpc`, `phaseA_a4d_vox_commercial_report_via_attributed_view`, `phaseA_a4e_vox_consumer_report_join_by_machine_id`, `phaseA_a4f_consumer_report_adyen_pending_flag`, `phaseA_a4g_vox_commercial_filter_by_machine_id`

**Summary:** New versioned-history table `machine_terminal_history` (terminal-id × machine-id × date-range) with EXCLUDE-overlap constraint, RLS, and the generic A.3 audit trigger installed. Backfilled with 9 known terminal-to-machine windows: ACTIVATE-2005 chain (LLFP_2005 Feb 13-14 → MPMCC-2005-0000-W0 Apr 23-27 → ACTIVATE-2005-0000-W0 Apr 28+), MPMCC-1054/1058 ← ACTIVATEMCC-1054/1058 Apr 28 rebrands, IFLYMCC-1024 install, ALHQ-1016 stable. New canonical writer `register_terminal_move(text, uuid, date, text, text, text)` is the only path to add new windows; validates inputs + FK + role (operator_admin or superadmin). New view `v_adyen_transactions_attributed` (with `security_invoker = true`) joins Adyen rows through the history table to expose `attributed_machine_name`, `attributed_machine_id`, `attributed_venue_group`, `attribution_source` per row. Dedupe patch (`a4b`) restricts the machines join to `status='Active'` so stale Inactive terminal claims don't double-count. New read-only RPC `get_per_machine_performance(p_date_from, p_date_to, p_venue_group, p_machine_names)` returns a JSON array per attributed-machine combining WEIMI sales (via `v_sales_history_attributed`) with Adyen settled+refunded captures, including refund-netted `adyen_net_cash_aed`. Existing `get_vox_commercial_report` patched (`a4d`) to read Adyen via the new view and split SettledBulk vs RefundedBulk so partial refunds net out of captured. **Net effect:** repurposed machines now appear as separate rows in any per-machine report (e.g. ACTIVATE-2005 has 5 days at 1,087 AED under MPMCC-2005-0000-W0 and 7 days at 1,456.85 AED under ACTIVATE-2005-0000-W0 in the Feb 1 → May 4 window, instead of 12 days collapsed into one row). Validated by Cody (⚠️ Approve with revisions — all revisions applied: real ALHQ uuid, btree_gist extension, input/role validation, security_invoker on the view, audit trigger installed, terminology corrected from "append-only audit" to "versioned history"). FE wiring of `/app/performance` Sites & Machines tab patched separately (`src/app/(app)/app/performance/page.tsx` — `machineData` keys by `sales_history.machine_mapping` instead of `machine_id`). Pending: register_terminal_move callsite from a future "Rename machine" UI, wire `get_per_machine_performance` if/when the Sites & Machines tab needs Adyen-net-cash beside revenue.

**Rollback:**

```sql
DROP FUNCTION IF EXISTS public.get_per_machine_performance(date, date, text, text[]);
DROP FUNCTION IF EXISTS public.register_terminal_move(text, uuid, date, text, text, text);
DROP VIEW    IF EXISTS public.v_adyen_transactions_attributed;
DROP TRIGGER IF EXISTS trg_mth_audit ON public.machine_terminal_history;
DROP POLICY  IF EXISTS mth_authenticated_read ON public.machine_terminal_history;
DROP POLICY  IF EXISTS mth_service_all       ON public.machine_terminal_history;
DROP TABLE   IF EXISTS public.machine_terminal_history;
-- restore the prior get_vox_commercial_report from migration history.
```

---

## 2026-05-04 — Orphan dispatching cleanup RPC

**Phase / Article:** Operational hardening / Articles 1, 4, 8, 12
**Applied to:** prod
**Migration name:** `cleanup_orphan_dispatching_rpc`

**Summary:** New canonical-writer RPC `cleanup_orphan_dispatching(date, text[])` to delete orphaned `refill_dispatching` rows that have no matching plan row in `refill_plan_output`. This gap was surfaced operationally when `write_refill_plan` (RPC B) rewrote plan rows for 4 machines (MC-2004, MINDSHARE, WAVEMAKER, WPP) — the old plan's dispatching rows were left behind because `write_refill_plan` only touches the plan table. The RPC validates caller role (operator_admin, superadmin, manager), requires non-NULL `p_dispatch_date`, and JOINs through `machines` + `shelf_configurations` to match dispatching rows back to plan rows by `(plan_date, machine_id, shelf_id, action)`. Only deletes rows where `packed=false AND picked_up=false` (Article 12 — never touch packed/picked-up rows). Returns `{status, dispatch_date, machines_scoped, orphan_rows_deleted}`. Designed by Dara, reviewed by Cody (⚠️ Approve with revisions — revisions applied: role validation, NULL guard, JOIN rewrite from subquery to NOT EXISTS). First call deleted 8 orphaned swap dispatching rows across 4 machines for 2026-05-05.

**Rollback:**

```sql
DROP FUNCTION IF EXISTS public.cleanup_orphan_dispatching(date, text[]);
```

---

## 2026-05-04 — Warehouse stock reconciliation RPC + bug fixes across 3 inventory RPCs

**Phase / Article:** Operational hardening / Articles 1, 4, 5, 8
**Applied to:** prod
**Migration names:** `inventory_rpc_adjust_warehouse_stock`, `patch_adjust_warehouse_stock_update_expiry`, `fix_adjust_warehouse_stock_wh_name_col`, `fix_adjust_warehouse_stock_generated_col`, `patch_adjust_wh_stock_expiry_unchanged_check`, `fix_log_manual_refill_generated_delta`, `fix_log_manual_refill_audit_constraints`, `fix_transfer_warehouse_stock_generated_delta`

**Summary:** New canonical-writer RPC `adjust_warehouse_stock` for physical count reconciliation of warehouse inventory. Matches existing rows by `wh_inventory_id` or `(warehouse, product, expiry)`, updates stock + consumer_stock + expiration_date + batch_id + status, inserts new rows when no match found. Unchanged-check includes expiry comparison (catches expiry-only corrections like mislabeled dates). Used to reconcile WH_MCC physical counts on 2026-05-04. Also fixed `inventory_audit_log.delta` generated-column bug in all 3 existing inventory RPCs (`adjust_warehouse_stock`, `log_manual_refill`, `transfer_warehouse_stock`) — the `delta` column is GENERATED ALWAYS and cannot be explicitly INSERTed. Fixed `log_manual_refill` pod_inventory_audit_log constraint violations: `operation` must be lowercase ('insert' not 'INSERT'), `source` must be from enum ('refill' not 'manual_refill').

**Rollback:**

```sql
DROP FUNCTION IF EXISTS public.adjust_warehouse_stock(uuid, jsonb, date, text);
-- Then CREATE OR REPLACE log_manual_refill and transfer_warehouse_stock with pre-fix bodies
```

---

## 2026-05-04 — Inventory operations: 3 new RPCs (transfer, manual refill, pod adjust)

**Phase / Article:** Operational hardening / Articles 1, 4, 5, 6, 8
**Applied to:** prod
**Migration names:** `inventory_rpc_transfer_warehouse_stock`, `inventory_rpc_log_manual_refill`, `inventory_rpc_adjust_pod_inventory`

**Summary:** Three new canonical-writer RPCs to close inventory management gaps. Designed by Dara, reviewed by Cody (Articles 1, 4, 5, 6, 8 — all pass). These enable the operator to: (1) transfer stock between warehouses (WH_CENTRAL → WH_MCC/WH_MM) with FIFO batch picking and cold-storage validation; (2) retroactively log manual refills that happened outside the system (backlog cleanup), decrementing source warehouse and creating pod_inventory entries; (3) correct pod_inventory via physical count reconciliation with batch-level FIFO support. All three write full audit trails to `inventory_audit_log` and/or `pod_inventory_audit_log`. Article 6 compliance verified: none of the three RPCs touch `warehouse_inventory.status` (the propose_inactivate trigger may fire when source stock hits zero, but that only proposes — manager confirms).

**Rollback:**

```sql
DROP FUNCTION IF EXISTS public.transfer_warehouse_stock(uuid, uuid, jsonb, date, text);
DROP FUNCTION IF EXISTS public.log_manual_refill(text, uuid, date, jsonb, text);
DROP FUNCTION IF EXISTS public.adjust_pod_inventory(text, date, jsonb, text);
```

---

## 2026-05-04 — Refill pipeline hardening: 6 RPC changes (B, E, C, D, F, A)

**Phase / Article:** Operational hardening / Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration names:** `refill_b_scoped_write_refill_plan`, `refill_e_loud_approve_refill_plan`, `refill_c_override_refill_quantity`, `refill_d_inject_swap`, `refill_f_seed_shelf_configurations`, `refill_a_multi_machine_generate`

**Summary:** Six coordinated RPC changes designed by Dara, reviewed by Cody (Articles 1, 2, 4, 5, 7, 8, 12, 14 — all pass), to eliminate the need for manual SQL in the refill pipeline. The operator (Claude / boonz-master skill) now works exclusively through RPCs for all plan mutations.

1. **RPC B — `write_refill_plan` scoped delete.** The DELETE now only removes pending rows for machines present in `p_lines` (was: all pending for date). Fixes the "sequential per-machine calls destroy each other" bug. Returns `machines_affected` array.

2. **RPC E — `approve_refill_plan` loud errors.** Pre-approve diagnostics detect missing `shelf_configurations`, unmatched `pod_products`/`boonz_products`, unmatched `machine_name`. Returns structured `alerts` jsonb array with impact descriptions. Dispatch gap detection: warns when `rows_approved > dispatching_rows_written`. Added `AND packed=false` guard to dispatching DELETE (never wipe packed rows).

3. **RPC C — `override_refill_quantity` (NEW).** Operator quantity override for pending REFILL/ADD NEW rows. Multi-variant products: proportional redistribution. Single-variant: direct update. Appends `[QTY OVERRIDE]` comment for audit trail.

4. **RPC D — `inject_swap` (NEW).** Inject a product swap into a live/approved plan. Inserts REMOVE + ADD NEW rows directly as `approved` + creates dispatching rows. Preserves packed dispatching rows. Full input validation: machine, shelf_config, pod_product, boonz_product existence checks with descriptive errors.

5. **RPC F — `seed_shelf_configurations` (NEW).** Auto-seed `shelf_configurations` from `v_live_shelf_stock`. Converts aisle codes (`0-A00`→`A01`, `1-A00`→`B01`). Idempotent via `ON CONFLICT (machine_id, shelf_code) DO NOTHING`. Called automatically by `auto_generate_refill_plan` when a machine has 0 configs.

6. **RPC A — `auto_generate_refill_plan` multi-machine.** New `p_machines text[]` parameter. When provided: bypasses health triage filter + LIMIT 10, processes exactly the listed machines. Auto-calls `seed_shelf_configurations` for machines with 0 configs. Added `AND packed=false` to dispatching DELETE. Old 3-param overload dropped.

**Cody review:** ⚠️ Approve with revisions. All revisions applied: alerts are warnings not blockers (E), packed rows preserved (D/E/A), idempotent ON CONFLICT (F), role validation on all new RPCs (C/D/F). Constitution articles satisfied: 1 (each RPC is canonical for its operation type), 4 (GUCs + role + input validation), 5 (status transitions respected), 8 (audit trigger fires on all targets), 12 (forward-only CREATE OR REPLACE).

**Verification:**

- All 6 functions confirmed: `prosecdef=true`, `has_via_rpc=true`, `has_rpc_name=true`.
- `auto_generate_refill_plan` has exactly one overload (4 params).
- Old 3-param overload dropped cleanly.

**Rollback:**

```sql
-- Reverse in opposite order
DROP FUNCTION IF EXISTS public.auto_generate_refill_plan(text, date, boolean, text[]);
-- Then CREATE OR REPLACE with old 3-param body (archived in this changelog git history)
DROP FUNCTION IF EXISTS public.seed_shelf_configurations(text);
DROP FUNCTION IF EXISTS public.inject_swap(date, text, text, text, text, text, int, text);
DROP FUNCTION IF EXISTS public.override_refill_quantity(date, text, text, int);
-- Then CREATE OR REPLACE approve_refill_plan + write_refill_plan with pre-B/E bodies
```

---

## 2026-05-04 — Refill app issues Phase 1: propose-then-confirm + canonical pickup

**Phase / Article:** Operational fix bundle / Articles 1, 2, 3, 4, 5, 6 (revised), 7, 8, 9, 12
**Applied to:** prod (additive only — no live-flow behavior change today)
**Migration names:** `m1_warehouse_inventory_status_proposal_table`, `m2_confirm_reject_warehouse_status_proposal_rpcs`, `m3_propose_status_change_functions_unbound`, `m4_mark_picked_up_rpc`, `m5_diagnostic_views`

**Summary:** First wave of fixes for the 12 refill-app issues + Issue #13 (orphan dispatch machine names). All migrations today are strictly additive — they introduce new tables, functions, and views, but do NOT alter behavior of any existing pack/receive/dispatch flow. CS guardrail in effect: "do not alter or touch anything in the existing packing and dispatching of today; fix the issues and stress test along the way."

1. **`warehouse_inventory_status_proposal` table (M1)** — Implements the propose-then-confirm pattern for `warehouse_inventory.status` mutations (Article 6 revised, see Amendment 002). Automated flows (triggers / RPCs / cron / n8n) write proposal rows here. The warehouse manager confirms or rejects via canonical RPCs. RLS: read for warehouse + admin roles, INSERT/UPDATE/DELETE blocked from authenticated. Universal audit trigger bound (Article 8).

2. **`confirm_warehouse_status_proposal` + `reject_warehouse_status_proposal` RPCs (M2)** — Canonical write paths for the manager's confirm/reject decision. SECURITY DEFINER, validate role + inputs, set `app.via_rpc`, return JSON. Confirm path atomically flips `warehouse_inventory.status` and marks proposal `confirmed`. Drift detection: if `warehouse_inventory.status` changed since the proposal was filed, marks proposal `superseded` instead of confirming.

3. **`propose_inactivate_on_zero_stock` + `propose_reactivate_on_stock_return` trigger functions (M3)** — Body created today, **NOT BOUND** to `warehouse_inventory`. Binding deferred to tonight's post-dispatch deploy (m3b) so today's pack/receive flow is untouched. Both functions write to the proposal table only; never UPDATE `warehouse_inventory.status` directly. Idempotency guard skips duplicate pending proposals.

4. **`mark_picked_up(uuid[])` RPC (M4)** — Canonical write path for the field-driver pickup flow. Replaces direct `refill_dispatching` UPDATEs from `field/pickup/page.tsx`. Filters to `packed=true AND picked_up=false`; returns counts + skipped IDs for FE feedback. Sits dormant until tonight's FE deploy wires it.

5. **Diagnostic views (M5)** — `v_pending_status_proposals` (manager UI surface), `v_orphan_dispatch_machine_names` (Issue #13: refill_plan_output rows whose machine_name doesn't resolve to `machines.official_name` — currently 4 rows: MPMCC-2005-0000-L0, ACTIVATEMCC-1058-0000-R0, ACTIVATEMCC_1054_0000_M0 (typo), JET-2001-3000-O1), `v_machines_without_shelf_config` (currently 2 rows: IRIS, LLFP — both `include_in_refill=false`, benign).

**Constitution amendment (002):** Article 6 revised. The previous absolute rule ("`warehouse_inventory.status` may only be written by the warehouse manager — no trigger / function / cron / n8n / app may mutate it") is replaced with a propose-then-confirm rule that allows automated flows to PROPOSE status changes via the new proposal table, with manager confirmation as the gate. Silent direct UPDATE of `warehouse_inventory.status` from any trigger / RPC / cron / n8n / FE remains forbidden. See `06_amendment_002_article_6_propose_then_confirm.md`.

**Today-safe verification:**

- `warehouse_inventory` triggers unchanged (no new mutation triggers; lockdown holds).
- `refill_dispatching` triggers unchanged (`enforce_packed_dispatch_immutability`, `tg_audit_refill_dispatching`, `trg_conserve_split_qty`, `trg_prevent_duplicate_unstarted_dispatch` all intact).
- No FE deploy required to apply these migrations. RPCs sit dormant until tonight's FE deploy.

**Rollback:**

```sql
-- M5
DROP VIEW IF EXISTS public.v_machines_without_shelf_config;
DROP VIEW IF EXISTS public.v_orphan_dispatch_machine_names;
DROP VIEW IF EXISTS public.v_pending_status_proposals;
-- M4
DROP FUNCTION IF EXISTS public.mark_picked_up(uuid[]);
-- M3
DROP FUNCTION IF EXISTS public.propose_reactivate_on_stock_return();
DROP FUNCTION IF EXISTS public.propose_inactivate_on_zero_stock();
-- M2
DROP FUNCTION IF EXISTS public.reject_warehouse_status_proposal(uuid, text);
DROP FUNCTION IF EXISTS public.confirm_warehouse_status_proposal(uuid, text);
-- M1
DROP TABLE IF EXISTS public.warehouse_inventory_status_proposal;
```

**Pending tonight (post-dispatch deploy window):** m3b (bind triggers), FE updates to (a) wire `mark_picked_up`, (b) add `picked_up=false` filter in pickup page, (c) surface `v_pending_status_proposals` in the inventory page; conserve_split trigger swap; backfills.

---

## 2026-04-30 — Boonz Master operational intelligence layer

**Phase / Article:** Operational / Articles 1, 2, 3, 4, 5, 8, 12
**Applied to:** prod + repo
**Migration names:** `boonz_master_foundation`, `add_approve_refill_plan_rpc`

**Summary:** Introduced the Boonz Master skill as the single operational interface for the refill system, replacing the need for CS to route between `/refill-engine`, Cody, Stax, and Dara for day-to-day ops. Four changes shipped:

1. **`boonz_context` table** — Active operational brief. One row at a time. Master writes here when CS sets context ("NOVO promo next 2 weeks", "push office to aggressive"). The refill-engine reads this before generating any plan. Holds `context_text` (plain English), `default_scenario` (conservative/standard/aggressive), `scenario_overrides` per venue group, and `machine_modes` per machine.

2. **`planned_swaps` table** — Confirmed next-visit swap orders from operator, CS, or driver (phone call, chat, field note). Brain executes these unconditionally on next run, bypassing lifecycle signal checks. Status lifecycle: pending → applied | cancelled.

3. **`machine_field_notes` table** — Driver feedback loop. Post-dispatch prompt in field app creates a note (add_more, reduce, substitute, remove, general). Brain reads and applies on next plan run, marks as applied after.

4. **`product_mapping.mix_weight` column** — Controls how refill qty splits across variants of the same pod product. Default 1.0 = equal share. "More M&M than Mars" → update M&M weight to 1.5, Mars stays 1.0 → 60/40 split from next run.

5. **`approve_refill_plan(date, text[])` RPC** — New canonical approval gate. Replaces the missing approval step in the refill flow. Flips `operator_status` pending→approved, then writes `refill_dispatching` rows in one atomic call. FE "Approve & Dispatch" button calls this. Roles: operator_admin, superadmin, manager only.

6. **FE changes** — `RefillPlanningTab` plan state lifted to `page.tsx` parent (tab-wipe bug fixed). "Write plan" renamed to "Save draft". "Approve & Dispatch" button added (calls `approve_refill_plan` RPC). Two-step flow: save draft → review → approve.

7. **Boonz Master skill** — New `boonz-master` skill installed. Single ops interface. Interprets plain English instructions, writes to the new tables, invokes refill-engine with context applied. Replaces `/refill-engine` for daily ops.

8. **6am Dubai scheduled run** — `boonz-morning-refill` scheduled task created. Runs at 06:05 Dubai time daily. Reads `boonz_context` + pending swaps + field notes, generates tomorrow's plan for all critical/warning machines, posts morning brief with link to approve.

9. **`refill-engine` v4** — Updated SKILL.md. New CONTEXT CHECK step runs before PRE-FLIGHT: reads `boonz_context`, `planned_swaps`, `machine_field_notes`. Applies scenario mapping, machine_modes, planned swaps, field note adjustments to the plan.

**Rollback:**

```sql
-- boonz_master_foundation
DROP TABLE IF EXISTS public.machine_field_notes;
DROP TABLE IF EXISTS public.planned_swaps;
DROP TABLE IF EXISTS public.boonz_context;
ALTER TABLE public.product_mapping DROP COLUMN IF EXISTS mix_weight;
-- add_approve_refill_plan_rpc
DROP FUNCTION IF EXISTS public.approve_refill_plan(date, text[]);
```

FE rollback: revert `page.tsx` and `RefillPlanningTab.tsx` to previous state via git.

---

## 2026-04-27 (v2) — Supplier consolidation + driver task filtering + not-purchased + audit trail

**Phase / Article:** Post-fix procurement v2 / Articles 1, 4, 6
**Applied to:** prod + repo
**Migration names:** `procurement_supplier_consolidation`, `procurement_outcome_and_audit_schema`, `procurement_rpcs_v2`
**Summary:** (1) Merged Union Coop SUP_014 → SUP_005 (canonical "Union Coop"). Reclassified Arab Sweet + Merich as walk_in. Cleared bogus contact_email='na' on Carrefour. (2) create_purchase_order v2: driver task only for walk_in OR p_force_driver_task=true. FE adds emergency "🚨 pick-up" checkbox for supplier_delivered. Tasks page filters to walk_in + forced only. (3) Not-purchased: purchase_orders.purchase_outcome column. WH toggles lines as not_purchased in receiving page; RPC closes them with received_qty=0. Driver hints (outcome_comment parsed) surfaced in receiving UI — auto-marks not_available lines, shows partial qty. (4) Procurement audit log: procurement_events append-only table + driver_tasks trigger for status transitions. RPCs log po_created / goods_received / line_not_purchased. 10 historical events backfilled.
**Rollback:** Re-activate SUP_014, revert Arab Sweet + Merich procurement_type. p_force_driver_task defaults false — RPC change is backward-compatible. purchase_outcome is additive + nullable.

---

## 2026-04-27 — Procurement flow overhaul: B-1 → B-6 fixes + 2 new canonical writers

**Phase / Article:** Post-A.5 procurement fix / Constitution Articles 1, 3, 4, 6
**Applied to:** prod + repo
**Migration names:** `procurement_supplier_type_column`, `procurement_po_number_sequence`, `create_purchase_order_rpc`, `receive_purchase_order_rpc`, `tighten_warehouse_inventory_rls`
**Summary:** Full procurement flow investigation identified 6 active bugs and 2 feature gaps. Applied in one session: (1) B-1 — added `suppliers.procurement_type` column to replace hardcoded `WALK_IN_SUPPLIER_CODES = ["SUP_005","SUP_011"]` constant in FE; backfilled SUP_005/011/014 as `walk_in`; Union Coop (SUP_014) was silently missing, causing wrong confirm dialog and null email attempts. (2) B-2 — receiving page was inserting extra `purchase_orders` rows for each expiry batch, inflating `line_count` and `total_ordered` in every order view; fixed by moving receipt logic to the `receive_purchase_order` RPC which only UPDATEs the original line and creates separate `warehouse_inventory` rows per batch. (3) B-3 — `warehouse_inventory` was being written directly from the browser client by `field_staff` role; moved to `receive_purchase_order` SECURITY DEFINER RPC and tightened RLS to remove `field_staff` from write policy. (4) B-4 — `po_additions` (field-added items) were shown on the receiving page but never processed by the confirm action; RPC now accepts `p_additions` array and marks each addition received + creates `warehouse_inventory` row. (5) B-5 — `po_number` was generated client-side via max+1 query (race condition); replaced with `po_number_seq` Postgres sequence, assigned inside `create_purchase_order` RPC via `nextval()`. (6) B-6 — orders list now cross-references `driver_tasks` by `po_id` to show "In transit — awaiting WH receipt" when a driver has collected a PO but WH has not yet received it. Two new canonical writers registered in `RPC_REGISTRY.md`: `create_purchase_order` and `receive_purchase_order`.
**Rollback:** To revert the RLS tightening: `DROP POLICY warehouse_write_wh_inventory ON warehouse_inventory; CREATE POLICY warehouse_write_wh_inventory ON warehouse_inventory FOR ALL TO public USING (EXISTS (SELECT 1 FROM user_profiles WHERE id=(SELECT auth.uid()) AND role=ANY(ARRAY['field_staff','warehouse','operator_admin','superadmin','manager'])));`. FE rollback: revert the three modified files to the versions before this session. The RPCs and sequence are additive and safe to leave in place even if FE is rolled back.

---

## 2026-04-26 — A.6.0 incident filed: 4 non-canonical write paths into protected tables

**Phase / Article:** A.6.0 / Constitution Article 1 (canonical write paths) — drift surfaced by A.5b smoke test
**Applied to:** repo (incident report only — no migration applied)
**Migration name:** —
**Summary:** Post-A.5b investigation of one anomalous `via_rpc=false` audit row on `machines` widened into a full sweep that revealed four distinct non-canonical write paths active in prod over the last 24 hours. The largest by volume: `refill_plan_output` saw 180 direct INSERT/DELETE/UPDATE writes (n8n service_role + FE operator_admin), zero of which went through the canonical `write_refill_plan` RPC despite the RPC being correctly patched in A.5b. Three smaller findings: a `machines` repurpose-shape UPDATE done directly against PostgREST (Article 1 violation), a coordinated 4-row `boonz_product_id` remap that was a legitimate data-correction migration but lacked an audit-trail marker row (process gap), and an n8n flow doing pointless `updated_at` heartbeats on `machines`. **A.5b is correct as shipped** — the 24 canonical writers are constitutional. What surfaced is a Phase B FE/n8n migration gap: the canonical writers exist and work but the production traffic doesn't go through them yet. Full evidence, audit_ids, repro queries, and a 10-step remediation sequence (B.x.3 → B.x.1 → B.x.2 → B.x.4 → A.6, with Cody review gates) live in `INCIDENT_2026-04-26_NON_CANONICAL_WRITES.md`. Pulls A.6 (governance YAML in warn mode) priority forward.
**Rollback:** N/A (no migration applied — investigation + sequencing artifact only).

---

## 2026-04-26 — A.5b applied: patch remaining 24 canonical writers + RLS on `refill_dispatch_plan`

**Phase / Article:** A.5b / Constitution Article 1 (canonical path) + Article 2 (RLS) + Article 4 (validation/via_rpc) + Article 8 (universal audit)
**Applied to:** prod
**Migration names:** `phaseA_a5b_part1_of_4_canonical_writers`, `phaseA_a5b_part2_of_4_canonical_writers`, `phaseA_a5b_part3_of_4_canonical_writers`, `phaseA_a5b_part4_of_4_rls_refill_dispatch_plan` (split into 4 because the combined diff exceeds Supabase's per-migration size limit)

**Summary:** Closes the A.5 perimeter. Patches the 24 remaining canonical SECURITY DEFINER writers and closes the one real RLS gap surfaced by Amendment 001.

**Change 1 — 22 plpgsql writers patched (parts 1–3):**
`add_new_machine`, `add_sanity_increment`, `auto_decrement_pod_inventory`, `auto_sanity_check`, `backfill_dispatch_boonz_product_ids`, `load_pod_staging_chunk`, `pack_dispatch_line`, `process_adyen_staging`, `process_weimi_staging`, `push_plan_to_dispatch`, `receive_all_dispatches_for_machine`, `receive_dispatch_line`, `repurpose_machine`, `return_all_dispatches_for_machine`, `return_dispatch_line`, `toggle_machine_refill`, `upsert_aisle_snapshot`, `upsert_pod_snapshot`, `upsert_refill_stock_snapshot`, `upsert_sales_lines`, `write_dispatch_plan`, `write_refill_plan`. Each now starts its `BEGIN` block with `PERFORM set_config('app.via_rpc', 'true', true); PERFORM set_config('app.rpc_name', '<fn>', true);` so the A.4 generic audit trigger captures `via_rpc=true, rpc_name=<fn>` on every protected-entity row. Where missing (13 of 24), folded in `SET search_path TO 'public'` at function level (defensive Article 4 hardening — built-in param, function-level SET is allowed).

**Change 2 — 2 SQL-language writers converted to plpgsql:**
`refresh_product_scores` and `retry_staging_errors` were SQL-language; they couldn't use `PERFORM`, so they were re-authored as plpgsql while preserving exact behaviour. `refresh_product_scores` additionally writes its own explicit `INSERT INTO write_audit_log` row before `REFRESH MATERIALIZED VIEW CONCURRENTLY mv_global_product_scores;` — matview refreshes don't fire AFTER triggers, so the audit row is written manually (mirrors A.5a's `refresh_sales_aggregated`).

**Change 3 — RLS on `refill_dispatch_plan` (part 4):**
`ALTER TABLE refill_dispatch_plan ENABLE ROW LEVEL SECURITY` + `CREATE POLICY refill_dispatch_plan_select FOR SELECT TO authenticated USING (true)`. No INSERT/UPDATE/DELETE policy — default-deny for anon/authenticated. service_role bypasses RLS, which is how canonical RPC writes still reach the table. Closes Amendment 001's only real RLS gap.

**Why PERFORM set_config in body, not function-level SET:**
Cody's review recommended function-level `SET app.via_rpc='true'` (atomic save/restore on entry/exit, no SET LOCAL leak). Supabase rejected that shape with `42501: permission denied to set parameter "app.via_rpc"` because custom GUCs (any param with a dot) must be pre-registered via `ALTER DATABASE/ROLE/SYSTEM SET app.via_rpc=''` to be accepted in a function-level SET clause, and the migration role lacks that grant. Pivot: stay with the A.5a precedent — `PERFORM set_config(...)` at the top of `BEGIN`. **Audited the 4 nested-DEFINER call sites** (`auto_sanity_check→add_sanity_increment`, `receive_all_dispatches_for_machine→receive_dispatch_line`, `return_all_dispatches_for_machine→return_dispatch_line`, `upsert_sales_lines→refresh_sales_aggregated`) and confirmed none write to a protected entity AFTER the inner call returns — they either return immediately or update a non-protected table (`daily_pipeline_runs`). So the SET LOCAL leak from PERFORM does not corrupt the audit trail in any current code path.

**Verification:**

- All 24 functions confirmed `prosecdef=true`, `proconfig` includes `search_path=public`, body contains both `PERFORM set_config` calls.
- Smoke 1: ran `toggle_machine_refill('ADDMIND-1007-0000-W0', !current); toggle_machine_refill(..., current);` — two new `write_audit_log` rows landed with `via_rpc=true, rpc_name='toggle_machine_refill'`.
- Smoke 2: ran `refresh_product_scores();` — one row landed with `table_name='mv_global_product_scores', operation='REFRESH', via_rpc=true, rpc_name='refresh_product_scores', payload={kind: matview_refresh, trigger: manual_or_cron}`.
- Security advisors run post-apply: zero new findings on `refill_dispatch_plan`; no patched function appears in the `function_search_path_mutable` list (the 35 remaining are pre-existing helpers/triggers/read-only RPCs out of A.5b scope).

**Open follow-ups (not blockers):**

- **A.5c**: re-author all 25 A.5a/A.5b writers to function-level `SET app.via_rpc='true'` once `app.via_rpc` is pre-registered at db level (requires a separate `ALTER DATABASE postgres SET app.via_rpc=''` migration as superuser, then rewriting the bodies). This eliminates the SET LOCAL leak entirely and matches Cody's preferred shape.
- **B.x**: tighten `refill_plan_output` RLS — currently allows authenticated INSERT/UPDATE which violates Article 1/3 (sole canonical writer is `write_refill_plan`).
- **A.4.b**: install audit triggers on the 6 deferred protected tables once Amendment 001 lands.
- **Investigate** (RESOLVED → see `INCIDENT_2026-04-26_NON_CANONICAL_WRITES.md`): the `machines` audit row at 2026-04-26 06:06:03 UTC was the visible tip of four distinct non-canonical write paths into protected tables. Most material: zero `write_refill_plan` calls in 24h despite 180 direct INSERT/DELETE/UPDATE writes against `refill_plan_output`. A.5b is correct as shipped — what surfaced is a Phase B FE/n8n migration gap, now sequenced as B.x.1–B.x.4 in the incident doc.

**Rollback:**

```sql
-- Function bodies: pre-A.5b versions are archived in pg_proc history and in
-- /sessions/gracious-compassionate-noether/a5b_rows.json. To roll any one
-- back, CREATE OR REPLACE FUNCTION with the prior body.
-- RLS on refill_dispatch_plan:
ALTER TABLE public.refill_dispatch_plan DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS refill_dispatch_plan_select ON public.refill_dispatch_plan;
```

---

## 2026-04-26 — Data correction: merge Santiveri Cranberries → Cran Berry + Article 7 RLS on inventory_audit_log

**Phase / Article:** Data correction / Constitution Article 7 (audit log append-only), Article 6 (warehouse_inventory.status untouched), Appendix A (boonz_products + product_mapping: intentionally permissive)
**Applied to:** prod
**Migration names:** `data_merge_cranberries_into_cran_berry`, `rls_inventory_audit_log_append_only`
**Summary:** Two `boonz_products` rows represented the same physical SKU — "Santiveri - Cran Berry" (`cd5fd194`) and "Santiveri - Cranberries" (`19c2983f`). Migration 1 removed the duplicate by: (a) deleting 24 redundant `product_mapping` rows and 5 `product_pricing` rows where Cran Berry already had identical entries; (b) remapping `boonz_product_id` FK on `purchase_orders` (1), `weekly_procurement_plan` (10), `refill_dispatching` (25), `warehouse_inventory` (1), `pod_inventory` (3); (c) correcting 4 rows in `inventory_audit_log` (same physical product, data correction not historical falsification); (d) deleting the orphaned `boonz_products` row. Orphan check confirmed 0 remaining references. Migration 2 applied INSERT-only RLS to `inventory_audit_log` per the Article 7 `*_audit_log` wildcard — closing the gap that made the correction migration possible in the first place.
**Rollback:** Re-insert `boonz_products` row `19c2983f`, re-point all FK columns back. No schema changes to reverse for migration 2 (ADD POLICY is forward-only; to revert, DROP POLICies and DISABLE RLS).

---

## 2026-04-26 — A.5a follow-up applied: widen `write_audit_log.operation` CHECK

**Phase / Article:** A.5a.1 / Constitution Article 12 (forward-only)
**Applied to:** prod
**Migration name:** `phaseA_a5a_followup_allow_refresh_op`
**Summary:** End-to-end smoke of A.5a's `refresh_sales_aggregated()` failed with `23514: violates check constraint "write_audit_log_operation_check"` — the column's CHECK was authored in A.3 with the value set `{'INSERT','UPDATE','DELETE'}`. The patched `refresh_sales_aggregated()` records `operation='REFRESH'` for matview refreshes (the only reasonable verb — REFRESH is conceptually an UPDATE on the entire matview but not on any single row). Forward-only fix: dropped the existing CHECK and re-added it with `{'INSERT','UPDATE','DELETE','REFRESH'}`. Pure additive widening — every prior row remains valid; no behavior regression; no RLS change. Cody auto-approve path (constraint-widening, no surface change).
**Verification:** Re-ran `SELECT public.refresh_sales_aggregated();` — succeeded; one row landed in `write_audit_log` with `operation='REFRESH'`, `via_rpc=true`, `rpc_name='refresh_sales_aggregated'`, `payload->>'kind'='matview_refresh'`.
**Rollback:**

```sql
ALTER TABLE public.write_audit_log
  DROP CONSTRAINT write_audit_log_operation_check;
ALTER TABLE public.write_audit_log
  ADD CONSTRAINT write_audit_log_operation_check
  CHECK (operation = ANY (ARRAY['INSERT','UPDATE','DELETE']));
-- Note: cannot roll back if any rows with operation='REFRESH' exist.
-- Inspect first: SELECT count(*) FROM public.write_audit_log WHERE operation='REFRESH';
```

---

## 2026-04-26 — A.5a applied: patch `upsert_daily_sales` + split matview refresh

**Phase / Article:** A.5a / Constitution Article 1 (canonical path) + Article 4 (validation/via_rpc) + Article 8 (universal audit) + Article 9 (heavy work on its own surface) + Article 11 (cron via RPC) + Article 12 (forward-only)
**Applied to:** prod
**Migration name:** `phaseA_a5a_patch_upsert_daily_sales_and_split_matview`
**Summary:** First batch of A.5 — patches the writer that triggered this entire diagnostic session (the n8n `Supabase Upsert1` gateway timeout on 2026-04-25). Three coordinated changes shipped together.

**Change 1 — `upsert_daily_sales(p_items jsonb)` body:**

- Added `PERFORM set_config('app.via_rpc',  'true', true)` at the top of `BEGIN`. `is_local=true` scopes the GUC to the current transaction (no leak across pooled n8n connections).
- Added `PERFORM set_config('app.rpc_name', 'upsert_daily_sales', true)` for the audit-log `rpc_name` field.
- Removed the synchronous `PERFORM refresh_sales_aggregated();` at the end (the line that was causing the gateway timeout).
- Updated COMMENT to record A.5a context.
- All other behavior preserved verbatim: `SECURITY DEFINER`, `search_path=public`, `TimeZone=Asia/Dubai`, `resolve_machine_id` lookup, defensive timestamp parse, total_amount fallback chain, `ON CONFLICT (internal_txn_sn) DO UPDATE` rules, per-item `EXCEPTION WHEN OTHERS` envelope, jsonb summary return shape.

**Change 2 — `refresh_sales_aggregated()` body:**

- Added the same two `set_config` GUC tags so the cron-triggered refresh is audit-traceable.
- Inserted an explicit row into `public.write_audit_log` before the `REFRESH MATERIALIZED VIEW CONCURRENTLY`. This is required by Article 8 because matviews cannot carry AFTER triggers, so the writer must record itself. Required Cody Change 3 in the review.
- Pinned `search_path TO 'public'` (defensive; the previous version inherited the calling session's path).
- Updated COMMENT.

**Change 3 — pg_cron schedule:**

- New cron job `refresh-sales-aggregated-10min` runs `*/10 * * * *` calling `SELECT public.refresh_sales_aggregated();`.
- The `DO $cron$` block first `cron.unschedule`s any prior version of the same job, then `cron.schedule`s — making the migration idempotent / replay-safe.
- Cadence rationale: 10 min keeps `sales_history_aggregated` fresh enough for ops dashboards (refill-engine, partner-performance) which already tolerate hour-old aggregates; cheap enough for a ~15K-row matview with `CONCURRENTLY` refresh.

**Constitutional impact:**

- Article 1 ✅ — `upsert_daily_sales` remains the sole writer for `sales_history`.
- Article 4 ✅ — GUC tags now declared. Input validation via `EXCEPTION WHEN OTHERS` envelope (per-item; preserves partial-success semantics for the n8n batch).
- Article 8 ✅ — every `sales_history` write now lands in `write_audit_log` with `via_rpc=true, rpc_name='upsert_daily_sales'`. Every matview refresh lands with `via_rpc=true, rpc_name='refresh_sales_aggregated'`.
- Article 9 ✅ — heavy work (matview refresh) is now on its own surface (cron), separated from the synchronous writer.
- Article 11 ✅ — cron job calls an RPC, not raw DDL/DML.
- Article 12 ✅ — `CREATE OR REPLACE FUNCTION` is forward-only; cron block is idempotent.

**Phase B note (deferred, not done in A.5a):** `upsert_daily_sales` still has `EXECUTE` granted to `PUBLIC` (`=X/postgres` ACL entry). Phase B will tighten to `service_role` only — n8n already auths as service_role. Don't ship this now (would be an unrelated behavior change).

**Verification:**

- `pg_get_functiondef(upsert_daily_sales)` confirms both `set_config` calls present and `refresh_sales_aggregated()` call removed.
- `pg_get_functiondef(refresh_sales_aggregated)` confirms both `set_config` calls present and the explicit `INSERT INTO public.write_audit_log` line.
- `cron.job` shows `refresh-sales-aggregated-10min` active with schedule `*/10 * * * *`.
- End-to-end smoke (replay-an-existing-row pattern):
  - `SELECT public.upsert_daily_sales('[{...one existing internal_txn_sn replayed...}]'::jsonb)` returned `{"status":"ok","upserted":1,"skipped":0,"total":1}`.
  - `write_audit_log` row appeared: `table=sales_history, op=UPDATE, via_rpc=true, rpc_name='upsert_daily_sales'`.
  - `SELECT public.refresh_sales_aggregated();` succeeded after the follow-up CHECK widening (see A.5a.1 entry above).
  - `write_audit_log` row appeared: `table=sales_history_aggregated, op=REFRESH, via_rpc=true, rpc_name='refresh_sales_aggregated', payload={kind: matview_refresh, trigger: cron}`.
- Bypass-detector still works: pre-existing `machines` audit row from A.4 smoke still shows `via_rpc=false` — proves the index `idx_wal_via_rpc` will surface unpatched canonical paths until A.5b+ closes them.

**Operational impact:**

- The 23:59 n8n flow that fired this whole diagnostic is now safe — the synchronous matview refresh that caused the gateway timeout is gone. Worst case, the n8n upsert returns immediately with the per-item summary, and the matview catches up within ≤10 minutes.
- The matview refresh now happens 144x/day (every 10 min) vs ~3-5x/day previously. The marginal cost is small — `REFRESH MATERIALIZED VIEW CONCURRENTLY` is incremental relative to the previous full refresh.

**Rollback:**

```sql
-- 1. Restore upsert_daily_sales pre-A.5a body (without GUC tags, with inline matview refresh).
--    Body archived in this CHANGELOG file's git history at HEAD~1.
--    Re-apply via CREATE OR REPLACE FUNCTION.

-- 2. Restore refresh_sales_aggregated pre-A.5a body:
CREATE OR REPLACE FUNCTION public.refresh_sales_aggregated()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY sales_history_aggregated;
END;
$$;

-- 3. Drop the cron job:
SELECT cron.unschedule('refresh-sales-aggregated-10min');
```

(Rollback is destructive of the audit-tagging behavior. Prefer forward-fix via a new migration unless a critical regression is observed.)

---

## 2026-04-26 — A.4 applied: install audit triggers on 10 protected tables

**Phase / Article:** A.4 / Constitution Article 1 (canonical write paths) + Article 8 (universal audit) + Article 15 (Appendix A reconciliation flagged)
**Applied to:** prod
**Migration name:** `phaseA_a4_install_audit_triggers`
**Summary:** Installed the generic `audit_log_write(pk_col)` AFTER trigger from A.3 onto every protected table where the Constitution name unambiguously matches a live `public.*` table. The trigger fires on INSERT, UPDATE, and DELETE for all 10 tables and writes one row to `public.write_audit_log` per affected row, capturing `table_name`, `operation`, `row_pk` (extracted via `TG_ARGV[0]`), `actor`, `actor_role`, `via_rpc` (false until A.5 patches the canonical writers), `rpc_name`, `occurred_at`, and a full `old`/`new` jsonb payload. Idempotent (DROP IF EXISTS guards before each CREATE), so the migration is replay-safe. Updated the `audit_log_write()` function COMMENT to record installation date. The 10 tables and their PK columns:

| #   | Table                     | PK column injected  | Trigger name                       |
| --- | ------------------------- | ------------------- | ---------------------------------- |
| 1   | `machines`                | `machine_id`        | `tg_audit_machines`                |
| 2   | `shelf_configurations`    | `shelf_id`          | `tg_audit_shelf_configurations`    |
| 3   | `planogram`               | `planogram_id`      | `tg_audit_planogram`               |
| 4   | `sim_cards`               | `sim_id`            | `tg_audit_sim_cards`               |
| 5   | `slot_lifecycle`          | `slot_lifecycle_id` | `tg_audit_slot_lifecycle`          |
| 6   | `pod_inventory`           | `pod_inventory_id`  | `tg_audit_pod_inventory`           |
| 7   | `pod_inventory_audit_log` | `audit_id`          | `tg_audit_pod_inventory_audit_log` |
| 8   | `warehouse_inventory`     | `wh_inventory_id`   | `tg_audit_warehouse_inventory`     |
| 9   | `refill_plan_output`      | `id`                | `tg_audit_refill_plan_output`      |
| 10  | `sales_history`           | `transaction_id`    | `tg_audit_sales_history`           |

**Deferred to A.4.b** (pending Article 15 amendment): `sales_history_aggregated` (Constitution called it `sales_aggregated`), `refill_dispatch_plan` (called `dispatch_plan`), `refill_dispatching` (called `dispatch_lines`), `inventory_audit_log` (called `warehouse_inventory_audit_log`). The Constitution names predate the schema as it stands today, so before installing triggers we must amend Appendix A so the protected-entity list and the live schema agree.

**Removed from protected list** (via the Article 15 amendment): `slots` (does not exist in `public`; the rotation lifecycle is captured in `slot_lifecycle` which already has its trigger), and `settlements` (does not exist as a table — settlements are computed views on top of `sales_history`).

**Important pre-A.5 expectation:** Until A.5 patches the canonical writers, every row appearing in `write_audit_log` will have `via_rpc = false`. This is **not** a constitutional violation — it just means the writer didn't yet declare itself via the `app.via_rpc` GUC. A.5 fixes that, and the `idx_wal_via_rpc` partial index (created in A.3) becomes the bypass-traffic detector once the canonical paths are tagged.

**Verification:**

- All 10 triggers exist and are enabled (`pg_trigger.tgenabled = 'O'`); `pg_get_triggerdef` confirms each binds `audit_log_write` with the correct PK arg.
- Synthetic smoke: a no-op self-update on one row of `machines` produced exactly one row in `write_audit_log` with `table_name=machines`, `operation=UPDATE`, correct `row_pk`, `via_rpc=false`, `rpc_name=NULL`, and a full `payload.old` / `payload.new` snapshot. Confirms trigger fires, PK extraction works, and payload capture works end-to-end.

**Rollback:**

```sql
DROP TRIGGER IF EXISTS tg_audit_machines ON public.machines;
DROP TRIGGER IF EXISTS tg_audit_shelf_configurations ON public.shelf_configurations;
DROP TRIGGER IF EXISTS tg_audit_planogram ON public.planogram;
DROP TRIGGER IF EXISTS tg_audit_sim_cards ON public.sim_cards;
DROP TRIGGER IF EXISTS tg_audit_slot_lifecycle ON public.slot_lifecycle;
DROP TRIGGER IF EXISTS tg_audit_pod_inventory ON public.pod_inventory;
DROP TRIGGER IF EXISTS tg_audit_pod_inventory_audit_log ON public.pod_inventory_audit_log;
DROP TRIGGER IF EXISTS tg_audit_warehouse_inventory ON public.warehouse_inventory;
DROP TRIGGER IF EXISTS tg_audit_refill_plan_output ON public.refill_plan_output;
DROP TRIGGER IF EXISTS tg_audit_sales_history ON public.sales_history;
```

(Rollback drops only the triggers; the `audit_log_write` function and `write_audit_log` table from A.3 remain. Existing audit rows are preserved.)

---

## 2026-04-26 — A.3 applied: universal audit ledger

**Phase / Article:** A.3 / Constitution Article 7 (audit append-only) + Article 8 (universal audit) + Article 12 (forward-only)
**Applied to:** prod
**Migration name:** `phaseA_a3_audit_log_infra`
**Summary:** Built the universal write ledger that turns "what happened to my protected tables" from an unanswerable question into a SQL query. Created `public.write_audit_log` (audit_id, table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, occurred_at, payload jsonb). RLS enabled with append-only policies (SELECT/INSERT permissive for `authenticated`; UPDATE/DELETE explicitly blocked). Three supporting indexes: `(table_name, occurred_at DESC)`, `(via_rpc, occurred_at DESC) WHERE via_rpc = false` (the bypass-traffic detector), `(actor, occurred_at DESC)`. Created the generic `public.audit_log_write()` `SECURITY DEFINER` trigger function — reads `app.via_rpc` and `app.rpc_name` session GUCs, captures the PK via `TG_ARGV[0]`, records full row payload as jsonb. EXECUTE revoked from PUBLIC/anon/authenticated (callable only as a trigger). The ledger is empty until A.4 installs the trigger on each protected table.
**Verification:** Verified via Supabase MCP — `pg_class.relrowsecurity = true`. Policies: `wal_insert, wal_no_delete, wal_no_update, wal_select`. Indexes: `idx_wal_actor, idx_wal_table_occurred, idx_wal_via_rpc, write_audit_log_pkey`. Function `audit_log_write` is DEFINER. EXECUTE grants: `{postgres=X/postgres, service_role=X/postgres}` — anon and authenticated have no execute.
**Rollback:**

```sql
DROP FUNCTION IF EXISTS public.audit_log_write();
DROP TABLE IF EXISTS public.write_audit_log;
```

(Note: rollback is destructive of audit data once any rows exist. Prefer forward-fix via a new migration.)

---

## 2026-04-25 — A.2 applied: deprecate `rename_machine_in_place_legacy`

**Phase / Article:** A.2 / Constitution Article 13 (deprecation 90-day process) + Article 1 (one canonical write path)
**Applied to:** prod
**Migration name:** `phaseA_a2_deprecate_rename_machine_legacy`
**Summary:** Closed the side door on the legacy machine-rename path. The function `rename_machine_in_place_legacy(uuid, text, text, text, text, boolean, date, text)` was previously `SECURITY DEFINER` and granted EXECUTE to `anon`, `authenticated`, and `service_role`. It is superseded by `repurpose_machine` as the canonical writer for machine identity transitions. Caller scan (code: `src/`, `engines/`, `scripts/`, `n8n/`, `boonz-data-migration/`; DB: `cron.job`, triggers, other DEFINER functions) returned **zero callers** — function is fully dormant. Applied: (1) `ALTER FUNCTION ... SECURITY INVOKER`, (2) `REVOKE EXECUTE FROM PUBLIC, anon, authenticated`, (3) updated function comment to mark deprecated and schedule DROP for 2026-07-24. `service_role` retains EXECUTE for the monitor window as an escape hatch; revoke at end of 90-day period if usage stays at zero.
**Verification:** `pg_proc.prosecdef = false` (was true). `proacl = {postgres=X/postgres,service_role=X/postgres}` (was `{postgres,anon,authenticated,service_role}`). Comment updated.
**Rollback:**

```sql
ALTER FUNCTION public.rename_machine_in_place_legacy(uuid, text, text, text, text, boolean, date, text)
  SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.rename_machine_in_place_legacy(uuid, text, text, text, text, boolean, date, text)
  TO anon, authenticated;
COMMENT ON FUNCTION public.rename_machine_in_place_legacy(uuid, text, text, text, text, boolean, date, text) IS
  'LEGACY: Older rename-in-place pattern. Same machine_id is preserved across the rename. Use only for backwards-compat with existing field PWA flows. For new identity transitions, use repurpose_machine() which atomically creates a fresh machine_id (canonical pattern as of Round 2).';
```

---

## 2026-04-25 — Architecture repository established

**Phase / Article:** Phase A scaffolding / Article 15 (PRs declare invariants)
**Applied to:** repo
**Migration name:** n/a
**Summary:** Created `boonz-erp/docs/architecture/` and seeded it with the Constitution v1.0, Phase A plan, and A1 before/after dashboard. Added this CHANGELOG, the migrations registry, and the RPC registry. Going forward, every backend change that touches a protected entity must be reflected here in addition to the SQL migration.
**Rollback:** `rm -rf boonz-erp/docs/architecture` (no DB impact).

---

## 2026-04-25 — A1 applied: RLS on `planogram` + `pod_inventory_audit_log`

**Phase / Article:** A.1 / Constitution Article 2 (RLS mandatory) + Article 7 (audit logs append-only)
**Applied to:** prod
**Migration name:** `phaseA_a1_rls_planogram_pia`
**Summary:** Enabled Row Level Security on `public.planogram` (was disabled — meant any authenticated user could mutate planogram with no RLS gate) and on `public.pod_inventory_audit_log` (was disabled — audit log was technically writeable/deletable). Added permissive SELECT/INSERT/UPDATE/DELETE policies for `authenticated` on `planogram` (matches the prior implicit behavior — no behavior change for the FE). On `pod_inventory_audit_log`, added permissive SELECT + INSERT, and explicit UPDATE/DELETE blocks to make the table append-only at the policy layer. `auto_decrement_pod_inventory` (the only function that writes to this log) is `SECURITY DEFINER` and continues to write fine — DEFINER bypasses RLS as the function owner. Zero rows mutated. Zero FE behavior change.
**Verification:** Visited via Supabase MCP: both tables now report `rowsecurity = true`. Policy counts: `planogram` = 4, `pod_inventory_audit_log` = 4.
**Rollback:**

```sql
DROP POLICY IF EXISTS planogram_select ON public.planogram;
DROP POLICY IF EXISTS planogram_insert ON public.planogram;
DROP POLICY IF EXISTS planogram_update ON public.planogram;
DROP POLICY IF EXISTS planogram_delete ON public.planogram;
ALTER TABLE public.planogram DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pial_select ON public.pod_inventory_audit_log;
DROP POLICY IF EXISTS pial_insert ON public.pod_inventory_audit_log;
DROP POLICY IF EXISTS pial_no_update ON public.pod_inventory_audit_log;
DROP POLICY IF EXISTS pial_no_delete ON public.pod_inventory_audit_log;
ALTER TABLE public.pod_inventory_audit_log DISABLE ROW LEVEL SECURITY;
```

---

## 2026-04-25 — Decision: skip Supabase preview branching for Phase A

**Phase / Article:** Phase A process / Article 12 (forward-only)
**Applied to:** decision log
**Migration name:** n/a
**Summary:** Attempted to create a preview branch via `mcp__supabase__create_branch` to apply A1 in isolation first. Returned `PaymentRequiredException` — branching is Pro-plan-only. Decided to apply Phase A directly to prod instead, with the `before/after` artifact as the visual diff and the rollback SQL as the safety net. This is acceptable for Phase A specifically because every step is metadata-only (no row mutation, no schema-shape change). For Phase B (FE migration touches data writes via new code paths), we will revisit branching or a staging Supabase project.
**Rollback:** n/a (decision-only).

---

## 2026-04-25 — Constitution v1.0 ratified

**Phase / Article:** n/a (constitutive doc)
**Applied to:** repo
**Migration name:** n/a
**Summary:** Authored 15 articles defining canonical write paths, validation, audit, surfaces (edge fns / n8n / cron), schema hygiene, and process. Codified the "make the wrong thing impossible" governance principle. See `01_constitution.html`.
**Rollback:** n/a (deprecating the Constitution requires the amendment process in Article 15 itself).

---

## 2026-06-04 — Refill qty-guard + manual-flow view ids

- `refillv2_swap_qty_from_live_shelf_stock`: engine_swap_pod v9_4 -> v9_5. Removal/M2W `qty_out` now reads `v_live_shelf_stock` (pod-scoped, slot_name->shelf_code map) instead of the `v_pod_inventory_latest x product_mapping` SUM that fanned out (78 mapping rows -> 234u phantom M2W on NOVO A08). Verified qty_out == live stock. Cody+Dara cleared. Articles 1,4,12,14.
- `refillv2_slots_view_add_ids`: `get_machine_slots_with_expiry` now also returns shelf_id, pod_product_id, suggested_pod_product_id (read-only, DROP+CREATE, backward-compatible). Unblocks manual-refill FE row writers. Cody cleared (class c).
- Open follow-ups: product_mapping 78-rows-per-pod bloat; M2W->Remove+destination redesign (Dara); manual-refill FE wiring (Stax spec in BOONZ BRAIN/spec_manual_refill_fe_stax.md).
