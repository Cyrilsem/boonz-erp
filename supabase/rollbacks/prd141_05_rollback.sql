-- PRD-141 item 5 rollback: remove the m2m_transfer queue branch and restore approve_m2m_transfer.
DO $rb$
DECLARE v text; i int; j int;
BEGIN
  v := pg_get_viewdef('public.v_wm_confirmations'::regclass, true);
  i := strpos(v, '        ), m2m_candidates AS (');
  j := strpos(v, '        ), candidates AS (');
  v := substr(v, 1, i - 1) || substr(v, j);
  v := regexp_replace(v, '\n        UNION ALL\n         SELECT m2m_candidates\.line_id.*?FROM m2m_candidates', '', 's');
  EXECUTE 'CREATE OR REPLACE VIEW public.v_wm_confirmations AS ' || v;
  v := pg_get_functiondef('public.approve_m2m_transfer(uuid,uuid)'::regprocedure);
  v := replace(v, ' AND NOT EXISTS (SELECT 1 FROM public.refill_dispatching WHERE m2m_transfer_id = p_transfer_id AND is_m2m AND action = ''Remove'' AND driver_confirmed_at IS NOT NULL) THEN', ' THEN');
  v := replace(v, 'SELECT dispatch_id, COALESCE(driver_confirmed_qty, quantity) AS quantity FROM', 'SELECT dispatch_id, quantity FROM');
  v := replace(v, 'SELECT d0.dispatch_id, COALESCE((SELECT s0.driver_confirmed_qty FROM public.refill_dispatching s0 WHERE s0.dispatch_id = d0.m2m_partner_id), d0.quantity) AS quantity, d0.m2m_partner_id FROM public.refill_dispatching d0', 'SELECT dispatch_id, quantity, m2m_partner_id FROM public.refill_dispatching');
  EXECUTE v;
  -- wm_confirm_line keeps accepting the source (harmless with no queue rows of that source).
END $rb$;
REVOKE EXECUTE ON FUNCTION public.approve_m2m_transfer(uuid, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.approve_m2m_transfer(uuid, uuid) TO authenticated, service_role;
