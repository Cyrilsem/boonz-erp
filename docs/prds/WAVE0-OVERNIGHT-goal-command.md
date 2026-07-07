/goal WAVE0-OVERNIGHT — push Wave 0 to completion autonomously tonight. AUTO; self-run Dara/Cody/Stax. Project ref: eizcexopcuoycuosittm. Parking: docs/prds/MASTER-PARKING-LOT.md. Log each step to PRD-0NN-EXECUTION-LOG.md, commit+push (main==origin/main).

STATE 2026-07-07: SHIPPED 076 / 077(delta-blocking live) / 078 / 084(advisory). Branch-data RESOLVED = rollback-on-prod (engines transaction-pure). Phantoms cleared. 082 billing cleared. 083 Family-B = orphan island (deprecate ok; approve_refill_plan SHARED-keep). REMAINING: 079,080,081,082,083,085.

CS PRE-AUTH (overnight only): CS sign-off GRANTED IN ADVANCE for any change meeting the AUTONOMY ENVELOPE. The `cody` skill is the mandatory constitutional reviewer per protected migration.

AUTONOMY ENVELOPE — you MAY apply to prod tonight without waiting IFF ALL hold:

1.  behind a flag AND fully reversible (flag off / revert to captured original / rename-not-drop);
2.  referee GREEN: refill_qa.diff_vs_golden shows ONLY the PRD's intended delta (identical for guard/verify PRDs) AND refill_qa.conservation_check delta = 0 new violations;
3.  Family A engines (engine_add_pod, engine_swap_pod, engine_finalize_pod, pick_machines_for_refill) md5 byte-identical unless the PRD explicitly changes them;
4.  the `cody` skill returns PASS;
5.  NOT irreversible (no DROP, no data delete, no destructive DDL) and NOT dependent on a human-only step (live packing cycle, FE deploy, an unmade design decision).
    ELSE -> PARK to MASTER-PARKING-LOT.md {date,prd,blocker,needed,owner,evidence} and CONTINUE. NEVER force.

CAPTURE: candidate = engine inside BEGIN..ROLLBACK on prod (persists nothing) -> capture_run -> diff_vs_golden. Never persist experimental writes.

WORK in this order; each: load PRD + goal-command, do work via branch/rollback, validate, `cody` PASS, apply-if-envelope-met, set Status, EXECUTION-LOG, commit:
085 finalize-preserve: read the LIVE date-only engine_finalize_pod body; if it lacks the approved-guard, add guard (exclude status='approved' from the upsert) + finalize_pending_changes; register the referee regression T-test. Reversible+flagged -> ship (or mark verified + add test).
083 retire-dup-engine: DEPRECATE ONLY (Article 13: RAISE redirect on orchestrate_refill_plan + propose_add_plan + propose_swap_plan + engine_publish_to_refill_plan + reconcile_intent_progress behind engine_single_path=deprecate; KEEP approve_refill_plan/write_refill_plan/refill_plan_output). DROP nothing (park the drop). Fix refill-brain skill+docs to Family A.
079 availability+held: build wh_is_pickable + v_wh_stock_state (held classes) [additive, safe -> ship]. Refactor v_wh_pickable + engine_add_pod.wh_avail onto it behind wh_gate_v2 ONLY IF rollback-capture proves engine_add_pod.wh_avail AND diff_vs_golden IDENTICAL on golden; ANY shift -> PARK the unification (keep held-view shipped).
082 planned/filled (backend only tonight): stop pack_dispatch_line overwriting quantity (write filled_quantity only) behind qty_split_v1; backfill quantity=original_quantity where safe; remove edit_dispatch_qty item_added block. Ship behind flag only if diff+conservation green + cody PASS. PARK the FE reader repoint (human/FE).
081 pack-rpc-only: create enforce_pack_via_rpc trigger in WARN + refill_pack_bypass_log (non-blocking, safe -> ship, flag=warn). PARK the ENFORCE flip (needs a live packing cycle).
080 fefo-reservation: build wh_reservation table + bind_fefo_reserved + release hooks behind fefo_reserve_v1=off (dark). PARK enabling (needs Ops TTL + reservation-shape ruling).

AFTER each emit {prd,status,diff_summary,conservation_delta,parks}. END: Wave 0 scoreboard X/10 + parked list with EXACTLY what each needs from CS/Ops/FE for AM review. Do NOT author Wave 1-5 (locked).

GLOBAL: branch/rollback before prod; flag-gate all; referee green before any flag; `cody` PASS per protected migration; forward-only; npm build green; parks never block. PUSH HARD; never force a red gate; nothing irreversible.
