-- PRD-119/PRD-120 close-out, item 7 (quarantine reader audit): grepped
-- pg_proc for every function reading `quarantined` (16 matches). 15 of the
-- 16 already correctly check `manually_quarantined` (or read the canonical
-- `v_wh_pickable` view) -- confirming PRD-118 G2a's 12-function patch pass
-- covered almost everything. `bind_dispatch_fefo` was the one genuine
-- remaining offender: its `_bind_tally` temp-table filter checked
-- `NOT COALESCE(quarantined,false)` only, missing
-- `NOT COALESCE(manually_quarantined,false)` -- meaning a WM-quarantined
-- batch (deliberately held via `set_wh_quarantine`) could still be
-- FEFO-bound onto a dispatch line by this function.
--
-- Fix is purely additive/restrictive: adds one more exclusion to an
-- already-restrictive filter, narrows the pickable set, never widens it.
-- Verified safe against today's live packing day (2026-09-07): 0 packed
-- lines at the time of this fix, so no already-pinned row is affected
-- retroactively -- this migration only changes future FEFO-bind calls.
--
-- Cody: approve, Articles 1 (still the sole FEFO-binder, no new writer), 6
-- (n/a, does not touch warehouse_inventory.status), 12 (forward-only
-- md5-guarded CREATE OR REPLACE).
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='bind_dispatch_fefo' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '3e20f5993b394eea3bca2970dd57f424' THEN RAISE EXCEPTION 'bind_dispatch_fefo drifted (md5 %)', md5(v_def); END IF;

  v_new := replace(v_def,
    E'WHERE status=''Active'' AND NOT COALESCE(quarantined,false)\n    AND (expiration_date IS NULL OR expiration_date >= (now() AT TIME ZONE ''Asia/Dubai'')::date)\n    AND NOT public._is_phantom_wh_row_v3(batch_id, expiration_date);',
    E'WHERE status=''Active'' AND NOT COALESCE(quarantined,false) AND NOT COALESCE(manually_quarantined,false)\n    AND (expiration_date IS NULL OR expiration_date >= (now() AT TIME ZONE ''Asia/Dubai'')::date)\n    AND NOT public._is_phantom_wh_row_v3(batch_id, expiration_date);');
  IF v_new = v_def THEN RAISE EXCEPTION 'bind_dispatch_fefo: _bind_tally WHERE pattern not found'; END IF;

  EXECUTE v_new;
END $mig$;
