-- PRD-072 P2: retire the legacy confirm_machine_packed(4-arg) overload and give the
-- canonical 5-arg (PRD-044 two-mode) argument DEFAULTS.
--
-- ROOT CAUSE FOUND 2026-07-04: the PRD-044 migration created the 5-arg WITHOUT defaults
-- and kept the 4-arg delegate. The FE calls with named args
--   {p_machine_name, p_dispatch_date, p_reason, p_final}   (no p_packed_by)
-- which PostgREST can match to NEITHER overload (4-arg lacks p_final; 5-arg's missing
-- p_packed_by has no default). Every driver confirm since 2026-06-21 has failed
-- ("Confirm failed: ..."): dispatch_pack_confirmation has 3 rows on 06-21 (ship-day
-- testing), 1 on 06-26, zero since. This is the driver-visible "qty edits not saving"
-- bug: pack_dispatch_line succeeds per line, then the confirm 404s.
--
-- Fix (same class as PRD-071's push v7 42725 fix): drop the 4-arg delegate, then
-- re-create the 5-arg with defaults so the FE's 4-key named call resolves uniquely.
-- Body is byte-identical to the live PRD-044 two-mode body; only the argument
-- DEFAULT clauses are new. p_final defaults TRUE = legacy finish semantics for any
-- residual 4-key caller that omitted it.
DROP FUNCTION IF EXISTS public.confirm_machine_packed(text, date, uuid, text);

CREATE OR REPLACE FUNCTION public.confirm_machine_packed(p_machine_name text, p_dispatch_date date DEFAULT NULL::date, p_packed_by uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_final boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_role text; v_machine_id uuid;
  v_date date := COALESCE(p_dispatch_date, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date);
  v_unresolved jsonb; v_unresolved_n integer; v_resolved_n integer; v_summary jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','confirm_machine_packed',true);
  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'confirm_machine_packed: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'confirm_machine_packed: p_reason required (>= 10 chars)';
  END IF;
  PERFORM set_config('app.mutation_reason', p_reason, true);
  SELECT machine_id INTO v_machine_id FROM public.machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN RAISE EXCEPTION 'confirm_machine_packed: machine % not found', p_machine_name; END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('dispatch_id', rd.dispatch_id, 'shelf_id', rd.shelf_id,
            'boonz_product_id', rd.boonz_product_id, 'action', rd.action, 'quantity', rd.quantity) ORDER BY rd.shelf_id), '[]'::jsonb),
         COUNT(*) INTO v_unresolved, v_unresolved_n
  FROM public.refill_dispatching rd
  WHERE rd.machine_id = v_machine_id AND rd.dispatch_date = v_date
    AND COALESCE(rd.cancelled, false) = false AND COALESCE(rd.include, true) = true
    AND COALESCE(rd.packed, false) = false AND COALESCE(rd.skipped, false) = false
    AND COALESCE(rd.pack_outcome::text, '') <> 'not_filled' AND rd.action IN ('Refill','Add New','Add');
  SELECT COUNT(*) INTO v_resolved_n FROM public.refill_dispatching rd
  WHERE rd.machine_id = v_machine_id AND rd.dispatch_date = v_date
    AND COALESCE(rd.cancelled, false) = false AND COALESCE(rd.include, true) = true
    AND (rd.packed OR rd.skipped OR rd.pack_outcome = 'not_filled');
  IF p_final AND v_unresolved_n > 0 THEN
    RETURN jsonb_build_object('status','blocked','machine',p_machine_name,'dispatch_date',v_date,
      'unresolved_count',v_unresolved_n,'unresolved',v_unresolved,
      'message','Finish blocked: some included lines are neither packed nor marked not_filled/skipped. Pack/mark them, or use Save & come back.');
  END IF;
  SELECT jsonb_build_object(
    'total_included', COUNT(*) FILTER (WHERE COALESCE(include,true) AND NOT COALESCE(cancelled,false)),
    'packed', COUNT(*) FILTER (WHERE packed AND COALESCE(pack_outcome::text,'packed') NOT IN ('partial','not_filled')),
    'partial', COUNT(*) FILTER (WHERE pack_outcome = 'partial'),
    'not_filled', COUNT(*) FILTER (WHERE pack_outcome = 'not_filled'),
    'skipped', COUNT(*) FILTER (WHERE skipped))
  INTO v_summary FROM public.refill_dispatching
  WHERE machine_id = v_machine_id AND dispatch_date = v_date AND NOT COALESCE(cancelled,false);
  INSERT INTO public.dispatch_pack_confirmation (machine_id, dispatch_date, confirmed_by, confirmed_at, reason, summary, final)
  VALUES (v_machine_id, v_date, COALESCE(p_packed_by, v_uid), now(), p_reason, v_summary, p_final)
  ON CONFLICT (machine_id, dispatch_date) DO UPDATE
    SET confirmed_by = EXCLUDED.confirmed_by, confirmed_at = now(), reason = EXCLUDED.reason,
        summary = EXCLUDED.summary, final = EXCLUDED.final;
  IF p_final THEN
    RETURN jsonb_build_object('status','ok','confirmed',true,'machine',p_machine_name,'dispatch_date',v_date,
      'pack_state','completed','confirmed_by',COALESCE(p_packed_by, v_uid),
      'packed_n',(v_summary->>'packed')::int,'partial_n',(v_summary->>'partial')::int,
      'skipped_n',(v_summary->>'skipped')::int,'not_filled_n',(v_summary->>'not_filled')::int,'summary',v_summary);
  ELSE
    RETURN jsonb_build_object('status','saved','saved',true,'machine',p_machine_name,'dispatch_date',v_date,
      'pack_state','in_progress','resolved_n',v_resolved_n,'remaining_n',v_unresolved_n,'summary',v_summary);
  END IF;
END; $function$;
