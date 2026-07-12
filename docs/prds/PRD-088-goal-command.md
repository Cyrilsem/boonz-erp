# /goal — Close the dashboard-clocks + return-provenance chapter (PRD-086/087/088/099)

Paste as your `/goal` in Claude Code. **AUTO MODE**: verify, ship, close. Mostly bookkeeping — the only
code change is merging an already-committed branch and one optional FE chip removal. Project ref:
eizcexopcuoycuosittm.

---

**GOAL:** Close out the dashboard-clock work (086/087/088) and the return-provenance fix (099).
Key finding (verified live 2026-07-10): **PRD-088's backend outcome is already live.**
`get_machine_health` was restructured (PRD-074 v3) so both output columns already derive from
`v_machine_health_signals.days_since_visit` (`hs` join):

- `last_plan_days = COALESCE(hs.days_since_visit, -1)::int`
- `days_since_visit = COALESCE(hs.days_since_visit, -1)::int` (identical)
- `last_plan_date = CASE WHEN hs.days_since_visit < 0 THEN NULL ELSE CURRENT_DATE - hs.days_since_visit END`

There is **no `plan_data` CTE and no `rpo.dispatched=true`** in the live body — PRD-087's narrowing is
already superseded by this unification. So **do NOT write a PRD-088 migration.** Verify + close only.

**Steps:**

1. **Verify PRD-088 (no migration):**
   `select count(*) filter (where days_since_visit >= 0 and last_plan_days <> days_since_visit) as mismatches from get_machine_health();`
   → must be **0** (was 0 across 37 rows / 30 with a visit on 2026-07-10). If 0, PRD-088 acceptance is met
   by the live function — record the evidence, no code change.

2. **Merge PRD-099** (`approve_return` provenance fix). Branch `fix/prd-099-approve-return-provenance`
   (commit `e693ffe`) is committed + pushed, Cody PASS, tsc green. The reconcile that was blocking merge
   is **DONE** (2026-07-10, CS chose "discard shells": the two Barebells Hazelnut quarantine rows
   `6cb1b7b2` + `8f24dda3` were `reject_return`'d; units remain in WH_CENTRAL batch `785bd939`; no
   double-count). Open the PR and merge to `main`. No further data action.

3. **FE chip (optional, cosmetic):** on `feat/prd-087-ui-uplift`, remove the now-redundant `last plan {n}d`
   chip in `src/app/(app)/refill/SnapshotTab.tsx` (~L1670) — it always equals `last visit {n}d` now. Leave
   the single `last visit {n}d`. Correctness doesn't depend on this; let it ride the ui-uplift train.

4. **Close the docs:** update EXECUTION-LOGs and set Status:
   - PRD-086 → CLOSED (shipped `1b0bb8c`).
   - PRD-087 → CLOSED as **SUPERSEDED by PRD-088** (its `dispatched=true` change is no longer in the live
     function; the clock-unification is what shipped).
   - PRD-088 → CLOSED — **satisfied by live `get_machine_health` (PRD-074 v3); 0 mismatches verified
     2026-07-10; no migration required.** Optional FE chip noted.
   - PRD-099 → CLOSED — merged to main; reconcile done (reject shells; units in batch `785bd939`).
     Commit the EXECUTION-LOG/PRD status updates. Report the merge SHA(s).

**Acceptance:** PRD-099 on `main`; 088 mismatch count = 0 recorded; 086/087/088/099 marked CLOSED; no new
migration written for 088; `days_since_visit` untouched.

**Rollback:** docs-only for 088 (nothing to undo). PRD-099 rollback = `CREATE OR REPLACE approve_return`
reverting the two added lines (no data undo).
