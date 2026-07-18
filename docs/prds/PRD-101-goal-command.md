# PRD-101 goal command

GOAL: Execute PRD-101 (docs/prds/PRD-101-sim-assign-edit-only.md) AUTO. Self-run Stax (Cody light — FE only). Keep PRD-101-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. FE-only: make SIM assignment Edit-only on /field/config/sims, matching /app/sims. commit+push (main==origin/main).

POLICY: assignment AND unassignment stay fully available inside the Edit drawer (SimCardDrawer machine dropdown; `— unassigned —` clears machine_id+machine_name). Remove ONLY the redundant inline row button + its bottom-sheet modal. Do NOT touch sim_cards schema/data, RPCs, or the office page /app/sims.

HARD GATES: no backend / DB / migration / RPC change; no protected-entity mutation (sim_cards untouched at the data layer). Refill engines untouched → Family-A md5 byte-identical; diff_vs_golden IDENTICAL (plan-neutral). npm run build green, zero TS/lint errors (fully remove the now-unused onAssignToggle prop + AssignModal — no dangling symbols). forward-only.

WS-1 src/components/config/SimCardTable.tsx: remove the Assign/Unassign <button> from the Actions cell (keep Edit). Remove `onAssignToggle` from `SimCardTableProps` and the destructure. RenewalBadge/serialDisplay untouched.
WS-2 src/app/(field)/field/config/sims/page.tsx: delete the AssignModal component, `assignSim` state, `handleAssignToggle`, the `onAssignToggle={handleAssignToggle}` prop on <SimCardTable>, and the `{assignSim && <AssignModal/>}` block. Keep openEdit → SimCardDrawer + fetchData.
WS-3 verify (no change) SimCardDrawer.tsx already assigns AND clears machine_id/machine_name; verify /app/sims (src/app/(app)/app/sims/page.tsx) is untouched and still Edit-only.

T-TESTS: T1 field rows Actions = Edit only (no Assign/Unassign). T2 Edit → pick machine saves machine_id+name; `— unassigned —` clears both. T3 /app/sims unchanged. T4 npm run build green, no unused-symbol errors. T5 grep: zero change under src/lib, supabase/, engines.

CLOSE: CHANGELOG; PRD-101 SHIPPED + EXECUTION-LOG; commit+push (main==origin/main). Rollback = single revert (restore button + AssignModal); no data migration. ON BLOCKER (SimCardDrawer lacks an unassign path): PARK to MASTER-PARKING-LOT.md and do NOT remove the row button.
