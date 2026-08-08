-- PRD-110 · leg 164 · D-40 · THE w_intents DIAL
--
-- CS ruling (2026-08-01): "ADD THE w_intents DIAL as its own Dara/Cody-reviewed unit, with a
-- monotonicity probe proving dial-controls-feature before the miner may map to it."
-- Dara design: docs/prds/PRD-110-D40-DARA-w-intents-design.md
-- Proof:       golden fixture 78 (RED 10/28 at 20260809040000, before this file).
--
-- The dial ships at 0. LAW 4: the live p_score set must be IDENTICAL across this migration,
-- pinned by IDENTITY (machine_id, p_score, urgency, p_tier), not by count - D-29's idiom.

-- ============================================================ 0. PRE-IMAGE ==
CREATE TEMP TABLE _d40_pre ON COMMIT DROP AS
  SELECT machine_id, p_score, urgency, p_tier FROM public.v_machine_priority;

CREATE TEMP TABLE _d40_ctx ON COMMIT DROP AS
  SELECT (SELECT count(*) FROM _d40_pre)                                        AS n_pre,
         (SELECT relacl::text FROM pg_class WHERE oid='public.pick_urgency_params'::regclass) AS acl_pre,
         (SELECT relrowsecurity FROM pg_class WHERE oid='public.pick_urgency_params'::regclass) AS rls_pre,
         (SELECT to_char(max(updated_at) AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS.US')
            FROM public.pick_urgency_params)                                    AS stamp_pre,
         (SELECT md5(pg_get_viewdef('graveyard.v_machine_service_priority'::regclass, true))) AS dep_pre,
         (SELECT count(*) FROM public.refill_plan_output)                       AS rpo_pre;

DO $g$
BEGIN
  IF (SELECT n_pre FROM _d40_ctx) < 20 THEN
    RAISE EXCEPTION 'D-40 PRE: v_machine_priority returned % rows, refusing to measure inertness against a fleet that small',
      (SELECT n_pre FROM _d40_ctx);
  END IF;
END $g$;

-- ============================================================== 1. THE DIAL ==
ALTER TABLE public.pick_urgency_params
  ADD COLUMN IF NOT EXISTS w_intents    numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS intents_norm numeric NOT NULL DEFAULT 3;

ALTER TABLE public.pick_urgency_params
  DROP CONSTRAINT IF EXISTS pick_urgency_params_intents_norm_check,
  DROP CONSTRAINT IF EXISTS pick_urgency_params_w_intents_check;

ALTER TABLE public.pick_urgency_params
  ADD CONSTRAINT pick_urgency_params_intents_norm_check CHECK (intents_norm > 0),
  ADD CONSTRAINT pick_urgency_params_w_intents_check    CHECK (w_intents >= 0);

COMMENT ON COLUMN public.pick_urgency_params.w_intents IS
  'D-40 (CS 2026-08-01). Weight on s_intents. SHIPPED AT 0 and never yet sanctioned at any '
  'other value: at 0 the term is arithmetically inert and every live p_score is byte-identical '
  'to the pre-D-40 view. CHECK (>= 0) on purpose - the measured direction lives in the TERM '
  '(s_intents is HIGH when FEW intents are open), not in the sign of this number. '
  'A dial at 0 also cannot be moved by the miner: proposals are multiplicative.';

COMMENT ON COLUMN public.pick_urgency_params.intents_norm IS
  'D-40. Open-intent count at which s_intents saturates to 0 (the machine reads as fully '
  'attended). CHECK (> 0) is what makes a zero divisor impossible in v_machine_priority.';

-- ============================================================== 2. THE TERM ==
-- s_intents is INTENT HEADROOM: 100 when nothing is open on the machine (nobody is on it),
-- falling to 0 at intents_norm open intents. Measured signal: CS DROPS machines carrying more
-- open intents (38.2% concordance over 1653 pairs = 61.8% inverse), so few intents = more
-- urgent. Same species as every sibling s_term: 0..100, non-negative weight.
--
-- ⛔⛔ NULL-PROOF BY CONSTRUCTION, AND THE INERT DIAL IS EXACTLY WHY IT MATTERS. 0 * NULL is
--     NULL, so a NULL s_intents would not contribute nothing at w_intents = 0 - it would
--     propagate through the whole weighted sum and take p_score, urgency and both tier gates
--     with it on every machine. NULLIF guards the divisor the CHECK already forbids; the
--     COALESCE(..., 1) turns an impossible norm into a 0 contribution rather than a NULL.
CREATE OR REPLACE VIEW public.v_machine_priority AS
 WITH shelf_u25 AS (
         SELECT vls.machine_id,
            count(*) FILTER (WHERE vls.is_enabled AND vls.current_stock > 0 AND vls.fill_pct < 25) AS under25
           FROM v_live_shelf_stock vls
          GROUP BY vls.machine_id
        ), shelf_graded AS (
         SELECT i.machine_id,
                CASE
                    WHEN i.dvel >= pp.a_floor THEN 'A'::text
                    WHEN i.dvel >= pp.b_floor THEN 'B'::text
                    WHEN i.dvel > 0::numeric THEN 'C'::text
                    ELSE 'D'::text
                END AS grade,
            i.dos,
            i.stock,
            i.cap,
                CASE
                    WHEN i.dvel >= pp.a_floor THEN pp.grade_wt_a
                    WHEN i.dvel >= pp.b_floor THEN pp.grade_wt_b
                    WHEN i.dvel > 0::numeric THEN pp.grade_wt_c
                    ELSE 0::numeric
                END * GREATEST(0::numeric, LEAST(1::numeric, (pp.horizon_days - COALESCE(i.dos, pp.horizon_days)) / pp.horizon_days)) * 100::numeric AS shelf_runout,
            i.dvel >= pp.a_floor AND i.dos < pp.horizon_days AS a_below,
            i.dvel >= pp.b_floor AND i.dos < pp.horizon_days AS ab_below,
            i.stock = 0 AS is_empty,
            COALESCE(i.stock > 0 AND (i.stock::numeric / NULLIF(i.cap, 0)::numeric * 100::numeric) < pp.low_fill_pct_floor, false) AS is_low,
                CASE
                    WHEN i.dvel >= pp.a_floor THEN pp.empty_wt_a
                    WHEN i.dvel >= pp.b_floor THEN pp.empty_wt_b
                    WHEN i.dvel > 0::numeric THEN pp.empty_wt_c
                    ELSE pp.empty_wt_d
                END AS empty_grade_mult
           FROM v_shelf_sales_identity i
             CROSS JOIN pick_urgency_params pp
        ), magg AS (
         SELECT shelf_graded.machine_id,
            count(*) FILTER (WHERE shelf_graded.grade = 'A'::text) AS a_count,
            count(*) FILTER (WHERE shelf_graded.grade = 'B'::text) AS b_count,
            count(*) FILTER (WHERE shelf_graded.grade = 'C'::text) AS c_count,
            count(*) FILTER (WHERE shelf_graded.grade = 'D'::text) AS d_count,
            min(shelf_graded.dos) FILTER (WHERE shelf_graded.grade = 'A'::text) AS soonest_a_dos,
            max(shelf_graded.shelf_runout) FILTER (WHERE shelf_graded.grade = ANY (ARRAY['A'::text, 'B'::text, 'C'::text])) AS worst_runout,
            avg(shelf_graded.shelf_runout) FILTER (WHERE shelf_graded.grade = ANY (ARRAY['A'::text, 'B'::text, 'C'::text])) AS breadth_runout,
            sum(shelf_graded.stock) FILTER (WHERE shelf_graded.grade = ANY (ARRAY['A'::text, 'B'::text, 'C'::text])) AS abc_stock,
            sum(shelf_graded.cap) FILTER (WHERE shelf_graded.grade = ANY (ARRAY['A'::text, 'B'::text, 'C'::text])) AS abc_cap,
            bool_or(shelf_graded.a_below) AS hero_below,
            bool_or(shelf_graded.ab_below) AS any_ab_below,
            count(*) AS graded_shelves,
            sum(shelf_graded.empty_grade_mult) FILTER (WHERE shelf_graded.is_empty) AS empty_mult_sum,
            sum(shelf_graded.empty_grade_mult) FILTER (WHERE shelf_graded.is_low) AS low_mult_sum,
            count(*) FILTER (WHERE shelf_graded.is_empty AND (shelf_graded.grade = ANY (ARRAY['A'::text, 'B'::text]))) AS empty_ab_count
           FROM shelf_graded
          GROUP BY shelf_graded.machine_id
        ), hole_agg AS (
         SELECT h.machine_id,
            count(*) FILTER (WHERE h.is_hole) AS holes_total,
            count(*) FILTER (WHERE h.is_hole AND h.grade = 'A'::text) AS holes_a,
            count(*) FILTER (WHERE h.is_hole AND h.grade = 'B'::text) AS holes_b,
            count(*) FILTER (WHERE h.is_hole AND h.grade = 'C'::text) AS holes_c,
            count(*) FILTER (WHERE h.is_hole AND h.grade = 'D'::text) AS holes_d,
            sum(h.hole_wt) FILTER (WHERE h.is_hole) AS hole_wt_sum
           FROM v_shelf_holes h
          GROUP BY h.machine_id
        ), mscore AS (
         SELECT s_1.machine_id,
            COALESCE(g.worst_runout, 0::numeric) * p_1.runout_worst_wt + COALESCE(g.breadth_runout, 0::numeric) * p_1.runout_breadth_wt AS s_runout,
            GREATEST(0::numeric, LEAST(100::numeric, (1::numeric - COALESCE(g.abc_stock, 0::numeric) / NULLIF(g.abc_cap, 0::numeric)) * 100::numeric)) AS s_capacity,
            LEAST(100::numeric, (p_1.expiry_weight_expired * s_1.expired_skus_now::numeric + p_1.expiry_weight_exp3d * s_1.expired_skus_3d::numeric) / p_1.expiry_norm * 100::numeric) AS s_expiry,
            GREATEST(0::numeric, LEAST(100::numeric, (s_1.days_since_visit::numeric - p_1.stale_grace_days) / NULLIF(p_1.stale_full_days - p_1.stale_grace_days, 0::numeric) * 100::numeric)) AS s_stale,
            100::numeric * COALESCE(g.empty_mult_sum, 0::numeric) / GREATEST(g.graded_shelves, 1::bigint)::numeric AS s_empty,
            100::numeric * COALESCE(g.low_mult_sum, 0::numeric) / GREATEST(g.graded_shelves, 1::bigint)::numeric AS s_lowfill,
            100::numeric * LEAST(1::numeric, COALESCE(ha.hole_wt_sum, 0::numeric) / NULLIF(p_1.holes_norm, 0::numeric)) AS s_holes,
            100::numeric * (1::numeric - LEAST(1::numeric, COALESCE(GREATEST(0::numeric, COALESCE(s_1.active_intent_count, 0)::numeric) / NULLIF(p_1.intents_norm, 0::numeric), 1::numeric))) AS s_intents,
            COALESCE(ha.holes_total, 0::bigint) AS holes_total,
            COALESCE(ha.holes_a, 0::bigint) AS holes_a,
            COALESCE(ha.holes_b, 0::bigint) AS holes_b,
            COALESCE(ha.holes_c, 0::bigint) AS holes_c,
            COALESCE(ha.holes_d, 0::bigint) AS holes_d,
            COALESCE(g.empty_ab_count, 0::bigint) AS empty_ab_count,
            COALESCE(g.hero_below, false) AS hero_below,
            COALESCE(g.any_ab_below, false) AS any_ab_below,
            COALESCE(g.a_count, 0::bigint) AS a_count,
            COALESCE(g.b_count, 0::bigint) AS b_count,
            COALESCE(g.c_count, 0::bigint) AS c_count,
            COALESCE(g.d_count, 0::bigint) AS d_count,
            g.soonest_a_dos
           FROM v_machine_health_signals s_1
             LEFT JOIN magg g ON g.machine_id = s_1.machine_id
             LEFT JOIN hole_agg ha ON ha.machine_id = s_1.machine_id
             CROSS JOIN pick_urgency_params p_1
        )
 SELECT s.machine_id,
    s.official_name,
    s.venue_group,
    s.location_type,
    s.building_id,
    s.dead_slot_pct,
    s.empty_shelf_pct,
    s.fill_pct,
    s.hero_slot_count,
    s.expired_skus_now,
    s.expired_skus_30d,
    s.days_since_visit,
    s.units_last_7d,
    s.is_ramping,
    s.active_intent_count,
    s.tier,
    s.empty_shelves_count,
    s.cur_stock,
    s.expired_skus_3d,
    s.expired_skus_7d,
    s.runway_days,
    m.include_in_refill,
    COALESCE(m.status, 'Active'::text) AS machine_status,
    COALESCE(u.under25, 0::bigint) AS under25,
        CASE
            WHEN s.venue_group = 'VOX'::text THEN 'vox'::text
            ELSE 'main'::text
        END AS svc_track,
        CASE
            WHEN ms.hero_below AND s.days_since_visit::numeric > p.cooldown_days OR s.days_since_visit::numeric > p.stale_override_days OR s.expired_skus_now >= p.p1_expired_min OR ms.empty_ab_count >= p.p1_empty_ab_min OR p.w_holes > 0::numeric AND (ms.holes_a >= 1 OR ms.holes_total >= p.p1_holes_min) OR (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill + p.w_holes * ms.s_holes + p.w_intents * ms.s_intents) >= p.p1_threshold THEN 'P1_RESTOCK'::text
            WHEN s.expired_skus_3d >= p.p2_exp3d_min OR ms.any_ab_below OR p.w_holes > 0::numeric AND ms.holes_total >= p.p2_holes_min OR (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill + p.w_holes * ms.s_holes + p.w_intents * ms.s_intents) >= p.p2_threshold THEN 'P2_MAINTAIN'::text
            ELSE 'P3_OK'::text
        END AS p_tier,
    (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill + p.w_holes * ms.s_holes + p.w_intents * ms.s_intents)::numeric(6,2) AS p_score,
    array_remove(ARRAY[
        CASE
            WHEN ms.hero_below AND s.days_since_visit::numeric > p.cooldown_days THEN 'hero_runout'::text
            ELSE NULL::text
        END,
        CASE
            WHEN s.days_since_visit::numeric > p.stale_override_days THEN 'stale_overdue'::text
            ELSE NULL::text
        END,
        CASE
            WHEN s.expired_skus_now >= p.p1_expired_min THEN 'expired_now'::text
            ELSE NULL::text
        END,
        CASE
            WHEN ms.empty_ab_count >= p.p1_empty_ab_min THEN 'hero_shelf_empty'::text
            ELSE NULL::text
        END,
        CASE
            WHEN s.expired_skus_3d >= p.p2_exp3d_min THEN 'expiring_soon'::text
            ELSE NULL::text
        END,
        CASE
            WHEN ms.any_ab_below THEN 'seller_below_horizon'::text
            ELSE NULL::text
        END,
        CASE
            WHEN ms.s_empty > 0::numeric THEN 'empty_shelves'::text
            ELSE NULL::text
        END,
        CASE
            WHEN ms.s_lowfill >= 20::numeric THEN 'low_fill_sellers'::text
            ELSE NULL::text
        END,
        CASE
            WHEN p.w_holes > 0::numeric AND ms.holes_a >= 1 THEN 'empty_hero_row'::text
            ELSE NULL::text
        END,
        CASE
            WHEN p.w_holes > 0::numeric AND ms.holes_total >= p.p1_holes_min THEN 'empty_rows_2plus'::text
            ELSE NULL::text
        END,
        CASE
            WHEN p.w_holes > 0::numeric AND ms.holes_total >= p.p2_holes_min THEN 'hole_row'::text
            ELSE NULL::text
        END,
        CASE
            WHEN (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill + p.w_holes * ms.s_holes + p.w_intents * ms.s_intents) >= p.p1_threshold THEN 'high_urgency'::text
            ELSE NULL::text
        END,
        CASE
            WHEN ms.s_capacity >= 50::numeric THEN 'low_capacity'::text
            ELSE NULL::text
        END], NULL::text) AS reasons_arr,
    COALESCE(s.venue_group, s.building_id, s.official_name) AS r_cluster,
    (p.w_runout * ms.s_runout + p.w_capacity * ms.s_capacity + p.w_expiry * ms.s_expiry + p.w_stale * ms.s_stale + p.w_empty * ms.s_empty + p.w_lowfill * ms.s_lowfill + p.w_holes * ms.s_holes + p.w_intents * ms.s_intents)::numeric(6,2) AS urgency,
    round(ms.soonest_a_dos, 2) AS soonest_a_dos,
    ms.a_count AS grade_a_count,
    ms.b_count AS grade_b_count,
    ms.c_count AS grade_c_count,
    ms.d_count AS grade_d_count,
    ms.s_empty::numeric(6,2) AS s_empty,
    ms.s_lowfill::numeric(6,2) AS s_lowfill,
    ms.empty_ab_count,
    ms.s_runout::numeric(6,2) AS s_runout,
    ms.s_capacity::numeric(6,2) AS s_capacity,
    ms.s_expiry::numeric(6,2) AS s_expiry,
    ms.s_stale::numeric(6,2) AS s_stale,
    ms.s_holes::numeric(6,2) AS s_holes,
    ms.holes_total,
    ms.holes_a,
    ms.holes_b,
    ms.holes_c,
    ms.holes_d,
    ms.s_intents::numeric(6,2) AS s_intents
   FROM v_machine_health_signals s
     JOIN machines m ON m.machine_id = s.machine_id
     LEFT JOIN shelf_u25 u ON u.machine_id = s.machine_id
     LEFT JOIN mscore ms ON ms.machine_id = s.machine_id
     CROSS JOIN pick_urgency_params p
;

-- ========================================================= 3. POST-IMAGE ==
DO $g$
DECLARE
  v_sites_runout  int;
  v_sites_intents int;
  v_def           text;
  v_diff          int;
  v_null_s        int;
  v_null_score    int;
  v_n_post        int;
BEGIN
  v_def := pg_get_viewdef('public.v_machine_priority'::regclass, true);

  -- ⭐ EQUALITY AGAINST A SIBLING TERM, NEVER A LITERAL. The parking lot recorded the weighted
  --   sum as occurring SIX times; pg_get_viewdef says FIVE. A hard-coded count would bless a
  --   view that later gains a site without the new term (S-299: an enumeration is a claim).
  v_sites_runout  := (length(v_def) - length(replace(v_def,'p.w_runout * ms.s_runout','')))
                     / length('p.w_runout * ms.s_runout');
  v_sites_intents := (length(v_def) - length(replace(v_def,'p.w_intents * ms.s_intents','')))
                     / length('p.w_intents * ms.s_intents');

  IF v_sites_runout = 0 OR v_sites_intents <> v_sites_runout THEN
    RAISE EXCEPTION 'D-40 POST: the new term is at % of % weighted-sum sites', v_sites_intents, v_sites_runout;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='v_machine_priority'
                    AND column_name='s_intents') THEN
    RAISE EXCEPTION 'D-40 POST: s_intents is summed but not exposed';
  END IF;

  SELECT count(*), count(*) FILTER (WHERE s_intents IS NULL), count(*) FILTER (WHERE p_score IS NULL)
    INTO v_n_post, v_null_s, v_null_score
    FROM public.v_machine_priority;

  IF v_null_s <> 0 OR v_null_score <> 0 THEN
    RAISE EXCEPTION 'D-40 POST: % null s_intents, % null p_score - the 0*NULL trap fired', v_null_s, v_null_score;
  END IF;

  IF v_n_post <> (SELECT n_pre FROM _d40_ctx) THEN
    RAISE EXCEPTION 'D-40 POST: row count moved % -> %', (SELECT n_pre FROM _d40_ctx), v_n_post;
  END IF;

  -- ⛔ LAW 4, BY IDENTITY. Not "the count matched" - every machine returns the same score,
  --    the same urgency and the same tier. FULL OUTER so a machine appearing or vanishing
  --    counts as a difference rather than as an empty join.
  SELECT count(*) INTO v_diff
    FROM _d40_pre a
    FULL OUTER JOIN public.v_machine_priority b ON b.machine_id = a.machine_id
   WHERE a.machine_id IS NULL OR b.machine_id IS NULL
      OR a.p_score IS DISTINCT FROM b.p_score
      OR a.urgency IS DISTINCT FROM b.urgency
      OR a.p_tier  IS DISTINCT FROM b.p_tier;

  IF v_diff <> 0 THEN
    RAISE EXCEPTION 'D-40 POST: % machines changed score/urgency/tier at w_intents = 0 - the dial is not inert', v_diff;
  END IF;

  -- the dial actually shipped at 0, and the norm at its designed default
  IF (SELECT w_intents FROM public.pick_urgency_params ORDER BY id LIMIT 1) <> 0 THEN
    RAISE EXCEPTION 'D-40 POST: w_intents did not ship at 0';
  END IF;
  IF (SELECT intents_norm FROM public.pick_urgency_params ORDER BY id LIMIT 1) <> 3 THEN
    RAISE EXCEPTION 'D-40 POST: intents_norm did not ship at 3';
  END IF;

  -- Article 2/3: the grant surface and RLS state of the params table are untouched
  IF (SELECT relacl::text FROM pg_class WHERE oid='public.pick_urgency_params'::regclass)
     IS DISTINCT FROM (SELECT acl_pre FROM _d40_ctx) THEN
    RAISE EXCEPTION 'D-40 POST: pick_urgency_params grants moved';
  END IF;
  IF (SELECT relrowsecurity FROM pg_class WHERE oid='public.pick_urgency_params'::regclass)
     IS DISTINCT FROM (SELECT rls_pre FROM _d40_ctx) THEN
    RAISE EXCEPTION 'D-40 POST: pick_urgency_params RLS state moved';
  END IF;

  -- S-138 / fixture 58 seq 33: ADD COLUMN must not restamp the row CS last wrote
  IF (SELECT to_char(max(updated_at) AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS.US')
        FROM public.pick_urgency_params) IS DISTINCT FROM (SELECT stamp_pre FROM _d40_ctx) THEN
    RAISE EXCEPTION 'D-40 POST: pick_urgency_params.updated_at moved - fixture 58 seq 33 would redden';
  END IF;

  -- Article 7: the ONLY dependent object survives with an unchanged definition. ⛔ It lives in
  -- the `graveyard` schema, not in `public` - a retired view still holding a rewrite dependency
  -- on v_machine_priority. A pg_depend probe that reads relname without nspname says "public"
  -- and is wrong; this one names the schema, and CREATE OR REPLACE still has to keep every
  -- existing column's name, type and POSITION for the graveyard view's sake.
  IF (SELECT md5(pg_get_viewdef('graveyard.v_machine_service_priority'::regclass, true)))
     IS DISTINCT FROM (SELECT dep_pre FROM _d40_ctx) THEN
    RAISE EXCEPTION 'D-40 POST: v_machine_service_priority changed';
  END IF;

  -- LAW 12
  IF (SELECT count(*) FROM public.refill_plan_output) <> (SELECT rpo_pre FROM _d40_ctx) THEN
    RAISE EXCEPTION 'D-40 POST: refill_plan_output row count moved';
  END IF;

  RAISE NOTICE 'D-40 ok: term at %/% sites, % machines identical at w_intents = 0',
    v_sites_intents, v_sites_runout, v_n_post;
END $g$;
