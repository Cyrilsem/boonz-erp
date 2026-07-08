# /goal — PRD-088 unify plan clock with visit clock (run once)

Paste as your `/goal` in Claude Code. **AUTO MODE**: implement, verify, ship. Backend = one function
(`get_machine_health`); route past **Cody** (canonical reader). Supersedes PRD-087's `dispatched=true`
narrowing. No data change, no write path, `days_since_visit`/`v_machine_health_signals` untouched.
Project ref: eizcexopcuoycuosittm.

---

**GOAL:** A manual refill and a dispatched plan are the same servicing event, so `last_plan` must equal
`last_visit` for both. Make `get_machine_health.last_plan_date/last_plan_days` mirror the canonical
service clock (`days_since_visit`). Spec: `docs/prds/PRD-088-unify-plan-clock-with-visit.md`.

**Steps:**

1. Read the PRD in full. Note it reverses the PRD-087 `AND rpo.dispatched = true` approach.
2. `CREATE OR REPLACE FUNCTION public.get_machine_health()`:
   - Drop the `plan_data` CTE and its `pld` join.
   - Replace the two output columns so they derive from the existing `hs` join:
     `last_plan_date := CASE WHEN hs.days_since_visit IS NULL OR hs.days_since_visit < 0 THEN NULL ELSE (CURRENT_DATE - hs.days_since_visit) END`
     and `last_plan_days := COALESCE(hs.days_since_visit, -1)::int`.
   - Everything else byte-identical. Run past Cody. Use the guarded-transform apply (verify live base
     md5, verify result md5 = committed git file) to survive the concurrent `feat/prd-087-ui-uplift`
     session; re-check the function md5 after applying in case that session re-applies.
3. Verify (live SQL, must match dry-run):
   - `select count(*) from get_machine_health() where days_since_visit >= 0 and last_plan_days <> days_since_visit;` → **0**.
   - `select machine_name, days_since_visit, last_plan_days from get_machine_health() where machine_name in ('ADDMIND-1007-0000-W0','HUAWEI-2003-0000-B1','MINDSHARE-1009-4500-O1');` → last_plan_days == days_since_visit (1 == 1).
   - Fleet-wide `days_since_visit` md5 identical before vs after.
4. Apply the migration (MCP or `supabase db`), commit function + PRD + `PRD-088-EXECUTION-LOG.md` on
   `fix/prd-088-unify-plan-clock`, push to main. Backend-only → no Vercel deploy. Report commit SHA +
   migration version.
5. (Optional, hand to the ui-uplift branch) remove the now-redundant `last plan {n}d` chip in
   `SnapshotTab.tsx` (~L1670).

**Acceptance:** `last_plan_days == days_since_visit` for every machine; ADDMIND/HUAWEI/MINDSHARE read the
same on both clocks; `days_since_visit` unchanged; zero data changes.

**Rollback:** `CREATE OR REPLACE` restoring the prior `plan_data` CTE + `pld` columns.
