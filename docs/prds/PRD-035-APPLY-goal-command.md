# Claude Code /goal Command — PRD-035 APPLY (per-phase, gated)

Paste into Claude Code in `boonz-erp`. This goal **applies to prod**, but only one phase at a time, each after a passing rolled-back replay and your explicit "apply <phase>". STOP between phases.

```
/goal Apply PRD-035 using docs/prds/PRD-035-APPLY-RUNBOOK.md; read it and PRD-035-EXECUTION-LOG.md first. Apply order A->C->B->D->E. Supabase eizcexopcuoycuosittm. No em dashes.

PER-PHASE LOOP (run for each phase, STOP between phases):
1. Open the migration file; reconcile the runbook validate-query key names against the actual body (substitution_alerts, fill_band, swap_pass, refill_settings.swaps_enabled, relocation_candidate) and fix any mismatch before running.
2. REPLAY: run the phase's runbook block inside BEGIN..ROLLBACK (nothing persists). Print every CONFIRM checkbox as PASS/FAIL with the actual query result.
3. If any FAIL: stop, report, do not apply. If all PASS: STOP, show CS the results, wait for explicit "apply <phase>".
4. On green light: apply the migration to prod (run the file once / supabase migration up), re-run the read-only confirms on prod and paste results, set that phase to APPLIED (date + AC results) in PRD-035-EXECUTION-LOG.md, then STOP before the next phase.

RULES
- Never apply before its replay passes AND CS says apply. Forward-only; no edit-in-place, no _v2. No deletes (supersede only); no qty cut without a per-row diff.
- Cody verdicts already on file (A,B = approve-with-revisions re Art-16; C,D,E = approve). Do not re-review; just apply.
- PHASE A replay MUST exercise v24 NATIVE fallback: inside the txn first undo yesterday's per-machine workaround (set status='Active' on HUAWEI pod 35511de9 boonz Cola 07487368 + Mix Berries e2e27132, and HUAWEI pod 168aeb7e Hunter mappings boonz <> 85a0a6ca Sea Salted; DELETE mapping_id 1128acfb = JET Red Bull->Diet), then reset_approved_undispatched + reopen_stitched_rows on JET (a75f6648) + HUAWEI (9db7a821), then dry-run stitch. Rollback restores all. AC: engine_version=v24_wh_aware_variant_fallback; Red Bull/Healthy Cola/Hunter each resolve >0 via correct-or-sibling SKU; substitution_alerts>=1 carrying [SIBLING-FALLBACK] comments; zero silent 0-fills; non-hero machines unchanged vs v23.
- C is read-only (SECURITY INVOKER, STABLE); safe to apply directly after its checks.
- B AC: engine_version v18; fill scales with relative final_score (top=full, low+empty=floor); 0 local sales=0; stance absent from qty.
- D AC: picker v10; a Saturday plan_date yields 0 machines_to_visit; a Wednesday yields all VOX venue machines + 2-3 non-VOX; picks cluster by venue_group.
- E AC: engine_swap_pod v11; refill_settings.swaps_enabled default OFF and LEFT OFF after apply (manual enable only); Pass-3 swaps only when candidate-incumbent>=25 AND candidate>=50; dropped incumbent flagged relocation_candidate.

AFTER A IS LIVE (optional, ask CS first): on prod, revert the per-machine flavor-mapping workarounds (HUAWEI Healthy Cola/Hunter, JET Red Bull) and re-stitch those shelves so they fill via v24 native fallback instead of the manual mappings.

DO NOT in this goal: the Art-16 v_wh_pickable unification (separate later migration; do not half-migrate).

FINAL REPORT: per phase - replay PASS/FAIL, applied y/n + timestamp, prod confirm results; then restate the two open follow-ups (Art-16 unification; swaps_enabled stays OFF).
```
