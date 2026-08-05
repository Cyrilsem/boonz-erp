-- PRD-110 P4.3c — G12 acceptance-rate telemetry
-- Dara design + Cody review (leg 88). Read-only object; no protected entity is written.
-- Articles: 2 (security_invoker), 4 (INVOKER helper, validated), 12 (forward-only),
--           14 (no snapshot table), 16 (new canonical metric, registry entry same unit).

------------------------------------------------------------------ (1) params --
ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS g12_bar_pct       numeric(5,2) NOT NULL DEFAULT 60.00,
  ADD COLUMN IF NOT EXISTS g12_min_decided   integer      NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS g12_fixture_epoch date         NOT NULL DEFAULT DATE '2030-01-01';

COMMENT ON COLUMN public.refill_policy_params.g12_bar_pct IS
  'PRD-110 G12 bar. INCLUSIVE: acceptance_pct >= bar is a pass. S-137 - the object owns the boundary, it does not discover it.';
COMMENT ON COLUMN public.refill_policy_params.g12_min_decided IS
  'Below this many DECIDED proposals an acceptance rate is not evidence at any value; verdict is insufficient_evidence, never fail.';
COMMENT ON COLUMN public.refill_policy_params.g12_fixture_epoch IS
  'Dates >= this belong to the golden harness synthetic universe (LAW 12 2030 convention). HORIZON WARNING: revisit well before 2030-01-01 or live proposals begin classifying as fixture rows.';

--------------------------------------------------------- (2) verdict helper --
-- IMMUTABLE and data-free on purpose: every branch is unit-testable without
-- planting a single proposal. SECURITY INVOKER (Cody class (c) - DEFINER was
-- not justified, so the safer default stands).
CREATE OR REPLACE FUNCTION public.g12_verdict_v3(
  p_accepted    int,
  p_decided     int,
  p_min_decided int,
  p_bar_pct     numeric
) RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    -- ⛔ Cody (leg 88): a NULL bar must NOT fall through to 'fail'.
    --    (100.0*a/d) >= NULL is NULL, which is not TRUE, so a bare ELSE would
    --    render a missing threshold as "the miner is noise". S-126 in a new organ.
    WHEN p_accepted IS NULL OR p_decided IS NULL
      OR p_bar_pct IS NULL OR p_min_decided IS NULL   THEN 'insufficient_evidence'
    -- S-137: report the contradiction, never RAISE. A correct invariant that
    -- throws inside a view is a crash path for every consumer of that view.
    WHEN p_accepted < 0 OR p_decided < 0
      OR p_accepted > p_decided                       THEN 'incoherent'
    WHEN p_decided = 0 OR p_decided < p_min_decided   THEN 'insufficient_evidence'
    WHEN (100.0 * p_accepted / p_decided) >= p_bar_pct THEN 'pass'
    ELSE 'fail'
  END;
$$;

COMMENT ON FUNCTION public.g12_verdict_v3(int, int, int, numeric) IS
  'PRD-110 G12 verdict. Domain: insufficient_evidence | incoherent | pass | fail. Zero evidence is NOT a failing grade - that distinction is the whole point of the object.';

REVOKE ALL ON FUNCTION public.g12_verdict_v3(int, int, int, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.g12_verdict_v3(int, int, int, numeric) FROM anon;
GRANT EXECUTE ON FUNCTION public.g12_verdict_v3(int, int, int, numeric)
  TO authenticated, service_role;

------------------------------------------------------------- (3) the view ----
CREATE OR REPLACE VIEW public.v_proposal_acceptance_v3
WITH (security_invoker = true) AS
WITH p AS (
  -- ⛔ Cody (leg 88): ORDER BY id. One row by convention, not by structure -
  --    there is no constraint forcing it (S-138's shape).
  SELECT g12_bar_pct, g12_min_decided, g12_fixture_epoch
    FROM public.refill_policy_params ORDER BY id LIMIT 1
),
fam(family, miner, in_g12_scope, sort_order) AS (
  VALUES ('feedback_pins',  'mine_edit_history_v3', true,  1),
         ('picker_weights', 'mine_pick_history_v3', true,  2),
         ('rotation',       NULL,                   false, 3),
         ('facing',         NULL,                   false, 4),
         ('reallocation',   NULL,                   false, 5)
),
u AS (
  SELECT 'feedback_pins'::text AS family, status, plan_date    AS ref_date FROM public.feedback_proposals_v3
  UNION ALL SELECT 'picker_weights', status, window_start FROM public.picker_weight_proposals_v3
  UNION ALL SELECT 'rotation',       status, plan_date    FROM public.rotation_proposals_v3
  UNION ALL SELECT 'facing',         status, plan_date    FROM public.facing_proposals_v3
  UNION ALL SELECT 'reallocation',   status, plan_date    FROM public.reallocation_proposals_v3
),
c AS (
  SELECT u.family,
         (u.ref_date >= p.g12_fixture_epoch) AS is_fixture,
         CASE u.status
           WHEN 'pending'    THEN 'undecided'
           WHEN 'proposed'   THEN 'undecided'
           -- an offer that matched no target was never put to CS: not a decision
           WHEN 'unclaimed'  THEN 'unmatched'
           WHEN 'approved'   THEN 'accepted'
           WHEN 'applied'    THEN 'accepted'
           WHEN 'rejected'   THEN 'rejected'
           -- left the queue without a CS judgement: neither numerator nor denominator
           WHEN 'superseded' THEN 'withdrawn'
           WHEN 'expired'    THEN 'withdrawn'
           -- ⛔ NEVER remove this arm. A CASE with no ELSE silently drops any
           --    status a future migration adds, and the rate moves with no error.
           ELSE 'unmapped'
         END AS bucket
  FROM u CROSS JOIN p
),
g AS (
  SELECT fam.family, fam.miner, fam.in_g12_scope, fam.sort_order,
         p.g12_bar_pct, p.g12_min_decided, p.g12_fixture_epoch,
         count(c.family)::int                                                        AS total_rows,
         count(*) FILTER (WHERE c.family IS NOT NULL AND NOT c.is_fixture)::int      AS live_rows,
         count(*) FILTER (WHERE c.is_fixture)::int                                   AS fixture_rows,
         count(*) FILTER (WHERE NOT c.is_fixture AND c.bucket='accepted')::int       AS live_accepted,
         count(*) FILTER (WHERE NOT c.is_fixture AND c.bucket='rejected')::int       AS live_rejected,
         count(*) FILTER (WHERE NOT c.is_fixture AND c.bucket='undecided')::int      AS live_undecided,
         count(*) FILTER (WHERE NOT c.is_fixture AND c.bucket='unmatched')::int      AS live_unmatched,
         count(*) FILTER (WHERE NOT c.is_fixture AND c.bucket='withdrawn')::int      AS live_withdrawn,
         count(*) FILTER (WHERE NOT c.is_fixture AND c.bucket='unmapped')::int       AS live_unmapped,
         count(*) FILTER (WHERE c.is_fixture AND c.bucket='accepted')::int           AS fixture_accepted,
         count(*) FILTER (WHERE c.is_fixture AND c.bucket='rejected')::int           AS fixture_rejected,
         count(*) FILTER (WHERE c.is_fixture AND c.bucket='undecided')::int          AS fixture_undecided,
         count(*) FILTER (WHERE c.is_fixture AND c.bucket='unmatched')::int          AS fixture_unmatched,
         count(*) FILTER (WHERE c.is_fixture AND c.bucket='withdrawn')::int          AS fixture_withdrawn,
         count(*) FILTER (WHERE c.is_fixture AND c.bucket='unmapped')::int           AS fixture_unmapped
    FROM fam CROSS JOIN p LEFT JOIN c ON c.family = fam.family
   GROUP BY fam.family, fam.miner, fam.in_g12_scope, fam.sort_order,
            p.g12_bar_pct, p.g12_min_decided, p.g12_fixture_epoch
)
SELECT
  family, miner, in_g12_scope,
  total_rows, live_rows, fixture_rows,
  live_accepted, live_rejected, live_undecided, live_unmatched, live_withdrawn, live_unmapped,
  (live_accepted + live_rejected)                                                    AS live_decided,
  CASE WHEN (live_accepted + live_rejected) = 0 THEN NULL
       ELSE round(100.0 * live_accepted / (live_accepted + live_rejected), 2)
  END                                                                                AS live_acceptance_pct,
  public.g12_verdict_v3(live_accepted, live_accepted + live_rejected,
                        g12_min_decided, g12_bar_pct)                                AS live_verdict,
  fixture_accepted, fixture_rejected, fixture_undecided, fixture_unmatched,
  fixture_withdrawn, fixture_unmapped,
  (fixture_accepted + fixture_rejected)                                              AS fixture_decided,
  CASE WHEN (fixture_accepted + fixture_rejected) = 0 THEN NULL
       ELSE round(100.0 * fixture_accepted / (fixture_accepted + fixture_rejected), 2)
  END                                                                                AS fixture_acceptance_pct,
  -- the gate that was actually applied, published rather than hidden in config
  g12_bar_pct, g12_min_decided, g12_fixture_epoch,
  -- the object's own miscount detector: every row must land in exactly one bucket
  ( live_accepted + live_rejected + live_undecided + live_unmatched + live_withdrawn + live_unmapped
  + fixture_accepted + fixture_rejected + fixture_undecided + fixture_unmatched
  + fixture_withdrawn + fixture_unmapped = total_rows )                              AS bucket_sum_ok
FROM g
ORDER BY sort_order;

COMMENT ON VIEW public.v_proposal_acceptance_v3 IS
  'PRD-110 P4.3 G12 acceptance-rate telemetry. CANONICAL object for proposal acceptance (Article 16). One row per proposal family, ALWAYS five rows (fam is a VALUES list LEFT JOINed to the data, so an empty queue renders as zero-proposals-ever rather than vanishing). Live and fixture (synthetic >= g12_fixture_epoch) populations are computed SIDE BY SIDE and never collapsed - S-139: when a number could count two populations, publish both. in_g12_scope marks the two miner-fed queues; the three P3 proposer queues are reported, not graded.';

REVOKE ALL ON public.v_proposal_acceptance_v3 FROM PUBLIC;
REVOKE ALL ON public.v_proposal_acceptance_v3 FROM anon;
GRANT SELECT ON public.v_proposal_acceptance_v3 TO authenticated, service_role;
