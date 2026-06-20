# Claude Code /goal — PRD-040 Refill Closeout (gated, per track)

Paste into Claude Code in `boonz-erp`. Executes the backend tracks (A, B) under gates; specs the FE (C) and activation (D) tracks. STOPS before any prod apply.

```
/goal Execute PRD-040 (refill closeout). Read docs/prds/PRD-040-refill-closeout.md and PRD-034/035/036/037/039 + engines/refill/guardrails/*.md first. Supabase eizcexopcuoycuosittm. No em dashes. Forward-only migrations, no edit-in-place, no _v2 tables, no deletes (supersede only). engine_add_pod stays FROZEN unless a track explicitly changes it. refill_settings.swaps_enabled stays false for Tracks A/B/C (only Track D touches it, and only on explicit CS go). Apply NOTHING to prod until CS says "apply <track/item>".

TRACK A — apply the 2 built-but-unapplied migrations:
- A1 supabase/migrations/20260618130000_prd036_b_log_manual_refill_new_purchase.sql
- A2 supabase/migrations/20260616130000_prd019c_compact_product_fallback_is_configured.sql
For each: diff the file against the live object; Cody verdict; BEGIN..ROLLBACK replay proving no regression to log_manual_refill (A1) / v_refill_planning_compact consumers (A2). If stale, author a fresh forward migration instead. STOP with the verdict + replay; apply only on "apply A1"/"apply A2".

TRACK B — backend hygiene (Dara designs, Cody verdicts, replay, STOP before apply):
- B1 register get_candidate_affinity as canonical "candidate basket affinity" in METRICS_REGISTRY; PLAN (do not execute) converging find_substitutes_for_shelf onto it as one behaviour-diffed pass.
- B2 design product_family_id taxonomy + backfill (0/307); then flip coexistence Rule 2 from product_brand proxy to family_id. Show the family map for CS approval BEFORE any write.
- B3 define a true gross-profit margin source (90/307 missing avg_30days_cost); rework engine_swap_pod V() (and engine_add_pod if it consumes margin) to use it; replay PRD-039 U/C/A/H + R1 + PRD-037 T1-T13. Value-model-affecting => full replay required.
- B4 unify stitch_pod_to_boonz 4 inline WH reads onto v_wh_pickable in ONE behaviour-diffed migration (pull_overlaid.wh_avail_variant, pull_with_wh, alert supply CTE, diag); prove line + alert outputs unchanged except the intended in-date exclusion.

TRACK C — FE (Stax spec only in this goal; do not build FE here):
- C1 spec get_vox_returns read surface + FE for PRD-034 Phase C.
- C2 spec wiring of reopen_stitched_rows / release_wh_quarantine / check_remove_without_replace / convert_shelf (PRD-033).
- C3 plan landing feat/prd-033-operator-flexibility (PRD-033, prd023i/j, Performance tab) onto main + registry reconciliation. Output specs to docs/prds/; no code.

TRACK D — activation runbook only (no flag flip here):
- Write docs/prds/PRD-040-PHASE3-ENABLE-RUNBOOK.md: per-machine swaps_enabled:<machine_id>=true, N supervised /refill cycles, daily review log, rollback (flag=false). Revisit tunables v_cand_min_stock=3 / v_top_n=10 / v_K=3. Do NOT flip swaps_enabled.

PER TRACK:
1. Reconcile field/column names against live schema before running.
2. Replay in BEGIN..ROLLBACK; print PASS/FAIL with actual values.
3. ANY fail: stop, report, do not apply, do not continue.
4. ALL pass: STOP, show CS the table, wait for "apply <item>".
5. On go: apply, prod-confirm, write docs/prds/PRD-040-EXECUTION-LOG.md, update CHANGELOG/MIGRATIONS/RPC, then STOP.

HARD RULES
- Cody must verdict every migration (A1, A2, B2, B3, B4) and the affinity convergence plan before apply.
- swaps_enabled stays false; only Track D's runbook authorizes a flip, executed by CS.
- engine_add_pod stays byte-identical unless B3 explicitly changes its margin source (then T12 is re-baselined with CS sign-off).
- Do not push to git in this goal; commits are a separate prod-sync step.

FINAL REPORT: per track/item - PASS/FAIL, applied y/n + timestamp, prod confirm. Restate parked: PRD-038 (70/30), Phase-3 enable pending supervised cycles.
```
