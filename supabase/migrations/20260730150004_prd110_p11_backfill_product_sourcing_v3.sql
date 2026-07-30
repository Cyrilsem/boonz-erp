-- PRD-110 P1.1(iii) - genesis backfill of product_sourcing from product_mapping.source_of_supply,
-- plus the PARKED operating-model apply. Cody class (b) x2.
--
-- THE RESOLUTION RULE, and why the obvious one is WRONG (measured live 2026-07-30):
--   BUILD SPEC P1.1 says "backfill from product_mapping.source_of_supply (venue_team->venue) with
--   the 07-30 lesson: BOTH-rows products resolve to venue on co_managed machines". Here is what
--   that lesson looks like in the actual data, and it is decisive:
--     Fade Fit - all 4 variants - has ONE global-default mapping row marked venue_team, and a
--     machine-scoped row marked *boonz* on EVERY VOX machine. Aquafina is identical (global
--     venue_team, MPMCC-1058 scoped boonz).
--   So a naive "most specific mapping row wins" backfill resolves Fade Fit and Aquafina to
--   boonz_wh on precisely the co-managed machines where they are venue-supplied - reproducing
--   S-10 and the Aquafina half of S-06 inside the very table built to delete them.
--   IMPLEMENTED RULE:
--     partner_managed -> 'partner'  for every edge (WS-J1: zero Boonz inventory records).
--     co_managed      -> 'venue' if ANY Active mapping row at ANY scope (global OR this machine)
--                        says venue_team, else 'boonz_wh'.   <- the BOTH-rows lesson
--     fully_managed   -> 'boonz_wh' always (WS-J1: all products Boonz-sourced). The 286 pairs that
--                        carry a venue_team row anyway are NOT discarded - product_mapping is
--                        untouched and v_product_sourcing_model_conflicts keeps them visible.
--   Verified before writing: ACTIVATEMCC-1037 Fade Fit -> venue, MPMCC-1058 Aquafina -> venue,
--   AMZ-1029 Fade Fit -> boonz_wh.
--
-- CANDIDATE EDGE SET: machine-scoped Active mappings, UNION global-default Active mappings
-- resolved only onto machines that actually carry that pod on a live WEIMI shelf. Cross-joining
-- 228 global defaults onto 100 machines would manufacture ~7k edges for pods those machines have
-- never held; scoping to live shelves keeps the table to the plannable universe (~4022 edges).
--
--   Article 1 - genesis writes go through THIS DEFINER, never a raw INSERT in a migration body.
--   Article 4 - sets app.via_rpc/app.rpc_name, validates role, dry-run default.
--   Article 12 - insert-only and idempotent: it never supersedes or overwrites an existing Active
--                edge, so a human decision made after genesis can never be clobbered by a re-run.

CREATE OR REPLACE FUNCTION public.backfill_product_sourcing_v3(p_dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_user_id uuid;
  v_ins     int := 0;
  v_t0      timestamptz := clock_timestamp();
  v_preview jsonb;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'backfill_product_sourcing_v3', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_user_id AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'backfill_product_sourcing_v3: caller % lacks operator_admin role', v_user_id;
  END IF;

  CREATE TEMP TABLE _ps_candidates ON COMMIT DROP AS
  WITH mdl AS (
    SELECT v.machine_id, v.proposed_model,
           COALESCE(m.operating_model, v.proposed_model) AS eff_model
      FROM public.v_machine_operating_model_proposed v
      JOIN public.machines m ON m.machine_id = v.machine_id
  ),
  live_pods AS (
    SELECT DISTINCT machine_id, pod_product_id
      FROM public.v_shelf_slot_identity WHERE pod_product_id IS NOT NULL
  ),
  pairs AS (
    SELECT pm.machine_id, pm.pod_product_id, pm.boonz_product_id
      FROM public.product_mapping pm
     WHERE pm.status = 'Active' AND pm.machine_id IS NOT NULL
    UNION
    SELECT lp.machine_id, pm.pod_product_id, pm.boonz_product_id
      FROM public.product_mapping pm
      JOIN live_pods lp ON lp.pod_product_id = pm.pod_product_id
     WHERE pm.status = 'Active' AND pm.machine_id IS NULL
  )
  SELECT p.machine_id, p.pod_product_id, p.boonz_product_id, mdl.eff_model,
         CASE
           WHEN mdl.eff_model = 'partner_managed' THEN 'partner'
           WHEN mdl.eff_model = 'co_managed' AND EXISTS (
                SELECT 1 FROM public.product_mapping x
                 WHERE x.status = 'Active' AND x.source_of_supply = 'venue_team'
                   AND x.pod_product_id   = p.pod_product_id
                   AND x.boonz_product_id = p.boonz_product_id
                   AND (x.machine_id IS NULL OR x.machine_id = p.machine_id))
             THEN 'venue'
           ELSE 'boonz_wh'
         END AS src
    FROM pairs p
    JOIN mdl ON mdl.machine_id = p.machine_id
   WHERE NOT EXISTS (
     SELECT 1 FROM public.product_sourcing ps
      WHERE ps.status = 'Active'
        AND ps.machine_id       = p.machine_id
        AND ps.pod_product_id   = p.pod_product_id
        AND ps.boonz_product_id IS NOT DISTINCT FROM p.boonz_product_id);

  SELECT jsonb_object_agg(k, n) INTO v_preview
    FROM (SELECT eff_model || ':' || src AS k, count(*) AS n FROM _ps_candidates GROUP BY 1) q;

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'dry_run', true,
      'would_insert', (SELECT count(*) FROM _ps_candidates),
      'by_model_source', COALESCE(v_preview,'{}'::jsonb),
      'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int);
  END IF;

  WITH ins AS (
    INSERT INTO public.product_sourcing
      (machine_id, pod_product_id, boonz_product_id, source, origin, reason, changed_by)
    SELECT c.machine_id, c.pod_product_id, c.boonz_product_id, c.src, 'backfill',
           'PRD-110 P1.1 genesis backfill from product_mapping.source_of_supply; co_managed '
           'resolves any-scope venue_team to venue (07-30 BOTH-rows lesson)', v_user_id
      FROM _ps_candidates c
    RETURNING 1)
  SELECT count(*)::int INTO v_ins FROM ins;

  RETURN jsonb_build_object(
    'dry_run', false,
    'rows_inserted', v_ins,
    'by_model_source', COALESCE(v_preview,'{}'::jsonb),
    'active_edges_now', (SELECT count(*) FROM public.product_sourcing WHERE status='Active'),
    'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int);
END $fn$;

COMMENT ON FUNCTION public.backfill_product_sourcing_v3(boolean) IS
  'PRD-110 P1.1(iii). Idempotent, insert-only genesis of product_sourcing. Never supersedes or '
  'overwrites an Active edge, so a human decision made after genesis survives every re-run. '
  'Dry-run by default.';

REVOKE ALL ON FUNCTION public.backfill_product_sourcing_v3(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.backfill_product_sourcing_v3(boolean) TO authenticated;

-- ------------------------------------------------------- the PARKED operating-model apply (D-07)
-- Built, proven, and left OFF. BUILD SPEC P1.1 says CS reviews the generated mapping before apply;
-- the goal command PARKING protocol lists this as a DECISIONS-READY item. Dry-run by default so
-- the single activation command is the same call with p_dry_run => false.
CREATE OR REPLACE FUNCTION public.apply_proposed_operating_models_v3(p_dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_user_id uuid;
  v_applied int := 0;
  v_failed  int := 0;
  v_errs    jsonb := '[]'::jsonb;
  r         record;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'apply_proposed_operating_models_v3', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_user_id AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'apply_proposed_operating_models_v3: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'dry_run', true,
      'would_change', (SELECT count(*) FROM public.v_machine_operating_model_proposed WHERE would_change),
      'plan', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                          'machine', official_name, 'from', current_model, 'to', proposed_model)
                          ORDER BY official_name)
                        FROM public.v_machine_operating_model_proposed WHERE would_change),'[]'::jsonb),
      'conflict_edges', (SELECT count(*) FROM public.v_product_sourcing_model_conflicts));
  END IF;

  FOR r IN SELECT machine_id, official_name, proposed_model
             FROM public.v_machine_operating_model_proposed WHERE would_change
  LOOP
    BEGIN
      PERFORM public.set_machine_operating_model_v3(
        r.machine_id, r.proposed_model,
        'PRD-110 P1.1 operating-model backfill applied by CS from v_machine_operating_model_proposed');
      v_applied := v_applied + 1;
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      v_errs := v_errs || jsonb_build_object('machine', r.official_name, 'error', SQLERRM);
    END;
  END LOOP;

  RETURN jsonb_build_object('dry_run', false, 'applied', v_applied,
                            'failed', v_failed, 'errors', v_errs);
END $fn$;

COMMENT ON FUNCTION public.apply_proposed_operating_models_v3(boolean) IS
  'PRD-110 P1.1(i) PARKED activation (PARKING-LOT D-07). Applies v_machine_operating_model_proposed '
  'through the canonical writer, one machine at a time, collecting per-machine failures rather than '
  'aborting the batch. Dry-run by default.';

REVOKE ALL ON FUNCTION public.apply_proposed_operating_models_v3(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.apply_proposed_operating_models_v3(boolean) TO authenticated;
