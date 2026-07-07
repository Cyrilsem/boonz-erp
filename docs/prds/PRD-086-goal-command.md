# /goal — PRD-086 dispatch board completion counter fix (run once)

Paste this as your `/goal` in Claude Code. **AUTO MODE**: implement, verify, ship — do not stop for
confirmation unless a step genuinely fails. FE-only. No DB, no migration, no RPC, no data writes.
Project ref: eizcexopcuoycuosittm.

---

**GOAL:** Fix the Refill Dispatch board so a machine counts as complete when every line has reached a
terminal state (dispatched, not-filled, returned, or skipped) — not only when every line is
`dispatched=true`. On 2026-07-07 all 7 machines are 100% resolved but the board shows 0/7. Full spec:
`docs/prds/PRD-086-dispatch-board-completion-counter.md`.

**Single file to change:** `src/app/(app)/refill/DailyDispatchingTab.tsx`. Do not touch any RPC, view,
migration, or write path. `not_filled` rows must never be turned into packed/dispatched.

**Steps:**

1. Read `docs/prds/PRD-086-dispatch-board-completion-counter.md` in full.
2. In `DailyDispatchingTab.tsx`:
   a. Add `pack_outcome, returned, skipped` to the `refill_dispatching` `.select(...)` column list, and
   add `pack_outcome: string | null; returned: boolean; skipped: boolean;` to the line row type(s).
   b. Compute per line `nonFillable = pack_outcome === 'not_filled' || !!returned || !!skipped`. Add
   `fillable_total` and `not_filled_count` to the per-machine aggregate (keep `total`, `packed_count`,
   `picked_up_count`, `dispatched_count` unchanged).
   c. Replace `m.total` with `m.fillable_total` in `deriveStage`, in the `packedMachines` /
   `pickedUpMachines` / `dispatchedMachines` filters, in the progress-bar denominator, and in
   `allDone`. Treat `fillable_total === 0` as complete.
   d. Update the per-machine P/U/D chips to read `/ m.fillable_total`, and when `not_filled_count > 0`
   append a muted `· {not_filled_count} not filled`.
3. Verify: `npm run lint` and `npx tsc --noEmit` (or the repo's typecheck) pass. Reason through today's
   numbers from the PRD (e.g. AMZ-1029: 17 dispatched + 4 not-filled → fillable_total 17, dispatched 17
   → complete) and confirm all 7 machines would now read complete, while a genuinely mid-pack machine
   (a fillable line still `packed=false`) still would not.
4. Commit on branch `fix/prd-086-dispatch-completion-counter`, push, deploy to Vercel (prod) per the
   repo's standard deploy. Keep a short `PRD-086-EXECUTION-LOG.md`. Report deployed URL + commit SHA.

**Acceptance:** board reads PACKED/PICKED UP/DISPATCHED **7/7** for 2026-07-07; each card shows Complete;
bars at 100%; a still-pending fillable line keeps a machine incomplete; zero backend/data changes;
`not_filled` never silently converted to packed/dispatched.

**Rollback:** revert the branch commit and redeploy. Nothing else to undo.
