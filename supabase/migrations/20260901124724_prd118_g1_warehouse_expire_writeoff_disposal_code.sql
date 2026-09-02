-- PRD-118 item G1: warehouse_expire_writeoff could not write anything off as waste.
-- It required p_reason >= 10 chars and wrote p_reason STRAIGHT into
-- warehouse_inventory.disposal_reason, which is CHECK-constrained to 'Waste' |
-- 'Returning to supplier' | 'Returned to supplier'. 'Waste' alone is 5 characters —
-- too short to pass the reason-length check — so any reason detailed enough to pass
-- validation was guaranteed to fail the CHECK constraint. The only reasons that
-- satisfied both were the two supplier ones, so expired stock could only be written
-- off by mislabelling it as returned to the supplier.
--
-- Fix: separate the audit reason from the disposal code. New parameter
-- p_disposal_code text DEFAULT 'Waste', validated against the exact 3 CHECK-allowed
-- values and written to disposal_reason. p_reason stays free text (>= 10 chars,
-- unchanged), already flowing into inventory_audit_log — untouched.
--
-- The old 3-arg signature is explicitly DROPPED (not left as a shadow overload) —
-- a 3-arg caller still resolves fine against the new 4-arg function via its DEFAULT.
--
-- Verified against md5 587df1f97f2bee3351f29576da8c7039. Verified live: a real
-- Activia Mix & Go - Greek Yogurt Honey & Oats CENTRAL row (1 unit, expired 27 Aug)
-- correctly wrote off — disposal_reason='Waste' (passes the CHECK), warehouse_stock=0.
-- Cody: approve, Articles 1/4/12 — no bypass of Article 6 (no status write, only
-- disposal_reason + stock zeroing, matching the function's existing unmodified
-- comment "no status write... zeroing stock fires the manager propose-then-confirm
-- trigger").
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.proname='warehouse_expire_writeoff' AND p.pronamespace='public'::regnamespace
     AND pg_get_function_identity_arguments(p.oid) = 'p_wh_inventory_id uuid, p_reason text, p_caller_id uuid';
  IF v_def IS NULL THEN RAISE EXCEPTION 'original 3-arg signature not found (already patched?)'; END IF;
  IF md5(v_def) <> '587df1f97f2bee3351f29576da8c7039' THEN
    RAISE EXCEPTION 'warehouse_expire_writeoff drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;

  v_new := replace(v_def,
    'CREATE OR REPLACE FUNCTION public.warehouse_expire_writeoff(p_wh_inventory_id uuid, p_reason text, p_caller_id uuid DEFAULT NULL::uuid)',
    'CREATE OR REPLACE FUNCTION public.warehouse_expire_writeoff(p_wh_inventory_id uuid, p_reason text, p_caller_id uuid DEFAULT NULL::uuid, p_disposal_code text DEFAULT ''Waste''::text)');
  IF v_new = v_def THEN RAISE EXCEPTION 'signature not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
    $$  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'warehouse_expire_writeoff: reason must be >= 10 chars';
  END IF;$$,
    $$  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'warehouse_expire_writeoff: reason must be >= 10 chars';
  END IF;
  IF p_disposal_code NOT IN ('Waste','Returning to supplier','Returned to supplier') THEN
    RAISE EXCEPTION 'warehouse_expire_writeoff: p_disposal_code must be Waste|Returning to supplier|Returned to supplier (got %)', p_disposal_code;
  END IF;$$);
  IF v_new = v_def THEN RAISE EXCEPTION 'reason check not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
    'UPDATE public.warehouse_inventory
  SET warehouse_stock = 0, consumer_stock = 0, disposal_reason = p_reason
  WHERE wh_inventory_id = p_wh_inventory_id;',
    'UPDATE public.warehouse_inventory
  SET warehouse_stock = 0, consumer_stock = 0, disposal_reason = p_disposal_code
  WHERE wh_inventory_id = p_wh_inventory_id;');
  IF v_new = v_def THEN RAISE EXCEPTION 'update statement not found'; END IF;
  v_def := v_new;

  DROP FUNCTION public.warehouse_expire_writeoff(uuid, text, uuid);
  EXECUTE v_def;
END $mig$;
