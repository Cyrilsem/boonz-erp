# PRD-101 — EXECUTION LOG

## 2026-07-18 — SHIPPED (single session, AUTO, Stax self-run / Cody light)

- Blocker gate FIRST: SimCardDrawer.tsx verified as the complete assign+unassign path
  (draft.machine_id || null; machine_name resolved when set, null when cleared;
  '— unassigned —' option present). NOT parked.
- /app/sims checked before touching anything: it does not import SimCardTable at all
  (its 8 'assign' refs are its own Edit-drawer dropdown) — the shared-prop removal
  cannot ripple. Already Edit-only; untouched.
- WS-1 SimCardTable.tsx: Assign/Unassign button removed from Actions (Edit kept);
  onAssignToggle dropped from SimCardTableProps + destructure. RenewalBadge /
  serialDisplay untouched.
- WS-2 field sims page.tsx: AssignModal component, assignSim state,
  handleAssignToggle, the prop, and the render block all deleted. openEdit ->
  SimCardDrawer + fetchData intact.
- Built in an isolated worktree of main (primary checkout on feat/prd-100 with WIP
  never touched). Turbopack gotcha: it rejects a SYMLINKED node_modules ("points out
  of the filesystem root") — APFS clone copy (cp -cR) works.

### T-tests
- T1 PASS: Actions cell renders Edit only; zero AssignModal/onAssignToggle/assignSim
  symbols remain (grep = 0 in both files).
- T2 PASS (code-verified, drawer untouched): pick machine => machine_id + machine_name
  saved; '— unassigned —' => both nulled (SimCardDrawer lines ~108-110).
- T3 PASS: /app/sims not in the diff; does not consume SimCardTable.
- T4 PASS: npx tsc --noEmit 0 errors; npm run build green (56/56 pages).
- T5 PASS: diff = exactly 2 files (+2/-108); zero changes under src/lib, supabase/,
  or engines; zero DB calls made this task => Family-A md5 byte-identical and
  diff_vs_golden identical by construction (plan-neutral).

Rollback: single git revert of this commit (restores button + AssignModal). No data
migration; sim_cards untouched at the data layer.
