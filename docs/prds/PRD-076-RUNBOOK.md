# PRD-076 Runbook — shadow-diff referee (branch → capture → diff → interpret)

The reusable output-level referee for Wave 0b/0c and beyond. Proves a change altered the
plan **only where intended**, at row level — beyond the engine-md5 byte-identical check.

## Preconditions

- A golden baseline run exists (PRD-078, `label='golden_v1'`) to diff candidates against.
- The engine change under test is applied **on a preview branch only**, behind its flag.

## Loop

1. **Branch.** `create_branch` → note the branch `project_ref`. (Schema-only: seed fleet
   data from the golden fixture — PRD-078 — before capturing; a bare branch yields an
   empty plan.)
2. **Opt in on the branch session:** `SET refill_qa.on_branch = 'true';` (never set on
   prod; `capture_run` refuses without it).
3. **Capture baseline** (flag OFF): `SELECT refill_qa.capture_run('<plan_date>','baseline');`
   → baseline `run_id`.
4. **Enable the candidate flag**, re-run: `SELECT refill_qa.capture_run('<plan_date>','candidate');`
   → candidate `run_id`.
5. **Diff:** `SELECT refill_qa.diff_runs('<baseline>','<candidate>');`
   - Row detail: `SELECT * FROM refill_qa.diff_run_rows('<baseline>','<candidate>') WHERE class <> 'unchanged';`
6. **Interpret:**
   - Referee/verify PRDs (076/085): expect `identical=true`. Any non-unchanged row = FAIL.
   - Guard/behaviour PRDs (079-084): expect ONLY the intended delta class/rows. Anything
     else = unexpected diff = PARK.
   - `inputs_differ=true` means the input fingerprints diverged — the diff is not
     apples-to-apples; re-capture on frozen inputs before trusting it.
7. **Discard the branch** when done.

## Classes

`unchanged | added | removed | qty_changed | action_changed | status_changed | reason_changed`
at plan-slot grain `(machine_id, shelf_id, pod_product_id)`. `identical` = all non-unchanged
counts zero. `net_units` = Σcandidate.qty − Σbaseline.qty.
