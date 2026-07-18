# /goal — PRD-099 fix `approve_return` provenance (run once)

Paste as your `/goal` in Claude Code. **AUTO MODE**: implement, verify, ship. Backend = one function
(`approve_return`); route the change through **Cody** (protected-entity writer, Article 14) before
applying. No schema change, no data migration. Project ref: eizcexopcuoycuosittm.

---

**GOAL:** Make `approve_return` satisfy `wh_provenance_event_required` for manual/legacy returns.
Spec: `docs/prds/PRD-099-approve-return-provenance-fix.md`. (Sibling to PRD-098 return-approval-workflow —
align with it.)

**Root cause (already diagnosed):** `approve_return` flips the row to non-whitelisted
`provenance_reason='dispatch_return'` but never sets `source_event_id`. Pipeline returns already have an
event id (pass); manual/legacy rows (`unknown_pre_migration`, NULL event) fail the constraint.

**Steps:**

1. Read the PRD in full.
2. `CREATE OR REPLACE FUNCTION public.approve_return(...)` with two additions only:
   - Declare `v_event uuid := gen_random_uuid();`
   - `PERFORM set_config('app.source_event_id', v_event::text, true);` alongside the existing
     `set_config('app.provenance_reason','dispatch_return',true)`.
   - Add `source_event_id = COALESCE(source_event_id, v_event)` to the `UPDATE warehouse_inventory … SET`.
   - (Optional) include `v_event` in the `return_approval_log` insert.
     Everything else byte-identical (role gate, note check, quarantine-provenance guard, FOR UPDATE, return
     payload). Run past Cody first.
3. Verify with live SQL against a legacy row (in a rolled-back tx first):
   - `select approve_return('6cb1b7b2-2beb-…'::uuid, '<approver_uuid>', 'test approve barebells hazelnut',
null, 5);` → succeeds; then
   - `select provenance_reason, source_event_id from warehouse_inventory where wh_inventory_id='6cb1b7b2-…';`
     → `dispatch_return` + non-null `source_event_id`.
   - Confirm a pipeline row (e.g. `1305c7be-…`, already has an event id) keeps its original
     `source_event_id` after approval (COALESCE, unchanged).
4. **Reconcile the stopgap:** the Barebells Hazelnut units were credited manually on 2026-07-09. Do NOT let
   the fixed approval double-count — discard the pending Hazelnut quarantine rows OR reverse the manual
   credit. Confirm with CS which side to keep before approving those specific rows in prod.
5. Apply the migration (MCP or `supabase db`), commit the function + PRD + a short
   `PRD-099-EXECUTION-LOG.md` on `fix/prd-099-approve-return-provenance`. Report commit SHA.

**Acceptance:** approving a return succeeds for manual/legacy rows and pipeline rows; approved row has
`dispatch_return` + non-null `source_event_id`; pipeline rows keep their original event id; no constraint,
whitelist, or data change.

**Rollback:** `CREATE OR REPLACE FUNCTION approve_return(...)` reverting the two added lines. No data undo.
