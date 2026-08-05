-- ============================================================================
-- PRD-110 P1.4 fix — CONSERVATION in the estimator.
--
-- Defect 1 (found by dry-test E1, real): the cold-start seed used FLOOR() of
-- each split share and dropped the fractional remainder, so a WEIMI count of 14
-- seeded only 11 units. Three units vanished silently. Silent quantity loss is
-- a LAW-5 class failure. Fixed with a proper largest-remainder spread.
--
-- Defect 2 (found by inspection of the same pattern, real): the count-drop
-- allocator awarded its +1 remainder units by fractional rank WITHOUT checking
-- the bucket had headroom, so LEAST(est_qty, base+1) could silently discard a
-- unit when base already equalled est_qty. Now only buckets with headroom win a
-- remainder unit, and any shortfall that remains is reported as residual rather
-- than lost.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.estimate_shelf_composition_v3(
  p_shelf_id uuid    DEFAULT NULL,
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
  v_taken      numeric;
  v_seeded     numeric;
  v_residual   numeric;
  v_cand       int;
  v_disp       text;
  v_expl       numeric;
  v_days       numeric;
  v_decay      numeric;
  v_p          record;
  v_pick       record;
  n_shelves int := 0; n_skipped_done int := 0; n_cold int := 0;
  n_drop int := 0; n_rise_fill int := 0; n_rise_anom int := 0;
  n_sensor int := 0; n_unalloc int := 0; n_events int := 0;
  n_flat int := 0; n_decayed int := 0; n_no_weimi int := 0;
  n_cold_short int := 0;
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
    IF s.current_stock IS NULL OR s.stock_as_of IS NULL THEN
      n_no_weimi := n_no_weimi + 1; CONTINUE;
    END IF;

    n_shelves := n_shelves + 1;
    v_ref := 'estimator:' || to_char(s.stock_as_of AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS');

    IF EXISTS (SELECT 1 FROM public.inventory_events
                WHERE shelf_id = s.shelf_id AND source_ref = v_ref) THEN
      n_skipped_done := n_skipped_done + 1; CONTINUE;
    END IF;

    v_count := s.current_stock;

    IF s.max_stock IS NOT NULL AND v_count > s.max_stock THEN
      n_sensor := n_sensor + 1;
      IF NOT p_dry_run THEN
        PERFORM public.raise_inventory_anomaly_v3(
          s.shelf_id,'count_above_capacity', v_count, s.max_stock, NULL, s.stock_as_of,
          jsonb_build_object('source_ref',v_ref,'note','WEIMI count exceeds capacity; clamped for estimation'));
      END IF;
      v_count := s.max_stock;
    END IF;

    SELECT COALESCE(sum(est_qty),0) INTO v_believed
      FROM public.shelf_composition WHERE shelf_id = s.shelf_id;

    -- ================= COLD START (conserving) ==========================
    IF v_believed = 0 AND v_count > 0 THEN
      n_cold := n_cold + 1;
      v_seeded := 0;
      IF NOT p_dry_run THEN
        FOR b IN
          WITH cand AS (
            SELECT pm.boonz_product_id, GREATEST(COALESCE(pm.split_pct,0),0) AS w
              FROM public.product_mapping pm
             WHERE pm.pod_product_id = s.pod_product_id
               AND pm.status = 'Active'
               AND (pm.machine_id = s.machine_id OR pm.is_global_default = true)
          ), agg AS (
            SELECT boonz_product_id, max(w) AS w FROM cand GROUP BY boonz_product_id
             HAVING max(w) > 0
          ), tot AS (SELECT NULLIF(sum(w),0) AS sw FROM agg),
          sh AS (
            SELECT a.boonz_product_id,
                   FLOOR(v_count * a.w / t.sw)                                  AS base,
                   (v_count * a.w / t.sw) - FLOOR(v_count * a.w / t.sw)         AS frac,
                   (SELECT max(pi.expiration_date) FROM public.pod_inventory pi
                     WHERE pi.shelf_id = s.shelf_id
                       AND pi.boonz_product_id = a.boonz_product_id)            AS exp_bucket
              FROM agg a CROSS JOIN tot t WHERE t.sw IS NOT NULL
          ), ranked AS (
            SELECT sh.*,
                   ROW_NUMBER() OVER (ORDER BY frac DESC, boonz_product_id) AS rn,
                   v_count - SUM(base) OVER ()                              AS to_spread
              FROM sh
          )
          -- largest remainder: the leftover units go to the largest fractions,
          -- so SUM(qty) = v_count exactly. Nothing is dropped.
          SELECT boonz_product_id, exp_bucket,
                 base + CASE WHEN rn <= to_spread THEN 1 ELSE 0 END AS qty
            FROM ranked
        LOOP
          IF b.qty > 0 THEN
            PERFORM public.record_inventory_event_v3(
              s.shelf_id, b.boonz_product_id, b.qty, 'correction', b.exp_bucket,
              v_ref, 'P1.4 estimator cold-start seed from split_pct (largest-remainder)');
            n_events  := n_events + 1;
            v_seeded  := v_seeded + b.qty;
          END IF;
        END LOOP;

        -- CONSERVATION ASSERTION: the pod may have no active mapping at all, in
        -- which case nothing can be seeded. That is a real gap, not a rounding
        -- artifact, so it is reported rather than absorbed.
        IF v_seeded <> v_count THEN
          n_cold_short := n_cold_short + 1;
          PERFORM public.raise_inventory_anomaly_v3(
            s.shelf_id,'negative_delta_unallocatable', v_count, v_seeded, NULL, s.stock_as_of,
            jsonb_build_object('source_ref',v_ref,'seeded',v_seeded,'weimi_count',v_count,
              'shortfall',v_count - v_seeded,
              'note','cold-start seed could not conserve the WEIMI count - pod has no/partial active product_mapping'));
        END IF;

        UPDATE public.shelf_composition
           SET confidence = 0.30, last_verified_at = NULL, updated_at = now()
         WHERE shelf_id = s.shelf_id;
      END IF;
      CONTINUE;
    END IF;

    v_delta := v_count - v_believed;

    IF v_delta = 0 THEN
      n_flat := n_flat + 1;

    ELSIF v_delta < 0 THEN
      n_drop := n_drop + 1;

      SELECT COALESCE(sum(est_qty),0), count(*)
        INTO v_sellable, v_cand
        FROM public.shelf_composition
       WHERE shelf_id = s.shelf_id AND est_qty > 0
         AND (expiry_bucket IS NULL OR expiry_bucket >= CURRENT_DATE);

      v_alloc := LEAST(abs(v_delta), v_sellable);
      v_taken := 0;

      IF NOT p_dry_run AND v_alloc > 0 THEN
        FOR b IN
          WITH sell AS (
            SELECT boonz_product_id, expiry_bucket, est_qty
              FROM public.shelf_composition
             WHERE shelf_id = s.shelf_id AND est_qty > 0
               AND (expiry_bucket IS NULL OR expiry_bucket >= CURRENT_DATE)
          ), sh AS (
            SELECT boonz_product_id, expiry_bucket, est_qty,
                   FLOOR(v_alloc * est_qty / v_sellable)                        AS base,
                   (v_alloc * est_qty / v_sellable)
                     - FLOOR(v_alloc * est_qty / v_sellable)                    AS frac
              FROM sell
          ), ranked AS (
            -- only buckets with HEADROOM (est_qty > base) may win a remainder
            -- unit, else LEAST() would silently discard it.
            SELECT sh.*,
                   CASE WHEN est_qty > base
                        THEN ROW_NUMBER() OVER (
                               PARTITION BY (est_qty > base) ORDER BY frac DESC, est_qty DESC, boonz_product_id)
                        END AS rn,
                   v_alloc - SUM(base) OVER () AS to_spread
              FROM sh
          )
          SELECT boonz_product_id, expiry_bucket,
                 LEAST(est_qty, base + CASE WHEN rn IS NOT NULL AND rn <= to_spread THEN 1 ELSE 0 END) AS take
            FROM ranked
        LOOP
          IF b.take > 0 THEN
            PERFORM public.record_inventory_event_v3(
              s.shelf_id, b.boonz_product_id, -b.take, 'derived_decrement',
              b.expiry_bucket, v_ref,
              'P1.4 estimator: WEIMI drop allocated across ' || v_cand || ' sellable bucket(s)');
            n_events := n_events + 1;
            v_taken  := v_taken + b.take;
          END IF;
        END LOOP;
      END IF;

      -- residual = everything the sellable belief could not absorb, INCLUDING
      -- any rounding shortfall. Reported, never silently dropped.
      v_residual := abs(v_delta) - CASE WHEN p_dry_run THEN v_alloc ELSE v_taken END;

      IF v_residual > 0 THEN
        n_unalloc := n_unalloc + 1;
        IF NOT p_dry_run THEN
          PERFORM public.raise_inventory_anomaly_v3(
            s.shelf_id,'negative_delta_unallocatable', v_count, v_believed, NULL, s.stock_as_of,
            jsonb_build_object('source_ref',v_ref,'residual_units',v_residual,
              'sellable_belief',v_sellable,'allocated',v_taken,
              'note','count dropped more than sellable belief could absorb; expired units may have left the shelf - NOT auto-consumed'));
        END IF;
      END IF;

      IF NOT p_dry_run AND (v_cand > 1 OR v_residual > 0) THEN
        PERFORM public.decay_composition_confidence_v3(
          s.shelf_id, v_p.composition_decay_per_unexplained, 'multi-candidate derived decrement');
        n_decayed := n_decayed + 1;
      END IF;

    ELSE
      SELECT COALESCE(sum(qty_delta),0) INTO v_expl
        FROM public.inventory_events
       WHERE shelf_id = s.shelf_id
         AND kind IN ('load','venue_fill','spot_buy_receive','correction')
         AND ts > COALESCE((SELECT max(last_verified_at) FROM public.shelf_composition
                             WHERE shelf_id = s.shelf_id), s.stock_as_of - interval '7 days');

      IF v_expl >= v_delta THEN
        n_flat := n_flat + 1;
      ELSE
        v_disp := public._estimator_rise_disposition_v3(s.machine_id, s.pod_product_id, NULL);

        IF v_disp = 'venue_fill' THEN
          n_rise_fill := n_rise_fill + 1;
          IF NOT p_dry_run THEN
            SELECT boonz_product_id, expiry_bucket INTO v_pick
              FROM public.shelf_composition
             WHERE shelf_id = s.shelf_id ORDER BY est_qty DESC LIMIT 1;
            IF v_pick.boonz_product_id IS NOT NULL THEN
              PERFORM public.record_inventory_event_v3(
                s.shelf_id, v_pick.boonz_product_id, v_delta, 'venue_fill', v_pick.expiry_bucket, v_ref,
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
    'cold_start_not_conserved', n_cold_short,
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
