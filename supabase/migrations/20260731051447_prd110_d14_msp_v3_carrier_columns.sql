-- PRD-110 leg 42 · L42-U1 migration A of D
-- D-14 (CS-CLOSED 2026-07-31) carrier columns.
--
-- WHY THIS EXISTS. machine_service_policy.trip_interval_days and .z_default are read by the
-- LIVE v19 engine: engine_add_pod lines 163-164 (COALESCE(msp.trip_interval_days,21) -> trip_days)
-- and line 167 (COALESCE(msp.z_default, v_zmid) whenever the item margin IS NULL - measured
-- 2026-07-31: 243 of 544 pod-bound shelves). refill_sizing_mode is 'base_stock' TODAY, so both
-- branches are live. rank_slot_suitability and v_sizeup_candidates read trip_interval_days too.
-- Writing D-14's mapping into those columns would change tonight's 16:00Z production plan, which
-- PRD-110 LAW 12 forbids. D-14's ask was framed entirely in terms of the v3 base-stock resolver;
-- CS was never told the write lands in v19's live path. So the decision is honoured on a v3-scoped
-- carrier and the v19 propagation is parked as a one-line CS activation.
BEGIN;

ALTER TABLE public.machine_service_policy
  ADD COLUMN IF NOT EXISTS trip_interval_days_v3 integer,
  ADD COLUMN IF NOT EXISTS z_v3                  numeric,
  ADD COLUMN IF NOT EXISTS v3_source             text;

ALTER TABLE public.machine_service_policy
  ADD CONSTRAINT msp_trip_interval_days_v3_check
    CHECK (trip_interval_days_v3 IS NULL
           OR (trip_interval_days_v3 >= 1 AND trip_interval_days_v3 <= 90));

ALTER TABLE public.machine_service_policy
  ADD CONSTRAINT msp_z_v3_check
    CHECK (z_v3 IS NULL OR (z_v3 > 0 AND z_v3 <= 5));

-- LAW 6 / Article 16 in miniature: an override may not exist without naming the decision that
-- authorised it. Biconditional, so v3_source can be neither orphaned nor omitted.
ALTER TABLE public.machine_service_policy
  ADD CONSTRAINT msp_v3_source_required_check
    CHECK ((trip_interval_days_v3 IS NULL AND z_v3 IS NULL) = (v3_source IS NULL));

COMMENT ON COLUMN public.machine_service_policy.trip_interval_days_v3 IS
  'PRD-110 D-14 carrier. Override of trip_interval_days for the v3 base-stock resolver ONLY. NULL = no override. The base column trip_interval_days stays the only column the live v19 engine_add_pod / rank_slot_suitability / v_sizeup_candidates read, so a write here provably cannot move production (LAW 12).';

COMMENT ON COLUMN public.machine_service_policy.z_v3 IS
  'PRD-110 D-14b carrier. Override of z for the v3 base-stock resolver ONLY. NULL = no override. v19 engine_add_pod reads z_default, and only when the item margin IS NULL (243 of 544 pod-bound shelves on 2026-07-31).';

COMMENT ON COLUMN public.machine_service_policy.v3_source IS
  'PRD-110 D-14. Names the decision that authorised the v3 override. Enforced non-NULL whenever either override is set (msp_v3_source_required_check).';

-- POST-GUARD
DO $g$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_schema='public' AND table_name='machine_service_policy'
     AND column_name IN ('trip_interval_days_v3','z_v3','v3_source');
  IF n <> 3 THEN RAISE EXCEPTION 'A: expected 3 carrier columns, found %', n; END IF;

  SELECT count(*) INTO n FROM pg_constraint
   WHERE conrelid='public.machine_service_policy'::regclass
     AND conname IN ('msp_trip_interval_days_v3_check','msp_z_v3_check','msp_v3_source_required_check');
  IF n <> 3 THEN RAISE EXCEPTION 'A: expected 3 new CHECKs, found %', n; END IF;

  -- no existing row may have acquired an override by accident
  SELECT count(*) INTO n FROM public.machine_service_policy
   WHERE trip_interval_days_v3 IS NOT NULL OR z_v3 IS NOT NULL OR v3_source IS NOT NULL;
  IF n <> 0 THEN RAISE EXCEPTION 'A: carrier columns must land empty, found % populated', n; END IF;
END
$g$;

COMMIT;
