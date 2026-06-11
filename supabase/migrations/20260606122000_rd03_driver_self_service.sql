-- RD-03 — Driver self-service (outcome + recommendation). Dara → Cody ⚠️→cleared. APPLY NOTHING (CS review).
--
-- DISCOVERY CORRECTION: the PRD's ownership join `dispatch_plan` does NOT exist, and there is NO per-driver
-- assignment on refill_dispatching/refill_dispatch_plan. The real driver↔machine↔day signal is
-- `trip_events (driver_user_id, machine_id, dispatch_date)` — a driver "arrives" at a machine. So the
-- mandatory ownership check uses trip_events as the assignment proxy: a field_staff driver may report on a
-- dispatch ONLY if they have a trip_events row for that (machine_id, dispatch_date). operator/superadmin/
-- warehouse bypass. ⚠️ If you want stricter per-route ownership, a driver-route-assignment table is a
-- prerequisite (flagged; not built here).
--
-- CODY verdict (RD-03): ⚠️ Approve with revisions → cleared:
--   (a) ownership check mandatory — enforced via trip_events (above). ✅
--   (b) the outcome RPC NEVER mutates quantity/action — only the driver_outcome_* columns. ✅
--   (c) driver_recommendations is NOT Appendix-A protected (proposal feed), normal RLS, writer sets GUCs. ✅
--   Article 3 — field_staff never writes refill_dispatching directly (only via the DEFINER RPC, ownership-
--     scoped). Article 5 — outcome is an RPC state transition; cannot reverse a picked_up/finalized line.
--   Article 7 — recommendations RLS normal (not append-only-locked). Article 8 — both writers set app.via_rpc.
--   Article 4 — role gate + ownership + enum validation + service-role bypass. Article 14 — new table, no _v2.

-- 1) per-line driver outcome on refill_dispatching (Article 5 state machine)
ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS driver_outcome text
    CHECK (driver_outcome IN ('done','partial','not_done','machine_offline','no_stock_on_truck')),
  ADD COLUMN IF NOT EXISTS driver_outcome_qty int,
  ADD COLUMN IF NOT EXISTS driver_outcome_at timestamptz,
  ADD COLUMN IF NOT EXISTS driver_outcome_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL;

-- 2) structured driver recommendation feed
CREATE TABLE IF NOT EXISTS public.driver_recommendations (
  rec_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_by       uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  machine_id       uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  shelf_id         uuid REFERENCES public.shelf_configurations(shelf_id) ON DELETE SET NULL,
  kind             text NOT NULL CHECK (kind IN ('needs_product','overstocked','wrong_product','machine_issue','other')),
  boonz_product_id uuid,
  note             text NOT NULL,
  status           text NOT NULL DEFAULT 'open' CHECK (status IN ('open','actioned','dismissed')),
  source           text NOT NULL DEFAULT 'driver_app'
);
CREATE INDEX IF NOT EXISTS idx_driver_rec_machine_open
  ON public.driver_recommendations (machine_id) WHERE status = 'open';

ALTER TABLE public.driver_recommendations ENABLE ROW LEVEL SECURITY;

-- field_staff: SELECT/INSERT own only; operator/superadmin/warehouse: SELECT all. No field UPDATE/DELETE.
DROP POLICY IF EXISTS driver_rec_select_own ON public.driver_recommendations;
CREATE POLICY driver_rec_select_own ON public.driver_recommendations
  FOR SELECT USING (
    created_by = (SELECT auth.uid())
    OR EXISTS (SELECT 1 FROM public.user_profiles up
               WHERE up.id = (SELECT auth.uid())
                 AND up.role = ANY (ARRAY['operator_admin','superadmin','warehouse','manager']))
  );
DROP POLICY IF EXISTS driver_rec_insert_own ON public.driver_recommendations;
CREATE POLICY driver_rec_insert_own ON public.driver_recommendations
  FOR INSERT WITH CHECK (
    created_by = (SELECT auth.uid())
    OR EXISTS (SELECT 1 FROM public.user_profiles up
               WHERE up.id = (SELECT auth.uid())
                 AND up.role = ANY (ARRAY['operator_admin','superadmin','warehouse','manager']))
  );
-- (no UPDATE / DELETE policies => field_staff cannot mutate; operator state changes go through a future RPC)

-- 3) driver_report_dispatch_outcome — ownership-scoped; never mutates qty/action; auto punch-item on miss.
CREATE OR REPLACE FUNCTION public.driver_report_dispatch_outcome(
  p_dispatch_id uuid,
  p_outcome text,
  p_actual_qty int DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_role text;
  v_rd   record;
  v_machine_name text;
  v_is_field boolean := false;
  v_owns boolean := false;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','driver_report_dispatch_outcome',true);

  IF p_outcome NOT IN ('done','partial','not_done','machine_offline','no_stock_on_truck') THEN
    RAISE EXCEPTION 'driver_report_dispatch_outcome: invalid outcome %', p_outcome;
  END IF;

  SELECT * INTO v_rd FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch % not found', p_dispatch_id; END IF;

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    v_is_field := (v_role = 'field_staff');
    IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'driver_report_dispatch_outcome: role % not permitted', COALESCE(v_role,'none');
    END IF;
    -- E3 ownership: field_staff may only report on a machine they have a trip for that day
    IF v_is_field THEN
      v_owns := EXISTS (SELECT 1 FROM public.trip_events te
                        WHERE te.driver_user_id = v_uid
                          AND te.machine_id = v_rd.machine_id
                          AND te.dispatch_date = v_rd.dispatch_date);
      IF NOT v_owns THEN
        RAISE EXCEPTION 'driver_report_dispatch_outcome: dispatch % is not on your route for % (ownership)', p_dispatch_id, v_rd.dispatch_date;
      END IF;
    END IF;
  END IF;

  -- E4: cannot reverse a finalized/picked-up line (recorded as note only, no state change)
  IF COALESCE(v_rd.picked_up,false) = true THEN
    RAISE EXCEPTION 'dispatch % already picked_up/finalized — cannot record a driver outcome that reverses it', p_dispatch_id;
  END IF;

  -- E5 idempotent: same outcome again is a no-op (no duplicate punch-item)
  IF v_rd.driver_outcome IS NOT DISTINCT FROM p_outcome THEN
    RETURN jsonb_build_object('status','already_recorded','dispatch_id',p_dispatch_id,'outcome',p_outcome);
  END IF;

  -- record outcome ONLY (Cody b: never touch quantity/action)
  UPDATE public.refill_dispatching
     SET driver_outcome = p_outcome,
         driver_outcome_qty = CASE WHEN p_outcome = 'partial' THEN p_actual_qty ELSE NULL END,
         driver_outcome_at = now(),
         driver_outcome_by = v_uid
   WHERE dispatch_id = p_dispatch_id;

  SELECT official_name INTO v_machine_name FROM public.machines WHERE machine_id = v_rd.machine_id;

  -- E1: not_done / no_stock_on_truck -> auto action_tracker punch-item (deduped per dispatch+outcome)
  IF p_outcome IN ('not_done','no_stock_on_truck')
     AND NOT EXISTS (
       SELECT 1 FROM public.action_tracker
       WHERE source = 'driver_app'
         AND title = format('Re-dispatch: %s at %s', p_dispatch_id, v_machine_name)
     ) THEN
    INSERT INTO public.action_tracker (type, title, description, machine_name, status, priority, source)
    VALUES ('task',
            format('Re-dispatch: %s at %s', p_dispatch_id, v_machine_name),
            format('Driver reported %s on dispatch %s (machine %s). Re-dispatch or resolve.', p_outcome, p_dispatch_id, v_machine_name),
            v_machine_name, 'open', 'high', 'driver_app');
  END IF;

  RETURN jsonb_build_object('status','recorded','dispatch_id',p_dispatch_id,'outcome',p_outcome,
    'machine', v_machine_name, 'punch_item', (p_outcome IN ('not_done','no_stock_on_truck')));
END;
$function$;

-- 4) driver_propose_adjustment — writes driver_recommendations + driver_feedback (when product) + action_tracker.
CREATE OR REPLACE FUNCTION public.driver_propose_adjustment(
  p_machine_id uuid,
  p_kind text,
  p_note text,
  p_boonz_product_id uuid DEFAULT NULL,
  p_shelf_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_rec_id uuid;
  v_machine_name text;
  v_boonz_name text;
  v_owns boolean := true;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','driver_propose_adjustment',true);

  IF p_kind NOT IN ('needs_product','overstocked','wrong_product','machine_issue','other') THEN
    RAISE EXCEPTION 'driver_propose_adjustment: invalid kind %', p_kind;
  END IF;
  IF p_note IS NULL OR length(trim(p_note)) < 3 THEN
    RAISE EXCEPTION 'driver_propose_adjustment: note required';
  END IF;

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'driver_propose_adjustment: role % not permitted', COALESCE(v_role,'none');
    END IF;
    -- field_staff scoped to a machine they have a trip for (any recent date)
    IF v_role = 'field_staff' THEN
      v_owns := EXISTS (SELECT 1 FROM public.trip_events te
                        WHERE te.driver_user_id = v_uid AND te.machine_id = p_machine_id
                          AND te.dispatch_date >= CURRENT_DATE - 1);
      IF NOT v_owns THEN
        RAISE EXCEPTION 'driver_propose_adjustment: machine % is not on your recent route (ownership)', p_machine_id;
      END IF;
    END IF;
  END IF;

  SELECT official_name INTO v_machine_name FROM public.machines WHERE machine_id = p_machine_id;
  IF v_machine_name IS NULL THEN RAISE EXCEPTION 'machine % not found', p_machine_id; END IF;

  -- (1) driver_recommendations (created_by must satisfy RLS WITH CHECK)
  INSERT INTO public.driver_recommendations (created_by, machine_id, shelf_id, kind, boonz_product_id, note, status, source)
  VALUES (v_uid, p_machine_id, p_shelf_id, p_kind, p_boonz_product_id, p_note, 'open', 'driver_app')
  RETURNING rec_id INTO v_rec_id;

  -- (2) driver_feedback — only when a product is named (driver_feedback.boonz_product_name is NOT NULL)
  IF p_boonz_product_id IS NOT NULL THEN
    SELECT boonz_product_name INTO v_boonz_name FROM public.boonz_products WHERE product_id = p_boonz_product_id;
    INSERT INTO public.driver_feedback (plan_date, machine_id, machine_name, shelf_code, boonz_product_id,
      boonz_product_name, requested_qty, feedback_type, source, note, submitted_by)
    VALUES (CURRENT_DATE + 1, p_machine_id, v_machine_name,
      (SELECT shelf_code FROM public.shelf_configurations WHERE shelf_id = p_shelf_id),
      p_boonz_product_id, COALESCE(v_boonz_name, 'unmapped'),
      1, CASE WHEN p_kind = 'needs_product' THEN 'add_missing' ELSE 'note' END,
      'driver_app', format('[RD-03 %s] %s', p_kind, p_note), v_uid);
  END IF;

  -- (3) action_tracker punch-item
  INSERT INTO public.action_tracker (type, title, description, machine_name, status, priority, source)
  VALUES ('driver_feedback',
          format('Driver rec (%s): %s', p_kind, v_machine_name),
          format('%s%s', p_note, CASE WHEN v_boonz_name IS NOT NULL THEN ' | product: '||v_boonz_name ELSE '' END),
          v_machine_name, 'open', CASE WHEN p_kind = 'machine_issue' THEN 'high' ELSE 'medium' END, 'driver_app');

  RETURN jsonb_build_object('status','proposed','rec_id',v_rec_id,'machine',v_machine_name,'kind',p_kind,
    'wrote', jsonb_build_object('driver_recommendations', true, 'driver_feedback', (p_boonz_product_id IS NOT NULL), 'action_tracker', true));
END;
$function$;

GRANT EXECUTE ON FUNCTION public.driver_report_dispatch_outcome(uuid,text,int) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.driver_propose_adjustment(uuid,text,text,uuid,uuid) TO authenticated, service_role;
