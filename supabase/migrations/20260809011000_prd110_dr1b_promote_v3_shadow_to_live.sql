-- PRD-110 DR-1b · leg 161 · Object 3 of 4
-- promote_v3_shadow_to_live_v3(plan_date) — publish v3's plan into the live table, for the
-- clusters that are authoritative for v3 and for NOTHING else.
--
-- engine_add_pod_v3 writes exactly ONE table, public.pod_refills_shadow. Until now there was
-- no path from there into public.pod_refills, so a flipped cluster had nowhere for its plan to
-- land. This is that path, and it is the ONLY one.
--
-- ⛔ IT MUST PIN ONE run_id. pod_refills_shadow PK is
--    (run_id, plan_date, machine_id, shelf_id, pod_product_id); pod_refills PK is
--    (plan_date, machine_id, shelf_id, pod_product_id). "Promote every shadow row for the date"
--    collides on the live PK the instant a second shadow run exists for that date — and cron 45
--    plus any manual re-run guarantee that. The latest run by produced_at wins.
--
-- ⛔ IT REFUSES RATHER THAN PUBLISHES EMPTY. If a cluster is authoritative but the date has no
--    v3 shadow run, the honest outcome is a loud halt, not a plan with that cluster's machines
--    silently missing. revert_cluster_to_v19_v3 makes the halt recoverable in one call and is
--    never evidence-gated.

CREATE OR REPLACE FUNCTION public.promote_v3_shadow_to_live_v3(p_plan_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_actor      uuid;
  v_role       text;
  v_run_id     uuid;
  v_produced   timestamptz;
  v_machines   int;
  v_clusters   text[];
  v_deleted    int := 0;
  v_inserted   int := 0;
  v_qty0       int := 0;
  v_units      int := 0;
  v_result     jsonb;
BEGIN
  PERFORM set_config('app.via_rpc',  'true',                          true);
  PERFORM set_config('app.rpc_name', 'promote_v3_shadow_to_live_v3',  true);

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'promote_v3_shadow_to_live_v3: p_plan_date required';
  END IF;

  v_actor := auth.uid();
  IF v_actor IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_actor;
    IF v_role NOT IN ('operator_admin','superadmin') THEN
      RAISE EXCEPTION 'unauthorized: promotion requires operator_admin or superadmin (caller is %)', v_role;
    END IF;
  END IF;

  -- LAW 12. Never publish over a live plan.
  PERFORM public._assert_refill_plan_writable(p_plan_date);

  -- Scope, read from the ONE canonical object (Article 16).
  SELECT count(*), array_agg(DISTINCT cluster_key ORDER BY cluster_key)
    INTO v_machines, v_clusters
    FROM public.v_add_engine_scope_v3
   WHERE plan_date = p_plan_date AND assigned_engine = 'v3';

  IF COALESCE(v_machines, 0) = 0 THEN
    -- THE FLAG-OFF PATH. Zero clusters authoritative => this is a no-op that touches nothing.
    RETURN jsonb_build_object('status','noop_no_authoritative_machines',
      'plan_date', p_plan_date, 'machines', 0, 'rows_promoted', 0);
  END IF;

  SELECT s.run_id, s.produced_at
    INTO v_run_id, v_produced
    FROM public.pod_refills_shadow s
   WHERE s.plan_date = p_plan_date
     AND s.engine_tag = 'engine_add_pod_v3'
   ORDER BY s.produced_at DESC
   LIMIT 1;

  IF v_run_id IS NULL THEN
    RAISE EXCEPTION 'promote_v3_shadow_to_live_v3: % machine(s) in cluster(s) % are authoritative '
                    'for v3 but plan_date % has no engine_add_pod_v3 shadow run to promote. '
                    'Run engine_add_pod_v3 for this date, or revert_cluster_to_v19_v3 to hand '
                    'these clusters back to v19.',
                    v_machines, array_to_string(v_clusters, ', '), p_plan_date;
  END IF;

  -- Delete-then-insert INSIDE the authoritative scope only. Delete first so a machine that
  -- lost a shelf between runs cannot keep a stale live row.
  WITH gone AS (
    DELETE FROM public.pod_refills pr
     WHERE pr.plan_date = p_plan_date
       AND public.is_cluster_authoritative_v3(pr.machine_id)
    RETURNING 1
  )
  SELECT count(*) INTO v_deleted FROM gone;

  WITH ins AS (
    INSERT INTO public.pod_refills(
      plan_date, machine_id, shelf_id, pod_product_id,
      qty, current_stock, max_stock, velocity_30d, days_cover, signal,
      wh_available_pod, clamp_reason, reasoning)
    SELECT s.plan_date, s.machine_id, s.shelf_id, s.pod_product_id,
           s.qty, s.current_stock, s.max_stock,
           -- The ONE non-identity mapping. velocity_instock is the number v3 actually sized
           -- with; velocity_30d is the column the live table reserves for exactly that.
           -- ⚠️ This does NOT decide D-27 half-2 (velocity_raw vs the canonical in-stock
           -- object) — that ask stays open, and if it renames the concept this moves with it.
           s.velocity_instock,
           s.days_cover, s.signal, s.wh_available_pod, s.clamp_reason,
           -- Provenance, so a reader of pod_refills can always tell WHICH engine authored a
           -- row. "Make the flip auditable" is a Tier-4 requirement, and this is where a
           -- forensic reader lands first.
           s.reasoning || jsonb_build_object(
             'authored_by',      'engine_add_pod_v3',
             'shadow_run_id',    s.run_id,
             'availability_basis', s.availability_basis,
             'promoted_at',      now(),
             'promoted_by',      'promote_v3_shadow_to_live_v3')
      FROM public.pod_refills_shadow s
     WHERE s.run_id = v_run_id
       AND s.plan_date = p_plan_date
       AND public.is_cluster_authoritative_v3(s.machine_id)
    RETURNING qty
  )
  SELECT count(*), count(*) FILTER (WHERE qty = 0), COALESCE(sum(qty), 0)
    INTO v_inserted, v_qty0, v_units
    FROM ins;

  v_result := jsonb_build_object(
    'status',           'promoted',
    'plan_date',        p_plan_date,
    'clusters',         to_jsonb(v_clusters),
    'machines_in_scope', v_machines,
    'shadow_run_id',    v_run_id,
    'shadow_produced_at', v_produced,
    'rows_deleted',     v_deleted,
    'rows_promoted',    v_inserted,
    'rows_qty0',        v_qty0,
    'units',            v_units,
    -- ⛔ S-312. engine_swap_pod is still fleet-wide v19 and swaps_enabled is TRUE globally.
    --    It writes pod_swaps, a different table, so it cannot corrupt this partition — but
    --    engine_finalize_pod merges both into the live plan. A flipped cluster therefore gets
    --    v3 refill lines and v19 swap lines. Scoping the SWAP engine is a separate unit and
    --    PRD-110's Wave-2 SWAP items are parked under the engine freeze. Stated here so the
    --    seam is visible in every promotion payload rather than discovered in production.
    'residual_swap_engine', 'v19_fleetwide');

  INSERT INTO public.engine_cutover_audit_v3
    (cluster_key, action, outcome, refusal_code, from_engine, to_engine, reason, evidence, actor, actor_role)
  SELECT c, 'promote', 'applied', NULL, 'v19', 'v3',
         format('nightly promotion of engine_add_pod_v3 run %s for plan_date %s', v_run_id, p_plan_date),
         v_result, v_actor, v_role
    FROM unnest(v_clusters) AS c;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.promote_v3_shadow_to_live_v3(date) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.promote_v3_shadow_to_live_v3(date) TO authenticated;

COMMENT ON FUNCTION public.promote_v3_shadow_to_live_v3(date) IS
  'PRD-110 DR-1b. Publishes the latest engine_add_pod_v3 shadow run into pod_refills for '
  'v3-authoritative clusters only. No-op while 0 clusters are authoritative. Refuses loudly '
  'rather than publishing an empty plan for a flipped cluster.';

-- ── post-image guards ────────────────────────────────────────────────────────────
DO $guard$
DECLARE
  v_out jsonb;
  v_n   int;
BEGIN
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = 'promote_v3_shadow_to_live_v3') <> 1 THEN
    RAISE EXCEPTION 'DR-1b: promote_v3_shadow_to_live_v3 must have exactly one signature';
  END IF;

  -- FLAG-OFF PROOF, EXECUTED not inspected: 0 clusters authoritative today, so a real call on
  -- a synthetic far-future date must be a no-op that touches nothing.
  SELECT count(*) INTO v_n FROM public.engine_cutover_authority_v3 WHERE authoritative_engine = 'v3';
  IF v_n = 0 THEN
    v_out := public.promote_v3_shadow_to_live_v3(DATE '2030-01-15');
    IF v_out->>'status' <> 'noop_no_authoritative_machines' THEN
      RAISE EXCEPTION 'DR-1b: flag-off promotion was not a no-op: %', v_out;
    END IF;
    RAISE NOTICE 'DR-1b: flag-off no-op verified by execution: %', v_out;
  ELSE
    RAISE NOTICE 'DR-1b: % cluster(s) already authoritative; flag-off no-op check skipped', v_n;
  END IF;
END $guard$;
