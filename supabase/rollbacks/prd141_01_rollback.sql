-- PRD-141 items 0/1 rollback: take the ensure_swap_remove_leg hooks out of add_dispatch_row and
-- push_plan_to_dispatch (helper functions left in place, unreferenced).
DO $rb$
DECLARE v text;
BEGIN
  v := pg_get_functiondef('public.add_dispatch_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text,uuid)'::regprocedure);
  v := replace(v, '    -- PRD-141 item 1: an Add New on a lane holding a different pod writes its Remove leg.' || chr(10)
               || '    IF p_action = ''Add New'' THEN' || chr(10)
               || '      v_swap_remove := public.ensure_swap_remove_leg(p_machine_id, p_shelf_code, v_pod_product_id, p_dispatch_date);' || chr(10)
               || '    END IF;' || chr(10) || chr(10), '');
  v := replace(v, ', ''swap_remove'', v_swap_remove);', ');');
  v := replace(v, '  v_swap_remove       jsonb;' || chr(10), '');
  EXECUTE v;
  v := pg_get_functiondef('public.push_plan_to_dispatch(date,text)'::regprocedure);
  v := regexp_replace(v, '  -- PRD-141 item 1: Add New lanes on an occupied shelf get their Remove leg\..*?  END;' || chr(10), '', 's');
  EXECUTE v;
END $rb$;
REVOKE EXECUTE ON FUNCTION public.add_dispatch_row(uuid, text, uuid, numeric, text, date, text, uuid, uuid, text, text, text, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.add_dispatch_row(uuid, text, uuid, numeric, text, date, text, uuid, uuid, text, text, text, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.push_plan_to_dispatch(date, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.push_plan_to_dispatch(date, text) TO authenticated, service_role;
