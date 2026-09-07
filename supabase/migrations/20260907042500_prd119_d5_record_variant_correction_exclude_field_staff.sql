-- PRD-119/PRD-120 close-out, item 5 (D5 field-writer permissions audit):
-- D5 doctrine is "field_staff: dates yes, qty yes, products no." Verified
-- `apply_expiry_check` and `correct_expiry_v1` already enforce this
-- correctly (the latter has an explicit second gate refusing field_staff
-- outside p_scope='pod'). `record_variant_correction` -- whose entire
-- purpose is reassigning a dispatch/pod row's PRODUCT identity
-- (planned_variant_id -> new_variant_id) -- had a role check of
-- `NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager')`,
-- i.e. field_staff WAS authorized to call it. Direct contradiction of D5.
--
-- Confirmed zero live risk before fixing: grepped the entire repo (FE,
-- edge functions) for `record_variant_correction` -- no caller exists
-- anywhere. This RPC is currently unwired from any app surface, so
-- narrowing its role check breaks nothing live.
--
-- Cody: approve, Articles 1 (same function, same non-existent FE callers),
-- 4 (role check now matches D5 doctrine for field_staff).
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='record_variant_correction' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '170d343a3f7a2e786ae50a0f54a39285' THEN RAISE EXCEPTION 'record_variant_correction drifted (md5 %)', md5(v_def); END IF;

  v_new := replace(v_def,
    E'IF v_caller_role IS NULL OR v_caller_role NOT IN\n    (''field_staff'',''warehouse'',''operator_admin'',''superadmin'',''manager'') THEN',
    E'IF v_caller_role IS NULL OR v_caller_role NOT IN\n    (''warehouse'',''operator_admin'',''superadmin'',''manager'') THEN');
  IF v_new = v_def THEN RAISE EXCEPTION 'record_variant_correction: role-check pattern not found'; END IF;

  EXECUTE v_new;
END $mig$;
