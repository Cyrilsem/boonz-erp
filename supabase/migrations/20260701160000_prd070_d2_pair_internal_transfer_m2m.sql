-- PRD-070 D-2: pairing integrity for the mark_internal_transfer -> push_plan_to_dispatch path.
--
-- Problem: push_plan_to_dispatch carries source_origin='internal_transfer' + from_machine_id onto
-- dispatch legs but never sets is_m2m / m2m_transfer_id / m2m_partner_id / source_machine_id. So an
-- internal-transfer pair reaches dispatch UNFLAGGED and, on approval via the warehouse path, would
-- credit (source Remove) or draw (dest Refill) the warehouse. convert_removes_to_m2m_transfer already
-- flags both legs correctly; this closes the OTHER creation path.
--
-- push is per-machine, so source and dest legs are created in separate calls and cannot share a
-- transfer_id inline. This function is the pairing pass (and the backfill for existing rows).
--
-- SAFETY: it mutates ONLY pairing metadata (is_m2m, m2m_transfer_id, m2m_partner_id, source_machine_id,
-- source_kind). It never touches quantity, inventory, status, item_added, or calls receive. It moves
-- zero stock by construction, so warehouse delta is trivially 0. It flags a leg ONLY when it belongs to
-- an UNAMBIGUOUS 1:1 conserving pair (exactly one live source Remove/M2W leg + one live dest Refill/Add
-- New leg, same product + date, dest.from_machine_id = source.machine_id, qty match). Anything else
-- (multi-source batch splits, missing partner, qty mismatch) is left untouched and reported as skipped.
-- Idempotent: a leg already carrying a non-null m2m_transfer_id is skipped.

CREATE OR REPLACE FUNCTION public.pair_internal_transfer_m2m(
  p_plan_date date   DEFAULT NULL,
  p_caller_id uuid   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
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
  -- role gate
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
    format('PRD-070 D-2 pair internal_transfer legs plan_date=%s by=%s', COALESCE(p_plan_date::text,'ALL'), v_user_id), true);

  -- Candidate dest legs: live internal_transfer Refill/Add New, not yet flagged with a transfer_id,
  -- with a from_machine_id (the source). One row per dest leg with its unique matching source (if any).
  FOR v_pair IN
    WITH dest AS (
      SELECT d.dispatch_id AS dest_id, d.machine_id AS dest_machine, d.from_machine_id AS src_machine,
             d.pod_product_id, d.boonz_product_id, d.dispatch_date, d.quantity AS dest_qty, d.expiry_date
      FROM public.refill_dispatching d
      WHERE d.source_origin = 'internal_transfer'
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
      WHERE s.source_origin = 'internal_transfer'
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
    -- Only act on unambiguous 1:1 conserving pairs.
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

    -- dest leg: carry expiry from source when dest has none; flag as m2m dest.
    UPDATE public.refill_dispatching
       SET is_m2m = true, m2m_transfer_id = v_transfer_id, m2m_partner_id = v_pair.src_id,
           source_machine_id = v_pair.src_machine, source_kind = 'm2m',
           expiry_date = COALESCE(expiry_date, v_pair.src_expiry)
     WHERE dispatch_id = v_pair.dest_id;

    -- source leg: flag as m2m source (its own machine is the source).
    UPDATE public.refill_dispatching
       SET is_m2m = true, m2m_transfer_id = v_transfer_id, m2m_partner_id = v_pair.dest_id,
           source_machine_id = v_pair.src_machine, source_kind = 'm2m'
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

REVOKE ALL ON FUNCTION public.pair_internal_transfer_m2m(date,uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.pair_internal_transfer_m2m(date,uuid) TO authenticated, service_role;

-- DOWN:
-- DROP FUNCTION IF EXISTS public.pair_internal_transfer_m2m(date,uuid);
