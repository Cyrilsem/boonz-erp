/goal OVERNIGHT — golden_v2 fixture + Wave-1 REAL re-preview + Wave-2 SWAP ship-dark. AUTO; self-run Dara/Cody/Stax. Project ref: eizcexopcuoycuosittm. Parking: docs/prds/MASTER-PARKING-LOT.md. Log to PRD-0NN-EXECUTION-LOG.md, commit+push (main==origin/main).

CONTEXT: Wave 0 CLOSED. Wave 1 shipped DARK (089/090/093A; 091/092/093B parked). CORRECTION: engine ADD path is LIVE (~90%+ of every plan); golden_v1 is a 2-machine/21-row sliver crossing no Wave-1 threshold, so the 0-deltas were a FIXTURE artifact, NOT engine dormancy. Fix the fixture FIRST — Wave-2 SWAP would hit the same blind fixture otherwise.

PHASE 0 — BUILD golden_v2 (additive; do NOT touch golden_v1):
Capture a REPRESENTATIVE engine-dense fixture that exercises ADD + SWAP. Pick an engine-heavy plan_date (pod_refill_plan mostly reasoning->>'source'='engine_add_pod') and a machine set that DEMONSTRABLY includes: a band-3 performer above abs_velocity_floor, a niche-footprint SKU at its best location, a near-expiry shelf, a blocked_no_wh shelf, and a swap-eligible (dead/rotate) shelf. Capture via refill_qa.capture_run as label 'golden_v2' + store its conservation verdict. VERIFY golden_v2 contains >=1 shelf each Wave-1/Wave-2 flag can bite; if not, widen the machine set and re-capture. Record composition in an EXECUTION-LOG. If a representative fixture cannot be built -> PARK and STOP (never fake deltas).

PHASE 1 — Wave-1 REAL re-preview vs golden_v2 (NO enable):
For 089/090/093 (shipped dark) AND 091/092 (parked), run each flag-ON rollback capture (BEGIN..ROLLBACK: set flag on, run engine, diff_vs_golden('golden_v2') + conservation_check, ROLLBACK). Write the REAL per-PRD delta to each EXECUTION-LOG + update MASTER-PARKING-LOT. Do NOT enable any flag.

PHASE 2 — Wave-2 SWAP ship-dark, in order:
1 docs/prds/PRD-094-goal-command.md product-anchored swap caps swap_prod_cap_v1 (KEYSTONE)
2 docs/prds/PRD-095-goal-command.md expiry-risk swap trigger swap_expiry_v1
3 docs/prds/PRD-096-goal-command.md within-pod relocation pod_reloc_v1
4 docs/prds/PRD-097-goal-command.md R7/R3/empty-shelf guards swap_guards_v1
Each: WS on branch/rollback; prove flag OFF => diff_vs_golden('golden_v2') IDENTICAL (else PARK, do not ship); `cody` MUST PASS; ship code flag=OFF; capture ON-delta via rollback into the EXECUTION-LOG; other Family-A engines (engine_add_pod, engine_finalize_pod, pick_machines_for_refill) md5 byte-identical (engine_swap_pod changes only inside the flag guard). BLOCKER -> MASTER-PARKING-LOT.md {date,wave:2,prd,blocker,needed,owner,evidence}; CONTINUE; NEVER force/enable.

END: report (a) golden_v2 composition + which flags it can bite; (b) Wave-1 REAL deltas (5 PRDs); (c) Wave-2 scoreboard X/4 SHIPPED DARK + on-deltas; (d) parked list with what each needs from CS/Dara. Do NOT author Wave 3-5. Do NOT enable any behaviour flag.

GLOBAL: branch/rollback before prod; every change flag-gated OFF; referee green; `cody` PASS per protected migration; forward-only; npm build green; parks never block. PUSH HARD on build+validate; NEVER enable a flag; nothing irreversible.
