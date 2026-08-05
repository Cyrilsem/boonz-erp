-- PRD-110 P1.4 unit 4 — the two BUILD SPEC clauses that had no DB object.
-- Both are READ-ONLY views (Article 14: nothing materialized) with security_invoker=true
-- (Article 2: the caller's RLS on shelf_composition still applies).
-- Cody verdict 2026-07-30: approve with revisions (Article 16 registry entries required).

-- ---------------------------------------------------------------------------
-- 1. v_shelf_audit_prompts — "flagged shelves only (top uncertainty x
--    value-at-risk, max 3/visit)". The selection rule lives HERE, in one
--    canonical object, so the FE cannot reinvent it (the G1 lesson that
--    deleted the FE's independent scorer in P1.2).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_shelf_audit_prompts
WITH (security_invoker = true) AS
WITH p AS (
  SELECT composition_confidence_prompt_threshold AS thr,
         composition_max_prompts_per_visit       AS cap
    FROM public.refill_policy_params WHERE id = 1
), agg AS (
  SELECT sc.machine_id, sc.shelf_id,
         min(sc.confidence)                        AS confidence,
         sum(sc.est_qty)                           AS est_units,
         count(*) FILTER (WHERE sc.est_qty > 0)    AS buckets,
         max(sc.last_verified_at)                  AS last_verified_at,
         max(sc.updated_at)                        AS updated_at
    FROM public.shelf_composition sc
   GROUP BY sc.machine_id, sc.shelf_id
), scored AS (
  SELECT a.machine_id, ss.machine_name, a.shelf_id, ss.shelf_code,
         ss.pod_product_id, ss.pod_name,
         a.confidence, a.est_units, a.buckets,
         a.last_verified_at, a.updated_at,
         COALESCE(pp.recommended_selling_price, 0)::numeric AS unit_price,
         round((1 - a.confidence) * a.est_units
               * COALESCE(pp.recommended_selling_price, 0), 2) AS uncertainty_value_score,
         p.thr AS prompt_threshold, p.cap AS max_prompts_per_visit
    FROM agg a
    JOIN public.v_shelf_state ss ON ss.shelf_id = a.shelf_id
    LEFT JOIN public.pod_products pp ON pp.pod_product_id = ss.pod_product_id
    CROSS JOIN p
   WHERE a.est_units > 0
     AND a.confidence < p.thr          -- "flagged" = below the prompt threshold
), ranked AS (
  SELECT s.*,
         ROW_NUMBER() OVER (PARTITION BY s.machine_id
           ORDER BY s.uncertainty_value_score DESC, s.confidence, s.shelf_id) AS prompt_rank
    FROM scored s
)
SELECT machine_id, machine_name, shelf_id, shelf_code, pod_product_id, pod_name,
       confidence, est_units, buckets, unit_price, uncertainty_value_score,
       prompt_rank, prompt_threshold, max_prompts_per_visit,
       last_verified_at, updated_at
  FROM ranked
 WHERE prompt_rank <= max_prompts_per_visit;

COMMENT ON VIEW public.v_shelf_audit_prompts IS
'PRD-110 P1.4. Canonical driver-audit prompt selector: shelves whose composition confidence is below refill_policy_params.composition_confidence_prompt_threshold, ranked per machine by (1-confidence) * est_units * pod recommended_selling_price, capped at composition_max_prompts_per_visit. Deliberately DISJOINT from v_machine_priority: that object ranks MACHINES for refill urgency, this one ranks SHELVES for physical verification. Do not merge them (Article 16). Consumer: the Stax driver-collapse UI (S-14).';

-- ---------------------------------------------------------------------------
-- 2. v_expiry_action_queue — BUILD SPEC P1.4's auto-action gate:
--    "expiry auto-write-off lines require confidence >= 0.7 (param), else
--    a verify task".
--    NULL expiry_bucket is EXCLUDED on purpose: NULL = UNKNOWN = sellable.
--    Treating unknown as expired would inflate est_qty without bound
--    (leg-8 pointer risk 18).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_expiry_action_queue
WITH (security_invoker = true) AS
WITH p AS (
  SELECT composition_confidence_min_autoaction AS autoaction_min
    FROM public.refill_policy_params WHERE id = 1
)
SELECT sc.machine_id, ss.machine_name, sc.shelf_id, ss.shelf_code,
       sc.boonz_product_id, bp.boonz_product_name,
       sc.expiry_bucket, sc.est_qty, sc.confidence,
       (CURRENT_DATE - sc.expiry_bucket) AS days_expired,
       p.autoaction_min,
       CASE WHEN sc.confidence >= p.autoaction_min
            THEN 'auto_write_off' ELSE 'verify_task' END AS action,
       sc.last_verified_at, sc.updated_at
  FROM public.shelf_composition sc
  CROSS JOIN p
  JOIN public.v_shelf_state ss ON ss.shelf_id = sc.shelf_id
  LEFT JOIN public.boonz_products bp ON bp.product_id = sc.boonz_product_id
 WHERE sc.est_qty > 0
   AND sc.expiry_bucket IS NOT NULL
   AND sc.expiry_bucket < CURRENT_DATE;

COMMENT ON VIEW public.v_expiry_action_queue IS
'PRD-110 P1.4 auto-action gate. Believed-expired units per (shelf, product, expiry_bucket) from shelf_composition, with action = auto_write_off when confidence >= refill_policy_params.composition_confidence_min_autoaction (0.7) else verify_task. This is BELIEF, and is deliberately DISJOINT from the registered batch-record expiry metric v_machine_expiry_summary / v_machine_expiry_batches, which reads pod_inventory (DATA-SOURCE LAW: pod_inventory = expiry history ONLY). Do not merge them (Article 16). NULL expiry_bucket rows are excluded by design: NULL = UNKNOWN = sellable. Proposing an action is NOT taking one - the EXPIRY IRON RULE still requires a human write_off event.';
