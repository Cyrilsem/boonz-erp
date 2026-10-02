-- Bug 02 Oct: product mapping editor (By product view) duplicate-key crash.
-- Rollback: supabase/migrations/20261002145207_product_mapping_set_splits_rollback.sql
--
-- Root cause: product_mapping has UNIQUE (pod_product_id, boonz_product_id, machine_id) covering
-- ALL statuses, not just Active. The editor's "boonz product changed on an existing split" path
-- (src/app/(field)/field/config/product-mapping/page.tsx) did a plain DELETE-then-INSERT with no
-- upsert handling, so re-adding a boonz product that already had an Inactive row for the same
-- pod+machine hit the unique constraint directly. Separately, nothing enforced "removed rows get
-- archived, not deleted" or "the total must hit exactly 100 before saving" at the database layer.
--
-- New SECURITY DEFINER set_product_mapping_splits(p_pod_product_id, p_machine_id, p_splits,
-- p_reason, p_caller_id): the single canonical write path for a pod+machine's Active split set.
-- p_splits is the FULL desired Active set (jsonb array of {boonz_product_id, split_pct}). For
-- each entry: INSERT ... ON CONFLICT (pod_product_id, boonz_product_id, machine_id) DO UPDATE --
-- a true upsert, so reactivating an existing Inactive row never collides. Any row currently Active
-- for this pod+machine whose boonz_product_id is NOT in p_splits gets archived (status='Inactive',
-- split_pct=0, mix_weight=0), never hard-deleted. is_global_default is never written (it is a
-- GENERATED ALWAYS column). Refuses unless the splits sum to exactly 100 (rounded) -- the same
-- rule the FE already showed, now enforced server-side so it cannot be bypassed.
--
-- RLS (admins_manage_mapping: operator_admin/superadmin/manager/warehouse) already restricts who
-- can write to product_mapping; this function keeps the same role list for its own explicit check
-- and adds the atomicity and validation RLS cannot provide. product_mapping's existing generic
-- audit trigger (tg_audit_product_mapping) fires on every statement regardless of app.via_rpc, so
-- Article 8 is satisfied without any allowlist change.

CREATE OR REPLACE FUNCTION public.set_product_mapping_splits(
  p_pod_product_id uuid,
  p_machine_id uuid,
  p_splits jsonb,
  p_reason text,
  p_caller_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_caller_role text;
  v_entry jsonb;
  v_boonz_id uuid;
  v_pct numeric;
  v_sum numeric := 0;
  v_n int;
  v_wanted_ids uuid[] := '{}';
  v_activated int := 0;
  v_deactivated int := 0;
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = p_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('operator_admin', 'superadmin', 'manager', 'warehouse') THEN
    RAISE EXCEPTION 'set_product_mapping_splits: role % not authorized', COALESCE(v_caller_role, 'none');
  END IF;
  IF p_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'set_product_mapping_splits: p_pod_product_id is required';
  END IF;
  IF p_machine_id IS NULL THEN
    RAISE EXCEPTION 'set_product_mapping_splits: p_machine_id is required';
  END IF;
  IF p_splits IS NULL OR jsonb_typeof(p_splits) <> 'array' THEN
    RAISE EXCEPTION 'set_product_mapping_splits: p_splits must be a jsonb array';
  END IF;
  v_n := jsonb_array_length(p_splits);
  IF v_n < 1 THEN
    RAISE EXCEPTION 'set_product_mapping_splits: p_splits must have at least one entry';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 5 THEN
    RAISE EXCEPTION 'set_product_mapping_splits: p_reason is required';
  END IF;

  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_splits) LOOP
    v_boonz_id := NULLIF(v_entry ->> 'boonz_product_id', '')::uuid;
    v_pct := (v_entry ->> 'split_pct')::numeric;
    IF v_boonz_id IS NULL THEN
      RAISE EXCEPTION 'set_product_mapping_splits: every split needs a boonz_product_id';
    END IF;
    IF v_pct IS NULL OR v_pct < 0 OR v_pct > 100 THEN
      RAISE EXCEPTION 'set_product_mapping_splits: split_pct for % must be between 0 and 100 (got %)', v_boonz_id, v_pct;
    END IF;
    IF v_boonz_id = ANY (v_wanted_ids) THEN
      RAISE EXCEPTION 'set_product_mapping_splits: boonz_product_id % appears more than once in p_splits', v_boonz_id;
    END IF;
    v_wanted_ids := array_append(v_wanted_ids, v_boonz_id);
    v_sum := v_sum + v_pct;
  END LOOP;

  IF round(v_sum) <> 100 THEN
    RAISE EXCEPTION 'set_product_mapping_splits: Active splits must total 100 (got %)', v_sum;
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'set_product_mapping_splits', true);
  PERFORM set_config('app.mutation_reason',
    format('set_product_mapping_splits: pod=%s machine=%s reason=%s caller=%s',
      p_pod_product_id, p_machine_id, p_reason, p_caller_id), true);

  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_splits) LOOP
    v_boonz_id := (v_entry ->> 'boonz_product_id')::uuid;
    v_pct := (v_entry ->> 'split_pct')::numeric;
    INSERT INTO product_mapping (pod_product_id, boonz_product_id, machine_id, split_pct, mix_weight, status)
    VALUES (p_pod_product_id, v_boonz_id, p_machine_id, v_pct, v_pct / 100.0, 'Active')
    ON CONFLICT (pod_product_id, boonz_product_id, machine_id)
    DO UPDATE SET split_pct = EXCLUDED.split_pct, mix_weight = EXCLUDED.mix_weight,
      status = 'Active', updated_at = now();
    v_activated := v_activated + 1;
  END LOOP;

  UPDATE product_mapping
  SET status = 'Inactive', split_pct = 0, mix_weight = 0, updated_at = now()
  WHERE pod_product_id = p_pod_product_id
    AND machine_id = p_machine_id
    AND status = 'Active'
    AND NOT (boonz_product_id = ANY (v_wanted_ids));
  GET DIAGNOSTICS v_deactivated = ROW_COUNT;

  RETURN jsonb_build_object(
    'status', 'ok', 'pod_product_id', p_pod_product_id, 'machine_id', p_machine_id,
    'activated', v_activated, 'deactivated', v_deactivated, 'total_pct', v_sum);
END;
$function$;
