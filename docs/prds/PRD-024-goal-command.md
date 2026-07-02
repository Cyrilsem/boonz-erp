# /goal — PRD-024/025/026/027 Refill Review Fix Batch (<2500 chars)

Paste into Claude Code in the boonz-erp repo.

---

/goal Implement the 2026-06-12 refill review fix batch per docs/prds: PRD-024-stitch-split-normalization-and-0613-reset.md (critical, tonight), PRD-025-finalize-preserves-approved-rows.md, PRD-026-lifecycle-scoring-integrity.md, PRD-027-refill-hardening-batch.md.

STATE (verified live 2026-06-12, do not re-diagnose): stitch_pod_to_boonz v19 reads pm.mix_weight raw and only normalizes when total_split=0; 1,713 machine-scoped product_mapping rows have mix_weight=1.0 so multi-flavor shelves inflate pod_qty x N (VOXMCC A10: 10 planned, 30 dispatched on the committed 06-13 plan). Machine-scoped Activia split_pct sums to 170 so a data-only resync is wrong; fix must be self-normalizing in the RPC. engine_finalize_pod's upsert resets approved rows to draft (causes "Stitch failed: no approved rows"). evaluate-lifecycle v13.1 fetches sales with .limit(10000) but the 62d window holds 10,219 rows and grows; plus score>=4 AND trend<4 labels even a 9.36-score slot WIND DOWN, and relative spectrum_ratio marks Aquafina at 36u/30d DEAD. engine_swap_pod v10.1 never applies p_min_pearson and has no per-machine cap on dead-tag swaps. 2,612/2,615 shelves have NULL max_capacity.

RULES: Backend Constitution. Every RPC change through Cody before apply. Forward-only migrations, no \_v2 functions, no raw writes to pod_refill_plan / refill_plan_output / refill_dispatching. operator_status != 'pending' rows are untouchable. No DELETEs without per-row CS approval. Update RPC_REGISTRY, MIGRATIONS_REGISTRY, CHANGELOG per change. No em dashes in copy.

BUILD ORDER:

1. PRD-024 §1: stitch v20 migration phaseF_stitch_split_pct_normalize (read pm.split_pct, norm_split = split_pct/NULLIF(total_split,0); same treatment in remove_phys_split and the deviation/procurement CTEs). Capture v19 functiondef first. Run the §1 verification battery on a dry-run date. STOP for CS green light before any commit.
2. PRD-024 §2: 06-13 plan reset runbook, gated: pre-flight (no packed/picked/dispatched rows), reset_approved_undispatched, re-pick + add/swap/finalize, Gate 1 approve, stitch dry-run + battery, Gate 2 commit, approve_refill_plan, dispatch coverage check. Surface the NISSAN-0804/NOOK-1019/VML-1003 include-or-drop decision to CS at step 3.
3. PRD-025 Option A: finalize preserves 'approved' when qty+action unchanged, else draft (migration phaseF_finalize_preserve_approved, Cody). Verify the 4 regression cases.
4. PRD-026: lifecycle edge fn, paginate or SQL-aggregate sales (assert if rows==limit), trend guard (score>=8 never WIND DOWN), velocity floor (v30>=0.5/day never ROTATE OUT/DEAD; >=1.0/day never below WATCH; thresholds need CS confirm). Re-run scoring, check the 25-slot regression set.
5. PRD-027 WS1 (p_min_pearson applied + explicit fallback marker; cap across passes) and WS5 (stitch emits real current/max stock). WS2/WS3/WS4 are tickets, do last or hand to Stax/Dara.

DONE WHEN: battery green, 06-13 rebuilt with zero shelves where SUM(variants) > pod_qty and no duplicates of 06-12 refilled shelves, "no approved rows" unreproducible, lifecycle regression set sane, registries updated, each step committed separately.

Start with step 1. Show me the migration draft and Cody's verdict before applying anything.
