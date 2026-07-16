# /goal — PRD-087 planned=visited (run once)

Paste as your `/goal` in Claude Code. **AUTO MODE**: implement, verify, ship. Backend = one function
(`get_machine_health`); route the function change through **Cody** (canonical reader review) before
applying. No migration to data, no write-path change, no touch to `days_since_visit`/
`v_machine_health_signals`. Project ref: eizcexopcuoycuosittm.

---

**GOAL:** Make the "last plan" clock execution-based so planned = visited for dispatched+complete refills.
Spec: `docs/prds/PRD-087-planned-equals-visited-when-executed.md`.

**Steps:**

1. Read the PRD in full.
2. `CREATE OR REPLACE FUNCTION public.get_machine_health()` changing ONLY the `plan_data` CTE: add
   `AND rpo.dispatched = true` to its WHERE (keep `operator_status='approved'` and
   `plan_date <= CURRENT_DATE`). Everything else in the function byte-identical. Run it past Cody first.
3. (Optional, tiny) In `src/app/(app)/refill/SnapshotTab.tsx` (~L1670) relabel the `last plan {n}d` chip
   to `last executed {n}d`, or hide it when it equals `last visit`.
4. Verify with live SQL:
   - `select machine_name, days_since_visit, last_plan_date, last_plan_days from get_machine_health()
where machine_name in ('VOXMCC-1011-0101-B0','ACTIVATE-2005-0000-W0','OMDCW-1021-0100-W0');`
     → `last_plan_days` should equal `days_since_visit` (0) for these (dispatched today).
   - Pick a machine with an approved-but-undispatched-only recent plan and confirm its `last_plan_days`
     no longer reads more recent than its real visit.
   - Confirm `days_since_visit` values are unchanged vs before.
5. Apply the migration (MCP or `supabase db`), commit the function + PRD + a short
   `PRD-087-EXECUTION-LOG.md` on `fix/prd-087-planned-equals-visited`; if the FE chip was touched, deploy
   to Vercel. Report commit SHA (+ URL if FE changed).

**Acceptance:** dispatched+complete machines show `last plan == last visit`; approved-only plans don't
inflate the planned clock; `days_since_visit` untouched; zero data changes.

**Rollback:** `CREATE OR REPLACE` reverting the single WHERE line (and revert the FE label if changed).
