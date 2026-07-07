/goal MASTER — Refill Brain remediation. AUTO mode; self-run Dara(design)/Cody(review)/Stax(wire). Project ref: eizcexopcuoycuosittm. Single cross-wave parking: docs/prds/MASTER-PARKING-LOT.md. Basis: docs/prds/WAVE0-reconciliation.md.

OBJECTIVE NOW: CLOSE WAVE 0 (foundation). Run these PRD goal-commands in STRICT order, one at a time:
1 docs/prds/PRD-076-goal-command.md shadow-diff harness NET-NEW
2 docs/prds/PRD-077-goal-command.md conservation merge gate NEW gate
3 docs/prds/PRD-078-goal-command.md golden baseline NET-NEW
4 docs/prds/PRD-079-goal-command.md availability+held wh_gate_v2 *
5 docs/prds/PRD-080-goal-command.md fefo+reservation fefo_reserve_v1 *
6 docs/prds/PRD-081-goal-command.md pack-rpc-only pack_guard *
7 docs/prds/PRD-082-goal-command.md planned/filled qty qty_split_v1 *
8 docs/prds/PRD-083-goal-command.md retire dup engine engine_single_path *
9 docs/prds/PRD-084-goal-command.md prepack drift guard prepack_guard
10 docs/prds/PRD-085-goal-command.md finalize preserve (verify only)
(* = protected migration -> Cody verdict + CS sign-off required before prod)

FOR each PRD in order:
A. Load its goal-command; run AUTO with that PRD's HARD GATES.
B. PRECONDITION for 079-085: referee GREEN = PRD-076 diff_vs_golden + PRD-077 conservation on golden_v1 (PRD-078). If not green -> PARK, skip.
C. CANDIDATE-CAPTURE = run the real engine inside BEGIN..ROLLBACK on prod (persists nothing; engines verified transaction-pure) or a branch when data-independent; never PERSIST experimental writes to prod. Ship all changes behind the PRD's flag (dark).
D. VALIDATE: run the PRD T-tests; diff_vs_golden identical for referee/verify PRDs or ONLY the intended delta; conservation_check NO new violations vs known-debt baseline; Family A engines (engine_add_pod, engine_swap_pod, engine_finalize_pod, pick_machines_for_refill) md5 byte-identical unless the PRD explicitly changes them.
E. If protected (*) -> STOP for Cody verdict + CS sign-off before ANY prod apply. Do NOT self-approve.
F. Green + sign-offs -> apply to prod, enable flag, set PRD Status=SHIPPED, write PRD-0NN-EXECUTION-LOG.md, update RPC_REGISTRY + CHANGELOG, commit + push (main==origin/main), go to next.
G. BLOCKER (failed test, unexpected diff, new conservation violation, missing decision, live caller, ambiguous reader) -> append MASTER-PARKING-LOT.md {date,wave:0,prd,blocker,needed,owner,evidence}; do safe independent sub-steps only; continue to NEXT PRD. NEVER force.

WAVE 0 COMPLETE when: all 10 SHIPPED, conservation shows no new violations vs baseline, diff_vs_golden shows only intended deltas.

THEN (LOCKED until Wave 0 COMPLETE; PRDs must be authored before running):
Wave 1 ADD (cases 2,3,6,12,14) · Wave 2 SWAP (4,5,7,10,R7,R3) · Wave 3 STRATEGIC (8,9) · Wave 4 FE/FLOW (add-swap-in-pack, dispatch-edit UX, drift tooling, 8pm advisory) · Wave 5 HARDENING (determinism, thresholds, base_stock default, config, observability).
If a wave's PRDs are NOT authored -> HARD STOP + request authoring. Do NOT invent specs or acceptance criteria.

GLOBAL GATES: branch-before-prod always; flag-gate always; referee green before enabling any flag; Cody signs every * migration; forward-only migrations; npm run build green; parks never block the loop.

START: PRD-076 (net-new referee, zero engine change). REPORT per PRD {prd, status: shipped|parked|gate-pending, diff_summary, conservation_delta, parks_added}.
