-- PRD-141 item 7 rollback: edit_purchase_order_line stops moving warehouse batches.
DO $rb$
DECLARE v text;
BEGIN
  v := pg_get_functiondef('public.edit_purchase_order_line(uuid,numeric,numeric,date,text)'::regprocedure);
  v := regexp_replace(v, '  -- PRD-141 item 7: move the received batches.*?  END IF;\n\n', '', 's');
  v := replace(v, '    ''wh_batches_updated'',       v_wh_batches_updated,' || chr(10), '');
  v := replace(v, chr(10) || '  v_wh_batches_updated  integer := 0; -- PRD-141 item 7', '');
  EXECUTE v;
END $rb$;
REVOKE EXECUTE ON FUNCTION public.edit_purchase_order_line(uuid, numeric, numeric, date, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.edit_purchase_order_line(uuid, numeric, numeric, date, text) TO authenticated, service_role;
