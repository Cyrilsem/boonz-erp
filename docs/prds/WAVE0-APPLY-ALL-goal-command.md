# WAVE0 APPLY-ALL goal command

GOAL: Execute Wave 0 (foundation / trust-the-data) end to end by running PRD-076 → PRD-085 one at a time, AUTO mode. Self-run Dara/Cody/Stax. Project ref: eizcexopcuoycuosittm. Order source: this file. Governed by docs/prds/MASTER-goal-command.md. Blocker log (single, cross-wave): docs/prds/MASTER-PARKING-LOT.md. Reconciliation: docs/prds/WAVE0-reconciliation.md (5 of these are prior-art VERIFY, not net-new — respect each PRD's Status banner).

QUEUE (strict order — PRD · flag · *=protected migration · nature):
1 PRD-076 refill-shadow-diff-harness — NET-NEW (referee)
2 PRD-077 conservation-merge-gate — NEW gate (guards shipped)
3 PRD-078 golden-regression-baseline — NET-NEW (referee)
4 PRD-079 availability-gate-held-state wh_gate_v2 VERIFY+held (PRD-045/036 shipped) *
5 PRD-080 fefo-reservation-at-approve fefo_reserve_v1 VERIFY+residual (PRD-036/050 shipped; 072 residue) *
6 PRD-081 enforce-pack-rpc-only pack_guard VERIFY+guard (PRD-028/068 shipped) *
7 PRD-082 planned-vs-filled-qty qty_split_v1 VERIFY+residual (PRD-044 shipped) *
8 PRD-083 retire-duplicate-engine engine_single_path EXTEND (PRD-074 partial) *
9 PRD-084 prepack-drift-guard prepack_guard EXTEND monitor→block (PRD-057)
10 PRD-085 finalize-preserve-approved-v2 — VERIFY only (PRD-025 shipped)

FOR each PRD in order:
A. DEPS: if any dependency PRD not SHIPPED -> PARK {dep_not_met}, skip.
B. LOAD its docs/prds/PRD-0NN-goal-command.md; run it AUTO with its HARD GATES.
C. PRECONDITION for 079-085: the referee must be green — PRD-076 diff_vs_golden + PRD-077 conservation on golden_v1 (PRD-078). If missing -> PARK, skip.
D. EXECUTE on a Supabase preview BRANCH first (never prod). Keep changes behind the PRD's flag (dark).
E. VALIDATE: run the PRD's T-tests; diff_vs_golden MUST be identical for referee/verify PRDs or show ONLY the PRD's intended delta; conservation_check NO new violations vs known-debt baseline; engines md5 byte-identical per each PRD's gate.
F. HUMAN GATE: for *protected PRDs (079-083) STOP for Cody verdict + CS sign-off before prod apply. Do NOT self-approve.
G. PROMOTE: on green + sign-offs -> apply migration to prod, enable flag, set PRD Status=SHIPPED, write PRD-0NN-EXECUTION-LOG.md, update RPC_REGISTRY/CHANGELOG, commit + push (main==origin/main), continue.
H. BLOCKER: any failed T-test, non-identical/unexpected diff, new conservation violation, missing decision, live caller, ambiguous reader -> append MASTER-PARKING-LOT.md {date,wave:0,prd,blocker,needed,owner,evidence}; do only safe independent sub-steps; continue to NEXT PRD. NEVER force.

STOP when: all 10 SHIPPED -> Wave 0 COMPLETE, unlock Wave 1; OR a *protected gate needs sign-off (pause, report); OR queue exhausted with parks (report parked + what each needs).

GLOBAL GATES: branch-before-prod always; flag-gate always; referee green before enabling any flag; Family A engines (engine_add_pod/engine_swap_pod/engine_finalize_pod/pick_machines_for_refill) md5 byte-identical unless a PRD explicitly changes them; Cody signs every *protected migration; forward-only migrations; parks never block the loop. After EACH PRD emit {prd, status: shipped|parked|gate-pending, diff_summary, conservation_delta, parks_added}.
