-- PRD-110 leg 33 · S-37 FIX · canonicalise the pod key in v_shelf_instock_velocity_split_v3.
--
-- DEFECT. v_shelf_sales_identity and v_shelf_instock_velocity_v3 both canonicalise the pod
-- alias 168aeb7e 'Hunter' -> 51e4600f 'Hunter Ridge'. This view did not, then joined
--     vel.pod_product_id (CANONICAL) = shelves.pod_product_id (RAW, from v_shelf_state)
-- so all 16 Hunter-keyed shelves missed the join and silently carried a NULL velocity.
--
-- THE FIX IS THREE EDITS, NOT ONE. Canonicalising only the final join double-counts: split
-- weights PARTITION BY (machine_id, pod_product_id), so each raw group would independently
-- claim the full merged-pod velocity on the 7 machines that carry BOTH shelves
-- (ALJLT-1015-0100-B1, ALJLT-1015-0200-O1, AMZ-1046-2406-O1, HUAWEI-2003-0000-B1,
-- MC-2004-0100-O1, USH-1008-0000-W1, WAVEMAKER-1006-4100-O1).
--   (1) `shelves`    - canonicalise the pod key (LEFT JOIN alias).
--   (2) `slot_stock` - canonicalise it there too; its pod_product_id comes from raw WEIMI
--                      history, and shelf_hours joins the two on that key.
--   (3) `n`          - RECOMPUTED over the merged group.
--
-- (3) IS THE ONE LEG 32'S DRY-RUN COULD NOT HAVE CAUGHT, and it is why this is not a
-- two-line change. v_shelf_state derives pod_shelf_count as
--     count(*) OVER (PARTITION BY b.machine_id, i.pod_product_id)   -- RAW key
-- and MEASURED THIS LEG: all 26 shelves in the family carry n = 1. Merging two n=1 shelves
-- without recomputing n sends both down the 'single_shelf' branch (w_raw = 1.0 each), w_sum
-- becomes 2.0, and the residual absorber "repairs" the group to w = 0.0 and w = 1.0.
-- Conservation still reads EXACTLY 0 - the absorber launders it - while one real shelf
-- silently receives zero velocity. That is a LAW 5 silent zero hiding behind a green
-- conservation check. Proof it was real: after this fix the family reports
-- instock_weighted = 14 (the 7 dual machines x 2). Under a join-only fix those same 14 rows
-- would have read 'single_shelf'.
--
-- PROVEN ON A _test SHADOW BEFORE APPLY (single read, all aggregates):
--   rows 544 = v_shelf_state pod-bound 544, distinct shelves 544  (no fan-out)
--   raw-keyed rows 0 · family 26 conserved · family NULL velocity 2, both AMZ-1046 (D-13)
--   n-vs-group-size mismatches 0 · single_shelf with w<>1 0 · merged groups of 2 = 7
--   conservation exact: 0 violating, max |sum(w)-1| = 0.000000000 across ALL 544
--   w in [0,1] 0 viol · sum(velocity_instock_shelf) = velocity_instock_pod 0 viol
--   pod-NULL <=> shelf-NULL 0 viol · exactly one absorber per pod · split_method total
--
-- ⚠️ ARTICLE 16 DEBT, RECORDED DELIBERATELY (Cody, this leg). This is now the THIRD inline
-- copy of a pod-identity rule that v_shelf_sales_identity owns canonically. There is no
-- canonical alias object to read, so the copy is unavoidable today - but it is drift risk,
-- not a design. Mitigated mechanically by golden fixture 2 seq 65, which fails if the three
-- definitions ever stop agreeing on the pair. Convergence onto ONE canonical alias object is
-- parked as S-38: it would have to touch a LIVE canonical metric object, which is out of
-- scope for an S-37 correctness fix (LAW 10).
--
-- 📌 FLAGGED, NOT RELITIGATED (inherited from leg 32): PRD-109's rule is that a name family
-- is "Active mapping ANY scope UNION product_family_id, NEVER name-prefix", and it records
-- Hunter vs Hunter Ridge as a landmine precisely because they are DIFFERENT products. This
-- alias is a pre-existing production decision in v_shelf_sales_identity; this migration
-- propagates it for consistency and does not endorse it. If CS rules the alias wrong, all
-- three copies AND this fixture change together - which is exactly what seq 65 guarantees.
--
-- Zero consumers at apply time (no view, no proc references it). security_invoker preserved.
-- No protected entity, no RLS, no SECURITY DEFINER, no live plan table, no engine, no flag.

CREATE OR REPLACE VIEW public.v_shelf_instock_velocity_split_v3 WITH (security_invoker = true) AS
WITH p AS (SELECT 30 AS win_days),
w AS (SELECT ba.t_anchor, ba.t_anchor - make_interval(days => p.win_days) AS t_start
      FROM p CROSS JOIN (SELECT max(ds.snapshot_at) AS t_anchor
                         FROM weimi_device_status ds JOIN machines m ON m.machine_id = ds.machine_id) ba),
-- Identical VALUES list to v_shelf_sales_identity and v_shelf_instock_velocity_v3.
-- Fixture 2 seq 65 asserts this agreement mechanically. Do not edit one copy alone.
alias(pod_product_id, canonical_pod) AS (
  VALUES ('168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid,'51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid)
),
shelves AS MATERIALIZED (
  SELECT ss.machine_id, ss.machine_name, ss.shelf_id, ss.shelf_code, ss.slot_name,
         COALESCE(al.canonical_pod, ss.pod_product_id) AS pod_product_id,
         -- pod_name stays the shelf's OWN binding (a Hunter shelf still reads 'Hunter').
         -- It is deliberately NOT functionally determined by pod_product_id after merging:
         -- the truthful answer to "what is on this shelf" is the shelf's own product, while
         -- the velocity POOL is the merged family. Consumers must key on pod_product_id.
         ss.pod_name,
         count(*) OVER (PARTITION BY ss.machine_id, COALESCE(al.canonical_pod, ss.pod_product_id))::integer AS n
  FROM v_shelf_state ss
  LEFT JOIN alias al ON al.pod_product_id = ss.pod_product_id
  WHERE ss.pod_product_id IS NOT NULL
),
snaps AS MATERIALIZED (
  SELECT DISTINCT ds.machine_id, ds.snapshot_at
  FROM weimi_device_status ds JOIN machines m ON m.machine_id = ds.machine_id CROSS JOIN w w_1
  WHERE ds.snapshot_at >= w_1.t_start AND ds.snapshot_at <= w_1.t_anchor
),
iv AS MATERIALIZED (
  SELECT q.machine_id, q.t_i, EXTRACT(epoch FROM q.t_next - q.t_i) / 3600.0 AS h_len
  FROM (SELECT snaps.machine_id, snaps.snapshot_at AS t_i,
               lead(snaps.snapshot_at) OVER (PARTITION BY snaps.machine_id ORDER BY snaps.snapshot_at) AS t_next
        FROM snaps) q
  WHERE q.t_next IS NOT NULL
),
slot_stock AS MATERIALIZED (
  SELECT h.machine_id, h.slot_name,
         COALESCE(al.canonical_pod, h.pod_product_id) AS pod_product_id,
         h.snapshot_at, sum(h.current_stock) AS stock
  FROM v_weimi_shelf_history_v3 h
  CROSS JOIN w w_1
  LEFT JOIN alias al ON al.pod_product_id = h.pod_product_id
  WHERE h.pod_product_id IS NOT NULL AND h.is_enabled AND COALESCE(h.is_broken, false) = false
    AND h.snapshot_at >= w_1.t_start AND h.snapshot_at <= w_1.t_anchor
  GROUP BY h.machine_id, h.slot_name, COALESCE(al.canonical_pod, h.pod_product_id), h.snapshot_at
),
shelf_hours AS MATERIALIZED (
  SELECT s.machine_id, s.shelf_id, s.pod_product_id,
         COALESCE(sum(iv.h_len) FILTER (WHERE ss.stock > 0), 0::numeric) AS shelf_instock_hours
  FROM shelves s
  LEFT JOIN iv ON iv.machine_id = s.machine_id
  LEFT JOIN slot_stock ss ON ss.machine_id = s.machine_id AND ss.slot_name = s.slot_name
                         AND ss.pod_product_id = s.pod_product_id AND ss.snapshot_at = iv.t_i
  GROUP BY s.machine_id, s.shelf_id, s.pod_product_id
),
wt AS (
  SELECT sh.machine_id, sh.shelf_id, sh.pod_product_id, sh.shelf_instock_hours,
         sum(sh.shelf_instock_hours) OVER (PARTITION BY sh.machine_id, sh.pod_product_id) AS pod_instock_hours
  FROM shelf_hours sh
),
split AS (
  SELECT s.machine_id, s.machine_name, s.shelf_id, s.shelf_code, s.slot_name, s.pod_product_id,
         s.pod_name, s.n, wt.shelf_instock_hours, wt.pod_instock_hours,
         CASE WHEN s.n = 1 THEN 'single_shelf'::text
              WHEN wt.pod_instock_hours > 0::numeric AND wt.shelf_instock_hours = 0::numeric THEN 'zero_instock'::text
              WHEN wt.pod_instock_hours > 0::numeric THEN 'instock_weighted'::text
              ELSE 'equal_fallback'::text END AS split_method,
         CASE WHEN s.n = 1 THEN 1.0
              WHEN wt.pod_instock_hours > 0::numeric THEN wt.shelf_instock_hours / wt.pod_instock_hours
              ELSE 1.0 / s.n::numeric END AS w_raw
  FROM shelves s
  JOIN wt ON wt.machine_id = s.machine_id AND wt.shelf_id = s.shelf_id AND wt.pod_product_id = s.pod_product_id
),
absorb AS (
  SELECT sp.machine_id, sp.machine_name, sp.shelf_id, sp.shelf_code, sp.slot_name, sp.pod_product_id,
         sp.pod_name, sp.n, sp.shelf_instock_hours, sp.pod_instock_hours, sp.split_method, sp.w_raw,
         sum(sp.w_raw) OVER (PARTITION BY sp.machine_id, sp.pod_product_id) AS w_sum,
         row_number() OVER (PARTITION BY sp.machine_id, sp.pod_product_id ORDER BY sp.shelf_instock_hours DESC, sp.shelf_id) AS absorber_rank
  FROM split sp
),
fin AS (
  SELECT a.machine_id, a.machine_name, a.shelf_id, a.shelf_code, a.slot_name, a.pod_product_id,
         a.pod_name, a.n, a.shelf_instock_hours, a.pod_instock_hours, a.split_method, a.w_raw,
         a.w_sum, a.absorber_rank,
         CASE WHEN a.absorber_rank = 1 THEN a.w_raw + (1.0 - a.w_sum) ELSE a.w_raw END AS w_instock
  FROM absorb a
),
vel AS MATERIALIZED (
  SELECT v.machine_id, v.pod_product_id, v.velocity_instock, v.velocity_raw, v.velocity_status
  FROM v_shelf_instock_velocity_v3 v
)
SELECT f.machine_id, f.machine_name, f.shelf_id, f.shelf_code, f.slot_name, f.pod_product_id, f.pod_name,
       f.n AS pod_shelf_count,
       round(f.shelf_instock_hours, 4) AS shelf_instock_hours,
       round(f.pod_instock_hours, 4) AS pod_instock_hours,
       f.split_method, f.w_instock, 1.0 / f.n::numeric AS w_equal,
       v.velocity_instock AS velocity_instock_pod, v.velocity_raw AS velocity_raw_pod,
       v.velocity_instock * f.w_instock AS velocity_instock_shelf,
       v.velocity_raw * f.w_instock AS velocity_raw_shelf,
       v.velocity_status, w.t_start, w.t_anchor,
       f.absorber_rank = 1 AS is_residual_absorber
FROM fin f
CROSS JOIN w
LEFT JOIN vel v ON v.machine_id = f.machine_id AND v.pod_product_id = f.pod_product_id;

-- Cody's required revision: a mechanical control, not a comment. Fails the suite if this
-- view's alias pair ever stops matching the canonical owner's.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required, acceptance_gate_sql)
VALUES (2, 65,
 'S-38 / Article 16 ANTI-DRIFT: this view canonicalises the pod alias inline, a THIRD copy of a rule v_shelf_sales_identity owns. Fails the instant the two definitions stop agreeing on the pair.',
 'SELECT (
    (SELECT count(*) FROM regexp_matches(pg_get_viewdef(''public.v_shelf_instock_velocity_split_v3''::regclass), ''168aeb7e-fc0c-441b-94df-6d8cc185945d''::text, ''g'')) > 0
    AND (SELECT count(*) FROM regexp_matches(pg_get_viewdef(''public.v_shelf_instock_velocity_split_v3''::regclass), ''51e4600f-2c15-428b-92ef-85fdc783c3af''::text, ''g'')) > 0
    AND (SELECT count(*) FROM regexp_matches(pg_get_viewdef(''public.v_shelf_sales_identity''::regclass), ''168aeb7e-fc0c-441b-94df-6d8cc185945d''::text, ''g'')) > 0
    AND (SELECT count(*) FROM regexp_matches(pg_get_viewdef(''public.v_shelf_sales_identity''::regclass), ''51e4600f-2c15-428b-92ef-85fdc783c3af''::text, ''g'')) > 0
    AND (SELECT count(*) FROM regexp_matches(pg_get_viewdef(''public.v_shelf_instock_velocity_v3''::regclass), ''168aeb7e-fc0c-441b-94df-6d8cc185945d''::text, ''g'')) > 0
    AND (SELECT count(*) FROM regexp_matches(pg_get_viewdef(''public.v_shelf_instock_velocity_v3''::regclass), ''51e4600f-2c15-428b-92ef-85fdc783c3af''::text, ''g'')) > 0
  )::text',
 'eq', 'true', true, 'P2', NULL);

DROP VIEW IF EXISTS public.v_shelf_instock_velocity_split_v3_test;
