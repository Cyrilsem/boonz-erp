# PRD-101: SIM assignment is Edit-only (remove the inline Assign/Unassign button on the field SIM page)

Status: SHIPPED 2026-07-18. All T-tests pass; build green; FE-only (2 files, -108 lines).

## Why (verified in the FE)

`/field/config/sims` renders a standalone **Assign / Unassign** button on every SIM row (`SimCardTable.tsx` → opens a bottom-sheet `AssignModal`), *in addition to* the machine dropdown already inside the Edit drawer (`SimCardDrawer`). The office page `/app/sims` has **no** such button — there, assignment happens only inside Edit.

So the field page is the inconsistent one, and the row button is redundant: the Edit drawer's machine dropdown (with `— unassigned —`) already covers both assign **and** unassign, writing the exact same `machine_id` + `machine_name`. The button label is also misleading — it reads `Assign` whenever a SIM has no machine linked (`sim.machine_id ? "Unassign" : "Assign"`), which looks like the wrong state after a stale page load even when the data is correct. Make assignment Edit-only, matching `/app/sims`.

## Design (Stax; Cody light — FE only, no backend / DB / RPC)

1. `src/components/config/SimCardTable.tsx` — remove the Assign/Unassign `<button>` from the Actions cell (keep **Edit**). Remove `onAssignToggle` from the `SimCardTableProps` interface and from the destructure.
2. `src/app/(field)/field/config/sims/page.tsx` — delete the `AssignModal` component, the `assignSim` state, `handleAssignToggle`, the `onAssignToggle={handleAssignToggle}` prop, and the `{assignSim && <AssignModal .../>}` render block. Keep `openEdit → SimCardDrawer` and `fetchData` wiring intact.
3. No change to `SimCardDrawer.tsx` — it already writes `machine_id` + `machine_name` on save and clears both when `— unassigned —` is picked (assign *and* unassign live here). No change to `/app/sims`. No DB / RPC / engine change.

## Gates

FE-only removal. No `sim_cards` schema/RPC change, no protected-entity mutation → no migration; Cody sanity-check only (no constitutional surface). `npm run build` green with zero TS/lint errors (the now-unused `onAssignToggle` prop and `AssignModal` are fully removed, not left dangling). Plan-neutral — does not touch the refill engines → Family-A md5 unchanged, `diff_vs_golden` identical. Forward-only; commit+push.

## T-tests

- T1 `/field/config/sims` rows show only **Edit** in the Actions column (no Assign/Unassign button).
- T2 Edit a SIM → machine dropdown → pick a machine ⇒ `machine_id` + `machine_name` saved; pick `— unassigned —` ⇒ both cleared. (assign + unassign both reachable via Edit)
- T3 `/app/sims` visually and functionally unchanged (was already Edit-only).
- T4 `npm run build` green; no unused-symbol errors from the removed `onAssignToggle` / `AssignModal`.
- T5 grep confirms no change under `src/lib`, `supabase/`, or the engines — write path untouched.

## CLOSE

CHANGELOG; PRD-101 SHIPPED + PRD-101-EXECUTION-LOG.md; commit+push (main==origin/main). Rollback = single revert (restore the button + `AssignModal`); no data migration.
