-- PRD-073: recommendation-driven pod splits (canonical writer, weekly recurring).
--
-- Principle (CS 2026-07-03): driver ground recommendations are demand signal. Recommended
-- flavors get proportional weight scaled to ~90%; all other mapped flavors share the
-- remaining ~10% evenly (low but nonzero so they stay alive). Percentages are REFRESHED
-- whenever new recommendations arrive.
--
-- Scope facts (Dara check 2026-07-04): product_mapping already supports per-machine
-- overrides (machine_id nullable, is_global_default). No DDL needed. split_pct and
-- mix_weight are stored in sync (mix_weight = split_pct/100) and stitch consumes
-- mix_weight; this writer preserves that sync, so stitch normalization semantics are
-- untouched (PRD-073 constraint).
--
-- Behavior:
--   * p_dry_run (DEFAULT TRUE): computes and returns current-vs-proposed without writing.
--     This is the Gate-1 table source: same code path as the write.
--   * Targets PER-MACHINE rows only; global defaults are never touched. Machines whose
--     pod resolves via global rows get per-machine rows created on write.
--   * p_rebuild=FALSE refuses machine+pod whose existing per-machine splits do not sum
--     to 100 (known-broken pods must be rebuilt deliberately, see Activia WH2-1018 = 170).
--   * p_rebuild=TRUE additionally allows recommended flavors with NO mapping row yet:
--     a per-machine row is created (the 'Activia ... Rasberry' case, engine-invisible
--     until now).
--   * Rounding to 2dp with the residual placed on the highest-weight recommended flavor
--     so the final sum is exactly 100.00; post-write assertion re-checks and aborts
--     the transaction otherwise.
--   * Audit: one write_audit_log row per call (INSERT via this DEFINER; append-only
--     policies untouched) with full old->new payload.
CREATE OR REPLACE FUNCTION public.reweight_pod_splits(
  p_machine text,
  p_pod     text,
  p_weights jsonb,               -- {"<boonz_product_id>": <rec_qty>, ...}
  p_reason  text,
  p_rebuild boolean DEFAULT false,
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_machine_id uuid;
  v_pod_id uuid;
  v_rec_total numeric;
  v_n_others int;
  v_rec_share numeric;   -- 90, or 100 when every mapped flavor is recommended
  v_other_share numeric; -- 10 spread evenly, or 0
  v_existing_sum numeric;
  v_has_machine_rows boolean;
  v_final_sum numeric;
  v_residual numeric;
  v_top_flavor uuid;
  v_applied jsonb;
  v_old jsonb;
  k text; q numeric;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','reweight_pod_splits',true);

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'reweight_pod_splits: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'reweight_pod_splits: p_reason required (>= 10 chars)';
  END IF;
  IF p_weights IS NULL OR jsonb_typeof(p_weights) <> 'object' OR p_weights = '{}'::jsonb THEN
    RAISE EXCEPTION 'reweight_pod_splits: p_weights must be a non-empty {boonz_product_id: rec_qty} object';
  END IF;
  PERFORM set_config('app.mutation_reason', p_reason, true);

  SELECT machine_id INTO v_machine_id FROM public.machines WHERE official_name = p_machine AND status IN ('Active','Warehouse');
  IF v_machine_id IS NULL THEN RAISE EXCEPTION 'reweight_pod_splits: Active/Warehouse machine % not found', p_machine; END IF;
  SELECT pod_product_id INTO v_pod_id FROM public.pod_products WHERE pod_product_name = p_pod;
  IF v_pod_id IS NULL THEN RAISE EXCEPTION 'reweight_pod_splits: pod product % not found', p_pod; END IF;

  -- validate weights payload: keys are existing boonz products, qtys > 0
  FOR k, q IN SELECT key, value::numeric FROM jsonb_each_text(p_weights) LOOP
    IF q IS NULL OR q <= 0 THEN
      RAISE EXCEPTION 'reweight_pod_splits: rec qty for % must be > 0 (got %)', k, q;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.boonz_products WHERE product_id = k::uuid) THEN
      RAISE EXCEPTION 'reweight_pod_splits: unknown boonz_product_id %', k;
    END IF;
  END LOOP;

  -- mapped flavor universe for this machine+pod: per-machine rows if any, else global
  DROP TABLE IF EXISTS _flavors;
  CREATE TEMP TABLE _flavors ON COMMIT DROP AS
  SELECT DISTINCT ON (bpid) bpid, has_machine_row FROM (
    SELECT pm.boonz_product_id AS bpid, (pm.machine_id IS NOT NULL) AS has_machine_row
    FROM public.product_mapping pm
    WHERE pm.pod_product_id = v_pod_id AND pm.status = 'Active'
      AND (pm.machine_id = v_machine_id OR pm.machine_id IS NULL)
  ) f ORDER BY bpid, has_machine_row DESC;

  -- recommended-but-unmapped flavors need p_rebuild (mapping row will be created)
  FOR k IN SELECT key FROM jsonb_each_text(p_weights) LOOP
    IF NOT EXISTS (SELECT 1 FROM _flavors WHERE bpid = k::uuid) THEN
      IF NOT p_rebuild THEN
        RAISE EXCEPTION 'reweight_pod_splits: % is recommended but has no mapping for pod % (machine % or global). Re-run with p_rebuild=true to create it.', k, p_pod, p_machine;
      END IF;
      INSERT INTO _flavors (bpid, has_machine_row) VALUES (k::uuid, false);
    END IF;
  END LOOP;

  -- broken-sum guardrail on existing per-machine rows
  SELECT COALESCE(sum(pm.split_pct),0), count(*) > 0
    INTO v_existing_sum, v_has_machine_rows
  FROM public.product_mapping pm
  WHERE pm.pod_product_id = v_pod_id AND pm.machine_id = v_machine_id AND pm.status = 'Active';
  IF v_has_machine_rows AND v_existing_sum <> 100 AND NOT p_rebuild THEN
    RAISE EXCEPTION 'reweight_pod_splits: existing per-machine splits for %/% sum to % (not 100). Re-run with p_rebuild=true to rebuild.', p_machine, p_pod, v_existing_sum;
  END IF;

  SELECT sum(value::numeric) INTO v_rec_total FROM jsonb_each_text(p_weights);
  SELECT count(*) INTO v_n_others FROM _flavors WHERE NOT (bpid::text IN (SELECT key FROM jsonb_each_text(p_weights)));
  v_rec_share   := CASE WHEN v_n_others = 0 THEN 100 ELSE 90 END;
  v_other_share := CASE WHEN v_n_others = 0 THEN 0 ELSE round(10.0 / v_n_others, 2) END;

  DROP TABLE IF EXISTS _proposed;
  CREATE TEMP TABLE _proposed ON COMMIT DROP AS
  SELECT f.bpid,
         bp.boonz_product_name,
         (w.value IS NOT NULL) AS recommended,
         COALESCE(round((w.value::numeric / v_rec_total) * v_rec_share, 2), v_other_share) AS new_pct,
         (SELECT pm.split_pct FROM public.product_mapping pm
           WHERE pm.pod_product_id = v_pod_id AND pm.machine_id = v_machine_id
             AND pm.boonz_product_id = f.bpid AND pm.status='Active') AS old_machine_pct,
         (SELECT pm.split_pct FROM public.product_mapping pm
           WHERE pm.pod_product_id = v_pod_id AND pm.machine_id IS NULL
             AND pm.boonz_product_id = f.bpid AND pm.status='Active') AS global_pct
  FROM _flavors f
  JOIN public.boonz_products bp ON bp.product_id = f.bpid
  LEFT JOIN jsonb_each_text(p_weights) w ON w.key = f.bpid::text;

  -- rounding residual onto the highest-weight recommended flavor
  SELECT sum(new_pct) INTO v_final_sum FROM _proposed;
  v_residual := round(100 - v_final_sum, 2);
  IF v_residual <> 0 THEN
    SELECT bpid INTO v_top_flavor FROM _proposed WHERE recommended ORDER BY new_pct DESC, bpid LIMIT 1;
    IF v_top_flavor IS NULL THEN
      SELECT bpid INTO v_top_flavor FROM _proposed ORDER BY new_pct DESC, bpid LIMIT 1;
    END IF;
    UPDATE _proposed SET new_pct = new_pct + v_residual WHERE bpid = v_top_flavor;
  END IF;
  SELECT sum(new_pct) INTO v_final_sum FROM _proposed;
  IF v_final_sum <> 100 THEN
    RAISE EXCEPTION 'reweight_pod_splits: proposed splits sum to % (must be 100) - internal error', v_final_sum;
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
           'boonz_product_id', bpid, 'flavor', boonz_product_name,
           'recommended', recommended,
           'current_pct', COALESCE(old_machine_pct, global_pct),
           'current_scope', CASE WHEN old_machine_pct IS NOT NULL THEN 'machine' WHEN global_pct IS NOT NULL THEN 'global' ELSE 'unmapped' END,
           'proposed_pct', new_pct) ORDER BY new_pct DESC, boonz_product_name)
    INTO v_applied FROM _proposed;

  IF p_dry_run THEN
    RETURN jsonb_build_object('status','dry_run','machine',p_machine,'pod',p_pod,
      'rebuild',p_rebuild,'proposed_sum',v_final_sum,'splits',v_applied);
  END IF;

  SELECT jsonb_agg(jsonb_build_object('boonz_product_id', boonz_product_id, 'split_pct', split_pct, 'mix_weight', mix_weight))
    INTO v_old
  FROM public.product_mapping
  WHERE pod_product_id = v_pod_id AND machine_id = v_machine_id AND status='Active';

  -- upsert per-machine rows for every flavor in the universe
  UPDATE public.product_mapping pm
     SET split_pct = p.new_pct,
         mix_weight = round(p.new_pct / 100.0, 3),
         updated_at = now()
  FROM _proposed p
  WHERE pm.pod_product_id = v_pod_id AND pm.machine_id = v_machine_id
    AND pm.boonz_product_id = p.bpid AND pm.status='Active';

  INSERT INTO public.product_mapping (pod_product_id, boonz_product_id, machine_id, split_pct, mix_weight, is_global_default, status)
  SELECT v_pod_id, p.bpid, v_machine_id, p.new_pct, round(p.new_pct / 100.0, 3), false, 'Active'
  FROM _proposed p
  WHERE NOT EXISTS (SELECT 1 FROM public.product_mapping pm
                    WHERE pm.pod_product_id = v_pod_id AND pm.machine_id = v_machine_id
                      AND pm.boonz_product_id = p.bpid AND pm.status='Active');

  -- post-write assertion: Active per-machine splits sum to exactly 100
  SELECT sum(split_pct) INTO v_final_sum
  FROM public.product_mapping
  WHERE pod_product_id = v_pod_id AND machine_id = v_machine_id AND status='Active';
  IF v_final_sum <> 100 THEN
    RAISE EXCEPTION 'reweight_pod_splits: post-write sum is % (must be 100) - aborting', v_final_sum;
  END IF;

  INSERT INTO public.write_audit_log (table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload)
  VALUES ('product_mapping', 'UPDATE', p_machine || '/' || p_pod, v_uid, v_role, true, 'reweight_pod_splits',
          jsonb_build_object('reason', p_reason, 'rebuild', p_rebuild, 'weights', p_weights,
                             'old', COALESCE(v_old,'[]'::jsonb), 'new', v_applied));

  RETURN jsonb_build_object('status','applied','machine',p_machine,'pod',p_pod,
    'rebuild',p_rebuild,'final_sum',v_final_sum,'splits',v_applied);
END;
$function$;

REVOKE ALL ON FUNCTION public.reweight_pod_splits(text,text,jsonb,text,boolean,boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.reweight_pod_splits(text,text,jsonb,text,boolean,boolean) TO authenticated, service_role;

COMMENT ON FUNCTION public.reweight_pod_splits(text,text,jsonb,text,boolean,boolean) IS
  'PRD-073 canonical writer: refresh per-machine pod splits from driver recommendations (rec flavors scale to 90%, others share 10%). p_dry_run=true returns Gate-1 current-vs-proposed. Weekly recurring after CS Gate-1 approval.';
