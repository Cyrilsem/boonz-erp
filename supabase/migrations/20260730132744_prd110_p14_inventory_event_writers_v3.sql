-- ============================================================================
-- PRD-110 P1.4 — canonical writers for the WS-J2 truth layer.
-- Article 1: these are the ONLY write paths for inventory_events /
-- shelf_composition / inventory_anomalies (the tables have SELECT-only RLS).
-- Article 4: each sets app.via_rpc + app.rpc_name, validates inputs and role.
-- Role gate matches the house pattern (record_blocked_demand_v3): a NULL actor
-- is allowed so cron/estimator can call it; a real caller must hold the role.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. P1.4 params (BUILD SPEC: "confidence >= 0.7 (param)", "<=3 prompts/visit")
-- ---------------------------------------------------------------------------
ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS composition_confidence_min_autoaction numeric NOT NULL DEFAULT 0.7,
  ADD COLUMN IF NOT EXISTS composition_confidence_prompt_threshold numeric NOT NULL DEFAULT 0.5,
  ADD COLUMN IF NOT EXISTS composition_decay_per_day numeric NOT NULL DEFAULT 0.02,
  ADD COLUMN IF NOT EXISTS composition_decay_per_unexplained numeric NOT NULL DEFAULT 0.15,
  ADD COLUMN IF NOT EXISTS composition_max_prompts_per_visit int NOT NULL DEFAULT 3;

COMMENT ON COLUMN public.refill_policy_params.composition_confidence_min_autoaction IS
  'PRD-110 P1.4: minimum shelf_composition.confidence for an automatic expiry write-off line. Below this the system raises a verify task instead of acting.';

-- ---------------------------------------------------------------------------
-- 1. raise_inventory_anomaly_v3 — canonical writer for inventory_anomalies.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.raise_inventory_anomaly_v3(
  p_shelf_id          uuid,
  p_kind              text,
  p_observed_qty      numeric DEFAULT NULL,
  p_expected_qty      numeric DEFAULT NULL,
  p_boonz_product_id  uuid    DEFAULT NULL,
  p_weimi_snapshot_at timestamptz DEFAULT NULL,
  p_detail            jsonb   DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
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

  INSERT INTO public.inventory_anomalies
    (machine_id, shelf_id, boonz_product_id, kind, observed_qty, expected_qty,
     weimi_snapshot_at, detail)
  VALUES (v_machine, p_shelf_id, p_boonz_product_id, p_kind, p_observed_qty, p_expected_qty,
          p_weimi_snapshot_at, COALESCE(p_detail,'{}'::jsonb))
  RETURNING anomaly_id INTO v_id;

  RETURN v_id;
END; $$;

-- ---------------------------------------------------------------------------
-- 2. record_inventory_event_v3 — THE canonical event writer.
--    Appends the event, then moves the matching shelf_composition bucket.
--    EXPIRY IRON RULE is enforced here: a derived_decrement may never consume
--    a KNOWN-expired bucket. Expired stock exits only by human event.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_inventory_event_v3(
  p_shelf_id         uuid,
  p_boonz_product_id uuid,
  p_qty_delta        numeric,
  p_kind             text,
  p_expiry_date      date        DEFAULT NULL,
  p_source_ref       text        DEFAULT NULL,
  p_note             text        DEFAULT NULL,
  p_ts               timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_actor    uuid;
  v_machine  uuid;
  v_event    uuid;
  v_prev     numeric := 0;
  v_new      numeric;
  v_had_row  boolean := false;
  v_anomaly  uuid;
  v_verified timestamptz;
  v_conf     numeric;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','record_inventory_event_v3',true);

  v_actor := auth.uid();
  IF v_actor IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up WHERE up.id = v_actor
      AND up.role IN ('warehouse','operator_admin','superadmin','manager','field_staff')
  ) THEN
    RAISE EXCEPTION 'record_inventory_event_v3: caller % lacks a permitted role', v_actor;
  END IF;

  -- ---- validate (Article 4) ------------------------------------------------
  IF p_shelf_id IS NULL OR p_boonz_product_id IS NULL THEN
    RAISE EXCEPTION 'record_inventory_event_v3: shelf_id and boonz_product_id are required';
  END IF;
  IF p_qty_delta IS NULL OR p_qty_delta = 0 THEN
    RAISE EXCEPTION 'record_inventory_event_v3: qty_delta must be non-zero (got %)', p_qty_delta;
  END IF;

  SELECT machine_id INTO v_machine FROM public.shelf_configurations WHERE shelf_id = p_shelf_id;
  IF v_machine IS NULL THEN
    RAISE EXCEPTION 'record_inventory_event_v3: shelf_id % does not exist', p_shelf_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.boonz_products WHERE product_id = p_boonz_product_id) THEN
    RAISE EXCEPTION 'record_inventory_event_v3: boonz_product_id % does not exist', p_boonz_product_id;
  END IF;

  -- ---- EXPIRY IRON RULE ---------------------------------------------------
  IF p_kind = 'derived_decrement'
     AND p_expiry_date IS NOT NULL
     AND p_expiry_date < CURRENT_DATE THEN
    RAISE EXCEPTION
      'record_inventory_event_v3: EXPIRY IRON RULE - a derived_decrement may not consume the known-expired bucket % on shelf %. Expired stock exits only via write_off, return or expired_sold_incident.',
      p_expiry_date, p_shelf_id;
  END IF;

  -- ---- append the event ---------------------------------------------------
  INSERT INTO public.inventory_events
    (ts, machine_id, shelf_id, boonz_product_id, qty_delta, kind, expiry_date,
     source_ref, actor, note)
  VALUES (COALESCE(p_ts, now()), v_machine, p_shelf_id, p_boonz_product_id, p_qty_delta,
          p_kind, p_expiry_date, p_source_ref, v_actor, p_note)
  RETURNING event_id INTO v_event;

  -- ---- move the composition bucket ---------------------------------------
  SELECT est_qty, true INTO v_prev, v_had_row
    FROM public.shelf_composition
   WHERE shelf_id = p_shelf_id AND boonz_product_id = p_boonz_product_id
     AND expiry_bucket IS NOT DISTINCT FROM p_expiry_date;
  v_prev := COALESCE(v_prev, 0);

  v_new := v_prev + p_qty_delta;

  -- Underflow is never silently absorbed (LAW 5 analogue): clamp AND flag.
  IF v_new < 0 THEN
    v_anomaly := public.raise_inventory_anomaly_v3(
      p_shelf_id, 'composition_underflow', v_new, v_prev, p_boonz_product_id, NULL,
      jsonb_build_object('event_id', v_event, 'kind', p_kind, 'qty_delta', p_qty_delta,
                         'expiry_bucket', p_expiry_date,
                         'note','delta drove est_qty below zero; clamped to 0'));
    v_new := 0;
  END IF;

  -- Confidence: 1.0 on driver_confirm, and on a load into an empty bucket
  -- ("load-to-empty" per BUILD SPEC). Other real events leave it unchanged.
  v_conf     := NULL;
  v_verified := NULL;
  IF p_kind = 'driver_confirm' THEN
    v_conf := 1.0; v_verified := COALESCE(p_ts, now());
  ELSIF p_kind = 'load' AND v_prev = 0 THEN
    v_conf := 1.0; v_verified := COALESCE(p_ts, now());
  END IF;

  INSERT INTO public.shelf_composition
    (machine_id, shelf_id, boonz_product_id, expiry_bucket, est_qty,
     confidence, last_verified_at, last_event_id, updated_at)
  VALUES (v_machine, p_shelf_id, p_boonz_product_id, p_expiry_date, v_new,
          COALESCE(v_conf, 1.0), v_verified, v_event, now())
  ON CONFLICT (shelf_id, boonz_product_id, expiry_bucket) DO UPDATE
    SET est_qty          = v_new,
        confidence       = COALESCE(v_conf, public.shelf_composition.confidence),
        last_verified_at = COALESCE(v_verified, public.shelf_composition.last_verified_at),
        last_event_id    = v_event,
        updated_at       = now();

  RETURN jsonb_build_object(
    'event_id', v_event, 'machine_id', v_machine, 'shelf_id', p_shelf_id,
    'boonz_product_id', p_boonz_product_id, 'expiry_bucket', p_expiry_date,
    'kind', p_kind, 'qty_delta', p_qty_delta,
    'est_qty_before', v_prev, 'est_qty_after', v_new,
    'clamped', (v_prev + p_qty_delta) < 0, 'anomaly_id', v_anomaly);
END; $$;

-- ---------------------------------------------------------------------------
-- 3. decay_composition_confidence_v3 — the estimator's uncertainty writer.
--    Separated from the event writer so "how sure are we" never rides on
--    "what happened". Clamped to [0,1].
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.decay_composition_confidence_v3(
  p_shelf_id uuid,
  p_amount   numeric,
  p_reason   text DEFAULT NULL
) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_actor uuid; v_n int;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','decay_composition_confidence_v3',true);

  v_actor := auth.uid();
  IF v_actor IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up WHERE up.id = v_actor
      AND up.role IN ('warehouse','operator_admin','superadmin','manager')
  ) THEN
    RAISE EXCEPTION 'decay_composition_confidence_v3: caller % lacks a permitted role', v_actor;
  END IF;
  IF p_amount IS NULL OR p_amount < 0 THEN
    RAISE EXCEPTION 'decay_composition_confidence_v3: p_amount must be >= 0 (got %)', p_amount;
  END IF;

  UPDATE public.shelf_composition
     SET confidence = GREATEST(0, LEAST(1, confidence - p_amount)),
         updated_at = now()
   WHERE shelf_id = p_shelf_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END; $$;

-- ---------------------------------------------------------------------------
-- 4. driver_confirm_shelf_v3 — the collapse. Driver states what is really on
--    the shelf; estimate snaps to truth and confidence resets to 1.0.
--    History is PRESERVED: every correction is an appended event, never an
--    overwrite (fixture 21).
--    Fixture 23: if a KNOWN-EXPIRED bucket confirms LOWER than the estimate,
--    expired units left the shelf with no write-off -> that is not a routine
--    confirm, it is an expired_sold_incident, and it raises an anomaly.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.driver_confirm_shelf_v3(
  p_shelf_id  uuid,
  p_confirmed jsonb,
  p_note      text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_actor uuid; v_machine uuid;
  v_row record; v_delta numeric; v_kind text;
  v_events int := 0; v_incidents int := 0; v_zeroed int := 0;
  v_res jsonb := '[]'::jsonb; v_one jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','driver_confirm_shelf_v3',true);

  v_actor := auth.uid();
  IF v_actor IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up WHERE up.id = v_actor
      AND up.role IN ('warehouse','operator_admin','superadmin','manager','field_staff')
  ) THEN
    RAISE EXCEPTION 'driver_confirm_shelf_v3: caller % lacks a permitted role', v_actor;
  END IF;

  SELECT machine_id INTO v_machine FROM public.shelf_configurations WHERE shelf_id = p_shelf_id;
  IF v_machine IS NULL THEN
    RAISE EXCEPTION 'driver_confirm_shelf_v3: shelf_id % does not exist', p_shelf_id;
  END IF;
  IF p_confirmed IS NULL OR jsonb_typeof(p_confirmed) <> 'array' THEN
    RAISE EXCEPTION 'driver_confirm_shelf_v3: p_confirmed must be a jsonb array of {boonz_product_id, expiry_date, qty}';
  END IF;

  -- (a) buckets the driver DID report -> snap to the reported qty
  FOR v_row IN
    SELECT (e->>'boonz_product_id')::uuid AS pid,
           NULLIF(e->>'expiry_date','')::date AS exp,
           (e->>'qty')::numeric AS qty
      FROM jsonb_array_elements(p_confirmed) e
  LOOP
    IF v_row.pid IS NULL OR v_row.qty IS NULL OR v_row.qty < 0 THEN
      RAISE EXCEPTION 'driver_confirm_shelf_v3: each entry needs boonz_product_id and qty >= 0 (got pid=%, qty=%)', v_row.pid, v_row.qty;
    END IF;

    SELECT COALESCE((SELECT est_qty FROM public.shelf_composition
                      WHERE shelf_id=p_shelf_id AND boonz_product_id=v_row.pid
                        AND expiry_bucket IS NOT DISTINCT FROM v_row.exp), 0)
      INTO v_delta;
    v_delta := v_row.qty - v_delta;

    IF v_delta <> 0 THEN
      -- an expired bucket that shrank = units sold/removed while expired
      IF v_delta < 0 AND v_row.exp IS NOT NULL AND v_row.exp < CURRENT_DATE THEN
        v_kind := 'expired_sold_incident';
        v_incidents := v_incidents + 1;
        PERFORM public.raise_inventory_anomaly_v3(
          p_shelf_id, 'expired_sold_suspected', v_row.qty, v_row.qty - v_delta, v_row.pid, NULL,
          jsonb_build_object('expiry_bucket', v_row.exp, 'units', abs(v_delta),
            'note','expired bucket shrank at driver confirm with no write-off'));
      ELSE
        v_kind := 'driver_confirm';
      END IF;

      v_one := public.record_inventory_event_v3(
        p_shelf_id, v_row.pid, v_delta, v_kind, v_row.exp, 'driver_confirm_shelf_v3', p_note);
      v_events := v_events + 1;
      v_res := v_res || v_one;
    END IF;

    -- reset confidence even when the estimate was already exactly right
    UPDATE public.shelf_composition
       SET confidence = 1.0, last_verified_at = now(), updated_at = now()
     WHERE shelf_id = p_shelf_id AND boonz_product_id = v_row.pid
       AND expiry_bucket IS NOT DISTINCT FROM v_row.exp;
  END LOOP;

  -- (b) buckets the estimator believed in that the driver did NOT report -> zero them
  FOR v_row IN
    SELECT sc.boonz_product_id AS pid, sc.expiry_bucket AS exp, sc.est_qty AS qty
      FROM public.shelf_composition sc
     WHERE sc.shelf_id = p_shelf_id AND sc.est_qty > 0
       AND NOT EXISTS (
         SELECT 1 FROM jsonb_array_elements(p_confirmed) e
          WHERE (e->>'boonz_product_id')::uuid = sc.boonz_product_id
            AND NULLIF(e->>'expiry_date','')::date IS NOT DISTINCT FROM sc.expiry_bucket)
  LOOP
    IF v_row.exp IS NOT NULL AND v_row.exp < CURRENT_DATE THEN
      v_kind := 'expired_sold_incident';
      v_incidents := v_incidents + 1;
      PERFORM public.raise_inventory_anomaly_v3(
        p_shelf_id, 'expired_sold_suspected', 0, v_row.qty, v_row.pid, NULL,
        jsonb_build_object('expiry_bucket', v_row.exp, 'units', v_row.qty,
          'note','expired bucket absent at driver confirm with no write-off'));
    ELSE
      v_kind := 'driver_confirm';
    END IF;

    PERFORM public.record_inventory_event_v3(
      p_shelf_id, v_row.pid, -v_row.qty, v_kind, v_row.exp, 'driver_confirm_shelf_v3',
      COALESCE(p_note,'') || ' [not present at confirm]');
    v_events := v_events + 1; v_zeroed := v_zeroed + 1;
  END LOOP;

  UPDATE public.shelf_composition
     SET confidence = 1.0, last_verified_at = now(), updated_at = now()
   WHERE shelf_id = p_shelf_id;

  RETURN jsonb_build_object(
    'shelf_id', p_shelf_id, 'machine_id', v_machine,
    'events_written', v_events, 'buckets_zeroed', v_zeroed,
    'expired_sold_incidents', v_incidents, 'confidence_reset_to', 1.0,
    'deltas', v_res);
END; $$;

-- ---------------------------------------------------------------------------
-- 5. resolve_inventory_anomaly_v3
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_inventory_anomaly_v3(
  p_anomaly_id uuid,
  p_resolution text,
  p_note       text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_actor uuid; v_n int;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','resolve_inventory_anomaly_v3',true);

  v_actor := auth.uid();
  IF v_actor IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up WHERE up.id = v_actor
      AND up.role IN ('warehouse','operator_admin','superadmin','manager')
  ) THEN
    RAISE EXCEPTION 'resolve_inventory_anomaly_v3: caller % lacks a permitted role', v_actor;
  END IF;
  IF p_note IS NULL OR length(btrim(p_note)) < 10 THEN
    RAISE EXCEPTION 'resolve_inventory_anomaly_v3: p_note must be at least 10 characters';
  END IF;

  UPDATE public.inventory_anomalies
     SET resolved_at = now(), resolution = p_resolution, resolved_by = v_actor,
         detail = detail || jsonb_build_object('resolution_note', p_note)
   WHERE anomaly_id = p_anomaly_id AND resolved_at IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  IF v_n = 0 THEN
    RAISE EXCEPTION 'resolve_inventory_anomaly_v3: anomaly % not found or already resolved', p_anomaly_id;
  END IF;
  RETURN jsonb_build_object('anomaly_id', p_anomaly_id, 'resolution', p_resolution);
END; $$;

-- ---------------------------------------------------------------------------
-- 6. Grants — authenticated may EXECUTE; anon never.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.raise_inventory_anomaly_v3(uuid,text,numeric,numeric,uuid,timestamptz,jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.record_inventory_event_v3(uuid,uuid,numeric,text,date,text,text,timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.decay_composition_confidence_v3(uuid,numeric,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.driver_confirm_shelf_v3(uuid,jsonb,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resolve_inventory_anomaly_v3(uuid,text,text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.raise_inventory_anomaly_v3(uuid,text,numeric,numeric,uuid,timestamptz,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_inventory_event_v3(uuid,uuid,numeric,text,date,text,text,timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decay_composition_confidence_v3(uuid,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.driver_confirm_shelf_v3(uuid,jsonb,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_inventory_anomaly_v3(uuid,text,text) TO authenticated;
