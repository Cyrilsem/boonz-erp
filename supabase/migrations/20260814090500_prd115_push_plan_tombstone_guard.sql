-- PRD-115 §2.2 - the resurrection killer, half two: belt and braces.
--
-- §2.1 rejects the plan row at removal time, which takes it out of BOTH writer
-- candidate sets (push reads operator_status='approved', approve_refill_plan
-- reads operator_status='pending'). This migration adds the second, independent
-- barrier the PRD asks for: push_plan_to_dispatch refuses to create a dispatch
-- row for a plan row that is linked to an operator-REMOVED dispatch row on the
-- same plan_date, REGARDLESS OF operator_status.
--
-- Why a second barrier at all: operator_status is a mutable text column. Any
-- hand-run UPDATE, any future re-approval path, or any plan-regeneration that
-- reuses the row can flip 'rejected' back to 'approved' and hand the resurrection
-- vector straight back. The edit log is append-only; a 'remove' entry against a
-- dispatch row that is still include=false is a fact that cannot be edited away.
-- The guard reads that fact, not the status.
--
-- The predicate is deliberately narrow (an AND of three conditions):
--   1. rd.dispatch_id = line.dispatch_id  - the plan row is LINKED to this row.
--   2. rd.include = false                 - the removal has not been undone.
--   3. an edit_log row with edit_kind='remove' - it was an OPERATOR removal, not
--      a skip, a cancel, or an engine-side include flip.
-- All three must hold. A plan row whose dispatch row was removed and then
-- re-included is NOT tombstoned, which is the correct read of an undo.
--
-- SURGICAL TRANSFORM, not a re-typed body. push_plan_to_dispatch is 24 kB of
-- conservation checks, RC-01 idempotency lookups, M2M pairing and FIFO batch
-- walking. PRD §3 requires the duplicate-unstarted, packed-row and conservation
-- guards to stay BYTE-IDENTICAL, and the only way to be certain of that is to
-- never retype them. This follows the pattern established by
-- 20260709015534_drift_kill_p1_wire_push_and_stitch.sql: pull the live
-- definition, refuse to proceed on base-md5 drift, refuse to proceed unless each
-- anchor appears EXACTLY once, splice, EXECUTE.
--
-- Base md5 (v11_rc01_single_writer_d43_s193): 5f858899eecef1e75e6ae6d00fcc1c8b
-- Rollback: re-run 20260806003000_prd110_d43_push_roles_and_s193_returned_squat.sql
--           followed by 20260709015534 (slot guard), or restore that md5.

DO $prd115$
DECLARE
  v_def text;

  -- Anchor 1: the DECLARE tail. v_slot_guard is the last declared variable.
  A_DECL text := E'  v_slot_guard           jsonb := NULL;';

  -- Anchor 2: the head of the ONLY loop that creates dispatch rows from plan
  -- rows. Reproduced verbatim, including the trailing newline after LOOP.
  A_LOOP text := $anchor$  FOR line IN
    SELECT * FROM refill_plan_output
    WHERE plan_date = p_plan_date AND machine_name = p_machine_name
      AND operator_status = 'approved' AND dispatched = false
  LOOP
$anchor$;

  -- Anchor 3: the response version key.
  A_VER  text := '''rpc_version'',''v11_rc01_single_writer_d43_s193''';

  G_BODY text := $guard$    -- PRD-115 §2.2 TOMBSTONE GUARD. A plan row linked to a dispatch row an
    -- operator REMOVED is dead for this plan_date, whatever operator_status now
    -- says. Without this, flipping the status back to 'approved' by any means
    -- re-opens the resurrection vector §2.1 closes (NISSAN-0804, 2026-08-14).
    -- Narrow on purpose: linked AND still-excluded AND an append-only 'remove'
    -- edit-log entry. A removal that was undone (include back to true) is not a
    -- tombstone and this guard lets it through.
    IF line.dispatch_id IS NOT NULL AND EXISTS (
      SELECT 1
        FROM public.refill_dispatching rd
        JOIN public.refill_dispatching_edit_log el
          ON el.dispatch_id = rd.dispatch_id AND el.edit_kind = 'remove'
       WHERE rd.dispatch_id   = line.dispatch_id
         AND rd.dispatch_date = p_plan_date
         AND COALESCE(rd.include, true) = false
    ) THEN
      v_tombstoned := v_tombstoned + 1;
      CONTINUE;
    END IF;

$guard$;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
   WHERE proname = 'push_plan_to_dispatch'
     AND pg_get_function_identity_arguments(oid) = 'p_plan_date date, p_machine_name text';
  IF v_def IS NULL THEN
    RAISE EXCEPTION 'PRD-115: push_plan_to_dispatch(date, text) not found';
  END IF;

  -- Idempotent: a re-run against an already-patched body is a no-op, not a
  -- double-splice. Checked BEFORE the md5 gate, which the patch itself moves.
  IF position('PRD-115 §2.2 TOMBSTONE GUARD' in v_def) > 0 THEN
    RAISE NOTICE 'PRD-115: push tombstone guard already present, nothing to do';
    RETURN;
  END IF;

  IF md5(v_def) <> '5f858899eecef1e75e6ae6d00fcc1c8b' THEN
    RAISE EXCEPTION 'PRD-115: push_plan_to_dispatch base drift (md5 %). Re-derive the anchors against the live body before splicing.', md5(v_def);
  END IF;

  IF (length(v_def) - length(replace(v_def, A_DECL, ''))) / length(A_DECL) <> 1 THEN
    RAISE EXCEPTION 'PRD-115: A_DECL anchor is not unique in push_plan_to_dispatch';
  END IF;
  IF (length(v_def) - length(replace(v_def, A_LOOP, ''))) / length(A_LOOP) <> 1 THEN
    RAISE EXCEPTION 'PRD-115: A_LOOP anchor is not unique in push_plan_to_dispatch';
  END IF;
  IF (length(v_def) - length(replace(v_def, A_VER, ''))) / length(A_VER) <> 1 THEN
    RAISE EXCEPTION 'PRD-115: A_VER anchor is not unique in push_plan_to_dispatch';
  END IF;

  v_def := replace(v_def, A_DECL, A_DECL || E'\n  v_tombstoned           int := 0;');
  v_def := replace(v_def, A_LOOP, A_LOOP || G_BODY);
  v_def := replace(v_def, A_VER,
    E'''lines_tombstoned'', v_tombstoned,\n    ''rpc_version'',''v12_prd115_tombstone_guard''');

  EXECUTE v_def;

  RAISE NOTICE 'PRD-115: push_plan_to_dispatch patched to v12, md5 %',
    (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc
      WHERE proname = 'push_plan_to_dispatch'
        AND pg_get_function_identity_arguments(oid) = 'p_plan_date date, p_machine_name text');
END $prd115$;

COMMENT ON FUNCTION public.push_plan_to_dispatch(date, text) IS
  'v12 (PRD-115 §2.2). Single writer from refill_plan_output to refill_dispatching. Carries the PRD-115 tombstone guard: a plan row LINKED to a dispatch row an operator removed (include=false + an append-only edit_kind=remove entry) never produces a dispatch row on that plan_date, regardless of operator_status. That is the belt to §2.1 braces, because operator_status is mutable and the edit log is not. Everything else (conservation stop-ship, RC-01 5a/5b idempotency, M2M pairing, FIFO batch walk, the ON CONFLICT duplicate-unstarted guard) is byte-identical to v11.';
