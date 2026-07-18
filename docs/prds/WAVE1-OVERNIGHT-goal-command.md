/goal WAVE1-OVERNIGHT — author-complete Wave 1 (ADD engine) autonomously tonight, SHIP DARK. AUTO; self-run Dara/Cody/Stax. Project ref: eizcexopcuoycuosittm. Parking: docs/prds/MASTER-PARKING-LOT.md. Log each to PRD-0NN-EXECUTION-LOG.md, commit+push (main==origin/main).

CONTEXT: Wave 0 CLOSED (referee live: refill_qa.diff_vs_golden + conservation_check + golden_v1). Wave 1 = ADD-engine behaviour changes. These CHANGE what the engine decides, so the rule is STRICTER than Wave 0.

QUEUE (strict order; all touch engine_add_pod; each behind its own flag, default OFF):
1 docs/prds/PRD-089-goal-command.md absolute velocity floor + min-facing add_abs_floor_v1
2 docs/prds/PRD-090-goal-command.md niche merchandising fill add_niche_fill_v1
3 docs/prds/PRD-091-goal-command.md on-machine expiry input expiry_input_v1
4 docs/prds/PRD-092-goal-command.md no-WH -> substitute/M2M/procurement add_nowh_action_v1
5 docs/prds/PRD-093-goal-command.md consignment SKU model consignment_v1

CRITICAL RULE — SHIP DARK, NEVER ENABLE: you MAY apply each PRD's code to prod ONLY behind its flag=OFF, and ONLY after proving flag-OFF => diff_vs_golden IDENTICAL (inertness). You MUST NOT flip any behaviour flag ON in prod — enabling a live plan change is CS-only after reviewing the delta. Capture the ON-delta by rollback ONLY (BEGIN..ROLLBACK: set flag on in-txn, run engine, diff_vs_golden + conservation_check, ROLLBACK). Report the delta for AM review.

FOR each PRD in order:
A. Load its goal-command; do WS on branch/rollback.
B. Prove flag OFF => diff_vs_golden IDENTICAL. If NOT identical -> PARK (do not ship); the code path is not truly inert.
C. `cody` skill MUST PASS (engine + any DDL are protected).
D. Ship the code with flag=OFF; set Status=SHIPPED DARK; write the ON-delta report (top changed shelves, unit deltas, conservation) into the EXECUTION-LOG for CS.
E. Family A engines (engine_swap_pod, engine_finalize_pod, pick_machines_for_refill) md5 byte-identical; engine_add_pod changes only inside the flag guard.
F. BLOCKER (flag-off not identical, cody FAIL, conservation regresses on the ON-capture, unmade decision) -> append MASTER-PARKING-LOT.md {date,wave:1,prd,blocker,needed,owner,evidence}; CONTINUE. NEVER force; NEVER enable.

END: report Wave 1 scoreboard (X/5 SHIPPED DARK) + FIVE plan-delta summaries (one per PRD, from the rollback ON-capture) for CS to review and enable in the morning. Do NOT author Wave 2-5 (locked; unauthored).

GLOBAL: branch/rollback before prod; every change flag-gated OFF; referee green; `cody` PASS per protected migration; forward-only; npm build green; parks never block. PUSH HARD on building + validating; NEVER enable a behaviour flag; nothing irreversible.
