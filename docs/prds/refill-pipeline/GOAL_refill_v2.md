# Claude Code /goal — Refill v2 (fill-to-capacity add + reliable swap + driver translator)

Copy everything inside the fences (<4000 chars).

```
/goal Build Refill v2 for boonz-erp (Supabase eizcexopcuoycuosittm). Read first: docs/prds/refill-pipeline/PRD-REFILL-V2-add-swap-rebuild.md (full specs + acceptance there). Governance per item: Dara→Cody verdict→migration FILE→diff-gate vs live→STOP for CS green light before applying any engine writer. APPLY NOTHING until CS signs each diff. Forward-only; no _v2 tables. Update the 3 registries.

CORE PRINCIPLE: quantity is decoupled from score. final_score/Pearson = RANKING only, never a fill cap.

1) ADD — engine_add_pod v14→v15. Fetch live via pg_get_functiondef; diff-gate.
- Every non-dead shelf fills to capacity: refill_qty = GREATEST(max_stock - current_stock, driver_req_qty), capped only by wh_avail.
- Dead = stance IN ('DEAD','ROTATE OUT','DEAD — SWAP NOW') OR velocity_30d=0 → refill_qty=0 AND write a swap-candidate tag (Dara: reason='dead_tagged_by_add' on pod_swaps OR planned_swaps — pick one, justify).
- WH scarcity is the ONLY throttle: when wh_avail < sum needed, allocate to shelves by descending velocity then final_score; shortfalls emit procurement_gap (keep existing gap output).
- Keep: GUCs app.via_rpc/app.rpc_name, role gate, audit, capacity clamp, decision jsonb in reasoning. compute_refill_decision stays for score; stop using its target_units to cap qty.
- AC: re-run on a plan_date → ≥95% of selling shelves end ≥95% fill; all shortfalls are blocked_no_wh; dead shelves qty=0 + tagged.

2) SWAP — engine_swap_pod v8→v9. Diff-gate.
- Trigger ONLY: shelves tagged dead/rotate-out from step 1 (low stock). REMOVE the Pass-2 autonomous-Pearson-on-healthy logic and ALL lifecycle optimization.
- Swap-in candidate: product performing GLOBALLY and NOT already in the machine, ranked by Pearson/correlation vs the machine basket (reuse find_substitutes_for_shelf source); fallback to global performance rank when correlation thin; record score/fallback reason.
- Removed product → warehouse (M2W paired return).
- Consume driver_recommendations (kind needs_product/wrong_product) as swaps.
- AC: zero swaps with reason lifecycle/autonomous_pearson_healthy; every swap-in not already in machine + has score/reason; every swap-out has paired M2W.

3) TRANSLATOR (new, read-only INVOKER) resolve_driver_intent(p_plan_date, p_machine_id) → rows {pod_product_id, boonz_product_id, qty, shelf_code(01-16)} from driver_feedback + driver_recommendations + product_mapping + pod_products. Anything unresolved → flagged 'unresolved_driver_intent' (never silently dropped). Feeds steps 1, 2, and 6.

4) EXPIRY daily rule (lightweight, inside the flow): a slot with expired/at-risk units → if product performs, step 1 refills it; if not, step 1 tags it for step 2. No strategic batch engine.

5) PICKER — pick_machines_for_refill v7→v8. Diff-gate. Select on the new P1 restock definition (mirror get_machine_health priority_tier='P1_RESTOCK' — bands in the PRD) and expand to venue siblings (exists). Exclude warehouses/not-included. Page and route must agree.

6) STITCH — stitch_pod_to_boonz. Diff-gate. Keep product_mapping % split, THEN overlay resolve_driver_intent at boonz SKU level (right SKU + qty), then dispatch as today. Shelf codes 01-16 only; add a guard so the WEIMI 0-based index never leaks operator/driver-facing.

7) PROCESS: confirm the 8pm cron (build_draft_for_confirmed, already auto-confirm+finalize+timeout-fixed) chains pick→add→swap→expiry→finalize to a draft and STOPS; Vercel approve → stitch+dispatch with NO Cowork. Don't auto-approve/auto-stitch in cron.

OUTPUT per item: Dara note, Cody verdict, SQL+diff, dry-run proof vs live (esp. AC1 fill %, AC2 dead, AC3 swap-in), apply order. Final summary; CS reviews + applies each engine diff. Run to completion; do not stop mid-phase except at the named CS green-light gates.
```
