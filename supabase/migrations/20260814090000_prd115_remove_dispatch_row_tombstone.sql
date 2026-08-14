-- PRD-115 §2.1 - the resurrection killer, half one.
--
-- INCIDENT (NISSAN-0804, 2026-08-14 ~14:27): CS re-scoped shelf A15 three times
-- while the packer was packing. remove_dispatch_row set include=false on the
-- dispatch row and stopped there. The linked refill_plan_output row stayed
-- operator_status='approved', so it remained a live instruction, and the next
-- push re-created what had just been removed. Dubai Popcorn came back twice.
--
-- The fix is that a removal at the dispatch layer is a decision about the PLAN,
-- not only about the row. remove_dispatch_row now stamps every refill_plan_output
-- row linked to the removed dispatch row (rpo.dispatch_id = the removed
-- dispatch_id) as 'rejected' and appends the removal provenance.
--
-- WHY operator_comment AND NOT comment:
--   refill_plan_output carries two free-text fields. `comment` is engine-authored
--   (the planner writes tier/score narration into it and push_plan_to_dispatch
--   copies it verbatim onto the dispatch row). `operator_comment` is the
--   human-authored field. A removal is a human decision, so it belongs in the
--   human field; writing into `comment` would corrupt an engine output and would
--   ride into any dispatch comment the row later produced.
--
-- NO SCHEMA CHANGE. PRD §3 forbids inventing a column here; if a first-class
-- tombstone column is ever warranted, Dara designs it first.
--
-- SINGLE TRANSACTION: the UPDATE sits inside the same function body as the
-- include=false write and the edit-log INSERT, so a dispatch row can never be
-- removed without its plan row being tombstoned in the same commit.
--
-- NO-OP WHEN THERE IS NO LINK: an operator-added dispatch row (created_by_edit)
-- has no refill_plan_output parent. ROW_COUNT is then 0 and the function returns
-- plan_rows_tombstoned=0. That is reported, not silent.
--
-- EVERY GUARD ABOVE IS BYTE-IDENTICAL to the prior definition: the role gate, the
-- edit-role gate, the FOR UPDATE lock, the picked_up refusal, the v_before
-- snapshot, the include=false UPDATE and the edit-log INSERT are unchanged.
-- The additions are the v_tomb declaration, the UPDATE below, and one additive
-- key on the returned envelope.

CREATE OR REPLACE FUNCTION public.remove_dispatch_row(p_dispatch_id uuid, p_edit_role text, p_reason text DEFAULT NULL::text, p_conductor_session text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row    refill_dispatching%ROWTYPE;
  v_role   text;
  v_before jsonb;
  v_tomb   int := 0;   -- PRD-115 §2.1: plan rows tombstoned by this removal
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','remove_dispatch_row',true);

  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NOT NULL AND v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'forbidden: remove_dispatch_row requires warehouse / operator_admin';
  END IF;
  IF p_edit_role NOT IN ('warehouse_manager','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'remove_dispatch_row not allowed for driver';
  END IF;

  SELECT * INTO v_row FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch % not found', p_dispatch_id; END IF;
  IF v_row.picked_up THEN RAISE EXCEPTION 'dispatch % already picked up — too late to remove', p_dispatch_id; END IF;

  v_before := jsonb_build_object('include', v_row.include, 'quantity', v_row.quantity,
                                 'boonz_product_id', v_row.boonz_product_id, 'shelf_id', v_row.shelf_id);

  UPDATE public.refill_dispatching
  SET include             = false,
      edit_count          = edit_count + 1,
      last_edited_by      = auth.uid(),
      last_edited_by_role = p_edit_role,
      last_edited_at      = now()
  WHERE dispatch_id = p_dispatch_id;

  -- PRD-115 §2.1 TOMBSTONE. Without this the plan row survives the removal as a
  -- live 'approved' instruction and the next push re-creates the dispatch row.
  -- operator_status='rejected' takes the row out of push_plan_to_dispatch's
  -- candidate set (WHERE operator_status='approved') and out of
  -- approve_refill_plan's re-approval set (WHERE operator_status='pending'),
  -- so neither writer can revive it.
  UPDATE public.refill_plan_output rpo
     SET operator_status  = 'rejected',
         operator_comment = COALESCE(NULLIF(trim(COALESCE(rpo.operator_comment,'')), '') || E'\n', '')
                            || format('removed_at_dispatch_by %s %s',
                                      COALESCE(auth.uid()::text, p_edit_role, 'unknown'),
                                      to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ')),
         reviewed_at      = now()
   WHERE rpo.dispatch_id = p_dispatch_id;
  GET DIAGNOSTICS v_tomb = ROW_COUNT;

  INSERT INTO public.refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
  VALUES
    (p_dispatch_id, auth.uid(), p_edit_role, 'remove', v_before, NULL, p_reason, p_conductor_session);

  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'edit_kind','remove', 'include', false,
                            'plan_rows_tombstoned', v_tomb);
END $function$;

COMMENT ON FUNCTION public.remove_dispatch_row(uuid, text, text, text) IS
  'PRD-115 §2.1. Removing a dispatch row also TOMBSTONES every refill_plan_output row linked to it (operator_status=rejected + removed_at_dispatch_by stamp appended to operator_comment), in the same transaction. Before this, the plan row stayed approved and the next push_plan_to_dispatch re-created the removed row (NISSAN-0804, 2026-08-14). The stamp goes in operator_comment, never in comment: comment is engine-authored and rides onto the dispatch row. plan_rows_tombstoned=0 is the honest report for an operator-added row that has no plan parent.';
