/goal Continue and COMPLETE PRD-048 per boonz-erp/docs/prds/PRD-048-add-brain-base-stock.md. Run AUTO-MODE, fully unattended overnight: take the safe/reasonable choice and CONTINUE, never pause to ask; if a piece is blocked, make the safe call, leave a clear TODO, move on; summarize at the end. Step 1 (seller-heavy backtest) is DONE — just record it; then execute steps 2,3,4 to ship.

NON-NEGOTIABLES (violation = revert that piece, keep going):

- SCOPE = ENGINE ADD sizing only (compute_refill_decision qty + engine_add_pod). Do NOT touch engine_swap_pod, pick_machines_for_refill, stitch_pod_to_boonz, push_plan_to_dispatch. swaps_enabled STAYS FALSE.
- Every canonical-writer change: Dara design -> Cody review -> apply. Migrations via Supabase MCP only (except the step-3 git commit).
- legacy MUST stay gate-clean: md5(pod_refills) for a fixed scratch plan_date unchanged vs v18. Prove it after every change.
- Instant rollback path must remain: UPDATE refill_policy_params SET refill_sizing_mode='legacy' -> engine reverts byte-identical v18 next run.

STEP 1 — RECORD ONLY (already run by CS in chat, read-only): seller-heavy backtest on AMZ-1029-3003-O1, AMZ-1038-3001-O1, AMZ-1057-2403-O1, AMZ-1068-2401-O1 (real sellers up to ~4 units/day). Write into PRD-048-EXECUTION-LOG.md §7 as the acceptance evidence and mark TODO#3 RESOLVED:
responsive picker: base_stock 16.3 trips vs legacy 24.6 = -34% at equal service (-0.07pp);
fixed 7-day: base_stock recovers ~163 AED/28d (+0.8pp service);
fixed 14-day: +445 AED/28d (+2.36pp service);
base_stock holds equal service at LOWER avg fill (68% vs 77%) = less capital.
Conclusion: §7 acceptance PASS on sellers; the dead-machine pilot simply had no sellers to move.

STEP 2 — Article-16 shelf-life (Cody condition): build the canonical shelf-life object Cody required (e.g. product_shelf_life table or v_product_shelf_life, sourced from product master / warehouse_inventory.expiration_date, FEFO-aware) and wire compute_base_stock_decision's spoilage cap to read it instead of the inline date. Dara -> Cody -> apply MCP-only. If genuinely blocked, write an explicit waiver note in the EXECUTION-LOG and proceed.

STEP 3 — prod-sync (the only git action): git commit the 4 PRD-048 migrations + 2 scripts + 4 docs (+ any step-2 migration) onto main with a clear message and push. NEVER commit .env or any secret. Realigns repo to prod.

STEP 4 — enable (safe: the nightly 8pm draft is still human-committed via FE Gate1+2, so enabling changes only the DRAFT, never live dispatch):
a. Scratch proof FIRST: on a NON-LIVE scratch plan_date, run pick + engine_add_pod with flag base_stock and assert — seller targets rise, dead (v7=0 AND v30=0) stay 0, no floor-on-tail (mu\*7<1.5 gets no floor), engine_swap_pod/stitch/dispatch outputs unchanged, get_advisors shows no new security/perf regression. Then flip back to legacy and confirm md5 gate-clean still holds. Clean up scratch rows.
b. If every assertion passes, ENABLE: UPDATE refill_policy_params SET refill_sizing_mode='base_stock', updated_by='<cs uuid if known else system>'. If a per-class enable is cheap to add (busy class first as canary), do it; else enable global and note that machine_service_policy.T already differentiates classes.
c. Do NOT run the engine on any already-dispatched live plan_date. If any §4.a assertion fails, DO NOT enable — leave flag legacy, log why, continue.

AT END print: GREEN (shelf-life resolved? git SHA pushed, flag state, scratch-proof assertions table), SKIPPED + TODOs, the one-line rollback command, and exactly what CS should eyeball in the next nightly draft (sellers fuller, dead still 0, swaps unchanged). Do not wait for input at any point.
