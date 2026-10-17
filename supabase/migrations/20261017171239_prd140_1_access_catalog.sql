-- PRD-140 Item 1: access catalog + resolver. Phase 1, no behaviour change.
--
-- Defines access once (database) instead of four places that must agree by
-- hand (28 frontend role arrays, the sidebar hiddenByRole map, the
-- middleware FIELD_ROUTE_RULES, and RLS/functions reading user_profiles.role
-- directly). RLS itself is untouched in this PRD; role stays the coarse tier
-- the database trusts.
--
-- Seed values below reproduce EXACTLY the baseline table recorded in
-- docs/prds/PRD-140-log.md (Step 0), derived from middleware
-- FIELD_ROUTE_RULES (the real /field enforcement) and sidebar-nav.tsx's
-- hiddenByRole map (the only real signal for /app sub-area intent, since
-- middleware does not restrict operator_admin/manager/superadmin/finance
-- within /app today). One discovered discrepancy, logged in that session's
-- Step 0: the sidebar hiddenByRole has a warehouse entry implying partial
-- /app access, but middleware fully blocks warehouse from /app. This seed
-- follows the enforced middleware behaviour (warehouse gets zero app.*
-- areas), matching today's real behaviour exactly, since Phase 1 must
-- change nothing and warehouse has live users this morning.
--
-- Designed and Cody-reviewed in the PRD-140 session (2026-10-06); that
-- session's apply_migration call failed with a transient tool error
-- ("Invalid or expired requestState") and the session hit its hard stop
-- before it could retry, so this was never applied. Re-applied verbatim
-- in the PRD-141 session (2026-10-17) via direct execute_sql after
-- apply_migration hit the same transient error twice; this file and the
-- supabase_migrations.schema_migrations row were written by hand to keep
-- parity, since execute_sql does not register migrations itself.

-- ── Tables ──────────────────────────────────────────────────────────────────

CREATE TABLE public.access_areas (
  key text PRIMARY KEY,
  surface text NOT NULL CHECK (surface IN ('app', 'field')),
  label text NOT NULL,
  route_prefix text,
  sidebar_label text,
  sort int NOT NULL DEFAULT 0
);

CREATE TABLE public.role_area_defaults (
  role text NOT NULL,
  area_key text NOT NULL REFERENCES public.access_areas(key) ON DELETE CASCADE,
  PRIMARY KEY (role, area_key)
);

CREATE TABLE public.user_area_overrides (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  area_key text NOT NULL REFERENCES public.access_areas(key) ON DELETE CASCADE,
  effect text CHECK (effect IN ('allow', 'deny')),
  granted_by uuid,
  granted_at timestamptz DEFAULT now(),
  note text,
  PRIMARY KEY (user_id, area_key)
);

CREATE TABLE public.access_audit_log (
  id bigserial PRIMARY KEY,
  at timestamptz DEFAULT now(),
  actor_id uuid,
  target_user_id uuid,
  action text,
  before jsonb,
  after jsonb
);

CREATE TABLE public.access_internal_functions (
  proname text PRIMARY KEY,
  note text
);

-- ── Seed: access_internal_functions (the 14 from PRD-140 Step 0 / PRD-139c) ──

INSERT INTO public.access_internal_functions (proname, note) VALUES
  ('_mirror_po_addition_line_v1', 'internal trigger-only helper'),
  ('_resolve_open_walkin_po_v3', 'internal trigger-only helper'),
  ('audit_log_write', 'internal audit writer'),
  ('close_anon_definer_functions', 'PRD-139c watchdog, cron-only'),
  ('procurement_price_sync_and_flag', 'cron job'),
  ('refresh_fleet_data', 'cron job'),
  ('run_delivery_verification_alerts', 'cron job'),
  ('run_machine_health_integrity_check', 'cron job'),
  ('run_weekly_miners_v3', 'cron job'),
  ('tg_mark_internal_move_pair', 'trigger function'),
  ('trigger_lifecycle_eval', 'trigger function'),
  ('auto_generate_refill_plan', 'invoker, cron job'),
  ('prd114_golden_gate_tick', 'invoker, cron job'),
  ('rename_machine_in_place_legacy', 'invoker, deprecated legacy path');

-- ── Seed: access_areas ───────────────────────────────────────────────────────
-- app.* sidebar_label matches the NavItem label in sidebar-nav.tsx byte for
-- byte (confirmed by reading the file, not assumed). app.settings.users has
-- no sidebar entry (sidebar still shows just "Settings").

INSERT INTO public.access_areas (key, surface, label, route_prefix, sidebar_label, sort) VALUES
  ('app.dashboard', 'app', 'Dashboard', '/app', 'Dashboard', 0),
  ('app.refill', 'app', 'Refill & Dispatch', '/refill', 'Refill & Dispatch', 10),
  ('app.driver_requests', 'app', 'Driver Requests', '/admin/driver-requests', 'Driver Requests', 11),
  ('app.pods', 'app', 'Pods', '/app/pods', 'Pods', 12),
  ('app.inventory', 'app', 'Inventory', '/app/inventory', 'Inventory', 13),
  ('app.products', 'app', 'Products', '/app/products', 'Products', 20),
  ('app.suppliers', 'app', 'Suppliers', '/app/suppliers', 'Suppliers', 21),
  ('app.procurement', 'app', 'Procurement', '/app/procurement', 'Procurement', 22),
  ('app.price_review', 'app', 'Price Review', '/app/procurement/price-review', 'Price Review', 23),
  ('app.lifecycle', 'app', 'Lifecycle', '/app/lifecycle', 'Lifecycle', 24),
  ('app.performance', 'app', 'Performance', '/app/performance', 'Performance', 30),
  ('app.financials', 'app', 'Financials', '/app/financials', 'Financials', 31),
  ('app.consumers', 'app', 'Consumers', '/refill/consumers', 'Consumers', 32),
  ('app.sales_pipeline', 'app', 'Sales Pipeline', '/app/sales-pipeline', 'Sales Pipeline', 33),
  ('app.sims', 'app', 'SIM Cards', '/app/sims', 'SIM Cards', 40),
  ('app.inventory_sessions', 'app', 'Inventory Sessions', '/admin/inventory-sessions', 'Inventory Sessions', 41),
  ('app.wh_quarantine', 'app', 'WH Quarantine', '/admin/wh-quarantine', 'WH Quarantine', 42),
  ('app.expiry_waste', 'app', 'Expiry & Waste', '/admin/expiry-waste', 'Expiry & Waste', 43),
  ('app.drift', 'app', 'Drift Monitor', '/refill/drift', 'Drift Monitor', 44),
  ('app.tracker', 'app', 'Tracker', '/app/tracker', 'Tracker', 45),
  ('app.settings', 'app', 'Settings', '/app/settings', 'Settings', 50),
  ('app.settings.users', 'app', 'Settings Users', '/app/settings/users', NULL, 51),
  ('field.home', 'field', 'Home', '/field', NULL, 0),
  ('field.profile', 'field', 'Profile', '/field/profile', NULL, 1),
  ('field.tasks', 'field', 'Tasks', '/field/tasks', NULL, 2),
  ('field.pod_inventory', 'field', 'Machine Stock Expiry', '/field/pod-inventory', NULL, 3),
  ('field.pickup', 'field', 'Pickup', '/field/pickup', NULL, 4),
  ('field.dispatching', 'field', 'Dispatching', '/field/dispatching', NULL, 5),
  ('field.dispatching.pick', 'field', 'Dispatching Pick', '/field/dispatching/pick', NULL, 6),
  ('field.trips', 'field', 'Trips', '/field/trips', NULL, 7),
  ('field.packing', 'field', 'Packing', '/field/packing', NULL, 8),
  ('field.shelf_view', 'field', 'Shelf View', '/field/shelf-view', NULL, 9),
  ('field.not_filled', 'field', 'Not Filled', '/field/not-filled', NULL, 10),
  ('field.capture', 'field', 'Capture', '/field/capture', NULL, 11),
  ('field.orders', 'field', 'Orders', '/field/orders', NULL, 12),
  ('field.receiving', 'field', 'Receiving', '/field/receiving', NULL, 13),
  ('field.inventory', 'field', 'Inventory', '/field/inventory', NULL, 14),
  ('field.expiry', 'field', 'Expiry', '/field/expiry', NULL, 15),
  ('field.config', 'field', 'Config', '/field/config', NULL, 16),
  ('field.config.sims', 'field', 'Config Sims', '/field/config/sims', NULL, 17),
  ('field.config.suppliers', 'field', 'Config Suppliers', '/field/config/suppliers', NULL, 18),
  ('field.config.product_naming', 'field', 'Config Product Naming', '/field/config/product-naming', NULL, 19),
  ('field.config.machines', 'field', 'Config Machines', '/field/config/machines', NULL, 20),
  ('field.config.boonz_products', 'field', 'Config Boonz Products', '/field/config/boonz-products', NULL, 21),
  ('field.config.pod_products', 'field', 'Config Pod Products', '/field/config/pod-products', NULL, 22),
  ('field.config.product_mapping', 'field', 'Config Product Mapping', '/field/config/product-mapping', NULL, 23);

-- ── Seed: role_area_defaults ─────────────────────────────────────────────────
-- Reproduces the Step 0 baseline table exactly. app.tracker is never a
-- default (granted at resolve time via tracker_boonz_access / owner email).

-- superadmin, operator_admin: every area except app.tracker (flag-driven).
INSERT INTO public.role_area_defaults (role, area_key)
SELECT r.role, aa.key
FROM (VALUES ('superadmin'), ('operator_admin')) AS r(role)
CROSS JOIN public.access_areas aa
WHERE aa.key <> 'app.tracker';

-- manager: same as superadmin/operator_admin except app.settings,
-- app.lifecycle, and app.settings.users (hidden in sidebar-nav.tsx's
-- hiddenByRole.manager; no live manager user today, so this also closes an
-- existing inconsistency where manager could reach /app/settings by direct
-- URL despite the UI hiding it).
INSERT INTO public.role_area_defaults (role, area_key)
SELECT 'manager', aa.key
FROM public.access_areas aa
WHERE aa.key NOT IN ('app.tracker', 'app.settings', 'app.lifecycle', 'app.settings.users');

-- warehouse: zero app.* areas (middleware fully blocks /app for warehouse
-- today); field.* = FIELD_WAREHOUSE_ROLES set (everything except
-- field.config.product_naming, which is admins-only).
INSERT INTO public.role_area_defaults (role, area_key)
SELECT 'warehouse', aa.key
FROM public.access_areas aa
WHERE aa.surface = 'field' AND aa.key <> 'field.config.product_naming';

-- field_staff: zero app.* areas; field.* = FIELD_ALL_ROLES set only.
INSERT INTO public.role_area_defaults (role, area_key)
VALUES
  ('field_staff', 'field.home'),
  ('field_staff', 'field.profile'),
  ('field_staff', 'field.tasks'),
  ('field_staff', 'field.pod_inventory'),
  ('field_staff', 'field.pickup'),
  ('field_staff', 'field.dispatching'),
  ('field_staff', 'field.trips');

-- finance: app.* per sidebar hiddenByRole.finance (inverse of the hidden
-- list); zero field.* (middleware has no /field path for finance).
INSERT INTO public.role_area_defaults (role, area_key)
VALUES
  ('finance', 'app.dashboard'),
  ('finance', 'app.inventory'),
  ('finance', 'app.products'),
  ('finance', 'app.suppliers'),
  ('finance', 'app.procurement'),
  ('finance', 'app.performance'),
  ('finance', 'app.financials'),
  ('finance', 'app.sims'),
  ('finance', 'app.settings');

-- ── RLS ──────────────────────────────────────────────────────────────────────

ALTER TABLE public.access_areas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_area_defaults ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_area_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.access_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.access_internal_functions ENABLE ROW LEVEL SECURITY;

CREATE POLICY access_areas_select ON public.access_areas
  FOR SELECT TO authenticated USING (true);

CREATE POLICY role_area_defaults_select ON public.role_area_defaults
  FOR SELECT TO authenticated USING (true);

-- ── Functions ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.resolve_user_access(p_user_id uuid)
RETURNS TABLE(area_key text, surface text, route_prefix text, sidebar_label text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_role text;
  v_tracker_flag boolean;
  v_email text;
BEGIN
  IF v_caller IS DISTINCT FROM p_user_id AND current_user <> 'service_role' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.resolve_user_access(v_caller) r
      WHERE r.area_key = 'app.settings.users'
    ) THEN
      RAISE EXCEPTION 'not authorized to resolve access for another user';
    END IF;
  END IF;

  SELECT up.role, up.tracker_boonz_access
    INTO v_role, v_tracker_flag
  FROM public.user_profiles up
  WHERE up.id = p_user_id;

  IF v_role IS NULL THEN
    RETURN;
  END IF;

  SELECT u.email INTO v_email FROM auth.users u WHERE u.id = p_user_id;

  RETURN QUERY
  WITH base AS (
    SELECT rad.area_key FROM public.role_area_defaults rad WHERE rad.role = v_role
    UNION
    SELECT uao.area_key FROM public.user_area_overrides uao
      WHERE uao.user_id = p_user_id AND uao.effect = 'allow'
    UNION
    SELECT 'app.tracker'::text
      WHERE v_tracker_flag OR lower(coalesce(v_email, '')) = 'cyrilsem@gmail.com'
  ),
  denied AS (
    SELECT uao.area_key FROM public.user_area_overrides uao
      WHERE uao.user_id = p_user_id AND uao.effect = 'deny'
  )
  SELECT aa.key, aa.surface, aa.route_prefix, aa.sidebar_label
  FROM base b
  JOIN public.access_areas aa ON aa.key = b.area_key
  WHERE b.area_key NOT IN (SELECT d.area_key FROM denied d);
END;
$function$;

REVOKE ALL ON FUNCTION public.resolve_user_access(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_user_access(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.has_area(p_user_id uuid, p_key text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.resolve_user_access(p_user_id) r WHERE r.area_key = p_key
  );
$function$;

REVOKE ALL ON FUNCTION public.has_area(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_area(uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.set_user_area_override(p_user_id uuid, p_key text, p_effect text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_before jsonb;
BEGIN
  IF current_user <> 'service_role' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.resolve_user_access(v_caller) r WHERE r.area_key = 'app.settings.users'
    ) THEN
      RAISE EXCEPTION 'not authorized to set access overrides';
    END IF;
  END IF;

  IF p_effect NOT IN ('allow', 'deny') THEN
    RAISE EXCEPTION 'invalid effect: %', p_effect;
  END IF;

  SELECT jsonb_build_object('effect', effect) INTO v_before
  FROM public.user_area_overrides WHERE user_id = p_user_id AND area_key = p_key;

  INSERT INTO public.user_area_overrides (user_id, area_key, effect, granted_by)
  VALUES (p_user_id, p_key, p_effect, v_caller)
  ON CONFLICT (user_id, area_key) DO UPDATE
    SET effect = p_effect, granted_by = v_caller, granted_at = now();

  INSERT INTO public.access_audit_log (actor_id, target_user_id, action, before, after)
  VALUES (v_caller, p_user_id, 'set_override', v_before,
    jsonb_build_object('area_key', p_key, 'effect', p_effect));
END;
$function$;

REVOKE ALL ON FUNCTION public.set_user_area_override(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_user_area_override(uuid, text, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.clear_user_area_override(p_user_id uuid, p_key text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_before jsonb;
BEGIN
  IF current_user <> 'service_role' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.resolve_user_access(v_caller) r WHERE r.area_key = 'app.settings.users'
    ) THEN
      RAISE EXCEPTION 'not authorized to clear access overrides';
    END IF;
  END IF;

  SELECT jsonb_build_object('effect', effect) INTO v_before
  FROM public.user_area_overrides WHERE user_id = p_user_id AND area_key = p_key;

  DELETE FROM public.user_area_overrides WHERE user_id = p_user_id AND area_key = p_key;

  INSERT INTO public.access_audit_log (actor_id, target_user_id, action, before, after)
  VALUES (v_caller, p_user_id, 'clear_override', v_before, NULL);
END;
$function$;

REVOKE ALL ON FUNCTION public.clear_user_area_override(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.clear_user_area_override(uuid, text) TO authenticated, service_role;

-- ── View ─────────────────────────────────────────────────────────────────────

CREATE VIEW public.v_my_access AS
SELECT * FROM public.resolve_user_access(auth.uid());

GRANT SELECT ON public.v_my_access TO authenticated;
REVOKE ALL ON public.v_my_access FROM PUBLIC, anon;

-- ── Remaining RLS policies (reference has_area, now that it exists) ──────────

CREATE POLICY user_area_overrides_select ON public.user_area_overrides
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.has_area(auth.uid(), 'app.settings.users'));

CREATE POLICY access_audit_log_select ON public.access_audit_log
  FOR SELECT TO authenticated
  USING (public.has_area(auth.uid(), 'app.settings.users'));

CREATE POLICY access_internal_functions_select ON public.access_internal_functions
  FOR SELECT TO authenticated
  USING (public.has_area(auth.uid(), 'app.settings.users'));
