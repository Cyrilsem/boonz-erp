-- PRD-110 · S-41 + S-42 · leg 36 · the estimator stops compounding what it already did
--
-- PROVEN RED FIRST by golden fixture 27 (migration 20260731...idempotency, run
-- 'leg 36 S-41/S-42 FAILING BASELINE (pre-fix)'):
--   seq 6 = false (expect true)  -- confidence decayed TWICE for one snapshot (0.94 -> 0.88)
--   seq 8 = 1     (expect 0)     -- the anomaly was re-raised for an observation already recorded
--   seq 9 = 2     (expect 1)     -- identical (shelf, kind, snapshot) inserted two rows
--   10 other assertions green, including the non-vacuity guard (seq 3) and residue (95/96/97).
--
-- ROOT CAUSE (one, two symptoms). The estimator's idempotency marker is `inventory_events`
-- (RISK 76). A shelf whose belief already equals its clamped count goes FLAT, writes no event,
-- and therefore never sets the marker - so cron 44 re-runs its whole body 24 times a day.
-- Measured live: `already_processed_skipped = 0` on a snapshot processed four times already.
--
-- WHAT CHANGES - exactly two behaviours, nothing else in either function.
--
-- (1) AGE DECAY IS NOW ANCHORED AND AT-MOST-ONCE-PER-DAY (S-42).
--     Before: `v_days` measured from a FIXED anchor (last_verified_at, else created_at) and the
--     tail SUBTRACTED `rate x v_days` on EVERY firing. That is cumulative in time - wrong even at
--     a once-per-day cadence - and at 24 firings/day it drove confidence 0.30 -> 0 in ~15 firings.
--     It was due to start at 2026-07-31 18:40:00Z, when v_days first exceeds 1 on the burn-in machine.
--     After: the anchor includes `last_age_decay_at`, which this function stamps immediately after
--     decaying. Applying the decay therefore ADVANCES the anchor, so a second firing in the same
--     day computes v_days < 1 and does nothing. Frequency-independent by construction.
--     `FLOOR(v_days)` makes the amount whole-days, so a 3-day gap costs exactly rate x 3, once.
--
-- (2) THE ANOMALY RAISER IS IDEMPOTENT PER OBSERVATION (S-41).
--     One physical observation is (shelf, kind, weimi_snapshot_at, product). Raising it again
--     returns the existing anomaly_id instead of inserting a duplicate. Only applies when
--     `p_weimi_snapshot_at IS NOT NULL` - without a snapshot there is no observation identity and
--     every call is genuinely new, so nothing is silenced.
--     ⚠️ RETURN CONTRACT CHANGE (Cody revision 1): this may now return a PRE-EXISTING anomaly_id.
--     The only caller today is the estimator, via PERFORM, which discards it. Recorded in
--     RPC_REGISTRY so no future caller assumes the id was freshly minted.
--
-- ⚠️ NO HISTORY IS DELETED (Cody + the standing no-destructive rule). The 35 live anomaly rows,
--    15 of which are known duplicates, are left exactly as they are. A unique index would have
--    required deleting them, which is why this is a function guard and not a constraint. The
--    duplicates are evidence of the defect and stay on the record.
--
-- ⚠️ FIRST-FIRING SETTLE-UP (Cody revision 2). `last_age_decay_at` ships NULL on all 31 existing
--    rows, so the first post-fix firing falls through to min(created_at) = 2026-07-30 18:40Z and
--    applies ONE legitimate accrued decay, then stamps and settles to once-per-day. That single
--    drop is CORRECT, not a regression - do not "fix" it next leg.
--
-- Art 12 forward-only: CREATE OR REPLACE (never DROP+CREATE, RISK 77 keeps the ACL), additive
-- nullable column, no backfill, signatures unchanged. Art 2/3: RLS untouched, SELECT-only policies
-- intact. Art 4: via_rpc/rpc_name and role validation preserved in both. Art 16: this function
-- PRODUCES confidence; v_shelf_audit_prompts / v_expiry_action_queue consume it - no metric is
-- re-derived inline. LAW 12: no live plan table touched. LAW 7: the EXPIRY IRON RULE is untouched -
-- expired buckets remain immutable to derived decrements.

BEGIN;

ALTER TABLE public.shelf_composition
  ADD COLUMN IF NOT EXISTS last_age_decay_at timestamptz;

COMMENT ON COLUMN public.shelf_composition.last_age_decay_at IS
  'PRD-110 S-42: anchor for per-day confidence age decay. Stamped by estimate_shelf_composition_v3 '
  'immediately after it applies an age decay, so repeated firings within the same day cannot '
  'compound it. NULL means never age-decayed; the anchor then falls back to last_verified_at, then '
  'created_at. Deliberately NOT bumped by unrelated writers - that is why it is a separate column '
  'and not updated_at.';

CREATE OR REPLACE FUNCTION public.estimate_shelf_composition_v3(p_shelf_id uuid DEFAULT NULL::uuid, p_dry_run boolean DEFAULT true, p_force_rederive boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  n_forced int := 0;
  n_age_decayed int := 0;
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

  IF p_force_rederive AND p_shelf_id IS NULL THEN
    RAISE EXCEPTION 'estimate_shelf_composition_v3: p_force_rederive requires a single p_shelf_id (refusing a fleet-wide forced re-derive)';
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
      IF p_force_rederive THEN
        n_forced := n_forced + 1;
      ELSE
        n_skipped_done := n_skipped_done + 1; CONTINUE;
      END IF;
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

    -- ============ AGE DECAY - S-42: anchored, and at most once per elapsed day ============
    -- The anchor now includes last_age_decay_at, which this branch stamps. Applying the decay
    -- therefore MOVES the anchor, so the next firing in the same day computes v_days < 1 and
    -- does nothing. That is what makes the total rate independent of cron 44's frequency.
    -- FLOOR(v_days) charges whole days only, so a 3-day gap costs rate x 3 exactly once, rather
    -- than rate x 3 on every firing until something else touches the shelf.
    IF NOT p_dry_run THEN
      SELECT EXTRACT(EPOCH FROM (now() - COALESCE(max(last_age_decay_at),
                                                  max(last_verified_at),
                                                  min(created_at))))/86400.0
        INTO v_days FROM public.shelf_composition WHERE shelf_id = s.shelf_id;
      IF v_days IS NOT NULL AND v_days >= 1 THEN
        v_decay := LEAST(1.0, v_p.composition_decay_per_day * FLOOR(v_days));
        PERFORM public.decay_composition_confidence_v3(s.shelf_id, v_decay, 'age decay');
        UPDATE public.shelf_composition
           SET last_age_decay_at = now()
         WHERE shelf_id = s.shelf_id;
        n_age_decayed := n_age_decayed + 1;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'dry_run', p_dry_run,
    'scope', CASE WHEN p_shelf_id IS NULL THEN 'fleet' ELSE 'single_shelf' END,
    'shelves_examined', n_shelves,
    'shelves_no_weimi', n_no_weimi,
    'already_processed_skipped', n_skipped_done,
    'force_rederive', p_force_rederive,
    'forced_rederive', n_forced,
    'cold_start_seeded', n_cold,
    'cold_start_not_conserved', n_cold_short,
    'count_drops_allocated', n_drop,
    'rises_auto_venue_fill', n_rise_fill,
    'rises_flagged_anomaly', n_rise_anom,
    'sensor_above_capacity', n_sensor,
    'unallocatable_residuals', n_unalloc,
    'shelves_flat', n_flat,
    'shelves_confidence_decayed', n_decayed,
    'shelves_age_decayed', n_age_decayed,
    'events_written', n_events,
    'runtime_ms', round(EXTRACT(EPOCH FROM (clock_timestamp()-v_t0))*1000));
END; $function$;

CREATE OR REPLACE FUNCTION public.raise_inventory_anomaly_v3(p_shelf_id uuid, p_kind text, p_observed_qty numeric DEFAULT NULL::numeric, p_expected_qty numeric DEFAULT NULL::numeric, p_boonz_product_id uuid DEFAULT NULL::uuid, p_weimi_snapshot_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_detail jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_actor uuid; v_machine uuid; v_id uuid;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','raise_inventory_anomaly_v3',true);

  v_actor := auth.uid();
  IF v_actor IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up WHERE up.id = v_actor
      AND up.role IN ('warehouse','operator_admin','superadmin','manager','field_staff')
  ) THEN
    RAISE EXCEPTION 'raise_inventory_anomaly_v3: caller % lacks a permitted role', v_actor;
  END IF;

  SELECT machine_id INTO v_machine FROM public.shelf_configurations WHERE shelf_id = p_shelf_id;
  IF v_machine IS NULL THEN
    RAISE EXCEPTION 'raise_inventory_anomaly_v3: shelf_id % does not exist', p_shelf_id;
  END IF;

  -- S-41: one PHYSICAL OBSERVATION is (shelf, kind, weimi_snapshot_at, product). Re-reporting it
  -- is not new information, so return what is already on the record instead of duplicating it.
  -- Guarded on a non-null snapshot: with no snapshot there is no observation identity, and every
  -- call is genuinely new - so this can never silence a caller that supplies no snapshot.
  -- ⚠️ RETURN CONTRACT: the id returned here is PRE-EXISTING, not freshly minted (see RPC_REGISTRY).
  IF p_weimi_snapshot_at IS NOT NULL THEN
    SELECT anomaly_id INTO v_id
      FROM public.inventory_anomalies
     WHERE shelf_id          = p_shelf_id
       AND kind              = p_kind
       AND weimi_snapshot_at = p_weimi_snapshot_at
       AND boonz_product_id IS NOT DISTINCT FROM p_boonz_product_id
     ORDER BY detected_at
     LIMIT 1;
    IF v_id IS NOT NULL THEN
      RETURN v_id;
    END IF;
  END IF;

  INSERT INTO public.inventory_anomalies
    (machine_id, shelf_id, boonz_product_id, kind, observed_qty, expected_qty,
     weimi_snapshot_at, detail)
  VALUES (v_machine, p_shelf_id, p_boonz_product_id, p_kind, p_observed_qty, p_expected_qty,
          p_weimi_snapshot_at, COALESCE(p_detail,'{}'::jsonb))
  RETURNING anomaly_id INTO v_id;

  RETURN v_id;
END; $function$;

-- RISK 77 belt-and-braces: CREATE OR REPLACE preserves the ACL, but assert it anyway.
REVOKE ALL ON FUNCTION public.estimate_shelf_composition_v3(uuid, boolean, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.estimate_shelf_composition_v3(uuid, boolean, boolean) FROM anon;
REVOKE ALL ON FUNCTION public.raise_inventory_anomaly_v3(uuid, text, numeric, numeric, uuid, timestamptz, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.raise_inventory_anomaly_v3(uuid, text, numeric, numeric, uuid, timestamptz, jsonb) FROM anon;

COMMIT;