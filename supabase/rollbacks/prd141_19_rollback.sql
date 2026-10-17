-- PRD-141 item 19 rollback: last visit back to v_delivery_verification 'landed'; stop stamping delivered_at.
-- The delivered_at column and its backfill are kept (harmless, and useful evidence).
DO $rb$
DECLARE
  v_def text := pg_get_viewdef('public.v_machine_health_signals'::regclass, true);
  i int := strpos(v_def, 'last_visit AS MATERIALIZED (');
  j int := strpos(v_def, 'manual_refill_visit AS (');
  v_old_cte text := 'last_visit AS MATERIALIZED (' || chr(10)
    || '         SELECT b_1.machine_id,' || chr(10)
    || '            ( SELECT max(dv.dispatch_date) AS max' || chr(10)
    || '                   FROM v_delivery_verification dv' || chr(10)
    || '                  WHERE dv.machine_id = b_1.machine_id AND dv.verdict = ''landed''::text) AS last_visit_date' || chr(10)
    || '           FROM base b_1' || chr(10)
    || '        ), manual_refill_visit AS (';
  v text;
BEGIN
  EXECUTE 'CREATE OR REPLACE VIEW public.v_machine_health_signals AS ' || substr(v_def, 1, i - 1) || v_old_cte || substr(v_def, j + length('manual_refill_visit AS ('));
  v := pg_get_functiondef('public.receive_dispatch_line(uuid,numeric,uuid,jsonb,boolean,text)'::regprocedure);
  v := regexp_replace(v, '\n         delivered_at = CASE WHEN v_dispatch\.action[^\n]*', '');
  EXECUTE v;
END $rb$;
