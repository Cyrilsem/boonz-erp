-- Rollback for 20261018073655_prd141_26_remove_lot_same_product.sql: restore the shelf-earliest lot order.
DO $rb$
DECLARE v text;
BEGIN
  v := pg_get_functiondef('public.add_dispatch_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text,uuid)'::regprocedure);
  v := replace(v, '   ORDER BY (pil.boonz_product_id = p_boonz_product_id) DESC NULLS LAST, pil.expiration_date ASC NULLS LAST  -- PRD-141 item 26',
                  '   ORDER BY pil.expiration_date ASC NULLS LAST');
  EXECUTE v;
END $rb$;
REVOKE EXECUTE ON FUNCTION public.add_dispatch_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text,uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.add_dispatch_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text,uuid) TO authenticated, service_role;
