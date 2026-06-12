# PRD-024: Stitch SKU-Split Normalization + 2026-06-13 Plan Reset

**Date:** 2026-06-12
**Status:** Approved direction, awaiting CS green light to execute
**Severity:** ⛔ Critical. Corrupts dispatched quantities on every multi-flavor shelf, every run. Tomorrow's committed plan is affected AND partly duplicates today's executed refill.
**Owner:** assistant (RPC patch + reset) → Cody (constitutional sign-off)
**Supersedes:** PRD-stitch-split-normalization.md (uploads, 2026-06-12). Counts refreshed and runbook retargeted from the 06-12 plan to the 06-13 plan.

---

## 1. Problem A: stitch gives every flavor SKU the full shelf quantity

`stitch_pod_to_boonz` v19, CTE `pull_raw`, reads `pm.mix_weight AS split_pct` and CTE `pull_norm` uses the value raw (only normalizes when `total_split = 0`). When machine-scoped mapping rows carry `mix_weight = 1.0` per variant, every SKU gets `floor(pod_qty × 1.0)` = the full quantity.

Verified live (2026-06-12):

- 2026-06-13 committed plan: VOXMCC-1005 A10, pod qty 10 → 30 units dispatched (Care 10 / Reload 10 / Upgrade 10).
- 2026-06-12 plan had the same on 4 shelves (VOXMCC A10 10→30, ACTIVATEMCC A08 7→21, A05 6→18, IFLYMCC A16 4→12); de-inflated by hand via `edit_dispatch_qty` before packing.
- **1,713** active machine-scoped `product_mapping` rows have `mix_weight = 1.0` (was 365 when first scoped; it grows with every mapping sync).
- **648** active rows have `mix_weight <> split_pct/100`.
- Machine-scoped Activia Mix & Go `split_pct` sums to **170**; global "TEST GOOD Dispatch" sums to 0.66. So a data-only resync of mix_weight is rejected: Activia would inflate 1.7×. The split must be self-normalizing in the RPC.

### Fix (2 expressions, stitch v19 → v20)

In `stitch_pod_to_boonz`:

1. `pull_raw`: `pm.split_pct AS split_pct` (read the real percentage column, not mix_weight).
2. `pull_norm`: `ELSE COALESCE(pnp.split_pct, 0) / NULLIF(total_split, 0)` (normalize by the windowed sum of the present variants).

`total_split` is already computed in `pull_norm_pre`. After the change `norm_split` sums to 1.0 across present variants regardless of raw percentages (100, 170, or all 1.0). Largest-remainder distribution and WH redistribution are unchanged. No signature change, no other CTE touched.

NOTE: the same raw-weight pattern also exists in stitch's REMOVE fan-out path (`remove_phys_split`) and the deviation/procurement CTEs (`n`, `pm_per_row`). Apply the identical normalization there for consistency (the REMOVE path already normalizes only when total = 0).

### Migration

- Name: `phaseF_stitch_split_pct_normalize`
- Forward-only `CREATE OR REPLACE FUNCTION public.stitch_pod_to_boonz(...)`. Capture current `pg_get_functiondef` before applying (rollback = redeploy prior body).
- Constitution: Article 1/4/8/12/14 all hold (single writer unchanged, via_rpc unchanged, forward migration, no \_v2). Cody verdict on prior draft: approve with re-run of verification battery.
- Update RPC_REGISTRY.md (v19 → v20), CHANGELOG.md, MIGRATIONS_REGISTRY.md.

### Verification battery (must pass on dry-run before commit)

1. Per multi-SKU shelf: SUM(variant qty) = pod_qty (no inflation, no shortfall beyond WH limits).
2. Per-SKU split tracks split_pct proportions (±1 largest-remainder tolerance).
3. No SKU exceeds its warehouse_stock; overflow redistributed to siblings.
4. Single-SKU shelves byte-identical to v19 output.
5. Activia Mix & Go (sum 170) splits proportionally and sums to pod_qty (regression case).
6. deviations = 0 on conserved shelves, noncanonical_shelf_codes = 0.

---

## 2. Problem B: the committed 2026-06-13 plan is stale and partly duplicate

Reconstructed from write_audit_log: the overnight session (01:49 to 02:42 Dubai, 2026-06-12) committed TWO plans: 06-13 at 02:11, then 06-12 at 02:41. The 06-12 plan was executed during the day (44/118 packed, 63 lines left open, OMDBB + OMDCW not visited). The 06-13 plan was built at 02:10 from PRE-refill stock, so:

| Machine       | 06-13 lines | Duplicates of shelves already refilled today |
| ------------- | ----------- | -------------------------------------------- |
| MPMCC-1054    | 7           | 7 (100%)                                     |
| ACTIVATE-2005 | 17          | 11                                           |
| VOXMCC-1005   | 14          | 7 (incl. A10 Vitamin Well re-inflated to 30) |
| OMDBB-1020    | 28          | 0 (not visited today, legit)                 |
| OMDCW-1021    | 22          | 0 (legit)                                    |
| VOXMM-1013    | 15          | 0 (packed today but never picked up)         |

Tonight's EOD sweep (cron 9, 23:59 Dubai, active) releases today's 63 open 06-12 lines, so no phantom carryover from today.

### Reset runbook for 2026-06-13 (execute tonight, AFTER the v20 migration)

All steps via canonical RPCs, no raw writes. Gates: each destructive step needs CS green light.

1. Pre-flight: confirm no 06-13 `refill_dispatching` row has `packed`, `picked_up` or `dispatched` = true (they were created last night; expect all false). If any are true, scope them OUT of the reset.
2. `reset_approved_undispatched('2026-06-13', NULL, 'PRD-024 stale duplicate plan rebuilt with stitch v20')` — flips rpo approved → pending on undispatched rows so the plan is editable again.
3. Rebuild the pod layer for 06-13: re-run `pick_machines_for_refill('2026-06-13')` + confirm, then `engine_add_pod` → `engine_swap_pod` → `engine_finalize_pod`. The engine reads live post-refill WEIMI stock, which removes the duplicate fills naturally. Expect ACTIVATE-2005, MPMCC-1054, VOXMCC to shrink or drop out; OMDBB, OMDCW, VOXMM to persist.
4. Carry over any operator pod-level edits that must survive (none known at time of writing; VOX-sourced kills from 06-12 were pod-level and persist).
5. Gate 1: `approve_pod_refill_plan('2026-06-13')` (or machine-name subset).
6. `stitch_pod_to_boonz('2026-06-13', true)` dry-run → run the §1 verification battery → Gate 2: commit with `p_dry_run := false`.
7. `approve_refill_plan` for the stitched machines (fires the dispatch bridge; stitch alone leaves rpo pending and writes no dispatch).
8. Post-commit: dispatch coverage check (every approved machine has ≥1 refill_dispatching row), and assert zero VW-style inflation: per shelf, SUM(variant qty) = pod qty.
9. Mind the 41 draft rows for NISSAN-0804 / NOOK-1019 / VML-1003 left from last night: include or drop them explicitly at step 3 (CS decision).

Ordering constraint: run finalize BEFORE approve (finalize resets approved rows to draft; see PRD-025).

---

## 3. Follow-ups (out of scope here)

- split_pct data hygiene: nightly validator or CHECK for active sets ≠ 100 (Activia 170, TEST GOOD 0.66). Owner: Dara.
- mix_weight column: retire or keep synced; currently misleading and unused by stitch v20.
- 1,713 uniform-1.0 machine-scoped rows: investigate which sync writes them (count tripled in under a month).
- OMDCW A02 "100% Krambals" per-machine intent: needs machine-specific mapping rows or a driver-rec path.
- driver_recommendations is empty fleet-wide; the v19/v20 driver SKU overlay has nothing to consume. Confirm intent.

## 4. Acceptance criteria

- [x] stitch v20 live (`phaseF_stitch_split_pct_normalize`, applied 2026-06-12), registries updated, Cody sign-off recorded (Articles 1, 4, 5, 8, 12, 14). Pre-apply audit: 0 variants lose allocation; no all-zero variant set. v19 rollback fingerprint captured.
- [x] Verification battery items 1/2/4/5 green via read-only simulation on the real 06-13 plan rows (106 shelf-pods, 82 multi-SKU: v20 conserves on all, 0 single-SKU drift vs v19, Activia 170 -> 4/3/3 = 10; v19 math inflated 4 shelf-pods, worst +60). Items 3 and 6 re-fire at the section-2 step-6 stitch dry-run before Gate 2.
- [ ] 06-13 plan rebuilt: no duplicate fills of today's refilled shelves, no shelf where SUM(variants) > pod qty. (CS-GATED: reset runbook not started; pre-flight verified clean - 103 rpo rows all pending, 103 dispatch rows all open.)
- [ ] Dispatch coverage check green; drivers see the corrected plan tomorrow morning. (Follows section-2 runbook.)
