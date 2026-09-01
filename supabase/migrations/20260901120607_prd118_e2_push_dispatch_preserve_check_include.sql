-- PRD-118 item E, Addendum 2 §E-2 (decoded 2026-08-30): push_plan_to_dispatch's
-- "one-shot" behaviour is not a flag, it is two checks. The tombstone check (skip an
-- rpo line whose dispatch_id points at an include=false row with an edit_log 'remove'
-- entry) is already correct. The PRESERVE check — for a machine/date/shelf/pod_product,
-- any dispatch row with created_by_edit OR edit_count>0 (skipped/cancelled/returned
-- excluded) is treated as "preserved": the rpo line is marked dispatched pointing at
-- that row and no new row is inserted — did NOT exclude include=false. A removed row
-- could therefore silently absorb a fresh plan line for the same lane, which is
-- exactly the failure CS hit on 28 Aug (a corrected Aquafina row that could never
-- reach dispatch after the machine had bridged).
--
-- Fix: add COALESCE(rd.include, true) = true to the general preserve-check predicate
-- (keyed on pod_product_id). NOTE: the sibling preserve-check for Refill/Add New +
-- source_origin='warehouse' (keyed on boonz_product_id + action) already had
-- rd.include = true — only the general check needed this fix.
--
-- Verified against md5 c064ad3d3b23763e8a66871a18601b0b. Live evidence of blast
-- radius: 49 current refill_dispatching rows match created_by_edit/edit_count>0 with
-- include=false and would have wrongly qualified as "preserved" under the old
-- predicate. Cody: approve, Articles 1/4/12 — no new write path, existing writer's
-- own preserve-check corrected to match its sibling check's already-correct shape.
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.proname='push_plan_to_dispatch' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'c064ad3d3b23763e8a66871a18601b0b' THEN
    RAISE EXCEPTION 'push_plan_to_dispatch drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;

  v_new := replace(v_def,
$$    SELECT rd.dispatch_id INTO v_existing_edit_id
      FROM refill_dispatching rd
     WHERE rd.machine_id     = v_machine_id
       AND rd.dispatch_date  = line.plan_date
       AND rd.shelf_id       = v_shelf_id
       AND rd.pod_product_id = v_pod_product_id
       AND (rd.created_by_edit OR rd.edit_count > 0)
       AND COALESCE(rd.skipped,   false) = false
       AND COALESCE(rd.cancelled, false) = false
       AND COALESCE(rd.returned,  false) = false
     ORDER BY rd.created_at DESC NULLS LAST
     LIMIT 1;$$,
$$    -- PRD-118 item E, Addendum 2 §E-2: a removed (include=false) row must never
    -- absorb a fresh plan line. This was the actual cause of push_plan_to_dispatch's
    -- observed "one-shot" behaviour for a corrected row after a remove.
    SELECT rd.dispatch_id INTO v_existing_edit_id
      FROM refill_dispatching rd
     WHERE rd.machine_id     = v_machine_id
       AND rd.dispatch_date  = line.plan_date
       AND rd.shelf_id       = v_shelf_id
       AND rd.pod_product_id = v_pod_product_id
       AND (rd.created_by_edit OR rd.edit_count > 0)
       AND COALESCE(rd.include,   true) = true
       AND COALESCE(rd.skipped,   false) = false
       AND COALESCE(rd.cancelled, false) = false
       AND COALESCE(rd.returned,  false) = false
     ORDER BY rd.created_at DESC NULLS LAST
     LIMIT 1;$$);
  IF v_new = v_def THEN RAISE EXCEPTION 'preserve check block not found'; END IF;
  EXECUTE v_new;
END $mig$;
