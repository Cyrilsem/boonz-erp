-- PRD-048 §4.5 fix: spoilage cap MUST dominate the min_fill floor.
-- The literal §3 formula target=min(cap,max(round(S),floor)) lets the seller floor re-inflate a
-- perishable above mu*shelf_life*0.8 (S is already spoilage-capped, but floor is not). §4.5 requires
-- the spoilage cap to dominate -> cap the floor by round(spoilage_cap) when shelf_life is known.
-- Forward-only CREATE OR REPLACE (Article 12). Pure read-only helper; within Cody-approved shape.

CREATE OR REPLACE FUNCTION public.compute_base_stock_decision(
  p_v7 numeric, p_v30 numeric, p_oh int, p_cap int,
  p_trip_days int, p_z numeric, p_shelf_life_days numeric, p_wh_pickable int,
  p_min_fill_pct numeric, p_seller_wk_threshold numeric,
  p_ewma_w7 numeric, p_ewma_w30 numeric, p_spoilage_factor numeric,
  p_is_cold_start boolean DEFAULT false
) RETURNS jsonb
LANGUAGE sql IMMUTABLE
SET search_path TO 'public'
AS $function$
WITH b AS (
  SELECT
    GREATEST(COALESCE(p_cap,0),0)         AS cap,
    GREATEST(COALESCE(p_oh,0),0)          AS oh,
    GREATEST(COALESCE(p_wh_pickable,0),0) AS wh,
    COALESCE(p_v7,0)  AS v7,
    COALESCE(p_v30,0) AS v30,
    (COALESCE(p_v7,0)=0 AND COALESCE(p_v30,0)=0) AS no_vel,
    COALESCE(p_is_cold_start,false)       AS cold,
    GREATEST(COALESCE(p_trip_days,21),1)  AS tdays,
    COALESCE(p_z,1.65)                    AS z,
    p_shelf_life_days                     AS slife,
    COALESCE(p_min_fill_pct,0.70)         AS minfill,
    COALESCE(p_seller_wk_threshold,1.5)   AS sellwk,
    COALESCE(p_ewma_w7,0.7)               AS w7,
    COALESCE(p_ewma_w30,0.3)              AS w30,
    COALESCE(p_spoilage_factor,0.8)       AS spf
),
m AS (
  SELECT b.*, (b.w7*(b.v7/7.0) + b.w30*(b.v30/30.0)) AS mu_day FROM b
),
s AS (
  SELECT m.*,
    sqrt(GREATEST(m.mu_day,0)) AS sigma,
    (m.mu_day*7.0) >= m.sellwk AS is_seller,
    CASE WHEN m.slife IS NOT NULL THEN m.mu_day*m.slife*m.spf ELSE NULL END AS spoilage_cap
  FROM m
),
t AS (
  SELECT s.*, (s.mu_day*s.tdays + s.z*s.sigma*sqrt(s.tdays)) AS s_raw FROM s
),
sc AS (
  SELECT t.*,
    CASE WHEN t.spoilage_cap IS NOT NULL THEN LEAST(t.s_raw, t.spoilage_cap) ELSE t.s_raw END AS s_capped
  FROM t
),
calc AS (
  SELECT sc.*,
    CASE WHEN sc.is_seller THEN ceil(sc.minfill*sc.cap)::int ELSE 0 END AS floor_units,
    CASE
      WHEN sc.no_vel AND NOT sc.cold THEN 0
      WHEN sc.no_vel AND sc.cold     THEN LEAST(sc.cap, ceil(sc.minfill*sc.cap)::int)
      ELSE LEAST(sc.cap,
             GREATEST( round(sc.s_capped::numeric)::int,
                       CASE WHEN sc.is_seller THEN
                              CASE WHEN sc.spoilage_cap IS NOT NULL
                                   THEN LEAST(ceil(sc.minfill*sc.cap)::int, round(sc.spoilage_cap::numeric)::int)
                                   ELSE ceil(sc.minfill*sc.cap)::int END
                            ELSE 0 END ))
    END AS target
  FROM sc
),
fin AS (
  SELECT calc.*,
    GREATEST(calc.cap - calc.oh, 0)                              AS headroom,
    GREATEST(LEAST(calc.target,calc.cap) - calc.oh, 0)          AS want
  FROM calc
)
SELECT jsonb_build_object(
  'mode',          'base_stock',
  'mu_day',        round(mu_day::numeric,4),
  'sigma',         round(sigma::numeric,4),
  's_raw',         round(s_raw::numeric,3),
  'spoilage_cap',  CASE WHEN spoilage_cap IS NULL THEN NULL ELSE round(spoilage_cap::numeric,3) END,
  's_capped',      round(s_capped::numeric,3),
  'is_seller',     is_seller,
  'is_cold_start', cold,
  'is_dead',       (no_vel AND NOT cold),
  'floor',         floor_units,
  'cap',           cap,
  'target',        target,
  'headroom',      headroom,
  'want',          want,
  'add',           LEAST(want, wh),
  'wh_pickable',   wh,
  'z',             z,
  'trip_days',     tdays,
  'reason', CASE
     WHEN no_vel AND NOT cold                      THEN 'dead_zero'
     WHEN no_vel AND cold                          THEN 'cold_start_seed'
     WHEN oh >= target                             THEN 'at_or_above_target'
     WHEN LEAST(want, wh) < want                   THEN 'wh_limited'
     WHEN target >= cap                            THEN 'fill_to_cap'
     WHEN is_seller AND floor_units > round(s_capped::numeric)::int THEN 'seller_floor'
     ELSE 'base_stock_target' END
) FROM fin;
$function$;

COMMENT ON FUNCTION public.compute_base_stock_decision IS
  'PRD-048 pure service-level base-stock sizing (order-up-to S). §4.5: spoilage cap dominates the seller floor. All inputs passed -> IMMUTABLE, unit-testable. Called by engine_add_pod when refill_sizing_mode=base_stock.';