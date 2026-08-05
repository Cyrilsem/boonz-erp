-- PRD-110 leg 42 · L42-U1 migration D of D — the CS-authorized D-14 writes.
-- D-14b: z varies by machine_class.  D-14c: AMZ-1046-2406-O1 gets a real service-policy row.
-- Both land on the v3 carrier ONLY. The base columns are written for AMZ-1046 at v19's OWN
-- hardcoded fallbacks (trip 21, z 1.65 = z_mid), which is the unique choice that keeps the live
-- engine bit-identical while satisfying the NOT NULL constraints. Neutrality is PROVEN below
-- against a pre-image, not asserted.
BEGIN;

SELECT set_config('request.jwt.claims',
  '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);

-- PRE-GUARD: A, B and C must all have landed.
DO $g$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_schema='public' AND table_name='machine_service_policy'
     AND column_name IN ('trip_interval_days_v3','z_v3','v3_source');
  IF n <> 3 THEN RAISE EXCEPTION 'D: migration A missing'; END IF;

  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_machine_base_stock_policy_v3' AND column_name='z_v3';
  IF n <> 1 THEN RAISE EXCEPTION 'D: migration B missing'; END IF;

  SELECT count(*) INTO n FROM golden.assertions WHERE fixture_id=28 AND seq=15 AND expect='policy_seed';
  IF n <> 1 THEN RAISE EXCEPTION 'D: migration C missing'; END IF;

  SELECT count(*) INTO n FROM public.machine_service_policy;
  IF n <> 30 THEN RAISE EXCEPTION 'D: expected 30 policy rows before the write, got %', n; END IF;
END
$g$;

-- PRE-IMAGE of the LIVE v19 inputs, expression-for-expression as engine_add_pod computes them.
CREATE TEMP TABLE d14_v19_pre AS
SELECT s.machine_id,
       COALESCE((SELECT msp.trip_interval_days FROM public.machine_service_policy msp
                  WHERE msp.machine_id = s.machine_id), 21)                       AS v19_trip_days,
       COALESCE((SELECT msp.z_default FROM public.machine_service_policy msp
                  WHERE msp.machine_id = s.machine_id),
                (SELECT z_mid FROM public.refill_policy_params LIMIT 1))          AS v19_z_null_margin
  FROM (SELECT DISTINCT machine_id FROM public.v_shelf_state WHERE pod_product_id IS NOT NULL) s;

-- ── D-14b ──────────────────────────────────────────────────────────────────────────────────
-- CS: "z varies by machine_class - high-traffic venue classes -> z_high, quiet office classes
-- -> z_low, else z_mid." The classes actually present are the 2026-06-21 VELOCITY TERTILES
-- busy / standard / backup, so the mapping proposed and applied is the tertile ordering:
--   busy (top tertile, high traffic)    -> z_high 2.05
--   standard (middle tertile)           -> z_mid  1.65
--   backup (bottom tertile, quiet)      -> z_low  1.28
UPDATE public.machine_service_policy msp
   SET z_v3 = CASE msp.machine_class
                WHEN 'busy'     THEN p.z_high
                WHEN 'standard' THEN p.z_mid
                WHEN 'backup'   THEN p.z_low
              END,
       v3_source = 'D-14b (CS 2026-07-31): z by machine_class - busy=z_high, standard=z_mid, backup=z_low',
       updated_at = now()
  FROM public.refill_policy_params p
 WHERE msp.machine_class IN ('busy','standard','backup');

-- ── D-14c ──────────────────────────────────────────────────────────────────────────────────
INSERT INTO public.machine_service_policy
  (machine_id, machine_class, trip_interval_days, z_default, source, notes,
   trip_interval_days_v3, z_v3, v3_source)
SELECT m.machine_id, 'standard', 21, 1.65,
  'prd110_d14c_seeded_by_decision',
  'D-14c (CS 2026-07-31). class=standard on two independent signals: 32 non-phantom shelves vs 40 on all four AMZ siblings, and site-code cohort 24xx = AMZ-1057-2403 + AMZ-1068-2401 (both standard), while the 30xx pair AMZ-1029-3003 + AMZ-1038-3001 is busy. Base columns are set to v19 engine_add_pod''s OWN hardcoded fallbacks (trip 21, z 1.65 = z_mid) so this row is provably neutral to live sizing (LAW 12); 21 is also the standard-class seed, so it is consistent either way. SERVICE ANOMALY for CS: 2 dispatch visits in 120 days versus 23-33 for every sibling, i.e. the real cadence is nearer 60 days than 3. The 3-day v3 override is the 24xx cohort MEASURED median (2.5, rounded up) per D-14a, NOT a claim about how often this machine is actually visited. Root cause of its invisibility is D-13 (stale Adyen metadata).',
  3, 1.65,
  'D-14c (CS 2026-07-31): seeded from the AMZ 24xx siblings'' measured cadence (median 2.5d -> 3) with z=z_mid for class standard'
  FROM public.machines m
 WHERE m.official_name = 'AMZ-1046-2406-O1'
   AND NOT EXISTS (SELECT 1 FROM public.machine_service_policy x WHERE x.machine_id = m.machine_id);

-- ── POST-GUARDS ────────────────────────────────────────────────────────────────────────────
DO $g$
DECLARE n bigint; t text;
BEGIN
  -- 1. LAW 12 PROOF: every live v19 input is bit-identical to the pre-image.
  SELECT count(*) INTO n
    FROM d14_v19_pre pre
    JOIN (SELECT s.machine_id,
                 COALESCE((SELECT msp.trip_interval_days FROM public.machine_service_policy msp
                            WHERE msp.machine_id = s.machine_id), 21) AS v19_trip_days,
                 COALESCE((SELECT msp.z_default FROM public.machine_service_policy msp
                            WHERE msp.machine_id = s.machine_id),
                          (SELECT z_mid FROM public.refill_policy_params LIMIT 1)) AS v19_z_null_margin
            FROM (SELECT DISTINCT machine_id FROM public.v_shelf_state WHERE pod_product_id IS NOT NULL) s
         ) post USING (machine_id)
   WHERE pre.v19_trip_days      IS DISTINCT FROM post.v19_trip_days
      OR pre.v19_z_null_margin  IS DISTINCT FROM post.v19_z_null_margin;
  IF n <> 0 THEN RAISE EXCEPTION 'D: LAW 12 VIOLATION - % machines changed their live v19 inputs', n; END IF;

  -- 2. the base columns are untouched fleet-wide
  SELECT count(*) INTO n FROM public.machine_service_policy WHERE z_default <> 1.65;
  IF n <> 0 THEN RAISE EXCEPTION 'D: z_default drifted on % rows', n; END IF;
  SELECT count(*) INTO n FROM public.machine_service_policy
   WHERE (machine_class, trip_interval_days) NOT IN (('busy',12),('standard',21),('backup',30));
  IF n <> 0 THEN RAISE EXCEPTION 'D: trip_interval_days drifted on % rows', n; END IF;

  -- 3. D-14b landed on exactly the intended shape
  SELECT count(*) INTO n FROM public.machine_service_policy WHERE z_v3 IS NULL;
  IF n <> 0 THEN RAISE EXCEPTION 'D: % rows left without a z_v3', n; END IF;
  SELECT string_agg(machine_class||'='||z_v3::text||'x'||c::text, ' ' ORDER BY machine_class) INTO t
    FROM (SELECT machine_class, z_v3, count(*) c FROM public.machine_service_policy
           GROUP BY machine_class, z_v3) q;
  IF t <> 'backup=1.28x10 busy=2.05x10 standard=1.65x11'
    THEN RAISE EXCEPTION 'D: unexpected z_v3 distribution: %', t; END IF;

  -- 4. D-14c landed
  SELECT count(*) INTO n FROM public.machine_service_policy;
  IF n <> 31 THEN RAISE EXCEPTION 'D: expected 31 policy rows, got %', n; END IF;
  SELECT count(*) INTO n FROM public.v_machine_base_stock_policy_v3
   WHERE machine_name='AMZ-1046-2406-O1' AND interval_source='policy_seed'
     AND visit_interval_days=3 AND horizon_days=4 AND z=1.65;
  IF n <> 1 THEN RAISE EXCEPTION 'D: AMZ-1046 did not resolve as designed'; END IF;

  -- 5. the resolver still covers the whole fleet and names every origin
  SELECT count(*) INTO n FROM public.v_machine_base_stock_policy_v3;
  IF n <> 31 THEN RAISE EXCEPTION 'D: resolver rows = %', n; END IF;
  SELECT count(*) INTO n FROM public.v_machine_base_stock_policy_v3
   WHERE z IS NULL OR visit_interval_days IS NULL OR horizon_days IS NULL
      OR z_source <> 'machine_service_policy_v3';
  IF n <> 0 THEN RAISE EXCEPTION 'D: % resolver rows are NULL or unnamed', n; END IF;
END
$g$;

DROP TABLE d14_v19_pre;

COMMIT;
