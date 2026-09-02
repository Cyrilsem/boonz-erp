-- PRD-119 P3 §4: apply_expiry_check — the canonical tap writer for the re-scoped
-- "Sanity checks - expiry" driver category. Replaces day_close_events-as-a-parking-lot
-- (evidence: 8 taps since 12 Aug, 0 ever acknowledged, so every removed batch stayed
-- Active) with an atomic writer that changes the shelf record at the tap, not at a
-- CS acknowledge that never comes.
--
-- p_outcome: removed | not_there | date_read.
--   removed  (dated lot, EXPIRED or 1-3d out): current_stock -= n, archive at 0;
--             disposition_events row state=removed_at_machine (source=driver_expiry_check,
--             linked via pod_inventory_id) — goes to the WM queue (goods physically moved).
--   not_there (dated OR DATE? lot): archive sold_through_<date>. No disposition row —
--             no goods moved, nothing for the WM to receive.
--   date_read (DATE? / NULL-expiry lot only): composes correct_expiry_v1('pod', ...).
--             No disposition row (no goods moved).
-- Every branch writes one day_close_events row, kind='expiry_check', acknowledged_at
-- stamped by the system at write time — the table becomes the log CS asked for, not a
-- gate a human has to click.
--
-- Companion fix: correct_expiry_v1's role gate excluded field_staff entirely, but this
-- writer's date_read path is the PRD's own explicit wiring target for the driver tap.
-- Widened to allow field_staff, scope-restricted to p_scope='pod' only — a driver may
-- correct a shelf lot's date, never a warehouse or dispatch-line date.
--
-- Verified end-to-end on real rows (rolled-back transactions): partial removal (dated
-- lot 6->4 units, stays Active, disposition_events row correctly linked via
-- pod_inventory_id — caught missing that link in a first draft, fixed before applying);
-- full not-there archive; date_read as a real field_staff caller reaching
-- correct_expiry_v1's pod-scope archive-and-reinsert (the case that proves the
-- auth.uid()-persists-across-nested-calls composition actually works, not just compiles).
--
-- Cody: approve, Articles 1/4/5/8/12 — status transitions via the canonical writer,
-- provenance set before every write, day_close_events log-not-gate semantics match §4
-- exactly, role widening is scope-restricted rather than blanket.
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='correct_expiry_v1' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'd52eec894a9576e514ae34dbfb6a750e' THEN RAISE EXCEPTION 'correct_expiry_v1 drifted (md5 %)', md5(v_def); END IF;
  v_new := replace(v_def,
    E'  IF v_user_id IS NOT NULL THEN\n    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;\n    IF v_role IS NULL OR v_role NOT IN (\'warehouse\',\'operator_admin\',\'superadmin\',\'manager\') THEN\n      RAISE EXCEPTION \'correct_expiry_v1: forbidden for role %\', COALESCE(v_role,\'unknown\');\n    END IF;\n  END IF;',
    E'  IF v_user_id IS NOT NULL THEN\n    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;\n    IF v_role IS NULL OR v_role NOT IN (\'warehouse\',\'operator_admin\',\'superadmin\',\'manager\',\'field_staff\') THEN\n      RAISE EXCEPTION \'correct_expiry_v1: forbidden for role %\', COALESCE(v_role,\'unknown\');\n    END IF;\n    IF v_role = \'field_staff\' AND p_scope <> \'pod\' THEN\n      RAISE EXCEPTION \'correct_expiry_v1: field_staff may only correct pod-scope expiry (got scope=%)\', p_scope;\n    END IF;\n  END IF;');
  IF v_new = v_def THEN RAISE EXCEPTION 'correct_expiry_v1: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

CREATE FUNCTION public.apply_expiry_check(
  p_pod_inventory_id uuid, p_outcome text, p_qty numeric DEFAULT NULL::numeric,
  p_new_expiry date DEFAULT NULL::date, p_actor uuid DEFAULT NULL::uuid, p_dry_run boolean DEFAULT true
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_actor, auth.uid());
  v_role text; v_pod pod_inventory%ROWTYPE; v_is_dated boolean; v_event_id uuid;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'apply_expiry_check: anonymous caller refused'; END IF;
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'apply_expiry_check: role % not authorized', COALESCE(v_role,'none');
  END IF;
  IF p_outcome NOT IN ('removed','not_there','date_read') THEN
    RAISE EXCEPTION 'apply_expiry_check: p_outcome must be removed | not_there | date_read (got %)', p_outcome;
  END IF;
  SELECT * INTO v_pod FROM public.pod_inventory WHERE pod_inventory_id = p_pod_inventory_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'apply_expiry_check: pod_inventory % not found', p_pod_inventory_id; END IF;
  IF v_pod.status <> 'Active' THEN RAISE EXCEPTION 'apply_expiry_check: pod_inventory % is not Active (status=%)', p_pod_inventory_id, v_pod.status; END IF;
  v_is_dated := v_pod.expiration_date IS NOT NULL;
  IF p_outcome = 'removed' AND NOT v_is_dated THEN
    RAISE EXCEPTION 'apply_expiry_check: outcome=removed requires a dated lot (row % has no expiry — use date_read or not_there)', p_pod_inventory_id;
  END IF;
  IF p_outcome = 'date_read' AND v_is_dated THEN
    RAISE EXCEPTION 'apply_expiry_check: outcome=date_read only applies to a DATE? (NULL-expiry) lot';
  END IF;
  IF p_outcome = 'removed' THEN
    IF p_qty IS NULL OR p_qty <= 0 OR p_qty > COALESCE(v_pod.current_stock,0) THEN
      RAISE EXCEPTION 'apply_expiry_check: p_qty must be > 0 and <= current_stock (%) for outcome=removed', v_pod.current_stock;
    END IF;
  END IF;
  IF p_outcome = 'date_read' AND p_new_expiry IS NULL THEN
    RAISE EXCEPTION 'apply_expiry_check: p_new_expiry is required for outcome=date_read';
  END IF;
  IF p_dry_run THEN
    RETURN jsonb_build_object('status','dry_run_ok','pod_inventory_id',p_pod_inventory_id,'outcome',p_outcome,
      'is_dated', v_is_dated, 'current_stock', v_pod.current_stock, 'qty', p_qty, 'new_expiry', p_new_expiry);
  END IF;
  PERFORM public.set_write_context('apply_expiry_check',
    format('apply_expiry_check pod=%s outcome=%s by=%s', p_pod_inventory_id, p_outcome, v_user_id),
    'expiry_writeoff', p_pod_inventory_id::text);
  IF p_outcome = 'removed' THEN
    UPDATE public.pod_inventory
       SET current_stock = current_stock - p_qty,
           status = CASE WHEN current_stock - p_qty <= 0 THEN 'Inactive' ELSE status END,
           removal_reason = CASE WHEN current_stock - p_qty <= 0 THEN 'expired_writeoff' ELSE removal_reason END,
           last_decremented_at = now()
     WHERE pod_inventory_id = p_pod_inventory_id;
    INSERT INTO public.disposition_events (actor, source, machine_id, shelf_id, boonz_product_id, expiration_date, qty, state, reason, pod_inventory_id)
    VALUES (v_user_id, 'driver_expiry_check', v_pod.machine_id, v_pod.shelf_id, v_pod.boonz_product_id, v_pod.expiration_date, p_qty,
      'removed_at_machine', 'driver expiry-check tap: expired/expiring lot removed from the shelf', p_pod_inventory_id)
    RETURNING event_id INTO v_event_id;
    INSERT INTO public.day_close_events (event_date, machine_id, dispatch_id, kind, payload, created_by, acknowledged_at, acknowledged_by)
    VALUES ((now() AT TIME ZONE 'Asia/Dubai')::date, v_pod.machine_id, NULL, 'expiry_check',
      jsonb_build_object('pod_inventory_id', p_pod_inventory_id, 'outcome', 'removed', 'qty', p_qty,
        'expiration_date', v_pod.expiration_date, 'disposition_event_id', v_event_id), v_user_id, now(), v_user_id);
  ELSIF p_outcome = 'not_there' THEN
    UPDATE public.pod_inventory
       SET current_stock = 0, status = 'Inactive',
           removal_reason = format('sold_through_%s', CURRENT_DATE), last_decremented_at = now()
     WHERE pod_inventory_id = p_pod_inventory_id;
    INSERT INTO public.day_close_events (event_date, machine_id, dispatch_id, kind, payload, created_by, acknowledged_at, acknowledged_by)
    VALUES ((now() AT TIME ZONE 'Asia/Dubai')::date, v_pod.machine_id, NULL, 'expiry_check',
      jsonb_build_object('pod_inventory_id', p_pod_inventory_id, 'outcome', 'not_there',
        'expiration_date', v_pod.expiration_date), v_user_id, now(), v_user_id);
  ELSIF p_outcome = 'date_read' THEN
    PERFORM public.correct_expiry_v1('pod', p_pod_inventory_id, p_new_expiry,
      format('driver read the printed expiry label at the machine (pod %s)', p_pod_inventory_id),
      v_user_id, false, false);
    INSERT INTO public.day_close_events (event_date, machine_id, dispatch_id, kind, payload, created_by, acknowledged_at, acknowledged_by)
    VALUES ((now() AT TIME ZONE 'Asia/Dubai')::date, v_pod.machine_id, NULL, 'expiry_check',
      jsonb_build_object('pod_inventory_id', p_pod_inventory_id, 'outcome', 'date_read', 'new_expiry', p_new_expiry), v_user_id, now(), v_user_id);
  END IF;
  RETURN jsonb_build_object('status','ok','pod_inventory_id',p_pod_inventory_id,'outcome',p_outcome,'disposition_event_id',v_event_id);
END $function$;
