-- PRD-110 P2 / D-12 · THE NIGHTLY SHADOW DIFF (v3 shadow vs v19 live)
--
-- BUILD SPEC P2 tail: "Runs in SHADOW: writes to pod_refill_plan_shadow; nightly diff vs v19
-- (units, lines, blocked, per-machine) + WMAPE tracking."
--
-- ⛔ WHY NEW OBJECTS RATHER THAN FIXING v_shadow_vs_live_plan_v3 (measured, leg 51):
--   That view reads `pod_refill_plan_shadow` FULL JOIN `pod_refill_plan` — the PLAN grain.
--   `engine_add_pod_v3`'s only INSERT target is `pod_refills_shadow` — the ADVISORY grain
--   (ADR §9 addendum: the sibling shadow table landed at P2, not P3.1, because every gated
--   Phase-2 acceptance assertion reads pod_refills / blocked_demand, never pod_refill_plan).
--   So the plan-grain view can never return a row before cutover, and "0 differences" from it
--   would read as PARITY. Golden fixture 34 seq 60/61 pin that emptiness as by-design.
--   The plan-grain view is NOT dropped (Article 12, forward-only) and gains a warning comment.
--   It becomes live and correct at cutover, when v3 writes plan rows.
--
-- ADR-shadow-plan-tables §2: "The nightly diff (v3 shadow vs v19 live) is a VIEW over this
-- table joined to [the live table], not a second materialization." Article 14's first clause
-- genuinely binds here — the inputs are already durable and immutable, so a view suffices and
-- a table would be the unconstitutional choice. Same reasoning as v_blocked_demand_shadow_v3.
--
-- Cody, class (a) DDL: Art 1 no writer (read-only views) · Art 2/3 security_invoker = true,
-- anon REVOKEd · Art 12 forward-only, three new objects, nothing dropped or redefined ·
-- Art 14 view-not-table, per ADR §2 · Art 16 registered in METRICS_REGISTRY as the canonical
-- "v3 vs v19 shadow diff" object, explicitly disjoint from the plan-grain view.
--
-- PROVEN BY: golden fixture 34 (44 assertions), which recomputes every number below
-- independently from the base tables and requires these views to reproduce all of them.
-- Baseline before this migration: 16 pass / 28 fail / 0 errors.

-- =======================================================================================
-- 1. LINE GRAIN — one row per (plan_date, machine, shelf, pod_product) on EITHER side.
-- =======================================================================================
CREATE VIEW public.v_engine_diff_v3
WITH (security_invoker = true) AS
WITH latest AS (
  -- ONE shadow run per plan_date: the latest by produced_at. 117 runs exist across the
  -- synthetic dates; unioning them would multiply every count silently. run_id breaks
  -- produced_at ties deterministically so the view is stable between reads.
  SELECT DISTINCT ON (sh.plan_date)
         sh.plan_date, sh.run_id, sh.engine_tag, sh.produced_at
    FROM public.pod_refills_shadow sh
   ORDER BY sh.plan_date, sh.produced_at DESC, sh.run_id
), s AS (
  SELECT sh.plan_date, sh.machine_id, sh.shelf_id, sh.pod_product_id,
         sh.qty, sh.current_stock, sh.max_stock, sh.days_cover, sh.signal,
         sh.clamp_reason, sh.wh_available_pod, sh.velocity_instock, sh.availability_basis,
         sh.reasoning, l.run_id, l.engine_tag, l.produced_at
    FROM public.pod_refills_shadow sh
    JOIN latest l ON l.plan_date = sh.plan_date AND l.run_id = sh.run_id
), v AS (
  SELECT p.plan_date, p.machine_id, p.shelf_id, p.pod_product_id,
         p.qty, p.current_stock, p.max_stock, p.days_cover, p.signal,
         p.clamp_reason, p.wh_available_pod, p.velocity_30d
    FROM public.pod_refills p
   WHERE p.plan_date IN (SELECT latest.plan_date FROM latest)
)
SELECT COALESCE(s.plan_date, v.plan_date)             AS plan_date,
       COALESCE(s.machine_id, v.machine_id)           AS machine_id,
       COALESCE(s.shelf_id, v.shelf_id)               AS shelf_id,
       COALESCE(s.pod_product_id, v.pod_product_id)   AS pod_product_id,
       s.run_id, s.engine_tag, s.produced_at,
       s.qty                                          AS qty_v3,
       v.qty                                          AS qty_v19,
       COALESCE(s.qty, 0) - COALESCE(v.qty, 0)        AS qty_delta,
       abs(COALESCE(s.qty, 0) - COALESCE(v.qty, 0))   AS abs_qty_delta,
       -- The four buckets partition the result set. 'v19_only' is the one that matters most:
       -- it is the PRD-109 Extra Gum class, a line v3 DROPS. An absence is invisible to any
       -- comparison that only walks the rows v3 produced.
       CASE WHEN v.plan_date IS NULL THEN 'v3_only'
            WHEN s.plan_date IS NULL THEN 'v19_only'
            WHEN s.qty = v.qty       THEN 'match'
            ELSE 'qty_diff'
       END                                            AS diff_kind,
       s.clamp_reason      AS clamp_reason_v3,   v.clamp_reason   AS clamp_reason_v19,
       s.signal            AS signal_v3,         v.signal         AS signal_v19,
       s.current_stock     AS current_stock_v3,  v.current_stock  AS current_stock_v19,
       s.max_stock         AS max_stock_v3,      v.max_stock      AS max_stock_v19,
       s.days_cover        AS days_cover_v3,     v.days_cover     AS days_cover_v19,
       s.wh_available_pod  AS wh_available_v3,   v.wh_available_pod AS wh_available_v19,
       s.velocity_instock  AS velocity_instock_v3,
       v.velocity_30d      AS velocity_30d_v19,
       s.availability_basis AS availability_basis_v3,
       s.reasoning          AS reasoning_v3
  FROM s
  FULL JOIN v
    ON  s.plan_date      =                    v.plan_date
    AND s.machine_id     =                    v.machine_id
    AND s.shelf_id       =                    v.shelf_id
    -- ⛔ IS NOT DISTINCT FROM, not `=`. All four key columns are NOT NULL on both tables today
    -- (verified at build time), so this is currently equivalent — but a `=` here is exactly how
    -- a diff starts silently dropping rows the day a nullable key appears.
    AND s.pod_product_id IS NOT DISTINCT FROM v.pod_product_id;

COMMENT ON VIEW public.v_engine_diff_v3 IS
  'PRD-110 D-12 CANONICAL (Article 16): line-grain nightly diff, engine_add_pod_v3 shadow output '
  '(pod_refills_shadow, latest run per plan_date) vs engine_add_pod v19 live output (pod_refills). '
  'diff_kind partitions into match / qty_diff / v3_only / v19_only. Read-only diagnostic; nothing '
  'operational consumes it (ADR-shadow-plan-tables §5 guarantee 2). Proven by golden fixture 34.';

-- =======================================================================================
-- 2. PER-MACHINE ROLLUP — the "per-machine" dimension BUILD SPEC P2 names, plus blocked.
-- =======================================================================================
CREATE VIEW public.v_engine_diff_v3_by_machine
WITH (security_invoker = true) AS
WITH d AS (
  SELECT * FROM public.v_engine_diff_v3
), lr AS (
  SELECT DISTINCT plan_date, run_id FROM d WHERE run_id IS NOT NULL
), b3 AS (
  SELECT b.plan_date, b.machine_id, count(*) AS n
    FROM public.v_blocked_demand_shadow_v3 b
    JOIN lr ON lr.plan_date = b.plan_date AND lr.run_id = b.run_id
   GROUP BY b.plan_date, b.machine_id
), b19 AS (
  SELECT b.plan_date, b.machine_id, count(*) AS n
    FROM public.blocked_demand b
   WHERE b.plan_date IN (SELECT lr.plan_date FROM lr)
   GROUP BY b.plan_date, b.machine_id
), spine AS (
  -- UNION, not just the diff's machines. A machine that is BLOCKED but carries no plan line
  -- must still appear — that combination is the single most interesting row in the report,
  -- and a diff-only spine would hide it. (Today the sets coincide; the union is what keeps
  -- that from being an assumption.)
  SELECT plan_date, machine_id FROM d
  UNION
  SELECT plan_date, machine_id FROM b3
  UNION
  SELECT plan_date, machine_id FROM b19
)
SELECT sp.plan_date,
       sp.machine_id,
       m.official_name AS machine_name,
       count(*) FILTER (WHERE d.diff_kind IN ('match','qty_diff','v3_only'))  AS lines_v3,
       count(*) FILTER (WHERE d.diff_kind IN ('match','qty_diff','v19_only')) AS lines_v19,
       count(*) FILTER (WHERE d.diff_kind = 'match')                          AS lines_match,
       count(*) FILTER (WHERE d.diff_kind = 'qty_diff')                       AS lines_qty_diff,
       count(*) FILTER (WHERE d.diff_kind = 'v3_only')                        AS lines_v3_only,
       count(*) FILTER (WHERE d.diff_kind = 'v19_only')                       AS lines_v19_only,
       COALESCE(sum(d.qty_v3), 0)                                             AS units_v3,
       COALESCE(sum(d.qty_v19), 0)                                            AS units_v19,
       COALESCE(sum(d.qty_v3), 0) - COALESCE(sum(d.qty_v19), 0)               AS units_delta,
       COALESCE(sum(d.abs_qty_delta), 0)                                      AS abs_units_delta,
       COALESCE(max(b3.n), 0)                                                 AS blocked_v3,
       COALESCE(max(b19.n), 0)                                                AS blocked_v19
  FROM spine sp
  LEFT JOIN d   ON d.plan_date  = sp.plan_date AND d.machine_id  = sp.machine_id
  LEFT JOIN b3  ON b3.plan_date = sp.plan_date AND b3.machine_id = sp.machine_id
  LEFT JOIN b19 ON b19.plan_date= sp.plan_date AND b19.machine_id= sp.machine_id
  LEFT JOIN public.machines m ON m.machine_id = sp.machine_id
 GROUP BY sp.plan_date, sp.machine_id, m.official_name;

COMMENT ON VIEW public.v_engine_diff_v3_by_machine IS
  'PRD-110 D-12: per-machine rollup of v_engine_diff_v3 (lines, units, blocked) — the per-machine '
  'dimension named in BUILD SPEC P2. Machine spine is the UNION of planned and blocked machines, so '
  'a blocked-but-unplanned machine cannot vanish from the report. Proven by golden fixture 34 seq 30-37.';

-- =======================================================================================
-- 3. NIGHTLY SUMMARY — one row per plan_date. This is what the nightly report reads.
-- =======================================================================================
CREATE VIEW public.v_engine_diff_v3_summary
WITH (security_invoker = true) AS
WITH latest AS (
  SELECT DISTINCT ON (sh.plan_date)
         sh.plan_date, sh.run_id, sh.engine_tag, sh.produced_at
    FROM public.pod_refills_shadow sh
   ORDER BY sh.plan_date, sh.produced_at DESC, sh.run_id
), agg AS (
  SELECT d.plan_date,
         count(DISTINCT d.machine_id)                                    AS machines_compared,
         count(*)                                                        AS lines_total,
         count(*) FILTER (WHERE d.diff_kind IN ('match','qty_diff','v3_only'))  AS lines_v3,
         count(*) FILTER (WHERE d.diff_kind IN ('match','qty_diff','v19_only')) AS lines_v19,
         count(*) FILTER (WHERE d.diff_kind = 'match')                   AS lines_match,
         count(*) FILTER (WHERE d.diff_kind = 'qty_diff')                AS lines_qty_diff,
         count(*) FILTER (WHERE d.diff_kind = 'v3_only')                 AS lines_v3_only,
         count(*) FILTER (WHERE d.diff_kind = 'v19_only')                AS lines_v19_only,
         COALESCE(sum(d.qty_v3), 0)                                      AS units_v3,
         COALESCE(sum(d.qty_v19), 0)                                     AS units_v19,
         COALESCE(sum(d.abs_qty_delta), 0)                               AS abs_units_delta
    FROM public.v_engine_diff_v3 d
   GROUP BY d.plan_date
), b3 AS (
  SELECT b.plan_date, count(*) AS n
    FROM public.v_blocked_demand_shadow_v3 b
    JOIN latest l ON l.plan_date = b.plan_date AND l.run_id = b.run_id
   GROUP BY b.plan_date
), b19 AS (
  SELECT b.plan_date, count(*) AS n
    FROM public.blocked_demand b
   WHERE b.plan_date IN (SELECT latest.plan_date FROM latest)
   GROUP BY b.plan_date
)
SELECT l.plan_date,
       l.run_id, l.engine_tag, l.produced_at,
       COALESCE(a.machines_compared, 0) AS machines_compared,
       COALESCE(a.lines_total, 0)       AS lines_total,
       COALESCE(a.lines_v3, 0)          AS lines_v3,
       COALESCE(a.lines_v19, 0)         AS lines_v19,
       COALESCE(a.lines_match, 0)       AS lines_match,
       COALESCE(a.lines_qty_diff, 0)    AS lines_qty_diff,
       COALESCE(a.lines_v3_only, 0)     AS lines_v3_only,
       COALESCE(a.lines_v19_only, 0)    AS lines_v19_only,
       COALESCE(a.units_v3, 0)          AS units_v3,
       COALESCE(a.units_v19, 0)         AS units_v19,
       COALESCE(a.units_v3, 0) - COALESCE(a.units_v19, 0) AS units_delta,
       COALESCE(a.abs_units_delta, 0)   AS abs_units_delta,
       COALESCE(b3.n, 0)                AS blocked_v3,
       COALESCE(b19.n, 0)               AS blocked_v19,
       CASE WHEN COALESCE(a.lines_total, 0) = 0 THEN NULL
            ELSE round(100.0 * a.lines_match / a.lines_total, 2) END AS agreement_pct,
       -- ⛔ THE ANTI-TRAP COLUMN. The whole reason fixture 34 exists is that an empty comparison
       -- reports as "no differences". A diff object must be able to say "I compared NOTHING"
       -- out loud. Any reader of this summary MUST branch on is_vacuous before quoting a delta.
       (COALESCE(a.lines_v3, 0) = 0 OR COALESCE(a.lines_v19, 0) = 0) AS is_vacuous
  FROM latest l
  LEFT JOIN agg a  ON a.plan_date  = l.plan_date
  LEFT JOIN b3     ON b3.plan_date = l.plan_date
  LEFT JOIN b19    ON b19.plan_date= l.plan_date;

COMMENT ON VIEW public.v_engine_diff_v3_summary IS
  'PRD-110 D-12 CANONICAL (Article 16): one row per plan_date that has a v3 shadow run — the nightly '
  'v3-vs-v19 diff report (units, lines, blocked, agreement_pct). ⛔ is_vacuous MUST be checked before '
  'quoting any delta: a comparison with an empty side reports zero differences and means nothing. '
  'Spine is shadow-run dates only; a date v3 never ran is absent rather than falsely reported at parity.';

COMMENT ON COLUMN public.v_engine_diff_v3_summary.is_vacuous IS
  'TRUE when either engine contributed zero lines. Zero differences with is_vacuous TRUE is NOT parity.';

-- The plan-grain view keeps its place (Article 12) but stops being a trap for the next reader.
COMMENT ON VIEW public.v_shadow_vs_live_plan_v3 IS
  '⛔ PRE-CUTOVER THIS VIEW IS ALWAYS EMPTY and its 0 rows are NOT evidence the engines agree. It '
  'reads pod_refill_plan_shadow, which engine_add_pod_v3 never writes (v3 writes pod_refills_shadow). '
  'It becomes correct at Phase-5 cutover, when v3 emits plan-grain rows. For the Phase-2 shadow gate '
  'use public.v_engine_diff_v3_summary — the canonical D-12 object. Pinned by golden fixture 34 seq 60/61.';

REVOKE ALL ON public.v_engine_diff_v3            FROM anon;
REVOKE ALL ON public.v_engine_diff_v3_by_machine FROM anon;
REVOKE ALL ON public.v_engine_diff_v3_summary    FROM anon;
GRANT SELECT ON public.v_engine_diff_v3            TO authenticated, service_role;
GRANT SELECT ON public.v_engine_diff_v3_by_machine TO authenticated, service_role;
GRANT SELECT ON public.v_engine_diff_v3_summary    TO authenticated, service_role;
