-- PRD-145 P3-6 test: the NOOK-1019-0200-B1 A12 shape of 20 Oct. Run after the migration in one transaction; ends with
-- RAISE so nothing persists. PASS = 'PRD145_P3_6 PASS ...'. Run without the migration it reports FAIL on cases 1 and 2
-- (the bug). Popit - Orange Squeeze leaves A12 both to A13 (add_intra_machine_move) and to the warehouse (add_dispatch_row
-- Remove, source_kind 'wh'), in both orders, on dates three to five days ahead.
DO $t$
DECLARE
  c_m  uuid := (SELECT machine_id FROM machines WHERE official_name = 'NOOK-1019-0200-B1');
  c_bp uuid := '20746a86-af2e-45c1-92b8-da5ee9517723';
  c_wh uuid := '4bebef68-9e36-4a5c-9c2c-142f8dbdae85';
  v_d  date := current_date + 3;
  r jsonb; v_rm uuid; v_add uuid; v_im boolean; v_intra_im boolean;
  ok1 boolean := false; ok2 boolean := false; ok3 boolean := false; ok4 boolean := false;
  e1 text; e2 text; e3 text; e4 text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);

  -- 1. intra move first, then the wh Remove (the 20 Oct order): the wh Remove stays a warehouse return
  BEGIN
    PERFORM public.add_intra_machine_move(c_m, 'A12', 'A13', c_bp, 2, v_d, 'PRD-145 P3-6 test move');
    r := public.add_dispatch_row(c_m, 'A12', c_bp, 1, 'Remove', v_d, 'wh', c_wh, NULL, 'operator_admin', 'PRD-145 P3-6 test', NULL, NULL);
    v_rm := (r->>'dispatch_id')::uuid;
    SELECT is_internal_move INTO v_im FROM refill_dispatching WHERE dispatch_id = v_rm;
    ok1 := NOT v_im AND NOT public.is_internal_move_dispatch(v_rm);
    e1 := format('wh Remove is_internal_move %s, fn %s', v_im, public.is_internal_move_dispatch(v_rm));
  EXCEPTION WHEN OTHERS THEN e1 := SQLERRM; END;

  -- 2. wh Remove first, then the intra move: the arriving intra Add New does not stamp it
  BEGIN
    r := public.add_dispatch_row(c_m, 'A12', c_bp, 1, 'Remove', v_d + 1, 'wh', c_wh, NULL, 'operator_admin', 'PRD-145 P3-6 test', NULL, NULL);
    v_rm := (r->>'dispatch_id')::uuid;
    PERFORM public.add_intra_machine_move(c_m, 'A12', 'A13', c_bp, 2, v_d + 1, 'PRD-145 P3-6 test move');
    SELECT is_internal_move INTO v_im FROM refill_dispatching WHERE dispatch_id = v_rm;
    ok2 := NOT v_im AND NOT public.is_internal_move_dispatch(v_rm);
    e2 := format('wh Remove is_internal_move %s, fn %s', v_im, public.is_internal_move_dispatch(v_rm));
  EXCEPTION WHEN OTHERS THEN e2 := SQLERRM; END;

  -- 3. the intra Remove leg of the move is still an in-machine move
  BEGIN
    SELECT bool_and(public.is_internal_move_dispatch(dispatch_id)) INTO v_intra_im FROM refill_dispatching
     WHERE machine_id = c_m AND dispatch_date = v_d + 1 AND action = 'Remove' AND source_kind = 'intra_machine';
    ok3 := COALESCE(v_intra_im, false);
    e3 := format('intra Remove internal %s', v_intra_im);
  EXCEPTION WHEN OTHERS THEN e3 := SQLERRM; END;

  -- 4. control (MC-2004): a wh Remove whose product lands as a wh Add New on another shelf is still a move
  BEGIN
    r := public.add_dispatch_row(c_m, 'A12', c_bp, 1, 'Remove', v_d + 2, 'wh', c_wh, NULL, 'operator_admin', 'PRD-145 P3-6 test', NULL, NULL);
    v_rm := (r->>'dispatch_id')::uuid;
    r := public.add_dispatch_row(c_m, 'A13', c_bp, 1, 'Add New', v_d + 2, 'wh', c_wh, NULL, 'operator_admin', 'PRD-145 P3-6 test', NULL, NULL);
    SELECT is_internal_move INTO v_im FROM refill_dispatching WHERE dispatch_id = v_rm;
    ok4 := v_im;
    e4 := format('wh Remove + wh Add New is_internal_move %s', v_im);
  EXCEPTION WHEN OTHERS THEN e4 := SQLERRM; END;

  RAISE EXCEPTION 'PRD145_P3_6 % | intra_then_wh %:% | wh_then_intra %:% | intra_leg %:% | mc2004_control %:%',
    CASE WHEN ok1 AND ok2 AND ok3 AND ok4 THEN 'PASS' ELSE 'FAIL' END, ok1, e1, ok2, e2, ok3, e3, ok4, e4;
END
$t$;
