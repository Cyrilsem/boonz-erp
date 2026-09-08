-- INCIDENT FIX (2026-09-08/09): the D4 correction's visit-aware K1 floor
-- (20260908071626_prd119_d4_correction_k1_visit_aware_floor.sql) regressed in
-- production. `machines_to_visit` contains `status='picked'` rows dated in
-- 2030 (test/exploratory calls against `pick_machines_for_refill` -- see
-- root-cause note below), so `days_to_next_planned_visit` for the affected
-- machines computed to ~1500 days, `GREATEST(7, 1500+3)` became the floor,
-- and `approve_refill_plan` refused every warehouse Refill/Add New line on
-- those machines regardless of how far out its expiry actually was. Hit live
-- 2026-09-09, ~80 lines refused. Reproduced live before this file was
-- written: 17 real lines on today's (2026-09-08) pending plan across 4
-- machines were being wrongly refused by the unbounded formula; all 17 pass
-- clean under the fix below.
--
-- Two independent defenses, either sufficient on its own:
--   1. Query-level: the next-visit lookup now ignores any machines_to_visit
--      row more than 60 days past plan_date (`mtv.plan_date <= p_plan_date +
--      60`) -- a 2030 row is excluded from the MIN() outright, so a stray
--      bad row can no longer poison the floor at all.
--   2. Formula-level: the floor itself is capped -- `GREATEST(7,
--      LEAST(COALESCE(next_visit_days + 3, 7), 21))`. Even if a bad row
--      somehow slipped past the 60-day filter (or the filter is loosened
--      later), the floor can never exceed 21 days.
-- The `COALESCE(..., 7)` is load-bearing, not decorative: nesting a bare
-- `GREATEST(7, LEAST(x + 3, 21))` would silently break the "no future visit
-- known -> fall back to the bare 7-day floor" case, because Postgres
-- LEAST/GREATEST ignore NULL operands rather than propagating them --
-- `LEAST(NULL, 21)` evaluates to 21, not NULL, which would have wrongly
-- applied the 21-day cap as the DEFAULT for every machine with no visible
-- schedule (a much more aggressive floor than intended) instead of falling
-- back to 7. The explicit COALESCE forces the NULL case to resolve to 7
-- before it ever reaches LEAST.
--
-- Fixture (rolled back, real machine ACTIVATE-2005-0000-W0, synthetic
-- 2099-06-01 plan+dispatch rows, a poisoned 2030-01-04 pick row inserted
-- alongside): a normal Refill/Add New line at expiry+10d approves clean
-- (status='ok') with the 2030 row present and untouched -- proving the fix
-- is robust even before the fleet-wide cleanup (next migration) runs.
-- Companion checks: dairy at expiry+4d still refused (7-day minimum intact);
-- a legitimate visit 40 days out (within the 60-day lookback) caps the floor
-- at 21, not 43 -- a line at expiry+25d passes (25 > 21), which is exactly
-- the discriminating case: under the old unbounded formula this would have
-- been wrongly refused (25 <= 43).
--
-- Root cause (found while diagnosing, fixed here only as containment, NOT
-- patched at the source -- flagged for CS, out of this incident's scope):
-- `pick_machines_for_refill(p_plan_date, ...)` validates `p_plan_date <
-- CURRENT_DATE - 7` (no more than 7 days in the past) but has NO upper
-- bound at all -- it will happily INSERT real `status='picked'` rows for
-- any future date, including 2030, with no dry-run isolation. The 64 bad
-- rows found (12 machines, created 2026-07-30 to 2026-08-14, add_source
-- 'picker' and 'operator') carry the signature of exploratory/test calls
-- against this RPC with far-future dates chosen specifically to avoid
-- colliding with real near-term routing -- not a data-entry typo and not a
-- bug in the picker's own date math. Recommend a follow-up to reject
-- `p_plan_date > CURRENT_DATE + 30` in `pick_machines_for_refill` itself;
-- not done in this migration since it changes the automated picker's own
-- behavior and deserves its own review, not a rider on an incident fix.
--
-- Cody: approve, Articles 1 (still the sole approval gate, no new write
-- path), 4, 5, 12 (forward-only, md5-guarded byte-exact replace -- item C's
-- unbound check, the NULL-expiry exemption, and the 48h floor are
-- byte-identical to the prior live function).
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='approve_refill_plan' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '4109f50cbfedf97795cb6259ab2738ec' THEN
    RAISE EXCEPTION 'approve_refill_plan drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;

  v_new := replace(v_def,
E'      OR rd3.expiry_date <= (p_plan_date + GREATEST(7,\n          (SELECT MIN(mtv.plan_date) - p_plan_date\n             FROM public.machines_to_visit mtv\n            WHERE mtv.machine_id = rd3.machine_id\n              AND mtv.plan_date > p_plan_date\n              AND mtv.status IN (\'picked\',\'cs_added\')) + 3\n        ))',
E'      OR rd3.expiry_date <= (p_plan_date + GREATEST(7, LEAST(\n          COALESCE(\n            (SELECT MIN(mtv.plan_date) - p_plan_date\n               FROM public.machines_to_visit mtv\n              WHERE mtv.machine_id = rd3.machine_id\n                AND mtv.plan_date > p_plan_date\n                AND mtv.plan_date <= p_plan_date + 60\n                AND mtv.status IN (\'picked\',\'cs_added\')) + 3,\n            7\n          ),\n          21\n        )))');
  IF v_new = v_def THEN
    RAISE EXCEPTION 'approve_refill_plan: K1 visit-floor pattern not found';
  END IF;

  EXECUTE 'CREATE OR REPLACE FUNCTION public.approve_refill_plan' || substring(v_new from position('(' in v_new));
END $mig$;
