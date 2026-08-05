-- PRD-110 P2.2a migration 2/3 — golden fixture 28, "Base-stock policy resolver (P2.2 inputs)".
-- LAW 1: the fixture precedes its subject. v_machine_base_stock_policy_v3 does NOT exist when
-- this lands, so the scenario guards with to_regclass and reads the view via dynamic EXECUTE —
-- a static reference would fail at PLAN time and land as a scenario_error (S-33) instead of a
-- clean, recorded red.
--
-- Assertions are drift-proof by construction: each one re-derives independently and asserts
-- MISMATCH = 0, rather than pinning today's counts (visits accrue nightly; a "= 30" would rot).
-- RISK 90: every assertion keys on something the fixture controls, never on winning a race with
-- cron 13/44.

DELETE FROM golden.assertions WHERE fixture_id = 28;
DELETE FROM golden.fixtures   WHERE fixture_id = 28;

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes, enabled, baseline_status)
VALUES (28,
 'Base-stock policy resolver (P2.2 inputs)',
 'PRD-110 S-43: machine_service_policy.trip_interval_days is a 2026-06-21 seed that overstates measured cadence on all 30 machines that have one (mean 3.67x). An inflated L inflates S, fill_to_cap absorbs it, and v3 degenerates to always-max-fill with no error, no qty-0 and no anomalous clamp_reason.',
 'P2', DATE '2030-01-28',
$scenario$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
DO $fx28$
DECLARE
  v_payload      jsonb;
  v_rows         bigint;
  v_scope_mm     bigint;
  v_null_iv      bigint;
  v_null_z       bigint;
  v_null_lead    bigint;
  v_null_hz      bigint;
  v_unnamed_src  bigint;
  v_unnamed_zsrc bigint;
  v_iv_mm        bigint;
  v_pol_mm       bigint;
  v_min_hz       numeric;
  v_max_hz       numeric;
  v_cap          numeric;
  v_amz_rows     bigint;
  v_amz_src      text;
  v_diverge      bigint;
  v_manual_ev    bigint;
BEGIN
  IF to_regclass('public.v_machine_base_stock_policy_v3') IS NULL THEN
    INSERT INTO golden.scratch (fixture_id, key, value)
    VALUES ({{fixture_id}}, 'obs', jsonb_build_object('view_exists','false'));
    RETURN;
  END IF;

  -- The fixture's OWN re-derivation. Deliberately written out in full rather than reusing the
  -- view, so that a later edit to the view which changes its meaning is caught rather than
  -- mirrored. Visit vocabulary is the CANONICAL one (Article 16, METRICS_REGISTRY "Days since
  -- visit"): dispatch evidence (NOT cancelled, NOT skipped) UNION manual-refill/adjust audit
  -- refs, joined on pod_inventory_audit_log.machine_id DIRECTLY (never through pod_inventory).
  CREATE TEMP TABLE fx28_exp ON COMMIT DROP AS
  WITH p AS (
    SELECT base_stock_lead_days AS lead_d, base_stock_default_interval_days AS def_iv,
           base_stock_min_gaps AS min_g, base_stock_cadence_lookback_days AS look,
           base_stock_max_horizon_days AS max_h, base_stock_interval_precedence AS prec, z_mid
      FROM public.refill_policy_params LIMIT 1),
  scope AS (SELECT DISTINCT machine_id FROM public.v_shelf_state WHERE pod_product_id IS NOT NULL),
  disp AS (
    SELECT DISTINCT rd.machine_id, rd.dispatch_date AS d
      FROM public.refill_dispatching rd JOIN scope s USING (machine_id) CROSS JOIN p
     WHERE rd.cancelled = false AND rd.skipped = false
       AND (rd.picked_up = true OR rd.returned = true OR rd.dispatched = true OR rd.packed = true)
       AND rd.dispatch_date >= CURRENT_DATE - p.look AND rd.dispatch_date <= CURRENT_DATE),
  man AS (
    SELECT DISTINCT pal.machine_id, pal.created_at::date AS d
      FROM public.pod_inventory_audit_log pal JOIN scope s USING (machine_id) CROSS JOIN p
     WHERE (pal.reference_id LIKE 'manual-refill-%' OR pal.reference_id LIKE 'adjust-%')
       AND pal.created_at::date >= CURRENT_DATE - p.look),
  allv AS (SELECT machine_id, d FROM disp UNION SELECT machine_id, d FROM man),
  g    AS (SELECT machine_id, (d - LAG(d) OVER (PARTITION BY machine_id ORDER BY d))::numeric AS gap FROM allv),
  o    AS (SELECT machine_id, count(gap)::int AS n,
                  percentile_cont(0.5) WITHIN GROUP (ORDER BY gap)::numeric AS med
             FROM g WHERE gap IS NOT NULL GROUP BY machine_id),
  dg   AS (SELECT machine_id, (d - LAG(d) OVER (PARTITION BY machine_id ORDER BY d))::numeric AS gap FROM disp),
  od   AS (SELECT machine_id, count(gap)::int AS n,
                  percentile_cont(0.5) WITHIN GROUP (ORDER BY gap)::numeric AS med
             FROM dg WHERE gap IS NOT NULL GROUP BY machine_id),
  r AS (
    SELECT s.machine_id, p.lead_d, p.def_iv, p.max_h, p.z_mid,
           msp.trip_interval_days::numeric AS pol_iv, msp.z_default,
           o.med AS full_med, COALESCE(o.n,0) AS n_gaps, od.med AS disp_med,
           CASE WHEN p.prec = 'policy_first'
                THEN CASE WHEN msp.trip_interval_days IS NOT NULL THEN 'policy_seed'
                          WHEN COALESCE(o.n,0) >= p.min_g          THEN 'observed'
                          ELSE 'param_default' END
                ELSE CASE WHEN COALESCE(o.n,0) >= p.min_g          THEN 'observed'
                          WHEN msp.trip_interval_days IS NOT NULL  THEN 'policy_seed'
                          ELSE 'param_default' END
           END AS exp_source
      FROM scope s CROSS JOIN p
      LEFT JOIN public.machine_service_policy msp ON msp.machine_id = s.machine_id
      LEFT JOIN o  ON o.machine_id  = s.machine_id
      LEFT JOIN od ON od.machine_id = s.machine_id)
  SELECT r.*,
         CASE r.exp_source WHEN 'observed' THEN r.full_med
                           WHEN 'policy_seed' THEN r.pol_iv
                           ELSE r.def_iv END AS exp_iv,
         COALESCE(r.z_default, r.z_mid) AS exp_z
    FROM r;

  EXECUTE 'CREATE TEMP TABLE fx28_act ON COMMIT DROP AS SELECT * FROM public.v_machine_base_stock_policy_v3';

  SELECT count(*) INTO v_rows FROM fx28_act;

  SELECT count(*) INTO v_scope_mm
    FROM (SELECT machine_id FROM fx28_act EXCEPT SELECT machine_id FROM fx28_exp
          UNION ALL
          SELECT machine_id FROM fx28_exp EXCEPT SELECT machine_id FROM fx28_act) q;

  SELECT count(*) FILTER (WHERE visit_interval_days IS NULL),
         count(*) FILTER (WHERE z IS NULL),
         count(*) FILTER (WHERE lead_days IS NULL),
         count(*) FILTER (WHERE horizon_days IS NULL),
         count(*) FILTER (WHERE interval_source IS NULL
                             OR interval_source NOT IN ('observed','policy_seed','param_default')),
         count(*) FILTER (WHERE z_source IS NULL OR z_source NOT IN ('machine_service_policy','param_z_mid')),
         min(horizon_days), max(horizon_days)
    INTO v_null_iv, v_null_z, v_null_lead, v_null_hz, v_unnamed_src, v_unnamed_zsrc, v_min_hz, v_max_hz
    FROM fx28_act;

  SELECT count(*) INTO v_iv_mm
    FROM fx28_act a JOIN fx28_exp e USING (machine_id)
   WHERE a.interval_source     IS DISTINCT FROM e.exp_source
      OR a.visit_interval_days IS DISTINCT FROM e.exp_iv
      OR a.z                   IS DISTINCT FROM e.exp_z
      OR a.horizon_days        IS DISTINCT FROM LEAST(GREATEST(e.exp_iv + e.lead_d, 1), e.max_h);

  SELECT count(*) INTO v_pol_mm
    FROM fx28_act a JOIN fx28_exp e USING (machine_id)
   WHERE a.policy_trip_interval_days IS DISTINCT FROM e.pol_iv;

  SELECT base_stock_max_horizon_days INTO v_cap FROM public.refill_policy_params LIMIT 1;

  SELECT count(*), min(a.interval_source) INTO v_amz_rows, v_amz_src
    FROM fx28_act a WHERE a.machine_name = 'AMZ-1046-2406-O1';

  -- S-43 non-vacuity guard: if the seed is ever corrected this goes red ON PURPOSE and must be
  -- re-phased, not deleted.
  SELECT count(*) INTO v_diverge
    FROM fx28_exp e WHERE e.exp_source = 'observed' AND e.pol_iv IS DISTINCT FROM e.full_med;

  -- Article 16 regression guard: proves the resolver is on the CANONICAL visit vocabulary and
  -- not a dispatch-only re-derivation. Measured 2026-07-31: 13 machines, every one of them
  -- shorter under the canonical definition (max 1.60x overstatement).
  SELECT count(*) INTO v_manual_ev
    FROM fx28_exp e WHERE e.disp_med IS DISTINCT FROM e.full_med;

  v_payload := jsonb_build_object(
    'view_exists','true',
    'rows',                v_rows::text,
    'scope_mismatch',      v_scope_mm::text,
    'null_interval',       v_null_iv::text,
    'null_z',              v_null_z::text,
    'null_lead',           v_null_lead::text,
    'null_horizon',        v_null_hz::text,
    'unnamed_interval_source', v_unnamed_src::text,
    'unnamed_z_source',    v_unnamed_zsrc::text,
    'interval_mismatch',   v_iv_mm::text,
    'policy_passthrough_mismatch', v_pol_mm::text,
    'min_horizon',         v_min_hz::text,
    'horizon_over_cap',    (CASE WHEN v_max_hz > v_cap THEN 1 ELSE 0 END)::text,
    'amz_rows',            v_amz_rows::text,
    'amz_interval_source', COALESCE(v_amz_src,'<none>'),
    'divergence_machines', v_diverge::text,
    'manual_evidence_machines', v_manual_ev::text);

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'obs', v_payload);
END
$fx28$;
$scenario$,
 'P2.2a. Pins the base-stock policy resolver contract: scope, three-tier interval precedence with a NAMED source, z provenance, horizon clamp. Reads nothing but the view + its own re-derivation; writes only golden.scratch. Article 16: the observed cadence uses the CANONICAL visit vocabulary (dispatch evidence UNION manual-refill/adjust), matching v_machine_health_signals.days_since_visit.',
 true, 'failing_expected');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES
(28, 1, 'The resolver view exists at all (red until migration 3/3 lands — this is the recorded LAW-1 baseline)',
 $c$SELECT value->>'view_exists' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'eq', 'true', true, 'P2'),
(28, 2, 'NON-VACUITY: the resolver returns rows at all, so every mismatch=0 assertion below is earned rather than vacuous',
 $c$SELECT value->>'rows' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'gt', '0', true, 'P2'),
(28, 3, 'SCOPE: exactly one row per in-scope pod-bound machine — no machine dropped, none invented (symmetric EXCEPT, drift-proof)',
 $c$SELECT value->>'scope_mismatch' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'eq', '0', true, 'P2'),
(28, 4, 'LAW 5: no machine resolves to a NULL visit_interval_days (a NULL interval is a silent starve)',
 $c$SELECT value->>'null_interval' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'eq', '0', true, 'P2'),
(28, 5, 'LAW 5: no machine resolves to a NULL z (RISK 91 — a vanished z silently strips safety stock fleet-wide)',
 $c$SELECT value->>'null_z' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'eq', '0', true, 'P2'),
(28, 6, 'LAW 5: no machine resolves to a NULL lead_days',
 $c$SELECT value->>'null_lead' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'eq', '0', true, 'P2'),
(28, 7, 'LAW 5: no machine resolves to a NULL horizon_days',
 $c$SELECT value->>'null_horizon' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'eq', '0', true, 'P2'),
(28, 8, 'LAW 6: interval_source NAMES which tier fired — always one of observed / policy_seed / param_default, never invented',
 $c$SELECT value->>'unnamed_interval_source' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'eq', '0', true, 'P2'),
(28, 9, 'LAW 6: z_source NAMES its origin (machine_service_policy or param_z_mid)',
 $c$SELECT value->>'unnamed_z_source' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'eq', '0', true, 'P2'),
(28, 10, 'CONTRACT: interval, source, z and the horizon clamp all match the fixture''s INDEPENDENT re-derivation on every machine',
 $c$SELECT value->>'interval_mismatch' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'eq', '0', true, 'P2'),
(28, 11, 'CONTRACT: policy_trip_interval_days is a faithful passthrough of machine_service_policy — the view reports the seed it did not use',
 $c$SELECT value->>'policy_passthrough_mismatch' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'eq', '0', true, 'P2'),
(28, 12, 'HORIZON FLOOR: no machine gets a horizon below 1 day (a 0-day horizon would zero every base-stock target)',
 $c$SELECT value->>'min_horizon' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'gte', '1', true, 'P2'),
(28, 13, 'HORIZON CEILING: base_stock_max_horizon_days is honoured — a pathological cadence cannot inflate S without bound',
 $c$SELECT value->>'horizon_over_cap' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'eq', '0', true, 'P2'),
(28, 14, 'THIRD TIER IS MANDATORY: AMZ-1046-2406-O1 (16 pod-bound shelves) resolves to exactly one row — it has NEITHER a service policy NOR a measurable cadence',
 $c$SELECT value->>'amz_rows' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'eq', '1', true, 'P2'),
(28, 15, 'THIRD TIER FIRES: AMZ falls to param_default, not to a NULL and not to a borrowed seed — two tiers would starve 16 shelves silently',
 $c$SELECT value->>'amz_interval_source' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'eq', 'param_default', true, 'P2'),
(28, 16, 'S-43 NON-VACUITY: observed cadence still disagrees with the seeded trip_interval_days on at least one machine. If the seed is ever curated this goes red ON PURPOSE — re-phase it, never delete it',
 $c$SELECT value->>'divergence_machines' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'gt', '0', true, 'P2'),
(28, 17, 'ARTICLE 16 REGRESSION GUARD: the cadence is built on the CANONICAL visit vocabulary. At least one machine''s interval differs from a dispatch-only derivation — if this goes red, someone dropped the manual-refill leg and every such machine silently over-fills',
 $c$SELECT value->>'manual_evidence_machines' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$c$, 'gt', '0', true, 'P2');
