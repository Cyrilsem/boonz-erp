# PRD-076 goal command

GOAL: Execute PRD-076 (docs/prds/PRD-076-refill-shadow-diff-harness.md) end to end, AUTO mode. Self-run Dara/Cody/Stax. Apply only green pieces, SKIP-and-HIGHLIGHT gate failures, keep PRD-076-EXECUTION-LOG.md current, never wait on CS. Project ref: eizcexopcuoycuosittm.

HARD GATES: engine_add_pod, engine_swap_pod, engine_finalize_pod, pick_machines_for_refill md5 byte-identical (read-only PRD). NO writes to prod planning/inventory — capture runs on a Supabase preview branch ONLY; assert branch before engine run; post-assert prod pod_refill_plan unchanged. BEGIN..ROLLBACK before refill_qa DDL; migrations forward-only. npm run build green if any FE.

WS-1 (Dara) refill_qa schema: plan_run(run_id,plan_date,label,engine_fingerprint,input_fingerprint,created_at,meta) + plan_run_row(run_id,machine_id,shelf_id,pod_product_id,action,qty,status,source,linked_intent_id,reasoning) idx (run_id,machine_id,shelf_id,pod_product_id,action). Cody reviews additive QA infra.

WS-2 capture_run(plan_date,label): create_branch; on branch run build_draft_for_confirmed(plan_date,true); copy pod_refill_plan rows -> plan_run_row tagged run_id; engine_fingerprint=md5 of pg_get_functiondef of the 6 pipeline fns; input_fingerprint=md5 of scoped input rows; discard branch. Guard: refuse if not on a branch.

WS-3 diff_runs(baseline,candidate,scope[]): full outer join on (machine_id,shelf_id,pod_product_id,action); classify unchanged/added/removed/qty_changed/action_changed/status_changed/reason_changed; aggregate fleet+per-machine+net_units+identical; inputs_differ when fingerprints differ. Pure SELECT.

WS-4 Runbook doc: branch->capture->diff->interpret loop for the WAVE0 executor and humans.

T-TESTS (log tables): T1 synthetic 3-class diff exact. T2 qty NULL vs 5 => qty_changed. T3 NO-OP self-test: same engine twice on frozen inputs => identical (zero false positives — MUST pass). T4 full-fleet capture => prod pod_refill_plan byte-unchanged. T5 mutate one input => inputs_differ. T6 Saturday => skipped_saturday empty diff.

CLOSE: RPC_REGISTRY (capture_run, diff_runs) + CHANGELOG; PRD-076 status SHIPPED + EXECUTION-LOG; commit + push, main==origin/main. Report: T-test table, any skip + why. ON BLOCKER: append PARKING_LOT.md and continue.
