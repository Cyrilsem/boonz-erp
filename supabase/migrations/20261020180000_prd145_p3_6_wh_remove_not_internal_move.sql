-- PRD-145 P3-6: a warehouse Remove is never an in-machine move because of an intra_machine Add New.
-- NOOK-1019-0200-B1 A12, 20 Oct: Popit left A12 two ways, some to the warehouse (wh Remove legs 0bd0ae62, a6e3a29f) and
-- some to A13 (intra_machine Remove + Add New pairs, linked by m2m_partner_id / m2m_transfer_id). The MC-2004 heuristic in
-- is_internal_move_dispatch matched each wh Remove to the intra_machine Add New on A13 (same product, other shelf), and
-- tg_mark_internal_move_pair stamped both wh Removes is_internal_move=true, which takes them out of the warehouse
-- return queue. An intra_machine Add New is already paired with its own intra_machine Remove, so it can never stand for
-- a wh Remove.
--   is_internal_move_dispatch    the Add-leg match skips intra_machine Add legs when the Remove is source_kind 'wh'
--   tg_mark_internal_move_pair   an arriving intra_machine Add New does not stamp open wh Removes
DO $patch$
DECLARE
  v_def text; n int; i int; pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.is_internal_move_dispatch(uuid)'::regprocedure);
  pairs := ARRAY[
    ARRAY[$a$        AND COALESCE(add_leg.include,   true)  = true
        AND ($a$,
          $a$        AND COALESCE(add_leg.include,   true)  = true
        -- PRD-145 P3-6: an intra_machine Add New is the other end of its own intra_machine Remove, never of a wh Remove.
        AND NOT (COALESCE(rd.source_kind, 'unknown') = 'wh' AND add_leg.source_kind = 'intra_machine')
        AND ($a$]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd145_p3_6: is_internal_move_dispatch anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.tg_mark_internal_move_pair()'::regprocedure);
  pairs := ARRAY[
    ARRAY[$a$         AND rd.wh_approved_at IS NULL
      RETURNING rd.dispatch_id$a$,
          $a$         AND rd.wh_approved_at IS NULL
         -- PRD-145 P3-6: an intra_machine Add New never stamps a wh Remove.
         AND NOT (NEW.source_kind = 'intra_machine' AND COALESCE(rd.source_kind, 'unknown') = 'wh')
      RETURNING rd.dispatch_id$a$]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd145_p3_6: tg_mark_internal_move_pair anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
