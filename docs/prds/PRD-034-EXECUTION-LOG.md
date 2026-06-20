# PRD-034 Execution Log

VOX-sourced returns must not credit Boonz warehouse. Migration files only; nothing
applied to prod without CS sign-off. Forward-only.

## Phase status

| Phase | Item                                        | File                                                                              | Cody                                                          | Applied          |
| ----- | ------------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------- | ---------------- |
| A     | `vox_return_log` ledger table               | `supabase/migrations/20260618090000_prd034_a_vox_return_log.sql`                  | Approve (Art 3 tightening taken: vrl_insert WITH CHECK false) | YES (2026-06-18) |
| B     | guard `receive_dispatch_line` Remove branch | `supabase/migrations/20260618090100_prd034_b_receive_dispatch_line_vox_guard.sql` | Approve (Art 1/4/6/8 clean)                                   | YES (2026-06-18) |
| C     | FE read surface `get_vox_returns`           | deferred per PRD                                                                  | n/a                                                           | NO               |

## Acceptance criteria (from the PRD) — proof tracked here

| AC  | Statement                                                                                                       | Status | Evidence                                                                                                                                           |
| --- | --------------------------------------------------------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | venue_team REMOVE: WH net delta 0, pod archived, one vox_return_log row, jsonb `wh_credit_skipped='venue_team'` | PASS   | rolled-back test: wh_delta=0, pod_archived=1, ledger_rows=1, wh_credit_skipped=venue_team, path=remove_venue_team_no_wh_credit                     |
| 2   | boonz REMOVE: WH credited as before, no vox_return_log row (regression)                                         | PASS   | rolled-back test: wh_delta=2 (=filled), pod_archived=1, ledger_rows=0, wh_credit_skipped=null, path=remove_single_expiry                           |
| 3   | supply resolution prefers per-machine then global default                                                       | PASS   | resolver returns venue_team for vt pair, boonz for boonz pair; ORDER BY machine-match DESC, is_global_default ASC                                  |
| 4   | diff touches only the Remove branch + new DECLARE                                                               | PASS   | pg_get_functiondef old-vs-new identical except v_supply DECLARE + Remove-branch resolver/venue_team branch + additive RETURN key wh_credit_skipped |
| 5   | vox_return_log append-only + RLS on                                                                             | PASS   | RLS enabled; vrl_no_update/vrl_no_delete USING(false); table loads in rolled-back txn                                                              |
| 6   | re-receive refused (item_added guard), no dup ledger row                                                        | PASS   | second call raised 'Dispatch ... already received'; ledger still 1 row                                                                             |

## Notes

- Phase A authored per the PRD DDL verbatim. Cody flag: the `vrl_insert` policy is
  `WITH CHECK (true)`, which permits direct authenticated INSERT on a CS-designated
  protected entity (Article 3). The canonical writer is the DEFINER
  receive_dispatch_line, which bypasses RLS as owner, so tightening the policy to
  `WITH CHECK (false)` blocks direct app writes without affecting the writer. Decision
  deferred to CS at the Phase A gate (see Cody verdict in the turn report).
