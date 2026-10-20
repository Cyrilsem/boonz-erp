-- Rollback for PRD-145 P3-6: restores is_internal_move_dispatch and tg_mark_internal_move_pair to their pre-migration
-- text. Rows written while it was live keep their is_internal_move value.
DO $patch$
DECLARE
  v_def text; n int; i int; pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.is_internal_move_dispatch(uuid)'::regprocedure);
  pairs := ARRAY[
    ARRAY[$a$        AND COALESCE(add_leg.include,   true)  = true
        -- PRD-145 P3-6: an intra_machine Add New is the other end of its own intra_machine Remove, never of a wh Remove.
        AND NOT (COALESCE(rd.source_kind, 'unknown') = 'wh' AND add_leg.source_kind = 'intra_machine')
        AND ($a$,
          $a$        AND COALESCE(add_leg.include,   true)  = true
        AND ($a$]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd145_p3_6 rollback: is_internal_move_dispatch anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.tg_mark_internal_move_pair()'::regprocedure);
  pairs := ARRAY[
    ARRAY[$a$         AND rd.wh_approved_at IS NULL
         -- PRD-145 P3-6: an intra_machine Add New never stamps a wh Remove.
         AND NOT (NEW.source_kind = 'intra_machine' AND COALESCE(rd.source_kind, 'unknown') = 'wh')
      RETURNING rd.dispatch_id$a$,
          $a$         AND rd.wh_approved_at IS NULL
      RETURNING rd.dispatch_id$a$]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd145_p3_6 rollback: tg_mark_internal_move_pair anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
