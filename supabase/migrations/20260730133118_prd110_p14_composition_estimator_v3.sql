-- ============================================================================
-- PRD-110 P1.4 — the composition estimator (WS-J2), SHADOW.
-- Reconciles the WEIMI pod-level count against per-SKU belief in
-- shelf_composition, writing every movement through the canonical event writer.
--
-- Reads nothing but: v_shelf_state (canonical shelf truth, P1.2),
-- product_mapping (pod -> SKU candidate map + split_pct ONLY, never for stock),
-- pod_inventory (expiry buckets ONLY - DATA-SOURCE LAW item 6).
-- Writes nothing but: inventory_events / shelf_composition / inventory_anomalies
-- and only ever via record_inventory_event_v3 / raise_inventory_anomaly_v3.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Rise disposition helper.
--    BUILD SPEC: "Count rise without event: co_managed + venue-sourced =>
--    auto venue_fill event; else anomaly row."
--    Extracted as its own function so BOTH branches are directly assertable by
--    fixture 19 without mutating a live machine. Fail-safe direction is
--    'anomaly': operating_model is NULL fleet-wide until D-07 is applied, so
--    today every rise lands as an anomaly rather than a silent auto-fill.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._estimator_rise_disposition_v3(
  p_machine_id       uuid,
  p_pod_product_id   uuid,
  p_boonz_product_id uuid DEFAULT NULL
) RETURNS text
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT CASE
    WHEN m.operating_model = 'co_managed'
     AND public.resolve_product_sourcing_v3(p_machine_id, p_pod_product_id, p_boonz_product_id) = 'venue'
      THEN 'venue_fill'
    ELSE 'anomaly'
  END
  FROM public.machines m WHERE m.machine_id = p_machine_id;
$$;

COMMENT ON FUNCTION public._estimator_rise_disposition_v3(uuid,uuid,uuid) IS
  'PRD-110 P1.4. Decides how an unexplained WEIMI count RISE is absorbed. Returns venue_fill only for a co_managed machine on a venue-sourced product; otherwise anomaly. Fail-safe is anomaly. NOTE: dormant until D-07 (operating_model backfill) is applied - every machine is NULL today, so this returns anomaly fleet-wide.';

-- ---------------------------------------------------------------------------
-- 2. estimate_shelf_composition_v3
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.estimate_shelf_composition_v3(
  p_shelf_id uuid    DEFAULT NULL,   -- NULL = whole eligible fleet
  p_dry_run  boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_actor      uuid;
  v_t0         timestamptz := clock_timestamp();
  s            record;
  b            record;
  v_ref        text;
  v_count      numeric;
  v_believed   numeric;
  v_sellable   numeric;
  v_delta      numeric;
  v_alloc      numeric;
  v_residual   numeric;
  v_cand       int;
  v_disp       text;
  v_expl       numeric;
  v_days       numeric;
  v_decay      numeric;
  v_p          record;
  -- counters
  n_shelves int := 0; n_skipped_done int := 0; n_cold int := 0;
  n_drop int := 0; n_rise_fill int := 0; n_rise_anom int := 0;
  n_sensor int := 0; n_unalloc int := 0; n_events int := 0;
  n_flat int := 0; n_decayed int := 0; n_no_weimi int := 0;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','estimate_shelf_composition_v3',true);

  v_actor := auth.uid();
  IF v_actor IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up WHERE up.id = v_actor
      AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'estimate_shelf_composition_v3: caller % lacks operator_admin role', v_actor;
  END IF;

  SELECT composition_decay_per_day, composition_decay_per_unexplained
    INTO v_p FROM public.refill_policy_params WHERE id = 1;

  FOR s IN
    SELECT ss.shelf_id, ss.machine_id, ss.pod_product_id, ss.current_stock,
           ss.max_stock, ss.stock_as_of, ss.sourcing
      FROM public.v_shelf_state ss
     WHERE (p_shelf_id IS NULL OR ss.shelf_id = p_shelf_id)
       AND ss.pod_product_id IS NOT NULL
     ORDER BY ss.machine_id, ss.shelf_id
  LOOP
    -- no WEIMI reading at all -> nothing to reconcile against
    IF s.current_stock IS NULL OR s.stock_as_of IS NULL THEN
      n_no_weimi := n_no_weimi + 1; CONTINUE;
    END IF;

    n_shelves := n_shelves + 1;
    -- snapshot identity carries into source_ref: this is what makes re-runs
    -- idempotent with no extra state table (stress-suite S4).
    v_ref := 'estimator:' || to_char(s.stock_as_of AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS');

    IF EXISTS (SELECT 1 FROM public.inventory_events
                WHERE shelf_id = s.shelf_id AND source_ref = v_ref) THEN
      n_skipped_done := n_skipped_done + 1; CONTINUE;
    END IF;

    v_count := s.current_stock;

    -- ---- sensor lie (fixture 14): count above capacity -------------------
    IF s.max_stock IS NOT NULL AND v_count > s.max_stock THEN
      n_sensor := n_sensor + 1;
      IF NOT p_dry_run THEN
        PERFORM public.raise_inventory_anomaly_v3(
          s.shelf_id,'count_above_capacity', v_count, s.max_stock, NULL, s.stock_as_of,
          jsonb_build_object('source_ref',v_ref,'note','WEIMI count exceeds capacity; clamped for estimation'));
      END IF;
      v_count := s.max_stock;   -- plan on the clamped value, never the absurd one
    END IF;

    SELECT COALESCE(sum(est_qty),0) INTO v_believed
      FROM public.shelf_composition WHERE shelf_id = s.shelf_id;

    -- ================= COLD START =======================================
    -- No belief yet but WEIMI reports stock. Seed from the pod's split_pct
    -- (product_mapping is the pod->SKU map; this is NOT a stock read) with
    -- expiry buckets from pod_inventory (expiry history ONLY, per LAW 6).
    -- Confidence is deliberately LOW: this is an inference, not an observation.
    IF v_believed = 0 AND v_count > 0 THEN
      n_cold := n_cold + 1;
      IF NOT p_dry_run THEN
        FOR b IN
          WITH cand AS (
            SELECT pm.boonz_product_id,
                   GREATEST(COALESCE(pm.split_pct,0),0) AS w
              FROM public.product_mapping pm
             WHERE pm.pod_product_id = s.pod_product_id
               AND pm.status = 'Active'
               AND (pm.machine_id = s.machine_id OR pm.is_global_default = true)
          ), agg AS (
            SELECT boonz_product_id, max(w) AS w FROM cand GROUP BY boonz_product_id
          ), tot AS (SELECT NULLIF(sum(w),0) AS sw FROM agg)
          SELECT a.boonz_product_id,
                 FLOOR(v_count * a.w / t.sw) AS base,
                 (v_count * a.w / t.sw) - FLOOR(v_count * a.w / t.sw) AS frac,
                 (SELECT max(pi.expiration_date) FROM public.pod_inventory pi
                   WHERE pi.shelf_id = s.shelf_id
                     AND pi.boonz_product_id = a.boonz_product_id) AS exp_bucket
            FROM agg a CROSS JOIN tot t
           WHERE t.sw IS NOT NULL AND a.w > 0
           ORDER BY frac DESC, a.boonz_product_id
        LOOP
          -- largest-remainder is applied below via the residual pass; seed the
          -- floor share here and only when it is a real quantity.
          IF b.base >= 1 THEN
            PERFORM public.record_inventory_event_v3(
              s.shelf_id, b.boonz_product_id, b.base, 'correction', b.exp_bucket,
              v_ref, 'P1.4 estimator cold-start seed from split_pct');
            n_events := n_events + 1;
          END IF;
        END LOOP;

        -- seed confidence is LOW: split_pct is a prior, not a count
        UPDATE public.shelf_composition
           SET confidence = 0.30, last_verified_at = NULL, updated_at = now()
         WHERE shelf_id = s.shelf_id;
      END IF;
      CONTINUE;   -- reconcile this shelf on the NEXT snapshot
    END IF;

    v_delta := v_count - v_believed;

    -- ================= FLAT =============================================
    IF v_delta = 0 THEN
      n_flat := n_flat + 1;
    -- ================= COUNT DROP =======================================
    ELSIF v_delta < 0 THEN
      n_drop := n_drop + 1;

      -- SELLABLE = not known-expired. Expired buckets are immutable to derived
      -- decrements (EXPIRY IRON RULE); the writer refuses them anyway, but the
      -- allocator must not even try, or the residual accounting goes wrong.
      SELECT COALESCE(sum(est_qty),0), count(*)
        INTO v_sellable, v_cand
        FROM public.shelf_composition
       WHERE shelf_id = s.shelf_id AND est_qty > 0
         AND (expiry_bucket IS NULL OR expiry_bucket >= CURRENT_DATE);

      v_alloc    := LEAST(abs(v_delta), v_sellable);
      v_residual := abs(v_delta) - v_alloc;

      IF NOT p_dry_run AND v_alloc > 0 THEN
        FOR b IN
          WITH sell AS (
            SELECT boonz_product_id, expiry_bucket, est_qty
              FROM public.shelf_composition
             WHERE shelf_id = s.shelf_id AND est_qty > 0
               AND (expiry_bucket IS NULL OR expiry_bucket >= CURRENT_DATE)
          ), sh AS (
            SELECT boonz_product_id, expiry_bucket, est_qty,
                   FLOOR(v_alloc * est_qty / v_sellable) AS base,
                   (v_alloc * est_qty / v_sellable)
                     - FLOOR(v_alloc * est_qty / v_sellable) AS frac
              FROM sell
          ), ranked AS (
            SELECT sh.*, ROW_NUMBER() OVER (ORDER BY frac DESC, est_qty DESC, boonz_product_id) AS rn,
                   v_alloc - SUM(base) OVER () AS to_spread
              FROM sh
          )
          -- largest-remainder rounding: whole units only, total exactly v_alloc
          SELECT boonz_product_id, expiry_bucket,
                 LEAST(est_qty, base + CASE WHEN rn <= to_spread THEN 1 ELSE 0 END) AS take
            FROM ranked
        LOOP
          IF b.take > 0 THEN
            PERFORM public.record_inventory_event_v3(
              s.shelf_id, b.boonz_product_id, -b.take, 'derived_decrement',
              b.expiry_bucket, v_ref,
              'P1.4 estimator: WEIMI drop allocated across ' || v_cand || ' sellable bucket(s)');
            n_events := n_events + 1;
          END IF;
        END LOOP;
      END IF;

      -- The count fell further than sellable belief could explain. The most
      -- likely physical story is that EXPIRED units left the shelf - which the
      -- estimator must never assume (IRON RULE). Flag it for a human.
      IF v_residual > 0 THEN
        n_unalloc := n_unalloc + 1;
        IF NOT p_dry_run THEN
          PERFORM public.raise_inventory_anomaly_v3(
            s.shelf_id,'negative_delta_unallocatable', v_count, v_believed, NULL, s.stock_as_of,
            jsonb_build_object('source_ref',v_ref,'residual_units',v_residual,
              'sellable_belief',v_sellable,
              'note','count dropped more than sellable belief; expired units may have left the shelf - NOT auto-consumed'));
        END IF;
      END IF;

      -- An allocation across >1 candidate is an inference, so it costs
      -- confidence. A single-candidate shelf is certain, so it does not.
      IF NOT p_dry_run AND (v_cand > 1 OR v_residual > 0) THEN
        PERFORM public.decay_composition_confidence_v3(
          s.shelf_id, v_p.composition_decay_per_unexplained, 'multi-candidate derived decrement');
        n_decayed := n_decayed + 1;
      END IF;

    -- ================= COUNT RISE =======================================
    ELSE
      -- Was the rise already explained by a real event since the last mark?
      SELECT COALESCE(sum(qty_delta),0) INTO v_expl
        FROM public.inventory_events
       WHERE shelf_id = s.shelf_id
         AND kind IN ('load','venue_fill','spot_buy_receive','correction')
         AND ts > COALESCE((SELECT max(last_verified_at) FROM public.shelf_composition
                             WHERE shelf_id = s.shelf_id), s.stock_as_of - interval '7 days');

      IF v_expl >= v_delta THEN
        n_flat := n_flat + 1;   -- already accounted for
      ELSE
        v_disp := public._estimator_rise_disposition_v3(s.machine_id, s.pod_product_id, NULL);

        IF v_disp = 'venue_fill' THEN
          n_rise_fill := n_rise_fill + 1;
          IF NOT p_dry_run THEN
            -- attribute to the largest existing bucket; unknown expiry if none
            SELECT boonz_product_id, expiry_bucket INTO b
              FROM public.shelf_composition
             WHERE shelf_id = s.shelf_id ORDER BY est_qty DESC LIMIT 1;
            IF b.boonz_product_id IS NOT NULL THEN
              PERFORM public.record_inventory_event_v3(
                s.shelf_id, b.boonz_product_id, v_delta, 'venue_fill', b.expiry_bucket, v_ref,
                'P1.4 estimator: co_managed venue-sourced count rise auto-attributed');
              n_events := n_events + 1;
            END IF;
          END IF;
        ELSE
          n_rise_anom := n_rise_anom + 1;
          IF NOT p_dry_run THEN
            PERFORM public.raise_inventory_anomaly_v3(
              s.shelf_id,'count_rise_unexplained', v_count, v_believed, NULL, s.stock_as_of,
              jsonb_build_object('source_ref',v_ref,'rise_units',v_delta,
                'sourcing',s.sourcing,'disposition',v_disp,
                'note','count rose with no Boonz event and machine is not co_managed+venue'));
            PERFORM public.decay_composition_confidence_v3(
              s.shelf_id, v_p.composition_decay_per_unexplained, 'unexplained count rise');
            n_decayed := n_decayed + 1;
          END IF;
        END IF;
      END IF;
    END IF;

    -- ---- per-day decay since last verification --------------------------
    IF NOT p_dry_run THEN
      SELECT EXTRACT(EPOCH FROM (now() - COALESCE(max(last_verified_at), min(created_at))))/86400.0
        INTO v_days FROM public.shelf_composition WHERE shelf_id = s.shelf_id;
      IF v_days IS NOT NULL AND v_days > 1 THEN
        v_decay := LEAST(1.0, v_p.composition_decay_per_day * v_days);
        PERFORM public.decay_composition_confidence_v3(s.shelf_id, v_decay, 'age decay');
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'dry_run', p_dry_run,
    'scope', CASE WHEN p_shelf_id IS NULL THEN 'fleet' ELSE 'single_shelf' END,
    'shelves_examined', n_shelves,
    'shelves_no_weimi', n_no_weimi,
    'already_processed_skipped', n_skipped_done,
    'cold_start_seeded', n_cold,
    'count_drops_allocated', n_drop,
    'rises_auto_venue_fill', n_rise_fill,
    'rises_flagged_anomaly', n_rise_anom,
    'sensor_above_capacity', n_sensor,
    'unallocatable_residuals', n_unalloc,
    'shelves_flat', n_flat,
    'shelves_confidence_decayed', n_decayed,
    'events_written', n_events,
    'runtime_ms', round(EXTRACT(EPOCH FROM (clock_timestamp()-v_t0))*1000));
END; $$;

COMMENT ON FUNCTION public.estimate_shelf_composition_v3(uuid,boolean) IS
  'PRD-110 P1.4 (WS-J2) composition estimator. Reconciles WEIMI pod-level counts against per-SKU belief. Idempotent per WEIMI snapshot via source_ref=estimator:<snapshot_at> (stress S4). Expired buckets are excluded from derived-decrement allocation (EXPIRY IRON RULE) and an unexplainable residual raises negative_delta_unallocatable rather than consuming them. Defaults to DRY RUN.';

REVOKE ALL ON FUNCTION public.estimate_shelf_composition_v3(uuid,boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._estimator_rise_disposition_v3(uuid,uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.estimate_shelf_composition_v3(uuid,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public._estimator_rise_disposition_v3(uuid,uuid,uuid) TO authenticated;
