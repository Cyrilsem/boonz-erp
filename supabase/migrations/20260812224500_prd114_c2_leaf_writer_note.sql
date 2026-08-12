-- PRD-114 - Cody condition C-2, discharged forward-only.
--
-- record_expiry_check clears app.via_rpc and app.rpc_name on exit. That is right
-- for a top-level call and WRONG the moment anything calls it from inside another
-- writer: the clear would disarm the caller's guard mid-transaction, which is the
-- S-160 / S-197 family. It is a leaf writer today and nothing said so.
--
-- The body is otherwise IDENTICAL to 20260812222400. Only the header comment
-- block changes. Written as a new migration rather than an edit of the applied
-- one - Article 12, and the PRD-003 rule that editing an applied migration is how
-- a file stops describing what actually ran.

CREATE OR REPLACE FUNCTION public.record_expiry_check(
  p_pod_inventory_id uuid,
  p_outcome          text,
  p_event_date       date DEFAULT NULL,
  p_actor            uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
-- LEAF WRITER (Cody C-2). This function CLEARS app.via_rpc and app.rpc_name before
-- it returns. Nothing in public may call it from inside another writer: the clear
-- would disarm the caller's canonical-writer guard for the rest of the transaction
-- (S-160 / S-197). Golden fixture 114 seq 21 pins the residue. If you ever need it
-- as a delegate, hoist the clear to the caller instead of removing it here.
DECLARE
  v_caller     uuid := (SELECT auth.uid());
  v_role       text;
  v_actor      uuid;
  v_today      date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_date       date;
  v_pod        public.pod_inventory%ROWTYPE;
  v_outcome    text;
  v_severity   text;
  v_shelf_code text;
  v_machine    text;
  v_product    text;
  v_driver     text;
  v_existing   public.day_close_events%ROWTYPE;
  v_event_id   uuid;
  v_updated    boolean := false;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'record_expiry_check', true);

  IF p_pod_inventory_id IS NULL THEN
    RAISE EXCEPTION 'record_expiry_check: p_pod_inventory_id required';
  END IF;

  -- Anonymous refused BY NAME, as its own statement (D-41 / D-42 class).
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'record_expiry_check: anonymous caller refused';
  END IF;
  SELECT up.role INTO v_role FROM public.user_profiles up WHERE up.id = v_caller;
  IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'record_expiry_check: role % not authorized', COALESCE(v_role,'none');
  END IF;

  -- p_actor is a RECORDED hint, never an authorization claim.
  IF p_actor IS NOT NULL AND p_actor <> v_caller AND v_role NOT IN ('operator_admin','superadmin','manager') THEN
    v_actor := v_caller;
  ELSE
    v_actor := COALESCE(p_actor, v_caller);
  END IF;

  v_outcome := lower(btrim(COALESCE(p_outcome, '')));
  IF v_outcome NOT IN ('exists','sold','remove','skip') THEN
    RAISE EXCEPTION 'record_expiry_check: p_outcome must be exists | sold | remove | skip (got %)',
      COALESCE(NULLIF(p_outcome,''), '<null>');
  END IF;

  v_date := COALESCE(p_event_date, v_today);
  -- A closed day is settled history; pack-ahead (PRD-111) and today are live.
  IF v_date < v_today THEN
    RAISE EXCEPTION 'record_expiry_check: event_date % is behind today (Dubai) % - a closed day cannot be checked',
      v_date, v_today;
  END IF;

  -- READ ONLY on pod_inventory. FOR UPDATE is a row lock so two taps on the same
  -- batch serialize; it writes nothing and trips no write guard.
  SELECT * INTO v_pod FROM public.pod_inventory
   WHERE pod_inventory_id = p_pod_inventory_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_expiry_check: pod_inventory % not found', p_pod_inventory_id;
  END IF;
  IF v_pod.status <> 'Active' OR COALESCE(v_pod.current_stock,0) <= 0 THEN
    RAISE EXCEPTION 'record_expiry_check: pod_inventory % is % with stock % - it is not on the checklist',
      p_pod_inventory_id, COALESCE(v_pod.status,'<null>'), COALESCE(v_pod.current_stock,0);
  END IF;
  IF v_pod.expiration_date IS NULL OR v_pod.expiration_date > v_today + 7 THEN
    RAISE EXCEPTION 'record_expiry_check: pod_inventory % expires % - outside the 7-day sanity window',
      p_pod_inventory_id, COALESCE(v_pod.expiration_date::text,'<null>');
  END IF;

  -- Severity is recomputed HERE from the ledger and the real clock. The client
  -- sends an outcome, never a severity: the red/amber rule is a backend fact.
  v_severity := CASE WHEN v_pod.expiration_date < v_today THEN 'expired' ELSE 'expiring' END;

  -- §3.2: an expired batch cannot "exist and stay". It either already sold or
  -- the driver pulls it. Exists / Skip are amber-only options.
  IF v_severity = 'expired' AND v_outcome NOT IN ('sold','remove') THEN
    RAISE EXCEPTION 'record_expiry_check: an EXPIRED batch takes sold or remove only (got %) - it cannot stay on the shelf',
      v_outcome;
  END IF;

  SELECT sc.shelf_code            INTO v_shelf_code FROM public.shelf_configurations sc WHERE sc.shelf_id = v_pod.shelf_id;
  SELECT m.official_name          INTO v_machine    FROM public.machines m            WHERE m.machine_id = v_pod.machine_id;
  SELECT bp.boonz_product_name    INTO v_product    FROM public.boonz_products bp     WHERE bp.product_id = v_pod.boonz_product_id;
  -- Snapshotted, not joined at read time: user_profiles RLS is own-row only.
  SELECT up.full_name             INTO v_driver     FROM public.user_profiles up      WHERE up.id = v_actor;

  SELECT * INTO v_existing FROM public.day_close_events
   WHERE kind = 'expiry_check'
     AND event_date = v_date
     AND payload ->> 'pod_inventory_id' = p_pod_inventory_id::text
   FOR UPDATE;

  IF FOUND AND v_existing.acknowledged_at IS NOT NULL THEN
    RAISE EXCEPTION 'record_expiry_check: this check was acknowledged at % and is locked - reopen it with the office',
      v_existing.acknowledged_at;
  END IF;

  IF FOUND THEN
    UPDATE public.day_close_events
       SET payload = payload || jsonb_build_object(
             'outcome',       v_outcome,
             'severity',      v_severity,
             'qty',           v_pod.current_stock,
             'expiry',        v_pod.expiration_date,
             'shelf_code',    v_shelf_code,
             'product_name',  v_product,
             'actor',         v_actor,
             'driver_name',   v_driver,
             'recorded_at',   now(),
             'retap_count',   COALESCE((payload ->> 'retap_count')::int, 0) + 1)
     WHERE id = v_existing.id
     RETURNING id INTO v_event_id;
    v_updated := true;
  ELSE
    INSERT INTO public.day_close_events
      (event_date, machine_id, dispatch_id, kind, payload, created_by)
    VALUES
      (v_date, v_pod.machine_id, NULL, 'expiry_check',
       jsonb_build_object(
         'pod_inventory_id', p_pod_inventory_id,
         'machine_name',     v_machine,
         'shelf_id',         v_pod.shelf_id,
         'shelf_code',       v_shelf_code,
         'boonz_product_id', v_pod.boonz_product_id,
         'product_name',     v_product,
         'qty',              v_pod.current_stock,
         'expiry',           v_pod.expiration_date,
         'severity',         v_severity,
         'outcome',          v_outcome,
         'actor',            v_actor,
         'driver_name',      v_driver,
         'recorded_at',      now(),
         'retap_count',      0),
       v_caller)
    RETURNING id INTO v_event_id;
  END IF;

  -- The GUCs are transaction-local and leak forward inside one transaction
  -- (PRD-016B). Leave them as we found them. See the LEAF WRITER note above.
  PERFORM set_config('app.via_rpc',  '', true);
  PERFORM set_config('app.rpc_name', '', true);

  RETURN jsonb_build_object(
    'ok', true, 'event_id', v_event_id, 'updated', v_updated,
    'event_date', v_date, 'pod_inventory_id', p_pod_inventory_id,
    'severity', v_severity, 'outcome', v_outcome,
    'shelf_code', v_shelf_code, 'product_name', v_product,
    'qty', v_pod.current_stock, 'expiry', v_pod.expiration_date);
END
$function$;
