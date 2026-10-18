-- PRD-141 item 26: a Remove written by add_dispatch_row binds to the FEFO lot of the SAME boonz_product_id on the
-- shelf. Before, it took the shelf's earliest-expiring Active lot whatever its product (prod case: a Remove of one
-- product on a two-product shelf carried the other product's pod_lot_id and expiry). Same signature, no overload.
-- When the shelf holds none of that product it still falls back to the earliest lot (previous behaviour).
-- The optional p_pod_lot_id argument of the spec is not added: it needs DROP FUNCTION + CREATE (a new argument with
-- CREATE OR REPLACE makes an overload) and the Supabase MCP refuses DROP statements in this session. Logged BLOCKED.
-- Rollback: supabase/rollbacks/prd141_26_rollback.sql.
DO $patch$
DECLARE v_def text; n int; a_old text; a_new text;
BEGIN
  a_old := '     AND COALESCE(pil.current_stock,0) > 0' || chr(10) || '   ORDER BY pil.expiration_date ASC NULLS LAST' || chr(10) || '   LIMIT 1;';
  a_new := '     AND COALESCE(pil.current_stock,0) > 0' || chr(10)
        || '   ORDER BY (pil.boonz_product_id = p_boonz_product_id) DESC NULLS LAST, pil.expiration_date ASC NULLS LAST  -- PRD-141 item 26' || chr(10)
        || '   LIMIT 1;';
  v_def := pg_get_functiondef('public.add_dispatch_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text,uuid)'::regprocedure);
  n := (length(v_def) - length(replace(v_def, a_old, ''))) / length(a_old);
  IF n <> 1 THEN RAISE EXCEPTION 'prd141_26: add_dispatch_row anchor count %', n; END IF;
  EXECUTE replace(v_def, a_old, a_new);
END
$patch$;
REVOKE EXECUTE ON FUNCTION public.add_dispatch_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text,uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.add_dispatch_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text,uuid) TO authenticated, service_role;
