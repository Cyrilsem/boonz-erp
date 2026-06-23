-- PRD-053 PHASE C — flagged driver additions to Head Office (FILE only).
--
-- A driver may ADD a line beyond plan; the addition is RECORDED and FLAGGED for CS
-- (Head Office) review, never blocked, never silently changing the books.
--
-- Dara — column/flag design (additive, forward-only) on refill_dispatching:
--   needs_review   bool  default false   -- true = awaits Head Office decision
--   review_reason  text                  -- e.g. 'driver_addition'
--   review_status  text  default 'none'  -- none | pending | accepted | rejected
--   reviewed_by    uuid                  -- CS who decided
--   reviewed_at    timestamptz
-- (a partial index for the queue).
--
-- driver_add_flagged_row  — wrapper that COMPOSES the canonical add_dispatch_row
--   (Art 1, never a foreign INSERT) then stamps the review flag on the new row.
--   A defaulted-param overload of add_dispatch_row was rejected (overload foot-gun,
--   CLAUDE.md), so a thin wrapper is used instead. Never blocks.
-- review_driver_addition — CS accept/reject of a flagged addition (records the
--   decision; rejection is surfaced to CS to action via the existing skip/cancel
--   writer — this RPC does not delete or cut qty).
-- v_driver_addition_review_queue — the Head Office queue (pending flagged adds).

-- ── Dara: columns + queue index ─────────────────────────────────────────────
ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS needs_review  boolean      NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS review_reason text,
  ADD COLUMN IF NOT EXISTS review_status text         NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS reviewed_by   uuid,
  ADD COLUMN IF NOT EXISTS reviewed_at   timestamptz;

CREATE INDEX IF NOT EXISTS idx_refill_dispatching_needs_review
  ON public.refill_dispatching (dispatch_date)
  WHERE needs_review AND review_status = 'pending';

-- ── writer: driver addition (composes add_dispatch_row, then flags) ─────────
CREATE OR REPLACE FUNCTION public.driver_add_flagged_row(
  p_machine_id uuid,
  p_shelf_code text,
  p_boonz_product_id uuid,
  p_quantity numeric,
  p_action text,
  p_dispatch_date date,
  p_source_kind text DEFAULT 'unknown',
  p_source_warehouse_id uuid DEFAULT NULL,
  p_source_machine_id uuid DEFAULT NULL,
  p_edit_role text DEFAULT NULL,
  p_reason text DEFAULT NULL,
  p_conductor_session text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_res  jsonb;
  v_id   uuid;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'driver_add_flagged_row', true);

  -- canonical write path (inherits add_dispatch_row's role gate, validation, audit)
  v_res := public.add_dispatch_row(
    p_machine_id, p_shelf_code, p_boonz_product_id, p_quantity, p_action,
    p_dispatch_date, p_source_kind, p_source_warehouse_id, p_source_machine_id,
    p_edit_role, COALESCE(p_reason, 'driver addition beyond plan (PRD-053)'), p_conductor_session);
  v_id := (v_res->>'dispatch_id')::uuid;
  IF v_id IS NULL THEN
    RETURN v_res;  -- add_dispatch_row did not insert; nothing to flag
  END IF;

  -- FLAG for Head Office review (never blocks, never changes the books)
  PERFORM set_config('app.mutation_reason',
    COALESCE(p_reason, 'PRD-053 driver addition flagged for Head Office review'), true);
  UPDATE public.refill_dispatching
     SET needs_review  = true,
         review_reason = 'driver_addition',
         review_status = 'pending'
   WHERE dispatch_id = v_id;

  RETURN v_res || jsonb_build_object('needs_review', true, 'review_reason', 'driver_addition', 'review_status', 'pending');
END;
$function$;

COMMENT ON FUNCTION public.driver_add_flagged_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text) IS
  'PRD-053 Phase C: driver addition beyond plan. Composes the canonical add_dispatch_row, then stamps needs_review=true / review_reason=driver_addition / review_status=pending. Never blocks.';

-- ── writer: Head Office accept / reject ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.review_driver_addition(
  p_dispatch_id uuid,
  p_decision text,            -- 'accepted' | 'rejected'
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_role text;
  v_row  refill_dispatching%ROWTYPE;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'review_driver_addition', true);

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'review_driver_addition: Head Office decision requires operator_admin/superadmin/manager (got %)', COALESCE(v_role,'unknown');
    END IF;
  END IF;
  IF p_decision NOT IN ('accepted','rejected') THEN
    RAISE EXCEPTION 'review_driver_addition: p_decision must be accepted | rejected';
  END IF;

  SELECT * INTO v_row FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'review_driver_addition: dispatch % not found', p_dispatch_id; END IF;
  IF NOT COALESCE(v_row.needs_review,false) THEN
    RAISE EXCEPTION 'review_driver_addition: dispatch % is not flagged for review', p_dispatch_id;
  END IF;

  PERFORM set_config('app.mutation_reason',
    format('PRD-053 Head Office %s of driver addition %s%s', p_decision, p_dispatch_id,
           COALESCE(' — '||p_reason, '')), true);

  UPDATE refill_dispatching
     SET review_status = p_decision,
         needs_review  = false,
         reviewed_by   = v_uid,
         reviewed_at   = now()
   WHERE dispatch_id = p_dispatch_id;

  -- NOTE: rejection records the decision only; it does NOT delete or cut qty
  -- (PRD-053 rule). To pull a rejected addition, CS uses the existing
  -- skip_dispatch_line / cancel writer on this dispatch_id.
  RETURN jsonb_build_object('status','ok','dispatch_id',p_dispatch_id,'review_status',p_decision,'reviewed_by',v_uid);
END;
$function$;

COMMENT ON FUNCTION public.review_driver_addition(uuid,text,text) IS
  'PRD-053 Phase C: Head Office accept/reject of a flagged driver addition. Records the decision (reviewed_by/at); does not delete or cut qty.';

-- ── Head Office review queue ────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.v_driver_addition_review_queue AS
  SELECT rd.dispatch_id, rd.dispatch_date, rd.machine_id, m.official_name AS machine_name,
         sc.shelf_code, rd.pod_product_id, pp.pod_product_name,
         rd.boonz_product_id, bp.boonz_product_name,
         rd.action, rd.quantity, rd.review_reason, rd.review_status,
         rd.last_edited_by, rd.last_edited_at
  FROM public.refill_dispatching rd
  LEFT JOIN public.machines m ON m.machine_id = rd.machine_id
  LEFT JOIN public.shelf_configurations sc ON sc.shelf_id = rd.shelf_id
  LEFT JOIN public.pod_products pp ON pp.pod_product_id = rd.pod_product_id
  LEFT JOIN public.boonz_products bp ON bp.product_id = rd.boonz_product_id
  WHERE rd.needs_review AND rd.review_status = 'pending';

GRANT EXECUTE ON FUNCTION public.driver_add_flagged_row(uuid,text,uuid,numeric,text,date,text,uuid,uuid,text,text,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.review_driver_addition(uuid,text,text) TO authenticated, service_role;
GRANT SELECT ON public.v_driver_addition_review_queue TO authenticated, service_role;
