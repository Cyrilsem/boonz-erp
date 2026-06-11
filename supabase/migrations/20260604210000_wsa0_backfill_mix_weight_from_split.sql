-- WS-A Step 0/snap-back - backfill product_mapping.mix_weight = split_pct/100. STATUS: DRAFT - NOT APPLIED.
--
-- Step 0 finding (read-only, confirmed live 2026-06-04): of 7,662 active product_mapping rows, 7,654 are at
-- the raw default mix_weight=1.000 (never backfilled). split_pct sums to 100 on 3,098/3,100 pods. The only 8
-- non-default rows are the Hunter pods (OMDBB-1020, OMDCW-1021) where mix_weight already equals split_pct/100.
-- apply_mix_weight_recommendation has never run in prod (it is staged), so there are ZERO genuine recommendation
-- divergences to preserve - all divergence is unbackfilled default. Therefore mix_weight must be snapped to
-- split_pct/100 everywhere BEFORE any reader switches to it; otherwise stitch reading mix_weight directly would
-- give every multi-variant pod equal/garbage splits instead of the configured 30/40/40.
--
-- This canonical writer sets mix_weight = ROUND(split_pct/100, 4) for active rows. After it, mix_weight sums to
-- 1.0/pod and encodes the current splits, so the WS-A reader switches are behavior-preserving and future
-- apply_mix_weight_recommendation edits take effect. product_mapping is protected (canonical RPC + CS sign-off).
-- Idempotent: only touches rows where mix_weight differs from split_pct/100. p_confirm=false returns the diff.

CREATE OR REPLACE FUNCTION public.backfill_mix_weight_from_split_pct(p_confirm boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid());
  v_role text;
  v_diff_n int;
  v_updated int := 0;
  v_sample jsonb;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'backfill_mix_weight_from_split_pct', true);

  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
  IF v_uid IS NOT NULL AND v_role NOT IN ('operator_admin','superadmin') THEN
    RAISE EXCEPTION 'backfill_mix_weight_from_split_pct: forbidden for role %', COALESCE(v_role,'unknown');
  END IF;

  SELECT COUNT(*) INTO v_diff_n
  FROM public.product_mapping
  WHERE status='Active' AND mix_weight IS DISTINCT FROM ROUND(split_pct/100.0, 4);

  SELECT jsonb_agg(s) INTO v_sample FROM (
    SELECT pm.machine_id, pm.pod_product_id, pm.boonz_product_id,
           pm.split_pct, pm.mix_weight AS mix_weight_before, ROUND(pm.split_pct/100.0,4) AS mix_weight_after
    FROM public.product_mapping pm
    WHERE pm.status='Active' AND pm.mix_weight IS DISTINCT FROM ROUND(pm.split_pct/100.0,4)
    ORDER BY pm.pod_product_id LIMIT 20
  ) s;

  IF NOT p_confirm THEN
    RETURN jsonb_build_object(
      'mode','diff_only','confirm',false,
      'rows_to_update', v_diff_n,
      'rule','mix_weight := ROUND(split_pct/100, 4) where status=Active',
      'sample', COALESCE(v_sample,'[]'::jsonb));
  END IF;

  UPDATE public.product_mapping
     SET mix_weight = ROUND(split_pct/100.0, 4), updated_at = now()
   WHERE status='Active' AND mix_weight IS DISTINCT FROM ROUND(split_pct/100.0, 4);
  GET DIAGNOSTICS v_updated = ROW_COUNT;

  RETURN jsonb_build_object('mode','applied','confirm',true,'rows_updated',v_updated);
END;
$function$;
