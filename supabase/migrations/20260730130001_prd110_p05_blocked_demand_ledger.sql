-- PRD-110 P0.5 - blocked_demand ledger (crude v1) + open/aging reader view.
-- Applied via Supabase MCP as `prd110_p05_blocked_demand_ledger` 2026-07-30.
--
-- WHY: LAW 5 "silent qty-0 is a build failure. Every blocked unit lands in blocked_demand."
-- Today the engine clamps demand it cannot satisfy and labels it (clamp_reason), but the units
-- have nowhere to land: procurement never sees them. Baseline measured live 2026-07-30:
-- 17 blocked_no_wh + 3 partial_wh_limited = 20 gap rows / 107 units on plan_date 2026-07-30.
--
-- Dara design notes (D1..D7):
--   D1 uuid PK `blocked_demand_id`.
--   D2 every column NOT NULL except the resolution triplet + boonz_product_id (documented below).
--   D3 enum-ish columns carry CHECK constraints, not free text; qty is int, times are timestamptz.
--   D4 every FK declares ON DELETE. Keys are RESTRICT: a machine/shelf/pod with unresolved
--      blocked demand must not vanish silently underneath procurement.
--   D5 each index below names the query it serves.
--
-- Cody class (a)+(b). blocked_demand is a NEW ledger, NOT in Appendix A (not a protected entity),
-- so this is not an Article 14 "parallel _v2 table" - it is the canonical (and only) object for
-- this concept. Article 2 satisfied (RLS on). Article 3 satisfied (no write policy at all  - 
-- writes only through the DEFINER RPC in 20260730130002). Article 8 satisfied (generic
-- audit_log_write trigger attached, incl. the stale-close DELETE path).

CREATE TABLE IF NOT EXISTS public.blocked_demand (
  blocked_demand_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_date         date NOT NULL,
  machine_id        uuid NOT NULL REFERENCES public.machines(machine_id)             ON DELETE RESTRICT,
  shelf_id          uuid NOT NULL REFERENCES public.shelf_configurations(shelf_id)   ON DELETE RESTRICT,
  pod_product_id    uuid NOT NULL REFERENCES public.pod_products(pod_product_id)     ON DELETE RESTRICT,
  boonz_product_id  uuid     NULL REFERENCES public.boonz_products(product_id)       ON DELETE SET NULL,
  qty_blocked       integer  NOT NULL CHECK (qty_blocked > 0),
  reason            text     NOT NULL CHECK (reason IN
                      ('blocked_no_wh','partial_wh_limited','substitution_exhausted','routing_gap')),
  source            text     NOT NULL CHECK (source IN ('engine_add','stitch','pack')),
  detected_by       text     NOT NULL DEFAULT 'record_blocked_demand_v3',
  reasoning         jsonb    NOT NULL DEFAULT '{}'::jsonb,
  created_at        timestamptz NOT NULL DEFAULT now(),
  resolved_at       timestamptz NULL,
  resolution        text     NULL CHECK (resolution IN ('po','spot_buy','transfer','dropped')),
  resolved_by       uuid     NULL REFERENCES public.user_profiles(id)                ON DELETE SET NULL,
  resolution_note   text     NULL,
  CONSTRAINT blocked_demand_resolution_pair CHECK (
    (resolved_at IS NULL     AND resolution IS NULL)
 OR (resolved_at IS NOT NULL AND resolution IS NOT NULL))
);

COMMENT ON TABLE public.blocked_demand IS
  'PRD-110 P0.5. One row per unit-block the planner could not satisfy. LAW 5: no blocked unit '
  'may be silent. Written ONLY by record_blocked_demand_v3 (engine_add source; stitch/pack '
  'sources arrive in Phase 3/4). Read through v_blocked_demand_open.';
COMMENT ON COLUMN public.blocked_demand.boonz_product_id IS
  'NULL by design in v1: pod_refills has no boonz_product_id, so P0.5 is pod-grain. SKU grain '
  'arrives with Phase 3 (P3.2). Nullable, not missing.';
COMMENT ON COLUMN public.blocked_demand.qty_blocked IS
  'Units of demand the plan could not place = ceil(reasoning.need_raw - pod_refills.qty). Always > 0.';
COMMENT ON COLUMN public.blocked_demand.reason IS
  'blocked_no_wh / partial_wh_limited are engine clamp_reasons (source=engine_add). '
  'substitution_exhausted comes from the Phase-3 stitch ladder, routing_gap from the FEFO bind step.';
COMMENT ON COLUMN public.blocked_demand.resolved_at IS
  'NULL = open demand. Paired with resolution by blocked_demand_resolution_pair so a row can '
  'never be half-resolved.';

-- Serves: the "is this (plan_date, shelf, pod) already open?" upsert arbiter inside
-- record_blocked_demand_v3. Partial so resolved history never blocks a genuinely new block.
CREATE UNIQUE INDEX IF NOT EXISTS uq_blocked_demand_open
  ON public.blocked_demand (plan_date, machine_id, shelf_id, pod_product_id, source)
  WHERE resolved_at IS NULL;

-- Serves: v_blocked_demand_open (the procurement worklist) - open rows, oldest demand first.
CREATE INDEX IF NOT EXISTS idx_blocked_demand_open_aging
  ON public.blocked_demand (plan_date, reason)
  WHERE resolved_at IS NULL;

-- Serves: per-machine drill-down on the FE machine page / advisory.
CREATE INDEX IF NOT EXISTS idx_blocked_demand_machine_date
  ON public.blocked_demand (machine_id, plan_date DESC);

ALTER TABLE public.blocked_demand ENABLE ROW LEVEL SECURITY;

-- Article 2/3: readable by the operating roles (procurement consumer), writable by NOBODY
-- directly. No INSERT/UPDATE/DELETE policy exists, so the DEFINER RPC (which runs as owner and
-- bypasses RLS) is structurally the only write path. Role lookup uses the (SELECT auth.uid())
-- form - bare auth.uid() is the #1 RLS perf bug in Boonz history.
DROP POLICY IF EXISTS blocked_demand_select ON public.blocked_demand;
CREATE POLICY blocked_demand_select ON public.blocked_demand
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles up
                 WHERE up.id = (SELECT auth.uid())
                   AND up.role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])));

-- Article 8: universal audit. Generic trigger, pk column passed as TG_ARGV[0].
-- Covers the stale-close DELETE path too, which is what makes that delete auditable.
DROP TRIGGER IF EXISTS tg_audit_blocked_demand ON public.blocked_demand;
CREATE TRIGGER tg_audit_blocked_demand
  AFTER INSERT OR UPDATE OR DELETE ON public.blocked_demand
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_write('blocked_demand_id');

-- Reader: the procurement worklist with aging. security_invoker so the caller's RLS applies
-- rather than the view owner's.
CREATE OR REPLACE VIEW public.v_blocked_demand_open
WITH (security_invoker = true) AS
SELECT bd.blocked_demand_id,
       bd.plan_date,
       bd.machine_id,
       m.official_name        AS machine_name,
       bd.shelf_id,
       sc.shelf_code,
       bd.pod_product_id,
       pp.pod_product_name,
       bd.boonz_product_id,
       bd.qty_blocked,
       bd.reason,
       bd.source,
       bd.created_at,
       (CURRENT_DATE - bd.plan_date)                     AS age_days,
       CASE WHEN (CURRENT_DATE - bd.plan_date) >= 14 THEN 'critical'
            WHEN (CURRENT_DATE - bd.plan_date) >=  7 THEN 'aging'
            WHEN (CURRENT_DATE - bd.plan_date) >=  3 THEN 'watch'
            ELSE 'fresh' END                             AS age_bucket,
       bd.reasoning
  FROM public.blocked_demand bd
  JOIN public.machines             m  ON m.machine_id      = bd.machine_id
  JOIN public.shelf_configurations sc ON sc.shelf_id        = bd.shelf_id
  JOIN public.pod_products         pp ON pp.pod_product_id  = bd.pod_product_id
 WHERE bd.resolved_at IS NULL;

COMMENT ON VIEW public.v_blocked_demand_open IS
  'PRD-110 P0.5 canonical reader for open blocked demand, with aging buckets '
  '(fresh <3d, watch 3-6d, aging 7-13d, critical >=14d measured from plan_date). '
  'The weekly-procurement consumer reads THIS, never blocked_demand directly.';

GRANT SELECT ON public.blocked_demand      TO authenticated;
GRANT SELECT ON public.v_blocked_demand_open TO authenticated;
