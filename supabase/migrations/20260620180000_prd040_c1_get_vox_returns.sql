-- PRD-040 Track C / C1 (PRD-034 Phase C): read-only VOX returns ledger reader.
-- Forward-only. No writes. SECURITY DEFINER (mirrors get_product_performance) solely to resolve
-- received_by -> user_profiles.full_name across staff: user_profiles RLS is own-row-only
-- (own_profile_select id = auth.uid()), so an INVOKER reader would NULL every name but the caller's.
-- Article 16: raw ledger passthrough, no registered-metric re-derivation. swaps_enabled untouched.
CREATE OR REPLACE FUNCTION public.get_vox_returns(
  p_date_from date,
  p_date_to date,
  p_machine_id uuid DEFAULT NULL
)
RETURNS TABLE (
  vox_return_id    uuid,
  dispatch_id      uuid,
  machine_id       uuid,
  machine_name     text,
  boonz_product_id uuid,
  product_name     text,
  qty              numeric,
  expiry_date      date,
  source_of_supply text,
  reason           text,
  received_at      timestamptz,
  received_by      uuid,
  received_by_name text
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT
    v.vox_return_id,
    v.dispatch_id,
    v.machine_id,
    m.official_name,
    v.boonz_product_id,
    bp.boonz_product_name,
    v.qty,
    v.expiry_date,
    v.source_of_supply,
    v.reason,
    v.received_at,
    v.received_by,
    up.full_name
  FROM public.vox_return_log v
  JOIN public.machines m ON m.machine_id = v.machine_id AND m.venue_group = 'VOX'
  LEFT JOIN public.boonz_products bp ON bp.product_id = v.boonz_product_id
  LEFT JOIN public.user_profiles up ON up.id = v.received_by
  WHERE v.received_at::date BETWEEN p_date_from AND p_date_to
    AND (p_machine_id IS NULL OR v.machine_id = p_machine_id)
  ORDER BY v.received_at DESC;
$$;

REVOKE ALL ON FUNCTION public.get_vox_returns(date, date, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_vox_returns(date, date, uuid) TO authenticated, service_role;
