-- Rollback for PRD-145 P3-4: drops the repin trigger and the three functions, takes the repin writer off the
-- canonical-write allowlist and restores pack_dispatch_line's child insert. The 'repin' edit kind stays in the checks
-- while edit-log rows of that kind exist (dropping it would fail on them).
DROP TRIGGER trg_repin_dispatch_on_lot_change ON public.warehouse_inventory;
DROP FUNCTION public.tg_repin_dispatch_on_lot_change();
DROP FUNCTION public.get_plan_pin_preview(date);
DROP FUNCTION public.zero_ghost_lot(uuid, text);
DROP FUNCTION public.get_ghost_lot_candidates();
DO $patch$
DECLARE
  v_def text; n int; i int; pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.pack_dispatch_line(uuid,jsonb,uuid)'::regprocedure);
  pairs := ARRAY[
    ARRAY[$a$item_added, expiry_date, from_wh_inventory_id, pack_outcome, source_origin, parent_dispatch_id, source_kind, from_warehouse_id, source_warehouse_id) VALUES ($a$,
          $a$item_added, expiry_date, from_wh_inventory_id, pack_outcome, source_origin, parent_dispatch_id) VALUES ($a$],
    ARRAY[$a$v_wh_row.expiration_date, v_wh_row.wh_inventory_id, 'packed', v_dispatch.source_origin, p_dispatch_id, v_dispatch.source_kind, v_dispatch.from_warehouse_id, v_dispatch.source_warehouse_id) RETURNING dispatch_id INTO v_new_child_id;  -- PRD-145 P3-4: the child is part of the line$a$,
          $a$v_wh_row.expiration_date, v_wh_row.wh_inventory_id, 'packed', v_dispatch.source_origin, p_dispatch_id) RETURNING dispatch_id INTO v_new_child_id;$a$]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd145_p3_4 rollback: pack_dispatch_line anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
  v_def := pg_get_functiondef('public.enforce_canonical_dispatch_write()'::regprocedure);
  n := (length(v_def) - length(replace(v_def, $a$'mark_picked_up','repin_dispatch_to_fefo',$a$, ''))) / length($a$'mark_picked_up','repin_dispatch_to_fefo',$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'prd145_p3_4 rollback: enforce_canonical_dispatch_write anchor count %', n; END IF;
  EXECUTE replace(v_def, $a$'mark_picked_up','repin_dispatch_to_fefo',$a$, $a$'mark_picked_up',$a$);
END
$patch$;
