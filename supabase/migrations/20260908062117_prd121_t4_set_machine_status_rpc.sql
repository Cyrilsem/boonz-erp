-- PRD-121 T4: set_machine_status becomes the canonical (and, after the
-- REVOKE below, exclusive) writer of machines.status, adyen_status,
-- adyen_inventory_in_store and installation_date.
--
-- Article 5 gap this closes: no canonical writer existed for machines.status
-- on an EXISTING row (see 20260824081149_commission_iris_1070_single_door.sql,
-- whose own header comment documents this gap). New-row creation
-- (add_new_machine's INSERT, the field-config "Add machine" / CSV-import
-- direct inserts) is out of scope -- this RPC and its enforcing trigger only
-- govern transitions on rows that already exist (trigger is BEFORE UPDATE,
-- not BEFORE INSERT).
--
-- Invariant (D3): status = 'Active' AND repurposed_at IS NULL
--   ==> adyen_status = 'Online today' AND adyen_inventory_in_store = 'Live'.
-- repurpose_machine is unaffected: its OLD-row UPDATE sets repurposed_at to
-- CURRENT_DATE in the same statement (so the NULL precondition is already
-- false when the trigger evaluates), and its NEW-row INSERT already sets
-- adyen_status='Online today', adyen_inventory_in_store='Live' and relies on
-- the status column DEFAULT 'Active' -- both satisfy the invariant with no
-- code change (Cody: repurpose_machine stays as-is).

-- ── 1. Append-only audit log ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.machine_status_events (
  event_id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id                      uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  old_status                      text,
  new_status                      text,
  old_adyen_status                text,
  new_adyen_status                text,
  old_adyen_inventory_in_store    text,
  new_adyen_inventory_in_store    text,
  old_installation_date           date,
  new_installation_date           date,
  reason                          text NOT NULL,
  changed_by                      uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  changed_by_role                 text,
  changed_at                      timestamptz NOT NULL DEFAULT now(),
  via_rpc                         boolean NOT NULL DEFAULT true,
  rpc_name                        text NOT NULL DEFAULT 'set_machine_status'
);

COMMENT ON TABLE public.machine_status_events IS
  'PRD-121 D3: append-only audit trail for set_machine_status writes to machines.status/adyen_status/adyen_inventory_in_store/installation_date.';

ALTER TABLE public.machine_status_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY machine_status_events_select ON public.machine_status_events
  FOR SELECT TO authenticated USING (true);

-- S-308: a new public table is born writable by authenticated via default
-- privileges. No INSERT/UPDATE/DELETE policy is created (default-deny), and
-- the grant itself is revoked below so only the DEFINER (which bypasses RLS
-- and grants as its owner) can write rows.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.machine_status_events FROM authenticated;

CREATE INDEX IF NOT EXISTS idx_machine_status_events_machine_changed
  ON public.machine_status_events (machine_id, changed_at DESC);
-- Serves: "history of status changes for machine X", newest first.

-- ── 2. The canonical writer ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_machine_status(
  p_machine_id uuid,
  p_status text DEFAULT NULL,
  p_adyen_status text DEFAULT NULL,
  p_adyen_inventory_in_store text DEFAULT NULL,
  p_installation_date date DEFAULT NULL,
  p_reason text DEFAULT NULL,
  p_caller uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := COALESCE(p_caller, auth.uid());
  v_role text;
  v_row public.machines%ROWTYPE;
  v_new_status text;
  v_new_adyen_status text;
  v_new_adyen_inventory_in_store text;
  v_new_installation_date date;
  v_event_id uuid;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'set_machine_status', true);

  IF v_caller IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_caller;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'set_machine_status: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  IF p_machine_id IS NULL THEN
    RAISE EXCEPTION 'set_machine_status: p_machine_id required';
  END IF;
  IF length(COALESCE(p_reason,'')) < 10 THEN
    RAISE EXCEPTION 'set_machine_status: p_reason must be at least 10 characters';
  END IF;
  IF p_status IS NULL AND p_adyen_status IS NULL AND p_adyen_inventory_in_store IS NULL AND p_installation_date IS NULL THEN
    RAISE EXCEPTION 'set_machine_status: at least one of p_status/p_adyen_status/p_adyen_inventory_in_store/p_installation_date must be provided';
  END IF;

  SELECT * INTO v_row FROM public.machines WHERE machine_id = p_machine_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'set_machine_status: machine % not found', p_machine_id;
  END IF;

  -- A NULL parameter means "leave this column unchanged" -- callers that
  -- only ever touch one of the four columns (e.g. the field-config status
  -- dropdown) don't need to first fetch and re-pass the other three.
  v_new_status := COALESCE(p_status, v_row.status);
  v_new_adyen_status := COALESCE(p_adyen_status, v_row.adyen_status);
  v_new_adyen_inventory_in_store := COALESCE(p_adyen_inventory_in_store, v_row.adyen_inventory_in_store);
  v_new_installation_date := COALESCE(p_installation_date, v_row.installation_date);

  UPDATE public.machines
     SET status = v_new_status,
         adyen_status = v_new_adyen_status,
         adyen_inventory_in_store = v_new_adyen_inventory_in_store,
         installation_date = v_new_installation_date,
         updated_at = now()
   WHERE machine_id = p_machine_id;

  INSERT INTO public.machine_status_events (
    machine_id, old_status, new_status,
    old_adyen_status, new_adyen_status,
    old_adyen_inventory_in_store, new_adyen_inventory_in_store,
    old_installation_date, new_installation_date,
    reason, changed_by, changed_by_role, via_rpc, rpc_name
  ) VALUES (
    p_machine_id, v_row.status, v_new_status,
    v_row.adyen_status, v_new_adyen_status,
    v_row.adyen_inventory_in_store, v_new_adyen_inventory_in_store,
    v_row.installation_date, v_new_installation_date,
    p_reason, v_caller, v_role, true, 'set_machine_status'
  ) RETURNING event_id INTO v_event_id;

  RETURN jsonb_build_object(
    'status', 'ok',
    'machine_id', p_machine_id,
    'event_id', v_event_id,
    'before', jsonb_build_object(
      'status', v_row.status, 'adyen_status', v_row.adyen_status,
      'adyen_inventory_in_store', v_row.adyen_inventory_in_store,
      'installation_date', v_row.installation_date),
    'after', jsonb_build_object(
      'status', v_new_status, 'adyen_status', v_new_adyen_status,
      'adyen_inventory_in_store', v_new_adyen_inventory_in_store,
      'installation_date', v_new_installation_date)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.set_machine_status(uuid, text, text, text, date, text, uuid) TO authenticated;

-- ── 3. Enforcement trigger ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.enforce_machine_status_invariant()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.status = 'Active' AND NEW.repurposed_at IS NULL THEN
    IF NEW.adyen_status IS DISTINCT FROM 'Online today'
       OR NEW.adyen_inventory_in_store IS DISTINCT FROM 'Live' THEN
      RAISE EXCEPTION
        'machines: status=Active with repurposed_at IS NULL requires adyen_status=Online today AND adyen_inventory_in_store=Live (machine_id=%, got adyen_status=%, adyen_inventory_in_store=%)',
        NEW.machine_id, NEW.adyen_status, NEW.adyen_inventory_in_store;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_enforce_machine_status_invariant ON public.machines;
CREATE TRIGGER trg_enforce_machine_status_invariant
  BEFORE UPDATE ON public.machines
  FOR EACH ROW
  WHEN (
    NEW.status IS DISTINCT FROM OLD.status
    OR NEW.adyen_status IS DISTINCT FROM OLD.adyen_status
    OR NEW.adyen_inventory_in_store IS DISTINCT FROM OLD.adyen_inventory_in_store
    OR NEW.repurposed_at IS DISTINCT FROM OLD.repurposed_at
  )
  EXECUTE FUNCTION public.enforce_machine_status_invariant();

-- ── 4. Lock the four columns to the RPC only ───────────────────────────────
-- `authenticated` holds a table-wide UPDATE grant on machines (verified live).
-- A column-level REVOKE alone is a no-op against that -- Postgres treats a
-- whole-table UPDATE grant as sufficient to update ANY column, column-level
-- grants only matter for a role that LACKS the table-wide grant. So: revoke
-- the table-wide grant entirely, then re-grant UPDATE on every column except
-- the four now owned by set_machine_status.
-- INSERT is untouched (add_new_machine / CSV import / add-machine form create
-- new rows and are out of this RPC's "existing row" scope per D2/D4).
REVOKE UPDATE ON public.machines FROM authenticated;
GRANT UPDATE (
  machine_id, pod_number, machine_number, official_name, pod_location, pod_address,
  freezone_location, trade_license_number, permit_issue_date, permit_expiry_date,
  permit_status, contact_person, contact_phone, contact_email, contract_signed,
  adyen_unique_terminal_id, adyen_permanent_terminal_id, adyen_store_code,
  adyen_fridge_assigned, micron_app_id, app_version, micron_version,
  payment_terminal_installed, payment_micron_bo_setup, payment_adyen_store_created,
  payment_app_deployed, payment_kiosk_mode, hw_compressor_ok, hw_calibration_ok,
  hw_door_spring_ok, hw_test_successful, wifi_network_name, wifi_mac_address,
  wifi_device_hostname, serial_number, notes, created_at, updated_at,
  include_in_refill, location_type, latitude, longitude, repurposed_at,
  previous_location, cabinet_count, building_id, source_of_supply, venue_group,
  adyen_store_description, shipment_batch_nbr, payment_connect_store_terminal,
  payment_general_ui_updated, payment_pos_hide_button, payment_app_deployed_terminal,
  payment_fan_test, primary_warehouse_id, secondary_warehouse_id, open_sunday,
  relaunched_at, operating_model, location_category
) ON public.machines TO authenticated;
