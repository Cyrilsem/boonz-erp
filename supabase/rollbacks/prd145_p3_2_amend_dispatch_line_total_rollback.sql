-- Rollback for PRD-145 P3-2: drops amend_dispatch_line_total and takes it off the canonical-write allowlist.
-- Lines already amended keep their lot rows, warehouse moves and edit-log rows (they are real stock moves).
DO $patch$
DECLARE
  v_def text; n int;
  c_old text := $a$    'close_return_backlog','amend_dispatch_line_total'];$a$;
  c_new text := $a$    'close_return_backlog'];$a$;
BEGIN
  v_def := pg_get_functiondef('public.enforce_canonical_dispatch_write()'::regprocedure);
  n := (length(v_def) - length(replace(v_def, c_old, ''))) / length(c_old);
  IF n <> 1 THEN RAISE EXCEPTION 'prd145_p3_2 rollback: enforce_canonical_dispatch_write anchor count %', n; END IF;
  EXECUTE replace(v_def, c_old, c_new);
END
$patch$;
DROP FUNCTION public.amend_dispatch_line_total(jsonb, numeric, text);
