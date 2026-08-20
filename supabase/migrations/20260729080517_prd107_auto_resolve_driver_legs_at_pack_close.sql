-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- PRD-107 Pack-stage truth, Phase 4 (post board-fix A4 audit, Finding 3). Source:
-- docs/prds/PRD-107-EXECUTION-LOG.md Phase 4; docs/architecture/MIGRATIONS_REGISTRY.md:688.
-- The packer's manual Remove-tick was found to be a REQUIRED step in the Remove state machine
-- (mark_picked_up only flips packed=true rows; driver_confirm_remove raises on unpacked).
-- confirm_machine_packed(final=true) now flips driver-side legs to packed=true via an UPDATE
-- (not INSERT, so conserve_split_dispatch_quantity - a BEFORE INSERT trigger - cannot fire and
-- corrupt split Remove quantities; probe: 38->38 conserved). tg_enforce_pack_via_rpc gains
-- confirm_machine_packed as a sanctioned pack writer (pack_guard='warn' today, not yet
-- load-bearing, correct once flipped to 'enforce').
-- This is the full CUMULATIVE body (recovered via pg_get_functiondef against live prod) —
-- it also carries the view-backed gate + orphan guard shipped by the prior migration
-- 20260729075541 (prd107_confirm_machine_packed_view_backed); the R2/R5 auto-resolve UPDATE
-- block below is this migration's own delta.

CREATE OR REPLACE FUNCTION public.confirm_machine_packed(p_machine_name text, p_dispatch_date date DEFAULT NULL::date, p_packed_by uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_final boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_role text; v_machine_id uuid;
  v_date date := COALESCE(p_dispatch_date, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date);
  v_unresolved jsonb; v_summary jsonb;
  v_p record;                 -- v_dispatch_pack_progress row
  v_orphans jsonb := '[]'::jsonb;
  v_orphan_n integer := 0;
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

  -- Article 16: the canonical object decides readiness. No inline re-derivation.
  SELECT * INTO v_p FROM public.v_dispatch_pack_progress
   WHERE machine_id = v_machine_id AND dispatch_date = v_date;

  IF NOT FOUND THEN
    -- No included, non-cancelled lines at all for this machine/date.
    RETURN jsonb_build_object('status','blocked','machine',p_machine_name,'dispatch_date',v_date,
      'unresolved_count',0,'unresolved','[]'::jsonb,
      'message','No included dispatch lines for this machine and date.');
  END IF;

  -- Line-level detail for the blocked response. Same predicate as the view.
  SELECT COALESCE(jsonb_agg(jsonb_build_object('dispatch_id', rd.dispatch_id, 'shelf_id', rd.shelf_id,
            'boonz_product_id', rd.boonz_product_id, 'action', rd.action, 'quantity', rd.quantity) ORDER BY rd.shelf_id), '[]'::jsonb)
    INTO v_unresolved
  FROM public.refill_dispatching rd
  WHERE rd.machine_id = v_machine_id AND rd.dispatch_date = v_date
    AND COALESCE(rd.cancelled, false) = false AND COALESCE(rd.include, true) = true
    AND COALESCE(rd.packed, false) = false AND COALESCE(rd.skipped, false) = false
    AND COALESCE(rd.pack_outcome::text, '') <> 'not_filled' AND rd.action IN ('Refill','Add New','Add');

  IF p_final AND NOT v_p.ready_to_pack_close THEN
    RETURN jsonb_build_object('status','blocked','machine',p_machine_name,'dispatch_date',v_date,
      'unresolved_count', v_p.packable_n - v_p.resolved_n,
      'unresolved', v_unresolved,
      'packable_n', v_p.packable_n, 'resolved_n', v_p.resolved_n,
      'driver_action_n', v_p.driver_action_n,
      'message','Finish blocked: some included lines are neither packed nor marked not_filled/skipped. Pack/mark them, or use Save & come back.');
  END IF;

  -- R2/R5: driver-side legs draw nothing from the warehouse. Resolve them here so
  -- the packer never has to tick them, while KEEPING the Remove state machine intact
  -- (mark_picked_up and driver_confirm_remove both require packed=true).
  -- UPDATE is safe: conserve_split_dispatch_quantity is a BEFORE INSERT trigger.
  IF p_final THEN
    UPDATE public.refill_dispatching rd
       SET packed = true
     WHERE rd.machine_id = v_machine_id AND rd.dispatch_date = v_date
       AND COALESCE(rd.cancelled,false) = false AND COALESCE(rd.include,true) = true
       AND COALESCE(rd.skipped,false) = false
       AND rd.action NOT IN ('Refill','Add New','Add')
       AND COALESCE(rd.packed,false) = false;
  END IF;

  -- R4: orphaned swap-leg guard. A live REMOVE whose paired swap-in all died
  -- would ship an EMPTY shelf. Flag it, surface it, propose the skip. Never silent,
  -- never auto-applied - the packer accepts it explicitly via skip_dispatch_line.
  IF p_final THEN
    v_orphans   := COALESCE(v_p.orphaned_swap_legs, '[]'::jsonb);
    v_orphan_n  := COALESCE(v_p.orphaned_swap_leg_n, 0);
    IF v_orphan_n > 0 THEN
      UPDATE public.refill_dispatching rd
         SET needs_review  = true,
             review_reason = 'orphaned_swap_leg',
             review_status = 'pending'   -- matches idx_refill_dispatching_needs_review
       WHERE rd.dispatch_id IN (
               SELECT (x->>'dispatch_id')::uuid FROM jsonb_array_elements(v_orphans) x)
         AND COALESCE(rd.needs_review,false) = false;
    END IF;
  END IF;

  SELECT jsonb_build_object(
    'total_included', COUNT(*) FILTER (WHERE COALESCE(include,true) AND NOT COALESCE(cancelled,false)),
    'packed', COUNT(*) FILTER (WHERE packed AND COALESCE(pack_outcome::text,'packed') NOT IN ('partial','not_filled')),
    'partial', COUNT(*) FILTER (WHERE pack_outcome = 'partial'),
    'not_filled', COUNT(*) FILTER (WHERE pack_outcome = 'not_filled'),
    'skipped', COUNT(*) FILTER (WHERE skipped))
  INTO v_summary FROM public.refill_dispatching
  WHERE machine_id = v_machine_id AND dispatch_date = v_date AND NOT COALESCE(cancelled,false);

  v_summary := v_summary || jsonb_build_object(
    'packable_n', v_p.packable_n, 'resolved_n', v_p.resolved_n,
    'driver_action_n', v_p.driver_action_n, 'no_pack_needed_n', v_p.no_pack_needed_n,
    'orphaned_swap_leg_n', v_orphan_n);

  INSERT INTO public.dispatch_pack_confirmation (machine_id, dispatch_date, confirmed_by, confirmed_at, reason, summary, final)
  VALUES (v_machine_id, v_date, COALESCE(p_packed_by, v_uid), now(), p_reason, v_summary, p_final)
  ON CONFLICT (machine_id, dispatch_date) DO UPDATE
    SET confirmed_by = EXCLUDED.confirmed_by, confirmed_at = now(), reason = EXCLUDED.reason,
        summary = EXCLUDED.summary, final = EXCLUDED.final;

  IF p_final THEN
    RETURN jsonb_build_object('status','ok','confirmed',true,'machine',p_machine_name,'dispatch_date',v_date,
      'pack_state','completed','confirmed_by',COALESCE(p_packed_by, v_uid),
      'packed_n',(v_summary->>'packed')::int,'partial_n',(v_summary->>'partial')::int,
      'skipped_n',(v_summary->>'skipped')::int,'not_filled_n',(v_summary->>'not_filled')::int,
      'packable_n', v_p.packable_n, 'resolved_n', v_p.resolved_n,
      'driver_action_n', v_p.driver_action_n,
      'orphaned_swap_legs', v_orphans, 'orphaned_swap_leg_n', v_orphan_n,
      'needs_review', (v_orphan_n > 0),
      'summary',v_summary);
  ELSE
    RETURN jsonb_build_object('status','saved','saved',true,'machine',p_machine_name,'dispatch_date',v_date,
      'pack_state','in_progress',
      'resolved_n',v_p.resolved_n,'remaining_n', v_p.packable_n - v_p.resolved_n,
      'packable_n', v_p.packable_n, 'driver_action_n', v_p.driver_action_n,
      'summary',v_summary);
  END IF;
END; $function$;

-- Sanction confirm_machine_packed as a pack-state writer on refill_dispatching. Full current
-- body recovered via pg_get_functiondef (pack_guard mode is read from refill_qa.flag at runtime,
-- so no era-stripping needed here — unlike the dispatch-write allowlist above).
CREATE OR REPLACE FUNCTION public.tg_enforce_pack_via_rpc()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rpc text := NULLIF(current_setting('app.rpc_name', true),'');
  v_via text := current_setting('app.via_rpc', true);
  v_mode text := refill_qa.flag('pack_guard');
BEGIN
  IF v_via IS DISTINCT FROM 'true' OR v_rpc IS NULL
     OR v_rpc NOT IN ('pack_dispatch_line','confirm_packed_transferred','confirm_machine_packed') THEN
    IF v_mode = 'enforce' THEN
      RAISE EXCEPTION 'refill_dispatching pack-state may change only via a sanctioned pack RPC (pack_guard=enforce). saw rpc=%, via_rpc=%', COALESCE(v_rpc,'(none)'), COALESCE(v_via,'(none)');
    ELSE
      INSERT INTO public.refill_pack_bypass_log(dispatch_id, rpc_name, via_rpc, detail)
      VALUES (NEW.dispatch_id, v_rpc, v_via IS NOT DISTINCT FROM 'true',
              jsonb_build_object('mode',COALESCE(v_mode,'warn'),'machine_id',NEW.machine_id,'filled',NEW.filled_quantity));
    END IF;
  END IF;
  RETURN NEW;
END $function$;
