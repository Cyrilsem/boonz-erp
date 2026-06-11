-- Refill System v2 / Phase 2 (#10, stage 1: tables + capture) - learning-loop signal capture.
--
-- Captures (a) what the engine recommended per plan_date (immutable snapshot) and (b) each operator
-- edit vs that snapshot as a typed signal. Stage 1 of #10: this round CAPTURES signals; the engine
-- CONSUMING them (deterministic feedback, threshold = 3-in-30d per CS) is a follow-up migration.
-- Tables by Dara. Capture is by trigger (Dara D6), not by modifying core writers.
-- APPLIED 2026-06-01 (CS sign-off; Cody-approved Articles 2,4,7,8,12,14; verified tables+RLS+trigger+10 seed rows).

-- ── Tables (Dara) ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.engine_recommendation_snapshot (
  snapshot_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_date      date NOT NULL,
  machine_id     uuid REFERENCES public.machines(machine_id)            ON DELETE SET NULL,
  shelf_id       uuid REFERENCES public.shelf_configurations(shelf_id)  ON DELETE SET NULL,
  pod_product_id uuid REFERENCES public.pod_products(pod_product_id)    ON DELETE SET NULL,
  action         text NOT NULL CHECK (action IN ('REFILL','ADD_NEW','REMOVE','M2W')),
  qty            int  NOT NULL,
  signal         text,
  reasoning      jsonb NOT NULL DEFAULT '{}'::jsonb,
  snapshot_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT engine_rec_snapshot_uniq UNIQUE (plan_date, machine_id, shelf_id, pod_product_id, action)
);

CREATE TABLE IF NOT EXISTS public.refill_edit_signals (
  signal_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_date      date NOT NULL,
  machine_id     uuid REFERENCES public.machines(machine_id)            ON DELETE SET NULL,
  shelf_id       uuid REFERENCES public.shelf_configurations(shelf_id)  ON DELETE SET NULL,
  pod_product_id uuid REFERENCES public.pod_products(pod_product_id)    ON DELETE SET NULL,
  action         text,
  signal_type    text NOT NULL CHECK (signal_type IN ('qty_raised','qty_lowered','item_added','item_removed','swap_rejected')),
  delta          int,
  source         text NOT NULL,
  note           text,
  created_by     uuid REFERENCES public.user_profiles(id)              ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT refill_edit_signals_delta_chk
    CHECK (signal_type NOT IN ('qty_raised','qty_lowered') OR delta IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_refill_edit_signals_plan_date
  ON public.refill_edit_signals (plan_date, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_refill_edit_signals_machine_pod
  ON public.refill_edit_signals (machine_id, pod_product_id, created_at DESC);

ALTER TABLE public.engine_recommendation_snapshot ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.refill_edit_signals            ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS engine_rec_snapshot_select ON public.engine_recommendation_snapshot;
CREATE POLICY engine_rec_snapshot_select ON public.engine_recommendation_snapshot
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles WHERE id = (SELECT auth.uid())
                   AND role = ANY (ARRAY['operator_admin','superadmin','manager'])));
DROP POLICY IF EXISTS engine_rec_snapshot_no_update ON public.engine_recommendation_snapshot;
CREATE POLICY engine_rec_snapshot_no_update ON public.engine_recommendation_snapshot FOR UPDATE USING (false);
DROP POLICY IF EXISTS engine_rec_snapshot_no_delete ON public.engine_recommendation_snapshot;
CREATE POLICY engine_rec_snapshot_no_delete ON public.engine_recommendation_snapshot FOR DELETE USING (false);

DROP POLICY IF EXISTS refill_edit_signals_select ON public.refill_edit_signals;
CREATE POLICY refill_edit_signals_select ON public.refill_edit_signals
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles WHERE id = (SELECT auth.uid())
                   AND role = ANY (ARRAY['operator_admin','superadmin','manager'])));
DROP POLICY IF EXISTS refill_edit_signals_no_update ON public.refill_edit_signals;
CREATE POLICY refill_edit_signals_no_update ON public.refill_edit_signals FOR UPDATE USING (false);
DROP POLICY IF EXISTS refill_edit_signals_no_delete ON public.refill_edit_signals;
CREATE POLICY refill_edit_signals_no_delete ON public.refill_edit_signals FOR DELETE USING (false);
-- No INSERT policy on either: DEFINER (owner) is the sole writer. Append-only (Article 7).

-- ── snapshot_engine_recommendations: freeze the engine's draft per plan_date (write-once) ──
CREATE OR REPLACE FUNCTION public.snapshot_engine_recommendations(
  p_plan_date   date,
  p_machine_ids uuid[] DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_user_id uuid; v_n integer;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','snapshot_engine_recommendations',true);
  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up WHERE up.id=v_user_id
      AND up.role = ANY(ARRAY['operator_admin','superadmin'])
  ) THEN RAISE EXCEPTION 'snapshot_engine_recommendations: caller % lacks operator_admin/superadmin', v_user_id; END IF;
  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'p_plan_date required'; END IF;

  INSERT INTO public.engine_recommendation_snapshot(plan_date, machine_id, shelf_id, pod_product_id, action, qty, signal, reasoning)
  SELECT prp.plan_date, prp.machine_id, prp.shelf_id, prp.pod_product_id, prp.action, prp.qty,
         prp.reasoning->>'signal', COALESCE(prp.reasoning,'{}'::jsonb)
    FROM public.pod_refill_plan prp
   WHERE prp.plan_date = p_plan_date
     AND prp.status IN ('draft','approved','stitched')
     AND (p_machine_ids IS NULL OR prp.machine_id = ANY(p_machine_ids))
  ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id, action) DO NOTHING;  -- immutable: first snapshot wins
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('status','ok','plan_date',p_plan_date,'snapshotted',v_n);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.snapshot_engine_recommendations(date, uuid[]) TO authenticated;

-- ── Capture trigger: emit a signal when a MANUAL-edit RPC diverges from the snapshot ──
CREATE OR REPLACE FUNCTION public.tg_capture_refill_edit_signal()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_rpc      text := current_setting('app.rpc_name', true);
  v_snap_qty int;
  v_type     text;
  v_delta    int;
BEGIN
  -- Only manual operator edits. Engine/orchestrator writes (engine_finalize_pod, reset_and_restitch,
  -- stitch_*) carry their own rpc_name and are skipped, so we never log the engine editing itself.
  IF v_rpc IS NULL OR v_rpc NOT IN ('edit_pod_refill_row','add_pod_refill_row') THEN
    RETURN NEW;
  END IF;

  SELECT s.qty INTO v_snap_qty
    FROM public.engine_recommendation_snapshot s
   WHERE s.plan_date=NEW.plan_date AND s.machine_id=NEW.machine_id AND s.shelf_id=NEW.shelf_id
     AND s.pod_product_id=NEW.pod_product_id AND s.action=NEW.action;

  IF TG_OP = 'INSERT' THEN
    IF v_snap_qty IS NULL THEN
      v_type := 'item_added'; v_delta := NEW.qty;   -- not in the engine recommendation => operator add
    ELSE
      RETURN NEW;
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.qty = 0 AND COALESCE(OLD.qty,0) > 0 THEN
      v_type := 'item_removed'; v_delta := -COALESCE(OLD.qty,0);
    ELSIF v_snap_qty IS NOT NULL AND NEW.qty > v_snap_qty THEN
      v_type := 'qty_raised';  v_delta := NEW.qty - v_snap_qty;   -- delta vs the ENGINE recommendation
    ELSIF v_snap_qty IS NOT NULL AND NEW.qty < v_snap_qty THEN
      v_type := 'qty_lowered'; v_delta := NEW.qty - v_snap_qty;
    ELSE
      RETURN NEW;
    END IF;
  ELSE
    RETURN NEW;
  END IF;

  INSERT INTO public.refill_edit_signals(plan_date, machine_id, shelf_id, pod_product_id, action,
    signal_type, delta, source, created_by)
  VALUES (NEW.plan_date, NEW.machine_id, NEW.shelf_id, NEW.pod_product_id, NEW.action,
    v_type, v_delta, v_rpc, auth.uid());

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS tg_capture_refill_edit_signal ON public.pod_refill_plan;
CREATE TRIGGER tg_capture_refill_edit_signal
  AFTER INSERT OR UPDATE ON public.pod_refill_plan
  FOR EACH ROW EXECUTE FUNCTION public.tg_capture_refill_edit_signal();

-- ── Seed from the 2026-06-01 driver_feedback rows (one-time, best-effort key resolution) ──
INSERT INTO public.refill_edit_signals(plan_date, machine_id, shelf_id, pod_product_id, action,
  signal_type, delta, source, note, created_by, created_at)
SELECT df.plan_date,
       df.machine_id,
       sc.shelf_id,
       (SELECT pm.pod_product_id FROM public.product_mapping pm
         WHERE pm.boonz_product_id = df.boonz_product_id AND pm.status='Active' LIMIT 1),
       NULL,
       CASE WHEN df.feedback_type = 'add_missing' THEN 'item_added' ELSE 'swap_rejected' END,
       CASE WHEN df.feedback_type = 'add_missing' THEN df.requested_qty ELSE NULL END,
       'driver_feedback_seed',
       df.note,
       df.submitted_by,
       df.created_at
FROM public.driver_feedback df
LEFT JOIN public.machines m       ON m.machine_id = df.machine_id
LEFT JOIN public.shelf_configurations sc
       ON sc.machine_id = df.machine_id AND sc.shelf_code = df.shelf_code
WHERE df.plan_date = '2026-06-01';
