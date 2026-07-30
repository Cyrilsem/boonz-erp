-- PRD-110 P1.1 - canonical writers + canonical readers for product_sourcing / operating_model.
-- Cody class (b) writer DEFINER x3 + (c) read-only helper x1.
--   Article 1 - set_product_sourcing_v3 is THE write path for an ongoing edit;
--               backfill_product_sourcing_v3 is THE genesis path (idempotent, insert-only);
--               set_machine_operating_model_v3 is THE write path for machines.operating_model
--               (Appendix A protected - a raw UPDATE would violate Articles 1 and 3).
--   Article 4 - every writer sets app.via_rpc + app.rpc_name, validates inputs and caller role.
--   Article 8 - targets carry the generic audit trigger.
--   Article 16 - readers are the canonical objects; no consumer re-derives sourcing inline.

-- ---------------------------------------------------------------- canonical reader (current edges)
CREATE OR REPLACE VIEW public.v_product_sourcing_current
WITH (security_invoker = true) AS
SELECT ps.sourcing_id, ps.machine_id, m.official_name AS machine_name, m.operating_model,
       ps.pod_product_id, pp.pod_product_name,
       ps.boonz_product_id, bp.boonz_product_name,
       ps.source, ps.origin, ps.valid_from, ps.changed_by, ps.reason
  FROM public.product_sourcing ps
  JOIN public.machines     m  ON m.machine_id     = ps.machine_id
  JOIN public.pod_products pp ON pp.pod_product_id = ps.pod_product_id
  LEFT JOIN public.boonz_products bp ON bp.product_id = ps.boonz_product_id
 WHERE ps.status = 'Active';

COMMENT ON VIEW public.v_product_sourcing_current IS
  'PRD-110 P1.1 canonical reader for live sourcing edges (Article 16). Consumers read THIS or '
  'resolve_product_sourcing_v3, never product_sourcing directly.';

-- --------------------------------------------------------------------------- the resolver (P1.2/P2)
-- Precedence: SKU-grain edge > pod-grain edge > operating-model default > 'boonz_wh'.
-- SECURITY INVOKER on purpose (Cody's "is DEFINER justified?" rule): it reads only, and every
-- caller already has SELECT on the underlying tables.
CREATE OR REPLACE FUNCTION public.resolve_product_sourcing_v3(
  p_machine_id       uuid,
  p_pod_product_id   uuid,
  p_boonz_product_id uuid DEFAULT NULL)
RETURNS text
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $fn$
  SELECT COALESCE(
    (SELECT ps.source FROM public.product_sourcing ps
      WHERE ps.status = 'Active' AND ps.machine_id = p_machine_id
        AND ps.pod_product_id = p_pod_product_id
        AND ps.boonz_product_id = p_boonz_product_id
      LIMIT 1),
    (SELECT ps.source FROM public.product_sourcing ps
      WHERE ps.status = 'Active' AND ps.machine_id = p_machine_id
        AND ps.pod_product_id = p_pod_product_id
        AND ps.boonz_product_id IS NULL
      LIMIT 1),
    (SELECT CASE m.operating_model WHEN 'partner_managed' THEN 'partner' ELSE 'boonz_wh' END
       FROM public.machines m WHERE m.machine_id = p_machine_id),
    'boonz_wh');
$fn$;

COMMENT ON FUNCTION public.resolve_product_sourcing_v3(uuid,uuid,uuid) IS
  'PRD-110 P1.1. Canonical sourcing lookup. Precedence: SKU-grain edge > pod-grain edge > '
  'operating-model default > boonz_wh. The final boonz_wh fallback is deliberately the CONSTRAINED '
  'answer: an unknown edge must never silently grant unconstrained (phantom) availability - that '
  'is the S-10 failure mode this whole task exists to delete.';

-- -------------------------------------------------------- conflicts: model vs the mapping evidence
-- Surfaces every machine where the PROPOSED operating model contradicts what
-- product_mapping.source_of_supply says, so CS sees the collision BEFORE applying the backfill.
-- Live at write time: 286 (machine, sku) pairs on 23 fully_managed machines carry a venue_team
-- mapping row. Under WS-J1 a fully-managed machine is Boonz-sourced by definition, so the backfill
-- resolves them to boonz_wh - this view is where that decision stays visible instead of vanishing.
CREATE OR REPLACE VIEW public.v_product_sourcing_model_conflicts
WITH (security_invoker = true) AS
WITH live_pods AS (
  SELECT DISTINCT machine_id, pod_product_id FROM public.v_shelf_slot_identity WHERE pod_product_id IS NOT NULL
),
pairs AS (
  SELECT pm.machine_id, pm.pod_product_id, pm.boonz_product_id
    FROM public.product_mapping pm WHERE pm.status = 'Active' AND pm.machine_id IS NOT NULL
  UNION
  SELECT lp.machine_id, pm.pod_product_id, pm.boonz_product_id
    FROM public.product_mapping pm
    JOIN live_pods lp ON lp.pod_product_id = pm.pod_product_id
   WHERE pm.status = 'Active' AND pm.machine_id IS NULL
)
SELECT v.machine_id, v.official_name, v.proposed_model, v.current_model,
       p.pod_product_id, pp.pod_product_name, p.boonz_product_id, bp.boonz_product_name,
       'venue_team mapping on a machine the model calls Boonz-sourced'::text AS conflict,
       public.resolve_product_sourcing_v3(p.machine_id, p.pod_product_id, p.boonz_product_id) AS resolved_source
  FROM pairs p
  JOIN public.v_machine_operating_model_proposed v ON v.machine_id = p.machine_id
  JOIN public.pod_products pp ON pp.pod_product_id = p.pod_product_id
  LEFT JOIN public.boonz_products bp ON bp.product_id = p.boonz_product_id
 WHERE v.proposed_model = 'fully_managed'
   AND EXISTS (SELECT 1 FROM public.product_mapping x
                WHERE x.status='Active' AND x.source_of_supply='venue_team'
                  AND x.pod_product_id = p.pod_product_id
                  AND x.boonz_product_id = p.boonz_product_id
                  AND (x.machine_id IS NULL OR x.machine_id = p.machine_id));

COMMENT ON VIEW public.v_product_sourcing_model_conflicts IS
  'PRD-110 P1.1. Machines the generated model calls fully_managed that nonetheless carry a '
  'venue_team product_mapping row. Nothing is lost by the backfill resolving these to boonz_wh: '
  'product_mapping is untouched and this view keeps the collision visible for CS.';

-- ------------------------------------------------------------------- writer 1: one edge (FE grid)
CREATE OR REPLACE FUNCTION public.set_product_sourcing_v3(
  p_machine_id       uuid,
  p_pod_product_id   uuid,
  p_source           text,
  p_reason           text,
  p_boonz_product_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_user_id  uuid;
  v_old      uuid;
  v_old_src  text;
  v_new      uuid;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'set_product_sourcing_v3', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_user_id AND up.role IN ('operator_admin','superadmin','manager')
  ) THEN
    RAISE EXCEPTION 'set_product_sourcing_v3: caller % lacks operator_admin/superadmin/manager role', v_user_id;
  END IF;

  IF p_machine_id IS NULL OR p_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'set_product_sourcing_v3: machine_id and pod_product_id are required';
  END IF;
  IF p_source IS NULL OR p_source NOT IN ('boonz_wh','venue','partner') THEN
    RAISE EXCEPTION 'set_product_sourcing_v3: source % must be boonz_wh|venue|partner', p_source;
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'set_product_sourcing_v3: a reason of at least 10 characters is required';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.machines WHERE machine_id = p_machine_id) THEN
    RAISE EXCEPTION 'set_product_sourcing_v3: machine % does not exist', p_machine_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pod_products WHERE pod_product_id = p_pod_product_id) THEN
    RAISE EXCEPTION 'set_product_sourcing_v3: pod_product % does not exist', p_pod_product_id;
  END IF;
  IF p_boonz_product_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.boonz_products WHERE product_id = p_boonz_product_id) THEN
    RAISE EXCEPTION 'set_product_sourcing_v3: boonz_product % does not exist', p_boonz_product_id;
  END IF;

  SELECT ps.sourcing_id, ps.source INTO v_old, v_old_src
    FROM public.product_sourcing ps
   WHERE ps.status = 'Active' AND ps.machine_id = p_machine_id
     AND ps.pod_product_id = p_pod_product_id
     AND ps.boonz_product_id IS NOT DISTINCT FROM p_boonz_product_id;

  IF v_old IS NOT NULL AND v_old_src = p_source THEN
    RETURN jsonb_build_object('changed', false, 'sourcing_id', v_old, 'source', v_old_src,
                              'note', 'already at this source; no supersede written');
  END IF;

  -- supersede first, so the partial unique index is never transiently violated
  IF v_old IS NOT NULL THEN
    UPDATE public.product_sourcing
       SET status = 'Superseded', valid_to = now()
     WHERE sourcing_id = v_old;
  END IF;

  INSERT INTO public.product_sourcing
    (machine_id, pod_product_id, boonz_product_id, source, origin, reason, changed_by)
  VALUES (p_machine_id, p_pod_product_id, p_boonz_product_id, p_source, 'manual', p_reason, v_user_id)
  RETURNING sourcing_id INTO v_new;

  RETURN jsonb_build_object('changed', true, 'sourcing_id', v_new,
                            'superseded_id', v_old, 'from', v_old_src, 'to', p_source);
END $fn$;

COMMENT ON FUNCTION public.set_product_sourcing_v3(uuid,uuid,text,text,uuid) IS
  'PRD-110 P1.1. THE canonical writer for a single sourcing edge (Article 1). Supersede-then-insert; '
  'never updates source in place. Backs the FE product x machine sourcing grid.';

REVOKE ALL ON FUNCTION public.set_product_sourcing_v3(uuid,uuid,text,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_product_sourcing_v3(uuid,uuid,text,text,uuid) TO authenticated;

-- ------------------------------------------------- writer 2: machines.operating_model (protected)
CREATE OR REPLACE FUNCTION public.set_machine_operating_model_v3(
  p_machine_id uuid,
  p_model      text,
  p_reason     text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_user_id uuid;
  v_old     text;
  v_bad     int;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'set_machine_operating_model_v3', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_user_id AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'set_machine_operating_model_v3: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_model IS NULL OR p_model NOT IN ('fully_managed','co_managed','partner_managed') THEN
    RAISE EXCEPTION 'set_machine_operating_model_v3: model % must be fully_managed|co_managed|partner_managed', p_model;
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'set_machine_operating_model_v3: a reason of at least 10 characters is required';
  END IF;

  SELECT operating_model INTO v_old FROM public.machines WHERE machine_id = p_machine_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'set_machine_operating_model_v3: machine % does not exist', p_machine_id;
  END IF;

  -- The mirror of tg_product_sourcing_model_guard. Without this, classifying a machine AFTER its
  -- edges exist would leave a state the trigger would have refused - the guard only fires on
  -- product_sourcing writes, so it cannot retro-validate.
  IF p_model = 'partner_managed' THEN
    SELECT count(*) INTO v_bad FROM public.product_sourcing
     WHERE machine_id = p_machine_id AND status='Active' AND source = 'boonz_wh';
    IF v_bad > 0 THEN
      RAISE EXCEPTION 'set_machine_operating_model_v3: machine % holds % Active boonz_wh sourcing '
                      'edge(s); a partner_managed machine may hold none. Re-source them first.',
                      p_machine_id, v_bad;
    END IF;
  ELSIF p_model = 'fully_managed' THEN
    SELECT count(*) INTO v_bad FROM public.product_sourcing
     WHERE machine_id = p_machine_id AND status='Active' AND source = 'venue';
    IF v_bad > 0 THEN
      RAISE EXCEPTION 'set_machine_operating_model_v3: machine % holds % Active venue sourcing '
                      'edge(s); a fully_managed machine may hold none. Re-source them first.',
                      p_machine_id, v_bad;
    END IF;
  END IF;

  IF v_old IS NOT DISTINCT FROM p_model THEN
    RETURN jsonb_build_object('changed', false, 'machine_id', p_machine_id, 'operating_model', v_old);
  END IF;

  UPDATE public.machines SET operating_model = p_model, updated_at = now()
   WHERE machine_id = p_machine_id;

  RETURN jsonb_build_object('changed', true, 'machine_id', p_machine_id,
                            'from', v_old, 'to', p_model, 'reason', p_reason);
END $fn$;

COMMENT ON FUNCTION public.set_machine_operating_model_v3(uuid,text,text) IS
  'PRD-110 P1.1. THE canonical writer for machines.operating_model (Appendix A protected entity). '
  'Refuses any classification that contradicts the machine live Active sourcing edges - the '
  'product_sourcing trigger cannot retro-validate, so this is where that invariant is held.';

REVOKE ALL ON FUNCTION public.set_machine_operating_model_v3(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_machine_operating_model_v3(uuid,text,text) TO authenticated;

GRANT SELECT ON public.v_product_sourcing_current           TO authenticated;
GRANT SELECT ON public.v_product_sourcing_model_conflicts   TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_product_sourcing_v3(uuid,uuid,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.resolve_product_sourcing_v3(uuid,uuid,uuid) FROM anon;
