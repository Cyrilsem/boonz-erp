-- PRD-013 Article 13 deprecation: PRD-012 approve_pod_inventory_add and
-- reject_pod_inventory_add are superseded by approve_pod_inventory_edit and
-- reject_pod_inventory_edit. Both wrappers still callable for the 90-day
-- monitor window; they now emit RAISE NOTICE so straggler callers surface in
-- logs. Sunset target: 2026-08-25.

CREATE OR REPLACE FUNCTION public.approve_pod_inventory_add(
  p_edit_id                  uuid,
  p_approver_id              uuid    DEFAULT NULL,
  p_decision_note            text    DEFAULT NULL,
  p_expiry_override_accepted boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  RAISE NOTICE 'DEPRECATED: approve_pod_inventory_add is superseded by approve_pod_inventory_edit (PRD-013). Sunset 2026-08-25.';
  RETURN public.approve_pod_inventory_edit(p_edit_id, p_approver_id, p_decision_note, p_expiry_override_accepted);
END;
$function$;

CREATE OR REPLACE FUNCTION public.reject_pod_inventory_add(
  p_edit_id        uuid,
  p_decision_note  text,
  p_approver_id    uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  RAISE NOTICE 'DEPRECATED: reject_pod_inventory_add is superseded by reject_pod_inventory_edit (PRD-013). Sunset 2026-08-25.';
  RETURN public.reject_pod_inventory_edit(p_edit_id, p_decision_note, p_approver_id);
END;
$function$;

COMMENT ON FUNCTION public.approve_pod_inventory_add(uuid,uuid,text,boolean) IS
  'DEPRECATED 2026-05-25. Thin shim that forwards to approve_pod_inventory_edit (PRD-013). Sunset target 2026-08-25. Do not extend; do not call from new code.';

COMMENT ON FUNCTION public.reject_pod_inventory_add(uuid,text,uuid) IS
  'DEPRECATED 2026-05-25. Thin shim that forwards to reject_pod_inventory_edit (PRD-013). Sunset target 2026-08-25. Do not extend; do not call from new code.';
