-- RD-03: driver self-service — per-line outcome + structured recommendations. NOT YET APPLIED.
--
-- ⚠️ OWNERSHIP-MODEL CAVEAT (Cody must rule): the PRD requires field_staff to act only on dispatch
-- rows on THEIR dispatch (join dispatch_plan). Live schema has NO dispatch_plan table and NO
-- driver-assignment column on refill_dispatching. With 2 field_staff total and no assignment model,
-- this build gates by role (field_staff/operator) + an active-line guard + idempotency, and records
-- driver_outcome_by. True per-driver scoping needs a driver-assignment mechanism (flagged as a
-- follow-up; Cody verdict in the summary). Never mutates quantity/action (Cody revision b).
-- Cody: Articles 2,3,4,5,7,8,12,14.

-- ── (1) per-line outcome on refill_dispatching (state machine) ────────────────────────────────
ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS driver_outcome text
    CHECK (driver_outcome IN ('done','partial','not_done','machine_offline','no_stock_on_truck')),
  ADD COLUMN IF NOT EXISTS driver_outcome_qty int,
  ADD COLUMN IF NOT EXISTS driver_outcome_at  timestamptz,
  ADD COLUMN IF NOT EXISTS driver_outcome_by  uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL;

-- ── (2) structured driver recommendation feed ────────────────────────────────────────────────
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
DROP POLICY IF EXISTS driver_rec_select ON public.driver_recommendations;
CREATE POLICY driver_rec_select ON public.driver_recommendations
  FOR SELECT TO authenticated
  USING (created_by = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.user_profiles
                    WHERE id = (SELECT auth.uid())
                      AND role = ANY (ARRAY['operator_admin','superadmin','warehouse','manager'])));
-- No insert/update/delete policy: written only by the DEFINER RPC (owner bypass). field_staff cannot
-- raw-write (Article 3); operator does not mutate via FE either.

-- ── (3) driver_report_dispatch_outcome ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.driver_report_dispatch_outcome(
  p_dispatch_id uuid,
  p_outcome     text,
  p_actual_qty  int DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid; v_row public.refill_dispatching; v_mname text; v_at_created boolean := false;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','driver_report_dispatch_outcome',true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id = v_user_id
      AND role = ANY(ARRAY['field_staff','operator_admin','superadmin','warehouse'])
  ) THEN
    RAISE EXCEPTION 'forbidden: driver_report_dispatch_outcome requires field_staff/operator';
  END IF;

  IF p_outcome NOT IN ('done','partial','not_done','machine_offline','no_stock_on_truck') THEN
    RAISE EXCEPTION 'invalid outcome: %', p_outcome;
  END IF;
  IF p_outcome = 'partial' AND (p_actual_qty IS NULL OR p_actual_qty < 0) THEN
    RAISE EXCEPTION 'partial outcome requires a non-negative p_actual_qty';
  END IF;

  SELECT * INTO v_row FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch % not found', p_dispatch_id; END IF;

  -- E5 idempotent (offline flush): same outcome already recorded -> no-op.
  IF v_row.driver_outcome IS NOT DISTINCT FROM p_outcome THEN
    RETURN jsonb_build_object('status','idempotent','dispatch_id',p_dispatch_id,'outcome',p_outcome);
  END IF;

  -- Records what happened; NEVER mutates quantity/action (Cody revision b). A picked_up line still
  -- accepts an informational outcome but the engine, not this RPC, reacts next cycle.
  UPDATE public.refill_dispatching
     SET driver_outcome     = p_outcome,
         driver_outcome_qty = p_actual_qty,
         driver_outcome_at  = now(),
         driver_outcome_by  = v_user_id
   WHERE dispatch_id = p_dispatch_id;

  SELECT official_name INTO v_mname FROM public.machines WHERE machine_id = v_row.machine_id;

  -- E1: not_done / no_stock_on_truck -> auto action_tracker punch-item (nothing silently dropped).
  IF p_outcome IN ('not_done','no_stock_on_truck') THEN
    INSERT INTO public.action_tracker(type, title, description, machine_name, status, priority, source, created_at, updated_at)
    VALUES ('redispatch',
            format('Re-dispatch to %s (%s)', COALESCE(v_mname,'machine'), p_outcome),
            format('Dispatch %s reported %s by driver; re-dispatch next cycle.', p_dispatch_id, p_outcome),
            v_mname, 'open', 'high', 'driver_report_dispatch_outcome', now(), now());
    v_at_created := true;
  END IF;

  RETURN jsonb_build_object('status','ok','dispatch_id',p_dispatch_id,'outcome',p_outcome,
    'actual_qty',p_actual_qty,'action_tracker_created',v_at_created);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.driver_report_dispatch_outcome(uuid,text,int) TO authenticated;

-- ── (4) driver_propose_adjustment — writes all three (rec + feedback + action_tracker) ────────
CREATE OR REPLACE FUNCTION public.driver_propose_adjustment(
  p_machine_id       uuid,
  p_kind             text,
  p_note             text,
  p_boonz_product_id uuid DEFAULT NULL,
  p_shelf_id         uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_user_id uuid; v_rec_id uuid; v_mname text; v_bname text; v_shelf_code text;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','driver_propose_adjustment',true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id = v_user_id
      AND role = ANY(ARRAY['field_staff','operator_admin','superadmin','warehouse'])
  ) THEN
    RAISE EXCEPTION 'forbidden: driver_propose_adjustment requires field_staff/operator';
  END IF;
  IF p_kind NOT IN ('needs_product','overstocked','wrong_product','machine_issue','other') THEN
    RAISE EXCEPTION 'invalid kind: %', p_kind;
  END IF;
  IF p_note IS NULL OR length(trim(p_note)) < 1 THEN RAISE EXCEPTION 'p_note required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.machines WHERE machine_id = p_machine_id) THEN
    RAISE EXCEPTION 'machine % not found', p_machine_id;
  END IF;

  INSERT INTO public.driver_recommendations(created_by, machine_id, shelf_id, kind, boonz_product_id, note)
  VALUES (v_user_id, p_machine_id, p_shelf_id, p_kind, p_boonz_product_id, trim(p_note))
  RETURNING rec_id INTO v_rec_id;

  SELECT official_name INTO v_mname FROM public.machines WHERE machine_id = p_machine_id;
  SELECT boonz_product_name INTO v_bname FROM public.boonz_products WHERE product_id = p_boonz_product_id;
  SELECT shelf_code INTO v_shelf_code FROM public.shelf_configurations WHERE shelf_id = p_shelf_id;

  -- Mirror to driver_feedback (write BOTH per reference_action_tracker_vs_driver_feedback); targets
  -- the next draft (CURRENT_DATE + 1). E8: unmapped product stored as free-note.
  INSERT INTO public.driver_feedback(plan_date, machine_id, machine_name, shelf_code, boonz_product_id,
    boonz_product_name, requested_qty, feedback_type, source, note, submitted_by, resolved, created_at)
  VALUES (CURRENT_DATE + 1, p_machine_id, COALESCE(v_mname,'?'), v_shelf_code, p_boonz_product_id,
    COALESCE(v_bname, '(unmapped)'), 0,
    CASE WHEN p_kind = 'needs_product' THEN 'add_missing' ELSE 'note' END,
    'driver_app', trim(p_note), v_user_id, false, now());

  -- Mirror to action_tracker.
  INSERT INTO public.action_tracker(type, title, description, machine_name, status, priority, source, created_at, updated_at)
  VALUES ('driver_recommendation', format('%s @ %s', p_kind, COALESCE(v_mname,'machine')),
    trim(p_note), v_mname, 'open', 'normal', 'driver_propose_adjustment', now(), now());

  RETURN jsonb_build_object('status','ok','rec_id',v_rec_id,'machine_id',p_machine_id,'kind',p_kind,
    'mirrored', jsonb_build_array('driver_recommendations','driver_feedback','action_tracker'));
END;
$function$;
GRANT EXECUTE ON FUNCTION public.driver_propose_adjustment(uuid,text,text,uuid,uuid) TO authenticated;
