-- PRD-130 step 06 (F6): pair_internal_transfer_m2m widens to also pair legs whose
-- source_kind='m2m' but whose source_origin never got set to 'internal_transfer' (this is
-- exactly the shape add_dispatch_row v4 (prd130_01) still produces when the caller sets
-- source_kind='m2m' without going through the new p_partner_dispatch_id path, and it is the
-- shape a legacy or non-add_dispatch_row writer could leave behind).
--
-- Root cause confirmed against the live function body (pg_get_functiondef): the current dest/src
-- CTEs both filter strictly on source_origin = 'internal_transfer'. A row with source_kind='m2m'
-- but source_origin left at its default therefore never enters either CTE and can never be
-- paired, exactly as F6 describes.
--
-- Backfill note (read before assuming this closes the 21 Sep 'ADDMIND/USH/ALJLT hand-carried
-- transfer' phantom): the four hand-carried legs named in the PRD narrative (ADDMIND A06/A07,
-- USH A14, ALJLT A02) were inspected live on 2026-09-22 and none of them carry source_kind='m2m'
-- or source_origin='internal_transfer' today -- the 09:00 21-Sep direct UPDATE that "restored"
-- them set source_kind='unknown' with no m2m signal at all, and they were already receipted as
-- ordinary warehouse Add New / Remove pairs (item_added=true / no_pack_needed). Widening the
-- match predicate here cannot retroactively pair rows that carry no m2m signal whatsoever --
-- there is nothing for either CTE to match on. Pairing those four specific legs for history, and
-- reversing the phantom warehouse credit they produced, is F8's job (a dry-run script CS runs by
-- hand, scripts/prd130_f8_phantom_dryrun.sql), not this function. This migration only widens the
-- matcher and re-runs it for 2026-09-21 to pick up any row that DOES already carry
-- source_kind='m2m' with source_origin unset; if that yields zero new pairs today, it is not a
-- bug in this migration, it means no such row exists in the current 21 Sep data (verify count in
-- the deploy report).
--
-- Change from the live body: dest/src CTEs now match on
-- (source_origin = 'internal_transfer' OR source_kind = 'm2m'), and both legs' closing UPDATE
-- now also sets source_origin = 'internal_transfer', per F6's own text ("set source_origin on
-- both legs when it pairs"). Signature and all other behavior (ambiguous/qty-mismatch skip
-- reasons, role gate, return shape) unchanged.

CREATE OR REPLACE FUNCTION public.pair_internal_transfer_m2m(p_plan_date date DEFAULT NULL::date, p_caller_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller_id, auth.uid());
  v_role    text;
  v_pair    RECORD;
  v_transfer_id uuid;
  v_paired  int := 0;
  v_legs    int := 0;
  v_results jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
BEGIN
  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager','warehouse') THEN
      RAISE EXCEPTION 'pair_internal_transfer_m2m: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','pair_internal_transfer_m2m', true);
  PERFORM set_config('app.via_trigger','true', true);
  PERFORM set_config('app.mutation_reason',
    format('PRD-130 F6 pair internal_transfer/m2m legs plan_date=%s by=%s', COALESCE(p_plan_date::text,'ALL'), v_user_id), true);

  FOR v_pair IN
    WITH dest AS (
      SELECT d.dispatch_id AS dest_id, d.machine_id AS dest_machine, d.from_machine_id AS src_machine,
             d.pod_product_id, d.boonz_product_id, d.dispatch_date, d.quantity AS dest_qty, d.expiry_date
      FROM public.refill_dispatching d
      WHERE (d.source_origin = 'internal_transfer' OR d.source_kind = 'm2m')
        AND d.action IN ('Refill','Add New')
        AND d.from_machine_id IS NOT NULL
        AND d.m2m_transfer_id IS NULL
        AND COALESCE(d.item_added,false)=false
        AND COALESCE(d.cancelled,false)=false
        AND COALESCE(d.returned,false)=false
        AND (p_plan_date IS NULL OR d.dispatch_date = p_plan_date)
    ),
    src AS (
      SELECT s.dispatch_id AS src_id, s.machine_id AS src_machine,
             s.pod_product_id, s.dispatch_date, s.quantity AS src_qty, s.expiry_date AS src_expiry
      FROM public.refill_dispatching s
      WHERE (s.source_origin = 'internal_transfer' OR s.source_kind = 'm2m')
        AND s.action IN ('Remove','Machine To Warehouse')
        AND s.m2m_transfer_id IS NULL
        AND COALESCE(s.item_added,false)=false
        AND COALESCE(s.cancelled,false)=false
        AND COALESCE(s.returned,false)=false
        AND (p_plan_date IS NULL OR s.dispatch_date = p_plan_date)
    ),
    matched AS (
      SELECT d.dest_id, d.dest_machine, d.src_machine, d.pod_product_id, d.boonz_product_id,
             d.dispatch_date, d.dest_qty, d.expiry_date AS dest_expiry,
             s.src_id, s.src_qty, s.src_expiry,
             count(*) OVER (PARTITION BY d.dest_id) AS src_count
      FROM dest d
      JOIN src s
        ON s.src_machine    = d.src_machine
       AND s.pod_product_id = d.pod_product_id
       AND s.dispatch_date  = d.dispatch_date
    )
    SELECT * FROM matched
  LOOP
    IF v_pair.src_count <> 1 THEN
      v_skipped := v_skipped || jsonb_build_object('dest_id', v_pair.dest_id, 'reason',
        format('ambiguous: %s candidate source legs (batch split / multi-match) - manual pairing', v_pair.src_count));
      CONTINUE;
    END IF;
    IF v_pair.src_qty <> v_pair.dest_qty THEN
      v_skipped := v_skipped || jsonb_build_object('dest_id', v_pair.dest_id, 'reason',
        format('qty mismatch: source %s <> dest %s', v_pair.src_qty, v_pair.dest_qty));
      CONTINUE;
    END IF;

    v_transfer_id := gen_random_uuid();

    UPDATE public.refill_dispatching
       SET is_m2m = true, m2m_transfer_id = v_transfer_id, m2m_partner_id = v_pair.src_id,
           source_machine_id = v_pair.src_machine, source_kind = 'm2m', source_origin = 'internal_transfer',
           expiry_date = COALESCE(expiry_date, v_pair.src_expiry)
     WHERE dispatch_id = v_pair.dest_id;

    UPDATE public.refill_dispatching
       SET is_m2m = true, m2m_transfer_id = v_transfer_id, m2m_partner_id = v_pair.dest_id,
           source_machine_id = v_pair.src_machine, source_kind = 'm2m', source_origin = 'internal_transfer'
     WHERE dispatch_id = v_pair.src_id;

    v_paired := v_paired + 1;
    v_legs   := v_legs + 2;
    v_results := v_results || jsonb_build_object(
      'transfer_id', v_transfer_id, 'dest_id', v_pair.dest_id, 'src_id', v_pair.src_id,
      'pod_product_id', v_pair.pod_product_id, 'qty', v_pair.dest_qty,
      'dispatch_date', v_pair.dispatch_date, 'dest_machine', v_pair.dest_machine, 'src_machine', v_pair.src_machine);
  END LOOP;

  RETURN jsonb_build_object(
    'status','ok',
    'plan_date', p_plan_date,
    'pairs_formed', v_paired,
    'legs_flagged', v_legs,
    'paired', v_results,
    'skipped', v_skipped
  );
END;
$function$;
