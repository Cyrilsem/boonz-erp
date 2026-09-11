-- PRD-120 follow-up F2: the NULL-pod_lot_id Remove-leg backlog is 822 rows total, of which
-- 794 are dispatched=true (HISTORICAL, already delivered/settled -- correctly excluded) and
-- 28 are dispatched=false (UNDELIVERED -- still operationally live and correctable).
--
-- Both check_null_pod_lot_remove_legs() and repair_remove_leg_shelf_lot_bulk() additionally
-- filtered "AND NOT COALESCE(rd.picked_up, false)", which silently narrowed the 28-row
-- undelivered set down to just 4 -- hiding 24 rows that are picked_up=true (driver already
-- physically handled the Remove) but not yet dispatched=true (day close not flagged) from
-- both the nightly alert and the bulk repair tool. This is why the nightly assertion has
-- been reporting count:4 instead of the true live count.
--
-- This was an unintentional over-restriction, not a deliberate safety gate: the underlying
-- single-row RPC repair_remove_leg_shelf_lot has no picked_up/dispatched guard at all -- it
-- only refuses on action<>'Remove' or cancelled/skipped/returned, and separately shelf-locks
-- when packed=true so a packed row's shelf assignment is never moved. Dropping the
-- picked_up condition (keeping the dispatched condition, which is what correctly separates
-- undelivered from historical) lets both functions see and safely repair the full live
-- backlog: only pod_lot_id, expiry_date, shelf_id (only if NOT packed), comment, and
-- edit_count/edit log are ever touched -- never quantity, action, or delivery-status flags.
--
-- Cody: approve. Articles 1 (no new write path), 4 (role/reason guards untouched), 8
-- (audit trigger unaffected), 12 (forward-only, md5-guarded byte-anchored replace()).
--
-- Verified in a rolled-back transaction: post-patch check_null_pod_lot_remove_legs()
-- reports null_pod_lot_remove_count: 25 (28 undelivered minus 3 quantity=0 rows the
-- function's own quantity>0 filter correctly excludes), not the pre-patch 4.
--
-- Applied, then ran repair_remove_leg_shelf_lot_bulk dry-run then real across all 9 distinct
-- plan_dates in the undelivered set: 25 attempted, 14 repaired, 11 correctly left alone
-- (genuinely no Active pod lot exists on that shelf now -- nothing to repair against).
-- Post-repair count: 11.

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='check_null_pod_lot_remove_legs' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'b8f1f33fa3c1a14549e2db3362fb32cf' THEN
    RAISE EXCEPTION 'check_null_pod_lot_remove_legs drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;
  v_new := replace(v_def,
    E'    AND NOT COALESCE(rd.picked_up, false)\n    AND NOT COALESCE(rd.dispatched, false);',
    E'    AND NOT COALESCE(rd.dispatched, false);');
  IF v_new = v_def THEN RAISE EXCEPTION 'check_null_pod_lot_remove_legs: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='repair_remove_leg_shelf_lot_bulk' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '4c3ce1eb3f27da9eb5d76d24455aa484' THEN
    RAISE EXCEPTION 'repair_remove_leg_shelf_lot_bulk drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;
  v_new := replace(v_def,
    E'       AND NOT COALESCE(rd.picked_up, false)\n       AND NOT COALESCE(rd.dispatched, false)',
    E'       AND NOT COALESCE(rd.dispatched, false)');
  IF v_new = v_def THEN RAISE EXCEPTION 'repair_remove_leg_shelf_lot_bulk: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;
