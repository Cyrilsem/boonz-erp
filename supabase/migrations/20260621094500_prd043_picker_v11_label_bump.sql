-- PRD-043: picker logic (VOX Wed/Fri gate + emergency override + days_until_next_vox_day helper)
-- is already live; only the RAISE NOTICE label still said v10. Bump label to v11 by
-- rehydrating the function from its own definition (byte-identical body, label swapped).
DO $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'pick_machines_for_refill';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'pick_machines_for_refill not found';
  END IF;

  IF position('pick_machines_for_refill v10 (' IN v_def) = 0 THEN
    RAISE EXCEPTION 'expected v10 label not found - aborting to avoid an unexpected rewrite';
  END IF;

  v_def := replace(v_def, 'pick_machines_for_refill v10 (', 'pick_machines_for_refill v11 (');
  EXECUTE v_def;
END $$;
