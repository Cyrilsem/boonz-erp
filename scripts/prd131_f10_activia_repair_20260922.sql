-- PRD-131 F10: Activia repair, AMZ-1029-3003-O1 shelf A05.
--
-- Rewritten 2026-09-23 after discovering the pod_inventory restore (this script's original Part
-- 2) was already done, correctly, earlier in this session (before a context compaction) --
-- reference_id 'adjust-AMZ-1029-3003-O1-A05-2026-09-22' in pod_inventory_audit_log, actor
-- 82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d (this session's own operator_admin caller). That pass used
-- WEIMI (real physical shelf state) as ground truth: WEIMI showed only 4 units actually on A05,
-- not 8, so it restored pro rata to the original 2:6 split of the two voided tap events --
-- Honey & Oats 0 -> 1 (audit_id 16a34082), Strawberries 5 -> 3 (audit_id 00c8d20e), both at
-- 2026-09-22 19:20:11. This is a BETTER repair than this script's original naive "restore the
-- full tapped quantity" (2 and 6) would have been -- that would have created 4 units of phantom
-- stock. Do NOT redo the pod_inventory restore. Verified live before writing this version: the
-- two original disposition_events rows (03027dc0 qty=2, f0e117f6 qty=6) still self-reference
-- their own superseded_by_event -- that part of the repair genuinely was not finished, and is
-- what this script now does.
--
-- Deferred to tonight's 22:00 Dubai batch. Part 2 below (the new Remove dispatch rows) REQUIRES
-- prd131_02 applied first: add_dispatch_row only sets movement_kind explicitly in its prd131_02
-- body, and once prd131_01's tg_movement_kind_required trigger is live, an insert without
-- movement_kind is rejected outright. If prd131_02 is held tonight, hold Part 2 of this script
-- (Part 1, properly superseding the two disposition_events, has no such dependency and can run
-- either way).

BEGIN;

SELECT set_config('app.mutation_reason',
  'PRD-131 F10: properly supersede the two voided AMZ-1029-3003-O1 A05 Activia tap events (pod_inventory already restored earlier this session via adjust_pod_inventory), then schedule the real removal for the next plan date', true);

-- Part 0: sanity-check the baseline this script assumes has not changed since it was drafted.
DO $$
DECLARE
  v_ev1 record;
  v_ev2 record;
BEGIN
  SELECT * INTO v_ev1 FROM disposition_events WHERE event_id = '03027dc0-d330-4c62-98b0-ff23d43f919c';
  SELECT * INTO v_ev2 FROM disposition_events WHERE event_id = 'f0e117f6-5cd9-4eb5-a6fc-15c32ff8984b';

  IF v_ev1.qty <> 2 OR v_ev1.superseded_by_event <> '03027dc0-d330-4c62-98b0-ff23d43f919c' THEN
    RAISE EXCEPTION 'F10 repair: event 03027dc0 no longer matches the assumed baseline (qty=%, superseded_by_event=%) -- stop, re-check by hand', v_ev1.qty, v_ev1.superseded_by_event;
  END IF;
  IF v_ev2.qty <> 6 OR v_ev2.superseded_by_event <> 'f0e117f6-5cd9-4eb5-a6fc-15c32ff8984b' THEN
    RAISE EXCEPTION 'F10 repair: event f0e117f6 no longer matches the assumed baseline (qty=%, superseded_by_event=%) -- stop, re-check by hand', v_ev2.qty, v_ev2.superseded_by_event;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pod_inventory_audit_log
    WHERE reference_id = 'adjust-AMZ-1029-3003-O1-A05-2026-09-22'
  ) THEN
    RAISE EXCEPTION 'F10 repair: expected pod_inventory_audit_log rows for adjust-AMZ-1029-3003-O1-A05-2026-09-22 are missing -- the stock restore this script assumes already happened may have been rolled back, stop and re-check by hand';
  END IF;
END $$;

-- Part 1: properly supersede the two original tap events (replacing the self-referencing
-- placeholder) with a correction event that states the real, WEIMI-grounded restored quantity
-- (1 and 3), not the originally tapped quantity (2 and 6) -- the events being superseded already
-- carry the tapped quantity in their own qty column, so history is not lost, only closed out.
WITH corr1 AS (
  INSERT INTO disposition_events (actor, source, machine_id, shelf_id, boonz_product_id, expiration_date, qty, state, reason)
  VALUES (auth.uid(), 'reconcile', 'f1a528fb-15e8-4f20-b4e2-ebb2e6852198', '268dabf1-e979-4a3b-9815-ee0ed4a40fde',
    'e6153383-9225-4a3d-b342-0f1d8db2c7fe', '2026-09-25', 1, 'restocked',
    'PRD-131 F10 correction: reverses event 03027dc0 (tapped from office, product never left machine); pod_inventory already restored to 1 (not the tapped 2) per WEIMI ground truth, pod_inventory_audit_log 16a34082-3a7d-42dd-a31c-ab8214754c4b')
  RETURNING event_id
)
UPDATE disposition_events SET superseded_by_event = corr1.event_id
FROM corr1
WHERE disposition_events.event_id = '03027dc0-d330-4c62-98b0-ff23d43f919c';

WITH corr2 AS (
  INSERT INTO disposition_events (actor, source, machine_id, shelf_id, boonz_product_id, expiration_date, qty, state, reason)
  VALUES (auth.uid(), 'reconcile', 'f1a528fb-15e8-4f20-b4e2-ebb2e6852198', '268dabf1-e979-4a3b-9815-ee0ed4a40fde',
    'e3a1a31a-d15e-42b2-a604-9de45e4deaf6', '2026-09-25', 3, 'restocked',
    'PRD-131 F10 correction: reverses event f0e117f6 (tapped from office, product never left machine); pod_inventory already restored to 3 (not the tapped 6) per WEIMI ground truth, pod_inventory_audit_log 00c8d20e-8dc0-4a97-b63d-946fa11865c3')
  RETURNING event_id
)
UPDATE disposition_events SET superseded_by_event = corr2.event_id
FROM corr2
WHERE disposition_events.event_id = 'f0e117f6-5cd9-4eb5-a6fc-15c32ff8984b';

-- Part 2: schedule the real removal for the units genuinely on the shelf and genuinely
-- expiring (1 Honey & Oats + 3 Strawberries = 4, matching the WEIMI-confirmed physical count,
-- NOT the originally tapped 2+6=8). "Next plan date" read as 2026-09-23 (tomorrow relative to
-- when this was drafted) -- if CS means a different date at execution time, change
-- p_dispatch_date below before running. REQUIRES prd131_02's add_dispatch_row (sets
-- movement_kind='warehouse_return' automatically).
SELECT public.add_dispatch_row(
  'f1a528fb-15e8-4f20-b4e2-ebb2e6852198'::uuid, 'A05',
  'e6153383-9225-4a3d-b342-0f1d8db2c7fe'::uuid, 1, 'Remove', '2026-09-23'::date,
  'unknown', NULL, NULL, NULL, 'expiring 2026-09-25', NULL, NULL
) AS honey_oats_remove_result;

SELECT public.add_dispatch_row(
  'f1a528fb-15e8-4f20-b4e2-ebb2e6852198'::uuid, 'A05',
  'e3a1a31a-d15e-42b2-a604-9de45e4deaf6'::uuid, 3, 'Remove', '2026-09-23'::date,
  'unknown', NULL, NULL, NULL, 'expiring 2026-09-25', NULL, NULL
) AS strawberries_remove_result;

-- Part 3: read-back verification before commit.
SELECT event_id, state, qty, superseded_by_event FROM disposition_events
WHERE event_id IN ('03027dc0-d330-4c62-98b0-ff23d43f919c','f0e117f6-5cd9-4eb5-a6fc-15c32ff8984b')
   OR reason ILIKE 'PRD-131 F10 correction%';

SELECT dispatch_id, action, quantity, dispatch_date, movement_kind FROM refill_dispatching
WHERE machine_id = 'f1a528fb-15e8-4f20-b4e2-ebb2e6852198' AND dispatch_date = '2026-09-23'
  AND boonz_product_id IN ('e6153383-9225-4a3d-b342-0f1d8db2c7fe','e3a1a31a-d15e-42b2-a604-9de45e4deaf6');

-- Review the Part 3 output, then COMMIT by hand. This script deliberately does not COMMIT
-- itself -- run it as a script, inspect the read-back, decide.
-- COMMIT;
